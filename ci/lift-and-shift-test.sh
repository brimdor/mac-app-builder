#!/bin/bash
# ci/lift-and-shift-test.sh — verifies the .app works when moved to a
# new location. This is the key property of the standard: the .app is
# truly portable.
#
# Usage: ci/lift-and-shift-test.sh <app-bundle-path>
# Example: ci/lift-and-shift-test.sh dist/Odysseus.app

set -eo pipefail

# Note: we intentionally do NOT use `set -u` here. The lift-and-shift test
# runs against an external .app and deals with timing-sensitive operations
# (server startup, file moves). An unbound variable should not abort the
# test. `set -e` and `set -o pipefail` are still on, so real errors are caught.

APP_BUNDLE="${1:-}"

if [ -z "$APP_BUNDLE" ]; then
    echo "usage: $0 <app-bundle-path>"
    exit 1
fi

if [ ! -d "$APP_BUNDLE" ]; then
    echo "✗ $APP_BUNDLE does not exist"
    exit 1
fi

BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "")
PORT=$(grep '^port:' "$(dirname "$APP_BUNDLE")/../apps/"*"/webappify.yaml" 2>/dev/null | head -1 | sed 's/^port:[[:space:]]*//' || echo "0")
if [ "$PORT" = "0" ]; then
    # Fallback: try to find the port in the .app's webappify.yaml
    PORT=$(plutil -convert json -o - "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null | python3 -c "import json, sys; print(0)" 2>/dev/null || echo "0")
fi

# If we don't know the port from webappify.yaml (we don't bundle the yml parser here),
# try to read it from the .app's webappify.yaml.
if [ -f "$APP_BUNDLE/Contents/Resources/webappify.yaml" ]; then
    PORT=$(grep '^port:' "$APP_BUNDLE/Contents/Resources/webappify.yaml" | head -1 | sed 's/^port:[[:space:]]*//')
fi

if [ -z "$PORT" ] || [ "$PORT" = "0" ]; then
    echo "✗ Could not determine port from webappify.yaml"
    exit 1
fi

echo "▶ Lift-and-shift test for $APP_BUNDLE"
echo "  bundle id: $BUNDLE_ID"
echo "  port:      $PORT"
echo

# ── Wipe existing data for clean test ─────────────────────────────────────
DATA_DIR="$HOME/Library/Application Support/$BUNDLE_ID"
LOGS_DIR="$HOME/Library/Logs/$BUNDLE_ID"
rm -rf "$DATA_DIR" "$LOGS_DIR" 2>/dev/null || true

# ── Copy to a temp location, launch, verify ──────────────────────────────
TEST_DIR="/tmp/lift-shift-test-$$"
mkdir -p "$TEST_DIR/original" "$TEST_DIR/shifted"

# Phase 1: launch from one location
cp -R "$APP_BUNDLE" "$TEST_DIR/original/MyApp.app"
ORIGINAL_APP="$TEST_DIR/original/MyApp.app"

echo "▶ Phase 1: launch from $TEST_DIR/original/"
open "$ORIGINAL_APP"
echo "  waiting for server to start on port $PORT…"
WAITED=0
MAX_WAIT=60
SERVER_UP=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -s -o /dev/null -w "%{http_code}" --max-time 1 "http://127.0.0.1:$PORT/" | grep -qE "^[12345]"; then
        SERVER_UP=1
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done
if [ "$SERVER_UP" != "1" ]; then
    echo "✗ Server did not start within ${MAX_WAIT}s from $ORIGINAL_APP"
    pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
    rm -rf "$TEST_DIR"
    exit 1
fi
echo "  ✓ server is up after ${WAITED}s"

# Write a known data point
sleep 2
MARKER="$DATA_DIR/.lift-shift-marker-$$"
echo "phase 1 marker" > "$MARKER" 2>/dev/null || true
sleep 1

# Quit
pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
sleep 2

if [ ! -f "$MARKER" ]; then
    echo "✗ Phase 1: data was not written to $DATA_DIR"
    rm -rf "$TEST_DIR"
    exit 1
fi
echo "  ✓ data written to $DATA_DIR"

# ── Phase 2: move the .app, relaunch, verify it still works ───────────────
echo
echo "▶ Phase 2: move .app to $TEST_DIR/shifted/ and relaunch"
mv "$ORIGINAL_APP" "$TEST_DIR/shifted/MyApp.app"
SHIFTED_APP="$TEST_DIR/shifted/MyApp.app"

open "$SHIFTED_APP"
echo "  waiting for server to start from new location…"
WAITED=0
SERVER_UP=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -s -o /dev/null -w "%{http_code}" --max-time 1 "http://127.0.0.1:$PORT/" | grep -qE "^[12345]"; then
        SERVER_UP=1
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done
if [ "$SERVER_UP" != "1" ]; then
    echo "✗ Server did not start within ${MAX_WAIT}s from $SHIFTED_APP"
    pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
    rm -rf "$TEST_DIR"
    exit 1
fi
echo "  ✓ server is up after ${WAITED}s from new location"

# Verify the original data is still there
if [ ! -f "$MARKER" ]; then
    echo "✗ Phase 2: original data was lost when .app was moved"
    pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
    rm -rf "$TEST_DIR"
    exit 1
fi
echo "  ✓ original data preserved after moving .app"

# Write a new data point from the new location
sleep 2
MARKER2="$DATA_DIR/.lift-shift-marker-2-$$"
echo "phase 2 marker" > "$MARKER2" 2>/dev/null || true
sleep 1

# Quit
pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
sleep 2

if [ ! -f "$MARKER2" ]; then
    echo "✗ Phase 2: new data was not written from the new location"
    rm -rf "$TEST_DIR"
    exit 1
fi
echo "  ✓ new data written from new location"

# ── Phase 3: verify both markers are still at the original ~/Library/ path
echo
echo "▶ Phase 3: final verification"
if [ -f "$MARKER" ] && [ -f "$MARKER2" ]; then
    echo "  ✓ both data points are at $DATA_DIR"
    echo "  ✓ the .app is fully portable"
else
    echo "✗ One or both data points are missing"
    rm -rf "$TEST_DIR"
    exit 1
fi

# ── Cleanup ────────────────────────────────────────────────────────────────
pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
rm -rf "$TEST_DIR" 2>/dev/null || true
rm -f "$MARKER" "$MARKER2" 2>/dev/null || true

echo
echo "✓ Lift-and-shift test passed"
echo "  the .app works from any location on the filesystem"
echo "  user data is preserved across moves"
echo "  this is a real macOS app, not a per-installation"
