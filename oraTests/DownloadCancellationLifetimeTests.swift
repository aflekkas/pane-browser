import Foundation
@testable import Ora
import Testing

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
