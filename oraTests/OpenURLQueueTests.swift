import Foundation
@testable import Ora
import Testing

/// Launch URLs arriving before the first window exists are queued in
/// `AppDelegate` and drained once by `OraRoot` on appear; without the
/// queue they were posted to a notification nobody had registered for
/// yet (or targeted at a mismatched window) and silently lost.
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

    @Test func appDelegateConsumesPendingURLsOnce() throws {
        let delegate = AppDelegate()
        let url = try #require(URL(string: "https://example.com/launch"))

        delegate.pendingOpenURLs.enqueue([url])
        #expect(delegate.consumePendingOpenURLs() == [url])
        #expect(delegate.consumePendingOpenURLs().isEmpty)
    }
}
