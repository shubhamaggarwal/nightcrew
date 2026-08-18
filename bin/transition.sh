#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"

id="${1:-}"
event="${2:-}"
[ -n "$id" ] && [ -n "$event" ] || die "usage: transition.sh <ticket-id> <event>"
tdir=$(resolve_ticket "$id") || die "unknown ticket: $id"
cur=$(cat "$tdir/state")

to=""
case "$event:$cur" in
  advance:new)                to=requirements ;;
  advance:requirements)       to=awaiting-approval ;;
  advance:planning)           to=executing ;;
  advance:executing)          to=verifying ;;
  advance:verifying)          to=closing ;;
  advance:closing)            to=closed ;;
  approve:awaiting-approval)  to=planning ;;
  fix:verifying)              to=executing ;;
  fail:new|fail:requirements|fail:planning|fail:executing|fail:verifying|fail:closing)
                              to=failed ;;
  retry:failed)
    to=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' \
      "$tdir/failed.json" 2>/dev/null) || die "$id: failed.json missing or unreadable"
    case "$to" in
      new|requirements|planning|executing|verifying|closing) ;;
      *) die "$id: failed.json names unknown state: $to" ;;
    esac ;;
esac
[ -n "$to" ] || die "$id: illegal transition: $cur --$event-->"
write_atomic "$tdir/state" "$to" || die "$id: state write failed"
[ "$event" = retry ] && rm -f "$tdir/failed.json" "$tdir/attempts"
log "$id: $cur --$event--> $to"
