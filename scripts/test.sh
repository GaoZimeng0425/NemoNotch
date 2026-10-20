#!/bin/sh
# NemoNotch 单元测试入口 — 证据梯子第 4 档的「工具捕获证据」(pstack prove-it-works)。
# 内置本机必需的 ad-hoc 签名 flags、支持只跑单个测试类、完整输出落日志产物,
# 结尾打印退出码 + 日志路径。报告测试结果时引用本脚本的退出码与日志,不要转述。
#
# Usage:
#   sh scripts/test.sh                              # 全量单元测试
#   sh scripts/test.sh --only FooTests              # 只跑 NemoNotchTests/FooTests
#   sh scripts/test.sh --only NemoNotchTests/FooTests/testBar   # 完整路径原样透传
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      [ $# -ge 2 ] || { echo "usage: sh scripts/test.sh [--only <TestClass>]" >&2; exit 2; }
      only="$2"; shift 2 ;;
    *)
      echo "usage: sh scripts/test.sh [--only <TestClass|full/testing/path>]" >&2
      exit 2 ;;
  esac
done

# shellcheck disable=SC2086
only_flag=
if [ -n "$only" ]; then
  case "$only" in
    */*) only_flag="-only-testing:$only" ;;  # 已含模块前缀,原样透传
    *)   only_flag="-only-testing:NemoNotchTests/$only" ;;
  esac
fi

mkdir -p build
log="$root/build/test.log"

echo "🧪 xcodebuild test ${only_flag:-(全部)} — 完整日志: $log"
echo "   (耗时较长;想看实时输出可另开终端 tail -f \"$log\")"

# 输出整体重定向到日志而不是 tee:POSIX sh 拿不到管道里 xcodebuild 的退出码,
# 而退出码正是要交付的证据。摘要与失败详情在结尾从日志中提取。
run_xcodebuild() {
  xcodebuild test \
    -project NemoNotch.xcodeproj \
    -scheme NemoNotch \
    -destination 'platform=macOS' \
    $only_flag \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    > "$log" 2>&1
}
# xcodeformatted Swift Testing 输出是逐用例行("Test case 'X' passed on …"),
# 没有单一的汇总行 — 用计数代替。带引号锚定("‘ passed on’")以免 display name
# 里恰好含 " failed " 的用例把计数虚增。grep -c 零匹配时返回 1,吃掉它。
count_cases() {
  passed=$(grep -c "' passed on" "$log" || true)
  failed=$(grep -c "' failed on" "$log" || true)
}

run_xcodebuild; status=$?
count_cases

# ── 冷启动宿主崩溃的有界重试(2026-10-20:把「冷 DerivedData 首跑可能崩,重试即可」
# 的口口相传变成机制)。三条同时成立才重试,且只重试一次:非零退出 + 0 个用例被执行
# + 日志含测试宿主崩溃特征。真失败(failed>0)不重试;编译错误(无崩溃特征)不重试
# — 绝不给真失败擦粉。首次日志另存 *.crash1 供排查。特征词取自 xcodebuild 已知措辞,
# 抓到真实崩溃日志后按需校准。逃生口:NEMONOTCH_TEST_NO_RETRY=1。
crash_sig='Early unexpected exit|Test runner exited|Test runner never began|never finished bootstrapping|Restarting after unexpected exit|crashed'
if [ "$status" != 0 ] && [ "${passed:-0}" -eq 0 ] && [ "${failed:-0}" -eq 0 ] \
   && [ "${NEMONOTCH_TEST_NO_RETRY:-0}" != "1" ] && grep -qE "$crash_sig" "$log"; then
  cp "$log" "$log.crash1"
  echo "⚠️  测试宿主在执行任何用例前退出(疑似冷 DerivedData 首跑崩溃)— 重试一次;首次日志: $log.crash1"
  run_xcodebuild; status=$?
  count_cases
fi

echo "── 摘要 ──────────────────────────────"
echo "   用例:通过 ${passed:-0} · 失败 ${failed:-0}"
if [ "$status" != 0 ]; then
  echo ""
  echo "❌ 测试失败(退出码 $status)— 失败用例:"
  grep -E "' failed on" "$log" | head -20
  echo ""
  echo "   日志尾 40 行:"
  tail -40 "$log"
  echo ""
  echo "   完整日志: $log"
  echo "   重跑单个: sh scripts/test.sh --only <TestClass>"
  exit $status
fi
# 零用例守卫:xcodebuild 对无匹配的 -only-testing 静默跑 0 个测试且返回 0
# (实测,Xcode 27)— 套件名拼错/已改名时这就是假绿。测试 target 接线断裂
# 的全量跑同样落在这里。宁可误杀,不可静默放行。
if [ "${passed:-0}" -eq 0 ] && [ "${failed:-0}" -eq 0 ]; then
  echo "❌ 退出码 0 但没有任何用例被执行 — --only 过滤器无匹配(套件名拼错/已改名?)或测试 target 接线断裂" >&2
  echo "   完整日志: $log" >&2
  exit 1
fi
echo "✅ 测试通过(退出码 0)"
echo "   完整日志: $log"
exit 0
