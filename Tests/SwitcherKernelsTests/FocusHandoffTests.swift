import SwitcherKernels

enum FocusHandoffTests {
    static func runAll() {
        Check.run("testHandoffAllowsDelayedBrowserOnlyOnce", delayedBrowser)
        Check.run("testHandoffCannotAuthorizeLeague", unrelatedApp)
        Check.run("testHandoffExpiresOrEndsWhenUserMovesOn", movedOn)
        Check.run("testHandoffRejectsOutOfOrderAndFutureInput", ordering)
        Check.run("testHandoffWaitsForTheLatestOverlappingInput", pendingInput)
        Check.run("testRestoreIsCancelledByPromptOrNewActivation", cancellation)
        Check.run("testRestoreRejectsSupersededWork", superseded)
        Check.run("testRestoreNeedsExactVisibleWindow", exactWindow)
    }

    static func delayedBrowser() {
        var handoff = BrowserHandoff()
        let click = FocusIntent.Input(.click, at: 10)
        handoff.recordLink(click, destinations: ["org.mozilla.firefox"])
        Check.equal(handoff.consume(bundleID: "org.mozilla.firefox", at: 12,
                                    inputs: [click, .init(.spaceChange, at: 11.99)], lastSwitchCause: click), click)
        Check.isNil(handoff.consume(bundleID: "org.mozilla.firefox", at: 12.1,
                                    inputs: [click], lastSwitchCause: click))
    }

    static func unrelatedApp() {
        var handoff = BrowserHandoff()
        let click = FocusIntent.Input(.click, at: 10)
        handoff.recordLink(click, destinations: ["org.mozilla.firefox"])
        Check.isNil(handoff.consume(bundleID: "com.riotgames.LeagueofLegends.GameClient", at: 11,
                                    inputs: [click], lastSwitchCause: nil))
        Check.equal(handoff.consume(bundleID: "org.mozilla.firefox", at: 11.5,
                                    inputs: [click], lastSwitchCause: nil), click)
        var empty = BrowserHandoff()
        Check.isNil(empty.consume(bundleID: "browser", at: 10, inputs: [], lastSwitchCause: nil))
    }

    static func movedOn() {
        let click = FocusIntent.Input(.click, at: 10)
        for kind in [FocusIntent.InputKind.typing, .click, .switcher, .shortcut] {
            var handoff = BrowserHandoff()
            handoff.recordLink(click, destinations: ["browser"])
            Check.isNil(handoff.consume(bundleID: "browser", at: 12,
                                        inputs: [click, .init(kind, at: 11)], lastSwitchCause: nil))
        }
        var handoff = BrowserHandoff()
        handoff.recordLink(click, destinations: ["browser"])
        Check.isNil(handoff.consume(bundleID: "browser", at: 50, inputs: [click], lastSwitchCause: nil))
        handoff = BrowserHandoff()
        handoff.recordLink(click, destinations: ["browser"])
        handoff.cancel()
        Check.isNil(handoff.consume(bundleID: "browser", at: 11, inputs: [click], lastSwitchCause: nil))
        handoff = BrowserHandoff()
        handoff.recordLink(click, destinations: ["browser"])
        Check.isNil(handoff.consume(bundleID: "browser", at: 11, inputs: [click],
                                    lastSwitchCause: .init(.switcher, at: 10.2)))
    }

    static func ordering() {
        var handoff = BrowserHandoff()
        let latest = FocusIntent.Input(.click, at: 20)
        handoff.recordLink(latest, destinations: ["newBrowser"])
        handoff.recordLink(.init(.click, at: 10), destinations: ["oldBrowser"])
        Check.isNil(handoff.consume(bundleID: "newBrowser", at: 19, inputs: [], lastSwitchCause: nil))
        Check.equal(handoff.consume(bundleID: "newBrowser", at: 21, inputs: [latest], lastSwitchCause: nil), latest)
    }

    static func pendingInput() {
        var inspection = BrowserHandoff.Inspection<String>()
        Check.expect(inspection.begin("non-link"))
        Check.expect(!inspection.begin("first link"))
        Check.expect(!inspection.begin("latest link"))
        Check.expect(inspection.isBusy)
        Check.equal(inspection.finish(), "latest link")
        Check.expect(inspection.isBusy, "the browser must still wait for the retained link query")
        Check.isNil(inspection.finish())
        Check.expect(!inspection.isBusy)
        Check.expect(inspection.begin("new click"))
        Check.expect(!inspection.begin("cancelled link"))
        inspection.cancelPending()
        Check.isNil(inspection.finish())
        Check.expect(!inspection.isBusy)
    }

    static func cancellation() {
        var state = FocusRestoration()
        let ticket = state.begin(stealer: 20, target: 10, window: 100)
        Check.expect(state.canRestore(ticket, frontmost: 20, protected: false))
        Check.expect(!state.canRestore(ticket, frontmost: 20, protected: true))
        state.activated(30, protected: true)
        Check.expect(!state.canRestore(ticket, frontmost: 20, protected: false))
        let next = state.begin(stealer: 20, target: 10, window: 100)
        state.activated(40, protected: false)
        Check.expect(!state.canRestore(next, frontmost: 20, protected: false))
    }

    static func superseded() {
        var state = FocusRestoration()
        let old = state.begin(stealer: 20, target: 10, window: 100)
        let current = state.begin(stealer: 21, target: 10, window: 101)
        Check.expect(!state.canRestore(old, frontmost: 20, protected: false))
        Check.expect(state.canRestore(current, frontmost: 21, protected: false))
        Check.expect(!state.canRestore(current, frontmost: 99, protected: false))
        state.cancel()
        Check.expect(!state.canRestore(current, frontmost: 21, protected: false))
    }

    static func exactWindow() {
        var state = FocusRestoration()
        let ticket = state.begin(stealer: 20, target: 10, window: 100)
        state.activated(10, protected: false)
        Check.expect(state.canRestore(ticket, frontmost: 10, protected: false))
        Check.expect(!state.landed(ticket, frontmost: 10, window: 101, onScreen: true))
        Check.expect(!state.landed(ticket, frontmost: 10, window: 100, onScreen: false))
        Check.expect(!state.landed(ticket, frontmost: 10, window: nil, onScreen: true))
        Check.expect(state.landed(ticket, frontmost: 10, window: 100, onScreen: true))
        state.cancel()
        Check.expect(!state.landed(ticket, frontmost: 10, window: 100, onScreen: true))
    }
}
