import Foundation

/// User preferences, changed from the settings window or optional menu bar icon.
enum Settings {
    enum Corner: String, CaseIterable {
        case topLeft, topRight
        var title: String { self == .topLeft ? "Top Left" : "Top Right" }
    }

    enum ButtonSize: Int, CaseIterable {
        case small = 16, medium = 20, large = 24
        var title: String { ["Small", "Medium", "Large"][Self.allCases.firstIndex(of: self)!] }
    }

    private static let defaults = UserDefaults.standard

    /// Run quietly by default; reopening the app always provides access to settings.
    static var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: "showMenuBarIcon") }
        set { defaults.set(newValue, forKey: "showMenuBarIcon") }
    }

    static var corner: Corner {
        get { defaults.string(forKey: "corner").flatMap(Corner.init) ?? .topLeft }
        set { defaults.set(newValue.rawValue, forKey: "corner") }
    }

    static var buttonSize: ButtonSize {
        get { ButtonSize(rawValue: defaults.integer(forKey: "buttonSize")) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "buttonSize") }
    }

    /// Show buttons on every thumbnail instead of only the hovered one.
    static var alwaysShow: Bool {
        get { defaults.bool(forKey: "alwaysShow") }
        set { defaults.set(newValue, forKey: "alwaysShow") }
    }

    /// Quitting an app takes a second ⌥-click / ⌘Q within a few seconds.
    static var confirmQuit: Bool {
        get { defaults.bool(forKey: "confirmQuit") }
        set { defaults.set(newValue, forKey: "confirmQuit") }
    }
}
