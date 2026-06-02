// AppDelegate.swift — main application delegate for the reference wrapper.
//
// This is the app-agnostic reference implementation. It:
//   - loads webappify.yaml
//   - creates the main NSWindow with a WKWebView
//   - sets up the standard menu bar
//   - spawns the bundled server
//   - polls the server for readiness
//   - loads the webapp URL into the WKWebView
//   - handles window close (doesn't quit, per macOS convention)
//   - handles Cmd+Q (terminates server, exits)
//
// To customize: per-app dirs should copy this file and modify the copy.
// Common customizations: custom About text, custom menu items, first-run
// wizard, post-launch hooks.

import Cocoa
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {

    // ── Configuration (loaded at startup) ──
    var config: WebAppConfig!

    // ── UI state ──
    private var window: NSWindow!
    private var webView: WKWebView!
    private var server: ServerManager!

    // ── Lifecycle ──

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            config = try Config.load()
        } catch {
            showFatalError("Failed to load webappify.yaml", message: "\(error)")
            return
        }

        NSLog("[\(config.name)] launching (bundleId=\(config.bundleId), port=\(config.port))")
        log("\(config.displayName) launching")

        setupMenuBar()
        setupWindow()
        startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Closing window doesn't quit; the app lives in the Dock
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("\(config.displayName) terminating")
        server?.stop()
    }

    // MARK: - Window

    private func setupWindow() {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 820)
        window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.title = config.displayName
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 800, height: 600)

        // Center on the main screen
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let x = sf.origin.x + (sf.width - rect.width) / 2
            let y = sf.origin.y + (sf.height - rect.height) / 2
            window.setFrame(NSRect(x: x, y: y, width: rect.width, height: rect.height), display: true)
        }
        window.setFrameAutosaveName("\(config.name)MainWindow")

        // WKWebView
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.websiteDataStore = WKWebsiteDataStore.default()
        webView = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        window.contentView?.addSubview(webView)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu bar (standard, app-agnostic)

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(config.displayName)", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(config.displayName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(config.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let reload = NSMenuItem(title: "Reload", action: #selector(reloadUI), keyEquivalent: "r")
        reload.target = self
        fileMenu.addItem(reload)
        fileMenu.addItem(NSMenuItem.separator())
        let openInBrowser = NSMenuItem(title: "Open in Browser…", action: #selector(openInBrowser), keyEquivalent: "")
        openInBrowser.target = self
        fileMenu.addItem(openInBrowser)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit (standard)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // Help
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Open Logs Folder", action: #selector(openLogsFolder), keyEquivalent: "")
            .target = self
        helpMenu.addItem(withTitle: "Open Data Folder", action: #selector(openDataFolder), keyEquivalent: "")
            .target = self
        helpMenu.addItem(withTitle: "Open Install Folder", action: #selector(openInstallFolder), keyEquivalent: "")
            .target = self
        helpMenu.addItem(NSMenuItem.separator())
        if config.updateFeed != nil {
            helpMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
                .target = self
            helpMenu.addItem(NSMenuItem.separator())
        }
        helpMenu.addItem(withTitle: "About \(config.displayName)", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Server lifecycle

    private func startServer() {
        server = ServerManager(config: config)
        server.onReady = { [weak self] in
            self?.loadUI()
        }
        do {
            try server.start()
        } catch {
            showFatalError("Failed to start server", message: "\(error.localizedDescription)")
        }
    }

    private func loadUI() {
        let url = URL(string: "http://127.0.0.1:\(config.port)\(config.url)")!
        NSLog("[\(config.name)] server ready, loading UI")
        log("Server ready, loading UI")
        webView.load(URLRequest(url: url))
    }

    // MARK: - Actions

    @objc func reloadUI() {
        webView?.reload()
    }

    @objc func openInBrowser() {
        if let url = URL(string: "http://127.0.0.1:\(config.port)\(config.url)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openLogsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: config.logsDir)])
    }

    @objc func openDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: config.dataDir)])
    }

    @objc func openInstallFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: config.appDir)])
    }

    @objc func checkForUpdates() {
        // v1: no Sparkle. Show a placeholder alert.
        let alert = NSAlert()
        alert.messageText = "Update check"
        alert.informativeText = "In-app updates are not yet wired up. The configured update feed is:\n\n\(config.updateFeed ?? "(not set)")\n\nSee the mac-app-builder project for v1.1 update support."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = config.displayName
        alert.informativeText = """
        Version \(config.version)

        Data: \(config.dataDir)
        Logs: \(config.logsDir)
        Server: http://127.0.0.1:\(config.port)\(config.url)

        Built with mac-app-builder.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Open external links in the default browser
        if let urlStr = navigationAction.request.url?.absoluteString,
           !urlStr.hasPrefix("http://127.0.0.1:\(config.port)"),
           !urlStr.hasPrefix("about:"),
           navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - Helpers

    private func log(_ s: String) {
        let line = "[\(Date())] [\(config.name)] \(s)\n"
        let path = config.logsDir + "/wrapper.log"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private func showFatalError(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}
