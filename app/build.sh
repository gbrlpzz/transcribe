#!/usr/bin/env bash
# Build the native Transcribe menu-bar app (requires Xcode Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"

echo "→ building Swift release binary…"
swift build -c release --product Transcribe

APP="dist/Transcribe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Transcribe "$APP/Contents/MacOS/Transcribe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature: enough for local use on this Mac.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ built $APP"
