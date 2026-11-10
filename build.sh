#!/bin/zsh
# Builds Uplink.app and installs it in ~/Applications.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/Uplink.app"
mkdir -p build
rm -f build/Uplink
swiftc -O -o build/Uplink Uplink.swift \
  -framework AppKit -framework AVFoundation -framework ScreenCaptureKit \
  -framework ServiceManagement -framework UserNotifications -framework Carbon -framework SwiftUI \
  2>&1 | grep -v "^$" || true
[ -f build/Uplink ] || { echo "Build failed"; exit 1; }
pkill -x Uplink 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns assets/glyph.png assets/glyph@2x.png assets/glyph-live.png assets/glyph-live-light.png assets/stickers-png/*.png "$APP/Contents/Resources/"
cp build/Uplink "$APP/Contents/MacOS/Uplink"
cp Info.plist "$APP/Contents/Info.plist"
plutil -insert UplinkHome -string "$PWD" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Installed $APP"
