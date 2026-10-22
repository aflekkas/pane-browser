import Foundation
@preconcurrency import WebKit

/// WebKit can omit the current document's scroll from interactionState even
/// after a completed render. Keep its opaque bytes intact and supplement only
/// the main document's viewport, recorded in an isolated content world.
final class BrowserLifecycleCheckpoint: NSObject, WKScriptMessageHandler {
    private struct Payload: Codable {
        let interactionState: Data
        let url: String
        let scrollX: Double
        let scrollY: Double
    }

    private static let prefix = Data("PaneCheckpoint1\0".utf8)
    private static let handler = "paneLifecycleScroll"
    private static let world = WKContentWorld.world(name: "PaneLifecycleScroll")
    private weak var webView: WKWebView?
    private var position: (url: String, scrollX: Double, scrollY: Double)?
    private var restoring: Payload?

    func install(on webView: WKWebView) {
        self.webView = webView
        let controller = webView.configuration.userContentController
        controller.add(self, contentWorld: Self.world, name: Self.handler)
        controller.addUserScript(WKUserScript(source: """
        (() => {
          const report = () => window.webkit.messageHandlers.paneLifecycleScroll.postMessage({
            url: location.href, scrollX: scrollX, scrollY: scrollY
          });
          addEventListener('scroll', report, {passive:true});
          addEventListener('pageshow', report);
          report();
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView,
              let body = message.body as? [String: Any], let url = body["url"] as? String,
              url == webView.url?.absoluteString,
              let scrollX = body["scrollX"] as? Double, let scrollY = body["scrollY"] as? Double,
              scrollX.isFinite, scrollY.isFinite else { return }
        position = (url, scrollX, scrollY)
    }

    func capture(_ state: Data, url: URL?) -> Data? {
        guard let state = TabInteractionStateCodec.validated(state) else { return nil }
        guard let position, position.url == url?.absoluteString else { return state }
        let payload = Payload(
            interactionState: state,
            url: position.url,
            scrollX: position.scrollX,
            scrollY: position.scrollY
        )
        guard let encoded = try? PropertyListEncoder().encode(payload) else { return nil }
        return TabInteractionStateCodec.validated(Self.prefix + encoded)
    }

    func prepareRestore(_ data: Data) -> Data? {
        restoring = nil
        guard data.starts(with: Self.prefix) else { return TabInteractionStateCodec.validated(data) }
        guard let payload = try? PropertyListDecoder().decode(Payload.self, from: data.dropFirst(Self.prefix.count)),
              payload.scrollX.isFinite, payload.scrollY.isFinite,
              TabInteractionStateCodec.isValid(payload.interactionState) else { return nil }
        restoring = payload
        return payload.interactionState
    }

    func didCommit() {
        position = nil
    }

    func didFinish() {
        guard let payload = restoring, let webView else { return }
        restoring = nil
        guard webView.url?.absoluteString == payload.url,
              let encodedURL = try? JSONEncoder().encode(payload.url),
              let literal = String(data: encodedURL, encoding: .utf8) else { return }
        // The URL guard also runs inside the evaluated document. A replacement
        // navigation cannot receive the old document's scroll position.
        webView.evaluateJavaScript("""
        requestAnimationFrame(() => {
          if (location.href === \(literal)) scrollTo(\(payload.scrollX), \(payload.scrollY));
        }); true;
        """, in: nil, in: Self.world, completionHandler: nil)
    }

    func supersede() {
        restoring = nil
        position = nil
    }

    func teardown() {
        supersede()
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.handler,
            contentWorld: Self.world
        )
        webView = nil
    }
}
