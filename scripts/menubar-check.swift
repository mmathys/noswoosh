// menubar-check — switches spaces back and forth and, after each switch settles,
// photographs the menu bar strip and prints its mean luma. This catches the failure
// in issue #9 that landing-check cannot: the space lands and its wallpaper and windows
// draw, but the menu bar is never composited (macOS 27.0 at near-zero progress).
//
//   swiftc -O scripts/menubar-check.swift -o /tmp/menubar-check
//   /tmp/menubar-check /path/to/noswoosh 16      # binary to drive, number of switches
//
// Each switch runs `<bin> right|left` directly, so no daemon is needed; the terminal
// needs Accessibility and Screen Recording. Use two spaces with different wallpapers,
// starting on the first. A healthy run alternates between two steady values, one per
// space, like `117 124 117 124`. A missing menu bar drops sharply toward black (#9
// measured 16 against a healthy ~45). Measure native switching first if you need a
// baseline for your wallpapers.

import Foundation
import CoreGraphics
import ImageIO

let a = CommandLine.arguments
guard a.count > 1 else {
    FileHandle.standardError.write("usage: menubar-check <noswoosh-binary> [switches]\n".data(using: .utf8)!)
    exit(1)
}
let bin = a[1]
let switches = a.count > 2 ? Int(a[2])! : 16
let shot = NSTemporaryDirectory() + "menubar-check.png"
// The menu bar strip in points: full main-display width, top 33pt (the 66px #9 used).
let strip = "0,0,\(Int(CGDisplayBounds(CGMainDisplayID()).width)),33"

func meanLuma(_ path: String) -> Double? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var sum = 0.0
    for i in stride(from: 0, to: buf.count, by: 4) {
        sum += 0.299 * Double(buf[i]) + 0.587 * Double(buf[i + 1]) + 0.114 * Double(buf[i + 2])
    }
    return sum / Double(w * h)
}

func run(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
}

var values: [String] = []
for i in 0..<switches {
    run(bin, [i % 2 == 0 ? "right" : "left"])
    Thread.sleep(forTimeInterval: 1.6)   // let the switch settle, as #9 measured it
    run("/usr/sbin/screencapture", ["-x", "-R", strip, shot])
    values.append(meanLuma(shot).map { String(format: "%.0f", $0) } ?? "?")
}
print(values.joined(separator: " "))
