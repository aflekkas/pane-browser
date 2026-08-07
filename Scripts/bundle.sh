#!/bin/bash
# Assemble Pane.app by hand. SPM builds the binary; this makes it an app.
# No Xcode required (ADR 0005).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="Pane.app"
BIN=".build/${CONFIG}/Pane"

[ -f "$BIN" ] || { echo "no binary at $BIN — run swift build first"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pane"
[ -d Fixtures ] && cp -R Fixtures "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pane</string>
  <key>CFBundleDisplayName</key><string>Pane</string>
  <key>CFBundleIdentifier</key><string>com.aflekkas.pane</string>
  <key>CFBundleExecutable</key><string>Pane</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>

  <!-- Default-browser registration. No entitlement is involved on macOS;
       com.apple.developer.web-browser is iOS-only (spec §8, ADR 0004). -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web site URL</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
    </dict>
  </array>

  <!-- Drives macOS ITP state together with linkedOnOrAfter. NOT the browser
       check, which is gated behind ENABLE(APP_BOUND_DOMAINS) and is
       iOS-only (spec §8). -->
  <key>NSCrossWebsiteTrackingUsageDescription</key>
  <string>Pane needs this to browse sites that embed cross-site content.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign. Restricted entitlements (passkeys) need a real provisioning
# profile and an organization account — milestone F, ADR 0004.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null \
  || echo "warning: ad-hoc signing failed; the app will still run locally"

echo "built $APP"
