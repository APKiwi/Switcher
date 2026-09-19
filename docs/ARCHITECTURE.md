# Switcher architecture

Switcher is a macOS accessory application that replaces the system app-switching gesture while it is running.
It shows regular applications with usable windows or Dock badges, orders them by recent use, and presents them
in a non-activating panel.

## Topology

`Sources/SimpleSwitcher` owns macOS integration and mutable state:

- `main.swift` installs process cleanup and starts `NSApplication`.
- `AppDelegate.swift` owns the idle and active session state and coordinates the other components.
- `HotkeyManager.swift` owns Carbon registrations, passive event-tap observation, modifier release, and the
  sticky-panel watchdog.
- `AppListProvider.swift` classifies windows, maintains MRU order, and applies the optional recent-app cap.
- `AppSwitcherPanel.swift` lays out the non-activating panel, click shields, selection, and mouse handling.
- `AppItemView.swift` draws an icon, selection, and optional Dock badge.
- `WindowActions.swift` performs deliberate Accessibility actions such as minimizing another app's windows.
- `Preferences.swift`, `PreferencesWindowController.swift`, `StatusBarController.swift`, and `LoginItem.swift`
  own settings and supporting surfaces.
- `PrivateAPIs.swift` declares the symbolic-hotkey and WindowServer query entry points.

`Sources/SwitcherKernels` contains pure logic with no AppKit, IPC, or mutable global state. The executable
checks under `Tests/SwitcherKernelsTests` exercise these kernels directly.

## Session and hotkey model

The application moves between `idle` and `active`. A global Cmd+Tab, Cmd+Shift+Tab, Option+Tab, or
Option+Shift+Tab opens a session. `TriggerModifier` records whether Command or Option opened it. All active
registrations, release detection, and watchdog checks follow that modifier until the session closes.

Option+backtick raises the backmost non-minimized Accessibility window in the front application. It does not
synthesize Cmd+backtick because the physically held Option modifier leaks into synthetic events and prevents
the system shortcut from matching.

The show-all shortcut is registered only while the recent-app cap is enabled. Carbon consumes a registered
combination globally, so registering it while the feature is off would steal a shortcut that does nothing.
The registration is idempotent and waits until the Carbon handler exists.

Shift-tap fires on Shift release only when no Shift+Tab occurred during that hold. `ShiftTapResolver` owns this
state machine because firing on press would double-step reverse Tab.

While the panel is active, ordinary modifier combinations that are not actions are registered as no-ops so
they do not leak to the application behind the panel. Option+backtick is excluded during an Option session
because its global registration already owns that exact combination.

## Permission and input safety

`enableSwitching()` creates the `.listenOnly` event tap before it disables system symbolic hotkeys or
registers replacement hotkeys. If Accessibility permission is missing, native Cmd+Tab remains available and
the app asks for permission. A background poll notices a new grant and enables switching.

macOS can cache `AXIsProcessTrusted()` for the lifetime of a process. Revoking permission may not be visible
until relaunch. This is safe because a passive tap never blocks the WindowServer. If revocation is observed,
the app restores native hotkeys and quits as cleanup.

A passive tap cannot consume outside mouse clicks. `AppSwitcherPanel` therefore creates an invisible shield
window on every screen, one level below the switcher. The shields dismiss the session without delivering the
click to the application underneath.

Modifier release normally arrives through `flagsChanged`. A dedicated high-priority tap thread reduces lost
events, and a roughly 100 ms watchdog independently checks the physical modifier while the panel is active.
Both dismissal paths are idempotent.

## Window discovery and minimized state

`AppListProvider` starts with `CGWindowListCopyWindowInfo`. `WindowFilter` accepts usable layers and minimum
bounds, including off-screen windows with an owner name so windows on other Spaces remain switchable. A Dock
badge independently rescues an application with no accepted window.

CGWindowList cannot distinguish a minimized window from one on another Space. Windows accepted only by the
off-screen branch are submitted in one batched `SLSWindowQueryWindows` request. `MinimizedState` decodes the
measured WindowServer tags into keep, minimized, or not-switchable. Invisible helper windows must reach the
third state or they keep applications such as browsers and messaging clients in the list forever.

Every query failure fails open. A failed batch, empty result, or missing window id means not minimized. This
may show an extra application after a macOS change but never makes a usable application disappear.

The diagnostic `--list-apps` mode prints the uncapped classification, exclusion reasons, badge rescues, and
the recent-app cut line. It exits before registering hotkeys. A bare SwiftPM binary uses a different
UserDefaults domain from the app bundle, so preference-sensitive diagnostics must use the bundled binary.

## Ordering and live refresh

MRU order is seeded at launch from front-to-back window order, deduplicated by application, with the current
front application forced to the head. macOS exposes no complete activation history, so this is a launch-time
proxy. Workspace activation notifications replace it with real use immediately.

The optional recent-app limit applies after the single MRU sort. It is off by default and saves its enabled
state separately from the selected count. A Dock badge does not exempt an application from the cap. Show-all
expands only the current session.

While the panel is open, a slow refresh appends newly visible applications without removing or reordering
existing items. Applications acted on with hide, quit, or minimize still consume their slot for that session
so the panel cannot refill behind the user's actions. An expanded session remains uncapped for refreshes.

## Panel and preferences

The panel is non-activating, uses the screen under the pointer, wraps into rows, and scales icons from the
target screen height. Hover starts only after the pointer moves from its opening position. Both a global mouse
monitor and an active tracking area are required because global monitors do not see events delivered to the
active Switcher process.

`GridNavigation` owns wrapping, row changes, short-last-row clamping, and reflow after an item disappears.
Grayscale is baked into the icon bitmap in sRGB. Applying a layer filter causes selection changes to
re-rasterize the icon and badge.

`Preferences` is the only persisted settings interface. Defaults must be registered before the initial MRU
seed because window classification reads them. The recent-app feature uses separate enabled and count keys so
turning it off does not discard a tuned count. This fork has no donation state or UI.

## Private APIs and threading

`CGSSetSymbolicHotKeyEnabled` disables and restores native switching. The WindowServer query family provides
the minimized-state snapshot. SkyLight query symbols require the explicit private-framework search path and
link in `Package.swift`.

The tap callback and main UI do not share unsynchronized mutable state. `HotkeyManager` protects active state
with a serial queue and writes it synchronously before dispatching delegate work. This ordering is required in
optimized builds.

`WindowActions` uses Accessibility calls only after deliberate input. Calls run off the main queue with a
messaging timeout because another application can be hung. Accessibility exposes only windows on the current
Space, so minimize cannot clear other Spaces. Hide remains the immediate all-Spaces alternative.
