import Foundation
import SwiftData
@preconcurrency import WebKit

/// One persisted `WKWebView.interactionState` blob per tab.
///
/// Kept as its own entity (Pane port plan §3.3) so sidebar `@Query` fetches
/// of tab lists never drag blob data through the fetch path, and so the row
/// can be deleted independently of the tab. Blobs use external storage.
/// Registering this model in the app container is an integration step —
/// see `parallel-ports/tabs-integration.md`. Private tabs must never get a
/// row here; their state lives only in memory on the `Tab` itself.
@Model
final class TabSessionSnapshot {
    @Attribute(.unique) var tabID: UUID
    /// The container (== profile / data-store identifier) the blob was
    /// captured under. A blob is meaningless under another data store, so
    /// restores must match this against the tab's current container.
    var containerID: UUID
    @Attribute(.externalStorage) var interactionState: Data
    var capturedAt: Date

    init(tabID: UUID, containerID: UUID, interactionState: Data, capturedAt: Date = Date()) {
        self.tabID = tabID
        self.containerID = containerID
        self.interactionState = interactionState
        self.capturedAt = capturedAt
    }
}

/// SwiftData access for `TabSessionSnapshot`. Every entry point refuses
/// private tabs first: private interaction state is never persisted.
enum TabLifecycleSnapshotStore {
    @discardableResult
    static func save(
        tabID: UUID,
        containerID: UUID,
        data: Data,
        isPrivate: Bool,
        in context: ModelContext,
        persist: ((ModelContext) throws -> Void)? = nil
    ) -> Bool {
        guard !isPrivate else { return false }
        guard let data = TabInteractionStateCodec.validated(data) else {
            delete(tabID: tabID, in: context)
            // Persist invalidation too, so reopen cannot revive the old blob.
            try? context.save()
            return false
        }
        let prior = fetch(tabID: tabID, in: context).map {
            ($0.containerID, $0.interactionState, $0.capturedAt)
        }
        if let existing = fetch(tabID: tabID, in: context) {
            existing.containerID = containerID
            existing.interactionState = data
            existing.capturedAt = Date()
        } else {
            context.insert(TabSessionSnapshot(tabID: tabID, containerID: containerID, interactionState: data))
        }
        do {
            if let persist {
                try persist(context)
            } else {
                try context.save()
            }
            return true
        } catch {
            // Restore the prior checkpoint in memory as well as on disk. A
            // failed write must not turn the next context save into deletion.
            if let prior, let existing = fetch(tabID: tabID, in: context) {
                existing.containerID = prior.0
                existing.interactionState = prior.1
                existing.capturedAt = prior.2
            } else {
                delete(tabID: tabID, in: context)
            }
            return false
        }
    }

    /// Returns the blob only when it was captured under `containerID`;
    /// a stale cross-container blob is deleted and never restored.
    static func restoreData(tabID: UUID, containerID: UUID, in context: ModelContext) -> Data? {
        guard let snapshot = fetch(tabID: tabID, in: context) else { return nil }
        guard snapshot.containerID == containerID,
              let data = TabInteractionStateCodec.validated(snapshot.interactionState)
        else {
            delete(tabID: tabID, in: context)
            return nil
        }
        return data
    }

    static func fetch(tabID: UUID, in context: ModelContext) -> TabSessionSnapshot? {
        let descriptor = FetchDescriptor<TabSessionSnapshot>(predicate: #Predicate { $0.tabID == tabID })
        return try? context.fetch(descriptor).first
    }

    static func delete(tabID: UUID, in context: ModelContext) {
        if let snapshot = fetch(tabID: tabID, in: context) {
            context.delete(snapshot)
        }
    }
}

/// Whether a restore assignment has produced a navigation yet (used to
/// decide the URL-load fallback in `Tab`).
enum TabLifecycleInteractionState {
    static func hasRestoredNavigation(on page: BrowserPage) -> Bool {
        guard let webView = page.contentView as? WKWebView else { return false }
        return webView.backForwardList.currentItem != nil || webView.url != nil
    }
}
