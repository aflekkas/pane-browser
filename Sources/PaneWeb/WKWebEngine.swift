// spec: §1
import Foundation
import WebKit
import PaneCore

/// The only place WebKit is imported. A translator: WK delegate callbacks in,
/// `WebEngineEvent` out. Keeping this thin is what lets everything upstream be
/// tested without WebKit (ADR 0006).
@MainActor
public final class WKWebEngine: NSObject, WebEngine {
    public let webView: PaneWebView
    public var onEvent: ((WebEngineEvent) -> Void)?
    /// Host hooks for the parts of §6 that need app-level context.
    public var onDownload: ((WKDownload, URL?) -> Void)?
    public var onOpenInNewTab: ((URL) -> Void)?
    /// spec §6 — the per-space submenu. Supplies (spaceID, name) pairs and
    /// receives the chosen destination. §6 calls this "what makes multi-space
    /// actually usable", and it is: without it, moving a link to another space
    /// means opening it, dragging the row, and confirming a dialog.
    public var spacesProvider: (() -> [(id: String, name: String)])?
    public var onOpenInSpace: ((URL, String) -> Void)?
    public var authHandler: ((URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?))?
    public var openPanelHandler: ((WKOpenPanelParameters, @escaping ([URL]?) -> Void) -> Void)?
    public var jsDialogHandler: ((String, String, @escaping (Bool) -> Void) -> Void)?
    /// spec §7 — a login form was seen or submitted in the page.
    public var onLoginForm: ((LoginFormInfo) -> Void)?
    private var observers: [NSKeyValueObservation] = []

    /// spec §3 — the identified data store is what makes spaces real. Handing
    /// in `.default()` would silently share one cookie jar across every space,
    /// which is the exact failure this API exists to prevent.
    public static func store(forProfile uuid: UUID) -> WKWebsiteDataStore {
        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: uuid)
        }
        return .default()
    }

    public init(dataStore: WKWebsiteDataStore = .default(), allowsJavaScript: Bool = true) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        // DRM vendors match on this; not spoofing for fun (spec §8).
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"

        // Set explicitly for intent and older-OS safety. On macOS 15+ SDK links
        // this is already the default — which is why the spec's manual freeze
        // tier was deleted (ADR 0001).
        if #available(macOS 14.0, *) {
            config.preferences.inactiveSchedulingPolicy = .suspend
        }
        // spec §6 — the escape hatch for a page that keeps killing its renderer.
        config.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript

        // spec §7 — detection script in an ISOLATED world. The handler is
        // registered for that world too, so page script cannot reach it.
        config.userContentController.addUserScript(CredentialBridge.userScript)

        self.webView = PaneWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.addScriptMessageHandler(
            self, contentWorld: CredentialBridge.world, name: CredentialBridge.messageName)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.decorateMenu = { [weak self] menu in self?.decorate(menu) }
        observe()
    }

    private func observe() {
        observers = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.onEvent?(.progressChanged(wv.estimatedProgress)) }
            },
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.onEvent?(.titleChanged(wv.title)) }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.onEvent?(.urlChanged(wv.url)) }
            },
        ]
    }

    public var currentURL: URL? { webView.url }
    public var title: String? { webView.title }
    public var canGoBack: Bool { webView.canGoBack }
    public var canGoForward: Bool { webView.canGoForward }
    public var estimatedProgress: Double { webView.estimatedProgress }

    public func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }
    public func reload() { webView.reload() }
    public func stopLoading() { webView.stopLoading() }

    /// spec §7 — fill, into the isolated world. `callAsyncJavaScript` in that
    /// world can still touch the DOM, which is what the fill needs; it just
    /// cannot be seen by page script.
    ///
    /// Success is confirmed by reading the DOM back, **not** by trusting the
    /// call's return value: `callAsyncJavaScript(_:arguments:in:in:)` bridges
    /// its result as `Void` here regardless of what the JS returns, so
    /// `as? Bool` is always nil and a working fill reports failure. Measured —
    /// it cost an hour. See docs/api-notes/webkit.md.
    public func fillCredentials(username: String, password: String) async -> Bool {
        _ = try? await webView.callAsyncJavaScript(
            "window.__paneFill(u, p);",
            arguments: ["u": username, "p": password],
            in: nil, in: CredentialBridge.world)
        // Read back through the ONE-ARGUMENT evaluateJavaScript, which does
        // bridge its result. Reading from the page world is deliberate: it
        // proves the isolated world's DOM write actually crossed the boundary.
        let readBack: Any? = try? await webView.evaluateJavaScript(
            "document.querySelector('input[type=password]')?.value ?? ''")
        return (readBack as? String) == password
    }

    /// spec §7 — reads the password field, ONLY when the user has agreed to
    /// save. Deliberately a separate call from detection: a secret should cross
    /// into Swift at the moment of consent, not speculatively on every page
    /// that happens to have a password field.
    public func readPasswordFieldForSaving() async -> String? {
        let v: Any? = try? await webView.evaluateJavaScript(
            "document.querySelector('input[type=password]')?.value ?? ''")
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    /// spec §4 — the blob the entire discard/restore claim rests on.
    public func captureInteractionState() -> Data? {
        webView.interactionState as? Data
    }

    /// Must be assigned BEFORE the view enters the hierarchy (spec §4).
    public func restoreInteractionState(_ data: Data) {
        webView.interactionState = data
    }
}

extension WKWebEngine {
    /// spec §6 — the must-have items. WebKit's proposed menu already carries
    /// copy/save/inspect; this adds what a tabbed browser needs.
    private func decorate(_ menu: NSMenu) {
        // WebKit does not tell us the clicked link through public API, so offer
        // the current page. Link-specific items would need the SPI element info.
        guard let url = webView.url else { return }
        menu.insertItem(.separator(), at: 0)
        let item = NSMenuItem(title: "Open in New Tab", action: #selector(openCurrentInNewTab), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        menu.insertItem(item, at: 0)

        let spaces = spacesProvider?() ?? []
        guard spaces.count > 1 else { return }
        let submenu = NSMenu()
        for s in spaces {
            let mi = NSMenuItem(title: s.name, action: #selector(openInSpace(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = [url.absoluteString, s.id]
            submenu.addItem(mi)
        }
        let spacesItem = NSMenuItem(title: "Open in Space", action: nil, keyEquivalent: "")
        spacesItem.submenu = submenu
        menu.insertItem(spacesItem, at: 1)
    }

    @objc private func openInSpace(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let url = URL(string: pair[0]) else { return }
        onOpenInSpace?(url, pair[1])
    }

    @objc private func openCurrentInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInNewTab?(url)
    }
}

extension WKWebEngine: WKScriptMessageHandlerWithReply {
    public func userContentController(_ c: WKUserContentController,
                                      didReceive message: WKScriptMessage) async
        -> (Any?, String?) {
        // Untrusted input from a web page: parsed through a closed struct and
        // dropped if it does not fit, never consumed as a loose dictionary.
        guard message.name == CredentialBridge.messageName,
              let info = LoginFormInfo(message.body) else { return (nil, nil) }
        onLoginForm?(info)
        return (nil, nil)
    }
}

extension WKWebEngine: WKUIDelegate {
    /// spec §6 uploads.
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        if let handler = openPanelHandler {
            handler(parameters) { completionHandler($0) }
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    /// spec §1 — JS dialogs are AppKit, never web content.
    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor () -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK")
        a.runModal(); completionHandler()
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    /// target=_blank and window.open land here. Returning nil and loading in
    /// place would silently swallow the navigation.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { onOpenInNewTab?(url) }
        return nil
    }
}

extension WKWebEngine: WKNavigationDelegate {
    public func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
        onEvent?(.didStartNavigation(w.url))
    }
    public func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        onEvent?(.didCommit(w.url))
    }
    public func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        onEvent?(.didFinish(w.url, title: w.title))
    }
    public func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        onEvent?(.didFail(w.url, message: e.localizedDescription))
    }
    public func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        onEvent?(.didFail(w.url, message: e.localizedDescription))
    }
    /// spec §6 — never silently reload; that is how you get an infinite crash
    /// loop on a bad page.
    public func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        onEvent?(.contentProcessDidTerminate)
    }

    /// spec §6 — auth and TLS both arrive here. The default when unimplemented
    /// is rejectProtectionSpace, so an unhandled challenge fails silently.
    public func webView(_ w: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if let authHandler { return await authHandler(challenge) }
        return (.performDefaultHandling, nil)
    }

    /// spec §6 — a response that is an attachment becomes a download.
    public func webView(_ w: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    public func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse,
                        didBecome download: WKDownload) {
        onDownload?(download, w.url)
    }

    public func webView(_ w: WKWebView, navigationAction: WKNavigationAction,
                        didBecome download: WKDownload) {
        onDownload?(download, w.url)
    }
}
