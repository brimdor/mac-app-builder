#!/bin/bash
# ci/build-app.sh — builds a per-app .app end to end.
#
# Steps:
#   1. Validate the per-app dir structure
#   2. Run the per-app's build-runtime.sh to bundle the runtime + source
#   3. Compile the per-app's customized Swift wrapper
#   4. Copy the per-app's webappify.yaml, icon, Info.plist into the bundle
#   5. Ad-hoc code sign
#   6. Output: dist/<AppName>.app
#
# Usage: ci/build-app.sh <app-name>
# Example: ci/build-app.sh odysseus

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${1:-}"
SKIP_RUNTIME="${SKIP_RUNTIME:-0}"

if [ -z "$APP_NAME" ]; then
    echo "usage: $0 <app-name>"
    echo "  example: $0 odysseus"
    exit 1
fi

PER_APP_DIR="$REPO_ROOT/apps/$APP_NAME"
# Capitalize the first letter. macOS ships bash 3.2 which doesn't support
# ${var^}, so we use tr.
APP_DISPLAY_NAME="$(echo "$APP_NAME" | tr '[:lower:]' '[:upper:]' | cut -c1)$(echo "$APP_NAME" | cut -c2-)"
DIST_DIR="$REPO_ROOT/dist"
APP_OUTPUT="$DIST_DIR/${APP_DISPLAY_NAME}.app"

echo "▶ Building $APP_DISPLAY_NAME (per-app: apps/$APP_NAME/)"
echo "  repo root: $REPO_ROOT"
echo "  per-app:   $PER_APP_DIR"
echo "  output:    $APP_OUTPUT"
echo

# ── 1. Validate per-app structure ──────────────────────────────────────────
echo "▶ Validating apps/$APP_NAME/"
[ -d "$PER_APP_DIR" ] || { echo "✗ $PER_APP_DIR does not exist"; exit 1; }
[ -f "$PER_APP_DIR/webappify.yaml" ] || { echo "✗ webappify.yaml missing"; exit 1; }
[ -d "$PER_APP_DIR/wrapper/Sources" ] || { echo "✗ wrapper/Sources missing"; exit 1; }
[ -x "$PER_APP_DIR/build-runtime.sh" ] || { echo "✗ build-runtime.sh missing or not executable"; exit 1; }
echo "  ✓ all required files present"

# ── 2. Compile the Swift wrapper (uses per-app customized sources if they exist) ──
# The per-app can override the reference wrapper by putting customized Swift
# sources in apps/<name>/wrapper/Sources/. If those exist, we use them; otherwise
# we fall back to the reference wrapper.
echo
echo "▶ Compiling Swift wrapper"
PER_APP_WRAPPER_SOURCES="$PER_APP_DIR/wrapper/Sources"
if [ -d "$PER_APP_WRAPPER_SOURCES" ] && [ -n "$(ls -A "$PER_APP_WRAPPER_SOURCES" 2>/dev/null)" ]; then
    echo "  using per-app customized wrapper at $PER_APP_WRAPPER_SOURCES"
    SOURCES_DIR="$PER_APP_WRAPPER_SOURCES" "$REPO_ROOT/wrapper/build.sh" "$APP_DISPLAY_NAME" "$APP_OUTPUT"
else
    echo "  using reference wrapper at $REPO_ROOT/wrapper/Sources"
    "$REPO_ROOT/wrapper/build.sh" "$APP_DISPLAY_NAME" "$APP_OUTPUT"
fi

# ── 3. Bundle the runtime (Python + upstream source + venv) ───────────────
if [ "$SKIP_RUNTIME" = "1" ]; then
    echo
    echo "▶ Skipping runtime bundling (SKIP_RUNTIME=1)"
else
    echo
    echo "▶ Bundling runtime"
    APP_DIR="$APP_OUTPUT/Contents" \
    "$PER_APP_DIR/build-runtime.sh"
fi

# ── 4. Copy the per-app's webappify.yaml into the bundle ──────────────────
echo
echo "▶ Copying webappify.yaml into bundle"
cp "$PER_APP_DIR/webappify.yaml" "$APP_OUTPUT/Contents/Resources/webappify.yaml"

# ── 5. Copy the per-app's icon (if present) ───────────────────────────────
if [ -f "$PER_APP_DIR/icon.icns" ]; then
    echo "▶ Copying icon.icns"
    cp "$PER_APP_DIR/icon.icns" "$APP_OUTPUT/Contents/Resources/icon.icns"
elif [ -f "$PER_APP_DIR/icon.png" ]; then
    echo "▶ Converting icon.png → icon.icns"
    ICON_TMP="$(mktemp -d)"
    sips -z 512 512 "$PER_APP_DIR/icon.png" --out "$ICON_TMP/icon.png" >/dev/null 2>&1
    if ! sips -s format icns "$ICON_TMP/icon.png" --out "$APP_OUTPUT/Contents/Resources/icon.icns" >/dev/null 2>&1; then
        echo "  (icon conversion failed — continuing without an icon)"
    fi
    rm -rf "$ICON_TMP"
else
    echo "▶ No icon found (icon.png or icon.icns); the .app will use the system default"
fi

# ── 6. Per-app Info.plist overrides (optional) ────────────────────────────
if [ -f "$PER_APP_DIR/Info.plist" ]; then
    echo "▶ Applying per-app Info.plist overrides"
    # Merge the per-app's Info.plist on top of the wrapper's.
    # For v1, the per-app's plist fully replaces the wrapper's. (We can do
    # smarter merging later if needed.)
    cp "$PER_APP_DIR/Info.plist" "$APP_OUTPUT/Contents/Info.plist"
else
    # No per-app Info.plist, but the per-app's webappify.yaml has authoritative
    # values for bundle_id, display_name, version. Sync them into the
    # wrapper's Info.plist so the running .app has the right identity.
    echo "▶ Syncing Info.plist with webappify.yaml"
    BUNDLE_ID=$(grep '^bundle_id:' "$PER_APP_DIR/webappify.yaml" | head -1 | sed 's/^bundle_id:[[:space:]]*//')
    DISPLAY_NAME=$(grep '^display_name:' "$PER_APP_DIR/webappify.yaml" | head -1 | sed 's/^display_name:[[:space:]]*//')
    VERSION=$(grep '^version:' "$PER_APP_DIR/webappify.yaml" | head -1 | sed 's/^version:[[:space:]]*//')
    if [ -n "$BUNDLE_ID" ]; then
        /usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP_OUTPUT/Contents/Info.plist"
    fi
    if [ -n "$DISPLAY_NAME" ]; then
        /usr/bin/plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$APP_OUTPUT/Contents/Info.plist"
    fi
    if [ -n "$VERSION" ]; then
        /usr/bin/plutil -replace CFBundleVersion -string "$VERSION" "$APP_OUTPUT/Contents/Info.plist"
        /usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_OUTPUT/Contents/Info.plist"
    fi
fi

# ── 7. Ad-hoc code sign ────────────────────────────────────────────────────
echo
echo "▶ Ad-hoc code signing"
codesign --force --deep --sign - "$APP_OUTPUT"
codesign --verify --verbose=2 "$APP_OUTPUT" 2>&1 | head -5 | sed 's/^/  /'

# ── 8. Print summary ───────────────────────────────────────────────────────
echo
echo "✓ Built $APP_OUTPUT"
echo "  size:  $(du -sh "$APP_OUTPUT" | cut -f1)"
echo "  files: $(find "$APP_OUTPUT" -type f | wc -l | tr -d ' ')"
echo
echo "To run:"
echo "  open '$APP_OUTPUT'"
echo
echo "To test:"
echo "  ./ci/cardinal-rule-test.sh '$APP_OUTPUT'"
echo "  ./ci/lift-and-shift-test.sh '$APP_OUTPUT'"
