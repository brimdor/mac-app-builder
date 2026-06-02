#!/bin/bash
# ci/publish-release.sh — publishes a built .dmg as a GitHub Release.
#
# v1: Uploads the .dmg as a workflow artifact. Does NOT create a GitHub
# Release automatically — that's done manually or in CI v1.1.
#
# v1.1: Will use `gh release create` to create a release with the .dmg
# attached, and will maintain a Sparkle appcast.xml.
#
# Usage: ci/publish-release.sh <app-name> <version>
# Example: ci/publish-release.sh odysseus 0.1.0

set -euo pipefail

APP_NAME="${1:-}"
VERSION="${2:-}"

if [ -z "$APP_NAME" ] || [ -z "$VERSION" ]; then
    echo "usage: $0 <app-name> <version>"
    echo "  example: $0 odysseus 0.1.0"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DISPLAY_NAME="$(echo "$APP_NAME" | tr '[:lower:]' '[:upper:]' | cut -c1)$(echo "$APP_NAME" | cut -c2-)"
DMG_PATH="$REPO_ROOT/dist/${APP_DISPLAY_NAME}-${VERSION}.dmg"

if [ ! -f "$DMG_PATH" ]; then
    echo "✗ $DMG_PATH does not exist — run ci/package-dmg.sh first"
    exit 1
fi

echo "▶ Publishing $APP_DISPLAY_NAME $VERSION"
echo "  dmg:   $DMG_PATH"
echo "  size:  $(du -h "$DMG_PATH" | cut -f1)"
echo

# v1: just print instructions. v1.1: actually do it.
cat <<EOF
v1: this script does not auto-publish. To distribute this build:

  1. Verify the .app and .dmg locally:
       open '$REPO_ROOT/dist/${APP_DISPLAY_NAME}.app'
       open '$DMG_PATH'

  2. Upload the .dmg somewhere end users can download it:
       - GitHub Releases (manual or via 'gh release create')
       - S3 / CloudFront
       - Internal CDN

  3. v1.1 will automate this step.

The .dmg is at: $DMG_PATH
EOF
