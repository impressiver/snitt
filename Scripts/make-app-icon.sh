#!/bin/bash
# Builds Resources/AppIcon.icns by running Scripts/generate-app-icon.swift and
# compiling what it renders.
#
# The .icns and the reference AppIcon.png are committed, so a build never
# depends on this script having been run first. Rerunning it is what keeps
# them in sync with the generator.
set -euo pipefail

ICONSET="Resources/AppIcon.iconset"
ICNS="Resources/AppIcon.icns"

# The generator writes every rendition itself, each drawn at its own size
# (rev 5, W10). `sips` used to downscale one 1024 master into all ten, which
# is exactly what `RecordingIcon` warns against for the poster badge: the
# small sizes — the ones Finder lists and the menu bar show — came out muddy.
./Scripts/generate-app-icon.swift

if [ ! -d "$ICONSET" ]; then
  echo "error: $ICONSET not found — the generator did not run" >&2
  exit 1
fi

iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$ICONSET"

echo "Built $ICNS"
