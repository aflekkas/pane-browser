import AppKit
import Foundation
@preconcurrency import WebKit

final class BrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var delegate: BrowserPageDelegate?

    let webView: WKWebView
    private let messageNames: [String]
    private let isolatedMessageNames: Set<String>
    var originalURL: URL?
    private(set) var lastCommittedURL: URL?
    var isDownloadNavigation = false
    /// Profile (container/Space) this page belongs to; scopes certificate
    /// exceptions and download resume. Retained from init.
    let profileIdentifier: UUID
    let isPrivateProfile: Bool
    let privateSessionID: UUID
    @MainActor lazy var authenticationSession = BrowserAuthenticationSession()
    let downloadActivity = BrowserDownloadActivity()
    /// One app-run session identifier for certificate-exception scope.
    static let appSessionID = UUID().uuidString

    private var isReadyForNavigation = false
    private var pendingLoadRequest: URLRequest?
    private var pendingReload = false
    private let lifecycleRestoration = TabLifecycleRestoreController()
    private var lifecycleRestoreInFlight = false
    private let lifecycleCheckpoint = BrowserLifecycleCheckpoint()
    var onLifecycleNavigation: (() -> Void)?
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
        delegate: BrowserPageDelegate?,
        navigationReadinessGate: ((@escaping () -> Void) -> Void)? = nil
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

        profileIdentifier = profile.identifier
        isPrivateProfile = profile.isPrivate
        privateSessionID = profile.privateSessionID

        let contentController = WKUserContentController()
        webConfiguration.userContentController = contentController
        messageNames = configuration.scriptMessageNames
        isolatedMessageNames = configuration.isolatedScriptMessageNames
        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        self.delegate = delegate

        super.init()
        TabLifecycleActivityProbe.install(on: contentController)
        lifecycleCheckpoint.install(on: webView)

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
            self?.onLifecycleNavigation?()
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
            let ready: () -> Void = { [weak self] in
                self?.isReadyForNavigation = true
                self?.flushPendingNavigationIfNeeded()
            }
            if let navigationReadinessGate {
                navigationReadinessGate(ready)
            } else {
                ready()
            }
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

    func load(_ request: URLRequest) {
        cancelAuthentication()
        supersedeLifecycleRestoration()
        onLifecycleNavigation?()
        guard isReadyForNavigation else {
            pendingLoadRequest = request
            pendingReload = false
            return
        }

        webView.load(request)
    }

    func reload() {
        cancelAuthentication()
        supersedeLifecycleRestoration()
        onLifecycleNavigation?()
        guard isReadyForNavigation else {
            pendingReload = true
            pendingLoadRequest = nil
            return
        }

        webView.reload()
    }

    func goBack() {
        cancelAuthentication()
        supersedeLifecycleRestoration()
        onLifecycleNavigation?()
        webView.goBack()
    }

    func goForward() {
        cancelAuthentication()
        supersedeLifecycleRestoration()
        onLifecycleNavigation?()
        webView.goForward()
    }

    func stopLoading() {
        cancelAuthentication()
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
        // Compare against the tracker's surviving document URL, not
        // `lastCommittedURL`: after an SPA pushState/replaceState the
        // committed URL is stale (/login) while the surviving document
        // legitimately sits on the tracked route (/other). Generation
        // was already bumped at provisional start, so old fills stay
        // invalid; only the fresh document context is re-registered.
        guard passwordTracker.canRehandshake(committedURL: passwordTracker.currentDocumentURL, currentURL: webView.url)
        else {
            return
        }
        evaluatePasswordJavaScript(
            "window.__oraPasswordManager && window.__oraPasswordManager.reannounce && window.__oraPasswordManager.reannounce();"
        )
    }

    func teardown() {
        cancelAuthentication()
        downloadActivity.clear()
        supersedeLifecycleRestoration()
        onLifecycleNavigation = nil
        pendingLoadRequest = nil
        pendingReload = false
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
        lifecycleCheckpoint.teardown()
        webView.removeFromSuperview()
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
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
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
        cancelAuthentication()
        // Any new navigation — including same-URL reload — retires the
        // previous document for password purposes immediately, while the
        // navigation is still in progress.
        passwordTracker.invalidate()
        onLifecycleNavigation?()
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
            lifecycleCheckpoint.didCommit()
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
            lifecycleRestoreInFlight = false
            lifecycleCheckpoint.didFinish()
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

    @available(macOS 11.3, *)
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if navigationResponse.canShowMIMEType, !disposition.hasPrefix("attachment") {
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

/// Lifecycle state assignment shares the page readiness gate.
extension BrowserPage {
    private func supersedeLifecycleRestoration() {
        lifecycleRestoreInFlight = false
        lifecycleRestoration.supersede()
        lifecycleCheckpoint.supersede()
    }

    private func flushPendingNavigationIfNeeded() {
        guard isReadyForNavigation else { return }
        if lifecycleRestoration.applyIfReady(true, assignAndVerify: { data in
            guard let nativeState = lifecycleCheckpoint.prepareRestore(data) else { return false }
            lifecycleRestoreInFlight = true
            webView.interactionState = nativeState
            // Decode updates the back/forward list synchronously. A URL alone
            // can belong to an unrelated navigation and is not restore proof.
            let assigned = webView.backForwardList.currentItem != nil
            lifecycleRestoreInFlight = assigned
            return assigned
        }) {
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

    /// Capture the live interaction state (history/scroll) for lifecycle
    /// checkpoint/discard. Must run before any teardown.
    var hasPendingLifecycleRestore: Bool {
        lifecycleRestoration.hasPendingRestore || lifecycleRestoreInFlight
    }

    var lifecycleFallbackURL: URL? {
        pendingLoadRequest?.url ?? webView.url
    }

    var isLifecycleCaptureReady: Bool {
        isReadyForNavigation && !hasPendingLifecycleRestore && pendingLoadRequest == nil
            && !pendingReload && !webView.isLoading && webView.backForwardList.currentItem != nil
    }

    func captureInteractionState() -> Data? {
        guard isLifecycleCaptureReady else { return nil }
        guard let data = webView.interactionState as? Data else { return nil }
        return lifecycleCheckpoint.capture(data, url: webView.url)
    }

    /// Completion is delivered only after actual assignment/verification, or
    /// after a newer navigation supersedes the queued request.
    func restoreInteractionState(
        _ data: Data,
        completion: @escaping (TabLifecycleRestoreOutcome) -> Void
    ) {
        pendingLoadRequest = nil
        pendingReload = false
        lifecycleRestoration.enqueue(data, completion: completion)
        flushPendingNavigationIfNeeded()
    }
}
