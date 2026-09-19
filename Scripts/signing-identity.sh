#!/usr/bin/env bash
# Prints a stable codesign identity: the self-signed local dev identity by
# default, or an explicitly-requested identity (e.g. a real Developer ID for
# a release build) when SNITT_SIGN_IDENTITY names one.
#
# Ad-hoc signing ("-") changes the app's code identity on every build, which
# makes macOS TCC forget Screen Recording permission each time. A self-signed
# certificate keeps the identity constant so permission grants persist. A
# Developer ID re-signs the same app under a DIFFERENT stable identity, which
# is exactly as disruptive to that TCC grant as ad-hoc — so this script never
# reaches for a Developer ID on its own. Selecting one is something a
# release build must ask for explicitly, not something that happens because
# a certificate merely exists in the keychain.
set -euo pipefail

# SNITT_SIGN_IDENTITY selects which identity to look up:
#   - unset (the default): "Snitt Development", today's behaviour, unchanged.
#   - set to a non-empty name (e.g. "Developer ID Application: impressiver
#     LLC (TEGDRM8W7U)"): that exact identity, matched the same way the
#     default is below — and a failure to find it is fatal, never a silent
#     fall-through to the default or to ad-hoc.
#   - set to an empty string: a hard error, not "use the default". This
#     project has already been bitten four times by an empty override
#     silently coercing to a default value; `SNITT_SIGN_IDENTITY=` staying
#     quiet here would be the fifth.
#
# `${SNITT_SIGN_IDENTITY+x}` (not `${SNITT_SIGN_IDENTITY:+x}`) is the form
# that actually distinguishes "unset" from "set empty" — `:+` treats an
# empty value the same as unset, collapsing exactly the distinction this
# needs to preserve.
OVERRIDE_REQUESTED=0
if [ -z "${SNITT_SIGN_IDENTITY+x}" ]; then
  IDENTITY_NAME="Snitt Development"
else
  if [ -z "$SNITT_SIGN_IDENTITY" ]; then
    echo "error: SNITT_SIGN_IDENTITY is set but empty. That is not \"use the default identity\" — unset the variable entirely for that. Set it to a real identity name (see \`security find-identity -p codesigning\`) or don't set it at all." >&2
    exit 1
  fi
  IDENTITY_NAME="$SNITT_SIGN_IDENTITY"
  OVERRIDE_REQUESTED=1
fi

# Note: NO -v flag. `-v` lists "valid identities only", which EXCLUDES a
# self-signed root because nothing vouches for it — the exact kind of
# certificate the instructions below tell you to create. codesign signs with an
# untrusted certificate perfectly well; trust governs verification, not signing.
if security find-identity -p codesigning | grep -q "\"$IDENTITY_NAME\""; then
  echo "$IDENTITY_NAME"
  exit 0
fi

if [ "$OVERRIDE_REQUESTED" = "1" ]; then
  # Signing with the wrong certificate silently is the exact failure this
  # whole mechanism exists to prevent — so an explicitly-requested identity
  # that isn't installed is a hard, loud error naming both what was asked
  # for and what actually exists, never a fall-through to "Snitt
  # Development" or to ad-hoc.
  echo "error: no code-signing identity named \"$IDENTITY_NAME\" was found (requested via SNITT_SIGN_IDENTITY)." >&2
  echo "" >&2
  echo "Identities available in this keychain:" >&2
  security find-identity -p codesigning >&2
  exit 1
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
