import Foundation

// MARK: - CLI modes

// Every branch exits, so the daemon path below the call site is only reached
// when noswoosh was invoked with no arguments at all.
func runCLIIfRequested() {
    let args = CommandLine.arguments
    guard args.count > 1 else { return }
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
        applySystemSetup()
        print("""
        noswoosh setup complete:
          - system animated Ctrl+arrow shortcuts disabled (live + persisted)
        Remaining: start the daemon (brew services start noswoosh, or the
        LaunchAgent from install.sh) and grant it Accessibility permission.
        """)
        exit(0)
    case "teardown":
        setCtrlArrowShortcuts(enabled: true)
        unregisterLoginItem()
        if appBundleURL != nil {
            print("noswoosh teardown complete: system Ctrl+arrow shortcuts re-enabled, login item removed.")
        } else {
            print("noswoosh teardown complete: system Ctrl+arrow shortcuts re-enabled.")
        }
        exit(0)
    case "version", "--version":
        print("noswoosh \(noswooshVersion)")
        exit(0)
    default:
        FileHandle.standardError.write("usage: noswoosh [left | right | list | setup | teardown | version]\n".data(using: .utf8)!)
        exit(1)
    }
}
