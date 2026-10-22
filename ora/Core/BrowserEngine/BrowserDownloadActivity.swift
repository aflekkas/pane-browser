import Foundation

/// Per-page ownership, read again after asynchronous discard probes.
/// All mutations occur on WebKit's main thread.
final class BrowserDownloadActivity {
    private var transfers: Set<UUID> = []
    private var isRetired = false
    var isActive: Bool {
        !transfers.isEmpty
    }

    func begin(_ id: UUID) {
        guard !isRetired else { return }
        transfers.insert(id)
    }

    func end(_ id: UUID) {
        transfers.remove(id)
    }

    func clear() {
        isRetired = true
        transfers.removeAll()
    }
}
