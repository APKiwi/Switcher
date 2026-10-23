import Foundation

/// One link action may activate a browser after a router has finished its work.
/// The caller supplies evidence of a link and registered destination browsers.
public struct BrowserHandoff {
    /// Keeps the latest input while an earlier Accessibility query is in flight.
    /// Browser decisions may proceed only after the whole chain is idle.
    public struct Inspection<Request> {
        public private(set) var isBusy = false
        private var pending: Request?
        public init() {}
        public mutating func begin(_ request: Request) -> Bool {
            if isBusy {
                pending = request
                return false
            }
            isBusy = true
            return true
        }
        public mutating func finish() -> Request? {
            if let pending {
                self.pending = nil
                return pending
            }
            isBusy = false
            return nil
        }
        public mutating func cancelPending() { pending = nil }
    }

    private var request: (cause: FocusIntent.Input, destinations: Set<String>)?
    private var newestRequestAt = -Double.infinity
    public static let lifetime: TimeInterval = 10
    public init() {}

    public mutating func recordLink(_ cause: FocusIntent.Input, destinations: Set<String>) {
        guard cause.at > newestRequestAt, cause.kind == .click || cause.kind == .confirmKey else { return }
        newestRequestAt = cause.at
        request = (cause, destinations)
    }

    public mutating func consume(bundleID: String?, at: TimeInterval,
                                 inputs: [FocusIntent.Input], lastSwitchCause: FocusIntent.Input?) -> FocusIntent.Input? {
        guard let request, at >= request.cause.at else { return nil }
        let movedOn = inputs.contains {
            $0.kind != .spaceChange && $0.at > request.cause.at + FocusIntent.launchSlack && $0.at <= at
        }
        if at - request.cause.at > Self.lifetime || movedOn
            || (lastSwitchCause.map { $0.at > request.cause.at } ?? false) {
            cancel()
            return nil
        }
        guard let bundleID, request.destinations.contains(bundleID) else { return nil }
        cancel()
        return request.cause
    }

    public mutating func cancel() { request = nil }
}
