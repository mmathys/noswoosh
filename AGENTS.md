# Working on noswoosh

One Swift file (`noswoosh.swift`), a bundle script, and a release workflow. Read the
source comments first — they explain the technique. This file covers only what the
code can't tell you.

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

## Traps

**Don't tidy the private-API constants.** The numeric `CGEventField`s and the `1e-4`
gesture progress are load-bearing and hard-won. `FLT_TRUE_MIN` — what the reference
implementations use — is flushed to zero on Apple Silicon and breaks direction.

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
API reads still work. Real verification needs several spaces with distinguishable
windows — a change can compile, run, and still switch the wrong way.
