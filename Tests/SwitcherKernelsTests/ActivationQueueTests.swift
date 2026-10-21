import Foundation
import SwitcherKernels

/// Pins the order the MRU list takes activations in while the focus guard
/// judges them. A steal sent back must never rank, and an activation known to
/// be kept early must not jump an older one still being judged.
enum ActivationQueueTests {

    static func runAll() {
        Check.run("testAKnownKeepIsReleasedAtOnce", testAKnownKeepIsReleasedAtOnce)
        Check.run("testAnUndecidedActivationHoldsLaterOnes", testAnUndecidedActivationHoldsLaterOnes)
        Check.run("testASentBackStealNeverRanks", testASentBackStealNeverRanks)
        Check.run("testSettlesOutOfOrderReleaseInNoticeOrder", testSettlesOutOfOrderReleaseInNoticeOrder)
        Check.run("testFlushKeepsWhatIsStillUndecided", testFlushKeepsWhatIsStillUndecided)
        Check.run("testAnUnknownIDReleasesNothing", testAnUnknownIDReleasesNothing)
        Check.run("testOverlappingStealsLeaveTheOrderAlone", testOverlappingStealsLeaveTheOrderAlone)
        Check.run("testAReclickAfterARevertRanksFirst", testAReclickAfterARevertRanksFirst)
    }

    /// A panel selection: its cause is recorded before the activation.
    private static func testAKnownKeepIsReleasedAtOnce() {
        var queue = ActivationQueue<String>()
        Check.equal(queue.notice("panel pick", kept: true).released, ["panel pick"])
    }

    private static func testAnUndecidedActivationHoldsLaterOnes() {
        var queue = ActivationQueue<String>()
        let late = queue.notice("late click")
        Check.equal(queue.notice("panel pick", kept: true).released, [])
        Check.equal(queue.settle(late.id, kept: true), ["late click", "panel pick"])
    }

    private static func testASentBackStealNeverRanks() {
        var queue = ActivationQueue<String>()
        let steal = queue.notice("steal")
        let next = queue.notice("next")
        Check.equal(queue.settle(steal.id, kept: false), [])
        Check.equal(queue.settle(next.id, kept: true), ["next"])
    }

    private static func testSettlesOutOfOrderReleaseInNoticeOrder() {
        var queue = ActivationQueue<String>()
        let a = queue.notice("a"), b = queue.notice("b"), c = queue.notice("c")
        Check.equal(queue.settle(c.id, kept: true), [])
        Check.equal(queue.settle(b.id, kept: false), [])
        Check.equal(queue.settle(a.id, kept: true), ["a", "c"])
    }

    /// The guard stops failing open: anything not judged a steal keeps its rank.
    private static func testFlushKeepsWhatIsStillUndecided() {
        var queue = ActivationQueue<String>()
        _ = queue.notice("undecided")
        let steal = queue.notice("steal")
        _ = queue.notice("kept", kept: true)
        Check.equal(queue.settle(steal.id, kept: false), [])
        Check.equal(queue.flush(), ["undecided", "kept"])
        Check.equal(queue.notice("after", kept: true).released, ["after"])
    }

    private static func testAnUnknownIDReleasesNothing() {
        var queue = ActivationQueue<String>()
        Check.equal(queue.settle(42, kept: true), [])
    }

    /// Round-two review: B steals and its revert lands on A while C is still
    /// undecided, then D steals and is sent back too. Promoting only what was
    /// kept leaves [A, X, B, C, D] as it was.
    private static func testOverlappingStealsLeaveTheOrderAlone() {
        var queue = ActivationQueue<pid_t>()
        var order: [pid_t] = [1, 2, 3, 4, 5]
        let promote = { (released: [pid_t]) in
            for pid in released { order = RecentApps.promote(pid, in: order, cap: 50) }
        }
        let b = queue.notice(3)
        let c = queue.notice(4)
        promote(queue.settle(b.id, kept: false))
        promote(queue.notice(1, kept: true).released)
        let d = queue.notice(5)
        promote(queue.settle(c.id, kept: false))
        promote(queue.settle(d.id, kept: false))
        promote(queue.notice(1, kept: true).released)
        Check.equal(order, [1, 2, 3, 4, 5])
    }

    /// Round-two review: the user clicks a reverted stealer while another
    /// activation is undecided. The click is its own activation and ranks first.
    private static func testAReclickAfterARevertRanksFirst() {
        var queue = ActivationQueue<pid_t>()
        var order: [pid_t] = [1, 2, 3]
        let promote = { (released: [pid_t]) in
            for pid in released { order = RecentApps.promote(pid, in: order, cap: 50) }
        }
        let steal = queue.notice(3)
        let other = queue.notice(2)
        promote(queue.settle(steal.id, kept: false))
        promote(queue.notice(1, kept: true).released)
        let click = queue.notice(3)
        promote(queue.settle(other.id, kept: false))
        promote(queue.settle(click.id, kept: true))
        Check.equal(order, [3, 1, 2])
    }
}
