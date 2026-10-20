#!/bin/bash
set -euo pipefail

SCHEME="NemoNotch"
PROJECT="NemoNotch.xcodeproj"
BUILD_DIR="build"
APP_NAME="NemoNotch"
DMG_NAME="NemoNotch"

# Target architecture: default arm64. Pass --x86 to build x86_64 instead,
# or --arm to be explicit. Single-arch builds compile ~2x faster than the
# default universal binary, at the cost of only running on that architecture.
ARCH="arm64"
case "${1:-}" in
  ""|--arm|--arm64) ARCH="arm64" ;;
  --x86|--x86_64|--intel) ARCH="x86_64" ;;
  *)
    echo "Unknown option: $1"
    echo "Usage: $0 [--arm | --x86]"
    exit 1
    ;;
esac
echo "==> Target architecture: $ARCH"

# Arch-suffixed DMG so --arm and --x86 builds don't overwrite each other.
DMG_NAME="$DMG_NAME-$ARCH"

# Version from the latest release tag globally (v0.5.4 -> 0.5.4) so local DMGs
# carry a real version instead of pbxproj's dev placeholder; build number =
# commit count. Falls back to 0.0.0 when the repo has no tag yet. The `|| true`
# is load-bearing: with pipefail an empty grep exits 1 and would kill the
# script before the fallback on the next line could run.
VERSION="$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 | sed 's/^v//' || true)"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
echo "==> Version: $VERSION (build $BUILD_NUMBER)"

# ── Local-deploy signing (2026-10-20): stable self-signed identity ────────
# ad-hoc 每次构建换 cdhash,「合并即部署」的重装在 TCC/Keychain 眼里都是陌生
# app;自签证书让重装保持同一身份。fail-closed:身份解析不到就地失败,绝不
# 静默回退 ad-hoc —— 证书丢失若被吞掉,后续只会表现为「授权莫名又丢了」
# 这种无从排查的谜题。判据用 codesign 实签探针(find-identity -p codesigning
# 对无信任设置的自签证书不显示,不能当存在性检查,实测 2026-10-20)。
# 生成/重建证书:sh scripts/make-signing-cert.sh
# 显式逃生口(临时 ad-hoc):NEMONOTCH_SIGNING_IDENTITY='-'
SIGNING_IDENTITY="${NEMONOTCH_SIGNING_IDENTITY:-NemoNotch Local Code Signing}"
if [ "$SIGNING_IDENTITY" != "-" ]; then
  probe=$(mktemp) && printf 'probe' > "$probe"
  if ! codesign -f -s "$SIGNING_IDENTITY" "$probe" >/dev/null 2>&1; then
    echo "✋ 签名身份 '$SIGNING_IDENTITY' 解析不到 — 拒绝静默回退 ad-hoc。"
    echo "   重建: sh scripts/make-signing-cert.sh"
    echo "   临时显式回退: NEMONOTCH_SIGNING_IDENTITY=- ./build.sh"
    rm -f "$probe"
    exit 1
  fi
  rm -f "$probe"
fi
echo "==> Signing identity: $SIGNING_IDENTITY"

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$BUILD_DIR/$SCHEME.xcarchive" \
  -destination 'platform=macOS' \
  ARCHS="$ARCH" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  | tail -1

echo "==> Exporting .app..."
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/$SCHEME.xcarchive" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist ExportOptions.plist

echo "==> Signing ($SIGNING_IDENTITY)..."
codesign --force --deep --sign "$SIGNING_IDENTITY" "$BUILD_DIR/export/$APP_NAME.app"

echo "==> Creating DMG..."
DMG_STAGING="$BUILD_DIR/dmg_staging"
mkdir -p "$DMG_STAGING"
cp -R "$BUILD_DIR/export/$APP_NAME.app" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$BUILD_DIR/$DMG_NAME.dmg"

echo "==> Done: $BUILD_DIR/$DMG_NAME.dmg"
ls -lh "$BUILD_DIR/$DMG_NAME.dmg"

# ----------------------------------------------------------------------------
# Deploy: kill the running app, replace /Applications copy, relaunch.
# The freshly exported .app is at $BUILD_DIR/export/$APP_NAME.app; we copy it
# into /Applications and open it so you can try the new build immediately.
# ----------------------------------------------------------------------------
APP_BUNDLE="$BUILD_DIR/export/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

echo "==> Closing running $APP_NAME..."
# Graceful quit first, then force-kill any survivors. Ignore errors so a
# not-yet-running app doesn't abort the script.
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
sleep 1
pkill -x "$APP_NAME" 2>/dev/null || true

echo "==> Installing to $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
cp -R "$APP_BUNDLE" "$INSTALL_PATH"

echo "==> Launching $APP_NAME..."
open "$INSTALL_PATH"
echo "==> All done. $APP_NAME is running from /Applications."
