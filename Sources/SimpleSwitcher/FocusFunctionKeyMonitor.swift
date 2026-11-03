import AppKit
import SwitcherKernels

/// Observes F1 to F20 presses at the session tap. Another app's Carbon hotkey
/// on a bare function key goes to that app as a hotkey event, so the global
/// `NSEvent` monitor never sees it (`FocusIntentSpecs.md`, Function keys).
/// Every other key is dropped in the callback unread. This passive tap never
/// changes or posts an event, and it stays apart from the gesture tap so a
/// refused keyboard tap cannot take gesture observation with it.
final class FocusFunctionKeyMonitor {
    var onFunctionKey: ((TimeInterval) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isAvailable: Bool { tap.map(CGEvent.tapIsEnabled) ?? false }

    func start() {
        // Creating a keyboard tap without listen access raises the Input
        // Monitoring prompt. The preflight never does.
        guard tap == nil, CGPreflightListenEventAccess() else { return }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FocusFunctionKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if type == .keyDown,
                      FocusIntent.isFunctionKey(UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))) {
                monitor.onFunctionKey?(TimeInterval(event.timestamp) / 1_000_000_000)
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                               eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
                               callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }
}
