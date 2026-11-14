#!/bin/bash
# 一键构建 Amoo Bridge for Mac.app（Intel / Apple Silicon 均按本机架构编译）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/Amoo Bridge Mac.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "[1/4] 编译 Swift ..."
swiftc -O -target "$(uname -m)-apple-macosx12.0" \
  -o "$APP/Contents/MacOS/AmooBridgeMac" \
  "$ROOT/Sources/main.swift" "$ROOT/Sources/AmooDriver.swift"

echo "[2/4] 拷贝资源 ..."
cp "$ROOT/Resources/index.html" "$APP/Contents/Resources/index.html"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "[3/4] 校验 plist ..."
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "[4/4] ad-hoc 签名 ..."
codesign --force --deep -s - "$APP" 2>/dev/null || echo "  (跳过签名，仍可直接双击运行)"

echo "完成：$APP"
