import AppKit
import ApplicationServices

/// `--focus-probe`: runs the focus guard for two minutes and prints every
/// decision, with this bundle's own grants, to re-measure the `FocusIntent`
/// rules after a macOS update (`FocusIntentSpecs.md`).
///
/// It registers no hotkeys and never touches the native Cmd+Tab, so it can run
/// beside an installed Switcher. Turn that one's focus guard off first, or both
/// revert. Key presses are classified and counted, never recorded.
enum FocusProbe {

    static let duration: TimeInterval = 120

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let startedAt = ProcessInfo.processInfo.systemUptime
        let log: (String) -> Void = { message in
            print(String(format: "%7.3f ", ProcessInfo.processInfo.systemUptime - startedAt) + message)
        }

        let accessibility = AXIsProcessTrusted()
        log("Switcher focus probe, \(Int(duration))s, \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("bundle \(Bundle.main.bundlePath)")
        log("Accessibility granted: \(accessibility ? "yes" : "NO")")
        log("listen access (Accessibility covers it on macOS 27): \(CGPreflightListenEventAccess() ? "yes" : "no")")
        guard accessibility else {
            log("Accessibility is not granted to this build, so the probe cannot see input. Stopping.")
            exit(2)
        }

        let focusGuard = FocusGuard()
        focusGuard.trace = log
        focusGuard.start()
        Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            summarize(focusGuard.tally, log: log)
            exit(0)
        }
        log("ready")
        app.run()
        exit(0)
    }

    private static func summarize(_ tally: FocusGuard.Tally, log: (String) -> Void) {
        log("")
        log("Summary")
        let counts = tally.inputs.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        log("  input seen: \(counts.isEmpty ? "none" : counts)")
        log("  activations: intended \(tally.intended), launched \(tally.launched), allowed \(tally.allowed), steals \(tally.steals)")
        for method in FocusGuard.RevertMethod.allCases {
            let result = tally.reverts[method] ?? (0, 0)
            log("  revert via \(method.rawValue): ok \(result.ok), failed \(result.failed)")
        }
        log("  Check each STEAL above: was it really one you did not ask for?")
    }
}
