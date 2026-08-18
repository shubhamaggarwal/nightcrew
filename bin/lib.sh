#!/bin/bash
# Shared helpers. Every bin script sources this. Bash 3.2 compatible.
# NC_ROOT is env-overridable so tests can sandbox config/state/prompts.

NC_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NC_ROOT="${NC_ROOT:-$(cd "$NC_BIN/.." && pwd)}"
NC_STATE="$NC_ROOT/state"
NC_CONFIG="$NC_ROOT/config.json"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

write_atomic() {
  local path="$1" content="$2"
  printf '%s\n' "$content" > "$path.tmp" && mv "$path.tmp" "$path"
}

state_config() {
  python3 - "$NC_CONFIG" "$1/.nightcrew/config.json" "$2" "$3" <<'PY'
import json, sys
g, o, state, key = sys.argv[1:5]
val = None
for path in (g, o):
    try:
        with open(path) as f:
            v = json.load(f).get("states", {}).get(state, {}).get(key)
        if v is not None:
            val = v
    except (OSError, ValueError):
        pass
if val is None:
    sys.exit(1)
print(val)
PY
}

global_config() {
  local val
  val=$(python3 -c 'import json,sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
sys.exit(1) if v is None else print(v)' "$NC_CONFIG" "$1" 2>/dev/null) || val="${2:-}"
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
}

alloc_id() {
  local lock="$NC_STATE/next-id.lock" n
  mkdir -p "$NC_STATE"
  until mkdir "$lock" 2>/dev/null; do sleep 0.1; done
  n=$(cat "$NC_STATE/next-id" 2>/dev/null || echo 1)
  write_atomic "$NC_STATE/next-id" "$((n + 1))"
  rmdir "$lock"
  printf 'T-%04d\n' "$n"
}

registry_add() {
  mkdir -p "$NC_STATE"
  touch "$NC_STATE/registry"
  grep -qxF "$1" "$NC_STATE/registry" || printf '%s\n' "$1" >> "$NC_STATE/registry"
}

resolve_ticket() {
  local wd
  [ -f "$NC_STATE/registry" ] || return 1
  while IFS= read -r wd; do
    [ -d "$wd/.nightcrew/tickets/$1" ] && { printf '%s\n' "$wd/.nightcrew/tickets/$1"; return 0; }
  done < "$NC_STATE/registry"
  return 1
}

ticket_workdir() { (cd "$1/../../.." && pwd); }

run_with_timeout() {
  local secs="$1" pid watcher rc=0
  shift
  "$@" &
  pid=$!
  ( sleep "$secs" && kill -TERM "$pid" 2>/dev/null ) &
  watcher=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return "$rc"
}
