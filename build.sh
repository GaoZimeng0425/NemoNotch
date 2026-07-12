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
# commit count. Falls back to 0.0.0 when the repo has no tag yet.
VERSION="$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 | sed 's/^v//')"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
echo "==> Version: $VERSION (build $BUILD_NUMBER)"

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

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$BUILD_DIR/export/$APP_NAME.app"

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
