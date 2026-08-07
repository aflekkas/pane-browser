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
    // spec §3 — per-space state. Each space has its own tabs, its own engines
    // and, crucially, its own WKWebsiteDataStore, so two spaces can be logged
    // into the same site as different users simultaneously.
    private var spaceModel = SpaceModel()
    private var tabsBySpace: [String: TabModel] = [:]
    private var enginesBySpace: [String: [TabID: WKWebEngine]] = [:]
    private var statesBySpace: [String: [TabID: Data]] = [:]
    private var storesBySpace: [String: WKWebsiteDataStore] = [:]

    private var spaceID: String { spaceModel.current ?? "default" }

    private var model: TabModel {
        get { tabsBySpace[spaceID] ?? TabModel() }
        set { tabsBySpace[spaceID] = newValue }
    }
    private var engines: [TabID: WKWebEngine] {
        get { enginesBySpace[spaceID] ?? [:] }
        set { enginesBySpace[spaceID] = newValue }
    }
    private var states: [TabID: Data] {
        get { statesBySpace[spaceID] ?? [:] }
        set { statesBySpace[spaceID] = newValue }
    }

    /// spec §3 — lazy profile activation. The data store is instantiated on
    /// first use, never for every space at launch.
    private func store(forSpace id: String) -> WKWebsiteDataStore {
        if let s = storesBySpace[id] { return s }
        guard let space = spaceModel.spaces.first(where: { $0.id == id }),
              let profile = spaceModel.profile(for: space) else {
            return .default()
        }
        let s = WKWebEngine.store(forProfile: profile.dataStoreUUID)
        storesBySpace[id] = s
        return s
    }

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

        bootstrapSpaces()
        if restoreSession {
            restore(fallback: startURL)
        } else {
            let home = startURL ?? URLNormalizer.homeURL
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
            let id = model.open(Tab(kind: kind, url: URLNormalizer.homeURL, lastActiveAt: Date()))
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
            sidebarWidth.constant = sidebarWidth.constant > 0 ? 0 : 232

        case .selectSpace(let id):
            guard id != spaceModel.current else { return }
            spaceModel.select(id)
            if model.tabs.isEmpty {
                let home = URLNormalizer.homeURL
                let newID = model.open(Tab(kind: .ephemeral, url: home, lastActiveAt: Date()))
                _ = engine(for: newID)
            }
            showSelected()
            sidebar.spaces = spaceModel

        case .newSpace(let name):
            let s = spaceModel.addSpace(named: name)
            tabsBySpace[s.id] = TabModel()
            spaceModel.select(s.id)
            let home = URLNormalizer.homeURL
            let newID = model.open(Tab(kind: .ephemeral, url: home, lastActiveAt: Date()))
            _ = engine(for: newID)
            showSelected()
            sidebar.spaces = spaceModel
            persistSpaces()

        case .renameSpace(let id, let name):
            spaceModel.rename(id, to: name)
            sidebar.spaces = spaceModel
            persistSpaces()

        case .setSpaceIcon(let id, let symbol):
            spaceModel.setIcon(id, to: symbol)
            sidebar.spaces = spaceModel
            persistSpaces()

        case .deleteSpace(let id):
            guard spaceModel.spaces.count > 1 else { return }
            spaceModel.removeSpace(id)
            tabsBySpace[id] = nil
            enginesBySpace[id] = nil
            statesBySpace[id] = nil
            // §3: release the reference. remove(forIdentifier:) DELETES the
            // user's data and must never be used for teardown.
            storesBySpace[id] = nil
            sidebar.spaces = spaceModel
            showSelected()
            persistSpaces()

        case .sweepDiscardable:
            for id in model.discardCandidates(at: Date()) { discard(id) }

        case .sweepDiscardableForced:
            for id in model.discardCandidates(at: Date(), force: true) { discard(id) }
        }
        sidebar.model = model
        syncChrome()
        scheduleSave()
    }

    /// spec §3 — spaces are loaded from the store, or a single default space is
    /// created on first run. A space always has a profile; a profile always has
    /// a stable data-store UUID.
    private func bootstrapSpaces() {
        if let store {
            let sem = DispatchSemaphore(value: 0)
            Task {
                if let loaded = try? await store.loadSpaces(), !loaded.spaces.isEmpty {
                    await MainActor.run {
                        self.spaceModel.load(spaces: loaded.spaces, profiles: loaded.profiles)
                    }
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 2)
        }
        if spaceModel.spaces.isEmpty {
            spaceModel.addSpace(named: "Personal")
        }
        for s in spaceModel.spaces where tabsBySpace[s.id] == nil {
            tabsBySpace[s.id] = TabModel()
        }
        sidebar.spaces = spaceModel
        sidebar.onSelectSpace = { [weak self] in self?.dispatch(.selectSpace($0)) }
        sidebar.onNewSpace = { [weak self] in self?.dispatch(.newSpace(name: $0)) }
        sidebar.onRenameSpace = { [weak self] id, name in self?.dispatch(.renameSpace(id, name)) }
        sidebar.onSetSpaceIcon = { [weak self] id, sym in self?.dispatch(.setSpaceIcon(id, sym)) }
        sidebar.onDeleteSpace = { [weak self] in self?.dispatch(.deleteSpace($0)) }
        sidebar.onNewTab = { [weak self] in self?.dispatch(.newTab(kind: .ephemeral)) }
        persistSpaces()
    }

    private func persistSpaces() {
        guard let store else { return }
        let spaces = spaceModel.spaces
        let profiles = Array(spaceModel.profiles.values)
        Task { try? await store.saveSpaces(spaces, profiles: profiles) }
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
        let sid = spaceID
        // Capture live tabs' state too, so a crash loses at most the last
        // interaction rather than the whole session.
        var live: [(TabID, Data)] = []
        for (id, e) in engines {
            if let blob = e.captureInteractionState() { live.append((id, blob)) }
        }
        let pending = states
        Task {
            try? await store.saveTabs(tabs, spaceID: sid)
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
            let home = fallback ?? URLNormalizer.homeURL
            dispatch(.newTab(kind: .ephemeral))
            dispatch(.navigate(home.absoluteString))
            return
        }
        states = snaps
        for var t in loaded {
            t.lifecycle = .discarded          // materialise lazily
            model.open(t, select: false)
        }
        // Prefer a tab that has somewhere to go; restoring straight into a
        // blank tab makes it look like the session was lost.
        let landing = model.tabs.first(where: { $0.url != nil }) ?? model.tabs.first
        if let landing { model.select(landing.id, at: Date()) }
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
        let e = WKWebEngine(dataStore: store(forSpace: spaceID))
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

        // Arc/Zen layout: nav controls and the address field live INSIDE the
        // sidebar, so the content area has no chrome above it at all. That is
        // the defining move — more than any spacing value (spec §5, and
        // docs/reference/arc-sidebar.md).
        let header = sidebar.header

        let navRow = NSStackView()
        navRow.translatesAutoresizingMaskIntoConstraints = false
        navRow.orientation = .horizontal
        navRow.spacing = 2
        for (btn, glyph, sel) in [
            (backButton, "chevron.left", #selector(mBack)),
            (forwardButton, "chevron.right", #selector(mForward)),
            (reloadButton, "arrow.clockwise", #selector(mReload)),
        ] {
            btn.image = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)
            btn.isBordered = false
            btn.contentTintColor = .secondaryLabelColor
            btn.target = self; btn.action = sel
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 26).isActive = true
            navRow.addArrangedSubview(btn)
        }
        backButton.isEnabled = false; forwardButton.isEnabled = false

        addressBar.translatesAutoresizingMaskIntoConstraints = false
        addressBar.placeholderString = "Search or Enter URL…"
        addressBar.delegate = self
        addressBar.target = self
        addressBar.action = #selector(commitAddress)
        addressBar.isBezeled = false
        addressBar.drawsBackground = true
        addressBar.backgroundColor = .quaternaryLabelColor.withAlphaComponent(0.16)
        addressBar.focusRingType = .none
        addressBar.font = .systemFont(ofSize: 12)
        addressBar.wantsLayer = true
        addressBar.layer?.cornerRadius = 8
        addressBar.cell?.usesSingleLineMode = true

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1; progress.isHidden = true

        header.addSubview(navRow)
        header.addSubview(addressBar)
        header.addSubview(progress)

        let side = sidebar.view
        side.translatesAutoresizingMaskIntoConstraints = false
        contentBox.translatesAutoresizingMaskIntoConstraints = false
        contentBox.wantsLayer = true
        contentBox.layer?.cornerRadius = 8
        contentBox.layer?.masksToBounds = true

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(side); content.addSubview(divider); content.addSubview(contentBox)

        sidebarWidth = side.widthAnchor.constraint(equalToConstant: 232)
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: content.topAnchor),
            side.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            side.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarWidth,

            // Traffic lights sit over the sidebar; leave them room.
            navRow.topAnchor.constraint(equalTo: header.topAnchor, constant: 22),
            navRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            navRow.heightAnchor.constraint(equalToConstant: 22),

            addressBar.topAnchor.constraint(equalTo: navRow.bottomAnchor, constant: 6),
            addressBar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            addressBar.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            addressBar.heightAnchor.constraint(equalToConstant: 26),

            progress.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            progress.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            progress.topAnchor.constraint(equalTo: addressBar.bottomAnchor, constant: 2),
            progress.heightAnchor.constraint(equalToConstant: 2),

            divider.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            // Content fills everything right of the divider. No toolbar.
            contentBox.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            contentBox.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 8),
            contentBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            contentBox.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
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
    public func forceSweepForBench() { dispatch(.sweepDiscardableForced) }
    public var liveEngineCount: Int { engines.count }
    public var tabCount: Int { model.tabs.count }
}
