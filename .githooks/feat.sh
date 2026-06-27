#!/bin/sh
# git feat <name> — start a feature in its own worktree.
# Creates feature/<name> off origin/develop (fallback: local develop) and adds
# a sibling worktree at ../<repo>-worktrees/<name> so you can work on several
# features at once without switching branches in the main checkout.
set -e

name="$1"
if [ -z "$name" ]; then
  echo "usage: git feat <name>" >&2
  exit 1
fi

main_wt=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
repo=$(basename "$main_wt")
parent=$(dirname "$main_wt")
wt="$parent/${repo}-worktrees/$name"
branch="feature/$name"

if git -C "$main_wt" show-ref --verify --quiet "refs/heads/$branch"; then
  echo "✋ 分支 $branch 已存在。" >&2
  exit 1
fi

if ! git -C "$main_wt" show-ref --verify --quiet refs/heads/develop; then
  echo "✋ 本地没有 develop 分支。" >&2
  exit 1
fi

# Warn (don't block) if local develop is behind origin/develop.
git -C "$main_wt" fetch origin develop --quiet 2>/dev/null || true
if git -C "$main_wt" show-ref --verify --quiet refs/remotes/origin/develop; then
  behind=$(git -C "$main_wt" rev-list --count develop..origin/develop 2>/dev/null || echo 0)
  if [ "${behind:-0}" -gt 0 ]; then
    echo "⚠️  本地 develop 落后 origin/develop $behind 个提交;建议先在 develop 上 git pull。" >&2
  fi
fi

git -C "$main_wt" worktree add -b "$branch" "$wt" develop
echo ""
echo "✅ $branch  @  $wt   (off develop)"
echo "   下一步:  cd \"$wt\""
echo "   完成后:  git feat-done $name"
