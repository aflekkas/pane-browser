// spec: §4
import Foundation

/// The tab collection and its lifecycle rules. Deliberately free of AppKit and
/// WebKit so every transition can be exercised headlessly against a fake engine
/// (ADR 0006). `now` is injected rather than read from the clock, so idle-timeout
/// behaviour is testable without sleeping.
public struct TabModel: Sendable {
    public private(set) var tabs: [Tab] = []
    public private(set) var selected: TabID?
    /// spec §5 "Today" is cleared on a timer; closed tabs are reopenable until then.
    public private(set) var recentlyClosed: [Tab] = []
    private let maxRecentlyClosed = 25

    public init() {}

    // MARK: - Queries

    public subscript(id: TabID) -> Tab? {
        get { tabs.first { $0.id == id } }
    }

    /// spec §5 — three sections, ordered. Essentials, Pinned, Today.
    public func section(_ kind: TabKind) -> [Tab] {
        tabs.filter { $0.kind == kind }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public var selectedTab: Tab? { selected.flatMap { self[$0] } }

    // MARK: - Mutation

    @discardableResult
    public mutating func open(_ tab: Tab, select: Bool = true) -> TabID {
        var t = tab
        t.sortIndex = (tabs.filter { $0.kind == t.kind }.map(\.sortIndex).max() ?? -1) + 1
        tabs.append(t)
        if select { selected = t.id }
        return t.id
    }

    public mutating func close(_ id: TabID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closed = tabs.remove(at: i)
        recentlyClosed.append(closed)
        if recentlyClosed.count > maxRecentlyClosed { recentlyClosed.removeFirst() }
        guard selected == id else { return }
        // Select the neighbour rather than clearing selection — closing the last
        // tab in a section should not dump the user into an empty content area.
        let sameKind = section(closed.kind)
        selected = sameKind.first(where: { $0.sortIndex >= closed.sortIndex })?.id
            ?? sameKind.last?.id
            ?? tabs.first?.id
    }

    @discardableResult
    public mutating func reopenLastClosed() -> TabID? {
        guard let t = recentlyClosed.popLast() else { return nil }
        return open(t)
    }

    public mutating func select(_ id: TabID, at now: Date = Date()) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selected = id
        touch(id, at: now)
    }

    public mutating func touch(_ id: TabID, at now: Date = Date()) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].lastActiveAt = now
    }

    public mutating func update(_ id: TabID, _ body: (inout Tab) -> Void) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        body(&tabs[i])
    }

    /// Reorder within a section (drag and drop, spec §5).
    public mutating func move(_ id: TabID, toIndex target: Int, in kind: TabKind) {
        guard var moving = self[id] else { return }
        var ordered = section(kind).filter { $0.id != id }
        let clamped = max(0, min(target, ordered.count))
        moving.kind = kind
        ordered.insert(moving, at: clamped)
        for (i, t) in ordered.enumerated() {
            update(t.id) { $0.sortIndex = i; $0.kind = kind }
        }
    }

    // MARK: - Lifecycle (spec §4)

    /// Which tabs are eligible to be discarded right now.
    ///
    /// The selected tab is never eligible — discarding what the user is looking
    /// at would be visible, and no memory policy is worth that.
    /// `force` skips only the *idle* threshold. The never-discard conditions
    /// and the selected-tab rule still apply — a benchmark that discards things
    /// the product would never discard measures nothing the product does.
    public func discardCandidates(at now: Date, force: Bool = false) -> [TabID] {
        tabs.filter { t in
            guard t.lifecycle == .live else { return false }
            guard t.id != selected else { return false }
            guard t.isDiscardable else { return false }
            if force { return true }
            return now.timeIntervalSince(t.lastActiveAt) >= t.idleBeforeDiscard
        }.map(\.id)
    }

    public mutating func markDiscarded(_ id: TabID) {
        update(id) { $0.lifecycle = .discarded }
    }

    public mutating func markLive(_ id: TabID, at now: Date = Date()) {
        update(id) { $0.lifecycle = .live; $0.lastActiveAt = now }
    }
}
