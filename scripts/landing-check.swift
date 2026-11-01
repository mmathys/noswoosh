// landing-check — films the display while switching spaces and reports, per switch,
// whether it landed BLACK and how long the visible transition took. This catches the
// two failures that an "it switched" assertion cannot: a switch that lands with the
// destination space never composited (macOS 27.0.1 at near-zero progress, issue #15),
// and a switch that lands but slides.
//
//   swiftc -O scripts/landing-check.swift -o /tmp/landing-check \
//       -F /System/Library/PrivateFrameworks -framework SkyLight
//   /tmp/landing-check RRRRRLLLLL 1100 4      # pattern, ms between presses, rounds
//
// Run with the daemon (or a build of it) running and the terminal granted Screen
// Recording. Presses go through osascript, the only way to reach the Carbon hotkey.
// Calibration on 27.0.1: native switching reports ~437ms transit / ~27 slide frames;
// an instant switch reports 0-20ms / 0-1. A BLACK landing is a settled frame with mean
// luma < 8 — fine for any real wallpaper, but a pure-black wallpaper will false-alarm.
// Start from the first space so the pattern walks the whole list.

import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSCopyManagedDisplaySpaces") func SLSCopyManagedDisplaySpaces(_ c: Int32) -> Unmanaged<CFArray>
let cid = SLSMainConnectionID()
func curSpace() -> UInt64 {
    let d = (SLSCopyManagedDisplaySpaces(cid).takeRetainedValue() as! [[String: Any]])[0]
    return ((d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0
}
func press(_ c: Character) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application \"System Events\" to key code \(c == "L" ? 123 : 124) using control down"]
    try? p.run()
}

let W = 64, H = 36
struct Frame { let t: Double; let px: [Float]; var mean: Float { px.reduce(0, +) / Float(px.count) } }
let lock = NSLock()
var frames: [Frame] = []
let clock0 = CACurrentMediaTime()

final class Out: NSObject, SCStreamOutput {
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // Skip frames the compositor marked idle/blank-duplicate: only .complete carries new pixels.
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = att.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        var px = [Float](repeating: 0, count: W * H)
        for y in 0..<H { for x in 0..<W {
            let p = base + y * bpr + x * 4   // BGRA
            px[y * W + x] = 0.114 * Float(p[0]) + 0.587 * Float(p[1]) + 0.299 * Float(p[2])
        } }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        let t = (CACurrentMediaTime() - clock0) * 1000
        lock.lock(); frames.append(Frame(t: t, px: px)); lock.unlock()
    }
}

let sem = DispatchSemaphore(value: 0)
var display: SCDisplay!
SCShareableContent.getWithCompletionHandler { c, _ in display = c!.displays.first!; sem.signal() }
sem.wait()
let cfg = SCStreamConfiguration()
cfg.width = W; cfg.height = H; cfg.pixelFormat = kCVPixelFormatType_32BGRA
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60); cfg.showsCursor = false; cfg.queueDepth = 8
let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
let out = Out()
try! stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "f"))
stream.startCapture { e in if let e { print("capture error \(e)"); exit(2) } ; sem.signal() }
sem.wait()

func dist(_ a: [Float], _ b: [Float]) -> Float {
    var s: Float = 0; for i in 0..<a.count { s += abs(a[i] - b[i]) }; return s / Float(a.count)
}
func avg(_ fs: [Frame]) -> [Float]? {
    guard !fs.isEmpty else { return nil }
    var r = [Float](repeating: 0, count: W * H)
    for f in fs { for i in 0..<r.count { r[i] += f.px[i] } }
    return r.map { $0 / Float(fs.count) }
}

let a = CommandLine.arguments
let pattern = Array(a.count > 1 ? a[1] : "RL")
let gapMs = a.count > 2 ? Double(a[2])! : 1500
let rounds = a.count > 3 ? Int(a[3])! : 5
Thread.sleep(forTimeInterval: 0.6)

var presses: [(t: Double, k: Character, from: UInt64)] = []
for _ in 0..<rounds { for k in pattern {
    presses.append(((CACurrentMediaTime() - clock0) * 1000, k, curSpace()))
    press(k)
    Thread.sleep(forTimeInterval: gapMs / 1000)
} }
stream.stopCapture { _ in sem.signal() }
sem.wait()

var transits: [Double] = [], inters: [Int] = [], blacks = 0
for (i, p) in presses.enumerated() {
    let next = i + 1 < presses.count ? presses[i + 1].t : p.t + gapMs
    let win = frames.filter { $0.t > p.t && $0.t < next }
    // A static screen produces no new frames, so "before" is the last frame up to the press.
    guard let pre = frames.last(where: { $0.t <= p.t })?.px,
          let post = avg(win.filter { $0.t > next - 250 }) ?? win.last?.px else { print("\(p.k) no frames"); continue }
    let span = dist(pre, post)
    let postMean = post.reduce(0, +) / Float(post.count)
    let isBlack = postMean < 8
    if isBlack { blacks += 1 }
    if span < 3 { print("\(p.k) from \(p.from): no visible change\(isBlack ? " BLACK" : "")"); continue }
    let thr = max(2, span * 0.15)
    let firstMove = win.first { dist($0.px, pre) > thr }
    let settled = win.first { dist($0.px, post) < thr }
    let inter = win.filter { dist($0.px, pre) > thr && dist($0.px, post) > thr }.count
    let transit = (settled?.t ?? .nan) - (firstMove?.t ?? .nan)
    transits.append(transit); inters.append(inter)
    print(String(format: "%@ from %llu: reacts %+.0fms, transit %.0fms, slide frames %d, post luma %.0f%@",
                 String(p.k), p.from, (firstMove?.t ?? .nan) - p.t, transit, inter, postMean, isBlack ? "  BLACK" : ""))
}
let st = transits.filter { !$0.isNaN }.sorted()
print(String(format: "SUMMARY n=%d black=%d transit_median=%.0fms transit_max=%.0fms slideframes_median=%d frames=%d",
             presses.count, blacks, st.isEmpty ? -1 : st[st.count / 2], st.last ?? -1,
             inters.sorted().isEmpty ? -1 : inters.sorted()[inters.count / 2], frames.count))
