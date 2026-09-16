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
