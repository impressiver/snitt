#!/bin/bash
# Generates a Sparkle appcast (RSS, not Atom — see below) for one release.
# The maintainer's decision (binding, see task-5-brief.md): GitHub Releases
# is the host, so the item's enclosure URL is a release asset URL the
# caller supplies; this script never constructs one, so a re-tagged or
# renamed release cannot silently 404.
#
# Usage: Scripts/make-appcast.sh <version> <zip> <release-url> [signature] [--output <path>]
#
# <version>       Must match CFBundleShortVersionString (and
#                 CFBundleVersion — Task 1/3 keep both equal, driven from
#                 the single AppVersion.fallback source; see
#                 Scripts/make-app.sh) of the build the zip contains.
#                 Sparkle compares appcast items against the INSTALLED
#                 app's CFBundleShortVersionString to decide whether an
#                 update is newer. Cross-checked against the zip's own
#                 Contents/Info.plist below when that's readable — a wrong
#                 <version> is exactly the kind of drift that makes
#                 Sparkle silently never offer the update, or offer one
#                 that installs and still reports the old version.
# <zip>           Path to the already-built, signed (and, in real use,
#                 notarized) update archive. Read to measure its byte
#                 length for the enclosure's `length` attribute and, when
#                 possible, to cross-check <version> — this script does
#                 not sign, notarize, or upload anything.
# <release-url>   The URL the enclosure will point at once uploaded to
#                 GitHub Releases. Taken as an argument, not built from
#                 <version>, so a release that gets re-tagged or renamed
#                 fails loudly instead of shipping a 404.
# [signature]     The EdDSA signature for <zip>, base64-encoded, as
#                 produced by Sparkle's own `sign_update` (shipped in the
#                 Sparkle SPM checkout under .build/checkouts/Sparkle, or
#                 the prebuilt binary at
#                 .build/artifacts/sparkle/Sparkle/bin/sign_update).
#                 Optional as a positional argument ONLY because it can
#                 come from SPARKLE_SIGNATURE instead (see below); an
#                 explicit argument here wins if both are set. This script
#                 never signs anything itself and never sees a private
#                 key.
# [--output <path>]
#                 Write the generated feed to <path> instead of stdout,
#                 atomically (write to a sibling temp file, then rename)
#                 so a run that fails validation, or is interrupted, never
#                 touches — let alone truncates — a good feed already at
#                 <path>. THIS IS THE RECOMMENDED WAY TO PRODUCE
#                 appcast.xml: `make-appcast.sh ... > appcast.xml` looks
#                 equivalent but is NOT — the shell opens (and truncates)
#                 appcast.xml before this script runs a single check, so a
#                 refused, unsigned run still destroys the previous good
#                 feed. `--output` never opens <path> until the document
#                 is fully built and validated.
#
#                 <path>'s filename must be exactly "appcast.xml" — see
#                 REQUIRED_OUTPUT_BASENAME below. Scripts/make-app.sh's
#                 SUFeedURL is
#                 https://github.com/impressiver/snitt/releases/latest/download/appcast.xml,
#                 and Sparkle fetches that exact URL; an appcast uploaded
#                 under any other asset name is a feed Sparkle will never
#                 request — no error anywhere, updates simply never
#                 appear. Tying the required basename to a named constant,
#                 checked here AND asserted against the real SUFeedURL in
#                 Tests/SnittAppTests/AppcastTests.swift, is what keeps
#                 the two from drifting apart silently again.
#
# SPARKLE_SIGNATURE   Fallback source for the signature above, so a CI-less,
#                     by-hand release doesn't need to quote a base64 blob
#                     on the command line. Whichever source wins, an EMPTY
#                     signature is refused outright (see below) — Sparkle
#                     rejects an unsigned update at INSTALL time, after the
#                     user has already downloaded it and waited; failing
#                     here instead costs a release, not a user's trust.
#
# The maintainer's key. `sign_update` reads the private EdDSA key from the
# login Keychain by default (`generate_keys`, also shipped alongside
# `sign_update`, creates it there). That default is the one to keep: it
# means the private key is never a file this script — or any script — can
# accidentally read, log, or leave lying around, and it is never generated
# or reimplemented here. Run `generate_keys` once, by hand, on the
# maintainer's machine; it prints the public key to paste into
# SUPublicEDKey in Scripts/make-app.sh's Info.plist. Nothing secret ever
# enters this repo.
#
# GitHub's own releases.atom is Atom (<feed>/<entry>), not an RSS appcast:
# Sparkle's SUAppcast parses /rss/channel/item and needs
# <enclosure sparkle:version=…>, which an Atom feed never has — pointing
# SUFeedURL at releases.atom would make every check silently find zero
# items, forever. This script emits RSS on purpose; do not "simplify" it
# into pointing at GitHub's Atom feed instead.
set -euo pipefail

# The one required asset name for the feed this script produces — the
# last path component of Scripts/make-app.sh's SUFeedURL. Kept as a named
# constant, checked against any --output path below, so a future SUFeedURL
# edit that isn't matched here fails loudly (via the Swift test that reads
# both values) instead of silently drifting, the way the two disagreed
# with no error at all before this constant existed.
REQUIRED_OUTPUT_BASENAME="appcast.xml"

usage() {
  echo "usage: $(basename "$0") <version> <zip> <release-url> [signature] [--output <path>]" >&2
  echo "" >&2
  echo "the EdDSA signature can also be supplied via SPARKLE_SIGNATURE;" >&2
  echo "an explicit [signature] argument takes precedence if both are set." >&2
  echo "an empty/missing signature is refused — see this script's header." >&2
  echo "" >&2
  echo "--output writes atomically and requires a path named exactly" >&2
  echo "\"$REQUIRED_OUTPUT_BASENAME\" — see this script's header." >&2
}

# Pull --output <path> out of the argument list before positional parsing,
# so it can appear anywhere without disturbing <version>/<zip>/<release-url>/
# [signature]'s order.
OUTPUT_PATH=""
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      if [ $# -lt 2 ] || [ -z "${2-}" ]; then
        echo "error: --output requires a non-empty path argument" >&2
        usage
        exit 1
      fi
      OUTPUT_PATH="$2"
      shift 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

if [ -n "$OUTPUT_PATH" ] && [ "$(basename "$OUTPUT_PATH")" != "$REQUIRED_OUTPUT_BASENAME" ]; then
  echo "error: --output's filename must be exactly \"$REQUIRED_OUTPUT_BASENAME\" (got \"$(basename "$OUTPUT_PATH")\")" >&2
  echo "Sparkle's SUFeedURL fetches that exact asset name — see this script's header" >&2
  exit 1
fi

# Distinguish "no argument at all" ($# too low) from "argument given but
# empty" (an explicit "") — this project has been bitten by collapsing
# that distinction before (R15, notarize.sh). Each of the three required
# positionals gets its own named check below rather than one blanket
# `[ $# -lt 3 ]`, so a caller gets told WHICH argument is the problem.
if [ $# -lt 3 ]; then
  echo "error: missing required arguments: <version> <zip> <release-url>" >&2
  usage
  exit 1
fi

VERSION="${1-}"
ZIP="${2-}"
RELEASE_URL="${3-}"
ARG_SIGNATURE="${4-}"

if [ -z "$VERSION" ]; then
  echo "error: <version> must not be empty" >&2
  usage
  exit 1
fi

if [ -z "$ZIP" ]; then
  echo "error: <zip> must not be empty" >&2
  usage
  exit 1
fi

if [ -z "$RELEASE_URL" ]; then
  echo "error: <release-url> must not be empty" >&2
  usage
  exit 1
fi

if [ ! -e "$ZIP" ]; then
  echo "error: no such file: $ZIP" >&2
  exit 1
fi

if [ ! -f "$ZIP" ]; then
  echo "error: not a regular file: $ZIP" >&2
  exit 1
fi

# An explicit 4th argument wins over SPARKLE_SIGNATURE if both are set —
# documented above, and worth being deliberate about rather than leaving
# whichever branch happens to run first as an accident of shell evaluation
# order.
if [ -n "$ARG_SIGNATURE" ]; then
  SIGNATURE="$ARG_SIGNATURE"
else
  SIGNATURE="${SPARKLE_SIGNATURE-}"
fi

# Refuse BEFORE emitting or writing anything. An unsigned entry is one
# Sparkle will reject at install time — after the user has downloaded it
# and waited. Failing here, loudly, before a single byte of XML is built,
# costs a release instead of a user's trust. `set -e` does NOT propagate a
# command substitution's own failure through `[ "$(...)" = ... ]` (that
# exact pattern was Task 4's N8 bug) — this check has no such substitution
# to hide behind: SIGNATURE is a plain variable, tested directly.
if [ -z "$SIGNATURE" ]; then
  echo "error: no signature available — pass it as a 4th argument or set SPARKLE_SIGNATURE" >&2
  echo "an unsigned appcast item will not be emitted; see this script's header" >&2
  exit 1
fi

# Byte length of the artifact Sparkle will download, not a line count or an
# estimate. `stat`'s own failure must not be swallowed by a bare command
# substitution — capture it and check the exit status explicitly, the same
# discipline Task 4's N8 fix required for a boolean decision.
if ! LENGTH="$(stat -f%z "$ZIP" 2>/dev/null)"; then
  echo "error: could not determine the byte length of $ZIP" >&2
  exit 1
fi

if [ -z "$LENGTH" ] || [ "$LENGTH" -le 0 ]; then
  echo "error: $ZIP has no measurable length ($LENGTH) — refusing to emit a zero-length enclosure" >&2
  exit 1
fi

# Cross-check <version> against the archive's own Contents/*.app/Info.plist
# when the zip actually has one readable — nearly free given the zip is
# already open for the length check above, and it guards the exact
# mismatch (a stale or mistyped <version>) that makes Sparkle silently
# ignore an update, or install one that still reports the old version.
# Deliberately a SOFT check: if the zip isn't a real app archive (a test
# fixture, or some other packaging this script hasn't anticipated), or the
# tools to inspect it aren't available, this does not block emission —
# only an ACTUAL, DETECTED mismatch does.
if command -v unzip >/dev/null 2>&1 && command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
  ARCHIVE_INFO_PLIST_ENTRY="$(unzip -Z1 "$ZIP" 2>/dev/null | grep -m1 -E '(^|/)Contents/Info\.plist$' || true)"
  if [ -n "$ARCHIVE_INFO_PLIST_ENTRY" ]; then
    VERIFY_DIR="$(mktemp -d -t snitt-appcast-verify)"
    if unzip -p "$ZIP" "$ARCHIVE_INFO_PLIST_ENTRY" > "$VERIFY_DIR/Info.plist" 2>/dev/null; then
      ARCHIVE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$VERIFY_DIR/Info.plist" 2>/dev/null || true)"
      if [ -n "$ARCHIVE_VERSION" ] && [ "$ARCHIVE_VERSION" != "$VERSION" ]; then
        rm -rf "$VERIFY_DIR"
        echo "error: <version> ($VERSION) does not match CFBundleShortVersionString found inside $ZIP ($ARCHIVE_VERSION)" >&2
        exit 1
      fi
    fi
    rm -rf "$VERIFY_DIR"
  fi
fi

# Minimal, deliberate escaping for the handful of characters that are
# actually unsafe inside an XML attribute value. Applied to every value
# that isn't a literal this script wrote itself.
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

VERSION_ESCAPED="$(xml_escape "$VERSION")"
RELEASE_URL_ESCAPED="$(xml_escape "$RELEASE_URL")"
SIGNATURE_ESCAPED="$(xml_escape "$SIGNATURE")"

PUB_DATE="$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S %z")"

DOCUMENT="$(cat <<APPCAST
<?xml version="1.0" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Snitt</title>
    <link>${RELEASE_URL_ESCAPED}</link>
    <description>Snitt release updates</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION_ESCAPED}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION_ESCAPED}</sparkle:version>
      <sparkle:shortVersionString>${VERSION_ESCAPED}</sparkle:shortVersionString>
      <enclosure
        url="${RELEASE_URL_ESCAPED}"
        sparkle:version="${VERSION_ESCAPED}"
        sparkle:shortVersionString="${VERSION_ESCAPED}"
        length="${LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${SIGNATURE_ESCAPED}"
      />
    </item>
  </channel>
</rss>
APPCAST
)"

if [ -n "$OUTPUT_PATH" ]; then
  # Atomic replace: write beside the destination, then rename. A `mv`
  # within the same directory is a single filesystem rename, so a reader
  # (or a subsequent run of this script) only ever sees the old complete
  # file or the new complete file — never a truncated one, and never one
  # from a run that failed validation above.
  TMP_OUTPUT="$(mktemp "${OUTPUT_PATH}.XXXXXX")" || {
    echo "error: could not create a temp file next to $OUTPUT_PATH" >&2
    exit 1
  }
  printf '%s\n' "$DOCUMENT" > "$TMP_OUTPUT"
  mv -f "$TMP_OUTPUT" "$OUTPUT_PATH"
  echo "Wrote appcast to $OUTPUT_PATH" >&2
else
  printf '%s\n' "$DOCUMENT"
fi
