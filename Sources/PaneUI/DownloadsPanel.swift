// spec: §6
import AppKit
import PaneCore

/// spec §6 — "NSPopover panel off a toolbar button, plus Dock icon progress via
/// NSApp.dockTile."
///
/// spec §1 — AppKit, not web content.
@MainActor
public final class DownloadsPanel: NSViewController {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "Nothing downloaded yet.")
    private var items: [DownloadManager.Item] = []
    public var onReveal: ((URL) -> Void)?

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))

        table.headerView = nil
        table.rowHeight = 40
        table.style = .inset
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(revealSelected)
        let col = NSTableColumn(identifier: .init("d"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 12)
        view.addSubview(empty)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    public func update(_ newItems: [DownloadManager.Item]) {
        // Newest first: the thing you just started is the thing you want to see.
        items = newItems.reversed()
        empty.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        table.reloadData()
    }

    @objc private func revealSelected() {
        let row = table.clickedRow
        guard row >= 0, row < items.count, let dest = items[row].destination else { return }
        onReveal?(dest)
    }
}

extension DownloadsPanel: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        let name = NSTextField(labelWithString: item.filename)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle

        let detail = NSTextField(labelWithString: Self.detailText(item))
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = item.failure != nil ? .systemRed : .secondaryLabelColor

        let stack = NSStackView(views: [name, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSView()
        cell.addSubview(stack)

        if !item.isFinished && item.failure == nil {
            let bar = NSProgressIndicator()
            bar.isIndeterminate = item.totalBytes <= 0
            bar.minValue = 0
            bar.maxValue = Double(max(item.totalBytes, 1))
            bar.doubleValue = Double(item.bytesWritten)
            if bar.isIndeterminate { bar.startAnimation(nil) }
            bar.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                bar.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
                bar.heightAnchor.constraint(equalToConstant: 3),
            ])
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
        ])
        return cell
    }

    /// States the quarantine status explicitly. If a download ever lands
    /// without it, the user should be able to see that rather than discover it
    /// when Gatekeeper stays silent.
    static func detailText(_ item: DownloadManager.Item) -> String {
        if let f = item.failure { return "Failed — \(f)" }
        if item.isFinished {
            let q = item.destination.map {
                DownloadManager.hasQuarantine($0) ? "checked by macOS" : "NOT quarantined"
            } ?? ""
            return "\(byteString(item.bytesWritten)) · \(q)"
        }
        if item.totalBytes > 0 {
            let pct = Int(Double(item.bytesWritten) / Double(item.totalBytes) * 100)
            return "\(byteString(item.bytesWritten)) of \(byteString(item.totalBytes)) · \(pct)%"
        }
        return byteString(item.bytesWritten)
    }

    static func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
