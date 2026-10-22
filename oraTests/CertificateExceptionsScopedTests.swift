import Foundation
@testable import Ora
import Security
import Testing

struct CertificateExceptionsScopedTests {
    // SHA-256("abc") and SHA-256("") — published FIPS 180-4 vectors.
    private let fingerprintA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private let fingerprintB = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private let scopeA = CertificateExceptionScope(profileID: "space-1", sessionID: "session-1")
    private let scopeB = CertificateExceptionScope(profileID: "space-2", sessionID: "session-1")

    @Test func sha256MatchesKnownVectors() {
        #expect(CertificateExceptions.sha256Hex(Data("abc".utf8)) == fingerprintA)
        #expect(CertificateExceptions.sha256Hex(Data()) == fingerprintB)
        #expect(CertificateExceptions.fingerprint(ofCertificateData: Data("abc".utf8)) == fingerprintA)
    }

    @Test func exactHostPortFingerprintAndScopeIsAllowed() {
        let store = CertificateExceptions()
        #expect(store.allowForSession(host: "example.com", port: 443, fingerprint: fingerprintA, scope: scopeA))
        #expect(store.isAllowed(host: "example.com", port: 443, fingerprint: fingerprintA, scope: scopeA))
        // Normalisation: case, trailing dot, colon-grouped fingerprint.
        #expect(store.isAllowed(host: "EXAMPLE.com.", port: 443, fingerprint: fingerprintA.uppercased(), scope: scopeA))
    }

    @Test func changedFingerprintPortHostOrScopeIsNotAllowed() {
        let store = CertificateExceptions()
        store.allowForSession(host: "example.com", port: 443, fingerprint: fingerprintA, scope: scopeA)

        #expect(!store.isAllowed(host: "example.com", port: 443, fingerprint: fingerprintB, scope: scopeA))
        #expect(!store.isAllowed(host: "example.com", port: 8443, fingerprint: fingerprintA, scope: scopeA))
        #expect(!store.isAllowed(host: "sub.example.com", port: 443, fingerprint: fingerprintA, scope: scopeA))
        #expect(!store.isAllowed(host: "example.com", port: 443, fingerprint: fingerprintA, scope: scopeB))
        #expect(
            !store.isAllowed(
                host: "example.com",
                port: 443,
                fingerprint: fingerprintA,
                scope: CertificateExceptionScope(profileID: "space-1", sessionID: "session-2")
            )
        )
    }

    @Test func invalidIdentityFailsClosedAndClearIsScopeBound() {
        let store = CertificateExceptions()
        #expect(!store.allowForSession(host: "example.com", port: 443, fingerprint: "not-a-fingerprint", scope: scopeA))
        #expect(!store.allowForSession(host: "", port: 443, fingerprint: fingerprintA, scope: scopeA))
        #expect(!store.isAllowed(host: "example.com", port: 443, fingerprint: "", scope: scopeA))
        #expect(store.isEmpty)

        store.allowForSession(host: "example.com", port: 443, fingerprint: fingerprintA, scope: scopeA)
        store.allowForSession(host: "example.com", port: 443, fingerprint: fingerprintA, scope: scopeB)
        store.clear(scope: scopeA)
        #expect(!store.isAllowed(host: "example.com", port: 443, fingerprint: fingerprintA, scope: scopeA))
        #expect(store.isAllowed(host: "example.com", port: 443, fingerprint: fingerprintA, scope: scopeB))
        store.clearAll()
        #expect(store.isEmpty)
    }

    @Test func missingTrustFailsClosed() {
        let store = CertificateExceptions()
        let evaluation = store.evaluate(host: "example.com", port: 443, trust: nil, scope: scopeA)
        #expect(evaluation.decision == .cancel)
        #expect(evaluation.fingerprint == nil)
    }

    @Test func severityMapsExpiredAndMismatchToAmberOthersToRed() {
        func cfError(_ code: Int) -> CFError {
            CFErrorCreate(nil, kCFErrorDomainOSStatus, code, nil)
        }
        #expect(CertificateExceptions.severity(for: cfError(Int(errSecCertificateExpired))) == .amber)
        #expect(CertificateExceptions.severity(for: cfError(Int(errSecCertificateNotValidYet))) == .amber)
        #expect(CertificateExceptions.severity(for: cfError(Int(errSecHostNameMismatch))) == .amber)
        #expect(CertificateExceptions.severity(for: cfError(Int(errSecInternalComponent))) == .red)
        #expect(CertificateExceptions.severity(for: nil) == .red)
    }
}
