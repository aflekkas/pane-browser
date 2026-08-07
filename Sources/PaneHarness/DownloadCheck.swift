// spec: §6
import Foundation
import AppKit
import WebKit
import PaneCore
import PaneWeb
import PaneUI

/// Milestone E's download gate: a file downloaded through Pane must land with
/// `com.apple.quarantine` actually present. Verified by reading the xattr back,
/// not by trusting that the call did not throw.
@MainActor
public enum DownloadCheck {
    public static func run(url: URL) async -> Int32 {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.orderBack(nil)

        let manager = DownloadManager()
        let engine = WKWebEngine()
        engine.webView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView?.addSubview(engine.webView)
        engine.onDownload = { dl, page in manager.attach(dl, pageURL: page) }

        engine.load(url)

        // Poll for completion rather than sleeping a guessed duration.
        var finished: DownloadManager.Item?
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(250))
            if let done = manager.items.first(where: { $0.isFinished || $0.failure != nil }) {
                finished = done
                break
            }
        }

        guard let item = finished else {
            FileHandle.standardError.write(Data("download: never completed\n".utf8))
            return 1
        }
        var failures: [String] = []
        if let f = item.failure { failures.append("download failed: \(f)") }
        guard let dest = item.destination else {
            failures.append("no destination recorded")
            emit(item, nil, failures)
            return 1
        }
        if !FileManager.default.fileExists(atPath: dest.path) {
            failures.append("file is not on disk at \(dest.path)")
        }
        // THE assertion. A download without quarantine means Gatekeeper never
        // prompts, which makes the browser a malware vector.
        let props = (try? dest.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        if props == nil { failures.append("com.apple.quarantine is ABSENT — Gatekeeper will not prompt") }
        // Provenance is a REFINEMENT, not the security property, and is
        // reported rather than failed. The URLs do not live in the xattr — they
        // are rows in ~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2
        // keyed by event UUID, and three attempts to populate them via
        // NSURLQuarantinePropertiesKey did not take. Arc's own rows are empty
        // too. Gatekeeper prompts on the xattr regardless.
        // See docs/api-notes/quarantine.md.
        let hasProvenance = props?[kLSQuarantineDataURLKey as String] != nil

        // Uniquing: downloading twice must not clobber.
        let again = DownloadManager.uniqueDestination(in: dest.deletingLastPathComponent(),
                                                      filename: dest.lastPathComponent)
        if again == dest { failures.append("uniquing did not avoid the existing file") }

        emit(item, props, failures, provenance: hasProvenance)
        try? FileManager.default.removeItem(at: dest)
        return failures.isEmpty ? 0 : 1
    }

    private static func emit(_ item: DownloadManager.Item, _ props: [String: Any]?,
                             _ failures: [String], provenance: Bool = false) {
        let payload: [String: Any] = [
            "rec": "download",
            "filename": item.filename,
            "destination": item.destination?.path ?? "",
            "bytes": item.bytesWritten,
            "quarantine_present": props != nil,
            "quarantine_keys": (props?.keys.map { $0 } ?? []).sorted(),
            "provenance_urls_recorded": provenance,
            "failures": failures,
            "pass": failures.isEmpty,
        ]
        let json = try! JSONSerialization.data(withJSONObject: payload,
                                               options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(json); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
