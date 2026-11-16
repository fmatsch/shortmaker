#!/bin/bash
# Baut "ShortMaker.app" (Release, ad-hoc signiert). Es genügen die Command Line Tools.
# Aufruf: Scripts/build_app.sh   → erzeugt ./build/ShortMaker.app
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/ShortMaker.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ShortMaker "$APP/Contents/MacOS/ShortMaker"
cp -R Models "$APP/Contents/Resources/Models"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift Scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"
echo "Fertig: $APP"
