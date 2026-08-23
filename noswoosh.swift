import Cocoa
import Carbon.HIToolbox
import ApplicationServices

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
// How it works: two input sources feed one switch core — a Ctrl+arrow hotkey,
// and an event tap that intercepts real 3-finger horizontal swipes and replaces
// them with the instant switch (posting/tapping events requires Accessibility
// permission). The switch itself has two modes:
// - gesture (default): a synthetic Dock-swipe (techniques from
//   jurplel/InstantSpaceSwitcher, MIT, and joshuarli/iss, ISC) — it runs
//   through the Dock's own pipeline, so state stays consistent everywhere:
//   the Dock is the sole authoritative owner of the Spaces model.
// - direct (experimental, NOSWOOSH_SWITCH_MODE=direct): show/hide the spaces
//   straight through WindowServer (SLSShowSpaces/SLSHideSpaces/
//   SLSManagedDisplaySetCurrentSpace). Instant and transition-free, but the
//   Dock's in-process Spaces model cannot be updated from outside, so
//   Mission Control desyncs (issue #1 research notes).
//
// macOS 27 (Tahoe's successor) added validation: synthetic Dock swipes must
// carry a serialized raw IOHID queue payload in CGEvent field 4205, and each
// DockControl event must be paired with a companion gesture event. Without this
// the Dock silently ignores the event. The macOS 27 payload layout is
// reverse-engineered from joshuarli/iss (ISC). Everything 27-specific is gated
// behind `needsAugmentation`, so the verified macOS 26 path is untouched.
//
// Two Dock settings matter; `noswoosh setup` configures both:
// - The system's animated Ctrl+arrow shortcuts (symbolic hotkeys 79/81) must
//   be disabled or they consume the key combo first. Setup disables them
//   live via SkyLight (defaults alone doesn't affect the running session)
//   AND persists them in com.apple.symbolichotkeys for future logins.
// - `defaults write com.apple.dock workspaces-auto-swoosh -bool NO` + Dock
//   restart. Without it, landing on a WINDOWLESS space makes macOS yank you
//   away ~400ms later: WindowServer re-promotes the last-active app, that app
//   re-orders its key window (which lives on another space), and the Dock's
//   window-order follow rule — registered at Dock startup only when this key
//   is true — switches to it ("switching to space N for window ordered on
//   non-visible space" in the Dock log). This affects native switching too.
//
// Build: swiftc noswoosh.swift -O -o noswoosh \
//          -F /System/Library/PrivateFrameworks -framework SkyLight

let noswooshVersion = "1.6.1"

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

// MARK: - Private SkyLight calls (space bookkeeping + direct switching)

typealias CGSConnectionID = UInt32

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> CGSConnectionID

@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>

@_silgen_name("SLSGetActiveSpace")
func SLSGetActiveSpace(_ cid: CGSConnectionID) -> UInt64

@_silgen_name("SLSShowSpaces")
func SLSShowSpaces(_ cid: CGSConnectionID, _ spaces: CFArray)

@_silgen_name("SLSHideSpaces")
func SLSHideSpaces(_ cid: CGSConnectionID, _ spaces: CFArray)

@_silgen_name("SLSManagedDisplaySetCurrentSpace")
func SLSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString, _ space: UInt64) -> Int32

@_silgen_name("SLSManagedDisplaySetIsAnimating")
func SLSManagedDisplaySetIsAnimating(_ cid: CGSConnectionID, _ display: CFString, _ animating: Bool) -> Int32

@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: CGSConnectionID, _ selector: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

let cid = SLSMainConnectionID()

struct SpaceInfo { let ids: [UInt64]; let currentIndex: Int; let displayIdent: String? }

// Space list for the display that owns the currently active space, plus the
// active space's index in it. Keying off the global active space (not
// displays.first) keeps boundary math correct on multi-display setups, where the
// switch lands on whichever display has focus. On a single display this is
// exactly the first display. The list includes fullscreen spaces, which the
// swipe traverses too.
func spaceInfo() -> SpaceInfo? {
    let displays = SLSCopyManagedDisplaySpaces(cid).takeRetainedValue() as! [[String: Any]]
    let active = SLSGetActiveSpace(cid)
    for display in displays {
        guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
        let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        if let idx = ids.firstIndex(of: active) {
            return SpaceInfo(ids: ids, currentIndex: idx,
                             displayIdent: display["Display Identifier"] as? String)
        }
    }
    return nil
}

// MARK: - macOS version gate

// macOS 27+ validates synthetic Dock swipes against a serialized IOHID payload.
// The running OS — not the build SDK — decides, so check it at runtime.
// NOSWOOSH_FORCE_AUGMENT=0/1 overrides for testing without a rebuild.
func computeNeedsAugmentation() -> Bool {
    if let force = ProcessInfo.processInfo.environment["NOSWOOSH_FORCE_AUGMENT"] {
        return force == "1"
    }
    var buf = [CChar](repeating: 0, count: 32)
    var size = buf.count
    guard sysctlbyname("kern.osproductversion", &buf, &size, nil, 0) == 0,
          let major = Int(String(cString: buf).split(separator: ".").first ?? "") else {
        return false
    }
    return major >= 27
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
let fieldGestureScrollY = field(119)   // iss style
let fieldScrollGestureFlagBits = field(135)   // iss style: direction hint
let fieldGestureZoomDeltaX     = field(139)   // iss style: required

let kCGSEventGesture: Int64 = 29
let kCGSEventDockControl: Int64 = 30
let kIOHIDEventTypeDockSwipe: Int64 = 23
let kCGGestureMotionHorizontal: Int64 = 1
let kRawIOHIDPayloadTag: Int = 4205    // 0x106D — CGEvent field carrying the blob
let gestureVelocity = 2000.0

enum GesturePhase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

// Synthetic events we post re-enter our own event tap. The 26 path tags its
// events (they may be spread over time, so a counter could mismatch against
// interleaved real gestures); the 27 path's paired events are counted: the tap
// passes through exactly this many DockControl/gesture events untouched.
// Harmless in CLI mode (no tap runs) since the process exits promptly.
var passthrough = 0

// MARK: pre-27 path (macOS 26) — bare Dock-swipe, three styles

// macOS 26.0–26.5 (fixed by 26.6): WindowServer builds the destination space's
// compositing surfaces *as the swipe's progress advances* — a near-zero-
// progress commit (style "zero", the legacy technique) lands on a space whose
// surfaces were never built and get dropped: windows stay onscreen with
// alpha 1 but never paint (issue #1). Styles via NOSWOOSH_GESTURE_STYLE:
// - "zero" (default): the legacy instant sequence — near-zero progress, high
//   velocity. Correct on macOS 26.6+; wedges on 26.0–26.5.
// - "ramp": progress ramps 0 → ±1 over NOSWOOSH_GESTURE_MS (default 40ms) —
//   the only shape verified wedge-free on 26.5, at the cost of a fast
//   visible slide. The workaround for 26.0–26.5.
// - "iss": the joshuarli/iss (ISC) event shape — NO progress field at all;
//   direction rides in integer field 135 as the bit pattern of ±FLT_TRUE_MIN
//   (an integer field, so the subnormal survives the float-pipeline flush the
//   zero style's 1e-4 works around), field 139 = FLT_TRUE_MIN, terminal
//   velocity ±400. Tested on 26.5.2: equally instant, equally wedged — same
//   zero-travel class as "zero".
// NOSWOOSH_GESTURE_MS: total duration for "ramp"; optional inter-phase gap
// for "iss" (default 0 = atomic; ~10ms per jurplel/InstantSpaceSwitcher
// PR #88 — tested on 26.5.2, did not help the wedge).
enum GestureStyle { case iss, ramp, zero }
let gestureStyle: GestureStyle = {
    switch ProcessInfo.processInfo.environment["NOSWOOSH_GESTURE_STYLE"] {
    case "ramp": return .ramp
    case "iss": return .iss
    default: return .zero
    }
}()
let gestureDurationMS: Int = {
    if let raw = ProcessInfo.processInfo.environment["NOSWOOSH_GESTURE_MS"],
       let ms = Int(raw) {
        return min(max(ms, 0), 1000)
    }
    return gestureStyle == .ramp ? 40 : 0
}()

// Synthetic events identify themselves to our own event tap via this tag in
// the user-data field, so the tap passes them through instead of intercepting
// them. Real trackpad gestures carry 0 there.
let noswooshEventTag: Int64 = 0x4E53_5753 // 'NSWS'

// Default progress is near zero: commits the switch with nothing left to
// animate (the paced path passes a real ramp instead).
// NOTE: not FLT_TRUE_MIN — that subnormal flushes to zero (sign lost) in
// the event pipeline on Apple Silicon, breaking direction; 1e-4 survives.
func postDockSwipe(_ phase: GesturePhase, right: Bool, progress magnitude: Double = 1e-4) {
    guard let ev = CGEvent(source: nil) else { return }
    let progress = magnitude * (right ? 1 : -1)
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

// iss-style event: no progress field at all; see the style comment above.
func makeIssDockEvent(_ phase: GesturePhase, right: Bool) -> CGEvent? {
    guard let ev = CGEvent(source: nil) else { return nil }
    ev.setIntegerValueField(fieldCGSEventType, value: kCGSEventDockControl)
    ev.setIntegerValueField(fieldGestureHIDType, value: kIOHIDEventTypeDockSwipe)
    ev.setIntegerValueField(fieldGesturePhase, value: phase.rawValue)
    let hint = right ? Float.leastNonzeroMagnitude : -Float.leastNonzeroMagnitude
    ev.setIntegerValueField(fieldScrollGestureFlagBits,
                            value: Int64(Int32(bitPattern: hint.bitPattern)))
    ev.setIntegerValueField(fieldSwipeMotion, value: kCGGestureMotionHorizontal)
    ev.setDoubleValueField(fieldGestureScrollY, value: 0)
    ev.setDoubleValueField(fieldGestureZoomDeltaX, value: Double(Float.leastNonzeroMagnitude))
    if phase == .ended {
        ev.setDoubleValueField(fieldSwipeVelocityX, value: right ? 400 : -400)
        ev.setDoubleValueField(fieldSwipeVelocityY, value: 0)
    }
    ev.setIntegerValueField(.eventSourceUserData, value: noswooshEventTag)
    return ev
}

// Dock event + companion gesture event, both tagged for our own tap.
func postTaggedPair(_ dock: CGEvent) {
    guard let companion = CGEvent(source: nil) else { return }
    companion.setIntegerValueField(fieldCGSEventType, value: kCGSEventGesture)
    companion.setIntegerValueField(.eventSourceUserData, value: noswooshEventTag)
    dock.post(tap: .cgSessionEventTap)
    companion.post(tap: .cgSessionEventTap)
}

// Atomic iss sequence: build all three phases up front so we never emit a
// truncated one, then post each as a tracked pair back-to-back.
func postIssSequence(right: Bool) {
    var events: [CGEvent] = []
    for phase in [GesturePhase.began, .changed, .ended] {
        guard let ev = makeIssDockEvent(phase, right: right) else { return }
        events.append(ev)
    }
    events.forEach(postTaggedPair)
}

// One paced sequence at a time; switches requested mid-sequence queue up and
// run back-to-back, so rapid inputs never interleave two gestures.
var gestureInFlight = false
var pendingSwitches: [Bool] = []

func postPacedDockSwipe(right: Bool) {
    gestureInFlight = true
    let finish = {
        gestureInFlight = false
        if !pendingSwitches.isEmpty {
            postPacedDockSwipe(right: pendingSwitches.removeFirst())
        }
    }
    if gestureStyle == .iss {
        // iss shape with phases a fixed gap apart (PR #88 fallback for the
        // Dock dropping back-to-back phases).
        let gap = Double(gestureDurationMS) / 1000.0
        if let began = makeIssDockEvent(.began, right: right) { postTaggedPair(began) }
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            if let changed = makeIssDockEvent(.changed, right: right) { postTaggedPair(changed) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + gap * 2) {
            if let ended = makeIssDockEvent(.ended, right: right) { postTaggedPair(ended) }
            finish()
        }
        return
    }
    // ramp style: changed events at roughly a real gesture's cadence
    // (~16ms apart), progress ramping linearly so the destination surfaces
    // get composited by commit time.
    postDockSwipe(.began, right: right)
    let duration = Double(gestureDurationMS) / 1000.0
    let steps = min(max(gestureDurationMS / 16, 1), 8)
    for i in 1...steps {
        let fraction = Double(i) / Double(steps + 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * fraction) {
            postDockSwipe(.changed, right: right, progress: fraction)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        postDockSwipe(.ended, right: right, progress: 1.0)
        finish()
    }
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
    // On the 27 path direction is inverted: rightward = negative progress.
    ev.setDoubleValueField(fieldSwipeProgress, value: right ? -1.0 : 1.0)
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
    companion.setIntegerValueField(fieldCGSEventType, value: kCGSEventGesture)
    passthrough += 2
    dock.post(tap: .cgSessionEventTap)
    companion.post(tap: .cgSessionEventTap)
}

// MARK: - Direct WindowServer switch (experimental, off by default)

// Instant and transition-free, but structurally inconsistent: the Dock's
// in-process Spaces model (its private _currentSpace state, which Mission
// Control trusts) cannot be written from outside the Dock — yabai does it via
// SIP-off code injection; Hammerspoon gave up and drives Mission Control's
// AX UI instead. Kept for experiments only: NOSWOOSH_SWITCH_MODE=direct.
let useDirectSwitch =
    ProcessInfo.processInfo.environment["NOSWOOSH_SWITCH_MODE"] == "direct"

// Bring the app owning the topmost window ON THE LANDING SPACE to the front.
// Without this the menu bar composites both spaces' bars (double-draw garble),
// because nothing tells the system focus moved. Safe here — unlike activation
// mid-gesture (which amplified the surface race), no transition is in flight.
// The candidate MUST be resolved by mapping windows to the destination space
// (SLSCopySpacesForWindows): the "what's onscreen" list is stale right after a
// direct switch, and activating whatever it lists first re-activates the app
// we just LEFT, whose key window is on a now-hidden space — WindowServer then
// re-promotes that window on top of the landing space and Mission Control's
// model desyncs. Debounced so rapid-fire switching activates once, on the
// final landing. NOSWOOSH_NO_ACTIVATE=1 disables (menu-bar garble returns).
let skipActivation = ProcessInfo.processInfo.environment["NOSWOOSH_NO_ACTIVATE"] == "1"
var pendingActivation: DispatchWorkItem?
func activateLandingAppSoon(on dest: UInt64) {
    pendingActivation?.cancel()
    let work = DispatchWorkItem { activateApp(onSpace: dest) }
    pendingActivation = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
}

// Topmost normal window on a space, resolved via SLSCopySpacesForWindows
// (the plain onscreen list is stale right after a switch).
func topWindow(onSpace dest: UInt64) -> (num: UInt32, pid: pid_t)? {
    guard let wins = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    for w in wins { // front-to-back
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
              let num = w[kCGWindowNumber as String] as? UInt32,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              pid != getpid() else { continue }
        let spaces = SLSCopySpacesForWindows(cid, 0x7, [NSNumber(value: num)] as CFArray)?
            .takeRetainedValue() as? [NSNumber] ?? []
        if spaces.contains(where: { $0.uint64Value == dest }) { return (num, pid) }
    }
    return nil
}

func activateApp(onSpace dest: UInt64) {
    guard let top = topWindow(onSpace: dest) else { return }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != top.pid {
        NSRunningApplication(processIdentifier: top.pid)?.activate()
    }
}

// Map an AXUIElement window to its CGWindowID (private but ubiquitous).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// Re-order one window via Accessibility, without touching focus.
func raiseWindow(number: UInt32, ownerPID pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return }
    for win in windows {
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(win, &wid) == .success, wid == number {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            return
        }
    }
}

func directSwitch(to dest: UInt64, info: SpaceInfo, ident: String) {
    _ = SLSManagedDisplaySetIsAnimating(cid, ident as CFString, true)
    SLSShowSpaces(cid, [NSNumber(value: dest)] as CFArray)
    // Hide every other space on the display, not just the one the (possibly
    // stale) bookkeeping claims is current — self-heals any earlier mismatch
    // that left two spaces composited at once.
    let others = info.ids.filter { $0 != dest }.map { NSNumber(value: $0) }
    SLSHideSpaces(cid, others as CFArray)
    _ = SLSManagedDisplaySetCurrentSpace(cid, ident as CFString, dest)
    _ = SLSManagedDisplaySetIsAnimating(cid, ident as CFString, false)
    if !skipActivation { activateLandingAppSoon(on: dest) }
}

// MARK: - Destination pre-warm (macOS 26 gesture path)

// TESTED, DOESN'T HELP (off by default, NOSWOOSH_PRIME=1 re-enables): showing
// the destination space via SLSShowSpaces before the gesture (mimicking the
// Dock's WillSwitchSpaces step) wedged identically at 0ms and 16ms lead time.
// Consistent with the root cause being surfaces DROPPED at commit teardown,
// not never built — a pre-warm can't survive the teardown.
// NOSWOOSH_PRIME_MS delays the gesture after the pre-warm (default 0).
let primeEnabled = !needsAugmentation
    && ProcessInfo.processInfo.environment["NOSWOOSH_PRIME"] == "1"
let primeDelayMS: Int = {
    if let raw = ProcessInfo.processInfo.environment["NOSWOOSH_PRIME_MS"],
       let ms = Int(raw) {
        return min(max(ms, 0), 500)
    }
    return 0
}()

// MARK: - Post-landing heal (macOS 26 gesture path)

// Experimental, off by default: attempts to repair a wedged landing after the
// fact. Results on 26.5.2 — none reliable: "show" does nothing; a guarded
// activation heals only when focus hadn't moved; even unguarded
// activate-all-windows left landings blank. Kept env-gated for future OS
// builds. Timing note: an activation racing the transition is itself a proven
// wedge trigger (the v1.5.1 regression), hence the enforced delay.
// NOSWOOSH_HEAL: activate (unguarded, orders all windows forward)
//   | raise (AXRaise the top landing-space window; no focus change)
//   | show (re-SLSShowSpaces) | off (default).
// NOSWOOSH_HEAL_MS: delay after the switch (default 200).
enum HealMode { case activate, raise, show, off }
let healMode: HealMode = {
    if needsAugmentation { return .off }
    switch ProcessInfo.processInfo.environment["NOSWOOSH_HEAL"] {
    case "activate": return .activate
    case "show": return .show
    case "raise": return .raise
    default: return .off
    }
}()
let healDelayMS: Int = {
    if let raw = ProcessInfo.processInfo.environment["NOSWOOSH_HEAL_MS"],
       let ms = Int(raw) {
        return min(max(ms, 50), 2000)
    }
    return 200
}()
var pendingHeal: DispatchWorkItem?
func scheduleHeal(on dest: UInt64) {
    if healMode == .off { return }
    pendingHeal?.cancel()
    let work = DispatchWorkItem {
        switch healMode {
        case .show:
            SLSShowSpaces(cid, [NSNumber(value: dest)] as CFArray)
        case .activate:
            guard let top = topWindow(onSpace: dest) else { return }
            NSRunningApplication(processIdentifier: top.pid)?
                .activate(options: [.activateAllWindows])
        case .raise:
            guard let top = topWindow(onSpace: dest) else { return }
            raiseWindow(number: top.num, ownerPID: top.pid)
        case .off:
            break
        }
    }
    pendingHeal = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(healDelayMS) / 1000.0, execute: work)
}

// MARK: - Switch core (both input sources call only this)

// The gesture commits asynchronously, so on rapid presses the space list can be
// stale. Trust our own prediction for a short window after a switch. macOS 27's
// list settles slower after a synthetic switch, so give it a wider window.
var predictedIndex: Int?
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
            events.append(aug)
        }
        events.forEach(postPair)
    } else if gestureDurationMS == 0 && gestureStyle == .iss {
        postIssSequence(right: right)
    } else if gestureDurationMS == 0 || gestureStyle == .zero {
        postDockSwipe(.began, right: right)
        postDockSwipe(.changed, right: right)
        postDockSwipe(.ended, right: right)
    } else if gestureInFlight {
        pendingSwitches.append(right)
    } else {
        postPacedDockSwipe(right: right)
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
    // While a paced gesture is in flight (or queued), the list definitely lags
    // our intent, so the prediction stays authoritative regardless of age.
    if let p = predictedIndex,
       gestureInFlight || !pendingSwitches.isEmpty
        || Date().timeIntervalSince(predictionTime) < predictionWindow {
        current = p
    }
    let target = current + (right ? 1 : -1)
    // Clamp at first/last space to avoid the rubber-band bounce animation
    // (on macOS 27 this also spares the Dock a swipe it would only reject).
    guard target >= 0, target < info.ids.count else { return }
    let dest = info.ids[target]
    if useDirectSwitch, let ident = info.displayIdent {
        directSwitch(to: dest, info: info, ident: ident)
    } else {
        if primeEnabled { SLSShowSpaces(cid, [NSNumber(value: dest)] as CFArray) }
        if primeEnabled && primeDelayMS > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(primeDelayMS) / 1000.0) {
                postSwitchGesture(right: right)
            }
        } else {
            postSwitchGesture(right: right)
        }
        scheduleHeal(on: dest)
    }
    predictedIndex = target
    predictionTime = Date()
}

// A real horizontal swipe's direction comes from progress/velocity sign. macOS
// 27 reversed it relative to the 26-era encoding (assumes a macOS 13+ SDK build).
func isRightSwipe(_ direction: Double) -> Bool {
    needsAugmentation ? direction < 0 : direction > 0
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
        // grace so the (possibly paced) gesture events flush before exit
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15 + Double(gestureDurationMS) / 1000.0))
        exit(0)
    case "setup":
        setCtrlArrowShortcuts(enabled: false)
        _ = runTool("/usr/bin/defaults", ["write", "com.apple.dock", "workspaces-auto-swoosh", "-bool", "NO"])
        _ = runTool("/usr/bin/killall", ["Dock"])
        print("""
        noswoosh setup complete:
          - system animated Ctrl+arrow shortcuts disabled (live + persisted)
          - Dock window-order space-follow disabled (empty-desktop yank fix; Dock restarted)
        Remaining: start the daemon (brew services start noswoosh, or the
        LaunchAgent from install.sh) and grant it Accessibility permission.
        """)
        exit(0)
    case "teardown":
        setCtrlArrowShortcuts(enabled: true)
        _ = runTool("/usr/bin/defaults", ["delete", "com.apple.dock", "workspaces-auto-swoosh"])
        _ = runTool("/usr/bin/killall", ["Dock"])
        print("noswoosh teardown complete: system Ctrl+arrow shortcuts re-enabled, Dock space-follow restored.")
        exit(0)
    case "version", "--version":
        print("noswoosh \(noswooshVersion)")
        exit(0)
    default:
        FileHandle.standardError.write("usage: noswoosh [left | right | list | setup | teardown | version]\n".data(using: .utf8)!)
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
app.setActivationPolicy(.prohibited)

// Input source 1: Ctrl+Left / Ctrl+Right hotkey.
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

for (id, keyCode) in [(UInt32(1), UInt32(kVK_LeftArrow)), (UInt32(2), UInt32(kVK_RightArrow))] {
    var ref: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: OSType(0x5350_5357), id: id) // 'SPSW'
    let status = RegisterEventHotKey(keyCode, UInt32(controlKey), hotKeyID,
                                     GetApplicationEventTarget(), 0, &ref)
    if status != noErr {
        log("could not register Ctrl+arrow hotkey (status \(status))")
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

    // Let our own synthetic events through without re-intercepting them
    // (tagged on the 26 path, counted pairs on the 27 path).
    if et == kCGSEventDockControl || et == kCGSEventGesture {
        if ev.getIntegerValueField(.eventSourceUserData) == noswooshEventTag {
            return pass
        }
        if passthrough > 0 {
            passthrough -= 1
            return pass
        }
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
