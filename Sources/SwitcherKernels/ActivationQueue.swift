import Foundation

/// Activations in the order they were noticed, each held until it is known
/// whether it keeps focus.
///
/// While the focus guard runs, the MRU order takes activations from here
/// instead of from the activation notice. A steal the guard sends back is
/// settled as not kept and never ranks, so nothing has to be undone. One known
/// to be kept at once, such as a panel pick whose cause is already recorded,
/// still waits behind an older activation being judged, so ranks always follow
/// the order the activations happened in.
public struct ActivationQueue<App> {

    public typealias ID = Int

    private struct Entry {
        let id: ID
        let app: App
        var kept: Bool?
    }

    private var waiting: [Entry] = []
    private var nextID: ID = 0

    public init() {}

    /// Adds an activation, with `kept` already known or nil until `settle`.
    /// Returns its id and the activations it released, oldest first.
    public mutating func notice(_ app: App, kept: Bool? = nil) -> (id: ID, released: [App]) {
        let id = nextID
        nextID += 1
        waiting.append(Entry(id: id, app: app, kept: kept))
        return (id, release())
    }

    /// Records whether an activation kept focus. Returns the activations it
    /// released, oldest first.
    public mutating func settle(_ id: ID, kept: Bool) -> [App] {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return [] }
        waiting[index].kept = kept
        return release()
    }

    /// Releases everything still waiting except settled steals, as when the
    /// guard stops and fails open.
    public mutating func flush() -> [App] {
        defer { waiting.removeAll() }
        return waiting.filter { $0.kept != false }.map(\.app)
    }

    private mutating func release() -> [App] {
        var released: [App] = []
        while let first = waiting.first, let kept = first.kept {
            waiting.removeFirst()
            if kept { released.append(first.app) }
        }
        return released
    }
}
