#!/usr/bin/env bash
# 自驱动截取「完成提示」全屏 glow + toast 一张图到 docs/images/completion-flash.png。
# 与 uitest-screenshots.sh 同源,但用 --flash 钉住完成态并整屏截图(而非裁面板矩形)。
# 用法: ./scripts/uitest-flash-screenshot.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/images/completion-flash.png"
RECT_FILE="/tmp/nemonotch-uitest.rect"
DERIVED="$ROOT/build/uitest"
APP="$DERIVED/Build/Products/Debug/NemoNotch.app"

mkdir -p "$ROOT/docs/images"

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
    open -a NemoNotch 2>/dev/null || open "/Applications/NemoNotch.app" 2>/dev/null || true
  fi
}
trap restore EXIT INT TERM
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
  grep -E "error:" "$BUILD_LOG" | head -5
  exit 1
fi
test -d "$APP" || { echo "构建产物未找到: $APP"; exit 1; }

echo "==> 截图 completion-flash(AI 完成态 + 全屏 glow + toast)"
rm -f "$RECT_FILE" /tmp/nemonotch-uitest-tasks.json /tmp/nemonotch-uitest-history.json
# 用 claude tab 当背景:面板里展示 AI 会话,叠加完成 toast,四周全屏 glow。
"$APP/Contents/MacOS/NemoNotch" --uitest --tab=claude --flash &
PID=$!
# 这个 uitest 实例会铺满屏:restore 陷阱在任何退出路径上先杀掉它
# (SIGKILL 杀不到的话,app 内部还有 12s 自杀定时器兜底)。
wait_for 2   # 等开屏 + 内容渲染 + glow 钉住

# app 自身在 glow / 面板之下铺了整屏暗色背景窗(--flash 专用),无需隐藏用户其它 app。
# 整屏截取主显示(内置刘海屏);glow 钉在 flashLevel=1,不会衰减。
screencapture -x "$OUT"

kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""
wait_for 0.4

# 整屏 retina PNG 体积大,缩到宽 1600 与 README 展示尺寸匹配。
if command -v sips >/dev/null; then
  sips --resampleWidth 1600 "$OUT" >/dev/null
fi


echo "完成。输出:"
ls -la "$OUT"
