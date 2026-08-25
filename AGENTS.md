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

**Don't tidy the private-API constants.** The numeric `CGEventField`s and the `1e-4`
gesture progress are load-bearing and hard-won. `FLT_TRUE_MIN` — what the reference
implementations use — is flushed to zero on Apple Silicon and breaks direction. Both
paths use `1e-4` as of 1.7.1: the 27 path shipped `±1.0` (full travel) through 1.7.0,
which switched correctly and so passed every functional test, but *visibly slid* —
instant switching is the whole point, and no assertion in this repo catches a switch
that works but animates. The ±9999 fling on `.ended` is what commits the 27 swipe, so
only the sign of progress matters; don't use `0`, which `fixed1616` serializes as 0 in
the IOHID payload. Verify by eye on a real 27, not just by checking that it switched.

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

**macOS 27 reverses swipe direction.** `isRightSwipe` and `makeAugmentedDockEvent` flip
the progress/velocity sign versus the pre-27 path. If direction is backwards on one OS
but right on the other, this is why — check the `needsAugmentation` branch, not the
field constants.

**The daemon must be `.accessory`, not `.prohibited`.** The yank guard works by
taking activation the moment we land on a space with no windows. A `.prohibited` app
cannot become active at all, so "tidying" the policy back silently reintroduces the
empty-desktop yank with no error and no log line. Neither policy shows a Dock icon or
a Cmd-Tab entry, so the change is invisible until you test on an empty desktop. Note the guard only
runs on macOS < 27 (`yankGuardNeeded`), so testing this on a 27 box proves nothing —
use `NOSWOOSH_FORCE_YANK_GUARD=1` there, or test on 26.

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
*can* be tested in the VM (no trackpad needed).

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
- *The yank does not happen on 27, and we know why.* **27 activates Finder** when you
  land on a windowless space. Finder owns the desktop and has no off-space window to
  order in, so the chain never starts — no follow-rule log line, no yank, 4/4 rounds
  with no daemon running and a browser (Safari) parked on another space. 26.6 instead
  picks a real app with a window elsewhere and yanks you to it; traced on the host the
  same day at 20ms resolution: land on empty space at 64ms, yanked at 456ms, Dock logs
  `switching to space 121 for window(5ea9) ... ordered on non-visible space` (that
  window belonged to whichever ordinary app macOS happened to pick — Arc in one
  session, Tart in another). Apple appears to have fixed this at the source in 27.
  The race margin is therefore unmeasurable on 27 — there is no race.

  **Consequence for the guard: on 27 it is unnecessary, and it displaces Finder.**
  Verified in the VM — with the 1.7.0 daemon running, landing on the windowless space
  makes *noswoosh* frontmost instead of Finder. Harmless in the sense that nothing
  yanks, but on an empty desktop 27 users would expect Finder to be active (desktop
  clicks, Finder menu bar, Cmd+N). **Fixed:** the guard is now gated on `macOSMajor < 27`
  via `yankGuardNeeded`, sharing one `kern.osproductversion` read with
  `needsAugmentation` so the two gates can't disagree. Override either way with
  `NOSWOOSH_FORCE_YANK_GUARD=0/1`. An unreadable version runs the guard — a needless
  activation is cheaper than the yank returning. The daemon logs one line when it skips
  the guard, so the OS decision isn't silent. Caveat: one VM, one build (26A5416b).

Two traps that cost time here, both worth avoiding: `rm -rf`-ing the bundle while the
old daemon runs leaves that process on the orphaned inode, so it keeps serving the
*previous* build — check `lsof -p <pid> | awk '$4=="txt"'` against `stat -f %i` on disk
rather than trusting PID start times. And don't run `strings`/`otool` inside the guest:
Command Line Tools are a stub, so it silently returns nothing *and* pops an
"Install Command Line Developer Tools" dialog onto every space, which makes every space
non-empty and quietly invalidates the next yank test. Copy the binary to the host.
