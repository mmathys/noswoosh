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
// How it works: switching is a synthetic Dock-swipe gesture (technique from
// jurplel/InstantSpaceSwitcher, MIT) with near-zero progress and high velocity —
// it runs through the Dock's own pipeline (state stays consistent) but the
// animation has no distance to travel, so it is instant. Two input sources feed
// one switch core: a Ctrl+arrow hotkey, and an event tap that intercepts real
// 3-finger horizontal swipes and replaces them with the instant switch. Posting
// events requires Accessibility permission.
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

let noswooshVersion = "1.6.0"

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

// MARK: - Private SkyLight reads (space bookkeeping only)

typealias CGSConnectionID = UInt32

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> CGSConnectionID

@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>

@_silgen_name("SLSGetActiveSpace")
func SLSGetActiveSpace(_ cid: CGSConnectionID) -> UInt64

let cid = SLSMainConnectionID()

struct SpaceInfo { let ids: [UInt64]; let currentIndex: Int }

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
            return SpaceInfo(ids: ids, currentIndex: idx)
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

let kCGSEventGesture: Int64 = 29
let kCGSEventDockControl: Int64 = 30
let kIOHIDEventTypeDockSwipe: Int64 = 23
let kCGGestureMotionHorizontal: Int64 = 1
let kRawIOHIDPayloadTag: Int = 4205    // 0x106D — CGEvent field carrying the blob
let gestureVelocity = 2000.0

enum GesturePhase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

// Synthetic events we post re-enter our own event tap; the tap passes through
// exactly this many DockControl/gesture events untouched instead of acting on
// them. Every post below bumps this; the tap decrements. Harmless in CLI mode
// (no tap runs) since the process exits promptly.
var passthrough = 0

// MARK: pre-27 path (macOS 26) — bare Dock-swipe, near-zero progress

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
    passthrough += 1
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
    if let p = predictedIndex, Date().timeIntervalSince(predictionTime) < predictionWindow {
        current = p
    }
    let target = current + (right ? 1 : -1)
    // Clamp at first/last space to avoid the rubber-band bounce animation
    // (on macOS 27 this also spares the Dock a swipe it would only reject).
    guard target >= 0, target < info.ids.count else { return }
    postSwitchGesture(right: right)
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
        // brief grace so the gesture events flush before exit
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
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

    // Let our own synthetic events through without re-intercepting them.
    if passthrough > 0 && (et == kCGSEventDockControl || et == kCGSEventGesture) {
        passthrough -= 1
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
