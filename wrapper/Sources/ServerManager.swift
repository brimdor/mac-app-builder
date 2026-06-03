// ServerManager.swift — spawns the bundled server, polls for readiness,
// terminates the server on quit.
//
// CRITICAL FIX for Sparkle updates: when Sparkle installs an update, it kills
// the old app process but macOS does NOT auto-kill child processes. The old
// Python server survives as an orphan, holding our port. If the new app tries
// to start a server on the same port before the orphan fully releases it,
// the bind fails and the UI stays black forever.
//
// This implementation:
//   1. Kills ALL processes holding our port (not just one)
//   2. Waits up to 5s for the port to be truly free (verified by connect)
//   3. Starts the new server only after confirmation
//   4. Enhanced readiness polling with diagnostics

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

    // MARK: - Lifecycle

    /// Spawn the server, return immediately. The process runs in the background.
    func start() throws {
        let fm = FileManager.default
        let portString = String(config.port)

        // 1. Ensure directories exist
        try? fm.createDirectory(atPath: config.dataDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: config.logsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: config.cacheDir, withIntermediateDirectories: true)

        // 2. Migrate .app_key from old bundle location to DATA_DIR
        let oldKeyPath = (Bundle.main.resourcePath ?? "") + "/app/data/.app_key"
        let newKeyPath = config.dataDir + "/.app_key"
        if fm.fileExists(atPath: oldKeyPath) && !fm.fileExists(atPath: newKeyPath) {
            do {
                try fm.copyItem(atPath: oldKeyPath, toPath: newKeyPath)
                NSLog("[\(config.name)] migrated .app_key from bundle to DATA_DIR")
            } catch {
                NSLog("[\(config.name)] failed to migrate .app_key: \(error.localizedDescription)")
            }
        }

        // 3. KILL PHASE — find and kill ALL orphaned processes on our port
        // After a Sparkle update, the old Python server survives as an orphan.
        // We must kill it AND wait for the port to be truly free.
        NSLog("[\(config.name)] checking for orphaned servers on port \(portString)...")
        let orphansKilled = killOrphans(onPort: config.port)
        if orphansKilled > 0 {
            NSLog("[\(config.name)] killed \(orphansKilled) orphan(s), waiting for port release...")
        }

        // 4. WAIT PHASE — verify port is truly free before starting
        let portFree = waitForPortFree(port: config.port, timeoutSeconds: 5)
        if !portFree {
            NSLog("[\(config.name)] WARNING: port \(portString) still occupied after 5s. Server may fail to bind.")
            // Last resort: try one more aggressive kill
            _ = killOrphans(onPort: config.port)
            Thread.sleep(forTimeInterval: 1)
        } else {
            NSLog("[\(config.name)] port \(portString) is free")
        }

        // 5. Resolve start command
        let resolvedCommand = config.startCommand.map { resolvePath($0) }
        guard let programRaw = resolvedCommand.first else {
            throw NSError(domain: "ServerManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "start_command is empty"])
        }
        let arguments = Array(resolvedCommand.dropFirst())

        let program: String
        let resourcesPath = Bundle.main.resourcePath ?? NSTemporaryDirectory()
        if programRaw.hasPrefix("/") {
            program = programRaw
        } else {
            let stripped = programRaw.hasPrefix("./") ? String(programRaw.dropFirst(2)) : programRaw
            let separator = resourcesPath.hasSuffix("/") ? "" : "/"
            program = resourcesPath + separator + stripped
        }

        // 6. First-launch: run setup.py if no database
        let dbPath = config.dataDir + "/app.db"
        if !fm.fileExists(atPath: dbPath) {
            runSetupIfNeeded(usingProgram: program)
        }

        // 7. Configure and launch server
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: program)
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: config.appDir)

        var env = ProcessInfo.processInfo.environment
        env["PORT"] = portString
        env["DATA_DIR"] = config.dataDir
        env["LOGS_DIR"] = config.logsDir
        env["CACHE_DIR"] = config.cacheDir
        env["APP_DIR"] = config.appDir
        env["BUNDLE_ID"] = config.bundleId
        env["DATABASE_URL"] = "sqlite:///" + config.dataDir + "/app.db"
        let sitePackages = (Bundle.main.resourcePath ?? "") + "/runtime/site-packages"
        if fm.fileExists(atPath: sitePackages) {
            env["PYTHONPATH"] = sitePackages
        }
        for (k, v) in config.env { env[k] = v }
        proc.environment = env

        // Log file
        let logPath = config.logsDir + "/server.log"
        if !fm.fileExists(atPath: logPath) {
            fm.createFile(atPath: logPath, contents: nil, attributes: nil)
        }
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        logHandle.seekToEndOfFile()
        logFileHandle = logHandle

        // Pipe stdout+stderr
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { logHandle.write(data) }
        }

        NSLog("[\(config.name)] starting server on port \(portString)...")
        try proc.run()
        process = proc

        // 8. Start readiness polling
        startReadinessPolling()
    }

    /// Stop the server child process.
    func stop() {
        readinessTimer?.invalidate()
        readinessTimer = nil
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
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

    // MARK: - Orphan cleanup (NEW)

    /// Find and SIGKILL every process holding the given port.
    /// Returns the number of processes killed.
    private func killOrphans(onPort port: Int) -> Int {
        let portString = String(port)
        guard let lsofData = Process.run(["/usr/sbin/lsof", "-ti", ":\(portString)"]),
              let lsofOutput = String(data: lsofData, encoding: .utf8) else {
            return 0
        }

        let pids = lsofOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { Int32($0) }
            .filter { $0 > 0 }

        guard !pids.isEmpty else { return 0 }

        for pid in pids {
            NSLog("[\(config.name)] SIGKILL orphan pid=\(pid) on port \(portString)")
            kill(pid, SIGKILL)
        }
        return pids.count
    }

    /// Block until the port is connectable (or timeout).
    /// Returns true if the port is free (connect fails), false if still occupied.
    private func waitForPortFree(port: Int, timeoutSeconds: TimeInterval) -> Bool {
        let portString = String(port)
        let url = URL(string: "http://127.0.0.1:\(portString)/")!
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var attempt = 0

        while Date() < deadline {
            // Check 1: can we connect? If connection REFUSED, port is free.
            var req = URLRequest(url: url)
            req.timeoutInterval = 0.3
            let semaphore = DispatchSemaphore(value: 0)
            var isRefused = false
            URLSession.shared.dataTask(with: req) { _, _, error in
                if let err = error as NSError? {
                    // Connection refused = port is free!
                    isRefused = (err.code == NSURLErrorCannotConnectToHost ||
                                 err.code == NSURLErrorNetworkConnectionLost)
                }
                // If no error, something IS responding → port still occupied
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + .milliseconds(500))

            if isRefused {
                return true
            }

            attempt += 1
            if attempt % 10 == 0 {
                // Every ~500ms, try killing again (orphan may have respawned)
                _ = killOrphans(onPort: port)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        return false
    }

    // MARK: - Readiness polling

    private func startReadinessPolling() {
        let url = URL(string: "http://127.0.0.1:\(config.port)\(config.url)")!
        let healthUrl = config.healthCheck.map { URL(string: "http://127.0.0.1:\(config.port)\($0.url)")! }
        let expected = config.healthCheck?.expectedStatus ?? 200
        let timeout = config.healthCheck?.timeoutSeconds ?? 60

        let startTime = Date()
        var attemptCount = 0
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            // Bail if process died
            if let p = self.process, !p.isRunning {
                NSLog("[\(self.config.name)] server process died before becoming ready")
                timer.invalidate()
                return
            }

            // Timeout
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > Double(timeout) {
                NSLog("[\(self.config.name)] server readiness timeout (\(Int(elapsed))s)")
                timer.invalidate()
                return
            }

            attemptCount += 1
            if attemptCount == 1 || attemptCount % 10 == 0 {
                NSLog("[\(self.config.name)] polling server readiness... (\(Int(elapsed))s elapsed)")
            }

            // Try the main URL
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            URLSession.shared.dataTask(with: req) { _, response, error in
                if let err = error {
                    if attemptCount % 10 == 0 {
                        NSLog("[\(self.config.name)] readiness check error: \(err.localizedDescription)")
                    }
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode < 500 else { return }

                // Optionally also check health URL
                if let healthUrl = healthUrl {
                    var hreq = URLRequest(url: healthUrl)
                    hreq.timeoutInterval = 1.5
                    URLSession.shared.dataTask(with: hreq) { _, hresponse, _ in
                        if let hhttp = hresponse as? HTTPURLResponse, hhttp.statusCode == expected {
                            DispatchQueue.main.async {
                                if !self.isReady {
                                    self.isReady = true
                                    timer.invalidate()
                                    NSLog("[\(self.config.name)] server ready after \(Int(elapsed))s")
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
                            NSLog("[\(self.config.name)] server ready after \(Int(elapsed))s")
                            self.onReady?()
                        }
                    }
                }
            }.resume()
        }
    }

    // MARK: - Helpers

    private func runSetupIfNeeded(usingProgram program: String) {
        let setupScript = config.appDir + "/setup.py"
        guard FileManager.default.fileExists(atPath: setupScript) else { return }

        NSLog("[\(config.name)] first launch detected, running setup.py")
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
        do {
            try setupProc.run()
            setupProc.waitUntilExit()
        } catch {
            NSLog("[\(config.name)] setup.py failed: \(error)")
        }
    }

    private func resolvePath(_ s: String) -> String {
        var result = s
        result = result.replacingOccurrences(of: "$PORT", with: String(config.port))
        result = result.replacingOccurrences(of: "$APP_DIR", with: config.appDir)
        return result
    }
}

// MARK: - Process helper for port-cleanup
private extension Process {
    /// Run a command synchronously, return stdout as Data, or nil on failure.
    static func run(_ arguments: [String]) -> Data? {
        guard let executable = arguments.first, !executable.isEmpty else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return proc.terminationStatus == 0 && !data.isEmpty ? data : nil
        } catch {
            return nil
        }
    }
}
