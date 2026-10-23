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
   Option chords and releases, and observed gestures count. Space-change notifications alone do not count.

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
| Microsoft AutoUpdate window | `com.microsoft.autoupdate2` | not set |
| Microsoft Update Assistant and AU Daemon | `com.microsoft.autoupdate.fba` | `LSUIElement` 1 |

When every agent counted as a prompt, League's helper coming forward made its own client window's next activation
read as leaving a prompt, so the guard let it through. Microsoft Update Assistant launched in the same second as the
AutoUpdate window it opened, and that window kept focus the same way. Little Snitch ignores keystrokes for the first second after
an alert appears and offers no setting to stop the alert taking focus.

Third-party credential prompts are agents too. GPG's pinentry-mac (`org.gpgtools.pinentry-mac`, `LSUIElement` true
in its source) is listed with the prompts. OpenVPN Connect, OneDrive and Proton Mail Bridge are installed agents
that can ask to sign in again with no input behind it, so a steal holding a focused password field keeps focus.

## Secure keyboard entry

Measured 2026-10-21 on 27.0.1 by calling `EnableSecureEventInput` from a command-line process and from an
accessory app that never activated. In both, `IsSecureEventInputEnabled()` turned true and
`CGSessionCopyCurrentDictionary()`'s `kCGSSessionSecureInputPID` named the frontmost app (Firefox), not the caller.
The holder PID therefore cannot tell who turned it on. The guard asks only whether it is on while the stealer is
in front, and a leaked secure input lets every steal through while it lasts.

## Not yet measured

- Whether desktop gesture envelopes reach the passive tap on each supported macOS version. The earlier rule
  that accepted a Space-change notice as intent let a cross-Space steal justify itself. Gesture timestamps now
  provide the input evidence. A refused or disabled gesture tap retains the fail-open Space behavior.
- Launches slower than a few seconds, with and without the user moving on.
- Live admin prompts (`sfltool` background item prompts). The exemption rests on the `Info.plist` evidence above,
  not on a prompt seen by the probe.
- Whether secure input is already on 150 ms after a prompt takes focus with its password field focused, for
  pinentry-mac, OpenVPN Connect and OneDrive's sign-in. AX modal state and focused-element notifications now
  supplement secure input. The real timing still needs a live check.
- Whether a reverted Little Snitch connection or changed-binary alert stays on screen. A panel that hides when its
  app deactivates would vanish, and the user would have to allow the agent.
- How often League of Legends' client and game activate in a row, and whether any app takes focus straight back
  after a revert. A revert is now called 150 ms after a steal instead of one second, so it should land about 175 ms after it.

Re-run the probe after a major macOS update.

## Focus handoff corrections

The owner reported cross-Space League activations, hidden `sfltool` installation password prompts, and
Choosy automatic browser routing being reverted. These reports identify the affected flows but are not a
recorded probe run. No live desktop switch or authentication prompt was triggered by the implementation session.

Source inspection found that raw Space notices counted as input, restore success tested only the app PID,
password-field checks were skipped for intentional activations, and pending AX restore work could outlive its
activation. The executable checks now pin these rules:

- A Space notice before or after an activation cannot authorize it. An observed gesture or Control+arrow
  navigation can cover its animation.
- A browser handoff requires link evidence and a registered browser destination. It is consumed once, expires,
  rejects stale/out-of-order evidence, and ends when the user moves on. League cannot consume it.
- New input, a prompt, a different activation or a newer restore invalidates old restore tickets.
- The right app with a different window, an off-screen window or an unknown window is not an exact-window success.

The runtime reads AX link roles, focused window ids, secure-field subroles and modal state. It also checks visible
windows owned by the listed prompt agents before each restore. It never reads password values or logs key text,
window titles or URLs. Failure to inspect the activating app because it is unresponsive leaves focus alone.

Symbol lookup on this machine confirmed `_AXUIElementGetWindow`, `_SLPSSetFrontProcessWithOptions` and
`GetProcessForPID` are present. None was invoked during that check.

Implementation references, not live behavior measurements on this machine:

- [Apple's Space notification](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)
  reports a change without a cause dictionary.
- [Apple's AX hit testing](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition)
  supplies the control at a click, and the focused control covers Return on a link.
- [yabai's exact-window focus](https://github.com/koekeishiya/yabai/blob/v6.0.0/src/window_manager.c)
  uses `_SLPSSetFrontProcessWithOptions` with a window id and AX raise. Switcher resolves the optional symbols
  dynamically and verifies the focused id and visibility instead of trusting the call's return value.
- [Dock gesture envelopes](https://github.com/oomol-lab/dockswipe/blob/main/dockswipe.m) use session event types
  29 and 30. macOS 27 changed their payload. Switcher observes only the envelopes, never their private payload.
  Other gestures can therefore grant the same short grace period. This deliberately fails open.

Required live checks with the installed guard off and `--focus-probe` running:

1. Leave League on another desktop and work in a particular window of an app with windows on several desktops.
   A steal should return to that window and log a verified window id. Deliberate keyboard and trackpad desktop
   changes must stay put. A missing or closed saved window must not be reported as an exact-window success.
2. Show the `sfltool` installation password prompt during and just after a suspected steal. Keep the prompt
   visible long enough to exercise delayed callbacks. No restore should cover it. Cancel instead of submitting
   if installation is not intended. Do not include a password in a log or report.
3. Click a link routed automatically through Choosy with the destination browser already running, then with a
   cold browser. The reported source is an Outlook message linking to Azure DevOps. Expect `link action`
   followed by `intended browser handoff`, with no Choosy picker required.
   A source that does not expose AXLink cannot provide this extra evidence. Note the source app if that happens.
4. Click or switch elsewhere while a browser request or restore is pending. The newer choice must win.

The probe logs verified restores, cancellation reasons, link-evidence detection and gesture observer availability.
Passing kernel checks and builds cannot substitute for these live checks.
