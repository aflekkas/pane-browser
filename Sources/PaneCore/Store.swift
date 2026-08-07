// spec: §2
import Foundation
import SQLite3

/// The single writer. **All SQLite goes through here** — an invariant enforced
/// mechanically by `Scripts/check-scope.sh`, which fails the build on any
/// `sqlite3_` symbol outside this file.
///
/// One database per install, WAL mode, per spec §2. Not one per profile,
/// because cross-space search is wanted and write volume is trivial.
///
/// No third-party dependency: this is a few hundred lines against the C API
/// rather than an entry against the zero-dependency budget (docs/budget.md).
public actor Store {
    private var db: OpaquePointer?
    public let path: String

    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        self.path = path
        // Swift 6 forbids calling actor-isolated methods from init, so opening
        // and migrating are nonisolated statics operating on a local handle.
        self.db = try Store.openDatabase(at: path)
    }

    /// In-memory store for checks and scenarios.
    public init() throws {
        self.path = ":memory:"
        self.db = try Store.openDatabase(at: ":memory:")
    }

    private nonisolated static func openDatabase(at path: String) throws -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            throw StoreError.open(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
        }
        // WAL per §2. Reads never block the writer, which matters because the
        // sidebar reads on every mutation.
        for pragma in ["PRAGMA journal_mode=WAL",
                       "PRAGMA synchronous=NORMAL",
                       "PRAGMA foreign_keys=ON"] {
            try execute(pragma, on: handle)
        }
        try execute(schema, on: handle)
        return handle
    }

    private nonisolated static func execute(_ sql: String, on handle: OpaquePointer?) throws {
        var msg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &msg) == SQLITE_OK else {
            let m = msg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(msg)
            throw StoreError.exec(m)
        }
    }

    /// `OpaquePointer` is not Sendable, so a nonisolated deinit cannot touch
    /// `db` under Swift 6. The handle is closed explicitly instead; the process
    /// exiting also releases it, and SQLite in WAL mode recovers cleanly from an
    /// unclean close — which is what a `kill -9` exercises anyway (milestone C
    /// gate).
    public func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    // MARK: - Schema (spec §2)

    private nonisolated static let schema = """
        CREATE TABLE IF NOT EXISTS profile(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            data_store_uuid TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS space(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            icon TEXT,
            color TEXT,
            profile_id TEXT NOT NULL REFERENCES profile(id) ON DELETE CASCADE,
            sort_index INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS tab(
            id TEXT PRIMARY KEY,
            space_id TEXT REFERENCES space(id) ON DELETE CASCADE,
            parent_id TEXT,
            kind TEXT NOT NULL,
            url TEXT,
            home_url TEXT,
            title TEXT,
            sort_index INTEGER NOT NULL DEFAULT 0,
            last_active_at REAL NOT NULL DEFAULT 0,
            lifecycle_state TEXT NOT NULL DEFAULT 'live'
        );
        CREATE TABLE IF NOT EXISTS session_snapshot(
            tab_id TEXT PRIMARY KEY REFERENCES tab(id) ON DELETE CASCADE,
            wk_interaction_state BLOB NOT NULL,
            captured_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS history(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            profile_id TEXT,
            url TEXT NOT NULL,
            title TEXT,
            visited_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS history_visited ON history(visited_at DESC);
        CREATE INDEX IF NOT EXISTS tab_space ON tab(space_id, sort_index);
        """

    /// Launch-time synchronous session load.
    ///
    /// Opens its own read-only handle rather than hopping through the actor.
    /// This exists because `init` cannot await, and the alternatives are worse:
    /// a semaphore blocking the main thread, or a detached Task capturing
    /// locals, which Swift 6 correctly rejects as a data race.
    ///
    /// Safe because it is read-only, happens before any writer exists, and WAL
    /// permits concurrent readers regardless.
    public nonisolated static func loadSessionSync(path: String) -> (tabs: [Tab], snapshots: [TabID: Data]) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return ([], [:])
        }
        defer { sqlite3_close_v2(handle) }

        var tabs: [Tab] = []
        var st: OpaquePointer?
        let sql = """
        SELECT id, kind, url, home_url, title, sort_index, last_active_at, lifecycle_state
        FROM tab ORDER BY sort_index
        """
        if sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                guard let idC = sqlite3_column_text(st, 0),
                      let uuid = UUID(uuidString: String(cString: idC)),
                      let kindC = sqlite3_column_text(st, 1),
                      let kind = TabKind(rawValue: String(cString: kindC)) else { continue }
                func col(_ i: Int32) -> String? {
                    sqlite3_column_text(st, i).map { String(cString: $0) }
                }
                tabs.append(Tab(
                    id: TabID(uuid), kind: kind,
                    url: col(2).flatMap(URL.init(string:)),
                    title: col(4),
                    homeURL: col(3).flatMap(URL.init(string:)),
                    lifecycle: LifecycleState(rawValue: col(7) ?? "live") ?? .live,
                    lastActiveAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 6)),
                    sortIndex: Int(sqlite3_column_int(st, 5))))
            }
        }
        sqlite3_finalize(st)

        var snaps: [TabID: Data] = [:]
        var st2: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT tab_id, wk_interaction_state FROM session_snapshot",
                              -1, &st2, nil) == SQLITE_OK {
            while sqlite3_step(st2) == SQLITE_ROW {
                guard let idC = sqlite3_column_text(st2, 0),
                      let uuid = UUID(uuidString: String(cString: idC)),
                      let bytes = sqlite3_column_blob(st2, 1) else { continue }
                snaps[TabID(uuid)] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(st2, 1)))
            }
        }
        sqlite3_finalize(st2)
        return (tabs, snaps)
    }

    // MARK: - Tabs

    /// Full replace of the tab set. Called debounced, so the cost of writing
    /// every tab rather than diffing is irrelevant at these volumes and the
    /// code is far harder to get subtly wrong.
    public func saveTabs(_ tabs: [Tab], spaceID: String?) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM tab")
            let sql = """
            INSERT INTO tab(id, space_id, parent_id, kind, url, home_url, title,
                            sort_index, last_active_at, lifecycle_state)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """
            for t in tabs {
                var st: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw err() }
                defer { sqlite3_finalize(st) }
                bindText(st, 1, t.id.raw.uuidString)
                bindText(st, 2, spaceID)
                bindText(st, 3, nil)
                bindText(st, 4, t.kind.rawValue)
                bindText(st, 5, t.url?.absoluteString)
                bindText(st, 6, t.homeURL?.absoluteString)
                bindText(st, 7, t.title)
                sqlite3_bind_int(st, 8, Int32(t.sortIndex))
                sqlite3_bind_double(st, 9, t.lastActiveAt.timeIntervalSince1970)
                bindText(st, 10, t.lifecycle.rawValue)
                guard sqlite3_step(st) == SQLITE_DONE else { throw err() }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func loadTabs() throws -> [Tab] {
        let sql = """
        SELECT id, kind, url, home_url, title, sort_index, last_active_at, lifecycle_state
        FROM tab ORDER BY sort_index
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw err() }
        defer { sqlite3_finalize(st) }

        var out: [Tab] = []
        while sqlite3_step(st) == SQLITE_ROW {
            guard let idText = text(st, 0), let uuid = UUID(uuidString: idText),
                  let kindText = text(st, 1), let kind = TabKind(rawValue: kindText)
            else { continue }
            let lifecycle = LifecycleState(rawValue: text(st, 7) ?? "live") ?? .live
            out.append(Tab(
                id: TabID(uuid),
                kind: kind,
                url: text(st, 2).flatMap(URL.init(string:)),
                title: text(st, 4),
                homeURL: text(st, 3).flatMap(URL.init(string:)),
                lifecycle: lifecycle,
                lastActiveAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 6)),
                sortIndex: Int(sqlite3_column_int(st, 5))))
        }
        return out
    }

    // MARK: - Spaces and profiles (spec §3)

    public func saveSpaces(_ spaces: [Space], profiles: [Profile]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM space"); try exec("DELETE FROM profile")
            for p in profiles {
                var st: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO profile(id,name,data_store_uuid,created_at) VALUES(?,?,?,?)",
                                         -1, &st, nil) == SQLITE_OK else { throw err() }
                defer { sqlite3_finalize(st) }
                bindText(st, 1, p.id); bindText(st, 2, p.name)
                bindText(st, 3, p.dataStoreUUID.uuidString)
                sqlite3_bind_double(st, 4, p.createdAt.timeIntervalSince1970)
                guard sqlite3_step(st) == SQLITE_DONE else { throw err() }
            }
            for sp in spaces {
                var st: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO space(id,name,icon,color,profile_id,sort_index) VALUES(?,?,?,NULL,?,?)",
                                         -1, &st, nil) == SQLITE_OK else { throw err() }
                defer { sqlite3_finalize(st) }
                bindText(st, 1, sp.id); bindText(st, 2, sp.name); bindText(st, 3, sp.icon)
                bindText(st, 4, sp.profileID)
                sqlite3_bind_int(st, 5, Int32(sp.sortIndex))
                guard sqlite3_step(st) == SQLITE_DONE else { throw err() }
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    public func loadSpaces() throws -> (spaces: [Space], profiles: [Profile]) {
        var profiles: [Profile] = []
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id,name,data_store_uuid,created_at FROM profile", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                guard let id = text(st, 0), let name = text(st, 1),
                      let u = text(st, 2).flatMap(UUID.init(uuidString:)) else { continue }
                profiles.append(Profile(id: id, name: name, dataStoreUUID: u,
                                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 3))))
            }
        }
        sqlite3_finalize(st)

        var spaces: [Space] = []
        var st2: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id,name,icon,profile_id,sort_index FROM space ORDER BY sort_index", -1, &st2, nil) == SQLITE_OK {
            while sqlite3_step(st2) == SQLITE_ROW {
                guard let id = text(st2, 0), let name = text(st2, 1), let pid = text(st2, 3) else { continue }
                spaces.append(Space(id: id, name: name, icon: text(st2, 2), profileID: pid,
                                    sortIndex: Int(sqlite3_column_int(st2, 4))))
            }
        }
        sqlite3_finalize(st2)
        return (spaces, profiles)
    }

    // MARK: - Session snapshots (spec §4)

    public func saveSnapshot(_ tabID: TabID, state: Data, at when: Date = Date()) throws {
        let sql = """
        INSERT INTO session_snapshot(tab_id, wk_interaction_state, captured_at)
        VALUES(?,?,?)
        ON CONFLICT(tab_id) DO UPDATE SET
            wk_interaction_state=excluded.wk_interaction_state,
            captured_at=excluded.captured_at
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw err() }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, tabID.raw.uuidString)
        _ = state.withUnsafeBytes { buf in
            sqlite3_bind_blob(st, 2, buf.baseAddress, Int32(state.count), Self.TRANSIENT)
        }
        sqlite3_bind_double(st, 3, when.timeIntervalSince1970)
        guard sqlite3_step(st) == SQLITE_DONE else { throw err() }
    }

    public func loadSnapshots() throws -> [TabID: Data] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT tab_id, wk_interaction_state FROM session_snapshot",
                                 -1, &st, nil) == SQLITE_OK else { throw err() }
        defer { sqlite3_finalize(st) }
        var out: [TabID: Data] = [:]
        while sqlite3_step(st) == SQLITE_ROW {
            guard let idText = text(st, 0), let uuid = UUID(uuidString: idText),
                  let bytes = sqlite3_column_blob(st, 1) else { continue }
            let n = Int(sqlite3_column_bytes(st, 1))
            out[TabID(uuid)] = Data(bytes: bytes, count: n)
        }
        return out
    }

    public func deleteSnapshot(_ tabID: TabID) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM session_snapshot WHERE tab_id=?",
                                 -1, &st, nil) == SQLITE_OK else { throw err() }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, tabID.raw.uuidString)
        guard sqlite3_step(st) == SQLITE_DONE else { throw err() }
    }

    // MARK: - History

    public func recordVisit(url: URL, title: String?, profileID: String?, at when: Date = Date()) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO history(profile_id,url,title,visited_at) VALUES(?,?,?,?)",
                                 -1, &st, nil) == SQLITE_OK else { throw err() }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, profileID)
        bindText(st, 2, url.absoluteString)
        bindText(st, 3, title)
        sqlite3_bind_double(st, 4, when.timeIntervalSince1970)
        guard sqlite3_step(st) == SQLITE_DONE else { throw err() }
    }

    public func historyCount() throws -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM history", -1, &st, nil) == SQLITE_OK else { throw err() }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(st, 0))
    }

    // MARK: - Plumbing

    private func exec(_ sql: String) throws { try Store.execute(sql, on: db) }

    private func err() -> StoreError { .exec(String(cString: sqlite3_errmsg(db))) }

    private func bindText(_ st: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(st, i, v, -1, Self.TRANSIENT) }
        else { sqlite3_bind_null(st, i) }
    }

    private func text(_ st: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case exec(String)
    public var description: String {
        switch self {
        case .open(let m): return "store open failed: \(m)"
        case .exec(let m): return "store failed: \(m)"
        }
    }
}
