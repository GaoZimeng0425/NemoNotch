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

# 已安装副本过期自检(见 .githooks/freshness.sh):不一致则自动重装并中止本次
if [ -f "$main_wt/.githooks/freshness.sh" ]; then
  . "$main_wt/.githooks/freshness.sh"
  nemonotch_check_fresh "$main_wt" || exit 1
fi

# 只许从主检出跑:worktree 内跑会让 stash 舞步走错地方(2026-10-20 实测:stash
# 记到 feature 分支、checkout develop 报 'already used'、pop 把 develop 版内容
# 灌回 worktree——旧记忆「feat-done 从 worktree 跑会失败」的机制化收口)。
here=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
if [ "$here" != "$main_wt" ]; then
  echo "✋ feat-done 只在主检出跑(当前在 $here)。" >&2
  echo "   cd \"$main_wt\" && git feat-done $name" >&2
  exit 1
fi

if ! git -C "$main_wt" show-ref --verify --quiet "refs/heads/$branch"; then
  echo "✋ 找不到分支 $branch。" >&2
  exit 1
fi

# Locate the worktree checked out on this branch (if any).
wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '
  /^worktree /{p=$2} /^branch /{ if ($2==b) print p }')

# ── 文档对账门禁:merge 前在 worktree 跑 doc-audit(纯 grep,秒级)──
# 漂移要在部署前被抓住,而不是 push 之后等 CI 变红(socket 描述曾漂 5 个月)。
# 纯文档 feature 也跑 — 那正是漂移进来的入口。逃生口:NEMONOTCH_SKIP_DOC_AUDIT=1。
if [ "${NEMONOTCH_SKIP_DOC_AUDIT:-0}" = "1" ]; then
  echo "⏭  NEMONOTCH_SKIP_DOC_AUDIT=1 — 跳过文档对账门禁" >&2
elif [ -n "$wt" ] && [ -f "$wt/scripts/doc-audit.sh" ]; then
  echo "📄 文档对账门禁:在 worktree 跑 doc-audit…"
  if ! sh "$wt/scripts/doc-audit.sh"; then
    echo "" >&2
    echo "❌ 文档对账未过 — 中止合并,worktree 与分支原样保留。" >&2
    echo "   修复后重试 git feat-done $name;应急跳过:NEMONOTCH_SKIP_DOC_AUDIT=1 git feat-done $name" >&2
    exit 1
  fi
fi

# ── 评审门禁:judge ≠ author 的机械化(2026-10-20)──
# 判断不能机械化,评审的「发生」可以:改动触及代码/scripts/hooks/CI 的 feature,
# 合并前必须有 .reviews/<name>.md 且 Verdict: APPROVED——由**未参与开发**的
# 会话/子代理填写(sh scripts/review.sh <name> 生成模板与审查清单)。
# 纯文档/格式 feature 自动跳过(触发集与测试门禁同判据扩到工程脚本)。
# 逃生口:NEMONOTCH_SKIP_REVIEW=1(应急,与 SKIP_TESTS 同款约定)。
if [ "${NEMONOTCH_SKIP_REVIEW:-0}" = "1" ]; then
  echo "⏭  NEMONOTCH_SKIP_REVIEW=1 — 跳过评审门禁" >&2
elif [ -n "$wt" ]; then
  base=$(git -C "$main_wt" merge-base develop "$branch")
  # 不接管道,同上——裸命令让 set -e 兜 fail-closed
  review_triggers=$(git -C "$wt" diff --name-only "$base...HEAD" -- '*.swift' '*.xcodeproj/project.pbxproj' 'scripts/*' '.githooks/*' '.github/*')
  if [ -z "$review_triggers" ]; then
    echo "📄 本 feature 无代码/脚本/hooks/CI 改动 — 跳过评审门禁" >&2
  else
    # 查「已提交」的记录内容(HEAD 里的 .reviews/<name>.md),不是工作区文件:
    # 评审是证据链,未提交的 APPROVED 不算数;也避免未跟踪记录卡死 worktree 拆除
    # (评审发现的实测点)。git show 失败(记录未提交)经 grep 落入拒绝分支 = fail-closed。
    if ! git -C "$wt" show "HEAD:.reviews/$name.md" 2>/dev/null | grep -q '^Verdict: APPROVED'; then
      echo "" >&2
      echo "❌ 评审门禁未过 — 本 feature 有代码/脚本/hooks/CI 改动,但没有**已提交**且 Verdict: APPROVED 的评审记录。" >&2
      echo "   流程:sh scripts/review.sh $name 生成模板 → 让未参与开发的会话/子代理评审" >&2
      echo "         diff、填 Findings 与 Verdict → git add .reviews/$name.md && git commit → 重试。" >&2
      echo "   应急跳过:NEMONOTCH_SKIP_REVIEW=1 git feat-done $name" >&2
      echo "" >&2
      exit 1
    fi
    verdict=$(git -C "$wt" show "HEAD:.reviews/$name.md" | grep '^Verdict:' | head -1 | sed 's/^Verdict: *//')
    reviewer=$(git -C "$wt" show "HEAD:.reviews/$name.md" | grep '^Reviewer:' | head -1 | sed 's/^Reviewer: *//')
    echo "🧑‍⚖️ 评审门禁:.reviews/$name.md — Verdict: $verdict(Reviewer: $reviewer)"
  fi
else
  echo "⚠️  分支没有 worktree — 评审门禁无法检查已提交的评审记录,请自行确保评审已完成" >&2
fi

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
      # The last feature leaves an empty .worktree/ behind; don't let it linger.
      rmdir "$main_wt/.worktree" 2>/dev/null || true
      echo "🧹 worktree 已移除,分支已删除" ;;
  esac
fi

echo "   记得推送:  git -C \"$main_wt\" push origin develop"
