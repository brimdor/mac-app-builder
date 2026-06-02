#!/bin/bash
# ci/publish-release.sh — sign a .dmg and render an appcast.xml.
#
# v1.1: this script does the work that was previously manual:
#   1. Sign the .dmg with the per-app's Ed25519 private key
#   2. Render appcasts/<app>.xml from the template
#   3. Append the new <item> to the existing appcast (or create a new one)
#   4. Print next-step instructions (e.g. commit the appcast, create GH release)
#
# Usage:
#   ci/publish-release.sh <app-name> <version> [dmg-url]
#
# Example:
#   ci/publish-release.sh odysseus 0.3.0 https://github.com/brimdor/mac-app-builder/releases/download/v0.3.0/Odysseus-0.3.0.dmg
#
# Environment:
#   ODYSSEUS_UPDATE_PRIVATE_KEY_PEM   if set, used as the private key
#                                      (overrides --private-key file lookup).
#                                      In CI, this is populated from a
#                                      GitHub Actions secret.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${1:-}"
VERSION="${2:-}"
DMG_URL="${3:-}"

if [ -z "$APP_NAME" ] || [ -z "$VERSION" ]; then
    echo "usage: $0 <app-name> <version> [dmg-url]"
    echo "  example: $0 odysseus 0.3.0 https://github.com/.../Odysseus-0.3.0.dmg"
    echo
    echo "  - <app-name>: the per-app dir name (e.g. odysseus)"
    echo "  - <version>:  the version to publish (e.g. 0.3.0)"
    echo "  - <dmg-url>:  the URL where end users will download the .dmg"
    echo "                (default: file://<path> of the local .dmg, for testing)"
    exit 1
fi

# Capitalize first letter (macOS bash 3.2 has no ${var^})
APP_DISPLAY_NAME="$(echo "$APP_NAME" | tr '[:lower:]' '[:upper:]' | cut -c1)$(echo "$APP_NAME" | cut -c2-)"
DIST_DIR="$REPO_ROOT/dist"
DMG_PATH="$DIST_DIR/${APP_DISPLAY_NAME}-${VERSION}.dmg"
APPCAST_DIR="$REPO_ROOT/appcasts"
APPCAST_PATH="$APPCAST_DIR/${APP_NAME}.xml"
APPCAST_TMPL="$APPCAST_DIR/appcast.xml.tmpl"

PRIVATE_KEY=""
if [ -n "${ODYSSEUS_UPDATE_PRIVATE_KEY_PEM:-}" ]; then
    PRIVATE_KEY_TMP="$(mktemp)"
    trap 'rm -f "$PRIVATE_KEY_TMP"' EXIT
    echo "$ODYSSEUS_UPDATE_PRIVATE_KEY_PEM" > "$PRIVATE_KEY_TMP"
    PRIVATE_KEY="$PRIVATE_KEY_TMP"
elif [ -f "$REPO_ROOT/keys/${APP_NAME}_update_private.pem" ]; then
    PRIVATE_KEY="$REPO_ROOT/keys/${APP_NAME}_update_private.pem"
else
    echo "✗ No private key found."
    echo "  Either set ODYSSEUS_UPDATE_PRIVATE_KEY_PEM in the environment,"
    echo "  or run tools/generate_keys.py $APP_NAME first."
    exit 1
fi

# Locate the .dmg
if [ ! -f "$DMG_PATH" ]; then
    echo "✗ $DMG_PATH does not exist. Run ci/package-dmg.sh first."
    exit 1
fi

# Default to a local file:// URL for testing
if [ -z "$DMG_URL" ]; then
    DMG_URL="file://$DMG_PATH"
    echo "▶ No --dmg-url given; using $DMG_URL"
    echo "  (for production, pass the public URL of the .dmg)"
fi

echo "▶ Publishing $APP_DISPLAY_NAME $VERSION"
echo "  dmg:        $DMG_PATH"
echo "  size:       $(du -h "$DMG_PATH" | cut -f1)"
echo "  dmg-url:    $DMG_URL"
echo "  appcast:    $APPCAST_PATH"
echo "  privkey:    $PRIVATE_KEY"
echo

# 1. Sign the .dmg
echo "▶ Signing $DMG_PATH"
SIGNATURE=$(python3 "$REPO_ROOT/tools/sign_update.py" \
    --dmg "$DMG_PATH" \
    --private-key "$PRIVATE_KEY" \
    --public-key "$REPO_ROOT/keys/${APP_NAME}_update_public.txt")
echo "  signature:  $SIGNATURE"

# 2. Compute the .dmg length
DMG_LENGTH=$(stat -f%z "$DMG_PATH")
echo "  length:     $DMG_LENGTH bytes"

# 3. Render the new <item>
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
NEW_ITEM=$(cat <<EOF
    <item>
      <title>$APP_DISPLAY_NAME $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>1</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>
      <enclosure url="$DMG_URL"
                 sparkle:edSignature="$SIGNATURE"
                 length="$DMG_LENGTH"
                 type="application/x-apple-diskimage" />
    </item>
EOF
)

# 4. Read existing appcast (if any) and prepend the new item
mkdir -p "$APPCAST_DIR"
if [ -f "$APPCAST_PATH" ]; then
    echo "▶ Updating existing appcast $APPCAST_PATH"
    # Insert NEW_ITEM before the closing </channel> tag.
    # We use python to do this safely (avoid sed quoting hell).
    python3 - <<PYEOF
import sys
with open("$APPCAST_PATH") as f:
    content = f.read()
new_item = """$NEW_ITEM"""
# Find the existing items (between <item> and </item>); keep them
# and add new_item at the top.
import re
existing = re.findall(r"<item>.*?</item>", content, re.DOTALL)
items = [new_item] + existing
items_xml = "\n" + "\n".join(items) + "\n  "
content_new = re.sub(r"<item>.*?</item>", "", content, flags=re.DOTALL)
content_new = content_new.replace("</channel>", items_xml + "</channel>")
# Fill in title/link
content_new = content_new.replace("\${APP_DISPLAY_NAME}", "$APP_DISPLAY_NAME")
content_new = content_new.replace("\${APPCAST_LINK}", "$DMG_URL")
content_new = content_new.replace("\${ITEMS}", "")
with open("$APPCAST_PATH", "w") as f:
    f.write(content_new)
print("  ✓ wrote", "$APPCAST_PATH", "with", len(existing) + 1, "item(s)")
PYEOF
else
    echo "▶ Creating new appcast $APPCAST_PATH"
    # Read template
    if [ ! -f "$APPCAST_TMPL" ]; then
        echo "✗ $APPCAST_TMPL missing"
        exit 1
    fi
    # Substitute
    {
        cat "$APPCAST_TMPL" | \
            sed -e "s|\${APP_DISPLAY_NAME}|$APP_DISPLAY_NAME|g" \
                -e "s|\${APPCAST_LINK}|$DMG_URL|g"
        # Replace ${ITEMS} placeholder
    } | python3 -c "
import sys
content = sys.stdin.read()
items = '''$NEW_ITEM'''
content = content.replace('\${ITEMS}', '\n' + items)
sys.stdout.write(content)
" > "$APPCAST_PATH"
    echo "  ✓ wrote $APPCAST_PATH with 1 item"
fi

# 5. Validate the XML
echo
echo "▶ Validating appcast XML"
xmllint --noout "$APPCAST_PATH" 2>&1 && echo "  ✓ valid XML" || echo "  ⚠ xmllint validation failed (continuing)"

# 6. Print next steps
echo
echo "============================================"
echo "  ✓ Appcast ready: $APPCAST_PATH"
echo "============================================"
cat "$APPCAST_PATH"
echo
echo "Next steps:"
echo "  1. Commit the updated appcast:"
echo "       git add appcasts/$APP_NAME.xml"
echo "       git commit -m 'Release $APP_DISPLAY_NAME $VERSION'"
echo
echo "  2. For GitHub Releases: upload $DMG_PATH to a release and the"
echo "     appcast will reference its URL."
echo
echo "  3. (Optional) Configure your CDN / GitHub Pages to serve the"
echo "     appcast at the URL configured in webappify.yaml's update_feed."
