# What must not break

This file is the regression charter: the behaviours worth re-checking after any
structural change. It exists because almost everything here fails *silently* —
a broken yank guard, a dropped event tag, a gate that stops firing all look
exactly like "works fine" until someone hits the case.

The rule of thumb for this codebase: **a test that only shows zero failures is
not enough.** For anything guard-shaped, also prove the guard still fires. A
guard you accidentally disabled also scores zero.

Recipes for the fiddly setups are in `AGENTS.md`.

## 1. Switching, the core

| # | Behaviour | How it is checked |
| --- | --- | --- |
| 1.1 | Ctrl+← / Ctrl+→ move exactly one space | walk all spaces in both directions, read back from `SLSCopyManagedDisplaySpaces` |
| 1.2 | Clamped at both ends — no rubber-band | keep pressing past the last space; position must not change |
| 1.3 | Rapid presses accumulate | 4 presses at 150 ms land exactly 4 spaces over (this is what `predictionWindow` exists for — 0.4 s on 27, 0.25 s before) |
| 1.4 | Full-screen spaces are traversed like any other | a full-screen app's space sits in the list and must be walked through, not skipped |
| 1.5 | The switch is instant | no visible slide; the whole point of the project |
| 1.6 | `noswoosh left/right/list` work as a CLI | with the daemon running *and* not running |
| 1.7 | A running daemon must not eat the CLI's own events | issue #8 — the events carry `eventSourceUserData == 'NSWS'` and the tap passes them straight back out |

## 2. The macOS 27 gesture path

Everything here is `needsAugmentation`-gated and reverse-engineered; treat any
change as breaking until measured on a 27 box.

| # | Behaviour |
| --- | --- |
| 2.1 | Dock swipes carry the serialized IOHID payload in field 4205, or 27's Dock silently ignores them |
| 2.2 | Each DockControl event is posted paired with a companion gesture event |
| 2.3 | The `eventSourceUserData` tag is applied **after** `augment()` — the serialize/deserialize round-trip drops it, and that was #8 |
| 2.4 | Progress is near-zero but never 0 and never `FLT_TRUE_MIN` (flushes to zero on Apple Silicon, losing the sign) |
| 2.5 | The read and write sides use **opposite** sign conventions on 27. Do not "tidy" them into agreement |
| 2.6 | `postedSwipeSign` mirrors the posted sign when Natural scrolling is off — 27 path only |
| 2.7 | A begin/changed/ended sequence always completes; a partial one strands the Dock mid-gesture on a blank space |

## 3. Trackpad swipe interception

| # | Behaviour |
| --- | --- |
| 3.1 | A real 3-finger horizontal swipe switches one space, instantly |
| 3.2 | Direction is read from progress (`.changed`) or velocity (`.ended`) — `isRightSwipe` is positive-is-right on both OSes |
| 3.3 | Vertical swipes (Mission Control, App Exposé) pass through untouched |
| 3.4 | On 27 the real terminal event is let through with its fields zeroed, so the Dock can close its own gesture state |
| 3.5 | The tap re-enables itself after `tapDisabledByTimeout` / `ByUserInput`, and the 5 s backstop catches a disable that arrives without a callback |
| 3.6 | Neither self-heal path resurrects a tap the user switched off in Settings |

Not automatable here — no way to synthesise a trackpad gesture that the tap
reads as real. Verified by hand, or by proving the tap's enabled state.

## 4. The empty-desktop yank guard

The most fragile thing in the project. Broken twice: once by a version gate
(#15), once by our own settings window.

| # | Behaviour |
| --- | --- |
| 4.1 | Landing on a desktop with no ordinary windows does **not** bounce you elsewhere ~400 ms later |
| 4.2 | The guard genuinely fires — the frontmost app becomes `noswoosh` within ~20 ms of landing. **Check this separately every time** |
| 4.3 | It runs on every macOS version. It is not version-gated any more |
| 4.4 | The daemon must be `.accessory`, never `.prohibited` — a prohibited app cannot become active and the guard dies silently |
| 4.5 | It fires on landing, never before — the switch re-activates macOS's pick at landing and wipes an early claim out |
| 4.6 | `spaceHasWindows` ignores our own pid. A window of ours on every space would otherwise make every desktop look occupied and switch the guard off everywhere |
| 4.7 | The settings window never sits on a non-visible space — it joins all spaces and floats. Activating us must not order a window in from somewhere else |

Do **not** "fix" this by activating Finder instead (yanks 6/6, to Finder's own
window's space) or by parking a window on the destination (emptiness is the
trigger, not the cause).

## 5. Multi-display

| # | Behaviour |
| --- | --- |
| 5.1 | The switch targets the display under the **mouse cursor**, not keyboard focus — this is what native Ctrl+arrow does too |
| 5.2 | Clamping is evaluated against the cursor display's own space list (#3) |
| 5.3 | A prediction made on one display is never applied to another's list |
| 5.4 | Works with "Displays have separate Spaces" both on and off |

## 6. Setup, login item, migration

| # | Behaviour |
| --- | --- |
| 6.1 | Symbolic hotkeys 79/81 are disabled live via SkyLight **and** persisted for future logins — `defaults` alone does not affect the running session |
| 6.2 | The system shortcut is only claimed while our own hotkey is on; turning ours off hands the combo back rather than leaving it dead |
| 6.3 | On-launch setup is idempotent — it runs on every single launch |
| 6.4 | `workspaces-auto-swoosh` is left at the macOS default; a legacy override is cleared, and the Dock restarted only if one was actually removed |
| 6.5 | The login item registers **once** and is remembered, so a launch never re-enables one the user switched off in System Settings |
| 6.6 | `NOSWOOSH_SKIP_LOGIN_ITEM=1` keeps scratch builds out of the login items list |
| 6.7 | Migration deletes the cask-era plist only when its `ProgramArguments` point into a `noswoosh.app` — `install.sh` writes the same label pointing at `~/.local/bin` and that one is not ours to remove |
| 6.8 | launchd started us from the old plist → keep running under the job (bootout would SIGKILL us), plist already gone so the job dies at next login |
| 6.9 | The job is someone else's process → boot it out, killing the second daemon |
| 6.10 | A stale re-bootstrap under a live login item → the launchd copy yields via bootout, not `exit()`, so KeepAlive cannot resurrect it |
| 6.11 | **Never two daemons in a steady state**, in any of those orders |
| 6.12 | Quit boots the legacy job out when we are running under it, or KeepAlive resurrects us |
| 6.13 | A bare binary (no `.app`) skips login item and migration entirely and keeps the hand-written LaunchAgent flow |

## 7. Accessibility

| # | Behaviour |
| --- | --- |
| 7.1 | Untrusted: the status item is forced visible even with "Hide menu bar icon" on — otherwise there is no route to the grant flow |
| 7.2 | Untrusted: the icon carries the `!` badge, and it stays a **template** image so it tints and inverts like any status item |
| 7.3 | Untrusted: the menu gains `Grant Accessibility…`; trusted, it is gone |
| 7.4 | Untrusted: Settings opens by itself at launch, CTA on top, every other control disabled |
| 7.5 | Trusted: no badge, no grant item, no CTA, no auto-open |
| 7.6 | Granting relaunches the daemon (trust is cached per-process, so a live grant cannot take effect) and the open window is carried across |
| 7.7 | The relaunch route differs by how we were started: KeepAlive restarts us; a login-item launch re-`open -n`s the bundle; a hand-run bare binary can only be told |
| 7.8 | Without the permission the event tap cannot be created — the daemon says so rather than failing mute |

Test the untrusted side with a **separate bundle id**. Do not `tccutil reset`
the real one: re-granting needs GUI interaction that cannot be automated, so a
reset can leave the machine with no way back.

## 8. Settings window

| # | Behaviour |
| --- | --- |
| 8.1 | Every toggle takes effect live, with no restart |
| 8.2 | Every toggle persists across a relaunch |
| 8.3 | Preferences are absent until touched — a fresh install must come up with both inputs on, not off |
| 8.4 | "Hide menu bar icon" is recoverable: relaunching from Finder reaches the running instance as a reopen and surfaces Settings |
| 8.5 | Turning the login item off does not get silently re-enabled on the next launch |
| 8.6 | The window is fixed-size, floats, and joins all spaces (see 4.7) |
| 8.7 | Rows and their trailing items line up on one column |
| 8.8 | Nothing AppKit is constructed before `NSApplication.shared` exists |

## 9. Packaging

| # | Behaviour |
| --- | --- |
| 9.1 | `make-app-bundle.sh` builds, assembles, and optionally signs |
| 9.2 | The version in the source, the tag, and `Info.plist` all agree — CI fails the release if they don't |
| 9.3 | The menu bar icon ships at 1x and 2x, both declaring the same **point** size |
| 9.4 | `LSUIElement` is set; no Dock icon, no Cmd-Tab entry |
| 9.5 | A Developer ID signature preserves the Accessibility grant across upgrades |
| 9.6 | `install.sh` (bare-binary flow) still builds and installs |

## Traps

- **Never `cp` over a running binary.** `cp` rewrites the inode in place and the
  kernel keeps page hashes that no longer match. Move the old bundle aside and
  `ditto` the new one in.
- **A running app keeps serving its old inode.** Replacing the bundle under a
  live daemon leaves it on the orphaned inode, so it keeps running the
  *previous* build — and `open` will just activate it rather than launching the
  new one. Kill first.
- **Launching from a terminal inherits the terminal's Accessibility trust**, so
  a bundled app run that way looks trusted when it would not be in production.
  Launch through LaunchServices to test the real thing.
- **`mru-spaces` is on by default** and reorders the space list underneath a
  running test, silently turning one transition into a different one. Address
  spaces by `id64`, not by position, or pin the order for the duration.
- **Landing on an empty space is what the yank needs.** Assert the destination
  is actually empty in the test itself; a test whose destination quietly gained
  a window proves nothing.
