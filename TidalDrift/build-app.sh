#!/bin/bash

# TidalDrift Dev Builder - Build, package DMG, install to /Applications, launch
# Uses xcodebuild (Debug) + Developer ID signing + DMG
# Requires: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

set -euo pipefail
APP_NAME="TidalDrift"
BUNDLE_ID="com.goldbergconsulting.tidaldrift"
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/version.env"
[ -f "$VERSION_FILE" ] && source "$VERSION_FILE"
VERSION="${APP_VERSION:-1.4.3}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

RUN_APP=true; [[ "$1" == "--no-run" ]] && RUN_APP=false

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     🌊 TidalDrift Dev Build v${VERSION}                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verify Xcode tooling is available.
if ! xcodebuild -version >/dev/null 2>&1; then
    echo -e "${RED}❌ Xcode CLI tools not available. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Xcode ($(xcodebuild -version | head -1))${NC}"

# Kill running instances
pkill -9 -x "$APP_NAME" 2>/dev/null || true
sleep 1
echo -e "${GREEN}✓ Killed old instances${NC}"

# Reset ALL TCC permissions (code signature changes on every rebuild, invalidating old grants)
for TCC_SERVICE in ScreenCapture Accessibility ListenEvent LocalNetwork; do
    tccutil reset "$TCC_SERVICE" "$BUNDLE_ID" 2>/dev/null || true
done
echo -e "${GREEN}✓ TCC permissions reset: ScreenCapture, Accessibility, ListenEvent, LocalNetwork${NC}"

# Cleanup
rm -rf "$APP_NAME.app" build-xcode
echo -e "${GREEN}✓ Cleanup${NC}"

# Certificate
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
if [ -n "$DEV_ID" ]; then
    echo -e "${GREEN}✓ Certificate: ${DEV_ID}${NC}"
else
    echo -e "${YELLOW}⚠ No Developer ID found, will use ad-hoc signing${NC}"
fi

# Build (Debug config so #if DEBUG features like loopback are available)
echo -e "${BLUE}🔨 Building (Debug)...${NC}"
mkdir -p dist/logs
BUILD_LOG="dist/logs/build-app.log"
xcodebuild -scheme "$APP_NAME" -configuration Debug -destination 'platform=macOS' -derivedDataPath ./build-xcode build 2>&1 | tee "$BUILD_LOG"
[ ! -f "./build-xcode/Build/Products/Debug/$APP_NAME" ] && echo -e "${RED}❌ Build failed${NC}" && exit 1
echo -e "${GREEN}✓ Build (log: ${BUILD_LOG})${NC}"

# Create .app bundle
echo -e "${BLUE}📦 Creating bundle...${NC}"
mkdir -p "$APP_NAME.app/Contents/MacOS" "$APP_NAME.app/Contents/Resources"
ditto --norsrc "./build-xcode/Build/Products/Debug/$APP_NAME" "$APP_NAME.app/Contents/MacOS/$APP_NAME"
[ -f "Resources/AppIcon.icns" ] && ditto --norsrc Resources/AppIcon.icns "$APP_NAME.app/Contents/Resources/AppIcon.icns"
[ -d "./build-xcode/Build/Products/Debug/TidalDrift_TidalDrift.bundle" ] && \
    ditto --norsrc "./build-xcode/Build/Products/Debug/TidalDrift_TidalDrift.bundle" "$APP_NAME.app/Contents/Resources/TidalDrift_TidalDrift.bundle"

cat > "$APP_NAME.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>TidalDrift discovers Macs on your network.</string>
    <key>NSBonjourServices</key><array><string>_rfb._tcp</string><string>_smb._tcp</string><string>_afpovertcp._tcp</string><string>_ssh._tcp</string><string>_tidaldrift._tcp</string><string>_tidaldrop._tcp</string><string>_tidaldrift-cast._udp</string><string>_tidalclip._tcp</string><string>_tidalstream._tcp</string></array>
</dict></plist>
EOF
echo -n "APPL????" > "$APP_NAME.app/Contents/PkgInfo"
echo -e "${GREEN}✓ Bundle${NC}"

# Sign
echo -e "${BLUE}🔏 Signing...${NC}"
if [ -n "$DEV_ID" ]; then
    codesign --force --deep --options runtime --sign "$DEV_ID" --entitlements TidalDrift.entitlements "$APP_NAME.app" 2>/dev/null || \
        codesign --force --deep --sign - "$APP_NAME.app" 2>/dev/null || true
    echo -e "${GREEN}✓ Signed (Developer ID)${NC}"
else
    codesign --force --deep --sign - "$APP_NAME.app" 2>/dev/null || true
    echo -e "${YELLOW}✓ Signed (ad-hoc)${NC}"
fi

# Create DMG
echo -e "${BLUE}💿 Creating DMG...${NC}"
mkdir -p dist
DMG_PATH="dist/${APP_NAME}-${VERSION}-dev.dmg"
rm -rf dist/dmg-staging "$DMG_PATH"
mkdir -p dist/dmg-staging
ditto --norsrc "$APP_NAME.app" "dist/dmg-staging/$APP_NAME.app"
ln -s /Applications "dist/dmg-staging/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "dist/dmg-staging" -ov -format UDZO "$DMG_PATH" 2>&1 | tail -1
rm -rf dist/dmg-staging
echo -e "${GREEN}✓ DMG: ${DMG_PATH} ($(du -h "$DMG_PATH" | cut -f1))${NC}"

# Install to /Applications
echo -e "${BLUE}📲 Installing to /Applications...${NC}"
rm -rf "/Applications/$APP_NAME.app"
ditto --norsrc "$APP_NAME.app" "/Applications/$APP_NAME.app"
echo -e "${GREEN}✓ Installed to /Applications${NC}"

# Cleanup build artifacts
rm -rf build-xcode "$APP_NAME.app"
echo -e "${GREEN}✓ Cleaned up${NC}"

echo ""
echo -e "${GREEN}🎉 Done! TidalDrift v${VERSION} installed to /Applications${NC}"

# Launch
if [ "$RUN_APP" = true ]; then
    echo -e "${BLUE}🚀 Launching...${NC}"
    open "/Applications/$APP_NAME.app"
fi
