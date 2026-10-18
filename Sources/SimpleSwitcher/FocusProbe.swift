import AppKit
import ApplicationServices
import SwitcherKernels

/// `--focus-probe`: a timed diagnostic for the planned focus guard. It runs the
/// `FocusIntent` rules live and reverts what they call a steal, so a run shows
/// how the guard would behave on this Mac, with this bundle's own grants.
///
/// The first run settled the two platform questions (`FocusIntentSpecs.md`):
/// key presses reach a global monitor with Accessibility only, and
/// `NSRunningApplication.activate` from a timer brings the previous app back.
/// The `kAXFrontmostAttribute` fallback stays in case a later macOS refuses.
///
/// It registers no hotkeys and never touches the native Cmd+Tab, so it can run
/// beside an installed Switcher. Key presses are classified and counted, never
/// recorded.
final class FocusProbe {

    static let duration: TimeInterval = 120
    /// How long a steal stands before the revert, so deliberate input can cancel it.
    static let grace: TimeInterval = 1.0
    static let revertCheckDelay: TimeInterval = 0.5

    enum RevertMethod: String, CaseIterable {
        case activate = "NSRunningApplication.activate"
        case axFrontmost = "AX kAXFrontmostAttribute"
    }

    private struct InFlightRevert {
        let target: NSRunningApplication
        let method: RevertMethod
        let startedAt: TimeInterval
        var triedMethods: [RevertMethod]
    }

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var inputs: [FocusIntent.Input] = []
    private var inputCounts: [String: Int] = [:]
    private var lastFlags: FocusIntent.Modifiers = []
    private var lastIntentional: NSRunningApplication?
    private var pendingRevert: Timer?
    private var inFlight: InFlightRevert?
    private var steals: [String] = []
    private var intendedCount = 0
    private var launchedCount = 0
    private var revertResults: [RevertMethod: (ok: Int, failed: Int)] = [:]
    private var monitors: [Any] = []

    private static var session: FocusProbe?

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let probe = FocusProbe()
        session = probe
        probe.start()
        app.run()
        exit(0)
    }

    private func start() {
        let accessibility = AXIsProcessTrusted()
        log("Switcher focus probe, \(Int(Self.duration))s, \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("bundle \(Bundle.main.bundlePath)")
        log("Accessibility granted: \(accessibility ? "yes" : "NO")")
        log("listen access (Accessibility covers it on macOS 27): \(CGPreflightListenEventAccess() ? "yes" : "no")")
        guard accessibility else {
            log("Accessibility is not granted to this build, so the probe cannot see input. Stopping.")
            exit(2)
        }

        lastIntentional = NSWorkspace.shared.frontmostApplication
        log("starting app: \(describe(lastIntentional))")

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appDidActivate(app)
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.record(.spaceChange, at: ProcessInfo.processInfo.systemUptime)
            self?.log("Space changed")
        }

        addMonitor(.keyDown) { [weak self] event in
            self?.record(FocusIntent.keyKind(keyCode: event.keyCode, modifiers: Self.modifiers(event)), at: event.timestamp)
        }
        addMonitor(.flagsChanged) { [weak self] event in
            guard let self else { return }
            let current = Self.modifiers(event)
            record(FocusIntent.flagsKind(from: lastFlags, to: current), at: event.timestamp)
            lastFlags = current
        }
        addMonitor([.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.record(.click, at: event.timestamp)
        }

        Timer.scheduledTimer(withTimeInterval: Self.duration, repeats: false) { [weak self] _ in
            self?.finish()
        }
        log("ready")
    }

    private func addMonitor(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(monitor)
        } else {
            log("global monitor for \(mask) was refused")
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

    // MARK: - Input

    private func record(_ kind: FocusIntent.InputKind, at timestamp: TimeInterval) {
        let name = "\(kind)"
        if inputCounts[name] == nil { log("first \(name) seen") }
        inputCounts[name, default: 0] += 1
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
            log("revert landed on \(describe(app)) \(ms(activationAt - flight.startedAt)) after \(flight.method.rawValue)")
            lastIntentional = app
            return
        }

        let launchedAt = app.launchDate.map { activationAt - Date().timeIntervalSince($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + FocusIntent.decisionDelay) { [weak self] in
            self?.decide(app, activationAt: activationAt, launchedAt: launchedAt)
        }
    }

    private func decide(_ app: NSRunningApplication, activationAt: TimeInterval, launchedAt: TimeInterval?) {
        let verdict = FocusIntent.classify(activationAt: activationAt, launchedAt: launchedAt, inputs: inputs)
        let launchNote = launchedAt.flatMap { activationAt - $0 < 15 ? ", launched \(ms(activationAt - $0)) before" : nil } ?? ""

        switch verdict {
        case .intended(let cause):
            intendedCount += 1
            lastIntentional = app
            log("intended: \(describe(app)), \(cause.kind) \(ms(activationAt - cause.at)) before\(launchNote)")
        case .launched(let cause):
            launchedCount += 1
            lastIntentional = app
            log("launched: \(describe(app)), \(cause.kind) \(ms(activationAt - cause.at)) before\(launchNote)")
        case .steal:
            handleSteal(app, activationAt: activationAt, launchNote: launchNote)
        }
    }

    private func handleSteal(_ app: NSRunningApplication, activationAt: TimeInterval, launchNote: String) {
        let before = inputs.filter { $0.at <= activationAt }
        let lastSwitching = before.filter { $0.kind.canSwitchApps }.max { $0.at < $1.at }
        let lastAny = before.max { $0.at < $1.at }
        let switchingNote = lastSwitching.map { "\($0.kind) \(ms(activationAt - $0.at)) before" } ?? "none"
        let anyNote = lastAny.map { "\($0.kind) \(ms(activationAt - $0.at)) before" } ?? "none"

        steals.append("\(String(format: "%.1f", activationAt - startedAt))s \(describe(app))")
        log("STEAL #\(steals.count): \(describe(app)), last switching input \(switchingNote), last input \(anyNote)\(launchNote)")

        guard let target = lastIntentional, !target.isTerminated, target.processIdentifier != app.processIdentifier else {
            log("  nothing to revert to")
            lastIntentional = app
            return
        }

        pendingRevert?.invalidate()
        let remaining = max(0, Self.grace - (ProcessInfo.processInfo.systemUptime - activationAt))
        pendingRevert = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            self?.graceExpired(stealer: app, target: target, activationAt: activationAt)
        }
        log("  reverting to \(describe(target)) \(ms(Self.grace)) after the steal unless there is deliberate input")
    }

    // MARK: - Revert

    private func graceExpired(stealer: NSRunningApplication, target: NSRunningApplication, activationAt: TimeInterval) {
        pendingRevert = nil
        if let cancel = inputs.filter({ $0.kind.cancelsRevert && $0.at > activationAt }).min(by: { $0.at < $1.at }) {
            lastIntentional = NSWorkspace.shared.frontmostApplication
            log("  revert cancelled by \(cancel.kind) \(ms(cancel.at - activationAt)) after the steal, keeping \(describe(lastIntentional))")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier == stealer.processIdentifier else {
            log("  frontmost is already \(describe(front)), nothing to revert")
            return
        }
        attemptRevert(to: target, with: .activate, tried: [])
    }

    private func attemptRevert(to target: NSRunningApplication, with method: RevertMethod, tried: [RevertMethod]) {
        let flight = InFlightRevert(
            target: target, method: method,
            startedAt: ProcessInfo.processInfo.systemUptime,
            triedMethods: tried + [method])
        inFlight = flight

        switch method {
        case .activate:
            let accepted = target.activate(options: [.activateIgnoringOtherApps])
            log("  \(method.rawValue) returned \(accepted)")
        case .axFrontmost:
            let pid = target.processIdentifier
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 1.0)
                let error = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                DispatchQueue.main.async { self?.log("  \(method.rawValue) returned AXError \(error.rawValue)") }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revertCheckDelay) { [weak self] in
            self?.checkRevert(flight)
        }
    }

    private func checkRevert(_ flight: InFlightRevert) {
        let front = NSWorkspace.shared.frontmostApplication
        let succeeded = front?.processIdentifier == flight.target.processIdentifier
        var tally = revertResults[flight.method] ?? (0, 0)
        if succeeded { tally.ok += 1 } else { tally.failed += 1 }
        revertResults[flight.method] = tally
        log("  \(flight.method.rawValue): \(succeeded ? "OK" : "FAILED"), frontmost after \(ms(Self.revertCheckDelay)) is \(describe(front))")

        if !succeeded, let fallback = RevertMethod.allCases.first(where: { !flight.triedMethods.contains($0) }) {
            attemptRevert(to: flight.target, with: fallback, tried: flight.triedMethods)
            return
        }
        inFlight = nil
    }

    // MARK: - Report

    private func finish() {
        log("")
        log("Summary")
        let counts = inputCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        log("  input seen: \(counts.isEmpty ? "none" : counts)")
        log("  activations: intended \(intendedCount), launched \(launchedCount), steals \(steals.count)")
        for (index, steal) in steals.enumerated() {
            log("    steal #\(index + 1) at \(steal)")
        }
        for method in RevertMethod.allCases {
            let tally = revertResults[method] ?? (0, 0)
            log("  revert via \(method.rawValue): ok \(tally.ok), failed \(tally.failed)")
        }
        log("  Check each steal above: was it really one you did not ask for?")
        exit(0)
    }

    // MARK: - Formatting

    private func log(_ message: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        print(String(format: "%7.3f ", elapsed) + message)
    }

    private func describe(_ app: NSRunningApplication?) -> String {
        guard let app else { return "none" }
        return "\(app.localizedName ?? app.bundleIdentifier ?? "?") (\(app.processIdentifier))"
    }

    private func ms(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded()))ms"
    }
}
