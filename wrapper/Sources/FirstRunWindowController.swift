// FirstRunWindowController.swift — native macOS wizard for first-run setup.
//
// Shown by the wrapper when ~/Library/Application Support/<bundle_id>/app.db
// doesn't exist. The wizard collects the admin username and password,
// validates them, and runs setup.py with the credentials as env vars.
//
// On success, the wizard dismisses itself and the wrapper proceeds to start
// the server. On failure, the wizard shows the error and lets the user retry
// or quit.

import Cocoa

/// Result of a successful first-run setup.
struct FirstRunResult {
    let username: String
    let password: String
}

final class FirstRunWindowController: NSWindowController, NSTextFieldDelegate {

    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let usernameField: NSTextField
    private let usernameError: NSTextField
    private let passwordField: NSSecureTextField
    private let passwordError: NSTextField
    private let confirmField: NSSecureTextField
    private let confirmError: NSTextField
    private let errorLabel: NSTextField
    private let createButton: NSButton
    private let quitButton: NSButton
    private let progressIndicator: NSProgressIndicator

    /// Called when setup completes successfully. The wrapper dismisses the
    /// wizard and starts the server.
    var onComplete: ((FirstRunResult) -> Void)?

    /// Called when the user clicks Quit.
    var onCancel: (() -> Void)?

    private var isRunning = false

    init(appName: String, bundleId: String, dataDir: String) {
        let rect = NSRect(x: 0, y: 0, width: 480, height: 540)
        let style: NSWindow.StyleMask = [.titled, .closable]
        let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.title = "Welcome to \(appName)"
        window.isReleasedWhenClosed = false
        window.center()

        let container = NSView(frame: rect)
        container.autoresizingMask = [.width, .height]

        // Title
        titleLabel = NSTextField(labelWithString: "Create your admin account")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.frame = NSRect(x: 24, y: 488, width: 432, height: 24)
        titleLabel.autoresizingMask = [.width, .minYMargin]
        container.addSubview(titleLabel)

        // Subtitle
        subtitleLabel = NSTextField(labelWithString: "This is a one-time setup. Your credentials will be stored locally in \(dataDir).")
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.cell?.wraps = true
        subtitleLabel.cell?.lineBreakMode = .byWordWrapping
        subtitleLabel.frame = NSRect(x: 24, y: 446, width: 432, height: 32)
        subtitleLabel.autoresizingMask = [.width, .minYMargin]
        container.addSubview(subtitleLabel)

        // Username
        let usernameLabel = NSTextField(labelWithString: "Username")
        usernameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        usernameLabel.textColor = .secondaryLabelColor
        usernameLabel.frame = NSRect(x: 24, y: 396, width: 432, height: 16)
        container.addSubview(usernameLabel)

        usernameField = NSTextField(frame: NSRect(x: 24, y: 364, width: 432, height: 24))
        usernameField.placeholderString = "admin"
        usernameField.font = NSFont.systemFont(ofSize: 13)
        usernameField.autoresizingMask = [.width]
        usernameField.delegate = nil  // we'll set in init below
        container.addSubview(usernameField)

        usernameError = NSTextField(labelWithString: "")
        usernameError.font = NSFont.systemFont(ofSize: 10)
        usernameError.textColor = .systemRed
        usernameError.frame = NSRect(x: 24, y: 346, width: 432, height: 14)
        usernameError.autoresizingMask = [.width]
        container.addSubview(usernameError)

        // Password
        let passwordLabel = NSTextField(labelWithString: "Password")
        passwordLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        passwordLabel.textColor = .secondaryLabelColor
        passwordLabel.frame = NSRect(x: 24, y: 308, width: 432, height: 16)
        container.addSubview(passwordLabel)

        passwordField = NSSecureTextField(frame: NSRect(x: 24, y: 276, width: 432, height: 24))
        passwordField.placeholderString = "At least 8 characters"
        passwordField.font = NSFont.systemFont(ofSize: 13)
        passwordField.autoresizingMask = [.width]
        container.addSubview(passwordField)

        passwordError = NSTextField(labelWithString: "")
        passwordError.font = NSFont.systemFont(ofSize: 10)
        passwordError.textColor = .systemRed
        passwordError.frame = NSRect(x: 24, y: 258, width: 432, height: 14)
        passwordError.autoresizingMask = [.width]
        container.addSubview(passwordError)

        // Confirm password
        let confirmLabel = NSTextField(labelWithString: "Confirm password")
        confirmLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        confirmLabel.textColor = .secondaryLabelColor
        confirmLabel.frame = NSRect(x: 24, y: 220, width: 432, height: 16)
        container.addSubview(confirmLabel)

        confirmField = NSSecureTextField(frame: NSRect(x: 24, y: 188, width: 432, height: 24))
        confirmField.placeholderString = "Type the password again"
        confirmField.font = NSFont.systemFont(ofSize: 13)
        confirmField.autoresizingMask = [.width]
        container.addSubview(confirmField)

        confirmError = NSTextField(labelWithString: "")
        confirmError.font = NSFont.systemFont(ofSize: 10)
        confirmError.textColor = .systemRed
        confirmError.frame = NSRect(x: 24, y: 170, width: 432, height: 14)
        confirmError.autoresizingMask = [.width]
        container.addSubview(confirmError)

        // Error label (top-level)
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 4
        errorLabel.cell?.wraps = true
        errorLabel.cell?.lineBreakMode = .byWordWrapping
        errorLabel.frame = NSRect(x: 24, y: 110, width: 432, height: 50)
        errorLabel.autoresizingMask = [.width, .minYMargin]
        container.addSubview(errorLabel)

        // Progress
        progressIndicator = NSProgressIndicator(frame: NSRect(x: 24, y: 86, width: 16, height: 16))
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.isHidden = true
        container.addSubview(progressIndicator)

        // Buttons
        quitButton = NSButton(title: "Quit", target: nil, action: nil)
        quitButton.bezelStyle = .rounded
        quitButton.frame = NSRect(x: 24, y: 24, width: 80, height: 32)
        container.addSubview(quitButton)

        createButton = NSButton(title: "Create Admin Account", target: nil, action: nil)
        createButton.bezelStyle = .rounded
        createButton.frame = NSRect(x: 348, y: 24, width: 108, height: 32)
        createButton.autoresizingMask = [.minXMargin]
        createButton.keyEquivalent = "\r"  // Enter
        container.addSubview(createButton)

        window.contentView = container
        super.init(window: window)

        // Now safe to reference self
        quitButton.target = self
        quitButton.action = #selector(quitClicked)
        createButton.target = self
        createButton.action = #selector(createClicked)

        // Make the username field the first responder
        window.initialFirstResponder = usernameField
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public API

    /// Show the wizard (as a standalone window — there's no main window yet
    /// at first-run time).
    func present() {
        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Enable/disable the form while setup is running.
    func setRunning(_ running: Bool) {
        isRunning = running
        usernameField.isEnabled = !running
        passwordField.isEnabled = !running
        confirmField.isEnabled = !running
        createButton.isEnabled = !running
        quitButton.isEnabled = !running
        if running {
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.isHidden = true
            progressIndicator.stopAnimation(nil)
        }
    }

    /// Show a top-level error (e.g. setup.py failed).
    func showError(_ message: String) {
        errorLabel.stringValue = message
    }

    /// Show field-level validation errors.
    private func showFieldErrors(username: String?, password: String?, confirm: String?) {
        usernameError.stringValue = username ?? ""
        passwordError.stringValue = password ?? ""
        confirmError.stringValue = confirm ?? ""
    }

    // MARK: - Actions

    @objc private func createClicked() {
        guard !isRunning else { return }
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue
        let confirm = confirmField.stringValue

        // Validate
        var usernameError: String?
        var passwordError: String?
        var confirmError: String?

        if username.isEmpty {
            usernameError = "Username is required"
        } else if username.count < 3 {
            usernameError = "Username must be at least 3 characters"
        } else if username.contains(" ") {
            usernameError = "Username cannot contain spaces"
        }

        if password.isEmpty {
            passwordError = "Password is required"
        } else if password.count < 8 {
            passwordError = "Password must be at least 8 characters"
        }

        if confirm != password {
            confirmError = "Passwords do not match"
        }

        if usernameError != nil || passwordError != nil || confirmError != nil {
            showFieldErrors(username: usernameError, password: passwordError, confirm: confirmError)
            errorLabel.stringValue = ""
            return
        }

        showFieldErrors(username: nil, password: nil, confirm: nil)
        errorLabel.stringValue = ""
        setRunning(true)
        onComplete?(FirstRunResult(username: username, password: password))
    }

    @objc private func quitClicked() {
        onCancel?()
    }
}
