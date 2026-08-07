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
    /// spec §3 — the space switcher. A strip of pills above the tab list, one
    /// per space, because a space with no visible affordance is a feature
    /// nobody finds.
    public var spaces = SpaceModel() { didSet { rebuildSpaceBar() } }
    public var onSelectSpace: ((String) -> Void)?
    public var onNewSpace: ((String) -> Void)?
    public var onRenameSpace: ((String, String) -> Void)?
    public var onSetSpaceIcon: ((String, String?) -> Void)?
    public var onDeleteSpace: ((String) -> Void)?
    public var onSelect: ((TabID) -> Void)?
    public var onClose: ((TabID) -> Void)?
    public var onReorder: ((TabID, Int, TabKind) -> Void)?

    private let outline = NSOutlineView()
    private let spaceBar = NSStackView()
    /// Filled by the window controller with nav buttons and the address field.
    /// Arc and Zen both put the URL bar *inside* the sidebar, which is what
    /// leaves the content area with no chrome above it at all — that is the
    /// defining move, more than any spacing value.
    public let header = NSView()
    private let newTabButton = NSButton()
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

        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        // spec §5 — "+ New Tab" as the last row of the list, per the Arc
        // reference in docs/reference/arc-sidebar.md.
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.isBordered = false
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        newTabButton.imagePosition = .imageLeading
        newTabButton.title = "  New Tab"
        newTabButton.font = .systemFont(ofSize: 13)
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.alignment = .left
        newTabButton.target = self
        newTabButton.action = #selector(newTabTapped)
        view.addSubview(newTabButton)

        // Spaces live at the BOTTOM, as in Arc and Zen.
        spaceBar.translatesAutoresizingMaskIntoConstraints = false
        spaceBar.orientation = .horizontal
        spaceBar.distribution = .fillEqually
        spaceBar.spacing = 2
        view.addSubview(spaceBar)

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hairline)
        self.bottomHairline = hairline

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            // Header: traffic-light clearance, then nav + address field.
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 72),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: newTabButton.topAnchor, constant: -2),

            newTabButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            newTabButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            newTabButton.heightAnchor.constraint(equalToConstant: 28),
            newTabButton.bottomAnchor.constraint(equalTo: hairline.topAnchor, constant: -6),

            hairline.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            hairline.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            hairline.bottomAnchor.constraint(equalTo: spaceBar.topAnchor, constant: -6),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            // Spaces pinned to the bottom.
            spaceBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            spaceBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            spaceBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            spaceBar.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private var bottomHairline: NSBox?
    public var onNewTab: (() -> Void)?

    @objc private func noop() {}
    @objc private func newTabTapped() { onNewTab?() }

    /// One pill per space plus a "+". System colours only — no palette, no
    /// theming; the accent colour is whatever the user set in System Settings.
    private func rebuildSpaceBar() {
        spaceBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for sp in spaces.spaces {
            let isCurrent = spaces.current == sp.id
            let b = SpaceButton(title: sp.name, target: self, action: #selector(spaceTapped(_:)))
            b.spaceID = sp.id
            b.onContextMenu = { [weak self] in self?.showSpaceMenu(for: sp.id, from: b) }
            if let sym = sp.icon {
                b.image = NSImage(systemSymbolName: sym, accessibilityDescription: sp.name)
                b.imagePosition = .imageLeading
            }
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 7
            b.layer?.backgroundColor = isCurrent
                ? NSColor.controlAccentColor.withAlphaComponent(0.20).cgColor
                : NSColor.clear.cgColor
            b.attributedTitle = NSAttributedString(string: sp.name, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: isCurrent ? .semibold : .regular),
                .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            b.identifier = NSUserInterfaceItemIdentifier(sp.id)
            spaceBar.addArrangedSubview(b)
        }
        let plus = NSButton(title: "+", target: self, action: #selector(newSpaceTapped))
        plus.isBordered = false
        plus.attributedTitle = NSAttributedString(string: "+", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        spaceBar.addArrangedSubview(plus)
    }

    @objc private func spaceTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onSelectSpace?(id)
    }

    @objc private func newSpaceTapped() {
        // Zen-style: name it as you create it, rather than creating "Space 3"
        // and making the user go find a rename command.
        guard let field = promptForName(title: "New Space", initial: "") else { return }
        onNewSpace?(field)
    }

    /// Right-click a space: rename, pick an icon, delete. Everything a space
    /// needs and nothing it does not.
    private func showSpaceMenu(for id: String, from view: NSView) {
        guard let sp = spaces.spaces.first(where: { $0.id == id }) else { return }
        let menu = NSMenu()

        let rename = NSMenuItem(title: "Rename…", action: #selector(renameSpace(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = id
        menu.addItem(rename)

        let iconItem = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        let iconMenu = NSMenu()
        for sym in SpaceModel.iconChoices {
            let mi = NSMenuItem(title: "", action: #selector(pickIcon(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = [id, sym]
            mi.image = NSImage(systemSymbolName: sym, accessibilityDescription: sym)
            mi.title = sym.replacingOccurrences(of: ".", with: " ").capitalized
            mi.state = (sp.icon == sym) ? .on : .off
            iconMenu.addItem(mi)
        }
        iconMenu.addItem(.separator())
        let none = NSMenuItem(title: "No Icon", action: #selector(clearIcon(_:)), keyEquivalent: "")
        none.target = self; none.representedObject = id
        iconMenu.addItem(none)
        iconItem.submenu = iconMenu
        menu.addItem(iconItem)

        if spaces.spaces.count > 1 {
            menu.addItem(.separator())
            let del = NSMenuItem(title: "Delete Space", action: #selector(deleteSpace(_:)), keyEquivalent: "")
            del.target = self; del.representedObject = id
            menu.addItem(del)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }

    @objc private func renameSpace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let sp = spaces.spaces.first(where: { $0.id == id }),
              let name = promptForName(title: "Rename Space", initial: sp.name) else { return }
        onRenameSpace?(id, name)
    }

    @objc private func pickIcon(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        onSetSpaceIcon?(pair[0], pair[1])
    }

    @objc private func clearIcon(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSetSpaceIcon?(id, nil)
    }

    @objc private func deleteSpace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let sp = spaces.spaces.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(sp.name)”?"
        // Be precise about what is and is not destroyed. Releasing the data
        // store reference does NOT delete the profile's cookies or logins;
        // WKWebsiteDataStore.remove(forIdentifier:) would, and is not used.
        alert.informativeText = "Its tabs will be closed. Saved logins and cookies for this space are kept on disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onDeleteSpace?(id)
    }

    /// spec §1 — panels are AppKit. No web content renders browser UI.
    private func promptForName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = initial
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

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


/// An NSButton that reports right-clicks, so a space pill can carry a context
/// menu without the sidebar having to hit-test manually.
@MainActor
final class SpaceButton: NSButton {
    var spaceID: String?
    var onContextMenu: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) { onContextMenu?() }

    /// ctrl-click is the same gesture on macOS and users expect it to work.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onContextMenu?(); return }
        super.mouseDown(with: event)
    }
}
