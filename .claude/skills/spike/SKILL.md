---
name: spike
description: 开一次性实验 worktree（spike/<idea>）验证想法：记录假设、成功标准、截止日期；永不合并。
argument-hint: <idea> "<一句话假设>"
---
参数：$ARGUMENTS。1. `git fetch origin && git worktree add .claude/worktrees/spike-<idea> -b spike/<idea> origin/main`
2. 在该目录写 SPIKE.md：假设、成功标准、截止日期（默认 2 天）、结论（留空）。
3. 告诉用户：`cd .claude/worktrees/spike-<idea> && claude -n spike-<idea>`；代码可以脏；禁止 gh pr create（CI 也会拒）。
4. 结束二选一：失败 → `git worktree remove --force .claude/worktrees/spike-<idea> && git branch -D spike/<idea>`；成功 → 结论写进 issue，`/new-feature <idea>` 干净实现。
