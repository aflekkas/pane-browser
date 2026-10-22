// spec: §7 — Safari/Chrome CSV and 1Password 1PUX, without shelling out or extracting files.
import Foundation

enum CredentialImport {
    struct Entry: Sendable, Equatable {
        let origin: String
        let username: String
        let password: String
    }

    struct Result: Sendable {
        var entries: [Entry] = []
        /// Diagnostics are fixed strings/row numbers, never attacker-controlled fields or URLs.
        var skipped: [String] = []
        var format = "unknown"
    }

    static let maximumCSVBytes = 16 * 1024 * 1024
    static let maximumCSVRows = 100_000
    static let maximumFieldBytes = 256 * 1024
    static let maximumArchiveBytes = 64 * 1024 * 1024
    static let maximumArchiveEntries = 1024
    static let maximumExportDataBytes = 32 * 1024 * 1024

    static func parse(_ data: Data, filename: String, cancelled: () -> Bool = { false }) -> Result {
        if cancelled() {
            return Result(skipped: ["Import cancelled."])
        }
        let isZIP = data.starts(with: [0x50, 0x4B, 0x03, 0x04])
        if filename.lowercased().hasSuffix(".1pux") || isZIP {
            return parse1PUX(data, cancelled: cancelled)
        }
        guard data.count <= maximumCSVBytes else { return Result(skipped: ["CSV exceeds the 16 MB limit."]) }
        guard let text = String(data: data, encoding: .utf8) else { return Result(skipped: ["File is not UTF-8."]) }
        return parseCSV(text, cancelled: cancelled)
    }

    /// Read at most limit + 1 bytes even for sparse files, changing files and misleading metadata.
    /// The caller runs this off the UI actor and owns the security-scoped resource lifetime.
    static func readFile(_ url: URL, cancelled: () -> Bool = { false }) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = url.pathExtension.lowercased() == "1pux" ? maximumArchiveBytes : maximumCSVBytes
        var data = Data()
        while data.count <= limit {
            if cancelled() {
                throw ImportFailure.cancelled
            }
            let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty {
                return data
            }
            data.append(chunk)
        }
        throw ImportFailure.limit
    }

    enum ImportFailure: Error { case malformed, limit, cancelled }

    static func parse1PUX(_ data: Data, cancelled: () -> Bool = { false }) -> Result {
        var result = Result(format: "1Password 1PUX")
        do {
            let decoded = try CredentialImportZIP.exportData(data, cancelled: cancelled)
            guard !cancelled(),
                  let root = try JSONSerialization.jsonObject(with: decoded) as? [String: Any],
                  let accounts = root["accounts"] as? [[String: Any]] else { throw ImportFailure.malformed }
            var itemCount = 0
            for account in accounts {
                guard let vaults = account["vaults"] as? [[String: Any]] else { throw ImportFailure.malformed }
                for vault in vaults {
                    guard let items = vault["items"] as? [[String: Any]] else { throw ImportFailure.malformed }
                    for item in items {
                        itemCount += 1
                        guard itemCount <= maximumCSVRows, !cancelled() else { throw ImportFailure.limit }
                        if let entry = loginEntry(item) {
                            result.entries.append(entry)
                        } else {
                            result.skipped
                                .append("Item \(itemCount): unsupported category, state, origin or login fields.")
                        }
                    }
                }
            }
            return result
        } catch {
            // Structural failure invalidates the ENTIRE archive, including earlier valid items.
            return Result(
                skipped: ["1PUX is invalid, unsupported, cancelled or exceeds resource limits."],
                format: result.format
            )
        }
    }

    /// Official schema: accounts[].vaults[].items[] directly contains overview/details/categoryUuid.
    /// https://support.1password.com/1pux-format/ — login category 001; other categories explicitly skipped.
    private static func loginEntry(_ item: [String: Any]) -> Entry? {
        guard item["categoryUuid"] as? String == "001", item["state"] as? String != "archived",
              let overview = item["overview"] as? [String: Any], let rawURL = overview["url"] as? String,
              let details = item["details"] as? [String: Any],
              let fields = details["loginFields"] as? [[String: Any]] else { return nil }
        let usernames = fields.filter { $0["designation"] as? String == "username" }
        let passwords = fields.filter { $0["designation"] as? String == "password" }
        guard usernames.count == 1, passwords.count == 1,
              let username = usernames[0]["value"] as? String,
              let password = passwords[0]["value"] as? String,
              !username.isEmpty, !password.isEmpty,
              [rawURL, username, password].allSatisfy({ $0.utf8.count <= maximumFieldBytes }),
              let origin = importOrigin(rawURL) else { return nil }
        return Entry(origin: origin, username: username, password: password)
    }

    static func importOrigin(_ raw: String) -> String? {
        guard let url = URL(string: raw.contains("://") ? raw : "https://\(raw)") else { return nil }
        return CredentialVault.originKey(for: url)
    }
}
