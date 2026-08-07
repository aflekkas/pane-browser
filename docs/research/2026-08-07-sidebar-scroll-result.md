# Sidebar scroll performance — measured result

**Date:** 2026-08-07 · **Host:** macOS 26.5.2, Apple Silicon
**Command:** `.build/debug/Pane --bench-scroll --rows 200`

Spec §5 asserts: *"`NSOutlineView`, view-based. **Not SwiftUI.** A `List` with
200 rows and drag reordering will stutter, and the sidebar is the one surface
where stutter is unforgivable."*

That was an unmeasured claim justifying an architectural decision. Now measured.

## Result: PASS

```json
{"rows": 201, "steps": 60,
 "p50_ms": 3.046, "p95_ms": 4.709, "max_ms": 5.723,
 "budget_ms": 8.0, "pass": true}
```

201 rows spread across all three sections (12 essentials, 48 pinned, the rest
ephemeral), scrolled the full height in 60 steps, each forcing a complete layout
and display pass.

**p95 of 4.7 ms against an 8 ms budget.** The budget is half of a 60fps frame
(16.67 ms), because the frame also has to composite web content — the sidebar
does not get the whole thing.

## What this does and does not establish

**Does:** `NSOutlineView` is comfortably fast enough at 200 rows. §5's choice is
sound on its own terms, and there is now a number that will fail if a future
change makes row construction expensive.

**Does not:** it is *not* a comparison against SwiftUI. §5 claims a SwiftUI
`List` "will stutter"; nothing here tests that, and building a SwiftUI sidebar
to find out would violate the invariant that forbids one. The honest reading is
"AppKit is fast enough", not "AppKit is faster than the alternative we did not
build".

Recorded so nobody later cites this file as proof of a comparison it never made.

## Method note

Measures **our** cost — row construction and layout via
`layoutSubtreeIfNeeded()` / `displayIfNeeded()` — not the window server's
compositing. That is the right boundary: compositing is not something the code
can regress, and including it would add variance that hides real changes.
