#!/bin/bash
# apps/odysseus/build.sh — entry point for building the Odysseus .app.
# Delegates to ci/build-app.sh with the right per-app name.

set -euo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$APP_DIR/../.." && pwd)"

cd "$REPO_ROOT"
exec ./ci/build-app.sh odysseus "$@"
