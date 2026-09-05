#!/bin/bash
# Assembles build/S5Server.app so the probe runs under its own TCC identity.
# The probe needs its own bundle because TCC keys on code identity, not
# filesystem location. A probe inside Snitt.app would get its own ad-hoc
# identity and no share of Snitt's grant. Only a separately-signed app with
# its own bundle identifier can hold its own Screen Recording grant — and
# that is what this spike tests: an app with a grant (S5Server) driven by a
# caller with none over a socket. See spike S5 findings for the identity
# discovery that justified this approach.
set -euo pipefail

APP="build/S5Server.app"
BUNDLE_ID="com.impressiver.snitt.s5probe"

swift build -c debug --product S5RealTopology

if [ ! -f ".build/debug/S5RealTopology" ]; then
  echo "error: swift build did not produce .build/debug/S5RealTopology" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>S5Server</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>S5Server</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if [ -f ".build/debug/S5RealTopology" ]; then
  cp ".build/debug/S5RealTopology" "$APP/Contents/MacOS/S5Server"
fi

if IDENTITY="$(./Scripts/signing-identity.sh)"; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with stable identity: $IDENTITY"
  echo "TCC grants will persist across rebuilds."
else
  codesign --force --sign - "$APP"
  echo "WARNING: signed ad-hoc. The app's identity changes on every build, so" >&2
  echo "macOS will forget Screen Recording permission each time you rebuild." >&2
  echo "Run ./Scripts/signing-identity.sh for one-time setup instructions." >&2
fi
echo "Built $APP"
