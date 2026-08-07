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
    case selectSpace(String)
    case newSpace(name: String)
    case renameSpace(String, String)
    case setSpaceIcon(String, String?)
    case setSpaceAccent(String, Int?)
    case deleteSpace(String)
    case nextSpace
    case previousSpace
    /// 1-based; ⌘1…⌘9 select the nth tab, ⌘9 the last, as every browser does.
    case selectTabIndex(Int)
    /// spec §4 — move a tab between essentials / pinned / today.
    case setTabKind(TabID, TabKind)
    case copyTabURL(TabID)
    case duplicateTab(TabID)
    case closeOtherTabs(TabID)
    /// spec §5 — drag a tab onto another space's pill.
    case moveTabToSpace(TabID, String)
    /// spec §4 — force the discard sweep now rather than waiting for the timer.
    /// Exists so the benchmark and scenarios can exercise discard deterministically.
    case sweepDiscardable
    /// Ignore idle thresholds; never-discard conditions still apply.
    case sweepDiscardableForced
}
