// spec: §6 (Pane boring floor — downloads)
import Foundation
@preconcurrency import WebKit

final class BrowserDownloadTask: NSObject, WKDownloadDelegate {
    let id = UUID()
    let isResumed: Bool
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

    init(
        download: WKDownload, originalURL: URL, pageURL: URL? = nil,
        profileScopeID: String? = nil, isResumed: Bool = false
    ) {
        self.download = download
        self.isResumed = isResumed
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
            let usableData = self?.isResumed == false ? resumeData : nil
            self?.lastResumeData = usableData
            once.call(usableData)
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
        // On supported macOS WebKit, resuming an already-resumed transfer
        // can add the previous Range offset twice (measured by the real
        // fixture). Never replay that second blob: retry must start fresh
        // in the SAME session. Opaque resume data is not rewritten by us.
        let usableData = isResumed ? nil : resumeData
        lastResumeData = usableData
        activity?.end(id)
        onFail?(error, usableData)
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
