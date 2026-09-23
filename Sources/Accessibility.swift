import Cocoa
import ApplicationServices

// MARK: - Accessibility permission

// The one place that knows how to send someone to the Accessibility pane. The
// system's own prompt offers the same button, but it only appears once per
// process and people dismiss it.
func openAccessibilitySettings() {
    let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
}

// Accessibility trust is evaluated when the process starts and cached for its
// lifetime, so a grant made while we are running does not take effect. Rather
// than making the user restart the daemon by hand, poll and exit once trusted.
// How we come back depends on how we were started: a LaunchAgent's KeepAlive
// restarts us by itself; a login-item launch has no KeepAlive, so relaunch the
// bundle with `open -n` (LaunchServices makes the new instance its own
// TCC-responsible process, and it outlives us where a child would not); a bare
// binary run by hand we can only ask.
func installAccessibilityGrantWatcher() {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    guard !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else { return }
    log("waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)")
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        guard AXIsProcessTrusted() else { return }
        // Carry the open window across the relaunch.
        if settingsWindow.isOpen {
            UserDefaults.standard.set(true, forKey: showSettingsAfterGrantKey)
        }
        if launchedByLegacyAgent || (appBundleURL == nil && getppid() == 1) {
            log("Accessibility granted — restarting to apply it")
        } else if let bundle = appBundleURL {
            log("Accessibility granted — relaunching to apply it")
            _ = runTool("/usr/bin/open", ["-n", bundle.path])
        } else {
            log("Accessibility granted — restart noswoosh to apply it")
        }
        exit(0)
    }
    // Versions before the settings window opened the Accessibility pane by itself
    // after 15s, because a background agent with no UI had no other way to say
    // anything. There is a window with a Grant button now, and opening System
    // Settings over whatever the user is doing is rude once they have been asked
    // properly — so that timer is gone rather than duplicated.
}
