#!/bin/zsh
# Build Notesy and assemble the .app bundle in dist/.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Notesy.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$ROOT/.build/$CONFIG/Notesy"

pkill -x Notesy 2>/dev/null || true

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notesy"

# Compile the Notesy app icon set into the resource catalog and legacy ICNS.
ICON_BUILD="$(mktemp -d)"
trap 'rm -rf "$ICON_BUILD"' EXIT
xcrun actool "$ROOT/Assets.xcassets" \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ICON_BUILD/partial.plist" \
    --output-format human-readable-text --errors --warnings

# SwiftPM stamps the deployment target into LC_BUILD_VERSION as the SDK version
# (sdk 14.0), which tells AppKit the app predates Liquid Glass and earns it the
# legacy window chrome. Keep the macOS 14 minimum but declare the real SDK so
# macOS 26+ draws the current chrome: glass traffic lights included.
vtool -set-build-version macos 14.0 26.0 -replace \
    -output "$APP/Contents/MacOS/Notesy.sdkfix" "$APP/Contents/MacOS/Notesy" >/dev/null
mv "$APP/Contents/MacOS/Notesy.sdkfix" "$APP/Contents/MacOS/Notesy"
chmod +x "$APP/Contents/MacOS/Notesy"

# Write Info.plist with icon reference
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Notesy</string>
    <key>CFBundleIdentifier</key><string>com.notesy.app</string>
    <key>CFBundleName</key><string>Notesy</string>
    <key>CFBundleDisplayName</key><string>Notesy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Notesy imports your notes from Apple Notes when you ask it to.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built: $APP"
