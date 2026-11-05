#!/bin/sh
# build-mediaremote-mini.sh — 重建 NemoNotch/Resources/MediaRemoteMini.bin.gz
#
# 源码出处:ungive/mediaremote-adapter(BSD-3),经 kirtan-shah/nowplaying-cli
# vendoring;本仓在 scripts/mediaremote-mini-src/ 基础上打了一个补丁:
# adapter_get 外包 @autoreleasepool——无 runloop 的常驻 daemon 里 autorelease
# 临时对象无人排空,每发泄漏 ~7.6KB(闲时)/MB 级(artwork);上游 #20 的
# ARC 修复(79a6049)只救一次性 CLI 形态。实案 2026-11-05:app 端 perl 守护
# 20.5h 涨到 8.8GB(内核 footprint 佐证)。
#
# 编译参数对齐 nowplaying-cli Makefile(2026-04 版本):
#   clang -dynamiclib -fobjc-arc -fvisibility=default -O3
#   -framework Foundation -framework AppKit -framework UniformTypeIdentifiers
#   + ad-hoc codesign + gzip -9n(无时间戳,可重放)
#
# 产物替换 NemoNotch/Resources/MediaRemoteMini.bin.gz 后,用
# scripts/mediaremote-leak-check.sh 验证(阈值 2000B/发)。

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/scripts/mediaremote-mini-src"
OUT="$ROOT/NemoNotch/Resources/MediaRemoteMini.bin.gz"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mrmini.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

clang -dynamiclib -fobjc-arc -fvisibility=default -O3 \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -I"$SRC/include" -I"$SRC" \
    "$SRC/adapter/env.m" "$SRC/adapter/get.m" "$SRC/adapter/globals.m" \
    "$SRC/adapter/keys.m" "$SRC/adapter/now_playing.m" \
    "$SRC/private/MediaRemote.m" "$SRC/utility/helpers.m" \
    -o "$TMP/MediaRemoteMini.dylib"

codesign --force --sign - "$TMP/MediaRemoteMini.dylib" >/dev/null 2>&1 || true

gzip -9n -c "$TMP/MediaRemoteMini.dylib" > "$OUT"
echo "REBUILT $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
shasum -a 256 "$OUT"
