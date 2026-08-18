#!/bin/bash
source "$(dirname "$0")/helpers.sh"
make_sandbox
R="$REPO_ROOT/bin/run-state.sh"
S="$REPO_ROOT/bin/submit.sh"

advance_to_executing() {  # <repo> -> ticket id on stdout
  local id
  id=$("$S" "$1" "Exec ticket $RANDOM")
  "$R" "$id" >/dev/null 2>&1                                  # new
  "$R" "$id" >/dev/null 2>&1                                  # requirements
  "$REPO_ROOT/bin/transition.sh" "$id" approve >/dev/null 2>&1
  "$R" "$id" >/dev/null 2>&1                                  # planning
  printf '%s\n' "$id"
}

repo=$(make_repo exec)

# Happy path: worktree created, branch commits, notes, advance
id=$(advance_to_executing "$repo")
tdir="$repo/.nightcrew/tickets/$id"
wt="$repo/.nightcrew/worktrees/$id"
assert_ok "$R" "$id"
assert_eq "$(cat "$tdir/state")" "verifying"
assert_ok test -d "$wt"
assert_eq "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" "ticket/$id"
assert_ok test "$(git -C "$wt" rev-list --count origin/main..HEAD)" -ge 1
assert_ok test -s "$tdir/execution-notes.md"
assert_eq "$(git -C "$wt" status --porcelain)" ""

# A no-op fix-cycle session is rejected (round-1 commits don't count)
"$REPO_ROOT/bin/transition.sh" "$id" fix >/dev/null 2>&1
STUB_NO_COMMIT=1 "$R" "$id"
assert_eq "$(cat "$tdir/state")" "failed"
assert_ok grep -q 'no new commits' "$tdir/failed.json"

# No commits produced -> failed
id2=$(advance_to_executing "$repo")
t2="$repo/.nightcrew/tickets/$id2"
STUB_NO_COMMIT=1 "$R" "$id2"
assert_eq "$(cat "$t2/state")" "failed"
assert_ok grep -q 'no new commits' "$t2/failed.json"

# Dirty pre-existing worktree -> failed, never guessed at
id3=$(advance_to_executing "$repo")
t3="$repo/.nightcrew/tickets/$id3"
wt3="$repo/.nightcrew/worktrees/$id3"
git -C "$repo" worktree add -b "ticket/$id3" "$wt3" origin/main >/dev/null 2>&1
echo dirt > "$wt3/uncommitted.txt"
"$R" "$id3"
assert_eq "$(cat "$t3/state")" "failed"
assert_ok grep -q 'dirty' "$t3/failed.json"

# Clean pre-existing worktree (fix cycle shape) -> reused
id4=$(advance_to_executing "$repo")
t4="$repo/.nightcrew/tickets/$id4"
wt4="$repo/.nightcrew/worktrees/$id4"
git -C "$repo" worktree add -b "ticket/$id4" "$wt4" origin/main >/dev/null 2>&1
assert_ok "$R" "$id4"
assert_eq "$(cat "$t4/state")" "verifying"

finish
