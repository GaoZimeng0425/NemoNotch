#!/bin/sh
# mediaremote-leak-check.sh — mediaremote-mini daemon 内存泄漏回归守卫
#
# 为什么存在(2026-11-05 实案):perl 守护在 daemon 模式下每发调用累积
# ~10KB(闲时)/MB 级(放歌带 artwork)内存——根因是垫片在无 runloop 进程里
# autorelease 池无人排空(上游 ungive/mediaremote-adapter #20 的 ARC 修复
# 只救了一次性 CLI 形态)。见 AGENTS.md 媒体节。
#
# 原理:起一个隔离 perl daemon(spawn 自仓库资产解出的 dylib),打 N 发,
# 用内核 footprint(vmmap)算每发平均增量;超阈值 = 守卫有牙地红(exit 1)。
# 注意:本探针量的是"闲时"泄漏(无音乐播放);artwork 路径无法在脚本里
# 可靠驱动,靠看门狗(NowPlayingCLI)兜底。
#
# 用法: scripts/mediaremote-leak-check.sh [dylib或bin.gz路径]
#        [--calls N] [--per-call-bytes B]
# 默认资产 = 仓库 NemoNotch/Resources/MediaRemoteMini.bin.gz
# 退出码: 0 绿 / 1 泄漏超标(红) / 2 探针自身故障(daemon 没跑起来等)

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASSET="$ROOT/NemoNotch/Resources/MediaRemoteMini.bin.gz"
CALLS=5000
PER_CALL_LIMIT=2000   # 字节/发;补丁版实测 ~500B,旧版 ~10000B

while [ $# -gt 0 ]; do
    case "$1" in
        --calls) CALLS=$2; shift 2 ;;
        --per-call-bytes) PER_CALL_LIMIT=$2; shift 2 ;;
        *) ASSET=$1; shift ;;
    esac
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mrleak.XXXXXX")
DAEMON_PID=""
DRIVER_PID=""
cleanup() {
    [ -n "$DRIVER_PID" ] && kill "$DRIVER_PID" 2>/dev/null
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

DYLIB="$WORK/MediaRemoteMini.dylib"
case "$ASSET" in
    *.gz) gunzip -c "$ASSET" > "$DYLIB" ;;
    *) cp "$ASSET" "$DYLIB" ;;
esac
[ -s "$DYLIB" ] || { echo "PROBE-FAIL: 无法准备 dylib ($ASSET)"; exit 2; }

SCRIPT="$ROOT/NemoNotch/Resources/mediaremote-mini.pl"
[ -f "$SCRIPT" ] || { echo "PROBE-FAIL: 找不到 $SCRIPT"; exit 2; }

mkfifo "$WORK/in" "$WORK/out"
perl "$SCRIPT" "$DYLIB" adapter_get_env --daemon < "$WORK/in" > "$WORK/out" 2>"$WORK/err" &
DAEMON_PID=$!
exec 3>"$WORK/in"
( cat "$WORK/out" > "$WORK/responses.jsonl" ) &
DRIVER_PID=$!
sleep 2
kill -0 "$DAEMON_PID" 2>/dev/null || {
    echo "PROBE-FAIL: daemon 启动即退,stderr:"; head -3 "$WORK/err"; exit 2
}

# vmmap 的 footprint 形如 "8.7G"/"24.8M"/"6097K",归一成字节;只认
# "Physical footprint:"(不带 peak),awk 按前缀锚定防两行都中。
fp_bytes() {
    vmmap --summary "$DAEMON_PID" 2>/dev/null | awk '
        $1 == "Physical" && $2 == "footprint:" {
            v = $3; u = v
            sub(/[0-9.]+/, "", u)
            sub(/[A-Z]$/, "", v)
            n = v + 0
            m = (u == "G") ? 1073741824 : (u == "M") ? 1048576 : (u == "K") ? 1024 : 1
            printf "%d", n * m
        }'
}
BEFORE=$(fp_bytes)
[ -n "$BEFORE" ] || { echo "PROBE-FAIL: 读不到基线 footprint"; exit 2; }

i=0
while [ "$i" -lt "$CALLS" ]; do printf '\n' >&3; i=$((i + 1)); done
sleep 8

AFTER=$(fp_bytes)
LINES=$(wc -l < "$WORK/responses.jsonl" | tr -d ' ')
[ -n "$AFTER" ] || { echo "PROBE-FAIL: 读不到终态 footprint"; exit 2; }
if [ "$LINES" -lt $((CALLS * 9 / 10)) ]; then
    echo "PROBE-FAIL: 响应不足($LINES/$CALLS),协议没跑通"; exit 2
fi

GROWTH_BYTES=$(( AFTER - BEFORE ))
PER_CALL=$(( GROWTH_BYTES / CALLS ))

echo "calls=$CALLS before=${BEFORE}B after=${AFTER}B growth=$((GROWTH_BYTES / 1024))K per_call=${PER_CALL}B limit=${PER_CALL_LIMIT}B asset=$ASSET"
if [ "$PER_CALL" -ge "$PER_CALL_LIMIT" ]; then
    echo "LEAK-RED: 每发泄漏 ${PER_CALL}B ≥ ${PER_CALL_LIMIT}B —— daemon 泄漏回来了"
    exit 1
fi
echo "LEAK-GREEN: 每发 ${PER_CALL}B < ${PER_CALL_LIMIT}B"
exit 0
