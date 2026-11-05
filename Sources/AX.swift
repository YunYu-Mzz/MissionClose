import Cocoa
import ApplicationServices

extension AXUIElement {
    func value(_ name: String) -> AnyObject? {
        // A timeout set on an application element does NOT apply to its child elements.
        // Bound each individual read, including Dock thumbnails and close buttons.
        AXUIElementSetMessagingTimeout(self, 0.2)
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success else { return nil }
        return v
    }

    var children: [AXUIElement] { value(kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    var identifier: String? { value(kAXIdentifierAttribute) as? String }
    var role: String? { value(kAXRoleAttribute) as? String }
    var subrole: String? { value(kAXSubroleAttribute) as? String }
    var title: String? { value(kAXTitleAttribute) as? String }
    var windows: [AXUIElement] { value(kAXWindowsAttribute) as? [AXUIElement] ?? [] }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = value(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Optional private API. If it disappears, known CG IDs cannot safely be resolved through AX.
    var windowID: CGWindowID? {
        guard let getWindow = AXWindowID.getWindow else { return nil }
        AXUIElementSetMessagingTimeout(self, 0.2)
        var id: CGWindowID = 0
        return getWindow(self, &id) == .success && id != 0 ? id : nil
    }

    /// Frame in AX (top-left origin) global coordinates.
    var frame: CGRect? {
        guard let p = value(kAXPositionAttribute), let s = value(kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    func press() -> Bool { AXUIElementPerformAction(self, kAXPressAction as CFString) == .success }

    /// Presses one of a window's title bar buttons, e.g. kAXCloseButtonAttribute.
    func pressButton(_ attribute: String) -> Bool {
        guard let button = element(attribute) else {
            Diagnostics.log("pressButton \(attribute): the window has no such button")
            return false
        }
        AXUIElementSetMessagingTimeout(button, 0.5)
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if result == .success { return true }
        // Pressing close often tears the window down before the app can answer, so the call reports
        // .cannotComplete / .invalidUIElement even though it worked. If the window is gone, count it as done.
        if attribute == kAXCloseButtonAttribute && (result == .cannotComplete || result == .invalidUIElement) {
            var role: AnyObject?
            let readResult = AXUIElementCopyAttributeValue(self, kAXRoleAttribute as CFString, &role)
            if AXActionResult.closeSucceeded(press: result, windowRead: readResult) {
                Diagnostics.log("pressButton \(attribute): AXError \(result.rawValue), but the window is gone; counted as success")
                return true
            }
        }
        Diagnostics.log("pressButton \(attribute): AXError \(result.rawValue)")
        return false
    }

    func set(_ attribute: String, _ flag: Bool) -> Bool {
        AXUIElementSetAttributeValue(self, attribute as CFString, (flag ? kCFBooleanTrue : kCFBooleanFalse)!) == .success
    }
}

private enum AXWindowID {
    typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    static let getWindow: GetWindow? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()
}

/// Lets AXUIElement be used as a dictionary key (CFEqual/CFHash semantics).
struct ElementKey: Hashable {
    let element: AXUIElement
    static func == (a: ElementKey, b: ElementKey) -> Bool { CFEqual(a.element, b.element) }
    func hash(into h: inout Hasher) { h.combine(CFHash(element)) }
}

/// Converts an AX rect (top-left origin) to Cocoa screen coordinates (bottom-left origin).
func cocoaRect(_ r: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}
