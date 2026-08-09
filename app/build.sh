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

# Stable code signing.
#
# Why it matters: macOS stores Microphone/Accessibility permissions against the
# app's signature. Ad-hoc signing (-) changes the signature on every rebuild,
# so macOS re-asks for permission every time. A stable identity (self-signed
# "Transcribe Code Signing" cert, or an Apple Development cert) keeps the
# designated requirement constant -> permissions persist across rebuilds.
IDENTITY=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Transcribe Code Signing"; then
    IDENTITY="Transcribe Code Signing"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $2}')
else
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || true
echo "  signed with: $IDENTITY"

echo "✓ built $APP"
