#!/bin/bash
# ci/check-upstream.sh — check if upstream Odysseus has new commits, and if so,
# trigger a new release of the mac-app-builder .app.
#
# Usage:
#   ci/check-upstream.sh <app-name>
#
# Environment:
#   UPSTREAM_REPO   — git URL of upstream (default: from build-runtime.sh)
#   UPSTREAM_REF    — git ref to track (default: main)
#   GITHUB_TOKEN    — required for creating releases via gh CLI
#
# Flow:
#   1. Clone upstream repo (shallow)
#   2. Get latest commit hash
#   3. Compare with last-known upstream commit (stored in .upstream-commit)
#   4. If different: build new .app, bump version, tag, release
#   5. If same: exit 0 (no action needed)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${1:-}"

if [ -z "$APP_NAME" ]; then
    echo "usage: $0 <app-name>"
    exit 1
fi

PER_APP_DIR="$REPO_ROOT/apps/$APP_NAME"
WEBAPIFY="$PER_APP_DIR/webappify.yaml"
UPSTREAM_STATE="$PER_APP_DIR/.upstream-commit"

# Read upstream config from build-runtime.sh
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/pewdiepie-archdaemon/odysseus.git}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"

echo "▶ Checking upstream for $APP_NAME"
echo "  repo: $UPSTREAM_REPO"
echo "  ref:  $UPSTREAM_REF"

# ── 1. Fetch latest upstream commit (shallow clone) ────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_REPO" "$TMP_DIR/upstream" 2>&1 | sed 's/^/  /'
LATEST_COMMIT="$(cd "$TMP_DIR/upstream" && git rev-parse HEAD)"
echo "  latest upstream commit: $LATEST_COMMIT"

# ── 2. Compare with last-known commit ────────────────────────────────────
if [ -f "$UPSTREAM_STATE" ]; then
    LAST_COMMIT="$(cat "$UPSTREAM_STATE")"
    echo "  last known commit:    $LAST_COMMIT"
    if [ "$LATEST_COMMIT" = "$LAST_COMMIT" ]; then
        echo "  ✓ Upstream is up to date. No release needed."
        exit 0
    fi
    echo "  ✗ New upstream commits detected!"
else
    echo "  (no previous state file; assuming first run)"
fi

# ── 3. Read current version and compute next ───────────────────────────────
CURRENT_VERSION="$(grep '^version:' "$WEBAPIFY" | head -1 | sed 's/^version:[[:space:]]*//')"
CURRENT_BUILD="$(grep '^build_number:' "$WEBAPIFY" | head -1 | sed 's/^build_number:[[:space:]]*//')"
echo "  current version: $CURRENT_VERSION (build $CURRENT_BUILD)"

# Bump version: x.y.z → x.y.(z+1)
# If no patch version, append .1
if echo "$CURRENT_VERSION" | grep -q '^[0-9]\+\.[0-9]\+$'; then
    NEXT_VERSION="${CURRENT_VERSION}.1"
elif echo "$CURRENT_VERSION" | grep -q '^[0-9]\+\.[0-9]\+\.[0-9]\+$'; then
    MAJOR="$(echo "$CURRENT_VERSION" | cut -d. -f1)"
    MINOR="$(echo "$CURRENT_VERSION" | cut -d. -f2)"
    PATCH="$(echo "$CURRENT_VERSION" | cut -d. -f3)"
    NEXT_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
else
    echo "  ✗ Cannot auto-bump version: $CURRENT_VERSION (expected x.y.z or x.y)"
    exit 1
fi
NEXT_BUILD="$((CURRENT_BUILD + 1))"
echo "  next version:    $NEXT_VERSION (build $NEXT_BUILD)"

# ── 4. Update webappify.yaml ─────────────────────────────────────────────
echo ""
echo "▶ Updating webappify.yaml"
sed -i '' "s/^version: .*/version: $NEXT_VERSION/" "$WEBAPIFY"
sed -i '' "s/^build_number: .*/build_number: $NEXT_BUILD/" "$WEBAPIFY"
echo "  version: $CURRENT_VERSION → $NEXT_VERSION"
echo "  build:   $CURRENT_BUILD → $NEXT_BUILD"

# ── 5. Save upstream state ──────────────────────────────────────────────
echo "$LATEST_COMMIT" > "$UPSTREAM_STATE"
echo "  saved upstream commit: $LATEST_COMMIT"

# ── 6. Commit version bump ──────────────────────────────────────────────
echo ""
echo "▶ Committing version bump"
git add "$WEBAPIFY" "$UPSTREAM_STATE"
git commit -m "Bump $APP_NAME to $NEXT_VERSION (build $NEXT_BUILD) — upstream $LATEST_COMMIT"

# ── 7. Create tag to trigger release workflow ──────────────────────────
TAG="v$NEXT_VERSION"
echo ""
echo "▶ Creating tag $TAG"
git tag "$TAG"

echo ""
echo "=========================================="
echo "  ✓ Upstream update detected!"
echo "=========================================="
echo "  upstream:     $UPSTREAM_REPO @ $UPSTREAM_REF"
echo "  commit:       $LATEST_COMMIT"
echo "  new version:  $NEXT_VERSION (build $NEXT_BUILD)"
echo "  tag:          $TAG"
echo ""
echo "Next: push the tag to trigger .github/workflows/release.yml"
echo "  git push origin main"
echo "  git push origin $TAG"
