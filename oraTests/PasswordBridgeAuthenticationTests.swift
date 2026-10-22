import Foundation
@testable import Ora
import SwiftData
import Testing

@MainActor
struct PasswordBridgeAuthenticationTests {
    @Test(arguments: [false, true])
    func delayedAuthenticationCannotFillAfterReloadOrCancelledNavigation(cancelNavigation: Bool) async throws {
        let fixture = try await PasswordBridgeLoopbackFixture()
        defer { fixture.stop() }
        let harness = try PasswordBridgeWorldHarness()
        defer { harness.close() }
        try await harness.load(fixture.url())
        let focus = try await harness.focusPassword()
        let captured = try await harness.waitForContext()
        let tab = try makeTab(page: harness.page, url: fixture.url())
        defer { tab.browserPage = nil }
        let gate = PasswordBridgeAuthenticationGate()
        defer { gate.resolve(false) }
        let usage = PasswordBridgeFixtureUsage()
        let coordinator = PasswordAutofillCoordinator(
            tab: tab,
            authenticate: { _ in await gate.authenticate() },
            revealPassword: { _ in "fixture-authenticated-password" },
            markUsed: { _ in usage.record() }
        )
        let entry = makeEntry()
        let pending = coordinator.autofill(entry, for: overlay(focus: focus, context: captured))
        try await harness.waitUntil("authentication suspended before navigation") { gate.isWaiting }
        if cancelNavigation {
            try await harness.cancelHeldNavigation(on: fixture)
        } else {
            try await harness.reload()
        }
        let current = try await harness.waitForContext()
        #expect(current != captured)
        // Cancellation retains the exact DOM, IDs and JS token. Only the
        // coordinator's native generation check can prevent the pending fill.
        if cancelNavigation {
            #expect(current.documentToken == captured.documentToken)
        }
        gate.resolve(true)
        await pending.value
        let afterDelayedAuth = try await harness.evaluatePage("document.getElementById('pw').value") as? String
        #expect(afterDelayedAuth == "")
        // This also detects removal of the native guard on reload, where
        // JS token/field-ID rejection could otherwise hide a native bypass.
        #expect(usage.isEmpty)

        // Current-context positive control traverses the same coordinator,
        // auth gate, dummy reveal closure, isolated fill and actual page DOM.
        let freshFocus = try await harness.focusPassword()
        let fresh = coordinator.autofill(entry, for: overlay(focus: freshFocus, context: current))
        try await harness.waitUntil("fresh authentication suspended") { gate.isWaiting }
        gate.resolve(true)
        await fresh.value
        let afterFreshAuth = try await harness.evaluatePage("document.getElementById('pw').value") as? String
        #expect(afterFreshAuth == "fixture-authenticated-password")
        #expect(usage.count == 1)
    }

    private func makeTab(page: BrowserPage, url: URL) throws -> Tab {
        let store = try ModelConfiguration.createOraContainer(isPrivate: true)
        let context = ModelContext(store)
        let manager = TabManager(modelContainer: store, modelContext: context, mediaController: MediaController())
        let container = try #require(manager.activeContainer)
        let tab = Tab(
            url: url,
            title: "Password fixture",
            container: container,
            order: 0,
            tabManager: manager,
            isPrivate: true
        )
        tab.browserPage = page
        return tab
    }

    private func overlay(focus: FocusMessage, context: PasswordDocumentContext) -> PasswordAutofillOverlayState {
        PasswordAutofillOverlayState(
            focus: focus, savedPasswordEntries: [], emailSuggestions: [], generatedPassword: nil,
            selectedSuggestionIndex: 0, fillContext: context
        )
    }

    private func makeEntry() -> SavedPasswordSummary {
        SavedPasswordSummary(
            metadata: SavedPasswordMetadata(
                id: UUID().uuidString, origin: "http://127.0.0.1", host: "127.0.0.1",
                username: "fixture-user@example.invalid", createdAt: Date(), updatedAt: Date(),
                lastUsedAt: nil, containerID: nil
            ), persistentReference: Data()
        )
    }
}

@MainActor
private final class PasswordBridgeAuthenticationGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    var isWaiting: Bool {
        continuation != nil
    }

    func authenticate() async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ authenticated: Bool) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: authenticated)
    }
}

private final class PasswordBridgeFixtureUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == 0
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}
