#!/usr/bin/env bash
set -euo pipefail
root="$(git rev-parse --show-toplevel)"; main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
cd "$root"
for f in .env .env.local CLAUDE.local.md; do [ -f "$main/$f" ] && [ ! -f "$f" ] && cp "$main/$f" "$f"; done   # 1. 本地配置
port=$((3000 + $(printf '%s' "$root" | cksum | cut -d' ' -f1) % 1000))                                        # 2. 独立端口
grep -q '^PORT=' .env 2>/dev/null && sed -i '' "s/^PORT=.*/PORT=$port/" .env || echo "PORT=$port" >> .env
[ -f package-lock.json ] && npm ci --no-audit --no-fund                                                        # 3. 依赖
echo "worktree ready: $root (PORT=$port)"
