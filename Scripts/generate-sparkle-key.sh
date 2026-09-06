#!/bin/bash
#
# Generate Snitt's Sparkle EdDSA update-signing key, or report the existing
# one, and print what the maintainer has to do next.
#
# Sparkle's own generate_keys prints the public half and stops. That leaves
# three things unsaid that have each cost someone a release: where the
# private key actually lives, that losing it is unrecoverable, and that the
# public half still has to reach the shipped Info.plist. This wrapper says
# them.
#
# Run this by hand, on the maintainer's machine, when you intend to ship.
# It touches the real login keychain, so it is not part of any build or
# test path.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATE_KEYS="$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys"

# The keychain coordinates Sparkle uses. Hardcoded in Sparkle itself, not
# configurable — see SUUpdaterKeychain in the Sparkle sources.
KEYCHAIN_SERVICE="https://sparkle-project.org"
KEYCHAIN_ACCOUNT="ed25519"

PLIST_SOURCE="Scripts/make-app.sh"

if [ ! -x "$GENERATE_KEYS" ]; then
  echo "error: Sparkle's generate_keys is not at:" >&2
  echo "  $GENERATE_KEYS" >&2
  echo >&2
  echo "It arrives with the Sparkle package artifact. Run 'swift build' first," >&2
  echo "then try again." >&2
  exit 1
fi

# generate_keys is idempotent: with a key already in the keychain it reports
# that and re-prints the public half rather than overwriting. Distinguish the
# two cases up front so the advice afterwards can be specific.
had_key_before=no
if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
  had_key_before=yes
fi

"$GENERATE_KEYS"

# Read the public half back rather than parsing it out of the prose above —
# -p prints it alone, and a value we re-read is a value we know is stored.
public_key="$("$GENERATE_KEYS" -p 2>/dev/null || true)"

# A second key for the same service would be silent and ruinous: sign_update
# and the plist could end up disagreeing, which verifies on the machine that
# built the update and fails on every other one.
key_count="$(security dump-keychain 2>/dev/null | grep -c "\"svce\"<blob>=\"$KEYCHAIN_SERVICE\"" || true)"

cat <<EOF

────────────────────────────────────────────────────────────────────────
Where the private key lives

  Keychain   ~/Library/Keychains/login.keychain-db
  Service    $KEYCHAIN_SERVICE
  Account    $KEYCHAIN_ACCOUNT

  In Keychain Access.app: select "login", search "sparkle".

  You were not prompted just now because the process that creates a
  keychain item gets access to it implicitly. Reading it from anything
  else — including 'security' — will prompt.
EOF

if [ "$key_count" -gt 1 ]; then
  cat <<EOF

  ⚠  $key_count keys found for this service. There should be exactly one.
     If sign_update picks a different key than the one in the plist,
     updates verify on the machine that built them and fail everywhere
     else. Resolve this before shipping.
EOF
fi

cat <<EOF

────────────────────────────────────────────────────────────────────────
Back it up now, before you rely on it

  Losing this key is unrecoverable. Every installed copy of Snitt will
  reject every future update, and the only remedy is shipping a new build
  by hand to each user.

    $GENERATE_KEYS -x ~/Desktop/snitt-sparkle-private.key
    # copy the contents into a password manager, then:
    rm ~/Desktop/snitt-sparkle-private.key

  Export outside this repo. Key-export patterns are gitignored, but do
  not make that the only thing standing between the key and a commit.

────────────────────────────────────────────────────────────────────────
Then put the public half in the shipped plist
EOF

if [ -n "$public_key" ]; then
  cat <<EOF

  In $PLIST_SOURCE:

    <key>SUPublicEDKey</key>
    <string>$public_key</string>
EOF
else
  cat <<EOF

  Run '$GENERATE_KEYS -p' to print the public half, and set SUPublicEDKey
  to it in $PLIST_SOURCE.
EOF
fi

cat <<EOF

  A public key is not a secret — that line is meant to be committed.

  Never set SUPublicEDKey to an empty string. An absent key makes Sparkle
  fall back to code-signature validation; an empty one makes it refuse to
  start at all. To ship without a key, omit the two lines entirely.

  Then rebuild and check it took:

    ./Scripts/make-app.sh
    /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" build/Snitt.app/Contents/Info.plist
    swift test

EOF

if [ "$had_key_before" = yes ]; then
  echo "  (A key already existed — nothing was overwritten.)"
  echo
fi
