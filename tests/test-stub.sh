#!/bin/bash
source "$(dirname "$0")/helpers.sh"
make_sandbox
STUB="$REPO_ROOT/tests/claude-stub.sh"

out="$SANDBOX/art/requirements.md"
mkdir -p "$SANDBOX/art"

# ok mode: writes >=100 bytes to the OUTPUT FILE path
assert_ok "$STUB" -p "blah
OUTPUT FILE: $out
more" --model m --max-turns 5 --allowedTools Read --output-format json
assert_ok test -s "$out"
assert_ok test "$(wc -c < "$out")" -ge 100

# garbage mode: file exists but tiny
STUB_MODE=garbage "$STUB" -p "OUTPUT FILE: $SANDBOX/art/g.md" >/dev/null
assert_ok test -e "$SANDBOX/art/g.md"
assert_fail test "$(wc -c < "$SANDBOX/art/g.md")" -ge 100

# missing mode: exit 0, no file
STUB_MODE=missing "$STUB" -p "OUTPUT FILE: $SANDBOX/art/m.md" >/dev/null
assert_fail test -e "$SANDBOX/art/m.md"

# exit1 mode
assert_fail env STUB_MODE=exit1 "$STUB" -p "OUTPUT FILE: $SANDBOX/art/x.md"

# verdict appended for verification.md
STUB_VERDICT=FAIL "$STUB" -p "OUTPUT FILE: $SANDBOX/art/verification.md" >/dev/null
assert_eq "$(tail -1 "$SANDBOX/art/verification.md")" "VERDICT: FAIL"

# execution-notes triggers a commit in cwd
repo=$(make_repo stub)
( cd "$repo" && "$STUB" -p "OUTPUT FILE: $SANDBOX/art/execution-notes.md" >/dev/null )
assert_eq "$(git -C "$repo" status --porcelain)" ""
assert_ok test "$(git -C "$repo" rev-list --count origin/main..HEAD)" -ge 1

# STUB_NO_COMMIT leaves the fixture repo untouched
repo2=$(make_repo stub2)
( cd "$repo2" && STUB_NO_COMMIT=1 "$STUB" -p "OUTPUT FILE: $SANDBOX/art/execution-notes2.md" >/dev/null )
assert_eq "$(git -C "$repo2" rev-list --count origin/main..HEAD)" "0"
assert_eq "$(git -C "$repo2" status --porcelain)" ""

# STUB_SLEEP delays before acting
t0=$SECONDS
STUB_SLEEP=1 "$STUB" -p "OUTPUT FILE: $SANDBOX/art/slept.md" >/dev/null
assert_ok test $((SECONDS - t0)) -ge 1

# a prompt with no OUTPUT FILE line fails loudly
assert_fail "$STUB" -p "no artifact path in this prompt"

finish
