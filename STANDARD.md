# Mac App Standard

> The rules every per-app `.app` in this repo must follow. If you (or the LLM agent) are designing a new per-app `.app`, follow this document.

## Table of contents

1. [The Cardinal Rule](#1-the-cardinal-rule)
2. [Bundle structure](#2-bundle-structure)
3. [Info.plist](#3-infoplist)
4. [webappify.yaml](#4-webappifyyaml)
5. [Native UI](#5-native-ui)
6. [Data location convention](#6-data-location-convention)
7. [Bundle ID convention](#7-bundle-id-convention)
8. [Naming convention](#8-naming-convention)
9. [Update flow](#9-update-flow)
10. [Code signing](#10-code-signing)
11. [What this standard does NOT cover](#11-what-this-standard-does-not-cover)
12. [Why a standard, not a packager](#12-why-a-standard-not-a-packager)

---

## 1. The Cardinal Rule

> **The `.app` bundle contains no unique user data.**

The `.app` is a shippable, versioned, replaceable artifact. It contains:

- ✅ The webapp's source code (a snapshot at build time)
- ✅ A language runtime (Python, etc.) and its installed dependencies
- ✅ The Swift wrapper binary
- ✅ The app icon, Info.plist, and bundled resources
- ✅ The Sparkle update framework

It does **not** contain:

- ❌ The user's database
- ❌ The user's settings
- ❌ The user's uploads, documents, or memory
- ❌ Logs
- ❌ Caches
- ❌ Anything that differs between two users running the same `.app` version

All user-generated data lives in the user's home directory, namespaced by the app's Bundle ID:

| Data | Location |
|---|---|
| User database, settings, uploads | `~/Library/Application Support/<bundle_id>/` |
| Logs | `~/Library/Logs/<bundle_id>/` |
| Caches | `~/Library/Caches/<bundle_id>/` |
| UserDefaults | `~/Library/Preferences/<bundle_id>.plist` |

This rule is non-negotiable. The Cardinal Rule test (`ci/cardinal-rule-test.sh`) asserts it on every CI build and must pass before any merge to `main`.

**Why this matters:** without this rule, "lift-and-shift" doesn't work. A `.app` that contains user data is not a product; it's a per-user installation that can't be moved, distributed, or versioned cleanly.

---

## 2. Bundle structure

Every `.app` must follow this on-disk layout:

```
MyApp.app/
└── Contents/
    ├── Info.plist                                  ← bundle metadata
    ├── PkgInfo                                     ← "APPL????" for legacy reasons
    ├── _CodeSignature/                             ← codesign output
    ├── MacOS/
    │   └── MyApp                                   ← Swift wrapper binary
    ├── Resources/
    │   ├── webappify.yaml                          ← runtime config
    │   ├── icon.icns                               ← app icon (multiple sizes)
    │   ├── app/                                    ← webapp source snapshot
    │   │   └── ...                                 ← (full webapp source tree, copied at build time)
    │   ├── runtime/                                ← language runtime
    │   │   └── python/                             ← (or node/, go/, etc.)
    │   │       ├── bin/python3                     ← relocatable interpreter
    │   │       └── site-packages/                  ← installed Python deps
│   │   └── ...                                      ← (or node_modules/ for Node)
    │   └── frameworks/                             ← any system frameworks
    │       └── Sparkle.framework/
    └── ...
```

**`Contents/Resources/app/` is read-only at runtime.** The wrapper spawns the server with the working directory set to `Contents/Resources/app/`. The server reads from here, but does not write here. Any writes go to `DATA_DIR` (passed as an env var).

**`Contents/Resources/runtime/` is also read-only at runtime.** The interpreter lives here. For Python, dependencies are installed to a sibling `site-packages/` directory (not a venv, due to a known issue with python-build-standalone + venv on macOS — see `apps/odysseus/build-runtime.sh` for the full explanation). The wrapper sets `PYTHONPATH=runtime/site-packages` so the spawned server can find its deps.

---

## 3. Info.plist

Required keys:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>MyApp</string>
    <key>CFBundleDisplayName</key>      <string>My App</string>
    <key>CFBundleIdentifier</key>       <string>com.example.myapp</string>
    <key>CFBundleVersion</key>          <string>1.2.3</string>
    <key>CFBundleShortVersionString</key> <string>1.2.3</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleExecutable</key>       <string>MyApp</string>
    <key>CFBundleIconFile</key>         <string>icon</string>
    <key>LSMinimumSystemVersion</key>   <string>11.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSPrincipalClass</key>         <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>   <true/>
        <key>NSExceptionDomains</key>
        <dict>
            <key>127.0.0.1</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>   <true/>
                <key>NSIncludesSubdomains</key>                 <true/>
            </dict>
        </dict>
    </dict>

    <!-- Sparkle (required if using Sparkle for updates) -->
    <key>SUFeedURL</key>                <string>https://example.com/appcast.xml</string>
    <key>SUPublicEDKey</key>            <string>...base64-encoded-ed25519-public-key...</string>
</dict>
</plist>
```

`SUFeedURL` and `SUPublicEDKey` are Sparkle's keys. If a per-app uses a different updater, those keys can be omitted but the wrapper must still provide an in-app update flow.

The `NSAppTransportSecurity` exception for `127.0.0.1` is required because the WKWebView loads the webapp's local server over HTTP, not HTTPS. (TLS to localhost is overkill and complicates cert management.)

---

## 4. webappify.yaml

This file lives at `Contents/Resources/webappify.yaml`. The wrapper reads it at runtime to know how to start the server and what URL to load.

### 4.1 Schema (v1)

```yaml
# webappify.yaml — runtime configuration for a webapp-wrapper .app
# Read by the wrapper at startup. Not used by the build pipeline.

# ── Identity ──────────────────────────────────────────────────────────────
name: MyApp                                        # CFBundleName, executable name
display_name: My App                               # CFBundleDisplayName, window title
bundle_id: com.example.myapp                       # CFBundleIdentifier
version: 1.2.3                                     # CFBundleVersion + CFBundleShortVersionString

# ── Runtime ──────────────────────────────────────────────────────────────
# v1 supports: python
# v1.x will add: node, static, go, rust, ruby
runtime: python

# ── Server lifecycle ─────────────────────────────────────────────────────
# The wrapper spawns this command, with these env vars set:
#   $PORT       — from `port` below
#   $DATA_DIR   — ~/Library/Application Support/<bundle_id>/
#   $LOGS_DIR   — ~/Library/Logs/<bundle_id>/
#   $CACHE_DIR  — ~/Library/Caches/<bundle_id>/
#   $APP_DIR    — Contents/Resources/app/ (the bundled source)
# The working directory is set to $APP_DIR.
start_command: ["./runtime/python/bin/python3", "-m", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", "$PORT"]
port: 7860
url: /                                             # path under http://127.0.0.1:port

# Optional: health check beyond polling the port
# health_check:
#   url: /api/ready                                 # additional URL to poll
#   expected_status: 200
#   timeout_seconds: 30

# Optional: extra env vars passed to the server
# env:
#   ODYSSEUS_DEBUG: "0"
#   LOG_LEVEL: "info"

# Optional: first-run wizard (shows on first launch only)
# first_run:
#   - id: admin_account
#     title: "Create your admin account"
#     description: "Pick a username and password for the admin account."
#     type: credentials                           # text | password | credentials
#     required: true

# Optional: override the update feed (else use Info.plist's SUFeedURL)
# update_feed: https://github.com/owner/repo/releases.atom
```

### 4.2 Validation

The CI pipeline validates every `webappify.yaml` against this schema. A per-app whose `webappify.yaml` doesn't validate cannot ship.

### 4.3 If the per-app is for a webapp that doesn't ship a `webappify.yaml`

Each per-app dir's `webappify.yaml` lives in the per-app dir, NOT in the upstream webapp's repo. The LLM agent (or human) writes it based on understanding the upstream webapp.

---

## 5. Native UI

The wrapper must implement:

| Feature | Required | Implementation hint |
|---|---|---|
| `NSWindow` with `WKWebView` | ✅ | Reference: `wrapper/Sources/AppDelegate.swift` |
| Native menu bar | ✅ | File / Edit / View / Window / Help |
| `File → Reload` (Cmd+R) | ✅ | `webView.reload()` |
| `File → Open in Browser` | ✅ | `NSWorkspace.shared.open(URL)` |
| `Help → Check for Updates…` | ✅ | Sparkle: `SPUUpdater.shared().checkForUpdates()` |
| `Help → Open Logs Folder` | ✅ | `NSWorkspace.shared.activateFileViewerSelecting([URL])` |
| `Help → Open Data Folder` | ✅ | Same, pointing at `DATA_DIR` |
| `Help → Open Install Folder` | ✅ | Same, pointing at `Contents/Resources/app/` |
| `Help → About MyApp` | ✅ | `NSAlert` with version, copyright, links |
| `MyApp → Quit MyApp` (Cmd+Q) | ✅ | `NSApp.terminate(_:)` |
| Dock icon | ✅ | Set via `CFBundleIconFile` in Info.plist |
| Server process management | ✅ | Wrapper spawns the server on launch, terminates it on quit |
| Window state restoration | ✅ | `NSWindow.setFrameAutosaveName` |
| Server log streaming to file | ✅ | Server's stdout/stderr → `LOGS_DIR/server.log` |
| First-run wizard | optional | If `webappify.yaml` has `first_run` items |
| App-level menu items | optional | Per-app can add custom menu items |

---

## 6. Data location convention

| Type | Standard location | macOS API to compute |
|---|---|---|
| User data | `~/Library/Application Support/<bundle_id>/` | `FileManager.url(for: .applicationSupportDirectory)` |
| Logs | `~/Library/Logs/<bundle_id>/` | `FileManager.url(for: .libraryDirectory).appending("/Logs")` |
| Caches | `~/Library/Caches/<bundle_id>/` | `FileManager.url(for: .cachesDirectory)` |
| Preferences | `~/Library/Preferences/<bundle_id>.plist` | `UserDefaults.standard` (auto-namespaced by bundle id) |

**Swift code (from the reference wrapper):**

```swift
let bundleId = Bundle.main.bundleIdentifier ?? "com.example.unknown"

let dataDir = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask
).first!.appendingPathComponent(bundleId, isDirectory: true)

let logsDir = FileManager.default.urls(
    for: .libraryDirectory, in: .userDomainMask
).first!
    .appendingPathComponent("Logs", isDirectory: true)
    .appendingPathComponent(bundleId, isDirectory: true)

let cacheDir = FileManager.default.urls(
    for: .cachesDirectory, in: .userDomainMask
).first!.appendingPathComponent(bundleId, isDirectory: true)

// Create on first launch
try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
```

**The wrapper passes these paths to the spawned server as environment variables:**

- `DATA_DIR` → `dataDir.path`
- `LOGS_DIR` → `logsDir.path`
- `CACHE_DIR` → `cacheDir.path`
- `APP_DIR` → `Bundle.main.resourcePath! + "/app"` (the bundled source)

The webapp's own code (or its `start_command` in `webappify.yaml`) reads from these env vars and writes user data to them. The webapp MUST NOT write to any path inside `Contents/Resources/`.

---

## 7. Bundle ID convention

`<reverse-dns>.<appname-lowercase>`. Examples:

- `com.pewdiepie-archdaemon.odysseus`
- `com.broville.foo`
- `com.zuriel-labs.bar`

The LLM agent derives a sensible bundle ID from the webapp's GitHub repo: `com.<github-org-or-owner>.<repo-name>`. For a personal GitHub repo, that's `com.<username>.<repo>`. For an org, that's `com.<org>.<repo>`.

The bundle ID must be unique on the user's system. Two per-apps with the same bundle ID would conflict.

---

## 8. Naming convention

| Field | Convention | Example |
|---|---|---|
| `CFBundleName` | Short, no spaces, matches executable | `Odysseus` |
| `CFBundleDisplayName` | Human-readable, may have spaces | `Odysseus` |
| `CFBundleExecutable` | Matches `CFBundleName` | `Odysseus` |
| App folder name on disk | Matches `CFBundleName` + `.app` | `Odysseus.app` |
| `webappify.yaml` `name` | Matches `CFBundleName` | `Odysseus` |
| `webappify.yaml` `display_name` | Matches `CFBundleDisplayName` | `Odysseus` |

`CFBundleName` and `CFBundleDisplayName` are often the same; they can differ when the app has a short internal name and a longer public-facing name (e.g. `Foo` vs `Foo Docs`).

---

## 9. Update flow

v1.1 uses [Sparkle 2.x](https://sparkle-project.org/) for in-app updates. Every `.app` MUST:

- Include `Sparkle.framework` in `Contents/Frameworks/`
- Set `SUFeedURL` and `SUPublicEDKey` in `Info.plist`
- Implement `Help → Check for Updates…` calling `SPUUpdater.checkForUpdates()`
- Use EdDSA (Ed25519) signatures on each released `.dmg` (Sparkle's default)

### 9.1 Appcast.xml

The appcast XML lives at the URL configured in `SUFeedURL` (or `webappify.yaml`'s `update_feed:` field). It is an RSS-like document with one `<item>` per release:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Odysseus</title>
    <item>
      <title>Odysseus 0.3.0</title>
      <pubDate>Mon, 02 Jun 2026 12:00:00 +0000</pubDate>
      <sparkle:version>3</sparkle:version>
      <sparkle:shortVersionString>0.3.0</sparkle:shortVersionString>
      <enclosure url="https://github.com/.../Odysseus-0.3.0.dmg"
                 sparkle:edSignature="base64-encoded-64-byte-sig"
                 length="284567890"
                 type="application/x-apple-diskimage" />
    </item>
  </channel>
</rss>
```

`sparkle:edSignature` is the base64-encoded **64-byte** Ed25519 signature of the `.dmg` file's contents. `length` is the `.dmg` size in bytes. `sparkle:version` is a monotonically increasing integer (separate from `shortVersionString`).

### 9.2 Build / publish flow

1. **Tag a release**: `git tag v0.3.0` and push.
2. **CI builds** the `.app` for each per-app via `ci/build-app.sh`.
3. **CI packages** the `.dmg` via `ci/package-dmg.sh`.
4. **CI signs** the `.dmg` with the per-app's Ed25519 private key (from a GitHub Actions secret).
5. **CI creates a GitHub Release** with the `.dmg` attached.
6. **CI regenerates** `appcasts/<app>.xml` with the new item and commits it to the repo.
7. **CI deploys** the appcast (commit to `main`, GitHub Pages, or a public S3 bucket).

### 9.3 User flow

1. User has v0.2.1 installed.
2. User launches the app.
3. Sparkle (background) fetches the appcast and finds v0.3.0.
4. Sparkle shows "Odysseus 0.3.0 is available" with release notes.
5. User clicks Install.
6. Sparkle downloads the `.dmg`, verifies the EdDSA signature against `SUPublicEDKey` baked into the .app.
7. Sparkle asks the user to quit the app.
8. After the user quits, Sparkle replaces the .app in `/Applications/`.
9. User relaunches and is on v0.3.0.

### 9.4 Trust model

- The **public key** (in `Info.plist`'s `SUPublicEDKey`) is committed to the repo and shipped with every `.app`.
- The **private key** lives ONLY in the CI environment (GitHub Actions secret). It is never committed and never leaves CI.
- A man-in-the-middle can substitute a fake appcast.xml, but Sparkle rejects updates whose `.dmg` signature doesn't match the public key. The MITM would need the private key, which is in CI.

### 9.5 Generating keys

```bash
SEED=$(openssl rand -hex 32)   # for production
python3 tools/generate_keys.py <app-name>
# Produces:
#   keys/<app>_update_private.pem   (DO NOT COMMIT — put in GitHub secret)
#   keys/<app>_update_public.txt    (commit this; 32-byte Ed25519 pub key, base64)
```

`SEED` makes the key generation deterministic for testing.

### 9.6 Configuring the per-app

In `apps/<name>/webappify.yaml`:

```yaml
# Required for updates to work. The URL of the appcast.xml.
update_feed: https://brimdor.github.io/mac-app-builder/appcasts/odysseus.xml
# Or for development:
# update_feed: http://127.0.0.1:9999/appcast.xml
```

At build time, this is copied into `Info.plist`'s `SUFeedURL` by `ci/build-app.sh`.

### 9.7 Manual update check

`Help → Check for Updates…` triggers `SPUUpdater.checkForUpdates()` which shows Sparkle's standard "Checking / Update available / No updates" UI. This works whether the updater is in automatic mode or not.

---

## 10. Code signing

v1 uses **ad-hoc signing**:

```bash
codesign --force --deep --sign - MyApp.app
```

Ad-hoc signing lets the `.app` run on the developer's Mac without warnings. It does NOT let the `.app` run on other Macs without a "right-click → Open" the first time, and it does NOT pass Gatekeeper on macOS 26+.

For real distribution outside the dev org, the per-app needs **Developer ID signing** with a registered Apple Developer account ($99/year). The CI workflow documents this path but does not automate it in v1.

The wrapper Swift sources don't need any special signing — ad-hoc signing of the `.app` bundle covers everything inside.

---

## 11. What this standard does NOT cover

Explicitly out of scope for v1:

- **Node.js / Go / Rust / Ruby runtimes.** v1 is Python only.
- **Generic packager.** We are NOT building a tool that "packages any webapp." Each per-app is hand-designed (by the LLM agent or a human) to fit the webapp it wraps. See §12 for why.
- **First-run wizards beyond simple inputs.** OAuth, license server validation, etc. are v2.
- **App Store distribution.** Different signing, sandboxing rules, and submission process.
- **Auto-update silent mode.** Sparkle always asks the user before updating (v1 default).
- **Telemetry / crash reporting.** Privacy-first; opt-in only, future.
- **Multi-app orchestration.** Each per-app is independent.
- **Linux / Windows support.** Future per-platform standards.

---

## 12. Why a standard, not a packager

We deliberately do NOT build a generic, config-driven packager. Reasons:

1. **Webapps are not uniform.** A "generic" packager that handles every case becomes a Turing-complete DSL. We've all seen this happen.
2. **Auto-detection is fragile.** "Detect Python from `requirements.txt`" works for trivial apps and breaks on real ones (custom install steps, MCP servers, sidecar processes, etc.).
3. **The LLM is the packager.** A capable LLM reading the webapp's repo can produce a per-app Swift wrapper that conforms to this standard. That's the automation — not a parameter sweep.
4. **The standard captures "what's a good `.app`."** A human or LLM can read this document and produce a conforming `.app` without further guidance. The standard is the spec; the LLM is the implementer.

If you're tempted to add a `webappify.yaml` field for some new runtime concern, ask first: "can this be expressed as a per-app Swift customization instead?" If yes, keep the standard minimal and let the per-app wrapper handle it. If no, it's a candidate for standardization.

---

## Appendix: conformance checklist

Before any merge to `main`, a per-app `.app` MUST pass:

- [ ] Bundle structure matches §2
- [ ] Info.plist has all required keys from §3
- [ ] `webappify.yaml` validates against the schema in §4
- [ ] Native UI implements all required items from §5
- [ ] Data locations match §6
- [ ] Bundle ID follows §7
- [ ] Naming follows §8
- [ ] Update flow (Sparkle or alternative) is wired up per §9
- [ ] Code is signed per §10
- [ ] Cardinal Rule test passes (`ci/cardinal-rule-test.sh`)
- [ ] Lift-and-shift test passes (`ci/lift-and-shift-test.sh`)
- [ ] The `.app` actually launches and works on a real Mac
