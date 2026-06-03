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

# ── 7a. Patch the source to respect $DATA_DIR (Cardinal Rule fix) ────────────
# Upstream Odysseus hardcodes its data path to './data/' relative to the
# working directory. The wrapper sets the working directory to
# Contents/Resources/app/, so the data would land inside the .app — a
# Cardinal Rule violation. We patch the source so that when the wrapper
# sets DATA_DIR=~/Library/Application Support/<bundle_id>/, Odysseus
# uses that path instead.
#
# This is a temporary workaround until upstream Odysseus supports DATA_DIR
# natively. The LLM agent should file a PR upstream to remove this patch.
echo "▶ Patching source to respect \$DATA_DIR (Cardinal Rule fix)"

# Important: the patches below are not idempotent on their own. The
# replacement text contains the search pattern (e.g. we replace
# `os.path.join(BASE_DIR, "data")` with
# `os.environ.get("DATA_DIR", os.path.join(BASE_DIR, "data"))` — which
# still contains the search text). Running the patch twice on the same
# file would double-wrap. To avoid that, we work on a fresh copy of the
# upstream source each time. The cloned source is in $WORK_DIR/app, and
# we copy it to $APP_DIR/Resources/app/ at step 8 — but that step is AFTER
# this patch. To make the patches idempotent, we restore the source files
# from $WORK_DIR/app/ before patching.

RESTORE_FROM="$WORK_DIR/app"

# 1. core/constants.py and src/constants.py: replace hardcoded DATA_DIR
for constants_file in \
    "$APP_DIR/Resources/app/core/constants.py" \
    "$APP_DIR/Resources/app/src/constants.py"; do
    rel_path="${constants_file#$APP_DIR/Resources/app/}"
    src_file="$RESTORE_FROM/$rel_path"
    if [ -f "$src_file" ] && [ -f "$constants_file" ]; then
        # Copy the unpatched source from $WORK_DIR into the app bundle so
        # we can patch a clean copy. The full source copy happens at
        # step 8; this is a no-op if it already happened.
        cp "$src_file" "$constants_file"
    fi
    if [ -f "$constants_file" ] && grep -q '^DATA_DIR = os.path.join(BASE_DIR, "data")' "$constants_file"; then
        sed -i.bak 's|^DATA_DIR = os.path.join(BASE_DIR, "data")|DATA_DIR = os.environ.get("DATA_DIR", os.path.join(BASE_DIR, "data"))|' "$constants_file"
        rm -f "$constants_file.bak"
        echo "  patched: ${constants_file#$APP_DIR/Resources/app/}"
    fi
done

# 2. setup.py: same DATA_DIR fix + LOGS_DIR fix
SETUP_FILE="$APP_DIR/Resources/app/setup.py"
SETUP_SRC="$RESTORE_FROM/setup.py"
if [ -f "$SETUP_SRC" ] && [ -f "$SETUP_FILE" ]; then
    cp "$SETUP_SRC" "$SETUP_FILE"
fi
if [ -f "$SETUP_FILE" ]; then
    if grep -q '^DATA_DIR = os.path.join(BASE_DIR, "data")' "$SETUP_FILE"; then
        sed -i.bak 's|^DATA_DIR = os.path.join(BASE_DIR, "data")|DATA_DIR = os.environ.get("DATA_DIR", os.path.join(BASE_DIR, "data"))|' "$SETUP_FILE"
        echo "  patched: setup.py (DATA_DIR)"
    fi
    # LOGS_DIR — use Python's re.sub (which is idempotent) to avoid the
    # sed recursion issue where the replacement contains the search pattern.
    if grep -q 'os.path.join(BASE_DIR, "logs")' "$SETUP_FILE"; then
        python3 -c "
import re
p = '$SETUP_FILE'
with open(p) as f:
    content = f.read()
content = re.sub(
    r'os\.path\.join\(BASE_DIR, \"logs\"\)',
    'os.environ.get(\"LOGS_DIR\", os.path.join(BASE_DIR, \"logs\"))',
    content
)
with open(p, 'w') as f:
    f.write(content)
print('  patched: setup.py (LOGS_DIR)')
"
    fi
    rm -f "$SETUP_FILE.bak"
fi

# 3. routes/embedding_routes.py: _ENDPOINT_FILE
EMBED_FILE="$APP_DIR/Resources/app/routes/embedding_routes.py"
EMBED_SRC="$RESTORE_FROM/routes/embedding_routes.py"
if [ -f "$EMBED_SRC" ] && [ -f "$EMBED_FILE" ]; then
    cp "$EMBED_SRC" "$EMBED_FILE"
fi
if [ -f "$EMBED_FILE" ] && grep -q '_ENDPOINT_FILE = os.path.join(BASE_DIR, "data"' "$EMBED_FILE"; then
    sed -i.bak 's|_ENDPOINT_FILE = os.path.join(BASE_DIR, "data", "embedding_endpoint.json")|_ENDPOINT_FILE = os.path.join(os.environ.get("DATA_DIR", os.path.join(BASE_DIR, "data")), "embedding_endpoint.json")|' "$EMBED_FILE"
    rm -f "$EMBED_FILE.bak"
    echo "  patched: routes/embedding_routes.py (_ENDPOINT_FILE)"
fi

# 4. routes/personal_routes.py: UPLOADS_DIR
PERSONAL_FILE="$APP_DIR/Resources/app/routes/personal_routes.py"
PERSONAL_SRC="$RESTORE_FROM/routes/personal_routes.py"
if [ -f "$PERSONAL_SRC" ] && [ -f "$PERSONAL_FILE" ]; then
    cp "$PERSONAL_SRC" "$PERSONAL_FILE"
fi
if [ -f "$PERSONAL_FILE" ] && grep -q 'UPLOADS_DIR = os.path.join(BASE_DIR, "data"' "$PERSONAL_FILE"; then
    sed -i.bak 's|UPLOADS_DIR = os.path.join(BASE_DIR, "data", "personal_uploads")|UPLOADS_DIR = os.path.join(os.environ.get("DATA_DIR", os.path.join(BASE_DIR, "data")), "personal_uploads")|' "$PERSONAL_FILE"
    rm -f "$PERSONAL_FILE.bak"
    echo "  patched: routes/personal_routes.py (UPLOADS_DIR)"
fi

# 5. core/database.py: DATABASE_URL fallback
DATABASE_FILE="$APP_DIR/Resources/app/core/database.py"
DATABASE_SRC="$RESTORE_FROM/core/database.py"
if [ -f "$DATABASE_SRC" ] && [ -f "$DATABASE_FILE" ]; then
    cp "$DATABASE_SRC" "$DATABASE_FILE"
fi
if [ -f "$DATABASE_FILE" ] && grep -q 'sqlite:///./data/app.db' "$DATABASE_FILE"; then
    # Replace the hardcoded fallback with one that uses $DATA_DIR.
    # The default "sqlite:///./data/app.db" is relative to the working
    # directory; we replace it with an absolute path based on $DATA_DIR.
    sed -i.bak "s|DATABASE_URL = os.getenv(\"DATABASE_URL\", \"sqlite:///./data/app.db\")|DATABASE_URL = os.getenv(\"DATABASE_URL\", \"sqlite:///\" + os.path.join(os.environ.get(\"DATA_DIR\", \"./data\"), \"app.db\"))|" "$DATABASE_FILE"
    rm -f "$DATABASE_FILE.bak"
    echo "  patched: core/database.py (DATABASE_URL)"
fi

# 6. src/secret_storage.py: move encryption key to $DATA_DIR
# The upstream hardcodes `data/.app_key` relative to the source tree.
# That puts the key INSIDE the .app bundle — it gets wiped on every
# Sparkle update. We patch it to use $DATA_DIR/.app_key so the key
# survives updates (Cardinal Rule: secrets live outside the .app).
SECRET_FILE="$APP_DIR/Resources/app/src/secret_storage.py"
SECRET_SRC="$RESTORE_FROM/src/secret_storage.py"
if [ -f "$SECRET_SRC" ] && [ -f "$SECRET_FILE" ]; then
    cp "$SECRET_SRC" "$SECRET_FILE"
fi
if [ -f "$SECRET_FILE" ] && grep -q '_KEY_PATH = Path(__file__).resolve().parent.parent / "data" / ".app_key"' "$SECRET_FILE"; then
    sed -i.bak 's|_KEY_PATH = Path(__file__).resolve().parent.parent / "data" / ".app_key"|_KEY_PATH = Path(os.environ.get("DATA_DIR", str(Path(__file__).resolve().parent.parent / "data"))) / ".app_key"|' "$SECRET_FILE"
    rm -f "$SECRET_FILE.bak"
    echo "  patched: src/secret_storage.py (_KEY_PATH -> \$DATA_DIR/.app_key)"
fi

# 7. Verify: scan for any remaining hardcoded 'BASE_DIR, "data"' usages
# and also verify the secret_storage patch is in place
echo "▶ Verifying no hardcoded data paths remain in patched files"
REMAINING=$(grep -rn 'os.path.join(BASE_DIR, "data"' "$APP_DIR/Resources/app/core/" "$APP_DIR/Resources/app/src/" "$APP_DIR/Resources/app/setup.py" "$APP_DIR/Resources/app/routes/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$REMAINING" -gt 0 ]; then
    echo "  WARNING: $REMAINING hardcoded data paths still present:"
    grep -rn 'os.path.join(BASE_DIR, "data"' "$APP_DIR/Resources/app/core/" "$APP_DIR/Resources/app/src/" "$APP_DIR/Resources/app/setup.py" "$APP_DIR/Resources/app/routes/" 2>/dev/null | sed 's/^/    /'
else
    echo "  ✓ all hardcoded data paths patched"
fi

# Verify secret_storage patch
if grep -q 'os.environ.get("DATA_DIR"' "$APP_DIR/Resources/app/src/secret_storage.py" 2>/dev/null; then
    echo "  ✓ secret_storage key path patched to use \$DATA_DIR"
else
    echo "  WARNING: secret_storage.py may not be patched — key could end up inside .app"
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
