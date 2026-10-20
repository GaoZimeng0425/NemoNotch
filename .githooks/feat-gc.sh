#!/bin/sh
# git feat-gc — 清理已合并进 develop 的本地 feature/* 与 hotfix/* 分支。
# feat-done 的正常流程会在合并后删分支;这里收拾自动化之前或中途中止留下的
# 化石(2026-10-20 盘点时主检出有 7 条)。
#
# 安全边界:只用 git branch -d(未合并的 git 自己拒删);有 worktree 在用的
# 跳过并说明;未合并的只列出不动,留给人逐条判断。可随时重跑,幂等。
set -e

main_wt=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
cd "$main_wt"

# 已安装副本过期自检(见 .githooks/freshness.sh)
if [ -f "$main_wt/.githooks/freshness.sh" ]; then
  . "$main_wt/.githooks/freshness.sh"
  nemonotch_check_fresh "$main_wt" || exit 1
fi

if ! git show-ref --verify --quiet refs/heads/develop; then
  echo "✋ 本地没有 develop 分支。" >&2
  exit 1
fi

# 被某个 worktree 检出的分支:git 本来就拒删,先过滤掉免得报错刷屏。
# 刚建还没提交的 feature 分支与 develop 同指针,会被 --merged 列出 — 正是靠这层过滤保住。
# porcelain 输出按行分隔,拼成空格分隔才能用 case 模式匹配(2026-10-20 首跑实测漏过滤)。
in_use=$(git worktree list --porcelain | awk '/^branch /{sub("refs/heads/","",$2); print $2}' | tr '\n' ' ')

deleted=0
for b in $(git branch --format='%(refname:short)' --merged develop | grep -E '^(feature|hotfix)/' || true); do
  case " $in_use " in
    *" $b "*) echo "⏭  $b 有 worktree 在用,跳过"; continue ;;
  esac
  git branch -d "$b"
  deleted=$((deleted + 1))
done
echo "🧹 已删除 $deleted 个已合并进 develop 的本地分支"

unmerged=$(git branch --format='%(refname:short)' --no-merged develop | grep -E '^(feature|hotfix)/' || true)
if [ -n "$unmerged" ]; then
  echo ""
  echo "⚠️  以下分支未合并进 develop,未动 — 逐条看值不值得救(确不要了: git branch -D <name>):"
  for b in $unmerged; do
    echo "   $b  ($(git log -1 --format='%ad %s' --date=short "$b"))"
  done
fi
