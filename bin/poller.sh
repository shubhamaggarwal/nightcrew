#!/bin/bash
# The engine loop. Runs forever under launchd; POLLER_ONCE=1 does a
# single scan pass (tests). All correctness lives in the scan: state
# files + locks on disk are the entire truth, so restarts are free.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

AUTO=' new requirements planning executing verifying closing '

active_count() {
  local n=0 wd t
  while IFS= read -r wd; do
    for t in "$wd"/.nightcrew/tickets/*/; do
      [ -d "$t/.lock" ] && n=$((n + 1))
    done
  done < "$NC_STATE/registry"
  echo "$n"
}

reclaim_stale() {  # <ticket-dir>; rc 0 = reclaimed, 1 = still live
  local pid
  pid=$(cat "$1/.lock/pid" 2>/dev/null || echo "")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  log "reclaiming stale lock: $1"
  rm -rf "$1/.lock"
}

acquire_poller_lock() {
  local lock="$NC_STATE/poller.lock" pid
  if ! mkdir "$lock" 2>/dev/null; then
    pid=$(cat "$lock/pid" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      die "another poller is already running (pid $pid)"
    fi
    log "reclaiming stale poller lock"
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || die "cannot acquire poller lock"
  fi
  echo $$ > "$lock/pid"
  trap 'rm -rf "$NC_STATE/poller.lock"' EXIT
}

mkdir -p "$NC_STATE"
touch "$NC_STATE/registry"
acquire_poller_lock
max=$(global_config max_concurrent 3)
interval=$(global_config poll_interval_seconds 5)

while :; do
  while IFS= read -r wd; do
    [ -n "$wd" ] || continue
    if [ ! -d "$wd" ]; then
      log "WARN: registered workdir missing: $wd"
      continue
    fi
    for tdir in "$wd"/.nightcrew/tickets/*/; do
      [ -d "$tdir" ] || continue
      id=$(basename "$tdir")
      state=$(cat "$tdir/state" 2>/dev/null) || continue
      case "$AUTO" in *" $state "*) ;; *) continue ;; esac
      if [ -d "$tdir/.lock" ]; then
        reclaim_stale "$tdir" || continue
      fi
      [ "$(active_count)" -lt "$max" ] || continue 2
      mkdir "$tdir/.lock" 2>/dev/null || continue
      "$NC_BIN/run-state.sh" "$id" &
      echo $! > "$tdir/.lock/pid" 2>/dev/null || true
    done
  done < "$NC_STATE/registry"
  if [ "${POLLER_ONCE:-0}" = 1 ]; then
    wait
    exit 0
  fi
  sleep "$interval"
done
