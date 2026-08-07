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

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
