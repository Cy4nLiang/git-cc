# git-cc

沙盒仓库：操练 Trunk-based + Tag Release 的 git 版本隔离。不要把这套流程直接套到 amazon-prd。

环境：macOS · Claude Code · git 2.40 · gh。主检出永远停在 `main`。

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
