import Cocoa

/// Writes to ~/Library/Logs/MissionClose.log when an action fails, so a beep can be explained
/// without reproducing it by hand. Nothing is logged while things work, and nothing leaves the Mac.
enum Diagnostics {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MissionClose.log")

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let maxBytes = 256 * 1024
    private static let lock = NSLock()

    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        trimIfNeeded()
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Keeps only the recent half once the log passes a quarter of a megabyte.
    private static func trimIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int,
              size > maxBytes, let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        let kept = text.suffix(text.count / 2)
        try? String(kept.drop(while: { $0 != "\n" }).dropFirst()).write(to: logURL, atomically: true, encoding: .utf8)
    }

    /// Everything known about a failed action, including the candidate windows that were considered.
    static func logFailure(action: String, label: String?, thumbnailSize: CGSize?, windows: [WindowRef], matched: WindowRef?) {
        var lines = ["\(action) failed  thumbnail=\(label.map { "\"\($0)\"" } ?? "nil") " +
                     "size=\(thumbnailSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")"]
        if let matched {
            lines.append("    matched [\(matched.app.localizedName ?? "?")] \"\(matched.title)\" " +
                         "but the action didn't take effect")
        } else {
            lines.append("    no matching window among \(windows.count) candidates:")
            for window in windows {
                lines.append("      [\(window.app.localizedName ?? "?")] \"\(window.title)\" " +
                             "live=\"\(window.window.title ?? "")\" " +
                             "size=\(Int(window.size.width))x\(Int(window.size.height))")
            }
        }
        log(lines.joined(separator: "\n"))
    }
}
