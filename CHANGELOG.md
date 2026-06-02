# Changelog

All notable changes to this project are documented here. Dates are in YYYY-MM-DD. The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).

## [0.2.1] — 2026-06-02

### Fixed
- **Blank window on launch (macOS 26).** The wrapper was using `.fullSizeContentView` and `isMovableByWindowBackground = true` on the main window, which on macOS 26 caused the WKWebView to render a black interior even though the URL loaded successfully (curl `/login` → 200 OK, `webView(_:didFinish:)` fired). The window setup is now standard (titled/closable/miniaturizable/resizable, no fullSizeContentView), and the WKWebView is sized to the window's contentRect with `autoresizingMask = [.width, .height]`.
- **Removed `setValue(false, forKey: "drawsBackground")` hack.** This private KVC could cause the webView to render a black background on macOS 26 even when the document loaded successfully. The webview now uses its default opaque background; webapps that want transparency can opt in via CSS.
- **Added `WKNavigationDelegate` diagnostics** (`didStartProvisionalNavigation`, `didFinish`, `didFail`, `didFailProvisionalNavigation`) to `AppDelegate`. These log to stderr and `~/Library/Logs/<bundleId>/wrapper.log` and are essential for diagnosing future blank-window issues.

### Verified
- ✅ App launches from `/Applications/Odysseus.app`
- ✅ Window appears with correct title and size
- ✅ WKWebView loads `http://127.0.0.1:7860/` and follows the redirect to `/login`
- ✅ `webView(_:didFinish:)` fires with `webView.url == http://127.0.0.1:7860/login`
- ✅ HTTP `/login` returns 200 OK

## [0.2.0] — 2026-06-02

### Added
- **First-run wizard** (`FirstRunWindowController.swift`): a native macOS window with username/password/confirm fields that appears on first launch. Calls `setup.py` with `ODYSSEUS_ADMIN_USER`/`ODYSSEUS_ADMIN_PASSWORD` env vars and dismisses on success. Skip the wizard by pre-seeding `auth.json`.
- **ServerManager safety net**: if `app.db` is missing on launch, `setup.py` runs automatically. Defensive in case the wizard is bypassed (e.g., by deleting only the database file).
- **Wrapper sets `DATABASE_URL` explicitly** to `sqlite:///<dataDir>/app.db`, so the webapp's hardcoded `sqlite:///./data/app.db` fallback is overridden. Some webapps (like Odysseus) compute their database URL from a hardcoded relative path; the wrapper's env var is the contract.
- **Cardinal Rule patch in `build-runtime.sh`**: now also patches `core/database.py` to compute the SQLite URL from `$DATA_DIR` if no `DATABASE_URL` is set. The fallback path `sqlite:///./data/app.db` is rewritten to `sqlite:///" + os.path.join($DATA_DIR, "app.db")`. Idempotent (re-runs cleanly from a fresh clone).
- **Patch verification step**: after patching, the build script greps for any remaining `os.path.join(BASE_DIR, "data"` patterns and warns if any are found.

### Fixed
- **Cardinal Rule violation**: the v0.1.0 build was writing the SQLite database to `Contents/Resources/app/data/app.db` because Odysseus's `core/database.py` hardcodes `sqlite:///./data/app.db` (relative to the working directory). The wrapper now sets `DATABASE_URL` explicitly, and the build-time patch rewrites the fallback to use `$DATA_DIR`. User data now lives at `~/Library/Application Support/com.pewdiepie-archdaemon.odysseus/`, never inside the `.app`.
- **Lift-and-shift test was failing**: the pre-existing failure was caused by the same database path issue (server couldn't open the database file, so the port never started listening). Both tests now pass with the v0.2.0 fixes.

### Verified
- ✅ `ci/test-all.sh odysseus` end-to-end: build → cardinal rule → lift-and-shift → DMG
- ✅ Cardinal Rule test passes: data is in `~/Library/Application Support/`, never in the `.app`
- ✅ Lift-and-shift test passes: the `.app` works from any location, and user data is preserved across moves
- ✅ Server starts within 7s of launch (with pre-seeded `auth.json`)
- ✅ First-run wizard collects admin credentials and runs `setup.py` correctly

### Migration from v0.1.0
- Delete the v0.1.0 `.app` from `/Applications/`.
- Install `dist/Odysseus-0.2.0.dmg` (drag to `/Applications/`).
- On first launch, the wizard will ask for admin credentials. If you have an existing `~/Library/Application Support/com.pewdiepie-archdaemon.odysseus/auth.json`, the wizard is skipped and the existing admin login is used.

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
