import AppKit
import ApplicationServices
import SwitcherKernels

/// Sends focus back when another app takes it unasked, such as an app that
/// brings itself forward while it boots.
///
/// `FocusIntent` decides what was asked for. This class feeds it input and
/// activations and does the revert. A steal stands for `grace` first, so a
/// click on the stealer keeps it. It fails open: security prompts, agents and
/// allowed apps keep focus (`FocusIntent.exemption`), and so does an app that
/// takes focus from in front of a prompt.
///
/// Needs only Accessibility: on macOS 27 global monitors receive other apps'
/// key presses with it (`FocusIntentSpecs.md`). Key presses are classified and
/// counted, never recorded.
final class FocusGuard {

    /// How long a steal stands before the revert, so deliberate input can keep it.
    static let grace: TimeInterval = 1.0
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

    private struct PendingRevert {
        let timer: Timer
        let activationAt: TimeInterval
        /// This steal and any it replaced, oldest first.
        let stealers: [NSRunningApplication]
    }

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
    private var pendingRevert: PendingRevert?
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
        pendingRevert?.timer.invalidate()
        pendingRevert = nil
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
        // Settled now rather than when the grace ends, so a newer steal in that
        // second reverts to the app the user just accepted.
        if kind.cancelsRevert, let pending = pendingRevert, timestamp > pending.activationAt {
            acceptSteal(at: pending.activationAt, cancelledBy: input)
        }
    }

    private func firstCancel(after time: TimeInterval) -> FocusIntent.Input? {
        inputs.filter { $0.kind.cancelsRevert && $0.at > time }.min { $0.at < $1.at }
    }

    /// Deliberate input after a steal means the user is dealing with it: whatever
    /// is in front now is where focus belongs.
    private func acceptSteal(at activationAt: TimeInterval, cancelledBy cause: FocusIntent.Input) {
        pendingRevert?.timer.invalidate()
        pendingRevert = nil
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ownPID { lastIntentional = front }
        lastSwitchCause = cause
        trace?("  revert cancelled by \(cause.kind) \(ms(cause.at - activationAt)) after the steal, keeping \(describe(front))")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + FocusIntent.decisionDelay) { [weak self] in
            self?.decide(app, activationAt: activationAt, launchedAt: launchedAt)
        }
    }

    private func decide(_ app: NSRunningApplication, activationAt: TimeInterval, launchedAt: TimeInterval?) {
        guard isRunning else { return }
        let verdict = FocusIntent.classify(activationAt: activationAt, launchedAt: launchedAt,
                                           inputs: inputs, lastSwitchCause: lastSwitchCause)
        let exemption = FocusIntent.exemption(bundleID: app.bundleIdentifier,
                                              isRegularApp: app.activationPolicy == .regular,
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
        case .launched(let cause):
            tally.launched += 1
            lastIntentional = app
            lastSwitchCause = cause
            trace?("launched: \(describe(app)), \(cause.kind) \(ms(activationAt - cause.at)) before\(launchNote)")
        case .steal:
            if let exemption {
                tally.allowed += 1
                trace?("allowed: \(describe(app)), \(exemption)\(launchNote)")
            } else if leavingPrompt {
                tally.allowed += 1
                lastIntentional = app
                trace?("allowed: \(describe(app)), it took focus from a prompt\(launchNote)")
            } else {
                handleSteal(app, activationAt: activationAt, launchNote: launchNote)
            }
        }
    }

    private func handleSteal(_ app: NSRunningApplication, activationAt: TimeInterval, launchNote: String) {
        // A newer steal replaces the pending one, and its revert sends both back.
        // Input that accepted the older stealer was already settled in `record`.
        let stealers = (pendingRevert?.stealers ?? []).filter { $0.processIdentifier != app.processIdentifier } + [app]
        pendingRevert?.timer.invalidate()
        pendingRevert = nil
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
            return
        }

        // Input between the activation and this decision.
        if let cancel = firstCancel(after: activationAt) {
            acceptSteal(at: activationAt, cancelledBy: cancel)
            return
        }

        let remaining = max(0, Self.grace - (ProcessInfo.processInfo.systemUptime - activationAt))
        let timer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            self?.graceExpired(stealers: stealers, target: target)
        }
        pendingRevert = PendingRevert(timer: timer, activationAt: activationAt, stealers: stealers)
        trace?("  reverting to \(describe(target)) \(ms(Self.grace)) after the steal unless there is deliberate input")
    }

    // MARK: - Revert

    private func graceExpired(stealers: [NSRunningApplication], target: NSRunningApplication) {
        pendingRevert = nil
        let stealer = stealers[stealers.count - 1]
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier == stealer.processIdentifier else {
            trace?("  frontmost is already \(describe(front)), nothing to revert")
            return
        }
        guard !target.isTerminated else {
            trace?("  \(describe(target)) has quit, nothing to revert to")
            lastIntentional = stealer
            return
        }
        attemptRevert(stealers: stealers, to: target, with: .activate, tried: [])
    }

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
        // Each stealer's rank was taken with the earlier ones still ranked.
        flight.stealers.reversed().forEach { onStealReverted?($0) }
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

        // Retry only while the stealer still holds focus and the user has not
        // acted since: a click elsewhere in this half second is theirs to keep.
        guard front?.processIdentifier == flight.stealer.processIdentifier,
              firstCancel(after: flight.startedAt) == nil,
              let fallback = RevertMethod.allCases.first(where: { !flight.triedMethods.contains($0) }) else { return }
        attemptRevert(stealers: flight.stealers, to: flight.target, with: fallback, tried: flight.triedMethods)
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
