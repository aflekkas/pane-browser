# Budgets

"Fast and small" is unfalsifiable as a slogan and trivial to enforce as a
number. These are hard ceilings; `Scripts/check-scope.sh` fails the gate when
the tree exceeds one.

**Raising a ceiling is a spec commit with a stated reason**, not a quiet edit.
This is the check that catches the drift no other check does — not *wrong* code,
just steadily *more* of it.

## Lines of Swift (excluding tests, comments, blank lines)

| Through milestone | Ceiling | Actual | Notes |
| --- | --- | --- | --- |
| A — it browses | 1,200 | — | window, address bar, one webview, interactionState |
| B — it has tabs | 3,000 | — | + tab model, lifecycle, sidebar, drag/drop |
| C — it remembers | 4,500 | — | + Store actor, session restore, discard/restore |
| D — it has spaces | 5,500 | — | + profiles, space switching |
| E — it's a real browser | 9,000 | — | + the whole boring floor. This is the big one. |
| F — it's yours | 11,500 | — | + credential vault, passkey plumbing |
| G — it's pretty | 12,000 | — | + glass |

For reference: these ceilings put Pane at roughly 1–2% the size of a Chromium
fork and well under a tenth of `duckduckgo/apple-browsers`. If a milestone needs
substantially more than its ceiling, the honest reading is usually that
something not in the spec is being built.

## Dependencies

**Ceiling: zero.** CI fails if `Package.swift` gains a `.package(` line without
a matching ADR.

The dependency most likely to be argued for is GRDB, for SQLite. That argument
must be made in writing once, weighed against a few hundred lines of direct
`sqlite3` C API behind the `Store` actor, and then it is settled either way.

## Harness

The verification harness is exempt from the LOC ceiling — it is the thing that
proves the ceilings are being met honestly, and capping it creates an incentive
to test less. It is tracked separately so the exemption cannot hide product code:

| Target | Ceiling |
| --- | --- |
| `PaneHarness` + `Tests/` + `paneshot` | untracked, but must not import product code except through public API |
