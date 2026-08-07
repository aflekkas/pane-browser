# UI parity with Arc

A standing goal, added 2026-08-07 at Alex's request: **Pane should reach visual
and interaction parity with Arc on the basic browser features.**

## Scope

**In:** layout, proportions, density, the shape of interactions — where things
live, how they respond, what a hover or a drag does.

**Explicitly out**, and these are not omissions to be corrected later:

- Custom theming and colour schemes. Pane uses system semantic colours only
  (`controlAccentColor`, `labelColor`, …) and inherits light/dark from macOS.
- Transparency and material effects. Liquid Glass is milestone G and is the
  *last* thing built, per spec §9.
- Anything in Arc that is not in Pane's spec: Boosts, Easels, Notes, split view,
  Little Arc, AI features. Parity means *the basic features look right*, not
  that Pane grows Arc's feature set. Spec §0 still governs.

## Checklist

Ticked only when it has been looked at against a real Arc screenshot, not when
it merely compiles.

### Sidebar shell
- [x] Nav controls and address field **inside** the sidebar, so the content area
      carries no chrome above it
- [x] Content view inset with rounded corners
- [x] Spaces pinned to the bottom
- [x] `+ New Tab` as the last row of the list
- [x] Sections separated by spacing, no headers
- [x] Row pitch 28 pt — confirmed against Zen's `--tab-min-height`
- [x] Corner radius 10 pt — Zen's `--border-radius-medium`
- [x] Essentials tiles 44 pt tall, reflowing column count (Zen grid auto-fit)
- [x] Spaces strip 28 pt tall, 3 pt gap — Zen's workspace strip
- [ ] Traffic-light clearance and header spacing matched precisely
- [x] Sidebar resizable by dragging the divider
- [ ] Sidebar auto-hide / hover-reveal

### Tabs
- [x] Essentials as an icon grid
- [x] Favicons on rows
- [x] Favicons on essentials tiles at the right size
- [x] Favicons cached to disk so they survive relaunch
- [x] Hover state on rows
- [x] Close button appearing on hover
- [x] Drag reorder with a live insertion indicator
- [x] Selected-row pill styling — rounded inset, not AppKit's full-bleed row

### Spaces
- [x] Rename
- [x] Icon picker
- [x] Delete with confirmation
- [x] Reorder by drag (model + cross-space tab drop)
- [x] Keyboard shortcut to switch spaces (⇧⌘[ / ⇧⌘])
- [x] Per-space accent applied to the selection pill

### Chrome
- [x] Address field styling (rounded, subtle fill, placeholder copy)
- [x] Download indicator in the sidebar rather than a menu item
- [ ] Find bar styled rather than the raw `NSTextFinder` bar

## Method

The reference measurements live in `docs/arc-sidebar.md`. When adding
to this list, measure off a real screenshot and record the number there first —
"looks about right" is how a UI drifts a pixel at a time.

**Automated visual goldens now work** (`./Scripts/visual.sh check`, wired into
`gate.sh phase`). They use `Capture.composite` — `displayIgnoringOpacity` for
chrome plus `WKWebView.takeSnapshot` for content — which needs no Screen
Recording permission and no window activation. Seven approaches are recorded in
`docs/api-notes/appkit.md`; six of them failed.

The golden scene is **hermetic**: fixed titles, no navigation, no favicon
fetches. The demo seed was unusable because titles and icons arrive from the
network at different times each run, so the golden failed against itself — and
a check that cries wolf is one people learn to ignore. The diff is scoped to
the sidebar region for the same reason: the content area shows a live
third-party page.

Verified capable of failing: a 2pt→12pt row-height change moves the ratio from
0.0002 to 0.0934. Run-to-run noise is ~0.02%, against a 0.2% threshold.
