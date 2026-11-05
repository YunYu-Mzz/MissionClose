import AppKit

/// Checks GitHub for a newer release: when you click Updates → Check Now, or once a day if you've
/// turned on Check Automatically (off by default). MissionClose makes no other network connections.
enum UpdateCheck {
    private static let latestAPI = URL(string: "https://api.github.com/repos/YunYu-Mzz/MissionClose/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/YunYu-Mzz/MissionClose/releases/latest")!
    private static let cask = "missionclose"
    private static let interval: TimeInterval = 24 * 60 * 60

    enum Key {
        static let automatic = "checkForUpdatesAutomatically"
        static let lastCheck = "lastUpdateCheck"
        static let lastNotified = "lastNotifiedVersion"
    }

    private static var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Installed with Homebrew? Then updating means `brew upgrade`, not a download.
    static var installedWithHomebrew: Bool {
        // This fork has no Homebrew cask. An upstream installation must not redirect fork updates.
        false
    }

    /// Starts (or stops) the daily background check to match the setting. Safe to call repeatedly.
    static func scheduleAutomaticChecks() {
        timer?.invalidate()
        timer = nil
        guard UserDefaults.standard.bool(forKey: Key.automatic) else { return }
        checkIfDue()
        // Checking hourly whether a day has passed copes with sleep and long uptimes.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in checkIfDue() }
    }

    private static func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: Key.lastCheck) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= interval { run(userInitiated: false) }
    }

    /// User-initiated checks always report back. Automatic ones stay silent unless there's a version
    /// they haven't already mentioned.
    static func run(userInitiated: Bool) {
        var request = URLRequest(url: latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MissionClose/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if userInitiated {
                        show(title: "Couldn't check for updates",
                             message: error?.localizedDescription ?? "GitHub didn't return a release.", latest: nil)
                    }
                    return
                }
                UserDefaults.standard.set(Date(), forKey: Key.lastCheck)
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if isNewer(latest, than: currentVersion) {
                    let defaults = UserDefaults.standard
                    guard userInitiated || defaults.string(forKey: Key.lastNotified) != latest else { return }
                    defaults.set(latest, forKey: Key.lastNotified)
                    show(title: "MissionClose \(latest) is available",
                         message: installedWithHomebrew
                            ? "You have \(currentVersion). Update with:\n\nbrew upgrade --cask \(cask)"
                            : "You have \(currentVersion). Settings are retained; Accessibility permission may need to be granted again.",
                         latest: latest)
                } else if userInitiated {
                    show(title: "You're up to date", message: "MissionClose \(currentVersion) is the latest version.", latest: nil)
                }
            }
        }.resume()
    }

    /// Compares dotted numeric versions: 1.10.0 is newer than 1.9.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func show(title: String, message: String, latest: String?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if latest == nil {
            alert.addButton(withTitle: "OK")
        } else if installedWithHomebrew {
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "What's New")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard latest != nil else { return }
        if installedWithHomebrew {
            if response == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew upgrade --cask \(cask)", forType: .string)
            } else if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(releasesPage)
            }
        } else if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releasesPage)
        }
    }
}
