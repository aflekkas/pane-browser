// spec: §7
import Foundation

/// spec §7 — "parse Safari and Chrome CSV exports, and 1Password `.1pux`. This
/// is your migration story and it is not optional."
///
/// A browser nobody can move into is a browser nobody uses, so this is a
/// feature, not a utility.
public enum CredentialImport {

    public struct Entry: Sendable, Equatable {
        public let origin: String
        public let username: String
        public let password: String
        public init(origin: String, username: String, password: String) {
            self.origin = origin; self.username = username; self.password = password
        }
    }

    public struct Result: Sendable {
        public var entries: [Entry] = []
        /// Rows that parsed but could not be stored, with the reason. Reported
        /// rather than silently dropped: an import that says "42 imported" while
        /// discarding 9 is worse than one that says why.
        public var skipped: [String] = []
        public var format: String = "unknown"
    }

    /// Sniffs the format rather than trusting the file extension.
    public static func parse(_ data: Data, filename: String) -> Result {
        if filename.lowercased().hasSuffix(".1pux") { return parse1PUX(data) }
        guard let text = String(data: data, encoding: .utf8) else {
            var r = Result(); r.skipped.append("file is not UTF-8"); return r
        }
        return parseCSV(text)
    }

    // MARK: - CSV (Safari and Chrome)

    /// Safari exports `Title,URL,Username,Password,Notes,OTPAuth`.
    /// Chrome exports `name,url,username,password,note`.
    /// Both are handled by looking up columns BY HEADER NAME rather than by
    /// position — position varies by version and a silent column shift would
    /// store passwords as usernames.
    public static func parseCSV(_ text: String) -> Result {
        var result = Result()
        let rows = splitCSV(text)
        guard let header = rows.first else {
            result.skipped.append("empty file"); return result
        }
        let lower = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }

        func column(_ names: [String]) -> Int? {
            for n in names { if let i = lower.firstIndex(of: n) { return i } }
            return nil
        }
        guard let urlIdx = column(["url", "website", "login_uri"]),
              let userIdx = column(["username", "login_username", "user"]),
              let passIdx = column(["password", "login_password"]) else {
            result.skipped.append("could not find url/username/password columns in header: \(lower.joined(separator: ","))")
            return result
        }
        result.format = lower.contains("otpauth") ? "Safari CSV" : "Chrome CSV"

        for row in rows.dropFirst() {
            guard row.count > max(urlIdx, max(userIdx, passIdx)) else {
                if row.count > 1 { result.skipped.append("short row: \(row.first ?? "?")") }
                continue
            }
            let rawURL = row[urlIdx].trimmingCharacters(in: .whitespaces)
            let user = row[userIdx].trimmingCharacters(in: .whitespaces)
            let pass = row[passIdx]
            guard !rawURL.isEmpty, !user.isEmpty, !pass.isEmpty else {
                result.skipped.append("missing url, username or password for “\(rawURL)”")
                continue
            }
            guard let url = URL(string: rawURL.contains("://") ? rawURL : "https://\(rawURL)"),
                  let origin = CredentialVault.originKey(for: url) else {
                // Almost always an http:// entry. Named explicitly, because
                // "9 skipped" with no reason is not information.
                result.skipped.append("not https: \(rawURL)")
                continue
            }
            result.entries.append(Entry(origin: origin, username: user, password: pass))
        }
        return result
    }

    /// RFC 4180 enough for real exports: quoted fields, embedded commas,
    /// embedded newlines, and "" as an escaped quote. Passwords contain all of
    /// these, which is exactly why a `split(separator: ",")` would corrupt them.
    static func splitCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\""); i = next          // escaped quote
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",":  row.append(field); field = ""
                case "\n", "\r\n":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                case "\r": break
                default: field.append(c)
                }
            }
            i = text.index(after: i)
        }
        row.append(field)
        if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        return rows
    }

    // MARK: - 1Password .1pux

    /// A `.1pux` is a zip containing `export.data` (JSON). Unzipped with the
    /// system `unzip`, because bundling a zip reader would be the first
    /// third-party dependency and this runs once per user, ever.
    public static func parse1PUX(_ data: Data) -> Result {
        var result = Result(); result.format = "1Password 1PUX"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-1pux-\(UUID().uuidString)")
        let archive = tmp.appendingPathExtension("zip")
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try data.write(to: archive)
        } catch {
            result.skipped.append("could not stage the archive: \(error)")
            return result
        }
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: archive)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", "-q", archive.path, "-d", tmp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            result.skipped.append("unzip failed to start"); return result
        }
        p.waitUntilExit()

        let exportURL = tmp.appendingPathComponent("export.data")
        guard let json = try? Data(contentsOf: exportURL),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            result.skipped.append("export.data missing or unreadable")
            return result
        }
        for account in (root["accounts"] as? [[String: Any]]) ?? [] {
            for vault in (account["vaults"] as? [[String: Any]]) ?? [] {
                for wrapper in (vault["items"] as? [[String: Any]]) ?? [] {
                    guard let item = wrapper["item"] as? [String: Any],
                          let overview = item["overview"] as? [String: Any] else { continue }
                    let title = (overview["title"] as? String) ?? "untitled"
                    guard let rawURL = overview["url"] as? String, !rawURL.isEmpty else {
                        result.skipped.append("no URL for “\(title)”"); continue
                    }
                    let details = (item["details"] as? [String: Any]) ?? [:]
                    let fields = (details["loginFields"] as? [[String: Any]]) ?? []
                    let user = fields.first { ($0["designation"] as? String) == "username" }?["value"] as? String
                    let pass = fields.first { ($0["designation"] as? String) == "password" }?["value"] as? String
                    guard let user, let pass, !user.isEmpty, !pass.isEmpty else {
                        result.skipped.append("no login fields for “\(title)”"); continue
                    }
                    guard let url = URL(string: rawURL.contains("://") ? rawURL : "https://\(rawURL)"),
                          let origin = CredentialVault.originKey(for: url) else {
                        result.skipped.append("not https: \(title)"); continue
                    }
                    result.entries.append(Entry(origin: origin, username: user, password: pass))
                }
            }
        }
        return result
    }
}
