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
