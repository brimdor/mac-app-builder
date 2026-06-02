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
    private var firstRunWizard: FirstRunWindowController?

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

        // First-run detection: if the user database doesn't exist in the
        // data dir, we need to collect admin credentials before starting the
        // server. Show a native wizard.
        if isFirstLaunch() {
            showFirstRunWizard()
        } else {
            setupMenuBar()
            setupWindow()
            startServer()
        }
    }

    private func isFirstLaunch() -> Bool {
        let dbPath = config.dataDir + "/app.db"
        let authPath = config.dataDir + "/auth.json"
        // First launch = neither the database nor the auth file exists.
        // The auth file is what setup.py creates on a successful first run.
        return !FileManager.default.fileExists(atPath: dbPath) &&
               !FileManager.default.fileExists(atPath: authPath)
    }

    private func showFirstRunWizard() {
        // Set up the menu bar (so Quit works) and a minimal main window
        // (so the app has a presence). The wizard appears on top.
        setupMenuBar()
        setupWindow()
        window.title = "Welcome to \(config.displayName)"

        let wizard = FirstRunWindowController(
            appName: config.displayName,
            bundleId: config.bundleId,
            dataDir: config.dataDir
        )
        wizard.onComplete = { [weak self] result in
            self?.runFirstRunSetup(result)
        }
        wizard.onCancel = {
            NSApp.terminate(nil)
        }
        firstRunWizard = wizard
        wizard.present()
    }

    private func runFirstRunSetup(_ result: FirstRunResult) {
        firstRunWizard?.setRunning(true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let strongSelf = self else { return }
            do {
                try strongSelf.runSetupPy(username: result.username, password: result.password) { message in
                    // Stream setup output to the wizard
                    DispatchQueue.main.async { [weak self] in
                        self?.firstRunWizard?.showError(message)
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.firstRunWizard?.setRunning(false)
                    // Verify setup actually created auth.json
                    let authPath = self.config.dataDir + "/auth.json"
                    if FileManager.default.fileExists(atPath: authPath) {
                        // Success! Dismiss the wizard and start the server.
                        self.firstRunWizard?.window?.orderOut(nil)
                        self.firstRunWizard = nil
                        self.window.title = self.config.displayName
                        self.startServer()
                    } else {
                        self.firstRunWizard?.showError(
                            "Setup did not create \(authPath). Check the server log for details."
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.firstRunWizard?.setRunning(false)
                    self?.firstRunWizard?.showError("Setup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runSetupPy(username: String, password: String, onLog: @escaping (String) -> Void) throws {
        // The setup script is at <app>/setup.py. We invoke the bundled
        // Python with PYTHONPATH pointing at the bundled site-packages.
        let resourcesPath = Bundle.main.resourcePath ?? NSTemporaryDirectory()
        let program = resourcesPath + "/runtime/python/bin/python3"
        let setupScript = config.appDir + "/setup.py"
        guard FileManager.default.isExecutableFile(atPath: program) else {
            throw NSError(domain: "FirstRun", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bundled Python not found at \(program)"])
        }
        guard FileManager.default.fileExists(atPath: setupScript) else {
            throw NSError(domain: "FirstRun", code: 2, userInfo: [NSLocalizedDescriptionKey: "setup.py not found in the app bundle"])
        }

        // Make sure data/logs dirs exist
        try? FileManager.default.createDirectory(atPath: config.dataDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: config.logsDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: program)
        proc.arguments = [setupScript]
        proc.currentDirectoryURL = URL(fileURLWithPath: config.appDir)

        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = resourcesPath + "/runtime/site-packages"
        env["DATA_DIR"] = config.dataDir
        env["LOGS_DIR"] = config.logsDir
        env["CACHE_DIR"] = config.cacheDir
        env["ODYSSEUS_ADMIN_USER"] = username
        env["ODYSSEUS_ADMIN_PASSWORD"] = password
        env["ODYSSEUS_SKIP_RUN_HINT"] = "1"
        proc.environment = env

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe

        // Read output line-by-line and forward to the wizard
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let text = String(data: data, encoding: .utf8) {
                onLog(text)
            }
        }

        try proc.run()
        proc.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil

        if proc.terminationStatus != 0 {
            throw NSError(domain: "FirstRun", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "setup.py exited with code \(proc.terminationStatus). Check the log for details."])
        }
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
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 820)
        window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.title = config.displayName
        window.minSize = NSSize(width: 800, height: 600)

        // Center on the main screen
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let x = sf.origin.x + (sf.width - rect.width) / 2
            let y = sf.origin.y + (sf.height - rect.height) / 2
            window.setFrame(NSRect(x: x, y: y, width: rect.width, height: rect.height), display: true)
        }
        window.setFrameAutosaveName("\(config.name)MainWindow")

        // WKWebView. The contentView is created lazily by Cocoa when we
        // first access it; its bounds may be NSRect.zero at this point.
        // We size the webView to the window's content rect (which IS
        // computed correctly because the window has a frame) and rely
        // on autoresizingMask to keep it filling as the user resizes.
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.websiteDataStore = WKWebsiteDataStore.default()
        webView = WKWebView(frame: window.contentRect(forFrameRect: window.frame), configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // NOTE: We deliberately do NOT set drawsBackground=false here. On
        // macOS 26, this private KVC can cause the webView to render a
        // black background and never paint the document content even
        // though the URL loaded successfully. Default opaque white is
        // what we want — if the webapp's CSS wants transparency it can
        // opt in.
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let url = webView.url?.absoluteString {
            NSLog("[\(config.name)] webView started loading \(url)")
        } else {
            NSLog("[\(config.name)] webView started loading")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url?.absoluteString {
            NSLog("[\(config.name)] webView finished loading \(url)")
        } else {
            NSLog("[\(config.name)] webView finished loading")
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
