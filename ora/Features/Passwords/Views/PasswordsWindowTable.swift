import SwiftUI

extension PasswordsWindowView {
    var passwordsTable: some View {
        GeometryReader { geometry in
            let contentWidth = max(minimumTableContentWidth, geometry.size.width)
            let actionsColumnWidth = max(52, contentWidth - 784)

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    passwordTableHeader(actionsColumnWidth: actionsColumnWidth)

                    Divider()
                        .overlay(Color(.separatorColor).opacity(0.7))

                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredEntries, id: \.id) { entry in
                                passwordTableRow(entry, actionsColumnWidth: actionsColumnWidth)

                                if entry.id != filteredEntries.last?.id {
                                    Divider()
                                        .overlay(Color(.separatorColor).opacity(0.45))
                                        .padding(.leading, 12)
                                }
                            }
                        }
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
            }
            .background(Color(.controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separatorColor).opacity(0.55), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    var minimumTableContentWidth: CGFloat {
        836
    }

    var tableLeadingInset: CGFloat {
        10
    }

    var tableTrailingInset: CGFloat {
        14
    }

    func passwordTableHeader(actionsColumnWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            tableHeaderCell("Site", width: 260, alignment: .leading)
            tableHeaderCell("Username", width: 220, alignment: .leading)
            tableHeaderCell("Password", width: 240, alignment: .leading)
            tableHeaderCell("Actions", width: actionsColumnWidth, alignment: .leading)
        }
        .padding(.leading, tableLeadingInset)
        .padding(.trailing, tableTrailingInset)
        .padding(.vertical, 12)
        .background(Color(.controlBackgroundColor).opacity(0.3))
    }

    func passwordTableRow(_ entry: SavedPasswordSummary, actionsColumnWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                SiteFaviconView(host: entry.host, size: 20, cornerRadius: 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.host)
                        .help(passwordManager.storedProtectionDescription(for: entry))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(passwordManager.storedProtectionDescription(for: entry))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let origin = entry.origin {
                        Text(origin)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 260, alignment: .leading)

            HStack(spacing: 6) {
                Text(entry.displayUsername)
                    .font(.subheadline)
                    .foregroundStyle(entry.username.isEmpty ? .secondary : .primary)
                    .lineLimit(1)

                copyActionButton(help: "Copy username") {
                    passwordManager.copyToPasteboard(entry.username)
                }
            }
            .frame(width: 220, alignment: .leading)

            HStack(spacing: 6) {
                Text(vaultPresentation.revealedPasswordIDs[entry.id] ?? "••••••••••••")
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)

                Button {
                    toggleReveal(entry)
                } label: {
                    Image(systemName: vaultPresentation.revealedPasswordIDs[entry.id] == nil ? "eye" : "eye.slash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.mutedForeground)
                }
                .buttonStyle(.plain)
                .help(vaultPresentation.revealedPasswordIDs[entry.id] == nil ? "Reveal password" : "Hide password")

                copyActionButton(help: "Copy password") {
                    copyPassword(entry)
                }
            }
            .frame(width: 240, alignment: .leading)

            HStack {
                Button(role: .destructive) {
                    pendingDelete = entry
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Delete saved password")
            }
            .frame(width: actionsColumnWidth, alignment: .leading)
        }
        .padding(.leading, tableLeadingInset)
        .padding(.trailing, tableTrailingInset)
        .padding(.vertical, 12)
    }

    func tableHeaderCell(_ title: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    func copyActionButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OraIcons(
                icon: .copy,
                size: .custom(14),
                color: theme.mutedForeground
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    func emptyState(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
            if let lastErrorMessage = passwordManager.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
