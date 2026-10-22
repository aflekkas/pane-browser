import Foundation

extension PasswordManagerService {
    func matchingEntries(for url: URL) -> [SavedPasswordSummary] {
        matchingEntries(for: url, containerID: nil)
    }

    func matchingEntries(for url: URL, containerID: UUID?) -> [SavedPasswordSummary] {
        // Strict vault policy: exact origin key only. http (non-loopback),
        // `www.`/bare-host bleed and subdomain sharing all end here — an
        // entry either has this exact origin key or it is not offered.
        guard let originKey = CredentialVault.originKey(for: url) else {
            return []
        }

        return scopedEntries(for: containerID)
            .filter { entry in
                credentialBySummaryID[entry.id]?.origin == originKey
            }
            .sorted {
                let lhsDate = $0.lastUsedAt ?? $0.updatedAt
                let rhsDate = $1.lastUsedAt ?? $1.updatedAt
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return $0.displayUsername.localizedCaseInsensitiveCompare($1.displayUsername) == .orderedAscending
            }
    }

    func emailSuggestions(limit: Int = 4) -> [PasswordEmailSuggestion] {
        emailSuggestions(for: nil, limit: limit)
    }

    func emailSuggestions(for containerID: UUID?, limit: Int = 4) -> [PasswordEmailSuggestion] {
        var seenEmails = Set<String>()

        return scopedEntries(for: containerID)
            .sorted {
                let lhsDate = $0.lastUsedAt ?? $0.updatedAt
                let rhsDate = $1.lastUsedAt ?? $1.updatedAt
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return $0.displayUsername.localizedCaseInsensitiveCompare($1.displayUsername) == .orderedAscending
            }
            .compactMap { entry -> PasswordEmailSuggestion? in
                let trimmedEmail = entry.username.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.looksLikeEmail(trimmedEmail) else {
                    return nil
                }

                let normalizedEmail = trimmedEmail.lowercased()
                guard seenEmails.insert(normalizedEmail).inserted else {
                    return nil
                }

                return PasswordEmailSuggestion(
                    email: trimmedEmail,
                    host: entry.host,
                    lastUsedAt: entry.lastUsedAt,
                    updatedAt: entry.updatedAt
                )
            }
            .prefix(limit)
            .map(\.self)
    }

    func entries(for containerID: UUID?) -> [SavedPasswordSummary] {
        scopedEntries(for: containerID)
    }
}
