// spec: §4
import Foundation
import AppKit
import WebKit
import PaneCore
import PaneWeb

/// Milestone A's gate: `interactionState` restore p50 < 200 ms.
///
/// Spec §9 step 1 is explicit — *"If restore is not sub-200ms here, stop and
/// fix it."* This measures it rather than asserting it.
///
/// Timing uses `ContinuousClock`, never `Date`. NTP can step the wall clock
/// mid-run and produce negative durations in an unattended overnight loop
/// (harness design §7.13).
@MainActor
public enum Bench {
    /// spec §9 step 1. Not a suggestion — if restore misses this, stop and fix it.
    public static let THRESHOLD_MS = 200.0

    /// `Duration.components` splits into whole seconds plus a sub-second
    /// attoseconds remainder. Using attoseconds alone silently truncates
    /// anything past one second, and dividing it by 1e15 already yields
    /// milliseconds — double-scaling that was the first bug this bench found,
    /// in itself. Both halves, one conversion, once.
    static func milliseconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
    public static func restore(iterations: Int = 20, fixture: URL) async -> Int32 {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.orderBack(nil)

        // 1. Load the fixture once and capture its interaction state.
        let seed = WKWebEngine()
        seed.webView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window.contentView?.addSubview(seed.webView)
        guard await load(seed, fixture) else {
            FileHandle.standardError.write(Data("bench: seed page failed to load\n".utf8))
            return 1
        }
        // Let WebKit settle so the captured state includes scroll position.
        try? await Task.sleep(for: .milliseconds(400))
        guard let state = seed.captureInteractionState(), !state.isEmpty else {
            FileHandle.standardError.write(Data("bench: interactionState was empty\n".utf8))
            return 1
        }
        seed.webView.removeFromSuperview()

        // 2. Restore it N times, measuring each.
        var samples: [Double] = []
        var restoredScrollY: Double? = nil
        for _ in 0..<iterations {
            let e = WKWebEngine()
            e.webView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
            let clock = ContinuousClock()
            let start = clock.now
            // spec §4: assign BEFORE the view enters the hierarchy.
            e.restoreInteractionState(state)
            window.contentView?.addSubview(e.webView)
            _ = await finish(e)
            samples.append(milliseconds(clock.now - start))
            // Prove restore actually RESTORED rather than merely re-navigated.
            // A fast number on a feature that does not work is worse than a
            // slow one on a feature that does — check the last iteration's
            // scroll offset against what the fixture scrolled to.
            if restoredScrollY == nil {
                try? await Task.sleep(for: .milliseconds(300))
                restoredScrollY = try? await e.webView.evaluateJavaScript("window.scrollY") as? Double
            }
            e.webView.removeFromSuperview()
        }

        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
        let r3: (Double) -> Double = { ($0 * 1000).rounded() / 1000 }
        // The fixture scrolls to y=1200. Allow slack for layout rounding, but
        // require it to be genuinely restored, not zero.
        let scrollOK = (restoredScrollY ?? 0) > 1000
        let payload: [String: Any] = [
            "rec": "bench", "metric": "interactionState_restore_ms",
            "iterations": iterations,
            "p50_ms": r3(p50), "p95_ms": r3(p95),
            "min_ms": r3(samples.first!), "max_ms": r3(samples.last!),
            "state_bytes": state.count,
            "threshold_ms": THRESHOLD_MS,
            "restored_scroll_y": restoredScrollY ?? -1,
            "scroll_restored": scrollOK,
            "pass": p50 < THRESHOLD_MS && scrollOK,
        ]
        let json = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        FileHandle.standardOutput.write(json); FileHandle.standardOutput.write(Data("\n".utf8))
        return (p50 < THRESHOLD_MS && scrollOK) ? 0 : 1
    }

    private static func load(_ e: WKWebEngine, _ url: URL) async -> Bool {
        e.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return await finish(e)
    }

    /// Holds the continuation so both the event handler and the timeout can
    /// resolve it exactly once. Main-actor isolated, so no locking is needed —
    /// and the region-isolation checker can actually verify it, which it cannot
    /// do for the equivalent `withTaskGroup` race.
    @MainActor
    private final class Waiter {
        private var cont: CheckedContinuation<Bool, Never>?
        private var settled = false
        func wait() async -> Bool {
            await withCheckedContinuation { c in self.cont = c }
        }
        func settle(_ value: Bool) {
            guard !settled else { return }
            settled = true
            cont?.resume(returning: value)
            cont = nil
        }
    }

    /// Resolve on the engine's own didFinish/didFail, raced against a timeout.
    /// Never a semaphore on the main thread.
    private static func finish(_ e: WKWebEngine) async -> Bool {
        let waiter = Waiter()
        e.onEvent = { ev in
            switch ev {
            case .didFinish: waiter.settle(true)
            case .didFail:   waiter.settle(false)
            default: break
            }
        }
        // A timeout is a failure, never a skip (harness design §7.6).
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            waiter.settle(false)
        }
        let result = await waiter.wait()
        timeout.cancel()
        return result
    }
}
