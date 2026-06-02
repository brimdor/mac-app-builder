# mac-app-builder — Tasks

> Living checklist for shipping the v1 of the Mac App Standard + the Odysseus POC.
> Check items off as they're completed.

## Conventions

- `[ ]` pending · `[x]` complete · `[~]` in progress · `[!]` blocked
- Every item should be testable. "It's done" means a test passes or a thing visibly works.
- The Cardinal Rule (no user data in the `.app`) is **non-negotiable**. The Cardinal Rule test (`ci/cardinal-rule-test.sh`) must pass before any commit to `main`.

---

## Phase 0 — Repo bootstrap

- [ ] Confirm repo name: **`mac-app-builder`** (private by default)
- [ ] Create the GitHub repo `mac-app-builder` with visibility: **private** (per user requirement)
- [ ] Initialize the local repo at `~/Code/mac-app-builder/`
- [ ] Set up `.gitignore` (no macOS noise, no build artifacts, no `.env`)
- [ ] Add `LICENSE` (MIT) and `README.md` (top-level)
- [ ] Set up branch protection on `main` (require PR, require CI pass, no direct pushes)
- [ ] Decide on a hosting strategy for `.dmg` + Sparkle appcast (private repo, so GitHub Releases on a *separate* public mirror, or S3 with signed URLs, or a private CDN)

## Phase 1 — Documentation: the standard + the agent prompt

- [ ] `STANDARD.md` — polished version of DESIGN.md §7
  - [ ] Bundle structure
  - [ ] Info.plist required keys
  - [ ] `webappify.yaml` schema (v1)
  - [ ] Native UI requirements (menu bar, About, etc.)
  - [ ] Update flow (Sparkle)
  - [ ] Data location convention (`~/Library/...`)
  - [ ] Bundle ID convention
  - [ ] Naming convention
  - [ ] "What this standard does NOT cover" (clarifies scope)
- [ ] `agent-prompt.md` — the LLM agent spec
  - [ ] Inputs the agent receives
  - [ ] Workflow (read standard → fetch upstream → detect changes → update per-app → run tests → commit)
  - [ ] What the agent may NOT do (modify STANDARD, modify reference wrapper, etc.)
  - [ ] Example walkthrough for Odysseus
- [ ] `docs/adding-a-new-webapp.md` — guide for adding a new per-app dir (LLM or human)
- [ ] `docs/lifting-and-shifting.md` — end-user-facing "move .app to another Mac" guide

## Phase 2 — Reference Swift wrapper

- [ ] `wrapper/Sources/main.swift` — NSApplication entry point
- [ ] `wrapper/Sources/AppDelegate.swift` — window, menu bar, app lifecycle (refactored to be app-agnostic)
- [ ] `wrapper/Sources/Config.swift` — `webappify.yaml` loader (uses Yams or hand-rolled parser)
- [ ] `wrapper/Sources/ServerManager.swift` — spawn bundled server, poll readiness, terminate on quit
- [ ] `wrapper/Sources/UpdateManager.swift` — Sparkle integration (or stub if Sparkle isn't available yet)
- [ ] `wrapper/Sources/FirstRunWizard.swift` — optional first-run UI
- [ ] `wrapper/Sources/MenuBar.swift` — standard menu bar setup
- [ ] `wrapper/Sources/AboutPanel.swift` — standard About dialog
- [ ] `wrapper/Sources/RevealInFinder.swift` — utility to reveal paths in Finder
- [ ] `wrapper/Resources/Info.plist.tmpl` — Info.plist template
- [ ] `wrapper/Resources/webappify.yaml.tmpl` — yaml template
- [ ] `wrapper/build.sh` — compiles the wrapper into a `.app` skeleton (takes app name + port + start command)
- [ ] `wrapper/README.md` — what's in the wrapper, how to customize

## Phase 3 — Odysseus per-app dir

- [ ] `apps/odysseus/DESIGN.md` — LLM-written design doc for Odysseus
  - [ ] Overview of Odysseus
  - [ ] Source layout (the upstream repo's structure)
  - [ ] Server lifecycle (uvicorn, port 7860)
  - [ ] First-run flow (admin account creation)
  - [ ] Custom UI (any custom menu items / About content)
  - [ ] Update feed (Sparkle appcast URL — for v1: GitHub Releases of mac-app-builder itself)
  - [ ] Known quirks (MCP servers, ChromaDB, etc.)
- [ ] `apps/odysseus/webappify.yaml` — runtime config
  - [ ] name, display_name, bundle_id, version
  - [ ] runtime: python
  - [ ] port: 7860
  - [ ] start_command: uvicorn invocation
  - [ ] env vars: DATA_DIR, LOGS_DIR
  - [ ] first_run: admin account wizard
- [ ] `apps/odysseus/Info.plist` — bundle metadata
- [ ] `apps/odysseus/icon.icns` — app icon (from `docs/odysseus.jpg` in upstream, or design a new one)
- [ ] `apps/odysseus/icon.png` — source icon for the icns
- [ ] `apps/odysseus/wrapper/` — customized Swift sources (copy of `wrapper/`, modified)
  - [ ] Custom About panel content
  - [ ] First-run admin account creation
  - [ ] Custom menu items if needed (e.g. "Open MCP Servers Folder")
- [ ] `apps/odysseus/build-runtime.sh` — Python runtime bundling
  - [ ] Download `python-build-standalone` for arm64-macos
  - [ ] Extract into `Contents/Resources/runtime/python/`
  - [ ] Create a venv with `--copies`
  - [ ] `pip install -r requirements.txt` from upstream
- [ ] `apps/odysseus/build.sh` — build entry point (delegates to `ci/build-app.sh`)
- [ ] `apps/odysseus/README.md` — human-readable docs for this app
- [ ] `apps/odysseus/tests/` — app-specific tests
  - [ ] Launch the .app
  - [ ] Verify the server starts
  - [ ] Verify the UI loads
  - [ ] Verify user data writes go to `~/Library/Application Support/`

## Phase 4 — CI scripts

- [ ] `ci/build-app.sh <app-name>` — compiles a per-app `.app`
  - [ ] Validates the per-app dir structure
  - [ ] Calls the per-app's `build-runtime.sh` if present
  - [ ] Compiles Swift wrapper with the app's config baked in
  - [ ] Stages the `.app` (Info.plist, webappify.yaml, icon, runtime)
  - [ ] Ad-hoc code sign
- [ ] `ci/package-dmg.sh <app-name>` — creates a `.dmg` from the `.app`
- [ ] `ci/sign-app.sh <dmg>` — signs the `.dmg`
- [ ] `ci/publish-release.sh <app-name> <version>` — uploads to GitHub Releases + updates appcast
  - [ ] For v1: uploads to workflow artifacts only
  - [ ] For v1.1: GitHub Releases + appcast generation
- [ ] `ci/cardinal-rule-test.sh <app>` — the Cardinal Rule test
  - [ ] Install `.app` to a temp location
  - [ ] Launch it
  - [ ] Perform a known write via the wrapper's normal code path
  - [ ] Verify the write landed in `~/Library/...`, NOT inside the `.app`
  - [ ] Move the `.app` to a new path and re-verify
- [ ] `ci/lift-and-shift-test.sh <app>` — the lift-and-shift test
  - [ ] Copy `.app` to a different directory
  - [ ] Launch from the new location
  - [ ] Verify it works
  - [ ] For v1: can be done by moving to `~/Applications-test/`
  - [ ] For v1.1: ideally done on a clean VM

## Phase 5 — GitHub Actions

- [ ] `.github/workflows/build.yml` — runs on push to `main` and on PRs
  - [ ] Runs on `macos-14` runner
  - [ ] Matrix: per app (`odysseus` for v1, expandable)
  - [ ] Checks out the repo
  - [ ] Runs `ci/build-app.sh`
  - [ ] Runs Cardinal Rule test
  - [ ] Runs lift-and-shift test
  - [ ] Packages `.dmg`
  - [ ] Uploads `.dmg` as a workflow artifact
  - [ ] For v1.1: publishes to GitHub Releases on `main` push
- [ ] `.github/workflows/agent.yml` — runs the LLM agent (v1.1, manual trigger)
  - [ ] For v1: documented but not implemented
  - [ ] For v1.1: triggered by `workflow_dispatch` and by webhooks from upstream webapp repos

## Phase 6 — End-to-end validation

- [ ] Run `ci/build-app.sh odysseus` locally
- [ ] Verify `dist/Odysseus.app` exists and is a real Mach-O arm64 binary
- [ ] Run the Cardinal Rule test — must pass
- [ ] Run the lift-and-shift test — must pass
- [ ] Install to `/Applications/Odysseus.app`
- [ ] Launch the app, verify the UI loads
- [ ] Quit the app, verify the server process is terminated
- [ ] Verify `~/Library/Application Support/com.example.odysseus/` contains the user data
- [ ] Verify `~/Library/Logs/com.example.odysseus/` contains the logs
- [ ] Verify NO user data lives inside `/Applications/Odysseus.app/`
- [ ] Copy `/Applications/Odysseus.app` to `~/Desktop/test-shifted/`
- [ ] Launch from `~/Desktop/test-shifted/Odysseus.app`
- [ ] Verify it still works (fresh install, no user data — this is the correct behavior)
- [ ] Delete the test copy
- [ ] Update the app via Sparkle (or simulate via manual .dmg replacement) — verify user data is preserved

## Phase 7 — Repo hygiene

- [ ] Initial commit: project skeleton
- [ ] Tag `v0.1.0` — the first working POC
- [ ] Push to GitHub
- [ ] Verify branch protection is enabled
- [ ] Open a test PR and verify CI runs
- [ ] Verify the Cardinal Rule test runs in CI
- [ ] Verify the lift-and-shift test runs in CI
- [ ] Add a `CODEOWNERS` file so PRs require review from a specific team/user
- [ ] Add issue templates (bug report, new-webapp request)
- [ ] Add PR template
- [ ] Set up Dependabot (or similar) for keeping actions up to date

## Phase 8 — Polish

- [ ] README has a "Quick start" section that shows the full Odysseus flow in <60 seconds
- [ ] README has a "What this is" section that explains the LLM-driven per-app design
- [ ] README has a "Roadmap" section
- [ ] At least one screenshot of the running Odysseus `.app`
- [ ] At least one animated GIF showing the update flow (or a placeholder)
- [ ] All shell scripts pass `shellcheck` (CI gate)
- [ ] All shell scripts have `set -euo pipefail` at the top
- [ ] All paths in scripts are quoted properly
- [ ] README has a "Contributing" section explaining the LLM agent flow
- [ ] Add a CHANGELOG.md

## Phase 9 — Future (NOT v1, just noting)

- [ ] Linux support (separate per-platform standard)
- [ ] More webapps (one per repo subdir)
- [ ] Auto-publish to GitHub Releases + Sparkle appcast
- [ ] App Store / Developer ID signing
- [ ] CI-triggered LLM agent
- [ ] First-run wizards with OAuth
- [ ] Crash reporting (opt-in)
- [ ] Telemetry (opt-in)
- [ ] Multi-app orchestration
- [ ] `webappify uninstall <app>` command (CLI tool for users)

---

## Definition of Done for v1

The v1 is "done" when:

1. The `mac-app-builder` repo exists on GitHub, is **private**, with branch protection on `main`.
2. `STANDARD.md`, `agent-prompt.md`, and `README.md` are polished and clear.
3. The `wrapper/` reference Swift implementation is functional and app-agnostic.
4. `apps/odysseus/` builds a working `.app` that conforms to the standard.
5. The Cardinal Rule test passes (verifies user data is in `~/Library/`, not in the `.app`).
6. The lift-and-shift test passes (verifies the `.app` works when moved).
7. CI runs on every PR and every push to `main`, and the Cardinal Rule + lift-and-shift tests are gating.
8. The `Odysseus.app` produced by CI can be installed on a real Mac (or VM), launched, and used to actually run Odysseus.
9. The whole pipeline — `git push` → CI → `.dmg` artifact — works end to end.

When all of the above are checked, v1 ships. We tag `v0.1.0` and start the loop: run the LLM agent against new upstream Odysseus releases, review PRs, ship updates via Sparkle.

---

## v0.1.0 status (committed)

**As of 2026-06-02, v0.1.0 has been built and committed.** The pipeline works end-to-end:

- ✅ `ci/build-app.sh odysseus` produces a working 510MB `dist/Odysseus.app`
- ✅ The `.app` launches, the server starts, the login page loads
- ✅ Build, package, sign scripts all work
- ✅ CI workflow is configured (will run on macos-14 runners)
- ✅ Cardinal Rule test exists and runs (currently fails for Odysseus — see known issue)
- ✅ Lift-and-shift test exists and runs

**Known issue blocking v0.1.0 distribution:**
- ❌ Odysseus hardcodes its data path → user data lands inside the .app → Cardinal Rule violation
- Fix: upstream PR to support `DATA_DIR` env var

**v0.2.0 priorities:**
- File upstream PR for Odysseus data path fix
- Add Sparkle integration for in-app updates
- Add first-run wizard UI (use the `first_run` field in `webappify.yaml`)
- Add Odysseus app icon
- Get the Cardinal Rule test to actually pass for Odysseus
