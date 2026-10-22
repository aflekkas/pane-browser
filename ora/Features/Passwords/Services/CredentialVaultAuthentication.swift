import Foundation
import LocalAuthentication

protocol CredentialAuthenticationContext: AnyObject {
    var keychainContext: LAContext? { get }
    func canAuthenticate() -> Bool
    func evaluate(reason: String, reply: @escaping (Bool) -> Void)
    func invalidate()
}

final class SystemCredentialAuthenticationContext: CredentialAuthenticationContext {
    let context = LAContext()
    var keychainContext: LAContext? {
        context
    }

    func canAuthenticate() -> Bool {
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func evaluate(reason: String, reply: @escaping (Bool) -> Void) {
        context.localizedCancelTitle = "Cancel"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in reply(success) }
    }

    func invalidate() {
        context.invalidate()
    }
}

/// Serializes session state, including callbacks delivered on LA's private queue.
/// Each attempt replaces/revokes the previous session. Lock revokes pending AND completed contexts.
final class CredentialVaultAuthentication {
    private let lock = NSRecursiveLock()
    private let makeContext: () -> CredentialAuthenticationContext
    private var generation = UUID()
    private var context: CredentialAuthenticationContext?
    private var authenticated = false
    private var completion: ((Bool) -> Void)?

    init(makeContext: @escaping () -> CredentialAuthenticationContext = { SystemCredentialAuthenticationContext() }) {
        self.makeContext = makeContext
    }

    var isAuthenticated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authenticated
    }

    @MainActor
    func authenticate(reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            begin(reason: reason) { continuation.resume(returning: $0) }
        }
    }

    private func begin(reason: String, reply: @escaping (Bool) -> Void) {
        lock.lock()
        let previous = context
        let previousCompletion = completion
        let token = UUID()
        generation = token
        let next = makeContext()
        context = next
        authenticated = false
        completion = reply
        lock.unlock()
        previous?.invalidate()
        previousCompletion?(false)
        // Capability failure is NEVER permission to unlock, including on the legacy backend.
        guard next.canAuthenticate() else { finish(token: token, success: false)
            return
        }
        next.evaluate(reason: reason) { [weak self] success in self?.finish(token: token, success: success) }
    }

    private func finish(token: UUID, success: Bool) {
        lock.lock()
        guard generation == token, completion != nil else { lock.unlock()
            return
        }
        authenticated = success
        let callback = completion
        completion = nil
        let failedContext = success ? nil : context
        if !success {
            context = nil
        }
        lock.unlock()
        failedContext?.invalidate()
        callback?(success)
    }

    func invalidate() {
        lock.lock()
        generation = UUID()
        authenticated = false
        let previous = context
        let callback = completion
        context = nil
        completion = nil
        lock.unlock()
        previous?.invalidate()
        callback?(false)
    }

    /// Check both sides of a potentially blocking keychain read. Lock invalidates LAContext immediately;
    /// even a backend that ignores cancellation cannot return its secret after session revocation.
    func withAuthenticatedContext<T>(_ body: (LAContext?) throws -> T) throws -> T {
        lock.lock()
        guard authenticated, let context else { lock.unlock()
            throw VaultError.userCancelled
        }
        let token = generation
        lock.unlock()
        let result = try body(context.keychainContext)
        lock.lock()
        defer { lock.unlock() }
        guard authenticated, generation == token else { throw VaultError.userCancelled }
        return result
    }
}
