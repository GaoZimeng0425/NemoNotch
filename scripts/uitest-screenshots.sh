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
if pgrep -x NemoNotch >/dev/null; then WAS_RUNNING=1; fi
osascript -e 'tell application "NemoNotch" to quit' 2>/dev/null || true
pkill -x NemoNotch 2>/dev/null || true
wait_for 1

echo "==> Debug 构建"
xcodebuild build \
  -project "$ROOT/NemoNotch.xcodeproj" \
  -scheme NemoNotch \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" >/dev/null
test -d "$APP" || { echo "构建产物未找到: $APP"; exit 1; }

for tab in "${TABS[@]}"; do
  echo "==> 截图 $tab"
  # 每次启动前清掉临时种子文件,否则 TaskStore 会在持久文件上反复追加,列表越积越多。
  rm -f "$RECT_FILE" /tmp/nemonotch-uitest-tasks.json /tmp/nemonotch-uitest-history.json
  "$APP/Contents/MacOS/NemoNotch" --uitest --tab="$tab" &
  PID=$!
  wait_for 1.6   # 等开屏 + 内容渲染
  if [ ! -f "$RECT_FILE" ]; then echo "未拿到矩形文件,$tab 跳过"; kill "$PID" 2>/dev/null || true; continue; fi
  RECT=$(tr ' ' ',' < "$RECT_FILE" | tr -d '\n')
  screencapture -x -R"$RECT" "$OUT_DIR/tab-$tab.png"
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true   # 确保实例完全退出再起下一个,避免端口/浮层残留
  wait_for 0.4
done

echo "==> 恢复用户的运行实例"
if [ "$WAS_RUNNING" -eq 1 ]; then
  open -a NemoNotch 2>/dev/null || open "/Applications/NemoNotch.app" 2>/dev/null || true
fi

echo "完成。输出:"
ls -la "$OUT_DIR"/tab-*.png
