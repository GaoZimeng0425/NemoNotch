#!/bin/sh
# NemoNotch Swift lint 门禁 — eslint 式统一入口。
#   SwiftFormat(.swiftformat)管「美化」;SwiftLint(.swiftlint.yml)管「检测」。
#   退出码非零 = SwiftLint error 级违规,或格式与 .swiftformat 不一致(check 模式)。
#
# Usage:
#   sh scripts/lint.sh                 # 全仓检查(只读,不改动任何文件)
#   sh scripts/lint.sh --fix           # 全仓格式化 + lint
#   sh scripts/lint.sh --staged        # 只检查暂存的 *.swift(pre-commit 用)
#   sh scripts/lint.sh --staged --fix  # 格式化暂存文件并重新 git add;部分暂存的文件只检查不改动
#
# pre-commit 调用的是 `--staged --fix`;人工排障直接跑本脚本可复现同样结果。
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

mode=repo
fix=0
for arg in "$@"; do
  case "$arg" in
    --staged) mode=staged ;;
    --fix) fix=1 ;;
    *)
      echo "usage: sh scripts/lint.sh [--staged] [--fix]" >&2
      exit 2 ;;
  esac
done

# ── 工具缺失 = 拦截而非跳过:防止 agent 在未装工具的机器上「假绿」通过门禁 ──
missing=""
for tool in swiftlint swiftformat; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  echo "" >&2
  echo "✋ lint 工具未安装:$missing — 门禁无法执行,拒绝放行(防假绿)。" >&2
  echo "   安装:brew install$missing 然后重试。" >&2
  echo "" >&2
  exit 1
fi

# ── 收集目标文件 ──
# 仓库内 Swift 路径不含空格(与 .githooks/pre-commit 的 xcstrings 段同款假设)。
fixable=""    # 已暂存且工作区与暂存一致 → 可安全自动格式化并重新暂存
checkonly=""  # 已暂存但工作区还有未暂存改动(部分暂存)→ 只检查,避免把未暂存改动带进提交
if [ "$mode" = staged ]; then
  for f in $(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACM -- '*.swift'); do
    [ -f "$f" ] || continue
    if git diff --quiet -- "$f"; then
      fixable="$fixable $f"
    else
      checkonly="$checkonly $f"
    fi
  done
  files="$fixable$checkonly"
  if [ -z "$files" ]; then
    exit 0  # 本次提交不含 Swift 文件 — 无事可做
  fi
else
  files="."
fi

sf_status=0
sl_status=0
had_partial=0

# ── SwiftFormat(美化)──
if [ "$mode" = staged ]; then
  if [ "$fix" = 1 ]; then
    if [ -n "$fixable" ]; then
      # shellcheck disable=SC2086
      swiftformat --quiet $fixable || sf_status=1
      # 重新暂存被格式化的文件;内容未变的文件 git add 是无操作
      # shellcheck disable=SC2086
      git add -- $fixable
    fi
    if [ -n "$checkonly" ]; then
      had_partial=1
      # shellcheck disable=SC2086
      swiftformat --lint --quiet $checkonly || sf_status=1
    fi
  else
    # shellcheck disable=SC2086
    swiftformat --lint --quiet $files || sf_status=1
  fi
else
  if [ "$fix" = 1 ]; then
    swiftformat --quiet . || sf_status=1
  else
    swiftformat --lint --quiet . || sf_status=1
  fi
fi

# ── SwiftLint(检测;error 级才非零退出,warning 放行)──
if [ "$mode" = staged ]; then
  # shellcheck disable=SC2086
  swiftlint lint --quiet --force-exclude $files || sl_status=1
else
  swiftlint lint --quiet || sl_status=1
fi

fail=0
if [ "$sf_status" != 0 ]; then
  fail=1
  echo "" >&2
  echo "❌ SwiftFormat:存在与 .swiftformat 不一致的文件(见上)。" >&2
  echo "   修复:sh scripts/lint.sh --fix(全仓)或 sh scripts/lint.sh --staged --fix(仅暂存文件)" >&2
  if [ "$had_partial" = 1 ]; then
    echo "   ⚠️  部分暂存的文件未被自动格式化(暂存与工作区不一致,避免把未暂存改动带进提交):$checkonly" >&2
    echo "      先完整暂存(git add <file>)再提交,或手动执行:swiftformat$checkonly" >&2
  fi
fi
if [ "$sl_status" != 0 ]; then
  fail=1
  echo "" >&2
  echo "❌ SwiftLint:error 级违规(见上,warning 放行)。" >&2
  echo "   修复对应行;确属误报或有理由保留时,加 // swiftlint:disable:next <rule> 并写明原因。" >&2
fi

if [ "$fail" = 0 ]; then
  echo "✅ swiftformat + swiftlint 通过"
fi
exit $fail
