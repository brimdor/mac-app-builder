#!/bin/bash
# apps/odysseus/build-runtime.sh — bundles the Python runtime and the
# upstream Odysseus source into the .app's Resources/runtime/ and
# Resources/app/ directories.
#
# Inputs (env vars):
#   APP_DIR          — path to the .app's Contents/ (set by ci/build-app.sh)
#   ODYSSEUS_REPO    — git URL of the upstream Odysseus repo (default below)
#   ODYSSEUS_REF     — git ref to check out (default: main)
#   PBS_VERSION      — python-build-standalone version (default: 20240909)
#
# Outputs:
#   $APP_DIR/Resources/app/         — full upstream Odysseus source tree
#   $APP_DIR/Resources/runtime/python/ — relocatable Python install
#   $APP_DIR/Resources/runtime/site-packages/ — installed Python dependencies
#
# Note: this script does NOT create a venv. venv creation with --copies
# fails on python-build-standalone on macOS due to dyld/libpython issues
# (the symlink in venv/bin/python3 resolves @executable_path incorrectly).
# Instead, we install dependencies to a "site-packages" directory and
# rely on PYTHONPATH to find them. This is simpler, fully portable, and
# matches what the upstream Odysseus's start_command already expects
# (it uses `uvicorn` from a venv; we replace the venv with site-packages).
#
# The start_command in webappify.yaml points to:
#   ./runtime/python/bin/python3 -m uvicorn app:app ...
# And we set PYTHONPATH=./runtime/site-packages so uvicorn finds its deps.

set -euo pipefail

if [ -z "${APP_DIR:-}" ]; then
    echo "✗ APP_DIR must be set (path to .app's Contents/)"
    exit 1
fi
ODYSSEUS_REPO="${ODYSSEUS_REPO:-https://github.com/pewdiepie-archdaemon/odysseus.git}"
ODYSSEUS_REF="${ODYSSEUS_REF:-main}"
PBS_VERSION="${PBS_VERSION:-20240909}"

ARCH="$(uname -m)"
case "$ARCH" in
    arm64) PBS_ARCH="aarch64" ;;
    x86_64) PBS_ARCH="x86_64" ;;
    *) echo "✗ Unsupported architecture: $ARCH"; exit 1 ;;
esac

PYTHON_VERSION="3.11.10"
PBS_TAG="cpython-${PYTHON_VERSION}+${PBS_VERSION}-${PBS_ARCH}-apple-darwin-install_only"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_VERSION}/${PBS_TAG}.tar.gz"

WORK_DIR="$(mktemp -d -t odysseus-runtime-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "▶ Bundling Odysseus runtime"
echo "  upstream: $ODYSSEUS_REPO @ $ODYSSEUS_REF"
echo "  python:   $PYTHON_VERSION ($PBS_VERSION, $PBS_ARCH)"
echo

# ── 1. Clone the upstream Odysseus source ──────────────────────────────────
echo "▶ Cloning upstream Odysseus"
git clone --depth 1 --branch "$ODYSSEUS_REF" "$ODYSSEUS_REPO" "$WORK_DIR/app" 2>&1 | sed 's/^/  /'

# ── 2. Download python-build-standalone ─────────────────────────────────────
echo "▶ Downloading python-build-standalone"
PBS_TARBALL="$WORK_DIR/pbs.tar.gz"
curl -fsSL "$PBS_URL" -o "$PBS_TARBALL"
ls -lh "$PBS_TARBALL" | sed 's/^/  /'

# ── 3. Extract into the .app's Resources/runtime/python/ ──────────────────
RUNTIME_DIR="$APP_DIR/Resources/runtime"
mkdir -p "$RUNTIME_DIR"
tar -xzf "$PBS_TARBALL" -C "$WORK_DIR"
# The tarball extracts to a directory like "python/" — move it to runtime/python/
PBS_EXTRACTED="$WORK_DIR/python"
if [ ! -d "$PBS_EXTRACTED" ]; then
    echo "✗ python-build-standalone extraction failed (no 'python' dir found)"
    exit 1
fi
mv "$PBS_EXTRACTED" "$RUNTIME_DIR/python"
echo "  installed: $RUNTIME_DIR/python (Python $PYTHON_VERSION)"

# ── 4. Verify the relocatable Python works ─────────────────────────────────
PYTHON_BIN="$RUNTIME_DIR/python/bin/python3"
if [ ! -x "$PYTHON_BIN" ]; then
    echo "✗ Python binary not found at $PYTHON_BIN"
    exit 1
fi
"$PYTHON_BIN" --version | sed 's/^/  /'

# ── 5. Ad-hoc sign the Python binary and key libraries ─────────────────────
echo "▶ Ad-hoc signing Python binaries (required on macOS 13+)"
find "$RUNTIME_DIR/python" -type f \( -name "*.so" -o -name "*.dylib" \) -print0 2>/dev/null | \
    while IFS= read -r -d '' f; do
        codesign --force --sign - "$f" 2>/dev/null || true
    done
if [ -d "$RUNTIME_DIR/python/python.app" ]; then
    codesign --force --deep --sign - "$RUNTIME_DIR/python/python.app" 2>/dev/null || true
fi

# ── 6. Copy the source tree to the final location (BEFORE installing deps) ─
# We need the source tree in place first so we can read requirements.txt
# when installing dependencies.
echo "▶ Copying source tree to $APP_DIR/Resources/app/"
mkdir -p "$APP_DIR/Resources/app"
rsync -a --delete "$WORK_DIR/app/" "$APP_DIR/Resources/app/" 2>/dev/null || cp -R "$WORK_DIR/app/." "$APP_DIR/Resources/app/"
SOURCE_FILE_COUNT=$(find "$APP_DIR/Resources/app" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "  $SOURCE_FILE_COUNT files copied"

# ── 7. Install dependencies into site-packages/ ───────────────────────────
SITE_PACKAGES_DIR="$RUNTIME_DIR/site-packages"
mkdir -p "$SITE_PACKAGES_DIR"

echo "▶ Upgrading pip in site-packages"
"$PYTHON_BIN" -m pip install --target "$SITE_PACKAGES_DIR" --upgrade --quiet pip wheel setuptools 2>&1 | tail -3 | sed 's/^/  /'

echo "▶ Installing Odysseus requirements"
APP_SOURCE_DIR="$APP_DIR/Resources/app"
if [ -f "$APP_SOURCE_DIR/requirements.txt" ]; then
    "$PYTHON_BIN" -m pip install --target "$SITE_PACKAGES_DIR" --upgrade --quiet -r "$APP_SOURCE_DIR/requirements.txt" 2>&1 | tail -10 | sed 's/^/  /'
else
    echo "  (no requirements.txt found at $APP_SOURCE_DIR/requirements.txt — skipping)"
    echo "  (looking for alternative files...)"
    for alt in pyproject.toml setup.py; do
        if [ -f "$APP_SOURCE_DIR/$alt" ]; then
            echo "  (found $alt — but v1 doesn't auto-install from it. Move deps to requirements.txt)"
        fi
    done
fi

# ── 8. Verify the install works ────────────────────────────────────────────
echo "▶ Verifying install"
PYTHONPATH="$SITE_PACKAGES_DIR" "$PYTHON_BIN" -c "
import fastapi, uvicorn
print(f'  fastapi={fastapi.__version__} uvicorn={uvicorn.__version__}')
" 2>&1 | head -5

echo
echo "✓ Odysseus runtime bundled"
echo "  source:        $APP_DIR/Resources/app/"
echo "  python:        $APP_DIR/Resources/runtime/python/"
echo "  site-packages: $APP_DIR/Resources/runtime/site-packages/"
echo "  size:          $(du -sh "$RUNTIME_DIR" | cut -f1)"
echo
echo "Update apps/odysseus/webappify.yaml so the start_command sets PYTHONPATH:"
echo "  export PYTHONPATH=\"./runtime/site-packages:\$PYTHONPATH\""
echo "  exec ./runtime/python/bin/python3 -m uvicorn app:app --host 127.0.0.1 --port \$PORT"
