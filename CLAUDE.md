# Nightcrew — project instructions

Local self-hosted ticket pipeline: bash engine (`bin/`) + stdlib-only Python
dashboard (`dashboard/server.py`). Tickets live in each target repo under
`.nightcrew/`; the engine walks them new → requirements → awaiting-approval
(human gate) → planning → executing → verifying → closing → closed, each LLM
state a fresh bounded `claude -p` session.

## Hard invariants — never break these

- `bin/transition.sh` is the ONLY writer of a ticket's `state` file after
  creation, and it validates every move. The dashboard mutates exclusively by
  shelling out to `bin/` scripts.
- Every state-ish write is atomic: build content, then `write_atomic`
  (`bin/lib.sh`) or tmp + `os.replace` in Python. No plain `>` redirects to
  files another process reads.
- Locks are mkdir-based with a PID stamp and stale-PID reclaim
  (per-ticket `.lock/`, `state/poller.lock`). Respect them.
- All shell must run on macOS bash 3.2: no `declare -A`, no `${var,,}`, no
  `readarray`, no `local -n`. JSON is handled with inline `python3`, never
  `jq`.
- `dashboard/server.py` is Python 3 stdlib only, binds `127.0.0.1` only, and
  escapes every ticket-derived string it renders.
- Nothing in the repo may hardcode a machine-local absolute path. The launchd
  plists are `.template` files rendered by `nightcrew install-launchd`.

## Tests

- `bash tests/run.sh` runs everything against `tests/claude-stub.sh` (zero
  tokens). Keep it green; add checks for every engine change.
- Tests sandbox themselves via `make_sandbox` (NC_ROOT + CLAUDE_BIN env
  overrides) and must never touch the real `state/` or any real repo.
- Fixture commits inside test sandboxes use `--no-verify`. Real project
  commits NEVER do.
- The dashboard has no bash tests by design: verify it with the curl
  checklist pattern (start server, curl routes, kill server) plus a browser
  check for visual changes.

## Commits and workflow

- Commit format (enforced by hook): sentence-case imperative subject ≤ 50
  chars, blank line, body wrapped at 72 with `## Summary`, `### What`,
  `### Why`, `## Test Plan` sections. No Conventional Commits, no emoji, no
  Co-Authored-By trailers.
- Enable repo hooks once per clone: `git config core.hooksPath .githooks`
  (they chain to any global hooks dir). gitleaks must be installed; pre-push
  refuses to push without it, and CI runs it on every push and PR.
- Work on a branch/worktree, never directly on master. Run the full suite
  before merging.

## Where things are

- Planning/design docs live in `.plans/` (gitignored, local-only). Do not
  commit internal plans or specs; the public repo carries only README and
  CLAUDE.md as documentation.
- `state/` (registry, id counter, daemon logs, poller lock) is gitignored
  runtime state — never commit it, never depend on its contents in tests.
- Prompt templates: `prompts/<state>.md`, one `OUTPUT FILE:` line each; the
  verifier's verdict is the LAST `VERDICT: PASS|FAIL` line in its artifact.
