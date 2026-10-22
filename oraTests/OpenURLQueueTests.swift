import AppKit
import Foundation
@testable import Ora
import Testing

/// Drive the real AppDelegate entry point with deterministic AppKit focus/order.
/// No window is shown and no test changes the user's active application.
@MainActor
struct OpenURLQueueTests {
    @Test func focusChoosesNormalOrPrivateRecipientInsteadOfLastRegistration() throws {
        let fixture = URLDeliveryFixture()
        defer { fixture.close() }
        let normal = fixture.makeWindow()
        let privateWindow = fixture.makeWindow()
        var normalURLs: [URL] = []
        var privateURLs: [URL] = []
        fixture.registry.register(window: normal) { normalURLs.append($0) }
        fixture.registry.register(window: privateWindow) { privateURLs.append($0) }
        let urls = try makeURLs(3)

        fixture.candidates = [normal, privateWindow]
        fixture.app.handleIncomingURLs([urls[0]])
        fixture.candidates = [privateWindow, normal]
        fixture.app.handleIncomingURLs([urls[1]])
        fixture.candidates = [normal, privateWindow]
        fixture.app.handleIncomingURLs([urls[2]])

        #expect(normalURLs == [urls[0], urls[2]])
        #expect(privateURLs == [urls[1]])
        #expect(fixture.windowRequests == 0)
    }

    @Test func closingBLeavesAReadyAndStaleTokensCannotRemoveReplacement() throws {
        let fixture = URLDeliveryFixture()
        defer { fixture.close() }
        let windowA = fixture.makeWindow()
        let windowB = fixture.makeWindow()
        var delivered: [URL] = []
        let oldToken = fixture.registry.register(window: windowA) { _ in Issue.record("Replaced handler called") }
        fixture.registry.register(window: windowA) { delivered.append($0) }
        let tokenB = fixture.registry.register(window: windowB) { _ in Issue.record("Closed B called") }
        fixture.registry.unregister(token: oldToken)
        windowB.close()
        fixture.registry.unregister(token: tokenB)
        // Even stale focus/order information must not resurrect a closed recipient.
        fixture.candidates = [windowB, windowA]
        let urls = try makeURLs(1)
        fixture.app.handleIncomingURLs(urls)
        #expect(delivered == urls)
        #expect(fixture.registry.isReady)
        #expect(fixture.windowRequests == 0)
    }

    @Test func zeroWindowsRequestsOnceAndOnlyReadyRegistrationDrains() throws {
        let fixture = URLDeliveryFixture()
        defer { fixture.close() }
        let urls = try makeURLs(3)
        fixture.app.handleIncomingURLs(Array(urls.prefix(2)))
        fixture.app.handleIncomingURLs([urls[2]])
        #expect(fixture.windowRequests == 1)
        #expect(fixture.registry.pendingCount == 3)
        #expect(!fixture.registry.isReady)

        let browser = fixture.makeWindow()
        fixture.candidates = [browser]
        #expect(fixture.registry.pendingCount == 3) // Window existence is not readiness.
        var delivered: [URL] = []
        fixture.registry.register(window: browser) { delivered.append($0) }
        #expect(delivered == urls)
        #expect(fixture.registry.pendingCount == 0)
        fixture.registry.register(window: browser) { _ in Issue.record("Queue replayed") }
        #expect(fixture.windowRequests == 1)
    }

    @Test func unrelatedActiveWindowFallsBackToFrontmostReadyBrowser() throws {
        let fixture = URLDeliveryFixture()
        defer { fixture.close() }
        let settings = fixture.makeWindow()
        let windowA = fixture.makeWindow()
        let windowB = fixture.makeWindow()
        var delivered: [URL] = []
        fixture.registry.register(window: windowA) { delivered.append($0) }
        fixture.registry.register(window: windowB) { _ in Issue.record("Background B hijacked URL") }
        fixture.candidates = [settings, windowA, windowB]
        let urls = try makeURLs(1)
        fixture.app.handleIncomingURLs(urls)
        #expect(delivered == urls)
        #expect(fixture.windowRequests == 0)
    }

    @Test func unrelatedWindowAloneCannotConsumePendingURLs() throws {
        let fixture = URLDeliveryFixture()
        defer { fixture.close() }
        fixture.candidates = [fixture.makeWindow()]
        let urls = try makeURLs(1)
        fixture.app.handleIncomingURLs(urls)
        #expect(fixture.windowRequests == 1)
        #expect(fixture.registry.pendingCount == 1)
        let browser = fixture.makeWindow()
        fixture.candidates.append(browser)
        var delivered: [URL] = []
        fixture.registry.register(window: browser) { delivered.append($0) }
        #expect(delivered == urls)
    }

    @Test func closingLastRecipientQueuesAndRequestsAnotherWindow() throws {
        let fixture = URLDeliveryFixture()
        defer { fixture.close() }
        let browser = fixture.makeWindow()
        fixture.candidates = [browser]
        var delivered: [URL] = []
        fixture.registry.register(window: browser) { delivered.append($0) }
        let urls = try makeURLs(2)
        fixture.app.handleIncomingURLs([urls[0]])
        browser.close()
        fixture.app.handleIncomingURLs([urls[1]])
        #expect(delivered == [urls[0]])
        #expect(fixture.registry.pendingCount == 1)
        #expect(fixture.windowRequests == 1)
        let replacement = fixture.makeWindow()
        fixture.candidates = [replacement, browser]
        fixture.registry.register(window: replacement) { delivered.append($0) }
        #expect(delivered == urls)
    }

    @Test func reentrantArrivalsFollowAcceptedBatchWithoutDuplicates() throws {
        let fixture = URLDeliveryFixture()
        defer { fixture.close() }
        let browser = fixture.makeWindow()
        fixture.candidates = [browser]
        let urls = try makeURLs(3)
        var delivered: [URL] = []
        fixture.registry.register(window: browser) { url in
            delivered.append(url)
            if url == urls[0] {
                fixture.app.handleIncomingURLs([urls[2]])
            }
        }
        fixture.app.handleIncomingURLs(Array(urls.prefix(2)))
        #expect(delivered == urls)
        #expect(fixture.registry.pendingCount == 0)
    }

    @Test func queuedDrainCanCloseSwitchRegisterAndReceiveReentrantly() throws {
        let fixture = URLDeliveryFixture()
        defer { fixture.close() }
        let urls = try makeURLs(3)
        fixture.app.handleIncomingURLs(Array(urls.prefix(2)))
        let windowA = fixture.makeWindow()
        let windowB = fixture.makeWindow()
        fixture.candidates = [windowA, windowB]
        var delivered: [URL] = []
        fixture.registry.register(window: windowA) { url in
            delivered.append(url)
            windowA.close()
            fixture.candidates = [windowB, windowA]
            fixture.registry.register(window: windowB) { delivered.append($0) }
            fixture.app.handleIncomingURLs([urls[2]])
        }
        #expect(delivered == urls)
        #expect(fixture.registry.pendingCount == 0)
        #expect(fixture.windowRequests == 1)
    }

    @Test func synchronousWindowCreationRegistrationDoesNotReenterDrain() throws {
        let fixture = URLDeliveryFixture()
        defer { fixture.close() }
        var delivered: [URL] = []
        fixture.app.browserWindowFactory = {
            fixture.windowRequests += 1
            let browser = fixture.makeWindow()
            fixture.candidates = [browser]
            fixture.registry.register(window: browser) { delivered.append($0) }
        }
        let urls = try makeURLs(2)
        fixture.app.handleIncomingURLs(urls)
        #expect(delivered == urls)
        #expect(fixture.windowRequests == 1)
        #expect(fixture.registry.pendingCount == 0)
    }

    @Test func unregisterDuringDrainPreservesUndeliveredURLsUntilNextRegistration() throws {
        let fixture = URLDeliveryFixture()
        defer { fixture.close() }
        let browser = fixture.makeWindow()
        fixture.candidates = [browser]
        var delivered: [URL] = []
        var token: UUID?
        token = fixture.registry.register(window: browser) { url in
            delivered.append(url)
            if let token {
                fixture.registry.unregister(token: token)
            }
        }
        let urls = try makeURLs(2)
        fixture.app.handleIncomingURLs(urls)
        #expect(delivered == [urls[0]])
        #expect(fixture.windowRequests == 1)
        #expect(fixture.registry.pendingCount == 1)
        fixture.registry.register(window: browser) { delivered.append($0) }
        #expect(delivered == urls)
    }

    @Test func registryDoesNotRetainWindowsAndPrunesDeadHandlers() throws {
        let fixture = URLDeliveryFixture()
        defer { fixture.close() }
        weak var weakWindow: NSWindow?
        weak var weakCapture: NSObject?
        autoreleasepool {
            let window = NSWindow()
            window.isReleasedWhenClosed = false
            weakWindow = window
            let capture = NSObject()
            weakCapture = capture
            fixture.registry.register(window: window) { [capture] _ in _ = capture }
        }
        #expect(weakWindow == nil)
        try fixture.app.handleIncomingURLs(makeURLs(1))
        #expect(weakCapture == nil)
        #expect(fixture.windowRequests == 1)
        #expect(fixture.registry.pendingCount == 1)
    }

    @Test func closeReleasesHandlerAndRegistryCanDeallocate() {
        _ = NSApplication.shared
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        weak var weakRegistry: BrowserURLRecipientRegistry?
        weak var weakCapture: NSObject?
        autoreleasepool {
            let registry = BrowserURLRecipientRegistry(candidateWindows: { [window] })
            weakRegistry = registry
            autoreleasepool {
                let capture = NSObject()
                weakCapture = capture
                registry.register(window: window) { [capture] _ in _ = capture }
            }
            window.close()
            #expect(weakCapture == nil)
        }
        #expect(weakRegistry == nil)
    }

    private func makeURLs(_ count: Int) throws -> [URL] {
        try (0 ..< count).map { try #require(URL(string: "https://example.com/\($0)")) }
    }
}

@MainActor
private final class URLDeliveryFixture {
    let app = AppDelegate()
    lazy var registry = BrowserURLRecipientRegistry(candidateWindows: { [weak self] in self?.candidates ?? [] })
    var candidates: [NSWindow] = []
    var windows: [NSWindow] = []
    var windowRequests = 0

    init() {
        _ = NSApplication.shared
        app.urlRegistry = registry
        app.browserWindowFactory = { [weak self] in self?.windowRequests += 1 }
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    func close() {
        for window in windows {
            window.close()
        }
        candidates = []
        windows = []
        app.browserWindowFactory = {}
    }
}
