import Foundation
import ApplicationServices

// Plain assertion-based tests, run by tools/test.sh and by CI. No XCTest, to keep the build
// dependency-free (swiftc only, no Xcode project).

var failures = 0
func check(_ condition: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)  (line \(line))")
        failures += 1
    }
}

func size(_ w: CGFloat, _ h: CGFloat) -> CGSize { CGSize(width: w, height: h) }

print("WindowMatching")

// Exact title is the strongest signal.
let two = [WindowCandidate(title: "Inbox", size: size(800, 600)),
           WindowCandidate(title: "Drafts", size: size(800, 600))]
check(WindowMatching.bestMatch(label: "Drafts", thumbnailAspect: 1.33, in: two) == 1, "picks the exactly matching title")

// Preview: the window title carries a suffix Mission Control doesn't show.
let preview = [WindowCandidate(title: "notes.txt", size: size(600, 400)),
               WindowCandidate(title: "photo.png – 2 documents, 2 total pages", size: size(708, 452))]
check(WindowMatching.bestMatch(label: "photo.png", thumbnailAspect: 1.56, in: preview) == 1, "matches a title with a trailing suffix")

// A title that changed since the index was built (terminal spinner) is caught by the live title.
let spinner = [WindowCandidate(title: "◐ building…", liveTitle: "✳ building…", size: size(900, 600))]
check(WindowMatching.bestMatch(label: "✳ building…", thumbnailAspect: 1.5, in: spinner) == 0, "falls back to the live title")

// Same title in two apps: the closest aspect ratio wins.
let duplicates = [WindowCandidate(title: "Untitled", size: size(400, 800)),
                  WindowCandidate(title: "Untitled", size: size(1600, 900))]
check(WindowMatching.bestMatch(label: "Untitled", thumbnailAspect: 1.78, in: duplicates) == 1, "breaks ties by aspect ratio")

// Untitled windows are labelled with the app's name.
let byApp = [WindowCandidate(title: "", appName: "Calculator", size: size(300, 400))]
check(WindowMatching.bestMatch(label: "Calculator", thumbnailAspect: 0.75, in: byApp) == 0, "matches on app name when the window has no title")

// An app name must not beat a real title match.
let both = [WindowCandidate(title: "Calculator", appName: "Notes", size: size(300, 400)),
            WindowCandidate(title: "", appName: "Calculator", size: size(300, 400))]
check(WindowMatching.bestMatch(label: "Calculator", thumbnailAspect: 0.75, in: both) == 0, "prefers a title match over an app name")

check(WindowMatching.bestMatch(label: "Nothing here", thumbnailAspect: 1.5, in: two) == nil, "returns nil when nothing matches")
check(WindowMatching.bestMatch(label: "", thumbnailAspect: 1.5, in: two) == nil, "returns nil for an empty label")

// Mission Control elides long titles in the middle; browsers hit this constantly.
let brave = [
    WindowCandidate(title: "სანიოლის 2 ტყუილი და რას შეცვლის სვანაძე? | ც9 - YouTube - Brave", size: size(1512, 949)),
    WindowCandidate(title: "beqaabu/MissionClose: Close windows straight from Mission Control on macOS - Brave", size: size(1512, 949)),
    WindowCandidate(title: "r/MacApps - Brave", size: size(1512, 949)),
]
check(WindowMatching.bestMatch(label: "beqaabu/MissionClose: Close w…from Mission Control on macOS",
                               thumbnailAspect: 1.59, in: brave) == 1, "matches a title elided in the middle")

check(WindowMatching.matchesElided(label: "Quarterly re…report.pdf", title: "Quarterly revenue report.pdf"),
      "head and tail both present")
check(!WindowMatching.matchesElided(label: "Quarterly re…missing", title: "Quarterly revenue report.pdf"),
      "tail that isn't in the title doesn't match")
check(!WindowMatching.matchesElided(label: "Other doc…pdf", title: "Quarterly revenue report.pdf"),
      "head that doesn't start the title doesn't match")
check(!WindowMatching.matchesElided(label: "Report.pdf", title: "Report.pdf"),
      "a label with no ellipsis isn't treated as elided")
check(WindowMatching.matchesElided(label: "…settings.json", title: "~/Projects/app/settings.json"),
      "handles a label elided only at the front")

print("Window identity")
let owners = [
    WindowCandidate(title: "WeChat", appName: "Browser", size: size(1500, 1000), processID: 10, windowID: 100),
    WindowCandidate(title: "微信", appName: "微信", size: size(1500, 1000), processID: 20, windowID: 200,
                    bundleID: "com.tencent.xinWeChat", appAliases: ["WeChat"]),
]
check(WindowMatching.bestMatch(label: "WeChat", thumbnailAspect: 1.5, in: owners, processID: 20, windowID: 200) == 1,
      "real window ID beats a misleading title in another app")
check(WindowMatching.bestMatch(label: "WeChat", thumbnailAspect: 1.5, in: owners, processID: 20) == 1,
      "localized app aliases match only within the owning process")
check(WindowMatching.bestMatch(label: "WeChat", thumbnailAspect: 1.5, in: owners, windowID: 999) == nil,
      "a missing window ID never falls back to a different window")
check(WindowMatching.bestMatch(label: "WeChat", thumbnailAspect: 1.5,
                               in: [WindowCandidate(title: "WeChat", processID: 20)],
                               processID: 20, windowID: 200) == nil,
      "failed AX window-ID reads cannot downgrade a known CG identity to title matching")
check(WindowMatching.bestMatch(label: "", thumbnailAspect: 1.5, in: owners, processID: 20, windowID: 200) == 1,
      "window ID works even without a title")
check(WindowMatching.bestMatch(label: "WeChat", thumbnailAspect: 1.5, in: owners, processID: 10, windowID: 200) == nil,
      "window ID cannot override a contradictory owner PID")
check(WindowMatching.bestMatch(label: "WeChat", thumbnailAspect: 1.5, in: owners, bundleID: "com.tencent.xinWeChat") == 1,
      "bundle identifier constrains localized-name fallback")
let identical = [WindowCandidate(title: "Untitled", size: size(800, 600)),
                 WindowCandidate(title: "Untitled", size: size(800, 600))]
check(WindowMatching.bestMatch(label: "Untitled", thumbnailAspect: 1.333, in: identical) == nil,
      "indistinguishable windows are rejected instead of picking the first")
check(WindowMatching.sameFrame(CGRect(x: 10, y: 20, width: 400, height: 300),
                               CGRect(x: 11, y: 20, width: 401, height: 299)), "thumbnail bounds tolerate pixel rounding")
check(!WindowMatching.sameFrame(CGRect(x: 10, y: 20, width: 400, height: 300),
                                CGRect(x: 40, y: 20, width: 400, height: 300)), "same-size windows at different positions are distinct")
print("AXActionResult")
check(AXActionResult.closeSucceeded(press: .success, windowRead: .success), "successful AX press is accepted")
check(AXActionResult.closeSucceeded(press: .cannotComplete, windowRead: .invalidUIElement), "invalidated window after close is accepted")
check(!AXActionResult.closeSucceeded(press: .cannotComplete, windowRead: .cannotComplete), "a hung app is not a closed window")
check(!AXActionResult.closeSucceeded(press: .cannotComplete, windowRead: .apiDisabled), "denied access is not a closed window")
check(!AXActionResult.closeSucceeded(press: .actionUnsupported, windowRead: .invalidUIElement), "unsupported close remains a failure")
print("UpdateCheck")
check(UpdateCheck.isNewer("0.3.0", than: "0.2.1"), "0.3.0 is newer than 0.2.1")
check(UpdateCheck.isNewer("0.10.0", than: "0.9.9"), "0.10.0 is newer than 0.9.9 (not string order)")
check(UpdateCheck.isNewer("1.0.0", than: "0.99.99"), "1.0.0 is newer than 0.99.99")
check(!UpdateCheck.isNewer("0.2.1", than: "0.2.1"), "the same version is not newer")
check(!UpdateCheck.isNewer("0.2.0", than: "0.2.1"), "an older version is not newer")
check(UpdateCheck.isNewer("0.3", than: "0.2.9"), "handles a two-part version")

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
