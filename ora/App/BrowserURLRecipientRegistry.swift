import AppKit
import Foundation

/// Routes external URLs to a ready browser window, using current AppKit focus
/// and front-to-back order rather than the order in which roots appeared.
@MainActor
final class BrowserURLRecipientRegistry: NSObject {
    static let shared = BrowserURLRecipientRegistry()

    private struct Recipient {
        weak var window: NSWindow?
        let token: UUID
        let handler: (URL) -> Void
    }

    private var recipients: [ObjectIdentifier: Recipient] = [:]
    private var queue = OpenURLQueue()
    private var isDraining = false
    private var windowRequested = false
    private var needsWindow: (() -> Void)?
    private let candidateWindows: @MainActor () -> [NSWindow]

    /// Tests inject focus/order without showing or taking control of real windows.
    init(candidateWindows: @escaping @MainActor () -> [NSWindow] = {
        [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows + NSApp.windows
    }) {
        self.candidateWindows = candidateWindows
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil
        )
    }

    var isReady: Bool {
        selectedRecipient() != nil
    }

    var pendingCount: Int {
        queue.urls.count
    }

    /// The handler must not strongly capture the window or its owning root.
    /// Re-registering one window replaces only that window's recipient.
    @discardableResult
    func register(window: NSWindow, handler: @escaping (URL) -> Void) -> UUID {
        let token = UUID()
        recipients[ObjectIdentifier(window)] = Recipient(window: window, token: token, handler: handler)
        windowRequested = false
        drain()
        return token
    }

    func unregister(token: UUID) {
        recipients = recipients.filter { $0.value.token != token && $0.value.window != nil }
    }

    func deliver(_ urls: [URL], needsWindow: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        // Enqueue the whole incoming batch before invoking any user code. A
        // reentrant arrival must follow all URLs already accepted in this batch.
        queue.enqueue(urls)
        self.needsWindow = needsWindow
        drain()
    }

    private func selectedRecipient() -> Recipient? {
        recipients = recipients.filter { $0.value.window != nil }
        for window in candidateWindows() {
            if let recipient = recipients[ObjectIdentifier(window)], recipient.window === window {
                return recipient
            }
        }
        return nil
    }

    private func drain() {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while !queue.isEmpty {
            if let recipient = selectedRecipient(), let url = queue.popFirst() {
                // Remove before calling out; reentrant registration/delivery
                // cannot replay this URL or overtake the remaining queue.
                recipient.handler(url)
            } else {
                guard !windowRequested, let needsWindow else { return }
                windowRequested = true
                needsWindow()
                // Creation may register synchronously, or much later. Only an
                // actual ready registration permits draining, never creation alone.
                guard selectedRecipient() != nil else { return }
            }
        }
        needsWindow = nil
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        recipients.removeValue(forKey: ObjectIdentifier(window))
    }
}

/// FIFO of external URLs waiting for a ready browser recipient.
struct OpenURLQueue {
    private(set) var urls: [URL] = []

    var isEmpty: Bool {
        urls.isEmpty
    }

    mutating func enqueue(_ newURLs: [URL]) {
        urls.append(contentsOf: newURLs)
    }

    mutating func popFirst() -> URL? {
        urls.isEmpty ? nil : urls.removeFirst()
    }
}
