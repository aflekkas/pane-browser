// spec: §6 (Pane boring floor — cert errors) / §1 (native interstitials only)
import CryptoKit
import Foundation
import Security

/// Scope of a certificate exception. Two exceptions in different scopes never
/// satisfy each other: profile (Ora Space / data-store) isolation is part of
/// the key, and every exception is additionally bound to one session.
struct CertificateExceptionScope: Hashable, Sendable {
    var profileID: String?
    var sessionID: String?

    init(profileID: String? = nil, sessionID: String? = nil) {
        self.profileID = profileID
        self.sessionID = sessionID
    }

    /// Session-only scope with no profile binding (legacy/single-profile use).
    static let session = CertificateExceptionScope()

    var storageKey: String {
        "\(profileID ?? "-")|\(sessionID ?? "-")"
    }
}

/// Exact identity of one exception: normalised host + port + leaf SHA-256 +
/// scope. Never a wildcard, never host-only, never fingerprint-only.
struct CertificateExceptionKey: Hashable, Sendable {
    var host: String
    var port: Int
    var fingerprint: String
    var scope: CertificateExceptionScope

    init(host: String, port: Int, fingerprint: String, scope: CertificateExceptionScope) {
        self.host = CertificateExceptions.normalizedHost(host)
        self.port = CertificateExceptions.normalizedPort(port)
        self.fingerprint = CertificateExceptions.normalizedFingerprint(fingerprint)
        self.scope = scope
    }

    var storageKey: String {
        "\(scope.storageKey)|\(host)|\(port)|\(fingerprint)"
    }
}

enum CertificateTrustSeverity: Equatable, Sendable {
    case red
    case amber
}

enum CertificateTrustDecision: Equatable, Sendable {
    /// Trust evaluated valid; let WebKit proceed normally.
    case performDefaultHandling
    /// An exact session exception matches; use the trust credential.
    case useCredential
    /// Invalid trust with a known fingerprint and no exception; ask the user.
    case requiresUserDecision
    /// Fail closed: no trust object or no usable certificate identity.
    case cancel
}

/// Session-scoped, in-memory certificate exceptions. Nothing is persisted and
/// nothing survives relaunch; there is no permanent-trust API by design.
final class CertificateExceptions: @unchecked Sendable {
    static let shared = CertificateExceptions()

    private let lock = NSLock()
    private var allowed: Set<String> = []

    init() {}

    // MARK: - Normalisation

    static func normalizedHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value
    }

    static func normalizedPort(_ port: Int) -> Int {
        port > 0 ? port : 443
    }

    /// Lowercase hex with separators removed; empty when not 64 hex chars.
    static func normalizedFingerprint(_ fingerprint: String) -> String {
        let hex = fingerprint.lowercased().filter(\.isHexDigit)
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return "" }
        return hex
    }

    static func isValidFingerprint(_ fingerprint: String) -> Bool {
        !normalizedFingerprint(fingerprint).isEmpty
    }

    // MARK: - Store

    func isAllowed(host: String, port: Int, fingerprint: String, scope: CertificateExceptionScope) -> Bool {
        let key = CertificateExceptionKey(host: host, port: port, fingerprint: fingerprint, scope: scope)
        guard !key.host.isEmpty, !key.fingerprint.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return allowed.contains(key.storageKey)
    }

    /// Records an exception for this session only. Invalid identities are
    /// refused (fail closed) rather than stored as a broad bypass.
    @discardableResult
    func allowForSession(host: String, port: Int, fingerprint: String, scope: CertificateExceptionScope) -> Bool {
        let key = CertificateExceptionKey(host: host, port: port, fingerprint: fingerprint, scope: scope)
        guard !key.host.isEmpty, !key.fingerprint.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        allowed.insert(key.storageKey)
        return true
    }

    func clear(scope: CertificateExceptionScope) {
        lock.lock()
        defer { lock.unlock() }
        allowed = allowed.filter { !$0.hasPrefix(scope.storageKey + "|") }
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        allowed.removeAll()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return allowed.count
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed.isEmpty
    }

    // MARK: - Fingerprint + evaluation

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(ofCertificateData der: Data) -> String {
        sha256Hex(der)
    }

    static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        return sha256Hex(SecCertificateCopyData(leaf) as Data)
    }

    static func chainSummary(_ trust: SecTrust) -> [String] {
        guard let certs = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return [] }
        return certs.map { SecCertificateCopySubjectSummary($0) as String? ?? "(unnamed certificate)" }
    }

    /// Amber for failures that are usually misconfiguration; red otherwise.
    /// Guessing low on an unrecognised failure errs in the wrong direction.
    static func severity(for error: CFError?) -> CertificateTrustSeverity {
        guard let error else { return .red }
        switch CFErrorGetCode(error) {
        case Int(errSecCertificateExpired), Int(errSecCertificateNotValidYet), Int(errSecHostNameMismatch):
            return .amber
        default:
            return .red
        }
    }

    struct Evaluation: Sendable {
        var decision: CertificateTrustDecision
        var fingerprint: String?
        var severity: CertificateTrustSeverity
        var reason: String
        var chain: [String]
    }

    /// Pure decision for one server-trust challenge. No UI, no side effects:
    /// `.requiresUserDecision` is the caller's cue to show the native
    /// interstitial and, only on explicit proceed, call `allowForSession`.
    func evaluate(
        host: String,
        port: Int,
        trust: SecTrust?,
        scope: CertificateExceptionScope
    ) -> Evaluation {
        guard let trust else {
            return Evaluation(
                decision: .cancel,
                fingerprint: nil,
                severity: .red,
                reason: "The certificate could not be verified.",
                chain: []
            )
        }
        var cfError: CFError?
        if SecTrustEvaluateWithError(trust, &cfError) {
            return Evaluation(
                decision: .performDefaultHandling,
                fingerprint: Self.fingerprint(of: trust),
                severity: .red,
                reason: "",
                chain: Self.chainSummary(trust)
            )
        }
        let fingerprint = Self.fingerprint(of: trust)
        let reason = (cfError as Error?)?.localizedDescription ?? "The certificate could not be verified."
        let severity = Self.severity(for: cfError)
        let chain = Self.chainSummary(trust)
        // Fail closed if the certificate identity is unavailable: without a
        // fingerprint there is nothing exact to key an exception to.
        guard let fingerprint, Self.isValidFingerprint(fingerprint) else {
            return Evaluation(decision: .cancel, fingerprint: nil, severity: severity, reason: reason, chain: chain)
        }
        if isAllowed(host: host, port: port, fingerprint: fingerprint, scope: scope) {
            return Evaluation(
                decision: .useCredential,
                fingerprint: fingerprint,
                severity: severity,
                reason: reason,
                chain: chain
            )
        }
        return Evaluation(
            decision: .requiresUserDecision,
            fingerprint: fingerprint,
            severity: severity,
            reason: reason,
            chain: chain
        )
    }
}
