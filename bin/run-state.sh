#!/bin/bash
# Run exactly one state transition for one ticket. No -e: failures are
# handled explicitly so every path ends in transition.sh, not a crash.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

id="${1:-}"
[ -n "$id" ] || die "usage: run-state.sh <ticket-id>"
tdir=$(resolve_ticket "$id") || die "unknown ticket: $id"
workdir=$(ticket_workdir "$tdir")
state=$(cat "$tdir/state")

# If the poller locked us, own the lock: record our PID, release on exit.
[ -d "$tdir/.lock" ] && echo $$ > "$tdir/.lock/pid"
trap 'rm -rf "$tdir/.lock"' EXIT

fail_ticket() {
  local fj
  fj=$(python3 -c 'import json,sys; print(json.dumps({"state": sys.argv[1], "when": sys.argv[2], "reason": sys.argv[3]}))' \
    "$state" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1")
  write_atomic "$tdir/failed.json" "$fj"
  "$NC_BIN/transition.sh" "$id" fail
  exit 1
}

artifact_for() {
  case "$1" in
    requirements) echo requirements.md ;;
    planning)     echo plan.md ;;
    executing)    echo execution-notes.md ;;
    verifying)    echo verification.md ;;
  esac
}

artifact_ok() { [ -f "$1" ] && [ "$(wc -c < "$1")" -ge 100 ]; }

render_prompt() {
  sed -e "s|{{TICKET_ID}}|$id|g" \
      -e "s|{{TICKET_DIR}}|$tdir|g" \
      -e "s|{{WORKDIR}}|$workdir|g" "$1"
}

next_log() {
  local n=1
  while [ -e "$tdir/logs/$state-$n.log" ]; do n=$((n + 1)); done
  printf '%s\n' "$tdir/logs/$state-$n.log"
}

run_session() {
  local cwd="$1" model turns mins tools tmpl prompt logf secs
  model=$(state_config "$workdir" "$state" model)          || fail_ticket "no model configured for $state"
  turns=$(state_config "$workdir" "$state" max_turns)      || fail_ticket "no max_turns configured for $state"
  mins=$(state_config "$workdir" "$state" timeout_minutes) || fail_ticket "no timeout_minutes configured for $state"
  tools=$(state_config "$workdir" "$state" allowed_tools)  || fail_ticket "no allowed_tools configured for $state"
  tmpl=$(state_config "$workdir" "$state" prompt)          || fail_ticket "no prompt configured for $state"
  if [ -f "$workdir/.nightcrew/prompts/$state.md" ]; then
    tmpl="$workdir/.nightcrew/prompts/$state.md"
  elif [ "${tmpl#/}" = "$tmpl" ]; then
    tmpl="$NC_ROOT/$tmpl"
  fi
  [ -f "$tmpl" ] || fail_ticket "prompt template missing: $tmpl"
  prompt=$(render_prompt "$tmpl")
  logf=$(next_log)
  secs=$(awk "BEGIN{print int($mins * 60)}")
  # stream-json (one JSON event per line) lets the dashboard read live
  # progress out of the log while the session runs; --verbose is required
  # by claude -p for this format.
  if [ "$tools" = "*" ]; then
    # "*" grants every tool: omit --allowedTools entirely.
    ( cd "$cwd" && run_with_timeout "$secs" \
        "$CLAUDE_BIN" -p "$prompt" --model "$model" --max-turns "$turns" \
        --output-format stream-json --verbose ) >> "$logf" 2>&1
  else
    ( cd "$cwd" && run_with_timeout "$secs" \
        "$CLAUDE_BIN" -p "$prompt" --model "$model" --max-turns "$turns" \
        --allowedTools "$tools" --output-format stream-json --verbose ) >> "$logf" 2>&1
  fi
}

require_clean_session() {  # <rc> — shared post-session checks
  local rc="$1"
  [ "$rc" -eq 143 ] && fail_ticket "session timed out"
  [ "$rc" -eq 0 ] || fail_ticket "session exited with rc=$rc"
}

default_base() {
  local b
  b=$(git -C "$workdir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||') || true
  if [ -n "$b" ]; then
    git -C "$workdir" fetch --quiet origin "$b" 2>/dev/null \
      || log "$id: fetch failed, using cached origin/$b"
    printf 'origin/%s\n' "$b"
  else
    git -C "$workdir" symbolic-ref --short HEAD
  fi
}

case "$state" in
  new)
    "$NC_BIN/transition.sh" "$id" advance
    ;;
  requirements|planning)
    art="$tdir/$(artifact_for "$state")"
    run_session "$workdir"; rc=$?
    require_clean_session "$rc"
    artifact_ok "$art" || fail_ticket "session produced no usable $(artifact_for "$state")"
    "$NC_BIN/transition.sh" "$id" advance
    ;;
  executing)
    wt="$workdir/.nightcrew/worktrees/$id"
    branch="ticket/$id"
    baseref=$(default_base)
    if [ -d "$wt" ]; then
      [ -z "$(git -C "$wt" status --porcelain)" ] \
        || fail_ticket "pre-existing worktree at $wt is dirty; resolve by hand"
    elif git -C "$workdir" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$workdir" worktree add "$wt" "$branch" >/dev/null 2>&1 \
        || fail_ticket "cannot attach worktree for existing branch $branch"
    else
      git -C "$workdir" worktree add -b "$branch" "$wt" "$baseref" >/dev/null 2>&1 \
        || fail_ticket "git worktree add failed"
    fi
    pre_head=$(git -C "$wt" rev-parse HEAD)
    run_session "$wt"; rc=$?
    require_clean_session "$rc"
    [ -z "$(git -C "$wt" status --porcelain)" ] \
      || fail_ticket "session left uncommitted changes in the worktree"
    [ "$(git -C "$wt" rev-parse HEAD)" != "$pre_head" ] \
      || fail_ticket "session produced no new commits this round"
    artifact_ok "$tdir/execution-notes.md" \
      || fail_ticket "session produced no usable execution-notes.md"
    "$NC_BIN/transition.sh" "$id" advance
    ;;
  verifying)
    wt="$workdir/.nightcrew/worktrees/$id"
    [ -d "$wt" ] || fail_ticket "worktree missing at $wt"
    run_session "$wt"; rc=$?
    require_clean_session "$rc"
    artifact_ok "$tdir/verification.md" \
      || fail_ticket "session produced no usable verification.md"
    verdict=$(grep -E '^VERDICT: (PASS|FAIL)$' "$tdir/verification.md" | tail -1)
    case "$verdict" in
      "VERDICT: PASS")
        "$NC_BIN/transition.sh" "$id" advance
        ;;
      "VERDICT: FAIL")
        n=$(cat "$tdir/attempts" 2>/dev/null || echo 0)
        n=$((n + 1))
        write_atomic "$tdir/attempts" "$n"
        max=$(global_config max_fix_cycles 2)
        if [ "$n" -gt "$max" ]; then
          fail_ticket "verification still failing after $max fix cycles"
        else
          "$NC_BIN/transition.sh" "$id" fix
        fi
        ;;
      *)
        fail_ticket "verification.md has no parseable VERDICT line"
        ;;
    esac
    ;;
  closing)
    wt="$workdir/.nightcrew/worktrees/$id"
    branch="ticket/$id"
    [ -d "$wt" ] || fail_ticket "worktree missing at $wt"
    git -C "$workdir" remote get-url origin >/dev/null 2>&1 \
      || fail_ticket "workdir has no origin remote to push to"
    title=$(sed -n 's/^title: //p' "$tdir/ticket.md" | head -1)
    baseref=$(default_base)
    base_branch=${baseref#origin/}
    git -C "$wt" push -qu origin "$branch" || fail_ticket "git push failed"
    body=$(mktemp)
    {
      for a in requirements plan execution-notes verification; do
        f="$tdir/$a.md"
        [ -f "$f" ] || continue
        printf '<details>\n<summary>%s</summary>\n\n' "$a"
        cat "$f"
        printf '\n</details>\n\n'
      done
      printf 'Ticket %s via nightcrew.\n' "$id"
    } > "$body"
    mkdir -p "$tdir/logs"
    clog=$(next_log)
    url=$(cd "$wt" && gh pr create --title "$title" --body-file "$body" \
            --base "$base_branch" --head "$branch" 2>>"$clog") \
      || url=$(cd "$wt" && gh pr view "$branch" --json url -q .url 2>>"$clog") \
      || { rm -f "$body"; fail_ticket "gh pr create failed"; }
    rm -f "$body"
    write_atomic "$tdir/pr-url" "$url" \
      || fail_ticket "could not record pr-url"
    git -C "$workdir" worktree remove "$wt" 2>/dev/null \
      || git -C "$workdir" worktree remove --force "$wt" 2>/dev/null \
      || log "$id: could not remove worktree $wt; remove by hand"
    "$NC_BIN/transition.sh" "$id" advance
    ;;
  *)
    die "$id: state '$state' is not runnable"
    ;;
esac
