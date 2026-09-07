#!/bin/bash
# Signs one nested code object with Snitt's own identity, hardened runtime,
# and (by default) a secure timestamp. Callers: the Sparkle items (an XPC
# service, Updater.app, Autoupdate, or the framework bundle itself) and
# Snitt's own client executables, `snitt` and `snitt-mcp` (D63), which are
# nested code under the same notarization rules.
#
# Factored out of make-app.sh's sign_nested() helper for the same reason
# Scripts/lib/sign-app-with-workaround.sh already was: so this exact
# production codesign invocation — the one that runs once per nested item,
# innermost first — can be exercised directly by a test against a real
# nested item, without driving a full app build.
#
# Usage: sign-nested-item.sh <item-path> <sign-identity>
set -euo pipefail

ITEM="$1"
SIGN_ID="$2"

# --timestamp asks Apple's timestamp server to countersign this signature.
# Apple's notary service REJECTS a binary lacking a secure timestamp on
# EVERY architecture and EVERY nested item, full stop — this is the defect
# that sent the first real notarization submission back Invalid on all
# three signed things (Snitt.app, Updater.app, both Sparkle XPC services).
# No local check catches its absence: `codesign --verify --deep --strict`
# passes, and the app launches fine, whether or not the signature is
# timestamped — only Apple's own service looks.
#
# It needs the network and adds latency, and — confirmed directly, not
# assumed — for a REAL (non-ad-hoc) identity an unreachable timestamp
# server makes codesign FAIL the whole signing call, not just skip the
# timestamp. `Scripts/signing-identity.sh`'s stable self-signed "Snitt
# Development" identity IS real in this sense (it gets an actual
# `Timestamp=` line back), so an offline developer using it — the whole
# point of that identity, so TCC grants survive a rebuild — would have
# every build fail outright if `--timestamp` were unconditional.
#
# Ad-hoc ("-") is different: confirmed directly that codesign silently
# ignores `--timestamp` for ad-hoc signing (no `Timestamp=` line, no
# network attempt even against a deliberately unreachable server, exit 0)
# — so ad-hoc builds pay nothing for this either way and need no special
# case.
#
# So: timestamp by default — this is what makes the release path (a plain
# `./Scripts/make-app.sh` run under a real identity, feeding
# `Scripts/notarize.sh`) always timestamped with no extra step to
# remember — with an explicit, per-invocation opt-out for offline work:
# `SNITT_SKIP_TIMESTAMP=1 ./Scripts/make-app.sh`. Same caveat as
# SNITT_FAKE_TEAM_IDENTIFIER_LINE in sign-app-with-workaround.sh: set it
# for one run, don't leave it exported — a stray "1" surviving from an
# earlier offline session would silently strip timestamps from a real
# release build too.
TIMESTAMP_ARGS=()
if [ "${SNITT_SKIP_TIMESTAMP:-}" != "1" ]; then
  TIMESTAMP_ARGS=(--timestamp)
fi

codesign --force --sign "$SIGN_ID" --options runtime --preserve-metadata=entitlements \
  "${TIMESTAMP_ARGS[@]+"${TIMESTAMP_ARGS[@]}"}" "$ITEM"
