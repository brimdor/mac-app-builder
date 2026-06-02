# mac-app-builder

> A standard + per-app Swift wrappers for turning GitHub webapps into self-contained macOS `.app`s.

**The Cardinal Rule:** The `.app` bundle contains no unique user data. All user data lives in `~/Library/Application Support/<bundle_id>/`. This makes the `.app` lift-and-shift: copy it to another Mac, drop it in `/Applications`, double-click, fresh install. No installer, no dev tools, no Terminal on the destination.

## Quick start (Odysseus POC)

The `apps/odysseus/` per-app directory builds a working `.app` for [Odysseus](https://github.com/pewdiepie-archdaemon/odysseus):

```bash
# One-time: install the build dependencies
brew install python@3.11
xcode-select --install   # for swiftc + codesign

# Build the .app
./ci/build-app.sh odysseus

# Result
ls -la dist/Odysseus.app/
open dist/Odysseus.app
```

CI does the same on every push to `main` (`.github/workflows/build.yml`).

## How this works

```
┌──────────────────┐         ┌──────────────────────┐
│  STANDARD.md     │ ←────── │  wrapper/             │   Reference Swift + WKWebView impl
│  (the rules)     │         │  (the canonical code) │
└──────────────────┘         └──────────────────────┘
         │                              │
         │  conformance to              │  copied & customized by
         │                              ▼
         │              ┌──────────────────────────────────┐
         │              │  apps/odysseus/wrapper/          │
         │              │  (per-app customized Swift)      │
         │              │                                  │
         │              │  apps/odysseus/webappify.yaml    │
         │              │  apps/odysseus/DESIGN.md         │
         │              │  apps/odysseus/build-runtime.sh  │
         │              └──────────────────────────────────┘
         │                              │
         ▼                              ▼
┌──────────────────────────────────────────────────────────┐
│  ci/build-app.sh  →  ci/cardinal-rule-test.sh  →  dist/   │
└──────────────────────────────────────────────────────────┘
```

The **LLM agent** (`agent-prompt.md`) is what keeps the per-app dir in sync with the upstream webapp. When Odysseus releases a new version, the agent reads the upstream changelog, updates `apps/odysseus/`, and opens a PR. Human review (enforced by branch protection) is required before merge.

## Repository layout

```
mac-app-builder/
├── README.md                  ← you are here
├── STANDARD.md                ← the Mac App Standard
├── agent-prompt.md            ← the LLM agent spec
├── tasks.md                   ← living checklist
├── wrapper/                   ← the reference Swift + WKWebView implementation
├── apps/
│   └── odysseus/              ← one per-app dir per webapp
├── ci/                        ← build, test, sign, package scripts
├── tests/                     ← Cardinal Rule test + lift-and-shift test
├── docs/                      ← guides for app authors and end users
└── .github/workflows/         ← CI
```

See **[`STANDARD.md`](STANDARD.md)** for the full rules every per-app `.app` must follow.

See **[`agent-prompt.md`](agent-prompt.md)** for how the LLM agent works.

## What's in v1

- ✅ The Standard (`STANDARD.md`)
- ✅ The reference Swift wrapper (`wrapper/`)
- ✅ One working per-app: Odysseus (`apps/odysseus/`)
- ✅ Cardinal Rule test (`ci/cardinal-rule-test.sh`)
- ✅ Lift-and-shift test (`ci/lift-and-shift-test.sh`)
- ✅ CI build pipeline (`.github/workflows/build.yml`)
- ✅ The LLM agent spec (`agent-prompt.md`) — manual trigger for v1, CI-triggered in v1.1

## What's NOT in v1

- Generic, config-driven packager (we deliberately do NOT do this — see `STANDARD.md` §"Why a standard, not a packager")
- Node.js / Go / Rust / Ruby runtimes (v1 is Python only; add per-runtimes as needed)
- App Store / Developer ID signing (v1 uses ad-hoc signing)
- GUI "drag a GitHub URL" installer (the LLM agent runs in CI, not as a user-facing tool)
- Linux support (planned for a future per-platform standard; see `tasks.md` Phase 9)
- Auto-publish to GitHub Releases / Sparkle (v1 produces artifacts; v1.1 publishes)

## The Cardinal Rule, in full

> **The `.app` bundle contains no unique user data.**
>
> The `.app` is a shippable, versioned, replaceable artifact. It contains the application code, the language runtime, the bundled source snapshot, the icon, the wrapper binary, and the update framework. It does NOT contain the user's database, settings, uploaded files, conversation history, or any other state the user has created by using the app.
>
> All user-generated data lives in the user's home directory, in standard macOS locations, namespaced by the app's Bundle ID.

The Cardinal Rule test (`ci/cardinal-rule-test.sh`) asserts this on every CI build. It MUST pass before any merge to `main`.

## License

MIT — see [LICENSE](LICENSE).
