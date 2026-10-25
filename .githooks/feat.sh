#!/bin/sh
# git feat <name> — start a feature in its own worktree.
# Pulls latest first: if local develop is purely behind origin/develop, fast-
# forwards the primary checkout's develop (--autostash shields any in-flight
# dirty files), then creates feature/<name> off the refreshed develop in a
# worktree nested inside the primary checkout at .worktree/<name> (the folder
# is git-ignored and excluded from swiftlint/swiftformat so the nested copy is
# never linted, formatted or staged from the primary checkout).
set -e

name="$1"
if [ -z "$name" ]; then
  echo "usage: git feat <name>" >&2
  exit 1
fi

main_wt=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')

# 已安装副本过期自检(见 .githooks/freshness.sh):不一致则自动重装并中止本次
if [ -f "$main_wt/.githooks/freshness.sh" ]; then
  . "$main_wt/.githooks/freshness.sh"
  nemonotch_check_fresh "$main_wt" || exit 1
fi

wt="$main_wt/.worktree/$name"
branch="feature/$name"

# ── get-or-create(目标状态语义,2026-10-24):重跑同一命令从任何中间状态回到现场 ──
# worktree+分支都在 → 指路复用(不报错);分支在、worktree 没了(feat-done 清理失败的
# 残留)→ 挂回来;都没有才走「拉最新 + 新建」。报错留给真正的错。
existing_wt=$(git -C "$main_wt" worktree list --porcelain | awk -v b="refs/heads/$branch" '
  /^worktree /{p=$2} /^branch /{ if ($2==b) print p }')
if git -C "$main_wt" show-ref --verify --quiet "refs/heads/$branch"; then
  # porcelain 是注册表视图不是文件系统视图:条目可能 prunable(目录被带外 rm 掉)。
  # 目录真在才指路,否则先 prune 清掉僵尸注册再走挂回——指到不存在的目录是静默的错成功。
  if [ -n "$existing_wt" ] && [ -d "$existing_wt" ]; then
    echo "✅ $branch 已在进行中 — worktree 在,直接进:"
    echo "   cd \"$existing_wt\"   (完成后: git feat-done $name)"
    exit 0
  fi
  [ -n "$existing_wt" ] && git -C "$main_wt" worktree prune
  echo "♻️  分支 $branch 在、worktree 缺(清理残留)— 挂回:"
  git -C "$main_wt" worktree add "$wt" "$branch"
  echo ""
  echo "✅ $branch  @  $wt   (分支已存在,worktree 已挂回)"
  echo "   下一步:  cd \"$wt\""
  echo "   完成后:  git feat-done $name"
  exit 0
fi

if ! git -C "$main_wt" show-ref --verify --quiet refs/heads/develop; then
  echo "✋ 本地没有 develop 分支。" >&2
  exit 1
fi

# ── 开工先拉最新:落后且未分叉 → 快进主检出的 develop,用最新代码建 worktree ──
git -C "$main_wt" fetch origin develop --quiet 2>/dev/null || true
if git -C "$main_wt" show-ref --verify --quiet refs/remotes/origin/develop; then
  behind=$(git -C "$main_wt" rev-list --count develop..origin/develop 2>/dev/null || echo 0)
  ahead=$(git -C "$main_wt" rev-list --count origin/develop..develop 2>/dev/null || echo 0)
  if [ "${behind:-0}" -gt 0 ] && [ "${ahead:-0}" -eq 0 ]; then
    main_branch=$(git -C "$main_wt" symbolic-ref --short HEAD 2>/dev/null || echo "")
    if [ "$main_branch" = "develop" ]; then
      echo "⬇️  develop 落后 origin/develop $behind 个提交 — 快进拉取(--autostash 保护在途改动)"
      stashes_before=$(git -C "$main_wt" stash list | wc -l | tr -d ' ')
      if ! git -C "$main_wt" merge --ff-only --autostash origin/develop; then
        echo "" >&2
        echo "✋ 拉取失败 — 不在最新代码上开工,已中止(未创建任何东西)。" >&2
        echo "   先处理主检出报出的冲突/脏改动,再重试 git feat $name。" >&2
        exit 1
      fi
      stashes_after=$(git -C "$main_wt" stash list | wc -l | tr -d ' ')
      if [ "$stashes_after" -gt "$stashes_before" ]; then
        echo "⚠️  autostash 恢复冲突 — 改动已以冲突标记(<<<<<<<)写进工作区,另有一份完整副本在 stash@{0}。" >&2
        echo "    恢复路径:解决文件里的冲突标记并 git add,然后 git -C \"$main_wt\" stash drop 丢弃已物化的副本。" >&2
        echo "    (此状态下 git stash pop 会因 needs merge 报错,别走那条路)" >&2
      fi
    else
      echo "⚠️  develop 落后 origin/develop $behind 个提交,但主检出当前在 ${main_branch:-(detached HEAD)} — 跳过拉取" >&2
    fi
  elif [ "${behind:-0}" -gt 0 ] && [ "${ahead:-0}" -gt 0 ]; then
    echo "⚠️  本地 develop 与 origin/develop 分叉(领先 $ahead / 落后 $behind)— 基于本地 develop 开工(本机 develop 是构建部署源),记得稍后同步。" >&2
  fi
fi

git -C "$main_wt" worktree add -b "$branch" "$wt" develop
echo ""
echo "✅ $branch  @  $wt   (off develop $(git -C "$main_wt" rev-parse --short develop))"
echo "   下一步:  cd \"$wt\""
echo "   完成后:  git feat-done $name"
