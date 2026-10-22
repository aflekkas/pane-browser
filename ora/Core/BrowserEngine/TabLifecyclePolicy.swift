import Foundation

/// Pane tab kind (spec §4), mapped from Ora's `TabType` at the call site so
/// this file stays free of SwiftData and WebKit and is unit-testable.
enum TabLifecycleKind: String, Sendable, Equatable {
    case ephemeral
    case pinned
    case essential

    /// Idle time before a live tab may be checkpointed (stage 1).
    var checkpointAfter: TimeInterval {
        switch self {
        case .ephemeral:
            5 * 60
        case .pinned, .essential:
            15 * 60
        }
    }
}

enum TabLifecycleState: String, Sendable, Equatable {
    case live
    case discarded
}

/// Everything the discard policy needs, as a value. Callers build this from
/// a live `Tab`; the policy itself never touches a model or a web view.
struct TabLifecycleFacts: Sendable, Equatable {
    let id: UUID
    let kind: TabLifecycleKind
    let state: TabLifecycleState
    let hasLivePage: Bool
    let lastAccessedAt: Date?
    let isActive: Bool
    let isPlayingAudio: Bool
    let hasActiveMediaSession: Bool
    /// Already fail-closed at the call site: a tab with a detected form
    /// whose dirtiness is unknown must arrive here as `true`.
    let hasUnsavedFormState: Bool
    let userPinnedExplicitly: Bool
    let isLoading: Bool

    init(
        id: UUID,
        kind: TabLifecycleKind,
        state: TabLifecycleState,
        hasLivePage: Bool,
        lastAccessedAt: Date?,
        isActive: Bool,
        isPlayingAudio: Bool = false,
        hasActiveMediaSession: Bool = false,
        hasUnsavedFormState: Bool = false,
        userPinnedExplicitly: Bool = false,
        isLoading: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.hasLivePage = hasLivePage
        self.lastAccessedAt = lastAccessedAt
        self.isActive = isActive
        self.isPlayingAudio = isPlayingAudio
        self.hasActiveMediaSession = hasActiveMediaSession
        self.hasUnsavedFormState = hasUnsavedFormState
        self.userPinnedExplicitly = userPinnedExplicitly
        self.isLoading = isLoading
    }

    /// Pane spec §4: the never-discard conditions, in one place.
    var isDiscardable: Bool {
        blockingReasons.isEmpty
    }

    var blockingReasons: [String] {
        var reasons: [String] = []
        if isPlayingAudio {
            reasons.append("playingAudio")
        }
        if hasActiveMediaSession {
            reasons.append("activeMediaSession")
        }
        if hasUnsavedFormState {
            reasons.append("unsavedFormState")
        }
        if userPinnedExplicitly {
            reasons.append("userPinnedExplicitly")
        }
        if isLoading {
            reasons.append("loading")
        }
        return reasons
    }
}

enum TabLifecycleStage: String, Sendable, Equatable {
    /// Capture `interactionState` only; the page stays live. This makes a
    /// later discard (or a crash) restorable before anything is unloaded.
    case checkpoint
    /// Capture, then deallocate the web view. The only stage that
    /// reclaims memory (ADR 0001: there is no frozen tier).
    case discard
}

/// Conservative two-stage idle unload.
///
/// Stage 1 fires at Pane's per-kind thresholds and only snapshots state.
/// Stage 2 (the destructive unload) additionally waits for the user's own
/// `tabAliveTimeout`, so this port never unloads sooner than the setting
/// Ora already exposes. A `userUnloadDelay` at or beyond one year is Ora's
/// "Never" sentinel and disables stage 2 entirely.
struct TabLifecyclePolicy: Sendable, Equatable {
    var userUnloadDelay: TimeInterval

    static let neverUnloadDelay: TimeInterval = 365 * 24 * 60 * 60

    var userUnloadEnabled: Bool {
        userUnloadDelay < Self.neverUnloadDelay
    }

    /// Earliest idle time at which stage 2 may fire for `kind`.
    func discardAfter(for kind: TabLifecycleKind) -> TimeInterval? {
        guard userUnloadEnabled else { return nil }
        return max(2 * kind.checkpointAfter, userUnloadDelay)
    }

    func stage(for facts: TabLifecycleFacts, at now: Date) -> TabLifecycleStage? {
        guard facts.state == .live, facts.hasLivePage, !facts.isActive else { return nil }
        guard let lastAccessedAt = facts.lastAccessedAt else { return nil }
        let idle = now.timeIntervalSince(lastAccessedAt)
        guard idle >= facts.kind.checkpointAfter else { return nil }
        guard facts.isDiscardable else { return .checkpoint }
        if let discardAfter = discardAfter(for: facts.kind), idle >= discardAfter {
            return .discard
        }
        return .checkpoint
    }

    func checkpointCandidates(from facts: [TabLifecycleFacts], at now: Date) -> [UUID] {
        facts.filter { stage(for: $0, at: now) == .checkpoint }.map(\.id)
    }

    func discardCandidates(from facts: [TabLifecycleFacts], at now: Date) -> [UUID] {
        facts.filter { stage(for: $0, at: now) == .discard }.map(\.id)
    }
}

/// Bounds and validation for interaction-state blobs. WebKit applies no
/// size limit and a non-`Data` or undecodable blob fails silently, so
/// every blob passes through here before it is persisted or assigned.
enum TabInteractionStateCodec {
    /// 4 MiB. Oversize blobs are dropped and restore falls back to a URL
    /// load rather than persisting unbounded per-tab state (plan §3.4.5).
    static let maximumByteCount = 4 * 1024 * 1024

    static func validated(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty, data.count <= maximumByteCount else { return nil }
        return data
    }

    static func isValid(_ data: Data) -> Bool {
        validated(data) != nil
    }
}

/// Pane spec §3 / Space teardown rule, as a pure function. Wiring it to
/// `BrowserEngine.releaseProfile` is an integration step (see
/// `parallel-ports/tabs-integration.md`); Ora has no shared profiles in v1,
/// so the container ID remains the profile ID and teardown only ever
/// releases the cached reference — it never deletes website data.
enum TabLifecycleProfileTeardown {
    static let inactiveDelay: TimeInterval = 10 * 60

    static func isEligible(
        containerLastAccessedAt: Date,
        isCurrentContainer: Bool,
        allTabsDiscarded: Bool,
        at now: Date
    ) -> Bool {
        guard !isCurrentContainer, allTabsDiscarded else { return false }
        return now.timeIntervalSince(containerLastAccessedAt) >= inactiveDelay
    }
}
