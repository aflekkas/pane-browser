import AppKit
import SwiftData
import SwiftUI

enum TabType: String, Codable {
    case pinned
    case fav
    case normal
}

struct URLUpdate: Codable {
    let href: String
    let title: String
    let favicon: String?
}

// MARK: - Tab

@Model
class Tab: ObservableObject, Identifiable {
    var id: UUID
    var url: URL
    var urlString: String
    var savedURL: URL?
    var title: String
    var favicon: URL? // Add favicon property
    var createdAt: Date
    var lastAccessedAt: Date?

    var type: TabType
    var order: Int
    var faviconLocalFile: URL?
    var backgroundColorHex: String = "#000000"
    /// True when the web view was unloaded by the lifecycle sweep and the
    /// tab's state lives in a `TabSessionSnapshot` (or, for private tabs,
    /// in memory only). Lightweight-migration default keeps old stores valid.
    var isDiscarded: Bool = false

    //    @Transient @Published var backgroundColor: Color = Color(.black)
    @Transient var isPlayingMedia: Bool = false
    @Transient var isLoading: Bool = false
    @Transient @Published var backgroundColor: Color = .black
    @Transient var historyManager: HistoryManager?
    @Transient var downloadManager: DownloadManager?
    @Transient var tabManager: TabManager?
    @Transient var browserPage: BrowserPage?
    @Transient var pageDelegate: TabBrowserPageDelegate?
    @Transient @Published var isWebViewReady: Bool = false
    @Transient @Published var loadingProgress: Double = 10.0
    @Transient var colorUpdated = false
    @Transient var maybeIsActive = false
    @Transient @Published var hasNavigationError: Bool = false
    @Transient @Published var navigationError: Error?
    @Transient @Published var failedURL: URL?
    @Transient @Published var hoveredLinkURL: String?
    @Transient var isPrivate: Bool = false
    @Transient var passwordCoordinator: PasswordAutofillCoordinator?
    @Transient @Published var passwordOverlayState: PasswordAutofillOverlayState?
    @Transient @Published var passwordTriggerOverlayState: PasswordAutofillOverlayState?
    /// Lifecycle guards (Pane spec §4). Set from the activity probe and
    /// the media bridge; `userPinnedExplicitly` is set only by an explicit
    /// pin action, never inferred from `type` alone.
    @Transient var hasActiveMediaSession: Bool = false
    @Transient var hasUnsavedFormState: Bool = false
    @Transient var userPinnedExplicitly: Bool = false
    @Transient var lastLifecycleActivity: TabLifecycleActivity?
    /// Private tabs keep interaction state here only — never on disk.
    @Transient var privateInteractionState: Data?

    @Relationship(inverse: \TabContainer.tabs) var container: TabContainer

    /// Whether this tab is considered alive (recently accessed)
    var isAlive: Bool {
        guard let lastAccessed = lastAccessedAt else { return false }
        let timeout = SettingsStore.shared.tabAliveTimeout
        return Date().timeIntervalSince(lastAccessed) < timeout
    }

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        favicon: URL? = nil,
        container: TabContainer,
        type: TabType = .normal,
        isPlayingMedia: Bool = false,
        order: Int,
        historyManager: HistoryManager? = nil,
        downloadManager: DownloadManager? = nil,
        tabManager: TabManager,
        isPrivate: Bool
    ) {
        let nowDate = Date()
        self.id = id
        self.url = url
        self.urlString = url.absoluteString

        self.title = title
        self.favicon = favicon
        self.createdAt = nowDate
        self.lastAccessedAt = nowDate
        self.type = type
        self.isPlayingMedia = isPlayingMedia
        self.container = container
        self.order = order
        self.historyManager = historyManager
        self.downloadManager = downloadManager
        self.tabManager = tabManager
        self.isPrivate = isPrivate
        self.passwordCoordinator = PasswordAutofillCoordinator(tab: self)
        self.isWebViewReady = false
    }

    func syncBackgroundColorFromHex() {
        backgroundColor = Color(hex: backgroundColorHex)
    }

    /// Call this whenever the color is set
    func updateBackgroundColor(_ color: Color) {
        backgroundColor = color
        backgroundColorHex = color.toHex() ?? "#000000"
    }

    func setFavicon() {
        guard let host = self.url.host else { return }

        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard let faviconURL = FaviconService.shared.faviconURL(for: domain) else { return }
        self.favicon = faviconURL

        let fileName = "\(self.id.uuidString).png"
        let saveURL = FileManager.default.faviconDirectory.appendingPathComponent(fileName)

        FaviconService.shared
            .downloadAndSaveFavicon(for: domain, faviconURL: faviconURL, to: saveURL) {
                [weak self] sourceURL, success in
                guard let self else { return }
                if success {
                    Task { @MainActor in
                        self.faviconLocalFile = saveURL
                        if let sourceURL {
                            self.favicon = sourceURL
                        }
                    }
                }
            }
    }

    func switchSections(from: Tab, to: Tab) {
        from.type = to.type
        switch to.type {
        case .pinned, .fav:
            from.savedURL = from.url
        case .normal:
            from.savedURL = nil
        }
    }

    func updateHeaderColor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if let page = self?.browserPage {
                self?.pageDelegate?.takeSnapshotAfterLoad(page)
            }
        }
    }

    func updateHistory() {
        if let historyManager = self.historyManager {
            Task { @MainActor in
                historyManager.record(
                    title: self.title,
                    url: self.url,
                    faviconURL: self.favicon,
                    faviconLocalFile: self.faviconLocalFile,
                    container: self.container
                )
            }
        }
    }

    func maintainSnapShots() {
        if !self.colorUpdated || self.browserPage?.isLoading == true, self.maybeIsActive {
            self.updateHeaderColor()

            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                guard let tab = self else { return }
                tab.maintainSnapShots()
            }
        }
    }

    func setupBrowserPageDelegate(for page: BrowserPage) {
        let delegate = TabBrowserPageDelegate()
        delegate.tab = self
        delegate.mediaController = tabManager?.mediaController
        delegate.passwordCoordinator = passwordCoordinator
        page.delegate = delegate
        pageDelegate = delegate
    }

    func goForward() {
        lastAccessedAt = Date()
        browserPage?.goForward()
        updateHeaderColor()
    }

    func goBack() {
        lastAccessedAt = Date()
        browserPage?.goBack()
        updateHeaderColor()
    }

    func restoreTransientState(
        historyManager: HistoryManager,
        downloadManager: DownloadManager,
        tabManager: TabManager,
        isPrivate: Bool
    ) {
        // Avoid double initialization
        if browserPage != nil {
            return
        }

        if passwordCoordinator == nil {
            passwordCoordinator = PasswordAutofillCoordinator(tab: self)
        }

        let engine = BrowserEngine.shared
        let profile = engine.makeProfile(identifier: container.id, isPrivate: isPrivate)
        let privacySettings = SettingsStore.shared.privacySettings(for: container.id)
        let userScripts = OraBrowserScripts.userScripts() + BrowserPrivacyService.privacyScripts(for: privacySettings)
        let page = engine.makePage(
            profile: profile,
            configuration: BrowserPageConfiguration.oraDefault(
                userScripts: userScripts,
                privacySettings: privacySettings
            ),
            delegate: nil
        )
        browserPage = page

        self.historyManager = historyManager
        self.downloadManager = downloadManager
        self.tabManager = tabManager
        self.isWebViewReady = false
        self.setupBrowserPageDelegate(for: page)
        self.syncBackgroundColorFromHex()
        self.isDiscarded = false
        // Try interaction-state restore before the view enters the
        // hierarchy (Pane spec §4). Assigning performs a real navigation,
        // so a blob that never produces one falls back to a URL load.
        if let state = interactionStateForRestore() {
            let assigned = page.restoreInteractionState(state)
            self.isWebViewReady = true
            if !assigned {
                verifyInteractionStateRestore(page: page, attemptsRemaining: 20)
            }
            return
        }
        // Load after a short delay to ensure layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            let url = if self.type != .normal {
                self.savedURL
            } else {
                self.url
            }
            page.load(URLRequest(url: url ?? self.url))
            self.isWebViewReady = true
        }
    }

    /// Polls briefly for the restored navigation to appear; if none does,
    /// the blob was undecodable and the tab falls back to its URL. This is
    /// verification of an assignment already made, not a timed restore.
    private func verifyInteractionStateRestore(page: BrowserPage, attemptsRemaining: Int) {
        if TabLifecycleInteractionState.hasRestoredNavigation(on: page) {
            return
        }
        guard attemptsRemaining > 0, browserPage === page else {
            if browserPage === page {
                deletePersistedInteractionState()
                let url = type != .normal ? (savedURL ?? url) : url
                page.load(URLRequest(url: url))
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.verifyInteractionStateRestore(page: page, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func interactionStateForRestore() -> Data? {
        // Pinned/fav tabs keep Ora's restore-to-`savedURL` semantics (the
        // Pane essential `homeURL` rule); blobs only restore normal tabs.
        guard type == .normal else { return nil }
        if isPrivate {
            return TabInteractionStateCodec.validated(privateInteractionState)
        }
        guard let context = modelContext else { return nil }
        return TabLifecycleSnapshotStore.restoreData(tabID: id, containerID: container.id, in: context)
    }

    func deletePersistedInteractionState() {
        privateInteractionState = nil
        guard !isPrivate, let context = modelContext else { return }
        TabLifecycleSnapshotStore.delete(tabID: id, in: context)
    }

    // MARK: - Lifecycle (Pane spec §4)

    var lifecycleKind: TabLifecycleKind {
        switch type {
        case .normal:
            .ephemeral
        case .pinned:
            .pinned
        case .fav:
            .essential
        }
    }

    func lifecycleFacts(isActive: Bool) -> TabLifecycleFacts {
        TabLifecycleFacts(
            id: id,
            kind: lifecycleKind,
            state: isDiscarded ? .discarded : .live,
            hasLivePage: browserPage != nil,
            lastAccessedAt: lastAccessedAt,
            isActive: isActive,
            isPlayingAudio: isPlayingMedia,
            hasActiveMediaSession: hasActiveMediaSession || (lastLifecycleActivity?.hasActiveMediaSession ?? false),
            hasUnsavedFormState: hasUnsavedFormState || (lastLifecycleActivity?.hasUnsavedFormState ?? false),
            userPinnedExplicitly: userPinnedExplicitly,
            isLoading: isLoading
        )
    }

    /// Captures the live page's interaction state. Must run before any
    /// teardown: reading after detach can capture stale scroll state.
    /// Non-private tabs persist via `TabSessionSnapshot`; private tabs
    /// keep the blob in memory only.
    @discardableResult
    func captureInteractionState() -> Bool {
        guard let page = browserPage, let data = page.captureInteractionState() else {
            return false
        }
        if isPrivate {
            privateInteractionState = data
            return true
        }
        guard let context = modelContext else { return false }
        let saved = TabLifecycleSnapshotStore.save(
            tabID: id,
            containerID: container.id,
            data: data,
            isPrivate: false,
            in: context
        )
        if saved {
            try? context.save()
        }
        return saved
    }

    /// Pane discard: capture first, then deallocate the web view — the
    /// only step that reclaims memory.
    func discard() {
        guard browserPage != nil else {
            isDiscarded = true
            return
        }
        captureInteractionState()
        destroyWebView()
        isDiscarded = true
        if !isPrivate {
            try? modelContext?.save()
        }
    }

    /// Probes the live page, refreshes the guard flags, and discards only
    /// if the policy still allows it with the probed facts. Probe errors
    /// and timeouts fail closed.
    func discardIfAllowed(policy: TabLifecyclePolicy, isActive: Bool, at now: Date = Date()) {
        guard let page = browserPage else { return }
        let probedGeneration = page.passwordNavigationGeneration
        TabLifecycleActivityProbe.probe(page: page) { [weak self] activity in
            // Recheck after the async probe: same page, same document
            // generation, and policy re-staged on current facts. A
            // navigation during the probe invalidates its result.
            guard let self, browserPage === page,
                  page.passwordNavigationGeneration == probedGeneration
            else { return }
            lastLifecycleActivity = activity
            hasActiveMediaSession = activity.hasActiveMediaSession
            hasUnsavedFormState = activity.hasUnsavedFormState
            if activity.isPlayingMedia {
                isPlayingMedia = true
            }
            guard policy.stage(for: lifecycleFacts(isActive: isActive), at: Date()) == .discard else { return }
            discard()
        }
    }

    func stopMedia(completed: @escaping () -> Void) {
        guard let page = browserPage else {
            completed()
            return
        }

        let js = """
        document.querySelectorAll('video, audio').forEach(el => {
            try {
                el.pause();
                el.src = '';
                el.load();
            } catch (e) {}
        });
        """
        page.evaluateJavaScript(js) { [weak self] _, _ in
            page.closeMediaPresentations {
                page.teardown()
                if self?.browserPage === page {
                    self?.browserPage = nil
                    self?.pageDelegate = nil
                }
                completed()
            }
        }
    }

    func loadURL(_ urlString: String) {
        lastAccessedAt = Date()
        let input = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Try to construct a direct URL (has scheme or valid domain+TLD/IP)
        if let directURL = constructURL(from: input) {
            browserPage?.load(URLRequest(url: directURL))
            return
        }

        // 2) Otherwise, treat as a search query using the selected search engine
        let searchEngineService = SearchEngineService()
        if let engine = searchEngineService.getDefaultSearchEngine(for: self.container.id),
           let searchURL = searchEngineService.createSearchURL(for: engine, query: input)
        {
            browserPage?.load(URLRequest(url: searchURL))
            return
        }

        // 3) Fallback to Google if for some reason engine lookup fails
        if let fallbackURL = URL(string: "https://www.google.com/search?client=safari&rls=en&ie=UTF-8&oe=UTF-8&q="
            + (input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        ) {
            browserPage?.load(URLRequest(url: fallbackURL))
        }
    }

    func destroyWebView() {
        browserPage?.teardown()
        browserPage = nil
        pageDelegate = nil
        isWebViewReady = false
    }

    func setNavigationError(_ error: Error, for url: URL?) {
        DispatchQueue.main.async {
            self.hasNavigationError = true
            self.navigationError = error
            self.failedURL = url
        }
    }

    func clearNavigationError() {
        DispatchQueue.main.async {
            self.hasNavigationError = false
            self.navigationError = nil
            self.failedURL = nil
        }
    }

    func retryNavigation() {
        // Don't clear error state immediately - let onStart callback handle it
        // This prevents showing white background before navigation begins
        if let url = failedURL {
            let request = URLRequest(url: url)
            browserPage?.load(request)
        }
    }

    func continueToInsecureSite() {
        // No host bypass exists anymore: reloading re-fires the auth
        // challenge, which routes through BrowserAuthHandler and asks for
        // an exact, session-scoped certificate decision.
        let url = failedURL ?? self.url
        clearNavigationError()
        browserPage?.load(URLRequest(url: url))
    }

    /// Certificate interstitial state, presented natively (never from web
    /// content) when BrowserAuthHandler needs a user decision.
    @Transient @Published var certificateChallenge: CertificateExceptions.Evaluation?
    @Transient var certificateDecision: ((Bool) -> Void)?

    func presentCertificateChallenge(
        _ evaluation: CertificateExceptions.Evaluation,
        decide: @escaping (Bool) -> Void
    ) {
        if let old = certificateChallenge {
            resolveCertificateChallenge(id: old.id, allowed: false)
        }
        certificateChallenge = evaluation
        certificateDecision = decide
    }

    func resolveCertificateChallenge(id: UUID, allowed: Bool) {
        guard certificateChallenge?.id == id else { return }
        let decide = certificateDecision
        certificateChallenge = nil
        certificateDecision = nil
        decide?(allowed)
    }

    var canGoBack: Bool {
        browserPage?.canGoBack ?? false
    }

    var canGoForward: Bool {
        browserPage?.canGoForward ?? false
    }

    var currentPageURL: URL? {
        browserPage?.currentURL
    }

    var pageWindow: NSWindow? {
        browserPage?.window
    }

    func reload() {
        browserPage?.reload()
    }

    func refreshBrowserPageForPrivacySettings() {
        guard isWebViewReady,
              let historyManager,
              let downloadManager,
              let tabManager
        else {
            return
        }

        destroyWebView()
        restoreTransientState(
            historyManager: historyManager,
            downloadManager: downloadManager,
            tabManager: tabManager,
            isPrivate: isPrivate
        )
    }

    func evaluateJavaScript(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        browserPage?.evaluateJavaScript(script, completion: completion)
    }

    /// Password-bridge evaluation only; runs in the isolated content world.
    func evaluatePasswordJavaScript(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        browserPage?.evaluatePasswordJavaScript(script, completion: completion)
    }

    func takeSnapshot(
        configuration: BrowserSnapshotConfiguration,
        completion: @escaping (NSImage?, Error?) -> Void
    ) {
        browserPage?.takeSnapshot(configuration: configuration, completion: completion)
    }
}

extension FileManager {
    var faviconDirectory: URL {
        let dir = urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Favicons")
        if !fileExists(atPath: dir.path) {
            try? createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        // swiftlint:disable:next identifier_name
        let r, g, b, a: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
            a = 1.0
        case 8:
            r = Double((int >> 24) & 0xFF) / 255
            g = Double((int >> 16) & 0xFF) / 255
            b = Double((int >> 8) & 0xFF) / 255
            a = Double(int & 0xFF) / 255
        default:
            return nil
        }

        self.init(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    func toHex() -> String? {
        guard let color = usingColorSpace(.deviceRGB) else { return nil }
        // swiftlint:disable:next identifier_name
        let r = Int(color.redComponent * 255)
        // swiftlint:disable:next identifier_name
        let g = Int(color.greenComponent * 255)
        // swiftlint:disable:next identifier_name
        let b = Int(color.blueComponent * 255)
        // swiftlint:disable:next identifier_name
        let a = Int(color.alphaComponent * 255)

        return a < 255
            ? String(format: "#%02X%02X%02X%02X", r, g, b, a)
            : String(format: "#%02X%02X%02X", r, g, b)
    }
}
