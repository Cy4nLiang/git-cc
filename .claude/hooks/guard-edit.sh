#!/usr/bin/env bash
set -u
input="$(cat)"
f="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
[ -z "$f" ] && exit 0
d="$(dirname "$f")"
while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
if [[ "$branch" =~ ^(main|master|release/[0-9]+\.[0-9]+)$ ]]; then
  printf 'BLOCKED by .claude/hooks/guard-edit.sh: %s is on protected branch %s. Work in a feature worktree (see CLAUDE.md).\n' "$f" "$branch" >&2
  exit 2
fi
exit 0
