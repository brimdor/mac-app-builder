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
    private var updater: Updater!
    private var cookiePreserver: CookiePreserver!

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

        // Start the server immediately. The upstream app (Odysseus) handles
        // its own first-time setup via the web UI when the user navigates to
        // it. No native wizard needed.
        setupMenuBar()
        setupWindow()
        startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Closing window doesn't quit; the app lives in the Dock
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("\(config.displayName) terminating")
        cookiePreserver?.stop()
        server?.stop()
    }

    // MARK: - Window

    private func setupWindow() {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 820)
        window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.title = config.displayName
        window.minSize = NSSize(width: 800, height: 600)

        // CRITICAL FIX for multi-monitor setups and Sparkle relaunch:
        // On macOS 15+ with multiple monitors, the window can be placed
        // at negative coordinates (e.g. y=-1268) which places it on a
        // secondary monitor or off-screen entirely. This makes the app
        // appear as a "black screen" because the window is visible but
        // positioned where the user can't see it properly.
        //
        // We ALWAYS center on the MAIN screen (the one with the menu bar,
        // which has frame.origin at (0,0)). We ignore any autosaved
        // positions because Sparkle relaunch can corrupt the saved position.
        window.setFrameAutosaveName("")
        
        // Find the main screen: it's the one with frame.origin == (0,0)
        let mainScreen = NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        
        if let screen = mainScreen {
            let sf = screen.visibleFrame
            let x = sf.origin.x + (sf.width - rect.width) / 2
            let y = sf.origin.y + (sf.height - rect.height) / 2
            let clampedX = max(sf.origin.x, min(x, sf.origin.x + sf.width - rect.width))
            let clampedY = max(sf.origin.y, min(y, sf.origin.y + sf.height - rect.height))
            window.setFrame(NSRect(x: clampedX, y: clampedY, width: rect.width, height: rect.height), display: true)
            NSLog("[\(config.name)] window placed on main screen at (\(clampedX), \(clampedY)) visibleFrame=\(sf)")
        } else {
            window.center()
            NSLog("[\(config.name)] window centered (no screen info)")
        }

        // WKWebView. We start with the contentView's *current* bounds
        // (which is correct at this point because the window has a
        // frame and the contentView is sized to match). The
        // autoresizingMask keeps the webView filling the contentView
        // as the user resizes the window.
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.websiteDataStore = WKWebsiteDataStore.default()
        webView = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        window.contentView?.addSubview(webView)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("[\(config.name)] window isVisible: \(window.isVisible), screen: \(String(describing: window.screen))")

        // CookiePreserver — mirrors WKWebView cookies to DATA_DIR so the
        // user's session survives Sparkle updates. When the app is killed
        // for update, WebKit's SQLite databases can be left corrupt. We
        // snapshot cookies every 30 s and restore them on launch.
        cookiePreserver = CookiePreserver(webView: webView, dataDir: config.dataDir)
        cookiePreserver.start()
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
            // Start the updater AFTER the server is up. This avoids
            // Sparkle prompting during first-run setup, and ensures
            // the user has a working app to return to if they reject
            // the update.
            self?.startUpdater()
        }
        do {
            try server.start()
        } catch {
            showFatalError("Failed to start server", message: "\(error.localizedDescription)")
        }
    }

    private func startUpdater() {
        updater = Updater(config: config)
        updater.start()
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
        if let u = updater {
            u.checkForUpdates()
        } else {
            // Updater hasn't started yet (e.g. server isn't ready).
            // Show a small alert so the user gets feedback.
            let alert = NSAlert()
            alert.messageText = "Update check"
            alert.informativeText = "The updater hasn't started yet. Please try again in a few seconds, after the app has finished loading."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let url = webView.url?.absoluteString {
            NSLog("[\(config.name)] webView started loading \(url)")
        } else {
            NSLog("[\(config.name)] webView started loading")
        }
        NSLog("[\(config.name)] webView frame: \(webView.frame)  contentView bounds: \(String(describing: window.contentView?.bounds))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url?.absoluteString {
            NSLog("[\(config.name)] webView finished loading \(url)")
        } else {
            NSLog("[\(config.name)] webView finished loading")
        }
        NSLog("[\(config.name)] webView frame after load: \(webView.frame)  contentView bounds: \(String(describing: window.contentView?.bounds))")
        // Force a redraw on the main thread, just in case macOS 26 needs
        // an extra nudge to composite the WKWebView's layer into the
        // window's contentView. We've seen the window appear black on
        // macOS 26 with multi-monitor setups otherwise.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.webView.frame = self.window.contentView!.bounds
            self.webView.needsDisplay = true
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[\(config.name)] webView failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("[\(config.name)] webView failed provisional: \(error.localizedDescription)")
    }

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
