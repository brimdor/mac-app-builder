# `wrapper/` — the reference Swift + WKWebView implementation

This is the **reference wrapper** for the mac-app-builder standard. It is a Swift + AppKit + WebKit application that:

- Loads `Contents/Resources/webappify.yaml` to get its configuration
- Creates an `NSWindow` with a `WKWebView` showing the bundled webapp
- Spawns the bundled server (defined in `webappify.yaml`)
- Polls the server for readiness, then loads the URL
- Provides a standard menu bar (File / Edit / Window / Help)
- Writes its log to `~/Library/Logs/<bundle_id>/wrapper.log`
- On quit, terminates the server child process

## Layout

```
wrapper/
├── Sources/
│   ├── main.swift                  ← entry point
│   ├── AppDelegate.swift           ← window, menu bar, lifecycle
│   ├── Config.swift                ← webappify.yaml loader
│   └── ServerManager.swift         ← spawn + manage server
├── Resources/
│   ├── Info.plist.tmpl             ← template (${APP_NAME} substituted)
│   └── webappify.yaml.tmpl         ← template for per-app config
├── build.sh                        ← compiles into a .app skeleton
└── README.md                       ← you are here
```

## Build

```bash
./wrapper/build.sh MyApp /tmp/MyApp.app
```

This produces a `.app` skeleton with the Swift binary compiled, but **no** app-specific resources (no `webappify.yaml`, no icon, no `app/`, no `runtime/`). The per-app build pipeline (`ci/build-app.sh`) adds those.

## Customizing for a per-app

To create a per-app wrapper:

1. Copy this entire `wrapper/` directory into `apps/<app>/wrapper/`.
2. Edit the Swift sources in the copy to add app-specific behavior (custom About text, custom menu items, first-run wizard, etc.).
3. Do **not** modify this reference wrapper. Per-app customizations go in the copy.

The standard rule: this directory is read-only. Changes here require a human review of the entire standard.

## Why a hand-rolled YAML parser?

`Config.swift` includes a small hand-rolled YAML parser that handles the subset needed by `webappify.yaml`. We don't use Yams or a full library because the schema is small and stable. If a per-app needs YAML features we don't support (anchors, multi-line scalars, etc.), swap in Yams in that per-app's wrapper — but then the per-app takes on the dependency.

## Known limitations

- v1 has no Sparkle integration. The `Check for Updates…` menu item shows a placeholder alert. v1.1 adds Sparkle.
- v1 has no first-run wizard. The `first_run` field in `webappify.yaml` is read but ignored. v1.1 implements it.
- The hand-rolled YAML parser is strict. It will reject `webappify.yaml` files that use YAML features outside the supported subset. This is intentional: it forces per-app authors to use simple, readable configs.
