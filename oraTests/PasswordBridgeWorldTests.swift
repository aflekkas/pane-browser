import AppKit
@testable import Ora
import Testing
import WebKit

/// Real-WKWebView coverage for the isolated password-bridge world.
///
/// These load fixture pages through the production `BrowserPage` wiring
/// (production user scripts + handler registration) and assert behaviour:
/// the page world cannot see the bridge, the isolated script still detects
/// and fills forms, and subframe/stale contexts never reach the delegate.
/// Fixture credentials below are inert dummies, not real secrets.
@MainActor
struct PasswordBridgeWorldTests {
    private static let dummyUsername = "fixture-user@example.invalid"
    private static let dummyPassword = "fixture-dummy-value"

    @Test func pageWorldCannotSeePasswordBridgeButIsolatedScriptDetectsForm() async throws {
        let fixture = try await PasswordBridgeLoopbackFixture()
        defer { fixture.stop() }
        let harness = try PasswordBridgeWorldHarness()
        defer { harness.close() }
        try await harness.load(fixture.url())

        let pageSeesBridge = try await harness.evaluatePage(
            """
            (typeof window.__oraPasswordManager !== 'undefined')
                || !!(window.webkit && window.webkit.messageHandlers
                    && window.webkit.messageHandlers.passwordManager)
            """
        ) as? Bool
        #expect(pageSeesBridge == false)

        // Focusing the password field must make the isolated-world script
        // report the form natively (main frame, fixture origin).
        _ = try await harness.evaluatePage("document.getElementById('pw').focus(); true")
        let focus = try await harness.waitForFocusMessage()
        #expect(focus.fieldKind == .password)
        #expect(!focus.passwordFieldIDs.isEmpty)
    }

    @Test func fillFromIsolatedWorldReachesPageDOM() async throws {
        let fixture = try await PasswordBridgeLoopbackFixture()
        defer { fixture.stop() }
        let harness = try PasswordBridgeWorldHarness()
        defer { harness.close() }
        try await harness.load(fixture.url())

        _ = try await harness.evaluatePage("document.getElementById('pw').focus(); true")
        let focus = try await harness.waitForFocusMessage()
        let context = try await harness.waitForContext()

        let payload: [String: Any] = [
            "usernameFieldID": focus.usernameFieldID ?? "",
            "passwordFieldIDs": focus.passwordFieldIDs,
            "username": Self.dummyUsername,
            "password": Self.dummyPassword,
            "highlightColor": "#E8F5E9",
            "submitAfterFill": false,
            "documentToken": context.documentToken
        ]
        let payloadJSON = try #require(String(
            data: JSONSerialization.data(withJSONObject: payload),
            encoding: .utf8
        ))
        _ = try await harness.evaluatePassword(
            "window.__oraPasswordManager.fillCredentials(\(payloadJSON)); true"
        )

        let filledPassword = try await harness.evaluatePage(
            "document.getElementById('pw').value"
        ) as? String
        let filledUsername = try await harness.evaluatePage(
            "document.getElementById('user').value"
        ) as? String
        #expect(filledPassword == Self.dummyPassword)
        #expect(filledUsername == Self.dummyUsername)
    }

    @Test(arguments: [false, true])
    func isolatedSubframePostReachesNativeAndIsRejected(crossOrigin: Bool) async throws {
        let fixture = try await PasswordBridgeLoopbackFixture()
        defer { fixture.stop() }
        let other = try await PasswordBridgeLoopbackFixture()
        defer { other.stop() }
        let harness = try PasswordBridgeWorldHarness(observeNativePosts: true)
        defer { harness.close() }
        let mainURL = try fixture.url()
        // Same-origin uses the EXACT main document URL. Origin/URL/token
        // checks all pass, leaving isMainFrame as the sole rejection reason.
        let childURL = try crossOrigin ? other.url() : mainURL
        try await harness.load(mainURL)
        let context = try await harness.waitForContext()
        let frame = try await harness.appendFrame(url: childURL)
        #expect(!frame.isMainFrame)
        #expect(frame.request.url == childURL)
        #expect((frame.securityOrigin.port != mainURL.port) == crossOrigin)

        let focusResult = try await harness.evaluate(
            """
            (() => {
                const field = document.querySelector('form input[type=password]');
                if (!field) return 'missing-form';
                field.focus();
                return document.activeElement === field ? 'focused' : 'not-focused';
            })()
            """, frame: frame, world: .page
        ) as? String
        try #require(focusResult == "focused")
        let pageSeesHandler = try await harness.evaluate(
            "!!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.passwordManager)",
            frame: frame, world: .page
        ) as? Bool
        #expect(pageSeesHandler == false)

        let attempt = try await harness.postProbe(token: context.documentToken, frame: frame)
        #expect(!attempt.message.frameInfo.isMainFrame)
        #expect(attempt.message.frameInfo.request.url == childURL)
        #expect(!attempt.forwarded)
        // Native forwarding has returned synchronously before the attempt is
        // recorded. No sleep-based negative or separate-handler ordering assumption.
        #expect(harness.recorder.passwordMessages.isEmpty)

        // Same payload + current token succeeds from the real main frame.
        let positive = try await harness.postProbe(token: context.documentToken)
        #expect(positive.message.frameInfo.isMainFrame)
        #expect(positive.forwarded)
        #expect(harness.recorder.passwordMessages.count == 1)
    }

    @Test func staleTokenFillAfterSameURLReloadDoesNotWrite() async throws {
        let fixture = try await PasswordBridgeLoopbackFixture()
        defer { fixture.stop() }
        let harness = try PasswordBridgeWorldHarness()
        defer { harness.close() }
        try await harness.load(fixture.url())

        _ = try await harness.evaluatePage("document.getElementById('pw').focus(); true")
        _ = try await harness.waitForFocusMessage()
        let oldContext = try await harness.waitForContext()

        // Same-URL reload: new document, new generation, new token.
        let focusCountBeforeReload = harness.focusMessageCount
        try await harness.reload()
        _ = try await harness.evaluatePage("document.getElementById('pw').focus(); true")
        let newFocus = try await harness.waitForFocusMessage(afterCount: focusCountBeforeReload)
        let newContext = try await harness.waitForContext()
        #expect(newContext != oldContext)
        #expect(newContext.documentToken != oldContext.documentToken)
        #expect(newContext.generation != oldContext.generation)

        // A fill request minted for the pre-reload document (the delayed-
        // auth case) must not write into the new document. Uses the NEW
        // document's field IDs with the OLD token, so the token mismatch
        // is the only thing that can refuse the write.
        try await harness.fill(focus: newFocus, token: oldContext.documentToken)
        let afterStaleFill = try await harness.evaluatePage(
            "document.getElementById('pw').value"
        ) as? String
        #expect(afterStaleFill == "")

        // The current document's token still fills.
        try await harness.fill(focus: newFocus, token: newContext.documentToken)
        let afterFreshFill = try await harness.evaluatePage(
            "document.getElementById('pw').value"
        ) as? String
        #expect(afterFreshFill == Self.dummyPassword)
    }

    @Test func validatorRejectsSubframeForgedAndStaleContexts() throws {
        let page = try #require(URL(string: "https://example.com/login"))
        let otherOrigin = try #require(URL(string: "https://evil.example.net/login"))
        let navigated = try #require(URL(string: "https://example.com/other"))
        let downgraded = try #require(URL(string: "http://example.com/login"))
        let otherPort = try #require(URL(string: "https://example.com:8443/login"))
        let owner = NSObject()
        let context = try PasswordDocumentContext(
            pageIdentity: ObjectIdentifier(owner),
            generation: 3,
            originKey: #require(PasswordBridge.originKey(for: page)),
            documentURL: page,
            documentToken: "token-current"
        )

        #expect(PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: page, pageURL: page, committedURL: page,
            payloadToken: "token-current", current: context
        ))
        // Subframe: never valid, even same-origin.
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: false, frameURL: page, pageURL: page, committedURL: page,
            payloadToken: "token-current", current: context
        ))
        // Forged: frame origin disagrees with the native page URL.
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: otherOrigin, pageURL: page, committedURL: page,
            payloadToken: "token-current", current: context
        ))
        // Stale: same-origin but different document (/login vs /other).
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: page, pageURL: navigated, committedURL: navigated,
            payloadToken: "token-current", current: context
        ))
        // Queued old-document message: correct origin/document, old token.
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: page, pageURL: page, committedURL: page,
            payloadToken: "token-previous-document", current: context
        ))
        // Scheme downgrade and port change are different origins.
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: downgraded, pageURL: downgraded, committedURL: downgraded,
            payloadToken: "token-current", current: context
        ))
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: otherPort, pageURL: otherPort, committedURL: otherPort,
            payloadToken: "token-current", current: context
        ))
        // Missing provenance fails closed: no token, no committed URL,
        // no registered document, no frame URL.
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: page, pageURL: page, committedURL: page,
            payloadToken: nil, current: context
        ))
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: page, pageURL: page, committedURL: nil,
            payloadToken: "token-current", current: context
        ))
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: page, pageURL: page, committedURL: page,
            payloadToken: "token-current", current: nil
        ))
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: nil, pageURL: page, committedURL: page,
            payloadToken: "token-current", current: context
        ))
    }

    @Test func fillContextEqualityCoversPageGenerationOriginAndToken() throws {
        let owner = NSObject()
        let page = try #require(URL(string: "https://example.com/login"))
        let base = PasswordDocumentContext(
            pageIdentity: ObjectIdentifier(owner),
            generation: 1,
            originKey: "https://example.com",
            documentURL: page,
            documentToken: "token-a"
        )
        // Identical context (nothing navigated) remains valid.
        #expect(base == PasswordDocumentContext(
            pageIdentity: ObjectIdentifier(owner),
            generation: 1,
            originKey: "https://example.com",
            documentURL: page,
            documentToken: "token-a"
        ))
        // Same origin, different document/generation (delayed auth across
        // a navigation or reload) must not match.
        #expect(base != PasswordDocumentContext(
            pageIdentity: ObjectIdentifier(owner),
            generation: 2,
            originKey: "https://example.com",
            documentURL: page,
            documentToken: "token-b"
        ))
        // HTTPS -> HTTP and port change change the origin key.
        #expect(base != PasswordDocumentContext(
            pageIdentity: ObjectIdentifier(owner),
            generation: 1,
            originKey: "http://example.com",
            documentURL: page,
            documentToken: "token-a"
        ))
        #expect(base != PasswordDocumentContext(
            pageIdentity: ObjectIdentifier(owner),
            generation: 1,
            originKey: "https://example.com:8443",
            documentURL: page,
            documentToken: "token-a"
        ))
        // Page replacement: different BrowserPage identity never matches.
        #expect(base != PasswordDocumentContext(
            pageIdentity: ObjectIdentifier(NSObject()),
            generation: 1,
            originKey: "https://example.com",
            documentURL: page,
            documentToken: "token-a"
        ))
    }
}
