import AppKit

/// Owns the one visible challenge for a page. Replacement and every page
/// lifetime boundary cancel the operation before UI or WebKit can act again.
@MainActor
final class BrowserAuthenticationSession {
    private var current: BrowserAuthenticationOperation?

    func begin(window: NSWindow?) -> BrowserAuthenticationOperation {
        cancel()
        let operation = BrowserAuthenticationOperation(window: window)
        current = operation
        return operation
    }

    func cancel() {
        current?.cancel()
        current = nil
    }
}

@MainActor
final class BrowserAuthenticationOperation {
    let id = UUID()
    private(set) var isActive = true
    var onCancel: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    init(window: NSWindow?) {
        if let window {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        }
    }

    func cancel() {
        guard isActive else { return }
        isActive = false
        let cancel = onCancel
        onCancel = nil
        removeObserver()
        cancel?()
    }

    func finish() {
        isActive = false
        onCancel = nil
        removeObserver()
    }

    private func removeObserver() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
}
