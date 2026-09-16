#!/usr/bin/env bash
set -u
cwd="$(jq -r '.cwd // empty')"; [ -z "$cwd" ] && cwd="$PWD"
cd "$cwd" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
[ "$(git config core.hooksPath)" = "$main/.githooks" ] || git config core.hooksPath "$main/.githooks"
b="$(git symbolic-ref --short -q HEAD || echo DETACHED)"
if [ "$(git rev-parse --path-format=absolute --git-dir)" != "$(git rev-parse --path-format=absolute --git-common-dir)" ]; then
  for f in .env .env.local CLAUDE.local.md; do
    [ -f "$main/$f" ] && [ ! -f "$f" ] && cp "$main/$f" "$f" && echo "bootstrap: copied $f from main checkout"
  done
  [ -f package.json ] && [ ! -d node_modules ] && echo "NOTE: node_modules missing; run: bash scripts/wt-setup.sh"
fi
echo "git context: branch=$b dir=$cwd main_checkout=$main"
case "$b" in main|master|release/*) echo "WARNING: '$b' is protected. Do NOT edit/commit here. Run /new-feature <name> first.";; esac
git worktree list | sed 's/^/worktree: /'
exit 0
