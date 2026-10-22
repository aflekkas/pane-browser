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
    private var restoreID: UUID?
    var hasPendingRestore: Bool {
        restoring != nil
    }

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
        if let acknowledgement = body["restoreID"] as? String {
            // Only this assignment can release its pending viewport restore.
            guard restoring != nil, acknowledgement == restoreID?.uuidString else { return }
            restoring = nil
            restoreID = nil
        } else if restoring != nil {
            // Ignore the restored document's initial zero-position reports.
            return
        }
        position = (url, scrollX, scrollY)
    }

    func capture(_ state: Data, url: URL?) -> Data? {
        guard !hasPendingRestore, let state = TabInteractionStateCodec.validated(state) else { return nil }
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
        supersede()
        guard data.starts(with: Self.prefix) else { return TabInteractionStateCodec.validated(data) }
        guard let payload = try? PropertyListDecoder().decode(Payload.self, from: data.dropFirst(Self.prefix.count)),
              payload.scrollX.isFinite, payload.scrollY.isFinite,
              TabInteractionStateCodec.isValid(payload.interactionState) else { return nil }
        restoring = payload
        restoreID = UUID()
        return payload.interactionState
    }

    func didCommit() {
        position = nil
    }

    func didFinish() {
        guard let payload = restoring, let restoreID, let webView else { return }
        guard webView.url?.absoluteString == payload.url else { supersede()
            return
        }
        guard let encodedURL = try? JSONEncoder().encode(payload.url),
              let literal = String(data: encodedURL, encoding: .utf8) else { return }
        // WebKit can apply its native scroll after didFinish, so wait for the
        // rendering frame. Hidden views suspend frames: keep the authoritative
        // checkpoint pending until this operation acknowledges actual application.
        // A replacement document/assignment cannot acknowledge an obsolete token.
        webView.evaluateJavaScript("""
        (() => {
        const operation = { id: "\(restoreID.uuidString)" };
        globalThis.__paneLifecycleViewportRestore = operation;
        operation.frame = requestAnimationFrame(() => {
          if (globalThis.__paneLifecycleViewportRestore !== operation || location.href !== \(literal)) return;
          delete globalThis.__paneLifecycleViewportRestore;
          scrollTo(\(payload.scrollX), \(payload.scrollY));
          window.webkit.messageHandlers.paneLifecycleScroll.postMessage({
            url: location.href, scrollX: scrollX, scrollY: scrollY,
            restoreID: "\(restoreID.uuidString)"
          });
        });
        })(); true;
        """, in: nil, in: Self.world, completionHandler: nil)
    }

    func supersede() {
        if let restoreID {
            webView?.evaluateJavaScript("""
            if (globalThis.__paneLifecycleViewportRestore?.id === "\(restoreID.uuidString)") {
              cancelAnimationFrame(globalThis.__paneLifecycleViewportRestore.frame);
              delete globalThis.__paneLifecycleViewportRestore;
            } true;
            """, in: nil, in: Self.world, completionHandler: nil)
        }
        restoring = nil
        restoreID = nil
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
