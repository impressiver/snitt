#!/bin/bash
# Signs an app bundle with hardened runtime, then conditionally adds
# com.apple.security.cs.disable-library-validation (R9) only when the
# signing identity has no real Team ID. Factored out of make-app.sh so this
# exact, production signing path can be exercised directly in a test
# against a Developer-ID-shaped identity — there's no real paid Developer
# ID in this repo, so BundleLayoutTests.swift injects one via
# SNITT_FAKE_TEAM_IDENTIFIER_LINE rather than asserting against a fixture
# the test wrote itself. See that file's
# signingWithADeveloperIDShapedIdentityCarriesNoWorkaround for the real
# proxy this enables.
#
# Usage: sign-app-with-workaround.sh <app-bundle-path> <sign-identity>
#
# SNITT_FAKE_TEAM_IDENTIFIER_LINE, if set, replaces the `codesign -dvv`
# TeamIdentifier read below. Never set this in normal use — only tests set
# it, to run this real script against a synthetic identity.
set -euo pipefail

APP="$1"
SIGN_ID="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Signing order is the whole risk here: codesign signs inner code before the
# enclosing bundle. An unsigned (or wrongly-signed) framework inside a signed
# app can launch fine from Finder on this machine and fail Gatekeeper or
# notarization on someone else's, with no local reproduction.
#
# Hardened runtime on the app enables library validation: dyld will refuse
# to load a dylib/framework whose signing Team ID doesn't match the main
# executable's. Confirmed by direct reproduction: even signing the app and
# every nested Sparkle item with the SAME identity ("Snitt Development",
# self-signed, TeamIdentifier "not set" on both), the app failed to launch
# with "different Team IDs" from dyld — a self-signed identity has no real
# Team ID, so two separately-produced signatures are never treated as
# matching, "not set" included.
#
# R9: this workaround must NOT ship unconditionally. Snitt holds Screen
# Recording and Microphone TCC grants and embeds an updater that downloads
# and runs code; com.apple.security.cs.disable-library-validation lets any
# validly-signed dylib — signed by anyone, not just Snitt's team — load
# into that process. A real Developer ID gives the app and its re-signed
# nested Sparkle components one genuine, matching Team ID, so library
# validation is satisfied without widening it. So: sign the app first
# WITHOUT the entitlement, read back whether the identity that just signed
# it has a real Team ID, and only add the entitlement (re-signing) when it
# does not. `needs-teamless-workaround.sh` holds the actual decision so it
# can also be unit-tested in isolation with a synthetic TeamIdentifier line.
codesign --force --sign "$SIGN_ID" --options runtime "$APP"

if [ -n "${SNITT_FAKE_TEAM_IDENTIFIER_LINE:-}" ]; then
  TEAM_LINE="$SNITT_FAKE_TEAM_IDENTIFIER_LINE"
else
  TEAM_LINE="$(codesign -dvv "$APP" 2>&1 | grep '^TeamIdentifier=' || true)"
fi

if [ -z "$TEAM_LINE" ]; then
  echo "error: could not read a TeamIdentifier= line from codesign -dvv \"$APP\" — refusing to guess" >&2
  exit 1
fi

if [ "$("$SCRIPT_DIR/needs-teamless-workaround.sh" "$TEAM_LINE")" = "yes" ]; then
  echo "No real Team ID ($TEAM_LINE) — adding disable-library-validation so the embedded framework can still load." >&2
  ENTITLEMENTS_DIR="$(mktemp -d -t snitt-app-entitlements)"
  ENTITLEMENTS="$ENTITLEMENTS_DIR/entitlements.plist"
  cat > "$ENTITLEMENTS" <<ENTITLEMENTS_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
ENTITLEMENTS_PLIST
  codesign --force --sign "$SIGN_ID" --options runtime --entitlements "$ENTITLEMENTS" "$APP"
  rm -rf "$ENTITLEMENTS_DIR"
else
  echo "Real Team ID ($TEAM_LINE) — library validation satisfied without any extra entitlement."
fi
