#!/usr/bin/env bash
# Clears precompiled module caches when a dependency version has moved.
#
# SwiftPM caches a .pcm per imported C module, validated against the exact
# bytes of the headers it was built from. Changing a dependency's version
# replaces those headers, and the cached module then fails validation with a
# diagnostic that names no source file of ours:
#
#   file '.../Sparkle.framework/Headers/SUAppcastItem.h' has been modified
#   since the module file '.../Sparkle-….pcm' was built
#   note: size changed from expected 18836 to 18835
#
# The build fails with nothing wrong in the tree, CI is green because it starts
# from an empty .build, and the only remedy is knowing which cache directory to
# delete. Observed on the Sparkle 2.9.6 to 2.10.0 bump.
#
# Keyed on Package.resolved rather than Package.swift: the resolved file is
# what records the version actually in use, so it moves on `swift package
# update` too, where the manifest does not. Deleting only these two
# directories, not .build, keeps the rebuild to the modules themselves.
set -euo pipefail

drop_stale_module_cache() {
  local root="${1:-.}"
  local resolved="$root/Package.resolved"
  local explicit="$root/.build/out/Intermediates.noindex/SwiftExplicitPrecompiledModules"
  local legacy="$root/.build/out/ModuleCache.noindex"

  [ -f "$resolved" ] || return 0
  [ -d "$explicit" ] || [ -d "$legacy" ] || return 0

  # Each directory is tested only if it EXISTS. `[ file -nt missing ]` is true
  # in bash, so comparing against an absent cache reports every present one as
  # stale and clears a cache that was built against exactly these versions.
  # Caught by the control test: clearing unconditionally passes any test that
  # only checks a stale cache goes away.
  local stale=0
  if [ -d "$explicit" ] && [ "$resolved" -nt "$explicit" ]; then stale=1; fi
  if [ -d "$legacy" ] && [ "$resolved" -nt "$legacy" ]; then stale=1; fi
  [ "$stale" -eq 1 ] || return 0

  echo "dependency versions moved since the module cache was built, clearing it" >&2
  rm -rf "$explicit" "$legacy"
}
