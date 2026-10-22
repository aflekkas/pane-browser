import Foundation
@testable import Ora
import Testing
import WebKit

@MainActor
struct LifecycleViewportRestoreTests {
    @Test(arguments: [false, true])
    func viewportSettlesAfterLateResetOrFiniteClamping(shortDocument: Bool) async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let profile = BrowserEngineProfile(identifier: UUID(), isPrivate: true)
        let source = LifecycleRepairHarness(profile: profile)
        defer { source.close() }
        try await source.load(fixture.url())
        try await source.load(fixture.url("/b"))
        try await source.scroll(to: 1200)
        let checkpoint = try #require(source.page.captureInteractionState())
        #expect(LifecycleRepairHarness.checkpointScrollY(checkpoint) == 1200)
        let restored = LifecycleRepairHarness(profile: profile, isVisible: false)
        defer { restored.close() }
        restored.traceViewport()
        defer { restored.dumpViewportTrace() }
        restored.page.restoreInteractionState(checkpoint) { _ in }
        try await restored.loaded(fixture.url("/b"))
        #expect(restored.page.hasPendingLifecycleRestore)
        if shortDocument {
            _ = try await restored.evaluate("document.body.innerHTML='<p>Short document</p>'; true")
        } else {
            // Real WebKit render ordering: reset on the frame AFTER the first
            // applied scroll. An immediate post-scroll acknowledgement falsely
            // succeeds before this callback and leaves the viewport at zero.
            _ = try await restored.evaluate("""
            globalThis.didResetViewport = false;
            addEventListener('scroll', () => requestAnimationFrame(() => {
              scrollTo(0, 0); globalThis.didResetViewport = true;
            }), {once:true}); true;
            """)
        }
        restored.show()
        try await LifecycleRepairHarness.waitUntil { !restored.page.hasPendingLifecycleRestore }
        let expected = shortDocument ? 0.0 : 1200.0
        try await restored.expectScroll(y: expected)
        if !shortDocument {
            #expect(try await restored.evaluate("globalThis.didResetViewport") as? Bool == true)
        }
        // Check again after a rendered frame: acknowledgement must represent
        // the persistent viewport, not a synchronous scrollTo return value.
        _ = try await restored.page.webView.callAsyncJavaScript(
            "await new Promise(resolve => requestAnimationFrame(resolve)); return true;",
            arguments: [:], in: nil, contentWorld: .page
        )
        try await restored.expectScroll(y: expected)
        let applied = try #require(restored.page.captureInteractionState())
        #expect(LifecycleRepairHarness.checkpointScrollY(applied) == expected)
        #expect(restored.page.canGoBack)
        #expect(restored.page.profileIdentifier == profile.identifier)
    }
}
