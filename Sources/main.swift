import Cocoa

// noswoosh — instant macOS space switching (verified on macOS 26 and 27, Apple Silicon).
//
//   noswoosh            daemon: Ctrl+Left/Right OR a 3-finger swipe switch
//                       spaces instantly (no animation)
//   noswoosh setup      one-time system config (see below), needs no sudo
//   noswoosh teardown   undo the system config
//   noswoosh left       switch one space left and exit
//   noswoosh right      switch one space right and exit
//   noswoosh list       print current space / count
//   noswoosh version    print version
//
// How it works: switching is a synthetic Dock-swipe gesture (technique from
// jurplel/InstantSpaceSwitcher, MIT) with near-zero progress and high velocity —
// it runs through the Dock's own pipeline (state stays consistent: the Dock is
// the sole authoritative owner of the Spaces model) but the animation has no
// distance to travel, so it is instant. Two input sources feed one switch core:
// a Ctrl+arrow hotkey, and an event tap that intercepts real 3-finger
// horizontal swipes and replaces them with the instant switch. Posting events
// requires Accessibility permission.
//
// Requires macOS 26.6+ on the 26 line: 26.0–26.5 has a WindowServer bug that
// drops the destination space's compositing surfaces on zero-travel switches
// (blank landings). No instant workaround exists from outside the Dock; the
// full investigation and every attempted mitigation are in GitHub issue #1.
//
// macOS 27 (Tahoe's successor) added validation: synthetic Dock swipes must
// carry a serialized raw IOHID queue payload in CGEvent field 4205, and each
// DockControl event must be paired with a companion gesture event. Without this
// the Dock silently ignores the event. The macOS 27 payload layout is
// reverse-engineered from joshuarli/iss (ISC). Everything 27-specific is gated
// behind `needsAugmentation`, so the verified macOS 26 path is untouched.
//
// `noswoosh setup` configures one thing: the system's animated Ctrl+arrow
// shortcuts (symbolic hotkeys 79/81) must be disabled or they consume the key
// combo first. Setup disables them live via SkyLight (defaults alone doesn't
// affect the running session) AND persists them in com.apple.symbolichotkeys
// for future logins. (For migration it also clears the legacy
// com.apple.dock workspaces-auto-swoosh override older versions set — see the
// yank guard and the setup case for why we no longer touch it.)
//
// Homebrew's install steps now run in a sandbox that denies mach-lookup, so the
// cask can no longer run setup or start anything at install time (#13). The
// daemon therefore sets itself up on every launch: it applies the system setup,
// registers itself as a login item (SMAppService), and migrates old installs
// off the cask-era LaunchAgent. Every step is idempotent.
//
// The source is split by concern under Sources/; this file is the only one with
// top-level code, and therefore the only place where declaration order is also
// execution order. Globals in every other file are initialised lazily on first
// use, which is what keeps the startup sequence below readable as a sequence
// rather than a set of ordering constraints.
//
// Build: swiftc Sources/*.swift -O -o noswoosh \
//          -F /System/Library/PrivateFrameworks -framework SkyLight
//
// What must not break when changing any of this: TESTING.md.

// MARK: - Entry point

// A CLI invocation never returns from here.
runCLIIfRequested()

// MARK: Daemon

// Setup runs on every launch, not at install time, and every step is idempotent
// — Homebrew's sandbox left us nowhere else to do it (#13). Order matters: the
// migration has to see the system in the state setup leaves it, and the login
// item must not be registered before we know whether an old LaunchAgent is
// still going to start a second copy of us.
applySystemSetup()
launchedByLegacyAgent = migrateFromLaunchAgentEra()
registerLoginItem()

// Before NSApplication exists, so the system's permission prompt is the first
// thing the user sees rather than something layered over our own window.
installAccessibilityGrantWatcher()

let app = NSApplication.shared
// .accessory, not .prohibited: no Dock icon and no Cmd-Tab entry either way, but
// a prohibited app cannot become active, which the yank guard depends on.
app.setActivationPolicy(.accessory)
app.delegate = appDelegate

installStatusItem()
refreshStatusItemForPermission()

if yankGuardNeeded {
    installYankGuard()
} else {
    log("empty-desktop yank guard off (forced by NOSWOOSH_FORCE_YANK_GUARD)")
}

installHotkeyHandler()
applyHotkey(hotkeyEnabled)
installSwipeTap()

// Open Settings unprompted in exactly two cases: we cannot work because the
// permission is missing, or we have just relaunched because it was granted. A
// Homebrew install cannot grant Accessibility for you (the install steps are
// sandboxed — #13), so for most people the first launch *is* the untrusted case
// and this window is the only thing that tells them so.
if !AXIsProcessTrusted() || UserDefaults.standard.bool(forKey: showSettingsAfterGrantKey) {
    UserDefaults.standard.removeObject(forKey: showSettingsAfterGrantKey)
    // After the run loop starts: activation needs it.
    DispatchQueue.main.async { settingsWindow.show() }
}

app.run()
