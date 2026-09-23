import Foundation

// MARK: - Running other tools, and saying things out loud

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

// Like runTool, but returns captured stdout (nil on a nonzero exit).
func runToolOutput(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    // Drain before waiting, or a chatty tool fills the pipe and deadlocks both.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

func log(_ message: String) {
    FileHandle.standardError.write("noswoosh: \(message)\n".data(using: .utf8)!)
}
