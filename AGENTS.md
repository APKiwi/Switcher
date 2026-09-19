# Switcher contributor instructions

Switcher is a small macOS Cmd+Tab replacement written in Swift. This repository is the `APKiwi/Switcher`
fork of `fad1/Switcher`. Project rules live here. Personal and tool-specific working rules belong outside
the repository.

## Required reading by task

Read this file for every task, then read only the matching references before changing files.

| Task | Required references |
| --- | --- |
| Architecture, hotkeys, window filtering, UI, preferences, or permissions | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| Build, tests, diagnostics, signing, release tags, or upstream integration | [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) |
| Window acceptance or minimized-state decoding | [`Sources/SwitcherKernels/WindowFilterSpecs.md`](Sources/SwitcherKernels/WindowFilterSpecs.md), [`Sources/SwitcherKernels/MinimizedStateSpecs.md`](Sources/SwitcherKernels/MinimizedStateSpecs.md) |
| User-facing behavior and supported shortcuts | [`README.md`](README.md) |

The code and executable kernel checks remain the final contract. Update the relevant reference when a durable
behavior or workflow changes.

## Fork and remote boundary

- `origin` is the writable `APKiwi/Switcher` fork. Push task branches only to `origin`.
- `upstream` is the read-only `fad1/Switcher` source. Fetching is allowed. Never push, open issues or pull
  requests, or post comments to `upstream`.
- Preserve the fork-only Option triggers, Option+backtick window cycling, stable local signing, and removal of
  every donation surface when integrating upstream work.
- Upstream changes to `HotkeyManager.swift` are ported onto the fork instead of resolved mechanically. Keep
  fork hotkey ids above upstream's highest id and keep active-session registrations on
  `activeModifier.carbonKey`.

## Work and finish

- Work in a task branch and worktree. Preserve unrelated local changes.
- Keep changes scoped. Record unrelated durable work as a GitHub issue in `APKiwi/Switcher` after searching
  open and closed issues for prior work.
- Merge current `origin/main` into the task branch before final verification when main moved during the task.
- Commit the verified change and push the task branch to `origin`. Do not merge to `main`, tag, install the
  app, or publish anything unless the task explicitly assigns that step.
- Do not launch the app for routine verification. Use the executable kernel checks and diagnostic list mode.
  A live Accessibility or visual check is a human handoff unless explicitly requested.

## Verification

Run from the worktree root:

```bash
swift build --disable-sandbox
swift run --disable-sandbox SwitcherKernelsTests
```

Do not substitute `swift test`. Command Line Tools can build an XCTest bundle without running it and still
exit successfully. `SwitcherKernelsTests` is the repository's executable test runner and must print its passed
check count.

For release-build, bundle, signing, or private-framework changes, also run:

```bash
swift build -c release --disable-sandbox
./build-app.sh release
codesign --verify --deep --strict Switcher.app
```

Building the bundle is allowed when relevant. Installing or opening it is a separate user-authorized action.

## Safety and architecture invariants

- Never disable native Cmd+Tab until the passive event tap exists. Restore native symbolic hotkeys on every
  clean shutdown and emergency path.
- The event tap stays `.listenOnly`. Click-away swallowing belongs to the panel's shield windows. Do not move
  that behavior to an active event tap, which can freeze input when Accessibility permission changes.
- Permission failure leaves native switching working. Grant detection may take over after launch. Permission
  revocation cleanup is best effort because macOS caches trust for the process lifetime.
- A Command session and an Option session use the modifier captured when the panel opens. Registration,
  release detection, the watchdog, and selection behavior must all use that active modifier.
- State read by the tap thread is synchronized. Event handlers set active state before dispatching delegate
  work to the main queue.
- Window filtering fails open. A private WindowServer query failure may show an extra app but must never hide
  an app the user could switch to.
- WindowServer minimized-state reads stay batched. Revalidate undocumented tag bits on every major macOS
  update against `MinimizedStateSpecs.md`.
- The recent-app cap is off by default. It limits the MRU-ordered list only. The show-all shortcut expands the
  current session without changing the saved preference.
- Pure decision logic belongs in `SwitcherKernels`. A kernel with measured behavior keeps implementation,
  evidence in `*Specs.md`, and executable checks aligned.
- SkyLight symbols require the explicit private-framework link in `Package.swift`. Private API changes must
  preserve the fail-safe behavior described above.

## Build, signing, and release boundaries

- `build-app.sh` prefers the stable `AP Kiwi Local Signing` identity and falls back to ad hoc signing. Do not
  create or alter signing identities during an ordinary code task.
- The fork publishes no GitHub releases and no Homebrew tap. It is built from source and installed locally.
- `Info.plist` is the single version source. Keep `CFBundleVersion` and `CFBundleShortVersionString` equal.
- Bump once for a batch only when release work requires it. Create and push an annotated tag only when the
  user explicitly asks. Tags go to `origin`.

## Contributor instruction harness

`AGENTS.md` is the canonical tool-neutral root. `CLAUDE.md` is a thin import. The combined size of
`AGENTS.md`, `AGENTS.override.md` when present, and `CLAUDE.md` must stay at or below 16 KiB. Put detailed
reference material under `docs/` and link it from the task table.

`.claude/settings.json` and `.codex/hooks.json` are byte-identical active hook registrations. The Codex runtime
file is `.codex/hooks.json`. Do not create `.codex/settings.json`. The pre-commit hook and CI run the same
instruction-budget check. Do not bypass a failing hook.
