// spec: §8
import Foundation
import AppKit
import WebKit
import PaneWeb

/// Milestone A′. Spec §8: *"Build drm-probe.html first… five minutes instead of
/// a week of manual testing."*
///
/// Loads the probe page in a real Pane-configured WKWebView — same
/// `applicationNameForUserAgent`, same configuration — and reports which key
/// systems the engine actually grants.
@MainActor
public enum DRMProbe {
    public static func run(fixture: URL) async -> Int32 {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.orderBack(nil)
        let e = WKWebEngine()
        e.webView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView?.addSubview(e.webView)
        e.webView.loadFileURL(fixture, allowingReadAccessTo: fixture.deletingLastPathComponent())

        // Poll for the page to finish its async probes rather than guessing a
        // sleep duration — a fixed sleep that is too short reports "unavailable"
        // for something that merely had not resolved yet.
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            let done = try? await e.webView.evaluateJavaScript("window.__paneDRM && window.__paneDRM.done === true") as? Bool
            if done == true { break }
        }
        guard let raw = try? await e.webView.evaluateJavaScript("JSON.stringify(window.__paneDRM || null)") as? String,
              raw != "null" else {
            FileHandle.standardError.write(Data("drm-probe: page never reported\n".utf8))
            return 1
        }
        FileHandle.standardOutput.write(Data(raw.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    }
}
