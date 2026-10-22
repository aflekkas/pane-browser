// spec: §6 (Pane boring floor — downloads)
import Foundation
@preconcurrency import WebKit

final class BrowserDownloadTask: NSObject, WKDownloadDelegate {
    let id = UUID()
    var activity: BrowserDownloadActivity?
    var originalURL: URL
    /// Page the download was initiated from, for quarantine provenance.
    var pageURL: URL?
    /// Profile/Space scope of the originating web view, for resume checks.
    var profileScopeID: String?
    var onDestinationRequest: ((URLResponse, String, @escaping (URL?) -> Void) -> Void)?
    var onRedirect: ((URL) -> Void)?
    var onFinish: (() -> Void)?
    /// Carries WebKit's resume data (nil when the server cannot resume).
    var onFail: ((Error, Data?) -> Void)?
    /// Download-time auth challenges do not route through the navigation
    /// delegate; omitting this rejects the protection space silently.
    var onAuthChallenge: ((URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?))?
    private(set) var lastResumeData: Data?

    private let download: WKDownload

    init(download: WKDownload, originalURL: URL, pageURL: URL? = nil, profileScopeID: String? = nil) {
        self.download = download
        self.originalURL = originalURL
        self.pageURL = pageURL
        self.profileScopeID = profileScopeID
        super.init()
        self.download.delegate = self
    }

    var progress: Progress {
        download.progress
    }

    func clearCallbacks() {
        onDestinationRequest = nil
        onRedirect = nil
        onFinish = nil
        onFail = nil
        onAuthChallenge = nil
    }

    func cancel() {
        activity?.end(id)
        download.cancel { _ in }
    }

    /// Cancelling via this variant surfaces resume data so the download can
    /// be resumed later instead of restarted from zero.
    func cancel(completionHandler: @escaping (Data?) -> Void) {
        activity?.end(id)
        let once = OnceCompletion(completionHandler)
        download.cancel { [weak self] resumeData in
            self?.lastResumeData = resumeData
            once.call(resumeData)
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        if let onDestinationRequest {
            onDestinationRequest(response, suggestedFilename, completionHandler)
        } else {
            completionHandler(nil)
        }
    }

    func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void
    ) {
        if let url = newRequest.url {
            originalURL = url
            onRedirect?(url)
        }
        decisionHandler(.allow)
    }

    func downloadDidFinish(_ download: WKDownload) {
        activity?.end(id)
        onFinish?()
        clearCallbacks()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        lastResumeData = resumeData
        activity?.end(id)
        onFail?(error, resumeData)
        clearCallbacks()
    }

    func download(
        _ download: WKDownload,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if let onAuthChallenge {
            return await onAuthChallenge(challenge)
        }
        // Default handling fails closed for invalid server trust and lets
        // WebKit apply its own credential handling for HTTP auth spaces.
        return (.performDefaultHandling, nil)
    }
}
