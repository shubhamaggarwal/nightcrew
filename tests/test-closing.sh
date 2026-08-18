#!/bin/bash
source "$(dirname "$0")/helpers.sh"
make_sandbox
R="$REPO_ROOT/bin/run-state.sh"
S="$REPO_ROOT/bin/submit.sh"

# Fake gh on PATH: records its args, prints a PR URL
mkdir -p "$SANDBOX/fakebin"
cat > "$SANDBOX/fakebin/gh" <<'EOF'
#!/bin/bash
echo "$@" >> "${GH_LOG:?}"
case "$1 $2" in
  "pr create") [ "${GH_FAIL_CREATE:-0}" = 1 ] && exit 1
               echo "https://github.com/example/repo/pull/42" ;;
  "pr view")   [ "${GH_FAIL_VIEW:-0}" = 1 ] && exit 1
               echo "https://github.com/example/repo/pull/42" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$SANDBOX/fakebin/gh"
export PATH="$SANDBOX/fakebin:$PATH"
export GH_LOG="$SANDBOX/gh.log"

to_closing() {  # <repo> -> id
  local id
  id=$("$S" "$1" "Close ticket $RANDOM")
  "$R" "$id" >/dev/null 2>&1
  "$R" "$id" >/dev/null 2>&1
  "$REPO_ROOT/bin/transition.sh" "$id" approve >/dev/null 2>&1
  "$R" "$id" >/dev/null 2>&1
  "$R" "$id" >/dev/null 2>&1
  "$R" "$id" >/dev/null 2>&1   # verifying, PASS
  printf '%s\n' "$id"
}

repo=$(make_repo close)
id=$(to_closing "$repo")
tdir="$repo/.nightcrew/tickets/$id"
wt="$repo/.nightcrew/worktrees/$id"

assert_ok "$R" "$id"
assert_eq "$(cat "$tdir/state")" "closed"
assert_eq "$(cat "$tdir/pr-url")" "https://github.com/example/repo/pull/42"
assert_fail test -d "$wt"                                   # worktree removed
bare="$SANDBOX/repos/close-origin.git"
assert_ok git --git-dir="$bare" show-ref --verify "refs/heads/ticket/$id"   # pushed
assert_ok grep -q "pr create" "$GH_LOG"
assert_ok grep -q -- "--base main" "$GH_LOG"

# gh pr create fails but pr view succeeds (idempotent re-close) -> closed
id2=$(to_closing "$repo")
t2="$repo/.nightcrew/tickets/$id2"
GH_FAIL_CREATE=1 "$R" "$id2"
assert_eq "$(cat "$t2/state")" "closed"
assert_eq "$(cat "$t2/pr-url")" "https://github.com/example/repo/pull/42"

# both gh calls fail -> failed with reason
id3=$(to_closing "$repo")
t3="$repo/.nightcrew/tickets/$id3"
GH_FAIL_CREATE=1 GH_FAIL_VIEW=1 "$R" "$id3"
assert_eq "$(cat "$t3/state")" "failed"
assert_ok grep -q 'gh pr create failed' "$t3/failed.json"

# workdir without an origin remote -> failed before any push
norepo="$SANDBOX/repos/noorigin"
git init -q -b main "$norepo"
git -C "$norepo" config user.email test@nightcrew.local
git -C "$norepo" config user.name "Nightcrew tests"
echo x > "$norepo/f"
git -C "$norepo" add f
git -C "$norepo" commit -qm "Init" --no-verify
id4=$("$S" "$norepo" "No origin")
t4="$norepo/.nightcrew/tickets/$id4"
source "$REPO_ROOT/bin/lib.sh"
write_atomic "$t4/state" "closing"
mkdir -p "$norepo/.nightcrew/worktrees/$id4"
"$R" "$id4"
assert_eq "$(cat "$t4/state")" "failed"
assert_ok grep -q 'no origin remote' "$t4/failed.json"

finish
