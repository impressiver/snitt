#!/bin/bash
#
# Cut a Snitt release: build, notarize, staple, package, publish — and then
# CHECK that what landed on the Releases page is what was meant to.
#
# Usage:
#   Scripts/release.sh <version>              Full release.
#   Scripts/release.sh --verify <version>     Only check an existing release's
#                                             assets. Needs no credentials and
#                                             touches nothing; safe on any past
#                                             release.
#   Scripts/release.sh --assets <version>     Print the required asset names.
#   Scripts/release.sh <version> --resume-from <n>
#                                             Restart at step <n> after a
#                                             failure you have diagnosed.
#   Scripts/release.sh <version> --dry-run    Print every command without
#                                             running it.
#
# WHY THIS EXISTS
#
# `docs/superpowers/notes/release-runbook.md` had eight steps, of which seven
# were commands and the eighth was a paragraph asking a human to remember to
# upload three files. That eighth step is the one with no failure mode: a
# release missing its DMG looks exactly like a release, and the person who
# notices is somebody arriving at the Releases page with no copy of Snitt
# installed and nothing to click. Everything below the upload is here so the
# upload cannot be the step that gets skipped.
#
# ONE LIST, USED TWICE. `required_assets` is what gets uploaded AND what gets
# verified afterwards. Adding a fourth artifact later means adding it there,
# which enrolls it in the check automatically — the failure this guards
# against is a new asset that ships for two releases and is then quietly
# forgotten, which is exactly what happens when the upload list and the
# check list are two lists.
#
# NOTHING SECRET IS READ FROM THE REPO. `SNITT_SIGN_IDENTITY` names a
# certificate in the keychain; notarization credentials come from
# `NOTARY_PROFILE` (a keychain profile) or the NOTARY_KEY trio, read by
# `Scripts/notarize.sh`; the Sparkle EdDSA private key never leaves the login
# keychain. This script passes them through and stores none of them.
#
# WHAT IT REFUSES TO DO, and why each check is here rather than in a person's
# memory:
#
#   - Release a version that disagrees with `AppVersion.fallback`. Sparkle
#     compares the appcast against the installed app's
#     CFBundleShortVersionString, so a tag and a binary that disagree produce
#     "updates sometimes don't appear" with no error attached.
#   - Release from a dirty tree or a branch other than the default. The tag
#     would name a commit nobody can check out.
#   - Re-use an existing tag. Sparkle's SUFeedURL resolves to the *latest*
#     release's appcast.xml; re-tagging silently repoints every install.
#   - Publish without every required asset present and non-empty.
#
set -euo pipefail

cd "$(dirname "$0")/.."

REPO="impressiver/snitt"
VERSION_SOURCE="Sources/SnittDocument/AppVersion.swift"
DEFAULT_BRANCH="main"

VERSION=""
MODE="release"
RESUME_FROM=1
DRY_RUN=0

usage() {
  sed -nE 's/^# ?//p' "$0" | sed -n '3,25p' >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verify) MODE="verify"; VERSION="${2:-}"; shift 2 ;;
    --assets) MODE="assets"; VERSION="${2:-}"; shift 2 ;;
    --resume-from) RESUME_FROM="${2:-1}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [ -z "$VERSION" ] || { echo "unexpected argument: $1" >&2; usage; }
       VERSION="$1"; shift ;;
  esac
done

[ -n "$VERSION" ] || usage

# A version this script would build a nonsense filename from is refused before
# anything runs, not after `hdiutil` has spent a minute on it.
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "error: version must look like 1.2.3, got '$VERSION'" >&2; exit 1 ;;
esac

ZIP="Snitt-$VERSION.zip"
DMG="Snitt-$VERSION.dmg"
APPCAST="appcast.xml"
TAG="v$VERSION"

# The one list. Uploaded in step 8, verified in step 9, printed by --assets.
required_assets() {
  printf '%s\n' "$ZIP" "$APPCAST" "$DMG"
}

if [ "$MODE" = "assets" ]; then
  required_assets
  exit 0
fi

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '   [dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

step() {
  local number="$1" title="$2"
  if [ "$number" -lt "$RESUME_FROM" ]; then
    printf '\n--- %s. %s [skipped: --resume-from %s]\n' "$number" "$title" "$RESUME_FROM"
    return 1
  fi
  printf '\n=== %s. %s\n' "$number" "$title"
  return 0
}

# ---------------------------------------------------------------------------
# Verification. Deliberately its own mode with no credentials and no side
# effects, so "did release X actually ship its installer" is a question anyone
# can ask about any release, at any time, without a release in progress.
# ---------------------------------------------------------------------------
verify_release() {
  local missing=0 listing
  echo "==> Verifying $TAG assets on $REPO"

  if ! listing="$(gh release view "$TAG" --repo "$REPO" \
        --json assets --jq '.assets[] | "\(.name)\t\(.size)"' 2>&1)"; then
    echo "error: cannot read release $TAG — $listing" >&2
    return 1
  fi

  while IFS= read -r asset; do
    local size
    # Tab-delimited so a filename with spaces cannot split the field.
    size="$(printf '%s\n' "$listing" | awk -F '\t' -v want="$asset" \
              '$1 == want { print $2; found = 1 } END { if (!found) print "" }')"
    if [ -z "$size" ]; then
      echo "  MISSING  $asset" >&2
      missing=1
    elif [ "$size" -eq 0 ]; then
      # A zero-byte asset is what a failed upload leaves behind, and it is
      # indistinguishable from a successful one in the web UI's file list.
      echo "  EMPTY    $asset (0 bytes)" >&2
      missing=1
    else
      printf '  ok       %s (%s bytes)\n' "$asset" "$size"
    fi
  done < <(required_assets)

  if [ "$missing" -ne 0 ]; then
    echo "" >&2
    echo "RELEASE INCOMPLETE: $TAG is missing at least one required asset." >&2
    echo "Upload it with: gh release upload $TAG <file> --repo $REPO" >&2
    return 1
  fi
  echo "==> $TAG has every required asset."
}

if [ "$MODE" = "verify" ]; then
  verify_release
  exit $?
fi

# ---------------------------------------------------------------------------
# Preflight. Every one of these is cheap and every one of them has a failure
# mode that is expensive or invisible later.
# ---------------------------------------------------------------------------
echo "=== 0. Preflight"

declared="$(sed -nE 's/.*public static let fallback = "([^"]+)".*/\1/p' "$VERSION_SOURCE")"
if [ "$declared" != "$VERSION" ]; then
  echo "error: releasing $VERSION but $VERSION_SOURCE declares '$declared'." >&2
  echo "       Bump AppVersion.fallback first — make-app.sh reads it for" >&2
  echo "       CFBundleShortVersionString, and Sparkle compares against that." >&2
  exit 1
fi
echo "  version    $VERSION (matches $VERSION_SOURCE)"

# Two different questions, answered in two different places on purpose.
#
# "Does a release require an explicit Developer ID?" is release policy, and
# it lives here: without SNITT_SIGN_IDENTITY, make-app.sh signs with the
# local self-signed identity and builds native-only, both of which produce an
# app that runs perfectly on this machine and is rejected everywhere else.
#
# "Is that a real identity?" is not this script's question. Scripts/signing-
# identity.sh already resolves it, refuses an empty override, and prints the
# keychain's actual contents on a miss. Calling it here means a typo in the
# identity name fails now rather than after the build — and means there is
# still only ONE definition of a valid identity.
if [ -z "${SNITT_SIGN_IDENTITY:-}" ]; then
  echo "error: SNITT_SIGN_IDENTITY is not set." >&2
  echo "       Without it make-app.sh signs with the local self-signed" >&2
  echo "       identity and builds native-only — never publish that." >&2
  echo "       Run Scripts/signing-identity.sh to list what is installed." >&2
  exit 1
fi
if ! ./Scripts/signing-identity.sh >/dev/null; then
  exit 1
fi
echo "  identity   $SNITT_SIGN_IDENTITY"

# Notarization credentials, checked HERE rather than discovered at step 3.
#
# This check is here because it was missing: the 0.3.0 attempt spent a full
# universal build, a deep codesign verify, and three minutes before
# notarize.sh reported it had no credentials. A preflight that catches the
# signing identity and not the notary credential fails at exactly the point
# where failing is most expensive, which is the opposite of what it is for.
#
# Delegated, not reimplemented. notarize.sh already resolves the precedence
# (a non-empty NOTARY_PROFILE wins; otherwise all three of the NOTARY_KEY
# trio, with the missing ones named), and `--check-credentials` runs that
# same code and exits before touching an artifact or the network. The first
# version of this check was a copy of that logic living here, which had
# already drifted — it tested the key file with `-r` where notarize.sh uses
# `-f`. Two copies of "what counts as a valid credential" is how a release
# passes preflight and fails at submission.
if ! notary_line="$(./Scripts/notarize.sh --check-credentials)"; then
  echo "" >&2
  echo "  Create a keychain profile once (preferred — the secret then lives" >&2
  echo "  in the keychain, not in a shell variable):" >&2
  echo "" >&2
  echo "    xcrun notarytool store-credentials snitt \\" >&2
  echo "      --apple-id <apple-id> --team-id TEGDRM8W7U \\" >&2
  echo "      --password <app-specific-password>" >&2
  echo "" >&2
  echo "  then re-run with NOTARY_PROFILE=snitt." >&2
  exit 1
fi
echo "  ${notary_line/notarization credentials:/notary    }"


branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" != "$DEFAULT_BRANCH" ]; then
  echo "error: on branch '$branch', not '$DEFAULT_BRANCH'." >&2
  echo "       A tag on a feature branch names a commit that may never merge." >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty. Commit or stash before releasing —" >&2
  echo "       the tag would name a commit that does not match what shipped." >&2
  git status --short >&2
  exit 1
fi
echo "  tree       clean, on $branch"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists." >&2
  echo "       Sparkle's SUFeedURL resolves to the LATEST release's" >&2
  echo "       appcast.xml, so re-tagging repoints every installed copy." >&2
  exit 1
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "error: release $TAG already exists on $REPO." >&2
  exit 1
fi
echo "  tag        $TAG is free"

SIGN_UPDATE=""
for candidate in \
  ".build/artifacts/sparkle/Sparkle/bin/sign_update" \
  ".build/checkouts/Sparkle/bin/sign_update"; do
  [ -x "$candidate" ] && { SIGN_UPDATE="$candidate"; break; }
done
if [ -z "$SIGN_UPDATE" ]; then
  # Located before the build rather than at step 5, because discovering it is
  # missing after notarization has already run costs a real round trip to
  # Apple. `swift build` materialises it.
  echo "error: Sparkle's sign_update not found. Run 'swift build' first." >&2
  exit 1
fi
echo "  sign_update $SIGN_UPDATE"

# ---------------------------------------------------------------------------
# The path, in the order documented in the release runbook. Each step's
# comment says what it produces and which step consumes it.
# ---------------------------------------------------------------------------

if step 1 "Build, universal, with the real Developer ID"; then
  run ./Scripts/make-app.sh
  if [ "$DRY_RUN" -eq 0 ]; then
    archs="$(lipo -archs build/Snitt.app/Contents/MacOS/Snitt)"
    # A release must not be able to ship one architecture because a flag was
    # forgotten. SNITT_SIGN_IDENTITY is what makes the build universal, so
    # this asserts the coupling actually held rather than assuming it.
    case "$archs" in
      *arm64*x86_64*|*x86_64*arm64*) echo "  archs      $archs" ;;
      *) echo "error: not a universal build ($archs)" >&2; exit 1 ;;
    esac
  fi
fi

if step 2 "Verify the signature"; then
  run codesign --verify --deep --strict build/Snitt.app
fi

if step 3 "Notarize and staple the app"; then
  run ./Scripts/notarize.sh build/Snitt.app
fi

if step 4 "Zip the STAPLED bundle"; then
  # AFTER stapling, never before. An app zipped before stapling launches on
  # the machine that built it — Gatekeeper falls back to asking Apple — and
  # fails only for a user who is offline or behind a restrictive network.
  # `ditto`, not `zip`: `zip` drops extended attributes that the signature
  # covers.
  run rm -f "$ZIP"
  run ditto -c -k --keepParent build/Snitt.app "$ZIP"
fi

if step 5 "Sign the update for Sparkle's EdDSA check"; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "   [dry-run] $SIGN_UPDATE -p $ZIP"
    SIGNATURE="dry-run-signature"
  else
    # `-p` prints the bare base64 signature. Without it sign_update prints a
    # whole `sparkle:edSignature="…" length="…"` attribute pair, which becomes
    # a nested, quote-escaped garbage attribute in the appcast.
    SIGNATURE="$("$SIGN_UPDATE" -p "$ZIP")"
    [ -n "$SIGNATURE" ] || { echo "error: sign_update produced nothing" >&2; exit 1; }
  fi
fi

if step 6 "Generate the appcast item"; then
  # The URL the asset WILL have. make-appcast.sh never constructs it, so a
  # renamed or re-tagged release fails loudly here instead of shipping a 404
  # to every installed copy.
  run ./Scripts/make-appcast.sh "$VERSION" "$ZIP" \
    "https://github.com/$REPO/releases/download/$TAG/$ZIP" \
    "${SIGNATURE:-dry-run-signature}" \
    --output "$APPCAST"
fi

if step 7 "Build and notarize the DMG"; then
  # make-dmg.sh refuses an app Apple has never notarized, so this cannot run
  # before step 3. The image needs its OWN ticket: notarizing the app does not
  # notarize an image that later contains it, and the app a user drags to
  # /Applications is assessed on its own from that moment on.
  run ./Scripts/make-dmg.sh build/Snitt.app
  run ./Scripts/notarize.sh "$DMG"
fi

if step 8 "Publish to GitHub Releases"; then
  if [ "$DRY_RUN" -eq 0 ]; then
    for asset in $(required_assets); do
      [ -s "$asset" ] || {
        echo "error: $asset is missing or empty — refusing to publish a" >&2
        echo "       release that would be incomplete from the moment it" >&2
        echo "       appeared. Re-run the step that produces it." >&2
        exit 1
      }
    done
  fi
  run git tag -a "$TAG" -m "Snitt $VERSION"
  run git push origin "$TAG"
  # All three assets in the CREATE call, not uploaded afterwards: a create
  # that succeeds followed by an upload that fails leaves a published,
  # incomplete release, and Sparkle's SUFeedURL points at the latest release
  # the instant it exists.
  run gh release create "$TAG" --repo "$REPO" \
    --title "Snitt $VERSION" --generate-notes \
    $(required_assets | tr '\n' ' ')
fi

if step 9 "Verify what actually landed"; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "   [dry-run] gh release view $TAG --json assets"
  else
    verify_release
  fi
fi

printf '\n==> Snitt %s published: https://github.com/%s/releases/tag/%s\n' \
  "$VERSION" "$REPO" "$TAG"
