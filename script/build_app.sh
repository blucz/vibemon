#!/usr/bin/env bash
# Build vibemon as a proper .app bundle so it can be installed, double-clicked,
# and registered as a Login Item via SMAppService.
set -euo pipefail

cd "$(dirname "$0")/.."

NAME="vibemon"
BIN="gpumon"             # the SwiftPM executable target name
BUNDLE_ID="com.blucz.vibemon"
VERSION="0.1.0"
BUILD_DIR=".build/app"
APP="$BUILD_DIR/$NAME.app"

echo "→ swift build -c release"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/$BIN" "$APP/Contents/MacOS/$NAME"
chmod +x "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>           <string>$NAME</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                 <string>$NAME</string>
    <key>CFBundleDisplayName</key>          <string>vibemon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>LSUIElement</key>                  <true/>
    <key>NSHighResolutionCapable</key>      <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign: Gatekeeper + SMAppService both want a signature even for local apps.
echo "→ codesign (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null

echo
echo "Built: $APP"
echo
echo "Install:   cp -R '$APP' /Applications/"
echo "Run once:  open '$APP'"
echo "Then: click the gauge icon in the menu bar → Open at Login."
