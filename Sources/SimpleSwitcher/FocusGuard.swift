import AppKit
import ApplicationServices
import Carbon
import SwitcherKernels

/// Sends focus back when another app takes it unasked, such as an app that
/// brings itself forward while it boots.
///
/// `FocusIntent` decides what was asked for. This class feeds it input and
/// activations and does the revert, as soon as a steal is decided. It fails
/// open: security prompts, macOS's agents and allowed apps keep focus
/// (`FocusIntent.exemption`), and so does an app that takes focus from in front
/// of a prompt.
///
/// Needs only Accessibility: on macOS 27 global monitors receive other apps'
/// key presses with it (`FocusIntentSpecs.md`). Key presses are classified and
/// counted, never recorded.
final class FocusGuard {

    /// How long after a revert's call its landing is checked, if it was not seen.
    static let revertCheckDelay: TimeInterval = 0.5

    /// `activate` brought the previous app back in every measured revert. The AX
    /// fallback stays in case a later macOS refuses activation from a timer.
    enum RevertMethod: String, CaseIterable {
        case activate = "NSRunningApplication.activate"
        case axFrontmost = "AX kAXFrontmostAttribute"
    }

    /// Counts for the `--focus-probe` summary.
    struct Tally {
        var inputs: [String: Int] = [:]
        var intended = 0
        var launched = 0
        var allowed = 0
        var steals = 0
        var reverts: [RevertMethod: (ok: Int, failed: Int)] = [:]
    }

    /// Each activation that keeps focus, in the order they happened, once it is
    /// judged. A steal sent back never comes through, so it never ranks.
    var onKeep: ((NSRunningApplication) -> Void)?
    /// Called as the guard starts and stops, so the MRU order knows where its
    /// activations come from.
    var onRunningChange: ((Bool) -> Void)?
    /// Every decision as a line of text, for `--focus-probe`.
    var trace: ((String) -> Void)?
    private(set) var tally = Tally()
    private(set) var isRunning = false

    private struct InFlightRevert {
        let stealer: NSRunningApplication
        let target: NSRunningApplication
        let method: RevertMethod
        let startedAt: TimeInterval
        let triedMethods: [RevertMethod]
    }

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var inputs: [FocusIntent.Input] = []
    private var lastFlags: FocusIntent.Modifiers = []
    /// Where focus belongs: the latest app brought forward on purpose.
    private var lastIntentional: NSRunningApplication?
    /// The input behind the latest deliberate activation, which ends any older
    /// launch's claim to focus.
    private var lastSwitchCause: FocusIntent.Input?
    /// Whether the latest activation was a prompt that may be taking a password.
    private var promptInFront = false
    /// Activations waiting to be judged before they reach `onKeep`.
    private var activations = ActivationQueue<NSRunningApplication>()
    /// Counts starts, so a decision queued before a stop is dropped after a restart.
    private var session = 0
    private var inFlight: InFlightRevert?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !isRunning else { return }
        // Global monitors see input bound for other apps, local ones input bound
        // for Switcher's own windows: the panel, Preferences and the menu bar icon.
        // Blind to other apps' input, every activation would read as a steal.
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        guard let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) else {
            trace?("global monitor was refused, not guarding")
            return
        }
        monitors.append(global)
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }

        isRunning = true
        session += 1
        activations = ActivationQueue()
        lastIntentional = NSWorkspace.shared.frontmostApplication
        lastSwitchCause = nil
        promptInFront = false

        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.appDidActivate(app)
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.record(.spaceChange, at: ProcessInfo.processInfo.systemUptime)
                self?.trace?("Space changed")
            },
        ]
        trace?("guarding, starting app \(describe(lastIntentional))")
        onRunningChange?(true)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        // Failing open: whatever is still being judged keeps its rank.
        keep(activations.flush())
        inFlight = nil
        inputs.removeAll()
        lastIntentional = nil
        lastSwitchCause = nil
        onRunningChange?(false)
    }

    /// Records a panel action that may change the frontmost app. The Carbon
    /// hotkeys behind H and Q never reach an event monitor.
    func noteSwitcherAction() {
        guard isRunning else { return }
        record(.switcher, at: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - Input

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            record(FocusIntent.keyKind(keyCode: event.keyCode, modifiers: Self.modifiers(event)), at: event.timestamp)
        case .flagsChanged:
            let current = Self.modifiers(event)
            record(FocusIntent.flagsKind(from: lastFlags, to: current), at: event.timestamp)
            lastFlags = current
        default:
            record(.click, at: event.timestamp)
        }
    }

    private static func modifiers(_ event: NSEvent) -> FocusIntent.Modifiers {
        let flags = event.modifierFlags
        var result: FocusIntent.Modifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    private func record(_ kind: FocusIntent.InputKind, at timestamp: TimeInterval) {
        let name = "\(kind)"
        if tally.inputs[name] == nil { trace?("first \(name) seen") }
        tally.inputs[name, default: 0] += 1
        let input = FocusIntent.Input(kind, at: timestamp)
        inputs.append(input)
        let horizon = timestamp - FocusIntent.launchLifetime - 5
        if let first = inputs.first, first.at < horizon {
            inputs.removeAll { $0.at < horizon }
        }
    }

    private func firstCancel(after time: TimeInterval) -> FocusIntent.Input? {
        inputs.filter { $0.kind.cancelsRevert && $0.at > time }.min { $0.at < $1.at }
    }

    /// Input after a steal that may switch apps means the user is acting on it:
    /// whatever is in front now is where focus belongs.
    private func acceptSteal(cancelledBy cause: FocusIntent.Input, after event: String, at time: TimeInterval) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ownPID { lastIntentional = front }
        lastSwitchCause = cause
        trace?("  revert cancelled by \(cause.kind) \(ms(cause.at - time)) after the \(event), keeping \(describe(front))")
    }

    // MARK: - Activation

    private func appDidActivate(_ app: NSRunningApplication) {
        let activationAt = ProcessInfo.processInfo.systemUptime
        if let flight = inFlight, flight.target.processIdentifier == app.processIdentifier {
            trace?("revert landed on \(describe(app)) \(ms(activationAt - flight.startedAt)) after \(flight.method.rawValue)")
            revertLanded(flight)
            return
        }

        if app.processIdentifier == ownPID {
            // Switcher comes forward only on the user's word, for Preferences, on
            // input its local monitor saw. A launcher handing focus back on the
            // Return that launched something carries that launch's own cause.
            lastIntentional = app
            promptInFront = false
            if let cause = inputs
                .filter({ $0.kind.canSwitchApps && $0.at <= activationAt && activationAt - $0.at <= FocusIntent.inputWindow })
                .max(by: { $0.at < $1.at }) {
                lastSwitchCause = cause
            }
            keep(activations.notice(app, kept: true).released)
            return
        }

        let launchedAt = app.launchDate.map { activationAt - Date().timeIntervalSince($0) }
        // A cause already seen stays one however much input arrives late, so a
        // panel pick ranks at once instead of after the decision delay.
        let intendedNow = !FocusIntent.classify(activationAt: activationAt, launchedAt: nil,
                                                inputs: inputs, lastSwitchCause: lastSwitchCause).isSteal
        let noticed = activations.notice(app, kept: intendedNow ? true : nil)
        keep(noticed.released)
        // The prompt may lose focus before its decision, and its password field
        // with it.
        let passwordFieldAtNotice = Self.showsPasswordField(app)
        let session = self.session
        DispatchQueue.main.asyncAfter(deadline: .now() + FocusIntent.decisionDelay) { [weak self] in
            guard let self, self.isRunning, self.session == session else { return }
            let kept = self.decide(app, activationAt: activationAt, launchedAt: launchedAt,
                                   passwordFieldAtNotice: passwordFieldAtNotice)
            self.keep(self.activations.settle(noticed.id, kept: kept))
        }
    }

    private func keep(_ apps: [NSRunningApplication]) {
        apps.forEach { onKeep?($0) }
    }

    /// Returns whether the app keeps focus, and so its rank.
    private func decide(_ app: NSRunningApplication, activationAt: TimeInterval, launchedAt: TimeInterval?,
                        passwordFieldAtNotice: Bool) -> Bool {
        let verdict = FocusIntent.classify(activationAt: activationAt, launchedAt: launchedAt,
                                           inputs: inputs, lastSwitchCause: lastSwitchCause)
        let showsPasswordField = verdict.isSteal && (passwordFieldAtNotice || Self.showsPasswordField(app))
        let exemption = FocusIntent.exemption(bundleID: app.bundleIdentifier,
                                              isRegularApp: app.activationPolicy == .regular,
                                              showsPasswordField: showsPasswordField,
                                              allowed: Preferences.focusGuardAllowedApps)
        let leavingPrompt = promptInFront
        promptInFront = exemption?.mayHoldTyping ?? false
        let launchNote = launchedAt.flatMap { activationAt - $0 < 15 ? ", launched \(ms(activationAt - $0)) before" : nil } ?? ""

        switch verdict {
        case .intended(let cause):
            tally.intended += 1
            lastIntentional = app
            lastSwitchCause = cause
            trace?("intended: \(describe(app)), \(cause.kind) \(ms(activationAt - cause.at)) before\(launchNote)")
            return true
        case .launched(let cause):
            tally.launched += 1
            lastIntentional = app
            lastSwitchCause = cause
            trace?("launched: \(describe(app)), \(cause.kind) \(ms(activationAt - cause.at)) before\(launchNote)")
            return true
        case .steal:
            if let exemption {
                tally.allowed += 1
                trace?("allowed: \(describe(app)), \(exemption)\(launchNote)")
                return true
            }
            if leavingPrompt {
                tally.allowed += 1
                lastIntentional = app
                trace?("allowed: \(describe(app)), it took focus from a prompt\(launchNote)")
                return true
            }
            return handleSteal(app, activationAt: activationAt, launchNote: launchNote)
        }
    }

    /// Returns whether the stealer keeps focus.
    private func handleSteal(_ app: NSRunningApplication, activationAt: TimeInterval, launchNote: String) -> Bool {
        tally.steals += 1
        if trace != nil {
            let before = inputs.filter { $0.at <= activationAt }
            let lastSwitching = before.filter { $0.kind.canSwitchApps }.max { $0.at < $1.at }
            let lastAny = before.max { $0.at < $1.at }
            let switchingNote = lastSwitching.map { "\($0.kind) \(ms(activationAt - $0.at)) before" } ?? "none"
            let anyNote = lastAny.map { "\($0.kind) \(ms(activationAt - $0.at)) before" } ?? "none"
            trace?("STEAL #\(tally.steals): \(describe(app)), last switching input \(switchingNote), last input \(anyNote)\(launchNote)")
        }

        guard let target = lastIntentional, !target.isTerminated, !target.isHidden,
              target.processIdentifier != app.processIdentifier else {
            trace?("  nothing to revert to")
            lastIntentional = app
            return true
        }

        // Input between the activation and this decision may be switching apps
        // itself, so a revert now would fight it.
        if let cancel = firstCancel(after: activationAt) {
            acceptSteal(cancelledBy: cancel, after: "steal", at: activationAt)
            return true
        }

        // A newer activation in front is judged on its own, and focus that is
        // already back needs nothing. Either way this one never ranks.
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier == app.processIdentifier else {
            trace?("  frontmost is already \(describe(front)), nothing to revert")
            return false
        }
        trace?("  reverting to \(describe(target)) \(ms(ProcessInfo.processInfo.systemUptime - activationAt)) after the steal")
        attemptRevert(stealer: app, to: target, with: .activate, tried: [])
        return false
    }

    // MARK: - Revert

    private func attemptRevert(stealer: NSRunningApplication, to target: NSRunningApplication,
                               with method: RevertMethod, tried: [RevertMethod]) {
        let flight = InFlightRevert(
            stealer: stealer, target: target, method: method,
            startedAt: ProcessInfo.processInfo.systemUptime,
            triedMethods: tried + [method])
        inFlight = flight

        switch method {
        case .activate:
            let accepted = target.activate(options: [.activateIgnoringOtherApps])
            trace?("  \(method.rawValue) returned \(accepted)")
        case .axFrontmost:
            let pid = target.processIdentifier
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 1.0)
                let error = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                DispatchQueue.main.async { self?.trace?("  \(method.rawValue) returned AXError \(error.rawValue)") }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revertCheckDelay) { [weak self] in
            self?.checkRevert(flight)
        }
    }

    private func revertLanded(_ flight: InFlightRevert) {
        inFlight = nil
        tally.reverts[flight.method, default: (ok: 0, failed: 0)].ok += 1
        lastIntentional = flight.target
        promptInFront = false
        keep(activations.notice(flight.target, kept: true).released)
    }

    /// Only a flight whose landing was not seen gets here.
    private func checkRevert(_ flight: InFlightRevert) {
        guard isRunning, inFlight?.startedAt == flight.startedAt else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == flight.target.processIdentifier {
            trace?("  \(flight.method.rawValue): OK, frontmost after \(ms(Self.revertCheckDelay)) is \(describe(front))")
            revertLanded(flight)
            return
        }
        inFlight = nil
        tally.reverts[flight.method, default: (ok: 0, failed: 0)].failed += 1
        trace?("  \(flight.method.rawValue): FAILED, frontmost after \(ms(Self.revertCheckDelay)) is \(describe(front))")

        // Input since the call that may switch apps is the user taking over:
        // whatever is in front now is theirs to keep. A stealer still in front
        // ranks after all, as it does when every method has failed.
        let stealerHolds = front?.processIdentifier == flight.stealer.processIdentifier
        if let cancel = firstCancel(after: flight.startedAt) {
            acceptSteal(cancelledBy: cancel, after: "revert call", at: flight.startedAt)
            if stealerHolds { keep(activations.notice(flight.stealer, kept: true).released) }
            return
        }
        guard stealerHolds else { return }
        guard let fallback = RevertMethod.allCases.first(where: { !flight.triedMethods.contains($0) }) else {
            trace?("  giving up, \(describe(front)) keeps focus")
            keep(activations.notice(flight.stealer, kept: true).released)
            return
        }
        attemptRevert(stealer: flight.stealer, to: flight.target, with: fallback, tried: flight.triedMethods)
    }

    /// Secure keyboard entry is on while a focused password field is in front.
    /// The session names the frontmost app as its holder whichever process
    /// turned it on (`FocusIntentSpecs.md`), so this asks only whether it is on
    /// with the app in front. A leaked one lets every steal through while it lasts.
    private static func showsPasswordField(_ app: NSRunningApplication) -> Bool {
        IsSecureEventInputEnabled()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    // MARK: - Trace formatting

    private func describe(_ app: NSRunningApplication?) -> String {
        guard let app else { return "none" }
        return "\(app.localizedName ?? app.bundleIdentifier ?? "?") (\(app.processIdentifier))"
    }

    private func ms(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded()))ms"
    }
}
