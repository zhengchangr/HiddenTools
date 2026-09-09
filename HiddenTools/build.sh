#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="../build/隐藏工具.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/HiddenTools "$APP/Contents/MacOS/HiddenTools"
cp Info.plist "$APP/Contents/Info.plist"
if [ -d Resources ]; then
    cp -R Resources "$APP/Contents/"
fi
codesign --force --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
echo "生成完成：$APP"
