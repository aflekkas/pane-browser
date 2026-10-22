import Foundation
@testable import Ora
import SwiftData
import Testing
import WebKit

@MainActor
struct DownloadFlowTests {
    @Test(arguments: ["html", "blob", "attachment"])
    func navigationRoutesProduceRealQuarantinedFiles(route: String) async throws {
        let fixture = try await DownloadFlowFixture()
        defer { fixture.stop() }
        let harness = try DownloadFlowHarness()
        defer { harness.close() }
        try await harness.load(fixture.url())
        try await harness.click(route)
        try await harness.wait("real \(route) download finishes") {
            harness.manager.recentDownloads.contains { $0.status == .completed }
        }
        let record = try #require(harness.manager.recentDownloads.first)
        let destination = try #require(record.destinationURL)
        #expect(try Data(contentsOf: destination).isEmpty == false)
        #expect(DownloadSafety.rawQuarantine(destination)?.isEmpty == false)
        #expect(record.quarantineVerified)
        #expect(harness.manager.isEphemeral(record))
        #expect(try harness.manager.modelContext.fetch(FetchDescriptor<Download>()).isEmpty)
        #expect(!harness.page.hasActiveDownloads)
    }

    @Test func realRangeResumeTracksProgressCancellationDestinationAndFinish() async throws {
        let fixture = try await DownloadFlowFixture()
        defer { fixture.stop() }
        let harness = try DownloadFlowHarness()
        defer { harness.close() }
        try await harness.load(fixture.url())
        try await harness.click("large")
        try await harness.wait("initial transfer progress") {
            harness.manager.activeDownloads.first?.downloadedBytes ?? 0 > 65536
        }
        let record = try #require(harness.manager.activeDownloads.first)
        let id = record.id
        let destination = try #require(record.destinationURL)
        #expect(harness.page.hasActiveDownloads)
        harness.manager.cancelDownload(record)
        try await harness.wait("WebKit cancellation returns real resume data") { record.resumeData != nil }
        #expect(!harness.page.hasActiveDownloads)
        harness.manager.retryDownload(record)
        harness.manager.retryDownload(record) // Double click must not start another request.
        try await harness.wait("resumed progress and ownership without destination callback") {
            record.status == .downloading && harness.page.hasActiveDownloads && record.downloadedBytes > 131_072
        }
        harness.manager.cancelDownload(record)
        try await harness.wait("resumed task is cancellable") { record.resumeData != nil }
        #expect(record.status == .cancelled)
        #expect(!harness.page.hasActiveDownloads)
        harness.manager.retryDownload(record)
        try await harness.wait("resumed finish") { record.status == .completed }
        #expect(record.id == id)
        #expect(record.destinationURL == destination)
        #expect(harness.manager.recentDownloads.count == 1)
        #expect(try Data(contentsOf: destination) == DownloadFlowFixture.payload)
        #expect(record.quarantineVerified)
        #expect(DownloadSafety.rawQuarantine(destination)?.isEmpty == false)
        #expect(fixture.requests.filter { $0.lowercased().contains("range: bytes=") }.count == 2)
        #expect(!harness.page.hasActiveDownloads)
    }

    @Test func retriesSelectOwningStoreAndLegacyScopeNeverInvokesProvider() async throws {
        let fixture = try await DownloadFlowFixture()
        defer { fixture.stop() }
        let first = try DownloadFlowHarness()
        let second = try DownloadFlowHarness(manager: first.manager)
        defer { first.close()
            second.close()
        }
        try await first.load(fixture.url())
        try await second.load(fixture.url())
        for (harness, identity) in [(first, "first"), (second, "second")] {
            let cookie = try #require(HTTPCookie(properties: [
                .domain: "127.0.0.1", .path: "/", .name: "session", .value: identity
            ]))
            await harness.page.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            let session = BrowserDownloadSession(page: harness.page)
            first.manager.registerDownloadSession(session)
            let record = try Download(originalURL: fixture.url("/attachment"), fileName: "page.html")
            record.profileID = session.profileScopeID
            record.status = .failed
            // Fresh fallback traverses startDownload on the exact retained store.
            first.manager.modelContext.insert(record)
            first.manager.retryDownload(record)
            try await first.wait("scoped fallback \(identity)") { record.status == .completed }
        }
        let requests = fixture.requests.filter { $0.hasPrefix("GET /attachment ") }
        #expect(requests.count == 2)
        #expect(requests[0].contains("session=first"))
        #expect(requests[1].contains("session=second"))
        #expect(first.page.downloadProfileScopeID != second.page.downloadProfileScopeID)
        let spy = DelayedDownloadSession(profileScopeID: first.page.downloadProfileScopeID)
        first.manager.registerDownloadSession(spy)
        for scope in [nil, "unknown", "private:wrong"] as [String?] {
            let legacy = try Download(originalURL: fixture.url("/large"), fileName: "legacy")
            legacy.status = .failed
            legacy.profileID = scope
            legacy.resumeData = Data([1, 2, 3])
            first.manager.retryDownload(legacy)
        }
        #expect(spy.invocations == 0)
    }

    @Test func delayedProviderKeepsRecordPendingAndNeverFallsBack() throws {
        let harness = try DownloadFlowHarness()
        defer { harness.close() }
        let session = DelayedDownloadSession(profileScopeID: harness.page.downloadProfileScopeID)
        harness.manager.registerDownloadSession(session)
        let record = try Download(originalURL: #require(URL(string: "https://fixture.invalid/file")), fileName: "file")
        record.profileID = session.profileScopeID
        record.status = .failed
        harness.manager.modelContext.insert(record)
        harness.manager.retryDownload(record)
        harness.manager.retryDownload(record)
        #expect(session.invocations == 1)
        #expect(record.status == .pending)
        #expect(try harness.manager.modelContext.fetch(FetchDescriptor<Download>()).contains { $0.id == record.id })
        session.completion?(nil)
        #expect(record.status == .failed)
        #expect(session.invocations == 1)
    }
}

@MainActor
private final class DelayedDownloadSession: DownloadTransferSession {
    let profileScopeID: String
    var invocations = 0
    var completion: ((BrowserDownloadTask?) -> Void)?
    init(profileScopeID: String) {
        self.profileScopeID = profileScopeID
    }

    func start(_ record: Download, resumeData: Data?, completion: @escaping (BrowserDownloadTask?) -> Void) {
        invocations += 1
        self.completion = completion
    }
}
