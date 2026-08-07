// spec: §5
import AppKit
import PaneCore
import PaneWeb

/// A tab row in the Pinned or Today list. Favicon slot plus title.
/// A discarded tab is dimmed — the user should be able to see which tabs cost
/// nothing right now, because that is the product's whole claim (spec §4).
@MainActor
final class TabRowView: NSTableCellView {
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    var onClose: (() -> Void)?

    init(tab: Tab, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        super.init(frame: .zero)
        self.isDiscarded = tab.lifecycle == .discarded

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        // spec §5 — a discarded row dims and swaps its favicon for a sleep
        // glyph. That is the only affordance for the memory behaviour.
        if tab.lifecycle == .discarded {
            icon.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "Discarded")
            icon.contentTintColor = .tertiaryLabelColor
        } else if let u = tab.url, let fav = FaviconFetcher.shared.icon(for: u) {
            icon.image = fav
            icon.contentTintColor = nil
        } else {
            icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
        }

        let label = NSTextField(labelWithString: tab.displayName)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        // Colour is set here for the UNSELECTED case; PillRowView flips it when
        // the row is selected and emphasized. Setting backgroundStyle alone did
        // nothing — NSTextField does not repaint from it — so the selected row
        // was dark text on an 85%-alpha accent fill, i.e. a contrast failure on
        // the one row the user is actually looking at.
        label.textColor = tab.lifecycle == .discarded ? .secondaryLabelColor : .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Close affordance, revealed on hover — the row should be quiet until
        // you point at it.
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        closeButton.alphaValue = 0
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        addSubview(icon); addSubview(label); addSubview(closeButton)
        textField = label
        imageView = icon

        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func closeTapped() { onClose?() }

    /// White on the accent pill, normal otherwise. Called by PillRowView, which
    /// is the only thing that knows whether the row is drawn selected.
    func setSelected(_ selected: Bool) {
        guard let label = textField else { return }
        if selected {
            label.textColor = .white
            closeButton.contentTintColor = .white
            imageView?.contentTintColor = imageView?.contentTintColor == nil ? nil : .white
        } else {
            label.textColor = isDiscarded ? .secondaryLabelColor : .labelColor
            closeButton.contentTintColor = .secondaryLabelColor
        }
    }

    private var isDiscarded = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.12
            closeButton.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.12
            closeButton.animator().alphaValue = 0
        }
    }
}

/// The selection pill. Arc draws a rounded, inset highlight rather than AppKit's
/// full-bleed row selection; matching that is most of what makes a sidebar read
/// as modern (docs/ui-parity.md).
@MainActor
final class PillRowView: NSTableRowView {
    var accent: NSColor = .controlAccentColor

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let inset = bounds.insetBy(dx: 6, dy: 1)
        // Zen --border-radius-medium: 10px (docs/zen-metrics.md)
        let path = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10)
        (isEmphasized ? accent.withAlphaComponent(0.85)
                      : NSColor.quaternaryLabelColor.withAlphaComponent(0.6)).setFill()
        path.fill()
    }

    /// Hover highlight, distinct from selection and much lighter.
    var isHovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Repaint the label whenever selection changes, so it can sit on the
    /// accent fill legibly. `drawSelection` cannot do this — it paints the
    /// background, not the subviews.
    override var isSelected: Bool { didSet { syncLabelColour() } }
    override var isEmphasized: Bool { didSet { syncLabelColour() } }

    private func syncLabelColour() {
        guard let cell = subviews.compactMap({ $0 as? TabRowView }).first
                ?? (self as NSView).subviews.first as? TabRowView else { return }
        cell.setSelected(isSelected && isEmphasized)
    }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, !isSelected else { return }
        let inset = bounds.insetBy(dx: 6, dy: 1)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10).fill()
    }
}

/// spec §5 — Essentials are an icon grid, four per row. One outline row renders
/// one chunk of up to four.
@MainActor
final class EssentialsRowView: NSView {
    private let onSelect: (TabID) -> Void

    init(ids: [TabID], model: TabModel, columns: Int = 4, onSelect: @escaping (TabID) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6

        for id in ids {
            guard let tab = model[id] else { continue }
            let b = NSButton()
            b.bezelStyle = .smallSquare
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 10   // Zen --border-radius-medium
            b.layer?.borderWidth = model.selected == id ? 1.5 : 0
            b.layer?.borderColor = NSColor.controlAccentColor.cgColor
            b.layer?.backgroundColor = (model.selected == id
                ? NSColor.controlAccentColor.withAlphaComponent(0.22)
                : NSColor.quaternaryLabelColor.withAlphaComponent(0.35)).cgColor
            if let u = tab.url, let fav = FaviconFetcher.shared.icon(for: u) {
                let big = fav.copy() as! NSImage
                big.size = NSSize(width: 22, height: 22)
                b.image = big
            } else {
                b.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: tab.displayName)
            }
            b.imageScaling = .scaleProportionallyUpOrDown
            b.toolTip = tab.displayName
            b.title = ""
            b.target = self
            b.action = #selector(tapped(_:))
            b.identifier = NSUserInterfaceItemIdentifier(id.raw.uuidString)
            b.alphaValue = tab.lifecycle == .discarded ? 0.55 : 1.0
            b.toolTip = tab.displayName
            stack.addArrangedSubview(b)
            // .fillEqually equalises WIDTH only; an NSButton keeps its intrinsic
            // height, which turns the tiles into pills. Pin height to the row so
            // they stay square.
            b.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
        // Zen uses grid auto-fit with a 48px minimum, so the column count
        // REFLOWS as the sidebar narrows rather than squashing four tiles into
        // pills. Fillers keep a short final row left-aligned.
        // Pad the final short row to the row's ACTUAL column count. Padding to
        // a hard-coded four stretched every tile when the sidebar was narrow
        // enough to fit only two or three.
        for _ in ids.count..<max(ids.count, columns) {
            let filler = NSView()
            filler.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(filler)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func tapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let uuid = UUID(uuidString: raw) else { return }
        onSelect(TabID(uuid))
    }
}
