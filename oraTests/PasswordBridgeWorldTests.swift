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

        let payload: [String: Any] = [
            "usernameFieldID": focus.usernameFieldID ?? "",
            "passwordFieldIDs": focus.passwordFieldIDs,
            "username": Self.dummyUsername,
            "password": Self.dummyPassword,
            "highlightColor": "#E8F5E9",
            "submitAfterFill": false
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

        _ = try await harness.evaluatePage(
            """
            (() => {
                const doc = document.querySelector('iframe').contentDocument;
                const field = doc && doc.querySelector('input[type=password]');
                if (field) { field.focus(); }
                return !!field;
            })()
            """
        )
        // Give any (incorrect) subframe delivery time to arrive.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(harness.recorder.passwordMessages.isEmpty)
    }

    @Test func validatorRejectsSubframeForgedAndStaleContexts() throws {
        let page = try #require(URL(string: "https://example.com/login"))
        let otherOrigin = try #require(URL(string: "https://evil.example.net/login"))
        let navigated = try #require(URL(string: "https://example.com/other"))

        #expect(PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: page, pageURL: page, committedURL: page
        ))
        // Subframe: never valid, even same-origin.
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: false, frameURL: page, pageURL: page, committedURL: page
        ))
        // Forged: frame origin disagrees with the native page URL.
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: otherOrigin, pageURL: page, committedURL: page
        ))
        // Stale: message from the pre-navigation page after commit moved on.
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: page, pageURL: navigated, committedURL: navigated
        ))
        // Missing native facts fail closed.
        #expect(!PasswordBridge.isValidMessage(
            isMainFrame: true, frameURL: nil, pageURL: page, committedURL: page
        ))
    }

    @Test func fillContextRejectsNavigationAwayFromOverlayOrigin() throws {
        let overlayHost = "example.com"
        let same = try #require(URL(string: "https://example.com/account"))
        let moved = try #require(URL(string: "https://evil.example.net/account"))

        #expect(PasswordBridge.isFillContextValid(currentURL: same, overlayHostname: overlayHost))
        #expect(!PasswordBridge.isFillContextValid(currentURL: moved, overlayHostname: overlayHost))
        #expect(!PasswordBridge.isFillContextValid(currentURL: nil, overlayHostname: overlayHost))
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

    func waitForFocusMessage() async throws -> FocusMessage {
        var found: FocusMessage?
        try await waitUntil { [recorder] in
            found = recorder.focusMessages.last
            return found != nil
        }
        return try #require(found)
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
