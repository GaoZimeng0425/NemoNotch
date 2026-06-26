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

git -C "$main_wt" fetch origin develop --quiet 2>/dev/null || true
base=develop
if git -C "$main_wt" show-ref --verify --quiet refs/remotes/origin/develop; then
  base=origin/develop
fi

git -C "$main_wt" worktree add -b "$branch" "$wt" "$base"
echo ""
echo "✅ $branch  @  $wt   (off $base)"
echo "   下一步:  cd \"$wt\""
echo "   完成后:  git feat-done $name"
