// spec: §2
import Foundation
import PaneCore
import PaneHarness

/// spec §2 / §4 persistence. Every one of these runs against a real SQLite
/// database — an in-memory one, so they are fast and leave nothing behind.
public func storeChecks(_ check: Check) async {
    let url = URL(string: "https://example.com/a")!
    let home = URL(string: "https://mail.example.com")!

    // A file-backed store, because ":memory:" would hide exactly the bug this
    // milestone exists to prevent: state that does not actually survive a
    // process boundary.
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("pane-check-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: tmp) }

    guard let store = try? Store(path: tmp.path) else {
        check.suite("Store — open") { $0.that(false, "could not open a file-backed store") }
        return
    }

    var roundTripped: [Tab] = []
    var snapshots: [TabID: Data] = [:]
    var historyCount = 0

    let a = Tab(kind: .essential, url: url, title: "Mail", homeURL: home, sortIndex: 0)
    let b = Tab(kind: .pinned, url: url, title: "Docs", sortIndex: 1)
    let c = Tab(kind: .ephemeral, url: url, title: "Scratch",
                lifecycle: .discarded, sortIndex: 2)
    let blob = Data((0..<512).map { UInt8($0 % 251) })

    do {
        try await store.saveTabs([a, b, c], spaceID: nil)
        try await store.saveSnapshot(c.id, state: blob)
        try await store.recordVisit(url: url, title: "Mail", profileID: nil)
        try await store.recordVisit(url: home, title: "Home", profileID: nil)
        await store.close()

        // Reopen from disk — a genuinely separate handle, which is the only way
        // to prove persistence rather than in-process caching.
        let reopened = try Store(path: tmp.path)
        roundTripped = try await reopened.loadTabs()
        snapshots = try await reopened.loadSnapshots()
        historyCount = try await reopened.historyCount()
        await reopened.close()
    } catch {
        check.suite("Store — round trip") { $0.that(false, "threw: \(error)") }
        return
    }

    check.suite("Store — tabs survive a reopen") { e in
        e.equal(roundTripped.count, 3, "all three tabs came back")
        e.equal(roundTripped.map(\.title), ["Mail", "Docs", "Scratch"], "order preserved by sort_index")
        e.equal(roundTripped.first?.kind, .essential, "kind round-trips")
        e.equal(roundTripped.first?.homeURL, home, "an essential's home URL round-trips")
        e.equal(roundTripped.last?.lifecycle, .discarded, "lifecycle state round-trips")
        e.equal(roundTripped.first?.id, a.id, "tab identity is stable across a reopen")
    }

    check.suite("Store — interactionState blobs survive") { e in
        e.equal(snapshots.count, 1, "one snapshot stored")
        e.equal(snapshots[c.id], blob, "the blob comes back byte-identical")
        e.equal(snapshots[c.id]?.count, 512, "and at full length, not truncated")
    }

    check.suite("Store — history") { e in
        e.equal(historyCount, 2, "both visits recorded")
    }

    // saveTabs is a full replace; prove it does not accumulate duplicates.
    guard let store2 = try? Store(path: tmp.path) else { return }
    var afterReplace: [Tab] = []
    do {
        try await store2.saveTabs([a], spaceID: nil)
        afterReplace = try await store2.loadTabs()
        await store2.close()
    } catch { return }

    check.suite("Store — save is a replace, not an append") { e in
        e.equal(afterReplace.count, 1, "re-saving one tab leaves exactly one row")
        e.equal(afterReplace.first?.title, "Mail", "and it is the right one")
    }
}
