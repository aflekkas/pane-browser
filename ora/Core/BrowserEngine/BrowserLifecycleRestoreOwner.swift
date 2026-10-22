import WebKit

/// Assigning interactionState returns no WKNavigation. Adopt its first native
/// start callback, then retain ownership only for that exact navigation. Queued
/// privacy-gated restoration remains separately owned by the restore controller.
final class BrowserLifecycleRestoreOwner {
    private enum State {
        case awaitingNavigation
        case navigating(WKNavigation)
    }

    private var state: State?
    var isRestoring: Bool {
        state != nil
    }

    func beginAssignment() {
        state = .awaitingNavigation
    }

    /// Returns true when a different navigation replaces the restore.
    func didStart(_ navigation: WKNavigation?) -> Bool {
        guard let state else { return false }
        switch state {
        case .awaitingNavigation:
            guard let navigation else { self.state = nil
                return true
            }
            self.state = .navigating(navigation)
            return false
        case let .navigating(owner):
            guard owner !== navigation else { return false }
            self.state = nil
            return true
        }
    }

    /// An obsolete failure/finish cannot clear a newer restoration.
    @discardableResult
    func complete(_ navigation: WKNavigation?) -> Bool {
        guard case let .navigating(owner) = state, owner === navigation else { return false }
        state = nil
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        let wasRestoring = state != nil
        state = nil
        return wasRestoring
    }
}
