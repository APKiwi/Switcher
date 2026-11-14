import Foundation
import SwitcherKernels

/// Pins the opt-in contract an app's Info.plist uses to take Option+backtick for
/// itself. Forwarding by mistake would leave an app with no window cycling at all,
/// so anything but a Boolean true keeps Switcher's own cycling.
enum OptionBacktickRouteTests {

    static func runAll() {
        Check.run("testInfoPlistTrueForwardsToTheApp", testInfoPlistTrueForwardsToTheApp)
        Check.run("testAbsentFalseOrMistypedKeepsSwitchersCycling", testAbsentFalseOrMistypedKeepsSwitchersCycling)
    }

    /// Bundle reads an Info.plist `<true/>` back as a bridged NSNumber, not a Swift Bool.
    static func testInfoPlistTrueForwardsToTheApp() {
        Check.equal(OptionBacktickRoute.route(declared: NSNumber(value: true)), .forwardToApp)
    }

    /// An Info.plist `<integer>1</integer>` bridges to Bool true in Swift, so it must be
    /// refused on its type.
    static func testAbsentFalseOrMistypedKeepsSwitchersCycling() {
        let declarations: [(String, Any?)] = [
            ("absent", nil),
            ("false", NSNumber(value: false)),
            ("string YES", "YES"),
            ("integer 1", NSNumber(value: 1)),
        ]
        for (name, value) in declarations {
            Check.equal(OptionBacktickRoute.route(declared: value), .cycleWindows, name)
        }
    }
}
