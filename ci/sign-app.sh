#!/bin/bash
# ci/sign-app.sh — signs a built .app and .dmg.
#
# v1: ad-hoc signing only. Real Developer ID signing requires an Apple
# Developer account and is documented but not automated.
#
# Usage: ci/sign-app.sh <app-or-dmg-path>
# Example: ci/sign-app.sh dist/Odysseus.app
#          ci/sign-app.sh dist/Odysseus-0.1.0.dmg

set -euo pipefail

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
    echo "usage: $0 <app-or-dmg-path>"
    exit 1
fi

if [ ! -e "$TARGET" ]; then
    echo "✗ $TARGET does not exist"
    exit 1
fi

echo "▶ Ad-hoc signing $TARGET"

if [[ "$TARGET" == *.app ]]; then
    codesign --force --deep --sign - "$TARGET"
    echo "✓ Signed $TARGET"
    echo
    echo "Verification:"
    codesign --verify --verbose=2 "$TARGET" 2>&1 | head -5 | sed 's/^/  /'
elif [[ "$TARGET" == *.dmg ]]; then
    # Ad-hoc signing of a .dmg uses --signature-size and a codesign_signature_signer
    # which requires a key. For a real DMG signature you'd use:
    #   codesign --sign "Developer ID Application: ..." "$TARGET"
    # For ad-hoc, just verify the .app inside is signed.
    echo "  (.dmg files don't have ad-hoc signing in v1; the .app inside should be signed)"
    MOUNT_POINT="$(mktemp -d -t dmg-mount-XXXXXX)"
    trap 'hdiutil detach "$MOUNT_POINT" 2>/dev/null || true; rm -rf "$MOUNT_POINT"' EXIT
    hdiutil attach "$TARGET" -mountpoint "$MOUNT_POINT" -readonly >/dev/null
    if [ -d "$MOUNT_POINT"/*.app ]; then
        codesign --verify --verbose=2 "$MOUNT_POINT"/*.app 2>&1 | head -3 | sed 's/^/  /'
    fi
    hdiutil detach "$MOUNT_POINT" >/dev/null
    echo
    echo "Note: real .dmg signing requires a Developer ID. For v1, distribute the .dmg"
    echo "from a host where users trust your certificate (or use a hosting provider that"
    echo "re-signs the .dmg for distribution, like GitHub Releases notarization)."
else
    echo "✗ Don't know how to sign $TARGET (expected .app or .dmg)"
    exit 1
fi
