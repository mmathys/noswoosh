import Foundation

// Enable/disable Mission Control's Ctrl+arrow symbolic hotkeys
// (79 = move left a space, 81 = move right a space).
//
//   ctrl-arrows          print live state
//   ctrl-arrows off      disable both — live (no logout) AND persisted
//   ctrl-arrows on       re-enable both — live AND persisted
//
// "Live" state is WindowServer's for this login session (private SkyLight
// API); "persisted" is com.apple.symbolichotkeys, which future sessions read.
// Both are needed: defaults alone doesn't affect the running session.
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

// hotkey ID -> arrow key code (left = 123, right = 124)
let hotKeys: [(id: Int32, keyCode: Int)] = [(79, 123), (81, 124)]

func persist(hotKey: Int32, keyCode: Int, enabled: Bool) -> Bool {
    let entry = "{enabled = \(enabled ? 1 : 0); value = { parameters = (65535, \(keyCode), 8650752); type = standard; };}"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys",
                         "-dict-add", String(hotKey), entry]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
switch arg {
case "on", "off":
    let enable = arg == "on"
    for hk in hotKeys {
        _ = setEnabled(hk.id, enable)
        let persisted = persist(hotKey: hk.id, keyCode: hk.keyCode, enabled: enable)
        print("hotkey \(hk.id): live-enabled = \(isEnabled(hk.id)), persisted = \(persisted ? "ok" : "FAILED")")
    }
case "":
    for hk in hotKeys {
        print("hotkey \(hk.id): live-enabled = \(isEnabled(hk.id))")
    }
default:
    FileHandle.standardError.write("usage: ctrl-arrows [on | off]\n".data(using: .utf8)!)
    exit(1)
}
