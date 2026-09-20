#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright © 2026 Ian White.
#
# The source directories a product actually compiles: its transitive target
# closure, as SwiftPM describes it.
#
# `make-app.sh`'s freshness guard needs this because comparing a product
# against ALL of `Sources` refuses correct builds. Editing a file in
# `Sources/SnittApp` correctly relinks nothing in `snitt-cli`, which compiles
# neither SnittApp nor anything importing it — so a whole-tree comparison
# reports a perfectly current binary as stale.
#
# That is the same trap the guard's manifest note already describes, one level
# down. Scoping `Package.swift` out of the comparison was the right move and
# did not go far enough: the reason it gave — "a manifest edit that correctly
# relinks nothing must not fail the build" — is equally true of a source file
# in a module the product does not compile.
#
# It matters because a check that fails on correct behaviour gets switched off,
# and this particular check is the one standing between a release and shipping
# a weeks-old binary. v0.6.0 and v0.6.1 both shipped one.
#
# The closure comes from SwiftPM rather than a hand-written map. A map is a
# second answer to "what does this product compile", and it drifts the first
# time a target gains a dependency — silently, into either a guard that refuses
# correct builds or, far worse, one that passes a genuinely stale binary.

# Cached for the run: `swift package describe` costs a package resolve, and the
# answer cannot change while the script is running.
#
# Pre-set it to skip the `swift` call entirely. That is not only a test seam:
# `swift package describe` takes SwiftPM's lock on `.build`, so ANY caller that
# already holds it — a test running under `swift test`, most obviously —
# deadlocks rather than failing. A test that drove the real `swift` here hung
# forever instead of reporting anything, which is exactly the shape of failure
# this repo's `run-tests.sh` exists to catch.
PRODUCT_SOURCE_PATHS_DESCRIPTION="${PRODUCT_SOURCE_PATHS_DESCRIPTION:-}"

# product_source_paths <product-name>
#
# Prints one path per line, sorted. Prints NOTHING — and returns 0 — when the
# description cannot be read or the product is unknown; the caller decides what
# to do about that, and `make-app.sh` refuses rather than falling back to the
# whole tree, because a silent fallback reinstates the bug this fixes.
product_source_paths() {
  if [ -z "$PRODUCT_SOURCE_PATHS_DESCRIPTION" ]; then
    PRODUCT_SOURCE_PATHS_DESCRIPTION="$(swift package describe --type json 2>/dev/null || true)"
  fi
  [ -n "$PRODUCT_SOURCE_PATHS_DESCRIPTION" ] || return 0

  printf '%s' "$PRODUCT_SOURCE_PATHS_DESCRIPTION" | PRODUCT="$1" python3 -c '
import json, os, sys

try:
    described = json.load(sys.stdin)
except ValueError:
    sys.exit(0)

targets = {t["name"]: t for t in described.get("targets", [])}


def closure(name, seen):
    """Every target `name` pulls in, itself included."""
    if name in seen or name not in targets:
        return seen
    seen.add(name)
    for dependency in targets[name].get("target_dependencies") or []:
        closure(dependency, seen)
    return seen


wanted = os.environ["PRODUCT"]
for product in described.get("products", []):
    if product["name"] != wanted:
        continue
    reached = set()
    for target in product.get("targets", []):
        closure(target, reached)
    # Sorted so a failure names the same file run to run.
    for path in sorted(targets[t]["path"] for t in reached if t in targets):
        print(path)
'
}
