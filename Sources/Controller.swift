import Cocoa

/// Observes trackpad touches (listen-only). Note: don't tap the Dock's private swipe events (type 30)
/// instead; any tap on them, even listen-only, stops an auto-hidden Dock from revealing on hover.
private func touchTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon { Unmanaged<Controller>.fromOpaque(refcon).takeUnretainedValue().handleTouches(type: type, event: event) }
    return Unmanaged.passUnretained(event)
}

/// Mission Control grabs mouse clicks itself, so the overlay panels never see them.
/// A session event tap sees clicks first: clicks on a visible ✕ are swallowed and handled here.
private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<Controller>.fromOpaque(refcon).takeUnretainedValue()
    return controller.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

final class Controller {
    private struct Thumb {
        let key: ElementKey
        let element: AXUIElement
        let frame: CGRect
        let panel: WindowButtonsPanel
    }

    private var thumbs: [ElementKey: Thumb] = [:]
    private var timer: Timer?
    /// Filters clicks; only enabled while Mission Control is open.
    private var tap: CFMachPort?
    private var touchTap: CFMachPort?
    private var swallowingMouseUp = false
    /// Consecutive ticks in which no thumbnail moved. Mission Control animates thumbnails on the way
    /// in and out (and follows your fingers during a swipe), so ✕ buttons only show once everything is still.
    private var stillTicks = 0
    /// A 3-finger swipe is under way. It can pause mid-way with the thumbnails standing still, and
    /// macOS keeps following it if some fingers lift, so it only counts as over once every finger is up.
    private var swiping = false
    private var fingersDown = 0
    private var isSettled: Bool { stillTicks >= 2 && !swiping }
    /// Every window on screen, gathered in the background when Mission Control opens so clicks are instant.
    private var windowIndex: [WindowRef]?
    private var indexGeneration = 0
    /// With "confirm before quitting" on: the thumbnail whose quit is armed, until when.
    private var pendingQuit: (key: ElementKey, until: Date)?
    private struct PendingClose {
        let target: WindowRef
        let thumbnailKey: ElementKey?
        let requireTermination: Bool
        let wasOnScreen: Bool
        var confirmation: RemovalConfirmation
    }
    private var pendingCloses: [ElementKey: PendingClose] = [:]
    /// Dock can retain the AX thumbnail after its real window has gone. Never resurrect its buttons.
    private var retiredThumbnails = Set<ElementKey>()
    private var nextCloseCheck: TimeInterval = 0
    private var layoutRefresh = LayoutRefresh()
    private var refreshContext: (spaces: Set<Int>, frontmostPID: pid_t?)?
    private var sessionSpaces: Set<Int>?

    private var suppressedThumbnails: Set<ElementKey> {
        retiredThumbnails.union(pendingCloses.values.compactMap(\.thumbnailKey))
    }

    func start() { schedule(after: 0.1) }

    /// Polls fast while Mission Control is open so buttons vanish as soon as it starts closing.
    private func schedule(after interval: TimeInterval) {
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.tick()
            self.schedule(after: self.thumbs.isEmpty && !self.layoutRefresh.isTransitioning ? 0.1 : 0.03)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func installTapsIfNeeded() {
        if tap == nil {
            let mask = [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown,
                        .mouseMoved, .leftMouseDragged, .keyDown, .scrollWheel,
                        .flagsChanged]
                .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            tap = makeTap(mask: mask, options: .defaultTap, callback: eventTapCallback)
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        }
        if touchTap == nil {
            touchTap = makeTap(mask: 1 << CGEventMask(NSEvent.EventType.gesture.rawValue), options: .listenOnly,
                               callback: touchTapCallback)
        }
    }

    private func makeTap(mask: CGEventMask, options: CGEventTapOptions, callback: CGEventTapCallBack) -> CFMachPort? {
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return port
    }

    private func setClickTapEnabled(_ enabled: Bool) {
        guard let tap, CGEvent.tapIsEnabled(tap: tap) != enabled else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
    }

    private func tick() {
        guard AXIsProcessTrusted() else { return clear() }
        installTapsIfNeeded()
        let root = MissionControl.root()
        if let sessionSpaces, sessionSpaces != MissionControl.currentSpaceIDs() { cancelCloseRefresh() }
        if advanceLayoutRefresh(root: root) { return }
        guard let mc = root else { return clear() }
        setClickTapEnabled(true)

        let spaces = MissionControl.currentSpaceIDs()
        if let sessionSpaces, sessionSpaces != spaces { cancelCloseRefresh() }
        sessionSpaces = spaces
        checkClosedWindows(in: mc)

        if thumbs.isEmpty && windowIndex == nil { refreshWindowIndex() }
        let size = CGFloat(Settings.buttonSize.rawValue), corner = Settings.corner
        let suppressed = suppressedThumbnails
        var next: [ElementKey: Thumb] = [:]
        for element in MissionControl.thumbnails(in: mc) {
            guard let frame = element.frame else { continue }
            let key = ElementKey(element: element)
            guard !suppressed.contains(key) else { continue }
            let previous = thumbs[key]?.panel
            let panel: WindowButtonsPanel
            if let previous, previous.size == size {
                panel = previous
            } else {
                previous?.orderOut(nil)
                panel = WindowButtonsPanel(size: size)
            }
            panel.place(on: frame, corner: corner)
            next[key] = Thumb(key: key, element: element, frame: frame, panel: panel)
        }
        if let pending = pendingQuit, Date() > pending.until {
            next[pending.key]?.panel.armed = false
            pendingQuit = nil
        }
        for (key, old) in thumbs where next[key] == nil { old.panel.close() }
        let moved = next.count != thumbs.count || next.contains { $0.value.frame != thumbs[$0.key]?.frame }
        stillTicks = moved ? 0 : stillTicks + 1
        thumbs = next
        updateHover(at: CGEvent(source: nil)?.location ?? .zero)
    }

    /// Buttons show on the thumbnail under the pointer (or on all of them, if configured),
    /// and only while Mission Control is at rest.
    private func updateHover(at point: CGPoint) {
        let alwaysShow = Settings.alwaysShow
        for thumb in thumbs.values {
            let active = isSettled && (alwaysShow || thumb.frame.union(thumb.panel.axFrame).contains(point))
            thumb.panel.updateHover(at: active ? point : nil)
            if active, !thumb.panel.isVisible {
                thumb.panel.quitMode = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
                thumb.panel.orderFrontRegardless()
            }
            if !active, thumb.panel.isVisible { thumb.panel.orderOut(nil) }
        }
    }

    /// Returns true when the event should be swallowed.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap, !thumbs.isEmpty || layoutRefresh.isTransitioning || swallowingMouseUp {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        case .leftMouseDragged:
            cancelCloseRefresh()
            hideUntilSettled()
            return false
        case .mouseMoved:
            if !thumbs.isEmpty { updateHover(at: event.location) }
            return false
        case .leftMouseDown:
            guard let thumb = thumbs.values.first(where: { $0.panel.isVisible && $0.panel.button(at: event.location) != nil }),
                  let button = thumb.panel.button(at: event.location)
            else { cancelCloseRefresh(); hideUntilSettled(); return false }
            swallowingMouseUp = true
            let quitApp = event.flags.contains(.maskAlternate)
            DispatchQueue.main.async { [weak self] in self?.perform(button.action, on: thumb, quitApp: quitApp) }
            return true
        case .keyDown:
            // ⌘W / ⌘Q / ⌘M act on the thumbnail under the pointer.
            if let (action, quitApp) = Self.shortcut(event), let thumb = thumb(at: event.location) {
                DispatchQueue.main.async { [weak self] in self?.perform(action, on: thumb, quitApp: quitApp) }
                return true
            }
            cancelCloseRefresh()
            if !thumbs.isEmpty { hideUntilSettled() } // Esc and other keys dismiss Mission Control
            return false
        case .rightMouseDown, .otherMouseDown:
            cancelCloseRefresh()
            return false
        case .scrollWheel: // space switching, or the start of a swipe
            cancelCloseRefresh()
            if !thumbs.isEmpty { hideUntilSettled() }
            return false
        case .flagsChanged:
            let quitMode = event.flags.contains(.maskAlternate)
            thumbs.values.forEach { $0.panel.quitMode = quitMode }
            return false
        case .leftMouseUp:
            defer { swallowingMouseUp = false }
            return swallowingMouseUp
        default:
            return false
        }
    }

    private func thumb(at point: CGPoint) -> Thumb? {
        guard isSettled else { return nil }
        return thumbs.values.first { $0.frame.union($0.panel.axFrame).contains(point) }
    }

    /// ⌘W closes the window, ⌘Q quits the app, ⌘M minimizes, ⌘⌥W closes the app's other
    /// windows; nil for anything else.
    private static func shortcut(_ event: CGEvent) -> (WindowAction, quitApp: Bool)? {
        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard modifiers == .maskCommand || modifiers == [.maskCommand, .maskAlternate] else { return nil }
        let withOption = modifiers.contains(.maskAlternate)
        // Match the typed letter; on non-Latin layouts fall back to the W/Q key positions like macOS shortcuts do.
        let typed = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased() ?? ""
        let letter = typed.unicodeScalars.allSatisfy(\.isASCII) && !typed.isEmpty
            ? typed
            : [13: "w", 12: "q", 46: "m"][event.getIntegerValueField(.keyboardEventKeycode)] ?? ""
        switch letter {
        case "w": return withOption ? (.closeOthers, false) : (.close, false)
        case "q" where !withOption: return (.close, true)
        case "m" where !withOption: return (.minimize, false)
        default: return nil
        }
    }

    fileprivate func handleTouches(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let touchTap {
            CGEvent.tapEnable(tap: touchTap, enable: true)
            return
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .gesture else { return }
        // Some gesture events carry no touch data at all; they'd otherwise read as "all fingers lifted".
        guard !ns.touches(matching: .any, in: nil).isEmpty else { return }
        let count = ns.touches(matching: .touching, in: nil).count
        guard count != fingersDown else { return }
        fingersDown = count
        if count >= 3 {
            cancelCloseRefresh()
            swiping = true
            hideUntilSettled()
        } else if count == 0 && swiping {
            swiping = false
            stillTicks = 0 // Mission Control keeps animating after the fingers lift
        }
    }

    private func hideUntilSettled() {
        stillTicks = 0
        thumbs.values.forEach { $0.panel.orderOut(nil) }
    }

    private func refreshWindowIndex() {
        windowIndex = []
        indexGeneration += 1
        let generation = indexGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let index = WindowIndex.all()
            DispatchQueue.main.async { [weak self] in
                // Drop results that arrive after Mission Control already closed.
                if let self, self.indexGeneration == generation, self.windowIndex != nil { self.windowIndex = index }
            }
        }
    }

    private func perform(_ action: WindowAction, on thumb: Thumb, quitApp: Bool) {
        if action == .close, quitApp, Settings.confirmQuit, !confirmQuit(thumb) { return }
        // A queued click may outlive the overview or its thumbnail. Never act on that stale event.
        guard AXIsProcessTrusted(), MissionControl.root() != nil, thumbs[thumb.key] != nil else { return }
        let identity = WindowIndex.identity(of: thumb.element)
        let fresh = WindowIndex.all(processID: identity.processID)
        // Keep the old title only for the SAME live AX window. A cached window that has closed
        // must never beat a fresh one with an identical title.
        let current = fresh.map { live -> WindowRef in
            guard let cached = windowIndex?.first(where: { CFEqual($0.window, live.window) }) else { return live }
            return WindowRef(app: live.app, window: live.window, title: cached.title, size: live.size,
                             windowID: live.windowID, appAliases: live.appAliases)
        }
        guard let target = WindowIndex.match(thumb.element, in: current, identity: identity) else {
            Diagnostics.logFailure(action: "\(action)", label: thumb.element.title,
                                   thumbnailSize: thumb.element.frame?.size, windows: fresh, matched: nil)
            NSSound.beep()
            return
        }
        let window = target.window
        let visibleBefore = Self.visibleWindows()
        var closeRequests: [(WindowRef, ElementKey?, Bool)] = []
        let ok: Bool
        switch action {
        case .close where quitApp:
            ok = target.app.terminate()
            if ok { closeRequests.append((target, thumb.key, true)) }
        case .close:
            ok = window.pressButton(kAXCloseButtonAttribute)
            if ok { closeRequests.append((target, thumb.key, false)) }
        case .minimize:
            cancelCloseRefresh()
            ok = window.set(kAXMinimizedAttribute, true) || window.pressButton(kAXMinimizeButtonAttribute)
        case .closeOthers:
            // Every standard window of the same app except this one.
            let others = fresh.filter {
                $0.app.processIdentifier == target.app.processIdentifier && !CFEqual($0.window, window)
            }
            let results = others.map { $0.window.pressButton(kAXCloseButtonAttribute) }
            for (other, succeeded) in zip(others, results) where succeeded {
                closeRequests.append((other, nil, false))
            }
            ok = results.allSatisfy { $0 }
        case .fullScreen:
            // Mission Control aborts a full-screen transition, so leave it first: pressing the thumbnail
            // does what clicking it would (exit and bring that window forward), then go full screen.
            cancelCloseRefresh()
            hideUntilSettled()
            ok = thumb.element.press()
            if ok { enterFullScreen(window, of: target.app, deadline: Date().addingTimeInterval(2)) }
        }
        if !ok {
            Diagnostics.logFailure(action: "\(action)", label: thumb.element.title,
                                   thumbnailSize: thumb.element.frame?.size, windows: fresh, matched: target)
            NSSound.beep()
        }
        let now = ProcessInfo.processInfo.systemUptime
        for (closedTarget, key, requireTermination) in closeRequests {
            let wasOnScreen = closedTarget.windowID.map { visibleBefore?[$0] == closedTarget.app.processIdentifier } ?? false
            pendingCloses[ElementKey(element: closedTarget.window)] = PendingClose(
                target: closedTarget, thumbnailKey: key, requireTermination: requireTermination,
                wasOnScreen: wasOnScreen, confirmation: RemovalConfirmation(now: now))
            if let key { thumbs.removeValue(forKey: key)?.panel.close() }
        }
    }

    /// WindowServer keeps closed-but-retained NSWindows in the all-windows list; use visibility.
    /// A missing/failed snapshot is unknown, never proof of a successful close.
    private static func visibleWindows() -> [CGWindowID: pid_t]? {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var result: [CGWindowID: pid_t] = [:]
        for entry in list {
            if let id = entry[kCGWindowNumber as String] as? UInt32,
               let pid = entry[kCGWindowOwnerPID as String] as? Int32 { result[id] = pid }
        }
        return result
    }

    private func checkClosedWindows(in mc: AXUIElement) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !pendingCloses.isEmpty, now >= nextCloseCheck else { return }
        nextCloseCheck = now + 0.1
        let visible = Self.visibleWindows()
        var confirmed = false
        for (key, var pending) in pendingCloses {
            let target = pending.target
            let removed: Bool?
            if target.app.isTerminated {
                removed = true
            } else if pending.requireTermination {
                removed = false // quitting can still be waiting for an unsaved document
            } else {
                var value: AnyObject?
                let read = AXUIElementCopyAttributeValue(target.window, kAXRoleAttribute as CFString, &value)
                if read == .invalidUIElement {
                    removed = true
                } else if pending.wasOnScreen, let id = target.windowID, let visible {
                    removed = visible[id] != target.app.processIdentifier
                } else {
                    removed = read == .success ? false : nil
                }
            }
            switch pending.confirmation.observe(removed: removed, at: now) {
            case .waiting:
                pendingCloses[key] = pending
            case .removed:
                pendingCloses.removeValue(forKey: key)
                if let thumbKey = pending.thumbnailKey {
                    retiredThumbnails.insert(thumbKey)
                    thumbs.removeValue(forKey: thumbKey)?.panel.close()
                }
                confirmed = true
            case .timedOut:
                pendingCloses.removeValue(forKey: key) // restore buttons if the user cancelled a save prompt
            }
        }
        if confirmed {
            refreshWindowIndex()
            if Settings.refreshLayoutAfterClose, MissionControl.supportsLayoutRefresh(mc) {
                layoutRefresh.request(at: now)
            }
        }
    }

    private func cancelCloseRefresh() {
        layoutRefresh.cancel()
        refreshContext = nil
        pendingCloses.removeAll()
    }

    /// Keep the event tap alive across our own exit so Escape, clicks and swipes cancel re-entry.
    /// Never use delayed blind toggles: observe the exit, allow its animation to finish, then reopen.
    private func advanceLayoutRefresh(root: AXUIElement?) -> Bool {
        let wasTransitioning = layoutRefresh.isTransitioning
        if !Settings.refreshLayoutAfterClose || swiping {
            layoutRefresh.cancel()
        }
        if let root, !MissionControl.supportsLayoutRefresh(root) { layoutRefresh.cancel() }
        if let context = refreshContext {
            let frontmost = NSWorkspace.shared.frontmostApplication
            let sameApp = frontmost?.processIdentifier == context.frontmostPID
                || frontmost?.bundleIdentifier == "com.apple.exposelauncher"
            if !sameApp || MissionControl.currentSpaceIDs() != context.spaces { layoutRefresh.cancel() }
        }
        let command = layoutRefresh.advance(at: ProcessInfo.processInfo.systemUptime,
            overviewVisible: root != nil, ready: !swiping && !swallowingMouseUp && pendingCloses.isEmpty)
        if let command {
            switch command {
            case .dismiss:
                refreshContext = (MissionControl.currentSpaceIDs(), NSWorkspace.shared.frontmostApplication?.processIdentifier)
                clearThumbnailState()
            case .reopen:
                break
            }
            if !MissionControl.toggle() {
                Diagnostics.log("Layout refresh: Mission Control could not be toggled")
                layoutRefresh.cancel()
            }
        }
        if !layoutRefresh.isTransitioning { refreshContext = nil }
        if wasTransitioning || layoutRefresh.isTransitioning {
            setClickTapEnabled(layoutRefresh.isTransitioning || root != nil || swallowingMouseUp)
            return true
        }
        return false
    }

    /// Waits for Mission Control to close, then makes the window full screen.
    private func enterFullScreen(_ window: AXUIElement, of app: NSRunningApplication, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if MissionControl.root() != nil {
                if Date() < deadline { self.enterFullScreen(window, of: app, deadline: deadline) } else { NSSound.beep() }
                return
            }
            // Let the exit animation finish before starting the full-screen one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                app.activate()
                _ = window.set(kAXMainAttribute, true)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                if !window.set("AXFullScreen", true) && !window.pressButton(kAXFullScreenButtonAttribute) {
                    NSSound.beep()
                }
            }
        }
    }

    /// First quit request arms the close button; a second one on the same thumbnail within 3 seconds goes through.
    private func confirmQuit(_ thumb: Thumb) -> Bool {
        if let pending = pendingQuit, pending.key == thumb.key, Date() <= pending.until {
            pendingQuit = nil
            thumb.panel.armed = false
            return true
        }
        if let pending = pendingQuit { thumbs[pending.key]?.panel.armed = false }
        pendingQuit = (thumb.key, Date().addingTimeInterval(3))
        thumb.panel.armed = true
        return false
    }

    private func clear() {
        cancelCloseRefresh()
        clearThumbnailState()
        // A close may finish before mouse-up. Don't leak that release into a different window.
        setClickTapEnabled(swallowingMouseUp)
    }

    private func clearThumbnailState() {
        pendingQuit = nil
        pendingCloses.removeAll()
        retiredThumbnails.removeAll()
        sessionSpaces = nil
        windowIndex = nil
        indexGeneration += 1
        stillTicks = 0
        thumbs.values.forEach { $0.panel.close() }
        thumbs.removeAll()
    }
}
