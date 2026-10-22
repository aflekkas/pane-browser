@testable import Ora
import Testing

@MainActor
struct LifecycleRepairActivityTests {
    @Test(arguments: ["bare", "plain", "input"])
    func actualEditBlocksAndResetOrSubmitClears(identifier: String) async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let harness = LifecycleRepairHarness()
        defer { harness.close() }
        try await harness.load(fixture.url())
        #expect(await !(harness.activity()).blocksDiscard)
        _ = try await harness.evaluate("""
        (() => {
            const el = document.getElementById('\(identifier)');
            if (el.isContentEditable) el.textContent = 'edited draft'; else el.value = 'edited draft';
            el.dispatchEvent(new InputEvent('input', { bubbles:true, composed:true }));
            return true;
        })()
        """)
        #expect(await (harness.activity()).formDirty)
        if identifier == "input" {
            _ = try await harness.evaluate("document.getElementById('form').reset(); true")
        } else {
            _ = try await harness.evaluate("""
            (() => {
                const form = document.getElementById('form');
                form.appendChild(document.getElementById('\(identifier)'));
                form.dispatchEvent(new Event('submit', { bubbles:true, cancelable:true }));
                return true;
            })()
            """)
        }
        #expect(await !(harness.activity()).blocksDiscard)
        #expect(try await harness.evaluate("typeof window.__paneLifecycle") as? String == "undefined")
    }

    @Test(arguments: ["open", "closed"])
    func shadowDraftsAreGuarded(mode: String) async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let harness = LifecycleRepairHarness()
        defer { harness.close() }
        try await harness.load(fixture.url())
        _ = try await harness.evaluate("""
        (() => {
            const root = document.getElementById('host').attachShadow({mode:'\(mode)'});
            root.innerHTML = '<div contenteditable>saved</div>';
            const field = root.firstChild;
            field.textContent = 'shadow draft';
            field.dispatchEvent(new InputEvent('input', {bubbles:true, composed:true}));
            return true;
        })()
        """)
        let activity = await harness.activity()
        #expect(activity.blocksDiscard)
        if mode == "closed" {
            #expect(activity.hasUninspectableFrames)
        } else {
            #expect(activity.formDirty)
        }
    }

    @Test func deepFrameMediaAndInspectionLimitsBlockDiscard() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let harness = LifecycleRepairHarness()
        defer { harness.close() }
        try await harness.load(fixture.url("/depth/8"))
        let activity = await harness.activity()
        #expect(activity.mediaSessionActive || activity.hasUninspectableFrames)
        #expect(activity.blocksDiscard)
        // WKWebView may cap nested frames before 32; either native limit or
        // explicit traversal limit must remain unknown, never silently clear.
        try await harness.load(fixture.url("/depth/40"))
        #expect(await (harness.activity()).blocksDiscard)
    }

    @Test func missingTrackerBecomesUnknownThenNewDocumentCanBeClear() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let harness = LifecycleRepairHarness()
        defer { harness.close() }
        try await harness.load(fixture.url())
        _ = try await harness.evaluate("delete window.__paneLifecycle; true", world: TabLifecycleActivityProbe.world)
        #expect(await (harness.activity()).hasUnsavedFormState)
        try await harness.load(fixture.url("/b"))
        #expect(await !(harness.activity()).blocksDiscard)
    }
}
