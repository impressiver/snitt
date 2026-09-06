#!/bin/bash
# Builds Resources/AppIcon.icns from Resources/AppIcon.png (the source
# rendered by Scripts/generate-app-icon.swift).
#
# Run this whenever Resources/AppIcon.png changes; the resulting .icns is
# committed alongside the source so a build never depends on this script
# having been run first. Rerunning it is what keeps the two in sync.
set -euo pipefail

SOURCE_PNG="Resources/AppIcon.png"
ICONSET="Resources/AppIcon.iconset"
ICNS="Resources/AppIcon.icns"

if [ ! -f "$SOURCE_PNG" ]; then
  echo "error: $SOURCE_PNG not found — run ./Scripts/generate-app-icon.swift first" >&2
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# The standard set iconutil expects: base size plus its @2x Retina variant,
# for every size Finder/Dock/⌘-Tab/Get-Info actually render at.
declare -a SIZES=(16 32 128 256 512)
for base in "${SIZES[@]}"; do
  double=$((base * 2))
  sips -z "$base" "$base" "$SOURCE_PNG" --out "$ICONSET/icon_${base}x${base}.png" >/dev/null
  sips -z "$double" "$double" "$SOURCE_PNG" --out "$ICONSET/icon_${base}x${base}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$ICONSET"

echo "Built $ICNS"
