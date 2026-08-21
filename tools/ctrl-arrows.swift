import Foundation

// Enable/disable the LIVE (WindowServer) state of Mission Control's
// Ctrl+arrow symbolic hotkeys (79 = move left a space, 81 = move right).
// The persisted state lives in com.apple.symbolichotkeys, but writing
// defaults alone does not affect the running session — this does.
//
//   ctrl-arrows          print live state
//   ctrl-arrows off      disable both (so spaceswitcher gets the keys)
//   ctrl-arrows on       re-enable both
//
// Build: swiftc ctrl-arrows.swift -o ctrl-arrows

typealias IsEnabledFn = @convention(c) (Int32) -> Bool
typealias SetEnabledFn = @convention(c) (Int32, Bool) -> Int32

guard let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
      let isEnabledPtr = dlsym(skylight, "SLSIsSymbolicHotKeyEnabled"),
      let setEnabledPtr = dlsym(skylight, "SLSSetSymbolicHotKeyEnabled") else {
    print("could not resolve SkyLight symbolic hotkey symbols")
    exit(1)
}

let isEnabled = unsafeBitCast(isEnabledPtr, to: IsEnabledFn.self)
let setEnabled = unsafeBitCast(setEnabledPtr, to: SetEnabledFn.self)

let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
for hotKey: Int32 in [79, 81] {
    if arg == "off" || arg == "on" {
        let err = setEnabled(hotKey, arg == "on")
        print("hotkey \(hotKey): set (err=\(err)), live-enabled now = \(isEnabled(hotKey))")
    } else {
        print("hotkey \(hotKey): live-enabled = \(isEnabled(hotKey))")
    }
}
