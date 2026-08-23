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
implementations use — is flushed to zero on Apple Silicon and breaks direction.

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
