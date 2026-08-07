// spec: §1
import Foundation

/// Turns whatever the user typed in the address bar into something navigable.
/// Pure logic, no AppKit, no WebKit — so it is testable under `swift test`.
public enum URLNormalizer {
    /// A bare token is a search unless it looks like a host.
    public static func resolve(_ raw: String, searchTemplate: String = "https://duckduckgo.com/?q=%@") -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Explicit scheme wins outright.
        if let u = URL(string: s), let scheme = u.scheme, !scheme.isEmpty, u.host != nil || scheme == "about" || scheme == "file" {
            return u
        }
        if looksLikeHost(s), let u = URL(string: "https://\(s)") { return u }

        let q = s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        return URL(string: searchTemplate.replacingOccurrences(of: "%@", with: q))
    }

    /// A whitespace-free token with a dot and a plausible TLD, or localhost.
    /// Public so the checks can exercise it directly — this is the branch that
    /// decides "navigate" vs "search", and getting it wrong is the single most
    /// visible address-bar bug there is.
    public static func looksLikeHost(_ s: String) -> Bool {
        if s.contains(" ") { return false }
        let hostPart = s.split(separator: "/", maxSplits: 1).first.map(String.init) ?? s
        if hostPart == "localhost" || hostPart.hasPrefix("localhost:") { return true }
        guard let dot = hostPart.lastIndex(of: "."), dot != hostPart.startIndex else { return false }
        let tld = hostPart[hostPart.index(after: dot)...].prefix(while: { $0 != ":" })
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }

    /// What the address bar shows: the URL without the noise.
    public static func display(_ url: URL) -> String {
        var s = url.absoluteString
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") && s.filter({ $0 == "/" }).count == 1 { s.removeLast() }
        return s
    }
}
