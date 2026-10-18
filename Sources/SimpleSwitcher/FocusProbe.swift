import AppKit
import ApplicationServices

/// `--focus-probe`: a timed diagnostic that answers the two questions a focus
/// guard depends on, on the running macOS, with this bundle's own grants.
///
/// 1. Do key presses in other apps reach a global `NSEvent` monitor with only
///    Accessibility granted? A launcher (Spotlight, Raycast, `open` in a
///    terminal) ends with Return, so a guard blind to keys would revert it.
/// 2. Will macOS bring the previous app back when a background app asks from a
///    timer, with no user input behind the request? Two mechanisms are tried in
///    turn: `NSRunningApplication.activate`, which `AppDelegate.activateApp`
///    uses today, and setting `kAXFrontmostAttribute` through Accessibility.
///
/// It registers no hotkeys and never touches the native Cmd+Tab, so it can run
/// beside an installed Switcher. Key presses are counted, never recorded.
final class FocusProbe {

    static let duration: TimeInterval = 120
    /// FocusGuard's window: an activation this soon after input counts as asked for.
    static let intentWindow: TimeInterval = 0.3
    /// How long a steal stands before the revert, so input can still cancel it.
    static let grace: TimeInterval = 1.0
    static let revertCheckDelay: TimeInterval = 0.5

    enum RevertMethod: String, CaseIterable {
        case activate = "NSRunningApplication.activate"
        case axFrontmost = "AX kAXFrontmostAttribute"
    }

    private struct PendingRevert {
        let target: NSRunningApplication
        let timer: Timer
    }

    private struct InFlightRevert {
        let target: NSRunningApplication
        let method: RevertMethod
        let startedAt: TimeInterval
        var triedMethods: [RevertMethod]
    }

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var lastInputAt: TimeInterval = 0
    private var lastInputKind = "none"
    private var inputCounts: [String: Int] = [:]
    private var lastIntentional: NSRunningApplication?
    private var pendingRevert: PendingRevert?
    private var inFlight: InFlightRevert?
    private var stealCount = 0
    private var intentionalCount = 0
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
        let inputMonitoring = CGPreflightListenEventAccess()
        log("Switcher focus probe, \(Int(Self.duration))s, \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("bundle \(Bundle.main.bundlePath)")
        log("Accessibility granted: \(accessibility ? "yes" : "NO")")
        log("Input Monitoring granted: \(inputMonitoring ? "yes" : "no")")
        guard accessibility else {
            log("Accessibility is not granted to this build, so neither question can be answered. Stopping.")
            exit(2)
        }

        lastIntentional = NSWorkspace.shared.frontmostApplication
        log("starting app: \(describe(lastIntentional))")

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appDidActivate(app)
        }

        let kinds: [(NSEvent.EventTypeMask, String)] = [
            (.keyDown, "keyDown"),
            (.flagsChanged, "flagsChanged"),
            ([.leftMouseDown, .rightMouseDown, .otherMouseDown], "mouseDown"),
        ]
        for (mask, kind) in kinds {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.noteInput(kind, at: event.timestamp)
            }) {
                monitors.append(monitor)
            } else {
                log("global monitor for \(kind) was refused")
            }
        }

        Timer.scheduledTimer(withTimeInterval: Self.duration, repeats: false) { [weak self] _ in
            self?.finish()
        }
        log("ready. Type in another app, launch something from Spotlight, and stage a steal (see the handoff).")
    }

    // MARK: - Input

    private func noteInput(_ kind: String, at timestamp: TimeInterval) {
        let first = inputCounts[kind] == nil
        inputCounts[kind, default: 0] += 1
        lastInputAt = max(lastInputAt, timestamp)
        lastInputKind = kind
        if first { log("first \(kind) seen") }

        if let pending = pendingRevert {
            pending.timer.invalidate()
            pendingRevert = nil
            lastIntentional = NSWorkspace.shared.frontmostApplication
            log("revert cancelled by \(kind) during the grace period, keeping \(describe(lastIntentional))")
        }
    }

    // MARK: - Activation

    private func appDidActivate(_ app: NSRunningApplication) {
        guard app.processIdentifier != ownPID else { return }
        let now = ProcessInfo.processInfo.systemUptime

        if let flight = inFlight, flight.target.processIdentifier == app.processIdentifier {
            log("revert landed on \(describe(app)) \(ms(now - flight.startedAt)) after \(flight.method.rawValue)")
            lastIntentional = app
            return
        }

        let inputAge = now - lastInputAt
        let launched = app.launchDate.map { Date().timeIntervalSince($0) }
        let launchNote = launched.flatMap { $0 < 15 ? ", launched \(ms($0)) ago" : nil } ?? ""
        let detail = "last input \(lastInputKind) \(lastInputAt == 0 ? "never" : ms(inputAge) + " before")\(launchNote)"

        if lastInputAt > 0, inputAge <= Self.intentWindow {
            intentionalCount += 1
            lastIntentional = app
            log("intentional: \(describe(app)), \(detail)")
            return
        }

        stealCount += 1
        log("STEAL #\(stealCount): \(describe(app)), \(detail)")
        guard let target = lastIntentional, !target.isTerminated, target.processIdentifier != app.processIdentifier else {
            log("  nothing to revert to")
            lastIntentional = app
            return
        }

        pendingRevert?.timer.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.grace, repeats: false) { [weak self] _ in
            self?.graceExpired()
        }
        pendingRevert = PendingRevert(target: target, timer: timer)
        log("  reverting to \(describe(target)) in \(ms(Self.grace)) unless there is input")
    }

    // MARK: - Revert

    private func graceExpired() {
        guard let pending = pendingRevert else { return }
        pendingRevert = nil
        let primary: RevertMethod = stealCount % 2 == 1 ? .activate : .axFrontmost
        attemptRevert(to: pending.target, with: primary, tried: [])
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
        let keyDowns = inputCounts["keyDown"] ?? 0
        log("")
        log("Summary")
        log("  input seen: keyDown \(keyDowns), flagsChanged \(inputCounts["flagsChanged"] ?? 0), mouseDown \(inputCounts["mouseDown"] ?? 0)")
        log("  activations: intentional \(intentionalCount), steals \(stealCount)")
        for method in RevertMethod.allCases {
            let tally = revertResults[method] ?? (0, 0)
            log("  revert via \(method.rawValue): ok \(tally.ok), failed \(tally.failed)")
        }

        let inputMonitoring = CGPreflightListenEventAccess()
        let keyVerdict: String
        if keyDowns == 0 {
            keyVerdict = "FAIL, no key presses arrived. A key-blind guard would revert launcher and Return-driven switches."
        } else if inputMonitoring {
            keyVerdict = "inconclusive, key presses arrived but Input Monitoring is granted, so Accessibility alone is unproven."
        } else {
            keyVerdict = "PASS, key presses arrive with Accessibility only."
        }
        log("  question 1, key visibility: \(keyVerdict)")

        let anyRevertWorked = revertResults.values.contains { $0.ok > 0 }
        let revertVerdict = revertResults.isEmpty
            ? "untested, no steal was staged."
            : (anyRevertWorked ? "PASS for the methods marked ok above." : "FAIL, macOS refused every revert.")
        log("  question 2, timer-driven revert: \(revertVerdict)")
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
