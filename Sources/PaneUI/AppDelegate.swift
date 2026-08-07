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
    /// Where to write an in-app window capture once seeding settles, then exit.
    public var captureTo: String?
    public var onReadyForCapture: ((NSWindow, String) -> Bool)?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let c = BrowserWindowController()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller = c
        if seedDemoTabs { seed(c) }
        if let path = captureTo, let w = c.window {
            // Give the seeded pages time to paint before capturing.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(9))
                let ok = onReadyForCapture?(w, path) ?? false
                exit(ok ? 0 : 1)
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// Menu items dispatch the same `Command` values scenarios do (ADR 0006).
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Pane", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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

    @objc private func reloadPage()  { controller?.dispatch(.reload) }
    @objc private func newTab()      { controller?.dispatch(.newTab(kind: .ephemeral)) }
    @objc private func closeTab()    { controller?.dispatch(.closeTab(nil)) }
    @objc private func reopenTab()   { controller?.dispatch(.reopenClosedTab) }
    @objc private func toggleSide()  { controller?.dispatch(.toggleSidebar) }
    @objc private func backPage()    { controller?.dispatch(.goBack) }
    @objc private func forwardPage() { controller?.dispatch(.goForward) }
}
