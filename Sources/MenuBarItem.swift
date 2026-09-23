import Cocoa

// MARK: - Menu bar item

// A status item gives the daemon somewhere to live that the user can see and
// quit from. Its image is a *template* — black pixels plus alpha — so macOS
// tints it for light and dark menu bars and inverts it while the menu is open.
// Shipped at 1x and 2x so the bar never resamples it.
var statusItem: NSStatusItem?

func menuBarImage() -> NSImage? {
    guard let dir = Bundle.main.resourcePath else { return nil }
    let image = NSImage(size: NSSize(width: 16, height: 18))
    for (file, scale) in [("menubar-icon.png", CGFloat(1)), ("menubar-icon@2x.png", CGFloat(2))] {
        guard let rep = NSImageRep(contentsOfFile: "\(dir)/\(file)") else { continue }
        // Point size, not pixel size: the 2x rep must claim the same 16x18 points.
        rep.size = NSSize(width: CGFloat(rep.pixelsWide) / scale,
                          height: CGFloat(rep.pixelsHigh) / scale)
        image.addRepresentation(rep)
    }
    guard !image.representations.isEmpty else { return nil }
    image.isTemplate = true
    return image
}

// The same icon with a warning badge bitten out of its bottom-right corner, for
// when we have no Accessibility permission and can therefore do nothing at all.
//
// Everything here is drawn in black-plus-alpha and the result stays a template,
// so the menu bar tints it like any other status item and it inverts correctly
// when the menu is open. That rules out a red badge — a non-template image would
// have to guess the menu bar's own colours — so the badge reads as a shape: a
// filled disc, separated from the head by a cleared ring, with the exclamation
// mark punched back out of it.
func badgedMenuBarImage() -> NSImage? {
    guard let base = menuBarImage() else { return nil }
    let badged = NSImage(size: base.size, flipped: false) { rect in
        base.draw(in: rect)
        guard let context = NSGraphicsContext.current else { return true }
        let diameter: CGFloat = 9
        let badge = NSRect(x: rect.maxX - diameter, y: rect.minY, width: diameter, height: diameter)

        // A cleared ring first, so the disc never merges into the silhouette.
        context.compositingOperation = .clear
        NSBezierPath(ovalIn: badge.insetBy(dx: -1.2, dy: -1.2)).fill()

        context.compositingOperation = .sourceOver
        NSColor.black.setFill()
        NSBezierPath(ovalIn: badge).fill()

        // The "!" — punched out, so it shows the menu bar through the disc.
        context.compositingOperation = .destinationOut
        NSColor.black.setFill()
        let stem: CGFloat = 1.5
        let x = badge.midX - stem / 2
        NSBezierPath(rect: NSRect(x: x, y: badge.minY + 3.4, width: stem, height: 3.1)).fill()
        NSBezierPath(ovalIn: NSRect(x: x, y: badge.minY + 1.5, width: stem, height: stem)).fill()
        return true
    }
    badged.isTemplate = true
    return badged
}

// Quit needs a real handler, not NSApplication.terminate directly: while we run
// under the LaunchAgent-era job (see migrateFromLaunchAgentEra), a plain exit is
// resurrected by its KeepAlive, so Quit has to take the job down with it.
final class MenuActions: NSObject {
    @objc func settings(_ sender: Any?) { settingsWindow.show() }

    @objc func grantAccessibility(_ sender: Any?) {
        openAccessibilitySettings()
        // Show Settings too: the CTA there is what tells them we relaunch on our
        // own once the switch is flipped, so nothing looks broken meanwhile.
        settingsWindow.show()
    }

    @objc func quit(_ sender: Any?) {
        if launchedByLegacyAgent {
            _ = runTool("/bin/launchctl", ["bootout", "gui/\(getuid())/\(legacyAgentLabel)"])
        }
        NSApp.terminate(nil)
    }
}
let menuActions = MenuActions()

// Held so the permission state can be reapplied without rebuilding the menu.
var grantMenuItem: NSMenuItem?

// Everything about the status item that depends on whether we are trusted: the
// badge, the tooltip, the extra menu item — and whether the icon may be hidden
// at all. It may not: with no permission the menu is the only route to the grant
// flow, so "Hide menu bar icon" is overridden until we are trusted, or a user who
// hid the icon and then upgraded would be stranded with a dead app and no UI.
func refreshStatusItemForPermission() {
    let trusted = AXIsProcessTrusted()
    statusItem?.isVisible = trusted ? !menuBarIconHidden : true
    if let button = statusItem?.button, button.image != nil {
        button.image = trusted ? menuBarImage() : badgedMenuBarImage()
    }
    statusItem?.button?.toolTip = trusted
        ? "noswoosh \(noswooshVersion)"
        : "noswoosh — needs Accessibility permission"
    grantMenuItem?.isHidden = trusted
}

func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let button = item.button else { return }
    if let image = menuBarImage() {
        button.image = image
    } else {
        button.title = "👽"   // bundle resources missing; still give the user a handle
    }
    button.toolTip = "noswoosh \(noswooshVersion)"
    let menu = NSMenu()
    let header = NSMenuItem(title: "noswoosh \(noswooshVersion)", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())
    let grant = NSMenuItem(title: "Grant Accessibility…",
                           action: #selector(MenuActions.grantAccessibility(_:)), keyEquivalent: "")
    grant.target = menuActions
    menu.addItem(grant)
    grantMenuItem = grant
    // No key equivalents anywhere in here: the menu is only reachable by clicking
    // the status item, and a stray Cmd+Q (or Cmd+,) would shadow the frontmost
    // app's own Quit or Settings.
    let settings = NSMenuItem(title: "Settings",
                              action: #selector(MenuActions.settings(_:)), keyEquivalent: "")
    settings.target = menuActions
    menu.addItem(settings)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit",
                          action: #selector(MenuActions.quit(_:)), keyEquivalent: "")
    quit.target = menuActions
    menu.addItem(quit)
    item.menu = menu
    statusItem = item
}

// Hiding the status item leaves no way back in, so AppDelegate's reopen handler
// is what makes this setting safe to offer: launching the app again from Finder
// reaches the running instance as a "reopen" and we surface Settings.
//
// There is no apply/refresh pair here as there is for the input sources: while
// untrusted the icon stays up regardless of the preference, so the only sane
// entry point is the permission-aware one.
func setMenuBarIconHidden(_ hidden: Bool) {
    menuBarIconHidden = hidden
    UserDefaults.standard.set(hidden, forKey: Pref.hideMenuBarIcon)
    refreshStatusItemForPermission()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settingsWindow.show()
        return true
    }
}
let appDelegate = AppDelegate()
