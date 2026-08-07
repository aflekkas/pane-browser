// spec: §1
import Foundation

/// Every state mutation in Pane goes through `Command`. Menus, key chords and
/// test scenarios all dispatch these and nothing else, so a scenario that sends
/// `.closeTab` exercises exactly the code path ⌘W exercises (ADR 0006).
///
/// A lint rule fails the build if anything outside the command bus mutates
/// model state directly. That is what makes scripted coverage real coverage
/// rather than a parallel universe.
public enum Command: Equatable, Sendable {
    case navigate(String)      // raw address-bar text, not yet resolved
    case goBack
    case goForward
    case reload
    case stopLoading
    case focusAddressBar

    case newTab(kind: TabKind)
    case closeTab(TabID?)      // nil = the selected tab
    case selectTab(TabID)
    case reopenClosedTab
    case toggleSidebar
    /// spec §4 — force the discard sweep now rather than waiting for the timer.
    /// Exists so the benchmark and scenarios can exercise discard deterministically.
    case sweepDiscardable
}
