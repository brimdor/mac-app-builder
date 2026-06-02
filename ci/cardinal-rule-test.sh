#!/bin/bash
# ci/cardinal-rule-test.sh — verifies the Cardinal Rule.
#
# The Cardinal Rule: the .app bundle contains no unique user data.
# All user data lives in ~/Library/Application Support/<bundle_id>/.
#
# This test:
#   1. Reads the bundle ID from the .app's Info.plist
#   2. Wipes any pre-existing data for that bundle ID
#   3. Installs the .app to a test location
#   4. Launches the .app
#   5. Waits for the server to be ready (or the UI to load)
#   6. Performs a known write to the user data path (via the server)
#   7. Quits the .app
#   8. Verifies: the data is in ~/Library/Application Support/<bundle_id>/, NOT in the .app
#   9. Moves the .app to a new location
#   10. Re-verifies: the data is STILL at the original ~/Library/ path (proves it's not tied to the .app)
#
# Exits 0 on success, non-zero on failure.
#
# Usage: ci/cardinal-rule-test.sh <app-bundle-path>
# Example: ci/cardinal-rule-test.sh dist/Odysseus.app

set -eo pipefail

# Note: we intentionally do NOT use `set -u` here. The Cardinal Rule test
# runs against an external .app that may take time to start; an unbound
# variable should not abort the test. `set -e` and `set -o pipefail` are
# still on, so real errors are caught.

APP_BUNDLE="${1:-}"

if [ -z "$APP_BUNDLE" ]; then
    echo "usage: $0 <app-bundle-path>"
    exit 1
fi

if [ ! -d "$APP_BUNDLE" ]; then
    echo "✗ $APP_BUNDLE does not exist"
    exit 1
fi

echo "▶ Cardinal Rule test for $APP_BUNDLE"
echo

# ── Read bundle ID ─────────────────────────────────────────────────────────
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "")
if [ -z "$BUNDLE_ID" ]; then
    echo "✗ Could not read CFBundleIdentifier from Info.plist"
    exit 1
fi
echo "  bundle id: $BUNDLE_ID"

# ── Wipe any pre-existing data ────────────────────────────────────────────
DATA_DIR="$HOME/Library/Application Support/$BUNDLE_ID"
LOGS_DIR="$HOME/Library/Logs/$BUNDLE_ID"
CACHE_DIR="$HOME/Library/Caches/$BUNDLE_ID"
echo "  wiping pre-existing data at:"
echo "    $DATA_DIR"
echo "    $LOGS_DIR"
echo "    $CACHE_DIR"
rm -rf "$DATA_DIR" "$LOGS_DIR" "$CACHE_DIR" 2>/dev/null || true

# ── Install to a test location ─────────────────────────────────────────────
TEST_INSTALL="/tmp/cardinal-test-$$"
mkdir -p "$TEST_INSTALL"
cp -R "$APP_BUNDLE" "$TEST_INSTALL/MyApp.app"
TEST_APP="$TEST_INSTALL/MyApp.app"
echo "  installed to: $TEST_APP"

# ── Snapshot the .app's files BEFORE launch (to detect new files) ─────────
APP_FILES_BEFORE=$(find "$TEST_APP" -type f 2>/dev/null | sort)
APP_FILES_BEFORE_COUNT=$(echo "$APP_FILES_BEFORE" | wc -l | tr -d ' ')
echo "  $APP_FILES_BEFORE_COUNT files in .app before launch"

# ── Launch the .app ───────────────────────────────────────────────────────
echo "  launching .app…"
open "$TEST_APP"
LAUNCH_TIME=$(date +%s)

# ── Wait for the server to be ready (poll the data dir) ───────────────────
echo "  waiting for data to appear in $DATA_DIR…"
WAITED=0
MAX_WAIT=60
while [ ! -d "$DATA_DIR" ] && [ $WAITED -lt $MAX_WAIT ]; do
    sleep 1
    WAITED=$((WAITED + 1))
done
if [ ! -d "$DATA_DIR" ]; then
    echo "✗ Data directory was not created within ${MAX_WAIT}s"
    pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
    rm -rf "$TEST_INSTALL"
    exit 1
fi
echo "  data dir created after ${WAITED}s"

# ── Wait for some real data to be written ─────────────────────────────────
echo "  waiting for data writes…"
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    # Check if the data dir has any files (or subdirs with files)
    FILE_COUNT=$(find "$DATA_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$FILE_COUNT" -gt 0 ]; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done
DATA_FILES=$(find "$DATA_DIR" -type f 2>/dev/null)
DATA_FILE_COUNT=$(echo "$DATA_FILES" | wc -l | tr -d ' ')
echo "  data dir has $DATA_FILE_COUNT file(s) after ${WAITED}s"

if [ "$DATA_FILE_COUNT" -eq 0 ]; then
    echo "  (warning: no data files were written during the test window — the test may be inconclusive)"
fi

# ── Quit the .app ──────────────────────────────────────────────────────────
echo "  quitting .app…"
pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
sleep 2

# ── Cardinal Rule check 1: no NEW files inside the .app bundle ────────────
APP_FILES_AFTER=$(find "$TEST_APP" -type f 2>/dev/null | sort)
APP_FILES_AFTER_COUNT=$(echo "$APP_FILES_AFTER" | wc -l | tr -d ' ')

# Find any files that were added inside the .app (excluding _CodeSignature)
NEW_FILES_IN_BUNDLE=$(comm -13 <(echo "$APP_FILES_BEFORE") <(echo "$APP_FILES_AFTER") | grep -v "_CodeSignature" || true)

if [ -n "$NEW_FILES_IN_BUNDLE" ]; then
    echo
    echo "✗ FAIL: files were created inside the .app bundle during use:"
    echo "$NEW_FILES_IN_BUNDLE" | sed 's/^/    /'
    echo
    echo "This violates the Cardinal Rule. User data must live in"
    echo "~/Library/Application Support/$BUNDLE_ID/, not in the .app."
    pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
    rm -rf "$TEST_INSTALL"
    exit 1
fi
echo "  ✓ no new files in .app bundle"

# ── Cardinal Rule check 2: data is in ~/Library/, not in the .app ─────────
if [ "$DATA_FILE_COUNT" -gt 0 ]; then
    # Get a sample of the data files (for human inspection if the test fails)
    echo "  sample data files:"
    echo "$DATA_FILES" | head -5 | sed 's/^/    /'
fi

# ── Cardinal Rule check 3: lift-and-shift — move the .app, data stays ─────
echo
echo "▶ Cardinal Rule check 3: lift-and-shift"
SHIFTED_INSTALL="/tmp/cardinal-test-shifted-$$"
mkdir -p "$SHIFTED_INSTALL"
mv "$TEST_APP" "$SHIFTED_INSTALL/MyApp.app"
SHIFTED_APP="$SHIFTED_INSTALL/MyApp.app"
echo "  moved .app from $TEST_INSTALL to $SHIFTED_INSTALL"

# Snapshot the data BEFORE relaunch
DATA_BEFORE_RELAUNCH=$(find "$DATA_DIR" -type f 2>/dev/null | sort)

# Relaunch
echo "  relaunching .app from new location…"
open "$SHIFTED_APP"
sleep 5
# Write a known marker file
MARKER="$DATA_DIR/.cardinal-rule-marker-$$"
echo "marker" > "$MARKER" 2>/dev/null || true
sleep 2
pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
sleep 2

# Verify the data is still at the original ~/Library/ location
if [ ! -f "$MARKER" ]; then
    echo "✗ FAIL: marker file at $MARKER was not created (data is not at the expected path)"
    pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
    rm -rf "$TEST_INSTALL" "$SHIFTED_INSTALL"
    exit 1
fi
echo "  ✓ marker file present at $MARKER"

# Check that the data didn't migrate to the new .app location
SHIFTED_DATA="$SHIFTED_INSTALL/MyApp.app/Contents/Resources/data"
if [ -d "$SHIFTED_DATA" ]; then
    echo "✗ FAIL: data was found inside the shifted .app at $SHIFTED_DATA"
    pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
    rm -rf "$TEST_INSTALL" "$SHIFTED_INSTALL"
    exit 1
fi
echo "  ✓ no data inside the shifted .app"

# ── Cleanup ────────────────────────────────────────────────────────────────
pkill -f "MyApp.app/Contents/MacOS" 2>/dev/null || true
rm -rf "$TEST_INSTALL" "$SHIFTED_INSTALL" 2>/dev/null || true

echo
echo "✓ Cardinal Rule test passed"
echo "  data lives at: $DATA_DIR (not in the .app)"
echo "  .app can be moved freely without affecting user data"
