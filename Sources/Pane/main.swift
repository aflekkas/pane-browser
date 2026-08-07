// spec: §1
import AppKit
import PaneCore
import PaneUI
import PaneHarness

// argv -> normal | selftest. Kept tiny on purpose; everything real lives in a
// library target so it can be tested (ADR 0006).
let args = CommandLine.arguments

// Arm mutants BEFORE any mode branch. Parsing this inside --selftest meant
// --verify-download silently ignored it, and the quarantine mutant "escaped"
// while actually never being planted — the same false green the canary caught
// once already, wearing a different hat.
if let i = args.firstIndex(of: "--mutate"), i + 1 < args.count {
    Mutants.arm(args[i + 1])
}

if args.contains("--selftest") {
    // Needs a real run loop: scenarios drive WKWebViews and AppKit.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let json = args.contains("--json")
    Task { @MainActor in exit(await Harness.runSelfTest(json: json)) }
    app.run()
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

// spec §3 — milestone D's gate.
if args.contains("--verify-isolation") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await IsolationCheck.run()) }
    app.run()
}

if let i = args.firstIndex(of: "--verify-download"), i + 1 < args.count,
   let u = URL(string: args[i + 1]) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await DownloadCheck.run(url: u)) }
    app.run()
}

if args.contains("--bench-scroll") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let n = args.firstIndex(of: "--rows").map { Int(args[$0 + 1]) ?? 200 } ?? 200
    Task { @MainActor in exit(await ScrollBench.run(rows: n)) }
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
delegate.goldenScene = args.contains("--golden-scene")
delegate.restoreSession = !args.contains("--no-restore")
if let i = args.firstIndex(of: "--store"), i + 1 < args.count { delegate.storePath = args[i + 1] }
if let i = args.firstIndex(of: "--bench-discard"), i + 1 < args.count {
    delegate.benchDiscardTabs = Int(args[i + 1]); delegate.restoreSession = false
}
if let i = args.firstIndex(of: "--capture"), i + 1 < args.count {
    delegate.captureTo = args[i + 1]
    // The composite path needs no Screen Recording grant and no activation,
    // so the gate can run the bare binary with a terminal frontmost.
    delegate.onReadyForCapture = { w, path in await Capture.composite(w, to: path) }
}
app.delegate = delegate
app.run()
