import ApplicationServices

enum AXActionResult {
    /// A timeout or denied attribute read is not evidence that a window disappeared.
    /// Only an invalidated window after a possibly delivered close counts as success.
    static func closeSucceeded(press: AXError, windowRead: AXError) -> Bool {
        press == .success || ((press == .cannotComplete || press == .invalidUIElement)
                             && windowRead == .invalidUIElement)
    }
}
