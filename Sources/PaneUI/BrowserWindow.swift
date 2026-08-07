// spec: §1
import AppKit
import WebKit
import PaneCore
import PaneWeb

/// Milestone B: sidebar + tabs + content. One `WKWebEngine` per live tab; a
/// discarded tab has no engine at all, which is the only way memory is actually
/// reclaimed (spec §4, ADR 0001).
@MainActor
public final class BrowserWindowController: NSWindowController, NSTextFieldDelegate {
    private var model = TabModel()
    private var engines: [TabID: WKWebEngine] = [:]
    private var states: [TabID: Data] = [:]          // interactionState for discarded tabs

    private let sidebar = SidebarController()
    private let contentBox = NSView()
    private let addressBar = NSTextField()
    private let progress = NSProgressIndicator()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private var sidebarWidth: NSLayoutConstraint!
    private var sweepTimer: Timer?
    private var saveTimer: Timer?
    private let store: Store?
    /// Where the session lives. Under Application Support so it survives, and
    /// overridable so scenarios and the kill -9 gate can use a scratch file.
    public static func defaultStorePath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pane", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("pane.sqlite").path
    }

    private let storePathInUse: String

    public init(startURL: URL? = nil, storePath: String? = nil, restoreSession: Bool = true) {
        let p = storePath ?? BrowserWindowController.defaultStorePath()
        self.storePathInUse = p
        self.store = try? Store(path: p)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Pane"
        window.titlebarAppearsTransparent = true
        window.center()
        super.init(window: window)

        buildChrome()
        sidebar.onSelect   = { [weak self] in self?.dispatch(.selectTab($0)) }
        sidebar.onClose    = { [weak self] in self?.dispatch(.closeTab($0)) }
        sidebar.onReorder  = { [weak self] id, i, kind in self?.reorder(id, i, kind) }

        if restoreSession {
            restore(fallback: startURL)
        } else {
            let home = startURL ?? URLNormalizer.resolve("duckduckgo.com")!
            dispatch(.newTab(kind: .ephemeral))
            dispatch(.navigate(home.absoluteString))
        }

        // spec §4 — the idle sweep. One minute is fine; the thresholds are 5
        // and 15 minutes, so a coarse tick costs nothing and avoids waking the
        // CPU more often than the policy can act on.
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dispatch(.sweepDiscardable) }
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - The command bus
    //
    // The ONLY mutator of app state. Menus, key chords, sidebar clicks and test
    // scenarios all arrive here, so a scenario dispatching .closeTab exercises
    // exactly the code ⌘W exercises (ADR 0006).

    public func dispatch(_ c: Command) {
        switch c {
        case .navigate(let raw):
            guard let url = URLNormalizer.resolve(raw), let id = model.selected else { return }
            model.update(id) { $0.url = url }
            engine(for: id)?.load(url)

        case .goBack:      currentEngine?.goBack()
        case .goForward:   currentEngine?.goForward()
        case .reload:      currentEngine?.reload()
        case .stopLoading: currentEngine?.stopLoading()

        case .focusAddressBar:
            window?.makeFirstResponder(addressBar)
            addressBar.currentEditor()?.selectAll(nil)

        case .newTab(let kind):
            let id = model.open(Tab(kind: kind, lastActiveAt: Date()))
            _ = engine(for: id)
            showSelected()
            dispatch(.focusAddressBar)

        case .closeTab(let maybe):
            guard let id = maybe ?? model.selected else { return }
            teardown(id)
            model.close(id)
            showSelected()

        case .selectTab(let id):
            model.select(id, at: Date())
            showSelected()

        case .reopenClosedTab:
            if model.reopenLastClosed() != nil { showSelected() }

        case .toggleSidebar:
            sidebarWidth.constant = sidebarWidth.constant > 0 ? 0 : 240

        case .sweepDiscardable:
            for id in model.discardCandidates(at: Date()) { discard(id) }
        }
        sidebar.model = model
        syncChrome()
        scheduleSave()
    }

    // MARK: - Persistence (spec §2, §4)

    /// Continuous writes, debounced 500ms per spec §6. Every tab mutation lands
    /// eventually; none of them block the UI.
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    public func saveNow() {
        guard let store else { return }
        let tabs = model.tabs
        // Capture live tabs' state too, so a crash loses at most the last
        // interaction rather than the whole session.
        var live: [(TabID, Data)] = []
        for (id, e) in engines {
            if let blob = e.captureInteractionState() { live.append((id, blob)) }
        }
        let pending = states
        Task {
            try? await store.saveTabs(tabs, spaceID: nil)
            for (id, blob) in pending { try? await store.saveSnapshot(id, state: blob) }
            for (id, blob) in live { try? await store.saveSnapshot(id, state: blob) }
        }
    }

    /// spec §6 — restore the sidebar instantly from SQLite and lazily
    /// materialise only the active tab. A restored tab starts `discarded`, so
    /// twenty restored tabs cost twenty rows, not twenty renderers.
    private func restore(fallback: URL?) {
        guard store != nil else { return }
        let (loaded, snaps) = Store.loadSessionSync(path: storePathInUse)

        guard !loaded.isEmpty else {
            let home = fallback ?? URLNormalizer.resolve("duckduckgo.com")!
            dispatch(.newTab(kind: .ephemeral))
            dispatch(.navigate(home.absoluteString))
            return
        }
        states = snaps
        for var t in loaded {
            t.lifecycle = .discarded          // materialise lazily
            model.open(t, select: false)
        }
        if let first = model.tabs.first { model.select(first.id, at: Date()) }
        sidebar.model = model
        showSelected()
        syncChrome()
    }

    // MARK: - Engines and lifecycle (spec §4)

    private var currentEngine: WKWebEngine? { model.selected.flatMap { engines[$0] } }

    /// Creates the engine on demand. A discarded tab has none until it is
    /// selected again — that absence IS the memory saving.
    @discardableResult
    private func engine(for id: TabID) -> WKWebEngine? {
        if let e = engines[id] { return e }
        guard let tab = model[id] else { return nil }
        let e = WKWebEngine()
        e.onEvent = { [weak self] ev in self?.handle(ev, from: id) }
        engines[id] = e
        // spec §4: assign interactionState BEFORE the view enters the hierarchy.
        if let blob = states[id] {
            e.restoreInteractionState(blob)
            states[id] = nil
        } else if let url = tab.restoreURL {
            e.load(url)
        }
        model.markLive(id, at: Date())
        return e
    }

    /// spec §4 — capture state, then release the WKWebView entirely. Releasing
    /// it is the only step that reclaims memory; everything else is bookkeeping.
    private func discard(_ id: TabID) {
        guard let e = engines[id] else { return }
        if let blob = e.captureInteractionState() {
            states[id] = blob
            if let store { Task { try? await store.saveSnapshot(id, state: blob) } }
        }
        e.webView.removeFromSuperview()
        engines[id] = nil
        model.markDiscarded(id)
    }

    private func teardown(_ id: TabID) {
        engines[id]?.webView.removeFromSuperview()
        engines[id] = nil
        states[id] = nil
    }

    private func reorder(_ id: TabID, _ index: Int, _ kind: TabKind) {
        model.move(id, toIndex: index, in: kind)
        sidebar.model = model
    }

    private func showSelected() {
        contentBox.subviews.forEach { $0.removeFromSuperview() }
        guard let id = model.selected, let e = engine(for: id) else { return }
        let web = e.webView
        web.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: contentBox.topAnchor),
            web.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
        ])
    }

    private func handle(_ e: WebEngineEvent, from id: TabID) {
        switch e {
        case .progressChanged(let p) where id == model.selected:
            progress.doubleValue = p
            progress.isHidden = p >= 1.0 || p <= 0.0
        case .titleChanged(let t):
            model.update(id) { $0.title = t }
            if id == model.selected { window?.title = (t?.isEmpty == false) ? t! : "Pane" }
            sidebar.model = model
        case .urlChanged(let u):
            model.update(id) { $0.url = u }
            if id == model.selected, window?.firstResponder !== addressBar.currentEditor(),
               let u { addressBar.stringValue = URLNormalizer.display(u) }
            sidebar.model = model
            syncChrome()
        case .didFinish, .didCommit:
            syncChrome()
        case .didFail(_, let message):
            progress.isHidden = true
            if id == model.selected { presentError(message) }
        case .contentProcessDidTerminate:
            // spec §6: never silently reload.
            if id == model.selected { presentError("This page stopped responding.") }
        default: break
        }
    }

    /// Re-derives ALL chrome from the selected tab's engine.
    ///
    /// This has to read from the engine rather than accumulate from events:
    /// events only ever arrive for the tab that fired them, so switching tabs
    /// left the title bar and address bar showing the *previous* tab's page —
    /// visible in the first sidebar screenshot as "DuckDuckGo" in the title
    /// while Hacker News was selected.
    private func syncChrome() {
        let e = currentEngine
        backButton.isEnabled = e?.canGoBack ?? false
        forwardButton.isEnabled = e?.canGoForward ?? false

        if window?.firstResponder !== addressBar.currentEditor() {
            if let u = e?.currentURL ?? model.selectedTab?.url {
                addressBar.stringValue = URLNormalizer.display(u)
            } else {
                addressBar.stringValue = ""
            }
        }
        let t = e?.title ?? model.selectedTab?.title
        window?.title = (t?.isEmpty == false) ? t! : "Pane"

        // Progress belongs to the selected tab only; a background tab finishing
        // must not leave a stalled bar over the foreground one.
        let p = e?.estimatedProgress ?? 1
        progress.doubleValue = p
        progress.isHidden = p >= 1.0 || p <= 0.0
    }

    private func presentError(_ message: String) {
        guard let window else { return }
        // spec §1: error UI is AppKit. A web-rendered error page inside a
        // compromised renderer is a real attack surface.
        let alert = NSAlert()
        alert.messageText = "Couldn’t load the page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: - Chrome

    private func buildChrome() {
        guard let window, let content = window.contentView else { return }

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        for (btn, glyph, sel) in [
            (backButton, "chevron.left", #selector(mBack)),
            (forwardButton, "chevron.right", #selector(mForward)),
            (reloadButton, "arrow.clockwise", #selector(mReload)),
        ] {
            btn.image = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)
            btn.bezelStyle = .texturedRounded
            btn.target = self; btn.action = sel
            btn.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(btn)
        }
        backButton.isEnabled = false; forwardButton.isEnabled = false

        addressBar.translatesAutoresizingMaskIntoConstraints = false
        addressBar.placeholderString = "Search or enter address"
        addressBar.delegate = self
        addressBar.target = self
        addressBar.action = #selector(commitAddress)
        addressBar.bezelStyle = .roundedBezel
        addressBar.focusRingType = .none
        bar.addSubview(addressBar)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1; progress.isHidden = true
        bar.addSubview(progress)

        let side = sidebar.view
        side.translatesAutoresizingMaskIntoConstraints = false
        contentBox.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(side); content.addSubview(divider)
        content.addSubview(bar); content.addSubview(contentBox)
        // `sidebar` is a stored property, so it is retained; NSWindowController
        // has no addChild. Space switching in milestone D will make this a
        // proper NSViewController containment hierarchy (spec §3).

        sidebarWidth = side.widthAnchor.constraint(equalToConstant: 240)
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            side.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            side.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarWidth,

            divider.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            bar.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),

            backButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            backButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 32),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            forwardButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 32),
            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 4),
            reloadButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 32),

            addressBar.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 8),
            addressBar.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            addressBar.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            progress.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),

            contentBox.topAnchor.constraint(equalTo: bar.bottomAnchor),
            contentBox.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentBox.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentBox.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    @objc private func mBack()    { dispatch(.goBack) }
    @objc private func mForward() { dispatch(.goForward) }
    @objc private func mReload()  { dispatch(.reload) }
    @objc public func focusAddress() { dispatch(.focusAddressBar) }
    @objc private func commitAddress() { dispatch(.navigate(addressBar.stringValue)) }

    // Exposed so the menu and scenarios drive the identical path.
    @objc public func newTab()      { dispatch(.newTab(kind: .ephemeral)) }
    @objc public func closeTab()    { dispatch(.closeTab(nil)) }
    @objc public func reopenTab()   { dispatch(.reopenClosedTab) }
    @objc public func toggleSide()  { dispatch(.toggleSidebar) }

    /// spec §4 — used by the benchmark to force a sweep deterministically.
    public func forceSweepForBench() { dispatch(.sweepDiscardable) }
    public var liveEngineCount: Int { engines.count }
    public var tabCount: Int { model.tabs.count }
}
