#!/bin/bash
source "$(dirname "$0")/helpers.sh"
make_sandbox
R="$REPO_ROOT/bin/run-state.sh"
S="$REPO_ROOT/bin/submit.sh"
T="$REPO_ROOT/bin/transition.sh"

repo=$(make_repo runstate)
id=$("$S" "$repo" "Test ticket")
tdir="$repo/.nightcrew/tickets/$id"

# new: pure advance, no session, no log
assert_ok "$R" "$id"
assert_eq "$(cat "$tdir/state")" "requirements"
assert_eq "$(ls "$tdir/logs" | wc -l | tr -d ' ')" "0"

# requirements happy path: artifact + advance + log
assert_ok "$R" "$id"
assert_eq "$(cat "$tdir/state")" "awaiting-approval"
assert_ok test -s "$tdir/requirements.md"
assert_ok test -e "$tdir/logs/requirements-1.log"

# awaiting-approval is human-owned: run-state must refuse
assert_fail "$R" "$id"
assert_eq "$(cat "$tdir/state")" "awaiting-approval"

# planning happy path
assert_ok "$T" "$id" approve
assert_ok "$R" "$id"
assert_eq "$(cat "$tdir/state")" "executing"
assert_ok test -s "$tdir/plan.md"

# Failure: garbage artifact -> failed with reason, retry re-runs the state
id2=$("$S" "$repo" "Garbage ticket")
t2="$repo/.nightcrew/tickets/$id2"
"$R" "$id2"   # new -> requirements
STUB_MODE=garbage "$R" "$id2"
assert_eq "$(cat "$t2/state")" "failed"
assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$t2/failed.json")" "requirements"
assert_ok "$T" "$id2" retry
assert_ok "$R" "$id2"
assert_eq "$(cat "$t2/state")" "awaiting-approval"
assert_ok test -e "$t2/logs/requirements-2.log"

# Failure: non-zero exit
id3=$("$S" "$repo" "Exit1 ticket")
t3="$repo/.nightcrew/tickets/$id3"
"$R" "$id3"
STUB_MODE=exit1 "$R" "$id3"
assert_eq "$(cat "$t3/state")" "failed"

# Failure: timeout (0.03 min = ~2s; stub sleeps 300)
id4=$("$S" "$repo" "Timeout ticket")
t4="$repo/.nightcrew/tickets/$id4"
"$R" "$id4"
set_state_cfg requirements timeout_minutes 0.03
STUB_MODE=timeout "$R" "$id4"
assert_eq "$(cat "$t4/state")" "failed"
assert_ok grep -q 'timed out' "$t4/failed.json"

# allowed_tools passes through as a flag by default...
id5=$("$S" "$repo" "Tools flag ticket")
t5="$repo/.nightcrew/tickets/$id5"
"$R" "$id5"
STUB_ARGS_FILE="$SANDBOX/args-default" "$R" "$id5"
assert_ok grep -q -- '--allowedTools' "$SANDBOX/args-default"
assert_eq "$(cat "$t5/state")" "awaiting-approval"

# ...and "*" grants all tools: --allowedTools omitted entirely
id6=$("$S" "$repo" "Wildcard tools ticket")
t6="$repo/.nightcrew/tickets/$id6"
"$R" "$id6"
set_state_cfg requirements allowed_tools '"*"'
STUB_ARGS_FILE="$SANDBOX/args-wild" "$R" "$id6"
assert_fail grep -q -- '--allowedTools' "$SANDBOX/args-wild"
assert_eq "$(cat "$t6/state")" "awaiting-approval"

finish
