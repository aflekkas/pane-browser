import AppKit
@testable import Ora
import SwiftData
import Testing
import WebKit

@MainActor
final class DownloadFlowHarness {
    let window: NSWindow
    let page: BrowserPage
    let tab: Tab
    let delegate = TabBrowserPageDelegate()
    let manager: DownloadManager
    let directory: URL

    init(profile: BrowserEngineProfile? = nil, manager sharedManager: DownloadManager? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadFlow-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try ModelConfiguration.createOraContainer(isPrivate: true)
        let context = ModelContext(store)
        manager = sharedManager ?? DownloadManager(modelContainer: store, modelContext: context)
        if sharedManager == nil {
            manager.downloadsDirectory = directory
        }
        let tabs = TabManager(modelContainer: store, modelContext: context, mediaController: MediaController())
        let container = try #require(tabs.activeContainer)
        tab = Tab(
            url: URL(string: "about:blank")!,
            title: "Fixture",
            container: container,
            order: 0,
            downloadManager: manager,
            tabManager: tabs,
            isPrivate: true
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        page = BrowserEngine().makePage(
            profile: profile ?? BrowserEngineProfile(identifier: UUID(), isPrivate: true),
            configuration: .oraDefault(userScripts: [], privacySettings: SpacePrivacySettings()), delegate: delegate
        )
        tab.browserPage = page
        tab.isWebViewReady = true
        delegate.tab = tab
        page.contentView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView?.addSubview(page.contentView)
    }

    func close() {
        for download in manager.activeDownloads {
            manager.cancelDownload(download)
        }
        page.teardown()
        window.close()
        tab.tabManager?.closeLifecycleFixture()
        tab.tabManager = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func load(_ url: URL) async throws {
        page.load(URLRequest(url: url))
        try await wait("load \(url)") { self.page.lastCommittedURL == url && !self.page.isLoading }
    }

    func click(_ id: String) async throws {
        _ = try await page.webView.evaluateJavaScript("document.getElementById('\(id)').click(); true")
    }

    func wait(_ label: String, _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FlowError.timeout(label)
    }

    enum FlowError: Error { case timeout(String) }
}
