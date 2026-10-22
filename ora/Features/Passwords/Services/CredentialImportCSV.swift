import Foundation

extension CredentialImport {
    static func parseCSV(_ text: String, cancelled: () -> Bool = { false }) -> Result {
        guard text.utf8.count <= maximumCSVBytes else { return Result(skipped: ["CSV exceeds the 16 MB limit."]) }
        var result = Result()
        var columns: (url: Int, user: Int, password: Int)?
        do {
            try CredentialImportCSV.read(text, cancelled: cancelled) { row, number in
                if number == 1 {
                    columns = try csvColumns(row)
                    result.format = row.contains { $0.lowercased() == "otpauth" } ? "Safari CSV" : "Chrome CSV"
                    return
                }
                guard let columns, row.count > max(columns.url, max(columns.user, columns.password)) else {
                    result.skipped.append("Row \(number): missing columns.")
                    return
                }
                let username = row[columns.user].trimmingCharacters(in: .whitespaces)
                let password = row[columns.password]
                guard !username.isEmpty, !password.isEmpty,
                      let origin = importOrigin(row[columns.url].trimmingCharacters(in: .whitespaces))
                else {
                    result.skipped.append("Row \(number): missing login fields or unsupported origin.")
                    return
                }
                result.entries.append(Entry(origin: origin, username: username, password: password))
            }
            if columns == nil {
                throw ImportFailure.malformed
            }
            return result
        } catch {
            // Never import a valid prefix of a syntactically malformed, cancelled or oversized file.
            return Result(
                skipped: ["CSV is malformed, has missing/ambiguous headers, was cancelled or exceeds limits."]
            )
        }
    }

    private static func csvColumns(_ header: [String]) throws -> (Int, Int, Int) {
        let normalized = header.map {
            $0.lowercased().trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        }
        func column(_ aliases: [String]) throws -> Int {
            let matches = normalized.indices.filter { aliases.contains(normalized[$0]) }
            guard matches.count == 1, let index = matches.first else { throw ImportFailure.malformed }
            return index
        }
        return try (
            column(["url", "website", "login_uri"]),
            column(["username", "login_username", "user"]),
            column(["password", "login_password"])
        )
    }
}

/// Strict byte state machine. Bounds are checked WHILE accumulating each field/row, before decoding.
/// Quoted CR/LF bytes are preserved exactly. Outside quotes, CRLF, LF and CR delimit records.
private enum CredentialImportCSV {
    enum State { case start, plain, quoted, closed }

    static func read(_ text: String, cancelled: () -> Bool, consume: ([String], Int) throws -> Void) throws {
        let bytes = Array(text.utf8)
        var state = State.start
        var field: [UInt8] = []
        var row: [String] = []
        var rowBytes = 0
        var count = 0
        var index = 0
        func endField() throws {
            guard row.count < 64, let value = String(bytes: field, encoding: .utf8) else {
                throw CredentialImport.ImportFailure.limit
            }
            row.append(value)
            field.removeAll(keepingCapacity: true)
        }
        func endRow() throws {
            try endField()
            if row.count != 1 || !row[0].isEmpty {
                count += 1
                guard count <= CredentialImport.maximumCSVRows + 1 else { throw CredentialImport.ImportFailure.limit }
                try consume(row, count)
            }
            row.removeAll(keepingCapacity: true)
            rowBytes = 0
        }
        while index < bytes.count {
            if index % 4096 == 0, cancelled() {
                throw CredentialImport.ImportFailure.cancelled
            }
            let byte = bytes[index]
            rowBytes += 1
            guard rowBytes <= 1024 * 1024 else { throw CredentialImport.ImportFailure.limit }
            if state == .quoted {
                if byte == 34 {
                    state = .closed
                } else {
                    field.append(byte)
                }
            } else if state == .closed, byte == 34 {
                field.append(34)
                state = .quoted
            } else if byte == 44 {
                try endField()
                state = .start
            } else if byte == 10 || byte == 13 {
                try endRow()
                state = .start
                if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 1
                }
            } else if byte == 34, state == .start {
                state = .quoted
            } else {
                guard state != .closed, byte != 34 else { throw CredentialImport.ImportFailure.malformed }
                field.append(byte)
                state = .plain
            }
            guard field.count <= CredentialImport.maximumFieldBytes else { throw CredentialImport.ImportFailure.limit }
            index += 1
        }
        guard state != .quoted, !cancelled() else { throw CredentialImport.ImportFailure.malformed }
        if !row.isEmpty || !field.isEmpty || state == .closed {
            try endRow()
        }
    }
}
