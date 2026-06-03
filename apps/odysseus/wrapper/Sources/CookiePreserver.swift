// CookiePreserver.swift — persists WKWebView cookies across app restarts.
//
// Problem: Sparkle updates kill the app with SIGKILL. WebKit's SQLite
// cookie database can be left in a corrupt state. On relaunch WebKit
// may rebuild the data store from scratch, losing session cookies.
// Result: user is logged out and has to re-enter credentials.
//
// Fix: periodically snapshot all cookies from WKHTTPCookieStore to a
// JSON file in ~/Library/Application Support/<bundle_id>/saved_cookies.json.
// On app launch (before loading any URL), restore those cookies so the
// user's session survives updates.

import Foundation
import WebKit

final class CookiePreserver {
    private let webView: WKWebView
    private let savePath: URL
    private var saveTimer: Timer?

    /// - Parameters:
    ///   - webView: the WKWebView whose cookie store we mirror
    ///   - dataDir: the app's DATA_DIR (e.g. ~/Library/Application Support/<bundle_id>)
    init(webView: WKWebView, dataDir: String) {
        self.webView = webView
        self.savePath = URL(fileURLWithPath: dataDir).appendingPathComponent("saved_cookies.json")
    }

    /// Start the periodic snapshot (every 30 s) and perform an immediate restore.
    func start() {
        restoreCookies()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.saveCookies()
        }
    }

    /// Stop the timer and perform a final save.
    func stop() {
        saveTimer?.invalidate()
        saveCookies()
    }

    // MARK: - Save

    func saveCookies() {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let serializable = cookies.map { c in
                var dict: [String: Any] = [
                    "name":  c.name,
                    "value": c.value,
                    "domain": c.domain,
                    "path":  c.path,
                    "secure": c.isSecure,
                    "httponly": c.isHTTPOnly
                ]
                if let exp = c.expiresDate {
                    dict["expires"] = exp.timeIntervalSince1970
                }
                return dict
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: serializable, options: [.prettyPrinted])
                try data.write(to: self.savePath, options: .atomic)
            } catch {
                NSLog("[CookiePreserver] save failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Restore

    func restoreCookies() {
        guard FileManager.default.fileExists(atPath: savePath.path) else { return }
        do {
            let data = try Data(contentsOf: savePath)
            guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            let store = webView.configuration.websiteDataStore.httpCookieStore
            var restored = 0
            for item in items {
                guard let name  = item["name"]  as? String,
                      let value = item["value"] as? String,
                      let domain = item["domain"] as? String,
                      let path  = item["path"]  as? String else { continue }

                var props: [HTTPCookiePropertyKey: Any] = [
                    .name:   name,
                    .value:  value,
                    .domain: domain,
                    .path:   path
                ]
                if let secure = item["secure"] as? Bool, secure {
                    props[.secure] = true
                }
                if let httpOnly = item["httponly"] as? Bool, httpOnly {
                    // HTTPCookie doesn't have a direct .httponly property key,
                    // but we set it via the port list trick or just ignore it.
                    // For our use-case (127.0.0.1) httpOnly isn't critical.
                }
                if let expTimestamp = item["expires"] as? TimeInterval {
                    props[.expires] = Date(timeIntervalSince1970: expTimestamp)
                }

                if let cookie = HTTPCookie(properties: props) {
                    store.setCookie(cookie) { /* no-op completion */ }
                    restored += 1
                }
            }
            NSLog("[CookiePreserver] restored \(restored) cookie(s)")
        } catch {
            NSLog("[CookiePreserver] restore failed: \(error.localizedDescription)")
        }
    }
}
