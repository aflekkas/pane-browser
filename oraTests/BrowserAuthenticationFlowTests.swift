import AppKit
@testable import Ora
import Testing

@MainActor
struct BrowserAuthenticationFlowTests {
    @Test(arguments: ["navigate", "teardown", "window", "replace"])
    func realBasicAuthSheetCancelsAtOwnerBoundary(boundary: String) async throws {
        let fixture = try await DownloadFlowFixture()
        defer { fixture.stop() }
        let harness = try DownloadFlowHarness()
        defer { harness.close() }
        try harness.page.load(URLRequest(url: fixture.url("/auth")))
        try await harness.wait("real HTTP auth sheet") { harness.window.attachedSheet != nil }
        let oldSheet = try #require(harness.window.attachedSheet)
        switch boundary {
        case "navigate":
            try await harness.load(fixture.url())
        case "teardown":
            harness.tab.destroyWebView()
        case "window":
            harness.window.close()
        default:
            try harness.page.load(URLRequest(url: fixture.url("/auth")))
        }
        try await harness.wait("old sheet dismissed") { oldSheet.sheetParent == nil }
        #expect(!oldSheet.isVisible)
        if boundary == "replace" {
            try await harness.wait("replacement sheet") { harness.window.attachedSheet != nil }
            #expect(harness.window.attachedSheet !== oldSheet)
            harness.page.stopLoading()
            try await harness.wait("replacement sheet cancelled") { harness.window.attachedSheet == nil }
        }
        #expect(!fixture.requests.contains { $0.lowercased().contains("authorization: basic") })
    }

    @Test func redirectShowsActualTLSEndpointAndStaleDecisionCannotGrant() async throws {
        let source = try await DownloadFlowFixture()
        let tls = try await DownloadFlowFixture(tls: DownloadFixtureTLS.options())
        defer { source.stop()
            tls.stop()
        }
        let harness = try DownloadFlowHarness()
        defer { harness.close() }
        let destination = try tls.url("/attachment", secure: true)
        try harness.page.load(URLRequest(url: source.url("/redirect?\(destination.absoluteString)")))
        try await harness.wait("invalid redirected endpoint interstitial") { harness.tab.certificateChallenge != nil }
        let challenge = try #require(harness.tab.certificateChallenge)
        #expect(challenge.host == destination.host)
        #expect(challenge.port == destination.port)
        #expect(try challenge.port != (source.url()).port)
        #expect(challenge.fingerprint != nil)
        let staleDecision = try #require(harness.tab.certificateDecision)
        try await harness.load(source.url())
        #expect(harness.tab.certificateChallenge == nil)
        staleDecision(true)
        harness.tab.resolveCertificateChallenge(id: challenge.id, allowed: true)
        #expect(try !CertificateExceptions.shared.isAllowed(
            host: challenge.host, port: challenge.port, fingerprint: #require(challenge.fingerprint),
            scope: harness.page.certificateExceptionScope
        ))
        #expect(harness.manager.recentDownloads.isEmpty)
    }

    @Test func certificateReplacementAndTeardownCompleteOnceWithoutLateGrant() async throws {
        let tls = try await DownloadFlowFixture(tls: DownloadFixtureTLS.options())
        defer { tls.stop() }
        let harness = try DownloadFlowHarness()
        defer { harness.close() }
        let url = try tls.url(secure: true)
        harness.page.load(URLRequest(url: url))
        try await harness.wait("first certificate challenge") { harness.tab.certificateChallenge != nil }
        let first = try #require(harness.tab.certificateChallenge)
        let stale = try #require(harness.tab.certificateDecision)
        harness.page.reload()
        try await harness.wait("replacement certificate challenge") {
            harness.tab.certificateChallenge != nil && harness.tab.certificateChallenge?.id != first.id
        }
        let replacement = try #require(harness.tab.certificateChallenge)
        harness.tab.resolveCertificateChallenge(id: first.id, allowed: true)
        #expect(harness.tab.certificateChallenge?.id == replacement.id)
        harness.tab.destroyWebView()
        #expect(harness.tab.certificateChallenge == nil)
        stale(true)
        #expect(try !CertificateExceptions.shared.isAllowed(
            host: first.host, port: first.port, fingerprint: #require(first.fingerprint),
            scope: harness.page.certificateExceptionScope
        ))
    }
}
