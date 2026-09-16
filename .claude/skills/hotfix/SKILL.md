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
