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

## Not yet measured

- Whether a trackpad Space swipe's `activeSpaceDidChange` notice arrives before or after the activation it causes.
  If it arrives after, a swipe reads as a steal.
- Launches slower than a few seconds, with and without the user moving on.

Re-run the probe after a major macOS update.
