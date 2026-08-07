// spec: §1
import AppKit
import PaneUI
import PaneHarness

// argv -> normal | selftest. Kept tiny on purpose; everything real lives in a
// library target so it can be tested (ADR 0006).
let args = CommandLine.arguments

if args.contains("--selftest") {
    exit(Harness.runSelfTest())
}

// Milestone A's gate. Needs a real run loop, so it drives NSApplication rather
// than running as a plain CLI.
if args.contains("--bench-restore") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let fixture = URL(fileURLWithPath: "Fixtures/bench-page.html").standardizedFileURL
    let n = args.firstIndex(of: "--iterations").map { Int(args[$0 + 1]) ?? 20 } ?? 20
    Task { @MainActor in
        let code = await Bench.restore(iterations: n, fixture: fixture)
        exit(code)
    }
    app.run()
}

if args.contains("--drm-probe") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let fixture = URL(fileURLWithPath: "Fixtures/drm-probe.html").standardizedFileURL
    Task { @MainActor in exit(await DRMProbe.run(fixture: fixture)) }
    app.run()
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
delegate.seedDemoTabs = args.contains("--seed-demo")
if let i = args.firstIndex(of: "--capture"), i + 1 < args.count {
    delegate.captureTo = args[i + 1]
    delegate.onReadyForCapture = { w, path in Capture.windowByID(w, to: path) }
}
app.delegate = delegate
app.run()
