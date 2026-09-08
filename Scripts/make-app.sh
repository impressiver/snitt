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

# The two client frontends ship INSIDE the app (D63). Until v0.1.0 they were
# built and then left in .build/, so an installed Snitt.app carried no `snitt`
# and no `snitt-mcp` at all — the entire agent surface §13's second validation
# question depends on was absent from the artifact that was signed, notarized
# and released. They are thin clients by construction (§4.9): they hold no TCC
# grant and only ask the running app to act, so shipping them inside the bundle
# costs nothing but bytes and gives `snitt setup` one fixed place to point at.
swift build -c debug --product snitt-cli
swift build -c debug --product snitt-mcp

for required in SnittApp snitt-cli snitt-mcp; do
  if [ ! -f ".build/debug/$required" ]; then
    echo "error: swift build did not produce .build/debug/$required" >&2
    exit 1
  fi
done

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
  <!-- Without this key Snitt shows the generic document icon in the Dock,
       the Finder, and Cmd-Tab. Resources/AppIcon.icns is generated from
       Resources/AppIcon.png by Scripts/make-app-icon.sh (source: Scripts
       generate-app-icon.swift), and copied into place below alongside the
       rest of this script's asset copies. -->
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
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
  <!-- D62/D68: transcription is on-device only; this grant never sends audio
       anywhere. Requested at first USE of transcription, not at launch
       (the 4.10 ladder). -->
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Snitt transcribes your narration on this Mac to make recordings searchable and editable as text. Audio never leaves your computer.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Snitt records your microphone when you enable it for a recording.</string>
  <!-- A .snitt is a DIRECTORY bundle, so the exported type must conform to
       com.apple.package. Without that the Finder presents it as a folder and
       a double-click navigates into it rather than opening Snitt — every key
       below is present and nothing works. -->
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.impressiver.snitt.recording</string>
      <key>UTTypeDescription</key><string>Snitt Recording</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>com.apple.package</string>
        <string>public.composite-content</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array><string>snitt</string></array>
      </dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Snitt Recording</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSTypeIsPackage</key><true/>
      <key>LSItemContentTypes</key>
      <array><string>com.impressiver.snitt.recording</string></array>
    </dict>
  </array>
  <!-- Task 5's Scripts/make-appcast.sh generates the real appcast this URL
       points at (run with --output, whose only accepted filename is
       this URL's own basename, "appcast.xml" — enforced by the script
       itself and cross-checked against this exact line by
       Tests/SnittAppTests/AppcastTests.swift's
       feedURLAndScriptOutputAgreeOnFilename, so the two cannot drift
       apart silently again). The maintainer uploads that generated file
       as the latest GitHub release's "appcast.xml" asset.

       GitHub's own releases.atom is Atom (<feed>/<entry>), not a Sparkle
       appcast: SUAppcast.m parses /rss/channel/item and needs
       <enclosure sparkle:version=…>, which an Atom feed never emits, so
       pointing at releases.atom would make every check silently find zero
       items. Do not "simplify" this into pointing at GitHub's Atom feed
       instead. -->
  <key>SUFeedURL</key>
  <string>https://github.com/impressiver/snitt/releases/latest/download/appcast.xml</string>
  <!-- The EdDSA public half. Its private counterpart lives ONLY in the
       maintainer's login keychain (service https://sparkle-project.org,
       account ed25519) and must never enter this repo. A public key is not
       a secret — this line is meant to be committed.

       Generated by Scripts/generate-sparkle-key.sh. If this value ever
       disagrees with the key sign_update signs with, updates verify on
       the machine that built them and fail everywhere else.

       Never replace this with an empty string to "disable" signing.
       Verified against Sparkle 2.9.6 (SUSignatures.m/SUHost.m): an ABSENT
       key reads as nil → SUSigningInputStatusAbsent, and Sparkle falls back
       to requiring the update be code-signed to match the installed app.
       But an EMPTY STRING is different and worse — NSData(base64Encoded:
       "") decodes to a valid zero-length NSData (confirmed by direct test,
       not assumed), which SUPublicKeys reads as PRESENT-but-wrong-length,
       SUSigningInputStatusInvalid, and SPUUpdater then refuses to start at
       all with SUNoPublicDSAFoundError no matter what else is correct.
       To go back to no key, delete the two lines below entirely. -->
  <key>SUPublicEDKey</key>
  <string>UJ2st1l244uWYJzO1Oe9pDfoWDsM5AbOzjxhlIk+6Hk=</string>
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

# `snitt-cli` builds under its target name; it ships as `snitt`, which is the
# name §8's whole CLI surface is written in and the name a person or an agent
# types. Renaming here rather than in Package.swift keeps the target name
# matching its Sources/ directory.
#
# NOT Contents/MacOS: macOS filesystems are case-INSENSITIVE by default, so
# `Contents/MacOS/snitt` and the app's own `Contents/MacOS/Snitt` are one path
# — copying the CLI there silently REPLACES the app binary with it, producing a
# bundle that looks complete, signs and notarizes cleanly, and launches a
# command-line tool with no UI. Caught by BundleLayoutTests' rpath check on the
# first build after this was written. A separate directory removes the
# collision rather than relying on nobody renaming anything.
mkdir -p "$APP/Contents/Helpers"
cp ".build/debug/snitt-cli" "$APP/Contents/Helpers/snitt"
cp ".build/debug/snitt-mcp" "$APP/Contents/Helpers/snitt-mcp"

# Must exist before signing: codesign seals Contents/Resources into the
# app's signature, so an icon dropped in afterward would invalidate it.
if [ ! -f "Resources/AppIcon.icns" ]; then
  echo "error: Resources/AppIcon.icns not found — run ./Scripts/make-app-icon.sh first" >&2
  exit 1
fi
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

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
if [ -n "${SNITT_SIGN_IDENTITY+x}" ]; then
  # An identity was explicitly requested (the release path — see
  # docs/superpowers/notes/release-runbook.md step 1). Do NOT catch a
  # failure here and fall back to ad-hoc: a release build that asked for a
  # specific identity and silently got ad-hoc instead is precisely the
  # "signed with the wrong certificate" failure this variable exists to
  # prevent. `set -e` on this plain assignment (not wrapped in `[ ... ]` or
  # an `if`) already makes signing-identity.sh's exit status fatal here, so
  # its own loud error is what the caller sees.
  IDENTITY="$(./Scripts/signing-identity.sh)"
  SIGN_ID="$IDENTITY"
  STABLE_IDENTITY=1
elif IDENTITY="$(./Scripts/signing-identity.sh)"; then
  SIGN_ID="$IDENTITY"
  STABLE_IDENTITY=1
else
  SIGN_ID="-"
  echo "WARNING: signing ad-hoc. The app's identity changes on every build, so" >&2
  echo "macOS will forget Screen Recording permission each time you rebuild." >&2
  echo "Run ./Scripts/signing-identity.sh for one-time setup instructions." >&2
fi

# Every codesign call below (this script's nested-item signs, plus both of
# Scripts/lib/sign-app-with-workaround.sh's) adds a secure timestamp by
# default and honors SNITT_SKIP_TIMESTAMP=1 as an explicit, per-invocation
# offline opt-out. See Scripts/lib/sign-nested-item.sh and
# Scripts/lib/sign-app-with-workaround.sh for the shared rationale (Apple's
# notary service rejects an untimestamped binary; --timestamp is a
# confirmed no-op for ad-hoc but a confirmed hard failure against an
# unreachable server for a real identity) — not repeated here to avoid it
# drifting out of sync across three copies.

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
#
# The actual codesign call lives in Scripts/lib/sign-nested-item.sh, not
# inline here, for the same reason Scripts/lib/sign-app-with-workaround.sh
# was already factored out: so this exact production signing call can be
# exercised directly by a test, independent of the full app build.
sign_nested() {
  ./Scripts/lib/sign-nested-item.sh "$1" "$SIGN_ID"
}

# The client executables are nested code too, and nested code that is
# unsigned — or signed with anything other than the app's own identity —
# fails notarization exactly the way the Sparkle items did. Signed BEFORE
# the app bundle below, because sealing the bundle hashes what is inside it.
sign_nested "$APP/Contents/Helpers/snitt"
sign_nested "$APP/Contents/Helpers/snitt-mcp"

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
# entitlement" branch actually works on a machine with no Developer ID
# installed. A real Developer ID (selected via SNITT_SIGN_IDENTITY, see
# docs/superpowers/notes/release-runbook.md step 1) exercises that same
# branch for real — SNITT_FAKE_TEAM_IDENTIFIER_LINE refuses to fire once a
# genuine Team ID is already present (R28), so the synthetic seam cannot
# mask the real one.
./Scripts/lib/sign-app-with-workaround.sh "$APP" "$SIGN_ID"

if [ "$STABLE_IDENTITY" = "1" ]; then
  echo "Signed with stable identity: $IDENTITY"
  echo "TCC grants will persist across rebuilds."
fi
echo "Built $APP"
