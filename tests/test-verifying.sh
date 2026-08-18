#!/bin/bash
source "$(dirname "$0")/helpers.sh"
make_sandbox
R="$REPO_ROOT/bin/run-state.sh"
S="$REPO_ROOT/bin/submit.sh"

to_verifying() {  # <repo> -> id
  local id
  id=$("$S" "$1" "Verify ticket $RANDOM")
  "$R" "$id" >/dev/null 2>&1
  "$R" "$id" >/dev/null 2>&1
  "$REPO_ROOT/bin/transition.sh" "$id" approve >/dev/null 2>&1
  "$R" "$id" >/dev/null 2>&1
  "$R" "$id" >/dev/null 2>&1   # executing
  printf '%s\n' "$id"
}

repo=$(make_repo verify)

# PASS -> closing
id=$(to_verifying "$repo")
tdir="$repo/.nightcrew/tickets/$id"
assert_ok "$R" "$id"
assert_eq "$(cat "$tdir/state")" "closing"
assert_eq "$(tail -1 "$tdir/verification.md")" "VERDICT: PASS"

# FAIL -> fix bounce with attempts counter, then exhaust to failed
id2=$(to_verifying "$repo")
t2="$repo/.nightcrew/tickets/$id2"
STUB_VERDICT=FAIL "$R" "$id2"
assert_eq "$(cat "$t2/state")" "executing"
assert_eq "$(cat "$t2/attempts")" "1"
"$R" "$id2" >/dev/null 2>&1                    # fix cycle 1 executes
STUB_VERDICT=FAIL "$R" "$id2"
assert_eq "$(cat "$t2/state")" "executing"
assert_eq "$(cat "$t2/attempts")" "2"
"$R" "$id2" >/dev/null 2>&1                    # fix cycle 2 executes
STUB_VERDICT=FAIL "$R" "$id2"
assert_eq "$(cat "$t2/state")" "failed"
assert_ok grep -q 'fix cycles' "$t2/failed.json"

# Garbage artifact (fails the size gate) -> failed
id3=$(to_verifying "$repo")
t3="$repo/.nightcrew/tickets/$id3"
STUB_MODE=garbage "$R" "$id3"
assert_eq "$(cat "$t3/state")" "failed"

# Well-sized artifact with no legal VERDICT line -> failed at the parser
id4=$(to_verifying "$repo")
t4="$repo/.nightcrew/tickets/$id4"
STUB_VERDICT=MAYBE "$R" "$id4"
assert_eq "$(cat "$t4/state")" "failed"
assert_ok grep -q 'no parseable VERDICT' "$t4/failed.json"

finish
