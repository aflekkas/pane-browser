import Foundation
@testable import Ora
import Testing

@MainActor
struct PasswordBridgeNavigationTests {
    @Test(arguments: ["pushState", "replaceState"])
    func spaRouteAcceptsRealFocusAndSubmitThenRejectsOldDocument(method: String) async throws {
        let fixture = try await PasswordBridgeLoopbackFixture()
        defer { fixture.stop() }
        let harness = try PasswordBridgeWorldHarness(observeNativePosts: true)
        defer { harness.close() }
        try await harness.load(fixture.url())
        let beforeRoute = try await harness.waitForContext()
        _ = try await harness.evaluatePage("history.\(method)({}, '', '/other'); true")
        let routeURL = try fixture.url("/other")
        try await harness.waitUntil("native SPA document URL") {
            harness.page.currentPasswordContext()?.documentURL == routeURL
        }
        let routed = try await harness.waitForContext()
        #expect(routed.documentToken == beforeRoute.documentToken)
        #expect(routed.generation == beforeRoute.generation)
        let focus = try await harness.focusPassword()
        try await harness.fill(focus: focus, token: routed.documentToken)
        let submitted = harness.recorder.submitMessages.count
        _ = try await harness.evaluatePage("document.getElementById('login-form').requestSubmit(); true")
        try await harness.waitUntil("production submit message after SPA route") {
            harness.recorder.submitMessages.count > submitted
        }
        let submission = harness.recorder.submitMessages[submitted]
        #expect(submission.username == "fixture-user@example.invalid")
        #expect(submission.password == "fixture-dummy-value")
        #expect(submission.hostname == "127.0.0.1")

        // Reload the same routed URL: a real new document, with every native
        // URL/origin check still matching. Only the old token is stale.
        try await harness.reload()
        let current = try await harness.waitForContext()
        #expect(current.documentToken != routed.documentToken)
        let stale = try await harness.postProbe(token: routed.documentToken)
        #expect(!stale.forwarded)
        let valid = try await harness.postProbe(token: current.documentToken)
        #expect(valid.forwarded)
    }

    @Test func cancelledProvisionalNavigationRestoresRealFocusAndFill() async throws {
        let fixture = try await PasswordBridgeLoopbackFixture()
        defer { fixture.stop() }
        let harness = try PasswordBridgeWorldHarness()
        defer { harness.close() }
        try await harness.load(fixture.url())
        let original = try await harness.waitForContext()
        _ = try await harness.evaluatePage("window.fixtureRetainedMarker = 'retained'; true")
        try await harness.cancelHeldNavigation(on: fixture)
        let restored = try await harness.waitForContext(afterGeneration: original.generation)
        #expect(restored.documentURL == original.documentURL)
        #expect(restored.documentToken == original.documentToken)
        #expect(restored.generation != original.generation)
        #expect(restored != original)
        let marker = try await harness.evaluatePage("window.fixtureRetainedMarker") as? String
        #expect(marker == "retained")
        let freshFocus = try await harness.focusPassword()
        try await harness.fill(focus: freshFocus, token: restored.documentToken)
        let filled = try await harness.evaluatePage("document.getElementById('pw').value") as? String
        #expect(filled == "fixture-dummy-value")
    }
}

extension PasswordBridgeWorldHarness {
    func focusPassword() async throws -> FocusMessage {
        let count = focusMessageCount
        let focused = try await evaluatePage("""
        (() => {
            const field = document.getElementById('pw');
            field.blur();
            field.focus();
            return document.activeElement === field;
        })()
        """) as? Bool
        try #require(focused == true)
        return try await waitForFocusMessage(afterCount: count)
    }

    func cancelHeldNavigation(on fixture: PasswordBridgeLoopbackFixture) async throws {
        let original = try await waitForContext()
        let started = recorder.startedNavigationCount
        let finished = recorder.finishedNavigationCount
        try page.load(URLRequest(url: fixture.url("/held")))
        try await waitUntil("server received held request and provisional navigation started") { [self] in
            fixture.hasReceived("/held") && recorder.startedNavigationCount > started && page.isLoading
        }
        // No response headers have been sent: the old DOM is retained,
        // but its password context must already be retired.
        #expect(page.currentPasswordContext() == nil)
        page.stopLoading()
        try await waitUntil("cancelled provisional navigation completed") { [self] in
            !page.isLoading && recorder.finishedNavigationCount > finished
        }
        _ = try await waitForContext(afterGeneration: original.generation)
    }
}
