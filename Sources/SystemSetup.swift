import Foundation

// MARK: - System configuration (all user-level, no sudo)

// hotkey 79 = "move left a space" (ctrl+left, key code 123),
// hotkey 81 = "move right a space" (ctrl+right, key code 124)
func setCtrlArrowShortcuts(enabled: Bool) {
    // Live (WindowServer) state — resolved via dlsym; writing defaults alone
    // does not affect the running login session.
    typealias SetHotKeyFn = @convention(c) (Int32, Bool) -> Int32
    if let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
       let sym = dlsym(skylight, "SLSSetSymbolicHotKeyEnabled") {
        let setEnabled = unsafeBitCast(sym, to: SetHotKeyFn.self)
        _ = setEnabled(79, enabled)
        _ = setEnabled(81, enabled)
    }
    // Persisted state for future logins.
    for (hotKey, keyCode) in [(79, 123), (81, 124)] {
        let entry = "{enabled = \(enabled ? 1 : 0); value = { parameters = (65535, \(keyCode), 8650752); type = standard; };}"
        _ = runTool("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys",
                                          "AppleSymbolicHotKeys", "-dict-add",
                                          String(hotKey), entry])
    }
}

// The whole of `noswoosh setup`, shared with the daemon, which runs it on every
// launch (see the header) — so everything in here must stay idempotent.
func applySystemSetup() {
    // Only take the combo away from macOS while we actually answer it. With the
    // hotkey switched off in Settings, leaving the system shortcut disabled here
    // would make Ctrl+arrow do nothing at all — worse than either state.
    setCtrlArrowShortcuts(enabled: !hotkeyEnabled)
    // Versions 1.6.4 and earlier disabled the Dock's window-order space-follow
    // (workspaces-auto-swoosh) to suppress the empty-desktop yank. That also
    // killed Dock-icon-follow, because the Dock runs both off the same
    // notification. The daemon's yank guard handles the yank directly now, so
    // leave the pref at the macOS default. Clear an override a prior version
    // left — restarting the Dock only if we actually removed one, so a fresh
    // install gets no gratuitous restart.
    if runTool("/usr/bin/defaults", ["delete", "com.apple.dock", "workspaces-auto-swoosh"]) {
        _ = runTool("/usr/bin/killall", ["Dock"])
    }
}
