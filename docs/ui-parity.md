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
- [x] Row pitch ~27–28 pt (measured off the reference)
- [ ] Traffic-light clearance and header spacing matched precisely
- [ ] Sidebar resizable by dragging the divider
- [ ] Sidebar auto-hide / hover-reveal

### Tabs
- [x] Essentials as an icon grid
- [x] Favicons on rows
- [ ] Favicons on essentials tiles at the right size
- [ ] Hover state on rows
- [ ] Close button appearing on hover
- [ ] Drag reorder with a live insertion indicator
- [ ] Selected-row pill styling matched (radius, inset, weight)

### Spaces
- [x] Rename
- [x] Icon picker
- [x] Delete with confirmation
- [ ] Reorder by drag
- [ ] Swipe / keyboard shortcut to switch spaces
- [ ] Per-space accent applied to the selection pill

### Chrome
- [x] Address field styling (rounded, subtle fill, placeholder copy)
- [ ] Download indicator in the sidebar rather than a menu item
- [ ] Find bar styled rather than the raw `NSTextFinder` bar

## Method

The reference measurements live in `docs/reference/arc-sidebar.md`. When adding
to this list, measure off a real screenshot and record the number there first —
"looks about right" is how a UI drifts a pixel at a time.

Note the honest constraint from `docs/api-notes/appkit.md`: automated visual
goldens do not work yet, because `cacheDisplay` cannot capture layer-backed
`NSScrollView` content. Until that is solved, every tick on this list means a
human-equivalent check — capture the screen with Pane frontmost and *look*.
