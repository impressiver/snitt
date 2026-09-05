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
  <key>SUFeedURL</key>
  <string>https://github.com/impressiver/snitt/releases.atom</string>
  <!-- Empty until the maintainer generates a real EdDSA keypair. Verified
       against Sparkle 2.9.6 source (SUUpdateValidator.m): with no EdDSA key
       configured, Sparkle does NOT accept arbitrary unsigned updates. For a
       .app-bundle update it falls back to requiring the downloaded update be
       Apple-code-signed by the SAME Developer ID team as the installed app
       (passesBasicUpdatePolicy); if the old bundle has no DSA/EdDSA key and
       is unsigned or ad-hoc signed, no rotation path exists at all and the
       update is rejected. So an empty key here is not "accepts anything" —
       it is "trust Apple's code-signing chain instead of Sparkle's own,"
       which only works once Snitt ships under a real Developer ID identity.
       Generate and ship a real EdDSA key before relying on this in
       production; do not treat the code-signing fallback as sufficient
       long-term. -->
  <key>SUPublicEDKey</key>
  <string></string>
  <!-- Ruling R3: false is the cold-start default for a fresh install that
       has no user setting yet. An update check is a network request telling
       a server this machine runs Snitt, at a moment the user did not choose
       — see §5. Task 3 adds a runtime setting that governs this once the
       user has had a chance to opt in. -->
  <key>SUEnableAutomaticChecks</key>
  <false/>
</dict>
</plist>
PLIST

if [ -f ".build/debug/SnittApp" ]; then
  cp ".build/debug/SnittApp" "$APP/Contents/MacOS/Snitt"
fi

# Embed Sparkle at Contents/MacOS, not the conventional Contents/Frameworks:
# spike S9 measured the rpath SwiftPM emits for SnittApp as @loader_path,
# which resolves relative to the executable at Contents/MacOS/Snitt. A
# framework copied in beside it there needs no rpath surgery.
# Contents/Frameworks would need `install_name_tool -add_rpath
# @executable_path/../Frameworks` for no offsetting benefit here.
SPARKLE_SRC=".build/debug/Sparkle.framework"
if [ -d "$SPARKLE_SRC" ]; then
  cp -R "$SPARKLE_SRC" "$APP/Contents/MacOS/Sparkle.framework"
else
  echo "error: $SPARKLE_SRC not found — did swift build produce it?" >&2
  exit 1
fi

STABLE_IDENTITY=0
if IDENTITY="$(./Scripts/signing-identity.sh)"; then
  SIGN_ID="$IDENTITY"
  STABLE_IDENTITY=1
else
  SIGN_ID="-"
  echo "WARNING: signing ad-hoc. The app's identity changes on every build, so" >&2
  echo "macOS will forget Screen Recording permission each time you rebuild." >&2
  echo "Run ./Scripts/signing-identity.sh for one-time setup instructions." >&2
fi

# Signing order is the whole risk here: codesign signs inner code before the
# enclosing bundle. An unsigned framework inside a signed app launches fine
# from Finder on this machine and fails Gatekeeper on someone else's, with
# no local reproduction. Sign the embedded framework FIRST, then the app.
codesign --force --deep --sign "$SIGN_ID" "$APP/Contents/MacOS/Sparkle.framework"
codesign --force --sign "$SIGN_ID" "$APP"

if [ "$STABLE_IDENTITY" = "1" ]; then
  echo "Signed with stable identity: $IDENTITY"
  echo "TCC grants will persist across rebuilds."
fi
echo "Built $APP"
