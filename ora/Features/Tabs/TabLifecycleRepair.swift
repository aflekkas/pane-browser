import Foundation

enum TabLifecycleCaptureOutcome: Equatable {
    case saved
    case pendingRestore
    case urlOnly
    case saveFailed
}

extension Tab {
    /// Every user section change, including drag/drop, updates durable intent.
    func setUserSection(_ section: TabType) {
        type = section
        userPinnedExplicitly = section == .pinned
        savedURL = section == .normal ? nil : url
    }

    func captureLifecycleCheckpoint() -> TabLifecycleCaptureOutcome {
        guard let page = browserPage,
              page.profileIdentifier == container.id, page.isPrivateProfile == isPrivate else { return .urlOnly }
        // The queued checkpoint is authoritative until WebKit actually applies
        // it. A newly created view has a valid but empty interactionState blob.
        guard !page.hasPendingLifecycleRestore else { return .pendingRestore }
        if let currentURL = page.lifecycleFallbackURL {
            url = currentURL
            urlString = currentURL.absoluteString
        }
        guard page.isLifecycleCaptureReady, let data = page.captureInteractionState() else {
            // Loading, not-yet-ready and oversized pages retain their URL and
            // any existing checkpoint. They must not block application quit.
            return .urlOnly
        }
        if isPrivate {
            privateInteractionState = data
            return .saved
        }
        guard let context = modelContext else { return .saveFailed }
        let saved = TabLifecycleSnapshotStore.save(
            tabID: id, containerID: container.id, data: data, isPrivate: false, in: context
        )
        lifecycleSnapshotSaveFailed = !saved
        return saved ? .saved : .saveFailed
    }

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
