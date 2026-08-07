# AppKit gotchas

## You cannot screenshot the sidebar from inside the app

**Found:** 2026-08-07, macOS 26.5.2. Cost about an hour and five failed attempts.
Recorded in full so nobody repeats it.

Goal was TCC-free visual verification: capture Pane's own window from inside the
process, so goldens need no Screen Recording grant. What actually happens:

| Attempt | Result |
| --- | --- |
| `view.cacheDisplay(in:to:)` on an un-ordered window | Uniform fill. A window never ordered on screen has an undrawn view hierarchy. |
| + `orderFront` / `displayIfNeeded` / `view.display()` | **WKWebView content captures correctly. Sidebar is blank white.** |
| `layer.render(in:)` instead | *Worse* — uniform. An offscreen window has no populated layer tree. |
| Removing `wantsLayer` from the sidebar's own view | Still blank. |
| `screencapture -l <windowNumber>` from a bare exec | Frame captures; content and sidebar unpainted. |

**Why.** `cacheDisplay` does not traverse layer-backed subviews, and
`NSScrollView` is layer-backed by AppKit regardless of what the app requests.
The sidebar lives in a scroll view, so it is structurally uncapturable this way.

Note this is the **opposite** of the failure the research predicted. The
expectation was that `WKWebView` — composited out-of-process in a remote layer
tree — would come out blank while AppKit chrome captured fine. Exactly the
reverse is true.

**What works:** `screencapture -x -o -l<id>` where `id` is
`NSWindow.windowNumber` (which *is* the CGWindowID), **with the app properly
activated via LaunchServices** — i.e. launched as a bundle with `open`, not as a
bare binary, and given time to paint. This needs the Screen Recording TCC grant.

**Status: unresolved for automation.** Visual goldens are therefore *not* wired
into the phase gate yet. The sidebar is currently verified by a human-equivalent
step — capture the full screen with Pane frontmost and actually look at the PNG.
That is real verification, but it is manual, and `gate.sh` must keep listing
visual goldens under "NOT proven by this run" until it is not.

**Do not** let a green gate imply the sidebar was checked.

## `NSWindowController` has no `addChild`

`addChild(_:)` is `NSViewController`. A window controller holding a child view
controller must retain it itself (a stored property is enough) and add its
`.view` to the hierarchy manually. Milestone D will convert this to a proper
`NSViewController` containment hierarchy for space switching (spec §3).

## KVO on WKWebView needs `MainActor.assumeIsolated`

`webView.observe(\.title) { ... }` hands back a nonisolated closure. Touching
main-actor state inside it requires `MainActor.assumeIsolated { }`. Sound,
because WebKit posts these on the main thread — but the compiler cannot know it.

## Chrome must be re-derived on tab switch, not accumulated from events

Engine events only ever arrive for the tab that fired them. Updating the title
bar and address bar purely from `titleChanged` / `urlChanged` leaves them showing
the **previous** tab's page after a switch — visible in the first sidebar
screenshot as "DuckDuckGo" in the title while Hacker News was selected.

`syncChrome()` reads the selected engine's current state directly. Anything
derived from the selected tab belongs there, not in the event handler.
