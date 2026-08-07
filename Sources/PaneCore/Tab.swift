// spec: §4
import Foundation

public struct TabID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
    public var description: String { raw.uuidString.prefix(8).lowercased() }
}

/// spec §4. Drives both the sidebar section a tab lives in and how aggressively
/// it may be discarded.
public enum TabKind: String, Sendable, Codable, CaseIterable {
    case essential   // icon grid; never discards below thumbnail state
    case pinned      // list; 15m idle before discard
    case ephemeral   // "Today"; 5m idle before discard
}

/// spec §4, as corrected. `frozen` was removed — WebKit already suspends a
/// detached WKWebView by default, so the only tier that reclaims memory is the
/// one that actually deallocates the view (ADR 0001).
public enum LifecycleState: String, Sendable, Codable {
    case live
    case discarded
}

public struct Tab: Identifiable, Sendable, Equatable {
    public let id: TabID
    public var kind: TabKind
    public var url: URL?
    public var title: String?
    /// spec §4: essentials "always restore to their pinned URL, not their
    /// wandered-to URL". Nil for every other kind.
    public var homeURL: URL?
    public var lifecycle: LifecycleState
    public var lastActiveAt: Date
    public var sortIndex: Int

    /// Reasons a tab must not be discarded regardless of idle time (spec §4).
    public var isPlayingAudio: Bool
    public var hasActiveMediaSession: Bool
    public var hasUnsavedFormState: Bool
    public var userPinnedExplicitly: Bool

    public init(id: TabID = TabID(), kind: TabKind = .ephemeral, url: URL? = nil,
                title: String? = nil, homeURL: URL? = nil,
                lifecycle: LifecycleState = .live, lastActiveAt: Date = .distantPast,
                sortIndex: Int = 0, isPlayingAudio: Bool = false,
                hasActiveMediaSession: Bool = false, hasUnsavedFormState: Bool = false,
                userPinnedExplicitly: Bool = false) {
        self.id = id; self.kind = kind; self.url = url; self.title = title
        self.homeURL = homeURL; self.lifecycle = lifecycle
        self.lastActiveAt = lastActiveAt; self.sortIndex = sortIndex
        self.isPlayingAudio = isPlayingAudio
        self.hasActiveMediaSession = hasActiveMediaSession
        self.hasUnsavedFormState = hasUnsavedFormState
        self.userPinnedExplicitly = userPinnedExplicitly
    }

    /// What the sidebar shows when there is no title yet.
    public var displayName: String {
        if let t = title, !t.isEmpty { return t }
        if let u = url { return URLNormalizer.display(u) }
        return "New Tab"
    }

    /// spec §4 — the four never-discard conditions, in one place so they cannot
    /// drift apart from the policy that consults them.
    public var isDiscardable: Bool {
        if isPlayingAudio || hasActiveMediaSession || hasUnsavedFormState { return false }
        if userPinnedExplicitly { return false }
        return true
    }

    /// Idle time before this kind may be discarded (spec §4).
    public var idleBeforeDiscard: TimeInterval {
        switch kind {
        case .ephemeral: return 5 * 60
        case .pinned:    return 15 * 60
        case .essential: return 15 * 60
        }
    }

    /// spec §4: essentials restore to their pinned URL, not where they wandered.
    public var restoreURL: URL? {
        kind == .essential ? (homeURL ?? url) : url
    }
}
