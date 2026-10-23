import AppKit
import ApplicationServices
import Carbon
import SwitcherKernels

/// Reads window identity and prompt structure off the UI thread. No text, field
/// values or window titles are read. An AX observer keeps same-app window changes
/// current, so restoring an app with several windows has an exact destination.
final class FocusWindowContext {
    struct Snapshot {
        let pid: pid_t
        let window: AXUIElement?
        let windowID: CGWindowID?
        let mayBePrompt: Bool
        let inspectionFailed: Bool
    }

    var onChange: ((Snapshot) -> Void)?
    private(set) var current: Snapshot?
    private let queue = DispatchQueue(label: "kiwi.ap.switcher.focus-context", qos: .userInitiated)
    private var observer: AXObserver?
    private var pid: pid_t?
    private var generation = 0
    private var refreshing = false
    private var refreshRequested = false

    func watch(_ pid: pid_t) {
        guard self.pid != pid else { refresh(); return }
        stop()
        self.pid = pid
        let generation = self.generation
        queue.async { [weak self] in
            guard let self else { return }
            let app = Self.application(pid)
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, _, context in
                guard let context else { return }
                Unmanaged<FocusWindowContext>.fromOpaque(context).takeUnretainedValue().refresh()
            }
            if AXObserverCreate(pid, callback, &observer) == .success, let observer {
                for notification in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
                                     kAXWindowCreatedNotification] {
                    AXObserverAddNotification(observer, app, notification as CFString,
                                              Unmanaged.passUnretained(self).toOpaque())
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.observer = observer
                if let observer {
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                }
                self.refresh()
            }
        }
    }

    func stop() {
        generation += 1
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        pid = nil
        current = nil
        refreshing = false
        refreshRequested = false
    }

    func refresh() {
        guard let pid else { return }
        guard !refreshing else {
            refreshRequested = true
            return
        }
        refreshing = true
        let generation = self.generation
        inspect(pid) { [weak self] snapshot in
            guard let self, self.generation == generation else { return }
            self.refreshing = false
            if self.refreshRequested {
                self.refreshRequested = false
                self.refresh()
                return
            }
            self.current = snapshot
            self.onChange?(snapshot)
        }
    }

    func inspect(_ pid: pid_t, completion: @escaping (Snapshot) -> Void) {
        queue.async {
            let app = Self.application(pid)
            var windowValue: CFTypeRef?
            let windowError = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue)
            let window = Self.element(windowValue)
            let focused = Self.element(Self.attribute(app, kAXFocusedUIElementAttribute))
            let secure = focused.map { Self.attribute($0, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole } ?? false
            let modal = window.map {
                (Self.attribute($0, kAXModalAttribute) as? Bool == true)
                    || (Self.attribute($0, kAXSubroleAttribute) as? String == kAXSystemDialogSubrole)
            } ?? false
            let snapshot = Snapshot(pid: pid, window: window, windowID: window.flatMap(FocusWindowAPI.id),
                                    mayBePrompt: secure || modal,
                                    inspectionFailed: windowError == .cannotComplete || windowError == .apiDisabled)
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    /// A link action is evidence even when Choosy routes it without activating.
    /// Query the source application, not whichever window happens to be on top
    /// by the time this work runs. Only the URL's scheme is inspected.
    func inspectLink(in pid: pid_t, at point: CGPoint?, completion: @escaping (Bool) -> Void) {
        queue.async {
            let app = Self.application(pid)
            var item: AXUIElement?
            if let point {
                AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &item)
            } else {
                item = Self.element(Self.attribute(app, kAXFocusedUIElementAttribute))
            }
            var isLink = false
            for _ in 0..<4 {
                guard let element = item else { break }
                // Do not inspect the document URL of a web view or window.
                if Self.attribute(element, kAXRoleAttribute) as? String == NSAccessibility.Role.link.rawValue {
                    if let url = Self.attribute(element, kAXURLAttribute) as? URL {
                        isLink = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                    } else {
                        // Some native link controls expose AXLink without AXURL.
                        isLink = true
                    }
                    break
                }
                item = Self.element(Self.attribute(element, kAXParentAttribute))
            }
            DispatchQueue.main.async { completion(isLink) }
        }
    }

    private static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        return app
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        // AX timeouts belong to the individual object. The application object's
        // limit is not inherited by its windows, controls or their parents.
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

/// Optional private entry points. Missing symbols leave app activation available
/// instead of preventing Switcher from launching after a macOS update.
enum FocusWindowAPI {
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias ActivateWindowFunction = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
    private typealias ProcessForPIDFunction = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private static let windowIDFunction: WindowIDFunction? = symbol("_AXUIElementGetWindow")
    private static let activateWindowFunction: ActivateWindowFunction? = symbol("_SLPSSetFrontProcessWithOptions")
    private static let processForPIDFunction: ProcessForPIDFunction? = symbol("GetProcessForPID")

    private static func symbol<T>(_ name: String) -> T? {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    static func id(_ window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard windowIDFunction?(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func activate(pid: pid_t, window: CGWindowID) -> Bool {
        var psn = ProcessSerialNumber()
        guard processForPIDFunction?(pid, &psn) == noErr, let activateWindowFunction else { return false }
        // kCPSUserGenerated targets the window's own Space without moving it.
        return activateWindowFunction(&psn, window, 0x200) == .success
    }

    static func isOnScreen(_ window: CGWindowID) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]],
              let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window }) else { return false }
        return row[kCGWindowIsOnscreen as String] as? Bool == true
    }

    static func exists(_ window: CGWindowID, for pid: pid_t) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]] else { return false }
        return rows.contains {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        }
    }

    /// Authentication agents can show a window before an activation notice, or
    /// keep one visible after losing focus. A running process alone proves neither.
    static func hasVisiblePrompt() -> Bool {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] else {
            return true
        }
        let prompts = Set(NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            // A normal Settings window can remain open behind the user's work.
            // Its activation is exempt, but visibility alone is not a password prompt.
            return id != "com.apple.systempreferences" && FocusIntent.prompts.contains(id)
        }.map(\.processIdentifier))
        return rows.contains {
            guard let pid = $0[kCGWindowOwnerPID as String] as? Int32, prompts.contains(pid),
                  let bounds = $0[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
            return width > 100 && height > 40 && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
    }
}
