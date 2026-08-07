// spec: §6
import AppKit
import WebKit

/// spec §6 context menus.
///
/// **Correction to the spec:** it names
/// `webView(_:contextMenuConfigurationForElement:)`, which is
/// `API_AVAILABLE(ios(13.0))` and takes a `UIContextMenuConfiguration`. It will
/// never fire on macOS. The macOS WebKit hook is SPI, so the supported route is
/// to subclass `WKWebView` and override `NSView.willOpenMenu(_:with:)`.
/// See `docs/research/2026-08-07-boring-floor.md`.
public final class PaneWebView: WKWebView {
    /// Called with the menu WebKit proposed, so the host can add its own items
    /// (notably "Open in New Tab" and the per-space submenu §6 calls the thing
    /// that makes multi-space usable).
    public var decorateMenu: ((NSMenu) -> Void)?

    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        decorateMenu?(menu)
    }
}
