import Foundation
@testable import Ora
import Testing

struct TabLifecycleTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let userDelay: TimeInterval = 60 * 60

    private func facts(
        kind: TabLifecycleKind = .ephemeral,
        state: TabLifecycleState = .live,
        hasLivePage: Bool = true,
        idle: TimeInterval,
        isActive: Bool = false,
        isPlayingAudio: Bool = false,
        hasActiveMediaSession: Bool = false,
        hasUnsavedFormState: Bool = false,
        userPinnedExplicitly: Bool = false,
        isLoading: Bool = false
    ) -> TabLifecycleFacts {
        TabLifecycleFacts(
            id: UUID(),
            kind: kind,
            state: state,
            hasLivePage: hasLivePage,
            lastAccessedAt: t0.addingTimeInterval(-idle),
            isActive: isActive,
            isPlayingAudio: isPlayingAudio,
            hasActiveMediaSession: hasActiveMediaSession,
            hasUnsavedFormState: hasUnsavedFormState,
            userPinnedExplicitly: userPinnedExplicitly,
            isLoading: isLoading
        )
    }

    private var policy: TabLifecyclePolicy {
        TabLifecyclePolicy(userUnloadDelay: userDelay)
    }

    @Test func nothingIsCandidateBeforeCheckpointThreshold() {
        #expect(policy.stage(for: facts(idle: 60), at: t0) == nil)
        #expect(policy.stage(for: facts(kind: .pinned, idle: 6 * 60), at: t0) == .checkpoint)
        #expect(policy.stage(for: facts(kind: .essential, idle: 6 * 60), at: t0) == nil)
    }

    @Test func checkpointPrecedesDiscard() {
        // Past Pane's 5-minute ephemeral checkpoint, before the user's
        // 1-hour unload delay: snapshot only, page stays live.
        #expect(policy.stage(for: facts(idle: 6 * 60), at: t0) == .checkpoint)
        #expect(policy.stage(for: facts(idle: userDelay), at: t0) == .discard)
    }

    @Test func pinnedDiscardsLaterThanEphemeral() {
        let pinned = facts(kind: .pinned, idle: 16 * 60)
        let ephemeral = facts(kind: .ephemeral, idle: 16 * 60)
        #expect(policy.stage(for: pinned, at: t0) == .checkpoint)
        #expect(policy.stage(for: ephemeral, at: t0) == .checkpoint)
        #expect(policy.stage(for: facts(kind: .pinned, idle: userDelay), at: t0) == .discard)
    }

    @Test func activeTabIsNeverCandidate() {
        #expect(policy.stage(for: facts(idle: 10 * userDelay, isActive: true), at: t0) == nil)
    }

    @Test func discardedOrPagelessTabsAreNotCandidates() {
        #expect(policy.stage(for: facts(state: .discarded, idle: 10 * userDelay), at: t0) == nil)
        #expect(policy.stage(for: facts(hasLivePage: false, idle: 10 * userDelay), at: t0) == nil)
    }

    @Test func playingAudioBlocksDiscardButNotCheckpoint() {
        let tab = facts(idle: 10 * userDelay, isPlayingAudio: true)
        #expect(tab.isDiscardable == false)
        #expect(policy.stage(for: tab, at: t0) == .checkpoint)
    }

    @Test func activeMediaSessionBlocksDiscard() {
        let tab = facts(idle: 10 * userDelay, hasActiveMediaSession: true)
        #expect(tab.blockingReasons == ["activeMediaSession"])
        #expect(policy.stage(for: tab, at: t0) == .checkpoint)
    }

    @Test func unsavedFormStateBlocksDiscard() {
        let tab = facts(idle: 10 * userDelay, hasUnsavedFormState: true)
        #expect(tab.blockingReasons == ["unsavedFormState"])
        #expect(policy.stage(for: tab, at: t0) == .checkpoint)
    }

    @Test func explicitlyPinnedBlocksDiscard() {
        let tab = facts(kind: .pinned, idle: 10 * userDelay, userPinnedExplicitly: true)
        #expect(tab.blockingReasons == ["userPinnedExplicitly"])
        #expect(policy.stage(for: tab, at: t0) == .checkpoint)
    }

    @Test func loadingBlocksDiscard() {
        let tab = facts(idle: 10 * userDelay, isLoading: true)
        #expect(policy.stage(for: tab, at: t0) == .checkpoint)
    }

    @Test func neverUnloadSettingDisablesDiscardOnly() {
        let never = TabLifecyclePolicy(userUnloadDelay: TabLifecyclePolicy.neverUnloadDelay)
        #expect(never.stage(for: facts(idle: 400 * 24 * 60 * 60), at: t0) == .checkpoint)
        #expect(never.discardCandidates(from: [facts(idle: 400 * 24 * 60 * 60)], at: t0).isEmpty)
        #expect(never.checkpointCandidates(from: [facts(idle: 6 * 60)], at: t0).count == 1)
    }

    @Test func candidateListsPartitionByStage() {
        let checkpoint = facts(idle: 6 * 60)
        let discard = facts(idle: userDelay)
        let fresh = facts(idle: 10)
        let all = [checkpoint, discard, fresh]
        #expect(policy.checkpointCandidates(from: all, at: t0) == [checkpoint.id])
        #expect(policy.discardCandidates(from: all, at: t0) == [discard.id])
    }

    @Test func noResultProbeBlocksDiscard() {
        // `nil` is what a JS error / no-result evaluation delivers; the
        // timeout and error paths in `probe` likewise produce `.unknown`.
        let activity = TabLifecycleActivityProbe.parse(nil)
        #expect(activity == .unknown)
        #expect(activity.probeFailed)
        #expect(activity.hasUnsavedFormState)
        #expect(activity.blocksDiscard)
        // Even with no form detected, unknown blocks: stage stays checkpoint.
        let tab = facts(idle: 10 * userDelay, hasUnsavedFormState: activity.hasUnsavedFormState)
        #expect(policy.stage(for: tab, at: t0) == .checkpoint)
    }

    @Test func unknownProbeBlocksDiscardRegardlessOfForm() {
        #expect(TabLifecycleActivity.unknown.hasUnsavedFormState)
        #expect(TabLifecycleActivity.unknown.blocksDiscard)
        let noForm = TabLifecycleActivity(probeFailed: true, hasForm: false)
        #expect(noForm.hasUnsavedFormState)
    }

    @Test func malformedPayloadBlocksDiscard() {
        #expect(TabLifecycleActivityProbe.parse("junk") == .unknown)
        #expect(TabLifecycleActivityProbe.parse(["state": "bogus"]) == .unknown)
        #expect(TabLifecycleActivityProbe.parse(["v": 2, "probeFailed": true]) == .unknown)
        // Missing fields and wrong types are malformed, not clear.
        #expect(TabLifecycleActivityProbe.parse(["v": 2, "hasForm": true]) == .unknown)
        #expect(TabLifecycleActivityProbe.parse([
            "v": 2, "hasForm": "yes", "dirty": false,
            "mediaSessionActive": false, "uninspectableFrames": false, "playing": false
        ]) == .unknown)
        #expect(TabLifecycleActivityProbe.parse([String: Any]()) == .unknown)
    }

    @Test func dirtyFormAndMediaSessionGuardsCoexist() {
        let activity = TabLifecycleActivityProbe.parse([
            "v": 2, "hasForm": true, "dirty": true,
            "mediaSessionActive": true, "uninspectableFrames": false, "playing": true
        ])
        // Neither guard masks the other.
        #expect(activity.hasUnsavedFormState)
        #expect(activity.hasActiveMediaSession)
        #expect(activity.isPlayingMedia)
        let tab = facts(
            idle: 10 * userDelay,
            isPlayingAudio: activity.isPlayingMedia,
            hasActiveMediaSession: activity.hasActiveMediaSession,
            hasUnsavedFormState: activity.hasUnsavedFormState
        )
        #expect(Set(tab.blockingReasons) == ["playingAudio", "activeMediaSession", "unsavedFormState"])
        #expect(policy.stage(for: tab, at: t0) == .checkpoint)
    }

    @Test func uninspectableFramesBlockDiscard() {
        let activity = TabLifecycleActivityProbe.parse([
            "v": 2, "hasForm": false, "dirty": false,
            "mediaSessionActive": false, "uninspectableFrames": true, "playing": false
        ])
        #expect(activity.hasUninspectableFrames)
        #expect(activity.hasUnsavedFormState)
        #expect(activity.blocksDiscard)
    }

    @Test func clearProbeAllowsDiscard() {
        let activity = TabLifecycleActivityProbe.parse([
            "v": 2, "hasForm": true, "dirty": false,
            "mediaSessionActive": false, "uninspectableFrames": false, "playing": false
        ])
        #expect(activity.probeFailed == false)
        #expect(activity.hasUnsavedFormState == false)
        #expect(activity.hasActiveMediaSession == false)
        #expect(activity.blocksDiscard == false)
    }

    @Test func probeScriptCoversFramesMediaSessionAndIndependentGuards() {
        let script = TabLifecycleActivityProbe.script
        #expect(script.contains("uninspectableFrames"))
        #expect(script.contains("contentDocument"))
        #expect(script.contains("mediaSession"))
        #expect(script.contains("dirty"))
        #expect(script.contains("mediaSessionActive"))
    }

    @Test func codecRejectsEmptyAndOversizeBlobs() {
        #expect(TabInteractionStateCodec.validated(nil) == nil)
        #expect(TabInteractionStateCodec.validated(Data()) == nil)
        let oversize = Data(count: TabInteractionStateCodec.maximumByteCount + 1)
        #expect(TabInteractionStateCodec.validated(oversize) == nil)
        let atLimit = Data(count: TabInteractionStateCodec.maximumByteCount)
        #expect(TabInteractionStateCodec.validated(atLimit)?.count == TabInteractionStateCodec.maximumByteCount)
        #expect(TabInteractionStateCodec.validated(Data([0x01, 0x02])) == Data([0x01, 0x02]))
    }

    @Test func profileTeardownNeedsInactiveDiscardedNonCurrentContainer() {
        let old = t0.addingTimeInterval(-11 * 60)
        #expect(TabLifecycleProfileTeardown.isEligible(
            containerLastAccessedAt: old, isCurrentContainer: false, allTabsDiscarded: true, at: t0
        ))
        #expect(!TabLifecycleProfileTeardown.isEligible(
            containerLastAccessedAt: old, isCurrentContainer: true, allTabsDiscarded: true, at: t0
        ))
        #expect(!TabLifecycleProfileTeardown.isEligible(
            containerLastAccessedAt: old, isCurrentContainer: false, allTabsDiscarded: false, at: t0
        ))
        #expect(!TabLifecycleProfileTeardown.isEligible(
            containerLastAccessedAt: t0.addingTimeInterval(-5 * 60),
            isCurrentContainer: false, allTabsDiscarded: true, at: t0
        ))
    }
}
