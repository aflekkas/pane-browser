// spec: §1
import Foundation
import WebKit
import PaneCore

/// The only place WebKit is imported. A translator: WK delegate callbacks in,
/// `WebEngineEvent` out. Keeping this thin is what lets everything upstream be
/// tested without WebKit (ADR 0006).
@MainActor
public final class WKWebEngine: NSObject, WebEngine {
    public let webView: WKWebView
    public var onEvent: ((WebEngineEvent) -> Void)?
    private var observers: [NSKeyValueObservation] = []

    public init(dataStore: WKWebsiteDataStore = .default()) {
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

        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
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

    /// spec §4 — the blob the entire discard/restore claim rests on.
    public func captureInteractionState() -> Data? {
        webView.interactionState as? Data
    }

    /// Must be assigned BEFORE the view enters the hierarchy (spec §4).
    public func restoreInteractionState(_ data: Data) {
        webView.interactionState = data
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
}
