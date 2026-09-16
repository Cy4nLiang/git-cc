#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Exit 2 = block, stderr goes back to Claude.
# Guard rail for Claude only; humans are covered by .githooks/pre-push, GitHub by rulesets.
set -uf
input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0
case "$cmd" in *git*|*gh\ *) ;; *) exit 0 ;; esac          # fast path

PROTECTED_RE='^(main|master|release/[0-9]+\.[0-9]+)$'
PROTECTED_NAMES='(main|master|release/[0-9]+\.[0-9]+)'
TAG_RE='^(refs/tags/)?v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$'
L='(^|[[:space:]:+=])'            # what may precede a ref name
R='([[:space:]:;|&)`]|$)'         # what may follow a ref name
deny() { printf 'BLOCKED by .claude/hooks/guard-git.sh: %s\n' "$1" >&2; exit 2; }

# Which repo does the command act on?  honour `git -C <path>` and a leading `cd <path> &&`
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"; [ -z "$cwd" ] && cwd="$PWD"
dir="$cwd"
if [[ "$cmd" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then dir="${BASH_REMATCH[1]}"
elif [[ "$cmd" =~ ^[[:space:]]*cd[[:space:]]+([^[:space:];&|]+) ]]; then dir="${BASH_REMATCH[1]}"; fi
dir="${dir/#\~/$HOME}"; [[ "$dir" = /* ]] || dir="$cwd/$dir"
branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"

# Normalise before matching (all rules below run on $flat / $norm, never on the raw command):
#  flat: newlines -> ';'  |  drop quoted message text after -m/--message/--grep/--title/--body/--notes
#        (so a commit message that *mentions* --no-verify does not trip R0)  |  strip remaining quote chars
#        (so "HEAD:main" matches like HEAD:main)
#  norm: flat + collapse git global options (-C <p>, -c k=v, --no-pager, -P) so `git -C x push` == `git push`
#        + drop refs/heads/ so HEAD:refs/heads/main == HEAD:main
flat="$(printf '%s' "$cmd" | tr '\n' ';' \
  | sed -E "s/(-[A-Za-z]*m|--message|--grep|--title|--body|--notes)(=|[[:space:]]+)(\"[^\"]*\"|'[^']*')//g; s/[\"']//g")"
norm="$(printf '%s' "$flat" \
  | sed -E 's/git([[:space:]]+(-C[[:space:]]+[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--no-pager|-P))+[[:space:]]+/git /g; s#refs/heads/##g')"
has()  { printf '%s' "$norm" | grep -Eq "$1"; }
hasf() { printf '%s' "$flat" | grep -Eq "$1"; }

# R0  never dismantle the guard rails (checked on $flat: `git -c core.hooksPath=` must still be visible)
if hasf '(^|[[:space:];])--no-verify([[:space:];|&]|$)|-c[[:space:]]*core\.hooksPath|git[[:space:]]+config[^|;&]*hooksPath|(^|[[:space:];])(ALLOW_PROTECTED_PUSH|GIT_DIR)=|--git-dir(=|[[:space:]])'; then
  deny "bypassing hooks (--no-verify / core.hooksPath / ALLOW_PROTECTED_PUSH / GIT_DIR / --git-dir) is not allowed. Ask the human."
fi
# R1  plain force push anywhere; --force-with-lease only on non-protected branches
if has 'git[[:space:]]+push[^|;&]*([[:space:]](--force|-f)([[:space:]]|$)|[[:space:]]\+[^[:space:]])'; then
  deny "plain force push is forbidden; --force-with-lease is allowed only on your own feat/fix/spike branch."
fi
if has 'git[[:space:]]+push[^|;&]*--force-with-lease' && { has "git[[:space:]]+push[^|;&]*${L}${PROTECTED_NAMES}${R}" || [[ "$branch" =~ $PROTECTED_RE ]]; }; then
  deny "force-with-lease to a protected branch is forbidden."
fi
# R2  deleting protected branches or v* tags on the remote (own feat/* branches may be deleted)
if has 'git[[:space:]]+push[^|;&]*([[:space:]](--delete|-d)([[:space:]]|$)|[[:space:]]:[^[:space:]])' \
   && has "git[[:space:]]+push[^|;&]*(${L}${PROTECTED_NAMES}${R}|refs/tags/v[0-9]|[[:space:]:]v[0-9]+\.[0-9]+\.[0-9]+)"; then
  deny "deleting protected branches or release tags is forbidden."
fi
# R3  explicit push to a protected ref from any branch (origin main / HEAD:main / HEAD:refs/heads/main / "HEAD:main")
if has "git[[:space:]]+push[^|;&]*${L}${PROTECTED_NAMES}${R}"; then
  deny "direct push to main/release/* is forbidden; open a PR: gh pr create --base <branch>."
fi
# R4  tags are immutable; never push all tags
if has 'git[[:space:]]+tag[^|;&]*[[:space:]](-d|--delete|-f|--force)([[:space:]]|$)' || has 'git[[:space:]]+push[^|;&]*[[:space:]](--tags|--follow-tags)([[:space:]]|$)'; then
  deny "deleting/moving tags or 'git push --tags' is forbidden; push one tag: git push origin vX.Y.Z."
fi
# R5  no admin bypass of branch protection
if has 'gh[[:space:]]+pr[[:space:]]+merge[^|;&]*--admin'; then
  deny "gh pr merge --admin bypasses branch protection; not allowed."
fi
# R6  protected branch checked out: read-only git, plus pushing version tags only
if [[ "$branch" =~ $PROTECTED_RE ]]; then
  if has 'git[[:space:]]+(commit|merge|rebase|cherry-pick|am|revert|apply|stash|reset[[:space:]]+--hard|switch|checkout[[:space:]]+-[bB])([[:space:]]|$)'; then
    deny "'$branch' is protected. Use a worktree: /new-feature <name> (or git worktree add ... -b feat/<name> origin/main)."
  fi
  # every `git push` segment must push version tags only: git push origin vX.Y.Z [vX.Y.W ...]
  bad="$(printf '%s' "$norm" | tr '|;&' '\n\n\n' | grep -E 'git[[:space:]]+push' | while read -r seg; do
      args="$(printf '%s' "$seg" | sed -E 's/.*git[[:space:]]+push//; s/(^|[[:space:]])-[^[:space:]]*//g')"
      set -- $args; [ $# -ge 1 ] && shift                       # first word is the remote
      [ $# -eq 0 ] && { echo '<current branch>'; continue; }
      for r in "$@"; do [[ "$r" =~ $TAG_RE ]] || echo "$r"; done
    done)"
  [ -n "$bad" ] && deny "'$branch' is protected: only 'git push origin vX.Y.Z' is allowed here (refused: $(printf '%s' "$bad" | tr '\n' ' '))."
fi
exit 0
