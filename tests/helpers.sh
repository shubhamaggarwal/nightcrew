#!/bin/bash
# Sourced by every test file. Plain-bash assertions; no framework.

FAILS=0
CHECKS=0
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_eq() {
  CHECKS=$((CHECKS + 1))
  [ "$1" = "$2" ] || { echo "FAIL(line ${BASH_LINENO[0]}): expected [$2], got [$1]"; FAILS=$((FAILS + 1)); }
}

assert_ok() {
  CHECKS=$((CHECKS + 1))
  "$@" || { echo "FAIL(line ${BASH_LINENO[0]}): command failed: $*"; FAILS=$((FAILS + 1)); }
}

assert_fail() {
  CHECKS=$((CHECKS + 1))
  if "$@" >/dev/null 2>&1; then
    echo "FAIL(line ${BASH_LINENO[0]}): expected failure: $*"; FAILS=$((FAILS + 1))
  fi
}

finish() {
  echo "$CHECKS checks, $FAILS failures"
  [ "$FAILS" -eq 0 ]
}

# make_sandbox — isolated NC_ROOT so tests never touch real state/.
make_sandbox() {
  SANDBOX=$(mktemp -d)
  trap 'rm -rf "$SANDBOX"' EXIT
  mkdir -p "$SANDBOX/state" "$SANDBOX/repos"
  cp "$REPO_ROOT/config.json" "$SANDBOX/config.json"
  [ -d "$REPO_ROOT/prompts" ] && cp -R "$REPO_ROOT/prompts" "$SANDBOX/prompts"
  export NC_ROOT="$SANDBOX"
  export CLAUDE_BIN="$REPO_ROOT/tests/claude-stub.sh"
}

# make_repo <name> — git repo + local bare origin, main pushed, origin/HEAD set.
make_repo() {
  local repo="$SANDBOX/repos/$1" bare="$SANDBOX/repos/$1-origin.git"
  git init -q --bare "$bare"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@nightcrew.local
  git -C "$repo" config user.name "Nightcrew tests"
  echo hello > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "Initial commit" --no-verify
  git -C "$repo" remote add origin "$bare"
  git -C "$repo" push -qu origin main
  git -C "$repo" remote set-head origin main
  printf '%s\n' "$repo"
}

set_global() {
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d[sys.argv[2]]=json.loads(sys.argv[3]); json.dump(d, open(p,"w"))' \
    "$NC_ROOT/config.json" "$1" "$2"
}

set_state_cfg() {
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["states"][sys.argv[2]][sys.argv[3]]=json.loads(sys.argv[4]); json.dump(d, open(p,"w"))' \
    "$NC_ROOT/config.json" "$1" "$2" "$3"
}
