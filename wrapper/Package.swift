// swift-tools-version: 5.9
//
// Package.swift — the mac-app-builder wrapper as a Swift Package.
//
// This is a thin wrapper around a webapp. The wrapper:
//   - loads webappify.yaml
//   - creates a window with a WKWebView
//   - spawns the bundled server (Python, Node, etc.) as a child process
//   - polls the server for readiness, then loads the URL in the WKWebView
//   - shows a first-run wizard if the user database doesn't exist
//   - uses Sparkle for in-app auto-updates
//
// We use Swift Package Manager so we can declare the Sparkle dependency.
// Sparkle is the de-facto standard for macOS auto-updates. The appcast
// flow is: a tagged release triggers a CI build that signs the .dmg
// with an EdDSA private key and pushes the .dmg + an appcast.xml to
// the configured feed URL. The installed .app's Sparkle then fetches
// the appcast on launch (or via Help → Check for Updates…) and offers
// to install the new version.
//
// App-name substitution: the wrapper has a `name` build setting that
// controls CFBundleExecutable / CFBundleName. We pass it via
// `-Xswiftc -DAPP_NAME=...` at build time.

import PackageDescription

let package = Package(
    name: "WebAppifyWrapper",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "wrapper", targets: ["Wrapper"])
    ],
    dependencies: [
        // Sparkle — the macOS auto-update framework.
        // https://sparkle-project.org/
        // 2.7.0 is the latest 2.x line at time of writing; pin to a
        // known-good version.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "Wrapper",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            linkerSettings: [
                // Add @executable_path/../Frameworks so the runtime can
                // find Sparkle.framework when the .app is in /Applications.
                // Without this, dyld looks in Contents/MacOS/Sparkle.framework
                // and fails to load.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
