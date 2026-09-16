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
