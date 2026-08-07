// spec: §7
import Foundation
import PaneCore
import PaneHarness

/// spec §7 — the parts of the vault that can be checked without prompting for
/// Touch ID. Reading a secret deliberately requires user presence, so a
/// headless check cannot exercise it; what IS checked is the origin policy,
/// which is where a mistake would be silent and dangerous.
public func vaultChecks(_ check: Check) {
    check.suite("Vault — origin key is https-only") { e in
        // A credential saved on https must never be offered over http: an
        // attacker who can serve plaintext for the host would otherwise harvest
        // it just by asking.
        e.that(CredentialVault.originKey(for: URL(string: "https://example.com/login")!) == "example.com",
               "https resolves to a bare host")
        e.that(CredentialVault.originKey(for: URL(string: "http://example.com/login")!) == nil,
               "plain http gets NO origin key, so nothing can be stored or offered")
        e.that(CredentialVault.originKey(for: URL(string: "http://localhost:8731/form")!) != nil,
               "localhost is exempt — development would be impossible otherwise")
        e.that(CredentialVault.originKey(for: URL(string: "http://127.0.0.1:8731/form")!) != nil,
               "and so is the loopback address")
    }

    check.suite("Vault — port is part of the origin") { e in
        e.equal(CredentialVault.originKey(for: URL(string: "https://example.com:8443/")!),
                "example.com:8443",
                "a non-default port is part of the identity, not decoration")
        e.equal(CredentialVault.originKey(for: URL(string: "https://example.com:443/")!),
                "example.com",
                "the default port is not, so it cannot produce two keys for one site")
    }

    check.suite("Vault — subdomains are distinct origins") { e in
        e.that(CredentialVault.originKey(for: URL(string: "https://mail.example.com/")!)
                != CredentialVault.originKey(for: URL(string: "https://example.com/")!),
               "a subdomain is a different origin — never share credentials up or down")
    }

    // Write/list/delete round trip. No secret is READ, so no Touch ID prompt.
    check.suite("Vault — save, list and delete round trip") { e in
        let vault = CredentialVault()
        let profile = "check-\(UUID().uuidString)"
        let origin = "vault-check.invalid"
        do {
            try vault.save(origin: origin, username: "alice",
                           password: "hunter2", profileID: profile)
            try vault.save(origin: origin, username: "bob",
                           password: "hunter3", profileID: profile)
        } catch {
            e.that(false, "save threw: \(error)")
            return
        }
        let listed = vault.credentials(origin: origin, profileID: profile)
        e.equal(listed.count, 2, "both usernames are listed WITHOUT prompting for a secret")
        e.that(listed.contains { $0.username == "alice" }, "alice is present")
        e.that(listed.contains { $0.username == "bob" }, "bob is present")

        // Per-profile isolation: the same origin under a different profile
        // must be empty. This is the vault half of §3's isolation promise.
        let other = vault.credentials(origin: origin, profileID: "different-profile")
        e.equal(other.count, 0, "another profile sees none of them")

        e.that(vault.delete(origin: origin, username: "alice", profileID: profile), "delete alice")
        e.equal(vault.credentials(origin: origin, profileID: profile).count, 1, "one left")
        _ = vault.delete(origin: origin, username: "bob", profileID: profile)
        e.equal(vault.credentials(origin: origin, profileID: profile).count, 0, "cleaned up")
    }
}
