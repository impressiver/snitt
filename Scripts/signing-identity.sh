#!/bin/bash
# Prints a stable codesign identity for local development.
#
# Ad-hoc signing ("-") changes the app's code identity on every build, which
# makes macOS TCC forget Screen Recording permission each time. A self-signed
# certificate keeps the identity constant so permission grants persist.
set -euo pipefail

IDENTITY_NAME="Snitt Development"

# Note: NO -v flag. `-v` lists "valid identities only", which EXCLUDES a
# self-signed root because nothing vouches for it — the exact kind of
# certificate the instructions below tell you to create. codesign signs with an
# untrusted certificate perfectly well; trust governs verification, not signing.
if security find-identity -p codesigning | grep -q "\"$IDENTITY_NAME\""; then
  echo "$IDENTITY_NAME"
  exit 0
fi

cat >&2 <<INSTRUCTIONS
No code-signing identity named "$IDENTITY_NAME" was found.

Create one ONCE (it is local-only and never leaves this machine):

  1. Open Keychain Access
  2. Menu: Keychain Access > Certificate Assistant > Create a Certificate...
  3. Name:              $IDENTITY_NAME
     Identity Type:     Self Signed Root
     Certificate Type:  Code Signing
     (tick "Let me override defaults" only if you want a longer validity)
  4. Create, then Done.

Then re-run this script. See docs/superpowers/notes/signing.md for why.
INSTRUCTIONS
exit 1
