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
# Usage: Scripts/notarize.sh <path-to-app>|<path-to-dmg>
#        Scripts/notarize.sh --check-credentials
#
# `--check-credentials` resolves credentials exactly as a real run would and
# exits — no artifact, no network, no submission. It exists so a release can
# fail on a missing credential in its first second rather than after a
# universal build (which is what happened on the 0.3.0 attempt). It is the
# SAME code path, deliberately: a second copy of "what counts as a valid
# credential" living in the release script is how the two drift, and the
# drift is invisible until a release stops at step 3.
#
# Accepts either the .app bundle or the .dmg installer built from it, because
# each needs its OWN notarization ticket. Notarizing the app does not notarize
# a DMG that later contains it — Gatekeeper assesses the downloaded .dmg on its
# own, quarantined from the browser, before the user ever reaches the app. The
# app is submitted as a ditto zip (a bundle is a directory; notarytool takes a
# file); a DMG is already a file and is submitted as itself.
#
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
  echo "usage: $(basename "$0") <path-to-app>|<path-to-dmg>" >&2
  echo "       $(basename "$0") --check-credentials" >&2
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
CHECK_CREDENTIALS_ONLY=0
if [ "${1-}" = "--check-credentials" ]; then
  CHECK_CREDENTIALS_ONLY=1
  shift
  # A placeholder that never reaches a filesystem check: the credential
  # block below runs, and this mode exits before anything touches $APP.
  set -- "--check-credentials"
fi

if [ $# -lt 1 ]; then
  echo "error: missing required argument: <path-to-app>|<path-to-dmg>" >&2
  usage
  exit 1
fi

APP="${1-}"

if [ -z "$APP" ]; then
  echo "error: <path-to-app>|<path-to-dmg> must not be empty" >&2
  usage
  exit 1
fi

# The artifact checks below are about an artifact, and --check-credentials
# has none. Guarded rather than reordered: the credential resolution has to
# stay where a real run reaches it, so that this mode and a real run cannot
# resolve differently.
if [ "$CHECK_CREDENTIALS_ONLY" -eq 0 ]; then
  if [ ! -e "$APP" ]; then
    echo "error: no such file or directory: $APP" >&2
    exit 1
  fi
fi

# Which of the two things this is decides how it gets submitted and how it
# gets assessed afterwards. Detected from the artifact itself, never from a
# flag: a caller who passes the wrong flag would get a run that succeeds at
# every step and produces something Gatekeeper rejects.
if [ "$CHECK_CREDENTIALS_ONLY" -eq 1 ]; then
  KIND=app
elif [ -d "$APP" ] && [ -f "$APP/Contents/Info.plist" ]; then
  KIND=app
elif [ -f "$APP" ] && [ "${APP##*.}" = "dmg" ]; then
  KIND=dmg
else
  echo "error: $APP does not look like an app bundle (missing Contents/Info.plist), and is not a .dmg" >&2
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
# `--deep` for a bundle, which has nested code to walk; a DMG has none, so
# --deep would be a no-op that only obscures which check actually ran.
if [ "$KIND" = app ]; then
  CODESIGN_VERIFY=(--verify --deep --strict)
  SIGN_HINT="sign it first — see ./Scripts/make-app.sh — before notarizing"
else
  CODESIGN_VERIFY=(--verify --strict)
  SIGN_HINT="sign it first — see ./Scripts/make-dmg.sh, which signs the image when SNITT_SIGN_IDENTITY is set"
fi
if [ "$CHECK_CREDENTIALS_ONLY" -eq 0 ] \
   && ! codesign "${CODESIGN_VERIFY[@]}" "$APP" >/dev/null 2>&1; then
  echo "error: $APP is not validly signed (codesign ${CODESIGN_VERIFY[*]} failed)" >&2
  echo "$SIGN_HINT" >&2
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

if [ "$CHECK_CREDENTIALS_ONLY" -eq 1 ]; then
  # PROVE it, don't just resolve it. Resolution alone answers "is a
  # credential named here", which for the keychain-profile path is only "is
  # NOTARY_PROFILE non-empty" — so `NOTARY_PROFILE=typo` passed this check
  # and failed at submission, after a universal build. That is the exact
  # failure this mode exists to move earlier, arriving through the other
  # door.
  #
  # `notarytool history` is the cheapest call that exercises the credential
  # end to end: about a second, no artifact, nothing submitted, and it fails
  # loudly on a profile that does not exist or a key that is not accepted.
  #
  # Deliberately NOT in the shared resolution block above. A real
  # notarization is about to talk to Apple anyway and does not need a probe
  # first; putting it there would add a round trip to every submission and
  # change behaviour for a path that is working.
  if ! probe="$(xcrun notarytool history "${NOTARIZE_ARGS[@]}" 2>&1)"; then
    echo "error: notarization credentials did not work." >&2
    if [ -n "$NOTARY_PROFILE_VALUE" ]; then
      echo "the keychain profile '$NOTARY_PROFILE_VALUE' is named but did not" >&2
      echo "authenticate. Check the name against the profiles you have created" >&2
      echo "with 'xcrun notarytool store-credentials'." >&2
    else
      echo "the API key $NOTARY_KEY_ID_VALUE did not authenticate." >&2
    fi
    # Apple's own message, which names the real cause far better than
    # anything this script could infer. Last, so it does not bury the above.
    printf '%s\n' "$probe" >&2
    exit 1
  fi
  # Names the credential, never its value — this prints into a release log.
  if [ -n "$NOTARY_PROFILE_VALUE" ]; then
    echo "notarization credentials: keychain profile '$NOTARY_PROFILE_VALUE' (verified)"
  else
    echo "notarization credentials: API key $NOTARY_KEY_ID_VALUE (verified)"
  fi
  exit 0
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

if [ "$KIND" = app ]; then
  SUBMISSION="$ZIP_DIR/$(basename "$APP" .app).zip"
  echo "==> Zipping $APP for submission..."
  ditto -c -k --keepParent "$APP" "$SUBMISSION"
else
  # Already a single file. Zipping it would submit an archive OF a disk image
  # rather than the disk image, and the ticket would staple to nothing.
  SUBMISSION="$APP"
fi

echo "==> Submitting to Apple's notary service (this can take several minutes)..."
if ! xcrun notarytool submit "$SUBMISSION" "${NOTARIZE_ARGS[@]}" --wait; then
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

# `--type execute` asks "may this run"; a disk image is not executed, it is
# opened, and assessing one as executable reports rejected on an image that is
# perfectly good. `--context context:primary-signature` is what makes the
# open-assessment read the DMG's own signature rather than looking for a
# quarantine origin the freshly-built file does not have yet.
if [ "$KIND" = app ]; then
  SPCTL_ARGS=(--assess --type execute -vv)
else
  SPCTL_ARGS=(--assess --type open --context context:primary-signature -vv)
fi
echo "==> Verifying with spctl (the same check Gatekeeper performs)..."
if ! spctl "${SPCTL_ARGS[@]}" "$APP"; then
  echo "error: spctl --assess failed after stapling — $APP will not be trusted on a clean machine" >&2
  exit 1
fi

echo "==> Notarized, stapled, and verified: $APP"
