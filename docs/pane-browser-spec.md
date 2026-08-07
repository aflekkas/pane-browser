# Pane: Build Spec

A minimal macOS browser. Sidebar, spaces (with real profile isolation), content. Nothing else.

**Stack:** Swift 6, AppKit shell, WKWebView content, macOS 14+ (hard requirement).

> **This document is living.** Claims corrected after the 2026-08-07 research
> fleet are marked inline with `[CORRECTED 2026-08-07]` and a citation. Where the
> original wrongness is instructive it is struck through rather than deleted —
> a future session that wonders "why not just do X?" should find the answer here.
>
> Full findings, including the adversarial verifiers' refutations of the
> researchers, are in `docs/research/`. Decisions that reverse a design choice
> have an ADR in `docs/decisions/`.

---

## 0. Two constraints that shape everything

**You cannot use Safari's passwords.** macOS has no public API letting a third-party app read Keychain-stored web credentials, and WKWebView does not inherit Safari's autofill machinery. Arc gets around this by being Chromium and shipping its own password manager. So you ship your own. ~~Passkeys are different: that system API is fully open to you, which is why Arc's passkey prompt looks native.~~

> **[CORRECTED 2026-08-07]** The passkey API is **not** "fully open to you". It is
> gated behind `com.apple.developer.web-browser.public-key-credential` (macOS
> 13.3+), an Apple-reviewed managed capability needing Account Holder on an
> *organization* developer account. Chrome and Firefox ship on it. Arc's prompt
> looks native because it has the entitlement, not because the API is open.
>
> The password half is confirmed and is if anything worse than stated:
> `ASSavePasswordRequest` and `ASGeneratePasswordsRequest` are
> `API_UNAVAILABLE(macos)`, and `ASCredentialIdentityStore` returns only your own
> extension's index — `ASCredentialIdentity` has four members and none is a
> secret. The one sanctioned import path is a user-initiated
> `ASCredentialImportManager` FIDO CXP transfer (macOS 26+).
>
> **Passwords and passkeys are two different projects.** Passkeys: ~1-2 days of
> code, blocked on business approval. Passwords: an entire vault, ~13-19 days.
> Do not budget them together. See ADR 0004.

**Liquid Glass costs battery.** `NSGlassEffectView` does real-time backdrop sampling with refraction. More expensive than the old `NSVisualEffectView` blur, and continuous rather than one-shot. The spec below constrains where it renders.

---

## 1. Architecture

```
BrowserApp (AppKit, main process)
├── SpaceController      profile lifecycle, data store ownership
├── SidebarController    NSOutlineView, glass layer, drag/drop
├── TabController        per-space tab tree, lifecycle state machine
├── WebHost              WKWebView pool, delegate fan-out
├── CredentialVault      keychain-backed passwords + WebAuthn bridge
└── Store                SQLite (WAL), single writer actor
```

**Hard rule: no web content renders browser UI.** Sidebar, command bar, settings, error pages, all AppKit. Error pages especially, since a web-rendered error page inside a compromised renderer is a real attack surface.

---

## 2. Data model

One SQLite file per install, WAL mode, accessed through a single `actor Store`. Not one DB per profile, because you want cross-space search and write volume is trivial.

```sql
space(id, name, icon, color, profile_id, sort_index, glass_tint)
profile(id, name, data_store_uuid, created_at)
tab(id, space_id, parent_id, kind, url, title, favicon_blob,
    scroll_y, sort_index, last_active_at, lifecycle_state)
session_snapshot(tab_id, wk_interaction_state BLOB, captured_at)
history(id, profile_id, url, title, visited_at)
credential(id, profile_id, origin, username, keychain_ref)
```

- `kind` enum: `essential | pinned | ephemeral`
- `lifecycle_state` enum: `live | discarded` — **[CORRECTED 2026-08-07]** `frozen` removed, see §4 and ADR 0001

Favicons and screenshots go to a content-addressed blob directory on disk, not the DB. Screenshots downsampled to 2x sidebar thumbnail size, HEIC.

---

## 3. Spaces and profiles

- Each `profile` owns exactly one `WKWebsiteDataStore(forIdentifier: UUID)`. **macOS 14+ only, and this API is the single reason this project is possible.** Before it, WebKit gave you `.default()` and `.nonPersistent()` and nothing else.
- ~~Each profile also owns its own `WKProcessPool`. Same pool means shared renderer processes; separate pools means hard isolation. You are paying for isolation deliberately.~~

> **[CORRECTED 2026-08-07] Process isolation is not available, and `WKProcessPool` does nothing.**
>
> `WKProcessPool` / `WKWebViewConfiguration.processPool` are
> `API_DEPRECATED("Creating and using multiple instances of WKProcessPool no longer has any effect.", macos(10.10, 12.0))`.
>
> More importantly the isolation being claimed does not exist at any layer we
> control: `NetworkProcessProxy::ensureDefaultNetworkProcess()` returns a single
> app-wide process held in a `NeverDestroyed<WeakPtr>`, and every data store is
> added as a **session inside that one process**. The GPU process is likewise a
> singleton. **Only WebContent processes partition per profile.**
>
> Multiple pools are not merely inert — they still create real `WebProcessPool`
> objects with fragmented process caches and prewarm pools. They cost something
> and buy nothing. Write no process-pool code.
>
> What survives is **data** isolation — separate cookie jars, storage, and
> logins — which is what the product actually needs. **The phrase "process
> isolation" must never appear in any description of Pane.**
>
> See ADR 0002 and `docs/research/2026-08-07-profiles.md`.
- Spaces reference a profile. Default is one profile per space, but the schema allows two spaces sharing one, because "Work" and "Work Admin" wanting the same Google login is a real case.

**Lazy profile activation.** Do not instantiate data stores for all spaces at launch. Instantiate on first switch, tear down after the space has been inactive 10 minutes and all its tabs are discarded. `WKWebsiteDataStore.remove(forIdentifier:)` exists but *deletes data*, so for teardown just release the reference and let WebKit reap processes.

**Space switching** is `NSViewController` child swap, not view rebuild. Keep the previous space's container view alive but `isHidden = true` for 60 seconds so back-and-forth is instant, then release.

---

## 4. Tab lifecycle

The core of the efficiency claim.

| State | Memory | Trigger |
|---|---|---|
| `live` | full renderer | visible, or hidden (WebKit suspends it for free) |
| ~~`frozen`~~ | ~~renderer alive, throttled~~ | **removed — WebKit already does this by default** |
| `discarded` | ~2KB, snapshot only | hidden 5m (ephemeral) / 15m (pinned) |

~~**Freeze:** `webView.setAllMediaPlaybackSuspended(true)`, inject a script calling `document.dispatchEvent(new Event('freeze'))` so freeze-aware sites cooperate. Set `webView.isHidden = true` so WebKit's own throttling engages.~~

> **[CORRECTED 2026-08-07] The freeze tier is redundant. Three tiers collapse to two.**
>
> WebKit already does this, and for an app linked against the macOS 15+ SDK it is
> the default with zero lines of code. `WKPreferences.inactiveSchedulingPolicy`
> (public, macOS 14+) defaults to `.suspend`, because
> `defaultShouldTakeNearSuspendedAssertion()` returns
> `!linkedOnOrAfterSDKWithBehavior(FullySuspendsBackgroundContentImmediately)`
> and `defaultRunningBoardThrottlingEnabled()` returns true on `PLATFORM(MAC)`
> for anything linked on/after macOS 14.
>
> A `WKWebView` detached from the view hierarchy already has JS execution and
> page layout paused, `requestAnimationFrame` stopped, CSS/SVG animations
> suspended, layer trees frozen, rendering resources destroyed, and
> `releaseMemory()` run.
>
> The only thing manual freezing can add is memory reclamation, and that requires
> actually deallocating the `WKWebView` — which is the discard tier.
>
> **Do instead:** set `inactiveSchedulingPolicy` explicitly (for intent and
> older-OS safety) and move all engineering budget to discard/restore.
>
> Source: `WebPreferencesDefaultValues.cpp`. See ADR 0001.

**Discard:** capture `webView.interactionState` (opaque `Data`, contains full session history, form state, scroll position), write to `session_snapshot`, capture `takeSnapshot` for the thumbnail, release the WKWebView entirely.

**Restore:** create webview, assign `webView.interactionState = blob` *before* adding to hierarchy. WebKit restores history and scroll natively. Target under 200ms. If you are over, you are doing main-thread work you should not be.

**Never discard** if the page has an active `MediaSession`, is playing audio, holds a `beforeunload` handler with unsaved state, or is a pinned tab the user explicitly nailed.

> **[CORRECTED 2026-08-07]** ~~KVO on `_isPlayingAudio`~~ is private API and would
> fail the no-SPI invariant. Use the public async
> `webView.requestMediaPlaybackState()`. Note the bare `requestMediaPlaybackState:`
> spelling is deprecated macOS 11.3 to 12.0, and `webView.mediaPlaybackState()`
> **does not exist** — it was fabricated by a researcher and caught by the
> verifier. See `docs/research/2026-08-07-lifecycle.md`.

Essentials never discard below thumbnail state and always restore to their pinned URL, not their wandered-to URL. (Zen behavior worth copying.)

---

## 5. Sidebar

`NSOutlineView`, view-based. **Not SwiftUI.**

> **[CORRECTED 2026-08-07] `NSOutlineViewDiffableDataSource` does not exist** and
> never has. AppKit ships `NSCollectionViewDiffableDataSource` and
> `NSTableViewDiffableDataSource`; the latter conforms only to
> `NSTableViewDataSource` and cannot be assigned to `NSOutlineView.dataSource`,
> which is typed `id<NSOutlineViewDataSource>`.
>
> Use the conventional `NSOutlineViewDataSource` with explicit
> `insertItems(at:inParent:withAnimation:)` / `removeItems(...)` for animation.
> See `docs/research/2026-08-07-architecture.md`.

 A `List` with 200 rows and drag reordering will stutter, and the sidebar is the one surface where stutter is unforgivable.

**Discarded tabs are visibly distinct.** A discarded row dims and swaps its
favicon for a sleep glyph. Added 2026-08-07: the memory behaviour in §4 is the
product's central claim, and a claim the user cannot see is one they cannot
believe. This is the only affordance for it — there is no memory readout, no
settings toggle, no statistics panel.

Three sections, no headers, separated by spacing:
- **Essentials** (icon grid, 4 per row)
- **Pinned** (list)
- **Today** (ephemeral, list, cleared on a timer)

### Glass layer

- One `NSGlassEffectContainerView` wrapping the **entire** sidebar. One container, not one per row. Nested glass views each get their own sampling pass; a container merges them into a single pass and lets adjacent shapes blend.
- `spacing` on the container ~12 so selected-row glass pills visually merge when adjacent.
- Selection indicator is an `NSGlassEffectView` with `cornerRadius` and `tintColor` from the space accent. It *animates position* between rows, it does not fade in and out.
- `isOpaque = false` only on the container. Rows use `.regular` style, not `.clear`, because clear glass over a busy webpage fails contrast.
- **Content area gets zero glass. Ever.** Glass over scrolling web content forces continuous resampling of a continuously changing backdrop. Single most expensive thing you could do.
- Respect `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency`, fall back to flat fills.

### Drag and drop

`NSPasteboard` with a custom UTI carrying tab IDs, plus `public.url` fallback so dragging to Finder or another app works. Cross-space drag moves the tab and, if the target space has a different profile, warns that session state will not transfer.

---

## 6. The boring floor

This is most of v1. Build it before the glass.

### Downloads
`WKDownloadDelegate`.

> **[CORRECTED 2026-08-07]** `WKDownloadPlaceholderPolicy`,
> `decidePlaceholderPolicy`, `didReceivePlaceholderURL` and `didReceiveFinalURL`
> are `API_AVAILABLE(ios(18.2), visionos(2.2))` — **no macOS**. Write `.download`
> temp files and move on completion yourself. `WKDownloadDelegate` has exactly
> one required method: `download(_:decideDestinationUsing:suggestedFilename:)`.

 Implement `download(_:decideDestinationUsing:suggestedFilename:)` with a uniquing pass against the destination directory. **Set the quarantine xattr (`com.apple.quarantine`) yourself** with `LSQuarantineDataURL` and `LSQuarantineOriginURL`, or Gatekeeper will not prompt and you have built a malware vector. Progress via `download.progress` observed with `NSProgress`. Persist `download.resumeData` on failure. `NSPopover` panel off a toolbar button, plus Dock icon progress via `NSApp.dockTile`.

### Uploads
`runOpenPanelWith:` in `WKUIDelegate`. Handle `allowsMultipleSelection` and `allowsDirectories` from the parameters object. Directory upload requires constructing the file list yourself.

### Basic auth
`webView(_:didReceive:completionHandler:)` on `WKNavigationDelegate`. Handle `NSURLAuthenticationMethodHTTPBasic` / `Digest` / `NTLM`. Sheet-attached `NSAlert` with a "remember" checkbox writing to a `URLCredentialStorage` scoped to the profile's `URLSession`. **Do not use shared credential storage** or you have leaked across profiles.

### Cert errors
Same delegate, `NSURLAuthenticationMethodServerTrust`. Evaluate with `SecTrustEvaluateWithError`, get the specific `errSec` code, map to a human explanation. Native full-content-area interstitial, red/amber by severity, "Advanced" disclosure showing the actual chain. Exceptions stored per profile in SQLite keyed by host + cert SHA-256. Never wildcard, never permanent by default.

### Find in page
`webView.find(_:configuration:)` returns `WKFindResult`.

> **[CORRECTED 2026-08-07]** `WKWebView.isFindInteractionEnabled` / `.findInteraction`
> are iOS 16 only. On macOS the route is
> `@interface WKWebView (WKNSTextFinderClient) <NSTextFinderClient>` (10.15.4+).
> Build the panel against `NSTextFinder`, not the iOS find interaction.

 Native floating panel over content, match count from the result. Bind cmd-G / shift-cmd-G. WebKit gives match ordering but not per-match rects publicly, so no scrollbar tick marks without SPI. Skip them.

### Context menus
~~`webView(_:contextMenuConfigurationForElement:)` gives `WKContextMenuElementInfo` with the link URL.~~ Build the menu natively.

> **[CORRECTED 2026-08-07] `contextMenuConfigurationForElement` is iOS-only.**
> It is `API_AVAILABLE(ios(13.0))` and takes a `UIContextMenuConfiguration`. It,
> and the whole `contextMenuWillPresent` / `willCommitWithAnimator` / `didEnd`
> family, **will never fire on macOS**.
>
> The macOS WebKit hook is SPI
> (`_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:`)
> and is therefore off-limits. **Public path: subclass `WKWebView` and override
> `NSView.willOpenMenu(_:with:)`.** See `docs/research/2026-08-07-boring-floor.md`.

 Must-haves: open in new tab, **open in new tab in space X (submenu)**, copy link, download linked file, open image in new tab, search selection, inspect element. The space submenu is what makes multi-space actually usable.

### Session restore
Two layers.
- **Continuous:** every tab mutation writes to SQLite through the store actor, debounced 500ms.
- **Snapshot:** full `interactionState` for live tabs captured on `applicationWillTerminate` and every 60s on a background queue.
- On launch, restore the sidebar instantly from SQLite and lazily materialize only the active tab.

### Crash recovery
`WKNavigationDelegate.webViewWebContentProcessDidTerminate`. **Do not silently reload**, that is how you get infinite crash loops on a bad page. Show a native "this page stopped responding" panel with a reload button. Count crashes per origin: three in five minutes on the same origin, offer to open in a fresh renderer with JS disabled. Also register a top-level `NSSetUncaughtExceptionHandler` that flushes the store actor's pending writes.

---

## 7. Credentials

Two independent subsystems. Do not conflate them.

### Passwords (your own vault)

- **Storage:** one `kSecClassInternetPassword` keychain item per credential, in the app's own keychain access group, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `SecAccessControlCreateWithFlags(.userPresence)` so reads require Touch ID.
- `kSecAttrServer` = origin, `kSecAttrAccount` = username, `kSecAttrLabel` carries the profile UUID so vaults are per-profile.
- **Detection:** `WKUserScript` injected at `.atDocumentEnd` in an isolated `WKContentWorld` (critical, otherwise pages can see your bridge). Walk for `input[type=password]`, resolve the username field by standard heuristics (nearest preceding text/email input in the same form), post to native via `WKScriptMessageHandler`.
- **Fill:** native anchors an `NSPopover` at the field's rect (script sends `getBoundingClientRect`). User picks, Touch ID gates the keychain read, native sends the value back through `callAsyncJavaScript` into the isolated world, which sets `.value` and dispatches `input` and `change` events so React and friends notice.
- **Save:** intercept form submit in the isolated world, compare against vault, prompt natively.
- **Import:** parse Safari and Chrome CSV exports, and 1Password `.1pux`. This is your migration story and it is not optional.

### Passkeys (the system's)

- `ASAuthorizationPlatformPublicKeyCredentialProvider` gives real iCloud Keychain passkeys with the real system Touch ID sheet. Fully supported path, and why Arc's prompt looks native.
> **[CORRECTED 2026-08-07] The entire shim below is deleted. Write zero WebAuthn code.**
>
> **It cannot work.** `WKContentWorld`, verbatim: *"The content world doesn't
> apply to the current document or DOM of a webpage… The content world affects
> only references to other JavaScript variables."* An override of
> `navigator.credentials` in an isolated world is structurally invisible to page
> scripts. It would have to live in `WKContentWorld.page`, where a hostile page
> can detect and subvert it — a worse posture than not shipping the feature.
>
> **It is also unnecessary.** With
> `com.apple.developer.web-browser.public-key-credential`, WebKit's own
> `WebAuthenticatorCoordinatorProxy` handles `navigator.credentials.create/get`
> natively against AuthenticationServices. Shimming would mean reimplementing
> CBOR, clientDataJSON, attestation and PRF/largeBlob extensions worse than
> WebKit already does.
>
> The entitlement is macOS 13.3+, Apple-reviewed, and requires **Account Holder
> on an organization developer account** (D-U-N-S number) plus review criteria
> that require Pane to *already be a credible browser*. Hence: built last.
>
> Note `ASPublicKeyCredentialClientData(challenge:origin:topOrigin:crossOrigin:)`
> **does not exist** — only `init(challenge:origin:)`. And `ASAuthorizationError`
> 1004 is the generic `Failed`, not an "unentitled" signal; `notInteractive` is
> 1005. See ADR 0003, ADR 0004, `docs/research/2026-08-07-credentials.md`.

~~Below, superseded, kept because the reasoning is instructive:~~

- Shim `navigator.credentials.create` and `.get` in the isolated world. Serialize `PublicKeyCredentialCreationOptions` / `RequestOptions` to JSON, base64url the `ArrayBuffer` fields, post to native.
- Native constructs `ASAuthorizationPlatformPublicKeyCredentialAssertionRequest(challenge:)` with `relyingPartyIdentifier` from the origin.
- **Validate the RP ID against the page's effective origin yourself.** WebKit does this internally; when you shim, you own it. Get this wrong and you have built a credential phishing tool.
- Present with `ASAuthorizationController`, `presentationContextProvider` returning the browser window.
- Marshal the assertion back, reconstruct the `PublicKeyCredential` object shape in JS, resolve the promise.
- Also add `ASAuthorizationSecurityKeyPublicKeyCredentialProvider` for hardware keys.
- Set `WKPreferences` to disable WebKit's built-in WebAuthn so it does not race your shim.

---

## 8. DRM test plan

WKWebView gets EME and FairPlay, but behavior differs from Safari and vendors gate on user agent. This is empirical.

~~**Entitlements:** you need `com.apple.developer.web-browser` (requires a granted request to Apple). Possibly `com.apple.security.cs.disable-library-validation` depending on how the CDM loads. The browser entitlement is also what lets you be set as default browser, so you want it regardless.~~

> **[CORRECTED 2026-08-07] `com.apple.developer.web-browser` is iOS/iPadOS 14.0 only.**
> There is no macOS variant. It gates nothing here, including default-browser
> status.
>
> **Default browser on macOS** is `CFBundleURLTypes` declaring http and https,
> plus `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`. No
> entitlement.
>
> **Also set `NSCrossWebsiteTrackingUsageDescription` in Info.plist.** macOS ITP
> state is driven by `linkedOnOrAfter` plus that key — *not* by the browser
> check. `isFullWebBrowserOrRunningTest()` sits behind `ENABLE(APP_BOUND_DOMAINS)`,
> which is defined only for `PLATFORM(IOS_FAMILY)`.
>
> **UA string:** do not derive it from `WebKit.framework` — measured on
> macOS 26.5.2 its `CFBundleShortVersionString` is `21624`, producing the
> nonsense `Version/21624 Safari/605.1.15`. Safari's real version lives in
> `Safari.app/Contents/Info.plist`, which App Sandbox blocks. Hardcode and
> maintain it.
>
> **DRM in ephemeral stores:** streaming works. `CDMPrivateFairPlayStreaming`
> permits `Temporary` sessions whenever `persistentState != Required`. Only
> offline/persistent-license flows need persistent state, so honest UI copy says
> "offline downloads unavailable", not "DRM broken in private windows".
>
> `disallow_webview=true` **does not exist** — zero occurrences across Google's
> OAuth docs. The documented error is `disallowed_useragent`.
>
> See ADR 0004, `docs/research/2026-08-07-drm-entitlement.md`.

Set `WKWebViewConfiguration.applicationNameForUserAgent` to a Safari-compatible string. Not spoofing for fun, DRM vendors match on it.

**Test matrix, in order of likely failure:**
- Widevine sites: dead on arrival (Widevine is Google's, no macOS WebKit path)
- Spotify web: Widevine, will fail
- Netflix, Disney+, Apple TV+: serve FairPlay to Safari, these are the real tests
- YouTube: fine, no DRM on standard content
- Test 1080p and 4K separately, HDCP path differs

**Build `drm-probe.html` first.** Call `navigator.requestMediaKeySystemAccess('com.apple.fps', ...)` and log the result. Five minutes instead of a week of manual testing.

Expected outcome: Apple ecosystem services work, Netflix probably works, anything Widevine-only does not. **Decide if that is acceptable before building the rest.**

---

## 9. Build order

1. Single window, one WKWebView, `interactionState` save/restore proving out. If restore is not sub-200ms here, stop and fix it.
2. DRM probe harness. Learn the bad news early.
3. Tab model + lifecycle state machine, headless, unit tested against a fake webview protocol.
4. Sidebar with real drag/drop, flat colors, no glass.
5. Profiles and spaces. Verify data store isolation by logging into the same site twice.
6. The boring floor, all of it, in the order listed in section 6.
7. Credential vault, then passkeys.
8. Glass, last. It is polish, and doing it last means you can measure exactly what it costs.

**The thing that will kill this project is step 6.** Weeks of unglamorous delegate plumbing with nothing to show anyone, sitting right where motivation dips. Build it before the glass, not after, because once the sidebar looks good you will not want to go write a certificate interstitial.

---

## Appendix: reference repos

- `https://github.com/zen-browser/desktop` (Gecko Arc-alike, MPL-2.0, the fallback path)
- `https://github.com/zen-browser/surfer` (Firefox fork build tooling)
- `https://github.com/kfix/MacPin` (old, unmaintained, but the closest prior art for tabs over WKWebView)
- `https://github.com/WebKit/WebKit` (source, for when WKWebView misbehaves)
- `https://developer.apple.com/documentation/webkit` (WKWebViewConfiguration, WKProcessPool, WKWebsiteDataStore, WKContentRuleList)
