// spec: §1
import AppKit
import WebKit
import PaneCore
import PaneWeb

/// Milestone A: one window, an address bar, one WKWebView. Deliberately the
/// smallest thing that is genuinely a browser rather than a fixed-URL demo,
/// because the app must be launchable from week one and never stop being
/// launchable.
@MainActor
public final class BrowserWindowController: NSWindowController, NSTextFieldDelegate {
    private let engine: WKWebEngine
    private let addressBar = NSTextField()
    private let progress = NSProgressIndicator()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()

    public init(url: URL? = nil) {
        self.engine = WKWebEngine()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Pane"
        window.titlebarAppearsTransparent = true
        window.center()
        super.init(window: window)
        buildChrome()
        engine.onEvent = { [weak self] in self?.handle($0) }
        if let url { engine.load(url) }
        else if let home = URLNormalizer.resolve("duckduckgo.com") { engine.load(home) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildChrome() {
        guard let window, let content = window.contentView else { return }

        // Toolbar row. AppKit, not web content — the hard rule (spec §1).
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true

        for (btn, glyph, action) in [
            (backButton, "chevron.left", #selector(goBack)),
            (forwardButton, "chevron.right", #selector(goForward)),
            (reloadButton, "arrow.clockwise", #selector(reload)),
        ] {
            btn.image = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)
            btn.bezelStyle = .texturedRounded
            btn.target = self
            btn.action = action
            btn.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(btn)
        }
        backButton.isEnabled = false
        forwardButton.isEnabled = false

        addressBar.translatesAutoresizingMaskIntoConstraints = false
        addressBar.placeholderString = "Search or enter address"
        addressBar.delegate = self
        addressBar.target = self
        addressBar.action = #selector(commitAddress)
        addressBar.bezelStyle = .roundedBezel
        addressBar.focusRingType = .none
        bar.addSubview(addressBar)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        bar.addSubview(progress)

        let web = engine.webView
        web.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        content.addSubview(web)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),

            backButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 32),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            forwardButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 32),
            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 4),
            reloadButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 32),

            addressBar.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 8),
            addressBar.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            addressBar.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            progress.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),

            web.topAnchor.constraint(equalTo: bar.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    // MARK: - Commands
    // Everything routes through dispatch(_:) so a scenario and a key chord take
    // the identical path (ADR 0006).

    public func dispatch(_ c: Command) {
        switch c {
        case .navigate(let raw):
            guard let url = URLNormalizer.resolve(raw) else { return }
            engine.load(url)
        case .goBack:       engine.goBack()
        case .goForward:    engine.goForward()
        case .reload:       engine.reload()
        case .stopLoading:  engine.stopLoading()
        case .focusAddressBar:
            window?.makeFirstResponder(addressBar)
            addressBar.currentEditor()?.selectAll(nil)
        }
    }

    @objc private func goBack()    { dispatch(.goBack) }
    @objc private func goForward() { dispatch(.goForward) }
    @objc private func reload()    { dispatch(.reload) }
    @objc public func focusAddress() { dispatch(.focusAddressBar) }
    @objc private func commitAddress() { dispatch(.navigate(addressBar.stringValue)) }

    private func handle(_ e: WebEngineEvent) {
        switch e {
        case .progressChanged(let p):
            progress.doubleValue = p
            progress.isHidden = p >= 1.0 || p <= 0.0
        case .titleChanged(let t):
            window?.title = (t?.isEmpty == false) ? t! : "Pane"
        case .urlChanged(let u):
            if let u, window?.firstResponder !== addressBar.currentEditor() {
                addressBar.stringValue = URLNormalizer.display(u)
            }
            syncNavButtons()
        case .didFinish, .didCommit:
            syncNavButtons()
        case .didFail(_, let message):
            // spec §1: error UI is AppKit, never web content.
            progress.isHidden = true
            presentError(message)
        case .contentProcessDidTerminate:
            // spec §6: never silently reload.
            presentError("This page stopped responding.")
        default: break
        }
    }

    private func syncNavButtons() {
        backButton.isEnabled = engine.canGoBack
        forwardButton.isEnabled = engine.canGoForward
    }

    private func presentError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn’t load the page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // spec §4 — restore state proving ground.
    public func captureState() -> Data? { engine.captureInteractionState() }
    public func restoreState(_ d: Data) { engine.restoreInteractionState(d) }
}
