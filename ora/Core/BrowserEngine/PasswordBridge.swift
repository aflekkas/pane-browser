import Foundation
import WebKit

/// Isolated content world for the privileged password-manager bridge.
///
/// The detection/fill script and its `passwordManager` message handler live
/// only in this world. Page script has its own global object, so it can
/// neither call the handler nor invoke the fill entry point. DOM reads and
/// writes still cross the boundary, which is all autofill needs. Every other
/// injected script (navigation listener, link hover, media hooks) stays in
/// the page world on purpose: those hooks must observe page globals.
enum PasswordBridge {
    static let handlerName = "passwordManager"
    static let worldName = "pane.passwords"

    static var world: WKContentWorld {
        .world(name: worldName)
    }

    static var contentWorld: BrowserScriptContentWorld {
        .isolated(name: worldName)
    }

    /// Origin identity used for native validation: scheme + host + non-default
    /// port. `file:` pages compare by path, since they have no host origin.
    static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return nil }
        if scheme == "file" {
            return "file://\(url.path)"
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        var key = "\(scheme)://\(host)"
        if let port = url.port {
            let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            if !isDefault {
                key += ":\(port)"
            }
        }
        return key
    }

    /// A password-bridge message is trustworthy only when WebKit itself says
    /// it came from the main frame of the exact document native code has
    /// registered: same page instance, same navigation generation, same
    /// full origin (scheme/host/effective port), same document URL, and
    /// the per-document token the isolated script announced at install.
    /// Missing provenance fails closed. Anything else is a subframe
    /// handout attempt, a forged payload, or a stale/queued message from a
    /// document that has already been navigated away from or reloaded.
    static func isValidMessage(
        isMainFrame: Bool,
        frameURL: URL?,
        pageURL: URL?,
        committedURL: URL?,
        payloadToken: String?,
        current: PasswordDocumentContext?
    ) -> Bool {
        guard isMainFrame,
              let current,
              let frameURL,
              let pageURL,
              let committedURL,
              let payloadToken,
              !payloadToken.isEmpty,
              payloadToken == current.documentToken,
              let frameKey = originKey(for: frameURL),
              frameKey == current.originKey,
              originKey(for: pageURL) == frameKey,
              originKey(for: committedURL) == frameKey,
              isSameDocument(frameURL, pageURL),
              isSameDocument(frameURL, committedURL),
              isSameDocument(frameURL, current.documentURL)
        else {
            return false
        }
        return true
    }

    /// Extracts the per-document token from a bridge payload without
    /// trusting any other field in it.
    static func payloadToken(from body: Any?) -> String? {
        guard let body = body as? String,
              let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["documentToken"] as? String
    }

    static func isBridgeReadyMessage(_ body: Any?) -> Bool {
        guard let body = body as? String,
              let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return object["type"] as? String == "bridgeReady"
    }

    /// Same document: identical scheme/host/port/path/query (fragment is
    /// not document identity). `/login` and `/other` on one origin differ.
    static func isSameDocument(_ lhs: URL, _ rhs: URL) -> Bool {
        func parts(_ url: URL) -> [String] {
            [
                url.scheme?.lowercased() ?? "",
                url.host?.lowercased() ?? "",
                String(url.port ?? -1),
                url.path,
                url.query ?? ""
            ]
        }
        return parts(lhs) == parts(rhs)
    }
}

/// Everything a fill/message decision is bound to. Captured natively at
/// overlay creation and re-derived at fill time; any navigation (including
/// a same-URL reload), page replacement, scheme downgrade, or port change
/// produces a different context and the operation must abort. `nil`
/// context (no registered document) fails closed.
struct PasswordDocumentContext: Equatable {
    let pageIdentity: ObjectIdentifier
    let generation: Int
    /// Full origin: scheme + host + effective (non-default) port.
    let originKey: String
    let documentURL: URL
    let documentToken: String
}

extension BrowserScriptContentWorld {
    var wkContentWorld: WKContentWorld {
        switch self {
        case .page:
            .page
        case let .isolated(name):
            .world(name: name)
        }
    }
}
