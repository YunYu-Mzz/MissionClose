import Cocoa
import ApplicationServices

/// Read-only diagnostic: `open -n -a MissionClose.app --args --probe`
/// Dumps what the accessibility API exposes for every regular app's windows, the on-screen window list,
/// and (if Mission Control is open) its thumbnails, to ~/Library/Logs/MissionClose-probe.txt, then exits.
/// It only reads attributes; it never presses, sets or closes anything.
enum Probe {
    static let outURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MissionClose-probe.txt")

    private static func names(_ e: AXUIElement) -> [String] {
        var arr: CFArray?
        guard AXUIElementCopyAttributeNames(e, &arr) == .success else { return [] }
        return (arr as? [String]) ?? []
    }

    private static func actions(_ e: AXUIElement) -> [String] {
        var arr: CFArray?
        guard AXUIElementCopyActionNames(e, &arr) == .success else { return [] }
        return (arr as? [String]) ?? []
    }

    private static func describe(_ v: AnyObject?) -> String {
        guard let v else { return "nil" }
        if let s = v as? String { return "\"\(s)\"" }
        if let n = v as? NSNumber { return "\(n)" }
        if CFGetTypeID(v) == AXUIElementGetTypeID() { return "<AXUIElement>" }
        if CFGetTypeID(v) == AXValueGetTypeID() { return "\(v)" }
        if let a = v as? [AnyObject] { return "[\(a.count) items]" }
        return "\(type(of: v))"
    }

    /// Every attribute of an element, one "name=value" per entry.
    private static func dumpAttributes(_ e: AXUIElement) -> String {
        names(e).filter { $0 != kAXChildrenAttribute as String && $0 != kAXParentAttribute as String }
            .map { "\($0)=\(describe(e.value($0)))" }.joined(separator: "  ")
    }

    static func run() {
        var out: [String] = ["# MissionClose probe  \(Date())", "AXIsProcessTrusted = \(AXIsProcessTrusted())",
                            "Executable = \(Bundle.main.executablePath ?? CommandLine.arguments[0])",
                            "PID = \(getpid()), parent PID = \(getppid())",
                            "Mode = \(CommandLine.arguments.contains("--probe") ? "command-line probe" : "running app menu")",
                            "A shell-launched probe may inherit the launcher's TCC context. Use the running app menu to verify its own permission.", ""]

        out.append("## Apps and the windows the accessibility API reports")
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 1.0)
            var raw: AnyObject?
            let err = AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &raw)
            let reported = raw as? [AXUIElement] ?? []
            let wins = WindowIndex.appWindows(ax)
            out.append("APP \(app.localizedName ?? "?")  bundle=\(app.bundleIdentifier ?? "?")  pid=\(app.processIdentifier)  AXWindows err=\(err.rawValue) count=\(reported.count) withFallbacks=\(wins.count)")
            let interesting = wins.isEmpty
                || (app.bundleIdentifier ?? "").lowercased().contains("tencent")
                || (app.bundleIdentifier ?? "").contains("Terminal")
            if interesting {
                out.append("   app attrs: \(dumpAttributes(ax))")
            }
            for w in wins {
                var cb: AnyObject?
                let cbErr = AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &cb)
                var line = "   WIN role=\(w.role ?? "nil") subrole=\(w.subrole ?? "nil") title=\"\(w.title ?? "nil")\""
                line += " frame=\(w.frame.map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "nil")"
                line += " minimized=\((w.value(kAXMinimizedAttribute) as? Bool).map(String.init) ?? "nil")"
                line += " closeButton: err=\(cbErr.rawValue) present=\(cb != nil)"
                line += " windowID=\(w.windowID.map(String.init) ?? "nil")"
                out.append(line)
                if interesting || w.subrole != kAXStandardWindowSubrole as String {
                    out.append("      attrs: \(dumpAttributes(w))")
                }
            }
        }

        out.append("")
        out.append("## On-screen windows at layer 0 (CGWindowList)")
        let cg = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        for w in cg where (w[kCGWindowLayer as String] as? Int) == 0 {
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            out.append("  #\(w[kCGWindowNumber as String] ?? "?") [\(w[kCGWindowOwnerName as String] ?? "?")] pid=\(w[kCGWindowOwnerPID as String] ?? "?") "
                       + "\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) name=\"\(w[kCGWindowName as String] ?? "")\"")
        }

        out.append("")
        out.append("## Mission Control thumbnails")
        if let mc = MissionControl.root() {
            let index = WindowIndex.all()
            out.append("MC root: \(dumpAttributes(mc))")
            for t in MissionControl.thumbnails(in: mc) {
                out.append("  THUMB title=\"\(t.title ?? "nil")\" id=\(t.identifier ?? "nil") frame=\(t.frame.map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "nil")")
                out.append("      attrs: \(dumpAttributes(t))")
                out.append("      actions: \(actions(t))")
                let identity = WindowIndex.identity(of: t)
                let match = WindowIndex.match(t, in: index, identity: identity)
                out.append("      ownerPID=\(identity.processID.map(String.init) ?? "nil") windowID=\(identity.windowID.map(String.init) ?? "nil") matched=\(match.map { "\($0.app.bundleIdentifier ?? "?") #\($0.windowID.map(String.init) ?? "nil")" } ?? "none (no safe match)")")
            }
        } else {
            out.append("Mission Control is not open (or its accessibility tree is not readable).")
        }

        do {
            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
        } catch {
            Diagnostics.log("Could not write probe: \(error)")
        }
    }
}
