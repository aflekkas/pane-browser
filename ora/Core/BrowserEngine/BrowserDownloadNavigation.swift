import AppKit
@preconcurrency import WebKit

/// A recovered session has no displayed page. startDownload uses that page's
/// cookie context, so a blank view silently drops first-party cookies. A real
/// top-level navigation supplies WebKit's normal cookie/redirect/auth policy;
/// convert its response before displaying or executing any downloaded content.
@MainActor
final class BrowserDownloadNavigation: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let scope: CertificateExceptionScope
    private weak var window: NSWindow?
    private let authentication = BrowserAuthenticationSession()
    private var completion: ((WKDownload?) -> Void)?
    private var converting = false

    init(dataStore: WKWebsiteDataStore, scope: CertificateExceptionScope, window: NSWindow?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.scope = scope
        self.window = window
        super.init()
        webView.navigationDelegate = self
    }

    func start(_ request: URLRequest, completion: @escaping (WKDownload?) -> Void) {
        self.completion = completion
        webView.load(request)
    }

    func cancel() {
        authentication.cancel()
        webView.stopLoading()
        finish(nil)
    }

    private func finish(_ download: WKDownload?) {
        guard let completion else { download?.cancel { _ in }
            return
        }
        self.completion = nil
        authentication.cancel()
        webView.navigationDelegate = nil
        completion(download)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard completion != nil else { decisionHandler(.cancel)
            return
        }
        converting = true
        decisionHandler(.download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        finish(download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        finish(download)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        if converting, error.domain == "WebKitErrorDomain", error.code == 102 {
            return
        }
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard completion != nil else { completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let operation = authentication.begin(window: window)
        Task { @MainActor in
            let result = await BrowserAuthHandler.respond(
                to: challenge,
                window: window,
                scope: scope,
                operation: operation
            )
            let active = operation.isActive && completion != nil
            operation.finish()
            completionHandler(active ? result.0 : .cancelAuthenticationChallenge, active ? result.1 : nil)
        }
    }
}
