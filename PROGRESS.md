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

**Current phase:** E complete; polish and Arc parity (docs/ui-parity.md)
**App launchable:** yes — `./Scripts/run.sh`
**Last verified gate:** full `./Scripts/gate.sh phase` — **all green** (2026-08-07)

```
unit checks        33 suites, 98 assertions, 0 failed
scenarios          10 scenarios, 18 assertions, 0 failed
mutation canary    5/5 mutants caught
restore latency    p50 87ms / 200ms, scroll restored
discard memory     freed 75MB of 204MB, compressor delta 0
visual goldens     ratio 0.0000
sidebar scroll     p95 4.7ms / 8ms at 201 rows
profile isolation  PASS
download quarantine PASS
DRM (FairPlay)     GO
```

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

- [x] `Fixtures/drm-probe.html` calling `requestMediaKeySystemAccess('com.apple.fps')`
- [ ] Netflix / Disney+ / Apple TV+ / YouTube checked by hand, 1080p and 4K separately
- [x] Result written to `docs/research/2026-08-07-drm-probe-result.md`

**Gate:** the FairPlay answer is written down. If FairPlay is unavailable in a
third-party `WKWebView`, that is a product-defining fact and it changes what
Pane is — surface it immediately rather than continuing.

**RESULT 2026-08-07: PASS — GO.** All four `com.apple.fps` variants are
AVAILABLE to an ad-hoc-signed binary with **no entitlements**. Widevine and
PlayReady return `NotSupportedError`. ClearKey works as a control, proving EME
is genuinely live rather than the result being a probe artefact.

Caveat that shapes UI copy: every system resolves to `sessionTypes:
["temporary"]`, `persistentState: "not-allowed"`. **Streaming works; offline
downloads do not.** Say "offline downloads unavailable", never "DRM broken".

Manual playback against real Netflix / Disney+ / Apple TV+ accounts is still
outstanding — the probe proves the CDM is reachable, not that any given service
permits us.

---

## Milestone B — it has tabs

Tab model, lifecycle state machine, sidebar with flat colours and real drag/drop.

- [x] Tab model + two-tier lifecycle state machine in `PaneCore`, headless — 49 assertions
- [x] `NSOutlineView` sidebar — conventional data source, **not** diffable
- [x] Drag and drop, `NSPasteboard` custom UTI + `public.url` fallback — *not yet exercised by a test*
- [x] ⌘T / ⌘W / ⇧⌘T / ⌃⌘S via the command bus

**Gate:** every transition in the (corrected, two-tier) §4 model covered by
headless tests against the fake engine protocol, including all four
never-discard conditions. 200 sidebar rows scroll without dropped frames. Drag
reorder survives relaunch. Visual golden reviewed by actually looking at it.

**RESULT 2026-08-07: PARTIAL — do not mark this phase complete.**

Passing:
- Lifecycle model: 49 assertions, 16 suites, all four never-discard conditions
  covered one suite each, plus a fifth (the selected tab never discards).
  Verified non-vacuous by planting a mutant that drops the audio guard — the
  suite fails and names the audio condition specifically.
- Sidebar renders correctly: three sections, essentials as a 4-per-row icon
  grid, pinned and today as lists, spacing not headers, selection highlighted.
  **Verified by looking at a screenshot, manually.**
- Chrome sync bug found and fixed: switching tabs left the title bar and address
  bar showing the previous tab's page. See `docs/api-notes/appkit.md`.

**Not yet done — this is what blocks the phase:**
- [x] Drag reorder survives relaunch — persistence landed in milestone C
- [x] Scenario harness: 7 end-to-end scenarios through the command bus, with a
      mutation canary proving the suite can actually fail
- [x] **Visual golden automation: SOLVED** on the seventh approach, after
      escalating to a stronger model per the two-strike rule. `Capture.composite`
      needs no TCC grant and no activation. Root cause was subtler than the
      working theory: `cacheDisplay` *samples* composited layer contents rather
      than re-drawing, so an unattended window has nothing to sample —
      `displayIgnoringOpacity` re-draws. Full write-up, including the six
      failures, in `docs/api-notes/appkit.md`.
- [x] **200-row scroll: PASS.** p50 3.0ms, p95 4.7ms against an 8ms half-frame
      budget. Result in `docs/research/2026-08-07-sidebar-scroll-result.md`.
      Note it establishes "AppKit is fast enough", NOT "faster than SwiftUI" —
      that comparison was never run and the invariant forbids building the
      SwiftUI version to find out.

> Correction folded in: `NSOutlineViewDiffableDataSource` does not exist.
> See `docs/research/2026-08-07-architecture.md`.

---

## Milestone C — it remembers

Session restore and the discard/restore tier that carries the memory claim.

- [x] Continuous writes to SQLite through the `Store` actor, debounced 500ms
- [x] `interactionState` snapshot on terminate and on every discard
- [x] Discard / restore — *thumbnail capture still outstanding*
- [x] Four never-discard conditions enforced (49 assertions)

**Gate:** `kill -9` mid-session, relaunch, everything returns. Discard a tab and
verify `phys_footprint` actually dropped **and** `vm_stat` shows it was not
merely compressed. Report `phys_footprint`, never RSS.

**RESULT 2026-08-07: PASS on restore.**

Seeded 10 tabs across all three kinds, `kill -9` the process, relaunched with
only `--store`:

```
before kill:  tabs=10  snapshots=10
after relaunch: tabs=11  snapshots=11   (11th is the new-tab from the fresh run)
  lifecycle:  discarded=8  live=3
  by kind:    essential=5  pinned=2  ephemeral=4
  titles all survived, e.g. "Gmail: Secure, AI-Powered Email…", "Hacker News"
  phys_footprint 33 MB, 4 WebContent processes for 11 tabs
```

8 of 11 restored as `discarded`, so eleven tabs cost eleven rows rather than
eleven renderers — the lazy materialisation §6 asks for.

**Still outstanding in this phase:**
- [x] **The discard-then-measure benchmark: PASS.** `./Scripts/bench-discard.sh 8`
      — 9 tabs / 9 WebContent processes / 215 MB → 1 process / 58 MB.
      **157 MB freed (73%).** Compressor pages went *down* by 54, so the memory
      was genuinely released rather than squeezed. Full result in
      `docs/research/2026-08-07-discard-memory-result.md`.
- [ ] Thumbnail capture on discard

---

## Milestone D — it has spaces

- [x] `WKWebsiteDataStore(forIdentifier:)` per profile
- [x] Space switching, per-space tabs/engines/stores
- [x] Lazy profile activation; teardown eligibility modelled

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

- [x] Downloads — `WKDownloadDelegate`, uniquing, resume data, **quarantine verified**
- [x] Uploads — `runOpenPanelWith:`, multiple + directory
- [x] Basic/digest/NTLM auth — sheet; per-profile scoping is automatic (see below)
- [x] Cert errors — `SecTrustEvaluateWithError`, native interstitial, exceptions keyed by host + cert SHA-256, session-scoped
- [x] Find in page — `NSTextFinder` against `NSTextFinderClient`
- [x] Context menus — `PaneWebView` overriding `NSView.willOpenMenu(_:with:)`
- [x] Crash recovery — no silent reload, per-origin counting, JS-disabled escape hatch

**Gate:** every item exercised against the local fixture server. Download's
`com.apple.quarantine` xattr **actually present** (verify with `xattr -p`).
401 auth, self-signed cert interstitial, renderer crash with no reload loop.

**RESULT 2026-08-07: download gate PASS.** `Pane --verify-download <url>`
against a local fixture server:

```
PASS | quarantine: True | provenance: False
```

The xattr is present, so Gatekeeper prompts — that is the security property and
it holds. **Provenance URLs are a known limitation**, reported rather than
failed: they live in the LaunchServices events database, not the xattr, and
three attempts to populate them via `NSURLQuarantinePropertiesKey` did not take.
Arc's own rows are empty too. Full write-up and a "do not try a fourth variation
of X" note in `docs/api-notes/quarantine.md`.

**Two spec corrections folded in:**
- §6 says to scope credentials to a per-profile `URLCredentialStorage`. Neither
  needed nor possible — WebKit's network process installs a per-identifier
  credential store automatically when the data store has a `dataStoreIdentifier`.
- §6 expected a match count from `WKFindResult`. It has exactly one property,
  `matchFound: Bool`; there is no total and no current index, so "3 of 17" is
  impossible with public API. Uses `NSTextFinder` instead.

**Still outstanding in this phase:**
- [x] Cert interstitial is now the full-content-area AppKit view §6 describes,
      red/amber by severity with an "Advanced" chain disclosure
- [x] Downloads indicator in the sidebar footer, appearing only when relevant
- [x] Cross-space tab drag with the profile warning §5 requires
- [x] Downloads panel is an `NSPopover` off the sidebar button, with per-item
      progress bars and Dock-tile percentage — §6's shape
- [x] Per-space context submenu — §6's "what makes multi-space actually usable"
- [x] Fixture server built; auth, download and untrusted-cert paths now have
      scenarios, with a `security.trust_all_certs` mutant proving the cert
      assertion can actually fail

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
