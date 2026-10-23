/// A restore owns one target window until new input, a prompt or another
/// activation supersedes it. Runtime callbacks must validate its ticket.
public struct FocusRestoration {
    public struct Ticket: Equatable {
        public let generation: Int
        public let stealer: Int32
        public let target: Int32
        public let window: UInt32?
    }

    public private(set) var pending: Ticket?
    private var generation = 0
    public init() {}

    public mutating func begin(stealer: Int32, target: Int32, window: UInt32?) -> Ticket {
        generation += 1
        let ticket = Ticket(generation: generation, stealer: stealer, target: target, window: window)
        pending = ticket
        return ticket
    }

    public mutating func cancel() { pending = nil }
    public mutating func activated(_ pid: Int32, protected: Bool) {
        if protected || (pending.map { pid != $0.target && pid != $0.stealer } ?? false) { cancel() }
    }

    public func canRestore(_ ticket: Ticket, frontmost: Int32?, protected: Bool) -> Bool {
        pending == ticket && !protected && (frontmost == ticket.stealer || frontmost == ticket.target)
    }

    public func landed(_ ticket: Ticket, frontmost: Int32?, window: UInt32?, onScreen: Bool) -> Bool {
        pending == ticket && frontmost == ticket.target
            && (ticket.window == nil || (window == ticket.window && onScreen))
    }
}
