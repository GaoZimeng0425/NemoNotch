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
