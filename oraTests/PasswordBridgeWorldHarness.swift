import AppKit
@testable import Ora
import Testing
import WebKit

// MARK: - Harness

@MainActor
final class PasswordBridgeWorldHarness {
    let recorder = PasswordBridgeMessageRecorder()
    private let window: NSWindow
    let page: BrowserPage
    let webView: WKWebView
    let tap = PasswordBridgeNativeTap()

    /// - Parameter observeNativePosts: only for tests that must observe
    ///   real `WKFrameInfo` provenance at the native handler boundary
    ///   (subframe posts, SPA old-document probes). When false (default),
    ///   the production password-handler registration is left completely
    ///   untouched, so detection/fill tests exercise the shipped wiring.
    init(observeNativePosts: Bool = false) throws {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
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
        webView = try #require(page.contentView as? WKWebView)
        tap.page = page
        tap.recorder = recorder
        if observeNativePosts {
            let controller = webView.configuration.userContentController
            // A transparent tap captures real WebKit provenance and then invokes
            // the unchanged production handler synchronously, with the same message.
            controller.removeScriptMessageHandler(
                forName: PasswordBridge.handlerName,
                contentWorld: PasswordBridge.world
            )
            controller.add(tap, contentWorld: PasswordBridge.world, name: PasswordBridge.handlerName)
            controller.add(tap, contentWorld: PasswordBridge.world, name: PasswordBridgeNativeTap.readyHandler)
            controller.addUserScript(WKUserScript(
                source: """
                if (window !== window.top) {
                    window.webkit.messageHandlers.passwordBridgeFixtureReady.postMessage({
                        href: location.href,
                        hasForm: !!document.querySelector('form input[type=password]')
                    });
                }
                """,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false,
                in: PasswordBridge.world
            ))
        }
        page.contentView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView?.addSubview(page.contentView)
    }

    func close() {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: PasswordBridgeNativeTap.readyHandler, contentWorld: PasswordBridge.world
        )
        page.teardown()
        window.close()
    }

    func load(_ url: URL) async throws {
        let finished = recorder.finishedNavigationCount
        page.load(URLRequest(url: url))
        try await waitUntil("finished navigation to \(url); check native navigation errors") { [self] in
            recorder.finishedNavigationCount > finished && page.currentURL == url && !page.isLoading
        }
        _ = try await waitForContext()
        let hasForm = try await evaluatePage("!!document.querySelector('form input[type=password]')") as? Bool
        try #require(hasForm == true)
    }

    func appendFrame(url: URL) async throws -> WKFrameInfo {
        let count = tap.readyMessages.count
        let urlJSON = try Self.jsonLiteral(url.absoluteString)
        _ = try await evaluatePage("""
        (() => {
            const frame = document.createElement('iframe');
            frame.style = 'width:600px;height:300px';
            frame.src = \(urlJSON);
            document.body.appendChild(frame);
            return true;
        })()
        """)
        try await waitUntil("isolated-world iframe ready acknowledgement for \(url)") { [tap] in
            tap.readyMessages.count > count
        }
        let message = tap.readyMessages[count]
        let body = try #require(message.body as? [String: Any])
        try #require(body["hasForm"] as? Bool == true)
        try #require(body["href"] as? String == url.absoluteString)
        return message.frameInfo
    }

    func evaluate(_ script: String, frame: WKFrameInfo?, world: WKContentWorld) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: frame, in: world) { result in
                continuation.resume(with: result)
            }
        }
    }

    func postProbe(token: String, frame: WKFrameInfo? = nil) async throws -> PasswordBridgeNativeTap.Attempt {
        let identifier = UUID().uuidString
        let payload = try Self.jsonLiteral([
            "type": "fixtureProbe", "fixtureAttemptID": identifier, "documentToken": token
        ])
        let result = try await evaluate(
            "window.webkit.messageHandlers.passwordManager.postMessage(JSON.stringify(\(payload))); 'posted'",
            frame: frame, world: PasswordBridge.world
        ) as? String
        try #require(result == "posted")
        try await waitUntil("actual native password handler delivery for \(identifier)") { [tap] in
            tap.attempts[identifier] != nil
        }
        return try #require(tap.attempts[identifier])
    }

    static func jsonLiteral(_ value: Any) throws -> String {
        try #require(String(
            data: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8
        ))
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

    func waitForContext(afterGeneration: Int? = nil) async throws -> PasswordDocumentContext {
        var found: PasswordDocumentContext?
        try await waitUntil { [page] in
            found = page.currentPasswordContext()
            return found != nil && (afterGeneration == nil || found?.generation != afterGeneration)
        }
        return try #require(found)
    }

    func reload() async throws {
        let finished = recorder.finishedNavigationCount
        let oldContext = try await waitForContext()
        page.reload()
        try await waitUntil("reload finished") { [self] in
            recorder.finishedNavigationCount > finished && !page.isLoading
        }
        _ = try await waitForContext(afterGeneration: oldContext.generation)
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

    func waitUntil(_ description: String = "bridge event", _ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 80 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError.timedOut(description)
    }

    enum HarnessError: Error {
        case timedOut(String)
    }
}

typealias FocusMessage = PasswordBridgeFocusPayload

@MainActor
final class PasswordBridgeMessageRecorder: BrowserPageDelegate {
    private(set) var passwordMessages: [String] = []
    private(set) var finishedNavigationCount = 0
    private(set) var startedNavigationCount = 0

    func browserPage(_ page: BrowserPage, didUpdateNavigation event: BrowserNavigationEvent) {
        if event.phase == .finished {
            finishedNavigationCount += 1
        }
        if event.phase == .started {
            startedNavigationCount += 1
        }
    }

    var submitMessages: [PasswordBridgeSubmitPayload] {
        passwordMessages.compactMap { body in
            guard let data = body.data(using: .utf8),
                  let event = try? JSONDecoder().decode(PasswordBridgeEvent.self, from: data),
                  event.type == "submit" else { return nil }
            return event.submit
        }
    }

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

/// Observes entry and exit of BrowserPage's real native handler. It never
/// reconstructs a WKScriptMessage, overrides its frame facts, or decides validity.
@MainActor
final class PasswordBridgeNativeTap: NSObject, WKScriptMessageHandler {
    static let readyHandler = "passwordBridgeFixtureReady"
    weak var page: BrowserPage?
    weak var recorder: PasswordBridgeMessageRecorder?
    private(set) var readyMessages: [WKScriptMessage] = []
    private(set) var attempts: [String: Attempt] = [:]

    struct Attempt {
        let message: WKScriptMessage
        let forwarded: Bool
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == Self.readyHandler {
            readyMessages.append(message)
            return
        }
        let before = recorder?.passwordMessages.count
        page?.userContentController(controller, didReceive: message)
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = payload["fixtureAttemptID"] as? String else { return }
        attempts[identifier] = Attempt(message: message, forwarded: recorder?.passwordMessages.count != before)
    }
}
