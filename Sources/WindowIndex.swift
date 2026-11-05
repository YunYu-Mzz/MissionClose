import Cocoa

struct WindowRef {
    let app: NSRunningApplication
    let window: AXUIElement
    let title: String
    let size: CGSize
    let windowID: CGWindowID?
    let appAliases: [String]
}

struct ThumbnailIdentity {
    let processID: pid_t?
    let windowID: CGWindowID?
    let bundleID: String?
}

enum WindowIndex {
    /// AXWindows is not consistently populated by every app. Main/focused windows and direct
    /// AXWindow children provide bounded, read-only fallbacks (never walk document contents).
    static func appWindows(_ app: AXUIElement) -> [AXUIElement] {
        var found = app.windows
        found += [app.element(kAXMainWindowAttribute), app.element(kAXFocusedWindowAttribute)].compactMap { $0 }
        found += app.children.filter { $0.role == kAXWindowRole as String }
        var seen = Set<ElementKey>()
        return found.filter { seen.insert(ElementKey(element: $0)).inserted }
    }

    static func all(processID: pid_t? = nil) -> [WindowRef] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                !app.isTerminated && (processID.map { app.processIdentifier == $0 }
                    ?? (app.activationPolicy == .regular))
            }
            .flatMap { app -> [WindowRef] in
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(axApp, 0.3)
                let bundle = app.bundleURL.flatMap { Bundle(url: $0) }
                let aliases = [bundle?.infoDictionary?["CFBundleName"] as? String,
                               bundle?.infoDictionary?["CFBundleDisplayName"] as? String,
                               app.executableURL?.deletingPathExtension().lastPathComponent].compactMap { $0 }
                return appWindows(axApp).compactMap { w in
                    guard w.role == kAXWindowRole as String,
                          (w.subrole == kAXStandardWindowSubrole as String || w.element(kAXCloseButtonAttribute) != nil),
                          (w.value(kAXMinimizedAttribute) as? Bool) != true,
                          let f = w.frame, f.width > 40, f.height > 40 else { return nil }
                    return WindowRef(app: app, window: w, title: w.title ?? "", size: f.size,
                                     windowID: w.windowID, appAliases: aliases)
                }
            }
    }

    /// CGWindowList reports the transformed window bounds while Mission Control is open.
    /// It exposes the real window ID and PID even without screen-recording access; no window
    /// names or images are needed. Use only a unique frame match, otherwise fall back conservatively.
    static func identity(of thumb: AXUIElement) -> ThumbnailIdentity {
        let bundleID: String? = thumb.identifier.flatMap { id in
            guard let range = id.range(of: ".space.", options: .backwards),
                  Int(id[range.upperBound...]) != nil else { return nil }
            return String(id[..<range.lowerBound])
        }
        if let frame = thumb.frame,
           let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] {
            let matches = info.filter { entry in
                guard entry[kCGWindowLayer as String] as? Int == 0,
                      let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                      let other = CGRect(dictionaryRepresentation: bounds) else { return false }
                return WindowMatching.sameFrame(frame, other)
            }
            if matches.count == 1,
               let pid = matches[0][kCGWindowOwnerPID as String] as? Int32,
               let id = matches[0][kCGWindowNumber as String] as? UInt32 {
                return ThumbnailIdentity(processID: pid, windowID: id, bundleID: bundleID)
            }
        }
        let pid = bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier }
        return ThumbnailIdentity(processID: pid, windowID: nil, bundleID: bundleID)
    }

    static func match(_ thumb: AXUIElement, in windows: [WindowRef], identity: ThumbnailIdentity? = nil) -> WindowRef? {
        guard let thumbFrame = thumb.frame else { return nil }
        let identity = identity ?? self.identity(of: thumb)
        let candidates = windows.map {
            WindowCandidate(title: $0.title, liveTitle: $0.window.title ?? $0.title,
                            appName: $0.app.localizedName ?? "", size: $0.size,
                            processID: $0.app.processIdentifier, windowID: $0.windowID,
                            bundleID: $0.app.bundleIdentifier, appAliases: $0.appAliases)
        }
        let aspect = thumbFrame.width / max(thumbFrame.height, 1)
        // Never discard a known CG window ID merely because AX failed to return it. That would
        // let an unrelated same-title window win precisely when the target is missing.
        guard let index = WindowMatching.bestMatch(label: thumb.title ?? "", thumbnailAspect: aspect, in: candidates,
                                                   processID: identity.processID,
                                                   windowID: identity.windowID,
                                                   bundleID: identity.bundleID) else { return nil }
        return windows[index]
    }
}
