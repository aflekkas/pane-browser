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
        let fixture = try FixtureSite.loginPage()
        let harness = BrowserHarness()
        try await harness.load(fixture.mainURL)

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
        #expect(focus.fieldKind == "password")
        #expect(!focus.passwordFieldIDs.isEmpty)
    }

    @Test func fillFromIsolatedWorldReachesPageDOM() async throws {
        let fixture = try FixtureSite.loginPage()
        let harness = BrowserHarness()
        try await harness.load(fixture.mainURL)

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

    @Test func iframePasswordFormNeverReachesBridge() async throws {
        let fixture = try FixtureSite.iframePage()
        let harness = BrowserHarness()
        try await harness.load(fixture.mainURL)

        // Non-vacuous: the subframe form must actually exist and be
        // focusable, and the focus must land inside the subframe document.
        // Poll: the iframe document may finish loading after the main page.
        var focused: String?
        for _ in 0 ..< 50 where focused != "focused" {
            focused = try await harness.evaluatePage(
                """
                (() => {
                    const doc = document.querySelector('iframe').contentDocument;
                    const field = doc && doc.querySelector('input[type=password]');
                    if (!field) { return 'missing'; }
                    field.focus();
                    return doc.activeElement === field ? 'focused' : 'not-focused';
                })()
                """
            ) as? String
            if focused != "focused" {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        #expect(focused == "focused")

        // Explicitly attempt to invoke the isolated handler from inside
        // the same-origin subframe's own page world: it must not exist
        // there (the handler lives only in the isolated main-frame world).
        let subframeSeesHandler = try await harness.evaluatePage(
            """
            (() => {
                const win = document.querySelector('iframe').contentWindow;
                try {
                    return !!(win.webkit && win.webkit.messageHandlers
                        && win.webkit.messageHandlers.passwordManager);
                } catch (error) { return false; }
            })()
            """
        ) as? Bool
        #expect(subframeSeesHandler == false)

        // Give any (incorrect) subframe delivery time to arrive.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(harness.recorder.passwordMessages.isEmpty)
    }

    @Test func staleTokenFillAfterSameURLReloadDoesNotWrite() async throws {
        let fixture = try FixtureSite.loginPage()
        let harness = BrowserHarness()
        try await harness.load(fixture.mainURL)

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

// MARK: - Harness

@MainActor
private final class BrowserHarness {
    let recorder = MessageRecorder()
    private let window: NSWindow
    private let page: BrowserPage

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.orderBack(nil)
        let profile = BrowserEngineProfile(identifier: UUID(), isPrivate: true)
        page = BrowserEngine().makePage(
            profile: profile,
            configuration: .oraDefault(
                userScripts: OraBrowserScripts.userScripts(),
                privacySettings: SpacePrivacySettings()
            ),
            delegate: recorder
        )
        page.contentView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView?.addSubview(page.contentView)
    }

    func load(_ url: URL) async throws {
        page.load(URLRequest(url: url))
        try await waitUntil { [page] in
            page.currentURL?.path == url.path && !page.isLoading
        }
    }

    func evaluatePage(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            page.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    func evaluatePassword(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            page.evaluatePasswordJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    func waitForFocusMessage(afterCount: Int = 0) async throws -> FocusMessage {
        var found: FocusMessage?
        try await waitUntil { [recorder] in
            let messages = recorder.focusMessages
            if messages.count > afterCount {
                found = messages[afterCount]
            }
            return found != nil
        }
        return try #require(found)
    }

    var focusMessageCount: Int {
        recorder.focusMessages.count
    }

    func waitForContext() async throws -> PasswordDocumentContext {
        var found: PasswordDocumentContext?
        try await waitUntil { [page] in
            found = page.currentPasswordContext()
            return found != nil
        }
        return try #require(found)
    }

    func reload() async throws {
        page.reload()
        try await waitUntil { [page] in !page.isLoading }
    }

    func fill(focus: FocusMessage, token: String) async throws {
        let payload: [String: Any] = [
            "usernameFieldID": focus.usernameFieldID ?? "",
            "passwordFieldIDs": focus.passwordFieldIDs,
            "username": "fixture-user@example.invalid",
            "password": "fixture-dummy-value",
            "highlightColor": "#E8F5E9",
            "submitAfterFill": false,
            "documentToken": token
        ]
        let payloadJSON = try #require(String(
            data: JSONSerialization.data(withJSONObject: payload),
            encoding: .utf8
        ))
        _ = try await evaluatePassword(
            "window.__oraPasswordManager.fillCredentials(\(payloadJSON)); true"
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 80 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError.timedOut
    }

    enum HarnessError: Error {
        case timedOut
    }
}

private struct FocusMessage: Decodable {
    let fieldKind: String
    let usernameFieldID: String?
    let passwordFieldIDs: [String]
}

@MainActor
private final class MessageRecorder: BrowserPageDelegate {
    private(set) var passwordMessages: [String] = []

    var focusMessages: [FocusMessage] {
        passwordMessages.compactMap { body in
            guard let data = body.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  envelope.type == "focus"
            else { return nil }
            return envelope.focus
        }
    }

    func browserPage(_ page: BrowserPage, didReceiveScriptMessage message: BrowserScriptMessage) {
        if message.name == PasswordBridge.handlerName, let body = message.body as? String {
            passwordMessages.append(body)
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let focus: FocusMessage?
    }
}

// MARK: - Fixtures

private enum FixtureSite {
    struct Site {
        let mainURL: URL
    }

    static func loginPage() throws -> Site {
        let directory = try makeDirectory()
        let main = directory.appendingPathComponent("login.html")
        try formHTML.write(to: main, atomically: true, encoding: .utf8)
        return Site(mainURL: main)
    }

    static func iframePage() throws -> Site {
        let directory = try makeDirectory()
        let frame = directory.appendingPathComponent("frame.html")
        try formHTML.write(to: frame, atomically: true, encoding: .utf8)
        let main = directory.appendingPathComponent("main.html")
        let html = """
        <!doctype html><html><body>
        <iframe src="frame.html" style="width:600px;height:300px"></iframe>
        </body></html>
        """
        try html.write(to: main, atomically: true, encoding: .utf8)
        return Site(mainURL: main)
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static let formHTML = """
    <!doctype html><html><body>
    <form action="/login" method="post">
      <input id="user" name="username" type="text" autocomplete="username"
             style="width:240px;height:24px">
      <input id="pw" name="password" type="password" autocomplete="current-password"
             style="width:240px;height:24px">
      <button type="submit">Sign in</button>
    </form>
    </body></html>
    """
}
