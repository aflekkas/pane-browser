# Arc sidebar — reference proportions

Supplied by Alex, 2026-08-07, as the target for sidebar proportions. Measured
off two screenshots: a sidebar crop and a full window with no tab open.

**This is a proportions reference, not a licence to copy Arc's feature set.**
Nothing here adds scope; it calibrates spacing, sizing and density for what
spec §5 already describes.

## Measured (normalised to points, assuming 2x)

| Element | Value |
| --- | --- |
| Sidebar width | ~150 pt at this window size (~15% of window width) |
| Search / URL field | full width less ~12 pt inset each side, ~30 pt tall, fully rounded, magnifier glyph leading |
| Essentials tiles | **2 per row at this width**, ~27 pt tall, ~8 pt gap, ~10 pt corner radius |
| List row pitch | **~27 pt** |
| Row icon | ~17 pt square, ~17 pt from the leading edge |
| Row label | starts ~29 pt from leading edge, ~13 pt semibold |
| Section separation | vertical space only — **no headers**, confirming §5 |
| Bottom strip | small icon row pinned to the bottom of the sidebar |

Row pitch of ~27 pt matches what Pane already uses (28 pt), so the list density
is close to right already.

## Structural differences from Pane's current layout

These are **layout** differences, larger than proportions, and are recorded here
rather than acted on unilaterally:

1. **The address bar lives at the top of the sidebar**, not in a toolbar above
   the content. This is what makes Arc's content area completely clean — there
   is no chrome above the page at all. Pane currently puts the address bar in a
   toolbar to the right of the divider.
2. **Traffic lights and back/forward/reload sit inside the sidebar header**,
   above the address field.
3. **Essentials are 2 per row at this width**, not 4. Arc appears to adapt the
   column count to sidebar width. Spec §5 specifies 4 per row.
4. **A "+ New Tab" affordance** sits as the last row of the list.
5. **A bottom icon strip** inside the sidebar.

(1) and (2) together are the substantive difference in feel. (3) conflicts with
spec §5 as written — the spec says four.

## What was adopted

Proportions and density only: sidebar width, field and tile sizing, insets,
corner radii, icon sizes, and the "+ New Tab" row.

Layout changes (1)–(3) touch what the spec specifies and are held for an
explicit decision rather than assumed.
