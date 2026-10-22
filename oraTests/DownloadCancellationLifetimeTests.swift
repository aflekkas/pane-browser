import Foundation
@testable import Ora
import Testing
import WebKit

@MainActor
struct DownloadCancellationLifetimeTests {
    @Test(arguments: [false, true])
    func deferredCancellationKeepsPolicyAfterWrapperRelease(isResumed: Bool) throws {
        var delivered: [Data?] = []
        var deferred: ((Data?) -> Void)?
        var task: BrowserDownloadTask? = try BrowserDownloadTask(
            originalURL: #require(URL(string: "https://fixture.invalid/file")),
            isResumed: isResumed, progress: Progress(totalUnitCount: 1024),
            cancelTransfer: { deferred = $0 }
        )
        weak var released = task
        task?.cancel { delivered.append($0) }
        task?.clearCallbacks()
        task = nil
        #expect(released == nil)
        let bytes = Data([1, 3, 5, 7])
        let complete = try #require(deferred)
        complete(bytes)
        complete(bytes)
        #expect(delivered.count == 1)
        let result = try #require(delivered.first)
        #expect(result == (isResumed ? nil : bytes))
    }
}

extension DownloadCancellationLifetimeTests {
    @Test func realWebKitCancellationCompletesOnceAfterTrackingIsRemoved() async throws {
        let fixture = try await DownloadFlowFixture()
        defer { fixture.stop() }
        let url = try fixture.url("/large")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        var task: BrowserDownloadTask? = await withCheckedContinuation { continuation in
            webView.startDownload(using: URLRequest(url: url)) { download in
                let wrapper = BrowserDownloadTask(download: download, originalURL: url)
                wrapper.onDestinationRequest = { _, _, completion in completion(destination) }
                continuation.resume(returning: wrapper)
            }
        }
        try await LifecycleRepairHarness.waitUntil { task?.progress.completedUnitCount ?? 0 > 65536 }
        weak var released = task
        var completions = 0
        var resumeData: Data?
        task?.cancel { data in
            completions += 1
            resumeData = data
        }
        task?.clearCallbacks()
        task = nil
        try await LifecycleRepairHarness.waitUntil { completions > 0 }
        #expect(completions == 1 && resumeData != nil)
        #expect(released == nil)
        // Drain another main-actor turn; a late delegate event cannot complete
        // cancellation again or mutate a wrapper removed from manager tracking.
        await Task.yield()
        #expect(completions == 1)
        withExtendedLifetime(webView) {}
    }
}
