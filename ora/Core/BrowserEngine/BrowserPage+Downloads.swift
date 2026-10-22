import AppKit
import Foundation
@preconcurrency import WebKit

/// Download, resume, and auth-challenge handling for `BrowserPage`,
/// extracted so the core page class stays within lint limits. WebKit
/// dispatches these delegate callbacks to the same instance.
extension BrowserPage {
    var hasActiveDownloads: Bool {
        downloadActivity.isActive
    }

    func cancelAuthentication() {
        MainActor.assumeIsolated { authenticationSession.cancel() }
    }

    var certificateExceptionScope: CertificateExceptionScope {
        CertificateExceptionScope(
            profileID: isPrivateProfile ? "private:\(privateSessionID.uuidString)" : profileIdentifier.uuidString,
            sessionID: Self.appSessionID
        )
    }

    /// Scope string stamped onto download tasks for resume checks.
    var downloadProfileScopeID: String {
        isPrivateProfile ? "private:\(privateSessionID.uuidString)" : profileIdentifier.uuidString
    }

    var windowForAuthSheets: NSWindow? {
        webView.window
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Route through the delegate (certificate exceptions + HTTP auth
        // live there); the default implementation is performDefaultHandling,
        // so no host-only bypass survives. Exactly-once via OnceCompletion.
        let once = OnceCompletion<(
            disposition: URLSession.AuthChallengeDisposition,
            credential: URLCredential?
        )> { result in
            completionHandler(result.disposition, result.credential)
        }
        guard let delegate else {
            once.call((.cancelAuthenticationChallenge, nil))
            return
        }
        delegate.browserPage(self, respondTo: challenge, scope: certificateExceptionScope) { disposition, credential in
            once.call((disposition: disposition, credential: credential))
        }
    }

    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard let downloadURL = navigationResponse.response.url else { return }
        let task = BrowserDownloadTask(
            download: download,
            originalURL: downloadURL,
            pageURL: webView.url,
            profileScopeID: downloadProfileScopeID
        )
        delegate?.browserPage(self, didStartDownload: task)
        isDownloadNavigation = false
        originalURL = nil
    }

    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let task = BrowserDownloadTask(
            download: download,
            originalURL: navigationAction.request.url ?? webView.url ?? URL(string: "about:blank")!,
            pageURL: webView.url,
            profileScopeID: downloadProfileScopeID
        )
        delegate?.browserPage(self, didStartDownload: task)
    }
}
