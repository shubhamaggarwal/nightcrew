#!/usr/bin/env python3
"""Nightcrew dashboard. Python 3 stdlib only. Binds 127.0.0.1 only.

Thin viewer: every mutation shells out to bin/ so the engine and the UI
share one implementation of every rule."""
import html
import json
import math
import os
import re
import subprocess
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "bin")
LLM_STATES = ["requirements", "planning", "executing", "verifying"]
MODELS = ["claude-opus-5", "claude-opus-5[1m]",
          "claude-sonnet-5", "claude-sonnet-5[1m]",
          "claude-haiku-4-5-20251001"]
COLUMNS = [
    ("Queue", ["new", "requirements"]),
    ("Needs you", ["awaiting-approval"]),
    ("In progress", ["planning", "executing", "verifying", "closing"]),
    ("Done", ["closed", "failed"]),
]
ARTIFACTS = ["ticket.md", "requirements.md", "plan.md",
             "execution-notes.md", "verification.md", "failed.json"]
BADGE_CLASS = {"new": "b-queue", "requirements": "b-queue",
               "awaiting-approval": "b-wait",
               "planning": "b-run", "executing": "b-run",
               "verifying": "b-run", "closing": "b-run",
               "closed": "b-done", "failed": "b-fail"}

# Log renderer render budget: bounds so one page render never carries the
# whole stream-json log (a session can write tens of MB across a run).
LOG_TAIL_BYTES = 262144
LOG_MAX_EVENTS = 400
LOG_TEXT_CHARS = 4000
LOG_TOOL_INPUT_CHARS = 1200
LOG_RESULT_CHARS = 2000
SYSTEM_NOTE_FIELDS = {
    "thinking_tokens": ("estimated_tokens",),
    "hook_started": ("hook_name",),
    "hook_response": ("hook_name", "exit_code"),
    "task_started": ("task_type", "description"),
    "task_notification": ("status", "summary"),
    "vcs_state_changed": ("kind", "branch"),
}

CSS = """
:root{color-scheme:dark}
*{box-sizing:border-box}
body{font:14px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,sans-serif;
  margin:0;color:#e7ebf7;background:#0b1020;
  background:radial-gradient(1100px 500px at 85% -120px,rgba(46,62,120,.35),rgba(11,16,32,0)),#0b1020;
  min-height:100vh}
header{position:sticky;top:0;z-index:10;display:flex;justify-content:space-between;
  align-items:center;padding:14px 24px;background:rgba(11,16,32,.82);
  backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px);border-bottom:1px solid #1d2540}
header>a{text-decoration:none;color:#e7ebf7;font-weight:700;font-size:14px;
  letter-spacing:.18em;text-transform:uppercase}
header>a b{color:#e8b34b;font-weight:700}
header nav a{margin-left:20px;font-size:13px;color:#949cbc;text-decoration:none;transition:color .15s}
header nav a:hover{color:#e8b34b}
main{padding:22px 24px;max-width:1280px;margin:0 auto}
.board{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px}
@media(max-width:960px){.board{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media(max-width:600px){.board{grid-template-columns:1fr}}
.col{background:#10162b;border:1px solid #1d2540;border-radius:14px;padding:12px;min-height:120px}
.col h2{display:flex;justify-content:space-between;align-items:center;margin:2px 4px 10px;
  font-size:11.5px;font-weight:600;letter-spacing:.1em;text-transform:uppercase;color:#949cbc}
.col h2 .n{background:#1d2540;color:#aeb7d8;border-radius:999px;padding:1px 9px;font-size:11px}
.card{background:#161e38;border:1px solid #263156;border-radius:12px;padding:12px;
  margin-bottom:10px;transition:transform .12s,border-color .12s,box-shadow .12s}
.card:hover{transform:translateY(-1px);border-color:#3a477a;box-shadow:0 6px 18px rgba(0,0,0,.35)}
.card .id{font:11px ui-monospace,Menlo,monospace;color:#6f7aa3}
.card .t{font-size:14px;font-weight:600;margin:4px 0 8px}
.card a{color:#e7ebf7;text-decoration:none}
.card .t a:hover{color:#e8b34b}
.badge{display:inline-block;font-size:11px;font-weight:600;padding:2px 9px;
  border-radius:999px;border:1px solid transparent}
.b-queue{background:rgba(148,156,188,.1);color:#aeb7d8;border-color:rgba(148,156,188,.25)}
.b-wait{background:rgba(138,182,255,.1);color:#8ab6ff;border-color:rgba(138,182,255,.3)}
.b-run{background:rgba(232,179,75,.1);color:#e8b34b;border-color:rgba(232,179,75,.3)}
.b-done{background:rgba(95,211,154,.1);color:#5fd39a;border-color:rgba(95,211,154,.3)}
.b-fail{background:rgba(255,122,122,.1);color:#ff7a7a;border-color:rgba(255,122,122,.3)}
.b-tool{background:rgba(232,179,75,.1);color:#e8b34b;border-color:rgba(232,179,75,.3);
  font-family:ui-monospace,Menlo,monospace}
@keyframes ncpulse{0%,100%{opacity:1}50%{opacity:.4}}
.b-run::before,.b-wait::before{content:'';display:inline-block;width:6px;height:6px;
  border-radius:50%;margin:0 6px 1px 0;vertical-align:middle}
.b-run::before{background:#e8b34b;animation:ncpulse 1.6s ease-in-out infinite}
.b-wait::before{background:#8ab6ff}
.meta{font:11px ui-monospace,Menlo,monospace;color:#6f7aa3;margin-top:8px}
.meta a{color:#8ab6ff}
.prog{height:4px;background:#1d2540;border-radius:999px;margin-top:10px;overflow:hidden;max-width:680px}
.prog-bar{height:100%;background:linear-gradient(90deg,#b98829,#e8b34b);border-radius:999px;
  transition:width .6s ease;animation:ncpulse 1.6s ease-in-out infinite}
.prog-meta{color:#e8b34b;margin-top:5px}
.warn{background:rgba(232,179,75,.08);border:1px solid rgba(232,179,75,.35);color:#ecd9a8;
  border-radius:10px;padding:10px 14px;margin-bottom:14px;font-size:13px}
.err{color:#ff7a7a;font-size:13px}
.path{font:11px ui-monospace,Menlo,monospace;color:#6f7aa3}
button{font:inherit;font-size:12.5px;font-weight:600;padding:6px 14px;border-radius:8px;
  border:1px solid #2a335a;background:#1a2340;color:#e7ebf7;cursor:pointer;
  margin-top:6px;transition:border-color .15s,color .15s,background .15s}
button:hover{border-color:#e8b34b;color:#e8b34b}
button.pri{background:#e8b34b;border-color:#e8b34b;color:#16130a}
button.pri:hover{background:#f2c56a;border-color:#f2c56a;color:#0b1020}
form.inline{display:inline}
pre{background:#0a0e1d;border:1px solid #1d2540;border-radius:12px;padding:14px;
  overflow-x:auto;font-size:12px;line-height:1.5;white-space:pre-wrap;color:#c7d0ec}
.log-file{margin-bottom:22px}
.log-file:last-child{margin-bottom:0}
.ev{background:#0a0e1d;border:1px solid #1d2540;border-radius:8px;padding:8px 12px;margin-bottom:6px}
.ev-text{color:#c7d0ec;white-space:pre-wrap}
.ev-think,.ev-note{color:#6f7aa3;font-size:12px}
.ev-tool summary{cursor:pointer}
.ev-tool-desc{color:#c7d0ec;font-size:12.5px;margin-bottom:4px}
.ev-res{border-left:3px solid #263156;padding-left:10px;color:#949cbc;white-space:pre-wrap}
.ev-res.ev-err{border-left-color:#ff7a7a}
.ev-cut{color:#6f7aa3;font-size:11px}
.ev-init,.ev-result{color:#aeb7d8;font-size:12.5px}
.tabs{margin:14px 0 6px}
.tabs a{display:inline-block;font-size:12.5px;padding:4px 12px;margin:0 6px 6px 0;
  border-radius:999px;border:1px solid #263156;color:#949cbc;text-decoration:none;
  transition:border-color .15s,color .15s}
.tabs a:hover{color:#e8b34b;border-color:#e8b34b}
.tabs a.on{background:#1d2540;color:#e7ebf7;border-color:#3a477a;font-weight:600}
label{display:block;font-size:12.5px;font-weight:600;color:#949cbc;margin:14px 0 5px}
.hint{font-weight:400;color:#6f7aa3}
code{font:11.5px ui-monospace,Menlo,monospace;background:#1d2540;padding:1px 5px;
  border-radius:5px;color:#e8b34b}
input[type=text],textarea,select{width:100%;max-width:680px;font:inherit;font-size:13.5px;
  padding:8px 10px;border:1px solid #2a335a;border-radius:8px;background:#0e1428;
  color:#e7ebf7;transition:border-color .15s,box-shadow .15s}
input[type=text]:focus,textarea:focus,select:focus{outline:none;border-color:#e8b34b;
  box-shadow:0 0 0 3px rgba(232,179,75,.15)}
textarea{font-family:ui-monospace,Menlo,monospace;font-size:12.5px}
.panel{background:#10162b;border:1px solid #1d2540;border-radius:14px;
  padding:18px 20px;margin-bottom:18px;max-width:760px}
.panel h2{margin:0 0 4px;font-size:14px;letter-spacing:.08em;text-transform:uppercase;color:#e8b34b}
.row{display:flex;gap:8px;max-width:680px;align-items:flex-start}
.row input{flex:1}
.row button{white-space:nowrap;margin-top:0}
.nb{display:none;background:#0e1428;border:1px solid #2a335a;border-radius:10px;
  margin-top:8px;max-width:680px;max-height:320px;overflow-y:auto;padding:6px}
.nb-head{display:flex;justify-content:space-between;align-items:center;gap:10px;
  padding:6px 8px;border-bottom:1px solid #1d2540;margin-bottom:4px;
  position:sticky;top:0;background:#0e1428}
.nb-head button{margin-top:0}
.nb-dir{display:block;padding:5px 10px;border-radius:7px;color:#c7d0ec;
  text-decoration:none;font-size:13px}
.nb-dir:hover{background:#1d2540;color:#e8b34b}
.nb-git{font-size:10px;font-weight:700;color:#5fd39a;border:1px solid rgba(95,211,154,.4);
  border-radius:5px;padding:0 5px;margin-left:6px;vertical-align:1px}
"""


def load_config():
    with open(os.path.join(ROOT, "config.json")) as f:
        return json.load(f)


def registry():
    try:
        with open(os.path.join(ROOT, "state", "registry")) as f:
            return [ln.strip() for ln in f if ln.strip()]
    except OSError:
        return []


def fm_title(path):
    try:
        with open(path, errors="replace") as f:
            m = re.search(r"^title: (.*)$", f.read(), re.M)
        return m.group(1) if m else "(untitled)"
    except OSError:
        return "(unreadable)"


def age(path):
    secs = int(time.time() - os.path.getmtime(path))
    if secs < 3600:
        return "%dm" % max(secs // 60, 0)
    if secs < 86400:
        return "%dh" % (secs // 3600)
    return "%dd" % (secs // 86400)


def tickets():
    out = []
    for wd in registry():
        troot = os.path.join(wd, ".nightcrew", "tickets")
        if not os.path.isdir(troot):
            continue
        for tid in sorted(os.listdir(troot)):
            tdir = os.path.join(troot, tid)
            sfile = os.path.join(tdir, "state")
            if not os.path.isfile(sfile):
                continue
            with open(sfile, errors="replace") as f:
                state = f.read().strip()
            t = {"id": tid, "dir": tdir, "workdir": wd, "state": state,
                 "title": fm_title(os.path.join(tdir, "ticket.md")),
                 "age": age(sfile), "pr": None, "failed": None}
            pru = os.path.join(tdir, "pr-url")
            if os.path.isfile(pru):
                with open(pru, errors="replace") as f:
                    t["pr"] = f.read().strip()
            fj = os.path.join(tdir, "failed.json")
            if os.path.isfile(fj):
                try:
                    with open(fj, errors="replace") as f:
                        t["failed"] = json.load(f)
                except ValueError:
                    t["failed"] = {"state": "?", "reason": "unreadable failed.json"}
            out.append(t)
    return out


def state_cfg(workdir, state, key, default=None):
    """Per-state config value: the workdir's .nightcrew/config.json override
    wins over the global config, mirroring bin/lib.sh state_config."""
    try:
        with open(os.path.join(workdir, ".nightcrew", "config.json"),
                  errors="replace") as f:
            v = json.load(f).get("states", {}).get(state, {}).get(key)
        if v is not None:
            return v
    except (OSError, ValueError):
        pass
    return load_config().get("states", {}).get(state, {}).get(key, default)


def session_progress(t):
    """Live progress for a running session, or None.

    Derived purely from files: the mkdir .lock proves a run-state owns the
    ticket right now, and the newest stream-json log gives an approximate
    turn count (assistant events) plus elapsed wall time."""
    if t["state"] not in LLM_STATES:
        return None
    if not os.path.isdir(os.path.join(t["dir"], ".lock")):
        return None
    logdir = os.path.join(t["dir"], "logs")
    prefix = t["state"] + "-"
    try:
        nums = [int(m.group(1)) for m in
                (re.match(r"%s(\d+)\.log$" % re.escape(prefix), n)
                 for n in os.listdir(logdir))
                if m]
    except OSError:
        return None
    if not nums:
        return None
    path = os.path.join(logdir, "%s%d.log" % (prefix, max(nums)))
    turns = 0
    try:
        st = os.stat(path)
        with open(path, errors="replace") as f:
            for line in f:
                if '"type":"assistant"' in line:
                    turns += 1
    except OSError:
        return None
    start = getattr(st, "st_birthtime", st.st_mtime)
    elapsed = max(0, int(time.time() - start))
    max_turns = int(state_cfg(t["workdir"], t["state"], "max_turns", 0) or 0)
    if max_turns:
        turns = min(turns, max_turns)
        pct = min(100, 100 * turns // max_turns)
    else:
        pct = 0
    return {"turns": turns, "max_turns": max_turns,
            "elapsed": elapsed, "pct": pct}


def progress_html(t):
    p = session_progress(t)
    if p is None:
        return ""
    mins, secs = divmod(p["elapsed"], 60)
    turns = ("turn ~%d/%d" % (p["turns"], p["max_turns"])
             if p["max_turns"] else "turn ~%d" % p["turns"])
    return ("<div class='prog'><div class='prog-bar' style='width:%d%%'></div></div>"
            "<div class='meta prog-meta'>working &middot; %s &middot; %dm%02ds elapsed</div>"
            % (max(p["pct"], 4), turns, mins, secs))


def find_ticket(tid):
    for t in tickets():
        if t["id"] == tid:
            return t
    return None


def run_bin(args):
    p = subprocess.run(args, capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def page(title, body, refresh=False):
    script = ("<script>setTimeout(function r(){"
              "if(document.getElementById('nc-splash')){setTimeout(r,1000);return;}"
              "location.reload()},5000)</script>") if refresh else ""
    return ("<!doctype html><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<title>%s</title>"
            "<style>%s</style><header><a href='/'>Night<b>crew</b></a>"
            "<nav><a href='/new'>New ticket</a><a href='/settings'>Settings</a></nav>"
            "</header><main>%s</main>%s"
            % (html.escape(title), CSS, body, script))


def badge(state):
    cls = BADGE_CLASS.get(state, "b-queue")
    return "<span class='badge %s'>%s</span>" % (cls, html.escape(state))


def card(t):
    h = ["<div class='card'><span class='id'>%s</span>" % html.escape(t["id"])]
    h.append("<div class='t'><a href='/ticket/%s'>%s</a></div>"
             % (t["id"], html.escape(t["title"])))
    if t["state"] == "failed" and t["failed"]:
        label = "failed · " + t["failed"].get("state", "?")
        h.append("<span class='badge b-fail'>%s</span>" % html.escape(label))
        reason = t["failed"].get("reason", "")
        if reason:
            h.append("<div class='meta err'>%s</div>"
                     % html.escape(reason[:120]))
    else:
        h.append(badge(t["state"]))
    h.append(progress_html(t))
    h.append("<div class='meta'>%s · %s</div>"
             % (html.escape(os.path.basename(t["workdir"])), t["age"]))
    if t["state"] == "awaiting-approval":
        h.append("<div class='meta'><a href='/ticket/%s?tab=requirements.md'>"
                 "Review requirements</a></div>" % t["id"])
        h.append("<form class='inline' method='post' action='/approve/%s'>"
                 "<button class='pri'>Approve</button></form>" % t["id"])
    if t["state"] == "failed":
        h.append("<form class='inline' method='post' action='/retry/%s'>"
                 "<button>Retry</button></form>" % t["id"])
    if t["pr"]:
        h.append("<div class='meta'><a href='%s'>PR</a></div>" % html.escape(t["pr"]))
    h.append("</div>")
    return "".join(h)


def board():
    ts = tickets()
    missing = [wd for wd in registry() if not os.path.isdir(wd)]
    h = []
    if missing:
        h.append("<div class='warn'>Registered but missing: %s</div>"
                 % html.escape(", ".join(missing)))
    h.append("<div class='board'>")
    for name, states in COLUMNS:
        col = [t for t in ts if t["state"] in states]
        h.append("<div class='col'><h2>%s <span class='n'>%d</span></h2>%s</div>"
                 % (name, len(col), "".join(card(t) for t in col)))
    h.append("</div>")
    return page("Nightcrew", splash_html() + "".join(h), refresh=True)


def clip(value, limit):
    """The single escape choke point for log-derived data: everything the
    renderer below shows on the page passes through here."""
    s = str(value)
    if len(s) <= limit:
        return html.escape(s)
    return (html.escape(s[:limit])
            + "<span class='ev-cut'>&hellip; +%d chars</span>" % (len(s) - limit))


def tail_lines(path):
    """Read at most the last LOG_TAIL_BYTES of path as text lines.

    A fixed byte-bounded tail off one snapshot is safe to read while the
    file is still being appended to, and keeps huge logs off the page.
    Returns (lines, skipped_bytes, size); ([], 0, 0) on any read error."""
    try:
        with open(path, "rb") as f:
            size = os.fstat(f.fileno()).st_size
            start = max(0, size - LOG_TAIL_BYTES)
            f.seek(start)
            data = f.read()
    except OSError:
        return [], 0, 0
    lines = data.decode("utf-8", "replace").splitlines()
    if start > 0 and lines:
        lines = lines[1:]  # drop the partial line the seek landed inside
    return lines, start, size


def log_events(lines):
    """Parse tail_lines() output into classified event dicts, keeping only
    the last LOG_MAX_EVENTS. Returns (events, dropped_count)."""
    events = []
    for line in lines:
        if not line.strip():
            continue
        try:
            d = json.loads(line)
        except (ValueError, TypeError):
            d = None
        if not isinstance(d, dict):
            events.append({"kind": "raw", "text": line})
            continue
        t = d.get("type")
        if t == "system" and d.get("subtype") == "init":
            d["kind"] = "init"
        elif t == "result":
            d["kind"] = "result"
        elif t in ("assistant", "user"):
            d["kind"] = t
        else:
            d["kind"] = "note"
        events.append(d)
    dropped = max(0, len(events) - LOG_MAX_EVENTS)
    return events[-LOG_MAX_EVENTS:], dropped


def build_tool_results(events):
    """tool_use_id -> tool_result block, scanning every user event's
    message.content up front so tool_use cards (rendered later) can show
    their paired result inline even though it appears after them in time."""
    results = {}
    for e in events:
        if e.get("kind") != "user":
            continue
        content = (e.get("message") or {}).get("content") or []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_result":
                tid = b.get("tool_use_id")
                if tid:
                    results[tid] = b
    return results


def ev_text(b):
    return "<div class='ev ev-text'>%s</div>" % clip(b.get("text", ""), LOG_TEXT_CHARS)


def ev_thinking(b):
    # These blocks carry an empty thinking string plus a signature; the
    # signature is never shown, so this is deliberately just a marker.
    return "<div class='ev ev-think'>thinking</div>"


def ev_tool_result(b):
    content = b.get("content")
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                parts.append(str(item.get("text", "")))
            elif isinstance(item, dict):
                parts.append("[%s]" % item.get("type", "?"))
        text = "\n".join(parts)
    else:
        text = content
    err = bool(b.get("is_error"))
    cls = "ev ev-res ev-err" if err else "ev ev-res"
    badge = "<span class='badge b-fail'>error</span> " if err else ""
    return "<div class='%s'>%s%s</div>" % (cls, badge, clip(text, LOG_RESULT_CHARS))


def ev_tool_use(b, results, used):
    name = b.get("name", "?")
    inp = b.get("input")
    inp = inp if isinstance(inp, dict) else {}
    if name == "Bash":
        cmd = str(inp.get("command", ""))
        desc = inp.get("description")
        preview = desc if desc else (cmd.splitlines()[0] if cmd else "")
        body = ("<div class='ev-tool-desc'>%s</div>" % clip(desc, 200)) if desc else ""
        body += "<pre>%s</pre>" % clip(cmd, LOG_TOOL_INPUT_CHARS)
    else:
        preview = inp.get("file_path", "") if name in ("Read", "Write", "Edit") else ""
        body = "<pre>%s</pre>" % clip(json.dumps(inp, indent=2), LOG_TOOL_INPUT_CHARS)
    tid = b.get("id")
    result_html = ""
    if tid and tid in results:
        result_html = ev_tool_result(results[tid])
        used.add(tid)
    return ("<details class='ev ev-tool'><summary>"
            "<span class='badge b-tool'>%s</span> %s</summary>%s%s</details>"
            % (clip(name, 60), clip(preview, 200), body, result_html))


def ev_init(e):
    tools = e.get("tools")
    fields = [
        ("model", e.get("model")),
        ("cwd", e.get("cwd")),
        ("permissionMode", e.get("permissionMode")),
        ("version", e.get("claude_code_version")),
        ("session", e.get("session_id")),
        ("tools", len(tools) if isinstance(tools, list) else 0),
    ]
    parts = ["%s=%s" % (html.escape(k), clip(v, 200)) for k, v in fields
              if v not in (None, "")]
    return "<div class='ev ev-init'>session start &middot; %s</div>" % " &middot; ".join(parts)


def ev_result(e):
    is_error = bool(e.get("is_error"))
    badge = ("<span class='badge b-fail'>fail</span>" if is_error
              else "<span class='badge b-done'>done</span>")
    dur = e.get("duration_ms")
    if isinstance(dur, (int, float)):
        mins, secs = divmod(int(dur) // 1000, 60)
        dur_s = "%dm%02ds" % (mins, secs)
    else:
        dur_s = "?"
    cost = e.get("total_cost_usd")
    cost_s = "$%.4f" % cost if isinstance(cost, (int, float)) else "?"
    parts = [badge,
             "subtype=%s" % clip(e.get("subtype", "?"), 40),
             "turns=%s" % clip(e.get("num_turns", "?"), 10),
             "duration=%s" % html.escape(dur_s),
             "cost=%s" % html.escape(cost_s)]
    return "<div class='ev ev-result'>%s</div>" % " ".join(parts)


def ev_note_run(name, count, first):
    if count > 1:
        return "<div class='ev ev-note'>%s &times;%d</div>" % (html.escape(name), count)
    fields = SYSTEM_NOTE_FIELDS.get(name, ())
    parts = ["%s=%s" % (html.escape(k), clip(first[k], 200))
              for k in fields if k in first]
    tail = (" " + " ".join(parts)) if parts else ""
    return "<div class='ev ev-note'>%s%s</div>" % (html.escape(name), tail)


def render_events(events):
    results = build_tool_results(events)
    used = set()
    out = []
    run_name, run_count, run_first = None, 0, None

    def flush():
        if run_name is not None:
            out.append(ev_note_run(run_name, run_count, run_first))

    for e in events:
        kind = e.get("kind")
        if kind == "note":
            name = e.get("subtype") or e.get("type") or "note"
            if name == run_name:
                run_count += 1
            else:
                flush()
                run_name, run_count, run_first = name, 1, e
            continue
        flush()
        run_name, run_count, run_first = None, 0, None
        if kind == "raw":
            out.append("<div class='ev ev-text'>%s</div>" % clip(e.get("text", ""), LOG_TEXT_CHARS))
        elif kind == "init":
            out.append(ev_init(e))
        elif kind == "result":
            out.append(ev_result(e))
        elif kind == "assistant":
            for b in (e.get("message") or {}).get("content") or []:
                if not isinstance(b, dict):
                    continue
                bt = b.get("type")
                if bt == "text":
                    out.append(ev_text(b))
                elif bt == "thinking":
                    out.append(ev_thinking(b))
                elif bt == "tool_use":
                    out.append(ev_tool_use(b, results, used))
        elif kind == "user":
            for b in (e.get("message") or {}).get("content") or []:
                if not isinstance(b, dict) or b.get("type") != "tool_result":
                    continue
                tid = b.get("tool_use_id")
                if tid in used:
                    continue
                out.append(ev_tool_result(b))
                if tid:
                    used.add(tid)
    flush()
    return "".join(out)


def log_html(path):
    lines, skipped, size = tail_lines(path)
    h = ["<div class='log-file'><p class='path'>%s</p>" % html.escape(path)]
    if size == 0:
        h.append("<p class='meta'>(empty)</p></div>")
        return "".join(h)
    events, dropped = log_events(lines)
    meta = ["%d bytes" % size]
    if skipped > 0 or dropped > 0:
        meta.append("showing last %d events of this log (earlier output not shown)"
                     % len(events))
    h.append("<p class='meta'>%s</p>" % " &middot; ".join(html.escape(m) for m in meta))
    h.append(render_events(events))
    h.append("</div>")
    return "".join(h)


def detail(tid, tab):
    t = find_ticket(tid)
    if t is None:
        return None
    tabs = [a for a in ARTIFACTS if os.path.isfile(os.path.join(t["dir"], a))]
    logs = sorted(os.listdir(os.path.join(t["dir"], "logs"))) \
        if os.path.isdir(os.path.join(t["dir"], "logs")) else []
    if logs:
        tabs.append("logs")
    tab = tab if tab in tabs else (tabs[0] if tabs else "")
    h = ["<p><span class='id'>%s</span> — <strong>%s</strong> %s "
         "<span class='meta'>%s</span></p>"
         % (html.escape(tid), html.escape(t["title"]), badge(t["state"]),
            html.escape(t["workdir"]))]
    h.append(progress_html(t))
    if t["state"] == "awaiting-approval":
        h.append("<form class='inline' method='post' action='/approve/%s'>"
                 "<button class='pri'>Approve</button></form> " % tid)
    if t["state"] == "failed":
        f = t["failed"] or {}
        h.append("<p class='err'>failed in %s at %s: %s</p>"
                 % (html.escape(f.get("state", "?")),
                    html.escape(f.get("when", "?")),
                    html.escape(f.get("reason", ""))))
        h.append("<form class='inline' method='post' action='/retry/%s'>"
                 "<button>Retry</button></form>" % tid)
    if t["pr"]:
        h.append("<p><a href='%s'>%s</a></p>" % (html.escape(t["pr"]), html.escape(t["pr"])))
    h.append("<p class='tabs'>%s</p>" % " ".join(
        "<a class='%s' href='/ticket/%s?tab=%s'>%s</a>"
        % ("on" if a == tab else "", tid, a, a) for a in tabs))
    if tab == "logs":
        for lg in logs:
            h.append(log_html(os.path.join(t["dir"], "logs", lg)))
    elif tab:
        p = os.path.join(t["dir"], tab)
        with open(p, errors="replace") as f:
            content = f.read()
        if t["state"] == "awaiting-approval" and tab == "requirements.md":
            h.append("<p class='path'>%s &middot; editable while awaiting your "
                     "approval</p>"
                     "<form method='post' action='/edit/%s/requirements.md'>"
                     "<textarea name='content' rows='24'>%s</textarea><br>"
                     "<button>Save changes</button></form>"
                     % (html.escape(p), tid, html.escape(content)))
        else:
            h.append("<p class='path'>%s</p><pre>%s</pre>"
                     % (html.escape(p), html.escape(content)))
    return page(tid, "".join(h), refresh=session_progress(t) is not None)


def browse(path):
    """Directory listing for the workdir picker. Dirs only, dotdirs hidden."""
    path = os.path.abspath(path) if path else os.path.expanduser("~")
    out = {"path": path, "parent": os.path.dirname(path), "dirs": [], "error": ""}
    try:
        names = sorted(os.listdir(path), key=str.lower)
    except OSError as e:
        out["error"] = str(e)
        return out
    for n in names:
        if n.startswith("."):
            continue
        p = os.path.join(path, n)
        try:
            if not os.path.isdir(p):
                continue
            out["dirs"].append({"name": n,
                                "git": os.path.isdir(os.path.join(p, ".git"))})
        except OSError:
            continue
    return out


BROWSER_JS = """
<script>
function nbRender(d){
  var el = document.getElementById('nb');
  var h = "<div class='nb-head'><span class='path'>" + nbEsc(d.path) + "</span>" +
          "<button type='button' onclick='nbPick(" + JSON.stringify(d.path) + ")'>" +
          "Use this directory</button></div>";
  if (d.error) h += "<p class='err'>" + nbEsc(d.error) + "</p>";
  if (d.parent && d.parent !== d.path)
    h += "<a class='nb-dir' href='#' onclick='return nbGo(" +
         JSON.stringify(d.parent) + ")'>&#8593; ..</a>";
  d.dirs.forEach(function(x){
    var full = d.path.replace(/\\/$/, '') + '/' + x.name;
    h += "<a class='nb-dir' href='#' onclick='return nbGo(" +
         JSON.stringify(full) + ")'>" + nbEsc(x.name) +
         (x.git ? " <span class='nb-git'>git</span>" : "") + "</a>";
  });
  el.innerHTML = h;
  el.style.display = 'block';
}
function nbEsc(s){var d=document.createElement('i');d.textContent=s;return d.innerHTML}
function nbGo(p){
  fetch('/browse?path=' + encodeURIComponent(p))
    .then(function(r){return r.json()}).then(nbRender);
  return false;
}
function nbPick(p){
  document.querySelector("input[name=workdir]").value = p;
  document.getElementById('nb').style.display = 'none';
}
function nbToggle(){
  var el = document.getElementById('nb');
  if (el.style.display === 'block') { el.style.display = 'none'; return; }
  nbGo(document.querySelector("input[name=workdir]").value || '');
}
</script>
"""


def new_form(error=""):
    recent = sorted({t["workdir"] for t in tickets()})
    opts = "".join("<option value='%s'>" % html.escape(w) for w in recent)
    err = "<p class='err'>%s</p>" % html.escape(error) if error else ""
    body = (err +
            "<form method='post' action='/submit' class='panel'>"
            "<label>Title</label><input type='text' name='title'>"
            "<label>Working directory (absolute path to a git repo)</label>"
            "<div class='row'>"
            "<input type='text' name='workdir' list='wds'>"
            "<button type='button' onclick='nbToggle()'>Browse&hellip;</button>"
            "</div><datalist id='wds'>%s</datalist>"
            "<div id='nb' class='nb'></div>"
            "<label>Description</label><textarea name='description' rows='8'></textarea>"
            "<br><button class='pri'>Create ticket</button></form>" % opts) + BROWSER_JS
    return page("New ticket", body)


def splash_html():
    """Embeddable splash fragment, or '' when the asset is absent."""
    p = os.path.join(ROOT, "dashboard", "splash.html")
    try:
        with open(p) as f:
            content = f.read()
    except OSError:
        return ""
    marker = "<!-- NC-SPLASH-START -->"
    if marker not in content:
        return ""
    return "<script>window.NC_EMBED=1</script>" + content.split(marker, 1)[1]


def prompt_path(state, cfg):
    rel = cfg["states"].get(state, {}).get("prompt", "prompts/%s.md" % state)
    return rel if os.path.isabs(rel) else os.path.join(ROOT, rel)


def model_select(current):
    opts = MODELS if current in MODELS else [current] + MODELS
    return "<select name='model'>%s</select>" % "".join(
        "<option value='%s'%s>%s</option>"
        % (html.escape(m), " selected" if m == current else "", html.escape(m))
        for m in opts)


def settings_page(error=""):
    cfg = load_config()
    err = "<p class='err'>%s</p>" % html.escape(error) if error else ""
    h = [err, "<p class='meta'>Changes apply on the next state run; no restart needed. "
              "Per-repo .nightcrew/ overrides are file-only and win over these defaults.</p>"]
    for st in LLM_STATES:
        s = cfg["states"].get(st, {})
        try:
            with open(prompt_path(st, cfg), errors="replace") as f:
                ptext = f.read()
        except OSError:
            ptext = ""
        h.append(
            "<form method='post' action='/settings/%s' class='panel'>"
            "<h2>%s</h2>"
            "<label>Model</label>%s"
            "<label>Max turns</label><input type='text' name='max_turns' value='%s'>"
            "<label>Timeout (minutes)</label><input type='text' name='timeout_minutes' value='%s'>"
            "<label>Allowed tools <span class='hint'>comma-separated; "
            "<code>*</code> grants all tools; claude patterns like "
            "<code>Bash(git:*)</code> pass through</span></label>"
            "<input type='text' name='allowed_tools' value='%s'>"
            "<label>Prompt — %s</label>"
            "<textarea name='prompt_text' rows='14'>%s</textarea>"
            "<br><button class='pri'>Save %s</button></form>"
            % (st, st,
               model_select(str(s.get("model", ""))),
               html.escape(str(s.get("max_turns", ""))),
               html.escape(str(s.get("timeout_minutes", ""))),
               html.escape(str(s.get("allowed_tools", ""))),
               html.escape(prompt_path(st, cfg)),
               html.escape(ptext), st))
    return page("Settings", "".join(h))


def unix_text(s):
    """Browsers submit textarea content with CRLF line endings; the engine's
    line-oriented greps (OUTPUT FILE:, VERDICT:) need clean LF."""
    return s.replace("\r\n", "\n").replace("\r", "\n")


def save_settings(state, form):
    """Returns an error string, or '' on success. Atomic writes only."""
    model = form.get("model", "").strip()
    tools = form.get("allowed_tools", "").strip()
    ptext = unix_text(form.get("prompt_text", ""))
    if not model:
        return "model must not be empty"
    if not ptext.strip():
        return "prompt must not be empty"
    try:
        turns = int(form.get("max_turns", ""))
        mins = float(form.get("timeout_minutes", ""))
        if turns <= 0 or mins <= 0 or not math.isfinite(mins):
            raise ValueError
    except ValueError:
        return "max_turns and timeout_minutes must be positive numbers"
    cfg = load_config()
    s = cfg["states"].setdefault(state, {})
    s["model"] = model
    s["max_turns"] = turns
    s["timeout_minutes"] = int(mins) if mins == int(mins) else mins
    s["allowed_tools"] = tools
    cfgpath = os.path.join(ROOT, "config.json")
    with open(cfgpath + ".tmp", "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(cfgpath + ".tmp", cfgpath)
    pp = prompt_path(state, cfg)
    with open(pp + ".tmp", "w") as f:
        f.write(ptext)
    os.replace(pp + ".tmp", pp)
    return ""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, to="/"):
        self.send_response(303)
        self.send_header("Location", to)
        self.end_headers()

    def _form(self):
        n = int(self.headers.get("Content-Length", 0))
        q = parse_qs(self.rfile.read(n).decode())
        return {k: v[0] for k, v in q.items()}

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/":
            return self._send(200, board())
        m = re.match(r"^/ticket/(T-\d+)$", path)
        if m:
            tab = parse_qs(query).get("tab", [""])[0]
            body = detail(m.group(1), tab)
            if body is None:
                return self._send(404, page("Not found", "<p>Unknown ticket.</p>"))
            return self._send(200, body)
        if path == "/new":
            return self._send(200, new_form())
        if path == "/browse":
            p = parse_qs(query).get("path", [""])[0]
            return self._send(200, json.dumps(browse(p)),
                              "application/json; charset=utf-8")
        if path == "/settings":
            return self._send(200, settings_page())
        return self._send(404, page("Not found", "<p>No such page.</p>"))

    def do_POST(self):
        path = self.path.partition("?")[0]
        if path == "/submit":
            f = self._form()
            with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as tf:
                tf.write(f.get("description", ""))
                descpath = tf.name
            rc, out = run_bin([os.path.join(BIN, "submit.sh"),
                               f.get("workdir", ""), f.get("title", ""), descpath])
            os.unlink(descpath)
            if rc != 0:
                return self._send(400, new_form(error=out))
            return self._redirect("/")
        m = re.match(r"^/settings/(%s)$" % "|".join(LLM_STATES), path)
        if m:
            err = save_settings(m.group(1), self._form())
            if err:
                return self._send(400, settings_page(error=err))
            return self._redirect("/settings")
        m = re.match(r"^/edit/(T-\d+)/requirements\.md$", path)
        if m:
            t = find_ticket(m.group(1))
            if t is None:
                return self._send(404, page("Not found", "<p>Unknown ticket.</p>"))
            if t["state"] != "awaiting-approval":
                return self._send(409, page("Rejected",
                                            "<p class='err'>Requirements are only "
                                            "editable while awaiting approval.</p>"))
            dest = os.path.join(t["dir"], "requirements.md")
            with open(dest + ".tmp", "w") as f:
                f.write(unix_text(self._form().get("content", "")))
            os.replace(dest + ".tmp", dest)
            return self._redirect("/ticket/%s?tab=requirements.md" % t["id"])
        m = re.match(r"^/(approve|retry)/(T-\d+)$", path)
        if m:
            rc, out = run_bin([os.path.join(BIN, "transition.sh"),
                               m.group(2), m.group(1)])
            if rc != 0:
                return self._send(409, page("Rejected", "<pre>%s</pre>" % html.escape(out)))
            return self._redirect("/")
        return self._send(404, page("Not found", "<p>No such action.</p>"))

    def log_message(self, fmt, *args):
        pass


def main():
    port = int(load_config().get("port", 8377))
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
