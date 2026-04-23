#!/bin/bash
set -euo pipefail

SCHEME="NemoNotch"
PROJECT="NemoNotch.xcodeproj"
BUILD_DIR="build"
APP_NAME="NemoNotch"
DMG_NAME="NemoNotch"

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$BUILD_DIR/$SCHEME.xcarchive" \
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
