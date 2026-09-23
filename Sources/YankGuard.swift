import Cocoa

// MARK: - Empty-desktop yank guard

// Landing on a space with no ordinary windows makes macOS pick some other app
// and activate it. If that app's window lives on a different space, ordering it
// in trips the Dock's window-order follow rule and you are yanked away ~400ms
// after landing — the Dock logs "switching to space N for window(...) ordered on
// non-visible space". This is macOS behavior, not ours: plain native switching
// does it too.
//
// The old fix was `workspaces-auto-swoosh -bool NO`, which stops the Dock from
// registering for that notification at all. But disassembling the Dock shows the
// rule's switcher has exactly ONE caller — that same notification block — so
// killing it also kills Dock-icon-follow (clicking a Dock icon to jump to the
// space its window is on). One pref, both behaviors; you cannot split them.
//
// So instead we let the Dock keep its rule and remove the *cause*: the moment we
// land somewhere with nothing to focus, we take activation ourselves. macOS
// still activates its pick (~at landing), but that app never gets to order its
// off-space window in first, so the follow never fires. Measured margin is
// ~380ms, which is why a plain notification observer is fast enough.
//
// Costs, both small: we are an .accessory app with no windows and no menu, so
// the menu bar stays with whatever macOS picked and nothing is visible; only
// keystrokes typed at an empty desktop go nowhere, which is where they were
// already going. Requires .accessory (not .prohibited) — a prohibited app
// cannot become active at all.
//
// Verified on macOS 26.6: 3/3 yanked without the guard, 0/3 with it. Re-verified on
// 27.0 (26A428) for issue #15: 8/8 without, 0/8 with. Three things that do NOT work,
// so don't "simplify" to them: parking a real window on the destination space
// (verified resident, still yanks — emptiness is the trigger, not the cause),
// activating BEFORE the switch (the switch re-activates macOS's pick at landing and
// wipes it out), and activating Finder instead of ourselves (6/6 yanked, to Finder's
// own window's space). It has to be on landing, and it has to be a windowless app.

// Is any ordinary (layer 0) window resident on this space?
func spaceHasWindows(_ spaceID: UInt64) -> Bool {
    let list = CGWindowListCopyWindowInfo([.excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] ?? []
    let ids = list.compactMap { w -> UInt32? in
        guard (w[kCGWindowLayer as String] as? Int) == 0 else { return nil }
        // Our own Settings window doesn't count as something the user has on this
        // desktop, and it sits on every space (see the settings window's
        // collectionBehavior), so counting it would make every desktop look
        // occupied and switch the guard off entirely.
        guard (w[kCGWindowOwnerPID as String] as? pid_t) != getpid() else { return nil }
        return w[kCGWindowNumber as String] as? UInt32
    }
    guard !ids.isEmpty else { return false }
    let spaces = SLSCopySpacesForWindows(cid, 0x7, ids as CFArray)
        .takeRetainedValue() as? [NSNumber] ?? []
    return spaces.contains { $0.uint64Value == spaceID }
}

// 1.7.0-1.7.5 gated this off on 27, on the belief that 27 had fixed it at the source
// by always activating **Finder** on a windowless landing — Finder owns the desktop,
// so it has no off-space window to order in and the chain never starts. That was
// measured 4/4 in a VM with one browser parked on another space, and it is true only
// of that arrangement. On a real desktop 27 picks whichever app was most recently
// used, exactly like 26, and the yank is back. Measured on 27.0 (26A428) with a
// full-screen space next to an empty one: 8/8 switches ended on the wrong space with
// the guard off, 0/8 with it on (issue #15).
//
// Finder is not even reliably safe. Activating Finder *by hand* on a windowless
// landing yanked 6/6 times — to whichever space Finder's own window was on. The one
// app guaranteed to have no off-space window to order in is a windowless one, i.e.
// us, which is why the guard activates itself rather than handing focus to Finder.
//
// So the guard now runs on every version. Its cost on 27 is the same one it already
// pays on 26 and is smaller than it sounds: we have no windows and no menu, so the
// menu bar on that empty desktop still reads "Finder" — verified by screenshot on
// 27.0. NOSWOOSH_FORCE_YANK_GUARD=0/1 still overrides, for testing either side
// without a rebuild.
let yankGuardNeeded: Bool = {
    if let force = ProcessInfo.processInfo.environment["NOSWOOSH_FORCE_YANK_GUARD"] {
        return force == "1"
    }
    return true
}()

// Daemon-only: a CLI switch exits within 150ms, so claiming activation there
// would be pointless (and we would hand focus back on exit anyway).
func installYankGuard() {
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil, queue: .main
    ) { _ in
        if !spaceHasWindows(SLSGetActiveSpace(cid)) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
