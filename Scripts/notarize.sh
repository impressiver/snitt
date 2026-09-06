#!/bin/bash
# Submits a signed Snitt.app to Apple's notary service, staples the ticket,
# then re-verifies with spctl the way Gatekeeper will on someone else's
# machine.
#
# The maintainer's decision (binding, see task-4-brief.md): this script is
# RUN BY A HUMAN with real credentials, never by CI, and NOTHING SECRET
# EVER ENTERS THIS REPO. It reads credentials from the environment or from
# a `notarytool` keychain profile — see CREDENTIALS below — and does
# nothing else with them beyond passing them straight to `xcrun
# notarytool`. It creates no files under version control and does not log
# credential values.
#
# This script does NOT sign anything. Signing is Task 2's job
# (Scripts/make-app.sh / Scripts/lib/sign-app-with-workaround.sh); this
# script only accepts an already-signed bundle, validates it, and submits
# it. If the bundle isn't validly signed, this refuses to proceed rather
# than let Apple's notary service produce a more opaque rejection later.
#
# Usage: Scripts/notarize.sh <path-to-app>
#
# CREDENTIALS (in this precedence order — the first one found wins):
#   1. NOTARY_PROFILE   Name of a notarytool keychain profile, created once
#                        with:
#                          xcrun notarytool store-credentials <profile-name> \
#                            --apple-id <email> --team-id <TEAMID> --password <app-specific-password>
#                        Preferred: the credential itself lives in the
#                        keychain, not in a shell environment variable.
#   2. NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                        An App Store Connect API key: NOTARY_KEY is a path
#                        to the downloaded .p8 private key file, NOTARY_KEY_ID
#                        is its Key ID, NOTARY_ISSUER is the Issuer ID. All
#                        three are required together — this script fails
#                        loudly naming exactly which are missing rather than
#                        submitting with a partial credential.
#
# If NOTARY_PROFILE is set to a non-empty value, the NOTARY_KEY* trio is
# IGNORED even if also set — a keychain profile is the simpler, less
# secret-shaped path, so a maintainer who has one configured gets it
# without needing to unset the other three.
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <path-to-app>" >&2
  echo "" >&2
  echo "credentials (first found wins):" >&2
  echo "  NOTARY_PROFILE                              notarytool keychain profile name" >&2
  echo "  NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER     App Store Connect API key (.p8 path, key id, issuer id)" >&2
  echo "" >&2
  echo "see Scripts/notarize.sh's header comment for how to create a keychain profile." >&2
}

# An explicitly empty first argument ("") is a distinct, reportable case
# from no argument at all ($# -eq 0) — R15 already burned this project once
# on exactly this distinction. The protection here is the `$# -lt 1` guard
# below PLUS the separate `-z "$APP"` check further down — NOT the `${1-}`
# expansion form on its own: once the guard has confirmed $# >= 1, $1 is
# always set, so `${1-}` and `${1:-}` are identical from this point on and
# neither one "covers" the empty-string case by itself. Do not read this as
# license to drop the `-z` check below — that check is the only thing
# actually distinguishing an empty argument from a real path.
if [ $# -lt 1 ]; then
  echo "error: missing required argument: <path-to-app>" >&2
  usage
  exit 1
fi

APP="${1-}"

if [ -z "$APP" ]; then
  echo "error: <path-to-app> must not be empty" >&2
  usage
  exit 1
fi

if [ ! -e "$APP" ]; then
  echo "error: no such file or directory: $APP" >&2
  exit 1
fi

if [ ! -d "$APP" ] || [ ! -f "$APP/Contents/Info.plist" ]; then
  echo "error: $APP does not look like an app bundle (missing Contents/Info.plist)" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found — this script requires macOS with the Xcode command line tools installed" >&2
  echo "run: xcode-select --install" >&2
  exit 1
fi

if ! xcrun --find notarytool >/dev/null 2>&1; then
  echo "error: xcrun notarytool not found — notarytool ships with Xcode 13+ command line tools" >&2
  echo "run: xcode-select --install (or update Xcode if it's older than 13)" >&2
  exit 1
fi

# R30: spctl ships at /usr/sbin on every macOS install and `set -e` would
# fail loudly anyway if it were somehow missing, but probe it explicitly
# for the same reason as xcrun/notarytool above — a named, specific error
# here beats an unexplained failure three network round-trips later, on
# whichever machine happens to be missing it.
if ! command -v spctl >/dev/null 2>&1; then
  echo "error: spctl not found — this script requires macOS's Gatekeeper assessment tool" >&2
  exit 1
fi

# Refuse an unsigned or invalidly-signed bundle up front. notarytool would
# eventually reject this too, but only after a network round-trip, and with
# a message about the submission rather than about the actual cause.
if ! codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  echo "error: $APP is not validly signed (codesign --verify --deep --strict failed)" >&2
  echo "sign it first — see ./Scripts/make-app.sh — before notarizing" >&2
  exit 1
fi

NOTARY_PROFILE_VALUE="${NOTARY_PROFILE-}"
NOTARY_KEY_VALUE="${NOTARY_KEY-}"
NOTARY_KEY_ID_VALUE="${NOTARY_KEY_ID-}"
NOTARY_ISSUER_VALUE="${NOTARY_ISSUER-}"

NOTARIZE_ARGS=()

if [ -n "$NOTARY_PROFILE_VALUE" ]; then
  NOTARIZE_ARGS=(--keychain-profile "$NOTARY_PROFILE_VALUE")
else
  missing=()
  [ -z "$NOTARY_KEY_VALUE" ] && missing+=("NOTARY_KEY")
  [ -z "$NOTARY_KEY_ID_VALUE" ] && missing+=("NOTARY_KEY_ID")
  [ -z "$NOTARY_ISSUER_VALUE" ] && missing+=("NOTARY_ISSUER")

  if [ ${#missing[@]} -gt 0 ]; then
    echo "error: no notarization credentials found." >&2
    echo "set NOTARY_PROFILE to a notarytool keychain profile name, or set" >&2
    echo "all three of NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER." >&2
    echo "missing: ${missing[*]}" >&2
    exit 1
  fi

  if [ ! -f "$NOTARY_KEY_VALUE" ]; then
    echo "error: NOTARY_KEY does not point at a file: $NOTARY_KEY_VALUE" >&2
    exit 1
  fi

  NOTARIZE_ARGS=(--key "$NOTARY_KEY_VALUE" --key-id "$NOTARY_KEY_ID_VALUE" --issuer "$NOTARY_ISSUER_VALUE")
fi

# ditto, not zip: this is Apple's own recommended way to zip an .app for
# notarytool, because it preserves the extended attributes and resource
# forks a plain `zip` can silently drop, which can invalidate the signature
# inside the archive that notarytool inspects.
ZIP_DIR="$(mktemp -d -t snitt-notarize)"
cleanup() {
  rm -rf "$ZIP_DIR"
}
trap cleanup EXIT

ZIP="$ZIP_DIR/$(basename "$APP" .app).zip"

echo "==> Zipping $APP for submission..."
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple's notary service (this can take several minutes)..."
if ! xcrun notarytool submit "$ZIP" "${NOTARIZE_ARGS[@]}" --wait; then
  echo "error: xcrun notarytool submit failed — see output above" >&2
  exit 1
fi
# Known, unverified-here uncertainty (review finding, not a bug): on some
# Xcode versions `notarytool submit --wait` has been reported to exit 0
# even when the submission's own status is "Invalid" rather than
# "Accepted". If that happens, this script does not stop here — but the
# next step cannot silently succeed either: `stapler staple` has no ticket
# to attach for a rejected submission and fails loudly, so the run still
# ends in a correct, non-distributable failure rather than a false
# success. If notarytool ever prints a non-Accepted status above, treat it
# as a real rejection even if this script's own exit code doesn't catch it.

# A successful submit does NOT mean the app is stapled. An unstapled app
# only works while the machine running it can reach Apple's servers to
# check notarization online — a stapled ticket is what works offline, on
# someone else's machine, which is the whole point of this script.
echo "==> Stapling notarization ticket..."
if ! xcrun stapler staple "$APP"; then
  echo "error: stapler staple failed — the submission may have succeeded but the ticket is not attached to $APP" >&2
  echo "the bundle at $APP is signed but NOT stapled; do not distribute it in this state" >&2
  exit 1
fi

echo "==> Verifying with spctl (the same check Gatekeeper performs)..."
if ! spctl --assess --type execute -vv "$APP"; then
  echo "error: spctl --assess failed after stapling — $APP will not be trusted on a clean machine" >&2
  exit 1
fi

echo "==> Notarized, stapled, and verified: $APP"
