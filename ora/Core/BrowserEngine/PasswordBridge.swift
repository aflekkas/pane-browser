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
    /// it came from the main frame, and that frame's request URL matches the
    /// URL the web view has actually committed/displayed. Anything else is a
    /// subframe handout attempt, a forged payload, or a stale message from a
    /// page that has already been navigated away from.
    static func isValidMessage(isMainFrame: Bool, frameURL: URL?, pageURL: URL?, committedURL: URL?) -> Bool {
        guard isMainFrame,
              let frameURL,
              let pageURL,
              let frameKey = originKey(for: frameURL),
              let pageKey = originKey(for: pageURL),
              frameKey == pageKey
        else {
            return false
        }
        if let committedURL, let committedKey = originKey(for: committedURL) {
            return committedKey == frameKey
        }
        return true
    }

    /// Fill may only run while the tab still shows the origin the overlay was
    /// created for. Checked again at fill time, after any async auth prompt,
    /// so a navigation in between cannot receive the credential.
    static func isFillContextValid(currentURL: URL?, overlayHostname: String) -> Bool {
        guard let currentURL,
              let host = currentURL.host?.lowercased(),
              !host.isEmpty
        else {
            return false
        }
        return host == overlayHostname.lowercased()
    }
}

extension BrowserScriptContentWorld {
    var wkContentWorld: WKContentWorld {
        switch self {
        case .page:
            .pageWorld
        case let .isolated(name):
            .world(name: name)
        }
    }
}
