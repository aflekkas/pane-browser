// spec: §1
import Foundation
import PaneCore
import PaneHarness

// Pure-logic checks. No AppKit, no WebKit, no Xcode required.
let check = Check()

check.suite("URLNormalizer") { e in
    e.equal(URLNormalizer.resolve("example.com")?.absoluteString, "https://example.com",
            "a bare host becomes https")
    e.equal(URLNormalizer.resolve("localhost:8080")?.absoluteString, "https://localhost:8080",
            "localhost with a port is a host, not a search")
    e.equal(URLNormalizer.resolve("http://example.com")?.scheme, "http",
            "an explicit scheme is preserved")
    e.equal(URLNormalizer.resolve("how tall is nelson's column")?.host, "duckduckgo.com",
            "prose becomes a search, not a malformed URL")
    // Would otherwise resolve to https://3.14 — a real address-bar bug.
    e.that(URLNormalizer.looksLikeHost("3.14") == false,
           "a dotted token with a numeric TLD is not a host")
    e.that(URLNormalizer.looksLikeHost("example.com/a b") == false,
           "a token containing a space is never a host")
    e.equal(URLNormalizer.display(URL(string: "https://www.example.com/")!), "example.com",
            "display strips scheme, www and a lone trailing slash")
    e.equal(URLNormalizer.display(URL(string: "https://example.com/a/b")!), "example.com/a/b",
            "display keeps a real path")
    e.that(URLNormalizer.resolve("   ") == nil, "whitespace resolves to nothing")
}

tabModelChecks(check)

exit(check.run())
