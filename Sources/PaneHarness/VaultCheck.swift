// spec: §7
import Foundation
import AppKit
import WebKit
import PaneCore
import PaneWeb

/// spec §7 — proves the credential bridge works AND that it is invisible to
/// page script. The second half is the security property: if the page can see
/// the handler, a hostile site can impersonate the bridge.
@MainActor
public enum VaultCheck {
    public static func run(formURL: URL) async -> Int32 {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.orderBack(nil)
        let e = WKWebEngine()
        e.webView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView?.addSubview(e.webView)

        var detected: LoginFormInfo?
        e.onLoginForm = { info in if detected == nil { detected = info } }
        e.load(formURL)

        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if detected != nil { break }
        }

        var failures: [String] = []
        if detected == nil { failures.append("login form was never detected") }

        // THE security assertion: page script must not see the bridge.
        let pageSees = try? await e.webView.evaluateJavaScript(
            "(typeof window.__paneFill !== 'undefined') || (window.webkit && window.webkit.messageHandlers && typeof window.webkit.messageHandlers.paneCredentials !== 'undefined')")
        if (pageSees as? Bool) == true {
            failures.append("LEAK: page world can see the credential bridge")
        }

        // Fill, then read the values back FROM THE PAGE WORLD to prove the
        // isolated world's DOM writes actually crossed.
        let filled = await e.fillCredentials(username: "alice", password: "hunter2")
        if !filled { failures.append("fill returned false") }
        try? await Task.sleep(for: .milliseconds(400))
        let readBack = try? await e.webView.evaluateJavaScript(
            "document.querySelector('input[type=password]').value")
        if (readBack as? String) != "hunter2" {
            failures.append("fill did not reach the page DOM (got \(readBack ?? "nil"))")
        }
        let userBack = try? await e.webView.evaluateJavaScript(
            "document.querySelector('input[name=username]').value")
        if (userBack as? String) != "alice" {
            failures.append("username not filled (got \(userBack ?? "nil"))")
        }

        let payload: [String: Any] = [
            "rec": "vault",
            "detected": detected != nil,
            "detected_origin": detected?.origin ?? "",
            "page_can_see_bridge": (pageSees as? Bool) ?? false,
            "filled": filled,
            "protection": CredentialVault.availableProtection.rawValue,
            "failures": failures,
            "pass": failures.isEmpty,
        ]
        let json = try! JSONSerialization.data(withJSONObject: payload,
                                               options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(json); FileHandle.standardOutput.write(Data("\n".utf8))
        return failures.isEmpty ? 0 : 1
    }
}
