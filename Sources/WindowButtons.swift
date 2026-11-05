import Cocoa

enum WindowAction {
    case close
    /// Keyboard only: close every other window of the same app (⌘⌥W).
    case closeOthers
}

/// The close button. A dark circle by default, red while hovered.
final class WindowButtonView: NSView {
    let action = WindowAction.close
    /// True while the pointer is over this button (set by the controller; the view never gets real mouse events).
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    /// Close button only: Option is held, so a click quits the app; show a power symbol instead of the ✕.
    var quitMode = false { didSet { if quitMode != oldValue { needsDisplay = true } } }
    /// Close button only: a quit is waiting for confirmation (a second ⌥-click / ⌘Q).
    var armed = false { didSet { if armed != oldValue { needsDisplay = true } } }

    init(size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var colors: (fill: NSColor, glyph: NSColor) {
        (NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1), NSColor(red: 0.45, green: 0.05, blue: 0.03, alpha: 1))
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
        let glyph = quitMode || armed ? powerGlyph() : crossGlyph()
        glyph.lineWidth = bounds.width * 0.085
        glyph.lineCapStyle = .round
        glyphColor.setStroke()
        glyph.stroke()
    }

    private func crossGlyph() -> NSBezierPath {
        let inset = bounds.width * 0.30
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

}

/// A single close button floating above Mission Control.
final class WindowButtonsPanel: NSPanel {
    let size: CGFloat
    let closeButton: WindowButtonView
    /// Button rect in AX / CGEvent coordinates (top-left origin), used for hit testing.
    private(set) var axFrame = CGRect.zero

    init(size: CGFloat) {
        let s = size
        self.size = s
        closeButton = WindowButtonView(size: s)
        super.init(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true // clicks are handled by the event tap
        // Above Mission Control, and .stationary so Mission Control doesn't shuffle it like a normal window.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: s, height: s))
        content.addSubview(closeButton)
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var quitMode: Bool {
        get { closeButton.quitMode }
        set { closeButton.quitMode = newValue }
    }

    var armed: Bool {
        get { closeButton.armed }
        set { closeButton.armed = newValue }
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
        axFrame.contains(point) ? closeButton : nil
    }

    /// Highlights the close button under the pointer (nil clears it).
    func updateHover(at point: CGPoint?) {
        closeButton.hovering = point.map { axFrame.contains($0) } ?? false
    }
}
