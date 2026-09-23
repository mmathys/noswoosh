import Cocoa

// MARK: - Private SkyLight reads (space bookkeeping only)

typealias CGSConnectionID = UInt32

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> CGSConnectionID

@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>

@_silgen_name("SLSGetActiveSpace")
func SLSGetActiveSpace(_ cid: CGSConnectionID) -> UInt64

// Returns the union of spaces the given windows live on (mask 0x7 = all).
@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32,
                             _ windows: CFArray) -> Unmanaged<CFArray>

let cid = SLSMainConnectionID()

struct SpaceInfo {
    let ids: [UInt64]
    let currentIndex: Int
    // "Display Identifier" of the display this list belongs to, so a prediction
    // made on one display is never applied to another's list.
    let display: String?
}

// UUID string of the display under the mouse cursor, in the same form as the
// "Display Identifier" values in SLSCopyManagedDisplaySpaces. A CGEvent's
// location is already in global CG coordinates, so this needs no flip from
// Cocoa's bottom-left origin.
func cursorDisplayUUID() -> String? {
    guard let location = CGEvent(source: nil)?.location else { return nil }
    var displayID = CGDirectDisplayID()
    var matched: UInt32 = 0
    guard CGGetDisplaysWithPoint(location, 1, &displayID, &matched) == .success,
          matched > 0,
          let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
}

// Space list for the display the switch will actually land on, plus that
// display's current index in it. The list includes fullscreen spaces, which the
// swipe traverses too.
//
// The Dock routes a Dock-swipe to the display under the *mouse cursor*, not the
// one holding keyboard focus — native Ctrl+arrow routes the same way, so merely
// hovering a display makes it the target. SLSGetActiveSpace tracks keyboard
// focus instead, so clamping against it guards the wrong list whenever cursor
// and focus sit on different displays: it either deadens a legal keypress or
// lets through a swipe that rubber-bands. See issue #3.
func spaceInfo() -> SpaceInfo? {
    let displays = SLSCopyManagedDisplaySpaces(cid).takeRetainedValue() as! [[String: Any]]

    func info(_ display: [String: Any], current: UInt64) -> SpaceInfo? {
        guard let spaces = display["Spaces"] as? [[String: Any]] else { return nil }
        let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard let idx = ids.firstIndex(of: current) else { return nil }
        return SpaceInfo(ids: ids, currentIndex: idx,
                         display: display["Display Identifier"] as? String)
    }

    // Multi-display: ask the cursor's display for its own current space. Each
    // display dict already carries one, so this costs no extra private call.
    if displays.count > 1, let uuid = cursorDisplayUUID(),
       let display = displays.first(where: { ($0["Display Identifier"] as? String) == uuid }),
       let current = (display["Current Space"] as? [String: Any])?["id64"] as? NSNumber,
       let result = info(display, current: current.uint64Value) {
        return result
    }

    // One managed display — a single screen, or "Displays have separate Spaces"
    // off, where every screen shares one list — plus the fallback for a failed
    // cursor lookup. Byte-identical to the behavior before the fix.
    let active = SLSGetActiveSpace(cid)
    for display in displays {
        if let result = info(display, current: active) { return result }
    }
    return nil
}
