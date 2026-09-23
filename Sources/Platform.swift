import Foundation

// MARK: - macOS version gate

// Major version of the running OS — not the build SDK — or 0 if it can't be read.
// The IOHID payload gate below is the only thing that keys off this. (The yank guard
// used to as well, until 1.7.6 — see issue #15 for why that gate was wrong.)
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

// The macOS 27 posting sign is relative to "Natural scrolling" being ON
// (`com.apple.swipescrolldirection`, the default): with it OFF the Dock reads a
// posted swipe the other way round, so every switch goes backwards. Measured on a
// MacBook Air (M4) running 27.0 (26A428), toggling only this setting between runs:
//
//   natural ON   posting +1e-4 / +9999 -> one space LEFT,  -1e-4 / -9999 -> RIGHT
//   natural OFF  posting +1e-4 / +9999 -> one space RIGHT, -1e-4 / -9999 -> LEFT
//
// Only the posted sign moves. The reading side is right either way: with the setting
// off a rightward 3-finger swipe reports positive progress and natively lands one
// space right, with it on it reports negative and lands one space left — `isRightSwipe`
// maps both correctly, so it is deliberately left alone (see its comment).
//
// Gated to the 27 path: the pre-27 path is untested with the setting off.
let postedSwipeSign: Double = {
    guard needsAugmentation else { return 1 }
    let naturalScrolling = CFPreferencesCopyAppValue(
        "com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool ?? true
    return naturalScrolling ? 1 : -1
}()
