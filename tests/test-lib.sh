#!/bin/bash
source "$(dirname "$0")/helpers.sh"
make_sandbox
source "$REPO_ROOT/bin/lib.sh"

# alloc_id: format, monotonic, starts at 1
assert_eq "$(alloc_id)" "T-0001"
assert_eq "$(alloc_id)" "T-0002"

# registry_add: appends once
registry_add /tmp/a
registry_add /tmp/a
registry_add /tmp/b
assert_eq "$(wc -l < "$NC_STATE/registry" | tr -d ' ')" "2"

# write_atomic: content lands, no tmp residue
write_atomic "$SANDBOX/f" "hello"
assert_eq "$(cat "$SANDBOX/f")" "hello"
assert_fail test -e "$SANDBOX/f.tmp"

# state_config: global value, workdir overlay, missing key.
# Values are set explicitly so the checks never couple to whatever the
# local config.json currently says (the settings UI edits it live).
repo=$(make_repo libcfg)
set_state_cfg requirements model '"model-from-global"'
assert_eq "$(state_config "$repo" requirements model)" "model-from-global"
mkdir -p "$repo/.nightcrew"
echo '{"states":{"requirements":{"model":"model-from-workdir"}}}' > "$repo/.nightcrew/config.json"
assert_eq "$(state_config "$repo" requirements model)" "model-from-workdir"
set_state_cfg requirements max_turns 41
assert_eq "$(state_config "$repo" requirements max_turns)" "41"
assert_fail state_config "$repo" requirements no_such_key

# global_config: value and default
set_global max_concurrent 7
assert_eq "$(global_config max_concurrent)" "7"
assert_eq "$(global_config nope 9)" "9"

# resolve_ticket / ticket_workdir
mkdir -p "$repo/.nightcrew/tickets/T-0042"
registry_add "$repo"
assert_eq "$(resolve_ticket T-0042)" "$repo/.nightcrew/tickets/T-0042"
assert_fail resolve_ticket T-9999
assert_eq "$(ticket_workdir "$repo/.nightcrew/tickets/T-0042")" "$repo"

# run_with_timeout: passes rc through, kills on overrun
run_with_timeout 5 bash -c 'exit 7'; assert_eq "$?" "7"
run_with_timeout 1 sleep 30; assert_eq "$?" "143"

finish
