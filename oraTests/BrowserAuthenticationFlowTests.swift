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
        #expect(!harness.manager.recentDownloads.contains { $0.status == .completed })
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

extension BrowserAuthenticationFlowTests {
    @Test func twoSpacesKeepRealAuthenticatedDownloadSessionsSeparateAcrossResume() async throws {
        let fixture = try await DownloadFlowFixture()
        defer { fixture.stop() }
        let first = try DownloadFlowHarness(profile: BrowserEngineProfile(identifier: UUID(), isPrivate: false))
        let second = try DownloadFlowHarness(
            profile: BrowserEngineProfile(identifier: UUID(), isPrivate: false), manager: first.manager
        )
        defer { first.close()
            second.close()
        }
        for harness in [first, second] {
            try harness.page.load(URLRequest(url: fixture.url("/auth")))
            try await harness.wait("each Space independently prompts for real HTTP credentials") {
                harness.window.attachedSheet != nil
            }
            let sheet = try #require(harness.window.attachedSheet)
            let fields = allSubviews(sheet.contentView).compactMap { $0 as? NSTextField }
            let username = try #require(fields.first { $0.placeholderString == "Username" })
            let password = try #require(fields.first { $0 is NSSecureTextField })
            username.stringValue = "fixture"
            password.stringValue = "pass"
            let signIn = try #require(allSubviews(sheet.contentView).compactMap { $0 as? NSButton }
                .first { $0.title == "Sign In" })
            signIn.performClick(nil)
            try await harness.wait("authenticated page committed") {
                harness.page.lastCommittedURL?.path == "/auth" && !harness.page.isLoading
            }
        }
        // Both profiles have independently authenticated, and both remain
        // alive. A retry for A must continue A even after B registered last.
        for harness in [first, second] {
            let url = try fixture.url("/auth-large")
            let literal = try #require(String(data: JSONEncoder().encode(url.absoluteString), encoding: .utf8))
            _ = try await harness.page.webView.evaluateJavaScript(
                "const a=document.getElementById('html'); a.href=\(literal); a.click(); true"
            )
            try await harness.wait("authenticated transfer") {
                first.manager.activeDownloads.contains {
                    $0.profileID == harness.page.downloadProfileScopeID && $0.downloadedBytes > 65536
                }
            }
            let record = try #require(first.manager.activeDownloads.first {
                $0.profileID == harness.page.downloadProfileScopeID
            })
            first.manager.cancelDownload(record)
            try await harness.wait("authenticated resume data") { record.resumeData != nil }
        }
        let record = try #require(first.manager.recentDownloads.first {
            $0.profileID == first.page.downloadProfileScopeID
        })
        first.manager.retryDownload(record)
        #expect(first.page.hasActiveDownloads)
        #expect(!second.page.hasActiveDownloads)
        try await first.wait("authenticated resumed transfer completes") { record.status == .completed }
        #expect(fixture.requests.contains { $0.lowercased().contains("range: bytes=") })
        #expect(record.quarantineVerified)
    }

    private func allSubviews(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { allSubviews($0) }
    }
}

extension BrowserAuthenticationFlowTests {
    @Test func explicitCertificateDecisionAllowsOnlyTheCurrentEndpoint() async throws {
        let tls = try await DownloadFlowFixture(tls: DownloadFixtureTLS.options())
        defer { tls.stop() }
        let harness = try DownloadFlowHarness()
        defer { harness.close() }
        let url = try tls.url(secure: true)
        harness.page.load(URLRequest(url: url))
        try await harness.wait("certificate decision") { harness.tab.certificateChallenge != nil }
        let challenge = try #require(harness.tab.certificateChallenge)
        harness.tab.resolveCertificateChallenge(id: challenge.id, allowed: true)
        try await harness.wait("explicit trust decision loads real TLS page") {
            harness.page.lastCommittedURL == url && !harness.page.isLoading
        }
        #expect(try CertificateExceptions.shared.isAllowed(
            host: challenge.host, port: challenge.port, fingerprint: #require(challenge.fingerprint),
            scope: harness.page.certificateExceptionScope
        ))
        #expect(try !CertificateExceptions.shared.isAllowed(
            host: challenge.host, port: challenge.port + 1, fingerprint: #require(challenge.fingerprint),
            scope: harness.page.certificateExceptionScope
        ))
    }
}

extension BrowserAuthenticationFlowTests {
    @Test func missingTabPresentationCancelsRealAuthWithoutOpeningAnOrphanSheet() async throws {
        let fixture = try await DownloadFlowFixture()
        defer { fixture.stop() }
        let harness = try DownloadFlowHarness()
        defer { harness.close() }
        harness.delegate.tab = nil
        try harness.page.load(URLRequest(url: fixture.url("/auth")))
        try await harness.wait("request reached auth fixture") { !fixture.requests.isEmpty }
        try await harness.wait("unowned challenge resolves") { !harness.page.isLoading }
        #expect(harness.window.attachedSheet == nil)
        #expect(harness.page.lastCommittedURL?.path != "/auth")
    }
}
