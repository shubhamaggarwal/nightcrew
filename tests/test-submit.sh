#!/bin/bash
source "$(dirname "$0")/helpers.sh"
make_sandbox
S="$REPO_ROOT/bin/submit.sh"

repo=$(make_repo submit)

# Rejections: relative path, missing dir, non-repo, empty title
assert_fail "$S" relative/path "T"
assert_fail "$S" "$SANDBOX/nope" "T"
mkdir -p "$SANDBOX/notrepo"
assert_fail "$S" "$SANDBOX/notrepo" "T"
assert_fail "$S" "$repo" ""
assert_fail "$S" "$repo" "$(printf 'Evil\ntitle: forged')"

# Happy path
echo "the description body" > "$SANDBOX/desc.txt"
id=$("$S" "$repo" "Fix the frobnicator" "$SANDBOX/desc.txt")
assert_eq "$id" "T-0001"
tdir="$repo/.nightcrew/tickets/T-0001"
assert_eq "$(cat "$tdir/state")" "new"
assert_ok grep -q '^title: Fix the frobnicator$' "$tdir/ticket.md"
assert_ok grep -q "^workdir: $repo$" "$tdir/ticket.md"
assert_ok grep -q '^created: ' "$tdir/ticket.md"
assert_ok grep -q 'the description body' "$tdir/ticket.md"
assert_ok test -d "$tdir/logs"
assert_ok test -d "$repo/.nightcrew/worktrees"

# Plumbing: exclude entry once, registry entry once, git status clean
exclude=$(git -C "$repo" rev-parse --git-path info/exclude)
case "$exclude" in /*) ;; *) exclude="$repo/$exclude" ;; esac
assert_eq "$(grep -cxF '.nightcrew/' "$exclude")" "1"
id2=$("$S" "$repo" "Second ticket")
assert_eq "$id2" "T-0002"
assert_eq "$(grep -cxF '.nightcrew/' "$exclude")" "1"
assert_eq "$(grep -cxF "$repo" "$NC_ROOT/state/registry")" "1"
assert_eq "$(git -C "$repo" status --porcelain)" ""

# failed submission leaves no partial ticket behind
assert_fail "$S" "$repo" "Orphan check" "$SANDBOX/missing-desc.txt"
assert_eq "$(ls "$repo/.nightcrew/tickets" | wc -l | tr -d ' ')" "2"

finish
