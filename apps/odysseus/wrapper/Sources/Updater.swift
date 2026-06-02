// Updater.swift — wraps Sparkle's SPUUpdater for in-app auto-updates.
//
// Flow:
//   1. On `start()`, we set up an SPUUpdater. The feed URL and public key
//      are read from the .app's Info.plist (SUFeedURL and SUPublicEDKey).
//   2. Sparkle checks for updates automatically per the user's system
//      preference (typically daily).
//   3. The user can also trigger a manual check via the Help menu's
//      "Check for Updates…" item, which calls `checkForUpdates()`.
//
// Sparkle 2.x is the dependency; this wrapper provides:
//   - a single point of control
//   - consistent NSLog formatting for update events
//   - a no-op path when `update_feed` is not configured
//   - delegate methods that we can hook into for analytics or testing

import Foundation
import Sparkle

final class Updater: NSObject, SPUUpdaterDelegate {

    private let config: WebAppConfig
    private var updater: SPUUpdater?

    // Notification name posted when an update is found. Other code can
    // listen for this (e.g. to show a custom UI). For v1.1 we just log.
    static let didFindUpdateNotification = Notification.Name("UpdaterDidFindUpdate")

    init(config: WebAppConfig) {
        self.config = config
        super.init()
    }

    /// Initialize the updater. Call this once after the app is up and
    /// running. The updater schedules automatic background checks per
    /// the user's system preference.
    func start() {
        // The feed URL is set in Info.plist (SUFeedURL) by the build
        // pipeline. We just log the value here for diagnostic purposes.
        guard let feedURLString = config.updateFeed, !feedURLString.isEmpty else {
            NSLog("[\(config.name)] Updater: no update_feed configured; updates disabled")
            return
        }
        NSLog("[\(config.name)] Updater: starting (feed=\(feedURLString))")

        // SPUUpdater needs a host bundle. The main bundle of our wrapper
        // .app is what Sparkle reads the SUPublicEDKey from, so this is
        // correct.
        guard let host = Bundle.main.hostBundle else {
            NSLog("[\(config.name)] Updater: bundle is not a proper .app; updates disabled")
            return
        }
        NSLog("[\(config.name)] Updater: host bundle = \(host.bundleURL.path)")

        // Listen for Sparkle's notifications. The delegate methods
        // are flaky to wire up in Swift (selector-renamed issues), so
        // we use the NSNotification approach which is rock-solid.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onAppcastLoaded(_:)),
                       name: NSNotification.Name("SUUpdaterDidFinishLoadingAppCastNotification"), object: nil)
        nc.addObserver(self, selector: #selector(onUpdateFound(_:)),
                       name: NSNotification.Name("SUUpdaterDidFindValidUpdateNotification"), object: nil)
        nc.addObserver(self, selector: #selector(onNoUpdateFound(_:)),
                       name: NSNotification.Name("SUUpdaterDidNotFindUpdateNotification"), object: nil)
        // Catch-all: log ANY notification from Sparkle so we can debug
        nc.addObserver(forName: nil, object: nil, queue: nil) { n in
            if n.name.rawValue.contains("Updater") || n.name.rawValue.contains("parkle") {
                NSLog("[\(self.config.name)] Sparkle notification: \(n.name.rawValue) userInfo: \(n.userInfo?.debugDescription ?? "nil")")
            }
        }

        // SPUStandardUserDriver is Sparkle's default UI. It shows the
        // standard "Update available" / "Release notes" / "Install and
        // Relaunch" sheets. We can subclass it for custom UI in the future.
        let driver = SPUStandardUserDriver(hostBundle: host, delegate: nil)
        let u = SPUUpdater(hostBundle: host, applicationBundle: Bundle.main, userDriver: driver, delegate: nil)
        // feedURL is read from Info.plist's SUFeedURL automatically.
        // Sparkle defaults to a 24-hour check interval; we keep that.
        u.automaticallyChecksForUpdates = true
        u.automaticallyDownloadsUpdates = false   // user must confirm install

        // IMPORTANT: must call start() on the SPUUpdater before
        // any other method (including checkForUpdates). Without this,
        // Sparkle silently does nothing.
        do {
            try u.start()
        } catch {
            NSLog("[\(config.name)] Updater: start() failed: \(error.localizedDescription)")
            return
        }
        self.updater = u

        NSLog("[\(config.name)] Updater: SPUUpdater started, feedURL=\(u.feedURL?.absoluteString ?? "nil")")

        // Kick off an initial check now. We use checkForUpdatesInBackground
        // which is the recommended API for "force a check now, but don't
        // block the UI." Sparkle throttles subsequent automatic checks
        // per its updateCheckInterval, so this is a one-time initial check.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            NSLog("[\(self?.config.name ?? "?")] Updater: calling checkForUpdatesInBackground")
            self?.updater?.checkForUpdatesInBackground()
        }
    }

    // MARK: - Notification handlers

    @objc private func onAppcastLoaded(_ n: Notification) {
        if let appcast = n.userInfo?["SUUpdaterAppcastKey"] as? SUAppcast {
            NSLog("[\(config.name)] Updater: appcast loaded, \(appcast.items.count) item(s)")
        } else {
            NSLog("[\(config.name)] Updater: appcast loaded (item count unknown)")
        }
    }

    @objc private func onUpdateFound(_ n: Notification) {
        if let item = n.userInfo?["SUUpdaterAppcastItemNotificationKey"] as? SUAppcastItem {
            NSLog("[\(config.name)] Updater: found update v=\(item.displayVersionString) (build \(item.versionString))")
            NotificationCenter.default.post(
                name: Updater.didFindUpdateNotification,
                object: self,
                userInfo: ["version": item.displayVersionString]
            )
        } else {
            NSLog("[\(config.name)] Updater: found update (item unknown)")
        }
    }

    @objc private func onNoUpdateFound(_ n: Notification) {
        NSLog("[\(config.name)] Updater: no update available")
    }

    /// Trigger a user-initiated check. Sparkle shows its own UI
    /// ("Checking..." → "Update available" → "Install and Relaunch").
    func checkForUpdates() {
        guard let u = updater else {
            NSLog("[\(config.name)] Updater: not started; cannot check")
            return
        }
        NSLog("[\(config.name)] Updater: user-initiated check")
        u.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    @objc @MainActor
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let items = appcast.items
        NSLog("[\(config.name)] Updater: appcast loaded, \(items.count) item(s)")
    }

    @objc @MainActor
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // This fires when Sparkle has loaded the appcast and there's no
        // newer version. The error is non-nil on success (it's a "no
        // update" sentinel), per Sparkle's API.
        let ns = error as NSError
        if ns.code == SUError.noUpdateError.rawValue {
            NSLog("[\(config.name)] Updater: no update available")
        } else {
            NSLog("[\(config.name)] Updater: did not find update: \(error.localizedDescription)")
        }
    }

    @objc @MainActor
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("[\(config.name)] Updater: found update v=\(item.displayVersionString) (build \(item.versionString))")
        NotificationCenter.default.post(
            name: Updater.didFindUpdateNotification,
            object: self,
            userInfo: ["version": item.displayVersionString]
        )
    }

    @objc @MainActor
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        NSLog("[\(config.name)] Updater: will install v=\(item.displayVersionString) (user accepted)")
    }
}

// Bundle helper: returns the .app bundle that contains the current bundle.
// For our wrapper, the running binary is at Contents/MacOS/<app>, so
// the host bundle is Bundle.main (which sees the .app's Info.plist
// via NSBundle).
private extension Bundle {
    var hostBundle: Bundle? {
        // In a properly-constructed .app, Bundle.main IS the .app bundle.
        return self.bundleURL.pathExtension == "app" ? self : Bundle.main
    }
}
