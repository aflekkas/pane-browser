import Foundation

struct CredentialImportReport: Equatable {
    var format: String
    var importedCount: Int
    var skipped: [String]
}

extension PasswordManagerService {
    /// Synchronous adapter for small callers/tests. Production UI uses off-actor parsing and the
    /// cooperative async writer below. Conflicts are retained, never silently overwritten.
    func importCredentials(
        data: Data,
        filename: String,
        containerID: UUID?,
        isPrivate: Bool
    ) -> CredentialImportReport {
        let parsed = CredentialImport.parse(data, filename: filename)
        guard !isPrivate, let containerID else { return invalidImportTarget() }
        defersMetadataRefresh = true
        defer { finishImportBatch() }
        var report = CredentialImportReport(format: parsed.format, importedCount: 0, skipped: parsed.skipped)
        for entry in parsed.entries {
            importEntry(entry, profileID: containerID.uuidString, report: &report)
        }
        return report
    }

    @MainActor
    func importCredentials(parsed: CredentialImport.Result, containerID: UUID) async -> CredentialImportReport {
        defersMetadataRefresh = true
        defer { finishImportBatch() }
        var report = CredentialImportReport(format: parsed.format, importedCount: 0, skipped: parsed.skipped)
        for (index, entry) in parsed.entries.enumerated() {
            if index % 8 == 0 {
                await Task.yield()
            }
            guard !Task.isCancelled, isAuthenticated else {
                report.skipped
                    .append("Import stopped; completed copies remain saved and existing passwords were retained.")
                break
            }
            importEntry(entry, profileID: containerID.uuidString, report: &report)
        }
        return report
    }

    private func importEntry(_ entry: CredentialImport.Entry, profileID: String, report: inout CredentialImportReport) {
        do {
            try saveVaultCredential(
                originKey: entry.origin,
                displayOrigin: entry.origin,
                host: Self.hostPart(ofVaultOrigin: entry.origin),
                username: entry.username,
                password: entry.password,
                profileID: profileID,
                insertOnly: true
            )
            report.importedCount += 1
        } catch {
            report.skipped
                .append("Password not imported: destination exists or keychain write failed. Existing data retained.")
        }
    }

    private func finishImportBatch() {
        defersMetadataRefresh = false
        persistMetadata()
        refresh()
    }

    private func invalidImportTarget() -> CredentialImportReport {
        CredentialImportReport(
            format: "unknown",
            importedCount: 0,
            skipped: ["Choose a normal space; private or unassigned imports are not supported."]
        )
    }
}
