// spec: §5
import Foundation
import AppKit

/// Golden image comparison. Deliberately its own executable so the gate can run
/// it without launching the browser.
///
///   paneshot diff   <golden.png> <candidate.png>
///   paneshot accept <name> --diff-ratio <r> --reason "<why>"
///
/// Acceptance is expensive on purpose (harness design §7.10): there is no
/// auto-accept and no record mode. `--diff-ratio` must match the computed value,
/// so the diff must actually have been run, and `--reason` must be substantive.
/// The cheapest way to make a visual regression disappear should not be to
/// bless it.

func loadRGBA(_ path: String) -> (w: Int, h: Int, px: [UInt8])? {
    guard let data = FileManager.default.contents(atPath: path),
          let rep = NSBitmapImageRep(data: data) else { return nil }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let cg = rep.cgImage else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let base = ctx.data else { return nil }
    let buf = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
    return (w, h, Array(UnsafeBufferPointer(start: buf, count: w * h * 4)))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: paneshot diff <golden> <candidate> | accept <name> …") }

switch args[1] {
case "diff":
    guard args.count >= 4 else { fail("usage: paneshot diff <golden> <candidate> [--region x,y,w,h]") }
    guard let a = loadRGBA(args[2]) else { fail("cannot read golden \(args[2])") }
    guard let b = loadRGBA(args[3]) else { fail("cannot read candidate \(args[3])") }
    // Never rescale. A dimension change must surface as a hard failure, not as
    // a silently-resampled pass (§7.12).
    guard a.w == b.w, a.h == b.h else {
        fail("dimension mismatch: golden \(a.w)x\(a.h) vs candidate \(b.w)x\(b.h) — never rescaled")
    }
    // Optional region. Goldens diff OUR chrome, not the third-party page in
    // the content area: a live web page changes between runs, so including it
    // makes the golden fail against itself — which trains people to ignore the
    // check, the worst outcome available. WebKit's rendering is not what this
    // regression test is for.
    var rx = 0, ry = 0, rw = a.w, rh = a.h
    if let i = args.firstIndex(of: "--region"), i + 1 < args.count {
        let parts = args[i+1].split(separator: ",").compactMap { Int($0) }
        if parts.count == 4 { rx = parts[0]; ry = parts[1]; rw = parts[2]; rh = parts[3] }
    }
    rw = min(rw, a.w - rx); rh = min(rh, a.h - ry)
    guard rw > 0, rh > 0 else { fail("empty region") }

    var differing = 0
    let total = rw * rh
    for y in ry..<(ry + rh) {
      for x in rx..<(rx + rw) {
        let i = (y * a.w + x) * 4
        // Per-channel tolerance absorbs antialiasing without hiding a real
        // change: a moved row shifts far more than 8/255 on many pixels.
        let dr = abs(Int(a.px[i]) - Int(b.px[i]))
        let dg = abs(Int(a.px[i+1]) - Int(b.px[i+1]))
        let db = abs(Int(a.px[i+2]) - Int(b.px[i+2]))
        if dr > 8 || dg > 8 || db > 8 { differing += 1 }
      }
    }
    let ratio = Double(differing) / Double(total)
    let payload: [String: Any] = [
        "rec": "diff", "golden": args[2], "candidate": args[3],
        "region": "\(rx),\(ry),\(rw),\(rh)",
        "differing_px": differing, "total_px": total,
        "ratio": (ratio * 10000).rounded() / 10000,
        "pass": ratio < 0.002,
    ]
    let json = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(json); FileHandle.standardOutput.write(Data("\n".utf8))
    exit(ratio < 0.002 ? 0 : 1)

case "accept":
    guard args.count >= 2 else { fail("usage: paneshot accept <name> --diff-ratio <r> --reason <why>") }
    let name = args.count > 2 ? args[2] : ""
    var ratio: String?
    var reason: String?
    var i = 3
    while i + 1 < args.count {
        if args[i] == "--diff-ratio" { ratio = args[i+1] }
        if args[i] == "--reason" { reason = args[i+1] }
        i += 1
    }
    guard let ratio, let reason else {
        fail("accept requires --diff-ratio (so the diff was actually run) and --reason")
    }
    guard reason.count >= 20 else {
        fail("--reason must be at least 20 characters and describe the VISUAL change")
    }
    let stamp = ProcessInfo.processInfo.environment["PANE_ACCEPT_STAMP"] ?? "unstamped"
    let line = "\(stamp)  \(name)  ratio=\(ratio)  \(reason)\n"
    let log = URL(fileURLWithPath: "Goldens/ACCEPTED.log")
    if let fh = try? FileHandle(forWritingTo: log) {
        fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
    } else {
        try? line.write(to: log, atomically: true, encoding: .utf8)
    }
    print("accepted \(name)")

default:
    fail("unknown command \(args[1])")
}
