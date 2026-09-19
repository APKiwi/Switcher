# Switcher

A fast, lightweight Cmd+Tab replacement for macOS. No bloat, no lag, no memory leaks.

## Why Switcher?

**Frustrated with AltTab?** You're not alone. AltTab is powerful but comes with costs:
- 🐌 Sluggish performance over time
- 💾 Memory usage that grows unbounded
- 🔋 Background CPU drain
- 🐛 Occasional freezes and glitches
- ⚙️ Complex settings for features you don't use

**Switcher takes a different approach:** do less, but do it well.

## What Switcher Does

- ✅ Shows only apps with visible windows (no hidden/minimized clutter)
- ✅ Sorts by most recently used
- ✅ Native macOS blur effect
- ✅ Instant response (<16ms)
- ✅ Light memory footprint (releases its UI when idle)
- ✅ Negligible background CPU (a lightweight permission check, no window polling)
- ✅ Keyboard shortcuts: H to hide, Q to quit, M to minimize, Cmd+, for Preferences, Shift to go back
- ✅ Mouse support: hover to select, click to activate
- ✅ Multi-monitor: appears on screen where your pointer is
- ✅ Optional: show only your N most recent apps — Cmd+Opt+Tab reveals the rest when you need them

## What Switcher Doesn't Do

- ❌ Window thumbnails (requires Screen Recording permission)
- ❌ Per-window switching
- ❌ Themes or extensive customization
- ❌ Anything else

**This is intentional.** Switcher does one thing and does it well.

## Installation

This is a fork of [fad1/Switcher](https://github.com/fad1/Switcher) that adds
Option+Tab, Option+backtick window cycling, and removes the donation prompts. It
publishes no Homebrew tap and no release builds, so build it from source:

```bash
git clone https://github.com/APKiwi/Switcher.git
cd Switcher
swift build -c release
./create-icon.sh  # optional: creates app icon
./build-app.sh release
cp -R Switcher.app /Applications/
```

### First Run

1. Open **Switcher.app**
2. When prompted, grant Accessibility permission in **System Settings → Privacy & Security → Accessibility** (toggle Switcher on)
3. Switcher takes over Cmd+Tab automatically within ~1 second — no relaunch needed

Until you grant permission, Switcher **leaves your native Cmd+Tab working** and waits, so it can never get stuck. You can quit any time from its menu bar icon (⌘ → Quit).

> The grant survives rebuilds, since the build signs with a stable local identity. If that identity is missing the build falls back to ad-hoc signing and says so, and then you do need to remove and re-add Switcher under Accessibility after a rebuild.

### Stopping Switcher

To turn Switcher off, use **menu bar ⌘ → Quit**.

> Removing its Accessibility permission is *not* a reliable off-switch: macOS caches an app's permission for its entire running lifetime, so Switcher keeps working until you **relaunch** it (at which point it sees no permission and leaves Cmd+Tab alone). Switcher uses a *passive* event tap, so — unlike many tools — revoking its permission does **not** risk the [known macOS input-freeze](https://developer.apple.com/forums/thread/735204) that active-tap apps can trigger.

### Auto-Start
Open **Preferences** (menu bar ⌘) and tick **Start at login** (macOS 13+). Or add it manually via System Settings → General → Login Items.

## Usage

| Key | Action |
|-----|--------|
| Cmd+Tab | Open switcher / next app |
| Option+Tab | Same as Cmd+Tab, for when Cmd is already in use |
| Cmd+Shift+Tab | Open switcher / previous app |
| Option+Shift+Tab | Same, during an Option session |
| Cmd+Opt+Tab | Show all apps (when the recent-apps limit is on) |
| Option+backtick | Cycle the front app's windows (mirrors Cmd+backtick) |
| Shift | Previous app |
| ←/→ | Navigate left/right |
| ↑/↓ | Navigate up/down (when multiple rows) |
| H | Hide selected app |
| Q | Quit selected app |
| M | Minimize selected app's windows |
| , | Open Preferences |
| Return | Activate |
| Escape | Dismiss |
| Release Cmd (or Option) | Activate selected |

Mouse: hover to select (after slight movement), click to activate.

## Preferences

Switcher runs in the background. Open **Preferences** from its menu bar icon, or by
launching Switcher again while it's already running. The window lets you:

- **Start at login** — launch Switcher automatically (macOS 13+)
- **Show icon in menu bar** — toggle the menu bar icon on or off
- **Grayscale icons** — show app icons without color (applies on the next Cmd+Tab)
- **Show declutter tip in switcher** — the ⌥⌘H "Hide others" hint that appears at 2+ rows
- **Hide apps with only minimized windows** — keep fully-minimized apps out of the list
- **Show only the [N] most recently used apps** — cap the switcher to your N most recent apps (2–12). When it's on, **Cmd+Opt+Tab** shows the full list for that one press of the switcher — handy when the app you want is older than the cap

The menu bar icon (⌘) also has a quick **Grayscale Icons** toggle, plus Preferences, Hide Other Apps, and Quit.

Grayscale can still be set from the terminal if you prefer:
```bash
defaults write com.simpleswitcher.app grayscaleIcons -bool true   # enable
defaults delete com.simpleswitcher.app grayscaleIcons             # revert
```

## Permissions

**Only Accessibility** — no Input Monitoring, no Screen Recording, no admin access.

## Technical Details

~3,000 lines of Swift across 13 files, plus ~400 lines of pure, tested kernel logic. No dependencies. Uses:
- Carbon hotkeys (avoids Input Monitoring requirement)
- CGEvent tap for modifier detection
- Private `CGSSetSymbolicHotKeyEnabled` API to intercept native Cmd+Tab

See [Switcher architecture](docs/ARCHITECTURE.md) for architecture details.

## Philosophy

> "Perfection is achieved not when there is nothing more to add, but when there is nothing left to take away." — Antoine de Saint-Exupéry

Switcher exists because sometimes you just want to switch apps. Fast. Without thinking about it. Without your computer grinding to a halt after a week of uptime.

If you need window thumbnails, per-window switching, or extensive customization, use AltTab. It's a great project with different goals.

If you want a Cmd+Tab that just works, try Switcher.

## Support

[![Support me on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/apkiwi)

## License

MIT
