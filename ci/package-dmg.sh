#!/bin/bash
# ci/package-dmg.sh — packages a built .app into a .dmg for distribution.
#
# Usage: ci/package-dmg.sh <app-name>
# Example: ci/package-dmg.sh odysseus
#
# Output: dist/<AppName>-<version>.dmg
#
# The .dmg contains:
#   - <AppName>.app
#   - A symlink to /Applications (the standard macOS install pattern)
#   - A README with install instructions

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${1:-}"

if [ -z "$APP_NAME" ]; then
    echo "usage: $0 <app-name>"
    exit 1
fi

PER_APP_DIR="$REPO_ROOT/apps/$APP_NAME"
APP_DISPLAY_NAME="$(echo "$APP_NAME" | tr '[:lower:]' '[:upper:]' | cut -c1)$(echo "$APP_NAME" | cut -c2-)"
APP_BUNDLE="$REPO_ROOT/dist/${APP_DISPLAY_NAME}.app"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "✗ $APP_BUNDLE does not exist — run ci/build-app.sh first"
    exit 1
fi

# Read version from webappify.yaml
VERSION=$(grep '^version:' "$PER_APP_DIR/webappify.yaml" | head -1 | sed 's/^version:[[:space:]]*//')
if [ -z "$VERSION" ]; then
    VERSION="0.1.0"
fi

DMG_PATH="$REPO_ROOT/dist/${APP_DISPLAY_NAME}-${VERSION}.dmg"
DMG_VOLNAME="${APP_DISPLAY_NAME} ${VERSION}"

echo "▶ Packaging $APP_DISPLAY_NAME $VERSION"
echo "  bundle: $APP_BUNDLE"
echo "  dmg:    $DMG_PATH"

# Stage a directory with the .app and a symlink to /Applications
STAGE="$(mktemp -d -t dmg-stage-XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Build the .dmg
rm -f "$DMG_PATH"
hdiutil create -volname "$DMG_VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null

echo
echo "✓ Packaged: $DMG_PATH"
echo "  size:    $(du -h "$DMG_PATH" | cut -f1)"
