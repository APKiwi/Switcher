import Foundation

/// Ordering rules for the "N most recently used apps" list.
///
/// The switcher's MRU order is built from activation notifications, so at launch
/// it knows about exactly one app: the frontmost one. That is invisible while the
/// switcher shows everything — the un-ranked apps just tie and land in an
/// arbitrary tail — but it decides *which apps are reachable at all* once the list
/// is capped. So the MRU list gets seeded from window z-order, and this is the
/// pure part of that seed.
public enum RecentApps {

    /// Builds the initial MRU order from a front-to-back list of window owners.
    ///
    /// Apps own several windows each, so the same pid appears repeatedly; the
    /// FIRST occurrence is the frontmost one and therefore the app's rank. The
    /// frontmost app is hoisted to the head regardless of where it appears —
    /// z-order is only a proxy for recency, but the app the user is actually in
    /// is known for certain, and it is the one position that must be right (the
    /// panel opens on index 1, i.e. "the app before this one").
    ///
    /// - Parameters:
    ///   - pids: window owners in front-to-back order, duplicates expected.
    ///   - frontmost: the currently active app, if any.
    public static func orderedUnique(pids: [pid_t], frontmost: pid_t?) -> [pid_t] {
        var seen = Set<pid_t>()
        var ordered: [pid_t] = []
        ordered.reserveCapacity(pids.count)

        if let frontmost {
            seen.insert(frontmost)
            ordered.append(frontmost)
        }
        for pid in pids where seen.insert(pid).inserted {
            ordered.append(pid)
        }
        return ordered
    }

    /// Where an activation moved an app from, so the move can be undone.
    public struct Promotion: Equatable {
        public let pid: pid_t
        /// The app's rank before it moved to the head, nil if it had none.
        public let previousIndex: Int?

        public init(pid: pid_t, previousIndex: Int?) {
            self.pid = pid
            self.previousIndex = previousIndex
        }
    }

    /// Moves `pid` to the head, as an activation does, keeping at most `cap` apps.
    public static func promote(_ pid: pid_t, in order: [pid_t], cap: Int) -> (order: [pid_t], promotion: Promotion) {
        let previousIndex = order.firstIndex(of: pid)
        var result = order.filter { $0 != pid }
        result.insert(pid, at: 0)
        if result.count > cap { result.removeLast(result.count - cap) }
        return (result, Promotion(pid: pid, previousIndex: previousIndex))
    }

    /// Puts a promoted app back where it was, or drops its rank if it had none.
    ///
    /// The focus guard calls this once it has reverted a steal. Without it the
    /// stealer would rank second, so a quick Cmd+Tab would go to it instead of
    /// the app used before. Apps promoted since keep their order: reverting
    /// moved the previous app back to the head, and this only moves the stealer.
    public static func undo(_ promotion: Promotion, in order: [pid_t]) -> [pid_t] {
        var result = order.filter { $0 != promotion.pid }
        if let index = promotion.previousIndex {
            result.insert(promotion.pid, at: min(index, result.count))
        }
        return result
    }
}
