import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// noswoosh — instant macOS space switching (verified on macOS 26 and 27, Apple Silicon).
//
//   noswoosh            daemon: Ctrl+Left/Right (one space), Option+1…0
//                       (jump straight to Desktop 1…10) OR a 3-finger swipe
//                       switch spaces instantly (no animation)
//   noswoosh setup      one-time system config (see below), needs no sudo
//   noswoosh teardown   undo the system config
//   noswoosh left       switch one space left and exit
//   noswoosh right      switch one space right and exit
//   noswoosh goto N     jump straight to Desktop N and exit
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
// `noswoosh setup` disables the animated system space shortcuts — Ctrl+arrow
// (symbolic hotkeys 79/81) and "Switch to Desktop 1…10" (118…127) — because
// each consumes its key combo before the daemon's own hotkey sees it. Setup
// disables them live via SkyLight (defaults alone doesn't affect the running
// session) AND persists them in com.apple.symbolichotkeys for future logins.
// (For migration it also clears the legacy com.apple.dock
// workspaces-auto-swoosh override older versions set — see the yank guard
// below and the setup case for why we no longer touch it.)
//
// Build: swiftc noswoosh.swift -O -o noswoosh \
//          -F /System/Library/PrivateFrameworks -framework SkyLight

let noswooshVersion = "1.7.4"

// MARK: - Setup / teardown (system configuration, all user-level)

func runTool(_ path: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

// Same, capturing stdout. Read to EOF before waiting so a full pipe can't
// deadlock the child.
func runToolOutput(_ path: String, _ arguments: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
}

// Flip one symbolic hotkey's live (WindowServer) state. Resolved via dlsym:
// writing defaults alone does not affect the running login session.
func setSymbolicHotKey(_ id: Int32, enabled: Bool) {
    typealias SetHotKeyFn = @convention(c) (Int32, Bool) -> Int32
    guard let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let sym = dlsym(skylight, "SLSSetSymbolicHotKeyEnabled") else { return }
    let setEnabled = unsafeBitCast(sym, to: SetHotKeyFn.self)
    _ = setEnabled(id, enabled)
}

// Symbolic hotkeys for the animated system space shortcuts that `setup`
// disables so the daemon's own hotkeys hear the combos first: 79/81 are
// "move left/right a space" (Ctrl+arrow, key codes 123/124), and 118…127 are
// "Switch to Desktop 1"…"Switch to Desktop 10".
let ctrlArrowSymbolicHotKeys = [79, 81]
let desktopSymbolicHotKeys = Array(118...127)

// The AppleSymbolicHotKeys dictionary, read through cfprefsd.
func systemSymbolicHotKeys() -> [String: Any]? {
    guard let data = runToolOutput("/usr/bin/defaults", ["export", "com.apple.symbolichotkeys", "-"]),
          let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
          let hotkeys = root["AppleSymbolicHotKeys"] as? [String: Any] else { return nil }
    return hotkeys
}

// Persist one `enabled` flag per key with `-dict-add`, going through cfprefsd the
// same way the system's own writes do. Each entry's `value` (the key binding) is
// copied across, so a rebinding — Opt+1…0 is itself a customization of the
// Ctrl+1…0 default — survives the cycle. 79/81 get their documented default if a
// fresh system somehow lacks the entry.
func persistSystemSpaceShortcuts(ids: [Int], enabled: Bool) {
    guard let hotkeys = systemSymbolicHotKeys() else { return }
    for id in ids {
        let key = String(id)
        var parameters: [Int]?
        if let value = hotkeys[key] as? [String: Any], let p = value["parameters"] as? [NSNumber] {
            parameters = p.map { $0.intValue }
        } else if let keyCode = [79: 123, 81: 124][id] {
            parameters = [65535, keyCode, 8650752]
        }
        guard let p = parameters, p.count == 3 else { continue }
        let entry = "{enabled = \(enabled ? 1 : 0); value = { parameters = (\(p[0]), \(p[1]), \(p[2])); type = standard; };}"
        _ = runTool("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys",
                                          "AppleSymbolicHotKeys", "-dict-add", key, entry])
    }
}

func systemSpaceShortcutsMatch(ids: [Int], enabled: Bool) -> Bool {
    guard let hotkeys = systemSymbolicHotKeys() else { return false }
    return ids.allSatisfy { id in
        guard let entry = hotkeys[String(id)] as? [String: Any] else { return false }
        return ((entry["enabled"] as? NSNumber)?.boolValue ?? false) == enabled
    }
}

func setSystemSpaceShortcuts(enabled: Bool) {
    let ids = ctrlArrowSymbolicHotKeys + desktopSymbolicHotKeys
    // Changing a hotkey live makes the system persist it itself, asynchronously,
    // and that write can land after ours and revert a single key (measured ~1 in
    // 6 even writing each key through cfprefsd). So re-issue both and verify the
    // readback, retrying until it sticks — in practice one or two passes.
    for _ in 0..<5 {
        for id in ids { setSymbolicHotKey(Int32(id), enabled: enabled) }
        persistSystemSpaceShortcuts(ids: ids, enabled: enabled)
        if systemSpaceShortcutsMatch(ids: ids, enabled: enabled) { return }
        Thread.sleep(forTimeInterval: 0.2)
    }
}

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

// Jump a display straight to a space by id. This is the one place noswoosh does
// not go through the Dock: a Dock gesture moves exactly one space, so an absolute
// jump would be a run of them — slow to cross and easy to overrun. Issue #1
// records this route failing on macOS 26.0–26.5, but it switches instantly and
// cleanly on 27; verify on 26.6+ before assuming otherwise.
@_silgen_name("SLSManagedDisplaySetCurrentSpace")
func SLSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString,
                                      _ space: UInt64) -> Int32

let cid = SLSMainConnectionID()

struct SpaceInfo {
    let ids: [UInt64]
    let currentIndex: Int
    // Indices into `ids` of the ordinary desktops (type 0), skipping fullscreen
    // spaces (type 4). Relative switching traverses every space, but the system's
    // "Desktop N" numbering counts only desktops, so absolute jumps use this.
    let desktopIndices: [Int]
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
        var ids: [UInt64] = []
        var desktopIndices: [Int] = []
        for space in spaces {
            guard let id = (space["id64"] as? NSNumber)?.uint64Value else { continue }
            if (space["type"] as? NSNumber)?.intValue == 0 { desktopIndices.append(ids.count) }
            ids.append(id)
        }
        guard let idx = ids.firstIndex(of: current) else { return nil }
        // If `type` ever goes missing, fall back to treating every space as a
        // desktop rather than deadening the Option+number hotkeys.
        if desktopIndices.isEmpty { desktopIndices = Array(ids.indices) }
        return SpaceInfo(ids: ids, currentIndex: idx, desktopIndices: desktopIndices,
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

// MARK: - macOS version gate

// Major version of the running OS — not the build SDK — or 0 if it can't be read.
// Two gates key off this (the IOHID payload below and the yank guard); keep it one
// read so they can't disagree.
func macOSMajorVersion() -> Int {
    var buf = [CChar](repeating: 0, count: 32)
    var size = buf.count
    guard sysctlbyname("kern.osproductversion", &buf, &size, nil, 0) == 0,
          let major = Int(String(cString: buf).split(separator: ".").first ?? "") else {
        return 0
    }
    return major
}
let macOSMajor = macOSMajorVersion()

// macOS 27+ validates synthetic Dock swipes against a serialized IOHID payload.
// NOSWOOSH_FORCE_AUGMENT=0/1 overrides for testing without a rebuild.
func computeNeedsAugmentation() -> Bool {
    if let force = ProcessInfo.processInfo.environment["NOSWOOSH_FORCE_AUGMENT"] {
        return force == "1"
    }
    return macOSMajor >= 27
}
let needsAugmentation = computeNeedsAugmentation()

// MARK: - Synthetic Dock-swipe gesture (undocumented CGEventFields)

func field(_ n: UInt32) -> CGEventField { unsafeBitCast(n, to: CGEventField.self) }
let fieldCGSEventType   = field(55)
let fieldGestureHIDType = field(110)
let fieldSwipeMask      = field(115)   // 27 payload
let fieldSwipeMotion    = field(123)
let fieldSwipeProgress  = field(124)
let fieldSwipePositionX = field(125)   // 27 payload
let fieldSwipePositionY = field(126)   // 27 payload
let fieldSwipeVelocityX = field(129)
let fieldSwipeVelocityY = field(130)
let fieldGesturePhase   = field(132)

let kCGSEventGesture: Int64 = 29
let kCGSEventDockControl: Int64 = 30
let kIOHIDEventTypeDockSwipe: Int64 = 23
let kCGGestureMotionHorizontal: Int64 = 1
let kRawIOHIDPayloadTag: Int = 4205    // 0x106D — CGEvent field carrying the blob
let gestureVelocity = 2000.0

enum GesturePhase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

// Synthetic events we post re-enter our own event tap; both paths tag them so
// the tap lets them straight back out. A tag travels with the event, so it also
// works across processes — which a counter could not, and that was #8: a running
// daemon intercepted the CLI's events and moved the wrong way.

// MARK: pre-27 path (macOS 26) — bare Dock-swipe, near-zero progress

// This path is correct on macOS 26.6+; on 26.0–26.5 WindowServer drops the
// destination's surfaces at commit (see the header note and issue #1, which
// also records the workarounds that were tried and rejected).

// Synthetic events identify themselves to our own event tap via this tag in
// the user-data field, so the tap passes them through instead of intercepting
// them. Real trackpad gestures carry 0 there.
let noswooshEventTag: Int64 = 0x4E53_5753 // 'NSWS'

func postDockSwipe(_ phase: GesturePhase, right: Bool) {
    guard let ev = CGEvent(source: nil) else { return }
    // Near-zero progress commits the switch with nothing left to animate.
    // NOTE: not FLT_TRUE_MIN — that subnormal flushes to zero (sign lost) in
    // the event pipeline on Apple Silicon, breaking direction; 1e-4 survives.
    let progress = 1e-4 * (right ? 1 : -1)
    let velocity = gestureVelocity * (right ? 1 : -1)
    ev.setIntegerValueField(fieldCGSEventType, value: kCGSEventDockControl)
    ev.setIntegerValueField(fieldGestureHIDType, value: kIOHIDEventTypeDockSwipe)
    ev.setIntegerValueField(fieldGesturePhase, value: phase.rawValue)
    ev.setDoubleValueField(fieldSwipeProgress, value: progress)
    ev.setIntegerValueField(fieldSwipeMotion, value: kCGGestureMotionHorizontal)
    ev.setDoubleValueField(fieldSwipeVelocityX, value: velocity)
    ev.setDoubleValueField(fieldSwipeVelocityY, value: velocity)
    ev.setIntegerValueField(.eventSourceUserData, value: noswooshEventTag)
    ev.post(tap: .cgSessionEventTap)
}

// MARK: macOS 27+ path — IOHID payload + companion pairs

func fixed1616(_ v: Double) -> Int32 {
    let f = Int32(truncatingIfNeeded: Int64(v * 65536.0))
    if f == 0 && v != 0 { return v > 0 ? 1 : -1 }
    return f
}

// Little-endian byte buffer helpers for the packed IOHID structs.
extension Array where Element == UInt8 {
    mutating func le(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le(_ v: Int32)  { le(UInt32(bitPattern: v)) }
}

// Serialized IOHID queue payload macOS 27 validates the synthetic swipe against:
// a queue header, a fluid-touch gesture record, and (on motion/end) a velocity
// record. Layout reverse-engineered from joshuarli/iss.
func generateIOHIDPayload(_ ev: CGEvent) -> [UInt8] {
    let phase   = ev.getIntegerValueField(fieldGesturePhase)
    let motion  = ev.getIntegerValueField(fieldSwipeMotion)
    let progress = ev.getDoubleValueField(fieldSwipeProgress)
    let posX    = ev.getDoubleValueField(fieldSwipePositionX)
    let posY    = ev.getDoubleValueField(fieldSwipePositionY)
    let velX    = ev.getDoubleValueField(fieldSwipeVelocityX)
    let velY    = ev.getDoubleValueField(fieldSwipeVelocityY)
    let mask    = ev.getIntegerValueField(fieldSwipeMask)
    // The velocity record is required on macOS 27 (dropping it entirely stops the
    // switch), even when the velocities are zero on the non-ended phases.
    let includeVelocity = velX != 0 || velY != 0 || phase == GesturePhase.ended.rawValue

    var p = [UInt8]()
    // IOHIDSystemQueueElementHeader (28 bytes)
    let ts = ev.timestamp
    p.le(ts != 0 ? ts : mach_absolute_time())   // timestamp
    p.le(UInt64(0))                             // sender_id
    p.le(UInt32(0))                             // options
    p.le(UInt32(0))                             // attribute_length
    p.le(UInt32(includeVelocity ? 2 : 1))       // event_count
    // IOHIDFluidTouchGestureData (40 bytes): 16-byte base + fields
    p.le(UInt32(40))                            // base.size
    p.le(UInt32(23))                            // base.type = fluid-touch gesture
    p.le(UInt32((UInt32(truncatingIfNeeded: phase) & 0xFF) << 24)) // base.options
    p.append(0); p.append(0); p.append(0); p.append(0)            // base.depth + reserved[3]
    p.le(fixed1616(posX))                       // position_x
    p.le(fixed1616(posY))                       // position_y
    p.le(Int32(0))                              // position_z
    p.le(UInt32(truncatingIfNeeded: mask))      // swipe_mask
    p.le(UInt16(truncatingIfNeeded: motion))    // gesture_motion
    p.le(UInt16(3))                             // gesture_flavor = Dock primary
    p.le(fixed1616(progress))                   // swipe_progress
    if includeVelocity {
        // IOHIDVelocityEventData (28 bytes): 16-byte base + 3 fixed velocities
        p.le(UInt32(28))                        // base.size
        p.le(UInt32(9))                         // base.type = velocity
        p.le(UInt32(0))                         // base.options
        p.append(1); p.append(0); p.append(0); p.append(0)       // base.depth = 1 + reserved
        p.le(fixed1616(velX))                   // velocity_x
        p.le(fixed1616(velY))                   // velocity_y
        p.le(Int32(0))                          // velocity_z
    }
    return p
}

// Round-trip the event through its serialized form to append the raw IOHID
// payload under field 4205, which the plain setters cannot write.
func augment(_ ev: CGEvent) -> CGEvent? {
    guard let cf = ev.data else { return nil }
    var bytes = [UInt8](cf as Data)
    // Serialized-event format must be version 2 (header 00 00 00 02).
    guard bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 2 else { return nil }
    let payload = generateIOHIDPayload(ev)
    let len = payload.count
    bytes.append(UInt8((len >> 8) & 0xFF))
    bytes.append(UInt8(len & 0xFF))
    bytes.append(UInt8((kRawIOHIDPayloadTag >> 8) & 0xFF))
    bytes.append(UInt8(kRawIOHIDPayloadTag & 0xFF))
    bytes.append(contentsOf: payload)
    return CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData)
}

func makeAugmentedDockEvent(_ phase: GesturePhase, right: Bool) -> CGEvent? {
    guard let ev = CGEvent(source: nil) else { return nil }
    ev.setIntegerValueField(fieldCGSEventType, value: kCGSEventDockControl)
    ev.setIntegerValueField(fieldGestureHIDType, value: kIOHIDEventTypeDockSwipe)
    ev.setIntegerValueField(fieldGesturePhase, value: phase.rawValue)
    // Near-zero progress, same as the pre-27 path and for the same reason: it
    // commits the switch with nothing left to animate. This path used full travel
    // (±1.0) through 1.7.0, which visibly slid on 27 — the switch was correct but
    // not instant, defeating the point. The ±9999 fling on .ended is what commits
    // it, so the magnitude here can be ~0 without losing the switch; only the sign
    // matters. Not FLT_TRUE_MIN (flushes to zero on Apple Silicon, losing the sign)
    // and not 0 either — `fixed1616` would serialize it as 0 in the IOHID payload.
    // On the 27 path direction is inverted: rightward = negative progress.
    ev.setDoubleValueField(fieldSwipeProgress, value: right ? -1e-4 : 1e-4)
    ev.setIntegerValueField(fieldSwipeMotion, value: kCGGestureMotionHorizontal)
    ev.setDoubleValueField(fieldSwipePositionX, value: 0.1)
    // A strong "fling" velocity on the terminal phase is what commits the switch.
    if phase == .ended {
        ev.setDoubleValueField(fieldSwipeVelocityX, value: right ? -9999.0 : 9999.0)
    }
    return ev
}

// Post a DockControl event paired with its companion gesture event.
func postPair(_ dock: CGEvent) {
    guard let companion = CGEvent(source: nil) else { return }
    companion.setIntegerValueField(.eventSourceUserData, value: noswooshEventTag)
    companion.setIntegerValueField(fieldCGSEventType, value: kCGSEventGesture)
    dock.post(tap: .cgSessionEventTap)
    companion.post(tap: .cgSessionEventTap)
}

// MARK: - Switch core (both input sources call only this)

// The gesture commits asynchronously, so on rapid presses the space list can be
// stale. Trust our own prediction for a short window after a switch. macOS 27's
// list settles slower after a synthetic switch, so give it a wider window.
var predictedIndex: Int?
var predictedDisplay: String?
var predictionTime = Date.distantPast
let predictionWindow = needsAugmentation ? 0.4 : 0.25

func postSwitchGesture(right: Bool) {
    // A began/changed/ended sequence must complete; a partial one leaves the Dock
    // mid-gesture on a blank space. On the 27 path, build all three augmented
    // events up front and post nothing if any fails to build, so we never emit a
    // truncated sequence.
    if needsAugmentation {
        var events: [CGEvent] = []
        for phase in [GesturePhase.began, .changed, .ended] {
            guard let dock = makeAugmentedDockEvent(phase, right: right),
                  let aug = augment(dock) else { return }
            // Tag it like the 26 path so our tap lets it back out. Must be set
            // *after* augment(): the serialize/deserialize round-trip in there
            // drops eventSourceUserData, which is why the 27 path used to rely on
            // a counter instead — and why a running daemon then intercepted the
            // CLI's events and moved the wrong way (#8).
            aug.setIntegerValueField(.eventSourceUserData, value: noswooshEventTag)
            events.append(aug)
        }
        events.forEach(postPair)
    } else {
        postDockSwipe(.began, right: right)
        postDockSwipe(.changed, right: right)
        postDockSwipe(.ended, right: right)
    }
}

func switchSpace(right: Bool) {
    guard let info = spaceInfo() else {
        postSwitchGesture(right: right)
        return
    }
    var current = info.currentIndex
    // Prefer our prediction while the list may still be catching up, so a rapid
    // second switch is not blocked by a stale "you're at the edge" reading.
    // Only on the display it was made for; the cursor may have moved since.
    if let p = predictedIndex, predictedDisplay == info.display,
       Date().timeIntervalSince(predictionTime) < predictionWindow {
        current = p
    }
    let target = current + (right ? 1 : -1)
    // Clamp at first/last space to avoid the rubber-band bounce animation
    // (on macOS 27 this also spares the Dock a swipe it would only reject).
    guard target >= 0, target < info.ids.count else { return }
    postSwitchGesture(right: right)
    predictedIndex = target
    predictedDisplay = info.display
    predictionTime = Date()
}

// Absolute jump to Desktop N (1-based): the Option+1…0 hotkey and `goto N` CLI.
// "Desktop N" counts only ordinary desktops, matching the system's own numbering,
// so the target is the Nth desktop index and the jump lands there directly, over
// any fullscreen spaces in between. It sets the space by id rather than posting a
// run of one-space Dock gestures: a gesture moves exactly one space, so a run is
// both slow to cross and easy to overrun, while this is a single call.
@discardableResult
func jumpToDesktop(_ desktop: Int) -> Bool {
    guard desktop >= 1, let info = spaceInfo(), let display = info.display,
          desktop <= info.desktopIndices.count else { return false }
    let targetIndex = info.desktopIndices[desktop - 1]
    guard SLSManagedDisplaySetCurrentSpace(cid, display as CFString, info.ids[targetIndex]) == 0 else {
        return false
    }
    // Keep relative switching consistent if the space list lags the jump.
    predictedIndex = targetIndex
    predictedDisplay = info.display
    predictionTime = Date()
    return true
}

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
// Verified on macOS 26.6: 3/3 yanked without the guard, 0/3 with it. Two things
// that do NOT work, so don't "simplify" to them: parking a real window on the
// destination space (verified resident, still yanks — emptiness is the trigger,
// not the cause), and activating BEFORE the switch (the switch re-activates
// macOS's pick at landing and wipes it out). It has to be on landing.

// Is any ordinary (layer 0) window resident on this space?
func spaceHasWindows(_ spaceID: UInt64) -> Bool {
    let list = CGWindowListCopyWindowInfo([.excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] ?? []
    let ids = list.compactMap { w -> UInt32? in
        guard (w[kCGWindowLayer as String] as? Int) == 0 else { return nil }
        return w[kCGWindowNumber as String] as? UInt32
    }
    guard !ids.isEmpty else { return false }
    let spaces = SLSCopySpacesForWindows(cid, 0x7, ids as CFArray)
        .takeRetainedValue() as? [NSNumber] ?? []
    return spaces.contains { $0.uint64Value == spaceID }
}

// macOS 27 fixed this at the source: it activates **Finder** on a windowless
// landing. Finder owns the desktop and has no off-space window to order in, so the
// chain never starts and nothing yanks — measured 4/4 rounds on 27.0 (26A5416b) with
// a browser parked on another space, versus a reliable yank on 26.6. Running the
// guard there would only displace Finder, and on an empty desktop a user expects
// Finder active (desktop clicks, its menu bar, Cmd+N). So gate it off on 27+.
//
// An unreadable version (0) means run it: a needless activation on an unknown OS is
// a far cheaper mistake than the yank coming back on one that needs the guard.
// NOSWOOSH_FORCE_YANK_GUARD=0/1 overrides, for testing either side without a rebuild.
let yankGuardNeeded: Bool = {
    if let force = ProcessInfo.processInfo.environment["NOSWOOSH_FORCE_YANK_GUARD"] {
        return force == "1"
    }
    return macOSMajor < 27
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

// A real horizontal swipe's direction comes from its progress sign (on .changed)
// or velocity sign (on .ended). A real trackpad swipe to the right carries
// *positive* progress and velocity, on 26 and 27 alike — measured on 27.0
// (26A428) with a passive tap: +0.65 / +7.8 landed one space right, -0.57 / -7.2
// one space left, natively.
//
// This is deliberately NOT the sign we *post* on 27. `makeAugmentedDockEvent`
// must send negative-for-right there, confirmed in a 27.0 VM: forcing positive
// progress moved left and negative moved right, twice each. So on 27 the read
// and write sides use opposite conventions. That asymmetry is real — do not
// "tidy" it by making them agree.
//
// Flipping the reading side too (1.7.2 and earlier) inverts every trackpad swipe,
// while Ctrl+arrow keeps working because it never reads a real gesture. Don't
// re-add it.
func isRightSwipe(_ direction: Double) -> Bool {
    direction > 0
}

// MARK: - CLI modes

let args = CommandLine.arguments
if args.count > 1 {
    switch args[1] {
    case "list":
        if let info = spaceInfo() {
            print("space \(info.currentIndex + 1) of \(info.ids.count)")
        }
        exit(0)
    case "left", "right":
        switchSpace(right: args[1] == "right")
        // brief grace so the gesture events flush before exit
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        exit(0)
    case "goto":
        guard args.count > 2, let desktop = Int(args[2]), desktop >= 1 else {
            FileHandle.standardError.write("usage: noswoosh goto <desktop-number>\n".data(using: .utf8)!)
            exit(1)
        }
        jumpToDesktop(desktop)
        // brief grace so the jump settles before exit
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        exit(0)
    case "setup":
        setSystemSpaceShortcuts(enabled: false)
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
        print("""
        noswoosh setup complete:
          - system animated Ctrl+arrow shortcuts disabled (live + persisted)
          - system animated Switch-to-Desktop 1…10 shortcuts disabled (live + persisted)
        Remaining: start the daemon (brew services start noswoosh, or the
        LaunchAgent from install.sh) and grant it Accessibility permission.
        """)
        exit(0)
    case "teardown":
        setSystemSpaceShortcuts(enabled: true)
        print("noswoosh teardown complete: system Ctrl+arrow and Switch-to-Desktop shortcuts re-enabled.")
        exit(0)
    case "version", "--version":
        print("noswoosh \(noswooshVersion)")
        exit(0)
    default:
        FileHandle.standardError.write("usage: noswoosh [left | right | goto N | list | setup | teardown | version]\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - Daemon mode

func log(_ message: String) {
    FileHandle.standardError.write("noswoosh: \(message)\n".data(using: .utf8)!)
}

// Accessibility trust is evaluated when the process starts and cached for its
// lifetime, so a grant made while we are running does not take effect. Rather
// than making the user restart the daemon by hand, poll and exit once trusted:
// the LaunchAgent sets KeepAlive, so launchd immediately starts a fresh process
// that picks the grant up. Run outside launchd there is nothing to restart us,
// so say so instead.
let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
    log("waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)")
    var secondsWaited = 0
    var openedSettings = false
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        if AXIsProcessTrusted() {
            if getppid() == 1 {
                log("Accessibility granted — restarting to apply it")
            } else {
                log("Accessibility granted — restart noswoosh to apply it")
            }
            exit(0)
        }
        secondsWaited += 1
        // The system prompt above already offers an "Open System Settings" button.
        // Give it a chance; if it was dismissed we are a background agent with no
        // UI, and the only remaining signal is a log file nobody opens — so take
        // the user to the pane directly, once.
        if secondsWaited == 15, !openedSettings {
            openedSettings = true
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            if let url = URL(string: pane), NSWorkspace.shared.open(url) {
                log("opened System Settings > Privacy & Security > Accessibility")
            }
        }
    }
}

let app = NSApplication.shared
// .accessory, not .prohibited: no Dock icon and no Cmd-Tab entry either way, but
// a prohibited app cannot become active, which the yank guard depends on.
app.setActivationPolicy(.accessory)
if yankGuardNeeded {
    installYankGuard()
} else if ProcessInfo.processInfo.environment["NOSWOOSH_FORCE_YANK_GUARD"] != nil {
    log("empty-desktop yank guard off (forced by NOSWOOSH_FORCE_YANK_GUARD)")
} else {
    log("empty-desktop yank guard off (macOS \(macOSMajor) handles it natively)")
}

// Input source 1: Ctrl+Left/Right (relative) and Option+1…0 (straight to
// Desktop 1…10). Hotkey ids: 1 = left, 2 = right, 21…30 = Desktop 1…10.
var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                              eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
    var hotKeyID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    switch hotKeyID.id {
    case 1: switchSpace(right: false)
    case 2: switchSpace(right: true)
    case 21...30: jumpToDesktop(Int(hotKeyID.id) - 20)
    default: break
    }
    return noErr
}, 1, &eventType, nil, nil)

for (id, keyCode) in [(UInt32(1), UInt32(kVK_LeftArrow)), (UInt32(2), UInt32(kVK_RightArrow))] {
    var ref: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: OSType(0x5350_5357), id: id) // 'SPSW'
    let status = RegisterEventHotKey(keyCode, UInt32(controlKey), hotKeyID,
                                     GetApplicationEventTarget(), 0, &ref)
    if status != noErr {
        log("could not register Ctrl+arrow hotkey (status \(status))")
    }
}

// Option+1…0 jump straight to Desktop 1…10. `setup` disables the system's own
// Switch-to-Desktop shortcuts (symbolic hotkeys 118…127) so they don't consume
// these combos first.
let desktopHotKeys: [(keyCode: Int, desktop: Int)] = [
    (kVK_ANSI_1, 1), (kVK_ANSI_2, 2), (kVK_ANSI_3, 3), (kVK_ANSI_4, 4),
    (kVK_ANSI_5, 5), (kVK_ANSI_6, 6), (kVK_ANSI_7, 7), (kVK_ANSI_8, 8),
    (kVK_ANSI_9, 9), (kVK_ANSI_0, 10),
]
for (keyCode, desktop) in desktopHotKeys {
    var ref: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: OSType(0x5350_5357), id: UInt32(20 + desktop))
    let status = RegisterEventHotKey(UInt32(keyCode), UInt32(optionKey), hotKeyID,
                                     GetApplicationEventTarget(), 0, &ref)
    if status != noErr {
        log("could not register Option+\(desktop == 10 ? "0" : String(desktop)) hotkey (status \(status))")
    }
}

// Input source 2: intercept real 3-finger horizontal swipes and replace them
// with the instant switch. Direction is read from progress (Changed) or, for
// discrete swipes that skip Changed, velocity (Ended). Vertical swipes (Mission
// Control, App Exposé) and everything else pass through untouched.
var swipeTracking = false
var swipeFired = false
var swipeTap: CFMachPort?

func resetSwipeState() { swipeTracking = false; swipeFired = false }

let swipeCallback: CGEventTapCallBack = { _, type, ev, _ in
    let pass = Unmanaged.passUnretained(ev)

    if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
        resetSwipeState()
        if AXIsProcessTrusted(), let t = swipeTap { CGEvent.tapEnable(tap: t, enable: true) }
        return pass
    }

    let et = ev.getIntegerValueField(fieldCGSEventType)

    // Synthetic Dock gestures are posted from a process and carry that process's
    // pid; real trackpad gestures come from the HID kernel with pid 0. Passing
    // the synthetic ones through is the primary guard (the technique
    // InstantSpaceSwitcher relies on) and, unlike the tag below, survives the
    // system re-emitting a copy of a gesture with its user data stripped.
    if (et == kCGSEventDockControl || et == kCGSEventGesture)
        && ev.getIntegerValueField(.eventSourceUnixProcessID) != 0 {
        return pass
    }

    // Let our own synthetic events through without re-intercepting them.
    if (et == kCGSEventDockControl || et == kCGSEventGesture)
        && ev.getIntegerValueField(.eventSourceUserData) == noswooshEventTag {
        return pass
    }

    if et == kCGSEventDockControl
        && ev.getIntegerValueField(fieldGestureHIDType) == kIOHIDEventTypeDockSwipe
        && ev.getIntegerValueField(fieldSwipeMotion) == kCGGestureMotionHorizontal {
        let phase = ev.getIntegerValueField(fieldGesturePhase)
        switch phase {
        case GesturePhase.began.rawValue:
            swipeTracking = true; swipeFired = false
            return nil
        case GesturePhase.changed.rawValue:
            if swipeTracking && !swipeFired {
                let p = ev.getDoubleValueField(fieldSwipeProgress)
                if p != 0 { swipeFired = true; switchSpace(right: isRightSwipe(p)) }
            }
            return swipeTracking ? nil : pass
        case GesturePhase.ended.rawValue:
            let wasTracking = swipeTracking
            if swipeTracking && !swipeFired {
                let v = ev.getDoubleValueField(fieldSwipeVelocityX)
                if v != 0 { switchSpace(right: isRightSwipe(v)) }
            }
            resetSwipeState()
            // On macOS 27 let the real terminal event through (fields cleared) so
            // the Dock can close its native gesture state after our synthetic
            // sequence already switched.
            if needsAugmentation && wasTracking {
                ev.setDoubleValueField(fieldSwipeVelocityX, value: 0)
                ev.setDoubleValueField(fieldSwipeVelocityY, value: 0)
                ev.setDoubleValueField(fieldSwipeProgress, value: 0)
                return pass
            }
            return wasTracking ? nil : pass
        case GesturePhase.cancelled.rawValue:
            resetSwipeState()
            return nil
        default:
            return swipeTracking ? nil : pass
        }
    }

    // Suppress companion gesture events belonging to a swipe we're intercepting.
    if et == kCGSEventGesture && swipeTracking { return nil }
    return pass
}

// Tap the private DockControl (30) and companion gesture (29) event types.
let swipeMask = (CGEventMask(1) << kCGSEventGesture) | (CGEventMask(1) << kCGSEventDockControl)
if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                               options: .defaultTap, eventsOfInterest: swipeMask,
                               callback: swipeCallback, userInfo: nil) {
    swipeTap = tap
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    // The callback re-enables the tap when the system disables it, but a disable
    // can arrive without a callback under load. Poll as a backstop so swipes never
    // silently die until the next relaunch.
    Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
        if AXIsProcessTrusted(), !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            log("re-enabled swipe event tap")
        }
    }
} else {
    // Fails when not (yet) trusted; the Accessibility poll above restarts us
    // once granted, and the fresh process creates the tap successfully.
    log("could not create swipe event tap (Accessibility not granted yet?)")
}

app.run()
