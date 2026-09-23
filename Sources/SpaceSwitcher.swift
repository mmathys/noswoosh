import Cocoa

// MARK: - Switch core (every input source calls only this)

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
