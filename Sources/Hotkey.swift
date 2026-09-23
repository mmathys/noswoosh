import Cocoa
import Carbon.HIToolbox

// MARK: - Input source 1: the Ctrl+arrow hotkey

// Each input source is two halves that have to move together. Ctrl+arrow is our
// Carbon hotkey *plus* the system shortcut we take the combo away from; leaving
// one half switched without the other gives you either a dead key combo or two
// handlers for it. The swipe is just the tap, but its two self-healing paths
// (the tapDisabled branch and the 5s backstop) must not resurrect a tap the user
// switched off — they check `swipeEnabled` for exactly that reason.
//
// apply* does the work; set* also persists. Startup calls apply*, so merely
// launching never materialises a key the user has not touched.
var hotKeyRefs: [EventHotKeyRef] = []

func applyHotkey(_ on: Bool) {
    setCtrlArrowShortcuts(enabled: !on)
    guard on else {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        return
    }
    guard hotKeyRefs.isEmpty else { return }   // idempotent: never double-register
    for (id, keyCode) in [(UInt32(1), UInt32(kVK_LeftArrow)), (UInt32(2), UInt32(kVK_RightArrow))] {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5350_5357), id: id) // 'SPSW'
        let status = RegisterEventHotKey(keyCode, UInt32(controlKey), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
        } else {
            log("could not register Ctrl+arrow hotkey (status \(status))")
        }
    }
}

func setHotkeyEnabled(_ on: Bool) {
    hotkeyEnabled = on
    UserDefaults.standard.set(on, forKey: Pref.hotkey)
    applyHotkey(on)
}

// The Carbon handler that turns a registered hotkey into a switch. Installed
// once; applyHotkey is what adds and removes the registrations themselves.
func installHotkeyHandler() {
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
        var hotKeyID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        switchSpace(right: hotKeyID.id == 2)
        return noErr
    }, 1, &eventType, nil, nil)
}
