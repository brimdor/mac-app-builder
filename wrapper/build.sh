#!/bin/bash
# wrapper/build.sh — compiles the reference wrapper Swift sources into a
# bare .app bundle. The per-app build pipeline (ci/build-app.sh) calls
# this and then customizes the result for the specific per-app.
#
# Usage:
#   ./wrapper/build.sh <app-name> <output-path>
#
# Example:
#   ./wrapper/build.sh Odysseus /tmp/Odysseus-skel.app
#
# This produces a .app with:
#   - MacOS/Odysseus           (Swift binary)
#   - Info.plist              (from Resources/Info.plist.tmpl, with name substituted)
#   - webappify.yaml          (NOT included — added by per-app build)
#   - icon.icns               (NOT included — added by per-app build)
#   - app/                    (NOT included — added by per-app build)
#   - runtime/                (NOT included — added by per-app build)
#
# The per-app build adds all the app-specific resources.

set -euo pipefail

WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="${1:-TestApp}"
OUTPUT_PATH="${2:-/tmp/$APP_NAME.app}"

if [ -z "$APP_NAME" ] || [ -z "$OUTPUT_PATH" ]; then
    echo "usage: $0 <app-name> <output-path>"
    exit 1
fi

echo "▶ Building $APP_NAME (reference wrapper)"
echo "  output: $OUTPUT_PATH"

# Find Swift toolchain
SWIFT="/usr/bin/swiftc"
if [ ! -x "$SWIFT" ]; then
    echo "✗ swiftc not found at $SWIFT — install Xcode or Command Line Tools"
    exit 1
fi

# Prepare bundle skeleton
rm -rf "$OUTPUT_PATH"
mkdir -p "$OUTPUT_PATH/Contents/MacOS" "$OUTPUT_PATH/Contents/Resources"

# Info.plist from template
APP_NAME="$APP_NAME" sed -e "s|\${APP_NAME}|$APP_NAME|g" \
    "$WRAPPER_DIR/Resources/Info.plist.tmpl" > "$OUTPUT_PATH/Contents/Info.plist"

# PkgInfo
echo "APPL????" > "$OUTPUT_PATH/Contents/PkgInfo"

# Compile Swift sources
# SOURCES_DIR can be overridden to use per-app customized sources instead of
# the reference. Default is the reference's own Sources/ directory.
SOURCES_DIR="${SOURCES_DIR:-$WRAPPER_DIR/Sources}"
echo "  compiling Swift…"
SWIFT_SOURCES=()
while IFS= read -r f; do
    SWIFT_SOURCES+=("$f")
done < <(find "$SOURCES_DIR" -maxdepth 1 -name '*.swift' -type f | sort)
echo "  sources dir: $SOURCES_DIR"
for src in "${SWIFT_SOURCES[@]}"; do
    echo "    $(basename "$src")"
done

xcrun "$SWIFT" \
    -O \
    -target "$(uname -m)-apple-macosx11.0" \
    -framework Cocoa -framework WebKit \
    -o "$OUTPUT_PATH/Contents/MacOS/$APP_NAME" \
    "${SWIFT_SOURCES[@]}"

echo "  binary: $OUTPUT_PATH/Contents/MacOS/$APP_NAME ($(du -h "$OUTPUT_PATH/Contents/MacOS/$APP_NAME" | cut -f1))"
echo "✓ Built $OUTPUT_PATH"
