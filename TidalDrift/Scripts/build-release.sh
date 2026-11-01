#!/bin/bash
set -e

# TidalDrift Release Build Script
# Creates a signed and notarized DMG for distribution

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Get script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# Change to project root
cd "$PROJECT_ROOT"

# Load environment variables from .env if it exists
if [ -f ".env" ]; then
    set -a
    source .env
    set +a
    echo -e "${GREEN}✓ Loaded credentials from .env${NC}"
fi

# Now set app variables (after cd to project root)
APP_NAME="TidalDrift"
VERSION=$(grep -A1 "CFBundleShortVersionString" Info.plist | grep string | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
BUILD_DIR=".build/release"
DIST_DIR="dist"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo -e "${BLUE}🌊 TidalDrift Release Build${NC}"
echo -e "   Version: ${VERSION}"
echo ""

# Check for Developer ID certificate
DEVID_CERT=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || echo "")

if [ -z "$DEVID_CERT" ]; then
    echo -e "${RED}❌ No Developer ID Application certificate found!${NC}"
    echo ""
    echo -e "${YELLOW}To create one:${NC}"
    echo "1. Go to https://developer.apple.com/account/resources/certificates"
    echo "2. Click '+' to create a new certificate"
    echo "3. Select 'Developer ID Application'"
    echo "4. Follow the CSR creation instructions"
    echo "5. Download and double-click to install in Keychain"
    echo ""
    echo -e "${YELLOW}After installing, run this script again.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found certificate: ${DEVID_CERT}${NC}"

# Check for notarization credentials - try keychain profile first, then .env
NOTARY_PROFILE_NAME="${NOTARY_PROFILE:-AC_PASSWORD}"
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE_NAME" &>/dev/null; then
    echo -e "${GREEN}✓ Found notarization profile: ${NOTARY_PROFILE_NAME}${NC}"
    SKIP_NOTARIZE=false
elif [ -n "$APPLE_ID" ] && [ -n "$TEAM_ID" ] && [ -n "$APP_SPECIFIC_PASSWORD" ]; then
    echo -e "${GREEN}✓ Using notarization credentials from .env${NC}"
    USE_ENV_CREDENTIALS=true
    SKIP_NOTARIZE=false
else
    echo -e "${YELLOW}⚠️  Notarization credentials not configured${NC}"
    echo ""
    echo "To set up notarization, either:"
    echo ""
    echo "1. Create a .env file with:"
    echo "   APPLE_ID=\"your-apple-id@email.com\""
    echo "   TEAM_ID=\"YOUR_TEAM_ID\""
    echo "   APP_SPECIFIC_PASSWORD=\"your-app-specific-password\""
    echo ""
    echo "2. Or store in keychain:"
    echo "   xcrun notarytool store-credentials \"AC_PASSWORD\" \\"
    echo "     --apple-id \"your-apple-id@email.com\" \\"
    echo "     --team-id \"YOUR_TEAM_ID\" \\"
    echo "     --password \"your-app-specific-password\""
    echo ""
    read -p "Continue without notarization? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    SKIP_NOTARIZE=true
fi

# Step 1: Clean build
echo -e "\n${BLUE}[1/6] Cleaning previous build...${NC}"
rm -rf .build TidalDrift.app "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# Step 2: Build release (single-threaded to avoid compiler race conditions)
echo -e "\n${BLUE}[2/6] Building release...${NC}"
swift build -c release -j 1

# Step 3: Create app bundle
echo -e "\n${BLUE}[3/6] Creating app bundle...${NC}"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

mkdir -p "${MACOS}" "${RESOURCES}"

# Copy executable
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS}/"

# Copy Info.plist
cp Info.plist "${CONTENTS}/"

# Copy entitlements (needed for hardened runtime)
cp TidalDrift.entitlements "${CONTENTS}/"

# Copy app icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${RESOURCES}/"
    echo -e "${GREEN}✓ Copied app icon${NC}"
else
    echo -e "${YELLOW}⚠️  No app icon found at Resources/AppIcon.icns${NC}"
fi

# Copy resources bundle if it exists
if [ -d ".build/plugins/outputs/tidaldrift/TidalDrift/TidalDrift.bundle" ]; then
    cp -R ".build/plugins/outputs/tidaldrift/TidalDrift/TidalDrift.bundle" "${RESOURCES}/TidalDrift_TidalDrift.bundle"
fi

# Create PkgInfo
echo -n "APPL????" > "${CONTENTS}/PkgInfo"

bash "$SCRIPT_DIR/bundle-iperf3.sh" "$APP_BUNDLE" "$DEVID_CERT"

# Step 4: Sign with Developer ID and Hardened Runtime
echo -e "\n${BLUE}[4/6] Signing with Developer ID...${NC}"
codesign --force --options runtime --deep --sign "${DEVID_CERT}" \
    --entitlements TidalDrift.entitlements \
    --timestamp \
    "${APP_BUNDLE}"

# Verify signature
codesign --verify --verbose=2 "${APP_BUNDLE}"
echo -e "${GREEN}✓ Signature verified${NC}"

# Step 5: Create DMG
echo -e "\n${BLUE}[5/6] Creating DMG...${NC}"

# Create temporary DMG folder
DMG_TEMP="dmg_temp"
rm -rf "${DMG_TEMP}"
mkdir -p "${DMG_TEMP}"
cp -R "${APP_BUNDLE}" "${DMG_TEMP}/"

# Create symlink to Applications
ln -s /Applications "${DMG_TEMP}/Applications"

# Create DMG
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov -format UDZO \
    "${DIST_DIR}/${DMG_NAME}"

rm -rf "${DMG_TEMP}"

# Sign the DMG too
codesign --force --sign "${DEVID_CERT}" --timestamp "${DIST_DIR}/${DMG_NAME}"

echo -e "${GREEN}✓ DMG created: ${DIST_DIR}/${DMG_NAME}${NC}"

# Step 6: Notarize
if [ "$SKIP_NOTARIZE" != "true" ]; then
    echo -e "\n${BLUE}[6/6] Submitting for notarization...${NC}"
    echo "This may take a few minutes..."
    
    if [ "$USE_ENV_CREDENTIALS" = "true" ]; then
        # Use credentials from .env file
        xcrun notarytool submit "${DIST_DIR}/${DMG_NAME}" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$APP_SPECIFIC_PASSWORD" \
            --wait
    else
        # Use keychain profile
        xcrun notarytool submit "${DIST_DIR}/${DMG_NAME}" \
            --keychain-profile "$NOTARY_PROFILE_NAME" \
            --wait
    fi
    
    # Staple the notarization ticket
    echo -e "\n${BLUE}Stapling notarization ticket...${NC}"
    xcrun stapler staple "${DIST_DIR}/${DMG_NAME}"
    
    echo -e "${GREEN}✓ Notarization complete!${NC}"
else
    echo -e "\n${YELLOW}[6/6] Skipping notarization${NC}"
fi

# Verify final product
echo -e "\n${BLUE}Verifying final DMG...${NC}"
spctl --assess --type open --context context:primary-signature "${DIST_DIR}/${DMG_NAME}" 2>&1 || true

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Release build complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Output: ${BLUE}${DIST_DIR}/${DMG_NAME}${NC}"
echo ""
ls -lh "${DIST_DIR}/${DMG_NAME}"
echo ""

if [ "$SKIP_NOTARIZE" = "true" ]; then
    echo -e "${YELLOW}⚠️  Not notarized - users will see Gatekeeper warnings${NC}"
    echo "Set up notarization credentials and run again for full distribution."
fi

