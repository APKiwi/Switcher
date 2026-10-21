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

    /// Called once a revert lands, with each app it sent back, latest first.
    var onStealReverted: ((NSRunningApplication) -> Void)?
    /// Every decision as a line of text, for `--focus-probe`.
    var trace: ((String) -> Void)?
    private(set) var tally = Tally()
    private(set) var isRunning = false

    private struct InFlightRevert {
        /// The app holding focus is the last.
        let stealers: [NSRunningApplication]
        var stealer: NSRunningApplication { stealers[stealers.count - 1] }
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
    /// Steals not sent back yet, oldest first. One that lost focus to a newer
    /// steal before its own decision goes back with that one's revert.
    private var unreverted: [NSRunningApplication] = []
    /// Steals sent back whose MRU ranks wait for `restoreRanks`, oldest first.
    private var landed: [NSRunningApplication] = []
    /// Activations noticed and not yet judged.
    private var undecided = 0
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
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        unreverted.removeAll()
        landed.removeAll()
        undecided = 0
        inFlight = nil
        inputs.removeAll()
        lastIntentional = nil
        lastSwitchCause = nil
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
        unreverted.removeAll()
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
            return
        }

        let launchedAt = app.launchDate.map { activationAt - Date().timeIntervalSince($0) }
        undecided += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + FocusIntent.decisionDelay) { [weak self] in
            self?.decide(app, activationAt: activationAt, launchedAt: launchedAt)
        }
    }

    private func decide(_ app: NSRunningApplication, activationAt: TimeInterval, launchedAt: TimeInterval?) {
        undecided = max(0, undecided - 1)
        guard isRunning else { return }
        defer { restoreRanks() }
        let verdict = FocusIntent.classify(activationAt: activationAt, launchedAt: launchedAt,
                                           inputs: inputs, lastSwitchCause: lastSwitchCause)
        let exemption = FocusIntent.exemption(bundleID: app.bundleIdentifier,
                                              isRegularApp: app.activationPolicy == .regular,
                                              showsPasswordField: verdict.isSteal && Self.showsPasswordField(app),
                                              allowed: Preferences.focusGuardAllowedApps)
        let leavingPrompt = promptInFront
        promptInFront = exemption?.mayHoldTyping ?? false
        let launchNote = launchedAt.flatMap { activationAt - $0 < 15 ? ", launched \(ms(activationAt - $0)) before" : nil } ?? ""

        switch verdict {
        case .intended(let cause):
            tally.intended += 1
            lastIntentional = app
            lastSwitchCause = cause
            unreverted.removeAll()
            trace?("intended: \(describe(app)), \(cause.kind) \(ms(activationAt - cause.at)) before\(launchNote)")
        case .launched(let cause):
            tally.launched += 1
            lastIntentional = app
            lastSwitchCause = cause
            unreverted.removeAll()
            trace?("launched: \(describe(app)), \(cause.kind) \(ms(activationAt - cause.at)) before\(launchNote)")
        case .steal:
            if let exemption {
                tally.allowed += 1
                trace?("allowed: \(describe(app)), \(exemption)\(launchNote)")
            } else if leavingPrompt {
                tally.allowed += 1
                lastIntentional = app
                unreverted.removeAll()
                trace?("allowed: \(describe(app)), it took focus from a prompt\(launchNote)")
            } else {
                handleSteal(app, activationAt: activationAt, launchNote: launchNote)
            }
        }
    }

    private func handleSteal(_ app: NSRunningApplication, activationAt: TimeInterval, launchNote: String) {
        unreverted = unreverted.filter { $0.processIdentifier != app.processIdentifier } + [app]
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
            unreverted.removeAll()
            return
        }

        // Input between the activation and this decision may be switching apps
        // itself, so a revert now would fight it.
        if let cancel = firstCancel(after: activationAt) {
            acceptSteal(cancelledBy: cancel, after: "steal", at: activationAt)
            return
        }

        // A newer activation in front decides for itself, and a newer steal's
        // revert takes this one back with it.
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier == app.processIdentifier else {
            trace?("  frontmost is already \(describe(front)), nothing to revert")
            if front?.processIdentifier == target.processIdentifier {
                // Focus is back, with an earlier revert or by itself.
                land(unreverted)
            }
            return
        }
        trace?("  reverting to \(describe(target)) \(ms(ProcessInfo.processInfo.systemUptime - activationAt)) after the steal")
        attemptRevert(stealers: unreverted, to: target, with: .activate, tried: [])
    }

    // MARK: - Revert

    private func attemptRevert(stealers: [NSRunningApplication], to target: NSRunningApplication,
                               with method: RevertMethod, tried: [RevertMethod]) {
        let flight = InFlightRevert(
            stealers: stealers, target: target, method: method,
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
        land(flight.stealers)
        restoreRanks()
    }

    private func land(_ stealers: [NSRunningApplication]) {
        let isLanding = { (app: NSRunningApplication) in
            stealers.contains { $0.processIdentifier == app.processIdentifier }
        }
        unreverted.removeAll(where: isLanding)
        landed.removeAll(where: isLanding)
        landed += stealers
    }

    /// Takes landed steals back out of the MRU order, latest first, once every
    /// activation noticed so far has been judged: each stealer's rank was taken
    /// with the earlier ones still ranked, and one still undecided may join them.
    private func restoreRanks() {
        guard undecided == 0, !landed.isEmpty else { return }
        let stealers = landed
        landed.removeAll()
        stealers.reversed().forEach { onStealReverted?($0) }
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
        // whatever is in front now is theirs to keep.
        if let cancel = firstCancel(after: flight.startedAt) {
            acceptSteal(cancelledBy: cancel, after: "revert call", at: flight.startedAt)
            return
        }
        // Retry only while the stealer still holds focus.
        guard front?.processIdentifier == flight.stealer.processIdentifier,
              let fallback = RevertMethod.allCases.first(where: { !flight.triedMethods.contains($0) }) else { return }
        attemptRevert(stealers: flight.stealers, to: flight.target, with: fallback, tried: flight.triedMethods)
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
