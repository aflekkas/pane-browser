# Architecture decision document — synthesis of all 13 reports

**Date:** 2026-08-07

Produced by a synthesis agent given all 9 research reports and 4 adversarial
verifications. Where it conflicts with an individual report, the individual
report's citation wins — check the source before acting.

---

# PANE — ARCHITECTURE DECISION DOCUMENT
**Rev 1.0 · macOS 26 · Swift 6 · AppKit + WKWebView · solo developer**

Source: 9 research reports, 4 adversarial verification passes. **Verified areas:** profiles, lifecycle, credentials, drm-entitlement (this one was *overturned* — the researcher's verdict was wrong). **Unverified areas — treat every claim as one source deep:** liquidglass, boring-floor, zen-and-rivals, toolchain, architecture-risk. Where an unverified claim is load-bearing I have flagged it and put a probe in §5.

---

## 1. KILL LIST

Things that are impossible, entitlement-gated, or that you must stop planning for today.

### 1.1 BLOCKED — Passkeys are gated behind an Apple-reviewed, organization-only entitlement

This is the single biggest constraint on the project and it is not a technical one.

- `com.apple.developer.web-browser.public-key-credential` (macOS 13.3+) is the **only** way a WKWebView browser can do WebAuthn for arbitrary relying parties. Without it, WKWebView passkeys work only for RP IDs you declare in `com.apple.developer.associated-domains` — structurally impossible for a general browser.
- It is a **managed capability**. Apple's own text: you must **hold the Account Holder role for an organization's Apple Developer account** and submit https://developer.apple.com/contact/request/macos-browsers-passkeys/. An organization account requires a D-U-N-S number.
- Apple reviews against published criteria: HTTP + HTTPS schemes declared in Info.plist; on launch the app must present a URL field, web search, or curated bookmarks; it must navigate directly to the specified destination and render the expected content. **Pane must already be a credible browser before it can apply.**
- It is a *restricted* entitlement → requires a provisioning profile → **unreachable with ad-hoc signing and unreachable with a free Apple ID.**
- Unknown whether it can be exercised at all in local development pre-approval. Assume not. Build the passkey path last, feature-flagged, behind a protocol with a no-op implementation.

One researcher told you to *"budget zero time"* on macOS browser entitlements because `com.apple.developer.web-browser` is iOS-only. That is true of that exact string and false as guidance. The verifier overturned the verdict to **partially-blocked** for exactly this reason. Calendar risk: weeks to never.

### 1.2 BLOCKED — There is no way to read the user's existing passwords on macOS

- `ASSavePasswordRequest` and `ASGeneratePasswordsRequest` (the browser-side password plumbing) are `API_AVAILABLE(ios(26.2), visionos(26.2)) API_UNAVAILABLE(macos, tvos, watchos)`. Apple built them and shipped them iOS-only.
- `ASCredentialIdentityStore.getCredentialIdentities(...)` returns **your own extension's** index. The `ASCredentialIdentity` protocol has exactly four members — `serviceIdentifier`, `user`, `recordIdentifier`, `rank`. There is no secret field anywhere in the type.
- The only sanctioned path from Apple Passwords into Pane is a **one-time, user-initiated FIDO CXP import**: `ASCredentialImportManager.importCredentials(token: UUID) async throws -> ASExportedCredentialData` (macOS 26.0+, Swift-only symbol, absent from the ObjC headers).

**Passwords and passkeys are two different projects.** Passkeys: ~1–2 days of code, blocked on business approval. Passwords: build an entire vault, ~13–19 days. Do not budget them together.

### 1.3 DEAD — The `navigator.credentials` JS shim

`WKContentWorld` documentation, verbatim: *"The content world doesn't apply to the current document or DOM of a webpage… The content world affects only references to other JavaScript variables."* An override of `navigator.credentials` in an isolated world is **structurally invisible to page scripts**. It would have to live in `WKContentWorld.page`, where hostile pages detect and subvert it. And it is unnecessary — with the entitlement, WebKit's own `WebAuthenticatorCoordinatorProxy` handles `navigator.credentials.create/get` natively. Delete the shim plan. You write zero WebAuthn code.

### 1.4 DEAD — Chrome-style per-profile process isolation

`NetworkProcessProxy::ensureDefaultNetworkProcess()` returns a single app-wide process held in a `NeverDestroyed<WeakPtr>`; every data store is added as a **session inside that one process**. The GPU process is likewise a singleton. **Only WebContent processes are partitioned per profile.** No API changes this. Write this down before anyone writes marketing copy about "isolation."

`WKProcessPool` and `WKWebViewConfiguration.processPool` are `API_DEPRECATED("Creating and using multiple instances of WKProcessPool no longer has any effect.", macos(10.10, 12.0))`. Note the nuance the verifier caught: multiple pools are *not* inert — they still create real `WebProcessPool` objects with **fragmented process caches and prewarm pools**. They just never gave you isolation. Delete all process-pool code; do not replace it.

### 1.5 DOES NOT EXIST — APIs the verifiers could not find documentation for

| Named in spec / report | Reality |
|---|---|
| `NSOutlineViewDiffableDataSource` | Does not exist and never has. AppKit ships only `NSCollectionViewDiffableDataSource` and `NSTableViewDiffableDataSource`; the latter conforms only to `NSTableViewDataSource` and cannot be assigned to `NSOutlineView.dataSource` (typed `id<NSOutlineViewDataSource>`). |
| `WKWebExtensionControllerConfiguration(identifier:)` | **Hard compile error**, not a warning: "has been renamed to `WKWebExtensionController.Configuration`", obsoleted in Swift 3. Correct: `WKWebExtensionController.Configuration(identifier: uuid)`, macOS **15.4**, not 26. |
| `ASPublicKeyCredentialClientData(challenge:origin:topOrigin:crossOrigin:)` | Fabricated. Only `initWithChallenge:origin:` exists; `topOrigin`/`crossOrigin` are properties set after construction. |
| `ASAuthorizationError` 1004 as an "unentitled" signal | 1004 is `ASAuthorizationErrorFailed`, a generic catch-all. `notInteractive` is **1005**. Do not debug against 1004 as a state indicator. |
| `WKPreferencesPrivate.h` in the macOS SDK | No `*Private.h` headers ship in `WebKit.framework/Headers` at all. |
| `webView.mediaPlaybackState()` | Does not exist. It is `requestMediaPlaybackState()` (async). The bare `requestMediaPlaybackState:` spelling is deprecated macOS 11.3→12.0. |
| `disallow_webview=true` | Zero occurrences across Google's OAuth docs. The documented error is `disallowed_useragent`; the documented (2016) parameter was `suppress_webview_warning=true`. |
| `com.apple.developer.web-browser` on macOS | iOS/iPadOS 14.0 only. No macOS variant. |
| macOS GPU-process `.sb` sandbox profile in the WebKit tree | WebKit ships only `SandboxProfiles/ios/`. The claim that it contains "unconditional encrypted-media allowances" is invented. (The *conclusion* — no entitlement gates FairPlay — still holds.) |

### 1.6 iOS-ONLY — features you will have to rebuild by hand

- **`WKDownloadPlaceholderPolicy`** / `decidePlaceholderPolicy` / `didReceivePlaceholderURL` / `didReceiveFinalURL` — `API_AVAILABLE(ios(18.2), visionos(2.2))`. No macOS. Write `.download` temp files and move on finish yourself.
- **`WKUIDelegate.contextMenuConfigurationForElement`** and the whole `contextMenuWillPresent` / `willCommitWithAnimator` / `didEnd` family — `API_AVAILABLE(ios(13.0))`, takes `UIContextMenuConfiguration`. **They will never fire on macOS.** The macOS WebKit hook is SPI (`_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:`, macOS 10.14). Public path: subclass `WKWebView`, override `NSView.willOpenMenu(_:with:)`.
- **`WKWebView.isFindInteractionEnabled` / `.findInteraction`** — iOS 16 only. macOS gets `@interface WKWebView (WKNSTextFinderClient) <NSTextFinderClient>` (10.15.4+) instead.
- **`NSScrollEdgeEffectStyle` over web content** — `WKWebView.scrollView` is `#if TARGET_OS_IPHONE`. On macOS the style is reachable only via `NSTitlebarAccessoryViewController.preferredScrollEdgeEffectStyle` and `NSSplitViewItemAccessoryViewController.preferredScrollEdgeEffectStyle` (26.1+). The iOS scroll-edge-glass recipe does not port.

### 1.7 SPI-ONLY — you cannot have these and ship on the Mac App Store

| Capability | Only mechanism |
|---|---|
| Audio playback detection | `-[WKWebView _isPlayingAudio]` (KVO-compliant by design — WebKit explicitly fires `willChangeValueForKey`/`didChangeValueForKey` from `PageClientImplCocoa`). No public equivalent exists; Apple's own `WKWebExtensionTab.isPlayingAudio(for:)` asks *you*. |
| `<input accept=…>` filters | `WKOpenPanelParameters._acceptedMIMETypes` / `._acceptedFileExtensions` / `._allowedFileExtensions` |
| Find-in-page "3 of 17" | `_countStringMatches:options:maxCount:` + `_WKFindDelegate`. `WKFindResult` has exactly one property: `matchFound: Bool`. |
| Why a web process died | `_webView:webContentProcessDidTerminateWithReason:` (`_WKProcessTerminationReason`). The public callback carries no reason. |
| Trimming session-state blobs | `-_sessionStateWithFilter:` |
| `NSGlassEffectView.Legibility`, `_variant`, `_path`, `_scrimState` | Exported from shipping AppKit 26.5, absent from the public header. Do not touch. |

**This forces the distribution decision. See §3.0.**

### 1.8 UNCATCHABLE CRASHES on your own code paths

- `WKWebsiteDataStore(forIdentifier:)` raises `NSInvalidArgumentException` for a nil identifier **or any UUID failing `WTF::UUID::isValid()`** (all-zero and all-ones sentinels included). ObjC exception on the calling thread — **not a Swift error, uncatchable, terminates the process.** Generate UUIDs yourself; round-trip-validate anything read from your registry file.
- `THROW_IF_SUSPENDED` guards 163 call sites including `takeSnapshotWithConfiguration:`, `setInteractionState:`, `evaluateJavaScript:`, `reload`, `goBack`. **Never use `-_suspendPage:`/`-_resumePage:`** — it poisons the object permanently.
- `WKWebsiteDataStore.allDataStoreIdentifiers` crashes reproducibly (Apple Forums 822262, April 2026, open, DTS engaged, no workaround). The verifier corrected the mechanism: `WKWebsiteDataStore.mm` never calls `InitializeWebKit2` for anything; in the C++ layer, `defaultDataStore()` and `dataStoreForIdentifier()` **do** call it, while `fetchAllDataStoreIdentifiers()` and **`removeDataStoreWithIdentifier()`** both omit it. So `remove(forIdentifier:)` is exactly as unsafe as the enumerator as a first-WebKit-call — and your tombstone-retry runs at app startup, which is precisely where that bites. **All evidence is iOS; unverified on macOS. Probe it (§5).**

### 1.9 Miscellaneous dead ends

- **Widevine on macOS WebKit** — dead. Irrelevant: Netflix, Disney+, Hulu, HBO Max and Prime Video all ship FairPlay for the WebKit path, and `WebCore/page/Quirks.cpp` carries active, recently-dated rdar-referenced quirks for all of them. The blocker is UA-based service gating, not the CDM.
- **Liquid Glass inside web content** — `-apple-visual-effect: -apple-system-glass-material` is private, non-functional in public Safari, requires the undocumented `useSystemAppearance` preference. App Store rejection. Web content cannot participate.
- **`NSGlassEffectView.effectIsInteractive`** — macOS **27.0, still beta**. Absent from the 26.5 SDK. Do not plan around it.
- **XCTest without Xcode** — `import XCTest` fails: "no such module". `XCTest.framework` ships exclusively inside `Xcode.app`. swift-testing *is* fully present (`Testing.framework` + `_Testing_AppKit` overlay + `libTestingMacros.dylib`).
- **`actool`, `ibtool`, `metal`, `metallib`** — all fail `xcrun -f`. No `Assets.car`, no `.icon` (Liquid Glass app icon), no xib/storyboard compilation, no custom Metal shaders. `iconutil` **is** present, so `.iconset → .icns` works.
- **Notarization** — requires a paid Developer ID cert; ad-hoc, Apple Development and Mac Distribution certs are explicitly excluded. This machine currently has **zero** signing identities and **zero** provisioning profiles.
- **XcodeGen / Tuist** — both generate `.xcodeproj`, which is inert without `xcodebuild`. Skip.
- **DuckDuckGo `macos-browser`** — archived 2025-02-24. Live code is `duckduckgo/apple-browsers` (752 MB monorepo).
- **Orion as an achievability proof** — Kagi's own words: *"forking WebKit, porting hundreds of APIs, and writing a browser app from scratch."* Six developers, six years, ~70% WebExtensions coverage. Orion's version numbers track WebKit's. Nothing about its extension architecture is reachable from system WKWebView. It is not evidence that a small team can do this.

---

## 2. CORRECTIONS

### FATAL — the spec said something that cannot compile or cannot run

**F1. `NSOutlineViewDiffableDataSource` → hand-rolled diff.**
Use `CollectionDifference` over a `Sendable` value-type tree, applied inside:
```swift
outlineView.beginUpdates()
outlineView.insertItems(at:inParent:withAnimation:)
outlineView.removeItems(at:inParent:withAnimation:)
outlineView.moveItem(at:inParent:to:inParent:)
outlineView.endUpdates()
```
(macOS 10.7-era API; `NSOutlineView.h` in the 26.5 SDK contains **zero** `API_AVAILABLE(macos(15..26))` declarations — AppKit shipped nothing new here.) Never use `reloadItem(_:reloadChildren:)` for structural change; it is the documented crash vector.

**F2. Manual background-tab freezing → delete the tier entirely.**
`WKPreferences.inactiveSchedulingPolicy` (public, macOS 14+) already does it, and **for an app linked against the macOS 15+ SDK `.suspend` is the default with zero lines of code**. The chain: `defaultRunningBoardThrottlingEnabled()` returns `linkedOnOrAfterSDKWithBehavior(RunningBoardThrottling)` on `PLATFORM(MAC)`; `defaultShouldTakeNearSuspendedAssertion()` returns `!linkedOnOrAfterSDKWithBehavior(FullySuspendsBackgroundContentImmediately)`, disabled only when linked before `DYLD_MACOSX_VERSION_15_0`. A detached WKWebView already has JS paused, layout paused, rAF stopped, layer trees frozen, rendering resources destroyed. Set the property explicitly for intent, then move all budget to the discard tier. **This deletes 3–4 dev days.**

Two verifier corrections you must carry:
- **Suspension is per WebContent *process*, not per WKWebView.** `WebProcessProxy::shouldTakeNearSuspendedAssertion()` iterates every page in `m_pageMap` and returns true (i.e. *not* fully suspended) if **any** page in that process qualifies. Same-site tabs share a process. Measure per-process RSS, never assume per-tab savings.
- **`removeFromSuperview()` is not the only trigger and not the best one.** `PageClientImpl::isViewVisible` returns false on three independent conditions: nil window, `isHiddenOrHasHiddenAncestor`, and window occlusion. **`setHidden(true)` gives identical suspension without tearing down layout** — strictly cheaper for a tab switcher. Fully-covered windows suspend for free.

**F3. `contextMenuConfigurationForElement` → `NSView.willOpenMenu(_:with:)`.**
Subclass `WKWebView`, override `willOpenMenu(_:with:)` / `didCloseMenu(_:with:)`, mutate the `NSMenu` in place, identify items by `NSMenuItem.identifier`. You lose the hit-tested element (`_WKContextMenuElementInfo` is SPI) — recover it with a `WKUserScript` `contextmenu` listener posting the target to a `WKScriptMessageHandler` *before* the menu opens.

**F4. Passkey shim → entitlement. See §1.1/§1.3.**

**F5. "No macOS browser entitlement exists, budget zero time" → wrong.** See §1.1. This was the verifier's stated reason for overturning the DRM area from *works-with-caveats* to *partially-blocked*.

**F6. Per-profile `WKProcessPool` → delete.** See §1.4.

### MAJOR

**M1. Profile on-disk path is not what the web says.**
Non-sandboxed: `~/Library/WebKit/<CFBundleIdentifier>/WebsiteDataStore/<UUID>/`
Sandboxed: `<container>/Data/Library/WebKit/WebsiteDataStore/<UUID>/` — the bundle-ID component is **omitted**, because the container is already keyed on it. The gate is `WebKit::processHasContainer()`, i.e. container presence, not the App Sandbox entitlement per se.
Consequences: changing `CFBundleIdentifier` orphans every profile in **both** configurations; flipping sandbox status relocates the whole root with **no migration path in the API**. **Freeze both on day one, forever.**

**M2. A profile's `WKWebsiteDataStore` must be strongly held for the whole time the profile is open.**
The registry is `static HashMap<PAL::SessionID, WeakRef<WebsiteDataStore>>`. Drop the last reference → `~WebsiteDataStore` runs → session removed from the network process → the next `dataStoreForIdentifier()` for the same UUID gets a **brand-new `SessionID`**. On-disk data survives (it is keyed on the UUID directory); **session cookies and all in-memory session state do not.** This is the mechanism behind every "session cleared on relaunch" report in the wild.

**M3. Profile deletion needs a real state machine.**
`remove(forIdentifier:)` returns `"Data store is in use"` if a live store has pages, and `"Data store is in use (by network process)"` if it ever touched the network process (WebKit has a `// FIXME: Try removing session from network process instead of returning error.`). Errors arrive as `NSError(domain: "WKWebSiteDataStore", code: WKErrorUnknown)` — note the **capital S**, it does *not* match `WKErrorDomain` — with only an English `localizedDescription`. There are **two** distinct in-use strings; substring-match `"in use"`, or just retry. Sequence: close all WKWebViews → nil out configurations and downloads → drop the ProfileStore → yield to the next main-loop turn → call remove → on failure mark `tombstoned` and retry next launch. All of this is `@MainActor` anyway (`WK_SWIFT_UI_ACTOR` == `NS_SWIFT_UI_ACTOR` == `@MainActor`, `WKFoundation.h:60`), which is where `~WebsiteDataStore`'s `RELEASE_ASSERT(RunLoop::isMain())` wants it. That is load-bearing, not incidental.

**M4. Never construct a fresh `WKWebViewConfiguration` per tab.**
`APIPageConfiguration` declares `LazyInitializedRef<WebProcessPool, createWebProcessPool> processPool`; a fresh configuration realizes a **genuinely new pool** with its own `WebProcessCache` and prewarm pool. `PageConfiguration::copy()` shares the already-realized pool. **One base configuration per profile; every tab does `baseConfig.copy() as! WKWebViewConfiguration`.**

**M5. `interactionState` is `Any?`, not `Data?`, and setting it performs a real navigation.**
- Getter: `WebKit::encodeSessionState(_page->sessionState())` → `NSData`: 4-byte big-endian version header (**currently 2**) + `kCFPropertyListBinaryFormat_v1_0`. Decoder does `if (versionNumber != sessionStateDataVersion) return false;` — **exact match, no migration, silent no-op on mismatch or non-NSData.** No error, no exception, no delegate callback. Blank web view.
- Setter calls `restoreFromSessionState(state, /*navigate=*/true)` → `goToBackForwardItem(*item, IsSessionRestoreNavigation::Yes)`. WebKit's own source: `// FIXME: Navigating should be separate from state restoration.` **Sub-200ms restore is not achievable as a contract.** Budget 0.8–3s for a real SPA. Show the snapshot instantly; reload underneath.
- **Fallback detection: `setInteractionState:` discards the return value, and no `WKNavigation` is handed back.** Do *not* use a 50ms timer (a cold WebContent launch exceeds it and you'll double-load). `restoreFromSessionState` calls `backForwardList().restoreFromState(...)` **before** the navigate branch, so immediately after assignment, `webView.backForwardList.currentItem != nil` is true iff the blob decoded. Gate on that — synchronous and race-free.
- No size cap on macOS: `maximumSessionStateDataSize` is 2 MB on iOS but `UINT32_MAX` off iOS. Blobs scale with `history.pushState` state objects and POST bodies, unbounded.
- Captured: back/forward list, per-item scroll position, page scale, pushState state objects, POST bodies, form **element** state. **Not captured:** `sessionStorage`, JS heap, WebSockets/SSE, WebRTC, video position, canvas/WebGL, nested scroller offsets, Service Worker in-flight state, IndexedDB transactions.

**M6. Snapshot before you detach, and impose your own timeout.**
On macOS `takeSnapshot` is a **software paint inside the WebContent process** (`WebPage::snapshotAtSize` → `paintSnapshotAtSize`), so it does not need a window. But: WebKit's own comment — *"Software snapshot will not capture elements rendered with hardware acceleration (WebGL, video, etc)"* — and *"This code doesn't consider snapshotConfiguration.afterScreenUpdates"* (silently ignored on macOS). There is **no built-in timeout**; a hung or RunningBoard-suspended web process leaves the completion handler unfired forever. Once the view is out-of-window under `.suspend`, the snapshot IPC may never be serviced at all. **Snapshot first, while in-window and live, is mandatory.**

**M7. Do not use a `sleep` to wait for scroll state to land.**
`WebPageProxy::sessionState()` does **zero IPC** — it reads UI-process state only. The web process pushes scroll/form state at two moments: `WebPage::pageStoppedScrolling()` and `WebPage::visibilityDidChange()` (WebKit's comment: *"We save the document / scroll state when backgrounding a tab…"*), both async via `HistoryItem::notifyChanged()` → `BackForwardUpdateItem`. But detaching the view is exactly what drops the foreground assertion, so a fixed delay races the very suspension you're relying on. **Either read `interactionState` before detaching (accepting a possibly-stale scroll offset) or drive off an observed signal. Never sleep.**

**M8. Per-profile HTTP-auth credential isolation is automatic; do not build it.**
`NetworkSessionCocoa.mm`: when a data store has an identifier, the network process sets `configuration.URLCredentialStorage = [[NSURLCredentialStorage alloc] _initWithIdentifier:<uuid> private:NO]`. WKWebView never touches your process's `URLCredentialStorage.shared` — networking happens in `com.apple.WebKit.Networking`. Writing to `.shared` is a no-op as far as WKWebView is concerned. (Gated on `CFNETWORK_SEPARATE_CREDENTIAL_STORAGE` — probe it, §5.)

**M9. Glass over WKWebView works; the spec's reason for doubting it was wrong.**
macOS WebKit uses **UI-side compositing** — `RemoteLayerTreeDrawingAreaProxyMac` materializes the web process's layer tree as **real CALayers inside your process**. There is no `CALayerHost`/`CAContext` boundary for ordinary page content. The "remote layer tree can't be sampled" premise is an artifact of pre-2020 WebKit. **Exception: video.** WebKit's GPU process hosts media layers cross-process via `LayerHostingContextManager`. Glass over `<video>` and over DRM/EME surfaces is genuinely at risk. **Probe first (§5).**

**M10. Glass rules you cannot violate.**
- **Glass cannot sample glass.** Any two overlapping-or-nearby `NSGlassEffectView`s not inside a shared `NSGlassEffectContainerView` render inconsistently *and* cost one sampling pass each. One container per visual cluster; never overlap two containers.
- **You must assign `glassView.contentView = yourView`.** Header: *"NSGlassEffectView only guarantees the contentView will be placed inside the glass effect; arbitrary subviews aren't guaranteed specific behavior."* Sibling-background layout is unsupported.
- `spacing` defaults to **0**, and 0 is *already* the batching mode (single sampling pass). Raising it **adds** the blob-melding morph — a visual choice, not a perf knob. The spec had this inverted.
- **`.regular`, not `.clear`.** `.clear` has no adaptive appearance and requires your own dimming layer; the HIG scopes it to media-rich, bold, bright backdrops. Arbitrary web pages are light text-on-white. `.clear` toolbar text will be unreadable on most of the web.
- **Do not use `NSGlassEffectView` as the window background.** `NSVisualEffectView` is **not** deprecated in the 26.5 SDK. Glass is a foreground effect for floating controls; using it as window background is what produces the 26.2 stale-backdrop bug and unfocused-window artifacts.
- **Do not put chrome in the title bar.** macOS 26 inserts a private `NSGlassContainerView` inside `NSToolbarView` that **swallows mouse events** (open since 26 beta 1). Use `titlebarAppearsTransparent = true` + `.fullSizeContentView` and float your own container.
- Glass demonstrably regressed *within* the 26.x line (backdrop caching broke in 26.2, unanswered by Apple; `NSScrollEdgeEffectStyle` only appeared in 26.1). **Ship a `PaneChrome.glassEnabled` kill switch.**

**M11. `WKWebView.obscuredContentInsets` (macOS 26.0) is the sanctioned API for floating chrome over web content.** Header: *"should be covered by UI elements managed by the client… The web view automatically adjusts how fixed and sticky elements are rendered near edges with non-zero obscured insets."* Pair with `NSBackgroundExtensionView` (`contentView`, `automaticallyPlacesContentView`) to bleed page edge color under the sidebar.

**M12. Content blocking is capped and impoverished.**
`constexpr size_t maxRuleCount = 150000;` per compiled list, enforced in `ContentExtensionParser.cpp`; the request to raise it to 300k (bug 205719) has been open since 2019. Vocabulary: triggers `url-filter` (mandatory), `url-filter-is-case-sensitive`, `resource-type`, `load-type`, `if-domain`/`unless-domain`; actions `block`, `block-cookies`, `css-display-none`, `ignore-previous-rules`. **No scriptlets, no procedural cosmetic filters, no per-request JS.** uBlock-grade is unreachable.
Licensing: `AdguardTeam/SafariConverterLib` is **GPL-3.0** — linking it makes Pane GPL-3.0. EasyList is GPLv3 **or** CC BY-SA 3.0 at your option; take the CC BY-SA branch for the data. `duckduckgo/TrackerRadarKit` is **Apache-2.0** and includes `ContentBlockerRulesBuilder.swift` — use it and skip EasyList for v1.

**M13. Quarantine is one Info.plist line plus provenance code.**
WebKit does **not** quarantine (`DownloadCocoa.mm` has no quarantine code). LaunchServices does, if `LSFileQuarantineEnabled = true` is in your Info.plist — verified: Safari sets exactly this, and `CoreTypes.bundle/Exceptions.plist` force-enables it for known browsers by bundle ID. A new bundle ID is in neither list. Then in `downloadDidFinish`, merge into `NSURLQuarantinePropertiesKey`: `kLSQuarantineTypeKey = kLSQuarantineTypeWebDownload`, `kLSQuarantineDataURLKey` = final URL, `kLSQuarantineOriginURLKey` = referring page. `LSSetItemAttribute` is not the modern path.

**M14. Certificate exceptions do not persist. You own that.**
`SecTrustCopyExceptions` returns a blob tied to **that specific `SecTrust` object**, not to a host. Keep a dictionary keyed by `host + leaf-cert SHA-256` (so the exception dies on cert rotation), scoped per profile, and call `SecTrustSetExceptions(trust, stored)` before returning `.useCredential(URLCredential(trust:))` on every subsequent challenge. Use `SecTrustEvaluateWithError(_:_:)` (`SecTrustEvaluate`/`SecTrustEvaluateAsync` are deprecated) and `SecTrustCopyCertificateChain` (`SecTrustGetCertificateAtIndex` deprecated macOS 12). `-_allowTLSCertificateChain:forHost:` is deprecated *with replacement named as* the public `didReceiveAuthenticationChallenge`.

**M15. `WKDownload` has its own auth challenge.**
`download(_:didReceive:completionHandler:)` is separate from the navigation delegate's. A download redirecting to an auth-protected host **will not** route through the navigation delegate. Both default to `NSURLSessionAuthChallengeRejectProtectionSpace` — silent failure — if unimplemented.

**M16. The Swift 6 signature trap that silently breaks your browser.**
`WKNavigationDelegate.h:82`: `decisionHandler:(WK_SWIFT_UI_ACTOR void (^)(WKNavigationActionPolicy))decisionHandler`. In Swift the parameter type is `@escaping @MainActor (WKNavigationActionPolicy) -> Void`. A signature written without `@MainActor` **silently fails to match the optional protocol requirement and is never called** — no warning, no crash, just a browser that navigates to everything. `@preconcurrency import` does **not** fix it. **Mitigation: use the async delegate forms exclusively**, and write one integration test that asserts each optional delegate method actually fires.

**M17. Do not put a Swift `actor` in front of SQLite WAL.**
WAL exists so readers proceed concurrently with a writer; an actor serializes every read behind every write and throws that away, while adding a reentrancy hazard (actor hop inside a synchronous transaction block). Use GRDB 7 `DatabasePool` **as** the concurrency primitive — one instance, app lifetime (GRDB rule 1) — and make `Store` a `final class: Sendable` facade, not an actor. Records must be `Sendable` structs; GRDB's legacy `Record` class is *"not Sendable, and its use is actively discouraged since GRDB 7."*

**M18. UA: pin a constant. Do not derive it.**
`standardUserAgentWithApplicationName()` returns exactly `"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"` + `" "` + applicationName. The OS token is **hardcoded to 10_15_7**. `defaultApplicationNameForUserAgent()` returns **nil on macOS** — so a stock WKWebView sends a UA with no `Version/` and no `Safari/` token at all, which is exactly the embedded-webview signature Google blocks. **Spoofing Safari is the fix, not the risk.**
Set `WKWebViewConfiguration.applicationNameForUserAgent = "Version/26.5 Safari/605.1.15"` and leave `customUserAgent` nil (`setApplicationNameForUserAgent` early-returns while `m_customUserAgent` is non-empty). Reserve `customUserAgent` for per-tab desktop/Chrome overrides.
**Do not read `WebKit.framework`'s `CFBundleShortVersionString`** — it is `"21624"` on this host. That yields `Version/21624 Safari/605.1.15`. Safari's real version lives in `/Applications/Safari.app/Contents/Info.plist` (`26.5.2` here), which a sandboxed build cannot read. **Pin a constant, verify against a real Safari per OS release, make it remote-configurable.**

**M19. App Sandbox: don't.** Direct inspection: neither Chrome nor Arc claims `com.apple.security.app-sandbox`. Both enable Hardened Runtime only (Chrome `flags=0x12a00`, Arc `flags=0x10000`). Safari carries a private `com.apple.private.app-sandbox.unquarantine` entitlement you cannot get. Sandboxing fights you on downloads, profile directories, native messaging and helper processes for zero benefit outside the MAS.

**M20. `com.apple.security.cs.allow-jit` is required** once Hardened Runtime is on, or WKWebView crashes on Apple Silicon when JavaScriptCore initializes. It is a Hardened Runtime entitlement → **unrestricted** per TN3125 → works ad-hoc. Do **not** also set `allow-unsigned-executable-memory` or `disable-executable-page-protection`.

**M21. Entitlement tiers are not flat.** TN3125: App Sandbox entitlements, **all** Hardened Runtime entitlements, `get-task-allow`, and `application-groups` are **unrestricted** on macOS — no provisioning profile, work ad-hoc. `keychain-access-groups`, `associated-domains`, and `web-browser.public-key-credential` are **restricted** — profile required, paid account required.

**M22. Ad-hoc signing has a real per-day cost.** TN3127: ad-hoc code's designated requirement is tied to the cdhash, which changes every build. macOS re-prompts for **every TCC permission on every rebuild** — camera, mic, screen recording, location, all of which a browser requests on behalf of web content. Apple DTS explicitly recommends Apple Development certificates for day-to-day macOS development for this reason.

**M23. SwiftUI `WebView`/`WebPage` (macOS 26) has no session restore.** Its complete public surface omits `interactionState`, `sessionState`, any restore, and any audio property. **Choosing it eliminates tab restore outright.** AppKit + raw WKWebView is a load-bearing architectural constraint, not a style preference.

**M24. `WKWebExtensionController.Configuration.defaultWebsiteDataStore` defaults to `WKWebsiteDataStore.defaultDataStore`** and will **silently leak extension state across profiles** if you don't set it. Confirmed verbatim in the header doc comment.

**M25. Registering http+https matters, but not for the reason given.** `isFullWebBrowserOrRunningTest()` on macOS checks `[NSWorkspace URLsForApplicationsToOpenURL:]` for both schemes against your own bundle URL. But the **ITP/TCC consequence does not exist on macOS** — `determineTrackingPreventionStateInternal()` guards on `ENABLE(APP_BOUND_DOMAINS)`, which is `PLATFORM(IOS_FAMILY)`-only, so it falls through to `isRunningTest()`. The real macOS consequence is `shouldEvaluateJavaScriptWithoutTransientActivation()`. Also note `isParentProcessAFullWebBrowser()` (used inside the child processes) calls `hasEntitlement(auditToken, "com.apple.developer.web-browser")` unconditionally with no macOS branch — **so inside Pane's WebContent/GPU/Networking processes, browser status is permanently false on macOS regardless of what you register.** The two checks disagree.

**M26. DRM in private windows: milder than reported.** `CDMPrivateFairPlayStreaming::supportsSessionTypeWithConfiguration()` permits `CDMSessionType::Temporary` whenever `persistentState != Required`. Streaming (Netflix/Disney+/Max) uses temporary sessions and should work in an ephemeral store. Only **offline downloads / persistent-license flows** break. Write the UI copy accordingly.

**M27. `NSFilePromiseProviderDelegate.filePromiseProvider(_:writePromiseTo:completionHandler:)` is `NS_SWIFT_NONISOLATED`** while the other two delegate methods are `NS_SWIFT_UI_ACTOR`. Under Swift 6 the write callback runs off the main actor and **cannot touch your `@MainActor` model** — capture a `Sendable` snapshot at drag-begin. Also: the custom UTI must be declared as an **exported type identifier in Info.plist** or cross-app drags silently fail.

### MINOR

- Profile identifiers are strictly `UUID`, not arbitrary strings. Persist your own name→UUID mapping outside WebKit.
- `WKWebsiteDataStore.fetchData(of:)`/`restoreData(_:)` (macOS 26) supports **exactly one** type: `WKWebsiteDataTypeLocalStorage`. Everything else fails with `"This API does not support fetching: <type>"`. It is **not** an export/clone/sync API.
- `fetchAllDataStoreIdentifiers` is literally `FileSystem::listDirectory(root)` compact-mapped through `WTF::UUID::parse`. It reports orphaned directories as profiles forever and knows nothing about your notion of a profile.
- `WKWebsiteDataStore(forIdentifier:)` **materializes the profile on disk immediately** — `resolveDirectoriesAsynchronously()` creates IndexedDB, LocalStorage, MediaCache, NetworkCache, Origins, MediaKeys, DeviceIdHashSalts, AlternativeServices. There is no "create but don't persist" mode.
- Only `mediaCacheDirectory` and `networkCacheDirectory` get `setExcludedFromBackup(true)`. **Everything else in a profile is included in Time Machine / iCloud backup and counts as user data**, unlike the default store's cache which lives in `~/Library/Caches`.
- The real per-profile cost is **disk, not RAM.** All stores share one network process and one GPU process. An idle live store is a session registration plus a directory tree — single-digit MB. Five profiles is five independent NetworkCache/CacheStorage trees under `~/Library`.
- `callAsyncJavaScript(_:arguments:in:contentWorld:)` — **`in:` is the `WKFrameInfo?`, not the world.** ObjC: `-callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:`.
- `kSecUseDataProtectionKeychain: true` is correct and standard, but the stated cause is wrong: `-34018` is `errSecMissingEntitlement`, a **code-signing / keychain-access-group** problem. Apple scopes the data-protection key to `kSecAttrAccessible` and `kSecAttrAccessGroup`, not `kSecAttrAccessControl`.
- FairPlay key system is a **prefix match**: `keySystem == "com.apple.fps" || keySystem.startsWith("com.apple.fps.")`. Both `com.apple.fps` and `com.apple.fps.1_0` are accepted. **The site's player picks, not you.** Leave both EME surfaces enabled (`EncryptedMediaAPIEnabled` and `LegacyEncryptedMediaAPIEnabled` both default true in WKWebView; `NeedsSiteSpecificQuirks` also defaults **true** in WKWebView, so the Netflix/Hulu/Disney+/HBO quirks apply to you).
- `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` is **macOS 12.0+**, not 14+. No availability guard needed. `LSSetDefaultHandlerForURLScheme` is long-deprecated; do not ship it.
- `WKOpenPanelParameters` completion handler must be called **exactly once** — twice or never permanently wedges the page's file input.
- Directory upload works: check `allowsDirectories`, set `panel.canChooseDirectories`, return the directory URL; WebKit enumerates it.
- `webView(_:authenticationChallenge:shouldAllowDeprecatedTLS:)` (macOS 11+) is a **separate** opt-in gate for TLS 1.0/1.1 needing its own UI decision.
- SwiftUI `List` perf on macOS 26: flat lists are 6x faster to load / 16x faster to update at 100k items. **Do not argue AppKit from a 200-row perf claim.** The real disqualifiers: hierarchical lists are still slow (active repro, macOS 26 beta 1), and `.onMove` only works on `ForEach` and cannot combine with `List`'s `children:` keypath — **there is no supported hierarchical drag-reorder in SwiftUI.**
- Known macOS 26 AppKit regression: `NSTableView` rows scroll *over* the header instead of clipping beneath, when the scroll view is flush to the top of its superview (FB21850950). `NSOutlineView` is a subclass and a likely inheritor. Workaround is a 1pt inset — **visually incompatible with a flush Liquid Glass sidebar.** Probe it.
- Arc's own telemetry: **5.52% of DAU regularly used multiple Spaces**; Calendar Preview hit 0.4%. The mechanics you most want to clone are the ones Arc's data says almost nobody used. Ship Pinned + Essentials; make 12-hour auto-archive **opt-in and reversible**.
- Orion does **not** use identified data stores for profiles — it generates a separate `.app` bundle per profile in `~/Applications/Orion/Orion Profiles/`. That is consistent with the source (separate bundle ID → separate `~/Library/WebKit/<bundleID>` root → separate UI process). It buys crash isolation at ~3–4x the effort. **Not for v1.**

---

## 3. REVISED ARCHITECTURE

### 3.0 Four decisions made now, once, irreversibly

| Decision | Choice | Why |
|---|---|---|
| **Distribution** | **Developer ID, notarized DMG. Not Mac App Store.** | MAS forbids the SPI you need for audio detection, accept= filters, match counts, and termination reason. MAS realistically cannot host a browser. This single decision resolves five open questions across four research areas. |
| **Sandbox** | **No App Sandbox. Hardened Runtime + `com.apple.security.cs.allow-jit`.** | Chrome and Arc are both unsandboxed. Sandboxing relocates the profile root with no migration path and fights downloads, native messaging, and helper processes. |
| **Bundle ID** | **Pick it today. Never change it.** | Baked into the profile path in both sandbox configurations. Changing it orphans every user's profiles invisibly. |
| **UI framework** | **AppKit + raw `WKWebView`.** Not SwiftUI `WebView`/`WebPage`. | `WebPage` has no `interactionState`, no session state, no restore, no audio. Choosing it deletes tab restore. Revisit at macOS 27 at the earliest. |

### 3.1 Module layout

```
Package.swift
├── PaneCore        // zero AppKit, zero WebKit. Pure Sendable value types + reducers.
│                   //   TabState / TabEvent / reduce(_:_:) -> TabState
│                   //   SpaceTree, ProfileRegistry model, discard policy engine
│                   //   → this is the only thing that gets unit tests
├── PaneStore       // GRDB 7 DatabasePool. Sendable struct records. ValueObservation.
├── PaneWeb         // @MainActor. ProfileStore, TabController, delegates, discard pipeline
├── PaneChrome      // @MainActor. NSGlassEffectView clusters, sidebar, outline diff
└── Pane            // @main NSApplicationDelegate, thin
```

Compile with `-default-isolation MainActor` (SE-0466, present in the host's Swift 6.3.3 toolchain: `swiftc -help` lists `-default-isolation MainActor|nonisolated`) plus approachable concurrency. Everything AppKit/WebKit is then implicitly main-actor; you annotate only what leaves — `PaneStore` and disk I/O. **Do not use `@preconcurrency import WebKit`** — it masks M16.

Fallback plan, blessed now rather than discovered in month three: if Swift 6 language mode proves intractable, drop to Swift 5 mode with `-strict-concurrency=complete` as warnings and flip at v1.1. Multiple credible practitioners report full-featured AppKit apps still cannot reach clean Swift 6 mode.

### 3.2 Spaces vs Profiles — decouple them

**Space = UI grouping. Profile = `WKWebsiteDataStore`. They are not the same object.**

Default: one profile, shared by all spaces. A space *may* be bound to a distinct profile; most won't be. Rationale:
- A pooled `WKWebView` cannot be reused across profiles — the data store is fixed at configuration time.
- Five profiles = five independent `NetworkCache`/`CacheStorage` trees under `~/Library`, all backed up by Time Machine.
- Arc's telemetry says 5.52% of users used multiple spaces at all.

Coupling them multiplies the disk footprint and the process-cache fragmentation for a feature almost nobody uses.

### 3.3 Profile subsystem

**You own the registry. WebKit is storage, not a database.**

```swift
// Persisted JSON in Application Support — the source of truth
struct ProfileRecord: Codable, Sendable {
    let id: ProfileID
    var name: String
    let uuid: UUID          // validated: != UUID(uuid: UUID_NULL), round-tripped
    let createdAt: Date
    var tombstoned: Bool
}
```

```swift
@MainActor final class ProfileStore {
    let uuid: UUID
    let dataStore: WKWebsiteDataStore          // STRONG. Held for the profile's whole open life.
    let baseConfiguration: WKWebViewConfiguration   // exactly ONE per profile
    let extensionController: WKWebExtensionController  // Configuration(identifier: uuid), macOS 15.4

    init(uuid: UUID) {
        precondition(uuid != UUID(uuid: UUID_NULL))
        self.dataStore = WKWebsiteDataStore(forIdentifier: uuid)
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = dataStore
        cfg.applicationNameForUserAgent = PaneUA.safariSuffix   // pinned constant
        cfg.preferences.inactiveSchedulingPolicy = .suspend      // explicit intent
        self.baseConfiguration = cfg
        let extCfg = WKWebExtensionController.Configuration(identifier: uuid)
        extCfg.defaultWebsiteDataStore = dataStore                // MUST set — M24
        self.extensionController = WKWebExtensionController(configuration: extCfg)
    }

    func makeConfiguration() -> WKWebViewConfiguration {
        baseConfiguration.copy() as! WKWebViewConfiguration        // shares the realized pool — M4
    }
}
```

**Launch sequence, strictly ordered:**
1. Read your JSON registry.
2. Touch `WKWebsiteDataStore.default()` — this is the InitializeWebKit2 guard. It covers **both** `allDataStoreIdentifiers` **and** `remove(forIdentifier:)`. (`init(forIdentifier:)` is itself a valid safe first touch.)
3. Process tombstones: `try await WKWebsiteDataStore.remove(forIdentifier:)`, substring-match `"in use"` on `localizedDescription`, leave tombstoned on failure.
4. *Optionally* `await WKWebsiteDataStore.allDataStoreIdentifiers` purely as a garbage-collection oracle — diff against your registry to find orphans. **Never the source of truth.**

**Deletion state machine:** close all WKWebViews → nil configurations and downloads → drop the `ProfileStore` → `await Task.yield()` / next main-loop turn → `remove(forIdentifier:)` → on failure, mark tombstoned and retry next launch. Never surface failure to the user immediately.

### 3.4 Tab lifecycle — two tiers, not three

**Tier 1 — Freeze.** `config.preferences.inactiveSchedulingPolicy = .suspend`, and `setHidden(true)` on the background tab's view (cheaper than `removeFromSuperview()`, identical suspension, keeps layout). That is the entire implementation. **Never `-_suspendPage:`.**

**Tier 2 — Discard.** The only tier that reclaims memory.

```
1. takeSnapshot(configuration:)   // WHILE IN-WINDOW AND LIVE. snapshotWidth = thumbnail width.
                                  // Wrap in withTimeout(~750ms). No built-in timeout exists.
2. let blob = webView.interactionState as? Data     // read BEFORE detaching (M7)
3. Persist TabRecord(url:title:blob:capturedAt:)    // url is the MANDATORY fallback
4. await webView.setAllMediaPlaybackSuspended(true)
5. Detach and deallocate. Only dealloc kills the WebContent process.
```

**Restore:**
```swift
webView.interactionState = blob
if webView.backForwardList.currentItem == nil {      // synchronous, race-free (M5)
    webView.load(URLRequest(url: record.url))
}
// keep the snapshot on screen until didCommit
```

**Discard gating — this is the whole feature.** Never discard when:
- `_isPlayingAudio` is true (or your JS fallback fires)
- `cameraCaptureState != .none` || `microphoneCaptureState != .none`
- `await webView.requestMediaPlaybackState() == .playing`
- the page has dirty form input
- the last navigation was a POST
- the tab is pinned / an Essential

`interactionState` does not carry `sessionStorage`, live JS heap, WebSocket/SSE connections, video position, canvas/WebGL, or Service Worker state. A half-written Gmail draft in a background tab is destroyed by an ungated discard. **This is the reputation-ending bug in this project.** Gating heuristics are worth more engineering than the mechanism.

> **⚠️ Unresolved contradiction in the dossier.** The lifecycle report says `sessionStorage` is unrecoverable (only SPI `_webViewToCloneSessionStorageFrom`, which needs a live source view). The architecture report claims macOS 26 adds `WKWebView.fetchData(of:completionHandler:)` / `restoreData(_:completionHandler:)` with `WKWebViewDataType.sessionStorage` at `WKWebView.h:684-702` — a *different* API from the localStorage-only `WKWebsiteDataStore.fetchData`. These are not mutually exclusive; the lifecycle researcher may simply have missed it. Neither claim was verifier-checked. **If it exists, discard becomes non-lossy for sessionStorage and this is a major win. Probe P5 (§5).**

**Audio detection.** Given the Developer ID decision: `_isPlayingAudio` KVO behind `respondsToSelector` + `@try`. WebKit deliberately maintains KVO compliance (`PageClientImplCocoa::isPlayingAudioWillChange/DidChange` calling `willChangeValueForKey`/`didChangeValueForKey` on `@selector(_isPlayingAudio)`), backed by `MediaProducerMediaState::IsPlayingAudio` — true audibility, WebAudio included. The public `requestMediaPlaybackState()` is not equivalent: poll-only, returns `.none` whenever the web process isn't running, and reports `HTMLMediaElement` state (a **muted** autoplaying video reads `.playing`). Keep a `WKUserScript` fallback at `.atDocumentStart`, `forMainFrameOnly: false`, hooking `play`/`pause`/`volumechange`/`ended` and `AudioContext.state` — you need it anyway for `WKWebExtensionTab.isPlayingAudio(for:)`.

Note: WebKit already takes a foreground assertion for `ActivityState::IsAudible` (with a grace timer) and `IsCapturingMedia`. Your gating heuristics are needed for the **discard** tier only — nothing stops your app from deallocating a view WebKit is protecting.

### 3.5 Chrome / Liquid Glass

```
NSWindow (titlebarAppearsTransparent, .fullSizeContentView, no NSToolbar)
└── content
    ├── WKWebView (full-bleed)
    │     obscuredContentInsets = NSEdgeInsets(top: chromeH, left: sidebarW, ...)
    ├── NSGlassEffectContainerView  [sidebar cluster]   spacing = 0
    │     contentView = sidebar stack
    │       └── NSGlassEffectView(style: .regular, cornerRadius: 22)
    │             contentView = NSOutlineView's scroll view
    └── NSGlassEffectContainerView  [top chrome cluster] spacing = 0
          └── NSGlassEffectView(style: .regular) contentView = URL field + controls
```

Rules: never overlap two containers; never a sibling background; `.regular` always (offer `.clear` only as a per-site media-mode opt-in); keep `NSVisualEffectView` for the window/sidebar *background material*.

Accessibility: observe `NSWorkspace.didChangeAccessibilityDisplayOptionsNotification`, read `accessibilityDisplayShouldReduceTransparency` and `...ShouldIncreaseContrast`, swap the whole container for an opaque variant. Apple only auto-degrades **standard system components** — a custom glass tab strip is not one.

Gate everything on `if #available(macOS 26.0, *)` with an `NSVisualEffectView` path, and ship `PaneChrome.glassEnabled` as a kill switch.

### 3.6 Sidebar

`NSOutlineView`, source-list style, hand-rolled diff (F1), wrapped as your own `OutlineDiffableDataSource<Item>` (~200 lines). Drag: `outlineView(_:pasteboardWriterForItem:)` returning an `NSPasteboardItem` with your **exported** UTI for internal reorder; `NSFilePromiseProvider` for drag-out (capture a `Sendable` snapshot at drag-begin — M27). Validate with `outlineView(_:validateDrop:proposedItem:proposedChildIndex:)` + `setDropItem(_:dropChildIndex:)`.

Use `NSSplitViewItem.topAlignedAccessoryViewControllers` / `bottomAlignedAccessoryViewControllers` (macOS 26) for pinned sidebar header/footer chrome — that is the Tahoe-native mechanism and the only route to `preferredScrollEdgeEffectStyle` (26.1+).

### 3.7 Store

GRDB 7 `DatabasePool`, one instance for the app's lifetime. `Store` is a `final class: Sendable` facade, not an actor. Reads: `try await pool.read { }`. Sidebar updates come from `ValueObservation`, not your own change notifications. Records are `Sendable` structs.

### 3.8 Passkeys (feature-flagged, post-approval)

Info.plist: `CFBundleURLTypes` with `http` and `https`, `CFBundleTypeRole = Viewer`. Entitlement: `com.apple.developer.web-browser.public-key-credential = true`. **You write zero WebAuthn code** — WebKit's `WebAuthenticatorCoordinatorProxy` handles it.

**But `ASAuthorizationWebBrowserPublicKeyCredentialManager` is REQUIRED, not cosmetic branding.** Apple's "Passkey use in web browsers" states the permission requirement in the *general* section, and WebKit trunk calls only `isDeviceConfiguredForPasskeys` — it never calls `requestAuthorizationForPublicKeyCredentials` on your behalf. Nothing in the WKWebView path flips System Settings → Privacy & Security → **Passkeys Access for Web Browsers** out of `.notDetermined`. You must:

```swift
let mgr = ASAuthorizationWebBrowserPublicKeyCredentialManager()
if mgr.authorizationStateForPlatformCredentials == .notDetermined {
    mgr.requestAuthorizationForPublicKeyCredentials { _ in }
}
if #available(macOS 26.2, *) {
    guard ASAuthorizationWebBrowserPublicKeyCredentialManager.isDeviceConfiguredForPasskeys else { … }
}
```
Instrument the **full** `ASAuthorizationError` enum (1000 Unknown, 1001 Canceled, 1002 InvalidResponse, 1003 NotHandled, 1004 Failed, 1005 NotInteractive, 1006 MatchedExcludedCredential, 1007 CredentialImport, 1008 CredentialExport, 1009 PreferSignInWithApple, 1010 DeviceNotConfiguredForPasskeyCreation). Do **not** treat 1004 as an entitlement signal.

Budget post-entitlement integration debt: a shipping Chromium browser *with* the entitlement reports on Apple's forums that GitHub sign-in falls back to a machine-password prompt and Google passkey creation errors out. Zero replies, no Apple response.

### 3.9 Password vault

`SecItem`, `kSecClassInternetPassword`, `kSecUseDataProtectionKeychain: true`, `SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.userPresence], &err)`, and a reused `LAContext` via `kSecUseAuthenticationContext` so one Touch ID prompt covers a burst. Requires a real provisioning profile in an app bundle — access groups derive from signed entitlements (and `keychain-access-groups` is **restricted**, so paid account required).

Migration: `ASCredentialImportManager.importCredentials(token:)` via a credential-provider extension declaring `SupportsCredentialExchange = YES` / `SupportedCredentialExchangeVersions = ["1.0"]`, plus app `NSUserActivityTypes` containing `ASCredentialExchangeActivityType`. Form fill runs in `WKContentWorld.page` (it has to touch the DOM, which crosses worlds anyway).

Free wins: macOS 26 extends Security Code (OTP) AutoFill to all third-party browsers without text-field content-type annotation (opt-out key `NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac`). Also implement `ASCredentialProviderViewController` so Pane's vault serves other apps.

### 3.10 DRM, UA, default browser

Nothing to do for FairPlay. `CFBundleURLTypes` with http+https. `try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https")` (and "http"). Use a **persistent** data store for normal tabs. Do **not** add certificate pinning to the auth-challenge handler — it breaks the FairPlay application-certificate fetch. Never touch the key-system string.

---

## 4. BUILD ORDER

Acceptance tests are the definition of done. If you can't run the test, the milestone isn't finished.

| # | Milestone | Days | You know it works when |
|---|---|---|---|
| **0** | **Toolchain + bundle skeleton.** `Package.swift` (5 targets), `Scripts/bundle.sh` (~60 lines: `swift build -c release`, assemble `Pane.app/Contents/{MacOS,Resources}`, write Info.plist, `iconutil -c icns`, `codesign --force --sign - --entitlements Pane.entitlements`). `@main` + `NSApplicationDelegate`. | 2–3 | `open .build/Pane.app` shows a window with a menu bar; a `WKWebView` loads `https://webkit.org`; app is Hardened-Runtime signed with `com.apple.security.cs.allow-jit` and does **not** crash on JSC init; `ps -axo rss=,comm=` shows `com.apple.WebKit.WebContent` alive. And `swift test --disable-xctest` runs one `@Test func t() { #expect(true) }` to completion. |
| **1** | **Probe battery** (§5, P1–P7). No product code. | 2–3 | Every probe writes a one-line PASS/FAIL to a log. §5 risks 2,3,5 are answered with measurements, not inference. |
| **2** | **Profile registry + ProfileStore + deletion state machine.** | 5–8 | Create 3 profiles. Log into `httpbin.org/basic-auth/…` in A → B re-prompts. `kill -9` the app; relaunch; A's cookies survive. Delete C **while one of its tabs is mid-load** → no crash, and C's `<UUID>` directory is gone from `~/Library/WebKit/<bundleID>/WebsiteDataStore/` within at most one relaunch. Registry JSON and disk agree after all of it. |
| **3** | **Tab model + GRDB store + session restore.** | 6–9 | 200 tabs across 3 spaces. `kill -9`. Relaunch → sidebar tree identical, expansion state preserved, active tab restores to the same scroll offset. **Only the visible tab spawned a WebContent process** — verify with `ps`. A tab whose blob fails to decode falls back to `load(URLRequest)` and shows the right page. |
| **4** | **Sidebar: outline + hand-rolled diff + drag/drop.** | 8–12 | Drag a tab between spaces and into a folder with animation; no `reloadItem` anywhere in the code path; the dragged tab's `WKWebView` does **not** reload (check `didStartProvisionalNavigation` never fires). Drag-out produces a `.webloc` via `NSFilePromiseProvider` from a nonisolated callback with no data race. Cross-app drag into Finder works (exported UTI declared). |
| **5** | **Discard tier + snapshot pipeline.** | 6–9 | 50 heavy tabs open. Trigger a discard sweep. Aggregate RSS across all `com.apple.WebKit.WebContent` processes drops measurably (record the number — no public figure exists). Restoring a discarded Gmail tab shows the snapshot instantly and commits within the measured p95. A tab with a dirty `<textarea>` is never discarded. A tab playing audio is never discarded (verify via `_isPlayingAudio` **and** the JS fallback independently). |
| **6** | **Boring floor.** Downloads + quarantine (5–7d), auth challenges both delegates (3–4d), cert interstitial + per-host exception store (4–5d), find via `NSTextFinder` (3–4d), context menu via `willOpenMenu` + JS hit-test (3–4d), open panel (1–2d), crash recovery (1–2d). | 20–29 | A 500MB download resumes after a `kill -9` from persisted `resumeData`. `xattr -p com.apple.quarantine` on a finished download shows type 0081 with origin and data URLs populated. A self-signed host shows an interstitial; accepting it survives navigating away and back **and** an app relaunch; rotating the cert re-prompts. Find bar highlights track scroll offset. Right-clicking a link shows "Open Link in New Tab" with the correct URL. A tab that crashes 3x in 60s shows a static interstitial instead of reload-looping. |
| **7** | **Liquid Glass chrome.** | 6–10 | Sidebar + URL bar glass in one container each; toggling Reduce Transparency in System Settings swaps to opaque within one runloop turn; a page with `position: fixed` header lays out correctly below the chrome via `obscuredContentInsets`; every glass control receives clicks (no `NSGlassContainerView` interception); the kill switch produces a usable non-glass UI. |
| **8** | **Content blocking.** TrackerRadarKit → `WKContentRuleListStore`, multi-list splitting, identifier-keyed compile cache + last-known-good store + failed-compilation store (copy DDG's shape). | 5–8 | Cold-start compile of the full rule set is cached and not repeated on next launch; a rule set over 150k rules splits across N lists and all N are added to one `WKUserContentController`; ads are visibly blocked on a reference page; a corrupt rule JSON falls back to last-known-good rather than leaving the user unprotected. |
| **9** | **Extensions.** `WKWebExtensionController` per profile, using WebKit's `Tools/MiniBrowser/mac/ExtensionManagerWindowController.m` as reference. | 5–10 | uBlock Origin Lite, Dark Reader, Bitwarden, 1Password and Vimium each either work or fail with a **recorded, specific** missing-API reason. Extension state does not leak between profiles (verify `defaultWebsiteDataStore` wiring). |
| **10** | **Password vault + import + provider extension.** | 13–19 | Save a credential, quit, relaunch, one Touch ID prompt fills a burst of fields. `ASCredentialImportManager` round-trips a real Apple Passwords export. Another app can request a credential from Pane's provider extension. |
| **11** | **UA / default browser / DRM verification.** | 2–4 code + 1–2 manual | UA string is byte-identical to Safari on the target OS (diff against a real Safari's `navigator.userAgent`). Netflix, Disney+, HBO Max, Prime Video and tv.apple.com all play. Google and Microsoft OAuth complete. Pane can be set as default browser and receives `application(_:open:)`. |
| **12** | **Passkeys.** Gated on §5 R1. | 1–2 | `webauthn.io` registration and assertion both succeed; the System Settings "Passkeys Access for Web Browsers" toggle appears and is honored; GitHub and Google passkey sign-in tested explicitly (known problem area). |

**Total: ~95–135 dev-days** for a credible v1, excluding entitlement approval latency. At a realistic solo pace that is **5–8 calendar months.** Milestones 10 and 12 are the ones to cut if you need to ship sooner; milestone 5's gating heuristics are the ones you must not cut.

---

## 5. DAY ONE

### Hour 0 — start the longest pole, before writing any code

1. **Enroll in the Apple Developer Program as an ORGANIZATION ($99/yr).** This needs a D-U-N-S number, which itself takes days to weeks. An individual account **cannot** request the passkey entitlement. If you cannot or will not form an entity, decide *today* that Pane ships without passkeys and cut milestone 12 from the plan.
2. Once enrolled: generate a Developer ID Application certificate (kills the ad-hoc TCC re-prompt tax, M22) and submit https://developer.apple.com/contact/request/macos-browsers-passkeys/ as soon as Pane has a URL field, search, and bookmarks (milestone 3-ish).
3. **Pick `CFBundleIdentifier` and write it down as immutable.** Suggested: `com.<yourdomain>.Pane`.

### Hour 1 — install

Nothing is required. CLT 26.5 ships the complete macOS 26.5 SDK — 298 frameworks, `.swiftmodule`s for AppKit/WebKit/AuthenticationServices/Security/SwiftUI, and a Swift 6 typecheck touching `NSGlassEffectView`, `WKWebView` and `ASAuthorizationPlatformPublicKeyCredentialProvider` exits 0 against `-target arm64-apple-macos26.0 -swift-version 6`.

Optional, cheap: `brew install swiftlint`. Do **not** install XcodeGen or Tuist.

**Install Xcode 26 only if you want the Liquid Glass `.icon` app icon** (Icon Composer + `actool`). Alternative: borrow a Mac with Xcode once per release to compile the icon. Everything else works without it.

### Hour 2 — clone exactly three things

```
git clone https://github.com/the-ora/browser              # Ora — GPL-3.0, ~4.3 MB
git clone -b dev --depth 1 https://github.com/zen-browser/desktop   # ~5.8 MB, patch overlay
git clone --depth 1 https://github.com/WebKit/WebKit --filter=blob:none --sparse
  # then: git sparse-checkout set Tools/MiniBrowser/mac
```

**Read on the web, do not clone (752 MB):** `duckduckgo/apple-browsers` — exactly five files:
- `macOS/DuckDuckGo/Tab/Model/Tab.swift` (the `TabExtensions` composition pattern is the best idea in the repo)
- `SharedPackages/BrowserServicesKit/Sources/BrowserServicesKit/ContentBlocking/{ContentBlockerRulesManager, ContentBlockingRulesCompilationTask, ContentBlockerRulesIdentifier, LastCompiledRulesStore}.swift`

**Add as SPM dependencies:** `https://github.com/duckduckgo/TrackerRadarKit` (Apache-2.0), `https://github.com/groue/GRDB.swift` (MIT, 7.11.1+).

**Read from Zen as behavioural specs, transfer 0% of the code:** `src/zen/glance/ZenGlanceManager.mjs` (~1,400 lines — hidden child browser in an overlay, parent scaled to 0.97 at 30% opacity, snapshot animated along a computed arc from the click point, parent/child correlated by a `glance-id` UUID; in AppKit that is a child `WKWebView` in an overlay plus a Core Animation arc — a day, not a month), `split-view/ZenViewSplitter.mjs`, `spaces/`, `compact-mode/`, `folders/`.

**Legal note before anyone reads Ora line by line:** Ora is GPL-3.0. If Pane will ever be closed-source, decide now whether you want a clean-room boundary. Read it for architecture; do not paste.

### Hour 3–8 — write the probe harness first

One SPM executable, `PaneProbes`, that assembles into an app bundle via the same `bundle.sh` you'll use for Pane. Each probe prints one `PASS`/`FAIL`/`MEASURED: n` line. Ship it as milestone 1.

| Probe | What it does | Kills / confirms |
|---|---|---|
| **P0** | Ad-hoc-signed, non-sandboxed, Hardened-Runtime + `allow-jit` app instantiates a `WKWebView` and loads a page. Check `log stream` for `com.apple.runningboard.assertions.webkit` errors. | The one thing that could turn the whole verdict to *blocked*. **Run this before anything else.** |
| **P1** | `await WKWebsiteDataStore.allDataStoreIdentifiers` as the **literal first WebKit statement** in the process. Then again after touching `.default()`. Then the same two-phase test for `remove(forIdentifier:)`. | Whether forum 822262 reproduces on macOS 26.5, or is iOS-only. All published evidence is iOS. |
| **P2** | `NSWindow` + full-bleed `WKWebView` + `NSGlassEffectView(style: .regular, cornerRadius: 22)` pinned over the top edge, `contentView` = an `NSTextField`. Load (a) a strong horizontal gradient page and scroll it, (b) a page with `<video>`, (c) a DRM/EME stream on tv.apple.com. Screenshot each. | Whether Liquid Glass refracts live web pixels at all (inference only, no empirical report exists), and whether video/DRM come back flat gray or black. **This one can sink the visual identity.** Also reproduce forum 810314 (26.2 stale backdrop) on 26.5. |
| **P3** | 5 identified data stores, one tab each, vs 1 store with 5 tabs. Record RSS of every `com.apple.WebKit.*` process. Then discard all 5 and re-record. | The only number that tells you whether the pool holds 5 views or 50, and whether eviction is even needed. No published figure exists. |
| **P4** | `log stream --predicate 'subsystem == "com.apple.WebKit"'` filtered on ProcessSwapping while the probe app runs, with and without http+https in `CFBundleURLTypes`. `WebProcessCache::updateCapacity` logs its computed capacity and the reason when zero. | Whether `CacheModel::PrimaryWebBrowser` is reachable. If not, the process cache **and** prewarming are off and restore latency gets materially worse — which is the entire product promise. |
| **P5** | `swiftc -typecheck` a call to `webView.fetchData(of: [.sessionStorage])` / `restoreData(_:)`. If it compiles: set `sessionStorage.foo = 'bar'` in view A, fetch, deallocate A, create B, restore, read it back. Also check whether it carries back/forward history. | Resolves the dossier contradiction (§3.4). Determines whether discard is lossy. |
| **P6** | Discard/restore round trip on 50 tabs: (a) RSS delta from deallocating, (b) wall clock from `interactionState = blob` to `didCommit` and `didFinishNavigation`, split by warm/cold HTTP cache and by whether a cached process was available, (c) p50/p95 blob size across a realistic tab mix including long-lived SPAs (Gmail, Figma, Slack, GitHub). | Kills or confirms every latency and footprint claim in the plan. macOS applies **no truncation at all** to blobs (`UINT32_MAX`), so p95 may be in the megabytes. |
| **P7** | Empty `NSOutlineView` in a source-list-styled sidebar, scroll view flush to the top of its superview. Does FB21850950 (rows scrolling over the header) reproduce? | The workaround is a 1pt inset, which is visually incompatible with a flush Liquid Glass sidebar. 30 minutes, and it can force a chrome redesign. |
| **P8** | Authenticate to `httpbin.org/basic-auth/u/p` in profile A; navigate to it in profile B. | Whether `CFNETWORK_SEPARATE_CREDENTIAL_STORAGE` is actually enabled in the shipping build. If not, you build credential isolation by hand. |

Also: write the **delegate-fires test** on day one (M16). One `XCTest`-free `@Test` that spins up a web view, navigates, and asserts every optional `WKNavigationDelegate` / `WKUIDelegate` / `WKDownloadDelegate` method you implement actually fired. A silently-unmatched `@MainActor` selector is otherwise invisible until a user reports that Pane navigates to everything.

---

## 6. TOP 5 UNRESOLVED RISKS

### R1 — Passkeys may be permanently unobtainable
**Risk:** `com.apple.developer.web-browser.public-key-credential` requires the Account Holder role on an **organization** Apple Developer account, and Apple reviews each application discretionarily. There is no public record of an indie approval; the only confirmed data point is one anonymous forum developer in March 2025. If refused, Pane cannot do passkey sign-in on any site — in 2026 that is a missing feature, not a caveat.
**Cheapest experiment:** One phone call to Apple Developer Support asking whether an individual who is the Account Holder of their own account satisfies the requirement, and whether a Developer ID (non-MAS) distribution is eligible. Cost: 30 minutes + the $99 enrolment you need anyway. **Do it in week one.** Secondary: ask DTS (one incident) whether the entitlement can be exercised in local development pre-approval — that determines whether passkeys can be built in parallel or must be a post-approval bolt-on.

### R2 — Liquid Glass over web content is unproven, and over video/DRM is likely broken
**Risk:** No direct empirical report exists of `NSGlassEffectView` refracting live `WKWebView` pixels on macOS 26. The positive case is **inference** from UI-side compositing plus Apple DTS confirming the equivalent iOS behavior. Video is genuinely at risk — WebKit's GPU process hosts media layers cross-process via `LayerHostingContextManager`, and DRM surfaces are additionally marked no-capture. A browser whose glass chrome renders as flat gray over every Netflix frame is a visible, embarrassing bug.
**Cheapest experiment:** **Probe P2. 30 minutes.** One window, one full-bleed web view, one glass view, three screenshots. This is the highest value-per-minute test in the entire document and it must happen before any chrome architecture is committed.

### R3 — sessionStorage loss on discard (dossier contradiction)
**Risk:** If `WKWebView.fetchData(of: .sessionStorage)` does not exist or does not round-trip, then every discard destroys `sessionStorage`, and the discard feature becomes a data-loss mechanism for exactly the tabs users care about — a half-filled checkout, a multi-step form, a draft. Two of the nine reports disagree about whether this API exists, and neither claim was verifier-checked.
**Cheapest experiment:** **Probe P5.** Ten minutes to typecheck against the local SDK; an hour to round-trip a value through a deallocated web view. Also check whether it carries the back/forward list — if not, you need a parallel `interactionState` snapshot alongside it.

### R4 — Google OAuth may block Pane regardless of UA
**Risk:** Google's policy bans embedded user agents **as a class**, not as a string match, and explicitly names WKWebView on macOS as an affected embedded user agent (error `disallowed_useragent`, enforced for all users since 2023-07-24). Google's *published* remedy is "don't use an embedded webview / use AppAuth", not "change your UA". The claim that a Safari UA spoof fixes it is inference, and the self-test parameter cited in the dossier (`disallow_webview=true`) does not exist in Google's documentation. Kagi's Orion has a filed instance of exactly this ("Google Sheets blocks login: This browser or app may not be secure"). If Google tightens detection beyond the UA, Pane is not a daily driver.
**Cheapest experiment:** As soon as milestone 0 exists, load `https://accounts.google.com/signin` in the probe app with `applicationNameForUserAgent = "Version/26.5 Safari/605.1.15"` and complete a real sign-in, then repeat with a Google OAuth consent flow on a third-party site. One hour. Then check Firefox iOS's and DDG's in-repo mitigations — both ship into this wall and their workarounds are readable. **Treat continued Google sign-in as a monitored risk with a kill-switch UA override, never as a closed item.**

### R5 — WebKit's process cache may be off, making restore latency structurally bad
**Risk:** `WebProcessCache::updateCapacity` disables the cache entirely unless `LegacyGlobalSettings::singleton().cacheModel() == CacheModel::PrimaryWebBrowser`, and the only setter found is on `_WKProcessPoolConfiguration` — SPI, on the deprecated class. If Pane does not land in `PrimaryWebBrowser` mode, both the 30-minute suspended-process cache **and** process prewarming are off. Every discard-restore and every back-navigation then pays a cold WebContent process launch, which public reports put at multiple seconds under bad conditions. The entire "aggressive discarding with fast restore" product promise rests on this.
**Cheapest experiment:** **Probe P4.** Run the probe app under `log stream --predicate 'subsystem == "com.apple.WebKit"'` and grep for the capacity line that `WebProcessCache::updateCapacity` emits, including its reason-for-zero. Fifteen minutes. Run it both with and without http+https registered in `CFBundleURLTypes`, since `isFullWebBrowserOrRunningTest()` is the only browser-identity lever you control on macOS.

**Runners-up, in order:** the `allDataStoreIdentifiers` crash on macOS (P1 — cheap, and a mitigation already exists); whether Swift 6 language mode is reachable at all for a full AppKit app (blessed fallback already written into §3.1); the macOS 26 `NSOutlineView` header-overlap regression (P7 — 30 minutes, but only a chrome redesign, not a blocker); and whether Apple's `WKWebExtension` coverage on macOS 26 is good enough that "Pane supports extensions" is an honest claim (milestone 9's acceptance test *is* the experiment — until it runs, do not put extensions on the feature list).