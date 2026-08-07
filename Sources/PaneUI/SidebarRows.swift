// spec: §5
import AppKit
import PaneCore

/// A tab row in the Pinned or Today list. Favicon slot plus title.
/// A discarded tab is dimmed — the user should be able to see which tabs cost
/// nothing right now, because that is the product's whole claim (spec §4).
@MainActor
final class TabRowView: NSTableCellView {
    init(tab: Tab) {
        super.init(frame: .zero)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.image = NSImage(systemSymbolName: tab.lifecycle == .discarded ? "moon.zzz" : "globe",
                             accessibilityDescription: nil)
        icon.contentTintColor = tab.lifecycle == .discarded ? .tertiaryLabelColor : .secondaryLabelColor

        let label = NSTextField(labelWithString: tab.displayName)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.textColor = tab.lifecycle == .discarded ? .secondaryLabelColor : .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(icon); addSubview(label)
        textField = label
        imageView = icon

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// spec §5 — Essentials are an icon grid, four per row. One outline row renders
/// one chunk of up to four.
@MainActor
final class EssentialsRowView: NSView {
    private let onSelect: (TabID) -> Void

    init(ids: [TabID], model: TabModel, onSelect: @escaping (TabID) -> Void) {
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
            b.layer?.cornerRadius = 8
            b.layer?.backgroundColor = (model.selected == id
                ? NSColor.controlAccentColor.withAlphaComponent(0.22)
                : NSColor.quaternaryLabelColor.withAlphaComponent(0.35)).cgColor
            b.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: tab.displayName)
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = tab.displayName
            b.title = ""
            b.target = self
            b.action = #selector(tapped(_:))
            b.identifier = NSUserInterfaceItemIdentifier(id.raw.uuidString)
            b.alphaValue = tab.lifecycle == .discarded ? 0.55 : 1.0
            stack.addArrangedSubview(b)
        }
        // Keep the grid to four columns even when the chunk is short, so a row
        // of two essentials does not stretch into two huge tiles.
        for _ in ids.count..<4 {
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
