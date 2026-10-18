import SwitcherKernels

/// Pins the focus-intent rules against the probe run they came from (times in
/// `FocusIntentSpecs.md`). FocusGuard's rule, any input within 300 ms of the
/// activation, reverted two Spotlight launches mid-boot and let a steal through
/// because the user was typing.
enum FocusIntentTests {

    typealias Input = FocusIntent.Input

    static func runAll() {
        // A. Measured cases
        Check.run("testColdLaunchFromSpotlightIsLaunched", testColdLaunchFromSpotlightIsLaunched)
        Check.run("testColdLaunchOfCalculatorIsIntended", testColdLaunchOfCalculatorIsIntended)
        Check.run("testStealDuringTypingIsASteal", testStealDuringTypingIsASteal)
        Check.run("testLateDeliveredClickStillCounts", testLateDeliveredClickStillCounts)
        Check.run("testHoldToSwitchReleaseCounts", testHoldToSwitchReleaseCounts)
        // B. Direct input
        Check.run("testTypingAloneNeverJustifiesAnActivation", testTypingAloneNeverJustifiesAnActivation)
        Check.run("testInputAfterTheActivationIsNotItsCause", testInputAfterTheActivationIsNotItsCause)
        Check.run("testInputWindowBoundary", testInputWindowBoundary)
        Check.run("testMostRecentCauseIsReported", testMostRecentCauseIsReported)
        Check.run("testSpaceChangeBeforeTheActivationCounts", testSpaceChangeBeforeTheActivationCounts)
        // C. Launches
        Check.run("testScriptedLaunchWithNoInputIsASteal", testScriptedLaunchWithNoInputIsASteal)
        Check.run("testSlowLaunchLandsWhenTheUserWaits", testSlowLaunchLandsWhenTheUserWaits)
        Check.run("testSlowLaunchIsAStealOnceTheUserMovedOn", testSlowLaunchIsAStealOnceTheUserMovedOn)
        Check.run("testInputWithinTheSlackKeepsTheLaunch", testInputWithinTheSlackKeepsTheLaunch)
        Check.run("testLaunchIntentExpires", testLaunchIntentExpires)
        // D. Input mapping
        Check.run("testReturnAndEnterAreConfirmKeys", testReturnAndEnterAreConfirmKeys)
        Check.run("testModifierChordsAreShortcuts", testModifierChordsAreShortcuts)
        Check.run("testOnlyCommandControlOptionReleasesCount", testOnlyCommandControlOptionReleasesCount)
        Check.run("testWhichInputsCancelARevert", testWhichInputsCancelARevert)
    }

    private static func classify(at activation: Double, launchedAt: Double? = nil,
                                 _ inputs: [Input]) -> FocusIntent.Verdict {
        FocusIntent.classify(activationAt: activation, launchedAt: launchedAt, inputs: inputs)
    }

    // MARK: - A. Measured cases

    /// STEAL #1 in the run: Return, TextEdit's launch 123 ms later, activation
    /// 440 ms after that. 563 ms is outside any sane direct window.
    static func testColdLaunchFromSpotlightIsLaunched() {
        let returnKey = Input(.confirmKey, at: 5.149)
        Check.equal(classify(at: 5.712, launchedAt: 5.272, [returnKey]), .launched(by: returnKey))
    }

    /// STEAL #3: Return, Calculator's launch 143 ms later, activation 229 ms after.
    /// 372 ms in all, which the wider direct window already covers.
    static func testColdLaunchOfCalculatorIsIntended() {
        let returnKey = Input(.confirmKey, at: 26.354)
        Check.equal(classify(at: 26.726, launchedAt: 26.497, [returnKey]), .intended(by: returnKey))
    }

    /// The staged `sleep 5; open -a Chess` while typing in TextEdit. A key went
    /// down 253 ms before the activation, so the 300 ms rule called it intended.
    static func testStealDuringTypingIsASteal() {
        let inputs = [
            Input(.click, at: 78.574),
            Input(.typing, at: 82.915),
        ]
        Check.equal(classify(at: 83.168, launchedAt: 82.893, inputs), .steal)
    }

    /// STEAL #4: the Dock click reached the monitor in the same millisecond as
    /// the activation notice, after it. Decided later with event times, it counts.
    static func testLateDeliveredClickStillCounts() {
        let click = Input(.click, at: 33.105)
        let inputs = [Input(.typing, at: 32.064), click]
        Check.equal(classify(at: 33.113, launchedAt: 26.497, inputs), .intended(by: click))
    }

    /// STEAL #2: a switcher held for 727 ms. Its Tab presses never reach a global
    /// monitor, only the Command release does, 11 ms after the activation notice.
    static func testHoldToSwitchReleaseCounts() {
        let release = Input(.modifierRelease, at: 9.990)
        Check.equal(classify(at: 9.993, [Input(.typing, at: 9.266), release]), .intended(by: release))
    }

    // MARK: - B. Direct input

    static func testTypingAloneNeverJustifiesAnActivation() {
        Check.equal(classify(at: 10, [Input(.typing, at: 9.95)]), .steal)
    }

    static func testInputAfterTheActivationIsNotItsCause() {
        Check.equal(classify(at: 10, [Input(.click, at: 10.01)]), .steal)
    }

    static func testInputWindowBoundary() {
        let window = FocusIntent.inputWindow
        let edge = Input(.click, at: 10 - window)
        Check.equal(classify(at: 10, [edge]), .intended(by: edge))
        Check.equal(classify(at: 10, [Input(.click, at: 10 - window - 0.01)]), .steal)
    }

    static func testMostRecentCauseIsReported() {
        let later = Input(.confirmKey, at: 9.9)
        Check.equal(classify(at: 10, [later, Input(.click, at: 9.7)]), .intended(by: later))
    }

    static func testSpaceChangeBeforeTheActivationCounts() {
        let swipe = Input(.spaceChange, at: 9.9)
        Check.equal(classify(at: 10, [swipe]), .intended(by: swipe))
    }

    // MARK: - C. Launches

    /// The Return that started `sleep 5` is long gone when the app launches.
    static func testScriptedLaunchWithNoInputIsASteal() {
        Check.equal(classify(at: 10.4, launchedAt: 10, [Input(.confirmKey, at: 5)]), .steal)
    }

    static func testSlowLaunchLandsWhenTheUserWaits() {
        let returnKey = Input(.confirmKey, at: 0)
        Check.equal(classify(at: 20, launchedAt: 0.12, [returnKey]), .launched(by: returnKey))
    }

    /// Launched, then back to work elsewhere: the late activation is the classic
    /// booting-app steal and goes back.
    static func testSlowLaunchIsAStealOnceTheUserMovedOn() {
        let inputs = [Input(.confirmKey, at: 0), Input(.typing, at: 3)]
        Check.equal(classify(at: 20, launchedAt: 0.12, inputs), .steal)
    }

    /// A key repeat or a second Return right after the launching one is not
    /// moving on.
    static func testInputWithinTheSlackKeepsTheLaunch() {
        let returnKey = Input(.confirmKey, at: 0)
        let inputs = [returnKey, Input(.typing, at: 0.2)]
        Check.equal(classify(at: 0.6, launchedAt: 0.12, inputs), .launched(by: returnKey))
    }

    static func testLaunchIntentExpires() {
        let lifetime = FocusIntent.launchLifetime
        Check.equal(classify(at: 0.1 + lifetime + 1, launchedAt: 0.1, [Input(.confirmKey, at: 0)]), .steal)
    }

    // MARK: - D. Input mapping

    static func testReturnAndEnterAreConfirmKeys() {
        Check.equal(FocusIntent.keyKind(keyCode: 36, modifiers: []), .confirmKey)
        Check.equal(FocusIntent.keyKind(keyCode: 76, modifiers: [.shift]), .confirmKey)
        Check.equal(FocusIntent.keyKind(keyCode: 36, modifiers: [.command]), .confirmKey)
    }

    static func testModifierChordsAreShortcuts() {
        let q: UInt16 = 12
        Check.equal(FocusIntent.keyKind(keyCode: q, modifiers: [.command]), .shortcut)
        Check.equal(FocusIntent.keyKind(keyCode: q, modifiers: [.control]), .shortcut)
        Check.equal(FocusIntent.keyKind(keyCode: q, modifiers: [.option, .shift]), .shortcut)
        Check.equal(FocusIntent.keyKind(keyCode: q, modifiers: [.shift]), .typing)
        Check.equal(FocusIntent.keyKind(keyCode: q, modifiers: []), .typing)
    }

    static func testOnlyCommandControlOptionReleasesCount() {
        Check.equal(FocusIntent.flagsKind(from: [.command], to: []), .modifierRelease)
        Check.equal(FocusIntent.flagsKind(from: [.option, .shift], to: [.shift]), .modifierRelease)
        Check.equal(FocusIntent.flagsKind(from: [.command, .shift], to: [.command]), .typing)
        Check.equal(FocusIntent.flagsKind(from: [], to: [.command]), .typing)
    }

    /// A revert waits out the grace period. Deliberate input cancels it, typing
    /// does not (that is the input the steal is taking), and neither does a
    /// Space change, which a steal from another Space causes itself.
    static func testWhichInputsCancelARevert() {
        Check.expect(FocusIntent.InputKind.click.cancelsRevert)
        Check.expect(FocusIntent.InputKind.confirmKey.cancelsRevert)
        Check.expect(FocusIntent.InputKind.shortcut.cancelsRevert)
        Check.expect(FocusIntent.InputKind.modifierRelease.cancelsRevert)
        Check.expect(!FocusIntent.InputKind.typing.cancelsRevert)
        Check.expect(!FocusIntent.InputKind.spaceChange.cancelsRevert)
        Check.expect(FocusIntent.InputKind.spaceChange.canSwitchApps)
        Check.expect(!FocusIntent.InputKind.typing.canSwitchApps)
    }
}
