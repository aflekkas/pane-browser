import Foundation

/// Per-page ownership, read again after asynchronous discard probes.
/// All mutations occur on WebKit's main thread.
final class BrowserDownloadActivity {
    private var transfers: Set<UUID> = []
    var isActive: Bool {
        !transfers.isEmpty
    }

    func begin(_ id: UUID) {
        transfers.insert(id)
    }

    func end(_ id: UUID) {
        transfers.remove(id)
    }

    func clear() {
        transfers.removeAll()
    }
}
