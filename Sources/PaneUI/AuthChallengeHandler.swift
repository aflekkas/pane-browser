// spec: §6
import AppKit
import Security
import PaneCore

/// spec §6 — HTTP auth and TLS trust.
///
/// Both arrive through the same delegate callback, and the default when
/// unimplemented is `rejectProtectionSpace`, so an unhandled challenge fails
/// silently rather than loudly.
///
/// **Correction to spec §6**, from `docs/research/2026-08-07-boring-floor.md`:
/// the spec says to scope credentials to a per-profile `URLCredentialStorage`.
/// That is neither needed nor possible — WebKit's network process already
/// installs a per-identifier credential store when the data store has a
/// `dataStoreIdentifier`. Per-profile credential isolation is **automatic** with
/// `WKWebsiteDataStore(forIdentifier:)` and cannot be injected.
@MainActor
public enum AuthChallengeHandler {

    public static func respond(to challenge: URLAuthenticationChallenge,
                               window: NSWindow?) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {

        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            return await serverTrust(challenge, window: window)

        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            return await basicAuth(challenge, window: window)

        default:
            return (.performDefaultHandling, nil)
        }
    }

    // MARK: - HTTP auth

    private static func basicAuth(_ challenge: URLAuthenticationChallenge,
                                  window: NSWindow?) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Repeated failures mean the credentials are wrong; do not loop.
        guard challenge.previousFailureCount < 3 else { return (.cancelAuthenticationChallenge, nil) }

        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.messageText = "Sign in to \(space.host)"
        alert.informativeText = space.realm.map { "Realm: \($0)" }
            ?? "This site requires a username and password."
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

        let response = window.map { alert.beginSheetModal(for: $0) } == nil
            ? alert.runModal() : await sheet(alert, on: window!)
        guard response == .alertFirstButtonReturn, !user.stringValue.isEmpty else {
            return (.cancelAuthenticationChallenge, nil)
        }
        // .forSession, not .permanent: writing to the keychain here would be a
        // credential store, which is milestone F and is specced separately.
        let credential = URLCredential(user: user.stringValue,
                                       password: pass.stringValue,
                                       persistence: .forSession)
        return (.useCredential, credential)
    }

    // MARK: - Server trust (spec §6)

    private static func serverTrust(_ challenge: URLAuthenticationChallenge,
                                    window: NSWindow?) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            return (.cancelAuthenticationChallenge, nil)
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            return (.performDefaultHandling, nil)
        }

        let host = challenge.protectionSpace.host
        let fingerprint = Self.fingerprint(of: trust)

        // spec §6: exceptions are keyed by host AND cert SHA-256. Never
        // wildcard — an exception for one certificate must not carry over to a
        // different certificate on the same host, which is exactly the
        // substitution an attacker performs.
        if let fingerprint, CertExceptions.shared.isAllowed(host: host, sha256: fingerprint) {
            return (.useCredential, URLCredential(trust: trust))
        }

        let reason = (error as Error?)?.localizedDescription ?? "The certificate could not be verified."
        let allowed = await presentInterstitial(host: host, reason: reason,
                                                fingerprint: fingerprint, window: window)
        guard allowed, let fingerprint else { return (.cancelAuthenticationChallenge, nil) }

        // spec §6: "never permanent by default". Session-scoped.
        CertExceptions.shared.allowForSession(host: host, sha256: fingerprint)
        return (.useCredential, URLCredential(trust: trust))
    }

    static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return sha256Hex(der)
    }

    /// CommonCrypto is not exposed to Swift here, so this is a direct SHA-256.
    /// Small, self-contained, and avoids a dependency for one hash.
    static func sha256Hex(_ data: Data) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (8 * UInt64(i))) & 0xff)) }

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = chunk + i * 4
                w[i] = (UInt32(msg[o]) << 24) | (UInt32(msg[o+1]) << 16)
                     | (UInt32(msg[o+2]) << 8) | UInt32(msg[o+3])
            }
            for i in 16..<64 {
                let s0 = rr(w[i-15], 7) ^ rr(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = rr(w[i-2], 17) ^ rr(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rr(e, 6) ^ rr(e, 11) ^ rr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rr(a, 2) ^ rr(a, 13) ^ rr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }

    private static func rr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    /// spec §1 — a native, full-content interstitial. Never a web-rendered
    /// error page: that would put UI inside a renderer we do not trust, which
    /// is the exact attack the invariant exists to prevent.
    private static func presentInterstitial(host: String, reason: String,
                                            fingerprint: String?, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "This Connection Is Not Private"
        var detail = "Pane cannot verify the identity of “\(host)”.\n\n\(reason)"
        if let fingerprint {
            let pretty = stride(from: 0, to: min(fingerprint.count, 32), by: 4)
                .map { i -> String in
                    let s = fingerprint.index(fingerprint.startIndex, offsetBy: i)
                    let e = fingerprint.index(s, offsetBy: 4)
                    return String(fingerprint[s..<e]).uppercased()
                }.joined(separator: " ")
            detail += "\n\nCertificate SHA-256 begins:\n\(pretty)"
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Continue for This Session")
        // Destructive option is second and not the default: the safe action
        // must be the one that happens if the user just hits Return.
        if let window { return await sheet(alert, on: window) == .alertSecondButtonReturn }
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func sheet(_ alert: NSAlert, on window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { c in
            alert.beginSheetModal(for: window) { c.resume(returning: $0) }
        }
    }
}

/// spec §6 — per-host, per-certificate, session-scoped. Never wildcard, never
/// permanent by default.
@MainActor
public final class CertExceptions {
    public static let shared = CertExceptions()
    private var allowed: Set<String> = []
    private init() {}

    private func key(_ host: String, _ sha: String) -> String { "\(host)|\(sha)" }

    public func isAllowed(host: String, sha256: String) -> Bool {
        allowed.contains(key(host, sha256))
    }

    public func allowForSession(host: String, sha256: String) {
        allowed.insert(key(host, sha256))
    }

    public func clear() { allowed.removeAll() }
}
