#!/bin/bash
# Builds Snitt-<version>.dmg — the drag-to-Applications installer a person
# downloads from GitHub Releases.
#
# THE DMG IS NOT AN UPDATE ARTIFACT. Sparkle's appcast enclosure is, and stays,
# the ZIP built in the release runbook's step 4. The DMG exists for one job:
# somebody arriving at the Releases page with no copy of Snitt installed. An
# existing install never fetches it, `make-appcast.sh` never names it, and
# pointing an appcast enclosure at a DMG would change how updates install for
# every user — so if you find yourself editing this script to serve an update,
# stop: the answer is the ZIP.
#
# Usage: Scripts/make-dmg.sh [path-to-app] [--output <path>] [--allow-unstapled]
#
#   [path-to-app]       Default build/Snitt.app. Must already be signed, and
#                       by default must already be NOTARIZED AND STAPLED.
#   --output <path>     Default Snitt-<version>.dmg in the current directory,
#                       where <version> is read from the app's own
#                       CFBundleShortVersionString — not from AppVersion.swift.
#                       The name has to describe the bundle actually inside it;
#                       reading the source of truth instead would let a stale
#                       build ship under a fresh version's name.
#   --allow-unstapled   Build from an app Gatekeeper would reject. LOCAL TESTING
#                       ONLY — see below for why the result is not publishable.
#
# ORDER: this runs AFTER notarizing and stapling the .app, never before.
#
# The runbook already explains this trap for the ZIP and it is the same trap
# here, one level deeper. Gatekeeper will accept a stapled DMG on first open,
# so a DMG built from an UNSTAPLED app looks completely fine: it mounts, the
# app launches, and `spctl` passes — on the machine that built it, and on any
# machine that can reach Apple's servers to check notarization online. Then the
# user drags the app to /Applications, which is the whole point of a DMG, and
# from that moment Gatekeeper is assessing the app on its own. With no ticket
# attached, an offline machine, a restrictive network, or an Apple outage turns
# it into "Snitt is damaged and can't be opened". Stapling the DMG does not fix
# that: a DMG's ticket covers the DMG, and the copied-out app is not the DMG.
# There is no local test that catches it, which is exactly why this script
# refuses rather than warns.
#
# Run from the repo root, like make-app.sh and make-appcast.sh. This
# deliberately does NOT cd there itself: it would make a relative --output
# resolve against the repo root rather than against the directory you are
# standing in, which is the kind of surprise that puts a release artifact
# somewhere nobody looks.
set -euo pipefail

APP="build/Snitt.app"
OUTPUT=""
ALLOW_UNSTAPLED=0
app_given=0

while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "error: --output requires a path" >&2
        exit 1
      fi
      OUTPUT="$2"; shift 2 ;;
    --allow-unstapled)
      ALLOW_UNSTAPLED=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)
      echo "error: unknown option: $1" >&2
      exit 1 ;;
    *)
      if [ "$app_given" -eq 1 ]; then
        echo "error: unexpected extra argument: $1" >&2
        exit 1
      fi
      APP="$1"; app_given=1; shift ;;
  esac
done

if [ -z "$APP" ]; then
  echo "error: <path-to-app> must not be empty" >&2
  exit 1
fi

if [ ! -d "$APP" ] || [ ! -f "$APP/Contents/Info.plist" ]; then
  echo "error: $APP does not look like an app bundle (missing Contents/Info.plist)" >&2
  exit 1
fi

# Signed first, and checked here rather than left to `hdiutil` — hdiutil will
# happily package anything, so an unsigned app produces a DMG that is only
# discovered to be worthless after it has been uploaded.
if ! codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  echo "error: $APP is not validly signed (codesign --verify --deep --strict failed)" >&2
  echo "sign it first — see ./Scripts/make-app.sh — before building a DMG" >&2
  exit 1
fi

# What this can and cannot prove, measured on this repo's own 0.2.0 build
# rather than assumed, because the obvious reading of these tools is wrong.
#
# `stapler validate` exits 65 with "does not have a ticket stapled to it" for
# an app Apple has never seen, and 0 for one it has — that part is reliable and
# is what this guard uses. What it does NOT mean is "a ticket is attached":
# with no local ticket it asks Apple's servers, and a lookup that answers is
# reported as success, printing "Downloaded ticket has been stored at ...".
#
# Worse, that lookup CACHES the ticket, so running the check changes the
# machine's answer to a later one. Observed here in this order: `spctl
# --assess` said "rejected: source=Unnotarized Developer ID"; `stapler
# validate` then downloaded a ticket and reported success; `spctl --assess`
# afterwards said "accepted: source=Notarized Developer ID" — same bundle,
# untouched, opposite verdicts, because a diagnostic in between mutated the
# state being diagnosed. Do not use spctl here for that reason, and do not
# trust either tool's verdict on a bundle you have already probed.
#
# So this guard proves NOTARIZED, not STAPLED. The stapled half is enforced by
# ORDER in docs/superpowers/notes/release-runbook.md — notarize and staple the
# app, then build the image from it — and a message claiming more than the
# check delivers would be the more dangerous error. (For the record, since
# nothing else in this repo writes it down: stapling an app bundle rewrites
# Contents/CodeResources in place and adds no new file, and a stapled bundle
# validates without printing the "Downloaded ticket" line. That absence is the
# only offline signal there is.)
if [ "$ALLOW_UNSTAPLED" -eq 0 ]; then
  if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "error: $APP is not notarized — Apple has no ticket for it." >&2
    echo "" >&2
    echo "A DMG built from an app Gatekeeper rejects installs fine here and" >&2
    echo "fails on every machine that has not seen it. Notarize and staple" >&2
    echo "the app first — in that order, before building the image:" >&2
    echo "  ./Scripts/notarize.sh $APP" >&2
    echo "" >&2
    echo "To build one anyway for local testing (never publish it):" >&2
    echo "  $(basename "$0") $APP --allow-unstapled" >&2
    exit 1
  fi
else
  echo "warning: --allow-unstapled — this DMG is for local testing and must not be published" >&2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
  echo "error: could not read CFBundleShortVersionString from $APP/Contents/Info.plist" >&2
  echo "refusing to name a DMG after a version it cannot confirm" >&2
  exit 1
fi

[ -n "$OUTPUT" ] || OUTPUT="Snitt-$VERSION.dmg"

# Staging directory, not `hdiutil create -srcfolder build/` directly: the image
# must contain exactly two things, and pointing hdiutil at a real directory
# ships whatever else happens to be sitting in it.
STAGE="$(mktemp -d -t snitt-dmg)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# ditto, not cp -R: it preserves the extended attributes and resource forks
# that carry the code signature and the stapled ticket. `cp -R` can drop them,
# which invalidates the signature of the copy while leaving the original — the
# one you verified — untouched and looking correct.
echo "==> Staging $APP..."
ditto "$APP" "$STAGE/$(basename "$APP")"

# The drag target. A DMG with no /Applications symlink makes the user find the
# folder themselves, and a surprising number then run the app from the mounted
# image, where it cannot be updated and vanishes on eject.
ln -s /Applications "$STAGE/Applications"

# No background image, no window geometry, no icon positions. Those require
# driving Finder over AppleScript against a mounted volume, which needs a GUI
# session, fails inside CI and over SSH, and is the single most fragile step in
# every DMG-building script this pattern gets copied from. A plain image opens
# to a readable list with both items in it and cannot break the release.
rm -f "$OUTPUT"
echo "==> Building $OUTPUT..."
hdiutil create \
  -volname "Snitt $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -quiet \
  "$OUTPUT"

# Signing the DMG is separate from signing the app inside it. Gatekeeper
# assesses the downloaded .dmg itself — it arrives quarantined from the
# browser — so an unsigned image is refused before the user ever sees the app.
if [ -n "${SNITT_SIGN_IDENTITY+x}" ] && [ -n "$SNITT_SIGN_IDENTITY" ]; then
  echo "==> Signing $OUTPUT with: $SNITT_SIGN_IDENTITY"
  codesign --sign "$SNITT_SIGN_IDENTITY" --timestamp "$OUTPUT"
  codesign --verify --strict "$OUTPUT"
else
  echo "warning: SNITT_SIGN_IDENTITY is not set — $OUTPUT is UNSIGNED." >&2
  echo "         Gatekeeper will refuse it on download. Do not publish it." >&2
fi

echo "Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
echo "Next: ./Scripts/notarize.sh $OUTPUT   (the DMG needs its own ticket)"
