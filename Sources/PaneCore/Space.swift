// spec: §3
import Foundation

/// A profile owns exactly one `WKWebsiteDataStore(forIdentifier:)`. That API is
/// macOS 14+, and per spec §3 it is *the single reason this project is
/// possible* — before it WebKit offered only `.default()` and `.nonPersistent()`.
///
/// What this buys is **data** isolation: separate cookie jars, storage and
/// logins. It does **not** buy process isolation — the network and GPU
/// processes are singletons and only WebContent partitions (ADR 0002). Never
/// describe Pane as having process isolation.
public struct Profile: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    /// The identifier handed to `WKWebsiteDataStore(forIdentifier:)`. Stable
    /// for the life of the profile — changing it orphans the data on disk.
    public let dataStoreUUID: UUID
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String,
                dataStoreUUID: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id; self.name = name
        self.dataStoreUUID = dataStoreUUID; self.createdAt = createdAt
    }
}

/// Spaces reference a profile rather than owning one. Default is one profile
/// per space, but two spaces may share one — "Work" and "Work Admin" wanting
/// the same Google login is a real case (spec §3).
public struct Space: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var icon: String?
    /// An index into a small fixed palette, not a free colour. Spaces need to
    /// be *distinguishable*; a colour picker would be theming, which is out of
    /// scope (docs/ui-parity.md).
    public var accent: Int?
    public var profileID: String
    public var sortIndex: Int

    public init(id: String = UUID().uuidString, name: String, icon: String? = nil,
                accent: Int? = nil, profileID: String, sortIndex: Int = 0) {
        self.id = id; self.name = name; self.icon = icon; self.accent = accent
        self.profileID = profileID; self.sortIndex = sortIndex
    }

    /// Fixed palette. Index, not a colour value, so it survives a light/dark
    /// switch and cannot drift into arbitrary theming.
    public static let accentCount = 6
}

/// Spaces and profiles, and the rules about which may be torn down.
public struct SpaceModel: Sendable {
    public private(set) var spaces: [Space] = []
    public private(set) var profiles: [String: Profile] = [:]
    public private(set) var current: String?

    public init() {}

    public var currentSpace: Space? { current.flatMap { id in spaces.first { $0.id == id } } }

    public func profile(for space: Space) -> Profile? { profiles[space.profileID] }

    @discardableResult
    public mutating func addSpace(named name: String, icon: String? = nil,
                                  sharingProfileWith existing: Space? = nil) -> Space {
        let profileID: String
        if let existing {
            profileID = existing.profileID          // §3: two spaces may share one profile
        } else {
            let p = Profile(name: name)
            profiles[p.id] = p
            profileID = p.id
        }
        let s = Space(name: name, icon: icon, profileID: profileID,
                      sortIndex: (spaces.map(\.sortIndex).max() ?? -1) + 1)
        spaces.append(s)
        if current == nil { current = s.id }
        return s
    }

    /// spec §3 — spaces are user-named and user-iconed, as in Zen. The icon is
    /// an SF Symbol name, not an image file: no asset pipeline, no theming, and
    /// it renders correctly at every size and in both appearances.
    public mutating func rename(_ id: String, to name: String) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        spaces[i].name = trimmed
        // A space with its own profile keeps the profile's name in step, so
        // the two never drift apart in the UI.
        if let pid = profiles[spaces[i].profileID]?.id,
           spaces.filter({ $0.profileID == pid }).count == 1 {
            profiles[pid]?.name = trimmed
        }
    }

    public mutating func setAccent(_ id: String, to index: Int?) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].accent = index.map { max(0, min(Space.accentCount - 1, $0)) }
    }

    public mutating func setIcon(_ id: String, to symbol: String?) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].icon = symbol
    }

    public mutating func removeSpace(_ id: String) {
        guard spaces.count > 1 else { return }   // never leave zero spaces
        spaces.removeAll { $0.id == id }
        if current == id { current = spaces.first?.id }
    }

    /// The icons offered when creating or editing a space. Deliberately a short
    /// fixed set — this is not a customisation surface.
    public static let iconChoices = [
        "person", "briefcase", "book", "cart", "hammer", "paintbrush",
        "gamecontroller", "heart", "leaf", "graduationcap", "airplane", "house",
    ]

    public mutating func select(_ id: String) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        current = id
    }

    public mutating func cycle(by delta: Int, wrap: Bool = true) {
        guard !spaces.isEmpty, let current,
              let i = spaces.firstIndex(where: { $0.id == current }) else { return }
        let n = spaces.count
        // Wrap, because a switcher that dead-ends at the last space feels broken.
        let target = wrap ? ((i + delta) % n + n) % n : max(0, min(n - 1, i + delta))
        self.current = spaces[target].id
    }

    /// Drag reorder for the space strip.
    public mutating func move(_ id: String, to index: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == id }) else { return }
        let moving = spaces.remove(at: from)
        spaces.insert(moving, at: max(0, min(index, spaces.count)))
        for (i, _) in spaces.enumerated() { spaces[i].sortIndex = i }
    }

    public mutating func load(spaces: [Space], profiles: [Profile]) {
        self.spaces = spaces.sorted { $0.sortIndex < $1.sortIndex }
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        if current == nil { current = self.spaces.first?.id }
    }

    /// spec §3 — a space's data store may be released once it has been inactive
    /// for 10 minutes *and* all its tabs are discarded. Releasing the reference
    /// is the whole teardown; `remove(forIdentifier:)` **deletes the data** and
    /// must never be used for this.
    public static let teardownAfter: TimeInterval = 10 * 60

    public static func isTeardownEligible(lastActive: Date, allTabsDiscarded: Bool,
                                          isCurrent: Bool, now: Date) -> Bool {
        guard !isCurrent, allTabsDiscarded else { return false }
        return now.timeIntervalSince(lastActive) >= teardownAfter
    }
}
