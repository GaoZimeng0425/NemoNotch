#!/bin/sh
# git feat-done <name> — merge feature/<name> back into develop (--no-ff) and
# tear down its worktree. Run it from anywhere in the repo.
#
# 合并前后自动 stash/恢复主检出的未提交改动(以前手动做了七轮的舞步):
# stash → checkout develop → merge(触发 post-merge 自动构建)→ stash pop。
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

# ── 自动 stash 舞步:主检出脏了不挡路,合并完原样恢复 ──
stash_created=0
if ! git -C "$main_wt" diff --quiet 2>/dev/null || ! git -C "$main_wt" diff --cached --quiet 2>/dev/null; then
  echo "📦 主检出有未提交改动 — 自动 stash,合并后恢复"
  git -C "$main_wt" stash push -m "feat-done auto-stash ($branch)"
  stash_created=1
fi

merge_ok=0
if git -C "$main_wt" checkout develop && git -C "$main_wt" merge --no-ff "$branch" -m "Merge $branch into develop"; then
  merge_ok=1
  echo "✅ merged $branch → develop (--no-ff)"
fi

# stash 恢复无条件尝试 —— merge/构建失败也不能吞掉用户的暂存改动。
if [ "$stash_created" = 1 ]; then
  echo "📦 恢复主检出 stash..."
  if ! git -C "$main_wt" stash pop; then
    # pop 冲突时工作区是半应用状态(冲突标记 + 部分文件已暂存),留着比冲突本身更迷惑:
    # 退回干净树;pop 失败时 stash 条目本就被保留,内容一点不丢。
    git -C "$main_wt" reset --hard HEAD -q
    echo "" >&2
    echo "⚠️  stash pop 冲突,已还原为干净工作区 — 你的改动完整保留在 stash@{0} 里。" >&2
    echo "    稍后手动恢复:git -C \"$main_wt\" stash pop  然后解冲突(通常是把文档增量重放到新版本上)" >&2
    echo "    查看:git -C \"$main_wt\" stash show -p" >&2
  fi
fi

if [ "$merge_ok" != 1 ]; then
  echo "❌ merge 失败(见上)— worktree 与分支保留,修复后重试 git feat-done $name" >&2
  exit 1
fi

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
