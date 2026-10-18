import Foundation

/// Decides whether an app activation was asked for or is a focus steal.
///
/// FocusGuard's rule, any input in the 300 ms before the activation, failed
/// three ways when measured (`FocusIntentSpecs.md`):
///
/// - A cold launch activates 230 to 440 ms after it starts, so a Spotlight
///   launch fell outside the window and was reverted mid-boot. Launches are
///   therefore judged from when they started, not from when they activated.
/// - The input behind an activation can reach a global monitor after the
///   activation notice. The caller decides `decisionDelay` later, using event
///   times, so the cause is already in `inputs`.
/// - Plain typing counted, so a steal while typing went through. Only input
///   that can switch apps counts as a cause.
///
/// Times are seconds on one monotonic clock (system uptime, which `NSEvent`
/// timestamps already use).
public enum FocusIntent {

    public enum InputKind: Equatable {
        /// Any mouse button down: a window, the Dock, a menu, Mission Control.
        case click
        /// Return or keypad Enter, which ends a launcher search or a terminal `open`.
        case confirmKey
        /// A key with Command, Control or Option held: app hotkeys, Cmd+Q, Cmd+H.
        case shortcut
        /// Command, Control or Option released. A hold-to-switch chord ends here,
        /// and its Tab presses are hotkeys no global monitor sees.
        case modifierRelease
        /// The active Space changed, as a trackpad swipe does.
        case spaceChange
        /// Characters, Shift, arrows and the rest. Evidence the user is busy,
        /// never a reason for another app to come forward.
        case typing

        public var canSwitchApps: Bool { self != .typing }

        /// Whether this input, arriving after a steal, means the user is dealing
        /// with it and the revert should stand down. Typing is what the steal is
        /// taking, and a steal from another Space changes the Space itself.
        public var cancelsRevert: Bool { self != .typing && self != .spaceChange }
    }

    public struct Input: Equatable {
        public let kind: InputKind
        public let at: TimeInterval

        public init(_ kind: InputKind, at: TimeInterval) {
            self.kind = kind
            self.at = at
        }
    }

    public enum Verdict: Equatable {
        /// Input that can switch apps came just before the activation.
        case intended(by: Input)
        /// The app's launch followed such input, and the user has waited since.
        case launched(by: Input)
        case steal

        public var isSteal: Bool { self == .steal }
    }

    public struct Modifiers: OptionSet, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)

        static let switching: Modifiers = [.command, .control, .option]
    }

    /// Longest measured gap from a click or key to the activation it caused was
    /// 255 ms, plus one ambiguous 407 ms.
    public static let inputWindow: TimeInterval = 0.5
    /// Return to the launch starting measured 123 and 143 ms.
    public static let launchWindow: TimeInterval = 0.5
    /// Input this soon after the launching input is still part of it, such as a
    /// second Return or a key typed as the launcher closes.
    public static let launchSlack: TimeInterval = 0.5
    /// A launch older than this is not waited for.
    public static let launchLifetime: TimeInterval = 60
    /// Late input was measured at up to 11 ms behind the activation notice.
    public static let decisionDelay: TimeInterval = 0.15

    /// - Parameters:
    ///   - activationAt: when the activation notice arrived.
    ///   - launchedAt: when the activating app launched, if that is known.
    ///   - inputs: recent input in any order, covering at least `launchLifetime`.
    public static func classify(activationAt: TimeInterval, launchedAt: TimeInterval?,
                                inputs: [Input]) -> Verdict {
        let direct = inputs
            .filter { $0.kind.canSwitchApps && $0.at <= activationAt && activationAt - $0.at <= inputWindow }
            .max { $0.at < $1.at }
        if let direct { return .intended(by: direct) }

        guard let launchedAt, activationAt - launchedAt <= launchLifetime else { return .steal }
        let launchCause = inputs
            .filter { $0.kind.canSwitchApps && $0.at <= launchedAt && launchedAt - $0.at <= launchWindow }
            .max { $0.at < $1.at }
        guard let launchCause else { return .steal }

        let movedOn = inputs.contains { $0.at > launchCause.at + launchSlack && $0.at < activationAt }
        return movedOn ? .steal : .launched(by: launchCause)
    }

    /// Return (36) and keypad Enter (76) confirm. A Command, Control or Option
    /// chord is a shortcut. Everything else is typing.
    public static func keyKind(keyCode: UInt16, modifiers: Modifiers) -> InputKind {
        if keyCode == 36 || keyCode == 76 { return .confirmKey }
        return modifiers.isDisjoint(with: .switching) ? .typing : .shortcut
    }

    /// Only a Command, Control or Option release counts. Presses and Shift are typing.
    public static func flagsKind(from previous: Modifiers, to current: Modifiers) -> InputKind {
        let released = previous.intersection(.switching).subtracting(current)
        return released.isEmpty ? .typing : .modifierRelease
    }
}
