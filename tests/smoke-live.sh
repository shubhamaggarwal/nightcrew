#!/bin/bash
# LIVE smoke test: real claude, real gh, real tokens. Run occasionally.
# Usage: tests/smoke-live.sh <path-to-github-backed-scratch-repo>
set -euo pipefail
cd "$(dirname "$0")/.."
repo="${1:?usage: smoke-live.sh <github-backed-scratch-repo>}"

id=$(bin/submit.sh "$repo" "Add SMOKE.md" <(echo \
  "Create a file SMOKE.md at the repo root containing exactly the word: smoke"))
echo "filed $id against $repo"

tdir="$repo/.nightcrew/tickets/$id"
deadline=$(( $(date +%s) + 3600 ))
while :; do
  state=$(cat "$tdir/state")
  echo "$(date +%H:%M:%S) $id: $state"
  case "$state" in
    awaiting-approval) bin/transition.sh "$id" approve ;;
    closed)  echo "PR: $(cat "$tdir/pr-url")"; exit 0 ;;
    failed)  echo "FAILED:"; cat "$tdir/failed.json"; exit 1 ;;
    new|requirements|planning|executing|verifying|closing) bin/run-state.sh "$id" || true ;;
  esac
  [ "$(date +%s)" -lt "$deadline" ] || { echo "smoke test timed out"; exit 1; }
  sleep 2
done
