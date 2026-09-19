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
#   - Release a version that disagrees with `AppVersion.marketing`. Sparkle
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
# Overridable for tests ONLY. Several of them drive the full dry-run path,
# which needs a version the preflight will accept — and `main` deliberately
# carries a marked one between releases, which the guard below refuses. The
# precedent is SNITT_FAKE_TEAM_IDENTIFIER_LINE; a real release never sets this.
VERSION_SOURCE="${SNITT_VERSION_SOURCE:-Sources/SnittDocument/AppVersion.swift}"
CASK_SOURCE="Casks/snitt.rb"
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

# A development version is not releasable, and the shape check above does not
# catch it: `0.5.0-dev` matches that glob, because its last component starts
# with a digit.
#
# Releasing one would tag v0.5.0-dev, name every artifact after it, and ship an
# app whose CFBundleShortVersionString says -dev to everyone who installs it.
# `main` carries exactly such a version between releases — the marker is what
# stops a development build claiming to be a release — so this is a plausible
# mistake to make, not a far-fetched one.
case "$VERSION" in
  *-*)
    bare="${VERSION%%-*}"
    echo "error: '$VERSION' is a development version, not a releasable one." >&2
    echo "       main carries a marked version between releases so that a" >&2
    echo "       build made there cannot claim to BE a release. Releasing" >&2
    echo "       means setting AppVersion.marketing to the bare version" >&2
    echo "       first:" >&2
    echo "         $bare, then ./Scripts/release.sh $bare" >&2
    echo "       Step 10 puts the marker back afterwards." >&2
    exit 1 ;;
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

# Writes the next development version to the version file and pushes it.
#
# Returns non-zero rather than exiting on any failure: the caller turns that
# into a warning, because by this point the release is already public.
#
# Pulls with --rebase first. A release takes ten minutes or so of building and
# two notarization round trips, and `main` can easily have moved in that time;
# a push rejected as non-fast-forward would otherwise be the common outcome
# rather than the rare one. A rebase conflict here leaves the tree dirty, so it
# is aborted and reported rather than left for someone to discover later.
bump_to_next_dev() {
  local next="$1"
  git fetch origin "$DEFAULT_BRANCH" --quiet || return 1
  if ! git pull --rebase --quiet origin "$DEFAULT_BRANCH"; then
    git rebase --abort 2>/dev/null || true
    return 1
  fi
  # The Homebrew cask carries the version and the hash of the release, and
  # nothing else would notice them going stale — a cask a release forgot to
  # update installs the PREVIOUS version, silently, for everyone who uses it.
  # Updated in the same commit as the version bump so the two cannot diverge.
  if [ -f "$CASK_SOURCE" ]; then
    local digest
    digest="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
    sed -i '' "s/^  version \".*\"$/  version \"$VERSION\"/" "$CASK_SOURCE"
    sed -i '' "s/^  sha256 \".*\"$/  sha256 \"$digest\"/" "$CASK_SOURCE"
    git add "$CASK_SOURCE" || return 1
  fi

  # Anchored on the exact released version, so this cannot rewrite a file
  # somebody edited in the meantime to say something else.
  local pattern="public static let marketing = \"$VERSION\""
  grep -q "$pattern" "$VERSION_SOURCE" || return 1
  sed -i '' "s/public static let marketing = \"$VERSION\"/public static let marketing = \"$next\"/" \
    "$VERSION_SOURCE" || return 1
  git add "$VERSION_SOURCE" || return 1

  # The ONLY commit in this project that reaches `main` without a pull
  # request, and the only one GitHub reports as a bypass:
  #
  #   remote: Bypassed rule violations for refs/heads/main:
  #   remote: - Changes must be made through a pull request.
  #   remote: - 3 of 3 required status checks are expected.
  #
  # A ruleset cannot scope a bypass to a file path — bypass actors are
  # all-or-nothing per ruleset — so the narrowing has to live here. This
  # asserts the commit is exactly the bookkeeping it claims to be: the version
  # constant, and the cask that carries the release hash beside it. Anything
  # else in the index means something unrelated is about to ride an unreviewed
  # push to a protected branch, which is the way a standing exception grows
  # into a hole.
  #
  # Refuses rather than committing partially: the caller treats a false return
  # as a warning and prints the two commands to finish by hand, which is the
  # right outcome for a release that is already published and verified.
  local staged allowed
  staged="$(git diff --cached --name-only | sort)"
  allowed="$(printf '%s\n%s\n' "$VERSION_SOURCE" "$CASK_SOURCE" | sort)"
  if [ -n "$(comm -23 <(printf '%s\n' "$staged") <(printf '%s\n' "$allowed"))" ]; then
    echo "error: the version bump would also commit files it has no business" >&2
    echo "       touching, so it is refusing rather than pushing them to" >&2
    echo "       $DEFAULT_BRANCH without review:" >&2
    comm -23 <(printf '%s\n' "$staged") <(printf '%s\n' "$allowed") | sed 's/^/         /' >&2
    return 1
  fi

  git commit --quiet -m "release: main moves to $next

Published $VERSION, so main must stop claiming it: a build made here would
otherwise report the same version as the release, and a bug report could not
tell the two apart.

The -dev marker reaches CFBundleShortVersionString only. CFBundleVersion is
the commit count, which Sparkle compares and which keeps rising on its own, so
this cannot make a development build refuse a real release." || return 1
  git push --quiet origin "$DEFAULT_BRANCH" || return 1
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

  verify_published_app || return 1
}

# ---------------------------------------------------------------------------
# The assets existing is not the property anyone cares about. This opens the
# PUBLISHED zip and checks what is inside it.
#
# It exists because v0.6.0 and v0.6.1 both shipped an app binary built weeks
# earlier: `make-app.sh` copied from a hardcoded product path a toolchain
# update had abandoned, and every check in the pipeline passed, because every
# check asked whether a file EXISTED. Nobody found out until a shipped feature
# appeared to have vanished from the released app.
#
# What this catches and what it does not, stated plainly rather than implied:
#
#   - the published app is not the one just built  -> caught (hash)
#   - the release ships the wrong version          -> caught (plist)
#   - the artifact does not match the tag          -> caught (build number)
#   - notarization did not survive the upload      -> caught (spctl)
#   - the BINARY is stale but the plist is fresh   -> NOT caught here
#
# That last one is the original bug, and it is caught at BUILD time by the
# freshness guard in make-app.sh, which is the only moment the question can be
# asked: it compares the binary against the sources before anything is copied.
# By the time a release finishes, step 10 has rewritten AppVersion.swift to
# the next -dev, so a source file is legitimately newer than the binary and an
# mtime check here would fail every release. Verified before writing this,
# rather than discovered by a failing release.
# ---------------------------------------------------------------------------
verify_published_app() {
  local workdir app short built tagged published_hash local_hash
  workdir="$(mktemp -d -t snitt-verify-published)"
  # shellcheck disable=SC2064
  trap "rm -rf '$workdir'" RETURN

  echo "==> Verifying the contents of the PUBLISHED $ZIP"
  if ! gh release download "$TAG" --repo "$REPO" --pattern "$ZIP"         --dir "$workdir" >/dev/null 2>&1; then
    echo "error: could not download $ZIP from $TAG to inspect it." >&2
    return 1
  fi
  if ! ditto -x -k "$workdir/$ZIP" "$workdir/extracted" 2>/dev/null; then
    echo "error: $ZIP did not extract — it is not a usable archive." >&2
    return 1
  fi
  app="$workdir/extracted/Snitt.app"
  if [ ! -d "$app" ]; then
    echo "error: $ZIP does not contain Snitt.app." >&2
    return 1
  fi

  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$short" != "$VERSION" ]; then
    echo "error: the published app calls itself '$short', but this is the" >&2
    echo "       $VERSION release. Somebody would install $short from a" >&2
    echo "       page titled $VERSION." >&2
    return 1
  fi

  # The app's build number is the tagged commit's first-parent count. Checking
  # it against the TAG rather than against HEAD is deliberate: by now HEAD has
  # moved on to the next -dev, and comparing to HEAD would pass whatever was
  # shipped.
  built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$app/Contents/Info.plist" 2>/dev/null || true)"
  tagged="$(git rev-list --count --first-parent "$TAG" 2>/dev/null || true)"
  if [ -n "$tagged" ] && [ "$built" != "$tagged" ]; then
    echo "error: the published app is build $built, but $TAG is commit" >&2
    echo "       number $tagged. The artifact does not match the tag." >&2
    return 1
  fi

  # Byte-identical to what was built, signed and notarized here. This is an
  # upload-integrity check: it cannot tell a good binary from a bad one, only
  # whether the bytes people download are the bytes that were verified.
  #
  # Only when the local build IS this version. `--verify 0.6.1` run on a
  # machine holding a 0.6.2 build must not report the older release corrupt:
  # the two binaries differing is correct there, and a check that cries wolf
  # on a healthy release is worse than no check, because the next real
  # failure reads as the same noise. Caught by running it, not by reasoning
  # about it.
  local local_short=""
  if [ -f "build/Snitt.app/Contents/Info.plist" ]; then
    local_short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      "build/Snitt.app/Contents/Info.plist" 2>/dev/null || true)"
  fi
  if [ -f "build/Snitt.app/Contents/MacOS/Snitt" ] && [ "$local_short" = "$VERSION" ]; then
    published_hash="$(shasum -a 256 "$app/Contents/MacOS/Snitt" | awk '{print $1}')"
    local_hash="$(shasum -a 256 "build/Snitt.app/Contents/MacOS/Snitt" | awk '{print $1}')"
    if [ "$published_hash" != "$local_hash" ]; then
      echo "error: the published binary is NOT the one built and notarized." >&2
      echo "       published $published_hash" >&2
      echo "       local     $local_hash" >&2
      return 1
    fi
    echo "   binary is byte-identical to the one built and notarized"
  elif [ -n "$local_short" ] && [ "$local_short" != "$VERSION" ]; then
    echo "   (local build is $local_short, not $VERSION — skipping the hash check)"
  fi

  # Gatekeeper against the downloaded copy, not the local one: this is the
  # path a real installation takes, and a staple that did not survive the
  # round trip looks fine locally.
  if ! spctl -a -t exec "$app" >/dev/null 2>&1; then
    echo "error: Gatekeeper REJECTS the published app. It was notarized here," >&2
    echo "       so the ticket did not survive the upload." >&2
    return 1
  fi

  echo "   version $short, build $built, Gatekeeper accepted"
  echo "==> The published $ZIP contains what it should."
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

declared="$(sed -nE 's/.*public static let marketing = "([^"]+)".*/\1/p' "$VERSION_SOURCE")"
if [ "$declared" != "$VERSION" ]; then
  echo "error: releasing $VERSION but $VERSION_SOURCE declares '$declared'." >&2
  case "$declared" in
    "$VERSION"-*)
      # The ordinary case, not an error the releaser should have to puzzle
      # over: main is on the development version for exactly this release.
      echo "       That is this release's development version. Set" >&2
      echo "       AppVersion.marketing to '$VERSION' and commit, then" >&2
      echo "       re-run — step 10 puts the marker back afterwards." >&2 ;;
    *)
      echo "       Bump AppVersion.marketing first — make-app.sh reads it for" >&2
      echo "       CFBundleShortVersionString, and Sparkle compares against that." >&2 ;;
  esac
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

  # What Sparkle COMPARES, checked against what was actually built.
  #
  # `sparkle:version` corresponds to the app's CFBundleVersion (Sparkle's own
  # SUAppcastItem.h says so), and this project keeps that DISJOINT from the
  # human version — it is the commit count. An appcast advertising the
  # marketing version instead is not a cosmetic error: Sparkle compares it
  # against the installed CFBundleVersion, reads the installed build as newer,
  # and offers nothing. That shipped in every release up to and including
  # v0.5.0 before anyone noticed, because a broken update check looks exactly
  # like no update being available.
  #
  # Checked HERE rather than inside make-appcast.sh because only this script
  # knows the difference between a real release and a test fixture: that one
  # warns and carries on when it cannot read the zip, and for a release that
  # has to be fatal.
  if [ "$DRY_RUN" -eq 0 ]; then
    BUILT_CFBUNDLEVERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
      build/Snitt.app/Contents/Info.plist 2>/dev/null || true)"
    # `#` as the delimiter, NOT `:`. The tag being matched is
    # `sparkle:version`, whose own colon closed the pattern early — sed then
    # read `version>.*:\1:p` as flags and died on 'v'. The check has therefore
    # never run since it was added in #126, and 0.6.0 is the first release to
    # reach it.
    APPCAST_SPARKLE_VERSION="$(sed -nE 's#.*<sparkle:version>([^<]*)</sparkle:version>.*#\1#p' \
      "$APPCAST" | head -1)"
    if [ -z "$BUILT_CFBUNDLEVERSION" ] || [ -z "$APPCAST_SPARKLE_VERSION" ]; then
      echo "error: could not read the build number from the app or the appcast." >&2
      exit 1
    fi
    if [ "$APPCAST_SPARKLE_VERSION" != "$BUILT_CFBUNDLEVERSION" ]; then
      echo "error: $APPCAST advertises sparkle:version '$APPCAST_SPARKLE_VERSION'," >&2
      echo "       but the app it points at has CFBundleVersion" >&2
      echo "       '$BUILT_CFBUNDLEVERSION'. Sparkle compares those, so this" >&2
      echo "       release would never be offered to anyone." >&2
      exit 1
    fi
    echo "   sparkle:version $APPCAST_SPARKLE_VERSION matches the built app"
  fi
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

# ---------------------------------------------------------------------------
# Step 10. Leave `main` carrying the NEXT version, not the one just shipped.
#
# Without this, `main` claims a version that is already public: every build a
# developer makes reports the same version as the release, so a bug report
# cannot distinguish "the shipped 0.4.0" from "0.4.0 plus thirty commits".
#
# The marker is what makes this safe, and it is the reason the two plist keys
# were split. A bare next-version here would make every development build
# claim to BE 0.5.0, and Sparkle would then refuse the real 0.5.0 when it
# shipped — 0.5.0 is not newer than 0.5.0. `-dev` only ever reaches
# CFBundleShortVersionString, which Sparkle does not compare; CFBundleVersion
# is the commit count and keeps rising regardless.
#
# NEXT PATCH, deliberately the SMALLEST possible increment.
#
# This used to propose the next MINOR, following Maven's release plugin. The
# problem with that is it makes a claim nobody has decided yet: it says the
# next release will carry new features, before anyone knows what the next
# release contains. Worse, it does so silently, so the size of the version
# bump is chosen by a script at the END of the previous release rather than
# by a person looking at what actually changed.
#
# A patch increment claims the least. Bumping to a minor or a major stays a
# deliberate act: set AppVersion.marketing, and preflight refuses any version
# that disagrees with the file, so the decision cannot be skipped by accident
# in either direction.
# ---------------------------------------------------------------------------
next_dev_version() {
  local v="$1" major rest minor patch
  major="${v%%.*}"; rest="${v#*.}"; minor="${rest%%.*}"; patch="${rest#*.}"
  # Strip any pre-release marker so 1.2.3-rc1 still yields 1.2.4-dev.
  patch="${patch%%-*}"
  case "$major$minor$patch" in ""|*[!0-9]*) return 1 ;; esac
  printf '%s.%s.%s-dev\n' "$major" "$minor" "$((patch + 1))"
}

if step 10 "Leave main on the next development version"; then
  if ! NEXT_DEV="$(next_dev_version "$VERSION")"; then
    echo "warning: could not derive a next version from '$VERSION'." >&2
    echo "         The release is published and fine — only the bump was" >&2
    echo "         skipped. Set AppVersion.marketing by hand." >&2
  elif [ "$DRY_RUN" -eq 1 ]; then
    echo "   [dry-run] set AppVersion.marketing to $NEXT_DEV, commit, push to $DEFAULT_BRANCH"
  else
    # Every failure from here on is a WARNING, never an exit. The release is
    # already published and verified; reporting it as failed because a
    # bookkeeping commit did not land would send someone looking for a broken
    # release that is fine. Each branch says exactly what to run by hand.
    if bump_to_next_dev "$NEXT_DEV"; then
      printf '==> main now carries %s\n' "$NEXT_DEV"
    else
      echo "warning: the release is published and verified, but main still" >&2
      echo "         carries $VERSION. Fix it with:" >&2
      echo "           sed -i '' 's/marketing = \"$VERSION\"/marketing = \"$NEXT_DEV\"/' \\" >&2
      echo "             $VERSION_SOURCE" >&2
      echo "           git commit -am 'release: main moves to $NEXT_DEV' && git push" >&2
    fi
  fi
fi

printf '\n==> Snitt %s published: https://github.com/%s/releases/tag/%s\n' \
  "$VERSION" "$REPO" "$TAG"
