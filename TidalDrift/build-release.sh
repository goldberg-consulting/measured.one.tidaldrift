#!/bin/bash

# TidalDrift Release Builder
# Uses xcodebuild + ditto --norsrc to avoid resource fork issues
# Requires: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

set -euo pipefail

APP_NAME="TidalDrift"
BUNDLE_ID="com.goldbergconsulting.tidaldrift"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

load_env_file() {
    local env_file="$1"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *=* ]] && continue

        local key="${line%%=*}"
        local value="${line#*=}"

        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
            value="${value:1:${#value}-2}"
        fi

        export "$key=$value"
    done <"$env_file"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/version.env" ] && source "$SCRIPT_DIR/version.env"
VERSION="${APP_VERSION:-1.4.3}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
if [ -f "$SCRIPT_DIR/.env" ]; then
    load_env_file "$SCRIPT_DIR/.env"
    echo -e "${BLUE}📋 Loaded .env${NC}"
fi
DMG_NAME="${APP_NAME}-${VERSION}"

NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
RELEASE_DIR="$(pwd)/dist"
APP_BUNDLE="$APP_NAME.app"

SKIP_NOTARIZE=false
for arg in "$@"; do [[ "$arg" == "--skip-notarize" ]] && SKIP_NOTARIZE=true; done
COPY_TO_SHARE="${COPY_TO_SHARE:-0}"

BUILD_START_TIME=$SECONDS
step_start() { STEP_START=$SECONDS; }
step_done() { echo -e "${GREEN}✓ $1 ($((SECONDS - STEP_START))s)${NC}"; }

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}     🌊 TidalDrift Release Builder v${VERSION}              ${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# [1/8] Verify Xcode
step_start
echo -e "${BLUE}[1/8] Verifying Xcode...${NC}"
if ! xcodebuild -version >/dev/null 2>&1; then
    echo -e "${RED}❌ Xcode CLI tools not available. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer${NC}"
    exit 1
fi
step_done "Xcode ($(xcodebuild -version | head -1))"

# [2/8] Cleanup
step_start
echo -e "${BLUE}[2/8] Cleanup...${NC}"
pkill -9 -x "$APP_NAME" 2>/dev/null || true
rm -rf "$APP_BUNDLE" build-xcode
for TCC_SERVICE in ScreenCapture Accessibility ListenEvent LocalNetwork; do
    tccutil reset "$TCC_SERVICE" "$BUNDLE_ID" 2>/dev/null || true
done
step_done "Cleanup + TCC reset"

# [3/8] Certificate
step_start
echo -e "${BLUE}[3/8] Checking certificate...${NC}"
DEV_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
[ -z "$DEV_ID" ] && echo -e "${RED}❌ No Developer ID certificate in keychain${NC}" && exit 1
step_done "Certificate: ${DEV_ID}"

# [4/8] Build
step_start
echo -e "${BLUE}[4/8] Building (Release)...${NC}"
find Resources -type f -exec xattr -c {} \; 2>/dev/null || true
mkdir -p dist/logs
BUILD_LOG="dist/logs/build-release.log"
xcodebuild -scheme TidalDrift -configuration Release -destination 'platform=macOS' -derivedDataPath ./build-xcode clean build 2>&1 | tee "$BUILD_LOG"
[ ! -f "./build-xcode/Build/Products/Release/TidalDrift" ] && echo -e "${RED}❌ Build failed (see ${BUILD_LOG})${NC}" && exit 1
step_done "Build (log: ${BUILD_LOG})"

# [5/8] Create bundle
step_start
echo -e "${BLUE}[5/8] Creating .app bundle...${NC}"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
ditto --norsrc ./build-xcode/Build/Products/Release/TidalDrift "$APP_BUNDLE/Contents/MacOS/TidalDrift"
[ -f "Resources/AppIcon.icns" ] && ditto --norsrc Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
[ -d "./build-xcode/Build/Products/Release/TidalDrift_TidalDrift.bundle" ] && \
    ditto --norsrc ./build-xcode/Build/Products/Release/TidalDrift_TidalDrift.bundle "$APP_BUNDLE/Contents/Resources/TidalDrift_TidalDrift.bundle"

cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>TidalDrift</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>TidalDrift</string>
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
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"
find "$APP_BUNDLE" -type f -exec xattr -c {} \; 2>/dev/null || true
find "$APP_BUNDLE" -type d -exec xattr -c {} \; 2>/dev/null || true
xattr -rc "$APP_BUNDLE" 2>/dev/null || true
step_done "Bundle"

# [6/8] Sign
step_start
echo -e "${BLUE}[6/8] Signing...${NC}"
codesign --force --deep --options runtime --sign "$DEV_ID" --timestamp --entitlements TidalDrift.entitlements "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
step_done "Signed"

# [7/8] DMG
step_start
echo -e "${BLUE}[7/8] Creating DMG...${NC}"
DMG_FINAL="${RELEASE_DIR}/${DMG_NAME}.dmg"
rm -rf "${RELEASE_DIR}/dmg-staging" "$DMG_FINAL"
mkdir -p "${RELEASE_DIR}/dmg-staging"
ditto --norsrc "$APP_BUNDLE" "${RELEASE_DIR}/dmg-staging/$APP_BUNDLE"
ln -s /Applications "${RELEASE_DIR}/dmg-staging/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "${RELEASE_DIR}/dmg-staging" -ov -format UDZO "$DMG_FINAL"
rm -rf "${RELEASE_DIR}/dmg-staging"
codesign --force --sign "$DEV_ID" --timestamp "$DMG_FINAL"
step_done "DMG"

# [8/8] Notarize
step_start
if [ "$SKIP_NOTARIZE" = true ]; then
    echo -e "${YELLOW}[8/8] Skipping notarization${NC}"
else
    echo -e "${BLUE}[8/8] Notarizing...${NC}"
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
        [ -n "${APPLE_ID:-}" ] && [ -n "${TEAM_ID:-}" ] && [ -n "${APP_SPECIFIC_PASSWORD:-}" ] && \
            xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_SPECIFIC_PASSWORD"
    fi
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
        echo -e "${RED}❌ Notarization credentials are not configured for profile '${NOTARY_PROFILE}'.${NC}"
        echo "   Option 1: set APPLE_ID, TEAM_ID, and APP_SPECIFIC_PASSWORD in TidalDrift/.env"
        echo "   Option 2: run xcrun notarytool store-credentials \"$NOTARY_PROFILE\" ..."
        exit 1
    fi
    xcrun notarytool submit "$DMG_FINAL" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_FINAL"
    step_done "Notarized"
fi

rm -rf build-xcode "$APP_BUNDLE"

if [ "$COPY_TO_SHARE" = "1" ]; then
    # Optional maintainer workflow, disabled by default for OSS portability.
    SMB_MOUNT="/Volumes/Eli Goldberg's Public Folder"
    SMB_URL="smb://US_LDHG427053._smb._tcp.local/Eli Goldberg's Public Folder/"

    if [ -d "$SMB_MOUNT" ]; then
        echo -e "${BLUE}📂 Copying to network share...${NC}"
        cp "$DMG_FINAL" "$SMB_MOUNT/"
        echo -e "${GREEN}✓ Copied to $SMB_MOUNT/${NC}"
    else
        echo -e "${BLUE}📂 Mounting network share...${NC}"
        if osascript -e "mount volume \"$SMB_URL\"" 2>/dev/null; then
            sleep 2
            if [ -d "$SMB_MOUNT" ]; then
                cp "$DMG_FINAL" "$SMB_MOUNT/"
                echo -e "${GREEN}✓ Copied to $SMB_MOUNT/${NC}"
            else
                echo -e "${YELLOW}⚠️  Mount succeeded but folder not found; copy manually${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️  Could not mount network share; copy manually${NC}"
            echo "   open \"$SMB_URL\""
        fi
    fi
else
    echo -e "${BLUE}ℹ️  Skipping network share copy (set COPY_TO_SHARE=1 to enable)${NC}"
fi

TOTAL_ELAPSED=$((SECONDS - BUILD_START_TIME))
echo ""
echo -e "${GREEN}🎉 Done! ${DMG_NAME}.dmg ($(du -h "$DMG_FINAL" | cut -f1)) in ${TOTAL_ELAPSED}s${NC}"
echo "   $DMG_FINAL"
