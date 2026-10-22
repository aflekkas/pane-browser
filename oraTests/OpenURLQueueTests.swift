import Foundation
@testable import Ora
import Testing

/// External-URL delivery: a URL reaches a tab only through an explicitly
/// registered ready recipient. Before registration it queues (FIFO,
/// exactly once) and requests a browser window; window existence alone
/// is never readiness. Tests drive the real
/// `AppDelegate.handleIncomingURLs` with injected registry/factory hooks.
struct OpenURLQueueTests {
    @Test func queuedURLsDrainInOrderExactlyOnce() throws {
        var queue = OpenURLQueue()
        let first = try #require(URL(string: "https://example.com/first"))
        let second = try #require(URL(string: "https://example.com/second"))

        #expect(queue.isEmpty)
        queue.enqueue([first])
        queue.enqueue([second])
        #expect(!queue.isEmpty)
        #expect(queue.drain() == [first, second])
        #expect(queue.isEmpty)
        #expect(queue.drain().isEmpty)
    }

    @Test func zeroWindowsQueuesAndRequestsWindowThenRegisterDrains() throws {
        let delegate = AppDelegate()
        let registry = BrowserURLRecipientRegistry()
        delegate.urlRegistry = registry
        var windowRequests = 0
        delegate.browserWindowFactory = { windowRequests += 1 }
        let first = try #require(URL(string: "https://example.com/one"))
        let second = try #require(URL(string: "https://example.com/two"))

        // No ready recipient (zero/unrelated windows): nothing is
        // delivered, both queue in order, window creation is requested.
        delegate.handleIncomingURLs([first, second])
        #expect(windowRequests == 2)
        #expect(registry.pendingCount == 2)
        #expect(!registry.isReady)

        // Registration drains after the recipient is in place, once.
        var delivered: [URL] = []
        registry.register { delivered.append($0) }
        #expect(delivered == [first, second])
        #expect(registry.pendingCount == 0)

        // A second registration gets nothing replayed.
        var replayed: [URL] = []
        registry.register { replayed.append($0) }
        #expect(replayed.isEmpty)
    }

    @Test func readyRecipientReceivesImmediatelyAndClosedRecipientRequeues() throws {
        let delegate = AppDelegate()
        let registry = BrowserURLRecipientRegistry()
        delegate.urlRegistry = registry
        var windowRequests = 0
        delegate.browserWindowFactory = { windowRequests += 1 }
        let url = try #require(URL(string: "https://example.com/live"))
        let afterClose = try #require(URL(string: "https://example.com/after-close"))

        var delivered: [URL] = []
        let token = registry.register { delivered.append($0) }
        delegate.handleIncomingURLs([url])
        #expect(delivered == [url])
        #expect(windowRequests == 0)

        // Recipient closed: delivery returns to the queue, never drops.
        registry.unregister(token: token)
        #expect(!registry.isReady)
        delegate.handleIncomingURLs([afterClose])
        #expect(delivered == [url])
        #expect(registry.pendingCount == 1)

        // A stale token cannot unregister a newer recipient.
        var second: [URL] = []
        let newerToken = registry.register { second.append($0) }
        #expect(second == [afterClose])
        registry.unregister(token: token)
        #expect(registry.isReady)
        registry.unregister(token: newerToken)
    }
}
