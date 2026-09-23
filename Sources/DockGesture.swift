import Cocoa

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
    ev.setDoubleValueField(fieldSwipeProgress, value: (right ? -1e-4 : 1e-4) * postedSwipeSign)
    ev.setIntegerValueField(fieldSwipeMotion, value: kCGGestureMotionHorizontal)
    ev.setDoubleValueField(fieldSwipePositionX, value: 0.1)
    // A strong "fling" velocity on the terminal phase is what commits the switch.
    if phase == .ended {
        ev.setDoubleValueField(fieldSwipeVelocityX, value: (right ? -9999.0 : 9999.0) * postedSwipeSign)
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
