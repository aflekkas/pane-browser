# Progress

Derived from `docs/pane-browser-spec.md` §9, reordered so the app is launchable
from the end of week one and never stops being launchable.

**Update this after every meaningful unit of work**, not at phase end. A phase
that dies halfway must leave a truthful record of how far it got.

**Record gate results honestly, including failures.** A checked box whose gate
does not pass is a false claim, and every decision built on top of it is also
wrong. `Scripts/check-progress.sh` re-runs the gate for every phase marked
complete; it will catch you.

---

## Status

**Current phase:** A — it browses
**App launchable:** yes — `./Scripts/run.sh`
**Last verified gate:** milestone A — restore p50 **82 ms** / 200 ms, scroll restored (2026-08-07)

---

## Phase 0 — repo, spec, enforcement

Enforcement lands *before* the code it governs, so there is never a window in
which drift is possible.

- [x] `git init`, `.gitignore`
- [x] Spec committed verbatim as `docs/pane-browser-spec.md`
- [x] All 14 research reports committed with citations and refutations
- [x] `CLAUDE.md` — reorientation procedure, invariants, delegation doctrine
- [x] `PROGRESS.md`, `docs/journal.md`, `docs/budget.md`
- [x] ADRs 0001–0006 seeded from research
- [x] `Scripts/check-scope.sh`, `Scripts/gate.sh`, git hooks, CI
- [x] Public repo created and pushed
- [x] Spec-correction commit applying research findings

**Gate:** `./Scripts/gate.sh pre` passes on a clean tree, the pre-commit hook
rejects a commit with no receipt, and CI is green on GitHub.

---

## Milestone A — it browses

Window, address bar, one `WKWebView`, back/forward/reload, ⌘L.
`interactionState` save and restore.

- [x] `Package.swift` — `PaneCore` / `PaneWeb` / `PaneUI` / `PaneHarness` / `Pane` / `PaneCheck`
- [x] `Scripts/bundle.sh` — hand-rolled `.app` (Info.plist, codesign)
- [x] `Scripts/run.sh` — build and launch
- [x] Window, address bar, navigation — **verified running, 31 MB phys_footprint**
- [x] `interactionState` capture and restore
- [x] Bench harness measuring restore latency

**Gate:** `./Scripts/run.sh` launches a browser you can actually use, **and**
restore p50 **< 200 ms** over 20 runs.

**RESULT 2026-08-07: PASS.** `.build/debug/Pane --bench-restore --iterations 20`

```json
{"p50_ms":80.962,"p95_ms":122.164,"min_ms":74.596,"max_ms":122.164,
 "state_bytes":695,"restored_scroll_y":1200,"scroll_restored":true,"pass":true}
```

p50 is 2.5x inside the threshold. The gate asserts **correctness as well as
latency** — `restored_scroll_y` proves the state was genuinely restored rather
than the URL merely re-navigated, because a fast number on a feature that does
not work is worse than a slow number on one that does.

> Spec §9 step 1: *"If restore is not sub-200ms here, stop and fix it."* That is
> a real stop, not a note. Do not proceed to B with a failing latency gate.

## Milestone A′ — DRM probe

An afternoon, and the cheapest decision point in the project. Do it inside A.

- [ ] `Fixtures/drm-probe.html` calling `requestMediaKeySystemAccess('com.apple.fps')`
- [ ] Netflix / Disney+ / Apple TV+ / YouTube checked by hand, 1080p and 4K separately
- [ ] Result written to `docs/research/` as a dated file

**Gate:** the FairPlay answer is written down. If FairPlay is unavailable in a
third-party `WKWebView`, that is a product-defining fact and it changes what
Pane is — surface it immediately rather than continuing.

---

## Milestone B — it has tabs

Tab model, lifecycle state machine, sidebar with flat colours and real drag/drop.

- [ ] Tab model + two-tier lifecycle state machine in `PaneCore`, headless
- [ ] `NSOutlineView` sidebar — conventional data source, **not** diffable
- [ ] Drag and drop, `NSPasteboard` custom UTI + `public.url` fallback
- [ ] ⌘T / ⌘W / switch / reopen-closed via `CommandBus`

**Gate:** every transition in the (corrected, two-tier) §4 model covered by
headless tests against the fake engine protocol, including all four
never-discard conditions. 200 sidebar rows scroll without dropped frames. Drag
reorder survives relaunch. Visual golden reviewed by actually looking at it.

> Correction folded in: `NSOutlineViewDiffableDataSource` does not exist.
> See `docs/research/2026-08-07-architecture.md`.

---

## Milestone C — it remembers

Session restore and the discard/restore tier that carries the memory claim.

- [ ] Continuous writes to SQLite through the `Store` actor, debounced 500ms
- [ ] `interactionState` snapshot on terminate and every 60s
- [ ] Discard / restore with thumbnail capture
- [ ] Four never-discard conditions enforced

**Gate:** `kill -9` mid-session, relaunch, everything returns. Discard a tab and
verify `phys_footprint` actually dropped **and** `vm_stat` shows it was not
merely compressed. Report `phys_footprint`, never RSS.

---

## Milestone D — it has spaces

- [ ] `WKWebsiteDataStore(forIdentifier:)` per profile
- [ ] Space switching via `NSViewController` child swap
- [ ] Lazy profile activation, teardown after inactivity

**Gate:** log into the same site in two spaces as two different users
**simultaneously**. Cookie jars verified disjoint on disk.

> Correction folded in: only WebContent processes partition per profile. The
> network and GPU processes are singletons. Data isolation is real; process
> isolation is not. Never claim otherwise.

---

## Milestone E — it's a real browser

All of spec §6. **This is where the project dies if it dies** — weeks of
delegate plumbing with nothing to demo, right where motivation dips. It is
scheduled before the glass deliberately. *Wanting to build the glass is the
signal that E is unfinished.*

- [ ] Downloads — `WKDownloadDelegate`, uniquing, resume, **quarantine xattr**
- [ ] Uploads — `runOpenPanelWith:`, multiple + directory
- [ ] Basic/digest/NTLM auth — sheet, per-profile credential scoping
- [ ] Cert errors — `SecTrustEvaluateWithError`, native interstitial, per-profile exceptions keyed by host + cert SHA-256
- [ ] Find in page — `NSTextFinderClient`, **not** `isFindInteractionEnabled`
- [ ] Context menus — subclass `WKWebView`, override `NSView.willOpenMenu(_:with:)`
- [ ] Crash recovery — no silent reload, per-origin crash counting

**Gate:** every item exercised against the local fixture server. Download's
`com.apple.quarantine` xattr **actually present** (verify with `xattr -p`).
401 auth, self-signed cert interstitial, renderer crash with no reload loop.

---

## Milestone F — it's yours

- [ ] Credential vault — keychain, `.userPresence`, per-profile, save/fill/update
- [ ] Import — Safari and Chrome CSV, 1Password `.1pux`
- [ ] Passkeys — entitlement plumbing and UI only, **no WebAuthn reimplementation**

**Gate:** vault save/fill/update against fixture login forms with Touch ID
gating the keychain read. Passkeys: full register + assert against an RP ID
covered by an Associated Domain we control.

> The passkey entitlement needs Account Holder on an *organization* Apple
> Developer account plus a D-U-N-S number, and Apple's review criteria require
> Pane to already be a credible browser. Verify against our own domain first;
> the entitlement later widens the same working code to every site.

---

## Milestone G — glass, last

- [ ] `NSGlassEffectContainerView` wrapping the whole sidebar, one container
- [ ] Selection indicator animates position between rows
- [ ] `if #available(macOS 26, *)`, `NSVisualEffectView` fallback
- [ ] Reduce-transparency fallback

**Gate:** measured CPU/energy delta vs the flat build, recorded in
`docs/research/`. Content area has **zero** glass.
