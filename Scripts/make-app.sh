#!/bin/bash
# Assembles build/Snitt.app so capture runs under a stable TCC identity.
# Without this, screen-recording permission is attributed to the terminal
# that launched the binary, not to Snitt (see spec 4.9).
set -euo pipefail

APP="build/Snitt.app"
BUNDLE_ID="com.impressiver.snitt"
VERSION_SOURCE="Sources/SnittDocument/AppVersion.swift"

# A failed sign (or anything else that trips `set -e` after this point) must
# not leave a half-built, unsigned bundle sitting in build/ looking like a
# real artifact. Tests would fail on it, which is the safe direction, but
# there's no reason to leave the debris.
cleanup_on_failure() {
  status=$?
  if [ "$status" -ne 0 ] && [ -e "$APP" ]; then
    echo "make-app.sh failed (exit $status) — removing incomplete $APP" >&2
    rm -rf "$APP"
  fi
}
trap cleanup_on_failure EXIT

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
  <!-- Sparkle's SUHost.validVersion reads ONLY CFBundleVersion (not
       CFBundleShortVersionString above). Without it, SPUUpdater's own
       checkIfConfiguredProperlyAndRequireFeedURL: bails immediately with
       SUInvalidHostVersionError and the updater never starts — before any
       of the SU* keys below are even consulted. AppVersion.swift's comment
       about Sparkle comparing against CFBundleShortVersionString describes
       appcast-item comparison once the updater IS running; this key is a
       separate, earlier gate. Same value, same single source. -->
  <key>CFBundleVersion</key><string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Snitt records your microphone when you enable it for a recording.</string>
  <!-- PLACEHOLDER — Task 5's make-appcast.sh generates the real appcast.
       GitHub's own releases.atom is Atom (<feed>/<entry>), not a Sparkle
       appcast: SUAppcast.m parses /rss/channel/item and needs
       <enclosure sparkle:version=…>, which an Atom feed never emits, so
       pointing at releases.atom would make every check silently find zero
       items. This URL is a stand-in with the same shape Task 5's output
       will have (an appcast.xml release asset); replace it with the real
       one when that task lands, the same way SUPublicEDKey below is a
       stand-in for a real key. -->
  <key>SUFeedURL</key>
  <string>https://github.com/impressiver/snitt/releases/latest/download/appcast.xml</string>
  <!-- No SUPublicEDKey key at all — not even an empty string. Verified
       against Sparkle 2.9.6 source (SUSignatures.m/SUHost.m): an ABSENT key
       reads back as nil, giving SUSigningInputStatusAbsent, which
       SPUUpdater's config check treats as "no key yet" and falls back to
       requiring the update be validly code-signed to match the installed
       app (safe: HTTPS feed + this script always code-signs, so the
       fallback never accepts an unsigned update). An EMPTY STRING is
       different and worse for us right now: NSData(base64Encoded: "")
       decodes to a valid zero-length NSData (confirmed by direct test, not
       assumed), which SUPublicKeys treats as a PRESENT-but-wrong-length key
       — SUSigningInputStatusInvalid — and SPUUpdater refuses to start at
       all (SUNoPublicDSAFoundError) regardless of anything else being
       correct. So: omit this key entirely until the maintainer generates a
       real EdDSA keypair; do not "fill in" with an empty string. -->
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
FRAMEWORK_DEST="$APP/Contents/MacOS/Sparkle.framework"
if [ -d "$SPARKLE_SRC" ]; then
  cp -R "$SPARKLE_SRC" "$FRAMEWORK_DEST"
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

# We deliberately do NOT use `--deep` on the framework. SPM's vendored
# Sparkle.framework arrives from Sparkle's own build already signed
# (ad-hoc) WITH the hardened runtime flag and entitlements on every nested
# item (the framework binary, Autoupdate, Updater.app, and both XPC
# services). `--deep` re-signs all of that nested code with a bare default
# signature, which strips the hardened runtime flag and drops entitlements
# — confirmed by reading back `codesign -dvv` flags before and after:
# 0x10002(adhoc,runtime) became 0x0(none). That is a notarization
# rejection this task exists to prevent, introduced by the very tool meant
# to prevent it.
#
# Instead we re-sign each nested code object explicitly, innermost first,
# with our OWN identity (required — nested code left at the vendor's
# ad-hoc signature would still fail notarization even with the runtime
# flag intact, since ad-hoc isn't a Developer ID), and
# `--preserve-metadata=entitlements` to carry over the entitlements each
# item already has from Sparkle's build rather than guessing at
# .entitlements files we don't own. `--options runtime` re-adds the
# hardened runtime flag our own signature would otherwise omit.
sign_nested() {
  codesign --force --sign "$SIGN_ID" --options runtime --preserve-metadata=entitlements "$1"
}

sign_nested "$FRAMEWORK_DEST/Versions/B/XPCServices/Downloader.xpc"
sign_nested "$FRAMEWORK_DEST/Versions/B/XPCServices/Installer.xpc"
sign_nested "$FRAMEWORK_DEST/Versions/B/Updater.app"
sign_nested "$FRAMEWORK_DEST/Versions/B/Autoupdate"
sign_nested "$FRAMEWORK_DEST"

# Sign the app with hardened runtime, adding
# com.apple.security.cs.disable-library-validation only if needed (R9) —
# see Scripts/lib/sign-app-with-workaround.sh for the full rationale. That
# script is also what BundleLayoutTests.swift exercises directly (with a
# synthetic Developer-ID-shaped identity injected via
# SNITT_FAKE_TEAM_IDENTIFIER_LINE) to prove the "has a real team, skip the
# entitlement" branch actually works, since no real Developer ID exists in
# this repo to produce that signature for real.
./Scripts/lib/sign-app-with-workaround.sh "$APP" "$SIGN_ID"

if [ "$STABLE_IDENTITY" = "1" ]; then
  echo "Signed with stable identity: $IDENTITY"
  echo "TCC grants will persist across rebuilds."
fi
echo "Built $APP"
