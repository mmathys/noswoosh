import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// noswoosh — instant macOS space switching (verified on macOS 26.5).
//
//   noswoosh           daemon: Ctrl+Left / Ctrl+Right switch spaces instantly
//   noswoosh left      switch one space left and exit
//   noswoosh right     switch one space right and exit
//   noswoosh list      print current space / count
//   noswoosh empty     print which spaces have no windows
//
// How it works:
// - The switch is a synthetic Dock-swipe trackpad gesture (technique from
//   jurplel/InstantSpaceSwitcher, MIT) with near-zero progress and high
//   velocity: it runs through the Dock's own pipeline (state stays
//   consistent) but the animation has no distance to travel, so it is
//   instant. Posting events requires Accessibility permission.
// - Landing on a windowless space normally makes WindowServer promote the
//   last-active app to front process; that app re-orders its key window,
//   which lives on another space, and the Dock follows it there ("switching
//   to space N for window ordered on non-visible space"). To prevent that,
//   the daemon force-fronts ITSELF (it owns only an invisible holder window
//   present on every space) whenever the target space is empty.
// - The system's animated Ctrl+arrow shortcuts (symbolic hotkeys 79/81) must
//   be disabled or they consume the key combo first; this is persisted in
//   com.apple.symbolichotkeys.
//
// Rebuilding changes the ad-hoc code signature — re-grant Accessibility
// (System Settings > Privacy & Security) after every rebuild.
// Build: swiftc noswoosh.swift -O -o noswoosh \
//          -F /System/Library/PrivateFrameworks -framework SkyLight

// MARK: - Private SkyLight / process APIs

typealias CGSConnectionID = UInt32

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> CGSConnectionID

@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>

// mask 0x7 = all spaces (current + other + fullscreen)
@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?

struct PSN { var high: UInt32 = 0; var low: UInt32 = 0 }

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<PSN>) -> OSStatus

// Forces front-process status; normal cooperative activation is denied to
// background processes on macOS 14+.
@_silgen_name("_SLPSSetFrontProcessWithOptions")
func SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<PSN>, _ wid: UInt32, _ mode: UInt32) -> Int32

let kCPSUserGenerated: UInt32 = 0x200
let cid = SLSMainConnectionID()

// MARK: - Space bookkeeping

struct SpaceInfo { let ids: [UInt64]; let currentIndex: Int }

// Lists ALL spaces (desktops + fullscreen apps): the swipe gesture traverses
// fullscreen spaces too, so boundary math must include them.
func spaceInfo() -> SpaceInfo? {
    let displays = SLSCopyManagedDisplaySpaces(cid).takeRetainedValue() as! [[String: Any]]
    guard let display = displays.first,
          let spaces = display["Spaces"] as? [[String: Any]] else { return nil }
    let curID = ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? 0
    let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
    guard let currentIndex = ids.firstIndex(of: curID) else { return nil }
    return SpaceInfo(ids: ids, currentIndex: currentIndex)
}

func spaceHasWindows(_ spaceID: UInt64) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return true }
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              (w[kCGWindowOwnerPID as String] as? Int) != Int(getpid()),
              let wid = w[kCGWindowNumber as String] as? UInt32,
              let bounds = w[kCGWindowBounds as String] as? [String: Any],
              ((bounds["Width"] as? NSNumber)?.intValue ?? 0) > 40,
              ((bounds["Height"] as? NSNumber)?.intValue ?? 0) > 40 else { continue }
        if let arr = SLSCopySpacesForWindows(cid, 0x7, [NSNumber(value: wid)] as CFArray)?
            .takeRetainedValue() as? [NSNumber],
           arr.contains(where: { $0.uint64Value == spaceID }) {
            return true
        }
    }
    return false
}

// Cache of windowless spaces so the hotkey path reacts instantly (the
// per-window space lookup is too slow to run inline with a keypress).
var emptySpaces = Set<UInt64>()

func refreshEmptySpaces() {
    guard let info = spaceInfo() else { return }
    emptySpaces = Set(info.ids.filter { !spaceHasWindows($0) })
}

// MARK: - Holder window + front-process protection

// Borderless windows refuse key status by default; the holder must be able to
// take it when we force-front ourselves.
final class HolderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

var holderWindow: NSWindow?

func createHolderWindow() {
    let w = HolderWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                         styleMask: .borderless, backing: .buffered, defer: false)
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    w.backgroundColor = .black
    w.alphaValue = 0.01
    w.ignoresMouseEvents = true
    w.hasShadow = false
    w.level = .normal
    w.orderFrontRegardless()
    holderWindow = w
}

func forceFrontSelf() {
    var psn = PSN()
    guard GetProcessForPID(getpid(), &psn) == noErr else { return }
    let wid = UInt32(holderWindow?.windowNumber ?? 0)
    _ = SLPSSetFrontProcessWithOptions(&psn, wid, kCPSUserGenerated)
    holderWindow?.makeKey()
}

// If the target space is windowless, claim front-process status right after
// the switch so nobody else gets promoted and drags us away.
func protectLanding(targetID: UInt64) {
    guard holderWindow != nil, emptySpaces.contains(targetID) else { return }
    for delay in [0.03, 0.15, 0.3] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { forceFrontSelf() }
    }
}

// MARK: - Synthetic Dock-swipe gesture (undocumented CGEventFields)

let fieldCGSEventType   = unsafeBitCast(UInt32(55),  to: CGEventField.self)
let fieldGestureHIDType = unsafeBitCast(UInt32(110), to: CGEventField.self)
let fieldSwipeMotion    = unsafeBitCast(UInt32(123), to: CGEventField.self)
let fieldSwipeProgress  = unsafeBitCast(UInt32(124), to: CGEventField.self)
let fieldSwipeVelocityX = unsafeBitCast(UInt32(129), to: CGEventField.self)
let fieldSwipeVelocityY = unsafeBitCast(UInt32(130), to: CGEventField.self)
let fieldGesturePhase   = unsafeBitCast(UInt32(132), to: CGEventField.self)

let kCGSEventDockControl: Int64 = 30
let kIOHIDEventTypeDockSwipe: Int64 = 23
let kCGGestureMotionHorizontal: Int64 = 1
let gestureVelocity = 2000.0

enum GesturePhase: Int64 { case began = 1, changed = 2, ended = 4 }

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
    ev.post(tap: .cgSessionEventTap)
}

func postSwitchGesture(right: Bool) {
    // Must send all three phases; two-phase sequences break Mission Control.
    postDockSwipe(.began, right: right)
    postDockSwipe(.changed, right: right)
    postDockSwipe(.ended, right: right)
}

// MARK: - Switching

// The gesture commits asynchronously, so on rapid key presses the space list
// can be stale. Trust our own prediction for a short window after a switch.
var predictedIndex: Int?
var predictionTime = Date.distantPast

func switchSpace(right: Bool) {
    guard let info = spaceInfo() else {
        postSwitchGesture(right: right)
        return
    }
    var current = info.currentIndex
    if let p = predictedIndex, Date().timeIntervalSince(predictionTime) < 0.25 {
        current = p
    }
    let target = current + (right ? 1 : -1)
    // Clamp at first/last space to avoid the rubber-band bounce animation.
    guard target >= 0, target < info.ids.count else { return }
    postSwitchGesture(right: right)
    predictedIndex = target
    predictionTime = Date()
    protectLanding(targetID: info.ids[target])
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
    case "empty":
        refreshEmptySpaces()
        if let info = spaceInfo() {
            for (i, id) in info.ids.enumerated() where emptySpaces.contains(id) {
                print("space \(i + 1) (id64=\(id)) is empty")
            }
        }
        exit(0)
    case "left", "right":
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        createHolderWindow()
        refreshEmptySpaces()
        switchSpace(right: args[1] == "right")
        // Keep alive through the landing protection. Note: empty-space
        // protection only holds while a process lives — that is the daemon's
        // job; a CLI switch into an empty space may get yanked after exit.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        exit(0)
    default:
        FileHandle.standardError.write("usage: noswoosh [left | right | list | empty]\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - Daemon mode: global hotkeys Ctrl+Left / Ctrl+Right

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
    FileHandle.standardError.write("noswoosh: waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)\n".data(using: .utf8)!)
}

// .accessory (not .prohibited): required to own the holder window; the daemon
// stays invisible either way (no visible windows, no Dock icon).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
createHolderWindow()
refreshEmptySpaces()
Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in refreshEmptySpaces() }

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
        FileHandle.standardError.write("noswoosh: could not register Ctrl+arrow hotkey (status \(status))\n".data(using: .utf8)!)
    }
}

app.run()
