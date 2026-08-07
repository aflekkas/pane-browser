// spec: §5
import AppKit

/// spec §5 — the Liquid Glass sidebar. **Milestone G, built last on purpose.**
///
/// Deployment target is macOS 14; `NSGlassEffectView` is macOS 26.0+. Compiled
/// against the 26.5 SDK and gated at runtime, so one binary serves both.
///
/// Three constraints from §5, each because the alternative is expensive or ugly:
///
/// - **One container for the whole sidebar**, never one per row. Nested glass
///   views each get their own backdrop sampling pass; a container merges them
///   into one and lets adjacent shapes blend.
/// - **`.regular`, never `.clear`.** Clear glass over a busy webpage fails
///   contrast exactly when the user needs to read a tab title.
/// - **Zero glass over the content area. Ever.** Glass over scrolling web
///   content forces continuous resampling of a continuously changing backdrop —
///   §5 calls it "the single most expensive thing you could do", and nothing
///   here goes near it.
@MainActor
public enum GlassLayer {

    /// Glass is available AND the user has not asked for reduced transparency.
    ///
    /// §5 requires respecting `accessibilityDisplayShouldReduceTransparency`.
    /// Read at call time rather than cached: the user can change it while the
    /// app is running, and a cached answer would ignore them until relaunch.
    /// Forced off for visual goldens. Glass samples a live backdrop from the
    /// window server; drawn into an offscreen bitmap there is nothing to
    /// sample, so the sidebar renders washed out and near-transparent. Goldens
    /// regression-test LAYOUT, and layout is what stays comparable — so they
    /// capture the flat path deliberately rather than photographing a material
    /// that cannot exist offscreen.
    nonisolated(unsafe) public static var forceDisabled = false

    public static var isEnabled: Bool {
        guard #available(macOS 26.0, *), !forceDisabled else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// Wraps the sidebar in a single glass container, or returns nil when glass
    /// is unavailable so the caller keeps its flat fill.
    ///
    /// Returns `NSView` rather than the concrete type so callers need no
    /// availability annotation of their own.
    public static func makeContainer(spacing: CGFloat = 12) -> NSView? {
        guard #available(macOS 26.0, *), isEnabled else { return nil }
        let container = NSGlassEffectContainerView()
        // §5: ~12 so selected-row glass pills visually merge when adjacent
        // rather than reading as separate blobs.
        container.spacing = spacing
        return container
    }

    /// The content view goes INSIDE the container, which is what makes the
    /// merged sampling pass work.
    public static func setContent(_ content: NSView, in container: NSView) {
        guard #available(macOS 26.0, *),
              let glass = container as? NSGlassEffectContainerView else { return }
        glass.contentView = content
    }

    /// The selection indicator. §5: it **animates position** between rows, it
    /// does not fade in and out — a fade reads as two selections briefly
    /// existing, which is exactly what a selection must never suggest.
    public static func makeSelectionPill(cornerRadius: CGFloat, tint: NSColor) -> NSView? {
        guard #available(macOS 26.0, *), isEnabled else { return nil }
        let pill = NSGlassEffectView()
        pill.cornerRadius = cornerRadius
        pill.tintColor = tint
        return pill
    }

    /// Move the pill to a new frame. Animated, and deliberately short: a
    /// selection that takes long enough to notice feels laggy rather than
    /// smooth.
    public static func move(_ pill: NSView, to frame: NSRect, animated: Bool = true) {
        guard animated else { pill.frame = frame; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pill.animator().frame = frame
        }
    }

    /// What the sidebar reports for the record. Kept because milestone G's gate
    /// is a *measured* CPU/energy delta against the flat build, and that
    /// measurement is meaningless without knowing which path actually ran.
    public static var describeState: String {
        if forceDisabled { return "flat (forced off for goldens)" }
        if #available(macOS 26.0, *) {
            return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                ? "flat (reduce transparency is on)"
                : "glass (NSGlassEffectContainerView)"
        }
        return "flat (macOS < 26)"
    }
}
