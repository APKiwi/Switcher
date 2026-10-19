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
        Check.run("testSpotlightLaunchAtTheWindowEdgeIsCoveredTwice", testSpotlightLaunchAtTheWindowEdgeIsCoveredTwice)
        Check.run("testStagedLaunchWithNoInputIsASteal", testStagedLaunchWithNoInputIsASteal)
        // B. Direct input
        Check.run("testTypingAloneNeverJustifiesAnActivation", testTypingAloneNeverJustifiesAnActivation)
        Check.run("testInputAfterTheActivationIsNotItsCause", testInputAfterTheActivationIsNotItsCause)
        Check.run("testInputWindowBoundary", testInputWindowBoundary)
        Check.run("testMostRecentCauseIsReported", testMostRecentCauseIsReported)
        Check.run("testSpaceChangeBeforeTheActivationCounts", testSpaceChangeBeforeTheActivationCounts)
        Check.run("testSpaceChangeNoticedJustAfterTheActivationCounts", testSpaceChangeNoticedJustAfterTheActivationCounts)
        Check.run("testSwitcherActionCounts", testSwitcherActionCounts)
        // C. Launches
        Check.run("testScriptedLaunchWithNoInputIsASteal", testScriptedLaunchWithNoInputIsASteal)
        Check.run("testSlowLaunchLandsWhenTheUserWaits", testSlowLaunchLandsWhenTheUserWaits)
        Check.run("testSlowLaunchIsAStealOnceTheUserMovedOn", testSlowLaunchIsAStealOnceTheUserMovedOn)
        Check.run("testInputWithinTheSlackKeepsTheLaunch", testInputWithinTheSlackKeepsTheLaunch)
        Check.run("testLaunchIntentExpires", testLaunchIntentExpires)
        Check.run("testSwitchingElsewhereEndsALaunchAtOnce", testSwitchingElsewhereEndsALaunchAtOnce)
        Check.run("testTheLaunchersOwnHandBackKeepsTheLaunch", testTheLaunchersOwnHandBackKeepsTheLaunch)
        // D. Input mapping
        Check.run("testReturnAndEnterAreConfirmKeys", testReturnAndEnterAreConfirmKeys)
        Check.run("testModifierChordsAreShortcuts", testModifierChordsAreShortcuts)
        Check.run("testOnlyCommandControlOptionReleasesCount", testOnlyCommandControlOptionReleasesCount)
        Check.run("testWhichInputsCancelARevert", testWhichInputsCancelARevert)
        // E. Exemptions
        Check.run("testSystemPromptsAreExemptEvenIfRegular", testSystemPromptsAreExemptEvenIfRegular)
        Check.run("testAgentsAreExempt", testAgentsAreExempt)
        Check.run("testUserAllowedAppsAreExempt", testUserAllowedAppsAreExempt)
        Check.run("testOrdinaryAppsAreNotExempt", testOrdinaryAppsAreNotExempt)
        Check.run("testOnlyPromptsMayHoldTyping", testOnlyPromptsMayHoldTyping)
    }

    private static func classify(at activation: Double, launchedAt: Double? = nil,
                                 _ inputs: [Input], switchedBy: Input? = nil) -> FocusIntent.Verdict {
        FocusIntent.classify(activationAt: activation, launchedAt: launchedAt, inputs: inputs,
                             lastSwitchCause: switchedBy)
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

    /// Second run: Return 488 ms before Calculator's activation, just inside the
    /// direct window. Had it come 100 ms later, the launch rule still holds it.
    static func testSpotlightLaunchAtTheWindowEdgeIsCoveredTwice() {
        let returnKey = Input(.confirmKey, at: 11.018)
        Check.equal(classify(at: 11.506, launchedAt: 11.149, [returnKey]), .intended(by: returnKey))
        Check.equal(classify(at: 11.606, launchedAt: 11.149, [returnKey]), .launched(by: returnKey))
    }

    /// Second run's STEAL #1: `sleep 5; open -a Chess`, then hands off. Chess
    /// launched 158 ms before it activated, the last input 3.6 s before that.
    static func testStagedLaunchWithNoInputIsASteal() {
        Check.equal(classify(at: 75.124, launchedAt: 74.966, [Input(.click, at: 71.568)]), .steal)
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

    /// Fails open until the notice order is measured: a swipe that reads as a
    /// steal would be swiped back.
    static func testSpaceChangeNoticedJustAfterTheActivationCounts() {
        let swipe = Input(.spaceChange, at: 10.1)
        Check.equal(classify(at: 10, [swipe]), .intended(by: swipe))
        Check.equal(classify(at: 10, [Input(.spaceChange, at: 10 + FocusIntent.decisionDelay + 0.01)]), .steal)
    }

    /// A click on the panel goes to Switcher's own window and an H or Q is a
    /// Carbon hotkey, so the app records them itself.
    static func testSwitcherActionCounts() {
        let action = Input(.switcher, at: 9.98)
        Check.equal(classify(at: 10, [action]), .intended(by: action))
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

    /// Inside the slack, but the user picked another app: the launch is over.
    static func testSwitchingElsewhereEndsALaunchAtOnce() {
        let inputs = [Input(.confirmKey, at: 0), Input(.switcher, at: 0.3)]
        Check.equal(classify(at: 2, launchedAt: 0.12, inputs, switchedBy: Input(.switcher, at: 0.3)), .steal)
    }

    /// A launcher that closes on Return gives focus back to the previous app on
    /// the same keypress. That switch has the launch's own cause.
    static func testTheLaunchersOwnHandBackKeepsTheLaunch() {
        let returnKey = Input(.confirmKey, at: 0)
        Check.equal(classify(at: 0.7, launchedAt: 0.12, [returnKey], switchedBy: returnKey), .launched(by: returnKey))
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
        Check.expect(FocusIntent.InputKind.switcher.cancelsRevert)
        Check.expect(!FocusIntent.InputKind.typing.cancelsRevert)
        Check.expect(!FocusIntent.InputKind.spaceChange.cancelsRevert)
        Check.expect(FocusIntent.InputKind.spaceChange.canSwitchApps)
        Check.expect(!FocusIntent.InputKind.typing.canSwitchApps)
    }

    // MARK: - E. Exemptions

    static func testSystemPromptsAreExemptEvenIfRegular() {
        for id in ["com.apple.SecurityAgent", "com.apple.systempreferences"] {
            Check.equal(FocusIntent.exemption(bundleID: id, isRegularApp: true, allowed: []), .systemPrompt)
        }
    }

    /// Little Snitch's alerts come from an `LSUIElement` agent.
    static func testAgentsAreExempt() {
        let agent = "at.obdev.littlesnitch.agent"
        Check.equal(FocusIntent.exemption(bundleID: agent, isRegularApp: false, allowed: []), .notARegularApp)
        Check.equal(FocusIntent.exemption(bundleID: agent, isRegularApp: false, allowed: [agent]), .notARegularApp)
        Check.equal(FocusIntent.exemption(bundleID: nil, isRegularApp: false, allowed: []), .notARegularApp)
    }

    static func testUserAllowedAppsAreExempt() {
        let code = "com.microsoft.VSCode"
        Check.equal(FocusIntent.exemption(bundleID: code, isRegularApp: true, allowed: [code]), .allowedByUser)
    }

    static func testOrdinaryAppsAreNotExempt() {
        Check.equal(FocusIntent.exemption(bundleID: "com.apple.Chess", isRegularApp: true, allowed: ["com.apple.TextEdit"]), nil)
        Check.equal(FocusIntent.exemption(bundleID: nil, isRegularApp: true, allowed: []), nil)
    }

    /// An allowed app in front is still guarded. A prompt in front is not, since
    /// a revert would send the rest of a password to the app behind it.
    static func testOnlyPromptsMayHoldTyping() {
        Check.expect(FocusIntent.Exemption.systemPrompt.mayHoldTyping)
        Check.expect(FocusIntent.Exemption.notARegularApp.mayHoldTyping)
        Check.expect(!FocusIntent.Exemption.allowedByUser.mayHoldTyping)
    }
}
