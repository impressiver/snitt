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
# it, to run this real script against a synthetic identity. R28: the
# override REFUSES to apply if the signature just produced already carries
# a genuine (non-"not set") Team ID — see below — so it cannot mask a real
# identity even if left exported in a shell.
set -euo pipefail

APP="$1"
SIGN_ID="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# See Scripts/make-app.sh's matching block for the full rationale (Apple
# rejects every unsigned-with-a-secure-timestamp binary on notarization;
# `--timestamp` is a confirmed no-op for ad-hoc but a confirmed hard
# failure against an unreachable server for a real identity). Timestamp by
# default; SNITT_SKIP_TIMESTAMP=1 is the explicit, per-invocation opt-out
# for offline work under a real (non-ad-hoc) identity — set for one run,
# never left exported, same discipline as SNITT_FAKE_TEAM_IDENTIFIER_LINE
# below.
TIMESTAMP_ARGS=()
if [ "${SNITT_SKIP_TIMESTAMP:-}" != "1" ]; then
  TIMESTAMP_ARGS=(--timestamp)
fi

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
# The microphone entitlement is NOT conditional and NOT a workaround.
#
# Snitt ships with the Hardened Runtime on (`--options runtime` below). Apple's
# Hardened Runtime page lists com.apple.security.device.audio-input among the
# access permissions it gates — "whether the app may record audio using the
# built-in microphone and access audio input using Core Audio" — and says "The
# default value of these Boolean entitlements is false". So a hardened app that
# never declares it cannot reach the microphone, whatever TCC says.
#
# The symptom is silence, not an error: AVCaptureDevice.requestAccess(for:
# .audio) is refused before TCC registers a client, so the app never appears
# under Privacy & Security > Microphone at all. Nothing to switch on, no
# dialog, no log. Reported from a clean install on a second Mac; invisible on
# any machine that granted the permission to an earlier build.
#
# Screen Recording, Input Monitoring and Speech Recognition are NOT on that
# list, which is why only the microphone broke — it is the one capability
# Snitt uses that the Hardened Runtime gates.
ENTITLEMENTS_DIR="$(mktemp -d -t snitt-app-entitlements)"
trap 'rm -rf "$ENTITLEMENTS_DIR"' EXIT
ENTITLEMENTS="$ENTITLEMENTS_DIR/entitlements.plist"

write_entitlements() {
  # $1: extra keys to add inside the dict, or empty for the baseline.
  cat > "$ENTITLEMENTS" <<ENTITLEMENTS_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>$1
</dict>
</plist>
ENTITLEMENTS_PLIST
}

write_entitlements ""
codesign --force --sign "$SIGN_ID" --options runtime --entitlements "$ENTITLEMENTS" \
  "${TIMESTAMP_ARGS[@]+"${TIMESTAMP_ARGS[@]}"}" "$APP"

REAL_TEAM_LINE="$(codesign -dvv "$APP" 2>&1 | grep '^TeamIdentifier=' || true)"

if [ -n "${SNITT_FAKE_TEAM_IDENTIFIER_LINE:-}" ]; then
  # R28: refuse to substitute a fake TeamIdentifier when the signature we
  # JUST PRODUCED already carries a genuine one. The override exists only
  # so a test can exercise the "real Team ID, skip the workaround" branch
  # without a real Developer ID in this repo; it must be structurally
  # incapable of MASKING a real identity once one exists — which is
  # exactly the moment this matters: the maintainer's first Developer-ID
  # run, under release pressure, with this variable possibly still
  # exported in a shell from an earlier test session.
  if [ -n "$REAL_TEAM_LINE" ] && [ "$REAL_TEAM_LINE" != "TeamIdentifier=not set" ]; then
    echo "error: SNITT_FAKE_TEAM_IDENTIFIER_LINE is set but the signature just produced already carries a genuine Team ID ($REAL_TEAM_LINE) — refusing to override a real identity" >&2
    exit 1
  fi
  TEAM_LINE="$SNITT_FAKE_TEAM_IDENTIFIER_LINE"
else
  TEAM_LINE="$REAL_TEAM_LINE"
fi

if [ -z "$TEAM_LINE" ]; then
  echo "error: could not read a TeamIdentifier= line from codesign -dvv \"$APP\" — refusing to guess" >&2
  exit 1
fi

# N8: this used to be `if [ "$("$SCRIPT_DIR/needs-teamless-workaround.sh" ...)" = "yes" ]`
# directly inside the `[` test. Under `set -e`, a command substitution's
# exit status is NOT propagated by the surrounding `[ ... ]` — if the
# decision script can't even execute (not executable, missing, chmod'd
# away), `$(...)` silently produces an empty string, `[ "" = "yes" ]` is
# false, and this script took the ELSE branch: no entitlement applied, exit
# 0, having decided "Real Team ID" without ever asking the question. A
# signing script that fails OPEN — silently proceeding as if a real Team ID
# were present — is the wrong failure direction for something this
# security-relevant. Capture the decision and its exit status separately
# so a failure to run is a hard, loud failure instead of a wrong answer.
if ! DECISION="$("$SCRIPT_DIR/needs-teamless-workaround.sh" "$TEAM_LINE")"; then
  echo "error: $SCRIPT_DIR/needs-teamless-workaround.sh failed to run against \"$TEAM_LINE\" — refusing to guess whether the workaround is needed" >&2
  exit 1
fi

if [ "$DECISION" = "yes" ]; then
  echo "No real Team ID ($TEAM_LINE) — adding disable-library-validation so the embedded framework can still load." >&2
  # Re-signing REPLACES the entitlement set, so the microphone key has to be
  # rewritten alongside the workaround rather than added to it. Dropping it
  # here would restore the original bug on exactly the ad-hoc builds the
  # maintainer tests with.
  write_entitlements "
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>"
  codesign --force --sign "$SIGN_ID" --options runtime --entitlements "$ENTITLEMENTS" \
    "${TIMESTAMP_ARGS[@]+"${TIMESTAMP_ARGS[@]}"}" "$APP"
elif [ "$DECISION" = "no" ]; then
  echo "Real Team ID ($TEAM_LINE) — library validation satisfied without widening it; the app keeps the microphone entitlement only."
else
  echo "error: needs-teamless-workaround.sh returned an unexpected answer: \"$DECISION\" (expected yes/no) — refusing to guess" >&2
  exit 1
fi
