# Changelog

All notable changes to this project are documented here. Dates are in YYYY-MM-DD. The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).

## [0.1.0] — 2026-06-02

### Added
- Initial project skeleton: `STANDARD.md`, `agent-prompt.md`, `README.md`, `LICENSE` (MIT)
- Reference Swift + WKWebView wrapper (`wrapper/`) with hand-rolled YAML parser for `webappify.yaml`
- Per-app directory for Odysseus (`apps/odysseus/`) with `DESIGN.md`, `webappify.yaml`, customized wrapper, Python runtime bundler
- CI build pipeline: `ci/build-app.sh`, `ci/package-dmg.sh`, `ci/sign-app.sh`, `ci/publish-release.sh`
- Cardinal Rule test (`ci/cardinal-rule-test.sh`) — verifies user data lives in `~/Library/`, not in the `.app`
- Lift-and-shift test (`ci/lift-and-shift-test.sh`) — verifies the `.app` works when moved
- GitHub Actions workflow (`.github/workflows/build.yml`) running on `macos-14`
- Documentation: `docs/adding-a-new-webapp.md`, `docs/lifting-and-shifting.md`
- Issue and PR templates, CODEOWNERS file
- `tasks.md` — living checklist of v1 progress

### Verified
- ✅ `ci/build-app.sh odysseus` produces a working 510MB `dist/Odysseus.app`
- ✅ The `.app` launches and the Odysseus login page loads (HTTP 200 on /login)
- ✅ The wrapper correctly:
  - Loads `webappify.yaml` from the bundle
  - Resolves the Python interpreter path inside `Contents/Resources/runtime/`
  - Sets `PYTHONPATH` to the bundled `site-packages/`
  - Runs `setup.py` on first launch to initialize the data
  - Spawns uvicorn and loads the URL in WKWebView
- ✅ Ad-hoc code signing works
- ✅ The `dist/Odysseus-0.1.0.dmg` can be built and inspected

### Known issues (v0.1.0)
- ❌ **Cardinal Rule test fails for Odysseus.** Upstream Odysseus hardcodes its data path to `./data/` relative to the working directory. The wrapper sets the working dir to `Contents/Resources/app/`, so the SQLite database lands inside the .app at `Contents/Resources/app/data/`. This violates the Cardinal Rule. **Fix:** file a PR upstream to support `DATA_DIR` env var (or XDG_DATA_HOME). The v0.1.0 build is functional but should not be distributed to end users until this is resolved.
- ⚠️ **No Sparkle integration.** v0.1.0 has a placeholder for "Check for Updates…". v0.2.0 adds Sparkle.
- ⚠️ **No first-run wizard UI.** The wrapper runs `setup.py` automatically, but doesn't show a custom wizard. v0.2.0 implements the `first_run` field in `webappify.yaml`.
- ⚠️ **Per-app customization is opt-in.** The build pipeline uses per-app customized wrapper sources if `apps/<name>/wrapper/Sources/` exists, otherwise the reference. v0.1.0 ships the Odysseus per-app with customizations.
- ⚠️ **No icon for Odysseus.** The `.app` uses the system default icon. v0.2.0 adds an `icon.png` to `apps/odysseus/`.

### Migration from prior setup
- The old `~/Documents/Github/odysseus/` installation (from earlier in this development session) is no longer needed. The new `Odysseus.app` is self-contained.
- To use the new build, install `dist/Odysseus.app` to `/Applications/`.
