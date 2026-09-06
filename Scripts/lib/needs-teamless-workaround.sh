#!/bin/bash
# Decides whether R9's com.apple.security.cs.disable-library-validation
# workaround is needed, given one line of `codesign -dvv` output containing
# the TeamIdentifier field (e.g. "TeamIdentifier=not set" or
# "TeamIdentifier=ABCDE12345").
#
# Why this exists as its own script rather than inline logic in
# make-app.sh: it's the one piece of this task's signing behavior that
# can't be exercised end-to-end without a real paid Developer ID (no such
# identity exists in this repo), so it's factored out to be unit-testable
# with a synthetic TeamIdentifier line instead — see
# `Tests/SnittAppTests/BundleLayoutTests.swift`'s
# `needsTeamlessWorkaroundLogic` test, which calls this script directly.
#
# Hardened runtime (`--options runtime`) enables library validation: dyld
# refuses to load a dylib/framework whose signing Team ID doesn't match the
# main executable's. Reproduced directly (see task-2-report.md): a
# self-signed dev identity and ad-hoc signing ("-") both report
# "TeamIdentifier=not set" for EVERY signing operation, even the same
# identity used twice, because "not set" is never treated as matching
# itself — only a genuine, non-empty Team ID satisfies library validation.
# A real Developer ID gives the app and its re-signed nested Sparkle
# components one matching, real Team ID, and needs no workaround.
#
# The workaround is scoped this narrowly on purpose: Snitt holds Screen
# Recording and Microphone TCC grants and embeds an updater that downloads
# and runs code. `disable-library-validation` lets any validly-signed
# dylib — signed by anyone, not just Snitt's team — load into that
# process, so it should never ship in a build that has a real identity and
# doesn't need it.
set -euo pipefail

# R15: `${1:-$(cat)}` fires on an EMPTY $1, not just a missing one — a
# caller that passes "" (e.g. a `grep || true` that came up empty) would
# fall through to reading stdin, which hangs on a terminal and silently
# answers "no" under /dev/null. Distinguish "no argument given" ($# == 0)
# from "given an empty string" explicitly instead.
if [ $# -ge 1 ]; then
  line="$1"
else
  line="$(cat)"
fi

if [ -z "$line" ]; then
  echo "error: needs-teamless-workaround.sh got an empty TeamIdentifier line — refusing to guess" >&2
  exit 1
fi

if [[ "$line" == "TeamIdentifier=not set" ]]; then
  echo "yes"
else
  echo "no"
fi
