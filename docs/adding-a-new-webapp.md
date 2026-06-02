# Adding a new per-app

This guide is for the **LLM agent** (or a human) creating a new per-app directory in `apps/<name>/`. Read [`STANDARD.md`](../STANDARD.md) first.

## When to add a new per-app

When you want to package a webapp — typically an open source project on GitHub — as a self-contained macOS `.app`. Each per-app is its own thing; you can add as many as you want.

## What's in a per-app dir

```
apps/<name>/
├── DESIGN.md             ← the LLM-written design for this .app
├── webappify.yaml        ← runtime config (read by the wrapper at startup)
├── Info.plist            ← optional: per-app overrides for the wrapper's plist
├── icon.png              ← app icon (PNG, will be converted to .icns)
├── icon.icns             ← OR pre-converted .icns
├── build.sh              ← entry point (delegates to ci/build-app.sh)
├── build-runtime.sh      ← bundles the language runtime + upstream source
├── README.md             ← human-readable docs
├── wrapper/              ← customized Swift sources (copy of ../wrapper/, then modified)
│   └── Sources/
└── tests/                ← app-specific tests (optional)
```

## Step-by-step

### 1. Create the directory

```bash
mkdir -p apps/<name>/wrapper/Sources
```

### 2. Read the upstream webapp's repo

Use `git clone` or the GitHub API to read the upstream webapp's source. Identify:

- **Language / runtime.** What does the app need to run? (Python, Node, Go, etc.)
- **Entry point.** What command starts the server? (e.g. `uvicorn app:app`)
- **Default port.** What port does the server listen on?
- **Dependencies.** Is there a `requirements.txt`, `package.json`, `go.mod`, etc.?
- **First-run flow.** Does the app need any user input on first launch? (license key, account creation, etc.)
- **External services.** Does the app need a database, vector store, etc.?

### 3. Write `DESIGN.md`

Document the per-app-specific decisions. See `apps/odysseus/DESIGN.md` for a complete example. The required sections are:

- Overview
- Source layout (upstream)
- Server lifecycle
- First-run flow
- Custom UI
- Update feed
- Known quirks

### 4. Write `webappify.yaml`

See the schema in `STANDARD.md` §4. Required fields: `name`, `display_name`, `bundle_id`, `version`, `runtime`, `port`, `url`, `start_command`. Optional: `health_check`, `env`, `first_run`, `update_feed`.

### 5. Write `build-runtime.sh`

This script bundles the upstream source and the language runtime into `Contents/Resources/app/` and `Contents/Resources/runtime/`. See `apps/odysseus/build-runtime.sh` for the Python pattern using `python-build-standalone`. Adapt for other runtimes.

For a new runtime (Node, Go, etc.), the pattern is:

1. Download a relocatable build of the runtime (e.g. `node-build-standalone`, pre-built Go binary)
2. Extract into `Contents/Resources/runtime/<runtime>/`
3. Copy the upstream source into `Contents/Resources/app/`
4. Install any dependencies (e.g. `npm install`)
5. Verify the runtime + deps work

### 6. Copy and customize the wrapper

```bash
cp -R wrapper/Sources apps/<name>/wrapper/Sources
```

Then edit the copy to add app-specific behavior. Common customizations:

- Custom About text (override `showAbout()` in `AppDelegate.swift`)
- Custom menu items
- First-run wizard (call out to `webappify.yaml`'s `first_run`)
- Custom URL handling

**Do not modify `wrapper/Sources/`.** That's the reference. Customize the copy in `apps/<name>/wrapper/`.

### 7. Add an icon

Provide a 1024×1024 PNG at `apps/<name>/icon.png`. The build pipeline converts it to `.icns` at multiple sizes.

### 8. Test

```bash
./ci/build-app.sh <name>
./ci/cardinal-rule-test.sh "dist/$(echo <name> | tr '[:lower:]' '[:upper:]' | cut -c1)$(echo <name> | cut -c2-).app"
./ci/lift-and-shift-test.sh "dist/$(echo <name> | tr '[:lower:]' '[:upper:]' | cut -c1)$(echo <name> | cut -c2-).app"
./ci/package-dmg.sh <name>
```

All four must succeed. If the Cardinal Rule or lift-and-shift test fails, fix the per-app and re-run.

### 9. Add to the CI matrix

Edit `.github/workflows/build.yml` to add the new app name to the `matrix.app` list:

```yaml
matrix:
  app: [odysseus, <name>]   # add <name> here
```

### 10. Open a PR

Commit everything and open a PR. The CI will build and test. A human reviewer merges.

## Tips

- **Start from an existing per-app.** Copy `apps/odysseus/` to `apps/<name>/` and modify. This is the fastest path.
- **Keep the per-app small.** The bigger the per-app's wrapper, the harder it is to maintain. If you find yourself wanting to add a lot of custom Swift code, maybe the runtime detection belongs in the standard instead.
- **Don't fork the webapp.** Per-app dirs are for *packaging* the webapp, not for *modifying* it. If the webapp has a bug, report it upstream.
- **Document quirks in DESIGN.md.** Future maintainers (human or LLM) will read it.
- **Test on a clean Mac.** The Cardinal Rule and lift-and-shift tests catch the most common bugs. But nothing beats running the .app on a real Mac that has no dev tools installed.
