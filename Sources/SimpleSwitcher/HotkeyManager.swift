import Cocoa
import Carbon
import ApplicationServices

protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyTriggered()
    func modifierKeyReleased()
    func keyPressed(_ keyCode: UInt16)
    func shiftPressed()
    func mouseClicked(at point: CGPoint)
}

class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private static let signature: OSType = {
        "smpl".utf16.reduce(0) { ($0 << 8) + OSType($1) }
    }()

    private var hotKeyPressedHandler: EventHandlerRef?
    private var tabHotKeyRef: EventHotKeyRef?
    private var tabOptionHotKeyRef: EventHotKeyRef?
    private var graveOptionHotKeyRef: EventHotKeyRef?
    private var activeHotKeyRefs: [EventHotKeyRef?] = []
    private var eventTap: CFMachPort?

    // Dedicated thread + run loop that services the event tap, so its callback is
    // never starved by main-thread UI work (see setupEventTap for rationale).
    private var eventTapThread: Thread?
    private var eventTapRunLoop: CFRunLoop?

    // Serial queue for thread-safe state access
    private let stateQueue = DispatchQueue(label: "com.simpleswitcher.state")

    // Backstop watchdog (see startCmdWatchdog) — polls live modifier state while
    // the panel is active in case the .listenOnly tap drops the Cmd-up event.
    private var cmdWatchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.simpleswitcher.cmdwatchdog")

    // State protected by stateQueue
    private var _isActive = false
    private var _shiftWasDown = false

    var isActive: Bool {
        get { stateQueue.sync { _isActive } }
        set { stateQueue.sync { _isActive = newValue } }
    }

    private var shiftWasDown: Bool {
        get { stateQueue.sync { _shiftWasDown } }
        set { stateQueue.sync { _shiftWasDown = newValue } }
    }

    /// Which physical modifier drives the *current* switching session. Cmd+Tab and
    /// Option+Tab are both registered as triggers; whichever fires from idle sets
    /// this, and every release-detection path (event tap, watchdog) plus the
    /// active-only hotkey registration follows it, so holding Option cycles and
    /// releasing Option commits, exactly mirroring the Command behaviour.
    enum TriggerModifier {
        case command
        case option

        /// Carbon modifier mask for RegisterEventHotKey.
        var carbonKey: Int { self == .option ? optionKey : cmdKey }
        /// CGEventFlags bit for live flagsChanged / flagsState checks.
        var eventFlag: CGEventFlags { self == .option ? .maskAlternate : .maskCommand }
    }

    private var _activeModifier: TriggerModifier = .command
    var activeModifier: TriggerModifier {
        get { stateQueue.sync { _activeModifier } }
        set { stateQueue.sync { _activeModifier = newValue } }
    }

    // Hotkey IDs - using actual key codes for easy mapping
    private enum HotkeyID: UInt32 {
        case tab = 1        // Cmd+Tab - activate/next
        case h = 2          // Cmd+H - hide
        case q = 3          // Cmd+Q - quit
        case leftArrow = 4  // Cmd+Left - previous
        case rightArrow = 5 // Cmd+Right - next
        case escape = 6     // Cmd+Escape - dismiss
        case returnKey = 7  // Cmd+Return - activate
        case upArrow = 8    // Cmd+Up - previous row
        case downArrow = 9  // Cmd+Down - next row
        case tabOption = 10 // Option+Tab - activate/next (parallel trigger)
        case graveOption = 11 // Option+backtick -> native Cmd+backtick (cycle app windows)
    }

    // Map hotkey IDs to key codes for delegate
    private static let hotkeyToKeyCode: [UInt32: UInt16] = [
        HotkeyID.tab.rawValue: UInt16(kVK_Tab),
        HotkeyID.h.rawValue: UInt16(kVK_ANSI_H),
        HotkeyID.q.rawValue: UInt16(kVK_ANSI_Q),
        HotkeyID.leftArrow.rawValue: UInt16(kVK_LeftArrow),
        HotkeyID.rightArrow.rawValue: UInt16(kVK_RightArrow),
        HotkeyID.upArrow.rawValue: UInt16(kVK_UpArrow),
        HotkeyID.downArrow.rawValue: UInt16(kVK_DownArrow),
        HotkeyID.escape.rawValue: UInt16(kVK_Escape),
        HotkeyID.returnKey.rawValue: UInt16(kVK_Return),
    ]

    // Ordinary Cmd+<key> combos that have no switcher action. Registered as no-op
    // Carbon hotkeys while the panel is open so they're swallowed instead of leaking
    // to the app behind the panel (e.g. Cmd+W closing a tab). Excludes the action
    // keys (Tab/H/Q/arrows/Escape/Return), which are registered separately.
    private static let swallowKeyCodes: [Int] = [
        kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_Z,
        kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B, kVK_ANSI_W, kVK_ANSI_E,
        kVK_ANSI_R, kVK_ANSI_Y, kVK_ANSI_T, kVK_ANSI_O, kVK_ANSI_U, kVK_ANSI_I,
        kVK_ANSI_P, kVK_ANSI_L, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_N, kVK_ANSI_M,
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
        kVK_ANSI_Backslash, kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_Comma,
        kVK_ANSI_Period, kVK_ANSI_Slash, kVK_ANSI_Grave,
        kVK_Space, kVK_Delete, kVK_ForwardDelete,
    ]

    func stop() {
        // Unregister tab hotkeys (Cmd+Tab and Option+Tab)
        if let ref = tabHotKeyRef {
            UnregisterEventHotKey(ref)
            tabHotKeyRef = nil
        }
        if let ref = tabOptionHotKeyRef {
            UnregisterEventHotKey(ref)
            tabOptionHotKeyRef = nil
        }
        if let ref = graveOptionHotKeyRef {
            UnregisterEventHotKey(ref)
            graveOptionHotKeyRef = nil
        }

        // Unregister active hotkeys
        unregisterActiveHotkeys()

        if let handler = hotKeyPressedHandler {
            RemoveEventHandler(handler)
            hotKeyPressedHandler = nil
        }
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        // Stop the dedicated event-tap thread's run loop so the thread can exit
        if let runLoop = eventTapRunLoop {
            CFRunLoopStop(runLoop)
            eventTapRunLoop = nil
        }
        eventTapThread = nil
    }

    /// Register hotkeys that only work when the panel is active (H, Q, arrows, …).
    /// They're registered under whichever modifier started this session, so they
    /// fire whether the user is holding Command or Option.
    func registerActiveHotkeys() {
        guard activeHotKeyRefs.isEmpty else { return }

        let eventTarget = GetEventDispatcherTarget()
        let modKey = UInt32(activeModifier.carbonKey)

        let hotkeys: [(HotkeyID, Int)] = [
            (.h, kVK_ANSI_H),
            (.q, kVK_ANSI_Q),
            (.leftArrow, kVK_LeftArrow),
            (.rightArrow, kVK_RightArrow),
            (.upArrow, kVK_UpArrow),
            (.downArrow, kVK_DownArrow),
            (.escape, kVK_Escape),
            (.returnKey, kVK_Return),
        ]

        for (hotkeyID, keyCode) in hotkeys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyManager.signature, id: hotkeyID.rawValue)
            RegisterEventHotKey(UInt32(keyCode), modKey, id, eventTarget, UInt32(kEventHotKeyNoOptions), &ref)
            activeHotKeyRefs.append(ref)
        }

        // Swallow every other ordinary Cmd+<key> combo so it doesn't leak to the
        // app behind the panel. These ids are absent from `hotkeyToKeyCode`, so the
        // Carbon handler no-ops them — registration alone consumes the keystroke.
        // The 0x1000 offset keeps the ids clear of the action ids (1–9).
        for keyCode in HotkeyManager.swallowKeyCodes {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyManager.signature, id: UInt32(0x1000 + keyCode))
            RegisterEventHotKey(UInt32(keyCode), modKey, id, eventTarget, UInt32(kEventHotKeyNoOptions), &ref)
            activeHotKeyRefs.append(ref)
        }

        // Second layer of the sticky-panel defense (the dedicated tap thread is
        // the first): a poll that dismisses even if the Cmd-up event is dropped.
        startCmdWatchdog()
    }

    /// Unregister active-only hotkeys so they work normally in other apps
    func unregisterActiveHotkeys() {
        stopCmdWatchdog()
        for ref in activeHotKeyRefs {
            if let ref = ref {
                UnregisterEventHotKey(ref)
            }
        }
        activeHotKeyRefs.removeAll()
    }

    // MARK: - Cmd-release Watchdog

    /// Backstop for a dropped Cmd-up event. Dismissal normally rides the
    /// `.listenOnly` tap's flagsChanged callback, but that single event can be
    /// lost — e.g. macOS disables the tap by timeout exactly as Cmd is released
    /// (re-enabled only afterward) — which leaves the panel stuck open. While the
    /// panel is active, poll the *live* modifier state and dismiss the moment Cmd
    /// is no longer physically held, independent of event delivery. The tap stays
    /// the instant primary path; this only catches the miss (worst case ~100ms).
    private func startCmdWatchdog() {
        guard cmdWatchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isActive else { return }
            let modDown = CGEventSource.flagsState(.combinedSessionState).contains(self.activeModifier.eventFlag)
            if !modDown {
                self.isActive = false  // mirror the tap's immediate-set
                DispatchQueue.main.async {
                    self.delegate?.modifierKeyReleased()
                }
            }
        }
        cmdWatchdog = timer
        timer.resume()
    }

    private func stopCmdWatchdog() {
        cmdWatchdog?.cancel()
        cmdWatchdog = nil
    }

    // MARK: - Carbon Hotkey Registration

    /// Installs the Carbon event handler and registers the global Cmd+Tab hotkey.
    /// Paired with `stop()`, which removes both — so this can be called again to
    /// re-enable switching after a permission revoke.
    func registerHotkeys() {
        let eventTarget = GetEventDispatcherTarget()

        var eventTypes = [EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )]

        let handler: EventHandlerUPP = { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )

            if let userData = userData {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                if id.id == HotkeyID.tab.rawValue || id.id == HotkeyID.tabOption.rawValue {
                    // Cmd+Tab / Option+Tab - activate switcher or select next.
                    // On the activating press (idle → active), record which modifier
                    // the user is holding so release-detection watches the right key.
                    if !manager.isActive {
                        manager.activeModifier =
                            (id.id == HotkeyID.tabOption.rawValue) ? .option : .command
                    }
                    manager.isActive = true
                    DispatchQueue.main.async {
                        manager.delegate?.hotkeyTriggered()
                    }
                } else if id.id == HotkeyID.graveOption.rawValue {
                    // Option+backtick: cycle the frontmost app's windows, mirroring
                    // the native Cmd+backtick behaviour.
                    DispatchQueue.main.async {
                        manager.cycleFrontmostAppWindows()
                    }
                } else {
                    // Other hotkeys (H, Q, arrows, etc.) - only registered when active
                    if let keyCode = HotkeyManager.hotkeyToKeyCode[id.id] {
                        DispatchQueue.main.async {
                            manager.delegate?.keyPressed(keyCode)
                        }
                    }
                }
            }
            return noErr
        }

        let userDataPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(eventTarget, handler, eventTypes.count, &eventTypes, userDataPtr, &hotKeyPressedHandler)

        // Register both global triggers at startup: Cmd+Tab and Option+Tab. The
        // panel-only hotkeys are registered later, when the panel becomes active.
        let id = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyID.tab.rawValue)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey), id, eventTarget, UInt32(kEventHotKeyNoOptions), &tabHotKeyRef)

        let optionID = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyID.tabOption.rawValue)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(optionKey), optionID, eventTarget, UInt32(kEventHotKeyNoOptions), &tabOptionHotKeyRef)

        // Option+backtick mirrors Cmd+backtick (macOS "cycle the front app's windows").
        let graveID = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyID.graveOption.rawValue)
        RegisterEventHotKey(UInt32(kVK_ANSI_Grave), UInt32(optionKey), graveID, eventTarget, UInt32(kEventHotKeyNoOptions), &graveOptionHotKeyRef)
    }

    /// Cycle to another window of the frontmost app, mirroring macOS's native
    /// Cmd+backtick. Bound to Option+backtick. Done through the Accessibility API
    /// (raise the backmost window) instead of synthesizing a Cmd+backtick keystroke,
    /// because the physically-held Option key leaks into a synthetic event and stops
    /// the system shortcut from matching.
    private func cycleFrontmostAppWindows() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        // Skip minimized windows, the way Cmd+backtick does.
        let visible = windows.filter { window in
            var minRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
               let minimized = minRef as? Bool {
                return !minimized
            }
            return true
        }
        // AXWindows is front-to-back; raising the backmost brings it forward, so
        // repeated presses round-robin through every window.
        guard visible.count > 1, let target = visible.last else { return }
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    // MARK: - Event Tap (for modifier release and mouse clicks only)
    // Note: keyDown removed - using Carbon hotkeys instead (only requires Accessibility permission)

    /// Creates the CGEvent tap. Returns true on success (or if already created).
    /// Returns false when `CGEvent.tapCreate` fails — which happens when
    /// Accessibility permission is not granted. The caller uses this as the gate:
    /// native Cmd+Tab is only disabled once this succeeds.
    @discardableResult
    func tryCreateEventTap() -> Bool {
        // Idempotent: never create a second tap / run-loop source.
        if eventTap != nil { return true }

        // Only listen for flagsChanged and mouse clicks
        // keyDown events require Input Monitoring permission, so we use Carbon hotkeys instead
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo = userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .flagsChanged {
                let flags = event.flags

                // Track the modifier that started this session (Command or Option),
                // not Command specifically, so Option+Tab holds/cycles/commits the
                // same way Cmd+Tab does.
                let shiftIsDown = flags.contains(.maskShift)
                let modIsDown = flags.contains(manager.activeModifier.eventFlag)

                if modIsDown {
                    if shiftIsDown && !manager.shiftWasDown {
                        // Shift was just pressed while the trigger modifier is held
                        DispatchQueue.main.async {
                            manager.delegate?.shiftPressed()
                        }
                    }
                    manager.shiftWasDown = shiftIsDown
                }

                // Trigger modifier released → commit the selection and dismiss.
                if !modIsDown {
                    manager.shiftWasDown = false
                    // Set inactive immediately
                    manager.isActive = false
                    DispatchQueue.main.async {
                        manager.delegate?.modifierKeyReleased()
                    }
                }
            } else if type == .leftMouseDown || type == .rightMouseDown {
                if manager.isActive {
                    let location = event.location
                    DispatchQueue.main.async {
                        manager.delegate?.mouseClicked(at: location)
                    }
                    // NOTE: the tap is .listenOnly (so revoking Accessibility can
                    // never freeze input), which means we CANNOT consume the click
                    // — it also reaches whatever is under the cursor. Keyboard use
                    // is unaffected; this only matters for click-to-dismiss.
                }
            } else if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                // Benign: macOS disables the tap after heavy input or a timeout —
                // just re-enable it. (Revocation is handled by AppDelegate's
                // permission poll, because macOS does NOT reliably deliver this
                // event when Accessibility permission is revoked.)
                if let eventTap = manager.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let userDataPtr = Unmanaged.passUnretained(self).toOpaque()

        // .listenOnly (passive): the window server never waits on this tap, so
        // revoking Accessibility while it's alive cannot freeze input. The cost is
        // we can't consume events (see the mouseDown branch above).
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: userDataPtr
        )

        guard let eventTap = eventTap else {
            print("Event tap not created — Accessibility permission not yet granted. Waiting…")
            return false
        }

        // Service the tap on a dedicated, high-priority thread with its own run loop.
        // Previously the source was added to the main run loop, so the Cmd-release
        // callback competed with main-thread UI work (loading icons, building the
        // panel). When that work ran long, macOS disabled the tap by timeout and the
        // Cmd-up event was lost — leaving the switcher panel stuck open. A dedicated
        // thread keeps the callback responsive regardless of what the UI is doing.
        let thread = Thread { [weak self] in
            let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self?.eventTapRunLoop = CFRunLoopGetCurrent()
            CGEvent.tapEnable(tap: eventTap, enable: true)
            print("Event tap created successfully")
            CFRunLoopRun()
        }
        thread.name = "com.simpleswitcher.eventtap"
        thread.qualityOfService = .userInteractive
        eventTapThread = thread
        thread.start()
        return true
    }
}
