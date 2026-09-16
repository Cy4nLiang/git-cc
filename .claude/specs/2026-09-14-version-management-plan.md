# Trunk-based + Tag Release：Claude Code 多会话版本管理方案（最终版）

> 环境：macOS，Claude Code v2.1.270，git 2.40，gh 2.89，目录 `/Users/cyanliang/workspace/git-cc`（空、未 `git init`）。
> 所有 hook / pre-push 脚本已在本机临时仓库实测（guard-git 141 条 git/gh 用例 + worktree 场景，bash 3.2）。文中涉及的 Claude Code / GitHub 行为均已按官方文档或本机 v2.1.270 实测确认，不再保留"需核实"项。

## 1. 一句话结论与分支模型

**只有 `main` 一条长期分支；一切改动走短命分支 + PR + squash；发布 = 打 tag（rc 上测试、同一 commit 转正上生产）；旧版本按需从正式 tag 切 `release/X.Y`；每个分支一个 worktree、一个 Claude 会话，CLAUDE.md + hooks + pre-push + ruleset 四层护栏。**

```
 feat/* fix/* chore/* ──PR(squash)──►  main  ──(可选)自动部署──► dev 环境
 (../git-cc.wt/<name>, 1 会话/分支)     │
                                        ├── tag vX.Y.Z-rc.N ──► staging/QA   （显式晋升，冻结快照）
 spike/* worktree-* ──✗ 永不 PR──┘      └── tag vX.Y.Z ─────► production    （必须与 rc 同一 commit）
 (claude --worktree, 用完即删)
                       release/X.Y ◄──PR(squash)── hotfix/X.Y.Z-* (cherry-pick -x 自 main)
                       (仅从正式 tag vX.Y.P 切出)   └── tag vX.Y.(P+1) ──► 该版本线 production
```

## 2. 分支与环境对应表

| 分支 / tag | 用途 | 对应环境 | 保护 | 谁能合入 | 生命周期 |
|---|---|---|---|---|---|
| `main` | 唯一主干，永远可构建；所有 tag 的来源 | dev（可选自动部署） | ruleset + hook + pre-push | 仅 PR（squash，CI 绿） | 永久 |
| `feat/*` `fix/*` `chore/*` `docs/*` `refactor/*` | 日常开发，从 `origin/main` 切 | 本地 worktree + PR CI | 无 | 作者 `gh pr merge --squash` | ≤ 2 天，合并即删 |
| `spike/*`、`worktree-*` | 想法验证，允许脏提交 | 本地实验 | CI 拒绝其 PR | 永不合入 | 数小时～2 天，结束即删 |
| tag `vX.Y.Z-rc.N` | 发布候选，QA 签收对象 | **staging** | tag ruleset + hook | `/release` | 永久不可变 |
| tag `vX.Y.Z` | 正式版本，必须与某 rc 同 commit | **production** | tag ruleset + hook + 环境审批（需 public 仓库或 Pro/Team） | `/release promote` | 永久不可变 |
| `release/X.Y` | 维护线，只从正式 tag `vX.Y.P` 切出，只收 `hotfix/*` | 该版本线 production | ruleset + hook + pre-push | 仅 PR（squash） | 首次热修 → EOL |
| `hotfix/X.Y.Z-*` | 针对 `release/X.Y` 的修复 | 本地 worktree + PR CI | 无 | 作者 | ≤ 1 天 |

## 3. 五项需求逐条满足

- **多版本**：每次发布是 annotated tag，任何版本 `git worktree add ../git-cc.wt/v1.4.2 v1.4.2` 即可复现。1.x 修 bug 与 2.x 开发并行：main 承载 2.x，1.x 走 `release/1.4`（只从 `v1.4.P` 切出）。修复方向 fix-forward：先在 main 修好，再 `cherry-pick -x` 到各条仍在支持的 release 线；`/release --from` 用 patch-id 比对检查是否漏前移。
- **生产**：只有不含 `-rc.` 的 `v*` tag 触发 prod 部署，且 tag 必须落在已签收的 rc 同一 commit（`/release promote` 机械保证）。prod job 绑定 GitHub Environment `production` 加人工审批，避免误打 tag 直接上线（Environments/required reviewers 仅 public 仓库或 Pro/Team 可用，Free 私有仓库下这道门会静默失效，见 §8）。tag 不可删不可移。
- **测试**：staging 只部署 `vX.Y.Z-rc.N` tag，是显式晋升出的冻结快照，QA 签收后不会被下一次 main 合并覆盖；测过的 commit 就是上线的 commit。rc 期发现 main 混入不想发的内容，在 main 上 `git revert` 走 PR 后重新打 rc（不从 rc 切 release 分支）。
- **想法验证**：`claude --worktree try-x` 一条命令得到独立 worktree + 分支 `worktree-try-x`，或 `/spike <idea>` 记录假设与截止日期。`spike/*`、`worktree-*` 的 PR 被 CI `promotion-guard` 拒绝，成功后用 `/new-feature` 重写干净版本。
- **开发稳定运行**：main 上每个 commit 都是一个完整、CI 绿、经 `/code-review` 的 PR；strict status check 保证"合起来也是绿"。默认策略是**短分支 + worktree，不合半成品**，feature flag 只作例外。主检出永远停在 main 只 `git pull --ff-only`，随时能跑；hook 禁止在 main 上编辑/提交。

## 4. 版本号与 tag 规则

- SemVer：`vMAJOR.MINOR.PATCH`，候选 `vMAJOR.MINOR.PATCH-rc.N`。全部 `git tag -a`，永不删除/移动，永不 `git push --tags`，只推单个 tag：`git push origin vX.Y.Z`。
- 升级判定：PR 标题含 `!` 或 `BREAKING CHANGE` → MAJOR；含 `feat` → MINOR；只有 `fix/chore/...` → PATCH。`release/X.Y` 只允许 PATCH。
- MAJOR 递增是固定检查点：`/release` 检测到后先提示从上一大版本最后正式 tag 建 `release/X.Y` 维护线，再打新 tag。
- 版本号真源是 tag：CI 用 `git describe --tags --always` 注入 `APP_VERSION`。若必须写进 `package.json`，在 QA 周期开始前先走 `chore(release): bump to X.Y.Z` PR。
- 提交规范 Conventional Commits `type(scope): subject`；squash 信息 = PR 标题，PR 必须 `--label <feat|fix|hotfix|breaking|chore|skip-changelog>`，`.github/release.yml` 按 label 分类生成 Release notes。
- 维护线发版 `gh release create --latest=false`，避免 1.4.3 盖过 2.x 成为 latest。

## 5. Claude Code 工作方式

### 5.1 一条分支 = 一个 worktree = 一个 Claude 会话

```
~/workspace/git-cc/            主检出：永远在 main，只 pull、review、发版；.claude/worktrees/ 放 spike
~/workspace/git-cc.wt/<name>/  手工 worktree：feat / fix / hotfix / release 维护线，各自一个终端一个会话
```

```bash
# 正式工作（feat/fix/hotfix）：手工 worktree（等价于 /new-feature 做的事）
cd ~/workspace/git-cc && git fetch origin --prune
git worktree add ../git-cc.wt/checkout-coupon -b feat/checkout-coupon origin/main
cd ../git-cc.wt/checkout-coupon && bash scripts/wt-setup.sh && claude -n feat-checkout-coupon

# 想法验证：Claude 内置 worktree（目录 .claude/worktrees/try-redis，分支 worktree-try-redis，基线 origin/HEAD，缺失时按 origin/main → origin/master）
cd ~/workspace/git-cc && claude --worktree try-redis          # 加 --tmux 可在 iTerm2 开独立面板
# 会话中途也可让 Claude 用 EnterWorktree 工具自建 worktree；退出用 ExitWorktree

# 并行：终端 1 主检出 review/发版，终端 2 feat，终端 3 hotfix，终端 4 spike
claude --from-pr 42        # 找回创建某 PR 的会话；claude -c 在某目录续最近会话

# 清理
git worktree remove ../git-cc.wt/checkout-coupon && git branch -D feat/checkout-coupon
git worktree unlock .claude/worktrees/try-redis 2>/dev/null; git worktree remove --force .claude/worktrees/try-redis
git branch -D worktree-try-redis && git worktree prune
```

`scripts/wt-setup.sh`（幂等；第 3 步按技术栈改）：

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(git rev-parse --show-toplevel)"; main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
cd "$root"
for f in .env .env.local CLAUDE.local.md; do [ -f "$main/$f" ] && [ ! -f "$f" ] && cp "$main/$f" "$f"; done   # 1. 本地配置
port=$((3000 + $(printf '%s' "$root" | cksum | cut -d' ' -f1) % 1000))                                        # 2. 独立端口
grep -q '^PORT=' .env 2>/dev/null && sed -i '' "s/^PORT=.*/PORT=$port/" .env || echo "PORT=$port" >> .env
[ -f package-lock.json ] && npm ci --no-audit --no-fund                                                        # 3. 依赖
echo "worktree ready: $root (PORT=$port)"
```

`.worktreeinclude`（让 `claude --worktree` 自动复制 gitignored 文件）：

```text
.env
.env.local
CLAUDE.local.md
```

### 5.2 CLAUDE.md（可直接粘贴）

```markdown
## Git 工作流（Trunk-based，必须遵守）
### 分支
- `main` 是唯一长期分支。禁止在 main / release/* 上编辑文件、commit、merge、rebase、cherry-pick、push（hooks 会拦截，被拦时不要绕过）。
- 任何改动先开短分支：`feat/<scope>-<desc>`、`fix/<scope>-<desc>`、`chore/*`、`docs/*`、`refactor/*`、`hotfix/<X.Y.Z>-<desc>`；只用 `[a-z0-9-/.]`。一个分支只做一件事，目标 ≤ 2 天；做不完就拆 PR，不合半成品。
- 正式工作只用 `/new-feature <name>`（手工 worktree，分支名合规）。`spike/*` 与 `worktree-*`（claude --worktree / EnterWorktree 创建）是实验分支：永不 `gh pr create`；若已在 `worktree-*` 上做了正式工作，PR 前 `git branch -m feat/<name>`。
- `release/X.Y` 只能由 /hotfix 从正式 tag 创建；同样只接受 PR。
### 提交
- Conventional Commits：`type(scope): subject`，type ∈ feat|fix|docs|refactor|test|chore|perf|ci|build|revert，英文祈使句 ≤ 72 字符；破坏性变更 `type!:` 或 `BREAKING CHANGE:` footer。
- 禁止：`--no-verify`、`git push --force`（自己的 feat 分支允许 `--force-with-lease`）、`git push --tags`、删除或移动 tag、`git stash`（跨 worktree 共享会串）、修改 `core.hooksPath`、设置 `ALLOW_PROTECTED_PUSH`、编辑 `.claude/hooks/**`、`.claude/settings.json`、`.githooks/**`（除非用户明确要求）。
- feature flag 只作例外：配置键 `FLAG_<NAME>` 默认关闭，同时建 issue，全量后一周内删除。
### 合并前清单（开 PR 前逐项做）
1. `git fetch origin && git rebase origin/main`（hotfix 用 `origin/release/X.Y`），重跑测试。
2. `/code-review`：修完所有 CONFIRMED；PLAUSIBLE 逐条说明取舍。大改动 `/code-review high` 或 `/code-review ultra`。
3. 涉及认证/权限/用户输入/依赖升级/外部调用/文件或命令执行 → 再跑 `/security-review`。
4. `gh pr create --base main --fill --label <feat|fix|chore>`（hotfix：`--base release/X.Y --label hotfix`）。PR 标题就是 squash 信息，必须符合规范。
5. `gh pr checks --watch` 全绿后告诉用户；除非用户明确要求，不要自己 `gh pr merge`；永远不用 `--admin`。
### 发布与回滚
- 版本号只来自 tag；`vX.Y.Z-rc.N` → staging，`vX.Y.Z` → production，二者必须同一 commit。发布/热修只走 `/release`、`/hotfix`。
- 回滚三级：1) 重新部署上一个正式 tag（首选，不动 git）；2) 开 `fix/revert-<sha>` 分支 `git revert <squash-sha>` 走 PR，再打新 PATCH；3) 永不 force、永不删 tag。
### 并行会话与 worktree
- 每个会话只在自己的 worktree 里工作；不要 `cd`/`git -C` 到别的 worktree 或主检出执行 git 命令。唯一例外：/new-feature、/hotfix、/spike 刚创建好 worktree 后，允许执行一次 `cd <新 worktree> && bash scripts/wt-setup.sh`，之后仍回到本会话自己的目录。
- 开始改动前先 `git branch --show-current`；在 main/release/* 上就先调用 /new-feature <name>（这个 skill 允许你自行调用，release/hotfix 则只能由用户触发）。新 worktree 先 `bash scripts/wt-setup.sh`，dev server 端口读 `.env` 的 `PORT`。
```

### 5.3 hooks 护栏

`.claude/settings.json`（入库）：

```json
{
  "worktree": { "baseRef": "fresh" },
  "permissions": {
    "allow": [
      "Bash(git status *)", "Bash(git status)", "Bash(git log *)", "Bash(git diff *)", "Bash(git branch *)",
      "Bash(git worktree list *)", "Bash(git fetch *)", "Bash(gh pr view *)", "Bash(gh pr checks *)", "Bash(gh run list *)"
    ],
    "ask": [ "Bash(gh release *)", "Bash(gh api *)", "Bash(gh repo delete *)" ],
    "deny": [ "Edit(/.claude/hooks/**)", "Edit(/.claude/settings.json)", "Edit(/.githooks/**)", "Read(/.env)", "Read(/.env.*)" ]
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-git.sh" } ] },
      { "matcher": "Edit|Write|MultiEdit|NotebookEdit",
        "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-edit.sh" } ] }
    ],
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/session-start.sh" } ] }
    ]
  }
}
```

要点：
- 脚本一律用 stdin JSON 的 `cwd` 判断分支，`$CLAUDE_PROJECT_DIR` 只用来定位脚本自身。已实测：`claude -p --worktree x` 启动时 hook 里 `$CLAUDE_PROJECT_DIR` = worktree 根、`cwd` = worktree 根；会话中途 EnterWorktree 后 `$CLAUDE_PROJECT_DIR` 仍 = 主检出根（与官方 worktrees 文档 "Hook paths don't follow the worktree" 一致）、`cwd` = worktree 根。两种情况下用 `cwd` 判分支都正确。
- `permissions.deny` 的路径必须用 `/` 前缀：`/path` 相对 settings 文件所在的项目根（`//path` 才是绝对路径），而裸路径或 `./path` 相对**当前工作目录**解析。Claude 的 Bash `cd` 在会话内持久生效，一旦执行过 `cd src && …`，`./.claude/hooks/**` 就不再匹配 `<root>/.claude/hooks/*`，deny 会静默失效——而这组 deny 正是防止模型改护栏的层。
- 不用 `if` 预过滤（脚本自带 fast-path），不写 `timeout` 字段（默认即可）。阻止方式用已核实的 exit 2 + stderr。

`.claude/hooks/guard-git.sh`（本机 bash 3.2 实测 141 条用例全部符合预期。匹配前先把命令归一化：丢掉 `-m/--message/--title/--body/--notes/--grep` 引号里的消息文本（提交信息里提到 `--no-verify`、`git push --tags` 不再误拦）、拆掉包裹 refspec 的引号（`"HEAD:main"`）、折叠 `git -C <p>` / `-c k=v` / `--no-pager` 全局选项（`git -C x push` 等同 `git push`）、去掉 `refs/heads/` 前缀；受保护名两侧用明确边界（`;`、`|`、`)` 等都算结束）；R6 改为"当前在受保护分支时，每个 `git push` 的 refspec 必须全部是版本 tag"）：

```bash
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
```

回归矩阵里新增并通过的关键用例（feat worktree 上，期望 exit 2）：`git -C ../../git-cc push origin main`、`git -C . push --tags`、`git -C . tag -d v1.0.0`、`git --no-pager push --force origin feat/x`、`git push origin HEAD:refs/heads/main`、`git push origin refs/heads/main`、`git push origin feat/x:refs/heads/main`、`git push origin HEAD:main; echo done`、`git push origin "HEAD:main"`、`git push --force-with-lease=main origin`、`bash -c 'git push origin HEAD:main'`；main 上 `git push origin HEAD v1.0.0`、`git push`、`git switch -c feat/z`。期望 exit 0 的误拦回归：`git commit -m "fix: handle --no-verify flag"`、`git log --grep hooksPath`、`git commit -m "docs: mention git push --tags in guide"`、heredoc 多行提交信息、`gh pr create --title "feat: allow git push --tags in docs"`、`git push origin feat/main-page`。

`.claude/hooks/guard-edit.sh`（新目录中的新文件也会逐级向上找仓库判分支）：

```bash
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
```

`.claude/hooks/session-start.sh`（stdout 注入上下文；自修复 `core.hooksPath` 为**绝对路径**——相对路径会按各 worktree 自己的检出解析，旧分支没有 `.githooks/` 时 pre-push 会静默失效，已实测）：

```bash
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
```

`.githooks/pre-push`（对人和 Claude 都生效，所有 worktree 共享；允许首次创建 `release/*`，拒绝更新/删除受保护分支与删除 `v*` tag；已实测。注意 git 2.40 在 "Everything up-to-date"、没有 ref 需要更新时**仍会调用** pre-push，只是 stdin 为空，下面的 while 循环不执行、exit 0 自然放行；`git push --dry-run` 也会触发 pre-push）：

```bash
#!/usr/bin/env bash
# Emergency override (humans only): ALLOW_PROTECTED_PUSH=1 git push ...
[ "${ALLOW_PROTECTED_PUSH:-0}" = "1" ] && exit 0
zero=0000000000000000000000000000000000000000; status=0
while read -r local_ref local_sha remote_ref remote_sha; do
  case "$remote_ref" in
    refs/heads/main|refs/heads/master|refs/heads/release/*)
      if [ "$local_sha" = "$zero" ]; then echo "pre-push: refusing to DELETE $remote_ref" >&2; status=1
      elif [ "$remote_sha" != "$zero" ]; then echo "pre-push: refusing direct push to $remote_ref; open a PR (gh pr create)" >&2; status=1
      fi ;;
    refs/tags/v*)
      [ "$local_sha" = "$zero" ] && { echo "pre-push: refusing to delete release tag $remote_ref" >&2; status=1; } ;;
  esac
done
exit $status
```

hook 自测一行命令（升级 Claude Code 后回归用；**由人在终端执行**——命令文本本身含 `git push … HEAD:main`，Claude 会话内执行会被本 hook 的 R3 先拦下，这本身也是一次验证）：

```bash
jq -cn --arg c 'git push origin HEAD:main' --arg d "$PWD" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | bash .claude/hooks/guard-git.sh; echo "exit=$?"   # 期望 exit=2
```

### 5.4 自定义 skills（`.claude/skills/<name>/SKILL.md`，入库）

frontmatter 只用 `name`、`description`、`argument-hint`；`release` 与 `hotfix` 额外加 `disable-model-invocation: true`，只能由用户手动 `/release`、`/hotfix` 触发（本机版本对带此字段的 skill 走 Skill 工具会返回 "cannot be used with Skill tool due to disable-model-invocation"，模型无法替你执行）。`new-feature`、`spike` 只建 worktree、无破坏性，**不加**该字段，这样 Claude 被 hook 拦下时或在 /hotfix 流程里可以自行调用 `/new-feature`。`$ARGUMENTS` 会被替换为用户在 `/name` 后输入的全部文字（本机实测 `/echo-args foo bar` → `ARGS=[foo bar]`；`argument-hint`、`disable-model-invocation` 均在官方 frontmatter 字段表中）。刻意不用 `!`cmd`` 注入与 `$0/$1`，所有命令由 Claude 在会话里执行。

`.claude/skills/new-feature/SKILL.md`：

```markdown
---
name: new-feature
description: 从最新 origin/main 开 feat/<name>（或 fix/、chore/）分支并创建独立 worktree。用户说"开个分支做 X"、或当前在 main/release/* 上被 hook 拦下需要 worktree 时使用。
argument-hint: <name> [--fix|--chore]
---
参数：$ARGUMENTS（第一个词是名字；含 --fix 用 fix/，含 --chore 用 chore/，默认 feat/）。
1. 名字规范化为 kebab-case（[a-z0-9-]，≤ 40 字符）；`git fetch origin --prune`。
2. `git show-ref --verify --quiet refs/heads/<prefix>/<name>` 成功或目录已存在 → 停止并告知。
3. `root=$(git rev-parse --show-toplevel); git worktree add "$(dirname "$root")/$(basename "$root").wt/<name>" -b <prefix>/<name> origin/main`
4. 在新目录执行 `bash scripts/wt-setup.sh`（用 `cd <path> && bash scripts/wt-setup.sh`，这是 CLAUDE.md 允许的唯一跨 worktree 例外；脚本不存在则提示）。
5. 只输出三行：分支名；worktree 绝对路径；`cd <path> && claude -n <prefix>-<name>`。
禁止：在当前目录切分支；修改源码；在新 worktree 里开始写代码（那是新会话的事）。
```

`.claude/skills/release/SKILL.md`：

```markdown
---
name: release
description: 从 main（或 release/X.Y）打 rc / 正式 tag 并创建 GitHub Release。用户说"出 rc""把 rc 转正""发布 X.Y.Z"时使用。
argument-hint: <X.Y.Z-rc.N | promote X.Y.Z-rc.N | X.Y.Z> [--from release/X.Y]
disable-model-invocation: true
---
参数：$ARGUMENTS。先执行 `git fetch origin --tags --prune` 与 `git tag --list 'v*' --sort=-v:refname | head -10`。
模式：`X.Y.Z-rc.N` 在源分支 HEAD（默认 origin/main；--from 则 origin/release/X.Y）打 rc；`promote X.Y.Z-rc.N` 在
`git rev-parse "vX.Y.Z-rc.N^{commit}"` 的**同一 commit** 打 vX.Y.Z（不允许换 commit）；`X.Y.Z` 直接打正式 tag，仅当用户明确不要 rc。
前置校验（任一失败即停止并说明）：
- 目标 tag 不存在；版本大于同线上一个 tag；--from 维护线只允许 PATCH；工作区干净。
- 源 commit CI 绿：`gh run list --commit <sha> --workflow ci --limit 1 --json conclusion`。
- MAJOR 递增 → 先提示用户从上一大版本最后正式 tag 建维护线（/hotfix 会创建），确认后再继续。
- --from 维护线：`git log --cherry-pick --right-only --no-merges --oneline origin/main...origin/release/X.Y` 非空则列出并提醒
  这些修复尚未前移到 main（提交信息含 `Forward-ported:` 的可忽略），由用户决定是否继续。
- 用 `git log --pretty='- %s (%h)' <上一正式tag>..<commit>` 生成草稿；出现 `!`/BREAKING 但没升 MAJOR，或有 feat 却只升 PATCH → 指出。
执行：`git tag -a v<ver> <commit> -m "v<ver>"` → `git push origin v<ver>`（只推这一个 tag）→
rc：`gh release create v<ver> --verify-tag --prerelease --generate-notes --title "v<ver>"`；
正式：`gh release create v<ver> --verify-tag --generate-notes --title "v<ver>" --notes-start-tag <上一正式tag>`（--from 时加 `--latest=false`）。
输出 tag、commit、Release URL、`gh run list --workflow deploy --limit 3`。禁止：移动/删除 tag；在 main 上 commit；任何 --force。
```

`.claude/skills/hotfix/SKILL.md`：

```markdown
---
name: hotfix
description: 为已发布版本线 X.Y 开热修：必要时从正式 tag 创建 release/X.Y，建 hotfix worktree，按 fix-forward cherry-pick。用户说"线上 1.4 有 bug"时使用。
argument-hint: <X.Y> <desc> [--pick <sha-on-main>]
disable-model-invocation: true
---
参数：$ARGUMENTS。先 `git fetch origin --tags --prune` 与 `git ls-remote --heads origin 'release/*'`。
1. 基线 = 该线最新**正式** tag vX.Y.P（忽略 rc）。远端无 release/X.Y 时通过 API 创建（不经本地 push，不触发护栏；会弹权限确认）：
   `gh api -X POST repos/{owner}/{repo}/git/refs -f ref=refs/heads/release/X.Y -f sha=$(git rev-parse "vX.Y.P^{commit}")`，然后 `git fetch origin`。
2. `root=$(git rev-parse --show-toplevel); git worktree add "$(dirname "$root")/$(basename "$root").wt/hotfix-X.Y.(P+1)" -b hotfix/X.Y.(P+1)-<desc> origin/release/X.Y`，
   `cd` 进去执行 `bash scripts/wt-setup.sh`（CLAUDE.md 允许的例外），并写一份不入库的 CLAUDE.local.md："本线只修 bug；修完必须 cherry-pick -x 到 main 及其他仍支持的 release/*"。
3. 修复策略（说明选了哪种）：默认 fix-forward——bug 在 main 也存在 → 先调用 /new-feature <desc> --fix 建好 fix worktree，然后**停下**，
   请用户在那个 worktree 里新开会话修好并走 PR squash 合入 main；用户给出 squash sha 后，再回到 hotfix 分支 `git cherry-pick -x <squash-sha>`。
   仅旧版本才有的 bug → 直接在 hotfix 分支修，事后前移到 main 时提交信息加 `Forward-ported: <sha>`。给了 --pick <sha> 就直接 cherry-pick -x。
4. 在 hotfix worktree 跑测试、/code-review，`gh pr create --base release/X.Y --fill --label hotfix`。
5. 传播清单：列出所有其他仍支持的 origin/release/*，提醒逐条 cherry-pick -x；合入后提示 `/release X.Y.(P+1) --from release/X.Y`。
禁止：在 release/X.Y 上直接 commit / cherry-pick / push。
```

`.claude/skills/spike/SKILL.md`：

```markdown
---
name: spike
description: 开一次性实验 worktree（spike/<idea>）验证想法：记录假设、成功标准、截止日期；永不合并。
argument-hint: <idea> "<一句话假设>"
---
参数：$ARGUMENTS。1. `git fetch origin && git worktree add .claude/worktrees/spike-<idea> -b spike/<idea> origin/main`
2. 在该目录写 SPIKE.md：假设、成功标准、截止日期（默认 2 天）、结论（留空）。
3. 告诉用户：`cd .claude/worktrees/spike-<idea> && claude -n spike-<idea>`；代码可以脏；禁止 gh pr create（CI 也会拒）。
4. 结束二选一：失败 → `git worktree remove --force .claude/worktrees/spike-<idea> && git branch -D spike/<idea>`；成功 → 结论写进 issue，`/new-feature <idea>` 干净实现。
```

### 5.5 合并前清单

```
写代码 → rebase origin/main → 测试 → /code-review（大改动 high / ultra）→ 敏感改动 /security-review
→ gh pr create --label → CI → 主检出会话 /code-review <PR#> --comment（第二双眼）→ gh pr merge --squash --delete-branch
```

- `/code-review` 在功能 worktree 里审当前 diff，`--fix` 直接应用修复；PR 打开后在主检出会话 `/code-review 42 --comment` 写行内评论；超大改动 `/code-review ultra`（云端多代理；`claude ultrareview [options] [target]` 也在 `claude --help` 的 Commands 列表里，已确认，是同一能力的命令行入口）。
- `/security-review` 审当前分支待合并改动，涉及认证、权限、输入处理、依赖升级、外部调用、文件/命令执行必跑。
- 若 ruleset 开了 `required_review_thread_resolution`，`--comment` 留下的线程需在 PR 页 resolve 才能合并；本方案单人仓库设为 false。

## 6. 从零初始化

以下命令由人在终端执行（zsh 或 bash 都可：已避免依赖 bash 的 `set -- $var` 分词，zsh 默认不分词）。

```bash
cd ~/workspace/git-cc && gh auth status
git init -b main && git config pull.ff only
cat > .gitignore <<'EOF'
node_modules/
dist/
.env
.env.*
!.env.example
.claude/settings.local.json
.claude/worktrees/
CLAUDE.local.md
.DS_Store
EOF
printf '.env\n.env.local\nCLAUDE.local.md\n' > .worktreeinclude; cp /dev/null .env.example
mkdir -p .claude/hooks .claude/skills/{new-feature,release,hotfix,spike} .githooks .github/{workflows,rulesets} scripts
#  -> 写入 CLAUDE.md、.claude/settings.json、.claude/hooks/*.sh、.githooks/pre-push、.claude/skills/*/SKILL.md、
#     scripts/wt-setup.sh、.github/workflows/{ci,deploy}.yml、.github/release.yml、.github/rulesets/*.json（附录）
chmod +x .claude/hooks/*.sh .githooks/pre-push scripts/wt-setup.sh
git config core.hooksPath "$PWD/.githooks"
git add -A && git commit -m "chore: bootstrap repository with trunk-based workflow"   # 唯一一次直接提交 main
git tag -a v0.1.0 -m "v0.1.0: bootstrap"

# 远端：public 才有 ruleset 与 Environments（Free 套餐私有仓库对 ruleset/branch protection API 返回 403，评委实测；
#       Environments/required reviewers 同样仅 public 仓库可配）；私有则只剩 hook + pre-push，见 §8
gh repo create git-cc --public --source=. --remote=origin --push          # 首次推 main 是"创建"，pre-push 放行
git remote set-head origin -a       # 让 origin/HEAD 存在（建议而非硬依赖：缺失时 claude --worktree 会按 origin/main → origin/master 猜）
git push origin v0.1.0 && gh release create v0.1.0 --verify-tag --title "v0.1.0" --notes "Bootstrap."
gh repo edit --default-branch main --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false \
  --delete-branch-on-merge --allow-update-branch --enable-auto-merge --squash-merge-commit-message pr-title-description
while read -r n c; do gh label create "$n" --color "$c" --force; done <<'EOF'   # 用 read 分词，zsh 下 `set -- $l` 不会拆开
feat 0E8A16
fix D73A4A
hotfix B60205
breaking 000000
chore CFD3D7
skip-changelog EEEEEE
EOF
for f in main release tags; do gh api -X POST repos/{owner}/{repo}/rulesets --input .github/rulesets/$f.json; done
gh ruleset list && gh ruleset check main     # ruleset 引用的 ci / promotion-guard 两个 check 在第一个 PR 跑过后才会出现在 GitHub 上，属正常

# 验证护栏
claude                       # 接受信任对话框；会话里 /hooks 应列出 3 个 hook；让它 `git commit` 应被拦
# 下面两条由人在终端执行（Claude 会话内执行会被 guard-git 自己拦下：R6 看到 `git commit`、pre-push 一行看到 `HEAD:main`）
jq -cn --arg c 'git commit -m x' --arg d "$PWD" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | bash .claude/hooks/guard-git.sh; echo "exit=$?"   # 期望 exit=2
git push --dry-run origin HEAD:main   # 应被 pre-push 拒绝（--dry-run 同样触发 pre-push）
mkdir -p ../git-cc.wt && git worktree add ../git-cc.wt/hello -b feat/hello origin/main && cd ../git-cc.wt/hello && bash scripts/wt-setup.sh && claude
```

附录文件（放在对应路径）：

`.github/rulesets/main.json`（`release.json` 把 `name` 改为 `protect-release`、`include` 改为 `["refs/heads/release/*"]`）：

```json
{ "name": "protect-main", "target": "branch", "enforcement": "active", "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [ { "type": "deletion" }, { "type": "non_fast_forward" }, { "type": "required_linear_history" },
    { "type": "pull_request", "parameters": { "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false,
        "allowed_merge_methods": ["squash"] } },
    { "type": "required_status_checks", "parameters": { "strict_required_status_checks_policy": true,
        "required_status_checks": [ { "context": "ci" }, { "context": "promotion-guard" } ] } } ] }
```

`.github/rulesets/tags.json`（`update` 是 GitHub REST ruleset 规则类型列表中的合法类型；tag ruleset 支持 Restrict creations/updates/deletions 与 Block force pushes，三条规则一起即"tag 不可删、不可移动"）：

```json
{ "name": "protect-version-tags", "target": "tag", "enforcement": "active", "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [ { "type": "deletion" }, { "type": "non_fast_forward" }, { "type": "update" } ] }
```

`.github/workflows/ci.yml`（job 名必须与 ruleset 的 `context` 一致；npm 步骤按技术栈改。仓库刚初始化时没有 `package-lock.json`，所以 setup-node 与 npm 步骤都挂 `hashFiles` 条件、否则走占位步骤，保证空仓库也能绿——不然 `setup-node` 的 `cache: npm` 会直接报 `Dependencies lock file is not found`，`ci` 必红；而 ruleset 把 `ci` 设为必需且 `bypass_actors: []`、hook 又禁止 `--admin`，第一个 PR（含上面的 `feat/hello`）就永远合不进去）：

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main, 'release/**']
jobs:
  ci:
    name: ci
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - if: hashFiles('package-lock.json') != ''
        uses: actions/setup-node@v4
        with: { node-version: 22, cache: npm }
      - if: hashFiles('package-lock.json') != ''
        run: npm ci && npm run lint --if-present && npm test && npm run build --if-present   # 按技术栈改
      - if: hashFiles('package-lock.json') == ''
        run: echo "no package-lock.json yet; ci is a no-op until the stack lands"
  promotion-guard:
    name: promotion-guard
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - env: { BASE: "${{ github.base_ref }}", HEAD: "${{ github.head_ref }}" }
        run: |
          case "$HEAD" in spike/*|worktree-*) echo "spike/* and worktree-* are never merged; re-implement on feat/*"; exit 1;; esac
          case "$BASE" in
            release/*) [[ "$HEAD" == hotfix/* ]] || { echo "release/* only accepts hotfix/* (got $HEAD)"; exit 1; } ;;
            main) [[ "$HEAD" =~ ^(feat|fix|chore|docs|refactor|test|perf|ci|build|revert)/ ]] || { echo "bad head branch name: $HEAD"; exit 1; } ;;
          esac
```

`.github/workflows/deploy.yml`（staging 只认 rc tag；prod 绑定 GitHub Environment，在仓库 Settings → Environments 给 `production` 配 required reviewers。Environments 仅 public 仓库或 Pro/Team 可配，Free 私有仓库下 `environment: production` 不会形成审批门，见 §8）：

```yaml
name: deploy
on: { push: { branches: [main], tags: ['v*'] } }
jobs:
  dev:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps: [ { run: "echo deploy dev from ${{ github.sha }}   # 可选，没有 dev 环境就删掉这个 job" } ]
  staging:
    if: startsWith(github.ref, 'refs/tags/v') && contains(github.ref_name, '-rc.')
    runs-on: ubuntu-latest
    environment: staging
    steps: [ { run: "echo deploy staging from ${{ github.ref_name }}" } ]
  production:
    if: startsWith(github.ref, 'refs/tags/v') && !contains(github.ref_name, '-rc.')
    runs-on: ubuntu-latest
    environment: production
    steps: [ { run: "echo deploy production from ${{ github.ref_name }}   # 替换为真实部署命令" } ]
```

`.github/release.yml`：

```yaml
changelog:
  exclude: { labels: [skip-changelog] }
  categories:
    - { title: Breaking Changes, labels: [breaking] }
    - { title: Features, labels: [feat] }
    - { title: Fixes, labels: [fix, hotfix] }
    - { title: Other, labels: ["*"] }
```

## 7. 日常流程速查

**功能**（主检出会话 → 新终端）

```bash
/new-feature checkout-coupon                      # 主检出会话；得到 ../git-cc.wt/checkout-coupon
cd ~/workspace/git-cc.wt/checkout-coupon && claude -n feat-checkout-coupon
git fetch origin && git rebase origin/main && npm test
/code-review                                      # 涉及支付/认证再 /security-review
gh pr create --base main --fill --label feat && gh pr checks --watch
gh pr merge --squash --delete-branch              # 或 --auto 让 GitHub 排队；多 PR 排队用 gh pr update-branch <n>
cd ~/workspace/git-cc && git pull --ff-only && git worktree remove ../git-cc.wt/checkout-coupon && git branch -D feat/checkout-coupon
```

**实验**

```bash
cd ~/workspace/git-cc && claude --worktree try-redis      # 或 /spike try-redis "缓存命中率能到 90%"
git diff origin/main --stat                               # 看看改了什么，作为重写参考
git worktree unlock .claude/worktrees/try-redis 2>/dev/null; git worktree remove --force .claude/worktrees/try-redis; git branch -D worktree-try-redis
/new-feature redis-cache                                  # 成功了就干净重写
```

**发布**（主检出会话，`git pull --ff-only` 之后）

```bash
/release 1.5.0-rc.1                       # tag + prerelease → deploy(staging)；QA 在 staging 验证
/release 1.5.0-rc.2                       # 发现问题：fix/* PR 合入 main 后再打一个 rc
/release promote 1.5.0-rc.2               # 同一 commit 打 v1.5.0 → deploy(production)，环境审批后上线
gh release view v1.5.0 && gh run list --workflow deploy --limit 3
```

**热修**（线上 1.4.x 报 bug，main 已是 1.5）

```bash
/hotfix 1.4 null-price                    # 无 release/1.4 则从 v1.4.2 创建；worktree ../git-cc.wt/hotfix-1.4.3
/new-feature null-price --fix             # fix-forward：先在 main 修好 → PR → squash 合入 → 拿到 sha（/hotfix 第 3 步会替你调用并停下等这一步）
cd ~/workspace/git-cc.wt/hotfix-1.4.3 && claude -n hotfix-1.4.3
git cherry-pick -x <sha> && npm test      # /code-review
gh pr create --base release/1.4 --fill --label hotfix && gh pr checks --watch && gh pr merge --squash --delete-branch
/release 1.4.3 --from release/1.4         # v1.4.3 → production（1.4 线），Release 带 --latest=false
```

**维护旧版本**（人在终端执行，或在对应 worktree 自己的 Claude 会话里做——不要让主检出会话 `cd`/`git -C` 过去）

```bash
git worktree add ../git-cc.wt/release-1.4 release/1.4     # 常驻 worktree，只看代码/打 tag，不在这里 commit
printf '# 1.4 维护线\n- 只修 bug；修完必须 cherry-pick -x 到 main。\n' > ../git-cc.wt/release-1.4/CLAUDE.local.md
git log --cherry-pick --right-only --no-merges --oneline origin/main...origin/release/1.4   # 未前移的修复
# 同步护栏到旧线：hotfix 分支 + PR（promotion-guard 只放行 hotfix/* 进 release/*）
git worktree add ../git-cc.wt/sync-guard-1.4 -b hotfix/1.4.4-sync-guardrails origin/release/1.4
cd ../git-cc.wt/sync-guard-1.4 && git checkout origin/main -- CLAUDE.md .claude/ .githooks/ scripts/ \
  && git commit -m 'chore: sync guardrails from main' && gh pr create --base release/1.4 --fill --label chore
gh pr checks --watch && gh pr merge --squash --delete-branch && cd ~/workspace/git-cc
/release 1.4.4 --from release/1.4         # 主检出会话；等价于 gh release create v1.4.4 --verify-tag --generate-notes --latest=false --notes-start-tag v1.4.3
```

## 8. 注意事项与坑

- **worktree 与 node_modules / .env / 构建产物**：都是 gitignored，新 worktree 里一律没有。手工 worktree 跑 `scripts/wt-setup.sh`，`claude --worktree` 靠 `.worktreeinclude`，SessionStart 再兜底复制 `.env`。不要 symlink `node_modules`（原生模块与锁文件不一致会炸），磁盘紧张换 pnpm。`dist/`、`.next/` 各自独立；dev server 端口由脚本按路径 hash 分配。
- **每个 worktree 单独安装依赖**：SessionStart 不自动 `npm ci`（大依赖树会撞 hook 超时并留下半装的 node_modules），只提示；由 wt-setup.sh 显式安装。
- **CLAUDE.md / settings / hooks / skills 随分支走**：每个 worktree 看到的是自己分支上的版本。规则改动单独开小 PR 优先合入 main；feat 分支 `git rebase origin/main` 即可拿到；`release/X.Y` 不能 rebase，用"维护旧版本"里的 hotfix PR 同步。分支特有规则放不入库的 `CLAUDE.local.md`。
- **settings.local.json 跨 worktree 共享**：`.claude/settings.json`（hooks、permissions、`worktree.baseRef`）从当前 worktree 自己的检出读取（已实测：worktree 检出里没有 hooks 时 hook 不触发）；`.claude/settings.local.json` 则统一位于**主检出根目录**——在任意 worktree（`--worktree`、`git worktree add`、EnterWorktree、桌面端）会话里选 "Yes, and don't ask again"，规则都写到那里，并对主检出与所有 linked worktree 生效（v2.1.211+；本机实测主检出 settings.local.json 里的 SessionStart hook 在 `git worktree add` 的 worktree 与 `claude -p --worktree` 会话中都触发），worktree 删除也不会丢。所以新 worktree 不会额外弹权限窗，也不要在各 worktree 各放一份（worktree 内自己的 settings.local.json 只作为 legacy overlay 叠加读取）。Claude Code 首次写该文件时会把 `**/.claude/settings.local.json` 加进全局 git excludes。护栏与 `worktree.baseRef` 仍必须放入库的 `settings.json`，这一结论不变。
- **同一分支不能开两个 worktree**：`fatal: 'main' is already checked out`。主检出独占 main；合并靠 `gh pr merge` 在远端完成再 `git pull --ff-only`。手动 `rm -rf` 了目录要 `git worktree prune`。
- **hooks 在 worktree 中的生效条件**：worktree 是完整检出，hooks/settings 从该 worktree 的 `.claude/` 读取（已核实）；脚本要 `chmod +x`（git 跟踪可执行位）；`--bare` 会跳过 hooks，不要用它开发；hooks 只拦 Claude 的工具调用，人类靠 pre-push，服务端靠 ruleset。`core.hooksPath` 必须是绝对路径（见 5.3）。hook 命令里 `$CLAUDE_PROJECT_DIR` 的指向：`claude --worktree` 启动 = worktree 根；会话中途 EnterWorktree = 仍是主检出根（hook 路径不随 worktree 走）；stdin `cwd` 两种情况都是 worktree 根，所以判分支只信 `cwd`。
- **`claude --worktree` 细节**：分支固定叫 `worktree-<name>`，所以只用于 spike；要转正 `git branch -m worktree-x feat/x`。退出规则（官方文档）：交互式会话退出时，工作区干净且会话未命名 → 自动删除 worktree 与分支；命名会话（`-n`）→ 询问是否删除；有未提交改动 → 询问保留还是删除。`claude -p --worktree` 不做任何清理并保留锁（`git worktree list --porcelain` 显示 `locked claude session <name>`），直到后续会话清扫 stale lock；手动清理前先 `git worktree unlock`。`.claude/worktrees/` 必须 gitignore。`worktree.baseRef=fresh` 的基线解析：`origin/HEAD` → `origin/main` → `origin/master` → 兜底名 `main`，随后 `git fetch origin <branch>`（近 24h 内 fetch 过则跳过），只有 fetch 失败才退回本地 HEAD；本机在未设 origin/HEAD 的仓库上 `claude -p --worktree ptest` 照常基于 origin/main 创建成功。建议初始化时 `git remote set-head origin -a` 以保证确定性，但不是硬依赖（远端 HEAD 无效时该命令会报 `Cannot determine remote HEAD`，GitHub 上正常）。
- **git 语义**：`git stash`、refs、tags、config 全仓库共享，HEAD/index/工作区每 worktree 独立——CLAUDE.md 已禁 stash，用 WIP commit 代替（squash 后无痕）。squash 合并后本地分支 `git branch -d` 会拒绝，用 `-D`。
- **GitHub 套餐**：Free 私有仓库无 ruleset（评委实测 403），此时 `required_status_checks`、`allowed_merge_methods` 全部落空，只剩 hook + pre-push + CI 信息性检查。Free 私有仓库同样不能配置 Environments/required reviewers（GitHub 文档：Free 只能为 public 仓库配置环境），`deploy.yml` 里 `environment: production` 的人工审批门也会静默失效，`/release promote` 打正式 tag 会直接触发 prod job。要么 public，要么 Pro/Team，要么把 prod job 改成 `on: workflow_dispatch` + 手动触发来替代审批。`bypass_actors: []` 意味着管理员也必须走 PR；紧急时 `gh api -X PUT repos/{owner}/{repo}/rulesets/<id> -f enforcement=disabled`，事后改回。
- **权限 deny 的副作用**：`Read(/.env)` 被拒后 Claude 无法诊断 .env 相关问题，需要人贴出相关行；`gh api`/`gh release` 在 ask 列表里，/hotfix 创建 release 分支、/release 建 Release 时会弹确认，这是刻意的。deny 路径一律 `/` 前缀（相对项目根），`./` 会随 Claude 的 `cd` 漂移而失效（见 5.3）。
- **护栏是护栏不是安全边界**：guard-git 匹配前会归一化命令（去引号、折叠 `git -C/-c/--no-pager`、去 `refs/heads/`、丢弃 `-m/--title` 等消息文本），`git -C <path> push`、`refs/heads/main`、`"HEAD:main"`、`bash -c '…'` 里的 git 都已覆盖；已知绕过：变量拼接（`r=main; git push origin HEAD:$r`）、先写进脚本文件再执行、`-m` 消息文本里的内容不检查（有意为之，避免误拦）。真正的强制是 pre-push（本地）与 ruleset（服务端）。

## 9. 可选进阶

- **CI 自动化**：`gh pr merge --auto --squash` + `--allow-update-branch` 让多 PR 自动排队；每日定时 workflow 跑 `git log --cherry-pick --right-only origin/main...origin/release/*` 报告未前移修复；`git-cliff` 生成 `CHANGELOG.md` 文件（`brew install git-cliff && git cliff --tag v1.5.0 -o CHANGELOG.md`）。
- **feature flag**：仅当一个改动确实无法拆成 ≤ 2 天的 PR 时使用；`FLAG_<NAME>` 默认关闭，staging 通过环境变量打开验证，建 issue 跟踪删除。
- **preview 环境**：在 `ci.yml` 里给每个 PR 部署临时 URL（Vercel/Netlify/Cloudflare Pages 都有现成 action），QA 可在合并前验证；配合 statusline 显示 `workspace.git_worktree` / `worktree.branch`，多终端并行时一眼看出当前会话在哪条分支。
- **子代理隔离**：自定义子代理 frontmatter 加 `isolation: worktree`，让 Claude 派出的子代理在临时 worktree 里跑测试/重构，不污染当前分支。