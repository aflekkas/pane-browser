// spec: §6 (Pane boring floor — HTTP auth + cert errors)
import AppKit
import Foundation

/// Single entry for navigation AND download auth challenges. Certificate
/// decisions delegate to `CertificateExceptions.evaluate` (exact
/// host+port+fingerprint+scope, session only, fail closed when no
/// fingerprint is available); no persistent trust is ever granted.
@MainActor
enum BrowserAuthHandler {
    static func respond(
        to challenge: URLAuthenticationChallenge,
        window: NSWindow?,
        scope: CertificateExceptionScope,
        exceptions: CertificateExceptions = .shared,
        presentCertificateDecision: ((CertificateExceptions.Evaluation, @escaping (Bool) -> Void) -> Void)? = nil
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            await serverTrust(
                challenge,
                scope: scope,
                exceptions: exceptions,
                presentCertificateDecision: presentCertificateDecision,
                window: window
            )
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            await basicAuth(challenge, window: window)
        default:
            (.performDefaultHandling, nil)
        }
    }

    private static func basicAuth(
        _ challenge: URLAuthenticationChallenge,
        window: NSWindow?
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.previousFailureCount < 3 else { return (.cancelAuthenticationChallenge, nil) }
        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.messageText = "Sign in to \(space.host)"
        alert.informativeText = space.realm.map { "Realm: \($0)" } ?? "This site requires a username and password."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        stack.orientation = .vertical
        stack.spacing = 6
        let user = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        user.placeholderString = "Username"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        pass.placeholderString = "Password"
        stack.addArrangedSubview(user)
        stack.addArrangedSubview(pass)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = user
        let response: NSApplication.ModalResponse = if let window {
            await withCheckedContinuation { continuation in
                let once = OnceCompletion<NSApplication.ModalResponse>(continuation.resume(returning:))
                alert.beginSheetModal(for: window) { once.call($0) }
            }
        } else {
            alert.runModal()
        }
        guard response == .alertFirstButtonReturn, !user.stringValue.isEmpty else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (
            .useCredential,
            URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession)
        )
    }

    private static func serverTrust(
        _ challenge: URLAuthenticationChallenge,
        scope: CertificateExceptionScope,
        exceptions: CertificateExceptions,
        presentCertificateDecision: ((CertificateExceptions.Evaluation, @escaping (Bool) -> Void) -> Void)?,
        window: NSWindow?
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let evaluation = exceptions.evaluate(host: space.host, port: space.port, trust: space.serverTrust, scope: scope)
        switch evaluation.decision {
        case .performDefaultHandling:
            return (.performDefaultHandling, nil)
        case .useCredential:
            guard let trust = space.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
            return (.useCredential, URLCredential(trust: trust))
        case .cancel:
            return (.cancelAuthenticationChallenge, nil)
        case .requiresUserDecision:
            let allowed: Bool = if let presentCertificateDecision {
                await withCheckedContinuation { continuation in
                    let once = OnceCompletion<Bool>(continuation.resume(returning:))
                    presentCertificateDecision(evaluation) { once.call($0) }
                }
            } else {
                await fallbackAlert(evaluation: evaluation, window: window)
            }
            guard allowed,
                  let fingerprint = evaluation.fingerprint,
                  exceptions.allowForSession(
                      host: space.host,
                      port: space.port,
                      fingerprint: fingerprint,
                      scope: scope
                  ),
                  let trust = space.serverTrust
            else { return (.cancelAuthenticationChallenge, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    /// Fallback when no tab interstitial is available: critical alert,
    /// proceed is the second button and never the default.
    private static func fallbackAlert(evaluation: CertificateExceptions.Evaluation, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "This Connection Is Not Private"
        alert.informativeText = evaluation.reason
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Continue for This Session")
        if let window {
            let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                let once = OnceCompletion<NSApplication.ModalResponse>(continuation.resume(returning:))
                alert.beginSheetModal(for: window) { response in once.call(response) }
            }
            return response == NSApplication.ModalResponse.alertSecondButtonReturn
        }
        return alert.runModal() == NSApplication.ModalResponse.alertSecondButtonReturn
    }
}
