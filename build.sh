#!/bin/bash
# Сборка MultiDock.app без Xcode (нужны только Command Line Tools).
set -e
cd "$(dirname "$0")"

swift build -c release

APP="MultiDock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MultiDock "$APP/Contents/MacOS/MultiDock"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo ""
echo "Готово: $(pwd)/$APP"
echo "Перетащите MultiDock.app в Программы и запустите."
