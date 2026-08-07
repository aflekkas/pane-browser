// spec: §5
import Foundation
import AppKit
import PaneCore
import PaneUI

/// spec §5 claims a SwiftUI `List` "with 200 rows and drag reordering will
/// stutter, and the sidebar is the one surface where stutter is unforgivable".
///
/// That is an assertion about AppKit being fast enough, and it was never
/// measured. This measures it: build 200 rows, scroll the whole height, and
/// report per-frame layout cost. A claim in a spec that nothing checks is a
/// claim that will quietly stop being true.
@MainActor
public enum ScrollBench {
    /// 60fps is 16.67ms. Budget half of it for the sidebar, since the frame
    /// also has to composite web content.
    public static let FRAME_BUDGET_MS = 8.0

    public static func run(rows: Int = 200) async -> Int32 {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-scroll-\(UUID().uuidString).sqlite").path
        let c = BrowserWindowController(storePath: path, restoreSession: false)
        c.window?.setContentSize(NSSize(width: 1280, height: 900))
        c.window?.orderFront(nil)

        // Populate across all three sections, so the measurement covers the
        // essentials grid and the two lists rather than one uniform case.
        for i in 0..<rows {
            let kind: TabKind = i < 12 ? .essential : (i < 60 ? .pinned : .ephemeral)
            c.dispatch(.newTab(kind: kind))
            c.dispatch(.navigate("https://example.com/row\(i)"))
        }
        try? await Task.sleep(for: .seconds(2))

        guard let outline = c.sidebarOutlineViewForBench else {
            FileHandle.standardError.write(Data("scroll: no outline view\n".utf8))
            return 1
        }

        // Force a full layout pass per step and time it. This measures OUR
        // cost — row construction and layout — not the window server's.
        var samples: [Double] = []
        let clock = ContinuousClock()
        let steps = 60
        let total = max(1, outline.bounds.height - 400)
        for s in 0..<steps {
            let y = total * CGFloat(s) / CGFloat(steps)
            let start = clock.now
            outline.scroll(NSPoint(x: 0, y: y))
            outline.layoutSubtreeIfNeeded()
            outline.displayIfNeeded()
            samples.append(Bench.milliseconds(clock.now - start))
        }

        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
        let worst = samples.last ?? 0
        let r3: (Double) -> Double = { ($0 * 1000).rounded() / 1000 }
        let payload: [String: Any] = [
            "rec": "bench", "metric": "sidebar_scroll_frame_ms",
            "rows": c.tabCount, "steps": steps,
            "p50_ms": r3(p50), "p95_ms": r3(p95), "max_ms": r3(worst),
            "budget_ms": FRAME_BUDGET_MS,
            "pass": p95 < FRAME_BUDGET_MS,
        ]
        let json = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        FileHandle.standardOutput.write(json); FileHandle.standardOutput.write(Data("\n".utf8))
        return p95 < FRAME_BUDGET_MS ? 0 : 1
    }
}
