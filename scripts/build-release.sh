#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CodexSwitcherMenubar"
VERSION="${1:-0.1.0}"
BUILD_DIR="$ROOT_DIR/dist/build"
STAGE_DIR="$ROOT_DIR/dist/stage"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/dist/${APP_NAME}-${VERSION}.dmg"

rm -rf "$BUILD_DIR" "$STAGE_DIR"
mkdir -p "$BUILD_DIR" "$STAGE_DIR"

swift build -c release --package-path "$ROOT_DIR" --product "$APP_NAME" >/dev/null
BIN_DIR="$(swift build -c release --package-path "$ROOT_DIR" --show-bin-path)"
BIN_PATH="$BIN_DIR/$APP_NAME"

if [[ ! -f "$BIN_PATH" ]]; then
  echo "Release binary not found at $BIN_PATH" >&2
  exit 1
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>com.juniorxxue.codex-switcher-menubar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - --timestamp=none "$APP_DIR" >/dev/null

cp -R "$APP_DIR" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Created: $DMG_PATH"
