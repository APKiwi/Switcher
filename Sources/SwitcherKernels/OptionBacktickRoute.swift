import Foundation

/// Decides who handles Option+backtick for the front app.
///
/// Switcher normally cycles the front app's windows itself by raising the backmost
/// Accessibility window. The Accessibility window list holds only the current
/// desktop's windows, so an app that can bring its windows from other desktops opts
/// out by setting `SwitcherForwardsOptionBacktick` to true in its Info.plist, and
/// Switcher posts the keystroke to that app instead. Gauge does this, because it is
/// an accessory app whose windows have no other way back from another desktop.
///
/// Only a Boolean true opts in, so a missing or mistyped value keeps Switcher's own
/// cycling. An Info.plist `<integer>1</integer>` bridges to Bool true in Swift, so the
/// value's Core Foundation type is checked rather than cast.
public enum OptionBacktickRoute: Equatable {
    /// Raise the front app's backmost Accessibility window.
    case cycleWindows
    /// Post Option+backtick to the front app, which cycles its own windows.
    case forwardToApp

    /// The Info.plist key an app sets to handle Option+backtick itself.
    public static let infoKey = "SwitcherForwardsOptionBacktick"

    /// `declared` is the front app's Info.plist value for `infoKey`, nil when absent.
    public static func route(declared: Any?) -> OptionBacktickRoute {
        guard let number = declared as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return .cycleWindows
        }
        return number.boolValue ? .forwardToApp : .cycleWindows
    }
}
