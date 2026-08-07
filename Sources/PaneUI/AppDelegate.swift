// spec: §1
import AppKit
import PaneCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: BrowserWindowController?
    /// Seeds a spread of tabs through the command bus so the sidebar can be
    /// screenshotted and reviewed without synthesising key events — which go to
    /// whichever app is frontmost and are therefore both unreliable and unsafe.
    public var seedDemoTabs = false
    /// A hermetic scene for visual goldens: fixed titles, no navigation, no
    /// favicon fetch. The demo seed is unusable as a golden because titles and
    /// favicons arrive from the network at different times on every run — the
    /// golden then fails against itself, which teaches people to ignore it.
    public var goldenScene = false
    public var storePath: String?
    public var restoreSession = true
    /// Number of tabs to open for the discard benchmark, all on a local fixture
    /// so the measurement is of Pane rather than of the network.
    public var benchDiscardTabs: Int?
    /// Where to write an in-app window capture once seeding settles, then exit.
    public var captureTo: String?
    /// Async because the composite capture awaits WKWebView.takeSnapshot.
    public var onReadyForCapture: ((NSWindow, String) async -> Bool)?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let c = BrowserWindowController(storePath: storePath, restoreSession: restoreSession)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller = c
        if seedDemoTabs { seed(c) }
        if goldenScene { seedGolden(c) }
        if let n = benchDiscardTabs { runDiscardBench(c, tabs: n) }
        if let path = captureTo, let w = c.window {
            // Give the seeded pages time to paint before capturing.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(9))
                let ok = await onReadyForCapture?(w, path) ?? false
                exit(ok ? 0 : 1)
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// spec §6 — full snapshot on terminate, so a clean quit never loses the
    /// last 500ms of debounced writes.
    public func applicationWillTerminate(_ n: Notification) { controller?.saveNow() }

    /// Menu items dispatch the same `Command` values scenarios do (ADR 0006).
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Pane", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Import Passwords…",
                        action: #selector(BrowserWindowController.importCredentials),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Pane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t")
        viewMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "w")
        let reopen = NSMenuItem(title: "Reopen Closed Tab", action: #selector(reopenTab), keyEquivalent: "t")
        reopen.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(reopen)
        viewMenu.addItem(.separator())
        let side = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSide), keyEquivalent: "s")
        side.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(side)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Find…", action: #selector(findInPage), keyEquivalent: "f")
        let next = NSMenuItem(title: "Find Next", action: #selector(findNext), keyEquivalent: "g")
        viewMenu.addItem(next)
        let prev = NSMenuItem(title: "Find Previous", action: #selector(findPrev), keyEquivalent: "G")
        prev.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(prev)
        viewMenu.addItem(.separator())
        let dl = NSMenuItem(title: "Downloads", action: #selector(showDownloads), keyEquivalent: "j")
        viewMenu.addItem(dl)
        viewMenu.addItem(withTitle: "Open Location…", action: #selector(BrowserWindowController.focusAddress), keyEquivalent: "l")
        viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(.separator())
        let back = NSMenuItem(title: "Back", action: #selector(backPage), keyEquivalent: "[")
        back.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(back)
        let fwd = NSMenuItem(title: "Forward", action: #selector(forwardPage), keyEquivalent: "]")
        fwd.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(fwd)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Space switching. ⌃⇥ / ⌃⇧⇥ is what Arc and Zen use.
        let spacesItem = NSMenuItem()
        let spacesMenu = NSMenu(title: "Spaces")
        let nextSpace = NSMenuItem(title: "Next Space", action: #selector(nextSpace), keyEquivalent: "]")
        nextSpace.keyEquivalentModifierMask = [.command, .shift]
        spacesMenu.addItem(nextSpace)
        let prevSpace = NSMenuItem(title: "Previous Space", action: #selector(prevSpace), keyEquivalent: "[")
        prevSpace.keyEquivalentModifierMask = [.command, .shift]
        spacesMenu.addItem(prevSpace)
        spacesItem.submenu = spacesMenu
        main.addItem(spacesItem)

        // ⌘1…⌘9 select tabs, ⌘9 the last — matching every other browser.
        let tabsItem = NSMenuItem()
        let tabsMenu = NSMenu(title: "Tabs")
        for n in 1...9 {
            let mi = NSMenuItem(title: n == 9 ? "Last Tab" : "Tab \(n)",
                                action: #selector(selectTabN(_:)), keyEquivalent: "\(n)")
            mi.tag = n
            tabsMenu.addItem(mi)
        }
        tabsItem.submenu = tabsMenu
        main.addItem(tabsItem)

        NSApp.mainMenu = main
    }

    /// Every seeded tab goes through `dispatch`, the same path a menu item
    /// takes (ADR 0006).
    private func seed(_ c: BrowserWindowController) {
        for (kind, url) in [
            (TabKind.essential,  "gmail.com"),
            (.essential,  "calendar.google.com"),
            (.essential,  "github.com"),
            (.essential,  "figma.com"),
            (.essential,  "linear.app"),
            (.pinned,     "developer.apple.com"),
            (.pinned,     "news.ycombinator.com"),
            (.ephemeral,  "example.com"),
            (.ephemeral,  "duckduckgo.com"),
        ] as [(TabKind, String)] {
            c.dispatch(.newTab(kind: kind))
            c.dispatch(.navigate(url))
        }
    }

    /// spec §4 — the measurement the memory claim actually rests on.
    /// Prints markers the shell driver measures around; it cannot attribute
    /// WebContent memory itself, because those processes are launchd-owned
    /// (PPID 1), not our children.
    private func runDiscardBench(_ c: BrowserWindowController, tabs n: Int) {
        let fixture = URL(fileURLWithPath: "Fixtures/bench-page.html").standardizedFileURL
        for _ in 0..<n {
            c.dispatch(.newTab(kind: .ephemeral))
            c.dispatch(.navigate(fixture.absoluteString))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            print("BENCH_LOADED tabs=\(c.tabCount) engines=\(c.liveEngineCount)")
            fflush(stdout)
            try? await Task.sleep(for: .seconds(6))
            c.forceSweepForBench()
            try? await Task.sleep(for: .seconds(6))
            print("BENCH_DISCARDED tabs=\(c.tabCount) engines=\(c.liveEngineCount)")
            fflush(stdout)
            try? await Task.sleep(for: .seconds(6))
            exit(0)
        }
    }

    /// Deterministic by construction: no network, no timers, no async fill.
    private func seedGolden(_ c: BrowserWindowController) {
        for (kind, title) in [
            (TabKind.essential, "Mail"), (.essential, "Calendar"),
            (.essential, "Code"), (.essential, "Design"), (.essential, "Tasks"),
            (.pinned, "Documentation"), (.pinned, "Issue Tracker"),
            (.ephemeral, "Search Results"), (.ephemeral, "Article"),
            (.ephemeral, "Reference"),
        ] as [(TabKind, String)] {
            c.addGoldenTab(kind: kind, title: title)
        }
    }

    @objc private func nextSpace()   { controller?.dispatch(.nextSpace) }
    @objc private func prevSpace()   { controller?.dispatch(.previousSpace) }
    @objc private func selectTabN(_ sender: NSMenuItem) {
        controller?.dispatch(.selectTabIndex(sender.tag))
    }
    @objc private func findInPage()  { controller?.performFind() }
    @objc private func findNext()    { controller?.findNext() }
    @objc private func findPrev()    { controller?.findPrevious() }
    @objc private func showDownloads() { controller?.showDownloadsPanel() }
    @objc private func reloadPage()  { controller?.dispatch(.reload) }
    @objc private func newTab()      { controller?.dispatch(.newTab(kind: .ephemeral)) }
    @objc private func closeTab()    { controller?.dispatch(.closeTab(nil)) }
    @objc private func reopenTab()   { controller?.dispatch(.reopenClosedTab) }
    @objc private func toggleSide()  { controller?.dispatch(.toggleSidebar) }
    @objc private func backPage()    { controller?.dispatch(.goBack) }
    @objc private func forwardPage() { controller?.dispatch(.goForward) }
}
