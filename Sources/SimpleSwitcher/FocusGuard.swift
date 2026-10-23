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
        case window = "WindowServer exact window"
        case activate = "NSRunningApplication.activate"
        case axRaise = "AX raise saved window"
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
        let ticket: FocusRestoration.Ticket
        let window: FocusWindowContext.Snapshot?
        let lease: RestoreLease
    }

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var inputs: [FocusIntent.Input] = []
    private var lastFlags: FocusIntent.Modifiers = []
    /// Where focus belongs: the latest app brought forward on purpose.
    private var lastIntentional: NSRunningApplication?
    private var lastWindow: FocusWindowContext.Snapshot?
    private let windows = FocusWindowContext()
    private let gestures = FocusGestureMonitor()
    private var restoration = FocusRestoration()
    private var browserHandoff = BrowserHandoff()
    private var browsers = Set<String>()
    private struct LinkInspection {
        let app: NSRunningApplication
        let point: CGPoint?
        let cause: FocusIntent.Input
    }
    private var linkInspection = BrowserHandoff.Inspection<LinkInspection>()
    private var linkWaiters: [UUID: (Bool) -> Void] = [:]
    private var linkEpoch = 0
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
        promptInFront = lastIntentional.map(isKnownPrompt) ?? false
        lastWindow = nil
        restoration = FocusRestoration()
        browserHandoff = BrowserHandoff()
        // Resolves handlers only. These URLs are never opened or fetched.
        browsers = Set([URL(string: "http://example.invalid")!, URL(string: "https://example.invalid")!]
            .flatMap { NSWorkspace.shared.urlsForApplications(toOpen: $0) }
            .compactMap { Bundle(url: $0)?.bundleIdentifier })
            .subtracting(["com.choosyosx.Choosy", Bundle.main.bundleIdentifier ?? ""])
        windows.onChange = { [weak self] snapshot in
            guard let self, self.isRunning,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { return }
            let protected = snapshot.mayBePrompt || IsSecureEventInputEnabled()
                || NSRunningApplication(processIdentifier: snapshot.pid).map(self.isKnownPrompt) == true
            self.promptInFront = protected
            if protected {
                self.cancelRestore(reason: "prompt window appeared")
                self.cancelBrowserHandoff()
            }
            if self.lastIntentional?.processIdentifier == snapshot.pid, self.inFlight == nil {
                self.lastWindow = snapshot
            }
        }
        if let app = lastIntentional { windows.watch(app.processIdentifier) }
        gestures.onGesture = { [weak self] at in
            guard let self, self.isRunning else { return }
            self.record(.gesture, at: at)
        }
        gestures.start()

        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.appDidActivate(app)
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.record(.spaceChange, at: now)
                if !self.gestures.isAvailable {
                    // With no gesture observer, a swipe is indistinguishable
                    // from a programmatic change. Leave the user in control.
                    self.record(.gesture, at: now)
                    self.cancelRestore(reason: "Space changed without gesture observation")
                }
                self.trace?("Space changed (gesture observer \(self.gestures.isAvailable ? "available" : "unavailable"))")
            },
        ]
        trace?("gesture observer: \(gestures.isAvailable ? "available" : "unavailable, Space changes fail open")")
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
        cancelRestore(reason: "guard stopped")
        windows.stop()
        gestures.stop()
        cancelBrowserHandoff()
        linkInspection = BrowserHandoff.Inspection()
        linkWaiters.removeAll()
        lastWindow = nil
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
        let source = NSWorkspace.shared.frontmostApplication
        switch event.type {
        case .keyDown:
            let kind = FocusIntent.keyKind(keyCode: event.keyCode, modifiers: Self.modifiers(event))
            record(kind, at: event.timestamp)
            if kind == .confirmKey, let source {
                inspectLink(in: source, point: nil, cause: .init(kind, at: event.timestamp))
            }
        case .flagsChanged:
            let current = Self.modifiers(event)
            record(FocusIntent.flagsKind(from: lastFlags, to: current), at: event.timestamp)
            lastFlags = current
        default:
            record(.click, at: event.timestamp)
            if event.type == .leftMouseDown, let source {
                inspectLink(in: source, point: event.cgEvent?.location,
                            cause: .init(.click, at: event.timestamp))
            }
        }
    }

    private func inspectLink(in app: NSRunningApplication, point: CGPoint?, cause: FocusIntent.Input) {
        guard !browsers.isEmpty else { return }
        let request = LinkInspection(app: app, point: point, cause: cause)
        guard linkInspection.begin(request) else { return }
        runLinkInspection(request)
    }

    private func runLinkInspection(_ request: LinkInspection) {
        let (app, point, cause) = (request.app, request.point, request.cause)
        let session = self.session
        let epoch = linkEpoch
        windows.inspectLink(in: app.processIdentifier, at: point) { [weak self] isLink in
            guard let self, self.isRunning, self.session == session else { return }
            if let pending = self.linkInspection.finish() {
                self.runLinkInspection(pending)
                return
            }
            if isLink, self.linkEpoch == epoch {
                self.browserHandoff.recordLink(cause, destinations: self.browsers)
                self.trace?("link action in \(self.describe(app)), browser handoff armed")
            }
            let waiters = Array(self.linkWaiters.values)
            self.linkWaiters.removeAll()
            waiters.forEach { $0(true) }
        }
    }

    private func cancelBrowserHandoff() {
        linkEpoch += 1
        linkInspection.cancelPending()
        browserHandoff.cancel()
    }

    /// The pending link query may be behind a window query on the AX queue.
    /// A browser decision must wait for the complete coalesced input chain,
    /// not merely whichever AX operation happened to be enqueued first.
    private func afterLinkEvidence(for app: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        guard let id = app.bundleIdentifier, browsers.contains(id), linkInspection.isBusy else {
            completion(true)
            return
        }
        let request = UUID()
        linkWaiters[request] = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let completion = self?.linkWaiters.removeValue(forKey: request) else { return }
            completion(false)
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
        if kind == .gesture, let previous = inputs.last, previous.kind == .gesture,
           timestamp - previous.at < 0.05 { return }
        if kind.cancelsRevert, let flight = inFlight {
            cancelRestore(reason: "new \(kind) input")
            acceptSteal(cancelledBy: .init(kind, at: timestamp), after: "revert call", at: flight.startedAt)
            if let front = NSWorkspace.shared.frontmostApplication {
                keep(activations.notice(front, kept: true).released)
            }
        }
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
    private func acceptSteal(cancelledBy cause: FocusIntent.Input, after event: String, at time: TimeInterval,
                             snapshot: FocusWindowContext.Snapshot? = nil) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ownPID {
            remember(front)
            if let snapshot, snapshot.pid == front.processIdentifier { lastWindow = snapshot }
        }
        lastSwitchCause = cause
        trace?("  revert cancelled by \(cause.kind) \(ms(cause.at - time)) after the \(event), keeping \(describe(front))")
    }

    private func remember(_ app: NSRunningApplication) {
        lastIntentional = app
        lastWindow = windows.current?.pid == app.processIdentifier ? windows.current : nil
        windows.watch(app.processIdentifier)
    }

    // MARK: - Activation

    private func appDidActivate(_ app: NSRunningApplication) {
        let activationAt = ProcessInfo.processInfo.systemUptime
        let leavingPrompt = promptInFront
        let protected = isKnownPrompt(app) || IsSecureEventInputEnabled()
        restoration.activated(app.processIdentifier, protected: protected)
        if restoration.pending == nil { cancelRestore(reason: "new activation or prompt") }
        promptInFront = protected
        if protected { cancelBrowserHandoff() }
        windows.watch(app.processIdentifier)
        if let flight = inFlight, flight.target.processIdentifier == app.processIdentifier {
            trace?("restore target activated, checking saved window")
            verifyLanding(flight)
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
        let immediate = FocusIntent.classify(activationAt: activationAt, launchedAt: nil,
                                             inputs: inputs, lastSwitchCause: lastSwitchCause)
        let intendedNow = !immediate.isSteal
        if case .intended(let cause) = immediate {
            remember(app)
            lastSwitchCause = cause
        }
        let noticed = activations.notice(app, kept: intendedNow ? true : nil)
        keep(noticed.released)
        let session = self.session
        DispatchQueue.main.asyncAfter(deadline: .now() + FocusIntent.decisionDelay) { [weak self] in
            guard let self, self.isRunning, self.session == session else { return }
            self.afterLinkEvidence(for: app) { [weak self] evidenceReady in
                guard let self, self.isRunning, self.session == session else { return }
                guard evidenceReady else {
                    self.trace?("allowed: \(self.describe(app)), link inspection timed out")
                    self.keep(self.activations.settle(noticed.id, kept: true))
                    return
                }
                self.windows.inspect(app.processIdentifier) { [weak self] snapshot in
                    guard let self, self.isRunning, self.session == session else { return }
                    let kept = self.decide(app, activationAt: activationAt, launchedAt: launchedAt, snapshot: snapshot, leavingPrompt: leavingPrompt)
                    self.keep(self.activations.settle(noticed.id, kept: kept))
                }
            }
        }
    }

    private func keep(_ apps: [NSRunningApplication]) {
        apps.forEach { onKeep?($0) }
    }

    /// Returns whether the app keeps focus, and so its rank.
    private func decide(_ app: NSRunningApplication, activationAt: TimeInterval, launchedAt: TimeInterval?,
                        snapshot: FocusWindowContext.Snapshot, leavingPrompt: Bool) -> Bool {
        let verdict = FocusIntent.classify(activationAt: activationAt, launchedAt: launchedAt,
                                           inputs: inputs, lastSwitchCause: lastSwitchCause)
        // Historical decisions may settle their MRU position, but never replace
        // the current restore target or prompt state after a newer activation.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return !verdict.isSteal || isKnownPrompt(app)
        }
        let showsPasswordField = Self.showsPasswordField(app) || snapshot.mayBePrompt
        let exemption = FocusIntent.exemption(bundleID: app.bundleIdentifier,
                                              isRegularApp: app.activationPolicy == .regular,
                                              showsPasswordField: showsPasswordField,
                                              allowed: Preferences.focusGuardAllowedApps)
        promptInFront = exemption?.mayHoldTyping ?? false
        if promptInFront {
            cancelRestore(reason: "protected activation")
            cancelBrowserHandoff()
        }
        let handoff = browserHandoff.consume(bundleID: app.bundleIdentifier, at: activationAt,
                                              inputs: inputs, lastSwitchCause: lastSwitchCause)
        if let handoff {
            lastIntentional = app
            lastWindow = snapshot
            lastSwitchCause = handoff
            tally.intended += 1
            trace?("intended browser handoff: \(describe(app)), link action \(ms(activationAt - handoff.at)) before")
            return true
        }
        let launchNote = launchedAt.flatMap { activationAt - $0 < 15 ? ", launched \(ms(activationAt - $0)) before" : nil } ?? ""

        switch verdict {
        case .intended(let cause):
            tally.intended += 1
            lastIntentional = app
            lastWindow = snapshot
            lastSwitchCause = cause
            trace?("intended: \(describe(app)), \(cause.kind) \(ms(activationAt - cause.at)) before\(launchNote)")
            return true
        case .launched(let cause):
            tally.launched += 1
            lastIntentional = app
            lastWindow = snapshot
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
                lastWindow = snapshot
                trace?("allowed: \(describe(app)), it took focus from a prompt\(launchNote)")
                return true
            }
            if snapshot.inspectionFailed {
                trace?("allowed: \(describe(app)), Accessibility inspection unavailable")
                cancelRestore(reason: "prompt inspection unavailable")
                return true
            }
            return handleSteal(app, activationAt: activationAt, launchNote: launchNote, snapshot: snapshot)
        }
    }

    /// Returns whether the stealer keeps focus.
    private func handleSteal(_ app: NSRunningApplication, activationAt: TimeInterval, launchNote: String,
                             snapshot: FocusWindowContext.Snapshot) -> Bool {
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
            remember(app)
            return true
        }

        // Input between the activation and this decision may be switching apps
        // itself, so a revert now would fight it.
        if let cancel = firstCancel(after: activationAt) {
            acceptSteal(cancelledBy: cancel, after: "steal", at: activationAt, snapshot: snapshot)
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
        return !attemptRevert(stealer: app, to: target, with: lastWindow?.windowID == nil ? .activate : .window, tried: [])
    }

    // MARK: - Revert

    private func cancelRestore(reason: String) {
        if let flight = inFlight {
            flight.lease.cancel()
            trace?("  restore cancelled: \(reason)")
        }
        inFlight = nil
        restoration.cancel()
    }

    private func isKnownPrompt(_ app: NSRunningApplication) -> Bool {
        FocusIntent.exemption(bundleID: app.bundleIdentifier, isRegularApp: app.activationPolicy == .regular,
                              allowed: [])?.mayHoldTyping == true
    }

    @discardableResult
    private func attemptRevert(stealer: NSRunningApplication, to target: NSRunningApplication,
                               with method: RevertMethod, tried: [RevertMethod]) -> Bool {
        cancelRestore(reason: "superseded restore")
        let saved = lastWindow?.pid == target.processIdentifier ? lastWindow : nil
        if let windowID = saved?.windowID, !FocusWindowAPI.exists(windowID, for: target.processIdentifier) {
            trace?("  saved window no longer exists, leaving focus alone")
            return false
        }
        let ticket = restoration.begin(stealer: stealer.processIdentifier, target: target.processIdentifier,
                                       window: saved?.windowID)
        let flight = InFlightRevert(stealer: stealer, target: target, method: method,
                                   startedAt: ProcessInfo.processInfo.systemUptime, triedMethods: tried + [method],
                                   ticket: ticket, window: saved, lease: RestoreLease())
        inFlight = flight
        let protected = promptInFront || IsSecureEventInputEnabled() || FocusWindowAPI.hasVisiblePrompt()
        guard restoration.canRestore(ticket, frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                     protected: protected), !target.isTerminated, !target.isHidden else {
            cancelRestore(reason: "prompt or foreground changed before restore")
            return false
        }

        switch method {
        case .window:
            let accepted = saved?.windowID.map { FocusWindowAPI.activate(pid: target.processIdentifier, window: $0) } ?? false
            trace?("  exact window \(saved?.windowID ?? 0) activation accepted: \(accepted)")
        case .activate:
            let accepted = target.activate(options: [.activateIgnoringOtherApps])
            trace?("  app activation accepted: \(accepted)")
        case .axRaise:
            guard let window = saved?.window else { cancelRestore(reason: "saved window unavailable"); return false }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Read the cancellation lease and live foreground immediately
                // before the IPC, never from mutable main-thread guard state.
                let front = NSWorkspace.shared.frontmostApplication
                guard flight.lease.isValid, !IsSecureEventInputEnabled(), !FocusWindowAPI.hasVisiblePrompt(),
                      front?.processIdentifier == target.processIdentifier else { return }
                AXUIElementSetMessagingTimeout(window, 0.1)
                guard flight.lease.isValid else { return }
                let error = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                DispatchQueue.main.async { self?.trace?("  AX raise returned \(error.rawValue)") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revertCheckDelay) { [weak self] in
            self?.checkRevert(flight)
        }
        return true
    }

    private func verifyLanding(_ flight: InFlightRevert, completion: ((Bool) -> Void)? = nil) {
        windows.inspect(flight.target.processIdentifier) { [weak self] snapshot in
            guard let self, self.isRunning, self.inFlight?.ticket == flight.ticket else { return }
            let landed = self.restoration.landed(flight.ticket,
                frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                window: snapshot.windowID,
                onScreen: snapshot.windowID.map(FocusWindowAPI.isOnScreen) ?? false)
            if landed {
                self.trace?("  restore verified (\(flight.ticket.window == nil ? "app only" : "exact window")): \(self.describe(flight.target)), window \(snapshot.windowID ?? 0)")
                self.inFlight = nil
                flight.lease.cancel()
                self.restoration.cancel()
                self.tally.reverts[flight.method, default: (ok: 0, failed: 0)].ok += 1
                self.lastIntentional = flight.target
                self.lastWindow = snapshot
                self.promptInFront = snapshot.mayBePrompt || Self.showsPasswordField(flight.target)
                self.keep(self.activations.notice(flight.target, kept: true).released)
            }
            completion?(landed)
        }
    }

    private func checkRevert(_ flight: InFlightRevert) {
        guard isRunning, inFlight?.ticket == flight.ticket else { return }
        verifyLanding(flight) { [weak self] landed in
            guard let self, !landed, self.inFlight?.ticket == flight.ticket else { return }
            self.tally.reverts[flight.method, default: (ok: 0, failed: 0)].failed += 1
            let front = NSWorkspace.shared.frontmostApplication
            let protected = self.promptInFront || IsSecureEventInputEnabled() || FocusWindowAPI.hasVisiblePrompt()
            guard self.restoration.canRestore(flight.ticket, frontmost: front?.processIdentifier, protected: protected) else {
                self.cancelRestore(reason: "foreground or protection changed during restore")
                return
            }
            if let cancel = self.firstCancel(after: flight.startedAt) {
                self.cancelRestore(reason: "new input during restore")
                self.acceptSteal(cancelledBy: cancel, after: "revert call", at: flight.startedAt)
                return
            }
            guard let fallback = RevertMethod.allCases.first(where: {
                !flight.triedMethods.contains($0) && ($0 != .window || flight.window?.windowID != nil)
                    && ($0 != .axRaise || flight.window?.window != nil)
            }) else {
                self.trace?("  restore unverified, giving up with \(self.describe(front)) in front")
                self.cancelRestore(reason: "restore methods exhausted")
                if let front { self.keep(self.activations.notice(front, kept: true).released) }
                return
            }
            self.attemptRevert(stealer: flight.stealer, to: flight.target, with: fallback, tried: flight.triedMethods)
        }
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
        return "\(app.localizedName ?? "?") [\(app.bundleIdentifier ?? "no bundle id")] (\(app.processIdentifier))"
    }

    private func ms(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded()))ms"
    }
}

/// The AX worker may still be queued when a prompt appears or the guard stops.
/// Main-thread invalidation reaches it without touching unsynchronized state.
private final class RestoreLease {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }
    func cancel() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}
