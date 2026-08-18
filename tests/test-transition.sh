#!/bin/bash
source "$(dirname "$0")/helpers.sh"
make_sandbox
T="$REPO_ROOT/bin/transition.sh"

repo=$(make_repo trans)
tdir="$repo/.nightcrew/tickets/T-0001"
mkdir -p "$tdir"
source "$REPO_ROOT/bin/lib.sh"
registry_add "$repo"

set_state() { write_atomic "$tdir/state" "$1"; }
get_state() { cat "$tdir/state"; }

# Full happy path
set_state new
assert_ok "$T" T-0001 advance;  assert_eq "$(get_state)" "requirements"
assert_ok "$T" T-0001 advance;  assert_eq "$(get_state)" "awaiting-approval"
assert_fail "$T" T-0001 advance                 # gate: only approve moves it
assert_eq "$(get_state)" "awaiting-approval"    # illegal move wrote nothing
assert_ok "$T" T-0001 approve;  assert_eq "$(get_state)" "planning"
assert_ok "$T" T-0001 advance;  assert_eq "$(get_state)" "executing"
assert_ok "$T" T-0001 advance;  assert_eq "$(get_state)" "verifying"
assert_ok "$T" T-0001 fix;      assert_eq "$(get_state)" "executing"
assert_ok "$T" T-0001 advance;  assert_eq "$(get_state)" "verifying"
assert_ok "$T" T-0001 advance;  assert_eq "$(get_state)" "closing"
assert_ok "$T" T-0001 advance;  assert_eq "$(get_state)" "closed"
assert_fail "$T" T-0001 advance                 # closed is terminal

# fail + retry round-trip
set_state executing
echo '{"state": "executing", "when": "x", "reason": "boom"}' > "$tdir/failed.json"
write_atomic "$tdir/attempts" "3"
assert_ok "$T" T-0001 fail;   assert_eq "$(get_state)" "failed"
assert_ok "$T" T-0001 retry;  assert_eq "$(get_state)" "executing"
assert_fail test -e "$tdir/failed.json"
assert_fail test -e "$tdir/attempts"   # retry grants a fresh fix budget

# retry rejects an unrecognized recorded state and preserves the record
set_state failed
echo '{"state": "bogus-state", "when": "x", "reason": "boom"}' > "$tdir/failed.json"
assert_fail "$T" T-0001 retry
assert_eq "$(get_state)" "failed"
assert_ok test -e "$tdir/failed.json"

# Illegal events
set_state planning
assert_fail "$T" T-0001 approve
assert_fail "$T" T-0001 fix
assert_fail "$T" T-0001 bogus
assert_fail "$T" T-9999 advance   # unknown ticket

finish
