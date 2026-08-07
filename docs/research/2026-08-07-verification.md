# Research — self-verification harness

**Date:** 2026-08-07  
**Host:** macOS 26.5.2, Apple Silicon, Command Line Tools only (no Xcode at time of research)

Four probes (headless driving, visual capture, memory/perf, fixtures & tests)
followed by a design agent that merged them. **Not adversarially verified** —
treat load-bearing claims as one source deep.


---


## Probe: Driving a running AppKit app headlessly without Xcode

**Area:** Driving a running AppKit app programmatically/headlessly with no Xcode (macOS 26.5, Apple Silicon, Command Line Tools only) — for a Swift 6 / AppKit / WKWebView browser built with SPM + hand-rolled bundle script


### Techniques


**In-app `--selftest` scenario runner (PRIMARY)** — `solid`

Bake a mode into the real app binary. In `main.swift`: `let app = NSApplication.shared; let delegate = AppDelegate(selftest: CommandLine.arguments.contains("--selftest")); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()`.

In `applicationDidFinishLaunching`, when selftest is on:
```swift
Task { @MainActor in
  let r = await ScenarioRunner.runAll()          // real windows, real WKWebViews
  FileHandle.standardOutput.write(r.ndjson)      // one JSON object per scenario + a summary line
  exit(r.failures == 0 ? 0 : 1)
}
```
Run it: `.build/release/Pane --selftest --scenario tabs.close_restores_selection --json`.

Key mechanics:
- Swift concurrency's MainActor executor IS the main run loop, so `await` inside `Task { @MainActor }` interleaves with real AppKit event dispatch. Never block the main thread on a `DispatchSemaphore` waiting for a WKWebView callback — that deadlocks.
- Bridge delegates to async: `await withCheckedContinuation { c in pendingLoad = c }` resumed in `webView(_:didFinish:)`; race it against `Task.sleep` for a timeout.
- Manual pump helper when you need to drain events synchronously: `while let e = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) { NSApp.sendEvent(e) }`.
- Watchdog inside the app (there is NO `/usr/bin/timeout` on macOS — verified): `DispatchQueue.global().asyncAfter(deadline: .now() + 120) { FileHandle.standardError.write("SELFTEST TIMEOUT".data(using:.utf8)!); _exit(70) }`.
- Assert the window is genuinely rendering before trusting any web assertion: `precondition(window.occlusionState.contains(.visible))`, `precondition(webView.window != nil)`.
- Serve deterministic fixtures from `python3 -m http.server` (python3 present) or an in-process `NWListener` so tests never touch the network.

Source: https://developer.apple.com/documentation/appkit/nsapplication/nextevent(matching:until:inmode:dequeue:)


**Verify swift-testing works from Command Line Tools; XCTest does NOT** — `solid`

HARD FACT, verified on this machine:
- `/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework` EXISTS (plus `_Testing_AppKit.framework`, `_Testing_Foundation.framework`, `_Testing_CoreGraphics.framework`).
- `/Library/Developer/CommandLineTools/usr/libexec/swift/pm/swiftpm-testing-helper` EXISTS.
- `swift test --help` exposes `--enable-swift-testing/--disable-swift-testing` and `--enable-xctest/--disable-xctest`.
- `XCTest.framework` does NOT exist anywhere: not in `/System/Library/Frameworks`, not in the CLT SDKs, not in CLT `Library/Developer/Frameworks`. `xcrun --find xctest` → `error: unable to find utility "xctest"`. `/Library/Developer/CommandLineTools/Platforms` does not exist.

So: `import Testing` + `swift test --disable-xctest --enable-swift-testing --parallel` works with CLT only. `import XCTest` will fail to build.

Use this for the pure-logic half of Pane: URL normalization, tab/session model, keybinding tables, history store, cookie policy, download naming. Do NOT try to put AppKit UI driving here — a `swift test` bundle has no `NSApplication` running and no main run loop you control.

Source: https://github.com/swiftlang/swift-testing


**XCUITest / XCTest UI automation via `swift test`** — `last-resort` · **NEEDS XCODE**

NOT POSSIBLE. Do not attempt. XCUITest requires (a) `XCTest.framework` — absent under CLT (verified above), (b) `XCUIApplication`/`XCTAutomationSupport`, (c) a generated UI-test *runner app* bundle that `xcodebuild` builds and installs, and (d) `xcodebuild test` to launch that runner and connect it to the target process over the automation session. SwiftPM has no notion of a UI-test target or a test runner app; `swift test` runs an in-process test bundle only. Even on a machine WITH Xcode, `swift test` cannot run XCUITests. The honest answer to the brief is: skip this entirely.

Source: https://forums.swift.org/t/how-do-you-ui-test-a-swift-package/49890


**In-process accessibility-tree dump (NSAccessibility protocol) — no TCC at all** — `solid`

This is the piece most people miss. You do NOT need the AX C API or any TCC permission to read your OWN accessibility tree — `NSAccessibility` is the in-process protocol implemented by every `NSView`/`NSCell`. Walk it directly:
```swift
func dump(_ e: Any) -> [String: Any] {
  let o = e as AnyObject
  return [
    "role": (o.accessibilityRole()?.rawValue) ?? "",
    "subrole": (o.accessibilitySubrole()?.rawValue) ?? "",
    "title": o.accessibilityTitle() ?? "",
    "value": String(describing: o.accessibilityValue() ?? ""),
    "identifier": o.accessibilityIdentifier() ?? "",
    "selected": o.isAccessibilitySelected(),
    "frame": NSStringFromRect(o.accessibilityFrame()),
    "children": (o.accessibilityChildren() ?? []).map(dump)
  ]
}
// root: NSApp.accessibilityWindows() ?? NSApp.windows.map { $0 as Any }
```
Also `NSAccessibilityUnignoredDescendant(view)` to skip ignored wrappers, and `accessibilityPerformPress()` / `accessibilityPerformShowMenu()` to actuate elements the same way VoiceOver would.

Emit this tree as JSON from `--selftest --dump-ax` and snapshot-diff it in CI. It gives you the sidebar outline structure, row titles, selection state and disclosure state for free, AND it forces you to actually set `accessibilityIdentifier` on your sidebar rows — which makes Pane accessible as a side effect.

Source: https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol


**Synthetic AppKit events in-process via NSApp.sendEvent / postEvent — no TCC** — `solid`

To exercise the REAL AppKit event path (hit testing, responder chain, tracking loops, `mouseDown`/`keyDown` overrides, `performKeyEquivalent`) without any permission:
```swift
let p = view.convert(NSPoint(x: 8, y: 8), to: nil)   // window coords
let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [],
  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
NSApp.sendEvent(down)            // synchronous, goes through NSWindow.sendEvent → responder chain
NSApp.sendEvent(up)

let key = NSEvent.keyboardEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
  context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false,
  keyCode: 0x11)!
if !(window.performKeyEquivalent(with: key)) { NSApp.sendEvent(key) }
```
Use `NSApp.postEvent(_:atStart:)` when you need the event to go through the queue instead (e.g. to break a modal tracking loop). For menus, prefer `NSApp.sendAction(#selector(...), to: nil, from: menuItem)` or `menuItem.menu?.performActionForItem(at:)` — synthetic clicks into `NSMenu` run a nested tracking run loop and will hang a scripted test.

Caveat: `sendEvent` bypasses the window server, so it will NOT reproduce bugs that live in event *routing* by the window server (cross-window click-through, real focus/key-window transitions). Treat as high-coverage, not total.

Source: https://developer.apple.com/documentation/appkit/nsapplication/postevent(_:atstart:)


**Pixel-level proof: WKWebView.takeSnapshot + NSView.cacheDisplay (in-process, no Screen Recording TCC)** — `solid`

`screencapture`/`CGWindowListCreateImage` need the Screen Recording TCC grant (and macOS 15+ re-prompts weekly, macOS 26 renamed the pane to "Screen & System Audio Recording"). Avoid both. Capture in-process instead — zero permissions:

Chrome/native UI:
```swift
let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
view.cacheDisplay(in: view.bounds, to: rep)
try rep.representation(using: .png, properties: [:])!.write(to: url)
```
Web content (cacheDisplay/`layer.render(in:)` return BLANK for WKWebView — content is composited out-of-process):
```swift
let cfg = WKSnapshotConfiguration()
cfg.rect = webView.bounds
cfg.afterScreenUpdates = false   // true is a known hang/blank source
let img = try await webView.takeSnapshot(configuration: cfg)
```
Then compare against a golden PNG with a tolerance (mean abs diff over `NSBitmapImageRep` samples) so antialiasing noise doesn't cause false failures. Save both actual and diff PNGs into an artifacts dir the agent can re-read.

Source: https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot(configuration:completionhandler:)


**Offscreen / no-visible-window operation — what actually works** — `flaky`

Ranked by how much it breaks:

1. BEST for full fidelity: real on-screen window, `NSApp.setActivationPolicy(.regular)`, `window.orderFrontRegardless()`, `NSApp.activate(ignoringOtherApps: true)`. Add `--selftest` runtime assertion `window.occlusionState.contains(.visible)`.
2. Hide from Dock/⌘-Tab but keep rendering: `NSApp.setActivationPolicy(.accessory)` (or `LSUIElement` in Info.plist) with the window still ordered in. Rendering still works; the window is real, just the app has no Dock tile. `.prohibited` cannot show windows — do not use.
3. Move the window off the visible display: AppKit's `constrainFrameRect(_:to:)` will drag it back onto a screen; you must subclass `NSWindow` and `override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r }`. But once fully off-screen, `occlusionState` loses `.visible` → WebKit marks the page non-visible → `requestAnimationFrame` stops, DOM timers throttle to ~1 Hz, `document.visibilityState === "hidden"`, and `takeSnapshot` can return blank or never call back.
4. Zero-size WKWebView still in the hierarchy: `WKWebView(frame: .zero)` added as a subview of a real window. Loading, `navigationDelegate` callbacks and `evaluateJavaScript` work reliably; layout/paint do not. Good for network/JS/cookie/history scenarios, useless for visual ones.
5. `orderOut(nil)` / `alphaValue = 0` / no window at all: WebKit throttles or never paints. `takeSnapshot` hangs with no error and no image. Documented repeatedly on Apple forums; an Apple engineer never offered a fix.

There is no virtual-display CLI in Command Line Tools. Creating one needs third-party (BetterDisplay, `displayplacer` for layout only) or a Screen Sharing/VNC login to materialise a framebuffer on a headless Mac.

Source: https://developer.apple.com/forums/thread/710015


**External driving via AXUIElement (AXUIElementCreateApplication / CopyAttributeValue / PerformAction kAXPressAction)** — `flaky`

Technically what you asked about, practically a trap for an unattended agent.

API shape:
```swift
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)
var wins: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins)
// recurse kAXChildrenAttribute; match kAXRoleAttribute == kAXRowRole / kAXOutlineRole,
// kAXTitleAttribute, kAXIdentifierAttribute
AXUIElementPerformAction(row, kAXPressAction as CFString)
AXUIElementSetAttributeValue(outline, kAXSelectedRowsAttribute as CFString, rows)
```
Gate check: `AXIsProcessTrusted()`; prompt with `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)`. Settings pane: `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`.

Permission reality (HARD FACT, verified locally on this machine):
- SIP is ENABLED (`csrutil status: enabled`).
- `ls "/Library/Application Support/com.apple.TCC/"` → **Operation not permitted**. `ls "$HOME/Library/Application Support/com.apple.TCC/"` → **Operation not permitted**. `sqlite3 ~/.../TCC.db "select ..."` → **authorization denied**. So you cannot read, let alone write, the TCC DB.
- `/usr/bin/tccutil` supports only `reset` (revoke), never `grant`. `sudo tccutil reset Accessibility com.you.Pane` clears; nothing grants.
- There is no API or CLI to grant Accessibility. The only path is a human clicking the toggle in System Settings.

So: a human must grant it once, and the grant is fragile (see pitfalls re: ad-hoc signing and the responsible-process rule). Use AX only as an optional, skippable tier that the selftest reports as SKIPPED when `AXIsProcessTrusted()` is false — never as the gate on "did my build work".

Source: https://developer.apple.com/documentation/applicationservices/axuielement_h


**Synthetic system-level events: CGEventPost / cliclick** — `flaky`

`CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cgSessionEventTap)` — or `brew install cliclick` then `cliclick c:400,300 kd:cmd t:l ku:cmd`.

Requires the `kTCCServicePostEvent` grant, which surfaces in the SAME "Accessibility" list in System Settings but is a DISTINCT service from `kTCCServiceAccessibility` used by AXUIElement — an app can hold one and not the other. Same manual-grant-only constraint as above.

Additional problems for unattended use: coordinates are global screen space in a flipped coordinate system (`CGEvent` uses top-left origin, AppKit uses bottom-left — convert with `screen.frame.maxY - point.y`); the target app must actually be frontmost or clicks land on whatever is; the real mouse cursor moves, so any concurrent human activity corrupts the run; and there is no synchronisation — you are inserting `sleep`s and hoping.

Use only for the handful of scenarios genuinely unreachable in-process (real drag-and-drop between windows, native menu bar tracking).

Source: https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html


**osascript / AppleScript System Events UI scripting** — `last-resort`

`osascript -e 'tell application "System Events" to tell process "Pane" to click button 1 of window 1'`.

Double TCC gate: the calling process needs Automation/Apple Events permission for `System Events` (`kTCCServiceAppleEvents`, prompt "X wants to control System Events"), AND System Events itself needs `kTCCServiceAccessibility`. Both prompts are modal and BLOCK `osascript` indefinitely if nobody clicks — which will silently hang an unattended agent run forever. If you ever call this, wrap it: `osascript -e 'with timeout of 10 seconds ...'` plus an external kill.

Useful non-UI-scripting subset that needs NO permission: your own app can register an `NSAppleEventDescriptor` handler or expose an `sdef`, and `osascript -e 'tell application "Pane" to ...'` targeting *your own* app still needs Automation consent from the caller. Prefer a plain CLI arg or a Unix-socket control channel instead.

Source: https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-tcc/index.html


**Control socket / IPC channel into the running app (scriptability without TCC)** — `solid`

Rather than driving the app from outside via the window server, let the app expose a local control channel and drive it with `nc`/`curl`/a tiny Swift client. No TCC, no window server, fully deterministic:

- `--control-socket /tmp/pane.sock` → in-app `NWListener(using: .tcp, on: ...)` or a `Network.framework` unix-domain listener; commands are NDJSON (`{"cmd":"open_tab","url":"..."}` → `{"ok":true,"tabs":3}`).
- Every command is dispatched on the MainActor and performs the *same* action the UI action performs (share the command layer between the menu item, the keybinding and the socket). That way scripted coverage is real coverage.
- This is exactly how a `--selftest` scenario can be driven interactively while the agent watches, and it makes an ad-hoc REPL possible: `echo '{"cmd":"screenshot"}' | nc -U /tmp/pane.sock`.

Guard it behind a debug build flag or a `--control-socket` opt-in so shipping Pane doesn't expose it.

Source: https://developer.apple.com/documentation/network/nwlistener


**CI: GitHub Actions macOS runner** — `solid`

YES, this works — and CI is strictly MORE capable than this local machine.

- GitHub-hosted macOS runners run under VMware vSphere with an **emulated display** (maintainer confirmed), so GUI apps launch and render; `displayplacer list` reports a real (small, ~1176x885 / up to 2560x1600) display. Vertical resolution above 1600 is not settable.
- Xcode IS preinstalled on the hosted images, so `xcodebuild` and `XCTest.framework` exist there even though they don't here. You can therefore run the SAME `--selftest` binary in CI plus, optionally, real XCUITests — but do not make the repo depend on that, or local runs diverge from CI.
- Accessibility TCC on the runner is still the blocker for AX-based driving: the system TCC DB is SIP-protected, and SIP is disabled only on the (long-EOL) macOS 13 image. Assume you cannot grant `kTCCServiceAccessibility` on modern images.

Workflow shape:
```yaml
runs-on: macos-15
steps:
  - uses: actions/checkout@v4
  - run: swift build -c release
  - run: swift test --disable-xctest --enable-swift-testing --parallel
  - run: ./Scripts/bundle.sh          # your hand-rolled .app packaging
  - run: ./build/Pane.app/Contents/MacOS/Pane --selftest --json | tee selftest.ndjson
  - uses: actions/upload-artifact@v4
    if: always()
    with: { name: selftest-artifacts, path: 'artifacts/**' }
```
No `xvfb`, no display setup action needed on macOS.

Source: https://github.com/actions/runner-images/discussions/5730


**Stable code-signing identity so any TCC grant survives rebuilds** — `flaky`

If you do decide to use any TCC-gated technique, an ad-hoc signature (`codesign -s -`) produces a NEW cdhash every build, and TCC stores the grant against the code-signing requirement (`csreq`) — so every single rebuild silently revokes the grant and the app stops working with no error. For an agent rebuilding 50x/day this is fatal.

Fix: create a self-signed code-signing certificate once in the login keychain and sign with it, giving a stable identity across rebuilds:
```bash
security find-identity -v -p codesigning        # list what you have
codesign --force --deep --options runtime \
  --sign "Pane Dev Self-Signed" build/Pane.app
codesign -dv --verbose=4 build/Pane.app 2>&1 | grep -E 'Identifier|TeamIdentifier|Signature'
```
Also keep the `.app` at a STABLE absolute path — TCC records the path too, and moving the bundle can drop the grant.

Source: https://evoleinik.com/posts/macos-dev-signing-preserve-permissions/


**Diagnosing hangs and crashes with no Instruments** — `solid`

Verified present in Command Line Tools on this machine: `/usr/bin/sample`, `/usr/bin/leaks`, `/usr/bin/heap`, `/usr/bin/vmmap`, `/usr/sbin/spindump`, `/usr/bin/ktrace`, `/usr/bin/fs_usage`, `lldb` (2100.0.17.203). `instruments` is NOT present.

Hang triage (the #1 failure mode of a scripted AppKit run):
```bash
sample Pane 5 -file /tmp/pane.sample.txt      # 5s stack sample, no permission needed for own process
lldb -p $(pgrep -x Pane) --batch -o "thread backtrace all" -o detach
spindump -notarget Pane 5 -file /tmp/pane.spin.txt   # needs sudo
```
Leaks/retain-cycle regression check (real substitute for the Leaks instrument), runnable in CI:
```bash
MallocStackLogging=1 ./Pane --selftest & PID=$!; sleep 20; leaks $PID --quiet; kill $PID
```
Logs and crashes: `log show --last 5m --predicate 'process == "Pane"' --info --debug`, `log stream --predicate 'subsystem == "com.you.pane"'`, crash reports in `~/Library/Logs/DiagnosticReports/Pane-*.ips` (parse the JSON, it has the full symbolicated-ish thread state). Have the selftest script always dump the newest `.ips` on nonzero exit.

Note there is NO `/usr/bin/timeout` and no `gtimeout` (verified) — either `brew install coreutils` or build the watchdog into the app.

Source: https://keith.github.io/xcode-man-pages/sample.1.html


### Recommended

Make `--selftest` the load-bearing contract and treat everything TCC-gated as optional garnish.

Structure it as three tiers the agent runs in order, each with its own exit code:

Tier 1 — `swift test --disable-xctest --enable-swift-testing --parallel`. Verified to work with Command Line Tools alone: `Testing.framework` and `swiftpm-testing-helper` ship in CLT; `XCTest.framework` does not exist anywhere on the box. Put URL parsing, tab/session model, keybinding tables, history and download naming here. Fast, hermetic, no display.

Tier 2 — `Pane --selftest --json`, the same shipped binary. `NSApplication.shared.run()` with a real `NSWindow` ordered front and `.regular` activation policy, scenarios driven from `Task { @MainActor in ... }` so `await` interleaves with genuine AppKit event dispatch. Drive UI three ways, cheapest first: (a) call the shared command layer that menus/keybindings also call; (b) synthesize `NSEvent.mouseEvent`/`keyboardEvent` and push through `NSApp.sendEvent` to exercise real hit-testing and the responder chain; (c) assert on the in-process `NSAccessibility` tree (`accessibilityChildren()`, `accessibilityRole()`, `accessibilityIdentifier()`, `isAccessibilitySelected()`) serialized to JSON. None of this needs any permission, and (c) forces you to give sidebar rows real accessibility identifiers.

Assert web state via `evaluateJavaScript` against real WKWebViews loading fixtures from a loopback `python3 -m http.server`. Prove pixels with `webView.takeSnapshot(configuration:)` (`afterScreenUpdates = false`) and `view.cacheDisplay(in:to:)` — never `screencapture`, which needs Screen Recording TCC and re-prompts.

Two non-negotiable guards inside the harness: a `_exit(70)` watchdog (macOS has no `timeout`), and `precondition(window.occlusionState.contains(.visible) && webView.window != nil)` before any visual assertion — otherwise WebKit throttles rAF/timers, `document.visibilityState` goes `hidden`, and `takeSnapshot` silently returns blank or hangs, and you will "pass" tests against a webview that never painted.

Emit NDJSON on stdout, logs on stderr, artifacts (snapshots, AX dumps, diffs) to a fixed directory, exit nonzero on any failure.

Tier 3 — optional AX/CGEvent driving, auto-SKIPPED when `AXIsProcessTrusted()` is false. Never gate the build on it.

Same three commands run unchanged on `macos-15` GitHub Actions runners, which have an emulated display.


### Pitfalls

- XCUITest is flatly impossible here. Verified: no `XCTest.framework` in `/System/Library/Frameworks`, in the CLT SDKs, or in CLT `Library/Developer/Frameworks`; `xcrun --find xctest` errors; `/Library/Developer/CommandLineTools/Platforms` does not exist. `import XCTest` will not even compile. XCUITest additionally needs a generated runner-app bundle that only `xcodebuild` produces — `swift test` cannot run UI tests even on a machine with Xcode. Use `import Testing` (swift-testing), which IS present in CLT.
- Accessibility permission cannot be granted non-interactively, full stop. Verified on this machine: SIP is enabled; `ls "/Library/Application Support/com.apple.TCC/"` and `ls "$HOME/Library/Application Support/com.apple.TCC/"` both return `Operation not permitted`; `sqlite3` on the user TCC.db returns `authorization denied`. `/usr/bin/tccutil` only supports `reset` (revoke), never grant. `AXIsProcessTrustedWithOptions` can only prompt a human. Any design that assumes the agent can self-grant AX will deadlock on a modal dialog nobody clicks.
- `kTCCServiceAccessibility` (AXUIElement) and `kTCCServicePostEvent` (CGEvent.post) are DIFFERENT TCC services that both render as one "Accessibility" row in System Settings. Holding one does not grant the other, so an app can pass `AXIsProcessTrusted()` and still have `CGEvent.post` silently no-op.
- Ad-hoc signing (`codesign -s -`) makes every rebuild a new cdhash, and TCC keys grants to the code-signing requirement. An agent that rebuilds constantly will silently lose any granted permission on the very next build, with NO error — just calls that quietly do nothing. Sign with a stable self-signed identity from the login keychain and keep the `.app` at a fixed absolute path (TCC records path too).
- TCC attribution follows the 'responsible process', not the immediate process. Launching `Pane.app/Contents/MacOS/Pane` directly from a shell makes the TERMINAL the responsible process (so the terminal's grants apply and prompts name the terminal), whereas `open -a Pane.app` makes Pane itself responsible. The two launch styles have different permission behaviour — pick one and be consistent, or you'll chase a phantom regression.
- A WKWebView that is not in a visible, non-occluded window does not paint. WebKit gates on `NSWindow.occlusionState & NSWindowOcclusionStateVisible`: lose it and requestAnimationFrame stops, DOM timers throttle to ~1 Hz, `document.visibilityState` becomes `hidden`, and `takeSnapshot` returns blank or never calls its completion handler with no error. Apple has never shipped a public way to force offscreen rendering (confirmed in Apple forum thread 710015 with no engineer rebuttal). Assert `occlusionState.contains(.visible)` at runtime rather than discovering this as a mystery flake.
- `orderOut(nil)`, `alphaValue = 0`, and a webview with no window at all are all silently broken for rendering. Moving a window off-screen also fails unless you subclass `NSWindow` and `override constrainFrameRect(_:to:) { r }` — and even then you lose `.visible` occlusion state, so you gain nothing.
- `view.cacheDisplay(in:to:)` and `layer.render(in:)` return BLANK for WKWebView content — it is composited out-of-process. Only `takeSnapshot(configuration:)` captures web pixels. Set `WKSnapshotConfiguration.afterScreenUpdates = false`; `true` is a documented source of hangs and blank images.
- Blocking the main thread on a `DispatchSemaphore` while waiting for a WKWebView navigation, `evaluateJavaScript`, or `takeSnapshot` callback is an instant deadlock — those callbacks are delivered on the main run loop you just stopped. Use `async`/`await` on the MainActor (whose executor IS the main run loop) or pump with `NSApp.nextEvent(matching:until:inMode:dequeue:)` + `NSApp.sendEvent`.
- There is no `/usr/bin/timeout` and no `gtimeout` on this machine (verified). A hung selftest will hang the agent forever. Build a watchdog into the app (`DispatchQueue.global().asyncAfter { _exit(70) }`) rather than relying on the shell, and on timeout dump `sample <pid> 5` before exiting.
- Synthetic clicks into `NSMenu` spin a nested tracking run loop that will never return control to your scripted scenario. Drive menus via `NSApp.sendAction(_:to:from:)` or `menu.performActionForItem(at:)` instead. The same applies to `NSAlert.runModal`, sheets, and `NSOpenPanel` — a scripted run must stub or auto-dismiss them, or it hangs.
- `osascript -e 'tell application "System Events" ...'` needs TWO grants (Automation for the caller, Accessibility for System Events) and both prompts are modal and blocking. In an unattended run this hangs indefinitely. If used at all, wrap in `with timeout of N seconds` plus an external kill.
- `NSApp.sendEvent` bypasses the window server, so it will not reproduce window-server-level bugs: cross-window click-through, real key-window/focus transitions, or genuine drag-and-drop between windows. Know which class of bug your green tests cannot catch.
- `NSApplication.ActivationPolicy.prohibited` cannot display windows at all. Use `.accessory` (or `LSUIElement`) if you want to hide the Dock tile while still rendering; `.regular` + `NSApp.activate(ignoringOtherApps: true)` if you need reliable key-window behaviour.
- `NSAccessibility` is for exposing YOUR app's tree; `AXUIElement` is for reading OTHER apps'. Don't reach for the AX C API (and its TCC gate) to inspect your own process — walk `NSAccessibility` in-process instead. If you ever do call `AXUIElementCopyAttributeValue` against your own pid, do it off the main thread with `AXUIElementSetMessagingTimeout` set, since the AX call is a synchronous round-trip that your own main thread must service.
- On GitHub-hosted runners you cannot grant Accessibility either — the system TCC DB is SIP-protected and SIP is disabled only on the ancient macOS 13 image. Don't build a CI plan around `sqlite3` inserts into TCC.db; the blog posts describing that are stale. Also note vertical resolution is capped at 1600px, so golden-image tests must not assume a large display.
- Xcode IS present on hosted runners but NOT locally. If you let CI use `xcodebuild`/XCTest, local and CI stop testing the same thing and the agent loses its ability to reproduce a CI failure. Keep CI running the identical three commands the agent runs locally.
- `screencapture` and `CGWindowListCreateImage` require the Screen Recording grant, macOS 15+ re-prompts weekly, and macOS 26.1 changed attribution for background/helper executables (Apple forum 807323). Never put them on the critical path of an automated check — capture in-process instead.

## Probe: Visual verification — capturing and checking what the UI looks like

**Area:** Capturing and verifying what Pane's UI actually looks like, so an autonomous agent can inspect and regression-test it


### Techniques


**ScreenCaptureKit self-capture (SCShareableContent.currentProcess) — NO TCC, captures WKWebView pixels** — `solid`

HARD FACT (read from the CLT SDK header /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/ScreenCaptureKit.framework/Headers/SCShareableContent.h line ~150): `+getCurrentProcessShareableContentWithCompletionHandler:` doc comment reads "...windows, displays and applications that are available to capture by current process WITHOUT USER CONSENT VIA TCC". API_AVAILABLE(macos(14.4)), Swift name `SCShareableContent.currentProcess`.

In-app debug code (compile into Pane behind a `PANE_HARNESS` flag):
```swift
import ScreenCaptureKit
@available(macOS 14.4, *)
func snap(_ win: NSWindow) async throws -> CGImage {
  let c = try await SCShareableContent.currentProcess          // no TCC prompt
  guard let w = c.windows.first(where: { $0.windowID == CGWindowID(win.windowNumber) })
  else { throw NSError(domain:"pane",code:1) }
  let f = SCContentFilter(desktopIndependentWindow: w)          // window content, ignores occluders
  let cfg = SCStreamConfiguration()
  cfg.width  = Int(f.contentRect.width  * CGFloat(f.pointPixelScale))
  cfg.height = Int(f.contentRect.height * CGFloat(f.pointPixelScale))
  cfg.scalesToFit = false
  cfg.showsCursor = false
  cfg.ignoreShadowsSingleWindow = true                          // macOS 14.0
  cfg.captureResolution = .best                                 // macOS 14.0
  cfg.colorSpaceName = CGColorSpace.sRGB                        // determinism
  cfg.includeChildWindows = true                                // macOS 14.2 (sheets/popovers)
  return try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
}
```
All of `SCScreenshotManager.captureImage(contentFilter:configuration:)`, `SCContentFilter(desktopIndependentWindow:)`, `contentRect`, `pointPixelScale` are API_AVAILABLE(macos(14.0)) — verified in SCStream.h / SCScreenshotManager.h. Only `currentProcess` needs 14.4, so gate with `if #available(macOS 14.4, *)` and fall back to `SCShareableContent.current` (which DOES prompt).

Source: https://developer.apple.com/documentation/screencapturekit/scshareablecontent/currentprocess


**WKWebView.takeSnapshot(configuration:) — the only reliable way to get web content pixels without TCC** — `solid`

HARD FACT: public since macOS 10.13 (`WKWebView.h` line 429). HARD FACT from WebKit source `Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm`, `-takeSnapshotWithConfiguration:`, USE(APPKIT) branch: it calls `_page->takeSnapshot(...)` directly — a SOFTWARE snapshot rendered in the Web Content process. It never touches CGWindowListCreateImage, so no Screen Recording permission is involved on macOS. The source comment at line ~1618 says verbatim: "Software snapshot will not capture elements rendered with hardware acceleration (WebGL, video, etc). This code doesn't consider snapshotConfiguration.afterScreenUpdates since the software snapshot always contains recent updates."

```swift
let cfg = WKSnapshotConfiguration()
cfg.rect = webView.bounds            // view coords; CGRect.null => bounds
cfg.snapshotWidth = NSNumber(value: Double(webView.bounds.width)) // points; nil => rect width
cfg.afterScreenUpdates = true        // ignored on macOS, harmless
let image = try await webView.takeSnapshot(configuration: cfg)  // NSImage
```
WKSnapshotConfiguration properties verified in the SDK header: `rect` (10.13), `snapshotWidth` (10.13), `afterScreenUpdates` (10.15).

Source: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm


**NSView.bitmapImageRepForCachingDisplay(in:) + cacheDisplay(in:to:) — works for AppKit chrome, BLANK for WKWebView** — `flaky`

HARD FACT: this is the documented-in-the-wild failure. WKWebViewTips issue #7: "The Cocoa API -[NSView cacheDisplayInRect:toBitmapImageRep:] does not work for WKWebView, it only returns an empty image" — because the web content is rendered in a separate process and hosted as a remote CALayer tree that AppKit's software draw path cannot read. Same root cause as WebKit bug 86773 ("Don't let -[CALayer renderInContext:] try to render WebView's root layer"). Apple's own answer in the forums is "use takeSnapshot instead".

Still use it for your OWN AppKit chrome (tab strip, URL bar, sidebar, split dividers):
```swift
guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
view.cacheDisplay(in: view.bounds, to: rep)     // rep.pixelsWide is 2x on Retina
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: url)
```
Two extra gotchas (HARD FACT, Apple Forums thread 800739): on macOS 26.0 this returned a BLANK image for any view not yet in an NSWindow hierarchy (fixed in 26.1, FB20272813); and thread 800776 reports it still returns blank for NSButton with NSBezelStyleGlass on Tahoe. The dev machine here is 26.5.2, so the window-hierarchy bug is fixed, but never call cacheDisplay on a detached view.

Source: https://github.com/ShingoFukuyama/WKWebViewTips/issues/7


**Getting the CGWindowID from a script** — `solid`

HARD FACT: `-[NSWindow windowNumber]` IS the CGWindowID — the same integer `screencapture -l` and `CGWindowListCreateImage` want. Do NOT shell out to a helper to discover it; have Pane publish it itself.

Best: in harness builds, on `applicationDidFinishLaunching` and on every window change, write a manifest:
```swift
let m = ["pid": ProcessInfo.processInfo.processIdentifier,
         "windows": NSApp.windows.map { ["id": $0.windowNumber, "title": $0.title,
                                         "frame": NSStringFromRect($0.frame),
                                         "scale": $0.backingScaleFactor] }] as [String: Any]
try JSONSerialization.data(withJSONObject: m).write(to: URL(fileURLWithPath: "\(dir)/windows.json"))
```
Then `screencapture -l $(jq -r '.windows[0].id' .pane-artifacts/windows.json) -o -x out.png`.

Fallbacks if you cannot instrument the app: `brew install smokris/getwindowid/getwindowid` then `GetWindowID Pane 'Window Title'`; or a 20-line Swift CLI over `CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)` filtering `kCGWindowOwnerPID`. Note pyobjc/Quartz is NOT installed on this machine (checked: `import Quartz` fails), so the Python route needs a venv.

Source: https://github.com/smokris/GetWindowID


**screencapture(1) -l <windowid> -o -x** — `last-resort`

HARD FACT (from `man screencapture` on this machine, macOS 26.5.2): `-l <windowid>` captures the window with that id; `-o` = in window capture mode, do not capture the window's shadow; `-x` = do not play sounds; `-C` = include cursor; `-t <fmt>` = png (default) / jpg / pdf / tiff; `-R x,y,w,h` = rect; `-a` = do not capture attached windows; `-r` = do not add screen dpi metadata (useful for deterministic goldens); `-D <n>` = display index. Located at /usr/sbin/screencapture, ships with the OS.

`screencapture -o -x -r -l 12345 /path/shot.png`

HARD FACT: this requires the Screen Recording TCC grant, attributed to the RESPONSIBLE process (your terminal / Claude Code's host app), not to screencapture itself. HARD FACT: kTCCServiceScreenCapture cannot be pre-granted from the CLI — `tccutil` can only RESET, never grant; the system TCC.db lives at /Library/Application Support/com.apple.TCC/TCC.db and is SIP-protected (verified: `sqlite3 -readonly` on it returns "authorization denied" even for read). And a PPPC/MDM profile cannot silently allow ScreenCapture either — Apple permits only Deny or standard-user-approval for that one service. On macOS 15+ the grant also expires and re-prompts periodically, which is fatal for an unattended agent.

Source: https://ss64.com/mac/screencapture.html


**WKWebView.createPDF(configuration:) — full-page capture beyond the viewport, no TCC** — `solid`

HARD FACT (WKWebView.h line 440, API_AVAILABLE(macos(11.0))): `createPDFWithConfiguration:completionHandler:`. WKPDFConfiguration (10.15.4+) has `rect` — header says "If the rect is set to the null rect, the bounds of the CURRENTLY DISPLAYED WEB PAGE will be used" — and `allowTransparentBackground` (macOS 14.0).

```swift
let pcfg = WKPDFConfiguration()   // leave .rect as CGRect.null for the whole page
let data = try await webView.pdf(configuration: pcfg)
try data.write(to: dir.appendingPathComponent("page.pdf"))
```
Rasterize for the agent to look at: `sips -s format png page.pdf --out page.png` (/usr/bin/sips ships with the OS). Use this when you need to verify layout below the fold; takeSnapshot's `rect` is view-relative so it cannot reach past the viewport without resizing the web view.

Source: https://developer.apple.com/documentation/webkit/wkwebview/createpdf(configuration:completionhandler:)


**Zero-dependency image diff: a ~70-line Swift CLI over CGImage bytes** — `solid`

No brew dependency, ships with the SPM build. Decode both PNGs with `CGImageSourceCreateWithURL` / `NSBitmapImageRep(contentsOf:)`, redraw both into an identical `CGContext(width:height:bitsPerComponent:8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: premultipliedLast)` (this normalizes color space and row padding — the #1 source of false diffs), then:
```swift
var over = 0
for i in stride(from: 0, to: w*h*4, by: 4) {
  let d = max(abs(Int(a[i])-Int(b[i])), abs(Int(a[i+1])-Int(b[i+1])), abs(Int(a[i+2])-Int(b[i+2])))
  if d > perPixelThreshold { over += 1 }        // perPixelThreshold = 8 (of 255) tolerates AA
}
let ratio = Double(over) / Double(w*h)          // fail if ratio > 0.002
```
Emit a diff PNG (red where over threshold) so the agent can READ it and see WHERE it changed. Two extra zero-dep options, both present in the CLT SDK (verified): CoreImage `CIFilter.colorAbsoluteDifference()` (macOS 14+, CIFilterBuiltins.h:2539) for a GPU diff image, and Vision `VNGenerateImageFeaturePrintRequest` + `VNFeaturePrintObservation.computeDistance(_:to:)` (VNObservation.h:580) for a perceptual-hash-style scalar distance that ignores AA entirely — great as a coarse "is this even the same screen" gate.

Source: https://developer.apple.com/documentation/vision/vnfeatureprintobservation/computedistance(_:to:)


**CLI diff tools via Homebrew (optional upgrade)** — `solid`

Verified available as bottles on this machine's Homebrew (6.0.15): `imagemagick` 7.1.2-29, `odiff` 4.5.0, `dssim` 3.4.0. NOT currently installed (`magick`/`compare` not on PATH), and Python has no Pillow/numpy/pyobjc.

- `brew install odiff` → `odiff --antialiasing --threshold=0.1 --fail-on-layout base.png new.png diff.png`. Exit 0 = match, 21 = pixel diff, 22 = layout (size) diff. Its `--antialiasing` mode detects and excludes subpixel-rendered pixels, which kills the biggest class of flaky screenshot failures. Best-in-class for this job.
- `brew install imagemagick` → `magick compare -metric AE -fuzz 2% base.png new.png diff.png 2>&1` prints the count of pixels differing by more than the fuzz. HARD FACT: AE is the ONLY ImageMagick metric affected by `-fuzz` (since IM 6.4.3). Also `-metric RMSE` (normalized 0..1) and `-metric PHASH` for perceptual.
- `brew install dssim` → `dssim base.png new.png` prints a structural-dissimilarity score; ~0.0002 is imperceptible, >0.01 is an obvious change.

Source: https://github.com/dmtrKovalenko/odiff


**Determinism knobs (do these or every golden will be flaky)** — `solid`

INFERENCE + standard practice, but each item is a concrete lever:
1. Pin the window size exactly: `window.setContentSize(NSSize(width: 1280, height: 800))` before capture; assert `window.backingScaleFactor == 2.0` and record px dims in the filename.
2. Pin appearance: `NSApp.appearance = NSAppearance(named: .aqua)` (and a separate `.darkAqua` golden set).
3. Pin the web side: inject a user stylesheet via `WKUserScript` at `.atDocumentStart` setting `* { animation: none !important; transition: none !important; caret-color: transparent !important; }` and `scrollbar-width: none`.
4. Wait for visual settle before capturing: `didFinish` navigation → `evaluateJavaScript("document.fonts.ready.then(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))).then(()=>true)")` → then takeSnapshot. Double-rAF after fonts.ready is what stops half-painted goldens.
5. Serve fixtures from a local `NSURLSessionConfiguration`-backed HTTP server or `loadHTMLString` — never hit the real internet in a golden test.
6. Overlay-scrollbar auto-hide: `NSScroller.preferredScrollerStyle` can flip; force `.overlay` and hide via CSS.
7. Strip metadata so byte-compares are stable: `screencapture -r` (no dpi metadata), or re-encode through your own CGImageDestination.


### Recommended

Build capture INTO Pane, not around it. Add a `--harness` launch flag that enables a `PaneHarness` object exposing capture over a Unix socket or a file-watched command queue, plus a `PANE_ARTIFACTS` env var for the output dir.

Primary path: ScreenCaptureKit self-capture. `SCShareableContent.currentProcess` (macOS 14.4+) is documented in the SDK header as returning content capturable "without user consent via TCC" — so Pane can screenshot its OWN windows with zero Screen Recording permission, zero prompts, and no monthly re-auth. Feed the matching `SCWindow` (matched by `window.windowNumber == scWindow.windowID`) into `SCContentFilter(desktopIndependentWindow:)` and `SCScreenshotManager.captureImage(contentFilter:configuration:)` (both macOS 14.0). This is the ONLY no-TCC path that returns one composited image containing both your AppKit chrome and the real WKWebView pixels, and `desktopIndependentWindow` means occlusion by other windows doesn't matter.

Secondary/fallback (also required on 14.0–14.3): capture in two layers and stitch. `webView.takeSnapshot(configuration:)` for web content — a WebProcess software render, no TCC — plus `cacheDisplay(in:to:)` on the chrome views. Do NOT expect `cacheDisplay` on a container holding the WKWebView to work; it comes back blank, and that will silently pass a "did it render" check forever. Assert non-blankness explicitly: reject any capture whose pixel variance is ~0.

Never depend on `screencapture -l` in the autonomous loop. It needs a TCC grant that cannot be pre-granted (tccutil only resets, TCC.db is SIP-locked, and Apple forbids MDM from silently allowing ScreenCapture), and macOS 15+ re-prompts periodically. Keep it as a manual debugging escape hatch only.

Layout: `.pane-artifacts/<run-id>/<NNN>-<scenario>-<state>@2x.png`, a sibling `windows.json` manifest, `latest/` symlink, and goldens in `Tests/Golden/<scenario>@2x.png`. Diff with a bundled Swift CLI (normalize both into an sRGB 8-bit RGBA context, per-channel threshold 8/255, fail above 0.2% of pixels) and always write `-diff.png` — the agent can open the PNG and see what moved. Upgrade to `brew install odiff` and `odiff --antialiasing --threshold=0.1 --fail-on-layout` once you hit AA flake.


### Pitfalls

- THE BIG ONE (HARD FACT): NSView.cacheDisplay(in:to:) / bitmapImageRepForCachingDisplay returns a blank/white image for WKWebView. Web content renders in a separate process as a remote CALayer tree that AppKit's software draw path cannot read. Same for CALayer.render(in:) (WebKit bug 86773 explicitly stops it rendering the WebView root layer) and NSWindow contentView snapshots. It returns a NON-NIL rep, so naive code 'succeeds' and writes a white PNG — the agent will believe it verified the UI. Always assert the capture is not uniform.
- WKWebView.takeSnapshot on macOS is a SOFTWARE snapshot (WebKit source comment): it will NOT capture WebGL, <video>, <canvas> with GPU backing, or other hardware-accelerated surfaces. Those come out blank/black. If Pane needs to prove video playback works, ScreenCaptureKit self-capture is the only option.
- kTCCServiceScreenCapture cannot be pre-granted. tccutil can only `reset`, never grant; /Library/Application Support/com.apple.TCC/TCC.db is SIP-protected (verified: sqlite3 -readonly returns 'authorization denied'); and Apple does not permit MDM/PPPC to silently Allow ScreenCapture (Deny or standard-user-approval only). macOS 15+ additionally expires the grant and re-prompts on a ~monthly/reboot cadence. Any harness built on screencapture(1) will silently start producing wallpaper-only or empty images mid-run.
- TCC attribution goes to the RESPONSIBLE process, not the binary. `screencapture` invoked from a shell inherits the terminal app's (or Claude Code's host app's) grant. So even if you grant it once, moving the agent to a different launcher (launchd, ssh, a different terminal) silently loses it. From ssh you must also `sudo launchctl bsexec $(pgrep loginwindow) screencapture ...` per the man page's SECURITY CONSIDERATIONS.
- macOS 26.0 regression (Apple Forums 800739, FB20272813): cacheDisplayInRect:toBitmapImageRep: returned blank for ANY view not already in an NSWindow hierarchy. Fixed in 26.1 — this machine is 26.5.2, so it's fine here, but never snapshot a detached view; add it to a window first. Thread 800776 reports it still returns blank for NSButton with NSBezelStyleGlass on Tahoe.
- Fully offscreen or minimized windows: AppKit flips NSWindow.occlusionState to non-visible and stops updating the backing store, and WKWebView throttles/suspends rendering when not visible, so both SCK and screencapture can return a stale or blank frame. INFERENCE: keep the harness window genuinely on-screen at a fixed origin; use NSApp.setActivationPolicy(.accessory) if you need it to not steal focus. Minimized windows never capture correctly.
- Retina scale: everything comes back at 2x. bitmapImageRepForCachingDisplay gives a rep whose pixelsWide is 2x bounds.width; SCK requires you to set cfg.width/height = contentRect * filter.pointPixelScale or you get a blurry downscale (the classic 'why is SCScreenshotManager output blurry' bug). Bake the scale into the golden filename and assert the pixel dimensions before diffing.
- Color-space drift: PNGs written from different paths carry different embedded profiles, and a naive byte-compare or even a CGImage byte-walk over differently-tagged images will report huge diffs on visually identical pictures. Always redraw both sides into one explicit sRGB 8-bit context before comparing, and set cfg.colorSpaceName = CGColorSpace.sRGB on the SCStreamConfiguration.
- ImageMagick trap: -fuzz affects ONLY the AE metric (since IM 6.4.3). `compare -metric RMSE -fuzz 5%` silently ignores the fuzz. Use `magick compare -metric AE -fuzz 2%` for a tolerance-aware pixel count.
- Naive tolerance choice: a single global 'percent different' threshold either misses a 4px icon shift (too loose) or fires on font antialiasing (too strict). Use a per-pixel channel threshold (~8/255) to absorb AA, THEN a small area threshold (~0.2% of pixels) to absorb subpixel jitter — two thresholds, not one. odiff's --antialiasing does the first step properly.
- Not waiting for visual settle. didFinish fires before fonts load and before the first composited frame. Without `document.fonts.ready` + double requestAnimationFrame, roughly one capture in ten is a half-painted page and the golden suite becomes noise the agent learns to ignore.
- Nothing works in a headless/no-GUI session. There must be a logged-in graphical session with an unlocked screen; a locked screen or a fast-user-switched-away session yields black frames from every path.
- pyobjc/Quartz, Pillow and numpy are NOT installed on this machine (verified), and imagemagick/odiff/dssim are available as brew bottles but not installed. Don't write a harness that assumes any of them; make the Swift diff CLI the default and the brew tools an opt-in upgrade.

## Probe: Proving memory and latency claims without Instruments

**Area:** Proving Pane's memory and latency claims on macOS 26 with Command Line Tools only (no Xcode, no Instruments, no XCUITest)


### Techniques


**footprint(1) — the primary memory tool, de-duplicates across the app + all WebKit helper processes** — `solid`

HARD FACT (verified on this machine, macOS 26.5.2, arm64, CLT only): /usr/bin/footprint exists, is NOT part of Xcode, and needs NO sudo for same-user processes.

Single process:
  /usr/bin/footprint 37851
  → prints a category table plus 'Auxiliary data: phys_footprint: 187 MB / phys_footprint_peak: 477 MB'

Multi-process de-duplicated total (THE money command):
  /usr/bin/footprint --noCategories $APP_PID $WC1 $WC2 $GPU_PID $NET_PID
  → ends with '====== Summary Footprint: 260 MB ======' which de-duplicates multiply-mapped shared objects. Man page: 'If multiple processes are specified, footprint will de-duplicate multiply-mapped objects and will display shared objects separately from private ones.'

Machine-readable (use this in the harness):
  /usr/bin/footprint -f bytes --noCategories -j /tmp/fp.json $PIDS
Verified JSON shape:
  {"unit":"byte","bytes per unit":1,
   "start_time":{"mach_absolute_time_ns":…,"mach_continuous_time_ns":…,"wall_time_s":…,"date":"…"},
   "processes":[{"name":"com.apple.WebKit.GPU","pid":5630,"page size":16384,
                 "footprint":15467216,
                 "auxiliary":{"phys_footprint":15499984,"phys_footprint_peak":116294352}}],
   "summary":{"total":{"dirty":…,"swapped":…,"clean":…,"reclaimable":…,"wired":…,"regions":…}},
   "total footprint":15467216, "shared":[], "end_time":{…}, "page size":16384}

Parse `total footprint` (de-duplicated, bytes) as the headline number and `processes[].auxiliary.phys_footprint` for the per-process breakdown. `start_time.mach_absolute_time_ns` lets you align the memory sample with your latency timeline.

Other useful flags (verified in -h/man): --sample <secs> --sample-duration <secs> for time series, --forkCorpse to snapshot without stalling the live process, -x/--exclude, --minFootprint <MiB>, --sysFootprint for system-level totals, -t/--targetChildren (USELESS here — see pitfalls).

Source: x-man-page://1/footprint


**phys_footprint vs RSS vs dirty — which number is honest** — `solid`

Measured all three on the SAME WebContent pid (37851) within seconds of each other, HARD FACT:
  ps -o pid,rss,vsz -p 37851   → RSS = 436928 KB ≈ 427 MB, VSZ ≈ 484 GB
  top -l 1 -stats pid,mem,cmprs -pid 37851 → MEM 310M, CMPRS 13M
  vmmap --summary 37851        → TOTAL RESIDENT 1.1G, DIRTY 187.6M, SWAPPED 9.8M
  footprint 37851              → phys_footprint 187 MB

So RSS overstates by ~2.3x and VSZ by ~2500x. Reasons, all visible in the vmmap summary above: __TEXT alone is 1.0G virtual / 486.6M resident and __LINKEDIT 573.0M virtual — that is the dyld shared cache, clean, file-backed, shared by every process on the box, and *not* your app's cost. RSS counts it; phys_footprint does not.

Definitions (XNU / WWDC18-416): phys_footprint = (internal − alternate_accounting) + (internal_compressed − alternate_accounting_compressed) + iokit_mapped + purgeable_nonvolatile + purgeable_nonvolatile_compressed + page_table. Mental model: **footprint = dirty + compressed**. Clean/read-only/shared pages don't count.

WHICH TO REPORT: phys_footprint, always, from footprint(1) with multi-pid de-duplication. It is (a) the number Xcode's memory gauge shows, (b) the number Jetsam/the memory-pressure machinery actually charges you, (c) the only one that doesn't inflate 2x from shared system code. Report `phys_footprint_peak` alongside it — a discard that frees memory but leaves a 477 MB peak still tells you the allocation happened. Never headline RSS; if you must, publish it in a secondary column labelled 'RSS (inflated by shared system code — not the claim)'.

Note also: footprint INCLUDES compressed pages, so a 'discarded' tab whose pages were merely compressed by the VM still shows up. That is the honest behaviour and exactly what you want — it prevents you claiming a win you didn't earn.

Source: https://asciiwwdc.com/2018/sessions/416


**Finding the WebContent processes — pgrep -P DOES NOT WORK (verified)** — `solid`

HARD FACT, verified on this machine right now:
  $ ps -Ao pid,ppid,comm | grep WebKit
   1517     1  …/com.apple.WebKit.Networking
   5630     1  …/com.apple.WebKit.GPU
  37851     1  …/com.apple.WebKit.WebContent
  67476     1  …/com.apple.WebKit.GPU

Every WebKit helper has **PPID = 1 (launchd)**. WebKit launches them as XPC services via launchd, so `pgrep -P $APP_PID`, `ps --ppid`, and `footprint -t/--targetChildren` all return NOTHING. This is the single fact that changes the whole measurement strategy. Also verified: `launchctl procinfo <pid>` (which would print the responsible pid) refuses without root — 'This subcommand requires root privileges: procinfo'. And they do NOT appear in `launchctl print gui/$UID` (only com.apple.webkit.webpushd shows up).

THREE WAYS THAT ACTUALLY WORK, in order of preference:

(1) BEST — ask WKWebView directly, via the WebKit SPI property that returns pid_t. HARD FACT: declared in WebKit's public source tree, WKWebViewPrivate.h:
     @property (nonatomic, readonly) pid_t _webProcessIdentifier;
     @property (nonatomic, readonly) pid_t _provisionalWebProcessIdentifier WK_API_AVAILABLE(macos(10.14.4));
     @property (nonatomic, readonly) pid_t _gpuProcessIdentifier WK_API_AVAILABLE(macos(13.0));
   Call it from Swift with no bridging header, guarded so it never ships:
     #if BENCH
     @objc private protocol WKProcSPI {
         @objc(_webProcessIdentifier) var webProcessIdentifier: pid_t { get }
         @objc(_gpuProcessIdentifier)  var gpuProcessIdentifier: pid_t  { get }
     }
     extension WKWebView {
         var benchWebProcessPID: pid_t { unsafeBitCast(self, to: WKProcSPI.self).webProcessIdentifier }
     }
     #endif
   Compile the bench build with `swift build -Xswiftc -DBENCH`. This gives you an exact tab→pid map, which is what you need to prove *per-tab* cost. INFERENCE: SPI is stable enough for a self-hosted benchmark but must be behind #if BENCH so it is never in a shipped/notarized binary.

(2) The responsible-pid private API, dlsym'd — works for any pid, no SPI on WKWebView needed. HARD FACT, symbol verified present on this machine:
     $ dyld_info -exports /usr/lib/system/libquarantine.dylib | grep respons
       0x00000898  _responsibility_get_pid_responsible_for_pid
       0x000017FC  _responsibility_get_responsible_for_pid
   Swift:
     typealias RespFn = @convention(c) (pid_t) -> pid_t
     let h = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_NOW)
     let f = unsafeBitCast(dlsym(h, "responsibility_get_pid_responsible_for_pid")!, to: RespFn.self)
     let owner = f(webContentPid)   // == your app's pid
   Apple confirms on the forums that this facility exists, is what Activity Monitor uses to group helpers under their app, and has no public equivalent outside Endpoint Security's responsible_audit_token.

(3) PURE-SHELL FALLBACK, zero SPI — PID set-difference around a controlled launch. Reliable because a benchmark box is yours:
     before=$(pgrep -x com.apple.WebKit.WebContent | sort)
     ./Pane.app/Contents/MacOS/Pane --bench … &  APP=$!
     # …drive it…
     after=$(pgrep -x com.apple.WebKit.WebContent | sort)
     KIDS=$(comm -13 <(echo "$before") <(echo "$after"))
     /usr/bin/footprint -f bytes --noCategories -j out.json $APP $KIDS
   Harden it by quitting Safari and running `pkill -x com.apple.WebKit.WebContent` in the harness preamble so `before` is empty. Add `ps -o pid,lstart -p …` to reject any pid whose start time predates the app launch.

Source: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewPrivate.h


**In-process self-report: task_info(TASK_VM_INFO) → phys_footprint** — `solid`

Let the app print its own footprint so the harness just reads stdout. Swift 6, no C shim needed:

  import Darwin.Mach
  func selfPhysFootprint() -> UInt64 {
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
      let kr = withUnsafeMutablePointer(to: &info) { p in
          p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
              task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
          }
      }
      return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
  }

Notes: use `mach_task_self_` (the global), not `mach_task_self()` — the latter is a macro Swift may not import. TASK_VM_INFO_COUNT / TASK_VM_INFO_REV1_COUNT are macros too complex for Swift's C importer; deriving the count from MemoryLayout as above is the standard workaround and gives you the REV1+ fields including phys_footprint. `info.phys_footprint_peak` is also available in the same struct.

**CRITICAL LIMITATION — state it in your own output:** this returns the footprint of the *UI process only*. It does NOT include com.apple.WebKit.WebContent, .GPU, or .Networking. For a WKWebView browser the WebContent processes are where ~90% of the memory lives (measured above: one WebContent = 187–245 MB while a typical AppKit shell is 60–120 MB). Using this number alone to claim 'discarded tabs cost almost nothing' would be self-deception of the worst kind — the tab's memory just moved to a process you stopped looking at.

Correct use: have the app emit BOTH its own phys_footprint AND the pid list of its WebContent/GPU processes (from _webProcessIdentifier), then have the shell harness run footprint(1) over the union. The app supplies the *map*; footprint(1) supplies the *numbers*.

os_proc_available_memory(): DO NOT USE. HARD FACT — it is declared API_AVAILABLE(ios(13.0), tvos(13.0), watchos(6.0)) and API_UNAVAILABLE(macos). It will not compile for macOS 14, and there is no macOS equivalent (macOS has no per-app jetsam limit to report against).

Source: https://developer.apple.com/documentation/os/os_proc_available_memory


**vmmap --summary — the diagnostic drill-down when footprint regresses** — `solid`

/usr/bin/vmmap --summary <pid>   (no sudo needed for same-user processes — VERIFIED)

Gives the region-category table plus a MALLOC ZONE table. Real output from a WebContent pid on this machine:
  WebKit Malloc_0x103b0e678   VIRT 1.3G  RES 270.8M  DIRTY 148.1M  SWAPPED 8272K  ALLOC COUNT 607845  BYTES ALLOCATED 150.2M  FRAG 6124K (4%)
  DefaultMallocZone           VIRT 65.2M RES 11.7M   DIRTY 6608K   SWAPPED 688K   ALLOC COUNT 30962  BYTES ALLOCATED 5501K  FRAG 1795K (25%)

Why you want it: footprint(1) tells you *that* memory grew; vmmap tells you *which category* — 'WebKit malloc', 'JS JIT generated code', 'JS VM Gigacage', 'Owned physical footprint (unmapped) (graphics)', 'MALLOC_SMALL'. For Pane specifically, a discarded tab that still shows nonzero 'JS JIT generated code' or 'JS VM Gigacage' means the JS heap was not actually torn down.

Use `vmmap --summary` for the human/regression-triage path and `footprint -j` for the automated path. Also: `/usr/bin/heap <pid>` (present in CLT) gives per-class object counts on the malloc heap — good for 'is a WKWebView still alive' checks on the UI process.

Caveat: read TOTAL *minus reserved VM space* (4.2G in my sample), not TOTAL (71.9G) — the latter includes enormous reserved-but-unbacked VA ranges that mean nothing.

Source: x-man-page://1/vmmap


**Latency: ContinuousClock / clock_gettime_nsec_np, printed as NDJSON on stdout** — `solid`

This is the PRIMARY latency mechanism. Do not make signposts load-bearing.

Swift 6:
  let clock = ContinuousClock()
  let t0 = clock.now
  … restore …
  let dt = t0.duration(to: clock.now)
  let ms = Double(dt.components.seconds) * 1000 + Double(dt.components.attoseconds) / 1e15
  print(#"{"ev":"restore","tab":\#(id),"phase":"first_paint","ms":\#(ms)}"#)
  FileHandle.standardOutput.synchronizeFile()  // or setvbuf line-buffered

Or straight to the syscall, which is what ContinuousClock wraps:
  let ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)   // monotonic, excludes sleep, no NTP jumps
  // CLOCK_MONOTONIC_RAW includes sleep; mach_absolute_time() + mach_timebase_info() is the old form.

Use ContinuousClock or CLOCK_UPTIME_RAW, NEVER Date()/NSDate — wall clock can step backwards under NTP and will silently produce negative or absurd durations in an unattended overnight run.

WHAT TO TIME for the sub-200ms claim — four phases, all emitted separately:
  T0  user action (restore invoked)
  T1  WKWebView instantiated + added to view hierarchy
  T2  didCommit  (WKNavigationDelegate.webView(_:didCommit:))
  T3  FIRST PAINT — the one that matters, and the one there is no public delegate for.
  T4  didFinish

Getting T3 with PUBLIC API only: inject a WKUserScript at .atDocumentStart that does a double requestAnimationFrame and posts back:
  let js = "requestAnimationFrame(()=>requestAnimationFrame(()=>window.webkit.messageHandlers.paneBench.postMessage(performance.now())))"
  config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
  config.userContentController.add(self, name: "paneBench")
The second rAF fires after the first real compositing pass, so it is a genuine paint proxy. It also gives you `performance.now()` inside the web process for cross-checking.

SPI alternative for T3: _WKNavigationDelegatePrivate's `_webView:renderingProgressDidChange:` with `_WKRenderingProgressEventFirstVisuallyNonEmptyLayout`. More accurate, but SPI — keep behind #if BENCH.

Also time RESTORE FIDELITY, not just speed: WKWebView.interactionState (public, macOS 12+) is what you persist on discard and restore afterward. Assert scroll offset and form state round-trip, or a fast restore that loses the user's place is a fake win.

Source: https://developer.apple.com/documentation/webkit/wkwebview/interactionstate


**Signposts WITHOUT Instruments: log stream/log show can read them (verified working)** — `solid`

HARD FACT — verified end to end on this machine, no Xcode:

LIVE CAPTURE (reliable — start it before the run):
  /usr/bin/log stream --signpost --style ndjson \
      --predicate 'eventType == "signpostEvent" AND subsystem == "com.pane.browser"' \
      > signposts.ndjson &
I ran exactly this (without the subsystem clause) for 4 seconds and got 739 JSON records.

HISTORICAL:
  /usr/bin/log show --last 10m --signpost --style json \
      --predicate 'eventType == "signpostEvent" AND subsystem == "com.pane.browser"'

Verified record shape — every field you need to reconstruct intervals yourself:
  {"eventType":"signpostEvent","signpostID":17216892719917625070,"signpostScope":"process",
   "signpostType":"begin"|"end"|"event","signpostName":"UpdateSequence",
   "subsystem":"com.apple.AppKit","category":"UpdateCycle.Stalls",
   "machTimestamp":12797266585506,"timestamp":"2026-08-07 11:53:38.870815+0300",
   "processID":1513,"processImagePath":"…","eventMessage":"…"}
Pair begin/end by (processID, signpostID, signpostName) and subtract machTimestamp — nanosecond-resolution mach ticks, far better than the string timestamp.

Emitting from Swift (OSSignposter, macOS 12+, so fine for a macOS 14 target):
  let sp = OSSignposter(subsystem: "com.pane.browser", category: "tabs")
  let id = sp.makeSignpostID()
  let st = sp.beginInterval("restore", id: id, "tab=\(tabID)")
  … ; sp.endInterval("restore", st)
Category .pointsOfInterest is NOT required for log(1) to see them — the AppKit records above came from an ordinary category.

IMPORTANT FLAGS: `--signpost` is mandatory; man log says 'By default signposts are not [displayed] unless --signpost is specified.' And `log` is a ZSH BUILT-IN — `which log` returns 'shell built-in command'. Always spell it /usr/bin/log or your predicate will die with 'too many arguments'.

VERDICT: workable, and genuinely nice for correlating your app's timeline against AppKit/WebKit system signposts (which you get for free — that is the one thing raw printf cannot do). But signposts can be dropped under load and are not guaranteed to persist to the on-disk store, so make them the *secondary*, diagnostic channel. NDJSON on stdout is the channel your pass/fail gate reads.

Source: https://eclecticlight.co/2018/06/08/the-unified-log-in-macos-mojave-signposts-and-instruments/


**leaks(1) — works fine without Instruments, without SIP changes, without get-task-allow (verified)** — `solid`

HARD FACT, tested on this machine (SIP ENABLED, `DevToolsSecurity -status` = 'Developer mode is currently disabled'), against an ad-hoc-signed Homebrew node with NO entitlements and NO get-task-allow:

  $ /usr/bin/leaks 62248
  Process 62248 is not debuggable. Due to security restrictions, leaks can only show or save
  contents of readonly memory of restricted processes.
  …
  Physical footprint:         13.9M
  Physical footprint (peak):  13.9M
  leaks Report Version: 4.0
  Process 62248: 10783 nodes malloced for 2265 KB
  Process 62248: 0 leaks for 0 total leaked bytes.

READ THAT CAREFULLY: the 'not debuggable' banner is a WARNING, not a failure. leaks still walked the malloc zones, counted 10783 nodes, and rendered a verdict. What it loses is the ability to dump the *contents* of leaked buffers. Do not let the harness treat that string as an error — grep for the 'N leaks for M total leaked bytes' line instead.

Harness usage (exit status is nonzero when leaks are found, so this is a clean gate):
  /usr/bin/leaks --quiet --atExit -- ./.build/debug/Pane --bench-scenario discard-restore-x50
  # or against a running pid:
  /usr/bin/leaks $APP_PID

With allocation backtraces — set MallocStackLogging in the TARGET's environment at launch (verified: leaks then reports 'Report Version: 4.0, multi-line stacks'):
  MallocStackLogging=1 ./Pane --bench-scenario …
  # MallocStackLoggingNoCompact=1 keeps full history incl. freed blocks (much heavier)
  # then: /usr/bin/malloc_history <pid> <address>   (also present in CLT)

SIP does NOT need disabling and get-task-allow is NOT needed, because your SPM-built app will not have the hardened runtime unless you explicitly pass `codesign --options runtime`. INFERENCE + supported by the general rule: hardened-runtime-without-get-task-allow is what blocks task_for_pid; a plain `codesign -s -` ad-hoc signature (which is all a hand-rolled bundle script needs) does not set that flag. **Actionable: do not add `--options runtime` to Pane's bundle script for local/dev builds** — add it only in a separate notarization path, and never run leaks against that build.

SCOPE: run leaks against the UI process only. It will refuse to give useful data on com.apple.WebKit.WebContent (a hardened Apple platform binary — I confirmed the same banner there), and a leak inside Apple's WebKit is not yours to fix anyway.

Source: https://afine.com/to-allow-or-not-to-get-task-allow-that-is-the-question


**memory_pressure(1) — prove discarded tabs survive real pressure** — `solid`

/usr/bin/memory_pressure is in CLT (verified). Options confirmed from -h:
  -l <level>   allocate until a low-memory notification (warn OR critical)
  -p <percent-free>  allocate until this % free
  -S           simulate the system's memory pressure level WITHOUT applying real pressure
  -w <percent> don't allocate, just wait until % free
  -v           print VM statistics each interval
  -Q           quiet

Use `sudo /usr/bin/memory_pressure -S -l critical` to simulate (safe, no real allocation) and assert that Pane's DISPATCH_SOURCE_TYPE_MEMORYPRESSURE handler fires and auto-discards background tabs. Use `-p 10 -s 1` for a real-allocation soak if you want to prove the app doesn't get jetsammed. Applying real pressure will churn the whole machine — do it in a separate scenario, never in the same run as your footprint numbers.

Complement with `/usr/bin/vm_stat 1` for system-wide swap/compressor activity during the run; a 'memory win' that just pushed 400 MB into the compressor is not a win, and vm_stat is how you catch it.

Source: x-man-page://1/memory_pressure


**ps / top — cheap sampling, but only as secondary columns** — `solid`

  ps -o pid=,rss=,vsz= -p $PID        # RSS in KB — INFLATED, see phys_footprint entry
  ps -o pid,rss,etime,lstart -p $PID  # lstart is useful for validating a pid belongs to this run
  top -l 1 -stats pid,command,mem,cmprs,purg -pid $PID

Verified `ps -L` keyword list includes: rss, vsz, etime, start, lstart. There is NO responsible-pid keyword — ps cannot help you attribute WebContent to the app.

These are ~5ms and safe to poll at 10 Hz, whereas footprint(1) takes ~15–40ms per process. INFERENCE-backed recommendation: poll `ps -o rss=` at high frequency to find the *shape* of a curve (when did it plateau?), then take one authoritative `footprint -j` reading at the settle point. Never report the ps number as the claim.

Source: x-man-page://1/ps


**xctrace / Instruments — CONFIRMED UNAVAILABLE** — `last-resort` · **NEEDS XCODE**

HARD FACT, verified:
  $ which instruments  → not found
  $ /usr/bin/xctrace list templates
    xcode-select: error: tool 'xctrace' requires Xcode, but active developer directory
    '/Library/Developer/CommandLineTools' is a command line tools instance
  $ xcrun --find xctrace
    xcrun: error: unable to find utility "xctrace", not a developer tool or in PATH
  $ xcode-select -p → /Library/Developer/CommandLineTools

/usr/bin/xctrace EXISTS as a file but is a shim that hard-errors. Do not write harness code that shells out to it 'in case Xcode is installed' — you will get a silently-empty trace path. Related: XCTest is NOT in CLT either (only XCTestSupport.framework inside the SDKs), so `swift test` must use swift-testing (bundled with the Swift 6.3.3 toolchain at /Library/Developer/CommandLineTools/usr/bin/swift), not XCTest.

Source: https://developer.apple.com/forums/thread/742995


**sample / spindump — for hangs, not for the benchmark** — `solid`

  /usr/bin/sample $PID 3 -f /tmp/pane.sample   # 3s of user-space stacks, no root, no Xcode
  /usr/sbin/spindump $PID 5 -o /tmp/pane.spin  # kernel+user stacks; ALSO prints 'Responsible:' per process — but needs root

Use `sample` as the automatic escalation when a latency assertion fails: if a restore exceeds the threshold, fire `sample $APP_PID 2` from the harness and archive the output next to the failing measurement. That turns 'restore took 640ms overnight' into an actionable stack. INFERENCE: this is the closest CLT substitute for Instruments' Time Profiler, and it is more than enough to identify a main-thread stall.

spindump's 'Responsible:' field is a fourth way to map WebContent→app, but it needs root, so prefer the three methods above.

Source: x-man-page://1/sample


### Recommended

Build a `--bench` mode into Pane and drive it from a shell harness. The app owns the *map*; footprint(1) owns the *numbers*.

**App side (behind `-Xswiftc -DBENCH`).** Add a scenario runner: `Pane --bench-scenario discard-restore --tabs 12 --iterations 20 --fixtures http://127.0.0.1:8099`. It emits one NDJSON object per event on stdout, line-buffered. Two record types: `{"ev":"pids","app":123,"tabs":[{"id":3,"wc":456}],"gpu":789}` (from `_webProcessIdentifier`) and `{"ev":"phase","tab":3,"phase":"first_paint","ms":137.4,"mach":12797266585506}` (ContinuousClock; first_paint via the double-rAF `postMessage` handler). Also expose `--bench-cmd` on stdin so the harness can step it: `discard 3`, `restore 3`, `settle`, `pids`.

**Harness side (bash + python3, both present).** Preamble: quit Safari, `pkill -x com.apple.WebKit.WebContent`, serve fixtures from a frozen local `python3 -m http.server` (never the real network), `caffeinate -dimsu` the run. Start `/usr/bin/log stream --signpost --style ndjson --predicate 'subsystem == "com.pane.browser"' > sp.ndjson &`. Launch the app, read the pid map, then at each measurement point sleep 2s to settle and run `/usr/bin/footprint -f bytes --noCategories -j fp_$N.json $APP $ALL_HELPERS`. Parse `["total footprint"]`.

**What to assert.** (1) Δfootprint per discarded tab = (total with N live) − (total with N discarded), divided by N. (2) restore→first_paint p50 and p95. (3) `leaks --quiet --atExit` after 50 discard/restore cycles. (4) footprint after cycle 50 ≤ footprint after cycle 5 × 1.05 — this catches the leak that `leaks` misses because it's still reachable.

**Thresholds that won't cry wolf.** 3 warm-up iterations discarded, then 20 measured. Gate on **median**, not mean. Commit a `baseline.json`; fail only if `median > baseline_median * 1.20` **and** `median > baseline_median + 15ms` (the absolute term kills false alarms on already-fast operations). Separately hard-gate the product claim: `p95_first_paint < 200ms`. For memory, allow ±5%: WebKit's own allocations aren't deterministic. Expect ±10–15% run-to-run on latency and ±3–5% on footprint with local fixtures; if you see more, the fixtures aren't frozen or the machine isn't quiet. On any failure, auto-run `sample $APP_PID 2` and archive it.


### Pitfalls

- VERIFIED — `pgrep -P $APP_PID` and `footprint -t/--targetChildren` return NOTHING for WebContent. `ps -Ao pid,ppid` on this machine shows every com.apple.WebKit.{WebContent,GPU,Networking} with PPID=1, because WebKit launches them as launchd XPC services. Any harness built on the parent/child relationship will silently measure only the UI shell and 'prove' a spectacular memory win that is entirely fictitious. This is the single most dangerous trap in this area.
- VERIFIED — `footprint -p 37851` FAILS with 'Unable to find pid for process matching 37851' even though the man page documents `-p, --pid pid`. It treats a bare numeric after -p as a process NAME. Use the positional form: `footprint 37851`. Costs an hour if you trust the man page.
- VERIFIED — `log` is a zsh built-in. `log show --predicate '…'` dies with '(eval):log:1: too many arguments'. Always write `/usr/bin/log`.
- VERIFIED — `log show/stream` hide signposts by default; without `--signpost` you get zero rows and will wrongly conclude signposts don't work headlessly. They do.
- VERIFIED — `leaks` prints 'Process N is not debuggable. Due to security restrictions...' and THEN successfully reports '0 leaks for 0 total leaked bytes'. The banner is a warning about dumping buffer *contents*, not a failure. A harness that greps for 'not debuggable' and bails will disable its own leak gate permanently.
- VERIFIED — RSS lies by ~2.3x for WebContent (427 MB RSS vs 187 MB phys_footprint on the same pid, same moment) and VSZ lies by ~2500x (484 GB). vmmap shows why: __TEXT is 486 MB resident and __LINKEDIT 573 MB virtual, all shared dyld cache. Reporting RSS makes discarded tabs look expensive and live tabs look catastrophic; reporting VSZ is meaningless. `top`'s MEM column is a *third* number (310 M) that matches neither.
- In-process TASK_VM_INFO phys_footprint EXCLUDES WebContent/GPU/Networking. If the app self-reports only its own number, discarding a tab will appear to cost nothing simply because the memory was always in a different process. Always cross-check the self-reported number against footprint(1) over the full pid set; if they disagree by less than the size of a WebContent process, your pid discovery is broken.
- os_proc_available_memory() is API_UNAVAILABLE(macos) — it will not compile against the macOS 14 SDK. There is no macOS equivalent.
- INFERENCE (well-established WebKit behaviour, worth verifying empirically in the harness) — WebKit keeps a process cache and may retain a suspended WebContent process after a WKWebView is deallocated, for reuse. A tab that is 'discarded' at t+0 may still have a live WebContent process at t+1s. Always settle for ≥2s before sampling, and explicitly assert that the discarded tab's pid is GONE (`kill -0 $pid` fails) rather than assuming it. If it lingers, the honest report includes it.
- phys_footprint counts COMPRESSED pages. A discard that only lets the VM compressor squeeze the pages shows almost no footprint drop — correctly. Do not 'fix' this by switching to a metric that hides it. Cross-check with `vm_stat 1` during the run: rising 'Pages occupied by compressor' means you moved the cost, not removed it.
- GPU and Networking helper processes are SHARED across every WKWebView in the app. Never divide their footprint per-tab. Report them as a fixed per-app overhead line.
- Use `footprint` with ALL pids in one invocation, not one invocation per pid summed. Summing double-counts shared regions; the single multi-pid call is what produces the de-duplicated 'Summary Footprint'.
- Never use Date()/NSDate for latency. NTP can step the wall clock mid-run and produce negative durations in an unattended overnight loop. ContinuousClock or clock_gettime_nsec_np(CLOCK_UPTIME_RAW).
- Do not benchmark against the real network. Page-load variance from DNS/TLS/CDN will swamp a 200ms budget and generate nightly false alarms. Serve frozen fixtures from 127.0.0.1 and pin the WKWebsiteDataStore (nonPersistent, or a fresh temp store per run) so disk-cache warmth doesn't drift.
- Signposts can be dropped under load and are not guaranteed to reach the persistent store — `log show` after the fact is best-effort. Start `log stream` BEFORE the run if you need them, and never make a pass/fail gate depend on a signpost record existing.
- MallocStackLogging must be in the TARGET process's environment at launch (not the harness's), and it materially inflates footprint. Never enable it in the run that produces the memory numbers — use a separate leak-hunting scenario.
- Do not add `codesign --options runtime` (hardened runtime) to the dev/bench bundle script. It is what would actually break `leaks` and require get-task-allow or SIP changes. Keep hardening in a separate notarization-only path.
- `_webProcessIdentifier` and `_WKRenderingProgressEventFirstVisuallyNonEmptyLayout` are WebKit SPI. Fine for a self-hosted benchmark, fatal for App Store review. Gate them behind `#if BENCH` and make the release build fail to compile if the symbol leaks into it.
- `pkill -f WebContent` in the harness preamble will also kill Safari's tabs and any other app's web views. Use `pkill -x com.apple.WebKit.WebContent` and only on a dedicated benchmark machine, or restrict cleanup to the pids you discovered.
- Gate on median with BOTH a relative and an absolute term (`>1.20x AND >+15ms`). A pure percentage threshold on an already-fast operation turns ordinary scheduler noise into a nightly failure, and the agent will learn to ignore its own alarms.
- xctrace exists at /usr/bin/xctrace but hard-errors under CLT ('requires Xcode'). XCTest is likewise absent — only XCTestSupport.framework ships in the SDKs. Use swift-testing via the bundled Swift 6.3.3 toolchain, and never write a fallback path that shells out to xctrace.

## Probe: Fixtures and the unit-test layer

**Area:** Deterministic test fixtures and the unit-test layer for Pane (Swift 6 / AppKit / WKWebView, SPM + CLT only, no Xcode)


### Techniques


**HARD FACT: XCTest.framework is NOT installed with Command Line Tools — swift-testing IS. This decides the framework question.** — `solid`

Verified on this machine (macOS 26.5.2, CLT only):

  find /Library/Developer/CommandLineTools -iname "XCTest*"
  # -> only .../SDKs/*.sdk/System/Library/PrivateFrameworks/XCTestSupport.framework (a .tbd, unrelated)
  # -> NO XCTest.framework, NO `xctest` binary anywhere

  ls /Library/Developer/CommandLineTools/Library/Developer/Frameworks/
  # -> Testing.framework, _Testing_AppKit.framework, _Testing_Foundation.framework,
  #    _Testing_CoreGraphics.framework, _Testing_CoreImage.framework, _Testing_UIKit.framework
  ls /Library/Developer/CommandLineTools/usr/libexec/swift/pm/
  # -> swiftpm-testing-helper   (the swift-testing runner; no XCTest needed)

So: write every test with `import Testing` / `@Test` / `@Suite`. Add to Package.swift nothing at all — swift-testing ships in the toolchain, it is NOT an SPM dependency on Apple platforms.

Run with:
  swift test --disable-xctest --enable-swift-testing
(both flags exist — confirmed in `swift test --help` under OPTIONS)

Anything you pull in that does `import XCTest` (including swift-snapshot-testing) will fail to build in this environment. INFERENCE, high confidence: this is the single biggest constraint on the test stack and should be verified by the agent in its first 10 minutes with a 3-line throwaway package.

Source: https://forums.swift.org/t/only-command-line-tools-installed-xctest-executable-not-found/34088


**Fixture server: one stdlib-only Python file (ThreadingHTTPServer + ssl.SSLContext), spawned by the test harness** — `solid`

HARD FACT: /usr/bin/python3 is 3.9.6 (CLT-bundled, always present). /opt/homebrew/bin/python3 is 3.14.6. `python3 -m http.server` in 3.14 gained --tls-cert/--tls-key/--tls-password-file and HTTPSServer/ThreadingHTTPSServer classes (verified via `python3 -m http.server --help`); 3.9 has none of that.

Do NOT use `python3 -m http.server` directly — it only serves static files, so it cannot do 401, redirects, hangs, or chunked-slow. Write ONE file, `Tests/Fixtures/fixture_server.py`, targeting 3.9 syntax so it runs on /usr/bin/python3 with zero Homebrew dependency:

  from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
  import ssl, sys, json, time, base64
  class H(BaseHTTPRequestHandler):
      protocol_version = 'HTTP/1.1'
      def do_GET(self): route(self)
  httpd = ThreadingHTTPServer(('127.0.0.1', 0), H)      # port 0 = kernel picks
  if '--tls' in sys.argv:
      ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)      # NOT ssl.wrap_socket (removed in 3.12)
      ctx.load_cert_chain(certfile=cert, keyfile=key)
      httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
  print(json.dumps({'port': httpd.server_address[1]}), flush=True)  # harness reads this line
  httpd.serve_forever()

Routes to implement (each is a fixture the browser tests need):
  GET /ok                 -> 200 text/html, <title>OK</title>
  GET /slow?ms=N          -> send headers, then time.sleep(N/1000), then body
  GET /hang               -> send headers, never send body, never close (tests load timeout / stop button)
  GET /big?bytes=N        -> Content-Length: N, Content-Disposition: attachment; filename="big.bin";
                             write in 64KB chunks with a flush; supports `Range:` -> 206 + Content-Range
                             (Range support is what makes WKDownload resume testable)
  GET /big-flaky?bytes=N&cut=M -> writes M bytes then self.wfile.close() mid-stream -> download fails with resumeData
  GET /redirect/3         -> 302 to /redirect/2 -> ... -> /ok    (chain)
  GET /redirect/loop      -> 302 to itself                        (loop detection)
  GET /redirect/cross     -> 302 to the *other* origin's port     (cross-origin redirect)
  GET /auth               -> if no Authorization: 401 + 'WWW-Authenticate: Basic realm="Pane"'
                             else validate base64 and 200
  GET /login              -> <form method=post action=/login><input name=u><input type=password name=p>
  POST /login             -> 302 to /ok on correct creds, 200 with error text otherwise
  GET /audio              -> page with <audio src=/tone.wav autoplay loop> (tests the tab audio indicator)
  GET /tone.wav           -> a WAV generated in-process by the `wave` module (no binary asset in the repo)
  GET /history?n=50       -> page whose inline JS does history.pushState() n times on load
  GET /popup, /download-js, /js-alert, /js-confirm, /js-prompt, /beforeunload

Spawn from Swift with Foundation.Process, read the JSON port line off the pipe, tear down in the suite's deinit. Because it binds port 0 you can run one server per @Suite and swift-testing parallelism will never collide.

Source: https://docs.python.org/3/library/http.server.html


**Self-signed cert generation with openssl (verified working on this machine)** — `solid`

HARD FACT: /opt/homebrew/bin/openssl is 3.6.3; /usr/bin/openssl (LibreSSL) also ships with macOS. I ran this and inspected the output — it produces the right SAN/EKU:

  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 90 \
    -keyout "$OUT/key.pem" -out "$OUT/cert.pem" \
    -subj "/CN=pane-fixture" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -addext "extendedKeyUsage=serverAuth" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment"

Verified output contains:
  X509v3 Subject Alternative Name: DNS:localhost, IP Address:127.0.0.1
  X509v3 Extended Key Usage: TLS Web Server Authentication
  X509v3 Basic Constraints: critical CA:FALSE
  Signature Algorithm: sha256WithRSAEncryption

Why each flag matters on Apple platforms: since macOS 10.15 the CN is ignored for hostname matching — SAN is mandatory; serverAuth EKU is mandatory; RSA >= 2048 and SHA-256 are mandatory; and validity must be <= 398 days. Keep -days 90. If you violate any of those you still get a failure, but a DIFFERENT one, and your test will assert the wrong thing.

Generate into a temp dir at suite setup, not into the repo. Two certs are worth having: `cert.pem` (untrusted-but-well-formed, for the interstitial test) and `expired.pem` (`-days 1` generated with faketime is unavailable; instead use `openssl req ... -not_before/-not_after` on OpenSSL 3.x, or just accept that 'untrusted root' is the one cert error you test end-to-end and unit-test the other SecTrust result codes against a fake).

Source: https://support.apple.com/en-us/102028


**Making the test EXPECT the trust failure rather than trusting it** — `solid`

The mistake to avoid: the usual StackOverflow snippet makes the delegate call completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!)) — that TRUSTS the cert and your interstitial never appears.

To make the failure happen, the delegate must NOT vend a credential:

  func webView(_ w: WKWebView,
               didReceive challenge: URLAuthenticationChallenge,
               completionHandler ch: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
      guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
          ch(.performDefaultHandling, nil); return
      }
      // record it for the test, then reject:
      recorder.serverTrustChallenges.append(SecTrustCopyCertificateChain(challenge.protectionSpace.serverTrust!))
      ch(.performDefaultHandling, nil)     // default = evaluate normally = fail for self-signed
  }

Then assert in `webView(_:didFailProvisionalNavigation:withError:)`:

  let ns = error as NSError
  #expect(ns.domain == NSURLErrorDomain)
  #expect(ns.code == NSURLErrorServerCertificateUntrusted)     // -1202
  #expect(ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String == fixtureURL)

Assert on the SYMBOLIC constant (NSURLErrorServerCertificateUntrusted), not the literal -1202, and accept the sibling codes as a set in the integration test — WebKit can surface -1200 (NSURLErrorSecureConnectionFailed) or -1201/-1203 depending on the SecTrust result. Pin the exact code only in the unit test, where you inject the error.

The 'proceed anyway' path (the second half of the interstitial) is the same delegate returning .useCredential with URLCredential(trust:) after the user clicks through. There is still no sanctioned API for this — WebKit bug 140197 has been open since 2015 — so unit-test the *decision* (did the interstitial view model transition to .proceeded and did it call the trust-accepting closure) and leave the actual WebKit acceptance to one integration test.

Source: https://developer.apple.com/documentation/foundation/1508628-url_loading_system_error_codes/nsurlerrorservercertificateuntrusted


**The protocol boundary: yes, wrap WKWebView — but wrap it as a NARROW COMMAND/EVENT port, not as a WKWebView-shaped protocol** — `solid`

The design instinct is right, the usual execution is wrong. Do NOT write `protocol WebViewProtocol { var url: URL? { get }; func load(_:) -> WKNavigation?; var backForwardList: WKBackForwardList { get } }` — that leaks WebKit types (WKNavigation, WKBackForwardList, WKNavigationAction are all non-constructible in tests) and your fake becomes unbuildable.

Define the port in YOUR vocabulary, in a module that does not import WebKit:

  @MainActor protocol WebEngine: AnyObject {
      var events: AsyncStream<WebEngineEvent> { get }
      func load(_ request: PaneRequest)
      func reload(ignoringCache: Bool)
      func stop()
      func goBack(); func goForward(); func go(offset: Int)
      func evaluate(_ js: String) async throws -> String
      func snapshot() async throws -> PaneImage
      func setMuted(_ muted: Bool)
  }

  enum WebEngineEvent: Sendable, Equatable {
      case didStartProvisional(URL)
      case didCommit(URL)
      case didFinish(URL, title: String?)
      case didFail(PaneNavigationError)              // your own enum, mapped from NSError
      case redirected(from: URL, to: URL)
      case serverTrustChallenge(TrustInfo)
      case httpAuthChallenge(realm: String, host: String)
      case backForwardChanged(canGoBack: Bool, canGoForward: Bool, entries: [HistoryEntry])
      case progress(Double)
      case audioStateChanged(isPlayingAudio: Bool, isMuted: Bool)
      case downloadStarted(DownloadID, suggestedFilename: String)
      case rendererTerminated(reason: RendererTerminationReason)
      case titleChanged(String)
  }

Then `WKWebEngine` is the only file that imports WebKit, and it is a pure translator: WKNavigationDelegate/WKUIDelegate/WKDownloadDelegate callbacks in, WebEngineEvent out. It contains NO branching logic. `FakeWebEngine` lets a test push any event sequence, including impossible orderings.

The tab lifecycle state machine then becomes a pure, synchronous, WebKit-free reducer:

  struct TabState: Equatable { enum Phase { case blank, provisional(URL), committed(URL), finished(URL), failed(PaneNavigationError), interstitial(TrustInfo), crashed } ... }
  func reduce(_ s: TabState, _ e: WebEngineEvent) -> (TabState, [TabEffect])

That reducer is where 60% of your unit tests live, it runs in microseconds, it needs no run loop, no window, no main actor even, and swift-testing's parameterized `@Test(arguments:)` lets you drive whole event sequences as table data:

  @Test(arguments: [
    ([.didStartProvisional(u), .didCommit(u), .didFinish(u, title: "OK")], TabState.Phase.finished(u)),
    ([.didStartProvisional(u), .didFail(.certUntrusted(info))],            .interstitial(info)),
    ([.didStartProvisional(u), .didStartProvisional(v), .didCommit(v)],    .committed(v)),  // races
  ])
  func lifecycle(events: [WebEngineEvent], expected: TabState.Phase) { ... }

What this CANNOT test (must be integration): whether real WebKit actually emits that event sequence. Specifically untestable with a fake — (1) delegate callback ORDERING and whether didCommit precedes provisional failure; (2) back/forward list semantics, especially pushState vs real navigation and same-document navigations; (3) process-per-tab isolation, WKProcessPool sharing, and renderer termination; (4) WKDownload resume-data validity; (5) SecTrust evaluation results; (6) cookie/WKWebsiteDataStore persistence and partitioning; (7) JS dialog re-entrancy and beforeunload; (8) memory/zombie behaviour when tabs are suspended. Every one of those is a real-WebKit integration test.

Source: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKNavigationDelegate.h


**Real-WebKit integration tests must NOT live in `swift test` — put them in a separate SPM executable that runs NSApplication** — `flaky`

HARD FACT: WKWebView's UI-process IPC is serviced by the main thread's CFRunLoop / AppKit event loop. `swift test` runs the swift-testing entry point as an async main which drains the main *dispatch* queue but does not run an AppKit event loop. INFERENCE (high confidence, and the thing to verify first): real WKWebView navigation delegate callbacks will either never fire or fire flakily under `swift test`, which matches the long-standing reports of WKWebView tests timing out in headless/CI runs.

The fix that is known to work for AppKit-in-a-CLI:

  // Sources/PaneIntegrationTests/main.swift  — an SPM *executable* target
  import AppKit
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)      // no Dock icon, no menu bar
  final class D: NSObject, NSApplicationDelegate {
      func applicationDidFinishLaunching(_ n: Notification) {
          Task { @MainActor in
              let failures = await IntegrationSuite.runAll()
              exit(failures == 0 ? 0 : 1)
          }
      }
  }
  let d = D(); app.delegate = d
  app.run()                                 // NOT RunLoop.main.run()

Run it as `swift run PaneIntegrationTests`. This also gives you a real Info.plist path (see the ATS pitfall), a real bundle identifier, and lets you attach the WKWebView to a real offscreen NSWindow — which matters, because WKWebView that is never in a window hierarchy gets deprioritised and on some OS versions its web content process is reaped.

If you insist on driving these from swift-testing instead, the only shape that works is a `.serialized` suite whose helper pumps the event loop while awaiting:

  @MainActor func pump(until deadline: Date, _ done: () -> Bool) {
      while !done() && Date() < deadline {
          if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                     inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
          RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
      }
  }

This is the flaky option. Prefer the separate executable.

Source: https://www.objc.io/blog/2018/10/02/using-appkit-from-the-command-line/


**Deterministic renderer crash: kill the WebContent XPC child, don't try to OOM it in JS** — `solid`

HARD FACT (verified locally): the child process is
  /System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent
Confirmed with `pgrep -fl "WebKit.WebContent"` -> a live pid on this machine.

In the integration harness:

  // after the page has committed, find the WebContent child whose parent is us
  let out = try shell("/usr/bin/pgrep", "-P", "\(ProcessInfo.processInfo.processIdentifier)", "-f", "WebKit.WebContent")
  // fall back to: pgrep -f com.apple.WebKit.WebContent  and filter by ppid via `ps -o ppid=`
  kill(pid, SIGKILL)
  // then assert webViewWebContentProcessDidTerminate(_:) fired within 5s
  // and that Pane repainted a 'this page crashed — reload' state and did NOT lose the URL/title/history

Why not a JS OOM page (`while(true) a.push(new Array(1e7))`): it is nondeterministic, takes tens of seconds, can wedge the whole test machine, and webViewWebContentProcessDidTerminate is documented as not always firing under memory pressure. SIGKILL fires it every time.

The *unit* test of the same behaviour is trivial: push `.rendererTerminated(reason:)` into the reducer and assert the phase becomes `.crashed` with the URL preserved. Note the known WebKit trap this catches (bug 176855): after termination the WKWebView must be told to reload — a naive implementation shows a permanently blank view.

Source: https://bugs.webkit.org/show_bug.cgi?id=176855


**swift-testing idioms that replace the XCTest patterns you can't use** — `solid`

  import Testing

  @Suite(.serialized)                              // opt out of parallelism per-suite
  @MainActor struct TabLifecycleTests {
      @Test func commitThenFinish() { ... }

      // XCTestExpectation replacement:
      @Test func delegateFires() async {
          await confirmation("navigation finished", expectedCount: 1) { done in
              engine.onFinish = { done() }
              engine.load(req)
          }
      }
      // assert something does NOT happen:
      await confirmation(expectedCount: 0) { c in ... }

      // known-broken without disabling — the test still runs and fails LOUDLY when fixed:
      @Test func pushStateHistory() { withKnownIssue("pane#41 pushState depth") { ... } }

      // hard timeout so a hung WKWebView can't wedge the suite:
      @Test(.timeLimit(.minutes(1))) func slowLoad() async throws { ... }

      // table-driven, one case per row, each reported separately:
      @Test(arguments: [301, 302, 303, 307, 308]) func redirect(status: Int) async throws { ... }

      // tags for the pre-commit vs nightly split:
      @Test(.tags(.integration)) func realWebKitLoad() async throws { ... }
  }

Exit tests (Swift 6.2+, available in the 6.3.3 toolchain here) let you assert your own precondition/fatalError paths without XCTest:
  await #expect(processExitsWith: .failure) { TabID(rawValue: -1) }

Selection:
  swift test --filter 'PaneTests.TabLifecycleTests'
  swift test --skip '.integration'
  swift test --xunit-output .build/tests.xml          # machine-readable result the agent can parse
  swift test --enable-code-coverage && \
    xcrun llvm-cov report .build/debug/PanePackageTests.xctest/Contents/MacOS/PanePackageTests \
      -instr-profile .build/debug/codecov/default.profdata
(llvm-cov and llvm-profdata are both present in CLT — verified with `xcrun --find`.)

Source: https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0008-exit-tests.md


**Snapshot testing: roll your own ~80-line NSBitmapImageRep differ; do NOT depend on swift-snapshot-testing** — `solid`

swift-snapshot-testing added a swift-testing path in 1.17.0, but its core `assertSnapshot` still routes failures through XCTFail and the library `import XCTest`s. INFERENCE (high confidence, must be verified in 5 minutes before committing to it): since XCTest.framework does not exist in this CLT-only environment, adding it as a dependency will fail at link time. Verify with a scratch package before adopting; assume it is blocked.

What to do instead — this is genuinely ~80 lines and has no dependency:

  @MainActor func snapshot(_ view: NSView) -> Data {
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
      view.cacheDisplay(in: view.bounds, to: rep)
      return rep.representation(using: .png, properties: [:])!
  }
  // for page content specifically, prefer WebKit's own:
  //   let cfg = WKSnapshotConfiguration(); cfg.rect = ...; cfg.snapshotWidth = 800
  //   let image = try await webView.takeSnapshot(configuration: cfg)

  func diff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, tolerance: Double = 0.002) -> Double {
      // compare width/height first, then walk bitmapData bytes, count |Δ| > 8 per channel,
      // return differing / total; write a red-overlay PNG to .build/snapshot-failures/ on failure
  }

Record mode = an env var: `PANE_RECORD_SNAPSHOTS=1 swift run PaneIntegrationTests`. Store references as PNG under Tests/__Snapshots__/.

The 'small ethos' argument is not the main reason to skip the library — the XCTest link is. But it is also true that the useful non-image strategies (recursive view description, JSON dumps of TabState) are three lines of your own code:

  #expect(String(reflecting: tabState) == fixture)        // or Codable -> JSONEncoder(.sortedKeys)

Text/JSON snapshots of the reducer state, the back/forward list, and the parsed download queue give you 90% of snapshot-testing's value with zero pixels and zero flake. Use image snapshots ONLY for chrome layout (tab strip at 3 widths, light/dark, RTL) — and expect them to be your flakiest tests.

Source: https://www.pointfree.co/blog/posts/146-swift-testing-support-for-snapshottesting


**Why not swift-nio / Network.framework for the fixture server** — `solid`

Network.framework NWListener with TLS needs `sec_protocol_options_set_local_identity(opts, sec_identity_create(secIdentity))`, and getting a SecIdentity requires SecPKCS12Import of a .p12 — which on macOS wants a keychain, needs a passphrase dance, and pollutes the developer's login keychain. That is a lot of ceremony and a real source of 'works on my machine' failures.

swift-nio + swift-nio-ssl means vendoring BoringSSL, a multi-minute cold build, and a permanent dependency in Package.resolved — for a browser project whose whole point is being small, that is the wrong trade.

If you nevertheless want an in-process server with no TLS (fine for 80% of fixtures: redirects, 401, slow, big files), a bare NWListener over plain TCP speaking HTTP/1.1 by hand is ~150 lines and needs no dependency:
  let l = try NWListener(using: .tcp, on: .any)   // .any -> kernel-assigned port
  l.newConnectionHandler = { c in c.start(queue: q); recv(c) }
Then use the Python server only for the HTTPS cases. Recommendation: don't split it — one Python file covers both and is easier for an autonomous agent to reason about and modify.

Source: https://developer.apple.com/forums/thread/687308


**Offline guarantees and store isolation** — `solid`

Nothing must reach the internet, and you should PROVE it rather than hope:

1. Per-test ephemeral store, always:
     let cfg = WKWebViewConfiguration()
     cfg.websiteDataStore = .nonPersistent()
   Otherwise tests leak cookies/localStorage into each other and the first failure cascades.

2. Deterministic 'no network' fixture: navigate to https://pane-test.invalid/ (.invalid is reserved by RFC 2606 and can never resolve) and assert NSURLErrorCannotFindHost (-1003). This gives you an offline-safe DNS-failure error page test.

3. Assert the negative: have the fixture server log every request it serves, and after the suite assert the set of hosts touched == {127.0.0.1}. Belt-and-braces: run the whole suite once nightly under a network-denied shell and require it still passes.

4. Fix the clock. Anything that formats a date, computes history recency, or expires a download must take an injected `now: () -> Date`. Never let a test call Date().

Source: https://developer.apple.com/documentation/webkit/wkwebsitedatastore/nonpersistent()


### Recommended

Use swift-testing exclusively. This is not a style preference — XCTest.framework is physically absent from Command Line Tools (verified: only Testing.framework and swiftpm-testing-helper ship there), so `import XCTest` cannot link. Run `swift test --disable-xctest --enable-swift-testing`. Verify this in the first ten minutes with a throwaway package; everything downstream depends on it, including the decision to skip swift-snapshot-testing (which imports XCTest and will not build here).

Split the suite into two executables with two different runners.

`swift test` holds only WebKit-free code. Put a `WebEngine` protocol at the boundary expressed in Pane's own vocabulary — `load/stop/goBack` in, an `AsyncStream<WebEngineEvent>` out — where no WKNavigation, WKBackForwardList, or WKNavigationAction ever crosses. The tab lifecycle then becomes a pure `reduce(TabState, WebEngineEvent) -> (TabState, [Effect])` that runs in microseconds with no run loop and no window, and `@Test(arguments:)` drives whole event sequences as table data, including orderings real WebKit rarely produces (double provisional start, commit-then-fail, terminate mid-load). This is where most tests live and it must stay under 10 seconds total.

`swift run PaneIntegrationTests` is a separate SPM executable that calls `NSApplication.shared.run()` with `.accessory` activation policy. Real WKWebView needs the AppKit event loop; `swift test`'s async main only drains the dispatch main queue, which is why WKWebView tests are famously flaky headless. Do not fight this — move them.

Fixtures: one stdlib-only Python file, `ThreadingHTTPServer` bound to port 0, printing its port as JSON on stdout, spawned per suite via `Process`. Write it in 3.9-compatible syntax so `/usr/bin/python3` works and Homebrew is not required. Routes cover slow, hang, Range-capable big files, redirect chains and loops, 401 Basic, a login form, a generated WAV audio page, and a pushState history page. TLS via `ssl.SSLContext(PROTOCOL_TLS_SERVER)` + `load_cert_chain`, with a cert from `openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 90 -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" -addext "extendedKeyUsage=serverAuth"` (verified working). Make the trust test *fail* by having the delegate return `.performDefaultHandling` and asserting `NSURLErrorServerCertificateUntrusted` — never `URLCredential(trust:)`.

Crash the renderer with `kill -9` on the `com.apple.WebKit.WebContent` child, never with a JS OOM loop.

Pyramid: 70% unit / 22% integration / 5% end-to-end / 3% visual. Pre-commit: `swift build && swift test` plus a 60-second integration smoke (load, back/forward, download, cert interstitial, crash-recover) — hard budget 3 minutes. Nightly: full integration matrix, all visual snapshots, coverage via llvm-cov, and a network-denied run.


### Pitfalls

- XCTest.framework does not exist in Command Line Tools. Verified on this machine: `find /Library/Developer/CommandLineTools -iname "XCTest*"` returns only an unrelated private XCTestSupport.tbd, and there is no `xctest` binary. Any dependency that does `import XCTest` — swift-snapshot-testing, Quick/Nimble, most mocking libraries — is unusable. Verify this before writing a line of test code, not after.
- App Transport Security will bite the http:// fixtures. `swift test` runs a bundle with no Info.plist so ATS defaults apply, and the integration executable needs `NSAllowsLocalNetworking` (for `localhost`) plus `NSAllowsArbitraryLoads`/`NSAllowsArbitraryLoadsInWebContent` for a bare `127.0.0.1` IP. NSAllowsLocalNetworking alone does NOT cover raw IPs. Cheapest fix: serve every fixture over HTTPS with the self-signed cert and handle trust in the delegate, so ATS is never in the picture. Second cheapest: bake the exception into the harness executable's generated Info.plist.
- `URLCredential(trust: challenge.protectionSpace.serverTrust!)` is the snippet everyone copies, and it silently makes the cert-interstitial test pass for the wrong reason — the interstitial never renders because the cert was accepted. Assert on the failure first; only add the accept path as a separate, explicitly-named 'proceed anyway' test.
- Cert validity over 398 days, a missing subjectAltName, or a missing serverAuth EKU each produce a DIFFERENT trust failure than 'untrusted root'. Your assertion on -1202 will then be testing the wrong thing, and will break the day you regenerate the cert with different flags. Keep `-days 90` and pin the extensions.
- swift-testing runs tests in parallel by default, which XCTest did not. Anything sharing a fixture server port, a WKWebsiteDataStore, a temp download directory, or NSApp state will interleave. Bind the fixture server to port 0 (kernel-assigned) per suite, use `.nonPersistent()` data stores, and mark AppKit-touching suites `@Suite(.serialized) @MainActor`.
- XCTest ran synchronous tests on the main thread implicitly; swift-testing does not. Every test that touches NSView, NSWindow, WKWebView, or any @MainActor model must carry an explicit `@MainActor`. Forgetting it produces a crash or a Main Thread Checker violation that looks like a WebKit bug.
- Real WKWebView delegate callbacks under `swift test` will hang or fire nondeterministically because there is no AppKit event loop. The tempting fix — sprinkling `RunLoop.main.run(until:)` or bumping timeouts to 20 seconds — buys flake, not correctness. `NSApplication.shared.run()` in a separate executable is the fix; `RunLoop.main.run()` specifically is NOT sufficient for AppKit event delivery.
- A WKWebView never added to a window can be deprioritised or have its content process reaped, and takeSnapshot returns blank. In the integration harness always attach it to a real (offscreen or `.accessory`-policy) NSWindow before asserting anything about rendering or timing.
- After `webViewWebContentProcessDidTerminate` the WKWebView stays permanently blank unless you explicitly reload it (WebKit bug 176855). Write the test to assert the view actually shows content again after recovery, not merely that the callback fired.
- Deliberately OOM-ing the renderer from JavaScript is nondeterministic, slow, can wedge the whole machine, and the termination callback is documented as not always firing under memory pressure. SIGKILL the `com.apple.WebKit.WebContent` child instead.
- `ssl.wrap_socket()` was removed in Python 3.12 — every blog-post snippet for HTTPS `http.server` uses it. Use `ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)` + `load_cert_chain` + `context.wrap_socket(httpd.socket, server_side=True)`. Also note `python3 -m http.server --tls-cert` exists only in 3.14 (Homebrew here); /usr/bin/python3 is 3.9.6 and has no TLS flags, so write your own script rather than relying on the module CLI.
- Image snapshot tests will be the flakiest thing in the suite — font rendering, backing scale, and the appearance mode all shift them. Prefer text/JSON snapshots of TabState, the back/forward list, and the download queue (`JSONEncoder` with `.sortedKeys`, compared as strings). Reserve pixels for tab-strip chrome, run them nightly not pre-commit, and always write a diff PNG to .build/snapshot-failures/ so the agent can inspect what changed.
- A fixture server left running after a crashed test run will make the next run pass against stale content or fail on a bound port. Kill it from the suite's `deinit` AND register an atexit/SIGTERM handler in the Python script; on startup, have the harness refuse to proceed if it finds an orphaned fixture process.
- Hidden internet dependencies creep in through favicon fetches, safe-browsing lookups, and OCSP/CRL revocation checks against the self-signed cert. Log every request the fixture server sees and assert the touched-host set is exactly {127.0.0.1}; run the whole suite network-denied once nightly to prove it.
- `--parallel/--no-parallel` in `swift test --help` defaults to `--no-parallel`, which governs XCTest-style parallelism — it does not turn off swift-testing's in-process parallelism. Use the `.serialized` trait for that. Confusing the two produces intermittent failures that look like race conditions in Pane.


---

# THE HARNESS DESIGN (merged)

# PANE SELF-VERIFICATION HARNESS — DESIGN

The load-bearing decision: **the shipped binary is the test runner.** There is no separate UI-test process, no XCTest, no automation permission, no screenshot tool outside the app. Everything the agent needs to prove Pane works is compiled into `Pane` itself and driven by `--selftest`. TCC is not on the critical path anywhere.

---

## 1. THE HARNESS

### 1.1 Directory layout

```
pane-browser/
├── Package.swift
├── Sources/
│   ├── PaneCore/            # NO WebKit, NO AppKit. Pure logic.
│   │   ├── URLNormalizer.swift
│   │   ├── TabState.swift          # struct + reduce(TabState, WebEngineEvent)
│   │   ├── SessionStore.swift
│   │   ├── HistoryStore.swift
│   │   ├── DownloadNaming.swift
│   │   ├── Keymap.swift            # [KeyChord: Command] table
│   │   ├── Command.swift           # THE command enum — see 1.3
│   │   └── WebEngine.swift         # protocol + WebEngineEvent enum (Pane vocabulary only)
│   ├── PaneWeb/             # the ONLY target that imports WebKit
│   │   ├── WKWebEngine.swift       # pure translator: WK delegates in, WebEngineEvent out
│   │   └── WebProcessIDs.swift     # #if PANE_BENCH only — _webProcessIdentifier SPI
│   ├── PaneUI/              # AppKit. imports PaneCore + PaneWeb
│   │   ├── BrowserWindow.swift
│   │   ├── TabStripView.swift
│   │   ├── SidebarOutline.swift
│   │   ├── CommandBus.swift        # single dispatch point for ALL commands
│   │   └── ModalPolicy.swift       # alerts/panels/JS dialogs routed through a policy object
│   ├── PaneHarness/         # compiled in only under -DPANE_HARNESS
│   │   ├── ScenarioRunner.swift
│   │   ├── Scenario.swift          # protocol: id, tags, timeout, run(Ctx) async throws
│   │   ├── Expect.swift            # THE only assertion type; counts every assertion
│   │   ├── Capture.swift           # SCK self-capture + takeSnapshot + cacheDisplay
│   │   ├── Beacon.swift            # per-run canary pixel patch (see §7.3)
│   │   ├── AXDump.swift            # in-process NSAccessibility tree → JSON
│   │   ├── Synth.swift             # NSEvent synthesis helpers
│   │   ├── Watchdog.swift          # _exit(70) + sample(1) on timeout
│   │   ├── BenchRunner.swift       # --bench-scenario
│   │   ├── ControlSocket.swift     # --control-socket, opt-in
│   │   └── Scenarios/
│   │       ├── TabScenarios.swift
│   │       ├── NavScenarios.swift
│   │       ├── DownloadScenarios.swift
│   │       ├── SecurityScenarios.swift
│   │       ├── CrashScenarios.swift
│   │       └── VisualScenarios.swift
│   ├── Pane/
│   │   └── main.swift              # ~40 lines: argv → normal | selftest | bench | socket
│   └── paneshot/            # standalone CLI, no deps
│       └── main.swift              # diff / accept / assert-not-uniform / png info
├── Tests/
│   └── PaneCoreTests/       # import Testing only
├── Fixtures/
│   ├── fixture_server.py    # ONE file, Python 3.9 syntax, /usr/bin/python3
│   └── site/                # static assets (fonts subset, images, css)
├── Goldens/
│   ├── <scenario>@1280x800@1x.png
│   ├── <scenario>@1280x800@2x.png
│   └── ACCEPTED.log
├── Harness/
│   ├── baseline.json        # committed bench baselines
│   ├── skip-budget.json     # declared allowable skips, with expiry dates
│   └── mutants.json         # mutation canary definitions
├── Scripts/
│   ├── bundle.sh            # hand-rolled .app
│   ├── gate.sh              # THE entry point: gate.sh pre | phase | bench | visual
│   ├── fixtures.sh          # start/stop fixture server, writes .pane-artifacts/fixtures.json
│   ├── bench.sh             # footprint(1) driver
│   └── install-hooks.sh     # installs .git/hooks/pre-commit
├── .pane-artifacts/         # gitignored; <run-id>/ per run + latest symlink
├── .pane-gate.log           # gitignored; gate receipts (see §7.5)
└── .github/workflows/ci.yml
```

### 1.2 Package.swift targets

```swift
.target(name: "PaneCore"),                                   // no deps
.target(name: "PaneWeb",     dependencies: ["PaneCore"]),
.target(name: "PaneUI",      dependencies: ["PaneCore","PaneWeb"]),
.target(name: "PaneHarness", dependencies: ["PaneUI"]),      // linked always, gated by #if
.executableTarget(name: "Pane", dependencies: ["PaneUI","PaneHarness"]),
.executableTarget(name: "paneshot"),
.testTarget(name: "PaneCoreTests", dependencies: ["PaneCore"]),
```

`PaneHarness` bodies are wrapped in `#if PANE_HARNESS`; without the flag the target compiles to empty stubs and `main.swift` prints `harness not compiled in` for `--selftest`. Two build modes:

```bash
swift build -c release -Xswiftc -DPANE_HARNESS                 # dev / test build
swift build -c release -Xswiftc -DPANE_HARNESS -Xswiftc -DPANE_BENCH   # bench build
swift build -c release                                          # ship build
```

A CI step greps the ship build: `nm -u .build/release/Pane | grep -q _webProcessIdentifier && exit 1` — SPI must not leak into a shipping binary.

### 1.3 The command layer (this is what makes scripted coverage real coverage)

```swift
public enum Command: Sendable, Equatable, CaseIterable /* where possible */ {
    case newTab(url: URL?)
    case closeTab(TabID)
    case selectTab(TabID)
    case reopenClosedTab
    case navigate(TabID, PaneRequest)
    case goBack(TabID), goForward(TabID), stop(TabID), reload(TabID, ignoringCache: Bool)
    case discardTab(TabID), restoreTab(TabID)
    case toggleSidebar
    case focusAddressBar
    case answerDialog(DialogID, DialogAnswer)
    ...
}
```

`CommandBus.dispatch(_ c: Command)` is the **only** mutator of app state. Menu items call it. `Keymap` resolves a `KeyChord` to a `Command` and calls it. The control socket calls it. `--selftest` calls it. There is no second path, so a scenario that dispatches `.closeTab` exercises exactly the code a ⌘W exercises. A lint rule (§7.7) fails the build if any view controller mutates `TabModel` directly.

### 1.4 `main.swift`

```swift
import AppKit
let args = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.regular)                       // NOT .accessory, NOT .prohibited
let mode = Mode(args)                                    // .normal | .selftest(Opts) | .bench(Opts)
let delegate = AppDelegate(mode: mode)
app.delegate = delegate
app.run()
```

In `applicationDidFinishLaunching`, for `.selftest`:

```swift
Watchdog.arm(seconds: opts.timeout ?? 300)               // _exit(70) + sample(getpid(),5)
NSApp.activate(ignoringOtherApps: true)
Task { @MainActor in
    let r = await ScenarioRunner.runAll(opts)
    Out.ndjson(r)                                        // stdout, line-buffered
    exit(r.failures == 0 ? 0 : 1)
}
```

Never a `DispatchSemaphore` on the main thread. All WebKit waits are `withCheckedContinuation` resumed from the delegate, raced against `Task.sleep` for a per-await timeout.

### 1.5 CLI surface

```
Pane --selftest [--json] [--scenario <id>] [--tag smoke|tabs|visual|...]
                [--list] [--artifacts <dir>] [--fixtures <base-url>]
                [--timeout <sec>] [--mutate <mutant-id>] [--seed <n>]
Pane --bench-scenario <id> [--tabs N] [--iterations N] [--fixtures <url>] [--ndjson]
Pane --dump-ax [--scenario <id>]
Pane --control-socket /tmp/pane.sock       # requires PANE_HARNESS
```

### 1.6 NDJSON contract (stdout; logs go to stderr; artifacts to `--artifacts`)

```json
{"rec":"env","git":"a1b2c3d","os":"26.5.2","scale":2.0,"screen":"1512x982","pid":4711,"beacon":"#3F7AE1","run":"20260807-114233-a1b2c3d"}
{"rec":"scenario","id":"tabs.close_restores_selection","status":"pass","assertions":7,"ms":812,"tags":["smoke","tabs"],"artifacts":["003-tabs.close-after@2x.png"]}
{"rec":"assert","scenario":"nav.back_after_pushstate","ok":false,"expr":"tab.canGoBack","expected":"true","actual":"false","file":"NavScenarios.swift","line":88}
{"rec":"scenario","id":"nav.back_after_pushstate","status":"fail","assertions":4,"ms":1330}
{"rec":"summary","total":64,"pass":62,"fail":1,"skip":1,"assertions":418,"ms":74210}
```

`status` ∈ `pass | fail | skip`. A timeout is `fail`, never `skip`. Skip requires `"reason"` and `"expires":"2026-09-30"`.

### 1.7 Guards compiled into the runner (non-negotiable)

```swift
// before ANY web or visual assertion
precondition(window.occlusionState.contains(.visible), "window not visible — WebKit throttled")
precondition(webView.window != nil,                    "webView detached")
precondition(!window.isMiniaturized)
```

Plus: fixed window geometry (`setContentSize(1280×800)`, origin `(40,120)`), `NSApp.appearance = NSAppearance(named: .aqua)` (a `.darkAqua` pass is a separate tagged run), a `WKUserScript` at `.atDocumentStart` killing animations/transitions/caret/scrollbars, and `.nonPersistent()` website data store per scenario.

### 1.8 Fixtures

`Fixtures/fixture_server.py` — one stdlib-only file, 3.9 syntax, `ThreadingHTTPServer` on port 0, prints `{"port":N,"tls_port":M}` as its first stdout line, serves both HTTP and (second listener) HTTPS with a self-signed cert generated into a temp dir at start:

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 90 \
  -keyout key.pem -out cert.pem -subj "/CN=pane-fixture" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -addext "extendedKeyUsage=serverAuth" \
  -addext "basicConstraints=critical,CA:FALSE"
```

Routes: `/ok /slow?ms /hang /big?bytes (Range→206) /big-flaky?cut /redirect/{3,loop,cross} /auth /login /audio /tone.wav /history?n /popup /download-js /js-{alert,confirm,prompt} /beforeunload /heavy?dom=50000`.

It logs every request to `.pane-artifacts/<run>/requests.ndjson`. `gate.sh` asserts the served-host set is exactly `{127.0.0.1}` and that every URL a scenario claimed to load appears in that log — a scenario that silently skipped its navigation cannot pass.

The Info.plist emitted by `bundle.sh` for **harness builds only** carries `NSAppTransportSecurity → NSAllowsLocalNetworking` + `NSAllowsArbitraryLoads` (bare `127.0.0.1` is not covered by local-networking alone). Ship builds get neither.

### 1.9 `bundle.sh`

```bash
./Scripts/bundle.sh --harness      # → build/Pane.app, ad-hoc signed, NO --options runtime
./Scripts/bundle.sh --release      # → build/Pane-release.app, hardened runtime, no PANE_HARNESS
```

**Never** add `--options runtime` to the harness bundle — hardened-runtime-without-`get-task-allow` is precisely what breaks `leaks(1)`. Keep the bundle at a stable absolute path `build/Pane.app`. Ad-hoc signing (`codesign -s -`) is fine *because nothing in the design needs a TCC grant to survive rebuilds* (§5).

---

## 2. THE FOUR LAYERS

### Layer 1 — Unit (`PaneCoreTests`)

**Command:** `swift test --disable-xctest --enable-swift-testing`
**Runtime:** < 10 s (hard budget; failing the budget is a build failure)
**Covers:** URL normalization and the omnibox search-vs-URL decision; the `reduce(TabState, WebEngineEvent)` lifecycle machine driven table-style via `@Test(arguments:)` including orderings real WebKit rarely emits (double provisional start, commit-then-fail, terminate mid-load); session serialization round-trip; history dedup and recency with an injected `now: () -> Date`; keybinding table (no duplicate chords, every `Command` case reachable); download filename derivation and collision suffixing; cookie/site-data policy decisions; back/forward list model.
**Cannot catch:** whether real WebKit ever emits those event sequences; delegate callback ordering; anything AppKit, layout, focus, or pixel; WKDownload resume-data validity; SecTrust results; process isolation; anything about timing or memory.

The `WebEngine` protocol is expressed entirely in Pane's vocabulary (`load(PaneRequest)`, `AsyncStream<WebEngineEvent>`). No `WKNavigation`, `WKBackForwardList`, or `WKNavigationAction` ever crosses it, so `FakeWebEngine` is buildable and can push impossible orderings.

### Layer 2 — Integration (`--selftest`)

**Command:** `./build/Pane.app/Contents/MacOS/Pane --selftest --json --fixtures http://127.0.0.1:$PORT --artifacts .pane-artifacts/$RUN`
**Runtime:** smoke tag ≈ 45 s; full ≈ 3 min
**Covers:** real `NSApplication`, real on-screen `NSWindow`, real `WKWebView`s loading loopback fixtures. Driven three ways, cheapest first:
- (a) `CommandBus.dispatch` — the same entry point menus and keys use;
- (b) synthesized `NSEvent.mouseEvent` / `keyboardEvent` through `window.performKeyEquivalent` then `NSApp.sendEvent` — exercises real hit-testing and the responder chain;
- (c) assertions against the in-process `NSAccessibility` tree serialized to JSON (`accessibilityChildren`, `accessibilityIdentifier`, `isAccessibilitySelected`, `accessibilityFrame`), snapshot-diffed.

Web state asserted via `evaluateJavaScript`. Renderer crash recovery via `kill(webContentPid, SIGKILL)` — never a JS OOM loop — asserting `webViewWebContentProcessDidTerminate` fires *and* that content actually returns after recovery (WebKit 176855: a naive implementation stays blank forever). Cert interstitial asserted by returning `.performDefaultHandling` and expecting `NSURLErrorServerCertificateUntrusted`, never `URLCredential(trust:)`.

Menus are driven with `NSApp.sendAction(_:to:from:)` / `menu.performActionForItem(at:)`. Synthetic clicks into `NSMenu` spin a nested tracking loop and hang forever. Alerts, sheets, `NSOpenPanel`, and JS dialogs all route through `ModalPolicy`, which in selftest mode auto-answers and records; `runModal` is banned by lint.

**Cannot catch:** window-server-level event routing — cross-window click-through, genuine key-window/focus transitions, real drag-and-drop between windows. `NSApp.sendEvent` bypasses the window server. Also cannot catch anything requiring a second application, real network conditions, or user-perceived quality.

### Layer 3 — Visual (`--selftest --tag visual`)

**Command:** `./Scripts/gate.sh visual` → runs the visual-tagged scenarios, then `paneshot diff` per capture.
**Runtime:** ≈ 40 s for ~15 captures.
**Covers:** full-window composited pixels (AppKit chrome + real web content in one image) via **ScreenCaptureKit self-capture**:

```swift
let c = try await SCShareableContent.currentProcess          // macOS 14.4+, NO TCC
let w = c.windows.first { $0.windowID == CGWindowID(window.windowNumber) }!
let f = SCContentFilter(desktopIndependentWindow: w)
let cfg = SCStreamConfiguration()
cfg.width  = Int(f.contentRect.width  * CGFloat(f.pointPixelScale))
cfg.height = Int(f.contentRect.height * CGFloat(f.pointPixelScale))
cfg.scalesToFit = false; cfg.showsCursor = false
cfg.ignoreShadowsSingleWindow = true; cfg.captureResolution = .best
cfg.colorSpaceName = CGColorSpace.sRGB; cfg.includeChildWindows = true
return try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
```

On 14.0–14.3 the fallback is `webView.takeSnapshot(configuration:)` (software render in the web process, no TCC) stitched with `view.cacheDisplay(in:to:)` for chrome. `cacheDisplay` on any container holding a `WKWebView` returns blank — it is banned by lint outside `Capture.swift`.

Settle protocol before every capture: `didFinish` → `evaluateJavaScript("document.fonts.ready.then(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))).then(()=>true)")` → capture. Without double-rAF after `fonts.ready`, roughly one capture in ten is half-painted.

`paneshot diff` normalizes both PNGs into an identical sRGB 8-bit premultiplied-last `CGContext` (this kills the colour-profile false-diff class), then a **two-threshold** comparison: per-channel |Δ| > 8/255 marks a pixel; fail if marked pixels > 0.2 % of total. Always writes `-diff.png` with red overlay. `--fail-on-size` if dimensions differ — never rescale to make it fit.

Golden naming: `Goldens/<scenario>@<W>x<H>@<scale>x.png`. Both `@1x` and `@2x` sets are maintained (CI runners are 1x; the dev Mac is 2x).

**Cannot catch:** whether the UI looks *good*, is legible, or is well-proportioned. It catches change, not quality. Also cannot catch anything outside the captured window (menu bar, Dock, popovers if `includeChildWindows` misses them).

### Layer 4 — Benchmark (`--bench-scenario` + `Scripts/bench.sh`)

**Command:** `./Scripts/gate.sh bench` (local only)
**Runtime:** ≈ 8 min
**Covers:** memory and restore latency.

App side emits NDJSON: `{"ev":"pids","app":123,"tabs":[{"id":3,"wc":456}],"gpu":789,"net":790}` from `_webProcessIdentifier` / `_gpuProcessIdentifier` (`#if PANE_BENCH`), and `{"ev":"phase","tab":3,"phase":"first_paint","ms":137.4,"mach":...}` timed with `ContinuousClock` (never `Date()`). Four phases: T0 restore invoked, T1 webview in hierarchy, T2 `didCommit`, T3 **first paint**, T4 `didFinish`. T3 comes from a `.atDocumentStart` `WKUserScript` doing double-rAF then `window.webkit.messageHandlers.paneBench.postMessage(performance.now())`.

Shell side owns the numbers:

```bash
/usr/bin/footprint -f bytes --noCategories -j fp_$N.json $APP $WC1 $WC2 ... $GPU $NET
# parse ["total footprint"] — de-duplicated across processes
```

One invocation with all pids. Never one-per-pid summed (double-counts shared regions). Never `footprint -p <number>` (that flag takes a *name*; verified to fail). Never RSS as the headline — it overstates ~2.3× because of the shared dyld cache; publish it only in a column labelled "RSS (inflated by shared system code — not the claim)".

`pgrep -P $APP_PID` returns nothing for WebContent (PPID=1, launchd XPC). The SPI pid map is primary; the PID set-difference around a controlled launch is the shell fallback, hardened by rejecting any pid whose `ps -o lstart=` predates app launch.

**Cannot catch:** perf on other hardware or under thermal pressure; cold-start disk effects (fixtures are warm and local); real-network page weight; anything a shared CI vCPU would render meaningless — which is why this layer never gates in CI.

---

## 3. THE PRE-COMMIT GATE

**The single command:**

```bash
./Scripts/gate.sh pre
```

**Hard budget: 180 s wall.** `gate.sh` self-times and *fails* if it exceeds 200 s — a gate too slow to run every time is a gate that gets skipped, so slowness is treated as a defect.

What it does, in order, aborting on first failure:

| Step | What | ~time |
|---|---|---|
| 1 | `Scripts/lint.sh` — bans `try?` in `PaneHarness`, `runModal`, `cacheDisplay` outside `Capture.swift`, `Date()` in `PaneCore`, direct model mutation outside `CommandBus`, `import XCTest`, `import WebKit` in `PaneCore`/`PaneUI` | 2 s |
| 2 | `swift build -c release -Xswiftc -DPANE_HARNESS -Xswiftc -warnings-as-errors` | 15–40 s (incremental) |
| 3 | `swift test --disable-xctest --enable-swift-testing` | < 10 s |
| 4 | `./Scripts/bundle.sh --harness` | 2 s |
| 5 | `./Scripts/fixtures.sh start` (asserts no orphan server first) | 1 s |
| 6 | `Pane --selftest --tag smoke --json --timeout 90` → `tee smoke.ndjson` | ≈ 45 s |
| 7 | Post-checks on `smoke.ndjson` (§7): scenario count == `--list` count; every scenario `assertions >= 1`; no skip past expiry; served-host set == `{127.0.0.1}`; every claimed URL present in `requests.ndjson` | 1 s |
| 8 | `paneshot diff` on the 3 smoke-tagged captures | 3 s |
| 9 | Write gate receipt: `echo "$(git write-tree) pre $(date -u +%s) pass" >> .pane-gate.log` | — |

Total ≈ 80–110 s.

The smoke tag is fixed at **12 scenarios**: app launches and window is visible; new tab; close tab restores selection; navigate + `didFinish` + title; back/forward; ⌘L focuses address bar via synthesized key event; download of `/big?bytes=1048576` completes with correct bytes and name; cert interstitial appears for the TLS fixture; renderer SIGKILL recovers; discard + restore round-trips `interactionState` scroll offset; sidebar AX tree has expected roles and identifiers; one full-window SCK capture diffs clean.

`Scripts/install-hooks.sh` installs a `.git/hooks/pre-commit` that is four lines and makes the gate structurally unskippable — see §7.5.

---

## 4. THE PHASE GATE

**Command:** `./Scripts/gate.sh phase`
**Budget:** ≈ 20 min. Run at every milestone and nightly.

Everything in `pre`, plus:

1. **Full integration suite** — all tags, `--timeout 300`, both `.aqua` and `.darkAqua` passes.
2. **Full visual set** — all `visual`-tagged captures at the local scale, `paneshot diff` against `@2x` goldens.
3. **AX tree snapshot diff** — `Pane --dump-ax` for 5 canonical states against `Goldens/ax/*.json`.
4. **Mutation canary** — pick one mutant from `Harness/mutants.json` (seeded by day-of-year), run `Pane --selftest --mutate <id>`, and **fail the gate if the suite passes**. Each mutant names the scenario that must catch it.
5. **Leak gate** — `MallocStackLogging=1 ./build/Pane.app/Contents/MacOS/Pane --bench-scenario discard-restore --iterations 50 &` then `/usr/bin/leaks $PID --quiet`. Parse the `N leaks for M total leaked bytes` line; the `Process N is not debuggable` banner is a *warning* and must not abort the check.
6. **Network-denied run** — full integration suite once with outbound blocked; must still pass.
7. **Benchmark** — `./Scripts/bench.sh`.

### Benchmark thresholds (concrete, all gated)

Protocol: quit Safari, `pkill -x com.apple.WebKit.WebContent`, `caffeinate -dimsu`, frozen local fixtures, `.nonPersistent()` store, 3 warm-up iterations discarded, 20 measured, **2 s settle before every footprint sample**.

**Latency**
- **Hard product claim:** `p95(restore → first_paint) < 200 ms`. Absolute; not relative to any baseline.
- **Regression:** fail if `median > baseline.median * 1.20` **AND** `median > baseline.median + 15 ms`. Both terms required — a pure percentage on an already-fast operation turns scheduler noise into nightly false alarms, and an agent that learns to ignore its own alarms has no gate at all.
- Reported per phase (T1, T2, T3, T4) so a regression is attributable.
- On any latency failure the harness auto-runs `sample $APP_PID 2 -f artifacts/slow.sample.txt` and archives it next to the measurement.

**Memory** (12 tabs of `/heavy?dom=50000`)
- `total footprint` with 11 of 12 discarded ≤ **1.10 ×** `total footprint` with 1 tab open.
- Δ per discarded tab ≥ **100 MB** (median across the 20 iterations).
- Every discarded tab's WebContent pid is **gone** within 5 s (`kill -0` fails). If WebKit's process cache retains it, the report says so — no assuming.
- After 50 discard/restore cycles: `footprint(cycle 50) ≤ footprint(cycle 5) × 1.05`. This catches the still-reachable growth that `leaks` cannot see.
- `leaks` reports **0 leaks**.
- Absolute footprint tolerance ±5 % vs `Harness/baseline.json` (WebKit allocation is not deterministic).
- `vm_stat 1` sampled throughout; a "win" that only grew the compressor is reported as such, not as a win.

**Pressure**
- `sudo /usr/bin/memory_pressure -S -l critical` → assert Pane's `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` handler fired and background tabs auto-discarded within 3 s. Separate scenario, separate run — never in the run that produces the footprint numbers.

**Cross-check (anti-self-deception, §7.4):** the gate **fails** if the app's self-reported `TASK_VM_INFO.phys_footprint` is within 20 MB of footprint(1)'s multi-pid `total footprint` while ≥ 1 tab is live. That can only mean pid discovery broke and you're measuring the UI shell alone.

Baselines are updated only by `./Scripts/gate.sh bench --rebaseline --reason "..."`, which appends to `Harness/baseline.json` with the reason, the git SHA, and the old value. A commit that changes `baseline.json` without a new reason entry is rejected by lint.

---

## 5. TCC / PERMISSIONS

**Nothing on the critical path needs any permission.** That is a design constraint, not an outcome.

| Capability | Mechanism | Permission | Status |
|---|---|---|---|
| Drive UI | `CommandBus` + `NSApp.sendEvent` (in-process) | none | required, always available |
| Inspect UI tree | `NSAccessibility` protocol, in-process | none | required |
| Capture window (chrome + web, composited) | `SCShareableContent.currentProcess` → `SCScreenshotManager` | **none** — the SDK header states this returns content capturable "without user consent via TCC" | required, macOS 14.4+ |
| Capture web pixels (fallback, 14.0–14.3) | `WKWebView.takeSnapshot` | none | fallback |
| Capture chrome (fallback) | `NSView.cacheDisplay(in:to:)` | none | fallback, blank for WKWebView |
| Full-page beyond viewport | `WKWebView.createPDF` + `sips -s format png` | none | on demand |
| Memory | `footprint`, `vmmap`, `leaks`, `heap` | none (same-user) | required |
| Hangs | `sample`, `lldb -p --batch` | none | required |
| Signposts | `/usr/bin/log stream --signpost` | none | diagnostic only |

**Explicitly excluded from the design:**

- **XCUITest / XCTest** — `XCTest.framework` does not exist under Command Line Tools. `import XCTest` will not compile. XCUITest additionally needs an `xcodebuild`-generated runner app. This is not a fallback; it is impossible. Consequence: `swift-snapshot-testing`, Quick/Nimble, and most mocking libraries are unusable — hence the ~80-line `paneshot` differ.
- **`screencapture` / `CGWindowListCreateImage`** — need Screen Recording, which **cannot be granted non-interactively**: `tccutil` only `reset`s, TCC.db is SIP-protected, and Apple forbids MDM/PPPC from silently allowing it. macOS 15+ also re-prompts periodically. Kept as a **manual human-debugging escape hatch only**; `lint.sh` fails the build if `screencapture` appears in any script under `Scripts/` other than `Scripts/manual-debug.sh`.
- **`AXUIElement` / `CGEvent.post` / `osascript`** — Accessibility and PostEvent are two distinct TCC services rendered as one row in System Settings, both grantable only by a human clicking a toggle, and `osascript`'s prompts are modal and will hang an unattended run **forever**. These live in **Tier 3**, a `--tag tcc` scenario set that reports `status:"skip", reason:"AXIsProcessTrusted()==false"` and **never gates anything**. The `--list` count check (§7.9) still ensures they are visibly skipped rather than silently absent.

**Consequence of needing no grants:** ad-hoc `codesign -s -` is fine, and the harness bundle deliberately omits `--options runtime`. If the design *had* needed a grant, an agent rebuilding 50×/day would silently lose it on every rebuild (TCC keys grants to the code-signing requirement) with no error at all. Avoiding permissions avoids that entire class of phantom regression.

---

## 6. CI

**Runs on `macos-15` (and a `macos-26` job once available). GitHub-hosted macOS runners have an emulated display — GUI apps launch and render. No xvfb, no display setup action.**

```yaml
name: pane
on: [push, pull_request]
jobs:
  gate:
    runs-on: macos-15
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - run: sudo xcode-select -s /Library/Developer/CommandLineTools   # match local exactly
      - run: ./Scripts/gate.sh pre
      - run: ./Scripts/gate.sh phase --no-bench-gate --visual-scale 1
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: pane-artifacts, path: '.pane-artifacts/**' }
```

**CI runs the identical `gate.sh` entry points the agent runs locally.** Xcode *is* preinstalled on hosted images, which is a trap: if CI ever used `xcodebuild`/XCTest, local and CI would stop testing the same thing and the agent would lose its ability to reproduce a CI failure. The first CI step forcibly points `xcode-select` at Command Line Tools.

**What genuinely runs in CI:**
- Layer 1 unit — fully.
- Layer 2 integration — fully. Real window, real WKWebView, real fixtures.
- Layer 3 visual — but at **scale 1.0**, against the `@1x` golden set. `backingScaleFactor` is 1.0 on the runner and cannot be forced to 2. Vertical resolution is capped at 1600 px, so the 1280×800 window fits with room to spare — do not design a golden that needs more.
- `leaks` — works (no hardened runtime on the harness bundle).
- Ship-build SPI-leak check.

**What does NOT gate in CI:**
- **Layer 4 benchmark.** Shared vCPUs, unknown neighbours, no thermal control. CI runs `--no-bench-gate`: it executes the bench, uploads the NDJSON as an artifact for trend-watching, and **never fails on a threshold**. Latency and memory claims are proven on the dev Mac only, and the report says which machine produced each number.
- **`memory_pressure` soak.** Runner has passwordless sudo so it *runs*, but the numbers are noise. Non-gating.

**What is impossible in CI:**
- **Any TCC grant.** The system TCC DB is SIP-protected; SIP is disabled only on the long-EOL macOS 13 image. Blog posts describing `sqlite3` inserts into TCC.db are stale. Tier 3 auto-skips, as designed.
- **`@2x` golden verification.** Structural, not fixable.
- **Notarization / hardened-runtime behaviour** without secrets — a separate manual workflow.

**Honesty rule baked into the workflow:** the uploaded artifact bundle always includes `result.json` naming which tiers ran, which were skipped, and why. A CI green with `bench: recorded-not-gated` is labelled as such in the job summary, so a green check never overstates what was proven.

---

## 7. ANTI-SELF-DECEPTION RULES

Each rule names a specific way this agent will fool itself, and a countermeasure that is *structural* — enforced by code or the gate, not by discipline.

### 7.1 "The test passes because it asserts nothing"
Every assertion goes through one type, `Expect`, which increments a per-scenario counter. There is no other assertion mechanism (lint bans bare `if ... { fail() }` and `try?` inside `PaneHarness`). **The runner fails any scenario reporting `assertions == 0`,** and `gate.sh` fails the run if the total assertion count drops below the previous run's count recorded in `.pane-gate.log` without a corresponding scenario deletion in git.

### 7.2 "The suite is green because it can't fail"
`Harness/mutants.json` defines deliberate defects (`tabs.off_by_one_selection`, `nav.swallow_back`, `download.wrong_extension`, `discard.keep_webview_alive`, …), each compiled in behind `--mutate <id>` and each naming the scenario that must catch it. The phase gate runs one mutant per day, seeded deterministically, and **fails if the suite passes**. A suite that cannot detect a planted bug is a suite that proves nothing.

### 7.3 "The screenshot is blank/stale/wrong-window and I called it verified"
A **canary beacon**: in harness builds the window's content view draws an 8×8 patch of a *per-run random RGB* at a fixed corner, and the colour is published in the `env` NDJSON record and `windows.json`. Every capture is validated before it is diffed:
1. beacon pixels at the expected point coordinate match the run's colour → proves this is *this run's* frame, *this* window, at *this* scale;
2. unique-colour count ≥ 16 and per-channel stddev ≥ 2.0 → proves non-uniform.

This single mechanism kills four failure modes at once: the white `cacheDisplay` PNG that "succeeds" with a non-nil rep, a stale frame from a throttled webview, capturing the wrong window, and a silent scale change. The beacon rect is excluded from golden diffs.

### 7.4 "The memory win is real" (it isn't — it moved to a process I stopped looking at)
Three hard checks in `bench.sh`:
- fail if `len(webcontent_pids) == 0` while tabs are live;
- fail if self-reported `phys_footprint` ≈ footprint(1) `total footprint` (within 20 MB) with ≥1 tab live — that means pid discovery broke;
- fail if any pid in the set has `lstart` earlier than app launch.

Plus: report `phys_footprint`, never RSS, as the claim; report `phys_footprint_peak` alongside (a discard that frees memory but leaves a 477 MB peak still tells you the allocation happened); and sample `vm_stat` throughout, because footprint counts *compressed* pages and a discard that merely let the compressor squeeze the tab is not a win. Do not "fix" that by switching to a metric that hides it.

### 7.5 "I'll run the gate before committing" (structurally unskippable)
`gate.sh` ends by appending `"$(git write-tree) pre $(date -u +%s) pass"` to `.pane-gate.log`. The installed hook:

```bash
#!/bin/sh
git diff --quiet || { echo "unstaged changes: gate would not match the commit"; exit 1; }
grep -q "^$(git write-tree) pre .* pass$" .pane-gate.log || {
  echo "no passing gate receipt for this exact tree — run ./Scripts/gate.sh pre"; exit 1; }
```

The receipt is keyed to the **tree hash of the exact content being committed**. Editing a file after the gate ran invalidates it. `--no-verify` exists, so CI re-runs `gate.sh pre` on every push and a receipt-less commit surfaces there. This is the most important rule in the document: it converts "I should test" into "I cannot commit untested content."

### 7.6 "It's skipped, so it's fine"
`skip` requires `reason` and an `expires` date. `Harness/skip-budget.json` declares a maximum skip count per tag. The gate fails if skips exceed the budget or if any skip is past `expires`. A timeout is **fail**, never skip. A crashed run (`_exit(70)`) is **fail**, and the watchdog dumps `sample $(getpid()) 5` plus the newest `~/Library/Logs/DiagnosticReports/Pane-*.ips` into the artifacts dir before exiting.

### 7.7 "The scripted path works" (but real users take a different path)
`CommandBus.dispatch` is the only mutator; `lint.sh` fails if any file outside `CommandBus.swift` mutates the tab model. A test that dispatches `.closeTab` therefore exercises exactly the ⌘W code. Additionally, at least one smoke scenario per command family must drive via **synthesized NSEvent** rather than direct dispatch, and the runner tags each scenario record with `"drive":"command"|"event"|"ax"` — the gate fails if the `event`-driven count drops below 6.

### 7.8 "The page loaded" (it didn't — the fixture server was down)
`fixture_server.py` logs every request. `gate.sh` asserts: the served-host set is exactly `{127.0.0.1}`; every URL a scenario declared in its `expectedRequests` appears in the log; and a deliberate negative — one scenario loads `https://pane-test.invalid/` and asserts `NSURLErrorCannotFindHost`, proving the error path is real and that nothing silently reaches DNS. Nightly, the whole suite runs network-denied and must still pass.

### 7.9 "Coverage looks the same" (a scenario quietly stopped existing)
`Pane --selftest --list` emits the registry. The gate asserts `count(--list) == count(scenario records in the run)` — no scenario may be registered and not executed. It also diffs `--list` against the previous run's registry stored in `.pane-gate.log`; a scenario that disappears fails the gate unless the same commit deletes its source. Scenarios self-register via a compile-time list in `Scenarios/Registry.swift` that lint requires to name every `Scenario`-conforming type.

### 7.10 "I accepted the new golden" (without ever looking at it)
There is no auto-accept and no record mode that overwrites in place. Changing a golden requires:

```bash
paneshot accept <scenario> --diff-ratio 0.0431 --reason "sidebar row height 24→28 per redesign"
```

`--diff-ratio` must match the computed ratio to 4 dp (so the diff must actually have been run), and `--reason` must be ≥ 20 chars and differ from the previous entry for that scenario. Each acceptance appends to `Goldens/ACCEPTED.log`. Lint fails any commit whose diff touches a `Goldens/*.png` without a matching same-commit `ACCEPTED.log` line. **And the workflow requires the agent to `Read` the `-diff.png`** — which is the one thing it genuinely can do — before writing the reason; a reason that does not describe a visual change is caught by the human reviewing `ACCEPTED.log`, which is a short, high-signal file precisely because acceptance is expensive.

### 7.11 "The known-issue test is fine being red"
`withKnownIssue`-style scenarios carry an issue ID and are asserted **inverted**: the gate fails if a known-issue scenario **passes**. A fixed bug must force the annotation to be removed. Known-issue scenarios also carry an `expires` date and count against the skip budget.

### 7.12 "The visual test passed" (against a differently-sized image)
`paneshot diff` fails hard on dimension mismatch — it never rescales. Golden filenames encode `WxH@Nx`, and the harness asserts `window.backingScaleFactor` and the captured pixel dimensions match the filename before comparing. A scale change surfaces as a missing golden, not as a silent pass.

### 7.13 "Latency improved" (measured with a clock that moved)
`Date()` / `NSDate` is lint-banned in `PaneCore` and `PaneHarness`. Only `ContinuousClock` / `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`. NTP can step the wall clock mid-run and produce negative durations in an unattended overnight loop. Signposts are diagnostic-only: they can be dropped under load and never reach the persistent store, so **no pass/fail gate may depend on a signpost record existing** — the NDJSON on stdout is the gated channel.

### 7.14 "Green means shippable"
`gate.sh` prints a closing block listing, verbatim, what the run **did not** prove: window-server event routing, real drag-and-drop, cross-application behaviour, GPU-composited content under the takeSnapshot fallback, TCC-gated Tier 3, `@2x` goldens (in CI), and benchmark thresholds (in CI). It is generated from the tier/tag registry, not hand-written, so it stays honest as the suite grows.
