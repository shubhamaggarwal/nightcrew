#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

workdir="${1:-}"
title="${2:-}"
descfile="${3:-}"

case "$workdir" in /*) ;; *) die "workdir must be an absolute path" ;; esac
[ -d "$workdir" ] || die "no such directory: $workdir"
git -C "$workdir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git repository: $workdir"
[ -n "$title" ] || die "title must not be empty"
case "$title" in *$'\n'*|*$'\r'*) die "title must be a single line" ;; esac

desc=""
if [ -n "$descfile" ]; then
  [ -r "$descfile" ] || die "cannot read description file: $descfile"
  desc=$(cat "$descfile")
fi

mkdir -p "$workdir/.nightcrew/tickets" "$workdir/.nightcrew/worktrees"
exclude=$(git -C "$workdir" rev-parse --git-path info/exclude)
case "$exclude" in /*) ;; *) exclude="$workdir/$exclude" ;; esac
mkdir -p "$(dirname "$exclude")"
touch "$exclude"
grep -qxF '.nightcrew/' "$exclude" || printf '.nightcrew/\n' >> "$exclude"
registry_add "$workdir"

id=$(alloc_id)
tdir="$workdir/.nightcrew/tickets/$id"
mkdir -p "$tdir/logs"
trap 'rm -rf "$tdir"' EXIT
cat > "$tdir/ticket.md" <<EOF
---
title: $title
workdir: $workdir
created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---

$desc
EOF
write_atomic "$tdir/state" "new"
trap - EXIT
printf '%s\n' "$id"
