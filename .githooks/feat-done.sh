#!/bin/sh
# git feat-done <name> — merge feature/<name> back into develop (--no-ff) and
# tear down its worktree. Run it from anywhere in the repo.
#
# 流程:测试门禁(worktree 内跑单测,不过就中止)→ 自动 stash/恢复主检出的
# 未提交改动(以前手动做了七轮的舞步)→ checkout develop → merge(触发
# post-merge 自动构建)→ stash pop → 拆 worktree。
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

# ── 测试门禁:merge 前在 feature worktree 里跑单元测试 ──
# 合并=自动部署到 /Applications,测试必须在部署之前。无 Swift/pbxproj 改动跳过
# (pbxproj 在触发集里:INFOPLIST_KEY_* 等编译面改动不是"纯文档");
# 逃生口:NEMONOTCH_SKIP_TESTS=1(与 NEMONOTCH_HOOK_DEBUG 同款应急约定)。
if [ "${NEMONOTCH_SKIP_TESTS:-0}" = "1" ]; then
  echo "⏭  NEMONOTCH_SKIP_TESTS=1 — 跳过测试门禁" >&2
elif [ -n "$wt" ] && [ -f "$wt/scripts/test.sh" ]; then
  base=$(git -C "$main_wt" merge-base develop "$branch")
  # 不接 | head 之类管道:管道会吃掉 git diff 的退出码,把"检测出错"降级成
  # "无 Swift 改动"的 fail-open;保持裸命令让 set -e 兜成 fail-closed。
  swift_changes=$(git -C "$wt" diff --name-only "$base...HEAD" -- '*.swift' '*.xcodeproj/project.pbxproj')
  if [ -z "$swift_changes" ]; then
    echo "📄 本 feature 无 Swift/pbxproj 改动 — 跳过测试门禁" >&2
  else
    if [ -n "$(git -C "$wt" status --porcelain)" ]; then
      echo "⚠️  worktree 有未提交改动 — 门禁测的是「已提交+未提交」混合态,合并只带走已提交部分" >&2
    fi
    echo "🧪 测试门禁:在 worktree 跑单元测试…"
    if ! sh "$wt/scripts/test.sh"; then
      echo "" >&2
      echo "❌ 测试未过 — 中止合并,worktree 与分支原样保留。" >&2
      echo "   修复后重试 git feat-done $name;应急跳过:NEMONOTCH_SKIP_TESTS=1 git feat-done $name" >&2
      exit 1
    fi
  fi
else
  echo "⚠️  分支没有 worktree 或缺 scripts/test.sh — 跳过测试门禁,请自行确保测试通过" >&2
fi

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
