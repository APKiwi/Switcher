# Focus intent: measured behavior

Evidence for `FocusIntent`. Measured with `SimpleSwitcher --focus-probe` on macOS 27.0.1 (26A434), 2026-10-19,
beside an installed Switcher. Times are seconds since the probe started.

## Permissions

- Global `NSEvent` monitors receive `keyDown` from other apps with Accessibility only. The TCC database held an
  Accessibility row for `com.simpleswitcher.app` and no Input Monitoring row, yet 151 key presses arrived and
  `CGPreflightListenEventAccess()` returned true.
- `NSRunningApplication.activate(options:)` called from a timer, with no input behind it, brought the previous app
  back 25 ms and 27 ms after the call, two of two. The `kAXFrontmostAttribute` fallback was never needed.

## How the 300 ms rule failed

FocusGuard calls an activation intended when any input arrived in the 300 ms before it.

| Case | Input before activation | Launch before activation | 300 ms rule | Right answer |
| --- | --- | --- | --- | --- |
| TextEdit from Spotlight | Return 563 ms | 440 ms | steal, reverted mid-boot | intended |
| Calculator from Spotlight | Return 372 ms | 229 ms | steal, reverted mid-boot | intended |
| `sleep 5; open -a Chess` while typing | key 253 ms | 275 ms | intended | steal |
| Dock click back to Calculator | click delivered 0 ms after the notice | | steal until the grace period | intended |
| Switcher hold of 727 ms | Command release delivered 11 ms after the notice | | steal until the grace period | intended |

Three causes, one rule change each:

1. A cold launch starts 123 to 143 ms after Return and activates 229 to 440 ms after it starts. Judge a launch from
   its start (`launchWindow`), and keep that intent while the user waits for it.
2. The input behind an activation can reach the monitor after the activation notice. Decide `decisionDelay` later
   with event timestamps.
3. Typing is not a reason for another app to come forward. Only clicks, Return or Enter, Command, Control or
   Option chords and releases, and Space changes count.

## Second run, with these rules

The same day, 18 activations: 17 intended and one steal. Three were launches inside the direct window
(Calculator from Spotlight 488 ms after Return, TextEdit 392 ms, Terminal 325 ms after a click). The steal was a
staged `sleep 5; open -a Chess` with no input for 3.6 s. Chess activated 158 ms after it launched, and
`NSRunningApplication.activate` brought TextEdit back 28 ms after the call. Another Chess launch never took focus
itself and came forward 5.5 s after it started, on a click.

## Exemptions

Read from `Info.plist` on 27.0.1. SecurityAgent (`com.apple.SecurityAgent`), the LocalAuthentication agent behind
Touch ID and password sheets (`com.apple.LocalAuthentication.UIAgent`) and `com.apple.UserNotificationCenter` set
`NSUIElement`. CoreServicesUIAgent (`com.apple.coreservices.uiagent`, Gatekeeper) sets `LSUIElement`. All run as
`com.apple.*` agents, so the macOS-agent rule covers them, and they are also listed by bundle id, with System
Settings, which is a regular app.

Third-party agents are guarded, read 2026-10-21:

| Bundle | Id | Agent |
| --- | --- | --- |
| Little Snitch Agent, connection alerts | `at.obdev.littlesnitch.agent` | `LSUIElement` true |
| League of Legends client helper | `com.riotgames.LeagueofLegends.LeagueClient` | `LSUIElement` 1 |
| League of Legends client window | `com.riotgames.LeagueofLegends.LeagueClientUx` | `LSUIElement` 0 |
| League of Legends game | `com.riotgames.LeagueofLegends.GameClient` | `LSUIElement` 0 |

When every agent counted as a prompt, League's helper coming forward made its own client window's next activation
read as leaving a prompt, so the guard let it through. Little Snitch ignores keystrokes for the first second after
an alert appears and offers no setting to stop the alert taking focus.

## Not yet measured

- Whether a trackpad Space swipe's `activeSpaceDidChange` notice arrives before or after the activation it causes.
  Until it is measured, a Space change noticed up to `decisionDelay` after an activation counts as its cause. A
  swipe is never swiped back, and a steal from another Space is let through.
- Launches slower than a few seconds, with and without the user moving on.
- Live admin prompts (`sfltool` background item prompts). The exemption rests on the `Info.plist` evidence above,
  not on a prompt seen by the probe.
- Whether a reverted Little Snitch connection or changed-binary alert stays on screen. A panel that hides when its
  app deactivates would vanish, and the user would have to allow the agent.
- How often League of Legends' client and game activate in a row, and whether any app takes focus straight back
  after a revert. A revert is now called 150 ms after a steal instead of one second, so it should land about 175 ms after it.

Re-run the probe after a major macOS update.
