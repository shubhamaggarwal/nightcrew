# Nightcrew

File a coding ticket before bed; wake up to a pull request.

Nightcrew is a local, self-hosted ticket pipeline for [Claude
Code](https://claude.com/claude-code). You file tickets on a small dark-mode
dashboard, approve their requirements once, and a background crew walks each
one through the pipeline — every stage a fresh, bounded `claude -p` session —
until it lands as a GitHub PR on the repo you pointed it at.

```
new → requirements → awaiting-approval → planning → executing → verifying → closing → closed
                          (you)                                     ↘ failed (retry)
```

Everything is files. Tickets live inside the target repo under `.nightcrew/`
(kept out of the repo's history via `.git/info/exclude`); state transitions
are one tiny shell script; `cat` and `grep` are first-class debugging tools.
The dashboard is a single stdlib-only Python file bound to `127.0.0.1`.

## Requirements

macOS, git, python3, the `claude` CLI, and `gh` (authenticated). No other
dependencies — no npm, no pip, no database.

## Quick start

```bash
git clone <this repo> && cd nightcrew
ln -s "$PWD/bin/nightcrew" /opt/homebrew/bin/nightcrew   # or anywhere on PATH
nightcrew start
```

`nightcrew start` launches the poller and the dashboard in the background and
opens the board at `http://127.0.0.1:8377`. `nightcrew stop` shuts both down;
`nightcrew status` tells you what is running. Both are idempotent.

To run Nightcrew as always-on launchd services instead (survives reboots):

```bash
nightcrew install-launchd     # renders plists for THIS checkout's path
launchctl load ~/Library/LaunchAgents/com.nightcrew.poller.plist
launchctl load ~/Library/LaunchAgents/com.nightcrew.dashboard.plist
```

Use one launch method or the other, never both at once — a second dashboard
on the same port crash-loops under launchd's KeepAlive.

## Usage

- **Dashboard** — file tickets (with a directory browser for picking the
  target repo), approve requirements, retry failures, edit per-state models
  and prompts on the Settings page.
- **CLI** — `bin/submit.sh <absolute-repo-path> "Title" [description-file]`.
- **Files** — `<repo>/.nightcrew/tickets/T-NNNN/` holds state, artifacts
  (requirements.md, plan.md, execution-notes.md, verification.md), and
  per-session logs.
- **Per-repo overrides** — drop `.nightcrew/config.json` or
  `.nightcrew/prompts/<state>.md` into a target repo to override the global
  defaults for that repo only.
- **Tools** — each state runs with a configurable tool allowlist; `*` grants
  every tool, and Claude Code patterns like `Bash(git:*)` pass through.

## Tests

```bash
bash tests/run.sh          # full suite against a stubbed claude; no tokens
tests/smoke-live.sh <repo> # one real ticket through to a PR; costs tokens
```

## Development workflow

Secrets are scanned at three gates, all using the free, open-source
[gitleaks](https://github.com/gitleaks/gitleaks):

1. **pre-commit** — staged changes are scanned before every commit
2. **pre-push** — the full local history is scanned before anything leaves
   your machine (the push is blocked if gitleaks is not installed)
3. **CI** — `.github/workflows/secret-scan.yml` runs gitleaks on every push
   and pull request

Enable the local hooks once per clone:

```bash
brew install gitleaks
git config core.hooksPath .githooks
```

The repo hooks chain to any globally-configured hooks dir, so a global
`core.hooksPath` setup keeps working.

## License

MIT — see [LICENSE](LICENSE).
