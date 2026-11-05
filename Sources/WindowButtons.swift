import Cocoa

enum WindowAction {
    case close, minimize, fullScreen
    /// Keyboard only: close every other window of the same app (⌘⌥W).
    case closeOthers
}

/// One traffic-light button. Subtle dark circle by default, the real traffic-light color while hovered.
final class WindowButtonView: NSView {
    let action: WindowAction
    /// True while the pointer is over this button (set by the controller; the view never gets real mouse events).
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    /// Close button only: Option is held, so a click quits the app; show a power symbol instead of the ✕.
    var quitMode = false { didSet { if quitMode != oldValue { needsDisplay = true } } }
    /// Close button only: a quit is waiting for confirmation (a second ⌥-click / ⌘Q).
    var armed = false { didSet { if armed != oldValue { needsDisplay = true } } }

    init(action: WindowAction, size: CGFloat) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var colors: (fill: NSColor, glyph: NSColor) {
        switch action {
        case .close, .closeOthers: return (NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1), NSColor(red: 0.45, green: 0.05, blue: 0.03, alpha: 1))
        case .minimize: return (NSColor(red: 1.0, green: 0.74, blue: 0.18, alpha: 1), NSColor(red: 0.55, green: 0.32, blue: 0.0, alpha: 1))
        case .fullScreen: return (NSColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1), NSColor(red: 0.0, green: 0.38, blue: 0.05, alpha: 1))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = hovering || armed
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        (highlighted ? colors.fill : NSColor(white: 0.12, alpha: 0.72)).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(highlighted ? 0 : 0.25).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()

        let glyphColor = highlighted ? colors.glyph : NSColor.white.withAlphaComponent(0.85)
        if action == .fullScreen {
            glyphColor.setFill()
            fullScreenGlyph().fill()
            return
        }
        let glyph: NSBezierPath
        switch action {
        case .close, .closeOthers: glyph = quitMode || armed ? powerGlyph() : crossGlyph()
        default: glyph = minusGlyph()
        }
        glyph.lineWidth = bounds.width * 0.075
        glyph.lineCapStyle = .round
        glyphColor.setStroke()
        glyph.stroke()
    }

    private func crossGlyph() -> NSBezierPath {
        let inset = bounds.width * 0.35
        let path = NSBezierPath()
        path.move(to: NSPoint(x: inset, y: inset))
        path.line(to: NSPoint(x: bounds.width - inset, y: bounds.height - inset))
        path.move(to: NSPoint(x: inset, y: bounds.height - inset))
        path.line(to: NSPoint(x: bounds.width - inset, y: inset))
        return path
    }

    /// ⏻: an open ring with a stroke through the gap at the top.
    private func powerGlyph() -> NSBezierPath {
        let center = NSPoint(x: bounds.midX, y: bounds.midY - bounds.height * 0.02)
        let radius = bounds.width * 0.2
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: 125, endAngle: 55, clockwise: false)
        path.move(to: center)
        path.line(to: NSPoint(x: center.x, y: center.y + radius * 1.25))
        return path
    }

    private func minusGlyph() -> NSBezierPath {
        let inset = bounds.width * 0.32
        let path = NSBezierPath()
        path.move(to: NSPoint(x: inset, y: bounds.midY))
        path.line(to: NSPoint(x: bounds.width - inset, y: bounds.midY))
        return path
    }

    /// Two triangles pointing to opposite corners, like the green button's full-screen glyph.
    private func fullScreenGlyph() -> NSBezierPath {
        let lo = bounds.width * 0.29, hi = bounds.width * 0.71, leg = bounds.width * 0.23
        let path = NSBezierPath()
        path.move(to: NSPoint(x: lo, y: hi)) // top-left
        path.line(to: NSPoint(x: lo + leg, y: hi))
        path.line(to: NSPoint(x: lo, y: hi - leg))
        path.close()
        path.move(to: NSPoint(x: hi, y: lo)) // bottom-right
        path.line(to: NSPoint(x: hi - leg, y: lo))
        path.line(to: NSPoint(x: hi, y: lo + leg))
        path.close()
        return path
    }
}

/// A row of close / minimize / full-screen buttons floating above Mission Control.
final class WindowButtonsPanel: NSPanel {
    let size: CGFloat
    let buttons: [WindowButtonView]
    /// Row rect in AX / CGEvent coordinates (top-left origin), used for hit testing.
    private(set) var axFrame = CGRect.zero

    init(size: CGFloat) {
        let s = size
        let spacing = (s * 0.3).rounded()
        self.size = s
        buttons = [WindowAction.close, .minimize, .fullScreen].map { WindowButtonView(action: $0, size: s) }
        let width = CGFloat(buttons.count) * s + CGFloat(buttons.count - 1) * spacing
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: s),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true // clicks are handled by the event tap
        // Above Mission Control, and .stationary so Mission Control doesn't shuffle it like a normal window.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: s))
        for (i, button) in buttons.enumerated() {
            button.setFrameOrigin(NSPoint(x: CGFloat(i) * (s + spacing), y: 0))
            content.addSubview(button)
        }
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var quitMode: Bool {
        get { buttons[0].quitMode }
        set { buttons[0].quitMode = newValue }
    }

    var armed: Bool {
        get { buttons[0].armed }
        set { buttons[0].armed = newValue }
    }

    /// Sits on the thumbnail's top-left corner, where the traffic lights would be (or top-right if configured).
    func place(on thumbAXFrame: CGRect, corner: Settings.Corner) {
        let s = size
        let x = corner == .topLeft ? thumbAXFrame.minX - s / 3 : thumbAXFrame.maxX + s / 3 - frame.width
        axFrame = CGRect(x: x, y: thumbAXFrame.minY - s / 3, width: frame.width, height: s)
        setFrame(cocoaRect(axFrame), display: false)
    }

    /// The button under a point in AX / CGEvent coordinates.
    func button(at point: CGPoint) -> WindowButtonView? {
        buttons.first { axFrame(of: $0).contains(point) }
    }

    private func axFrame(of button: WindowButtonView) -> CGRect {
        CGRect(x: axFrame.minX + button.frame.minX, y: axFrame.minY, width: button.frame.width, height: button.frame.height)
    }

    /// Highlights the button under the pointer (nil clears all).
    func updateHover(at point: CGPoint?) {
        for button in buttons { button.hovering = point.map { axFrame(of: button).contains($0) } ?? false }
    }
}
