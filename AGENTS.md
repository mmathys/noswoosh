# Working on noswoosh

One Swift file (`noswoosh.swift`), a bundle script, and a release workflow. Read the
source comments first — they explain the technique. This file covers only what the
code can't tell you.

## Shape

Two input sources — the Ctrl+arrow hotkey and an event tap that intercepts real
3-finger swipes — both call one `switchSpace(right:)` core. The core has two posting
paths chosen by `needsAugmentation` (runtime `kern.osproductversion >= 27`): the
lightweight pre-27 path (verified on macOS 26), and the macOS 27+ path that attaches a
serialized IOHID payload. Keep new work behind that gate so a change to one OS can't
regress the other. Verified on macOS 26 and 27 only — don't claim older releases the
pre-27 path *should* handle but nobody has tested.

## Build and release

```sh
swiftc noswoosh.swift -O -o noswoosh -F /System/Library/PrivateFrameworks -framework SkyLight
./scripts/make-app-bundle.sh --out build     # assembles noswoosh.app
```

Releasing is a tag push: bump `noswooshVersion` in `noswoosh.swift`, then
`git tag vX.Y.Z && git push origin vX.Y.Z`. CI builds, signs, notarizes, staples,
publishes, and bumps the cask in `mmathys/homebrew-tap`. The workflow header lists the
secrets; each group degrades to a skip when absent. Only edit the tap by hand if the
bump step reported a skip or a warning.

The tap release is fully automatic: the tag push triggers CI, which opens/merges the
cask bump in `mmathys/homebrew-tap` — never clone or push that repo by hand.

## Traps

**Don't tidy the private-API constants.** The numeric `CGEventField`s and the gesture
progress values are load-bearing and hard-won. `FLT_TRUE_MIN` — what the reference
implementations use — is flushed to zero on Apple Silicon and breaks direction. The
pre-27 path uses `1e-4`. The 27 path has gone back and forth: `±1.0` through 1.7.0
(reported to slide by eye on 27.0), `1e-4` from 1.7.1 to 1.7.6, `±0.1` on every phase
in 1.7.7, and since 1.7.8 `1e-4` on `.began`/`.changed` with `±0.1` on `.ended` only.

The two halves do different jobs, and that split is the whole design:

- **`.ended` decides whether it lands drawn.** On 27.0.1 near-zero progress **lands
  black**: WindowServer sometimes never composites the destination space, and it stays
  black through later switches until Mission Control redraws it. That was 8–13 of every
  20 switches at `1e-4`, 3/20 still at 0.02, and 0 in over 100 at 0.03–1.0. On 27.0 the
  same race blanks just the menu bar (#9). The ±9999 fling on `.ended` finishes the
  transition in one frame whatever the magnitude, so magnitude doesn't decide whether
  the switch animates, only whether it lands drawn.
- **`.began`/`.changed` decide whether you see a jiggle.** Whatever progress they carry,
  the Dock draws for one frame before the fling: at `0.1` that is the old space slid 10%
  toward the new one, then snapped home. That was 1.7.7's visible jiggle (1 in-between
  frame per switch; 0 at `1e-4`).

1.7.8 measured 0 in-between frames and 0 black in 70 switches on 27.2.1, and the menu
bar drew every time. But 27.2.1 never landed black or lost the menu bar even at `1e-4`
on every phase, so the black-screen half is **unproven on 27.0.x**. If black comes back
there, raise only the `.ended` value; raising `.began`/`.changed` brings the jiggle back.
Don't use `0` on any phase: `fixed1616` serializes it as 0 in the IOHID payload. The
measured tables are at `makeAugmentedDockEvent`; how to measure is under "Measuring a
switch" below.

**The macOS 27 IOHID payload is byte-exact.** `generateIOHIDPayload` writes packed
little-endian structs (28/40/28-byte records) whose sizes and field offsets the Dock
validates. One wrong offset and 27 silently drops the swipe — no error, just no switch.
Don't "clean up" the manual byte writes into Swift structs; Swift doesn't guarantee C
packing. If you touch it, re-verify on a real 27 (see VM testing below), not just a
compile.

**The passthrough counter couples the core and the tap.** Every synthetic event the
core posts re-enters our own event tap. The core bumps `passthrough` by exactly the
number of events it posts (1 per bare event, 2 per augmented pair); the tap decrements
and passes those through instead of re-intercepting. If you change how many events a
post emits, update the bump in lockstep or the tap will eat its own output or act on it
twice.

**On macOS 27 the read and write sides use opposite sign conventions, on purpose.**
`makeAugmentedDockEvent` must *post* negative-for-right on 27 (positive posts move left —
confirmed in a 27.0 VM by forcing each sign), while `isRightSwipe` *reads* a real
gesture, and real trackpad swipes carry positive-for-right on 26 and 27 alike. So only
the writer branches on `needsAugmentation`; the reader is unconditional. Flipping the
reader too inverts every trackpad swipe on 27 while Ctrl+arrow keeps working, because the
hotkey path never reads a real gesture — that was the 1.7.2 bug fixed in #7. If direction
is backwards on one OS but right on the other, check which *side* you changed, not the
field constants.

**The daemon must be `.accessory`, not `.prohibited`.** The yank guard works by
taking activation the moment we land on a space with no windows. A `.prohibited` app
cannot become active at all, so "tidying" the policy back silently reintroduces the
empty-desktop yank with no error and no log line. Neither policy shows a Dock icon or
a Cmd-Tab entry, so the change is invisible until you test on an empty desktop. The guard
runs on every version since 1.7.6 — `NOSWOOSH_FORCE_YANK_GUARD=0` turns it off if you need
the broken side for comparison.

**The yank guard has to fire on landing, not before.** Taking activation ahead of the
switch does nothing — the switch re-activates macOS's own pick when it commits. And
parking a real window on the destination space doesn't help either; emptiness is what
triggers the hunt, but the yank comes from the *other* app's window ordering. Both
were measured; see the README section.

**Never `cp` over the running binary.** `cp` rewrites the destination inode in place.
Do that to a running, signed binary and the kernel keeps page hashes that no longer
match it, then SIGKILLs every subsequent exec of that inode — new processes included.
The symptom is maddening: `codesign -v --strict` passes, the hash matches the build
byte for byte, the same bytes run fine from another path, and launchd just reports
`-9`. `scripts/install.sh` boots the agent out and `rm -f`s the target first; keep it
that way, and reach for `rm`-then-copy (or a temp file plus `mv`) anywhere else.

**Accessibility trust is cached for a process's lifetime.** That is the entire reason
the daemon polls `AXIsProcessTrusted()` and exits once granted, letting launchd's
`KeepAlive` restart it. It looks like a redundant loop; it isn't. Removing it brings
back a manual `launchctl kickstart` step for every user.

**Testing permission logic from a terminal lies to you.** TCC attributes a
terminal-launched binary's request to the terminal, so it reports *trusted* even when
the shipped app would not be. To exercise the untrusted path, force the branch in a
scratch build rather than trusting a green run.

**`setup`/`teardown` change system settings and restart the Dock.** If you toggle them
while testing, restore the user's original state before you finish.

**Space switching follows the cursor, not keyboard focus.** The Dock routes a Dock-swipe
to the display under the mouse pointer, and native Ctrl+arrow routes the same way —
hovering a second display, with no click and no focus change, makes it the target.
`SLSGetActiveSpace` and `SLSCopyActiveMenuBarDisplayIdentifier` track keyboard focus
instead, so they are the wrong input for anything that must agree with where a swipe will
land; using them for the boundary clamp was issue #3. The swipe cannot be *steered*
either: the 27 path carries `fieldSwipePositionX/Y`, but the pre-27 path has no position
field, so only the clamp can be made to follow. When testing multi-display, pin the cursor
explicitly with `CGWarpMouseCursorPosition` — otherwise results depend on wherever you
happened to leave it. Only relevant with "Displays have separate Spaces" on; with it off
every screen shares one space list.

**Nothing secret belongs in this repo.** Signing material lives in
`~/.config/noswoosh-signing/` and in CI secrets. The `.p12` must be exported with
legacy PBE flags (`-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1`) or
macOS `security import` rejects it.

## Checking your work

`noswoosh list` prints `space N of M` and is the cheapest confirmation that the private
API reads still work. Real verification needs several spaces — a change can compile,
run, and still switch the wrong way, or not at all.

**"Automatically rearrange Spaces based on most recent use" will misdirect your
tests.** It's in System Settings > Desktop & Dock, it's on by default, and it reorders
spaces as you use them — so a space's *index* is not stable between two runs a few
seconds apart. Navigate and assert by space **id** (`id64` from
`SLSCopyManagedDisplaySpaces`), re-reading the order before each run; a harness that
walks "two to the right" can land somewhere else entirely and you'll score a working
build as broken, or a broken one as fixed. Turning the setting off while testing works
too, but then you're not testing the configuration most users actually run. (Users hit
the same thing as "spaces switch in an unexpected order" — see the README.)

Test both OS paths. The catch: whichever machine you're on only runs one path natively.
Use `NOSWOOSH_FORCE_AUGMENT=1` / `=0` to force the 27 / pre-27 path regardless of OS for
a smoke test, but the payload is only *validated* by the real OS — a forced path can
post without switching. So confirm the 27 path on an actual macOS 27.

### Measuring a switch

"It switched" is true of a perfect switch, a switch that jiggled, and a switch that
landed on a black screen. Every progress-value bug this repo has had passed that check.
Measure what the eye sees instead, with three probes:

| probe | what it catches | how |
| --- | --- | --- |
| `scripts/landing-check.swift`, "slide frames" | a jiggle or slide | Films at 60fps. Compares every frame to "before" (old space) and "after" (new space). A frame matching neither is an in-between frame. A perfect cut has 0, 1.7.7's jiggle has 1, native has ~27. |
| `scripts/landing-check.swift`, `BLACK` | the destination never drawn (#15) | Mean brightness of the settled frame < 8. |
| `scripts/menubar-check.swift` | the menu bar never drawn (#9) | Photographs the top strip after each switch. Two wallpapers give two steady alternating values; a blank menu bar drops sharply. |

A one-frame jiggle is 1/60s: you can feel it but you can't judge it by eye, and you
can't tell 0 frames from 1 by watching. Hence the camera.

How to run a comparison, which is how 1.7.8 was found:

- **Test a build without installing it.** `LANDING_BIN=/path/to/build landing-check RL
  1100 5` drives the binary directly, and `menubar-check` always does. No daemon is
  needed. The terminal (or editor) running them needs both **Accessibility** and
  **Screen Recording**, and must be restarted after Screen Recording is granted. Without
  Accessibility the switches are silently dropped and every variant looks like "no
  visible change".
- **Compare several variants side by side, not one against your memory.** For 1.7.8 a
  scratch build read the progress values from environment variables, and five variants
  ran back to back on the same desktop: the shipped value, a smaller one, a missing
  `.changed`, near-zero everywhere, and the split. Only a side-by-side run separates
  "this value is better" from "the desktop changed between runs". Keep that scaffolding
  in a scratch copy, not in the shipped source.
- **Repeat until intermittent failures would have shown up.** The black landing hit 3 of
  20 switches at some values, so 10 clean switches proves little. Run the winner at 40+,
  and include a rapid run (~450ms apart) too, since the prediction window and Dock state
  behave differently under back-to-back switches.
- **Check that the machine can fail before trusting a pass.** A test that cannot fail
  proves nothing. 27.2.1 never lands black or loses the menu bar, even at `1e-4` on
  every phase, so a clean run there says nothing about 27.0.x — like testing an umbrella
  indoors. Always run the known-bad variant alongside the candidate. If the known-bad
  one also passes, say in the commit and PR that the result is unproven on the OS where
  the bug lived. This is the same lesson as the yank-guard retraction below: "I could
  not make it fail" is only evidence if the setup could have failed.

### Testing on a macOS 27 VM

The pre-27 path you can verify on a 26 host. For 27, a VM is the cheap loop (Apple's
Virtualization framework boots a 27 guest on a 26 host):

```sh
brew install cirruslabs/cli/tart        # needs: brew trust cirruslabs/cli
tart clone ghcr.io/cirruslabs/macos-golden-gate-vanilla:27.0 noswoosh-27   # ~30 GB
tart set noswoosh-27 --display 1280x800 --display-refit
tart run noswoosh-27 &                   # login is admin / admin; caffeinate -w <pid>
```

The guest has **no swiftc** (Command Line Tools are a stub), so build on the host and
copy the app in. Sign it with the same Developer ID as the installed app — TCC keys the
Accessibility grant to the code signature, not notarization or path, so a matching
signature reuses a grant already made in the VM:

```sh
./scripts/make-app-bundle.sh --binary /path/to/host-build --out /tmp/nsw \
    --sign "Developer ID Application: ... (TEAMID)"
ditto -c -k --keepParent /tmp/nsw/noswoosh.app /tmp/nsw.zip
scp /tmp/nsw.zip admin@$(tart ip noswoosh-27):                # ssh key via admin/admin
# in the VM: ditto -x -k nsw.zip ~/ ; then (re)bootstrap the LaunchAgent
```

Two traps that will waste your time:

- **Granting Accessibility.** The clean way is injecting a `kTCCServiceAccessibility`
  row into the system `TCC.db`, but SIP (on in the stock image) makes that DB read-only
  even to root. Either tick the checkbox once in the VM's System Settings window, or
  `tart run --recovery` + `csrutil disable` for a fully scriptable image. There is no
  in-between: a manual `.mobileconfig` doesn't grant Accessibility without MDM.
- **Don't drive the switch from a bare SSH/sudo process.** Event-posting trust is
  attributed to the *responsible* process; over SSH that's sshd, not noswoosh, so
  gestures are silently dropped and you'll misread a working build as broken. Launch via
  `launchctl asuser 501 sudo -u admin open -n ~/noswoosh.app --args right` — `open`
  makes the app its own responsible process, so the grant applies. Read the result with
  `... noswoosh list` between switches.

The **swipe path can't be tested in the VM** — there's no trackpad, so no real swipe
events to intercept. Verify swipe on a host with a trackpad (any supported OS; it shares
the switch core), and leave the 27-swipe-specific glue (companion suppression, terminal-
event passthrough) for bare-metal 27.

### Verifying the yank guard on 27

The yank guard is **not** behind `needsAugmentation` — it posts no events, so it runs
identically on both OSes and gets none of the protection that gate normally gives you.
Its correctness depends on macOS behavior that 27 could change, and every failure mode
is silent: the yank simply comes back, with no error and no log line. Unlike swipe, it
*can* be tested in the VM (no trackpad needed) — but see the retraction below for why a
VM alone is not enough to conclude the guard is unnecessary.

Do these in order; the first is cheapest and invalidates the rest if it fails.

**1. Re-check the "one pref, both behaviors" premise.** The whole design rests on the
Dock's follow rule having exactly one entry point, gated on `workspaces-auto-swoosh`.
That was established by disassembling the 26.6 Dock; 27 already tightened Dock-swipe
validation once, so don't assume it carried over.

```sh
lipo -thin arm64e -output /tmp/dock27 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
otool -tV /tmp/dock27 > /tmp/dock27.asm
strings -a /tmp/dock27 | grep -c 'ordered on non-visible space'   # expect 1
```

Then resolve the `adrp`+`add` pair that references the `workspaces-auto-swoosh` literal
(string vmaddr = `0x100000000` + its file offset in the thinned slice) and confirm two
things still hold: the pref read is followed by a call to
`CGSSetWindowDidOrderInOnNonCurrentManagedSpacesOnlyNotificationBlock`, and the switcher
called at the end of that block still has exactly **one** caller — the block itself. If
it has two, the rule gained a second entry point and the premise is dead.

Baseline for comparison, macOS 26.6.2 (25G83), arm64e slice: pref read `0x1001e4afc`,
block install `0x1001e4b78`, callback body `0x1001e9754`, switcher `0x1001ed344` (one
caller, at `0x1001e9b10`). The notification payload carries `WindowID`,
`ManagedSpaceID`, `PSN.hi`/`PSN.lo`.

**2. Check `SLSCopySpacesForWindows` still reports truthfully.** It is the private half
of `spaceHasWindows()`, and if it changes shape the guard stops firing. Cheapest probe:
on a space you know has windows, confirm it returns that space id for those windows; on
a windowless one, confirm no window maps to it. Getting this wrong in the *other*
direction is worse than the yank — the guard would steal activation on every switch.

**3. Test the guard itself.** Arrange a windowless space in the guest, park on the space
next to it, then switch into it and see whether you stay:

```sh
launchctl asuser 501 sudo -u admin open -n ~/noswoosh.app --args right
sleep 1
launchctl asuser 501 sudo -u admin open -n ~/noswoosh.app --args list
```

Moved after the sleep means the guard failed. `open -n` is required for the same
responsible-process reason as everywhere else in this file. Read the Dock's own verdict
with `log stream --process Dock --info --debug` and grep for `non-visible space`; a hit
is the follow rule firing, which is exactly what the guard is supposed to prevent.

**4. Re-measure the race margin.** On 26.6 macOS activates its pick at ~300ms, we take
activation ~20ms later, and the yank would land ~700ms — roughly 380ms of headroom. It
is a race, not a guarantee. If 27 orders the window in sooner the margin narrows, and
that is worth knowing before it shows up as a flaky yank under load.

**Results, macOS 27.0 (26A5416b), tart VM, run 2026-08-25.**

- *Premise: holds.* `workspaces-auto-swoosh` read at `0x10017ad48`, `tbz` gate, one call
  to `CGSSetWindowDidOrderInOnNonCurrentManagedSpacesOnlyNotificationBlock` at
  `0x10017ae24` (the only one in the binary). Follow switcher `0x10018490c`, callers: 1.
  Same shape as 26.6. Note 27's Dock is arm64e-only, no fat slice to thin.
- *`SLSCopySpacesForWindows`: works.* Maps windows to spaces correctly, and the guard's
  negative case confirms it in both directions — landing on spaces with windows did
  **not** take activation, landing on the windowless one did.
- *Follow: works*, with the pref at default. 1.7.0's `setup` correctly cleared a legacy
  `workspaces-auto-swoosh = 0` left by an older build and restarted the Dock.
- *`.accessory` policy: works* — `NSApp.activate()` succeeds on 27.
- *The yank appeared not to happen on 27 — **this conclusion was wrong**, see the
  retraction below.* What was measured: landing on a windowless space activated
  **Finder**, which owns the desktop and so has no off-space window to order in, so the
  chain never started — no follow-rule log line, no yank, 4/4 rounds with no daemon
  running and a browser (Safari) parked on another space. 26.6 instead picks a real app
  with a window elsewhere and yanks you to it; traced on the host the same day at 20ms
  resolution: land on empty space at 64ms, yanked at 456ms, Dock logs
  `switching to space 121 for window(5ea9) ... ordered on non-visible space` (that
  window belonged to whichever ordinary app macOS happened to pick — Arc in one
  session, Tart in another).

**Retraction (2026-09-23, issue #15, macOS 27.0 26A428, bare metal).** 27 did *not* fix
this. It picks the most-recently-used app on a windowless landing exactly like 26 does;
the VM just happened to have an app layout where that pick was always Finder. One
browser parked on one other space is not a desktop, and the conclusion did not survive
contact with a real one. Two measurements, `mru-spaces` off so positions are stable, a
seven-space layout with four empty spaces:

| transition | guard off (shipped 1.7.5) | guard on |
| --- | --- | --- |
| full-screen space → empty space | 8/8 landed on the wrong space | 0/8 |
| ordinary space → empty space | 6/6 wrong | 0/8 |
| seven-transition sweep, ×4 each | 16/28 wrong | 0/28 |

Two things worth carrying forward. **Finder is not a safe app to activate.** Activating
Finder by hand on a windowless landing yanked 6/6 — to whichever space Finder's *own*
window was on. The only app guaranteed to have nothing to order in is a windowless one,
which is why the guard activates itself and not Finder. **And the displacement cost is
not real:** with the guard holding activation on an empty 27 desktop the menu bar still
reads "Finder", because we have no windows and no menu of our own — screenshotted on
27.0. That was the entire argument for gating the guard off, and it does not hold.

Generalisable lesson: this gate was turned off on the strength of a 4/4 run in a VM
whose window layout was a special case of the thing being measured. When a guard's
failure mode is silent, "I could not make it happen" is not evidence that it cannot.
Test on a machine with a real spread of apps across spaces, or don't change the gate.

Two traps that cost time here, both worth avoiding: `rm -rf`-ing the bundle while the
old daemon runs leaves that process on the orphaned inode, so it keeps serving the
*previous* build — check `lsof -p <pid> | awk '$4=="txt"'` against `stat -f %i` on disk
rather than trusting PID start times. And don't run `strings`/`otool` inside the guest:
Command Line Tools are a stub, so it silently returns nothing *and* pops an
"Install Command Line Developer Tools" dialog onto every space, which makes every space
non-empty and quietly invalidates the next yank test. Copy the binary to the host.
