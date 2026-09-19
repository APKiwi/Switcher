# Switcher development

## Build and test

Use `--disable-sandbox` in agent and restricted environments because SwiftPM otherwise invokes
`sandbox-exec` inside the outer sandbox.

```bash
swift build --disable-sandbox
swift run --disable-sandbox SwitcherKernelsTests
```

`SwitcherKernelsTests` is an executable target with a small assertion harness. It prints named failures and
returns nonzero. Do not use `swift test` as proof on a machine with only Command Line Tools. That command can
build a bundle it cannot execute and still return success.

Pure logic belongs in `SwitcherKernels`. Measured window behavior follows the implementation, evidence, and
tests triad used by `WindowFilter` and `MinimizedState`. Keep the scenario lists and executable checks aligned.

## Diagnostic list mode

Build and run the computed application list without registering hotkeys:

```bash
swift build --disable-sandbox
.build/debug/SimpleSwitcher --list-apps
```

The bare binary has no application bundle id and therefore reads a different UserDefaults domain. To prove a
saved preference, build a bundle and run:

```bash
./build-app.sh debug
Switcher.app/Contents/MacOS/SimpleSwitcher --list-apps
```

Do not open the application during routine agent verification. Hand a live Accessibility or visual check to
the user unless the task explicitly requests a launch.

## Bundle and signing

`build-app.sh` builds `Switcher.app`, copies `Info.plist` and the committed icon, and signs the bundle. It
prefers the shared self-signed identity `AP Kiwi Local Signing` so Accessibility permission survives rebuilds.
If the identity is missing, it reports the fallback and signs ad hoc.

Creating or trusting the identity is a one-time machine action under `Scripts/make_signing_cert.sh`. It asks
for login-keychain access and is never part of ordinary automated verification.

For a bundle-related change:

```bash
swift build -c release --disable-sandbox
./build-app.sh release
codesign --verify --deep --strict Switcher.app
```

The bundle is a build artifact. Do not copy it to `/Applications` or open it without explicit authorization.

## Permissions and troubleshooting

Switcher needs Accessibility only. It does not need Input Monitoring or Screen Recording. The minimized-state
query also adds no permission.

Without Accessibility permission, the app leaves native Cmd+Tab working and polls for a grant. macOS caches a
revoked grant for the running process, so removing the permission is not a reliable stop action. Quit from the
menu bar, or relaunch after changing permission.

If native Cmd+Tab remains disabled after an uncatchable SIGKILL, run Switcher again and quit cleanly, or log
out. Normal termination and caught emergency paths restore it.

`MinimizedStateSpecs.md` contains the measured WindowServer bits. Re-run that investigation after a major
macOS update if minimized-only applications reappear. The classifier deliberately fails open.

## Version and tags

This fork publishes no GitHub releases and no Homebrew tap. The app is built from source locally.

`Info.plist` owns the version. Keep `CFBundleVersion` and `CFBundleShortVersionString` equal. If the current
version already has a tag, one requested release batch may bump it and leave it untagged while work continues.
If it is already ahead of the newest tag, keep riding that staged version.

Tags are user-started. Before tagging, update the task branch from current `origin/main`, run the executable
checks and release build, merge through the repository's assigned integration flow, then tag current main.
Push tags only to `origin`.

```bash
git tag -a v1.x.x -m "Switcher v1.x.x"
git push origin v1.x.x
```

Installing the tagged build is separate from tagging and is never automatic.

## Integrating upstream

`upstream` is the read-only `fad1/Switcher` remote. Never write to it. Fetch and integrate onto a fork branch,
then push the reviewed result to `origin`.

Every upstream integration must preserve these fork contracts:

- Remove donation nags, menu items, preference controls, and the `launchCount`, `hasDonated`, `donateURL`,
  and `openDonatePage()` implementation.
- Port `HotkeyManager.swift` instead of resolving it mechanically. Upstream changes overlap the Option-trigger
  paths and hotkey ids have collided before.
- Keep fork hotkey ids above upstream's highest id.
- Register active-session actions with `activeModifier.carbonKey`, not a hardcoded Command modifier.
- Preserve Option+Tab, Option+Shift+Tab, and Option+backtick behavior.
- Run the executable kernel checks and a release build after integration.

Do not recreate upstream's release or Homebrew workflow in this fork.
