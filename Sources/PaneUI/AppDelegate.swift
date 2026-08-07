// spec: §1
import AppKit
import PaneCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: BrowserWindowController?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let c = BrowserWindowController()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller = c
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

    @objc private func reloadPage()  { controller?.dispatch(.reload) }
    @objc private func backPage()    { controller?.dispatch(.goBack) }
    @objc private func forwardPage() { controller?.dispatch(.goForward) }
}
