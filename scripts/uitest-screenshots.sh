#!/usr/bin/env bash
# 自驱动截取 NemoNotch 全部 6 个 Tab 的面板截图到 docs/images/。
# 用法: ./scripts/uitest-screenshots.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/docs/images"
RECT_FILE="/tmp/nemonotch-uitest.rect"
DERIVED="$ROOT/build/uitest"
APP="$DERIVED/Build/Products/Debug/NemoNotch.app"
TABS=(overview claude agents launcher pomodoro system)

mkdir -p "$OUT_DIR"

wait_for() { osascript -e "delay $1"; }  # 用 osascript 而非 shell sleep

echo "==> 退出当前运行实例(截完恢复)"
WAS_RUNNING=0
PID=""
if pgrep -x NemoNotch >/dev/null; then WAS_RUNNING=1; fi
# 无论正常结束、出错(set -e)还是被 Ctrl-C / TERM:先杀掉 uitest 实例,再把用户的
# 实例拉回来 —— 以前构建失败时脚本直接退出,用户的 NemoNotch 就一直停着。
restore() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  if [ "$WAS_RUNNING" -eq 1 ] && ! pgrep -x NemoNotch >/dev/null; then
    echo "==> 恢复用户的运行实例"
    # 先按路径:同 bundle id 的 Debug 构建也注册在 LaunchServices 里,按名字可能解析到它。
    open "/Applications/NemoNotch.app" 2>/dev/null || open -a NemoNotch 2>/dev/null || true
  fi
}
trap restore EXIT
# 中断即退出(EXIT 陷阱负责收尾):只挂 restore 的话 bash 跑完处理函数会接着往下执行,
# 把用户的 app 拉起来之后又启动全屏 uitest 实例。
trap 'exit 130' INT
trap 'exit 143' TERM
osascript -e 'tell application "NemoNotch" to quit' 2>/dev/null || true
pkill -x NemoNotch 2>/dev/null || true
wait_for 1

echo "==> Debug 构建"
BUILD_LOG="$ROOT/build/uitest-build.log"
mkdir -p "$ROOT/build"
# 与 build.sh / test.sh 同一组 ad-hoc 签名参数:本机没有项目的开发证书,缺了就构建失败。
if ! xcodebuild build \
  -project "$ROOT/NemoNotch.xcodeproj" \
  -scheme NemoNotch \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" >"$BUILD_LOG" 2>&1; then
  echo "构建失败,完整日志: $BUILD_LOG"
  grep -m5 -E "error:" "$BUILD_LOG" || true
  exit 1
fi
test -d "$APP" || { echo "构建产物未找到: $APP"; exit 1; }

for tab in "${TABS[@]}"; do
  echo "==> 截图 $tab"
  # 每次启动前清掉临时种子文件,否则 TaskStore 会在持久文件上反复追加,列表越积越多。
  rm -f "$RECT_FILE" /tmp/nemonotch-uitest-tasks.json /tmp/nemonotch-uitest-history.json
  "$APP/Contents/MacOS/NemoNotch" --uitest --tab="$tab" &
  PID=$!
  wait_for 1.6   # 等开屏 + 内容渲染
  if [ ! -f "$RECT_FILE" ]; then echo "未拿到矩形文件,$tab 跳过"; kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""; continue; fi
  RECT=$(tr ' ' ',' < "$RECT_FILE" | tr -d '\n')
  screencapture -x -R"$RECT" "$OUT_DIR/tab-$tab.png"
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true   # 确保实例完全退出再起下一个,避免端口/浮层残留
  PID=""
  wait_for 0.4
done


echo "完成。输出:"
ls -la "$OUT_DIR"/tab-*.png
