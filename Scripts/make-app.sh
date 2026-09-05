#!/bin/bash
# Assembles build/Snitt.app so capture runs under a stable TCC identity.
# Without this, screen-recording permission is attributed to the terminal
# that launched the binary, not to Snitt (see spec 4.9).
set -euo pipefail

APP="build/Snitt.app"
BUNDLE_ID="com.impressiver.snitt"
VERSION_SOURCE="Sources/SnittDocument/AppVersion.swift"

APP_VERSION="$(sed -nE 's/.*public static let fallback = "([^"]+)".*/\1/p' "$VERSION_SOURCE")"
if [ -z "$APP_VERSION" ]; then
  echo "error: could not extract AppVersion.fallback from $VERSION_SOURCE" >&2
  echo "refusing to write an empty CFBundleShortVersionString" >&2
  exit 1
fi

swift build -c debug --product SnittApp

if [ ! -f ".build/debug/SnittApp" ]; then
  echo "error: swift build did not produce .build/debug/SnittApp" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Snitt</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Snitt</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Snitt records your microphone when you enable it for a recording.</string>
</dict>
</plist>
PLIST

if [ -f ".build/debug/SnittApp" ]; then
  cp ".build/debug/SnittApp" "$APP/Contents/MacOS/Snitt"
fi

if IDENTITY="$(./Scripts/signing-identity.sh)"; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with stable identity: $IDENTITY"
  echo "TCC grants will persist across rebuilds."
else
  codesign --force --sign - "$APP"
  echo "WARNING: signed ad-hoc. The app's identity changes on every build, so" >&2
  echo "macOS will forget Screen Recording permission each time you rebuild." >&2
  echo "Run ./Scripts/signing-identity.sh for one-time setup instructions." >&2
fi
echo "Built $APP"
