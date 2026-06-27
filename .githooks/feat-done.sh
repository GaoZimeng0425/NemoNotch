#!/bin/sh
# git feat-done <name> — merge feature/<name> back into develop (--no-ff) and
# tear down its worktree. Run it from anywhere in the repo.
set -e

name="$1"
if [ -z "$name" ]; then
  echo "usage: git feat-done <name>" >&2
  exit 1
fi

branch="feature/$name"
main_wt=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')

if ! git -C "$main_wt" show-ref --verify --quiet "refs/heads/$branch"; then
  echo "✋ 找不到分支 $branch。" >&2
  exit 1
fi

# Locate the worktree checked out on this branch (if any).
wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '
  /^worktree /{p=$2} /^branch /{ if ($2==b) print p }')

git -C "$main_wt" checkout develop
git -C "$main_wt" merge --no-ff "$branch" -m "Merge $branch into develop"
echo "✅ merged $branch → develop (--no-ff)"

here=$(pwd -P)
if [ -n "$wt" ]; then
  case "$here" in
    "$wt"|"$wt"/*)
      echo "⚠️  你正站在该 worktree 里,无法自删。请执行:" >&2
      echo "    cd \"$main_wt\" && git worktree remove \"$wt\" && git branch -d $branch" >&2 ;;
    *)
      git worktree remove "$wt"
      git -C "$main_wt" branch -d "$branch"
      echo "🧹 worktree 已移除,分支已删除" ;;
  esac
fi

echo "   记得推送:  git -C \"$main_wt\" push origin develop"
