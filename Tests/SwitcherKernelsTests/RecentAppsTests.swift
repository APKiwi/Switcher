import Foundation
import SwitcherKernels

/// Pins the MRU seed. These matter more than they look: under the recent-apps
/// cap, this ordering is the difference between "the 4 apps you just used" and
/// "4 arbitrary apps" on the first Cmd+Tab after a launch.
enum RecentAppsTests {

    static func runAll() {
        Check.run("testFirstOccurrenceWins", testFirstOccurrenceWins)
        Check.run("testOrderIsOtherwisePreserved", testOrderIsOtherwisePreserved)
        Check.run("testFrontmostIsHoistedFromTheMiddle", testFrontmostIsHoistedFromTheMiddle)
        Check.run("testFrontmostWithNoWindowsStillLeads", testFrontmostWithNoWindowsStillLeads)
        Check.run("testNoFrontmostKeepsZOrder", testNoFrontmostKeepsZOrder)
        Check.run("testEmptyInput", testEmptyInput)
        Check.run("testPromoteRemembersTheRank", testPromoteRemembersTheRank)
        Check.run("testPromoteKeepsTheCap", testPromoteKeepsTheCap)
        Check.run("testUndoAfterARevertRestoresTheOrder", testUndoAfterARevertRestoresTheOrder)
        Check.run("testUndoOfALaunchDropsItsRank", testUndoOfALaunchDropsItsRank)
        Check.run("testUndoBeforeTheRevertIsRecordedGivesTheSameOrder", testUndoBeforeTheRevertIsRecordedGivesTheSameOrder)
        Check.run("testUndoClampsToTheEnd", testUndoClampsToTheEnd)
    }

    /// An app owns several windows, so its pid repeats; the frontmost of them is
    /// the app's rank, and the rest must not push later apps down.
    private static func testFirstOccurrenceWins() {
        let seed = RecentApps.orderedUnique(pids: [10, 10, 20, 10, 30, 20], frontmost: nil)
        Check.equal(seed, [10, 20, 30])
    }

    private static func testOrderIsOtherwisePreserved() {
        let seed = RecentApps.orderedUnique(pids: [30, 20, 10], frontmost: nil)
        Check.equal(seed, [30, 20, 10])
    }

    /// z-order is a proxy; the active app is known for certain, so it wins over it.
    private static func testFrontmostIsHoistedFromTheMiddle() {
        let seed = RecentApps.orderedUnique(pids: [10, 20, 30], frontmost: 30)
        Check.equal(seed, [30, 10, 20])
    }

    /// e.g. the active app's only window is on another Space, so it is absent
    /// from the on-screen list — it is still what the user is looking at.
    private static func testFrontmostWithNoWindowsStillLeads() {
        let seed = RecentApps.orderedUnique(pids: [10, 20], frontmost: 99)
        Check.equal(seed, [99, 10, 20])
    }

    private static func testNoFrontmostKeepsZOrder() {
        let seed = RecentApps.orderedUnique(pids: [10, 20], frontmost: nil)
        Check.equal(seed, [10, 20])
    }

    private static func testEmptyInput() {
        Check.equal(RecentApps.orderedUnique(pids: [], frontmost: nil), [])
        Check.equal(RecentApps.orderedUnique(pids: [], frontmost: 7), [7])
    }

    // MARK: - Activations and the focus guard's undo

    private static func testPromoteRemembersTheRank() {
        let moved = RecentApps.promote(30, in: [10, 20, 30, 40], cap: 50)
        Check.equal(moved.order, [30, 10, 20, 40])
        Check.equal(moved.promotion, RecentApps.Promotion(pid: 30, previousIndex: 2))
        Check.equal(RecentApps.promote(99, in: [10], cap: 50).promotion.previousIndex, nil)
    }

    private static func testPromoteKeepsTheCap() {
        Check.equal(RecentApps.promote(99, in: [10, 20, 30], cap: 3).order, [99, 10, 20])
    }

    /// Previous app T, stealer S. The steal and the revert leave [T, S, ...],
    /// and the undo must give back the order from before the steal.
    private static func testUndoAfterARevertRestoresTheOrder() {
        let before: [pid_t] = [1, 2, 3, 9, 4]
        let steal = RecentApps.promote(9, in: before, cap: 50)
        let revert = RecentApps.promote(1, in: steal.order, cap: 50)
        Check.equal(revert.order, [1, 9, 2, 3, 4])
        Check.equal(RecentApps.undo(steal.promotion, in: revert.order), before)
    }

    /// The common steal: an app that just launched had no rank to go back to.
    private static func testUndoOfALaunchDropsItsRank() {
        let steal = RecentApps.promote(9, in: [1, 2], cap: 50)
        let revert = RecentApps.promote(1, in: steal.order, cap: 50)
        Check.equal(RecentApps.undo(steal.promotion, in: revert.order), [1, 2])
    }

    /// The guard and the MRU tracker observe the same notice, in either order.
    private static func testUndoBeforeTheRevertIsRecordedGivesTheSameOrder() {
        let steal = RecentApps.promote(9, in: [1, 2, 3, 9, 4], cap: 50)
        let undone = RecentApps.undo(steal.promotion, in: steal.order)
        Check.equal(RecentApps.promote(1, in: undone, cap: 50).order, [1, 2, 3, 9, 4])
    }

    private static func testUndoClampsToTheEnd() {
        let promotion = RecentApps.Promotion(pid: 9, previousIndex: 7)
        Check.equal(RecentApps.undo(promotion, in: [9, 1, 2]), [1, 2, 9])
    }
}
