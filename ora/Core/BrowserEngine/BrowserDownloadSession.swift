import AppKit
import Foundation
@preconcurrency import WebKit

@MainActor
protocol DownloadTransferSession: AnyObject {
    var profileScopeID: String { get }
    func start(_ record: Download, resumeData: Data?, completion: @escaping (BrowserDownloadTask?) -> Void)
    func cancelPending(_ recordID: UUID)
}

extension DownloadTransferSession {
    func cancelPending(_ recordID: UUID) {}
}

/// Retains the exact WebKit data store, including a private store's identity,
/// even if the initiating tab closes. Never routes retry through the key window.
@MainActor
final class BrowserDownloadSession: DownloadTransferSession {
    let profileScopeID: String
    private let webView: WKWebView
    private let activity: BrowserDownloadActivity
    private weak var page: BrowserPage?
    private var pending: [UUID: UUID] = [:]
    private weak var retryWindow: NSWindow?
    private var restoredScope: CertificateExceptionScope?
    private let authenticationSession = BrowserAuthenticationSession()

    init(page: BrowserPage) {
        self.page = page
        activity = page.downloadActivity
        webView = page.webView
        profileScopeID = page.downloadProfileScopeID
    }

    /// Called only after the manager finds this regular profile in its model
    /// store. A private store cannot be reconstructed from a persisted ID.
    init(restoringRegularProfile identifier: UUID, window: NSWindow?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = BrowserEngine.shared.makeProfile(identifier: identifier, isPrivate: false)
            .dataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        profileScopeID = identifier.uuidString
        activity = BrowserDownloadActivity()
        retryWindow = window
        restoredScope = CertificateExceptionScope(profileID: profileScopeID, sessionID: BrowserPage.appSessionID)
    }

    func configure(_ task: BrowserDownloadTask) {
        task.activity = activity
        activity.begin(task.id)
        task.onAuthChallenge = { [weak self, weak page, weak task] challenge in
            if let self, let scope = self.restoredScope {
                let operation = self.authenticationSession.begin(window: self.retryWindow)
                task?.onCancelAuthentication = { [weak operation] in operation?.cancel() }
                let result = await BrowserAuthHandler.respond(
                    to: challenge, window: self.retryWindow, scope: scope, operation: operation
                )
                task?.onCancelAuthentication = nil
                let active = operation.isActive
                operation.finish()
                return active ? result : (.cancelAuthenticationChallenge, nil)
            }
            guard let page, let delegate = page.delegate else { return (.cancelAuthenticationChallenge, nil) }
            return await withCheckedContinuation { continuation in
                let once = OnceCompletion<(URLSession.AuthChallengeDisposition, URLCredential?)> {
                    continuation.resume(returning: $0)
                }
                delegate.browserPage(page, respondTo: challenge, scope: page.certificateExceptionScope) {
                    task?.onCancelAuthentication = nil
                    once.call(($0, $1))
                }
                // The tab delegate installs its owner synchronously, before
                // presenting. Cancelling this transfer dismisses only that
                // challenge, never a newer navigation's prompt.
                let operation = page.authenticationSession.activeOperation
                task?.onCancelAuthentication = { [weak operation] in operation?.cancel() }
            }
        }
    }

    func start(_ record: Download, resumeData: Data?, completion: @escaping (BrowserDownloadTask?) -> Void) {
        // This gate MUST precede either WebKit invocation. Resume blobs can
        // contain authenticated requests; checking the returned task is too late.
        guard DownloadSafety.canResume(downloadProfileID: record.profileID, taskProfileID: profileScopeID) else {
            completion(nil)
            return
        }
        let pendingID = UUID()
        activity.begin(pendingID)
        pending[record.id] = pendingID
        let received: @MainActor @Sendable (WKDownload) -> Void = { [self] download in
            let task = BrowserDownloadTask(
                download: download, originalURL: record.originalURL,
                pageURL: record.pageURLString.flatMap(URL.init(string:)), profileScopeID: profileScopeID,
                isResumed: resumeData != nil
            )
            guard pending[record.id] == pendingID else {
                task.cancel()
                completion(nil)
                return
            }
            pending.removeValue(forKey: record.id)
            configure(task)
            activity.end(pendingID)
            completion(task)
        }
        if let resumeData {
            webView.resumeDownload(fromResumeData: resumeData, completionHandler: received)
        } else {
            webView.startDownload(using: URLRequest(url: record.originalURL), completionHandler: received)
        }
    }

    func cancelPending(_ recordID: UUID) {
        if let pendingID = pending.removeValue(forKey: recordID) {
            activity.end(pendingID)
        }
    }
}
