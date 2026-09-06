import Foundation

/// Single source of truth for persisted settings, wrapping `UserDefaults.standard`.
/// All keys live here so nothing is referenced as a stray string literal.
enum Preferences {

    // MARK: - Keys

    private enum Key {
        // NOTE: must stay "grayscaleIcons" for backward compatibility with the
        // existing `defaults write com.simpleswitcher.app grayscaleIcons` workflow.
        static let grayscaleIcons = "grayscaleIcons"
        static let showMenuBarIcon = "showMenuBarIcon"
    }

    private static let defaults = UserDefaults.standard

    /// Registers in-process fallbacks. Does NOT persist, so this must run before
    /// any read, on every launch (see AppDelegate.applicationDidFinishLaunching).
    static func registerDefaults() {
        defaults.register(defaults: [Key.showMenuBarIcon: true])
    }

    // MARK: - Accessors

    static var grayscaleIcons: Bool {
        get { defaults.bool(forKey: Key.grayscaleIcons) }
        set { defaults.set(newValue, forKey: Key.grayscaleIcons) }
    }

    static var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: Key.showMenuBarIcon) }
        set { defaults.set(newValue, forKey: Key.showMenuBarIcon) }
    }
}
