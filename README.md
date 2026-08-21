# noswoosh

Instant, animation-free switching between macOS Spaces with **Ctrl+←/→** — no third-party apps, no SIP disabling, no global Reduce Motion. A single ~250-line Swift file you compile yourself.

*The name: "swoosh" is Apple's own word for the space-slide animation — from the long-dead Snow Leopard setting `workspaces-swoosh-animation-off`. This is that setting, resurrected.*

Verified on **macOS 26 (Tahoe)**, Apple Silicon. The technique it uses is known to work on macOS 14/15 as well.

## Why

macOS has no supported way to disable only the space-switch slide animation:

- The old `defaults write com.apple.dock workspaces-swoosh-animation-off` died with Lion (2011).
- **Reduce Motion** works but is global (and it's a crossfade, not an instant cut).
- Per-app accessibility settings (Reduce Motion for Dock only) exist on iOS, not macOS.
- yabai can do it, but only with SIP partially disabled.

This tool takes the approach used by [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher), [WhichSpace](https://github.com/gechr/WhichSpace), and BetterTouchTool: synthesize a Dock-swipe trackpad gesture with **near-zero progress and high velocity**. The switch runs through the Dock's own pipeline — so Mission Control, focus, wallpaper, and Dock state all stay consistent — but the animation has zero distance to travel, making it instant. No SIP changes, no admin rights; only an Accessibility permission to post events.

## Install

Requires Xcode Command Line Tools (`xcode-select --install`).

### Homebrew

```sh
brew install mmathys/tap/noswoosh
noswoosh-ctrl-arrows off          # disable the system's animated Ctrl+arrow shortcuts (live + persisted)
brew services start noswoosh      # start the daemon now and at every login
```

Then the one step that can't be scripted: **grant Accessibility permission** (macOS prompts on first start, or add `/opt/homebrew/opt/noswoosh/bin/noswoosh` under System Settings → Privacy & Security → Accessibility) and run `brew services restart noswoosh`. Re-show these instructions anytime with `brew info noswoosh`. Note: every `brew upgrade` changes the binary hash, so the Accessibility grant must be re-done after upgrades.

The formula lives in [mmathys/homebrew-tap](https://github.com/mmathys/homebrew-tap).

### From source

```sh
git clone https://github.com/mmathys/noswoosh.git
cd noswoosh
./install.sh
```

The installer:

1. Compiles `noswoosh.swift` and installs the binary + source to `~/.local/bin/`.
2. Disables the system's **animated** Ctrl+←/→ Mission Control shortcuts (symbolic hotkeys 79/81) — persisted in `com.apple.symbolichotkeys` and applied live so no logout is needed. Ctrl+Shift+arrows and all other shortcuts are untouched.
3. Installs and starts a LaunchAgent (`com.$USER.noswoosh`) so the daemon runs at every login. It logs to `~/Library/Logs/noswoosh.log`.

### Grant Accessibility (one manual step)

On first start the daemon requests Accessibility permission (macOS gates synthetic events behind it). Approve the prompt, or add it manually:

**System Settings → Privacy & Security → Accessibility → "+" → Cmd+Shift+G → `~/.local/bin/noswoosh`**

Then restart the daemon:

```sh
launchctl kickstart -k gui/$(id -u)/com.$USER.noswoosh
```

> **Important:** the permission is tied to the binary's code signature. **Every rebuild invalidates it.** If toggling the checkbox doesn't take, *remove* the entry ("−"), restart the daemon (which re-triggers the prompt), enable it, and restart the daemon once more. Check `~/Library/Logs/noswoosh.log` — a `waiting for Accessibility permission` line after a restart means it's still not trusted.

## Usage

- **Ctrl+→ / Ctrl+←** — switch one space right/left, instantly. Clamped at the first/last space (no rubber-band bounce).
- CLI (mostly for scripting/debugging):
  ```sh
  noswoosh list    # "space 2 of 4"
  noswoosh right   # switch once and exit
  noswoosh left
  noswoosh empty   # which spaces have no windows
  ```

## The empty-desktop yank (and why this tool prevents it)

While building this we found a macOS behavior you can reproduce with plain native switching: **switch to a desktop with no windows, and ~400 ms later macOS yanks you to a different desktop.** Chain of events (visible in the Dock's log):

1. Landing on a windowless space, WindowServer promotes the last-active app to front process.
2. That app (AppKit) re-orders its key window — which lives on another space.
3. The Dock's follow rule fires: `switching to space N for window ordered on non-visible space`, and you're yanked to wherever that window lives.

The daemon prevents this by keeping an invisible 1×1 window on every space and force-fronting *itself* (via `_SLPSSetFrontProcessWithOptions`, the same private call yabai uses — normal activation is denied to background processes by macOS 14+ cooperative activation) whenever it switches you onto a windowless space. It owns no other windows, so nothing gets re-ordered and nothing yanks you. This protection is why the tool runs as a daemon: it only holds while the process lives.

## Caveats

- **Private APIs.** `SLSCopyManagedDisplaySpaces`, `SLSCopySpacesForWindows`, `_SLPSSetFrontProcessWithOptions`, and the undocumented gesture `CGEventField`s are unsupported by Apple and can break in any macOS release. (Known: macOS 27 betas changed gesture-event serialization — see WhichSpace for the IOHID-payload adaptation.)
- **Apple Silicon quirk:** the reference implementations use `FLT_TRUE_MIN` as the gesture progress; that subnormal float gets flushed to zero (sign lost) somewhere in the event pipeline on macOS 26/arm64, making every switch go the same direction. This port uses `1e-4`, which survives and is still visually zero.
- Single-display use is what's tested. Multi-display setups may need the cursor-display targeting logic from InstantSpaceSwitcher.
- Turn off "Automatically rearrange Spaces based on most recent use" (System Settings → Desktop & Dock) if you want stable space ordering.

## Uninstall

```sh
./uninstall.sh
```

Removes the daemon, binary, and LaunchAgent, and re-enables the system's animated Ctrl+arrow shortcuts. Also remove the Accessibility entry manually if you like.

## Credits

- Gesture technique: [jurplel/InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) (the `±FLT_TRUE_MIN` progress trick and three-phase gesture) and [gechr/WhichSpace](https://github.com/gechr/WhichSpace).
- Force-front technique: [koekeishiya/yabai](https://github.com/koekeishiya/yabai).

## License

MIT — see [LICENSE](LICENSE).
