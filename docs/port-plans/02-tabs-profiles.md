# 02 — Port Pane tab lifecycle + spaces/profile isolation into Ora ("Pane" fork)

Status: research plan only. No source modified. No build run (Xcode absent).
Ora UI (SwiftUI sidebar, tab lists, settings screens) is unchanged in every step below.
All changes are in the engine/persistence layer: `BrowserPage`, `BrowserEngine`,
`Tab`, `TabManager`, `ModelConfiguration+Shared`, plus tests/harness.

Conventions: `ora:` = `repos/ora/`, `pane:` = `repos/pane/`. Line refs are to the
trees as read on 2026-10-22.

---

## 1. What Ora currently does

### 1.1 Tab model

- `Tab` is a SwiftData `@Model` class, not a value type
  ([Tab.swift](ora/ora/Features/Tabs/Models/Tab.swift:19)). Persisted fields:
  `id`, `url`/`urlString`, `savedURL`, `title`, `favicon`, `createdAt`,
  `lastAccessedAt`, `type` (`TabType: pinned | fav | normal`,
  [Tab.swift](ora/ora/Features/Tabs/Models/Tab.swift:5)), `order`,
  `faviconLocalFile`, `backgroundColorHex`.
- The live page is transient: `@Transient var browserPage: BrowserPage?`
  ([Tab.swift](ora/ora/Features/Tabs/Models/Tab.swift:42)), plus transient
  `isWebViewReady`, `isPlayingMedia`, delegates and managers
  (lines 36–55). There is **no persisted lifecycle/discard state and no
  `interactionState` anywhere in Ora** (tree-wide search: zero hits in `repos/ora`).
- Kind semantics already partly mirror Pane: `pinned`/`fav` tabs keep a
  `savedURL` and restore to it instead of the wandered-to URL
  ([Tab.swift](ora/ora/Features/Tabs/Models/Tab.swift:235),
  [TabManager.swift](ora/ora/Features/Tabs/State/TabManager.swift:113));
  closed `pinned`/`fav` tabs are not deleted, only de-web-viewed
  ([TabManager.swift](ora/ora/Features/Tabs/State/TabManager.swift:394)).

### 1.2 Persistence — SwiftData, one store

- Yes, SwiftData. Container schema is exactly `[TabContainer, History, Download]`
  at `Application Support/Ora/OraData.sqlite`
  ([ModelConfiguration+Shared.swift](ora/ora/Core/Extensions/ModelConfiguration+Shared.swift:10));
  `createOraContainer` re-lists the same three types (line 21) — both lists must
  change together for any new model.
- Private windows get `isStoredInMemoryOnly: true` (line 8) and therefore share
  no on-disk tab store. OraRoot builds one container/context per window and
  **deletes the store file then `fatalError`s on container failure**
  ([OraRoot.swift](ora/ora/App/OraRoot.swift:43)).
- Saves are ad-hoc `try? modelContext.save()` calls sprinkled through
  `TabManager` (e.g. lines 122, 171, 289, 480) — no debounce, no single writer.
- Recently-closed tabs: in-memory `[ClosedTabSnapshot]`, capped at 5, normal
  tabs only, never persisted
  ([TabManager.swift](ora/ora/Features/Tabs/State/TabManager.swift:61),
  line 388, `restoreLastTab` line 415). Pane caps at 25
  ([TabModel.swift](pane/Sources/PaneCore/TabModel.swift:13)).

### 1.3 Session restore

- Relaunch restore is "whatever SwiftData kept": `initializeActiveContainerAndTab`
  picks the most-recently-accessed container and tab
  ([TabManager.swift](ora/ora/Features/Tabs/State/TabManager.swift:144)).
- Only the active tab is materialised at launch; other tabs get a page lazily on
  activation (`activateTab` → `restoreTransientState` if `!isWebViewReady`,
  [TabManager.swift](ora/ora/Features/Tabs/State/TabManager.swift:465);
  same lazy path in
  [BrowserView.swift](ora/ora/Features/Browser/Views/BrowserView.swift:125)).
  This already matches Pane's "rows, not renderers" launch shape.
- **But restore is a fresh navigation**: `restoreTransientState` creates a
  `BrowserPage` and loads `savedURL ?? url`
  ([Tab.swift](ora/ora/Features/Tabs/Models/Tab.swift:234)). Back/forward list,
  scroll position and form state are lost on every de-web-viewing and every
  relaunch. Nothing captures state on quit either — `applicationShouldTerminate`
  only posts `.quitRequested` for a confirm dialog
  ([OraApp.swift](ora/ora/App/OraApp.swift:17)).

### 1.4 Inactive-tab cleanup (Ora's current "discard")

- A 60 s timer runs `cleanupOldTabs` + `removeOldTabs` + `autoClearContainerTabs`
  ([TabManager.swift](ora/ora/Features/Tabs/State/TabManager.swift:542)).
- `cleanupOldTabs` (line 484): if `!tab.isAlive && tab.isWebViewReady &&
  tab != activeTab && !tab.isPlayingMedia && tab.type == .normal` →
  `tab.destroyWebView()`. `isAlive` uses one global `tabAliveTimeout`
  ([Tab.swift](ora/ora/Features/Tabs/Models/Tab.swift:60)), default **1 hour**,
  picker values 1 h–2 days or "Never"
  ([SettingsStore.swift](ora/ora/Core/Utilities/SettingsStore.swift:295)).
- `destroyWebView()` just tears down and nils the page
  ([Tab.swift](ora/ora/Features/Tabs/Models/Tab.swift:295)) — **no state
  capture first**, so cleanup is exactly the data-losing path Pane's discard
  exists to replace. Re-activation re-navigates to the URL (§1.3).
- Guards are weaker than Pane's: only `isPlayingMedia` (set from the injected
  media bridge, [MediaController.swift](ora/ora/Features/Player/State/MediaController.swift:85))
  and active-tab. No media-session, unsaved-form, or explicitly-pinned guard;
  pinned/fav are exempt only by the `type == .normal` condition, and
  `removeOldTabs`/`autoClearContainerTabs` **delete** idle normal tabs outright
  (lines 500, 519) rather than discarding them.
- `BrowserPage.teardown()` stops loading, nils delegates, removes scripts and
  detaches the view ([BrowserPage.swift](ora/ora/Core/BrowserEngine/BrowserPage.swift:174))
  — the right deallocation hook, already present.

### 1.5 Spaces → data stores

- Ora's "space" is `TabContainer` (`id`, `name`, `emoji`, timestamps, cascade
  `tabs`/`folders`) ([TabContainer.swift](ora/ora/Features/Tabs/Models/TabContainer.swift:7)).
  There is no separate Profile entity: **container ID is the profile ID**.
- The seam is already Pane-shaped: `BrowserEngineProfile(identifier:isPrivate:)`
  uses `WKWebsiteDataStore.nonPersistent()` for private and
  `WKWebsiteDataStore(forIdentifier: identifier)` otherwise
  ([BrowserEngineProfile.swift](ora/ora/Core/BrowserEngine/BrowserEngineProfile.swift:12)).
- Callers pass the container ID: `makeProfile(identifier: container.id, …)`
  ([Tab.swift](ora/ora/Features/Tabs/Models/Tab.swift:214),
  [PrivacyService.swift](ora/ora/Features/Privacy/Services/PrivacyService.swift:16)).
- `BrowserEngine.makeProfile` caches non-private profiles forever in
  `[ProfileKey: BrowserEngineProfile]` guarded by `NSLock`
  ([BrowserEngine.swift](ora/ora/Core/BrowserEngine/BrowserEngine.swift:44)).
  **No eviction, ever** — the lazy-activation/teardown half of Pane §3 is missing.
- Each `restoreTransientState` builds a fresh `BrowserPage` whose
  `WKWebViewConfiguration.websiteDataStore = profile.dataStore`
  ([BrowserPage.swift](ora/ora/Core/BrowserEngine/BrowserPage.swift:25)).
  `BrowserPrivacyService.prepareConfiguration` runs async and gates the first
  load via `pendingLoadRequest` (lines 81–87, 190) — any restore change must
  respect this gate.
- Private mode quirk to preserve-or-fix deliberately: `makeProfile` returns a
  **new** profile per call for private (line 47), i.e. a new `nonPersistent()`
  store per tab — private tabs do not share a cookie jar with each other today.

---

## 2. What Pane does and why

### 2.1 Two-tier lifecycle (spec §4, ADR 0001)

- Originally specced three tiers (`live | frozen | discarded`); ADR 0001
  collapsed it to two because WebKit already suspends a detached `WKWebView`
  (`WKPreferences.inactiveSchedulingPolicy` defaults to `.suspend` on macOS 15+
  SDK links). "Frozen" is one explicit line; **all budget goes to
  discard/restore, the only tier that deallocates the view and reclaims memory**
  ([0001](pane/docs/decisions/0001-two-tier-tab-lifecycle.md:18),
  [spec §4](pane/docs/pane-browser-spec.md:125)).
- Model: `LifecycleState: live | discarded`
  ([Tab.swift](pane/Sources/PaneCore/Tab.swift:21)); kinds
  `essential | pinned | ephemeral` with idle thresholds **5 min ephemeral,
  15 min pinned/essential** (lines 74–81).
- `TabModel.discardCandidates(at:force:)`
  ([TabModel.swift](pane/Sources/PaneCore/TabModel.swift:98)): live only, never
  the selected tab, never when `!isDiscardable`, idle threshold per kind;
  `force` skips only the idle check (benchmarks must measure what the product
  would actually discard).
- Four never-discard conditions in one place, `Tab.isDiscardable`
  ([Tab.swift](pane/Sources/PaneCore/Tab.swift:68)): playing audio, active
  `MediaSession`, unsaved form state (`beforeunload`), explicitly nailed by
  user. Each has a dedicated headless check
  ([TabModelChecks.swift](pane/Sources/PaneCheck/TabModelChecks.swift:106)).
- Discard = capture `webView.interactionState` → persist blob → remove view →
  **nil the engine** ([BrowserWindow.swift](pane/Sources/PaneUI/BrowserWindow.swift:511);
  capture/restore seam in
  [WKWebEngine.swift](pane/Sources/PaneWeb/WKWebEngine.swift:128)).
  Restore = new engine, **assign `interactionState` before the view enters the
  hierarchy**, else load `restoreURL` (BrowserWindow.swift:498). Essentials
  restore to `homeURL`, not the wandered URL (Tab.swift:84).
- Session restore: every restored tab starts `.discarded`; only the landing tab
  materialises (BrowserWindow.swift:418). Snapshots also captured on every
  `saveNow` for live tabs (line 397), writes debounced 500 ms (line 390).
- Caveat found in Pane's own code: three of the four guard flags
  (`isPlayingAudio`, `hasActiveMediaSession`, `hasUnsavedFormState`) are
  **model-and-test only** — nothing in `PaneWeb`/`PaneUI` ever sets them
  (tree-wide search). Only `userPinnedExplicitly` is wired (BrowserWindow.swift:235).
  Porting the model without wiring detection ports the tests, not the protection.

### 2.2 Spaces/profiles (spec §3, ADR 0002)

- `Profile` owns one stable `dataStoreUUID`; `Space` merely references
  `profileID`, and two spaces may share one profile
  ([Space.swift](pane/Sources/PaneCore/Space.swift:12)).
- ADR 0002: `WKProcessPool` is deprecated and inert; network/GPU processes are
  singletons; only WebContent partitions. Isolation claim is **data isolation
  only — never say "process isolation"**
  ([0002](pane/docs/decisions/0002-no-process-pool-isolation.md:18)).
- Lazy activation: store created on first switch; teardown after **10 min
  inactive AND all tabs discarded**; teardown = release the reference, **never
  `WKWebsiteDataStore.remove(forIdentifier:)`** (it deletes user data)
  (Space.swift:149, spec §3 line 107).
- Cross-space move carries the URL, not the blob, with a profile-change warning
  (BrowserWindow.swift:258) — a blob is meaningless under another data store.

### 2.3 Persistence (spec §2, §6)

- One SQLite file, WAL, **single `Store` actor**; `sqlite3_` may appear nowhere
  else ([Store.swift](pane/Sources/PaneCore/Store.swift:14), CLAUDE.md invariant).
  Schema: `profile`, `space`, `tab`, `session_snapshot(tab_id, wk_interaction_state BLOB)`
  (Store.swift:72). Launch load is a synchronous read-only second handle because
  `init` cannot `await` (Store.swift:115).

### 2.4 Measured targets (PROGRESS.md, 2026-08-07, macOS 26.5.2)

| Gate | Target | Measured |
|---|---|---|
| Restore latency | p50 < 200 ms, 20 runs, scroll proven restored | **p50 87 ms** (status block) / p50 80.962 ms, p95 122.164 ms, blob 695 B, `restored_scroll_y=1200`, PASS ([PROGRESS.md](pane/PROGRESS.md:26), lines 72–82) |
| Discard memory | footprint drop, compressor must not grow | 9 tabs/9 WebContent procs/215 MB → 1 proc/58 MB; **157 MB freed (73%)**, compressor delta −54 pages, PASS ([discard result](pane/docs/research/2026-08-07-discard-memory-result.md:11)); status block cites a different run, "freed 75MB of 204MB" (PROGRESS.md:27) — treat 157 MB run as canonical, flag the stale summary |
| Profile isolation | two stores, same cookie name, distinct values, disjoint dirs | **PASS** (PROGRESS.md:30; gate definition §Milestone D, line 209) |
| Kill -9 restore | relaunch returns all tabs, non-active as discarded | 10 tabs → 11 rows, 8 discarded, 33 MB, 4 WebContent procs (PROGRESS.md:176) |

Honesty bound from Pane's own research: `interactionState` assignment performs
a **real navigation**, so sub-200 ms holds for small/cached fixture pages; real
SPAs budget 0.8–3 s. The 200 ms gate is a fixture gate, not a product promise
([lifecycle research](pane/docs/research/2026-08-07-lifecycle.md:106)).

---

## 3. Gap analysis + minimal change set (no UI changes)

### 3.1 Already matching — do not rebuild

| Pane behaviour | Ora today |
|---|---|
| `WKWebsiteDataStore(forIdentifier:)` per space | Done: container ID is the identifier (§1.5) |
| Lazy tab materialisation at launch/activation | Done (§1.3) |
| Pinned/fav restore to saved URL (≈ essential `homeURL`) | Done via `savedURL` (§1.1) |
| Injected-media playing flag guarding cleanup | Done via `MediaController` → `isPlayingMedia` |
| 60 s cleanup sweep cadence | Done (TabManager.swift:543) |
| Closed-tab reopen stack | Done, but cap 5 + unpersisted (Pane: 25) |

### 3.2 Differences that matter

1. **No `interactionState` capture/restore at all.** Cleanup and relaunch both
   re-navigate from URL, losing history/scroll/forms. This is the whole port.
2. **Thresholds**: one global 1 h default vs Pane's per-kind 5/15 min; Ora also
   *deletes* very idle tabs (`removeOldTabs`) where Pane only discards.
3. **Guards**: Ora checks audio + active only. No media-session, unsaved-form,
   or explicit-pin guard (pinned/fav are exempt by type, which conflates
   "kind" with "nailed").
4. **Profile cache never evicts**; no 10-min/all-discarded teardown, no
   shared-profile concept (container ≡ profile, 1:1 forever).
5. **Cross-container tab move** (`moveTabToContainer`,
   TabManager.swift:139) silently keeps the tab; if discard blobs existed, a
   moved tab's blob must be dropped (different data store).
6. **No benchmarks or isolation tests** in Ora (see §4).

### 3.3 Recommended persistence approach (the Store-actor conflict)

Pane's invariant "all SQLite through one `Store` actor" conflicts head-on with
Ora: Ora is SwiftData end-to-end (tabs, history, downloads, passwords) with a
shared `ModelContainer`, and `Tab` is an `@Model` referenced by views via
`@Query`. Importing Pane's `Store` actor would create a **second writer for
tab state** — dual source of truth, no FK/cascade between the two databases,
and a sync bug farm. **Recommendation: do not port `Store`. Keep SwiftData as
the single writer; port Pane's *semantics* (blob per tab, captured on discard /
terminate / debounced save) into SwiftData.** Specifically:

- New `@Model TabSessionSnapshot`: `tabID: UUID` (unique), `interactionState:
  Data` marked `@Attribute(.externalStorage)`, `capturedAt: Date`. External
  storage keeps multi-KB–MB blobs out of the row store.
- Register it in **both** lists in
  [ModelConfiguration+Shared.swift](ora/ora/Core/Extensions/ModelConfiguration+Shared.swift:12)
  (schema array and `ModelContainer(for:)` list). Lightweight migration should
  absorb an additive model; verify against a copy of a real `OraData.sqlite`.
- Private windows use the in-memory container (§1.2), so snapshots are
  automatically never persisted for private tabs — the correct behaviour, free.
- Delete the snapshot row when its tab is deleted (cascade manually in
  `deleteContainerContents` / `closeTab` delete path) and when a tab moves
  container. Never write snapshots for `isPrivate` tabs even in a shared
  context — assert it in tests.
- Rejected alternative: a blob `Data?` column directly on `Tab`. Simpler, but
  every `@Query` fetch of tab lists would drag blob metadata through the
  sidebar's fetch path; a separate entity keeps list fetches lean and deletable
  independently.

### 3.4 Minimal change set, in order

**Step 1 — Engine seam (`BrowserPage`/`BrowserEngineProfile`).**
- In [BrowserPage.swift](ora/ora/Core/BrowserEngine/BrowserPage.swift:90):
  add `captureInteractionState() -> Data?` (`webView.interactionState as? Data`;
  the property is `Any?` and non-`Data` assignment silently no-ops — cast and
  log) and `restoreInteractionState(_:) -> Bool` that assigns **before** the
  view is attached and returns `webView.backForwardList.currentItem != nil` as
  the decode check (timer-based fallback races cold process launch; see
  lifecycle research §"50ms" refutation). Caller falls back to `load(url)` on
  `false`.
- Set `preferences.inactiveSchedulingPolicy = .suspend` explicitly in the
  `WKWebViewConfiguration` block (BrowserPage.swift:23) — free tier, ADR 0001.
- Capture must be read **before** detach/teardown (scroll state is pushed
  async; reading after removal can capture stale state — same research).
- In [BrowserEngineProfile.swift](ora/ora/Core/BrowserEngine/BrowserEngineProfile.swift:4):
  no change for creation; add `release`/eviction support in
  [BrowserEngine.swift](ora/ora/Core/BrowserEngine/BrowserEngine.swift:44):
  `releaseProfile(identifier:)` dropping the cache entry once §Step 4's
  eligibility rule fires. Never call `remove(forIdentifier:)`.

**Step 2 — Pure discard policy (new file, no WebKit).**
- New `ora/Core/BrowserEngine/DiscardPolicy.swift`: a `Sendable` struct
  porting `discardCandidates`/`isDiscardable` from
  [TabModel.swift](pane/Sources/PaneCore/TabModel.swift:98) /
  [Tab.swift](pane/Sources/PaneCore/Tab.swift:68), operating on a lightweight
  `TabDiscardFacts` value (id, kind mapped from `TabType`, lifecycle,
  `lastAccessedAt`, isActive, isPlayingMedia, hasActiveMediaSession,
  hasUnsavedFormState, userPinnedExplicitly) so it is unit-testable without
  SwiftData or a window. Map kinds: `.normal → ephemeral (5m)`,
  `.pinned → pinned (15m)`, `.fav → essential-equivalent`: restore-to-`savedURL`
  behaviour already exists; give fav the 15 m threshold **and**
  `userPinnedExplicitly` treatment only if product confirms fav == "nailed"
  (open question Q2).

**Step 3 — Wire lifecycle into `Tab`/`TabManager`.**
- [Tab.swift](ora/ora/Features/Tabs/Models/Tab.swift:19): add persisted
  `isDiscarded: Bool` (default false; lightweight migration), transient
  `hasActiveMediaSession`/`hasUnsavedFormState` flags. Add
  `discard()` = capture blob → hand to snapshot store → `destroyWebView()` →
  `isDiscarded = true`; extend `restoreTransientState` (line 200) to try
  snapshot restore first, fall back to current URL load, clear `isDiscarded`,
  and delete/refresh the snapshot after successful commit. Private tabs:
  keep the blob in memory only (a `[UUID: Data]` on `TabManager`), never in
  the snapshot model.
- **Wire the guards, don't just declare them** (Pane didn't): audio exists
  (`isPlayingMedia`); media-session needs a flag from the existing
  `mediaEvent` bridge / `MediaController.Session.wasPlayed`; unsaved-form
  needs a `beforeunload`/dirty-form signal — cheapest honest v1 is a user
  script in the isolated content world reporting form dirtiness, failing
  **closed** (treat unknown as dirty for tabs with a detected form). If v1
  cannot wire a guard, the policy must treat it as blocking, not absent.
- [TabManager.swift](ora/ora/Features/Tabs/State/TabManager.swift:484):
  replace the body of `cleanupOldTabs` with the Step-2 policy + `tab.discard()`.
  Keep the 60 s timer. Keep `removeOldTabs`/`autoClearContainerTabs` deletion
  semantics untouched (they are user-configured deletion policies, not
  discard) but make them delete the snapshot row too.
- Session restore: after `initializeActiveContainerAndTab` (line 144), mark
  every tab with no live page `isDiscarded = true`; capture snapshots for all
  live tabs on quit — hook where `.quitRequested` is handled
  ([OraRoot.swift](ora/ora/App/OraRoot.swift:152)) before
  `reply(toApplicationShouldTerminate: true)`, plus the existing debounced
  saves. This is the kill -9 gate equivalent.
- `closeTab` for pinned/fav (line 394) should go through `discard()` rather
  than bare `destroyWebView()` so reopening restores state, and
  `moveTabToContainer` (line 139) must delete the moved tab's snapshot.

**Step 4 — Profile teardown (no shared profiles in v1).**
- Track per-container `lastAccessedAt` (already on `TabContainer`) + all-tabs-
  discarded; on the same 60 s timer, call `BrowserEngine.releaseProfile` when
  Pane's rule (10 min, non-current, all discarded) fires, porting
  `SpaceModel.isTeardownEligible`
  ([Space.swift](pane/Sources/PaneCore/Space.swift:155)) as a pure function.
- Do **not** introduce a separate Profile entity or shared profiles in this
  port: Ora's UI has no surface for sharing, and container≡profile already
  gives data isolation. Record as a deliberate scope cut (Q3).

**Step 5 — Snapshot hygiene.**
- Cap blob retention: log blob sizes in the bench; if p95 lands in MBs
  (unbounded per lifecycle research), add a per-tab size cap with URL-fallback
  rather than persisting unbounded state. Delete snapshots for tabs whose URL
  has since navigated to a different container.

Out of scope: thumbnail capture on discard (Pane itself still lacks it,
PROGRESS.md:199), sidebar "discarded" dimming (that is a UI change), frozen
tier (ADR 0001 says it does not exist), any `WKProcessPool` code (ADR 0002).

---

## 4. How to verify (no Xcode yet — write these first, run when available)

Ora's test target is `oraTests` (Swift Testing, `@testable import Ora`,
[oraTests.swift](ora/oraTests/oraTests.swift:10)); `project.yml` already wires
`TEST_HOST` to the built app
([project.yml](ora/project.yml:150)), so WebKit-bearing tests can run hosted.
Pane's own checks are a standalone harness, not XCTest — port the assertions,
not the harness.

1. **Policy tests (pure, unhosted logic).** Port
   [TabModelChecks.swift](pane/Sources/PaneCheck/TabModelChecks.swift:83)
   suites to Swift Testing against Step-2 `DiscardPolicy`: per-kind thresholds,
   selected-tab exemption, **one test per never-discard condition** (lines
   106–129), discarded-not-recandidate, restore resets idle clock. Add a
   mutant check: dropping the audio guard must fail a named test.
2. **Snapshot store round-trip.** Port
   [StoreChecks.swift](pane/Sources/PaneCheck/StoreChecks.swift:62): save blob
   against an in-memory `ModelContainer` (the private config already provides
   one), reopen/fetch, assert byte-identical and full-length; assert private
   tabs write nothing; assert tab deletion removes the row.
3. **Isolation check.** Port
   [IsolationCheck.swift](pane/Sources/PaneHarness/IsolationCheck.swift:17)
   as a hosted test: two fixed UUIDs → `BrowserEngine.shared.makeProfile`,
   assert stores are distinct objects, neither is `.default()`, set the
   `session` cookie to different values via `httpCookieStore`, assert no
   cross-visibility and simultaneous distinctness, assert distinct on-disk
   dirs under `~/Library/WebKit`. Use throwaway UUIDs and
   `WKWebsiteDataStore.remove(forIdentifier:)` **in test teardown only**
   (deleting test data is the one legitimate use). Also add the negative
   control Pane lacks: a `.default()`-store tab must FAIL the leak assertion,
   proving the test can fail.
4. **Restore bench.** Port [Bench.swift](pane/Sources/PaneHarness/Bench.swift:30)
   behind a Debug launch argument (e.g. `--bench-restore` read in
   `AppDelegate.applicationDidFinishLaunching`,
   [OraApp.swift](ora/ora/App/OraApp.swift:7)): local fixture page scrolled to
   y=1200, capture via `BrowserPage`, 20 restores, `ContinuousClock`, emit the
   same JSON keys (`p50_ms`, `p95_ms`, `state_bytes`, `restored_scroll_y`,
   `scroll_restored`, `pass`). Gate: p50 < 200 ms **and** scroll restored.
   Prefer driving it through `BrowserPage` (not a raw `WKWebView`) so the
   `BrowserPrivacyService` readiness gate (BrowserPage.swift:81) is inside
   the measurement.
5. **Discard-memory bench.** Adapt `Scripts/bench-discard.sh` per
   [discard result](pane/docs/research/2026-08-07-discard-memory-result.md:11):
   8+ heavy tabs, force sweep through the real `TabManager` path, compare
   `phys_footprint` (never RSS) of WebContent processes that did not exist
   before launch, and require `vm_stat` compressor pages not to grow. Report
   freed MB and process count before/after; expect the selected tab's engine
   to survive.
6. **Kill -9 session gate.** Seed 10 tabs across kinds, `kill -9`, relaunch:
   all rows return, only the landing tab has a page, footprints stay in the
   tens of MB (Pane reference: PROGRESS.md:176).
7. **Regression gate.** Existing `oraTests` suite must stay green; run
   `xcodegen generate` then the `ora` scheme's test action once Xcode exists
   (targets/scheme already declared, project.yml:163).

---

## 5. Risks / open questions

- **R1 `interactionState` is `Any?`, undebuggable on failure.** Non-`Data`
  blobs and undecodable blobs silently no-op; cross-version persistence is
  not guaranteed by Apple. Mitigations are built into Step 1 (cast check,
  `backForwardList.currentItem` probe, URL fallback) — do not ship without
  all three. It also does not carry `sessionStorage`, live JS heap, WebSocket
  or media position: an ungated discard can still lose user work, which is
  why §3.4 insists guards be wired or fail closed.
- **R2 Restore latency on real pages.** The 200 ms target is fixture-true
  only (§2.4). Product copy and any UI affordance must not promise it for
  SPAs; if a discarded-tab indicator is ever added, it needs a "restoring"
  state, not instant-open expectations.
- **R3 SwiftData migration.** Adding `TabSessionSnapshot` + `isDiscarded`
  should be a lightweight migration, but OraRoot's failure path deletes the
  store and `fatalError`s (OraRoot.swift:43) — a failed migration becomes
  total data loss. Gate the migration on a copied real-world store before
  shipping, and consider softening that failure path in a separate change.
- **R4 Blob size.** macOS applies no truncation; deep-history SPA tabs may
  produce MB-scale blobs. Bench must report p95 blob size before the snapshot
  store ships; Step 5's cap depends on that number.
- **R5 Private-store semantics change.** Sharing one `nonPersistent()` store
  across private tabs (fixing §1.5's per-tab stores) changes login behaviour
  in private windows. Decide explicitly; the discard port does not require it.
- **Q1** Should Ora's existing `tabAliveTimeout` setting (1 h default) be
  retired in favour of Pane's fixed 5/15 min per-kind thresholds, or should
  the thresholds scale from it? The Settings UI cannot change, so retiring it
  orphans a visible picker — product decision needed.
- **Q2** Is Ora `fav` ≡ Pane `essential` (nailed, never discard) or merely
  pinned-with-thumbnail (15 min)? §3.4 assumes the latter for discard timing
  but keeps restore-to-`savedURL`; confirm before Step 2 lands.
- **Q3** Shared profiles (two spaces, one login) are cut from v1 (§3.4 Step 4).
  Confirm nobody's spaces workflow depends on it — Ora has never had it, so
  this is a non-regression, but it is a divergence from Pane spec §3.
- **Q4** Recently-closed cap 5 → 25 and persisting the closed stack: trivial
  once snapshots exist, but it is a behaviour change visible in reopen flows;
  include or defer?
- **Q5** GPL-3.0: Ora is GPL-3.0 and Pane is the user's own earlier work —
  confirm licence compatibility/attribution expectations before copying Pane
  code (policy functions, bench) rather than reimplementing from this plan.
