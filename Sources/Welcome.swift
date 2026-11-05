import Cocoa
import ApplicationServices

/// Shown on first launch, and whenever Accessibility access is missing. Without that access the app
/// does nothing at all, and a bare system prompt doesn't explain why it's being asked for.
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private let statusLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    var onShowSettings: ((NSView) -> Void)?

    static let shared = WelcomeWindow()

    func showIfNeeded() {
        let firstRun = !UserDefaults.standard.bool(forKey: "didShowWelcome")
        guard firstRun || !AXIsProcessTrusted() else { return }
        UserDefaults.standard.set(true, forKey: "didShowWelcome")
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MissionClose"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = makeContent()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        refresh()
        // Keep permission state current while this window is visible.
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func makeContent() -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 430))

        let icon = NSImageView(frame: NSRect(x: 190, y: 320, width: 80, height: 80))
        icon.image = NSApp.applicationIconImage
        content.addSubview(icon)

        let title = NSTextField(labelWithString: "Close windows from Mission Control")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 30, y: 282, width: 400, height: 26)
        content.addSubview(title)

        let body = NSTextField(wrappingLabelWithString: """
        Open Mission Control and hover a window, then click the large ✕ to close it. \
        Hold ⌥ to quit its app, or use ⌘W and ⌘Q.

        Allow Accessibility access so MissionClose can control windows. \
        Diagnostics stay on your Mac; update checks use GitHub.
        """)
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.frame = NSRect(x: 40, y: 150, width: 380, height: 120)
        content.addSubview(body)

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 30, y: 112, width: 400, height: 20)
        content.addSubview(statusLabel)

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.target = self
        actionButton.action = #selector(openSettings)
        actionButton.keyEquivalent = "\r"
        actionButton.frame = NSRect(x: 62, y: 58, width: 220, height: 32)
        content.addSubview(actionButton)

        let settingsButton = NSButton(title: "Settings…", target: self, action: #selector(showSettings(_:)))
        settingsButton.bezelStyle = .rounded
        settingsButton.controlSize = .large
        settingsButton.frame = NSRect(x: 294, y: 58, width: 104, height: 32)
        content.addSubview(settingsButton)

        let hint = NSTextField(labelWithString: "Runs in the background. Reopen MissionClose for settings.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 30, y: 28, width: 400, height: 16)
        content.addSubview(hint)

        return content
    }

    private func refresh() {
        if AXIsProcessTrusted() {
            statusLabel.stringValue = "Accessibility access granted. You're all set."
            statusLabel.textColor = .systemGreen
            actionButton.title = "Done"
            actionButton.action = #selector(close)
        } else {
            statusLabel.stringValue = "Waiting for Accessibility access…"
            statusLabel.textColor = .secondaryLabelColor
            actionButton.title = "Open Accessibility Settings"
            actionButton.action = #selector(openSettings)
        }
    }

    @objc private func openSettings() {
        // Ask the system first: if the app has never been added, this puts it in the list.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func close() {
        window?.close()
    }

    @objc private func showSettings(_ sender: NSButton) {
        onShowSettings?(sender)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        window = nil
    }
}
