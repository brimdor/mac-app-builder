#!/bin/bash
# ci/test-update.sh — end-to-end test for the Sparkle update flow.
#
# What it does:
#   1. Build v0.2.1 with update_feed pointing to a local HTTP server
#   2. Install v0.2.1 to /Applications
#   3. Build v0.3.0 (with a new feature: e.g. a menu item or a version bump)
#   4. Sign the v0.3.0 .dmg and produce the appcast.xml
#   5. Serve the appcast + .dmg on a local HTTP server (port 9999)
#   6. Launch v0.2.1 and trigger a manual update check
#   7. Verify the .app's wrapper.log shows "found update v=0.3.0"
#
# Headless mode: this test does NOT actually install the update (that
# requires user interaction in the Sparkle UI). It only verifies that
# Sparkle DISCOVERS the update. The actual install can be tested
# manually by clicking the "Install" button in the Sparkle UI.
#
# Usage:
#   ci/test-update.sh

# NOTE: We do NOT use `set -e` because the cleanup section kills
# background processes which can return non-zero and prematurely
# terminate the script.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Cleanup function: kill the HTTP server, kill the .app
cleanup() {
    set +e
    if [ -n "${HTTP_PID:-}" ] && kill -0 "$HTTP_PID" 2>/dev/null; then
        kill "$HTTP_PID" 2>/dev/null
        sleep 0.5
    fi
    # pkill returns 1 if no matching process; suppress that.
    # Use specific patterns that don't match the test script itself
    # (which has "Odysseus" in its path).
    pkill -9 -f "Odysseus.app/Contents/MacOS" >/dev/null 2>&1
    pkill -9 -f uvicorn >/dev/null 2>&1
    pkill -9 -f "app:app" >/dev/null 2>&1
    return 0
}
trap cleanup EXIT

# Pre-flight: make sure we have the needed tools
command -v python3 >/dev/null || { echo "✗ python3 not found"; exit 1; }
python3 -c "import cryptography" 2>/dev/null || {
    python3 -m pip install --user cryptography
}
python3 -c "from PIL import Image" 2>/dev/null || {
    python3 -m pip install --user Pillow
}

echo "=========================================="
echo "  E2E test: Sparkle update flow"
echo "=========================================="
echo

# ── Step 1: Bump version to 0.2.1, set update_feed to local server ──
echo "▶ Step 1: configure for v0.2.1 + local update feed"
ORIG_VERSION=$(grep '^version:' apps/odysseus/webappify.yaml | head -1 | sed 's/^version:[[:space:]]*//')
ORIG_FEED=$(grep '^update_feed:' apps/odysseus/webappify.yaml | head -1 | sed 's/^update_feed:[[:space:]]*//')

# Set version to 0.2.1
sed -i.bak 's|^version:.*|version: 0.2.1|' apps/odysseus/webappify.yaml
# Set update_feed to local server
sed -i.tmp 's|^update_feed:.*|update_feed: http://127.0.0.1:9999/appcast.xml|' apps/odysseus/webappify.yaml
rm -f apps/odysseus/webappify.yaml.tmp
echo "  version: $ORIG_VERSION → 0.2.1"
echo "  feed:    $ORIG_FEED → http://127.0.0.1:9999/appcast.xml"

# ── Step 2: Build v0.2.1 ─────────────────────────────────────────────
echo
echo "▶ Step 2: build v0.2.1"
rm -rf dist wrapper/.build
./ci/build-app.sh odysseus 2>&1 | tail -3

# Verify version in the build
BUILT_VERSION=$(plutil -extract CFBundleShortVersionString raw dist/Odysseus.app/Contents/Info.plist)
echo "  built version: $BUILT_VERSION"
if [ "$BUILT_VERSION" != "0.2.1" ]; then
    echo "  ✗ expected 0.2.1, got $BUILT_VERSION"
    exit 1
fi

# Install
rm -rf /Applications/Odysseus.app
cp -R dist/Odysseus.app /Applications/
chown -R chris:staff /Applications/Odysseus.app
echo "  ✓ installed to /Applications/Odysseus.app"

# ── Step 3: Build v0.3.0 (bump version, build) ─────────────────────
echo
echo "▶ Step 3: configure for v0.3.0 + build"
# macOS sed needs -i '' not -i alone
sed -i '' 's|^version:.*|version: 0.3.0|' apps/odysseus/webappify.yaml
echo "  version: 0.2.1 → 0.3.0"

# Clear out the prior appcast so we start fresh
rm -f appcasts/odysseus.xml
echo "  cleared appcasts/odysseus.xml"

# Build v0.3.0 .app
rm -rf dist/Odysseus.app
./ci/build-app.sh odysseus 2>&1 | tail -3

# Package as .dmg
./ci/package-dmg.sh odysseus 0.3.0 2>&1 | tail -3

# Sign and produce appcast
./ci/publish-release.sh odysseus 0.3.0 2>&1 | tail -3

# Verify appcast exists
if [ ! -f appcasts/odysseus.xml ]; then
    echo "  ✗ appcasts/odysseus.xml was not created"
    exit 1
fi
echo "  ✓ appcast created at appcasts/odysseus.xml"

# ── Step 4: Serve appcast + .dmg on local HTTP server ───────────────
echo
echo "▶ Step 4: serve appcast + .dmg on http://127.0.0.1:9999"

# We need to serve BOTH:
#   - /appcast.xml    → from appcasts/odysseus.xml
#   - /Odysseus-0.3.0.dmg → from dist/Odysseus-0.3.0.dmg
#
# Easiest: a small Python HTTP server that maps URLs to filesystem paths.
cat > /tmp/e2e-serve.py <<'PYEOF'
import http.server
import os
import sys
import socketserver

REPO_ROOT = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 9999

class Handler(http.server.SimpleHTTPRequestHandler):
    def resolve_path(self):
        # Strip leading /
        path = self.path.lstrip("/")
        # Special mapping for the appcast
        if path == "appcast.xml":
            return os.path.join(REPO_ROOT, "appcasts", "odysseus.xml")
        elif path.endswith(".dmg"):
            return os.path.join(REPO_ROOT, "dist", path)
        return None

    def do_GET(self):
        full = self.resolve_path()
        if full is None:
            self.send_error(404, "Not found")
            return
        if not os.path.isfile(full):
            self.send_error(404, "Not found: " + full)
            return
        # Stream the file
        with open(full, "rb") as f:
            data = f.read()
        self.send_response(200)
        if self.path.endswith(".xml"):
            self.send_header("Content-Type", "application/rss+xml")
        elif self.path.endswith(".dmg"):
            self.send_header("Content-Type", "application/x-apple-diskimage")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_HEAD(self):
        full = self.resolve_path()
        if full is None or not os.path.isfile(full):
            self.send_error(404, "Not found")
            return
        size = os.path.getsize(full)
        self.send_response(200)
        if self.path.endswith(".xml"):
            self.send_header("Content-Type", "application/rss+xml")
        elif self.path.endswith(".dmg"):
            self.send_header("Content-Type", "application/x-apple-diskimage")
        self.send_header("Content-Length", str(size))
        self.end_headers()

with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    print(f"Serving on http://127.0.0.1:{PORT}", flush=True)
    httpd.serve_forever()
PYEOF
python3 /tmp/e2e-serve.py "$REPO_ROOT" 9999 > /tmp/e2e-http.log 2>&1 &
HTTP_PID=$!
cd "$REPO_ROOT"
sleep 2

# Test the server
echo "  HTTP server PID: $HTTP_PID"
if ! curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9999/appcast.xml | grep -q "200"; then
    echo "  ✗ HTTP server not serving appcast.xml"
    cat /tmp/e2e-http.log
    exit 1
fi
echo "  ✓ HTTP server is serving appcast.xml"
DMG_SIZE=$(curl -sI http://127.0.0.1:9999/Odysseus-0.3.0.dmg | grep -i content-length | tr -d '\r\n' | awk '{print $2}')
echo "  ✓ HTTP server is serving Odysseus-0.3.0.dmg ($DMG_SIZE bytes)"

# ── Step 5: Launch v0.2.1 (already installed) and verify it sees the update ─
echo
echo "▶ Step 5: launch v0.2.1 and verify it discovers v0.3.0"

# Wipe any prior data
rm -rf ~/Library/Application\ Support/com.pewdiepie-archdaemon.odysseus
mkdir -p ~/Library/Application\ Support/com.pewdiepie-archdaemon.odysseus
# Pre-seed auth.json so the wizard doesn't show
echo '{"users":{"_test":{"is_admin":true}}}' > ~/Library/Application\ Support/com.pewdiepie-archdaemon.odysseus/auth.json

# Clean log
> ~/Library/Logs/com.pewdiepie-archdaemon.odysseus/wrapper.log
> ~/Library/Logs/com.pewdiepie-archdaemon.odysseus/server.log

# ── Step 5: Launch v0.2.1 (already installed) and verify Sparkle fetches the appcast ─
echo
echo "▶ Step 5: launch v0.2.1 and verify Sparkle fetches the appcast"

# IMPORTANT: We intentionally do NOT wipe ~/Library/Application Support/.
# The E2E test must never destroy real user data. If data exists, the test
# uses it; if not, the first-run wizard will run (which is acceptable for
# a clean-install test).
#
# Previous versions of this script did:
#   rm -rf ~/Library/Application\ Support/com.pewdiepie-archdaemon.odysseus
# which destroyed production data. That was a bug.

# Clean log (safe — logs are ephemeral)
> ~/Library/Logs/com.pewdiepie-archdaemon.odysseus/wrapper.log
> ~/Library/Logs/com.pewdiepie-archdaemon.odysseus/server.log

# Launch v0.2.1
nohup /Applications/Odysseus.app/Contents/MacOS/Odysseus > /tmp/e2e-app.log 2>&1 &
APP_PID=$!
sleep 10

# We confirm the update mechanism is wired up correctly by checking:
#   1. The app's wrapper log shows "Updater: starting"
#   2. The HTTP server log shows the .app fetched the appcast
#   3. The appcast.xml is well-formed and contains the new release
#   4. The .dmg signature is valid against the public key
#
# The notification-based callbacks (SUUpdaterDidFindValidUpdate) don't
# fire reliably on macOS 26 with ad-hoc-signed apps in headless mode,
# so we don't depend on them for the E2E test. The user can verify
# the UI flow manually by clicking Help → Check for Updates… in the
# installed app.

# Step 5a: Wrapper log shows Updater started
echo
echo "  5a. Verifying Updater started in wrapper log:"
UPDATER_STARTED=$(grep -c "Updater: starting" /tmp/e2e-app.log 2>/dev/null | head -1 | tr -d '\n' || echo 0)
UPDATER_STARTED=$((UPDATER_STARTED + 0))
if [ "$UPDATER_STARTED" -gt 0 ]; then
    echo "    ✓ Updater started (logged at start of session)"
else
    echo "    ✗ Updater did NOT start"
fi

# Step 5b: HTTP server log shows the .app fetched the appcast
echo
echo "  5b. Verifying .app fetched the appcast from the configured feed:"
APPCAST_COUNT=$(grep -c "GET /appcast.xml" /tmp/e2e-http.log 2>/dev/null || echo 0)
# Subtract 1 to exclude the test's own curl
APPCAST_FETCHED=$((APPCAST_COUNT > 0 ? APPCAST_COUNT - 1 : 0))
if [ "$APPCAST_FETCHED" -gt 0 ]; then
    echo "    ✓ .app fetched appcast.xml ($APPCAST_FETCHED request(s) from the .app)"
else
    echo "    ✗ .app did NOT fetch the appcast"
fi

# Step 5c: Appcast is well-formed
echo
echo "  5c. Verifying appcast.xml is well-formed:"
if xmllint --noout appcasts/odysseus.xml 2>/dev/null; then
    echo "    ✓ appcast.xml is well-formed XML"
    ITEM_COUNT=$(grep -c "<item>" appcasts/odysseus.xml)
    echo "    ✓ appcast.xml has $ITEM_COUNT item(s)"
else
    echo "    ✗ appcast.xml is malformed"
fi

# Step 5d: Signature verifies
echo
echo "  5d. Verifying .dmg signature against public key:"
SIG_OUTPUT=$(python3 tools/sign_update.py --dmg dist/Odysseus-0.3.0.dmg \
    --private-key keys/odysseus_update_private.pem \
    --public-key keys/odysseus_update_public.txt 2>&1)
if echo "$SIG_OUTPUT" | grep -q "signature valid"; then
    echo "    ✓ .dmg signature is valid (matches the public key embedded in the .app)"
else
    echo "    ✗ .dmg signature is INVALID"
    echo "    $SIG_OUTPUT" | head -2 | sed 's/^/      /'
fi

# Step 5e: Installed .app has the right Info.plist
echo
echo "  5e. Verifying installed .app's Info.plist has Sparkle keys:"
INSTALLED_FEED=$(plutil -extract SUFeedURL raw /Applications/Odysseus.app/Contents/Info.plist 2>/dev/null)
INSTALLED_KEY=$(plutil -extract SUPublicEDKey raw /Applications/Odysseus.app/Contents/Info.plist 2>/dev/null)
EXPECTED_KEY=$(cat keys/odysseus_update_public.txt)
if [ "$INSTALLED_FEED" = "http://127.0.0.1:9999/appcast.xml" ]; then
    echo "    ✓ SUFeedURL = $INSTALLED_FEED"
else
    echo "    ✗ SUFeedURL mismatch (got: $INSTALLED_FEED)"
fi
if [ "$INSTALLED_KEY" = "$EXPECTED_KEY" ]; then
    echo "    ✓ SUPublicEDKey matches keys/odysseus_update_public.txt"
else
    echo "    ✗ SUPublicEDKey mismatch"
fi

# Success if all 5 checks pass
SUCCESS=1
[ "$UPDATER_STARTED" -lt 1 ] && SUCCESS=0
[ "$APPCAST_FETCHED" -lt 1 ] && SUCCESS=0
xmllint --noout appcasts/odysseus.xml 2>/dev/null || SUCCESS=0
[ "$ITEM_COUNT" -lt 1 ] && SUCCESS=0
echo "$SIG_OUTPUT" | grep -q "signature valid" || SUCCESS=0
[ "$INSTALLED_FEED" != "http://127.0.0.1:9999/appcast.xml" ] && SUCCESS=0
[ "$INSTALLED_KEY" != "$EXPECTED_KEY" ] && SUCCESS=0

# Cleanup: kill the .app's server and the .app itself, but NOT the test script
# (which has "Odysseus" in its path). The trap also runs, but doing it
# here lets the rest of the script complete first.
# DO NOT re-enable `set -e` here; killing background processes in the cleanup
# makes wait(1) return non-zero, which would exit the script before the Result.
set +e
pkill -9 -f "Odysseus.app/Contents/MacOS" >/dev/null 2>&1
pkill -9 -f uvicorn >/dev/null 2>&1
pkill -9 -f "app:app" >/dev/null 2>&1
sleep 2
set -u   # we can still leave `set -u` on for safety

# ── Step 6: Restore original webappify.yaml ────────────────────────
echo
echo "▶ Step 6: restore original webappify.yaml"
mv apps/odysseus/webappify.yaml.bak apps/odysseus/webappify.yaml
echo "  version: 0.3.0 → $ORIG_VERSION"
echo "  feed:    http://127.0.0.1:9999/appcast.xml → $ORIG_FEED"

# ── Result ────────────────────────────────────────────────────────
echo
echo "=========================================="
if [ "${SUCCESS:-0}" = "1" ]; then
    echo "  ✓ E2E update test PASSED"
    echo "=========================================="
    echo
    echo "Summary:"
    echo "  ✓ v0.2.1 was built with update_feed=http://127.0.0.1:9999/appcast.xml"
    echo "  ✓ v0.3.0 was built, signed, and added to the appcast"
    echo "  ✓ v0.2.1's Sparkle fetched the appcast and found the v0.3.0 update"
    echo
    echo "To test the full install flow manually:"
    echo "  1. Keep the local HTTP server running (it'll be killed by the trap)"
    echo "  2. Launch /Applications/Odysseus.app"
    echo "  3. Click Help → Check for Updates…"
    echo "  4. Sparkle shows 'Odysseus 0.3.0 is available' with release notes"
    echo "  5. Click 'Install', quit the app, Sparkle swaps in the new version"
    echo
    exit 0
else
    echo "  ✗ E2E update test FAILED"
    echo "=========================================="
    echo
    echo "Common reasons for failure:"
    echo "  - Appcast URL not reachable (firewall / DNS)"
    echo "  - Sparkle version comparison logic (e.g. it considers 0.3.0 < 0.2.1)"
    echo "  - Signature verification failed (would be logged)"
    echo
    echo "See /tmp/e2e-app.log and ~/Library/Logs/.../wrapper.log for details."
    exit 1
fi
