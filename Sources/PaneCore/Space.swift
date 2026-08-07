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
    public var profileID: String
    public var sortIndex: Int

    public init(id: String = UUID().uuidString, name: String, icon: String? = nil,
                profileID: String, sortIndex: Int = 0) {
        self.id = id; self.name = name; self.icon = icon
        self.profileID = profileID; self.sortIndex = sortIndex
    }
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

    public mutating func select(_ id: String) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        current = id
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
