// spec: §4
import Foundation
import AppKit
import PaneCore
import PaneUI

/// End-to-end scenarios driven through `CommandBus.dispatch`, the same path a
/// menu item or key chord takes (ADR 0006). A scenario that dispatches
/// `.closeTab` therefore exercises exactly the code ⌘W exercises — that is what
/// makes scripted coverage real coverage rather than a parallel universe.
///
/// Every assertion goes through `Expect`, which counts them; a scenario
/// reporting zero assertions fails (harness design §7.1).
@MainActor
public enum Scenarios {

    nonisolated(unsafe) static var fixtures: Fixtures?

    public static func runAll(json: Bool) async -> Int32 {
        var results: [(String, Int, [String], Double)] = []

        let fx = Fixtures()
        if await fx.start() { fixtures = fx }
        else { FileHandle.standardError.write(Data("fixtures: server did not start\n".utf8)) }
        defer { fx.stop() }

        for (name, body) in all {
            let e = Expect(name)
            let clock = ContinuousClock()
            let start = clock.now
            await body(e)
            let ms = Bench.milliseconds(clock.now - start)
            _ = e.finish()
            results.append((name, e.assertions, e.failures, ms))
        }

        let failed = results.filter { !$0.2.isEmpty }
        for (name, n, failures, ms) in results {
            let status = failures.isEmpty ? "pass" : "fail"
            if json {
                let payload: [String: Any] = [
                    "rec": "scenario", "id": name, "status": status,
                    "assertions": n, "ms": (ms * 100).rounded() / 100,
                    "failures": failures,
                ]
                let d = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                FileHandle.standardOutput.write(d)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                print("\(status == "pass" ? "✓" : "✗") \(name)  (\(n) assertions, \(Int(ms))ms)")
                for f in failures { print("    \(f)") }
            }
        }
        let total = results.reduce(0) { $0 + $1.1 }
        print("\(results.count) scenarios, \(total) assertions, \(failed.count) failed")
        return failed.isEmpty ? 0 : 1
    }

    /// A fresh controller per scenario, on a throwaway store, so scenarios
    /// cannot leak state into each other — the classic source of a suite that
    /// passes only in one order.
    private static func fresh() -> BrowserWindowController {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-scn-\(UUID().uuidString).sqlite").path
        let c = BrowserWindowController(storePath: path, restoreSession: false)
        c.window?.orderBack(nil)
        return c
    }

    private static var all: [(String, (Expect) async -> Void)] {
        [
            ("tabs.new_tab_is_selected", { e in
                let c = fresh()
                let before = c.tabCount
                c.dispatch(.newTab(kind: .ephemeral))
                e.equal(c.tabCount, before + 1, "a new tab is added")
                e.that(c.selectedTabID != nil, "and becomes selected")
            }),

            ("tabs.close_then_reopen_restores", { e in
                let c = fresh()
                c.dispatch(.newTab(kind: .ephemeral))
                c.dispatch(.navigate("example.com"))
                let n = c.tabCount
                c.dispatch(.closeTab(nil))
                e.equal(c.tabCount, n - 1, "closing removes it")
                c.dispatch(.reopenClosedTab)
                e.equal(c.tabCount, n, "reopen brings it back")
            }),

            ("tabs.kind_promotion_moves_sections", { e in
                let c = fresh()
                c.dispatch(.newTab(kind: .ephemeral))
                c.dispatch(.navigate("example.com"))
                guard let id = c.selectedTabID else {
                    e.that(false, "no selected tab"); return
                }
                e.equal(c.tabCount(ofKind: .ephemeral), 2, "starts in Today (plus the initial tab)")
                c.dispatch(.setTabKind(id, .essential))
                e.equal(c.tabCount(ofKind: .essential), 1, "promoted into Essentials")
                e.equal(c.tabCount(ofKind: .ephemeral), 1, "and left Today")
            }),

            ("lifecycle.discard_releases_the_engine", { e in
                let c = fresh()
                c.dispatch(.newTab(kind: .ephemeral))
                c.dispatch(.navigate("example.com"))
                c.dispatch(.newTab(kind: .ephemeral))
                try? await Task.sleep(for: .seconds(2))
                let live = c.liveEngineCount
                e.that(live >= 2, "engines exist for live tabs")
                c.forceSweepForBench()
                e.that(c.liveEngineCount < live,
                       "a forced sweep releases engines — the only step that reclaims memory")
                e.that(c.liveEngineCount >= 1,
                       "the selected tab keeps its engine and is never discarded")
            }),

            ("spaces.switching_isolates_tab_lists", { e in
                let c = fresh()
                c.dispatch(.newTab(kind: .ephemeral))
                let first = c.tabCount
                c.dispatch(.newSpace(name: "Second"))
                e.equal(c.tabCount, 1, "a new space starts with its own single tab")
                c.dispatch(.previousSpace)
                e.equal(c.tabCount, first, "switching back restores the original space's tabs")
            }),

            ("spaces.cycle_wraps", { e in
                let c = fresh()
                c.dispatch(.newSpace(name: "B"))
                c.dispatch(.newSpace(name: "C"))
                // Cycle back to the FIRST space before testing forward wrap.
                // Starting on the last space made this vacuous: clamping and
                // wrapping both leave you there, so the clamp mutant escaped.
                c.dispatch(.previousSpace)
                c.dispatch(.previousSpace)
                let first = c.currentSpaceName
                c.dispatch(.previousSpace)
                e.that(c.currentSpaceName != first,
                       "going back from the first space wraps to the last, it does not clamp")
                c.dispatch(.nextSpace)
                e.equal(c.currentSpaceName, first, "and forward returns")
            }),

            ("net.auth_challenge_is_answered", { e in
                guard let base = fixtures?.baseURL else {
                    e.that(false, "fixture server unavailable"); return
                }
                // The fixture returns 401 then 200 with the right credentials.
                // Pane cancels rather than prompting in an unattended run, so
                // what this asserts is that the challenge REACHES the delegate
                // and the load resolves rather than hanging — the silent
                // rejectProtectionSpace default is the bug being guarded.
                let c = fresh()
                c.dispatch(.newTab(kind: .ephemeral))
                c.dispatch(.navigate(base.appendingPathComponent("auth").absoluteString))
                try? await Task.sleep(for: .seconds(3))
                e.that(c.selectedURL != nil, "the navigation resolved instead of hanging")
            }),

            ("net.attachment_becomes_a_download", { e in
                guard let base = fixtures?.baseURL else {
                    e.that(false, "fixture server unavailable"); return
                }
                let c = fresh()
                c.dispatch(.newTab(kind: .ephemeral))
                c.dispatch(.navigate(base.appendingPathComponent("download/scn.bin").absoluteString))
                var sawDownload = false
                for _ in 0..<24 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if !c.downloads.items.isEmpty { sawDownload = true; break }
                }
                e.that(sawDownload, "Content-Disposition: attachment routes to WKDownload")
                if let dest = c.downloads.items.first?.destination {
                    try? FileManager.default.removeItem(at: dest)
                }
            }),

            ("net.untrusted_cert_does_not_silently_load", { e in
                guard let tls = fixtures?.tlsURL else {
                    e.that(false, "fixture TLS server unavailable"); return
                }
                // The fixture serves a self-signed cert for a name that does not
                // match. The page must NOT load: silently accepting bad TLS is
                // the worst possible failure here, so the assertion is that it
                // did not happen.
                let c = fresh()
                c.dispatch(.newTab(kind: .ephemeral))
                c.dispatch(.navigate(tls.absoluteString))
                try? await Task.sleep(for: .seconds(4))
                let loaded = c.selectedURL?.host == "127.0.0.1"
                    && c.selectedPageTitle?.isEmpty == false
                e.that(!loaded, "an untrusted certificate does not load silently")
            }),

            ("nav.address_bar_resolves_search_vs_host", { e in
                let c = fresh()
                c.dispatch(.newTab(kind: .ephemeral))
                c.dispatch(.navigate("example.com"))
                try? await Task.sleep(for: .seconds(2))
                e.that(c.selectedURL?.host?.contains("example.com") == true,
                       "a bare host navigates rather than searching")
            }),
        ]
    }
}
