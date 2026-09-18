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

APP_VERSION="$(sed -nE 's/.*public static let marketing = "([^"]+)".*/\1/p' "$VERSION_SOURCE")"
if [ -z "$APP_VERSION" ]; then
  echo "error: could not extract AppVersion.marketing from $VERSION_SOURCE" >&2
  echo "refusing to write an empty CFBundleShortVersionString" >&2
  exit 1
fi

# The build number Sparkle actually compares (CFBundleVersion), kept DISJOINT
# from the human version above — which is Sparkle's own guidance, and what
# lets `main` carry `0.5.0-dev` without a development build claiming to be the
# real 0.5.0 and then refusing it when it ships.
#
# The commit count is the whole mechanism: strictly larger on every commit, so
# a later build always outranks an earlier one, and nobody has to remember to
# bump anything. `--first-parent` counts merges as one step, so the number a
# release gets does not depend on how many commits its PR happened to contain.
BUILD_NUMBER="$(git rev-list --count --first-parent HEAD 2>/dev/null || true)"
if [ -z "$BUILD_NUMBER" ]; then
  # A tarball with no .git, or a shallow clone. Refused rather than defaulted:
  # a CFBundleVersion of "0" or "1" would be LOWER than every shipped build,
  # so Sparkle would offer this app an "update" to a version it already has,
  # for ever. A loud failure is recoverable; that is not.
  echo "error: could not count commits for CFBundleVersion." >&2
  echo "       This must be a full git clone — Sparkle compares this number," >&2
  echo "       and a wrong one silently breaks updates rather than failing." >&2
  exit 1
fi

# Universal (arm64 + x86_64) whenever this is a RELEASE build, and on request
# otherwise. Every dependency is already universal — Sparkle ships both slices
# — so an arm64-only Snitt was the single thing stopping it launching on an
# Intel Mac, and macOS 26 is the last release those can run. Tying it to
# SNITT_SIGN_IDENTITY rather than leaving it a separate flag is deliberate: a
# release must not be able to ship one slice because somebody forgot a
# variable. Development builds stay native, because doubling every compile to
# serve a machine the developer does not have is a bad trade.
if [ -n "${SNITT_SIGN_IDENTITY+x}" ] || [ -n "${SNITT_UNIVERSAL+x}" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
  echo "Building universal (arm64 + x86_64)."
else
  ARCH_FLAGS=()
fi

# A RELEASE is never a debug build.
#
# Every release up to and including v0.6.1 shipped `-c debug`: unoptimised,
# carrying debug assertions, and compiling the `#if DEBUG` code that exists
# for previews and test seams. That is not what anyone should be installing.
#
# Tied to SNITT_SIGN_IDENTITY for the same reason the universal slice is: a
# release must not be able to ship the wrong configuration because somebody
# forgot a variable. Development builds stay debug, because waiting for an
# optimised build to check a layout change is a bad trade. SNITT_CONFIG
# overrides either way, for testing this script itself.
CONFIG="${SNITT_CONFIG:-}"
if [ -z "$CONFIG" ]; then
  if [ -n "${SNITT_SIGN_IDENTITY+x}" ]; then CONFIG="release"; else CONFIG="debug"; fi
fi
case "$CONFIG" in
  debug|release) ;;
  *) echo "error: SNITT_CONFIG must be 'debug' or 'release', got '$CONFIG'" >&2; exit 1 ;;
esac
echo "Building -c $CONFIG."

# ASK the build system where it writes. Never hardcode it.
#
# This used to be a literal: `.build/apple/Products/Debug` for multi-arch and
# `.build/debug` otherwise. A toolchain update moved the real output to
# `.build/out/Products/Debug` and left the old directory in place, holding a
# binary from the last build that used it. The existence check below passed,
# because the file was right there. Every universal build from then on copied
# a STALE app into the bundle, and universal is tied to SNITT_SIGN_IDENTITY,
# so that means every release: v0.6.0 and v0.6.1 both shipped an app binary
# frozen weeks earlier, while local development builds were correct. It
# surfaced as a shipped feature that had "disappeared" (#128's "Export for"
# picker) with no failure anywhere in the pipeline.
PRODUCT_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
if [ -z "$PRODUCT_DIR" ] || [ ! -d "$PRODUCT_DIR" ]; then
  echo "error: could not resolve the build output directory from swift build." >&2
  exit 1
fi

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product SnittApp

# The two client frontends ship INSIDE the app (D63). Until v0.1.0 they were
# built and then left in .build/, so an installed Snitt.app carried no `snitt`
# and no `snitt-mcp` at all — the entire agent surface §13's second validation
# question depends on was absent from the artifact that was signed, notarized
# and released. They are thin clients by construction (§4.9): they hold no TCC
# grant and only ask the running app to act, so shipping them inside the bundle
# costs nothing but bytes and gives `snitt setup` one fixed place to point at.
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product snitt-cli
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product snitt-mcp

for required in SnittApp snitt-cli snitt-mcp; do
  if [ ! -f "$PRODUCT_DIR/$required" ]; then
    echo "error: swift build did not produce $PRODUCT_DIR/$required" >&2
    exit 1
  fi
  # EXISTING is not the property that matters; FRESH is. A leftover from an
  # earlier toolchain satisfies `-f` forever and ships silently. If any source
  # file is newer than the binary we are about to copy, the binary is not the
  # source tree we are releasing.
  STALE_SOURCE="$(find Sources Package.swift -type f -newer "$PRODUCT_DIR/$required" -print -quit 2>/dev/null || true)"
  if [ -n "$STALE_SOURCE" ]; then
    echo "error: $PRODUCT_DIR/$required is OLDER than $STALE_SOURCE." >&2
    echo "       swift build reported success, so it wrote its output somewhere" >&2
    echo "       else and this file is a leftover. Copying it would ship code" >&2
    echo "       that is not in this tree. Check 'swift build --show-bin-path'." >&2
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
  <!-- Standard keys a shipped Mac app is expected to carry. None changes
       behaviour; their absence shows up in the About box, in Finder's
       "Kind" column, and in any store or catalogue listing. -->
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- developer-tools rather than video: what this records is work, and who
       it records it for is a developer or an agent acting for one (D66).
       Change it here if that ever stops being true. -->
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <!-- MPL-2.0 SECTION 3.2, and the reason this is not "All rights reserved".
       Distributing an executable obliges the distributor to "inform recipients
       of the Executable Form how they can obtain a copy of such Source Code
       Form by reasonable means in a timely manner", and to include that notice
       "conspicuously ... in any notice in an Executable version, related
       documentation or collateral in which You describe recipients' rights".

       The About box IS that notice for a Mac app: it is the one place a person
       looks to find out whose software this is. It previously read "All rights
       reserved", which is the opposite of what the licence says and was the
       only rights statement shipped in the binary. -->
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Ian White. Licensed under the Mozilla Public License 2.0. Source: https://github.com/impressiver/snitt</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <!-- Sparkle's SUHost.validVersion reads ONLY CFBundleVersion (not
       CFBundleShortVersionString above). Without it, SPUUpdater's own
       checkIfConfiguredProperlyAndRequireFeedURL: bails immediately with
       SUInvalidHostVersionError and the updater never starts — before any
       of the SU* keys below are even consulted.

       This is the monotonic build number, NOT the marketing version, and
       the two are deliberately disjoint — Sparkle asks that the version it
       compares be strictly numeric and that a human-readable string be kept
       apart from it. That separation is what lets main carry a -dev
       marketing version between releases: the marker changes what a person
       reads without touching what Sparkle compares.

       No backticks in this comment, deliberately. This heredoc delimiter is
       unquoted so APP_VERSION expands, which means a backtick would run as a
       command substitution while the plist is being written. -->
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
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
    <!-- Plain video, so a file can be dropped on the Dock icon or opened
         with Snitt from the Finder. Opening one IMPORTS it into a new
         document, which is why the role is Viewer rather than Editor: Snitt
         does not write back to somebody else's .mp4, it copies it into a
         bundle and edits that. Declaring Editor here would offer Snitt as a
         handler that owns the file, which it never becomes. -->
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.mpeg-4</string>
        <string>com.apple.quicktime-movie</string>
      </array>
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

if [ -f "$PRODUCT_DIR/SnittApp" ]; then
  cp "$PRODUCT_DIR/SnittApp" "$APP/Contents/MacOS/Snitt"
  # Sparkle.framework sits BESIDE this binary in Contents/MacOS, so the binary
  # needs an @loader_path rpath to find it.
  #
  # A single-arch `swift build` emits that rpath itself. A multi-arch one goes
  # through a different build path and emits `@executable_path/../lib`
  # INSTEAD — so the universal binary looks in Contents/lib, which does not
  # exist, and the app dies at launch with
  # "Library not loaded: @rpath/Sparkle.framework". Verified by running it:
  # exit 134, dyld naming both paths it tried.
  #
  # Added here rather than as a linker flag because this layout is make-app.sh's
  # decision, not the package's, and it must hold however the binary was built.
  # Before signing, deliberately: install_name_tool invalidates a signature.
  # Counted into a variable rather than `| grep -q`. Under `set -o pipefail`,
  # `grep -q` exits on the FIRST match and closes the pipe, so otool is killed
  # by SIGPIPE and the pipeline reports failure even though the match was
  # found. `!` then inverts that into "not present" and the tool runs anyway.
  # The guard therefore failed in exactly the case it was written for: only a
  # binary that ALREADY has the rpath can short-circuit grep. `|| true` keeps
  # grep's exit 1 (no match) from tripping `set -e`.
  RPATH_COUNT="$(otool -l "$APP/Contents/MacOS/Snitt" \
    | grep -cE 'path @loader_path \(offset' || true)"
  if [ "${RPATH_COUNT:-0}" -eq 0 ]; then
    install_name_tool -add_rpath "@loader_path" "$APP/Contents/MacOS/Snitt"
  fi
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
cp "$PRODUCT_DIR/snitt-cli" "$APP/Contents/Helpers/snitt"
cp "$PRODUCT_DIR/snitt-mcp" "$APP/Contents/Helpers/snitt-mcp"

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
# From the SAME resolved product directory as the binaries, not a literal.
# This was `.build/debug/Sparkle.framework`, which is the wrong tree for a
# universal build and the wrong configuration for a release one. It survived
# only because Sparkle is vendored and identical across configurations, which
# makes it a latent version of the bug that shipped two stale releases rather
# than a harmless inconsistency.
SPARKLE_SRC="$PRODUCT_DIR/Sparkle.framework"
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
