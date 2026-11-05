import Foundation

/// What matching needs to know about a window, with no accessibility objects involved so the rules
/// can be tested on their own. `liveTitle` is re-read at match time; `title` was cached when
/// Mission Control opened, and the two differ for windows whose title changes (a terminal spinner,
/// a document marked edited).
struct WindowCandidate {
    let title: String
    let liveTitle: String
    let appName: String
    let size: CGSize
    let processID: Int32?
    let windowID: UInt32?
    let bundleID: String?
    let appAliases: [String]

    init(title: String, liveTitle: String? = nil, appName: String = "", size: CGSize = .zero,
         processID: Int32? = nil, windowID: UInt32? = nil, bundleID: String? = nil, appAliases: [String] = []) {
        self.title = title
        self.liveTitle = liveTitle ?? title
        self.appName = appName
        self.size = size
        self.processID = processID
        self.windowID = windowID
        self.bundleID = bundleID
        self.appAliases = appAliases
    }
}

enum WindowMatching {
    static func sameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }
    /// Mission Control labels a thumbnail with the window's title, or the app's name when a window has
    /// none. Returns the index of the best candidate, or nil when nothing plausibly matches.
    ///
    /// Rules are tried in order of confidence; ties are broken by whichever window's shape is closest
    /// to the thumbnail's.
    static func bestMatch(label: String, thumbnailAspect: CGFloat, in candidates: [WindowCandidate],
                          processID: Int32? = nil, windowID: UInt32? = nil, bundleID: String? = nil) -> Int? {
        let eligible = candidates.indices.filter {
            (processID == nil || candidates[$0].processID == processID)
                && (bundleID == nil || candidates[$0].bundleID == bundleID)
        }
        // A system window ID is stronger than any title or shape. Never substitute a different
        // window if that exact window has gone away or is absent from the AX tree.
        if let windowID {
            let exact = eligible.filter { candidates[$0].windowID == windowID }
            return exact.count == 1 ? exact[0] : nil
        }
        guard !label.isEmpty else { return nil }
        let rules: [(WindowCandidate) -> Bool] = [
            { $0.title == label },
            { $0.liveTitle == label },
            // Some apps put more in the title bar than Mission Control shows,
            // e.g. Preview's "photo.png – 2 documents, 2 total pages".
            { $0.title.hasPrefix(label) },
            { $0.liveTitle.hasPrefix(label) },
            // ...and the reverse: a label that carries a suffix the window's own title doesn't.
            { !$0.title.isEmpty && label.hasPrefix($0.title) },
            // Mission Control shortens long titles by cutting out the middle:
            // "beqaabu/MissionClose: Close w…from Mission Control on macOS".
            { matchesElided(label: label, title: $0.title) },
            { matchesElided(label: label, title: $0.liveTitle) },
            { (!$0.appName.isEmpty && $0.appName == label) || $0.appAliases.contains(label) },
        ]
        for rule in rules {
            let matches = eligible.filter { rule(candidates[$0]) }
            guard !matches.isEmpty else { continue }
            let ranked = matches.sorted { closeness(candidates[$0], thumbnailAspect) < closeness(candidates[$1], thumbnailAspect) }
            if ranked.count > 1,
               abs(closeness(candidates[ranked[0]], thumbnailAspect) - closeness(candidates[ranked[1]], thumbnailAspect)) < 0.02 {
                return nil // identical titles/shapes are ambiguous, not a reason to close the first one
            }
            return ranked[0]
        }
        return nil
    }

    /// True when `title` could have been shortened into `label` by replacing its middle with "…".
    /// The tail is searched for rather than anchored at the end, because window titles often carry a
    /// suffix the thumbnail drops, such as " - Brave".
    static func matchesElided(label: String, title: String) -> Bool {
        let parts = label.components(separatedBy: "…")
        guard parts.count == 2, !title.isEmpty else { return false }
        let head = parts[0], tail = parts[1]
        guard title.count > label.count - 1 else { return false } // a shortened title is longer than its label
        guard head.isEmpty || title.hasPrefix(head) else { return false }
        guard !tail.isEmpty else { return true }
        // The tail has to come after the head, not overlap it.
        return title.dropFirst(head.count).contains(tail)
    }

    private static func closeness(_ candidate: WindowCandidate, _ thumbnailAspect: CGFloat) -> CGFloat {
        abs(candidate.size.width / max(candidate.size.height, 1) - thumbnailAspect)
    }
}
