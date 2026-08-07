# AppKit gotchas

## Screenshotting the sidebar from inside the app: solved, seventh attempt

**Found:** 2026-08-07, macOS 26.5.2. Six failed attempts recorded in full so
nobody repeats them; the seventh works and is wired to `--capture`.

Goal was TCC-free visual verification: capture Pane's own window from inside the
process, so goldens need no Screen Recording grant. The failures:

| Attempt | Result |
| --- | --- |
| `view.cacheDisplay(in:to:)` on an un-ordered window | Uniform fill. A window never ordered on screen has an undrawn view hierarchy. |
| + `orderFront` / `displayIfNeeded` / `view.display()` | **WKWebView content captures correctly. Sidebar is blank white.** |
| `layer.render(in:)` instead | *Worse* — uniform. An offscreen window has no populated layer tree. |
| Removing `wantsLayer` from the sidebar's own view | Still blank. |
| `screencapture -l <windowNumber>` from a bare exec | Frame captures; content and sidebar unpainted — the occluded window never painted for the window server, and there is nothing to grab. |
| Same via `open -a … --args --capture` | No file at all. TCC attributes the child `screencapture` to its *responsible process* — Pane itself under `open`, which holds no Screen Recording grant. The terminal's grant only covers processes the terminal is responsible for. |

**Root cause, measured.** Two independent limits, one per pane:

- `cacheDisplay` *samples layer contents*; it does not re-draw them. The scroll
  view's layer island only has populated contents when the window server has
  composited it, so an unattended window yields a flat sidebar. (The earlier
  "cacheDisplay cannot capture layer-backed views at all" theory was wrong —
  with a WKWebView forcing whole-window layer backing and the window genuinely
  on screen, it captures fine. The dependency is on *composited layer
  contents*, which unattended runs never produce.)
- No in-process draw can ever reach WKWebView pixels: they live in the
  WebContent process's remote layer tree. This half the research predicted.

**What works — `Capture.composite`, no TCC, no activation:**

- Chrome: `view.displayIgnoringOpacity(bounds, in: bitmapContext)`. Unlike
  `cacheDisplay` this *re-draws* the hierarchy into the given context instead of
  sampling cached layer contents, so it renders the scroll view even on a window
  never ordered on screen. Measured on a minimal repro: 341 distinct sidebar
  colours vs 1 for `cacheDisplay` on the identical window.
- Web content: `WKWebView.takeSnapshot` — WebKit's sanctioned export of the
  remote layer tree, which also works while occluded — composited into the same
  bitmap at the web view's frame. Snapshot only after `isLoading` clears, or
  you get the page's bare background, which is indistinguishable from failure.
- Draw at 1x: `displayIgnoringOpacity` honours the context's scale, not the
  window's backing scale — a 2x bitmap comes out with the UI in one quarter.
  1x is also what makes goldens comparable across machines.

Validation requires the *sidebar region* to be non-uniform on its own, not just
the whole image — "web fine, sidebar flat" was attempt 2's exact failure and a
whole-image check calls it success.

`CGWindowListCreateImage` (the historical TCC-free own-window path) is hard
unavailable in the macOS 26 SDK — compile error, "use ScreenCaptureKit". SCK
itself still needs the TCC grant plus a window the window server has actually
composited, so it inherits both problems the composite avoids.

`screencapture -l` remains the only capture showing the REAL composited pixels
(vibrancy, traffic lights). Manual parity checks only: it needs the grant on
the responsible process and a genuinely frontmost, painted window.

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
