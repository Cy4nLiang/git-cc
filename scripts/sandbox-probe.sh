#!/usr/bin/env bash
# CI + local probe for the trunk-based / tag-release sandbox.
# Does not mutate git. Exit 0 = design checks passed.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

version="$(git describe --tags --always)"
branch="$(git symbolic-ref --short -q HEAD || echo DETACHED)"
echo "APP_VERSION=$version"
echo "branch=$branch"

# PR context (GitHub Actions) or local override
HEAD="${GITHUB_HEAD_REF:-$branch}"
BASE="${GITHUB_BASE_REF:-main}"

if [ -n "${GITHUB_HEAD_REF:-}" ] || [ "${SANDBOX_PROBE_PROMOTION:-0}" = "1" ]; then
  case "$HEAD" in
    spike/*|worktree-*)
      echo "promotion-guard: $HEAD must never merge" >&2
      exit 1
      ;;
  esac
  case "$BASE" in
    release/*)
      [[ "$HEAD" == hotfix/* ]] || { echo "promotion-guard: $BASE only accepts hotfix/* (got $HEAD)" >&2; exit 1; }
      ;;
    main)
      [[ "$HEAD" =~ ^(feat|fix|chore|docs|refactor|test|perf|ci|build|revert)/ ]] \
        || { echo "promotion-guard: bad head branch name: $HEAD" >&2; exit 1; }
      ;;
  esac
  echo "promotion-guard: ALLOW $HEAD → $BASE"
fi

# Version tags must be annotated when present
if git rev-parse -q --verify refs/tags/v0.2.0 >/dev/null; then
  obj="$(git cat-file -t refs/tags/v0.2.0)"
  [ "$obj" = "tag" ] || { echo "v0.2.0 is $obj, expected annotated tag" >&2; exit 1; }
fi

# rc and stable of the same release must share a commit when both exist
if git rev-parse -q --verify refs/tags/v0.2.0 >/dev/null \
   && git rev-parse -q --verify refs/tags/v0.2.0-rc.1 >/dev/null; then
  a="$(git rev-parse 'v0.2.0^{commit}')"
  b="$(git rev-parse 'v0.2.0-rc.1^{commit}')"
  [ "$a" = "$b" ] || { echo "v0.2.0 and v0.2.0-rc.1 point at different commits" >&2; exit 1; }
  echo "same-commit promote: v0.2.0 == v0.2.0-rc.1 == $a"
fi

echo "sandbox-probe: ok"
