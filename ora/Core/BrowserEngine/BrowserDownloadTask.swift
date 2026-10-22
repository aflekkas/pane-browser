// spec: §6 (Pane boring floor — downloads)
import Foundation
@preconcurrency import WebKit

final class BrowserDownloadTask: NSObject, WKDownloadDelegate {
    let id = UUID()
    let isResumed: Bool
    var activity: BrowserDownloadActivity?
    /// Recovered fresh requests use a separate top-level navigation context.
    /// Keep that exact data-store owner alive until this task is released.
    var sourceWebView: WKWebView?
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
    var onCancelAuthentication: (() -> Void)?
    private(set) var lastResumeData: Data?

    let progress: Progress
    private let cancelTransfer: (@escaping (Data?) -> Void) -> Void

    convenience init(
        download: WKDownload, originalURL: URL, pageURL: URL? = nil,
        profileScopeID: String? = nil, isResumed: Bool = false
    ) {
        self.init(
            originalURL: originalURL, pageURL: pageURL, profileScopeID: profileScopeID,
            isResumed: isResumed, progress: download.progress,
            cancelTransfer: { completion in download.cancel { completion($0) } }
        )
        download.delegate = self
    }

    /// The cancellation operation is injectable so its asynchronous lifetime
    /// can be tested without subclassing or swizzling WebKit.
    init(
        originalURL: URL, pageURL: URL? = nil, profileScopeID: String? = nil,
        isResumed: Bool = false, progress: Progress,
        cancelTransfer: @escaping (@escaping (Data?) -> Void) -> Void
    ) {
        self.isResumed = isResumed
        self.originalURL = originalURL
        self.pageURL = pageURL
        self.profileScopeID = profileScopeID
        self.progress = progress
        self.cancelTransfer = cancelTransfer
        super.init()
    }

    func clearCallbacks() {
        onDestinationRequest = nil
        onRedirect = nil
        onFinish = nil
        onFail = nil
        onAuthChallenge = nil
        onCancelAuthentication = nil
    }

    func cancel() {
        onCancelAuthentication?()
        onCancelAuthentication = nil
        activity?.end(id)
        cancelTransfer { _ in }
    }

    /// Cancelling via this variant surfaces resume data so the download can
    /// be resumed later instead of restarted from zero.
    func cancel(completionHandler: @escaping (Data?) -> Void) {
        onCancelAuthentication?()
        onCancelAuthentication = nil
        activity?.end(id)
        let once = OnceCompletion(completionHandler)
        // WebKit keeps its delegate weakly. The manager releases this wrapper
        // immediately after cancel, so the decision cannot depend on its lifetime.
        let mayResume = !isResumed
        cancelTransfer { [weak self] resumeData in
            let usableData = mayResume ? resumeData : nil
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
