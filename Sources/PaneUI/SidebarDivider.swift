// spec: §5
import AppKit

/// A 6pt hit target that draws as a 1px hairline. Arc-parity: the sidebar must
/// be resizable, and a 1px divider is almost impossible to grab.
@MainActor
final class SidebarDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var lastX: CGFloat?

    override func draw(_ dirtyRect: NSRect) {
        // separatorColor is nearly invisible against a dark sidebar next to a
        // dark content area — the two panes read as one surface with a seam.
        // A slightly stronger line is what actually separates them.
        NSColor.separatorColor.blended(withFraction: 0.35, of: .labelColor)?.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        // Track against the WINDOW, not this view: the view moves as the
        // sidebar resizes, so view-local deltas feed back on themselves and the
        // drag accelerates away from the pointer.
        let x = event.locationInWindow.x
        guard let last = lastX else { lastX = x; return }
        onDrag?(x - last)
        lastX = x
    }

    override func mouseUp(with event: NSEvent) { lastX = nil }
}
