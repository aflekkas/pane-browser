import Foundation
@testable import Ora
import SwiftData
import Testing
import WebKit

@MainActor
struct DownloadRestartTests {
    @Test func persistedOwnerRetriesWithEmptyRegistryAndOriginalCookies() async throws {
        let fixture = try await DownloadFlowFixture()
        defer { fixture.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("retry.sqlite")
        let owner = UUID()
        let recordID = try writeFailedRecord(storeURL: storeURL, owner: owner, url: fixture.url("/large"))
        let profile = BrowserEngineProfile(identifier: owner, isPrivate: false)
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: "session", .value: "persisted-owner",
            .expires: Date().addingTimeInterval(3600)
        ]))
        await profile.dataStore.httpCookieStore.setCookie(cookie)
        defer { profile.clearData(ofTypes: [.all]) }
        let installed = await profile.dataStore.httpCookieStore.allCookies()
        #expect(installed.contains { $0.name == "session" && $0.value == "persisted-owner" })
        // Resolve the exact store used by recovery before retry, without
        // registering a transfer session or starting any prior download.
        let recoveredProfile = BrowserEngine.shared.makeProfile(identifier: owner, isPrivate: false)
        let recoveredCookies = await recoveredProfile.dataStore.httpCookieStore.allCookies()
        #expect(recoveredCookies.contains { $0.name == "session" && $0.value == "persisted-owner" })
        let store = try ModelConfiguration.createOraContainer(at: storeURL)
        let context = ModelContext(store)
        let manager = DownloadManager(modelContainer: store, modelContext: context)
        manager.downloadsDirectory = directory
        // This focused private page has a different cookie and has never started
        // a download. The new manager has no transfer sessions registered.
        let focused = try DownloadFlowHarness(manager: manager)
        defer { focused.close() }
        let otherCookie = try #require(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: "session", .value: "wrong-focused-session"
        ]))
        await focused.page.webView.configuration.websiteDataStore.httpCookieStore.setCookie(otherCookie)
        let focusedCookies = await focused.page.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        #expect(focusedCookies.contains { $0.name == "session" && $0.value == "wrong-focused-session" })
        #expect(!focusedCookies.contains { $0.value == "persisted-owner" })
        let record = try #require(context.fetch(FetchDescriptor<Download>()).first { $0.id == recordID })
        #expect(record.resumeData == nil)
        #expect(manager.canRetryDownload(record))
        manager.retryDownload(record)
        try await focused.wait("persisted retry completes") { record.status == .completed }
        let destination = try #require(record.destinationURL)
        #expect(try Data(contentsOf: destination) == DownloadFlowFixture.payload)
        #expect(record.profileID == owner.uuidString && !manager.isEphemeral(record))
        #expect(record.quarantineVerified)
        let requests = fixture.requests.filter { $0.hasPrefix("GET /large ") }
        #expect(requests.count == 1)
        #expect(requests.first?.contains("session=persisted-owner") == true)
        #expect(requests.first?.contains("wrong-focused-session") == false)
        #expect(requests.first?.lowercased().contains("range:") == false)
    }

    @Test func missingLegacyAndLostPrivateOwnersExplainRefusalWithoutNetwork() async throws {
        let fixture = try await DownloadFlowFixture()
        defer { fixture.stop() }
        let harness = try DownloadFlowHarness()
        defer { harness.close() }
        let scopes: [String?] = [nil, UUID().uuidString, "private:\(UUID())"]
        for scope in scopes {
            let record = try Download(originalURL: fixture.url("/large"), fileName: "missing.bin")
            record.profileID = scope
            record.markFailed(error: "fixture")
            #expect(harness.manager.canRetryDownload(record))
            harness.manager.retryDownload(record)
            #expect(record.status == .failed)
            #expect(record.error?.contains("unavailable") == true)
            #expect(!record.isActive)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.requests.isEmpty)
    }

    private func writeFailedRecord(storeURL: URL, owner: UUID, url: URL) throws -> UUID {
        let store = try ModelConfiguration.createOraContainer(at: storeURL)
        let context = ModelContext(store)
        context.insert(TabContainer(id: owner, name: "Download owner"))
        let record = Download(originalURL: url, fileName: "restart.bin")
        record.profileID = owner.uuidString
        record.markCancelled()
        record.resumeData = Data([1, 2, 3]) // Must be transient across store reopen.
        context.insert(record)
        try context.save()
        return record.id
    }
}

extension DownloadRestartTests {
    @Test func recoveredFreshRetryOwnsAndCancelsNavigationAuthentication() async throws {
        let fixture = try await DownloadFlowFixture()
        defer { fixture.stop() }
        let harness = try DownloadFlowHarness()
        defer { harness.close() }
        harness.window.makeKeyAndOrderFront(nil)
        let owner = TabContainer(name: "Recovered auth owner")
        harness.manager.modelContext.insert(owner)
        let record = try Download(originalURL: fixture.url("/auth-large"), fileName: "auth.bin")
        record.profileID = owner.id.uuidString
        record.markCancelled()
        harness.manager.modelContext.insert(record)
        try harness.manager.modelContext.save()
        harness.manager.retryDownload(record)
        try await harness.wait("recovered navigation auth sheet") { harness.window.attachedSheet != nil }
        let sheet = try #require(harness.window.attachedSheet)
        #expect(record.status == .pending)
        harness.manager.cancelDownload(record)
        try await harness.wait("recovered auth cancelled") { sheet.sheetParent == nil && !sheet.isVisible }
        #expect(record.status == .cancelled && harness.manager.canRetryDownload(record))
        #expect(!fixture.requests.contains { $0.lowercased().contains("authorization:") })
        #expect(record.destinationURL == nil)
    }
}
