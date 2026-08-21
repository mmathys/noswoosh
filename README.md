# noswoosh

Instant, animation-free switching between macOS Spaces with **Ctrl+←/→**.
No SIP disabling, no global Reduce Motion.

[![Latest release](https://img.shields.io/github/v/release/mmathys/noswoosh?color=blue)](https://github.com/mmathys/noswoosh/releases/latest)
[![MIT license](https://img.shields.io/github/license/mmathys/noswoosh?color=blue)](LICENSE)
![macOS 12+](https://img.shields.io/badge/macOS-12%2B-lightgrey)

![Side-by-side: the macOS space-switch animation versus noswoosh switching instantly](assets/demo.gif)

## Install

```sh
brew install --cask mmathys/tap/noswoosh
```

This installs `noswoosh.app`, runs the one-time system configuration, and starts a
login daemon.

Then **grant Accessibility permission** — macOS gates synthetic events behind it, and
it's the one step that can't be scripted. Approve the prompt on first start; if you
dismiss it, noswoosh opens **System Settings → Privacy & Security → Accessibility**
for you, where you can add `/Applications/noswoosh.app` yourself.

That's it — the daemon picks the grant up within a second, and **Ctrl+←/→** switches
spaces instantly.

<details>
<summary><b>Build from source instead</b></summary>

Requires Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/mmathys/noswoosh.git
cd noswoosh
./scripts/install.sh
```

The installer compiles `noswoosh.swift` to `~/.local/bin/`, runs `noswoosh setup`, and
installs a LaunchAgent (`ax.max.noswoosh`) that logs to `~/Library/Logs/noswoosh.log`.
Grant Accessibility to `~/.local/bin/noswoosh`.

Set `NOSWOOSH_SIGN_IDENTITY="Developer ID Application: ..."` to codesign the local
build, which keeps the grant across rebuilds.

</details>

## Usage

**Ctrl+→ / Ctrl+←** switches one space right/left, instantly. Movement is clamped at
the first and last space, so there's no rubber-band bounce.

A CLI is available for scripting and debugging:

```sh
noswoosh list      # "space 2 of 4"
noswoosh right     # switch once and exit
noswoosh left
noswoosh setup     # apply system config (teardown reverses it)
noswoosh teardown
noswoosh version
```

### What `setup` changes

Both are user-level; no `sudo`, no SIP changes. `noswoosh teardown` reverses both.

| Change | Why |
| --- | --- |
| Disables the system's animated Ctrl+←/→ shortcuts (symbolic hotkeys 79/81) | They'd otherwise consume the key combo first. Ctrl+Shift+arrows and all other shortcuts are untouched. |
| `defaults write com.apple.dock workspaces-auto-swoosh -bool NO` | Fixes the [empty-desktop yank](#the-empty-desktop-yank). Restarts the Dock. |

## How it works

macOS has no supported way to disable *only* the space-switch slide animation:

- The old `defaults write com.apple.dock workspaces-swoosh-animation-off` died with
  Lion (2011).
- **Reduce Motion** works but is global — and it's a crossfade, not an instant cut.
- Per-app accessibility settings (Reduce Motion for the Dock alone) exist on iOS, not
  macOS.
- yabai can do it, but only with SIP partially disabled.

noswoosh takes the approach used by
[InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher),
[WhichSpace](https://github.com/gechr/WhichSpace) and BetterTouchTool: synthesize a
Dock-swipe trackpad gesture with **near-zero progress and high velocity**. The switch
runs through the Dock's own pipeline — so Mission Control, focus, wallpaper and Dock
state all stay consistent — but the animation has zero distance to travel, making it
instant.

> The name: *swoosh* is Apple's own word for the space-slide animation, from the
> long-dead Snow Leopard setting `workspaces-swoosh-animation-off`. This is that
> setting, resurrected.

### The empty-desktop yank

While building this we found a macOS behavior reproducible with plain native
switching: **switch to a desktop with no windows, and ~400 ms later macOS yanks you to
a different desktop.** The chain of events, visible in the Dock's log:

1. Landing on a windowless space, WindowServer re-promotes the last-active app to
   front process.
2. That app (AppKit) re-orders its key window — which lives on another space.
3. The Dock's window-order follow rule fires (`switching to space N for window ordered
   on non-visible space`) and you're yanked to wherever that window lives.

Disassembling the Dock shows this follow rule is a **separate code path** from the
"switch to a Space with open windows when switching to an application" setting
(`AppleSpacesSwitchOnActivate` — disabling that does *not* help). The Dock registers
for the underlying WindowServer notification at startup only when the legacy pref
`workspaces-auto-swoosh` is true, which is the default. Hence the fix, fittingly a
sibling of the extinct key this tool is named after:

```sh
defaults write com.apple.dock workspaces-auto-swoosh -bool NO
killall Dock
```

`noswoosh setup` applies this. Side effect, arguably a feature: a window opening on
another space no longer auto-drags you to it.

## Troubleshooting

**Ctrl+arrows do nothing.** Check `~/Library/Logs/noswoosh.log`. A
`waiting for Accessibility permission` line as the last entry means the daemon still
isn't trusted; once you grant it, the log shows `Accessibility granted` and the daemon
restarts itself.

**The Accessibility checkbox won't stick.** Remove the entry with "−" and let the
daemon re-trigger the prompt, then approve it. If it still won't take:

```sh
launchctl kickstart -k gui/$(id -u)/ax.max.noswoosh
```

**Spaces switch in an unexpected order.** Turn off "Automatically rearrange Spaces
based on most recent use" in System Settings → Desktop & Dock.

## Caveats

- **Private APIs.** `SLSCopyManagedDisplaySpaces`, `SLSCopySpacesForWindows`,
  `_SLPSSetFrontProcessWithOptions` and the undocumented gesture `CGEventField`s are
  unsupported by Apple and can break in any macOS release. (Known: macOS 27 betas
  changed gesture-event serialization — see WhichSpace for the IOHID-payload
  adaptation.)
- **Apple Silicon quirk.** The reference implementations use `FLT_TRUE_MIN` as the
  gesture progress; that subnormal float is flushed to zero (sign lost) somewhere in
  the event pipeline on macOS 26/arm64, making every switch go the same direction.
  This port uses `1e-4`, which survives and is still visually zero.

Verified on **macOS 26 (Tahoe)**, Apple Silicon. The underlying technique is known to
work on macOS 14 and 15 as well.

## Uninstall

```sh
brew uninstall --cask noswoosh     # or: ./scripts/uninstall.sh, from source
```

This stops the daemon, removes the LaunchAgent, and restores both system settings that
`setup` changed. Remove the Accessibility entry manually if you like.

## Contributing

Issues and pull requests are welcome. The whole tool is one ~250-line Swift file
([`noswoosh.swift`](noswoosh.swift)); build it with:

```sh
swiftc noswoosh.swift -O -o noswoosh \
    -F /System/Library/PrivateFrameworks -framework SkyLight
```

Releases are cut by bumping `noswooshVersion` and pushing a matching `vX.Y.Z` tag;
CI builds, signs and publishes the app and updates the Homebrew cask.

## Credits

- Gesture technique: [jurplel/InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher)
  (the `±FLT_TRUE_MIN` progress trick and three-phase gesture) and
  [gechr/WhichSpace](https://github.com/gechr/WhichSpace).
- Force-front technique: [koekeishiya/yabai](https://github.com/koekeishiya/yabai).

## License

MIT — see [LICENSE](LICENSE).
