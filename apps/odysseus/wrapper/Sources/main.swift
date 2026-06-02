// main.swift — entry point for a webapp-wrapper .app.
//
// Standard NSApplication entry. The @objc AppDelegate is wired up via
// Info.plist's NSPrincipalClass / NSMainNibFile, or explicitly by being
// assigned to NSApp.delegate. We do the latter so we don't need a .xib.
//
// To customize: per-app dirs should copy this file and the rest of the
// reference wrapper into apps/<app>/wrapper/, then modify the copies.
// Do not modify the reference wrapper itself (see STANDARD.md §12).

import Cocoa

FileHandle.standardError.write("[main.swift] entry point reached\n".data(using: .utf8)!)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
