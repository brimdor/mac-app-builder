// Config.swift — loads webappify.yaml from the app bundle and exposes
// the configuration to the rest of the wrapper.
//
// webappify.yaml is a hand-rolled parser; we don't need a full YAML
// library for the simple schema. If the schema grows, swap in Yams.

import Foundation

struct FirstRunItem: Decodable {
    let id: String
    let title: String
    let description: String?
    let type: String          // "text" | "password" | "credentials"
    let required: Bool?
    let env: String?          // env var name to set with the value
}

struct WebAppConfig {
    let name: String
    let displayName: String
    let bundleId: String
    let version: String

    let runtime: String
    let port: Int
    let url: String
    let startCommand: [String]
    let healthCheck: HealthCheck?
    let env: [String: String]
    let firstRun: [FirstRunItem]
    let updateFeed: String?

    let dataDir: String
    let logsDir: String
    let cacheDir: String
    let appDir: String   // Contents/Resources/app/
    let configPath: String

    struct HealthCheck {
        let url: String
        let expectedStatus: Int
        let timeoutSeconds: Int
    }
}

enum ConfigError: Error, LocalizedError {
    case fileNotFound
    case parseError(String)
    case missingRequiredField(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "webappify.yaml not found in bundle Resources/"
        case .parseError(let msg):
            return "Failed to parse webappify.yaml: \(msg)"
        case .missingRequiredField(let name):
            return "Required field missing in webappify.yaml: \(name)"
        }
    }
}

enum Config {
    /// Load webappify.yaml from the app bundle and compute the standard
    /// data directory locations.
    static func load() throws -> WebAppConfig {
        guard let url = Bundle.main.url(forResource: "webappify", withExtension: "yaml") else {
            throw ConfigError.fileNotFound
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text, sourceURL: url)
    }

    // MARK: - Hand-rolled YAML parser
    //
    // We support a strict subset of YAML that covers webappify.yaml:
    //   - top-level scalars and lists
    //   - nested mappings (one level)
    //   - list of mappings (one level, for first_run)
    //   - comments (# to end of line)
    //   - quoted strings (single or double)
    //
    // We do NOT support: anchors, multi-line scalars, flow style, tags.
    // If a per-app needs more, swap in Yams.

    static func parse(_ text: String, sourceURL: URL) throws -> WebAppConfig {
        let lines = preprocess(text)
        let top = try parseMapping(lines, indent: 0, context: "top-level")
        return try buildConfig(from: top, sourceURL: sourceURL)
    }

    private static func preprocess(_ text: String) -> [String] {
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                // Strip comments outside of quoted strings (simple heuristic)
                var inSingle = false
                var inDouble = false
                var result = ""
                for ch in line {
                    if ch == "'" && !inDouble { inSingle.toggle() }
                    if ch == "\"" && !inSingle { inDouble.toggle() }
                    if ch == "#" && !inSingle && !inDouble { break }
                    result.append(ch)
                }
                // Trim trailing whitespace only. Leading whitespace is
                // meaningful in YAML (it indicates nesting depth) and must
                // be preserved.
                while let last = result.last, last == " " || last == "\t" {
                    result.removeLast()
                }
                return result
            }
    }

    private enum Value {
        case scalar(String)
        case list([Value])
        case mapping([String: Value])
    }

    private static func parseMapping(_ lines: [String], indent: Int, context: String) throws -> [String: Value] {
        var result: [String: Value] = [:]
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.isEmpty { i += 1; continue }
            let leading = line.prefix(while: { $0 == " " }).count
            if leading < indent { break }  // exited this mapping
            if leading > indent {
                throw ConfigError.parseError("Unexpected indent at line \(i + 1) (\(context))")
            }
            let content = String(line.dropFirst(indent))
            guard let colon = content.firstIndex(of: ":") else {
                throw ConfigError.parseError("Expected ':' at line \(i + 1) (\(context))")
            }
            let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                // Nested mapping or list — look at next non-empty line's indent
                var j = i + 1
                while j < lines.count && lines[j].isEmpty { j += 1 }
                if j < lines.count {
                    let nextIndent = lines[j].prefix(while: { $0 == " " }).count
                    if nextIndent > indent {
                        // Look ahead to see if it's a list (starts with "-") or mapping
                        let firstNonEmpty = lines[j].dropFirst(nextIndent)
                        if firstNonEmpty.hasPrefix("- ") || firstNonEmpty == "-" {
                            let (list, consumed) = try parseList(lines, startFrom: i + 1, baseIndent: nextIndent, context: key)
                            result[key] = .list(list)
                            i = i + 1 + consumed
                            continue
                        } else {
                            let (map, consumed) = try parseMappingLines(lines, startFrom: i + 1, baseIndent: nextIndent, context: key)
                            result[key] = .mapping(map)
                            i = i + 1 + consumed
                            continue
                        }
                    }
                }
                result[key] = .scalar("")
            } else {
                result[key] = .scalar(unquote(rest))
            }
            i += 1
        }
        return result
    }

    private static func parseMappingLines(_ lines: [String], startFrom: Int, baseIndent: Int, context: String) throws -> ([String: Value], Int) {
        // Find the slice of lines at baseIndent
        var slice: [String] = []
        var consumed = 0
        for j in startFrom..<lines.count {
            let line = lines[j]
            if line.isEmpty { slice.append(line); consumed += 1; continue }
            let leading = line.prefix(while: { $0 == " " }).count
            if leading < baseIndent { break }
            slice.append(line)
            consumed += 1
        }
        let map = try parseMapping(slice, indent: baseIndent, context: context)
        return (map, consumed)
    }

    private static func parseList(_ lines: [String], startFrom: Int, baseIndent: Int, context: String) throws -> ([Value], Int) {
        var items: [Value] = []
        var j = startFrom
        while j < lines.count {
            let line = lines[j]
            if line.isEmpty { j += 1; continue }
            let leading = line.prefix(while: { $0 == " " }).count
            if leading < baseIndent { break }
            let content = String(line.dropFirst(baseIndent))
            guard content.hasPrefix("- ") else { break }
            let afterDash = String(content.dropFirst(2))
            if afterDash.isEmpty {
                // Nested mapping follows
                var k = j + 1
                while k < lines.count && lines[k].isEmpty { k += 1 }
                if k < lines.count {
                    let nextIndent = lines[k].prefix(while: { $0 == " " }).count
                    if nextIndent > baseIndent {
                        let (map, consumed) = try parseMappingLines(lines, startFrom: k, baseIndent: nextIndent, context: "\(context)[\(items.count)]")
                        items.append(.mapping(map))
                        j = k + consumed
                        continue
                    }
                }
                items.append(.scalar(""))
            } else if afterDash.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                // "- key:" — nested mapping starts on the same line
                let key = String(afterDash.trimmingCharacters(in: .whitespaces).dropLast()).trimmingCharacters(in: .whitespaces)
                var k = j + 1
                while k < lines.count && lines[k].isEmpty { k += 1 }
                if k < lines.count {
                    let nextIndent = lines[k].prefix(while: { $0 == " " }).count
                    if nextIndent > baseIndent + 2 {
                        let (map, consumed) = try parseMappingLines(lines, startFrom: k, baseIndent: nextIndent, context: "\(context)[\(items.count)].\(key)")
                        var combined: [String: Value] = [:]
                        combined[key] = .mapping(map)
                        items.append(.mapping(combined))
                        j = k + consumed
                        continue
                    }
                }
                items.append(.mapping([key: .scalar("")]))
            } else {
                items.append(.scalar(unquote(afterDash)))
            }
            j += 1
        }
        return (items, j - startFrom)
    }

    private static func unquote(_ s: String) -> String {
        var str = s.trimmingCharacters(in: .whitespaces)
        if (str.hasPrefix("\"") && str.hasSuffix("\"") && str.count >= 2) ||
           (str.hasPrefix("'") && str.hasSuffix("'") && str.count >= 2) {
            str = String(str.dropFirst().dropLast())
        }
        return str
    }

    // MARK: - Build WebAppConfig

    private static func buildConfig(from top: [String: Value], sourceURL: URL) throws -> WebAppConfig {
        func getString(_ key: String) throws -> String {
            guard case .scalar(let s)? = top[key] else {
                throw ConfigError.missingRequiredField(key)
            }
            return s
        }
        func getInt(_ key: String) throws -> Int {
            guard case .scalar(let s)? = top[key] else {
                throw ConfigError.missingRequiredField(key)
            }
            return Int(s) ?? 0
        }
        func getStringOpt(_ key: String) -> String? {
            if case .scalar(let s)? = top[key], !s.isEmpty { return s }
            return nil
        }

        let bundleId = Bundle.main.bundleIdentifier ?? "com.example.unknown"
        let dataDir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent(bundleId, isDirectory: true).path) ?? "~/Library/Application Support/\(bundleId)"
        let logsDir = (try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Logs", isDirectory: true).appendingPathComponent(bundleId, isDirectory: true).path) ?? "~/Library/Logs/\(bundleId)"
        let cacheDir = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent(bundleId, isDirectory: true).path) ?? "~/Library/Caches/\(bundleId)"
        let appDir = (Bundle.main.resourcePath ?? "") + "/app"

        // Parse start_command. It can be either a YAML list or a single string.
        var startCommand: [String] = []
        if case .list(let items)? = top["start_command"] {
            for v in items {
                if case .scalar(let s) = v { startCommand.append(s) }
            }
        } else if let s = getStringOpt("start_command") {
            // Split on whitespace, respecting simple quoting
            startCommand = s.split(separator: " ").map { String($0) }
        }

        // Parse env
        var env: [String: String] = [:]
        if case .mapping(let m)? = top["env"] {
            for (k, v) in m {
                if case .scalar(let s) = v { env[k] = s }
            }
        }

        // Parse first_run
        var firstRun: [FirstRunItem] = []
        if case .list(let items)? = top["first_run"] {
            for v in items {
                guard case .mapping(let m) = v else { continue }
                let id = (m["id"].flatMap { if case .scalar(let s) = $0 { return s } else { return nil } }) ?? ""
                let title = (m["title"].flatMap { if case .scalar(let s) = $0 { return s } else { return nil } }) ?? ""
                let desc = m["description"].flatMap { if case .scalar(let s) = $0 { return s } else { return nil } }
                let type = (m["type"].flatMap { if case .scalar(let s) = $0 { return s } else { return nil } }) ?? "text"
                let required = m["required"].flatMap { if case .scalar(let s) = $0 { return s == "true" } else { return nil } } ?? false
                let envName = m["env"].flatMap { if case .scalar(let s) = $0 { return s } else { return nil } }
                firstRun.append(FirstRunItem(id: id, title: title, description: desc, type: type, required: required, env: envName))
            }
        }

        // Parse health_check
        var healthCheck: WebAppConfig.HealthCheck? = nil
        if case .mapping(let m)? = top["health_check"] {
            let url = (m["url"].flatMap { if case .scalar(let s) = $0 { return s } else { return nil } }) ?? "/"
            let status = (m["expected_status"].flatMap { if case .scalar(let s) = $0 { return Int(s) ?? 200 } else { return nil } }) ?? 200
            let timeout = (m["timeout_seconds"].flatMap { if case .scalar(let s) = $0 { return Int(s) ?? 30 } else { return nil } }) ?? 30
            healthCheck = WebAppConfig.HealthCheck(url: url, expectedStatus: status, timeoutSeconds: timeout)
        }

        return WebAppConfig(
            name: try getString("name"),
            displayName: (top["display_name"].flatMap { if case .scalar(let s) = $0 { return s.isEmpty ? nil : s } else { return nil } }) ?? (try? getString("name")) ?? "App",
            bundleId: bundleId,
            version: (top["version"].flatMap { if case .scalar(let s) = $0 { return s.isEmpty ? nil : s } else { return nil } }) ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"),
            runtime: (top["runtime"].flatMap { if case .scalar(let s) = $0 { return s.isEmpty ? nil : s } else { return nil } }) ?? "python",
            port: try getInt("port"),
            url: (top["url"].flatMap { if case .scalar(let s) = $0 { return s.isEmpty ? "/" : s } else { return nil } }) ?? "/",
            startCommand: startCommand,
            healthCheck: healthCheck,
            env: env,
            firstRun: firstRun,
            updateFeed: getStringOpt("update_feed"),
            dataDir: dataDir,
            logsDir: logsDir,
            cacheDir: cacheDir,
            appDir: appDir,
            configPath: sourceURL.path
        )
    }
}
