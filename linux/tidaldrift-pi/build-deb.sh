#!/bin/bash
# Build tidaldrift-pi_<version>_all.deb from the pkg/ tree.
# Works on macOS (brew install dpkg) and on Debian.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/pkg"
VERSION=$(awk -F': ' '/^Version:/ {print $2}' "$PKG_DIR/DEBIAN/control")
OUT="$SCRIPT_DIR/tidaldrift-pi_${VERSION}_all.deb"

command -v dpkg-deb >/dev/null || { echo "dpkg-deb not found (macOS: brew install dpkg)"; exit 1; }

# Stage into a temp tree so we can set ownership/permissions without
# touching the checked-in files (dpkg-deb --root-owner-group handles
# ownership; permissions still need to be right on disk).
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$PKG_DIR/" "$STAGE/pkg"

chmod 0755 "$STAGE/pkg/DEBIAN/postinst" "$STAGE/pkg/DEBIAN/prerm" "$STAGE/pkg/DEBIAN/postrm"
chmod 0755 "$STAGE/pkg/usr/bin/tidaldrift-pi-setup"
chmod 0644 "$STAGE/pkg/DEBIAN/control" "$STAGE/pkg/DEBIAN/conffiles"
find "$STAGE/pkg/etc" "$STAGE/pkg/lib" "$STAGE/pkg/usr/share" -type f -exec chmod 0644 {} +
find "$STAGE/pkg" -name .DS_Store -delete

dpkg-deb --root-owner-group --build "$STAGE/pkg" "$OUT"
echo ""
echo "Built: $OUT"
echo "Install on the Pi:"
echo "  scp '$OUT' <user>@raspberrypi.local:/tmp/"
echo "  ssh <user>@raspberrypi.local 'sudo apt install -y /tmp/$(basename "$OUT") && sudo tidaldrift-pi-setup <user>'"
