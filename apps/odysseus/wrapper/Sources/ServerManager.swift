// ServerManager.swift — spawns the bundled server, polls for readiness,
// terminates the server on quit.
//
// The server is a child process. We use Foundation's Process API.
//
// The server's working directory is set to $APP_DIR (Contents/Resources/app/),
// and the standard env vars ($DATA_DIR, $LOGS_DIR, $CACHE_DIR, $PORT) are
// passed so the server can find its user data location.
//
// IMPORTANT: this code does not write any user data to the bundle. The
// server's stdout/stderr is captured and tee'd to $LOGS_DIR/server.log, but
// the log file lives in the user's home directory, not in the bundle.

import Foundation

final class ServerManager {
    let config: WebAppConfig
    private var process: Process?
    private var logFileHandle: FileHandle?
    private(set) var isReady = false
    private var readinessTimer: Timer?
    var onReady: (() -> Void)?

    init(config: WebAppConfig) {
        self.config = config
    }

    /// Spawn the server, return immediately. The process runs in the background.
    func start() throws {
        // Make sure data/logs/cache dirs exist
        let fm = FileManager.default
        try? fm.createDirectory(atPath: config.dataDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: config.logsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: config.cacheDir, withIntermediateDirectories: true)

        // Resolve the start command. Substitute $PORT and similar.
        let resolvedCommand = config.startCommand.map { resolvePath($0) }

        // Find the executable. The first element is the program; rest are args.
        guard let programRaw = resolvedCommand.first else {
            throw NSError(domain: "ServerManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "start_command is empty"])
        }
        let arguments = Array(resolvedCommand.dropFirst())

        // Resolve the program to an absolute path. The start_command may use
        // a relative path like "./runtime/python/bin/python3" — we resolve
        // it relative to the .app's Resources/ directory.
        let program: String
        let resourcesPath = Bundle.main.resourcePath ?? NSTemporaryDirectory()
        if programRaw.hasPrefix("/") {
            // Already absolute
            program = programRaw
        } else {
            // Relative path: resolve against the .app's Resources/.
            // Strip leading "./" because URL(fileURLWithPath:) handles it
            // weirdly when used with relativeTo. We do the join manually.
            let stripped = programRaw.hasPrefix("./")
                ? String(programRaw.dropFirst(2))
                : programRaw
            let separator = resourcesPath.hasSuffix("/") ? "" : "/"
            program = resourcesPath + separator + stripped
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: program)
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: config.appDir)

        // First-launch detection: run setup.py if the database doesn't exist.
        // This is a safety net — the wrapper's FirstRunWindowController
        // should have already run setup.py before we get here. But if the
        // user deletes just the database (and not auth.json) or vice versa,
        // we want to re-run setup so the app still works.
        let dbPath = config.dataDir + "/app.db"
        if !FileManager.default.fileExists(atPath: dbPath) {
            let setupScript = config.appDir + "/setup.py"
            if FileManager.default.fileExists(atPath: setupScript) {
                NSLog("[\(config.name)] first launch detected, running setup.py (safety net)")
                let setupProc = Process()
                setupProc.executableURL = URL(fileURLWithPath: program)
                setupProc.arguments = [setupScript]
                setupProc.currentDirectoryURL = URL(fileURLWithPath: config.appDir)
                var setupEnv = ProcessInfo.processInfo.environment
                setupEnv["PYTHONPATH"] = (Bundle.main.resourcePath ?? "") + "/runtime/site-packages"
                setupEnv["DATA_DIR"] = config.dataDir
                setupEnv["LOGS_DIR"] = config.logsDir
                setupEnv["CACHE_DIR"] = config.cacheDir
                setupEnv["ODYSSEUS_SKIP_RUN_HINT"] = "1"
                setupProc.environment = setupEnv
                let setupOut = Pipe()
                setupProc.standardOutput = setupOut
                setupProc.standardError = setupOut
                setupOut.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty {
                        if let str = String(data: data, encoding: .utf8) {
                            FileHandle.standardError.write(str.data(using: .utf8) ?? Data())
                        }
                    }
                }
                do {
                    try setupProc.run()
                    setupProc.waitUntilExit()
                } catch {
                    NSLog("[\(config.name)] setup.py failed to launch: \(error)")
                }
            }
        }

        // Set up env. We set PYTHONPATH to include any bundled site-packages
        // (the convention for per-apps using python-build-standalone; venv
        // doesn't work reliably with relocatable Python on macOS).
        // We also set DATABASE_URL explicitly to the right SQLite path so
        // the webapp doesn't need any hardcoded-path patches for this.
        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(config.port)
        env["DATA_DIR"] = config.dataDir
        env["LOGS_DIR"] = config.logsDir
        env["CACHE_DIR"] = config.cacheDir
        env["APP_DIR"] = config.appDir
        env["BUNDLE_ID"] = config.bundleId
        // SQLite URL: "sqlite:///" + absolute path. Three slashes = absolute path.
        env["DATABASE_URL"] = "sqlite:///" + config.dataDir + "/app.db"
        // If the per-app bundles site-packages, expose them via PYTHONPATH.
        let sitePackages = (Bundle.main.resourcePath ?? "") + "/runtime/site-packages"
        if FileManager.default.fileExists(atPath: sitePackages) {
            env["PYTHONPATH"] = sitePackages
        }
        for (k, v) in config.env {
            env[k] = v
        }
        proc.environment = env

        // Open the server log file in append mode
        let logPath = config.logsDir + "/server.log"
        if !fm.fileExists(atPath: logPath) {
            fm.createFile(atPath: logPath, contents: nil, attributes: nil)
        }
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        logHandle.seekToEndOfFile()
        logFileHandle = logHandle

        // Pipe stdout+stderr to the log file (and a small in-memory buffer for the UI)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            logHandle.write(data)
        }

        try proc.run()
        process = proc

        // Start polling for readiness
        startReadinessPolling()
    }

    /// Stop the server child process.
    func stop() {
        readinessTimer?.invalidate()
        readinessTimer = nil
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        // Give it 3 seconds to exit cleanly, then SIGKILL
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        process = nil
        try? logFileHandle?.close()
        logFileHandle = nil
    }

    // MARK: - Readiness polling

    private func startReadinessPolling() {
        let url = URL(string: "http://127.0.0.1:\(config.port)\(config.url)")!
        let healthUrl = config.healthCheck.map { URL(string: "http://127.0.0.1:\(config.port)\($0.url)")! }
        let expected = config.healthCheck?.expectedStatus ?? 200
        let timeout = config.healthCheck?.timeoutSeconds ?? 60

        let startTime = Date()
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            // Bail if process died
            if let p = self.process, !p.isRunning {
                timer.invalidate()
                return
            }
            // Timeout
            if Date().timeIntervalSince(startTime) > Double(timeout) {
                timer.invalidate()
                return
            }
            // Try the main URL
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            URLSession.shared.dataTask(with: req) { _, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                    // Optionally also check the health URL
                    if let healthUrl = healthUrl {
                        var hreq = URLRequest(url: healthUrl)
                        hreq.timeoutInterval = 1.5
                        URLSession.shared.dataTask(with: hreq) { _, hresponse, _ in
                            if let hhttp = hresponse as? HTTPURLResponse, hhttp.statusCode == expected {
                                DispatchQueue.main.async {
                                    if !self.isReady {
                                        self.isReady = true
                                        timer.invalidate()
                                        self.onReady?()
                                    }
                                }
                            }
                        }.resume()
                    } else {
                        DispatchQueue.main.async {
                            if !self.isReady {
                                self.isReady = true
                                timer.invalidate()
                                self.onReady?()
                            }
                        }
                    }
                }
            }.resume()
        }
    }

    // MARK: - Helpers

    /// Replace $PORT in a command-line argument with the actual port.
    /// Also resolves $APP_DIR to the bundled source directory.
    private func resolvePath(_ s: String) -> String {
        var result = s
        result = result.replacingOccurrences(of: "$PORT", with: String(config.port))
        result = result.replacingOccurrences(of: "$APP_DIR", with: config.appDir)
        return result
    }
}
