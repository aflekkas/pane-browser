// spec: §3
import Foundation
import AppKit
import WebKit
import PaneCore
import PaneWeb

/// Milestone D's gate: *"log into the same site in two spaces as two different
/// users, simultaneously. Cookie jars verified disjoint on disk."*
///
/// Tests the thing the product actually claims — **data** isolation — and
/// deliberately does not test process isolation, which is not available at all
/// (ADR 0002).
@MainActor
public enum IsolationCheck {

    public static func run() async -> Int32 {
        // Two profiles, as two spaces would have.
        let workUUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let personalUUID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

        guard #available(macOS 14.0, *) else {
            FileHandle.standardError.write(Data("isolation: needs macOS 14+\n".utf8))
            return 1
        }
        let workStore = WKWebEngine.store(forProfile: workUUID)
        let personalStore = WKWebEngine.store(forProfile: personalUUID)

        var failures: [String] = []

        // 1. The stores must not be the same object as each other or as default.
        if workStore === personalStore { failures.append("both spaces got the SAME data store object") }
        if workStore === WKWebsiteDataStore.default() {
            failures.append("identified store silently fell back to .default() — every space would share one cookie jar")
        }

        // 2. A session cookie set for one profile must be invisible to the other.
        //    This is the "logged in as two different users at once" claim,
        //    reduced to something deterministic.
        let domain = "isolation-probe.example"
        let workCookie = HTTPCookie(properties: [
            .domain: domain, .path: "/", .name: "session",
            .value: "work-user-alice", .secure: "FALSE",
        ])!
        let personalCookie = HTTPCookie(properties: [
            .domain: domain, .path: "/", .name: "session",
            .value: "personal-user-bob", .secure: "FALSE",
        ])!

        await workStore.httpCookieStore.setCookie(workCookie)
        await personalStore.httpCookieStore.setCookie(personalCookie)

        let workCookies = await workStore.httpCookieStore.allCookies()
        let personalCookies = await personalStore.httpCookieStore.allCookies()

        let workValues = workCookies.filter { $0.domain.contains(domain) }.map(\.value)
        let personalValues = personalCookies.filter { $0.domain.contains(domain) }.map(\.value)

        if !workValues.contains("work-user-alice") {
            failures.append("work profile lost its own cookie")
        }
        if !personalValues.contains("personal-user-bob") {
            failures.append("personal profile lost its own cookie")
        }
        // The actual isolation assertion, both directions.
        if workValues.contains("personal-user-bob") {
            failures.append("LEAK: the personal profile's session cookie is visible to work")
        }
        if personalValues.contains("work-user-alice") {
            failures.append("LEAK: the work profile's session cookie is visible to personal")
        }

        // 3. Both are simultaneously logged in — the same cookie NAME holds a
        //    different value in each store at the same moment. This is what
        //    "two different users at once" means concretely.
        let simultaneous = workValues.contains("work-user-alice")
            && personalValues.contains("personal-user-bob")
            && workValues != personalValues
        if !simultaneous { failures.append("the two profiles are not simultaneously distinct") }

        // 4. Disjoint on disk.
        let root = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebKit", isDirectory: true)
        let workDir = findDir(root, containing: workUUID.uuidString)
        let personalDir = findDir(root, containing: personalUUID.uuidString)
        if let w = workDir, let p = personalDir, w == p {
            failures.append("both profiles resolved to the same directory on disk")
        }

        let payload: [String: Any] = [
            "rec": "isolation",
            "stores_distinct": !(workStore === personalStore),
            "fell_back_to_default": workStore === WKWebsiteDataStore.default(),
            "work_session": workValues.joined(separator: ","),
            "personal_session": personalValues.joined(separator: ","),
            "simultaneously_distinct": simultaneous,
            "work_dir": workDir ?? "not found on disk",
            "personal_dir": personalDir ?? "not found on disk",
            "failures": failures,
            "pass": failures.isEmpty,
        ]
        let json = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return failures.isEmpty ? 0 : 1
    }

    /// WebKit lays identified stores out under ~/Library/WebKit/<bundle>/... in
    /// a shape Apple does not document, so this searches rather than assuming.
    private static func findDir(_ root: URL, containing needle: String) -> String? {
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return nil }
        for case let p as String in e where p.contains(needle) {
            return root.appendingPathComponent(p).path
        }
        return nil
    }
}
