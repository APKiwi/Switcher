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

    /// Called with the stealer once a revert lands.
    var onStealReverted: ((NSRunningApplication) -> Void)?
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
    /// Whether the latest activation was a prompt that may be taking a password.
    private var promptInFront = false
    private var pendingRevert: Timer?
    private var inFlight: InFlightRevert?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastIntentional = NSWorkspace.shared.frontmostApplication
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

        // Global monitors see input bound for other apps, local ones input bound
        // for Switcher's own windows: the panel, Preferences and the menu bar icon.
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        } else {
            trace?("global monitor was refused")
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
        trace?("guarding, starting app \(describe(lastIntentional))")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        pendingRevert?.invalidate()
        pendingRevert = nil
        inFlight = nil
        inputs.removeAll()
        lastIntentional = nil
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
        inputs.append(FocusIntent.Input(kind, at: timestamp))
        let horizon = timestamp - FocusIntent.launchLifetime - 5
        if let first = inputs.first, first.at < horizon {
            inputs.removeAll { $0.at < horizon }
        }
    }

    // MARK: - Activation

    private func appDidActivate(_ app: NSRunningApplication) {
        guard app.processIdentifier != ownPID else { return }
        let activationAt = ProcessInfo.processInfo.systemUptime

        if let flight = inFlight, flight.target.processIdentifier == app.processIdentifier {
            trace?("revert landed on \(describe(app)) \(ms(activationAt - flight.startedAt)) after \(flight.method.rawValue)")
            lastIntentional = app
            promptInFront = false
            onStealReverted?(flight.stealer)
            return
        }

        let launchedAt = app.launchDate.map { activationAt - Date().timeIntervalSince($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + FocusIntent.decisionDelay) { [weak self] in
            self?.decide(app, activationAt: activationAt, launchedAt: launchedAt)
        }
    }

    private func decide(_ app: NSRunningApplication, activationAt: TimeInterval, launchedAt: TimeInterval?) {
        guard isRunning else { return }
        let verdict = FocusIntent.classify(activationAt: activationAt, launchedAt: launchedAt, inputs: inputs)
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
            trace?("intended: \(describe(app)), \(cause.kind) \(ms(activationAt - cause.at)) before\(launchNote)")
        case .launched(let cause):
            tally.launched += 1
            lastIntentional = app
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

        pendingRevert?.invalidate()
        let remaining = max(0, Self.grace - (ProcessInfo.processInfo.systemUptime - activationAt))
        pendingRevert = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            self?.graceExpired(stealer: app, target: target, activationAt: activationAt)
        }
        trace?("  reverting to \(describe(target)) \(ms(Self.grace)) after the steal unless there is deliberate input")
    }

    // MARK: - Revert

    private func graceExpired(stealer: NSRunningApplication, target: NSRunningApplication, activationAt: TimeInterval) {
        pendingRevert = nil
        let front = NSWorkspace.shared.frontmostApplication
        if let cancel = inputs.filter({ $0.kind.cancelsRevert && $0.at > activationAt }).min(by: { $0.at < $1.at }) {
            if let front, front.processIdentifier != ownPID { lastIntentional = front }
            trace?("  revert cancelled by \(cancel.kind) \(ms(cancel.at - activationAt)) after the steal, keeping \(describe(front))")
            return
        }
        guard front?.processIdentifier == stealer.processIdentifier else {
            trace?("  frontmost is already \(describe(front)), nothing to revert")
            return
        }
        guard !target.isTerminated else {
            trace?("  \(describe(target)) has quit, nothing to revert to")
            lastIntentional = stealer
            return
        }
        attemptRevert(stealer: stealer, to: target, with: .activate, tried: [])
    }

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

    private func checkRevert(_ flight: InFlightRevert) {
        guard isRunning, inFlight?.startedAt == flight.startedAt else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let succeeded = front?.processIdentifier == flight.target.processIdentifier
        var result = tally.reverts[flight.method] ?? (0, 0)
        if succeeded { result.ok += 1 } else { result.failed += 1 }
        tally.reverts[flight.method] = result
        trace?("  \(flight.method.rawValue): \(succeeded ? "OK" : "FAILED"), frontmost after \(ms(Self.revertCheckDelay)) is \(describe(front))")

        if !succeeded, front?.processIdentifier == flight.stealer.processIdentifier,
           let fallback = RevertMethod.allCases.first(where: { !flight.triedMethods.contains($0) }) {
            attemptRevert(stealer: flight.stealer, to: flight.target, with: fallback, tried: flight.triedMethods)
            return
        }
        inFlight = nil
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
