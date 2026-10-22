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
        operation: BrowserAuthenticationOperation,
        dismissCertificateDecision: ((UUID) -> Void)? = nil,
        exceptions: CertificateExceptions = .shared,
        presentCertificateDecision: ((CertificateExceptions.Evaluation, @escaping (Bool) -> Void) -> Void)? = nil
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard operation.isActive else { return (.cancelAuthenticationChallenge, nil) }
        return switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            await serverTrust(
                challenge,
                scope: scope,
                operation: operation,
                dismissCertificateDecision: dismissCertificateDecision,
                exceptions: exceptions,
                presentCertificateDecision: presentCertificateDecision,
                window: window
            )
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            await basicAuth(challenge, window: window, operation: operation)
        default:
            (.performDefaultHandling, nil)
        }
    }

    private static func basicAuth(
        _ challenge: URLAuthenticationChallenge,
        window: NSWindow?,
        operation: BrowserAuthenticationOperation
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
        let response = await present(alert, window: window, operation: operation)
        guard operation.isActive, response == .alertFirstButtonReturn, !user.stringValue.isEmpty else {
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
        operation: BrowserAuthenticationOperation,
        dismissCertificateDecision: ((UUID) -> Void)?,
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
                    let once = OnceCompletion<Bool> { continuation.resume(returning: $0) }
                    operation.onCancel = {
                        dismissCertificateDecision?(evaluation.id)
                        once.call(false)
                    }
                    guard operation.isActive else { once.call(false)
                        return
                    }
                    presentCertificateDecision(evaluation) { once.call($0) }
                }
            } else {
                await fallbackAlert(evaluation: evaluation, window: window, operation: operation)
            }
            operation.onCancel = nil
            guard allowed, operation.isActive,
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
    private static func fallbackAlert(
        evaluation: CertificateExceptions.Evaluation, window: NSWindow?, operation: BrowserAuthenticationOperation
    ) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "This Connection Is Not Private"
        alert.informativeText = "\(evaluation.host):\(evaluation.port)\n\(evaluation.reason)"
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Continue for This Session")
        return await present(alert, window: window, operation: operation) == .alertSecondButtonReturn
    }

    /// No app-modal fallback: absent presentation ownership cancels safely.
    private static func present(
        _ alert: NSAlert, window: NSWindow?, operation: BrowserAuthenticationOperation
    ) async -> NSApplication.ModalResponse {
        guard let window, operation.isActive else { return .abort }
        return await withCheckedContinuation { continuation in
            let once = OnceCompletion<NSApplication.ModalResponse> { continuation.resume(returning: $0) }
            operation.onCancel = { [weak window] in
                window?.endSheet(alert.window, returnCode: .abort)
                alert.window.orderOut(nil)
                once.call(.abort)
            }
            alert.beginSheetModal(for: window) { response in
                operation.onCancel = nil
                once.call(operation.isActive ? response : .abort)
            }
        }
    }
}
