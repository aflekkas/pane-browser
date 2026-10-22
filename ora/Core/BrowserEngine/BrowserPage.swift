import AppKit
import Foundation
@preconcurrency import WebKit

final class BrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var delegate: BrowserPageDelegate?

    private let webView: WKWebView
    private let messageNames: [String]
    private let isolatedMessageNames: Set<String>
    private var originalURL: URL?
    private(set) var lastCommittedURL: URL?
    private(set) var isDownloadNavigation = false
    private(set) var sslBypassedHosts: Set<String> = []
    private var isReadyForNavigation = false
    private var pendingLoadRequest: URLRequest?
    private var pendingReload = false
    private var pendingInteractionState: Data?
    /// Password-bridge per-document state (generation, token, tracked
    /// document URL). See `PasswordDocumentTracker`.
    let passwordTracker = PasswordDocumentTracker()
    private var urlObservation: NSKeyValueObservation?

    var passwordNavigationGeneration: Int {
        passwordTracker.generation
    }

    init(
        profile: BrowserEngineProfile,
        configuration: BrowserPageConfiguration,
        delegate: BrowserPageDelegate?
    ) {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.applicationNameForUserAgent = configuration.userAgent
        webConfiguration.websiteDataStore = profile.dataStore
        webConfiguration.allowsAirPlayForMediaPlayback = configuration.allowsAirPlayForMediaPlayback
        webConfiguration.preferences.setValue(
            configuration.allowsInspectableDebugging,
            forKey: "developerExtrasEnabled"
        )
        webConfiguration.preferences.setValue(
            configuration.allowsPictureInPicture,
            forKey: "allowsPictureInPictureMediaPlayback"
        )
        webConfiguration.preferences.setValue(configuration.allowsJavaScript, forKey: "javaScriptEnabled")
        webConfiguration.preferences.setValue(
            configuration.allowsJavaScriptWindowsAutomatically,
            forKey: "javaScriptCanOpenWindowsAutomatically"
        )
        webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically =
            configuration.allowsJavaScriptWindowsAutomatically
        webConfiguration.preferences.isElementFullscreenEnabled = true
        webConfiguration.preferences.inactiveSchedulingPolicy = .suspend
        webConfiguration.mediaTypesRequiringUserActionForPlayback =
            configuration.mediaPlaybackRequiresUserAction ? .all : []

        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = configuration.allowsJavaScript
        webConfiguration.defaultWebpagePreferences = webpagePreferences

        let contentController = WKUserContentController()
        webConfiguration.userContentController = contentController
        messageNames = configuration.scriptMessageNames
        isolatedMessageNames = configuration.isolatedScriptMessageNames
        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        self.delegate = delegate

        super.init()

        for messageName in configuration.scriptMessageNames {
            if isolatedMessageNames.contains(messageName) {
                contentController.add(self, contentWorld: PasswordBridge.world, name: messageName)
            } else {
                contentController.add(self, name: messageName)
            }
        }
        for script in configuration.userScripts {
            let userScript = WKUserScript(
                source: script.source,
                injectionTime: mapInjectionTime(script.injectionTime),
                forMainFrameOnly: script.forMainFrameOnly,
                in: script.contentWorld.wkContentWorld
            )
            contentController.addUserScript(userScript)
        }

        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            self?.passwordTracker.noteRouteChange(to: webView.url)
        }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = configuration.allowsBackForwardNavigationGestures
        webView.wantsLayer = true
        webView.isInspectable = configuration.allowsInspectableDebugging
        if let layer = webView.layer {
            layer.isOpaque = true
            layer.drawsAsynchronously = true
        }

        BrowserPrivacyService.shared.prepareConfiguration(
            webConfiguration,
            spaceID: profile.identifier
        ) { [weak self] in
            self?.isReadyForNavigation = true
            self?.flushPendingNavigationIfNeeded()
        }
    }

    var contentView: NSView {
        webView
    }

    var window: NSWindow? {
        webView.window
    }

    var currentURL: URL? {
        webView.url
    }

    var title: String? {
        webView.title
    }

    var canGoBack: Bool {
        webView.canGoBack
    }

    var canGoForward: Bool {
        webView.canGoForward
    }

    var isLoading: Bool {
        webView.isLoading
    }

    var estimatedProgress: Double {
        webView.estimatedProgress
    }

    /// Capture the live interaction state (history/scroll) for lifecycle
    /// checkpoint/discard. Must run before any teardown.
    func captureInteractionState() -> Data? {
        TabInteractionStateCodec.validated(webView.interactionState as? Data)
    }

    /// Restore an interaction-state blob through the privacy readiness
    /// gate: if content rules are still preparing, the blob is queued and
    /// applied by `flushPendingNavigationIfNeeded` instead of racing them.
    /// Returns whether WebKit already exposes a restored navigation item.
    @discardableResult
    func restoreInteractionState(_ data: Data) -> Bool {
        guard TabInteractionStateCodec.isValid(data) else { return false }
        guard isReadyForNavigation else {
            pendingInteractionState = data
            pendingLoadRequest = nil
            pendingReload = false
            return true
        }
        webView.interactionState = data
        return webView.backForwardList.currentItem != nil
    }

    func load(_ request: URLRequest) {
        guard isReadyForNavigation else {
            pendingLoadRequest = request
            pendingReload = false
            return
        }

        webView.load(request)
    }

    func reload() {
        guard isReadyForNavigation else {
            pendingReload = true
            pendingLoadRequest = nil
            return
        }

        webView.reload()
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func evaluateJavaScript(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        webView.evaluateJavaScript(script, completionHandler: completion)
    }

    /// Evaluate in the isolated password-bridge world. This is the only path
    /// allowed to touch `window.__oraPasswordManager`; page-world evaluation
    /// of that global would silently fail (and must never be re-pointed at
    /// the page world, which would hand fill to arbitrary page script).
    func evaluatePasswordJavaScript(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        webView.evaluateJavaScript(script, in: nil, in: PasswordBridge.world) { result in
            switch result {
            case let .success(value):
                completion?(value, nil)
            case let .failure(error):
                completion?(nil, error)
            }
        }
    }

    func takeSnapshot(
        configuration: BrowserSnapshotConfiguration,
        completion: @escaping (NSImage?, Error?) -> Void
    ) {
        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.afterScreenUpdates = configuration.afterScreenUpdates
        if let rect = configuration.rect {
            snapshotConfiguration.rect = rect
        }
        webView.takeSnapshot(with: snapshotConfiguration, completionHandler: completion)
    }

    func closeMediaPresentations(completion: @escaping () -> Void) {
        webView.closeAllMediaPresentations(completionHandler: completion)
    }

    /// Current password-bridge document context, or `nil` when no document
    /// has registered (fail closed). Equality covers page instance,
    /// generation, full origin, document URL, and document token.
    func currentPasswordContext() -> PasswordDocumentContext? {
        passwordTracker.context(
            pageIdentity: ObjectIdentifier(self),
            fallbackURL: webView.url ?? lastCommittedURL
        )
    }

    /// Re-handshake after a failed/cancelled provisional navigation: the
    /// previous document survives, but provisional start already retired
    /// its token, and its script only announces at installation. Ask the
    /// surviving isolated document to re-announce so fresh focus/fill can
    /// register a new context (at the new generation — fills captured
    /// before the navigation stay invalid). No-op when no committed
    /// document survives.
    private func rehandshakeSurvivingPasswordDocument() {
        guard passwordTracker.canRehandshake(committedURL: lastCommittedURL, currentURL: webView.url) else {
            return
        }
        evaluatePasswordJavaScript(
            "window.__oraPasswordManager && window.__oraPasswordManager.reannounce && window.__oraPasswordManager.reannounce();"
        )
    }

    func teardown() {
        passwordTracker.invalidate()
        urlObservation?.invalidate()
        urlObservation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        for messageName in messageNames {
            if isolatedMessageNames.contains(messageName) {
                controller.removeScriptMessageHandler(forName: messageName, contentWorld: PasswordBridge.world)
            } else {
                controller.removeScriptMessageHandler(forName: messageName)
            }
        }
        webView.removeFromSuperview()
    }

    func bypassSSL(for host: String) {
        sslBypassedHosts.insert(host)
    }

    private func flushPendingNavigationIfNeeded() {
        if let pendingInteractionState {
            self.pendingInteractionState = nil
            webView.interactionState = pendingInteractionState
            return
        }

        if let pendingLoadRequest {
            self.pendingLoadRequest = nil
            webView.load(pendingLoadRequest)
            return
        }

        if pendingReload {
            pendingReload = false
            webView.reload()
        }
    }

    private func emitNavigationEvent(
        phase: BrowserNavigationPhase,
        url: URL?,
        title: String?,
        progress: Double,
        isLoading: Bool
    ) {
        delegate?.browserPage(
            self,
            didUpdateNavigation: BrowserNavigationEvent(
                phase: phase,
                url: url,
                title: title,
                progress: progress,
                isLoading: isLoading
            )
        )
    }

    private func handleCancelledNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func mapInjectionTime(_ injectionTime: BrowserUserScriptInjectionTime) -> WKUserScriptInjectionTime {
        switch injectionTime {
        case .atDocumentStart:
            .atDocumentStart
        case .atDocumentEnd:
            .atDocumentEnd
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let frameURL = message.frameInfo.request.url
        if isolatedMessageNames.contains(message.name) {
            // Privileged bridge: the tracker registers bridgeReady tokens
            // and validates against WebKit's own frame facts plus the
            // registered document context, never the payload's claims.
            guard passwordTracker.shouldForwardMessage(
                isMainFrame: message.frameInfo.isMainFrame,
                frameURL: frameURL,
                pageURL: webView.url,
                committedURL: lastCommittedURL,
                body: message.body,
                pageIdentity: ObjectIdentifier(self)
            ) else {
                return
            }
        }
        delegate?.browserPage(
            self,
            didReceiveScriptMessage: BrowserScriptMessage(
                name: message.name,
                body: message.body,
                isMainFrame: message.frameInfo.isMainFrame,
                frameURL: frameURL,
                pageURL: webView.url
            )
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let action = BrowserNavigationAction(
            request: navigationAction.request,
            modifierFlags: navigationAction.modifierFlags
        )

        switch delegate?.browserPage(self, decidePolicyFor: action) ?? .allow {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .openInNewTab:
            if let url = navigationAction.request.url {
                delegate?.browserPage(self, didRequestOpenInNewTab: url)
            }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Any new navigation — including same-URL reload — retires the
        // previous document for password purposes immediately, while the
        // navigation is still in progress.
        passwordTracker.invalidate()
        if !isDownloadNavigation {
            originalURL = lastCommittedURL
            emitNavigationEvent(
                phase: .started,
                url: webView.url,
                title: webView.title,
                progress: 10.0,
                isLoading: true
            )
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if !isDownloadNavigation {
            lastCommittedURL = webView.url
            passwordTracker.commitDocument(url: webView.url)
            emitNavigationEvent(
                phase: .committed,
                url: webView.url,
                title: webView.title,
                progress: webView.estimatedProgress * 100.0,
                isLoading: true
            )
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isDownloadNavigation {
            lastCommittedURL = webView.url
            passwordTracker.commitDocument(url: webView.url)
            emitNavigationEvent(
                phase: .finished,
                url: webView.url,
                title: webView.title,
                progress: webView.estimatedProgress * 100.0,
                isLoading: false
            )
            originalURL = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isDownloadNavigation else {
            originalURL = nil
            return
        }

        emitNavigationEvent(
            phase: .finished,
            url: webView.url,
            title: webView.title,
            progress: 100.0,
            isLoading: false
        )

        if !handleCancelledNavigationError(error) {
            delegate?.browserPage(self, didFailNavigationWith: error, failingURL: webView.url)
        }
        rehandshakeSurvivingPasswordDocument()
        originalURL = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isDownloadNavigation else {
            originalURL = nil
            return
        }

        emitNavigationEvent(
            phase: .finished,
            url: webView.url,
            title: webView.title,
            progress: 100.0,
            isLoading: false
        )

        if handleCancelledNavigationError(error) {
            // Cancelled (e.g. stopLoading before commit): the committed
            // document survives and must be able to re-handshake.
            rehandshakeSurvivingPasswordDocument()
            return
        }

        rehandshakeSurvivingPasswordDocument()
        let nsError = error as NSError
        let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
        delegate?.browserPage(self, didFailNavigationWith: error, failingURL: failingURL)
        originalURL = nil
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust,
           sslBypassedHosts.contains(challenge.protectionSpace.host)
        {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    @available(macOS 11.3, *)
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.canShowMIMEType {
            isDownloadNavigation = false
            originalURL = nil
            decisionHandler(.allow)
            return
        }

        isDownloadNavigation = true
        emitNavigationEvent(
            phase: .finished,
            url: originalURL,
            title: webView.title,
            progress: 0,
            isLoading: false
        )
        decisionHandler(.download)
    }

    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard let downloadURL = navigationResponse.response.url else { return }
        let task = BrowserDownloadTask(download: download, originalURL: downloadURL)
        delegate?.browserPage(self, didStartDownload: task)
        isDownloadNavigation = false
        originalURL = nil
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let pageURL = URL(string: "\(origin.protocol)://\(origin.host):\(origin.port)")
        delegate?.browserPage(self, requestPermission: .mediaCapture, origin: pageURL) { decision in
            decisionHandler(decision == .grant ? .grant : .deny)
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        delegate?.browserPage(
            self,
            runOpenPanelWith: BrowserOpenPanelOptions(
                allowsDirectories: parameters.allowsDirectories,
                allowsMultipleSelection: parameters.allowsMultipleSelection
            ),
            completion: completionHandler
        )
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            delegate?.browserPage(self, didRequestOpenInNewTab: url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        delegate?.browserPage(self, runJavaScriptAlert: message)
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        delegate?.browserPage(self, runJavaScriptConfirm: message, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        delegate?.browserPage(
            self,
            runJavaScriptPrompt: prompt,
            defaultText: defaultText,
            completion: completionHandler
        )
    }
}
