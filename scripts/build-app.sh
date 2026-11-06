#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP_DIR="$PWD/build/AVDMenuBar.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/AVDMenuBar" "$APP_DIR/Contents/MacOS/AVDMenuBar"
cp -R "$BIN_DIR/AVDMenuBar_AVDCore.bundle" "$APP_DIR/Contents/Resources/"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$APP_DIR/Contents/Resources/"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

codesign --force --sign - "$APP_DIR"

echo "已生成：$APP_DIR"
echo "安装：rm -rf \"/Applications/AVDMenuBar.app\" && cp -R \"$APP_DIR\" /Applications/ && open \"/Applications/AVDMenuBar.app\""
