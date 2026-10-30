#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
APP="$ROOT/build/ClaudeStatus.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/ClaudeStatus" "$APP/Contents/MacOS/ClaudeStatus"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSUIElement</key><true/>
    <key>CFBundleIdentifier</key><string>dev.chrfalch.ClaudeStatus</string>
    <key>CFBundleName</key><string>ClaudeStatus</string>
    <key>CFBundleExecutable</key><string>ClaudeStatus</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
codesign --force -s - build/ClaudeStatus.app
