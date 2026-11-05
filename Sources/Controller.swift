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
    private var clickTapEnabled = false
    private var touchTap: CFMachPort?
    private var swallowingMouseUp = false
    /// Consecutive ticks in which no thumbnail moved. Mission Control animates thumbnails on the way
    /// in and out (and follows your fingers during a swipe), so ✕ buttons only show once everything is still.
    private var stillTicks = 0
    /// A 3-finger swipe is under way. It can pause mid-way with the thumbnails standing still, and
    /// macOS keeps following it if some fingers lift, so it only counts as over once every finger is up.
    private var swiping = false
    private var fingersDown = 0
    private var isSettled: Bool { stillTicks >= 2 && !swiping && ProcessInfo.processInfo.systemUptime >= resumePollingAt }
    /// Every window on screen, gathered in the background when Mission Control opens so clicks are instant.
    private var windowIndex: [WindowRef]?
    private struct OverviewSnapshot {
        let trusted: Bool
        let thumbnails: [MissionControl.Thumbnail]?
    }
    private let overviewWork = BackgroundWork<OverviewSnapshot>(label: "MissionClose.overview")
    private let indexWork = BackgroundWork<[WindowRef]>(label: "MissionClose.window-index")
    private let actionWork = BackgroundWork<Bool?>(label: "MissionClose.window-action")
    private var resumePollingAt: TimeInterval = 0
    private var latestPointer: CGPoint?
    private var hoverUpdateQueued = false
    /// With "confirm before quitting" on: the thumbnail whose quit is armed, until when.
    private var pendingQuit: (key: ElementKey, until: Date)?

    func start() { schedule(after: 0.1) }

    /// Only schedules background reads. AX/LaunchServices calls must never block the event-tap run loop.
    private func schedule(after interval: TimeInterval) {
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.tick()
            self.schedule(after: self.thumbs.isEmpty ? 0.2 : 0.06)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func installTapsIfNeeded() {
        if tap == nil {
            let mask = [CGEventType.leftMouseDown, .leftMouseUp, .mouseMoved, .leftMouseDragged, .keyDown, .scrollWheel,
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
        guard let tap, clickTapEnabled != enabled else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
        clickTapEnabled = enabled
    }

    private func tick() {
        guard !swiping, ProcessInfo.processInfo.systemUptime >= resumePollingAt else { return }
        overviewWork.start({ token in
            let trusted = AXIsProcessTrusted()
            guard trusted, !token.isCancelled, let mc = MissionControl.root() else {
                return OverviewSnapshot(trusted: trusted, thumbnails: nil)
            }
            return OverviewSnapshot(trusted: true, thumbnails:
                MissionControl.thumbnailFrames(in: mc, isCancelled: { token.isCancelled }))
        }, completion: { [weak self] snapshot in self?.apply(snapshot) })
    }

    private func apply(_ snapshot: OverviewSnapshot) {
        guard snapshot.trusted else { return clear() }
        installTapsIfNeeded()
        guard let snapshots = snapshot.thumbnails else { return clear() }
        setClickTapEnabled(true)

        let size = CGFloat(Settings.buttonSize.rawValue)
        var next: [ElementKey: Thumb] = [:]
        for snapshot in snapshots {
            let element = snapshot.element, frame = snapshot.frame
            let key = ElementKey(element: element)
            let previous = thumbs[key]?.panel
            let panel: WindowButtonsPanel
            if let previous, previous.size == size {
                panel = previous
            } else {
                previous?.orderOut(nil)
                panel = WindowButtonsPanel(size: size)
            }
            next[key] = Thumb(key: key, element: element, frame: frame, panel: panel)
        }
        if let pending = pendingQuit, Date() > pending.until {
            next[pending.key]?.panel.armed = false
            pendingQuit = nil
        }
        for (key, old) in thumbs where next[key] == nil { old.panel.orderOut(nil) }
        let moved = next.count != thumbs.count || next.contains { $0.value.frame != thumbs[$0.key]?.frame }
        stillTicks = moved ? 0 : stillTicks + 1
        thumbs = next
        updateHover(at: CGEvent(source: nil)?.location ?? .zero)
        // Don't query every app while the system is animating into its overview.
        if isSettled, windowIndex == nil { refreshWindowIndex() }
    }

    /// Buttons show on the thumbnail under the pointer (or on all of them, if configured),
    /// and only while Mission Control is at rest.
    private func updateHover(at point: CGPoint) {
        let alwaysShow = Settings.alwaysShow
        let settled = isSettled, corner = Settings.corner
        for thumb in thumbs.values {
            // Hidden panels must not chase every frame of the native overview animation.
            if settled { thumb.panel.place(on: thumb.frame, corner: corner) }
            let active = settled && (alwaysShow || thumb.frame.union(thumb.panel.axFrame).contains(point))
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
            clickTapEnabled = false
            if !thumbs.isEmpty || swallowingMouseUp { setClickTapEnabled(true) }
            return false
        case .mouseMoved:
            // Return the system event before drawing/reordering any overlay windows.
            latestPointer = event.location
            queueHoverUpdate()
            return false
        case .leftMouseDragged:
            pauseForTransition()
            return false
        case .leftMouseDown:
            guard isSettled,
                  let thumb = thumbs.values.first(where: { $0.panel.isVisible && $0.panel.button(at: event.location) != nil }),
                  let button = thumb.panel.button(at: event.location)
            else { pauseForTransition(); return false } // immediately pass ordinary thumbnail clicks to the system
            swallowingMouseUp = true
            let quitApp = event.flags.contains(.maskAlternate)
            DispatchQueue.main.async { [weak self] in self?.perform(button.action, on: thumb, quitApp: quitApp) }
            return true
        case .keyDown:
            // ⌘W / ⌘Q act on the thumbnail under the pointer.
            if let (action, quitApp) = Self.shortcut(event), let thumb = thumb(at: event.location) {
                DispatchQueue.main.async { [weak self] in self?.perform(action, on: thumb, quitApp: quitApp) }
                return true
            }
            pauseForTransition() // Esc and other keys dismiss Mission Control
            return false
        case .scrollWheel: // space switching, or the start of a swipe
            pauseForTransition()
            return false
        case .flagsChanged:
            let quitMode = event.flags.contains(.maskAlternate)
            DispatchQueue.main.async { [weak self] in self?.thumbs.values.forEach { $0.panel.quitMode = quitMode } }
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

    /// ⌘W closes the window, ⌘Q quits the app, ⌘⌥W closes the app's other
    /// windows; nil for anything else.
    private static func shortcut(_ event: CGEvent) -> (WindowAction, quitApp: Bool)? {
        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard modifiers == .maskCommand || modifiers == [.maskCommand, .maskAlternate] else { return nil }
        let withOption = modifiers.contains(.maskAlternate)
        // Match the typed letter; on non-Latin layouts fall back to the W/Q key positions like macOS shortcuts do.
        let typed = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased() ?? ""
        let letter = typed.unicodeScalars.allSatisfy(\.isASCII) && !typed.isEmpty
            ? typed
            : [13: "w", 12: "q"][event.getIntegerValueField(.keyboardEventKeycode)] ?? ""
        switch letter {
        case "w": return withOption ? (.closeOthers, false) : (.close, false)
        case "q" where !withOption: return (.close, true)
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
            swiping = true
            pauseForTransition()
        } else if count == 0 && swiping {
            swiping = false
            stillTicks = 0 // Mission Control keeps animating after the fingers lift
        }
    }

    private func hideUntilSettled() {
        stillTicks = 0
        for thumb in thumbs.values where thumb.panel.isVisible { thumb.panel.orderOut(nil) }
    }

    private func queueHoverUpdate() {
        guard !hoverUpdateQueued, !thumbs.isEmpty else { return }
        hoverUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hoverUpdateQueued = false
            if let point = self.latestPointer { self.updateHover(at: point) }
        }
    }

    /// Stop old work immediately, but defer AppKit calls until after the event tap returns.
    /// A short pause lets the native click/exit animation proceed without AX tree polling.
    private func pauseForTransition() {
        stillTicks = 0
        resumePollingAt = ProcessInfo.processInfo.systemUptime + 0.35
        overviewWork.cancel()
        actionWork.cancel()
        indexWork.cancel()
        windowIndex = nil
        DispatchQueue.main.async { [weak self] in self?.hideUntilSettled() }
    }

    private func refreshWindowIndex() {
        indexWork.start({ token in WindowIndex.all(isCancelled: { token.isCancelled }) },
                        completion: { [weak self] index in self?.windowIndex = index })
    }

    private func perform(_ action: WindowAction, on thumb: Thumb, quitApp: Bool) {
        guard isSettled, thumbs[thumb.key] != nil, !actionWork.isBusy else { return }
        if action == .close, quitApp, Settings.confirmQuit, !confirmQuit(thumb) { return }
        let element = thumb.element
        let cachedWindows = windowIndex ?? []
        indexWork.cancel()
        actionWork.start({ token in
            Self.execute(action, on: element, quitApp: quitApp, cachedWindows: cachedWindows, token: token)
        }, completion: { result in
            if result == false { NSSound.beep() }
        })
    }

    /// Potentially slow cross-process work runs only on the action queue. A user leaving the
    /// overview cancels resolution; recheck cancellation immediately before every side effect.
    private static func execute(_ action: WindowAction, on element: AXUIElement, quitApp: Bool,
                                cachedWindows: [WindowRef], token: WorkCancellation) -> Bool? {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        func cancelled() -> Bool { token.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline }
        guard !cancelled(), AXIsProcessTrusted(), MissionControl.root() != nil else { return nil }
        let identity = WindowIndex.identity(of: element)
        let fresh = WindowIndex.all(processID: identity.processID, isCancelled: cancelled)
        // Keep the old title only for the SAME live AX window. A cached window that has closed
        // must never beat a fresh one with an identical title.
        let current = fresh.map { live -> WindowRef in
            guard let cached = cachedWindows.first(where: { CFEqual($0.window, live.window) }) else { return live }
            return WindowRef(app: live.app, window: live.window, title: cached.title, size: live.size,
                             windowID: live.windowID, appAliases: live.appAliases)
        }
        guard !cancelled() else { return nil }
        guard let target = WindowIndex.match(element, in: current, identity: identity) else {
            guard !cancelled() else { return nil }
            Diagnostics.logFailure(action: "\(action)", label: element.title,
                                   thumbnailSize: element.frame?.size, windows: fresh, matched: nil)
            return false
        }
        guard !cancelled(), MissionControl.root() != nil, !cancelled() else { return nil }
        let window = target.window
        let ok: Bool
        switch action {
        case .close where quitApp:
            ok = target.app.terminate()
        case .close:
            ok = window.pressButton(kAXCloseButtonAttribute)
        case .closeOthers:
            // Every standard window of the same app except this one.
            let others = fresh.filter {
                $0.app.processIdentifier == target.app.processIdentifier && !CFEqual($0.window, window)
            }
            var results: [Bool] = []
            for other in others {
                guard !cancelled() else { return nil }
                results.append(other.window.pressButton(kAXCloseButtonAttribute))
            }
            ok = results.allSatisfy { $0 }
        }
        if !ok {
            Diagnostics.logFailure(action: "\(action)", label: element.title,
                                   thumbnailSize: element.frame?.size, windows: fresh, matched: target)
        }
        // Observe the system's layout as-is. Never dismiss or reopen Mission Control after closing.
        return ok
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
        pendingQuit = nil
        setClickTapEnabled(swallowingMouseUp)
        overviewWork.cancel()
        indexWork.cancel()
        actionWork.cancel()
        windowIndex = nil
        stillTicks = 0
        for thumb in thumbs.values where thumb.panel.isVisible { thumb.panel.orderOut(nil) }
        thumbs.removeAll()
    }
}
