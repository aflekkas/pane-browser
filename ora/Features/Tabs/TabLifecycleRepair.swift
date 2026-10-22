import Foundation

extension Tab {
    /// Called before navigation and on route changes. Pending probes are bound
    /// to page identity plus navigation generation; stale blobs are ineligible.
    func invalidateLifecycleSnapshot() {
        deletePersistedInteractionState()
        lastLifecycleActivity = nil
        hasActiveMediaSession = false
        hasUnsavedFormState = false
        // Audio is maintained independently by the media bridge. A navigation
        // does not grant permission to discard a still-playing document.
        if !isPrivate {
            do { try modelContext?.save() } catch { lifecycleSnapshotSaveFailed = true }
        }
    }

    func finishLifecycleDiscard() {
        destroyWebView()
        isDiscarded = true
        isWebViewReady = false
        isLoading = false
        loadingProgress = 0
        lastLifecycleActivity = nil
        hasActiveMediaSession = false
        hasUnsavedFormState = false
        isPlayingMedia = false
    }

    /// Never trusts the active/download state captured when the probe started.
    /// A page move, replacement or navigation invalidates its result.
    func probeLifecycleForDiscard(policy: TabLifecyclePolicy) {
        guard let page = browserPage, !page.hasActiveDownloads else { return }
        let generation = page.passwordNavigationGeneration
        let profileID = container.id
        TabLifecycleActivityProbe.probe(page: page) { [weak self, weak page] activity in
            guard let self, let page, browserPage === page,
                  container.id == profileID, page.profileIdentifier == profileID,
                  page.passwordNavigationGeneration == generation else { return }
            lastLifecycleActivity = activity
            hasActiveMediaSession = activity.hasActiveMediaSession
            hasUnsavedFormState = activity.hasUnsavedFormState
            // Do not latch a transient probe's audio value into the media
            // bridge's flag: the next clear probe must be able to clear it.
            guard !activity.blocksDiscard, !page.hasActiveDownloads else { return }
            MainActor.assumeIsolated {
                guard let manager = self.tabManager,
                      policy.stage(for: self.lifecycleFacts(isActive: manager.isActive(self)), at: Date()) == .discard,
                      !page.isLoading else { return }
                self.discard()
            }
        }
    }
}
