import AppKit
import Foundation
import SwiftData
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable automatic window tabbing for all NSWindow instances
        NSWindow.allowsAutomaticWindowTabbing = false
        AppearanceManager.shared.updateAppearance()
        #if DEBUG
            Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle")?.load()
            Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/macOSSwiftUISupport.bundle")?.load()
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let targetWindow = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
        guard let targetWindow else { return .terminateNow }
        NotificationCenter.default.post(name: .quitRequested, object: targetWindow)
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleIncomingURLs(urls)
    }

    func getWindow() -> NSWindow? {
        if let key = NSApp.keyWindow {
            return key
        }
        if let visible = NSApp.windows.first(where: { $0.isVisible }) {
            return visible
        }
        if let any = NSApp.windows.first {
            any.makeKeyAndOrderFront(nil)
            return any
        }
        return WindowFactory.makeMainWindow(rootView: OraRoot())
    }

    /// Delivery registry for external URLs. Injectable for tests.
    var urlRegistry = BrowserURLRecipientRegistry.shared

    /// Creates a browser window when a URL arrives with no ready
    /// recipient. Injectable for tests; production uses WindowFactory.
    var browserWindowFactory: () -> Void = {
        _ = WindowFactory.makeMainWindow(rootView: OraRoot())
    }

    func handleIncomingURLs(_ urls: [URL]) {
        for url in urls {
            urlRegistry.deliver(url, needsWindow: browserWindowFactory)
        }
    }

    func consumePendingOpenURLs() -> [URL] {
        urlRegistry.consumePending()
    }
}

/// Explicit ready-recipient delivery for external URLs.
///
/// A URL is delivered immediately only when a browser root has
/// registered itself ready (OraRoot onAppear). Otherwise it is queued
/// (FIFO, exactly once) and a browser window is requested; registration
/// drains the queue after the recipient is in place. Window existence
/// alone is never treated as readiness — an unrelated or not-yet-ready
/// window cannot swallow a URL, and a closed recipient (unregistered)
/// returns delivery to the queue instead of dropping the URL.
final class BrowserURLRecipientRegistry {
    static let shared = BrowserURLRecipientRegistry()

    private var handler: ((URL) -> Void)?
    private var handlerToken: UUID?
    private var queue = OpenURLQueue()

    var isReady: Bool {
        handler != nil
    }

    var pendingCount: Int {
        queue.urls.count
    }

    @discardableResult
    func register(_ handler: @escaping (URL) -> Void) -> UUID {
        let token = UUID()
        self.handler = handler
        handlerToken = token
        for url in queue.drain() {
            handler(url)
        }
        return token
    }

    func unregister(token: UUID) {
        guard handlerToken == token else { return }
        handler = nil
        handlerToken = nil
    }

    func deliver(_ url: URL, needsWindow: () -> Void = {}) {
        if let handler {
            handler(url)
            return
        }
        queue.enqueue([url])
        needsWindow()
    }

    func consumePending() -> [URL] {
        queue.drain()
    }
}

/// FIFO of external URLs waiting for the first browser window.
struct OpenURLQueue {
    private(set) var urls: [URL] = []

    var isEmpty: Bool {
        urls.isEmpty
    }

    mutating func enqueue(_ newURLs: [URL]) {
        urls.append(contentsOf: newURLs)
    }

    mutating func drain() -> [URL] {
        defer { urls = [] }
        return urls
    }
}

func deleteSwiftDataStore(_ loc: String) {
    let fileManager = FileManager.default
    let storeURL = URL.applicationSupportDirectory.appending(path: loc)
    let shmURL = storeURL.appendingPathExtension("-shm")
    let walURL = storeURL.appendingPathExtension("-wal")
    try? fileManager.removeItem(at: storeURL)
    try? fileManager.removeItem(at: shmURL)
    try? fileManager.removeItem(at: walURL)
}

class AppState: ObservableObject {
    @Published var showLauncher: Bool = false
    @Published var launcherSearchText: String = ""
    @Published var showFinderIn: UUID?
    @Published var isFloatingTabSwitchVisible: Bool = false
    @Published var isFullscreen: Bool = false
    @Published var isURLBarEditing: Bool = false
}

@main
struct OraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Shared model container that uses the same configuration as the main browser
    private let sharedModelContainer: ModelContainer? =
        try? ModelConfiguration.createOraContainer(isPrivate: false)

    var body: some Scene {
        WindowGroup(id: "normal") {
            OraRoot()
                .frame(minWidth: 500, minHeight: 360)
                .environmentObject(DefaultBrowserManager.shared)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])

        WindowGroup("Private", id: "private") {
            OraRoot(isPrivate: true)
                .frame(minWidth: 500, minHeight: 360)
                .environmentObject(DefaultBrowserManager.shared)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])

        WindowGroup("Settings", id: "settings") {
            if let sharedModelContainer {
                SettingsWindowRoot()
                    .environmentObject(AppearanceManager.shared)
                    .environmentObject(UpdateService.shared)
                    .environmentObject(DefaultBrowserManager.shared)
                    .modelContainer(sharedModelContainer)
            } else {
                // Fallback UI when SwiftData is completely broken
                VStack {
                    Text("Settings Unavailable")
                        .font(.title)
                }
                .padding()
                .frame(width: 400, height: 300)
            }
        }
        .windowToolbarStyle(UnifiedCompactWindowToolbarStyle())
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 640)
        .commands { OraCommands() }
    }
}
