#!/bin/bash
# wrapper/build.sh — builds the reference wrapper Swift code into a bare
# .app bundle skeleton, using Swift Package Manager.
#
# The wrapper is a SwiftPM package (see Package.swift) that depends on
# Sparkle. SPM handles compiling the wrapper sources AND resolving the
# Sparkle binary distribution. The result is a small, fast release build
# with Sparkle.framework embedded alongside the binary.
#
# Usage:
#   ./wrapper/build.sh <app-name> <output-path>
#   ./wrapper/build.sh Odysseus /tmp/Odysseus-skel.app
#
# This produces a .app with:
#   - MacOS/<app-name>             (Swift binary)
#   - Frameworks/Sparkle.framework (Sparkle 2.x, linked from SPM build)
#   - Info.plist                  (from Resources/Info.plist.tmpl)
#   - Resources/                  (empty — per-app build adds stuff here)
#   - PkgInfo
#
# Per-app customization: if apps/<name>/wrapper/Sources/*.swift exists,
# the per-app's build pipeline can copy those files in (but for v1.1
# we use a single unified wrapper with the per-app customizing via
# webappify.yaml; the per-app Sources/ dir is reserved for future use).

set -euo pipefail

WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="${1:-TestApp}"
OUTPUT_PATH="${2:-/tmp/$APP_NAME.app}"
BUILD_CONFIG="${3:-release}"   # debug or release

if [ -z "$APP_NAME" ] || [ -z "$OUTPUT_PATH" ]; then
    echo "usage: $0 <app-name> <output-path> [build-config]"
    echo "  example: ./wrapper/build.sh Odysseus /tmp/Odysseus.app release"
    exit 1
fi

# Find Swift toolchain
SWIFT_BUILD="/usr/bin/swift"
if [ ! -x "$SWIFT_BUILD" ]; then
    echo "✗ swift not found at $SWIFT_BUILD — install Xcode or Command Line Tools"
    exit 1
fi

echo "▶ Building $APP_NAME (SPM wrapper, $BUILD_CONFIG)"
echo "  wrapper: $WRAPPER_DIR"
echo "  output:  $OUTPUT_PATH"

# ── 1. Resolve the Sparkle dependency & compile the wrapper via SPM ───────
# If SOURCES_DIR is set (per-app customization), temporarily swap the
# wrapper sources so SPM builds the per-app customized version.
SOURCES_DIR="${SOURCES_DIR:-$WRAPPER_DIR/Sources}"
if [ "$SOURCES_DIR" != "$WRAPPER_DIR/Sources" ]; then
    echo "  using per-app sources: $SOURCES_DIR"
    # Back up reference sources, copy per-app sources in
    REF_BACKUP="$(mktemp -d)"
    cp -R "$WRAPPER_DIR/Sources/" "$REF_BACKUP/"
    rm -rf "$WRAPPER_DIR/Sources"
    cp -R "$SOURCES_DIR/" "$WRAPPER_DIR/Sources/"
    # Restore on exit
    restore_sources() {
        rm -rf "$WRAPPER_DIR/Sources"
        cp -R "$REF_BACKUP/" "$WRAPPER_DIR/Sources/"
        rm -rf "$REF_BACKUP"
    }
    trap restore_sources EXIT
fi

echo
cd "$WRAPPER_DIR"
"$SWIFT_BUILD" build -c "$BUILD_CONFIG" 2>&1 | tail -5

# Move back to original dir so OUTPUT_PATH is correct relative to caller
cd - > /dev/null

# Find the resulting binary. SPM puts it in
# .build/<arch>-apple-macosx/<config>/wrapper
SWIFT_BUILD_DIR="$WRAPPER_DIR/.build/$(uname -m | sed 's/arm64/arm64/')-apple-macosx/$BUILD_CONFIG"
if [ ! -f "$SWIFT_BUILD_DIR/wrapper" ]; then
    # Try the alternate form
    SWIFT_BUILD_DIR=$(find "$WRAPPER_DIR/.build" -name "wrapper" -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "")
    if [ -z "$SWIFT_BUILD_DIR" ] || [ ! -f "$SWIFT_BUILD_DIR/wrapper" ]; then
        echo "✗ Could not find built wrapper binary"
        exit 1
    fi
fi
WRAPPER_BINARY="$SWIFT_BUILD_DIR/wrapper"
echo "  binary: $WRAPPER_BINARY ($(du -h "$WRAPPER_BINARY" | cut -f1))"

# Find the Sparkle.framework that SPM downloaded
SPARKLE_FRAMEWORK=$(find "$WRAPPER_DIR/.build" -name "Sparkle.framework" -type d 2>/dev/null | head -1)
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "✗ Could not find Sparkle.framework"
    exit 1
fi
echo "  sparkle: $SPARKLE_FRAMEWORK"

# ── 2. Prepare bundle skeleton ────────────────────────────────────────────
echo
echo "▶ Preparing bundle skeleton"
rm -rf "$OUTPUT_PATH"
mkdir -p "$OUTPUT_PATH/Contents/MacOS" "$OUTPUT_PATH/Contents/Resources" "$OUTPUT_PATH/Contents/Frameworks"

# Copy the wrapper binary
cp "$WRAPPER_BINARY" "$OUTPUT_PATH/Contents/MacOS/$APP_NAME"
chmod +x "$OUTPUT_PATH/Contents/MacOS/$APP_NAME"

# Copy Sparkle.framework into Contents/Frameworks
cp -R "$SPARKLE_FRAMEWORK" "$OUTPUT_PATH/Contents/Frameworks/"
echo "  copied Sparkle.framework → Contents/Frameworks/"

# Info.plist from template
APP_NAME="$APP_NAME" sed -e "s|\${APP_NAME}|$APP_NAME|g" \
    "$WRAPPER_DIR/Resources/Info.plist.tmpl" > "$OUTPUT_PATH/Contents/Info.plist"

# PkgInfo
echo "APPL????" > "$OUTPUT_PATH/Contents/PkgInfo"

echo
echo "✓ Built $OUTPUT_PATH"
echo "  size:  $(du -sh "$OUTPUT_PATH" | cut -f1)"
echo "  files: $(find "$OUTPUT_PATH" -type f | wc -l | tr -d ' ')"
