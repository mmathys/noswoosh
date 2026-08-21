import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// noswoosh — instant macOS space switching (verified on macOS 26.5).
//
//   noswoosh            daemon: Ctrl+Left / Ctrl+Right switch spaces instantly
//   noswoosh setup      one-time system config (see below), needs no sudo
//   noswoosh teardown   undo the system config
//   noswoosh left       switch one space left and exit
//   noswoosh right      switch one space right and exit
//   noswoosh list       print current space / count
//   noswoosh version    print version
//
// How it works: the switch is a synthetic Dock-swipe trackpad gesture
// (technique from jurplel/InstantSpaceSwitcher, MIT) with near-zero progress
// and high velocity — it runs through the Dock's own pipeline (state stays
// consistent) but the animation has no distance to travel, so it is instant.
// Posting events requires Accessibility permission.
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
// Rebuilding changes the ad-hoc code signature — re-grant Accessibility
// (System Settings > Privacy & Security) after every rebuild.
// Build: swiftc noswoosh.swift -O -o noswoosh \
//          -F /System/Library/PrivateFrameworks -framework SkyLight

let noswooshVersion = "1.3.0"

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

let cid = SLSMainConnectionID()

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

// MARK: - Daemon mode: global hotkeys Ctrl+Left / Ctrl+Right

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
    FileHandle.standardError.write("noswoosh: waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)\n".data(using: .utf8)!)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

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
