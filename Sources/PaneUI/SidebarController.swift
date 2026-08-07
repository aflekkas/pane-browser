// spec: §5
import AppKit
import UniformTypeIdentifiers
import PaneCore

/// spec §5. `NSOutlineView`, view-based, **not SwiftUI** — a List with 200 rows
/// and drag reordering stutters, and the sidebar is the one surface where
/// stutter is unforgivable.
///
/// Note there is no diffable data source here: `NSOutlineViewDiffableDataSource`
/// does not exist in any macOS SDK. AppKit ships the collection-view and
/// table-view variants only, and `NSTableViewDiffableDataSource` cannot be
/// assigned to `NSOutlineView.dataSource`. Conventional data source plus
/// explicit insert/remove animations is the supported path
/// (docs/research/2026-08-07-architecture.md).
@MainActor
public final class SidebarController: NSViewController {
    /// Rows are either a section spacer or a tab. Essentials are chunked into
    /// rows of four to give the icon grid §5 asks for.
    enum Row: Hashable {
        case spacer(TabKind)
        case essentialsRow([TabID])
        case tab(TabID)
    }

    public var model = TabModel() { didSet { rebuild() } }
    public var onSelect: ((TabID) -> Void)?
    public var onClose: ((TabID) -> Void)?
    public var onReorder: ((TabID, Int, TabKind) -> Void)?

    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var rows: [Row] = []

    /// Custom UTI carrying tab IDs, with a `public.url` fallback so a drag out
    /// to Finder or another app still means something (spec §5).
    static let tabUTI = NSPasteboard.PasteboardType("com.aflekkas.pane.tab")

    public override func loadView() {
        view = NSView()
        // Flat fill via an NSBox rather than `wantsLayer` + a layer background:
        // cacheDisplay does not traverse layer-backed subviews, so making this
        // view layer-backed renders the whole sidebar blank in captures
        // (docs/api-notes/appkit.md). Glass is milestone G, deliberately last —
        // wanting to build it now is the signal that the plumbing is unfinished.
        let backing = NSBox()
        backing.boxType = .custom
        backing.borderWidth = 0
        backing.fillColor = .controlBackgroundColor
        backing.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backing)
        NSLayoutConstraint.activate([
            backing.topAnchor.constraint(equalTo: view.topAnchor),
            backing.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backing.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        outline.headerView = nil                       // §5: three sections, no headers
        outline.rowSizeStyle = .custom
        outline.selectionHighlightStyle = .regular
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 0
        outline.dataSource = self
        outline.delegate = self
        outline.backgroundColor = .clear
        outline.style = .inset
        outline.usesAutomaticRowHeights = false
        outline.target = self
        outline.doubleAction = #selector(noop)

        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col

        outline.registerForDraggedTypes([Self.tabUTI, .URL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func noop() {}

    /// spec §5 — Essentials (icon grid, 4 per row), Pinned (list), Today (list),
    /// separated by spacing rather than headers.
    private func rebuild() {
        var next: [Row] = []
        let essentials = model.section(.essential)
        if !essentials.isEmpty {
            for chunk in stride(from: 0, to: essentials.count, by: 4) {
                next.append(.essentialsRow(Array(essentials[chunk..<min(chunk + 4, essentials.count)]).map(\.id)))
            }
        }
        let pinned = model.section(.pinned)
        if !pinned.isEmpty {
            next.append(.spacer(.pinned))
            next.append(contentsOf: pinned.map { Row.tab($0.id) })
        }
        let today = model.section(.ephemeral)
        if !today.isEmpty {
            next.append(.spacer(.ephemeral))
            next.append(contentsOf: today.map { Row.tab($0.id) })
        }
        guard next != rows else { syncSelection(); return }
        rows = next
        outline.reloadData()
        syncSelection()
    }

    private func syncSelection() {
        guard let sel = model.selected,
              let i = rows.firstIndex(of: .tab(sel)) else {
            outline.deselectAll(nil); return
        }
        if outline.selectedRow != i {
            outline.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
    }

    private func tabID(atRow row: Int) -> TabID? {
        guard row >= 0, row < rows.count, case .tab(let id) = rows[row] else { return nil }
        return id
    }
}

// MARK: - Data source

extension SidebarController: NSOutlineViewDataSource {
    public func outlineView(_ v: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? rows.count : 0
    }
    public func outlineView(_ v: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        index
    }
    public func outlineView(_ v: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    public func outlineView(_ v: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let row = item as? Int, let id = tabID(atRow: row), let tab = model[id] else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(id.raw.uuidString, forType: Self.tabUTI)
        // public.url fallback so dragging out of Pane is meaningful (spec §5).
        if let u = tab.url { pb.setString(u.absoluteString, forType: .URL) }
        return pb
    }

    public func outlineView(_ v: NSOutlineView, validateDrop info: NSDraggingInfo,
                            proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard index >= 0 else { return [] }          // no dropping onto a row
        guard info.draggingPasteboard.string(forType: Self.tabUTI) != nil else { return [] }
        return .move
    }

    public func outlineView(_ v: NSOutlineView, acceptDrop info: NSDraggingInfo,
                            item: Any?, childIndex index: Int) -> Bool {
        guard let s = info.draggingPasteboard.string(forType: Self.tabUTI),
              let uuid = UUID(uuidString: s) else { return false }
        let id = TabID(uuid)
        // Which section did it land in, and at what offset within that section?
        let (kind, offset) = destination(forRow: index)
        onReorder?(id, offset, kind)
        return true
    }

    /// Map a flat outline row index back to (section, index-within-section).
    private func destination(forRow row: Int) -> (TabKind, Int) {
        var kind: TabKind = model.section(.essential).isEmpty ? .pinned : .essential
        var offset = 0
        for i in 0..<min(row, rows.count) {
            switch rows[i] {
            case .spacer(let k): kind = k; offset = 0
            case .essentialsRow(let ids): kind = .essential; offset += ids.count
            case .tab: offset += 1
            }
        }
        return (kind, offset)
    }
}

// MARK: - Delegate

extension SidebarController: NSOutlineViewDelegate {
    public func outlineView(_ v: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let row = item as? Int, row < rows.count else { return 28 }
        switch rows[row] {
        case .spacer:        return 14
        case .essentialsRow: return 56
        case .tab:           return 28
        }
    }

    public func outlineView(_ v: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let row = item as? Int, row < rows.count else { return false }
        if case .tab = rows[row] { return true }
        return false
    }

    public func outlineView(_ v: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Int, row < rows.count else { return nil }
        switch rows[row] {
        case .spacer:
            return NSView()                                   // §5: spacing, not headers
        case .essentialsRow(let ids):
            return EssentialsRowView(ids: ids, model: model) { [weak self] in self?.onSelect?($0) }
        case .tab(let id):
            guard let tab = model[id] else { return nil }
            return TabRowView(tab: tab)
        }
    }

    public func outlineViewSelectionDidChange(_ n: Notification) {
        guard let id = tabID(atRow: outline.selectedRow) else { return }
        if id != model.selected { onSelect?(id) }
    }
}
