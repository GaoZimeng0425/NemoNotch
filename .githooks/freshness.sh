#!/bin/sh
# 已安装副本 vs 源文件一致性自检 — 被 feat.sh / feat-done.sh / pre-commit 的
# **已安装副本** source。本文件自身不被 install.sh 复制,始终从主检出的源目录
# 读取,所以检查逻辑永远是最新的(不会出现「检查器自己过期」的递归问题)。
#
# 背景(2026-10-20 审计):install.sh 把 .githooks/ 下的 hooks 与 feat 脚本 cp
# 进共享 .git 目录,git feat / feat-done 跑的是那份副本。源改了不重装 = 静默跑
# 旧代码,排障时会盯着一份根本没在执行的源文件。「改了要重跑 install.sh」原本
# 只是注释里的一句提醒 — 这里把它变成机制。
#
# 行为:发现任一副本与源不一致 → 自动重装(sh .githooks/install.sh)→ 返回 1,
# 调用方中止当前命令并提示重跑(本次已在跑旧副本,不能让它继续)。
# 自愈三约束:出声(stderr 全程可见)、有界(只装一次)、只修环境不修代码。
#
# 用法(调用方):
#   . "$main_wt/.githooks/freshness.sh"
#   nemonotch_check_fresh "$main_wt" || exit 1
nemonotch_check_fresh() {
  # 显式逃生口:在 worktree 里开发 hooks 自身时,主检出的源还是旧的,自检会把副本
  # "修正"回旧版 — 这时按需跳过(与 NEMONOTCH_SKIP_TESTS 同款约定,用完即撤)。
  if [ "${NEMONOTCH_SKIP_FRESHNESS:-0}" = "1" ]; then
    echo "⏭  NEMONOTCH_SKIP_FRESHNESS=1 — 跳过已安装副本自检" >&2
    return 0
  fi
  nf_root="$1"
  nf_src="$nf_root/.githooks"
  nf_common=$(git -C "$nf_root" rev-parse --git-common-dir)
  case "$nf_common" in /*) ;; *) nf_common="$nf_root/$nf_common" ;; esac

  nf_stale=""
  for nf_pair in \
      "pre-commit:hooks/pre-commit" \
      "pre-merge-commit:hooks/pre-merge-commit" \
      "post-merge:hooks/post-merge" \
      "feat.sh:nemonotch-bin/feat.sh" \
      "feat-done.sh:nemonotch-bin/feat-done.sh" \
      "feat-gc.sh:nemonotch-bin/feat-gc.sh"; do
    nf_s="$nf_src/${nf_pair%%:*}"
    nf_d="$nf_common/${nf_pair#*:}"
    [ -f "$nf_s" ] || continue   # 源里没有的(基于旧 develop)不算过期
    if [ ! -f "$nf_d" ] || ! cmp -s "$nf_s" "$nf_d"; then
      nf_stale="$nf_stale ${nf_pair%%:*}"
    fi
  done
  [ -z "$nf_stale" ] && return 0

  echo "" >&2
  echo "✋ .githooks 源与已安装副本不一致:$nf_stale" >&2
  echo "   正在重新安装(sh .githooks/install.sh)…" >&2
  if sh "$nf_src/install.sh" >/dev/null 2>&1; then
    echo "   ✅ 已重装。本次命令用的是旧副本,已中止 — 请重新执行刚才的命令。" >&2
  else
    echo "   ❌ 自动重装失败 — 手动执行: sh \"$nf_src/install.sh\"" >&2
  fi
  echo "" >&2
  return 1
}
