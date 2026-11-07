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

# 内嵌 baguette（可选增强档）：Vendor/baguette/ 需含 Baguette 二进制与 Baguette_Baguette.bundle，
# 获取步骤见 README「iOS 模拟器支持」。缺失时打印提示并跳过，构建走基础档（截图轮询）。
EMBED_BAGUETTE=0
VENDOR_DIR="$PWD/Vendor/baguette"
if [ -d "$VENDOR_DIR" ]; then
  if [ -f "$VENDOR_DIR/Baguette" ] && [ -d "$VENDOR_DIR/Baguette_Baguette.bundle" ]; then
    EMBED_BAGUETTE=1
  else
    echo "警告：Vendor/baguette/ 缺少 Baguette 二进制或 Baguette_Baguette.bundle，跳过内嵌 baguette（基础档）。" >&2
  fi
else
  echo "提示：未找到 Vendor/baguette/，跳过内嵌 baguette，构建走基础档。获取步骤见 README。"
fi

if [ "$EMBED_BAGUETTE" = "1" ]; then
  mkdir -p "$APP_DIR/Contents/Resources/Helpers"
  cp "$VENDOR_DIR/Baguette" "$APP_DIR/Contents/Resources/Helpers/Baguette"
  cp -R "$VENDOR_DIR/Baguette_Baguette.bundle" "$APP_DIR/Contents/Resources/Helpers/"
  # 嵌套代码先签名，再签外层 bundle 封印其签名。
  codesign --force --sign - "$APP_DIR/Contents/Resources/Helpers/Baguette_Baguette.bundle"
  codesign --force --sign - "$APP_DIR/Contents/Resources/Helpers/Baguette"
  echo "已内嵌 baguette：$APP_DIR/Contents/Resources/Helpers/"
fi

codesign --force --sign - "$APP_DIR"

echo "已生成：$APP_DIR"
echo "安装：rm -rf \"/Applications/AVDMenuBar.app\" && cp -R \"$APP_DIR\" /Applications/ && open \"/Applications/AVDMenuBar.app\""
