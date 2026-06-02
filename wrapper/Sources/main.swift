// main.swift — entry point for a webapp-wrapper .app.
//
// This is the standard, app-agnostic entry point. All app-specific
// behavior is configured via Contents/Resources/webappify.yaml, which
// is read by AppDelegate at startup.
//
// To customize: per-app dirs should copy this file and the rest of the
// reference wrapper into apps/<app>/wrapper/, then modify the copies.
// Do not modify the reference wrapper itself (see STANDARD.md §12).

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
