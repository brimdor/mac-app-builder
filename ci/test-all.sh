#!/bin/bash
# ci/test-all.sh — runs the full test suite for a per-app.
#
# Usage: ci/test-all.sh <app-name>
# Example: ci/test-all.sh odysseus
#
# Runs:
#   1. ci/build-app.sh          — builds the .app
#   2. ci/cardinal-rule-test.sh — verifies the Cardinal Rule
#   3. ci/lift-and-shift-test.sh — verifies the .app is portable
#   4. ci/package-dmg.sh         — packages the .dmg

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${1:-}"

if [ -z "$APP_NAME" ]; then
    echo "usage: $0 <app-name>"
    exit 1
fi

echo "============================================"
echo "  Full test suite for $APP_NAME"
echo "============================================"
echo

# Step 1: build
echo "▶ Step 1/4: build"
"$REPO_ROOT/ci/build-app.sh" "$APP_NAME"
echo

# Step 2: Cardinal Rule
echo "▶ Step 2/4: Cardinal Rule"
DISPLAY_NAME="$(echo "$APP_NAME" | tr '[:lower:]' '[:upper:]' | cut -c1)$(echo "$APP_NAME" | cut -c2-)"
"$REPO_ROOT/ci/cardinal-rule-test.sh" "$REPO_ROOT/dist/${DISPLAY_NAME}.app"
echo

# Step 3: Lift and shift
echo "▶ Step 3/4: Lift and shift"
"$REPO_ROOT/ci/lift-and-shift-test.sh" "$REPO_ROOT/dist/${DISPLAY_NAME}.app"
echo

# Step 4: Package
echo "▶ Step 4/4: package .dmg"
"$REPO_ROOT/ci/package-dmg.sh" "$APP_NAME"
echo

echo "============================================"
echo "  ✓ All tests passed for $APP_NAME"
echo "============================================"
echo
echo "Artifacts:"
ls -la "$REPO_ROOT/dist/" | sed 's/^/  /'
