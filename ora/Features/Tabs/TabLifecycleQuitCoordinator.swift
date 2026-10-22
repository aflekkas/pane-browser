import AppKit
import Foundation

/// Registers every window's manager independently of URL routing and focus.
/// Weak ownership does not keep closed windows or their WebKit pages alive.
@MainActor
final class TabLifecycleQuitCoordinator {
    static let shared = TabLifecycleQuitCoordinator()

    private final class Entry {
        weak var manager: TabManager?

        init(_ manager: TabManager) {
            self.manager = manager
        }
    }

    enum SaveFailureChoice { case retry, quitAnyway, cancel }

    /// Only a durable save error needs a decision. Capture limitations already
    /// fall back to saved tab URLs in each manager.
    func requestTermination(
        capture: (() -> Bool)? = nil,
        onSaveFailure: () -> SaveFailureChoice,
        reply: (Bool) -> Void
    ) {
        while !(capture?() ?? captureAllLiveSnapshots()) {
            switch onSaveFailure() {
            case .retry: continue
            case .quitAnyway: reply(true)
                return
            case .cancel: reply(false)
                return
            }
        }
        reply(true)
    }

    func replyToApplicationTermination() {
        requestTermination(onSaveFailure: {
            let alert = NSAlert()
            alert.messageText = "Pane couldn't save your session"
            alert.informativeText = "Retry saving, or quit anyway. Recent tab history and scroll positions may be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .retry
            case .alertSecondButtonReturn: return .quitAnyway
            default: return .cancel
            }
        }, reply: { NSApp.reply(toApplicationShouldTerminate: $0) })
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(_ manager: TabManager) {
        entries = entries.filter { $0.value.manager != nil }
        entries[ObjectIdentifier(manager)] = Entry(manager)
    }

    /// Main-actor serialization completes each context's capture/save before
    /// the application replies to termination. Do not short-circuit on failure:
    /// the other windows must still checkpoint. Failure keeps the app running.
    @discardableResult
    func captureAllLiveSnapshots() -> Bool {
        entries = entries.filter { $0.value.manager != nil }
        var succeeded = true
        for entry in entries.values {
            if let manager = entry.manager, !manager.captureAllLiveSnapshots() {
                succeeded = false
            }
        }
        return succeeded
    }
}
