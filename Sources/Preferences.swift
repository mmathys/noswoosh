import Foundation

// MARK: - Preferences (what the settings window edits)

// Both input sources and their keys live in our own defaults domain, alongside
// loginItemRegistered above. An absent key must read as ON: that is what every
// version before the settings window did, and a fresh install must not come up
// with both inputs dead.
enum Pref {
    static let hotkey = "hotkeyEnabled"
    static let swipe  = "swipeEnabled"
    static let hideMenuBarIcon = "hideMenuBarIcon"
}

func prefBool(_ key: String) -> Bool {
    UserDefaults.standard.object(forKey: key) as? Bool ?? true
}

// Mirrored into globals because the swipe tap's callback reads its flag on the
// event thread, where a UserDefaults lookup per event would be silly.
var hotkeyEnabled = prefBool(Pref.hotkey)
var swipeEnabled  = prefBool(Pref.swipe)
// The odd one out: absent means *shown*, so it cannot use prefBool's default.
var menuBarIconHidden = UserDefaults.standard.bool(forKey: Pref.hideMenuBarIcon)
