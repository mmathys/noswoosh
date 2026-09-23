import Cocoa

// MARK: - Input source 2: intercepting real 3-finger swipes

// Intercept real 3-finger horizontal swipes and replace them with the instant
// switch. Direction is read from progress (Changed) or, for discrete swipes that
// skip Changed, velocity (Ended). Vertical swipes (Mission Control, App Exposé)
// and everything else pass through untouched.

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
//
// "Natural scrolling" mirrors the gesture itself, not this mapping: the same
// rightward 3-finger swipe reports +1.20 / +2.5 and lands one space right with the
// setting off, and -0.88 / -7.8 and lands one space left with it on (measured on
// 27.0, 26A428, passive tap). Both read correctly here, so `postedSwipeSign`
// corrects only the posting side.
func isRightSwipe(_ direction: Double) -> Bool {
    direction > 0
}

func applySwipe(_ on: Bool) {
    guard let tap = swipeTap else { return }   // not created yet, or no Accessibility
    CGEvent.tapEnable(tap: tap, enable: on)
    if !on { resetSwipeState() }
}

func setSwipeEnabled(_ on: Bool) {
    swipeEnabled = on
    UserDefaults.standard.set(on, forKey: Pref.swipe)
    applySwipe(on)
}

// Per-gesture tracking state, reset between gestures. `swipeTap` is held so
// Settings can enable and disable it without rebuilding it.
var swipeTracking = false
var swipeFired = false
var swipeTap: CFMachPort?

func resetSwipeState() { swipeTracking = false; swipeFired = false }

let swipeCallback: CGEventTapCallBack = { _, type, ev, _ in
    let pass = Unmanaged.passUnretained(ev)

    if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
        resetSwipeState()
        if swipeEnabled, AXIsProcessTrusted(), let t = swipeTap {
            CGEvent.tapEnable(tap: t, enable: true)
        }
        return pass
    }

    let et = ev.getIntegerValueField(fieldCGSEventType)

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
func installSwipeTap() {
    let swipeMask = (CGEventMask(1) << kCGSEventGesture) | (CGEventMask(1) << kCGSEventDockControl)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: swipeMask,
                                      callback: swipeCallback, userInfo: nil) else {
        // Fails when not (yet) trusted; the Accessibility poll restarts us once
        // granted, and the fresh process creates the tap successfully.
        log("could not create swipe event tap (Accessibility not granted yet?)")
        return
    }
    swipeTap = tap
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    // Created either way, enabled only if the user wants swipes: a tap that
    // exists but is disabled costs nothing and lets Settings flip it live.
    CGEvent.tapEnable(tap: tap, enable: swipeEnabled)
    // The callback re-enables the tap when the system disables it, but a disable
    // can arrive without a callback under load. Poll as a backstop so swipes never
    // silently die until the next relaunch.
    Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
        if swipeEnabled, AXIsProcessTrusted(), !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            log("re-enabled swipe event tap")
        }
    }
}
