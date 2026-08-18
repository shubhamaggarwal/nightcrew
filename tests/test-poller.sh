#!/bin/bash
source "$(dirname "$0")/helpers.sh"
make_sandbox
P="$REPO_ROOT/bin/poller.sh"
S="$REPO_ROOT/bin/submit.sh"

repo=$(make_repo poll)
id=$("$S" "$repo" "Polled ticket")
tdir="$repo/.nightcrew/tickets/$id"

# One pass: new -> requirements (dispatch happened, lock released)
POLLER_ONCE=1 "$P"
assert_eq "$(cat "$tdir/state")" "requirements"
assert_fail test -d "$tdir/.lock"

# Second pass runs the requirements session
POLLER_ONCE=1 "$P"
assert_eq "$(cat "$tdir/state")" "awaiting-approval"

# Human-owned states are never dispatched
POLLER_ONCE=1 "$P"
assert_eq "$(cat "$tdir/state")" "awaiting-approval"

# Stale lock (dead PID) is reclaimed
id2=$("$S" "$repo" "Stale lock ticket")
t2="$repo/.nightcrew/tickets/$id2"
mkdir "$t2/.lock"
sleep 0.2 & deadpid=$!; wait "$deadpid" 2>/dev/null
echo "$deadpid" > "$t2/.lock/pid"
POLLER_ONCE=1 "$P"
assert_eq "$(cat "$t2/state")" "requirements"

# Live lock is respected
id3=$("$S" "$repo" "Live lock ticket")
t3="$repo/.nightcrew/tickets/$id3"
mkdir "$t3/.lock"
sleep 30 & livepid=$!
echo "$livepid" > "$t3/.lock/pid"
POLLER_ONCE=1 "$P"
assert_eq "$(cat "$t3/state")" "new"
kill "$livepid" 2>/dev/null
rm -rf "$t3/.lock"

# Drain id3 out of the auto set so the cap test below is deterministic
"$REPO_ROOT/bin/transition.sh" "$id3" advance >/dev/null 2>&1   # new -> requirements
POLLER_ONCE=1 "$P"                                              # requirements session runs
assert_eq "$(cat "$t3/state")" "awaiting-approval"

# max_concurrent honored: two tickets ready in requirements, cap 1, slow
# sessions -> the first (lowest id) runs, the second is never dispatched.
set_global max_concurrent 1
id4=$("$S" "$repo" "Slow A")
id5=$("$S" "$repo" "Slow B")
"$REPO_ROOT/bin/transition.sh" "$id4" advance >/dev/null 2>&1
"$REPO_ROOT/bin/transition.sh" "$id5" advance >/dev/null 2>&1
STUB_SLEEP=2 POLLER_ONCE=1 "$P"
assert_eq "$(cat "$repo/.nightcrew/tickets/$id4/state")" "awaiting-approval"
assert_eq "$(cat "$repo/.nightcrew/tickets/$id5/state")" "requirements"
assert_fail test -e "$repo/.nightcrew/tickets/$id5/requirements.md"
set_global max_concurrent 3

# Missing registered workdir: warns, keeps going, no crash
echo "$SANDBOX/gone" >> "$NC_ROOT/state/registry"
assert_ok env POLLER_ONCE=1 "$P"

# A second poller refuses to start while one is live
mkdir -p "$NC_ROOT/state/poller.lock"
echo $$ > "$NC_ROOT/state/poller.lock/pid"
assert_fail env POLLER_ONCE=1 "$P"
rm -rf "$NC_ROOT/state/poller.lock"

# A stale poller lock (dead pid) is reclaimed at startup
mkdir -p "$NC_ROOT/state/poller.lock"
sleep 0.1 & stalepid=$!
wait "$stalepid" 2>/dev/null
echo "$stalepid" > "$NC_ROOT/state/poller.lock/pid"
assert_ok env POLLER_ONCE=1 "$P"
assert_fail test -d "$NC_ROOT/state/poller.lock"

finish
