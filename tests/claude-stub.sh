#!/bin/bash
# Stand-in for `claude` in tests. Zero tokens, deterministic.
# Reads the artifact path from the "OUTPUT FILE: " line in the -p prompt.

[ -n "${STUB_ARGS_FILE:-}" ] && printf '%s\n' "$@" > "$STUB_ARGS_FILE"

prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
out=$(printf '%s\n' "$prompt" | sed -n 's/^OUTPUT FILE: //p' | head -1)
[ -n "$out" ] || { echo "claude-stub: prompt has no OUTPUT FILE line" >&2; exit 64; }

sleep "${STUB_SLEEP:-0}"

case "${STUB_MODE:-ok}" in
  timeout) sleep 300 ;;
  exit1)   exit 1 ;;
  missing) : ;;
  garbage) printf 'x\n' > "$out" ;;
  ok)
    {
      echo "# Stub artifact"
      i=1
      while [ $i -le 20 ]; do echo "- line $i of canned stub output"; i=$((i + 1)); done
    } > "$out"
    case "$out" in
      *verification.md)
        printf 'VERDICT: %s\n' "${STUB_VERDICT:-PASS}" >> "$out" ;;
      *execution-notes.md)
        if [ "${STUB_NO_COMMIT:-0}" != 1 ]; then
          echo "stub change $$" >> stub-change.txt
          git add stub-change.txt
          git -c user.email=stub@nightcrew.local -c user.name=stub commit -qm "Stub change" --no-verify
        fi ;;
    esac ;;
esac
echo '{"result": "stub"}'
