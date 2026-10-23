import AppKit

/// Observes gesture envelopes without decoding their private payload. Dock
/// swipes changed payload format in macOS 27. Their session event types remain
/// 29 and 30. Other gestures also fail open during the short navigation window.
/// This passive tap never changes or posts an event.
final class FocusGestureMonitor {
    var onGesture: ((TimeInterval) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isAvailable: Bool { tap.map(CGEvent.tapIsEnabled) ?? false }

    func start() {
        guard tap == nil else { return }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FocusGestureMonitor>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                monitor.onGesture?(TimeInterval(event.timestamp) / 1_000_000_000)
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                               eventsOfInterest: (CGEventMask(1) << 29) | (CGEventMask(1) << 30),
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
