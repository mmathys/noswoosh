import Cocoa
import ServiceManagement

// MARK: - Login item (SMAppService), and the LaunchAgent era it replaces

// The bundle we run from, or nil for a bare binary (scripts/install.sh installs
// one). Bare installs keep the hand-written LaunchAgent flow; everything login-
// item- and migration-related is bundle-only.
let appBundleURL: URL? =
    Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil

// The label both the cask's postflight and install.sh bootstrap(ped) their
// LaunchAgent under. The cask era is over (#13); install.sh still uses it.
let legacyAgentLabel = "ax.max.noswoosh"
let legacyAgentPlistPath =
    ("~/Library/LaunchAgents/\(legacyAgentLabel).plist" as NSString).expandingTildeInPath

// Register the login item once, not on every launch: the user can switch it off
// in System Settings > General > Login Items, and re-registering would silently
// re-enable it — fighting a choice the user already made. The flag lives in our
// own defaults domain, so upgrades keep it and `teardown` (below) resets it.
let loginItemRegisteredKey = "loginItemRegistered"

// Set just before we exit to pick up a fresh Accessibility grant, and consumed by
// the process that replaces us. Without it the window the user was just looking
// at vanishes at the moment they finish granting, which reads as a crash.
let showSettingsAfterGrantKey = "showSettingsAfterGrant"

// teardown's other half of the registration: unregister, and forget we ever
// registered so a later `setup`/first launch registers again.
func unregisterLoginItem() {
    UserDefaults.standard.removeObject(forKey: loginItemRegisteredKey)
    guard appBundleURL != nil, #available(macOS 13.0, *) else { return }
    try? SMAppService.mainApp.unregister()
}

func loginItemIsEnabled() -> Bool {
    guard appBundleURL != nil, #available(macOS 13.0, *) else { return false }
    return SMAppService.mainApp.status == .enabled
}

func setLoginItemEnabled(_ on: Bool) {
    guard appBundleURL != nil, #available(macOS 13.0, *) else { return }
    do {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        // Set the flag either way, including on an explicit *off*. The flag means
        // "our one-time registration has happened", not "the login item is on" —
        // clearing it here would make the next launch's registerLoginItem() turn
        // the login item straight back on, fighting the switch the user just
        // flipped. `teardown` still clears it, which is what makes a later setup
        // register again.
        UserDefaults.standard.set(true, forKey: loginItemRegisteredKey)
    } catch {
        log("could not \(on ? "register" : "unregister") login item: \(error.localizedDescription)")
    }
}

// Hiding the status item leaves no way back in, so the reopen handler below is
// what makes this setting safe to offer: launching the app again from Finder

// MARK: - Setup on launch (#13)

// Whether launchd started *this* process from the cask-era plist, which changes
// how we may exit: a plain exit() under that job's KeepAlive is resurrected.
// Assigned once, by main, from migrateFromLaunchAgentEra().
var launchedByLegacyAgent = false

func registerLoginItem() {
    guard appBundleURL != nil else { return }   // bare binaries have no identity to register
    guard #available(macOS 13.0, *) else { return }
    // Escape hatch for development: a scratch build that registers itself would
    // point the login item at the scratch bundle.
    if ProcessInfo.processInfo.environment["NOSWOOSH_SKIP_LOGIN_ITEM"] == "1" { return }
    guard !UserDefaults.standard.bool(forKey: loginItemRegisteredKey) else { return }
    let service = SMAppService.mainApp
    if service.status == .enabled {   // registered out-of-band (or the flag was wiped)
        UserDefaults.standard.set(true, forKey: loginItemRegisteredKey)
        return
    }
    do {
        try service.register()
        UserDefaults.standard.set(true, forKey: loginItemRegisteredKey)
        log("registered as a login item")
        if service.status == .requiresApproval {
            log("login item needs approval: System Settings > General > Login Items & Extensions")
        }
    } catch {
        // Flag deliberately not set: retry on the next launch.
        log("could not register login item: \(error.localizedDescription)")
    }
}

// The upgrade path from the LaunchAgent era. Anyone installed before this has
// ~/Library/LaunchAgents/ax.max.noswoosh.plist written by the cask's postflight,
// pointing at the app bundle. Now that the app registers with SMAppService,
// launch must boot that job out and delete the plist — otherwise launchd and
// SMAppService each start a copy, two daemons race the same hotkeys and event
// tap, and `teardown` only knows about one of them. It survives the reverse
// order too (a stale `brew reinstall` dropping the old plist back after the
// login item is live) and is idempotent, since it runs on every launch.
//
// Returns whether *this process* is the legacy job's own — i.e. launchd started
// us from the old plist, and a bootout of the label would SIGKILL us. That case
// keeps running under the job for the rest of the session: the plist is already
// gone so the job dies at next login, and its KeepAlive is even useful (the
// Accessibility-grant restart below relies on it). Quit and the grant-restart
// both check this flag, because a plain exit() under KeepAlive gets resurrected.
func migrateFromLaunchAgentEra() -> Bool {
    guard appBundleURL != nil else { return false }

    // The plist — but only if it is the cask era's (ProgramArguments points into
    // a noswoosh.app). install.sh writes the same label pointing at ~/.local/bin;
    // that one belongs to the source-install flow and is not ours to remove.
    if let data = FileManager.default.contents(atPath: legacyAgentPlistPath),
       let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
       let program = ((plist as? [String: Any])?["ProgramArguments"] as? [String])?.first,
       program.contains("noswoosh.app/Contents/MacOS/noswoosh") {
        try? FileManager.default.removeItem(atPath: legacyAgentPlistPath)
        log("removed the LaunchAgent-era plist (the login item starts us now)")
    }

    // The loaded job, which outlives its plist until bootout or logout. Same
    // cask-era check, this time against launchd's own record of the program.
    guard let job = runToolOutput("/bin/launchctl", ["print", "gui/\(getuid())/\(legacyAgentLabel)"]),
          job.contains("noswoosh.app/Contents/MacOS/noswoosh") else { return false }
    let jobPID = job.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix("pid = ") }
        .flatMap { Int32($0.dropFirst("pid = ".count)) }

    if jobPID != getpid() {
        // The job is someone else's process (or idle). Booting it out kills any
        // second daemon and removes the job for this session in one move.
        _ = runTool("/bin/launchctl", ["bootout", "gui/\(getuid())/\(legacyAgentLabel)"])
        log("booted out the LaunchAgent-era job")
        return false
    }

    // launchd started us from the old plist. If another instance of the bundle
    // is already running (a stale reinstall re-bootstrapped the plist while the
    // login-item copy was up), yield to it — via bootout, not exit(), so
    // KeepAlive cannot resurrect us and the job is gone for the session.
    let bundleID = Bundle.main.bundleIdentifier ?? ""
    if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .contains(where: { $0.processIdentifier != getpid() }) {
        log("another noswoosh is already running — removing the LaunchAgent-era job (exits)")
        _ = runTool("/bin/launchctl", ["bootout", "gui/\(getuid())/\(legacyAgentLabel)"])
        exit(0)   // bootout normally kills us first; this covers it failing
    }
    log("running under the LaunchAgent-era job until next login (its plist is removed)")
    return true
}
