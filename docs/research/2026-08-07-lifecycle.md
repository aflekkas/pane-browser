# Research — lifecycle

**Date:** 2026-08-07  
**Host:** macOS 26.5.2 (build 25F84), Apple Silicon, Swift 6.3.3, SDK MacOSX26.5  
**Target:** macOS 14+ deployment

**Area:** Tab suspend / discard / restore (WKWebView interactionState, media suspension, audio detection, snapshots, background throttling, memory)

**Verdict:** `works-with-caveats` → **adversarially corrected to `works-with-caveats`** (researcher upheld: `True`)


> Claims are tagged HARD FACT (fetched from a primary source) or INFERENCE.
> Findings are preserved as reported. Where a verifier disagreed, BOTH are kept —
> the disagreement is the information.


---

## Hard facts

- WKWebView.interactionState is declared `@property (nonatomic, nullable, copy) id interactionState API_AVAILABLE(macos(12.0), ios(15.0));`. The header doc comment says it holds "back-forward list, currently loaded page, scroll position, form data..." and "can be retrieved and set on another WKWebView to restore state." In Swift it is `var interactionState: Any? { get set }` — NOT `Data?`. Verified in the macOS 26.5 SDK on this machine at /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/WebKit.framework/Headers/WKWebView.h:542.
  - min OS: `macOS 12.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.h
- Apple's public documentation for interactionState is a single abstract sentence ("An object you use to capture the current state of interaction in a web view so that you can restore that state later to another web view.") with NO discussion section, NO statement of the concrete type, NO statement that it may be archived to disk, and NO cross-version compatibility guarantee. Confirmed by fetching Apple's DocC JSON directly (primaryContentSections contains only a declaration, no 'content' section).
  - min OS: `macOS 12.0`
  - https://developer.apple.com/tutorials/data/documentation/webkit/wkwebview/interactionstate.json
- The getter is `return WebKit::encodeSessionState(_page->sessionState()).autorelease();` and the setter is `if (![(id)interactionState isKindOfClass:[NSData class]]) return; ... if (!WebKit::decodeSessionState(...)) return; _page->restoreFromSessionState(sessionState, true);`. The concrete class IS NSData. Passing a non-NSData object, or NSData that fails to decode, SILENTLY no-ops — no error, no exception, no callback.
  - min OS: `macOS 12.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm
- The blob format is: 4 bytes big-endian version number (currently 2) followed by a CFPropertyList written with kCFPropertyListBinaryFormat_v1_0. Constants: `static const uint32_t sessionStateDataVersion = 2; static const uint32_t sessionHistoryVersion = 1; const uint32_t sessionHistoryEntryDataVersion = 2;`. The decoder does `if (versionNumber != sessionStateDataVersion) return false;` — an EXACT match check that rejects both older and newer versions with no migration path and no fallback.
  - min OS: `macOS 12.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/Cocoa/LegacySessionStateCoding.cpp
- Back/forward item identifiers (BackForwardItemIdentifier / frameItemID) are NOT serialized into the legacy session blob — they are regenerated on decode. The blob therefore contains no process-local or app-run-local handles and IS portable across app restarts. (Grep of LegacySessionStateCoding.cpp for itemID/frameItemID returns only navigatedFrameID.)
  - min OS: `macOS 12.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/Cocoa/LegacySessionStateCoding.cpp
- There is NO size cap on the session state blob on macOS: `#if PLATFORM(IOS_FAMILY) static const uint32_t maximumSessionStateDataSize = 2 * 1024 * 1024; #else static const uint32_t maximumSessionStateDataSize = std::numeric_limits<uint32_t>::max(); #endif`. iOS truncates per-entry data past 2 MB (keeping at least the first entry); macOS never truncates. Only `maximumFrameStateTargetLength = 16 * 1024` caps the frame target string.
  - min OS: `macOS 12.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/Cocoa/LegacySessionStateCoding.cpp
- Setting interactionState performs a REAL NAVIGATION, not a state blit. WebPageProxy::restoreFromSessionState(sessionState, navigate=true) ends with `if (hasBackForwardList) { if (RefPtr item = backForwardList().currentItem()) return goToBackForwardItem(*item, IsSessionRestoreNavigation::Yes); }`. The source even carries `// FIXME: Navigating should be separate from state restoration.` The public API always passes navigate=true; only the SPI `-_restoreSessionState:andNavigate:` lets you pass NO.
  - min OS: `macOS 12.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/WebPageProxy.cpp
- Reading interactionState is cheap and synchronous — `WebPageProxy::sessionState()` reads only UI-process-side state (backForwardList(), pageLoadState, renderTreeSize) with `RELEASE_ASSERT(RunLoop::isMain())` and does no IPC to the WebContent process. Consequence: it returns whatever scroll/form state the web process last PUSHED to the UI process, not a live snapshot.
  - min OS: `macOS 12.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/WebPageProxy.cpp
- WebKit does push scroll+form state to the UI process at exactly the right moments: `WebPage::visibilityDidChange()` contains `// We save the document / scroll state when backgrounding a tab so that we are able to restore it if it gets terminated while in the background.` calling `history().saveDocumentAndScrollState()`, and `WebPage::pageStoppedScrolling()` calls `saveScrollPositionAndViewStateToItem(...)`. `HistoryController::saveScrollPositionAndViewStateToItem` ends with `item->notifyChanged();` which fires the BackForwardUpdateItem IPC. Note `HistoryItem::setScrollPosition` alone does NOT call notifyChanged() — the notify comes from the enclosing save call.
  - min OS: `macOS 12.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/WebProcess/WebPage/WebPage.cpp
- WKPreferences.inactiveSchedulingPolicy exists as PUBLIC API: `typedef NS_ENUM(NSInteger, WKInactiveSchedulingPolicy) { WKInactiveSchedulingPolicySuspend, WKInactiveSchedulingPolicyThrottle, WKInactiveSchedulingPolicyNone } API_AVAILABLE(macos(14.0), ios(17.0));` documented as "scheduling policy for the web view when it is inactive and detached from the view hierarchy... A suspended web view will pause JavaScript execution and page layout." Verified in the macOS 26.5 SDK at WebKit.framework/Headers/WKPreferences.h:85-99.
  - min OS: `macOS 14.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKPreferences.h
- For an app linked against the macOS 15.0 SDK or later, the DEFAULT inactiveSchedulingPolicy is already .suspend. Chain: setInactiveSchedulingPolicy maps .suspend to {shouldTakeNearSuspendedAssertions=false, backgroundWebContentRunningBoardThrottlingEnabled=true}; `defaultShouldTakeNearSuspendedAssertion()` returns `!linkedOnOrAfterSDKWithBehavior(FullySuspendsBackgroundContentImmediately)`; `defaultRunningBoardThrottlingEnabled()` returns `linkedOnOrAfterSDKWithBehavior(RunningBoardThrottling)` on PLATFORM(MAC); and RuntimeApplicationChecksCocoa disables FullySuspendsBackgroundContentImmediately only when `linkedBefore(..., DYLD_MACOSX_VERSION_15_0)` and RunningBoardThrottling only when `linkedBefore(..., DYLD_MACOSX_VERSION_14_0)`. Pane, built against the macOS 26 SDK, gets full background suspension for free.
  - min OS: `macOS 15.0 (SDK link target)`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/Shared/WebPreferencesDefaultValues.cpp
- On process suspension WebKit already aggressively reclaims: `WebProcess::prepareToSuspend` calls `suspendAllMediaBuffering()`, `page->processWillSuspend()`, `releaseMemory([]{})` (guarded so it runs at most once per visible-then-background cycle and is skipped if the process is being cached for perf), `freezeAllLayerTrees()`, and on Cocoa `destroyRenderingResources()`.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/WebProcess/WebProcess.cpp
- Media suspension APIs are public and macOS 12.0+: `- (void)setAllMediaPlaybackSuspended:(BOOL)suspended completionHandler:`, `- (void)pauseAllMediaPlaybackWithCompletionHandler:`, `- (void)requestMediaPlaybackStateWithCompletionHandler:(void (^)(WKMediaPlaybackState))`, `- (void)closeAllMediaPresentationsWithCompletionHandler:`. WKMediaPlaybackState is {None, Playing, Paused, Suspended}. The header states setAllMediaPlaybackSuspended "blocks all attempts by the page or the user to resume until setAllMediaPlaybackSuspended is called again with suspended set to false. Media playback should always be suspended and resumed in pairs." The 11.3-era spellings (suspendAllMediaPlayback:, resumeAllMediaPlayback:, requestMediaPlaybackState:) are API_DEPRECATED_WITH_REPLACEMENT as of 12.0.
  - min OS: `macOS 12.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.h
- requestMediaPlaybackState is a full async IPC round trip to the WebContent process (`sendWithAsyncReply(Messages::WebPage::RequestMediaPlaybackState(), ...)`) and returns `{}` (i.e. None) immediately if `!hasRunningProcess()`. It is poll-only — there is no change notification. It reflects HTMLMediaElement playback state, not audibility.
  - min OS: `macOS 12.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/WebPageProxy.cpp
- There is NO public API to detect that a WKWebView is playing audio. `_isPlayingAudio` is declared only in WKWebViewPrivate.h: `@property (nonatomic, readonly, getter=_isPlayingAudio) BOOL _playingAudio WK_API_AVAILABLE(macos(10.13.4), ios(11.3));`. Exhaustive grep for /audio/i across ALL public WebKit headers in the macOS 26.5 SDK returns only: pauseAllMediaPlayback prose, WKUIDelegate mic-permission prose, WKAudiovisualMediaTypes (an autoplay gate), and WKWebExtensionTab.
  - min OS: `macOS 10.13.4 (SPI)`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewPrivate.h
- Apple's own public web-extension API asks the HOST APP for this, rather than providing it: `- (BOOL)isPlayingAudioForWebExtensionContext:(WKWebExtensionContext *)context NS_SWIFT_NAME(isPlayingAudio(for:));` on the WKWebExtensionTab protocol, with "@discussion Defaults to `NO` if not implemented", plus `WKWebExtensionTabChangedPropertiesPlayingAudio = 1 << 4`. So to support the standard `tabs.onUpdated`/`audible` extension surface, a WKWebView browser MUST determine audio playback by some means WebKit does not publicly expose. Verified in macOS 26.5 SDK WebKit.framework/Headers/WKWebExtensionTab.h:183-188.
  - min OS: `macOS 15.4`
  - https://developer.apple.com/documentation/webkit/wkwebextensiontab/isplayingaudio(for:)
- _isPlayingAudio IS deliberately KVO-compliant — WebKit explicitly fires the notifications: `void PageClientImplCocoa::isPlayingAudioWillChange() { [webView() willChangeValueForKey:RetainPtr { NSStringFromSelector(@selector(_isPlayingAudio)) }.get()]; }` and the matching didChange. It is backed by `WebPageProxy::isPlayingAudio() { return internals().mediaState.contains(MediaProducerMediaState::IsPlayingAudio); }` — true audibility, covering WebAudio, not just <video>/<audio>.
  - min OS: `macOS 10.13.4 (SPI)`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/Cocoa/PageClientImplCocoa.mm
- On macOS, takeSnapshot(configuration:) is a SOFTWARE paint performed inside the WebContent process (`_page->takeSnapshot(...)` -> `WebPage::snapshotAtSize` -> `paintSnapshotAtSize`), not a window-server capture. WKWebView.mm carries the verbatim comment: "Software snapshot will not capture elements rendered with hardware acceleration (WebGL, video, etc). This code doesn't consider snapshotConfiguration.afterScreenUpdates since the software snapshot always contains recent updates. If we ever have a UI-side snapshot mechanism on macOS, we will need to factor in snapshotConfiguration.afterScreenUpdates at that time."
  - min OS: `macOS 10.13`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm
- takeSnapshotWithConfiguration:, setInteractionState:, requestMediaPlaybackStateWithCompletionHandler: and most other WKWebView methods begin with `THROW_IF_SUSPENDED`, defined as `if (_page && _page->isSuspended()) [[unlikely]] [NSException raise:NSInternalInconsistencyException format:@"The WKWebView is suspended"]`. A web view suspended via the `-_suspendPage:` SPI will HARD-CRASH the app if you then call these.
  - min OS: `macOS 12.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm
- interactionState does NOT carry sessionStorage. The serialized SessionState struct is exactly {backForwardListState, renderTreeSize, provisionalURL, isAppInitiated}; FrameState carries urlString/originalURLString/referrer/target/scrollPosition/shouldRestoreScrollPosition/pageScaleFactor/documentState/stateObjectData/httpBody/title/policyContainer. Form data is only `document->formElementsState()` (`item->setDocumentState(document->formElementsState())`). The only way to move sessionStorage between web views is the SPI `@property (nonatomic, weak, setter=_setWebViewToCloneSessionStorageFrom:) WKWebView *_webViewToCloneSessionStorageFrom;`, which requires a LIVE source web view — impossible once you have deallocated the discarded tab.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewConfigurationPrivate.h
- The new macOS 26 Swift/SwiftUI `WebPage` class has NO session restore and NO audio property. Its complete public surface (verified in the macOS 26.5 SDK swiftinterface at WebKit.framework/Modules/WebKit.swiftmodule/arm64e-apple-macos.swiftinterface, @available(macOS 26.0)) includes backForwardList, url, title, estimatedProgress, isLoading, serverTrust, hasOnlySecureContent, isWritingToolsActive, isBlockedByScreenTime, fullscreenState, cameraCaptureState, microphoneCaptureState, mediaType, customUserAgent, isInspectable, pauseAllMediaPlayback(), mediaPlaybackState(), setAllMediaPlaybackSuspended(_:), closeAllMediaPresentations() — but no interactionState, no sessionState, no restore, and no isPlayingAudio.
  - min OS: `macOS 26.0`
  - https://developer.apple.com/videos/play/wwdc2025/231/
- WebKit keeps its own cache of suspended WebContent processes: `Seconds WebProcessCache::cachedProcessLifetime { 30_min }` on Cocoa, capacity = min(ramSize / 256MB, 32) processes, disabled entirely if RAM < 2 GB, if processSwapsOnNavigation is off, or if `LegacyGlobalSettings::singleton().cacheModel() != CacheModel::PrimaryWebBrowser`.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/WebProcessCache.cpp
- Live measurement on this host (macOS 26.5.2, Apple Silicon, `ps -axo rss=,comm=`): a single com.apple.WebKit.WebContent process was resident at 363.9 MB, with com.apple.WebKit.Networking at 81.8 MB. This is one real data point for a WebContent process serving ordinary browsing content, and it is consistent with third-party reports of 200+ MB per content-heavy web view.
  - min OS: `n/a`
  - https://developer.apple.com/forums/thread/133449
- Orion (Kagi's shipping WKWebView-based macOS browser) implements exactly the feature Pane proposes — "Low Power Mode reduces Orion's power consumption up to 90%. It does this by cleverly suspending browser tabs you haven't used after five minutes." — and has a public, tracked defect from it: "Tabs completely break when suspended with media open (unrecoverable)", where the tab is unresponsive on reopen even after reload.
  - min OS: `n/a`
  - https://help.kagi.com/orion/features/low-power-mode.html

## Corrections to the spec


### (FATAL) Pane should manually freeze/throttle background tabs to save CPU and power — this is presented as core differentiating w

**Spec said:** Pane should manually freeze/throttle background tabs to save CPU and power — this is presented as core differentiating work.

**Reality:** WebKit already does this, and for an app linked against the macOS 15+ SDK it is the DEFAULT with zero lines of code. WKPreferences.inactiveSchedulingPolicy (public, macOS 14+) defaults to .suspend because defaultShouldTakeNearSuspendedAssertion() returns !linkedOnOrAfterSDKWithBehavior(FullySuspendsBackgroundContentImmediately) (disabled only for apps linkedBefore DYLD_MACOSX_VERSION_15_0) and defaultRunningBoardThrottlingEnabled() returns true on PLATFORM(MAC) for anything linked on/after macOS 14. A WKWebView detached from the view hierarchy already has JS execution and page layout paused, rAF stopped, CSS/SVG animations suspended, layer trees frozen, rendering resources destroyed, and releaseMemory() run. Manual freezing duplicates this and the only thing it can add is memory reclamation, which requires actually deallocating the WKWebView. Re-scope the 'freeze' tier to: set inactiveSchedulingPolicy explicitly (for intent + older-OS safety) and move all engineering budget to the discard/restore tier.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/Shared/WebPreferencesDefaultValues.cpp


### (MAJOR) Restoring a discarded tab by assigning interactionState should be sub-200ms.

**Spec said:** Restoring a discarded tab by assigning interactionState should be sub-200ms.

**Reality:** Assigning interactionState is not a state blit — it is a full navigation. The setter calls _page->restoreFromSessionState(state, /*navigate=*/true), which ends in goToBackForwardItem(*item, IsSessionRestoreNavigation::Yes). WebKit's own source carries `// FIXME: Navigating should be separate from state restoration.` Restore therefore costs: WebContent process launch (unless a prewarmed/cached process is available) + full resource load (memory cache is gone with the process; only the shared disk HTTP cache survives) + JS re-execution + layout + paint. Sub-200ms is achievable only for a small, well-cached, statically-rendered page onto a prewarmed process. For a real SPA (Gmail, Slack, Figma, GitHub) budget 0.8-3s. Note that public reports show WebContent process launch alone taking multiple seconds under bad conditions. The honest UX contract is: show the cached snapshot instantly, reload underneath, and never promise sub-200ms.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/WebPageProxy.cpp


### (MAJOR) interactionState is Apple-documented as persistable session state suitable for writing to disk and restoring across app 

**Spec said:** interactionState is Apple-documented as persistable session state suitable for writing to disk and restoring across app restarts.

**Reality:** It is not documented that way at all. Apple's entire public documentation is one abstract sentence with no discussion section, no stated type, and no persistence or compatibility guarantee (verified against Apple's DocC JSON). What is actually true, from source: it is NSData containing a 4-byte big-endian version header (currently 2) plus a binary plist; the decoder does an exact `if (versionNumber != sessionStateDataVersion) return false;` and rejects any other version SILENTLY — setInteractionState just returns, leaving a blank web view with no error, no exception and no delegate callback. The format has been at version 2 since the WebKit2 era, and back/forward item IDs are regenerated on decode rather than serialized, so cross-restart portability is real in practice — but it is an undocumented implementation detail, not a contract. This is survivable but only with a fallback: always persist {url, title, favicon} alongside the blob and load(URLRequest) if restore produces no navigation.

**Source:** https://developer.apple.com/tutorials/data/documentation/webkit/wkwebview/interactionstate.json


### (MAJOR) KVO on the private _isPlayingAudio is a hack with App Store rejection risk; there should be a public alternative to find

**Spec said:** KVO on the private _isPlayingAudio is a hack with App Store rejection risk; there should be a public alternative to find.

**Reality:** Half right and half wrong, and the half that is wrong matters. There IS no public alternative — an exhaustive grep of every public WebKit header in the macOS 26.5 SDK finds nothing, and Apple's own WKWebExtensionTab protocol asks the HOST APP `- (BOOL)isPlayingAudioForWebExtensionContext:` rather than providing it, which means Apple ships a public extension API that a WKWebView browser structurally cannot implement correctly without SPI. Conversely, _isPlayingAudio is far less of a hack than assumed: WebKit deliberately maintains KVO compliance for it via PageClientImplCocoa::isPlayingAudioWillChange/DidChange calling willChangeValueForKey/didChangeValueForKey on @selector(_isPlayingAudio), and it is backed by MediaProducerMediaState::IsPlayingAudio — true audibility, including WebAudio. The public requestMediaPlaybackState() is NOT equivalent: it is poll-only with no notification, it is an async IPC that returns None whenever the web process is not running, and it reports HTMLMediaElement playback (a muted autoplaying video reads Playing). Decision: if Pane ships notarized outside the Mac App Store, use _isPlayingAudio KVO with a guarded respondsToSelector + @try and a WKUserScript fallback. If Mac App Store distribution is required, SPI is disqualifying and you must inject a documentStart WKUserScript into all frames (forMainFrameOnly:NO) hooking HTMLMediaElement play/pause/volumechange/ended plus AudioContext.state.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/Cocoa/PageClientImplCocoa.mm


### (MAJOR) interactionState captures the tab's state so a discarded tab restores to where the user left off.

**Spec said:** interactionState captures the tab's state so a discarded tab restores to where the user left off.

**Reality:** It captures back/forward list, per-item scroll position, page scale, history.pushState state objects, POST bodies and form ELEMENT state (document->formElementsState()) — and nothing else. It does NOT capture window.sessionStorage, live JS heap state, open WebSocket/SSE connections, WebRTC sessions, video playback position, canvas/WebGL contents, nested scroller offsets, Service Worker in-flight state, or IndexedDB transactions. sessionStorage in particular is unrecoverable: the only mechanism WebKit offers is the SPI `_webViewToCloneSessionStorageFrom`, which requires a LIVE source WKWebView and is therefore useless after you deallocate the tab. Concrete failure: a user with a half-written Gmail draft or a multi-step checkout in a background tab loses it on discard. Real-world confirmation: Orion, Kagi's shipping WKWebView browser with the identical 5-minute tab-suspend feature, has a tracked unrecoverable-breakage defect for tabs suspended with media open. Discard must be gated by heuristics (never discard tabs with unsaved form input, active media, active capture, or recent POST navigations), not applied uniformly on a timer.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewConfigurationPrivate.h


### (MAJOR) takeSnapshot(configuration:) can be used to grab thumbnails, with concerns about whether it works on offscreen/hidden we

**Spec said:** takeSnapshot(configuration:) can be used to grab thumbnails, with concerns about whether it works on offscreen/hidden web views.

**Reality:** Better than feared in one way, worse in three others. Better: on macOS takeSnapshot is a software paint performed inside the WebContent process (WebPage::snapshotAtSize -> paintSnapshotAtSize), NOT a window-server capture, so it does not require the view to be in a window. Worse: (1) WebKit's own comment states "Software snapshot will not capture elements rendered with hardware acceleration (WebGL, video, etc)" — video tiles and WebGL canvases come back blank, exactly the tabs a thumbnail is most useful for; (2) it requires a LIVE, responsive WebContent process, and there is no timeout, so a hung or suspended web process leaves the completion handler unfired forever — you must impose your own timeout; (3) takeSnapshotWithConfiguration: is guarded by THROW_IF_SUSPENDED, which raises NSInternalInconsistencyException, so snapshotting a page suspended via the -_suspendPage: SPI hard-crashes the app. Also note afterScreenUpdates is silently ignored on macOS. Correct ordering is: snapshot FIRST, while the tab is still live and visible, then suspend/discard.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm


### (MINOR) (Implicit) Persisted interactionState blobs are small enough to store per tab without bounds.

**Spec said:** (Implicit) Persisted interactionState blobs are small enough to store per tab without bounds.

**Reality:** On macOS there is no cap at all: maximumSessionStateDataSize is 2 MB on iOS but std::numeric_limits<uint32_t>::max() on macOS, so nothing is ever truncated. Blob size scales with back/forward depth and with per-entry stateObjectData (history.pushState payloads) and httpBody (POST bodies). A long-lived SPA session can accumulate hundreds of pushState entries each carrying a serialized state object. For a browser persisting hundreds of tabs to disk on every mutation this is a real, unbounded footprint. Mitigations: trim the back/forward list before capture using the SPI -_sessionStateWithFilter: (Data via _sessionStateData), or cap stored history depth yourself, and compress the blob at rest.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/Cocoa/LegacySessionStateCoding.cpp


### (MINOR) (Implicit) The Swift type of interactionState is Data, and macOS 26's new SwiftUI WebKit API is a viable path.

**Spec said:** (Implicit) The Swift type of interactionState is Data, and macOS 26's new SwiftUI WebKit API is a viable path.

**Reality:** Two facts to plan around. (1) In Swift the property is `var interactionState: Any? { get set }`, not `Data?` — there is no compile-time type safety, and both the getter's cast and the setter's silent isKindOfClass:[NSData class] check are runtime-only. (2) The new macOS 26 `WebPage` class has NO interactionState, no sessionState and no restore of any kind — its complete public surface in the macOS 26.5 SDK swiftinterface omits session state entirely. Choosing WebPage/SwiftUI WebView would eliminate tab restore outright. Pane's AppKit + WKWebView choice is therefore not merely stylistic — it is load-bearing for this feature, and that should be recorded as a hard architectural constraint.

**Source:** https://developer.apple.com/tutorials/data/documentation/webkit/wkwebview/interactionstate.json


### (MINOR) (Implicit) interactionState read at discard time reflects the user's current scroll position and form contents.

**Spec said:** (Implicit) interactionState read at discard time reflects the user's current scroll position and form contents.

**Reality:** True in practice but only because of an async IPC you must not race. WebPageProxy::sessionState() does zero IPC — it reads UI-process-side state only. The web process pushes scroll/form state up at two moments: WebPage::pageStoppedScrolling() after a scroll gesture settles, and WebPage::visibilityDidChange() when the page goes non-visible (WebKit's comment: "We save the document / scroll state when backgrounding a tab so that we are able to restore it if it gets terminated while in the background"). Both propagate via HistoryItem::notifyChanged() -> BackForwardUpdateItem, which is asynchronous. So reading interactionState in the same turn that you remove the WKWebView from its superview can capture a stale scroll offset. Order it: detach/hide -> await at least one main-loop turn (in practice a short delay or a didFinishNavigation/visibility settle) -> read interactionState -> then deallocate.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/WebProcess/WebPage/WebPage.cpp


## Recommended approach

Collapse the spec's tiers from three to two, because WebKit owns one of them already.

Tier 1 — Freeze: delete this work. Set `config.preferences.inactiveSchedulingPolicy = .suspend` (macOS 14+) once, explicitly, and remove the background WKWebView from its superview. That is the whole implementation. Do NOT use `-_suspendPage:`/`-_resumePage:` SPI — it sets `_page->isSuspended()`, and every subsequent `THROW_IF_SUSPENDED` call site (`takeSnapshotWithConfiguration:`, `setInteractionState:`, `requestMediaPlaybackStateWithCompletionHandler:`, `evaluateJavaScript:`) raises `NSInternalInconsistencyException`.

Tier 2 — Discard (the only tier that reclaims memory). Sequence, strictly ordered:

1. `takeSnapshot(configuration:)` while the view is still live and in-window. Wrap in `withTimeout` (~750ms) — there is no built-in timeout. Set `WKSnapshotConfiguration.snapshotWidth` to your thumbnail width so the web process rasterizes small; the returned bitmap crosses IPC.
2. Detach the view; `await Task.yield()` plus one short delay so `WebPage::visibilityDidChange()`'s `saveDocumentAndScrollState()` → `BackForwardUpdateItem` IPC lands.
3. `guard let blob = webView.interactionState as? Data else { … }`. Persist `TabRecord(url: URL, title: String, blob: Data?, capturedAt: Date)` — the URL is the mandatory fallback.
4. `await webView.setAllMediaPlaybackSuspended(true)`, then deallocate the WKWebView. Only deallocation kills the WebContent process and reclaims RSS.

Restore: create the WKWebView, assign `interactionState = blob`, and if no `WKNavigation` results within ~50ms (`restoreFromSessionState` returns nil when decode fails or `currentIndex` is nil), fall back to `webView.load(URLRequest(url: record.url))`. Keep the snapshot on screen until `didCommit`.

Gating heuristics matter more than the mechanism. Never discard when: `_isPlayingAudio` (or your JS fallback) is true; `cameraCaptureState`/`microphoneCaptureState` != `.none`; `mediaPlaybackState() == .playing`; the page has dirty form input; or the last navigation was a POST. Orion ships this exact feature and has an unrecoverable-breakage bug for tabs suspended with media open.

Audio: decide distribution first. Notarized-outside-MAS → `_isPlayingAudio` KVO behind `respondsToSelector` + `@try`. MAS → `WKUserScript` at `.atDocumentStart`, `forMainFrameOnly: false`, hooking `HTMLMediaElement` play/pause/volumechange/ended and `AudioContext.state`.


## Effort estimate

14-20 dev days solo, and the distribution of that cost is counterintuitive — almost none of it is the APIs. Setting inactiveSchedulingPolicy, capturing/assigning interactionState, and calling setAllMediaPlaybackSuspended is roughly 2 days total including the persistence layer. The remaining 12-18 days are: (a) discard-gating heuristics and the dirty-form/unsaved-state detection that keeps you from destroying users' work — 4-6 days, and this is the part that determines whether the feature is shippable or a reputation-ending data-loss bug; (b) the snapshot pipeline with its own timeout, disk cache, eviction, HiDPI handling and the fact that video/WebGL tiles come back blank — 3-4 days; (c) audio detection plus a JS-injection fallback path and the extension-API plumbing for WKWebExtensionTab.isPlayingAudio(for:) — 2-3 days; (d) restore-failure fallback, the async scroll-state race, and soak testing across the tab states that actually break (media, capture, POST, SPA pushState depth) — 3-5 days. Add 2-3 days of contingency if Mac App Store distribution is required, since that removes _isPlayingAudio and forces the JS path to be the primary rather than the fallback. Note the effort estimate would DROP by 3-4 days versus the original spec, because the manual background-freezing tier is deleted outright.


## Open questions

- Distribution channel is the single highest-leverage unknown: Mac App Store or notarized DMG? It decides whether _isPlayingAudio KVO (and _sessionStateWithFilter: for blob trimming) are available at all, and it changes the audio-detection design from a 20-line KVO observer to a full injected-JS subsystem with cross-origin iframe coverage. Everything else in this area is settled; this is not.
- What is the actual measured cost of the discard/restore round trip on target hardware? Every number here is either from source reading or third-party reports. Build a 50-tab harness that measures (1) RSS delta from deallocating a WKWebView, (2) wall-clock from `interactionState = blob` to didCommit and to didFinishNavigation, split by warm/cold HTTP cache and by whether a cached WebContent process was available, and (3) p50/p95 interactionState blob size across a realistic tab mix including long-lived SPAs. The sub-200ms claim lives or dies on measurement (2).
- Does WebKit's WebProcessCache actually engage for Pane? Capacity is min(ramSize/256MB, 32) but it is gated on `LegacyGlobalSettings::singleton().cacheModel() == CacheModel::PrimaryWebBrowser`. Cache model is not settable through public WKWebView API. If Pane does not land in PrimaryWebBrowser mode, both the process cache and process prewarming are off, and restore latency gets materially worse. Worth verifying empirically via `os_log` filtering on the ProcessSwapping subsystem (`WebProcessCache::updateCapacity` logs its computed capacity and the reason when it is zero).
- How large do interactionState blobs actually get for hostile-but-normal sites, given macOS applies no truncation at all (maximumSessionStateDataSize is UINT32_MAX off iOS)? Specifically measure a long Gmail/Figma/Slack session with deep history.pushState state objects. If p95 is in the megabytes, the persistence layer needs blob trimming via the -_sessionStateWithFilter: SPI or a self-imposed history-depth cap — which loops back to the distribution-channel question.
- Is the 4-byte version header worth validating defensively before handing the blob to setInteractionState:? Reading the leading uint32 yourself and comparing against the value observed at capture time would convert WebKit's silent no-op into a detectable condition and let you fall back to load(URLRequest) deterministically rather than on a timeout. This depends on being willing to encode an implementation detail of an undocumented format — a judgment call worth making explicitly rather than by default.
- What is the intended behavior for pinned tabs and tabs with active WebSocket/SSE connections (chat, dashboards, CI monitors)? These are precisely the tabs where WebKit's default .suspend policy is already correct and where discard is user-hostile, but they are also the ones that hold memory longest. There is no API to distinguish them; it needs a product decision plus probably a user-visible per-site exclusion list.


---

## Adversarial verification

A second agent was instructed to **refute** the above, defaulting to 'refuted' absent primary-source confirmation.

**Upheld:** `True` · **Corrected verdict:** `works-with-caveats`


### APIs cited that could NOT be found in any documentation

- mediaPlaybackState() — cited in their gating-heuristic list as `mediaPlaybackState() == .playing`. No such WKWebView property or method exists in MacOSX26.5.sdk. The real API is requestMediaPlaybackStateWithCompletionHandler: (async requestMediaPlaybackState()); the bare requestMediaPlaybackState: spelling is API_DEPRECATED_WITH_REPLACEMENT(macos(11.3, 12.0)).

### APIs confirmed to exist

- `WKPreferences.inactiveSchedulingPolicy — macOS 14.0+ (MacOSX26.5.sdk WKPreferences.h:99, API_AVAILABLE(macos(14.0), ios(17.0)))`
- `WKInactiveSchedulingPolicy {Suspend=0, Throttle=1, None=2} — WKPreferences.h:89-93`
- `WKWebView.interactionState — macOS 12.0+ (WKWebView.h:542), type id / Any?`
- `-[WKWebView takeSnapshotWithConfiguration:completionHandler:] — macOS 10.13+ (WKWebView.h:429, NSImage on macOS)`
- `WKSnapshotConfiguration.snapshotWidth / .rect (macOS 10.13+) and .afterScreenUpdates (macOS 10.15+) — WKSnapshotConfiguration.h`
- `-[WKWebView setAllMediaPlaybackSuspended:completionHandler:] — macOS 12.0+ (WKWebView.h:369)`
- `-[WKWebView requestMediaPlaybackStateWithCompletionHandler:] — macOS 12.0+ (WKWebView.h:382)`
- `WKWebView.cameraCaptureState / .microphoneCaptureState — macOS 12.0+ (WKWebView.h:391, 397)`
- `WKMediaCaptureState / WKMediaPlaybackState enums — WKWebView.h:70-80`
- `-[WKWebExtensionTab isPlayingAudioForWebExtensionContext:] — WKWebExtensionTab.h:188 (host app implements it; WebKit does not provide it)`
- `-[WKWebView _isPlayingAudio] — SPI, WKWebView.mm:6556, KVO-compliant via PageClientImplCocoa::isPlayingAudioWillChange/DidChange`
- `-[WKWebView _suspendPage:] / -[WKWebView _resumePage:] — SPI, WKWebView.mm:5414/5425`
- `WKWebViewConfiguration._webViewToCloneSessionStorageFrom — SPI, WKWebViewConfigurationPrivate.h:59, declared (nonatomic, weak) WKWebView *`
- `WebKit::encodeSessionState / decodeSessionState -> encodeLegacySessionState / decodeLegacySessionState (SessionStateCoding.mm) — still the only path in main`

### Refutations


**Claim:** interactionState: 'Apple's entire public documentation is one abstract sentence with no discussion section, no stated type, and no persistence or compatibility guarantee.'

**Why it is wrong:** Two of the three sub-claims are wrong. (a) The type IS stated: the DocC JSON declares `var interactionState: Any? { get set }` / `@property (nonatomic, copy, nullable) id interactionState`. (b) The SDK header is NOT bare — MacOSX26.5.sdk WKWebView.h:538-541 carries a full @discussion: 'The interaction state (back-forward list, currently loaded page, scroll position, form data...) for the WKWebView, which can be retrieved and set on another WKWebView to restore state.' Apple explicitly names form data and scroll position. The researcher never read the header for this claim, only the web page. Their CONCLUSION survives and is in fact better supported by the header than by their argument: the documented use is transfer to ANOTHER LIVE WKWebView, not serialization to disk — so there is still no persistence or cross-version guarantee. But the stated evidence is inaccurate.

**Source:** https://developer.apple.com/tutorials/data/documentation/webkit/wkwebview/interactionstate.json


**Claim:** 'for an app linked against the macOS 15+ SDK it is the DEFAULT with zero lines of code' — presented as a per-WKWebView property.

**Why it is wrong:** Suspension is decided per WebContent PROCESS, not per WKWebView, and the researcher never says so. WebProcessProxy::shouldTakeNearSuspendedAssertion() (WebProcessProxy.cpp:868-886) iterates every page in m_pageMap and returns true — i.e. the process is NOT fully suspended — if ANY page in that process has shouldTakeNearSuspendedAssertions() true OR pageVisibilityBasedProcessSuppressionEnabled() false. Same-site tabs share a WebContent process in WebKit's process model, so a background tab sitting in the same process as a visible tab gets no suspension at all, no matter what inactiveSchedulingPolicy says. Pane must measure per-process residency, not assume per-tab savings. (The second disjunct is benign by default: UnifiedWebPreferences.yaml:6638-6648 gives PageVisibilityBasedProcessSuppressionEnabled a WebKit default of true.)

**Source:** https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebProcessProxy.cpp


**Claim:** 'A WKWebView detached from the view hierarchy already has ... releaseMemory() run.' Stated unconditionally as part of what WebKit gives you for free.

**Why it is wrong:** WebProcess::prepareToSuspend guards it: `if (!m_suppressMemoryPressureHandler && m_wasVisibleSinceLastProcessSuspensionEvent && !m_pageMap.isEmpty() && !isProcessBeingCachedForPerformance()) releaseMemory([] { });` followed immediately by `m_wasVisibleSinceLastProcessSuspensionEvent = false;`. WebKit's own comment says it 'only allow[s] this once for every time the process contains a visible page' and explicitly skips it for processes held in the WebProcessCache. So releaseMemory runs at most once per visible→background transition and never for cached processes. freezeAllLayerTrees(), destroyRenderingResources() and suspendAllMediaBuffering() ARE unconditional on that path — those parts of the claim check out.

**Source:** https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebProcess.cpp


**Claim:** Restore fallback: 'if no WKNavigation results within ~50ms (restoreFromSessionState returns nil when decode fails or currentIndex is nil), fall back to webView.load(...)'.

**Why it is wrong:** The return value they propose to key off is unreachable. -[WKWebView setInteractionState:] discards it: the body is `_page->restoreFromSessionState(sessionState, true);` with no assignment (WKWebView.mm:1828-1838). There is no WKNavigation handed back and no delegate contract that one arrives inside 50ms — a cold WebContent process launch alone can exceed that, so the timer will fire spuriously and issue a second load on top of an in-flight restore. A synchronous, race-free test does exist and they missed it: WebPageProxy::restoreFromSessionState calls backForwardList().restoreFromState(...) BEFORE the navigate branch (WebPageProxy.cpp:6573-6589), so immediately after assigning interactionState, `webView.backForwardList.currentItem != nil` is true iff the blob decoded and currentIndex was set. Gate the fallback on that, not on a 50ms timer.

**Source:** https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm


**Claim:** Tier 2 step 2: 'Detach the view; await Task.yield() plus one short delay so WebPage::visibilityDidChange()'s saveDocumentAndScrollState() -> BackForwardUpdateItem IPC lands.'

**Why it is wrong:** The mechanism is real (WebPage.cpp:4745-4754 confirms saveDocumentAndScrollState on becoming invisible) but the recipe races against the very suspension they are relying on. Detaching the view is exactly what drops the foreground assertion (WebPageProxy::updateThrottleState, WebPageProxy.cpp:3755-3763), and the save runs in the WebContent process whose reply must reach the UI process while RunningBoard is suspending it. A fixed 'short delay' has no guarantee of ordering against process suspension. Either read interactionState BEFORE detaching (accepting a possibly stale scroll offset) or drive the discard off an observed signal; do not use a sleep.

**Source:** https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebPage/WebPage.cpp


**Claim:** 'Orion, Kagi's shipping WKWebView browser with the identical 5-minute tab-suspend feature, has a tracked unrecoverable-breakage defect for tabs suspended with media open.' Cited twice as real-world confirmation.

**Why it is wrong:** Uncited and unverifiable. No URL, issue number or title is given. orionfeedback.org returned HTTP 404 on the search endpoints I tried and I had no web-search budget to locate it another way. This is the only external/real-world evidence in the entire report and it is the one item with no primary source. Treat it as an assertion, not a finding — the gating-heuristic recommendation it supports is independently justified by the SessionState struct contents, so nothing downstream collapses, but do not cite Orion to a stakeholder without a link.

**Source:** https://orionfeedback.org


**Claim:** Tier 1 implementation is 'set inactiveSchedulingPolicy and remove the background WKWebView from its superview.'

**Why it is wrong:** Incomplete rather than false — removeFromSuperview is not the only, or the best, trigger. PageClientImpl::isViewVisible (PageClientImplMac.mm:206-229) returns false on three independent conditions: nil window, `view.isHiddenOrHasHiddenAncestor`, and window occlusion (NSWindowOcclusionStateVisible clear). So `setHidden:YES` produces identical suspension without tearing down the view hierarchy or losing layout, and fully-covered windows suspend for free. For a tab switcher, hiding is strictly cheaper than detaching.

**Source:** https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/PageClientImplMac.mm


### Verifier notes

VERDICT: substantially upheld. This is the best-sourced of the reports I have checked — I attempted to break every load-bearing citation and all of them reproduced verbatim against WebKit main and MacOSX26.5.sdk. No iOS-for-macOS confusion, no deprecated-API substitutions, one nonexistent API name in a throwaway position.

WHAT I CONFIRMED VERBATIM (hard fact, all first-party):

1. The "free suspend" mechanism is exactly as described, and I traced the whole chain. WKPreferences.mm:205-207 — getter returns `backgroundWebContentRunningBoardThrottlingEnabled() ? (shouldTakeNearSuspendedAssertions() ? Throttle : Suspend) : None`. WebPreferencesDefaultValues.cpp:195-203 defaultRunningBoardThrottlingEnabled() = `#if PLATFORM(MAC) linkedOnOrAfterSDKWithBehavior(SDKAlignedBehavior::RunningBoardThrottling) #else false`. Lines 215-223 defaultShouldTakeNearSuspendedAssertion() = `!linkedOnOrAfterSDKWithBehavior(SDKAlignedBehavior::FullySuspendsBackgroundContentImmediately)`. RuntimeApplicationChecksCocoa.mm:198-200 disables RunningBoardThrottling only when linkedBefore DYLD_MACOSX_VERSION_14_0; line 218-219 disables FullySuspendsBackgroundContentImmediately only when linkedBefore DYLD_MACOSX_VERSION_15_0. Net: link against the macOS 15+ SDK on macOS and the effective policy is .suspend. Their central "delete Tier 1" argument is correct.

2. WebProcess.cpp prepareToSuspend does suspendAllMediaBuffering(), page->processWillSuspend(), (guarded) releaseMemory(), freezeAllLayerTrees(), destroyRenderingResources().

3. WKWebView.mm:1828-1838 setInteractionState: THROW_IF_SUSPENDED, silent return on non-NSData, silent return on decode failure, restoreFromSessionState(state, true). Confirms the "blank web view, no error, no delegate callback" failure mode.

4. WebPageProxy.cpp:6591 contains the literal `// FIXME: Navigating should be separate from state restoration.` and line 6602 `return goToBackForwardItem(*item, IsSessionRestoreNavigation::Yes);`. Restore-is-a-navigation is confirmed at source; the sub-200ms spec target is genuinely unachievable as a contract.

5. LegacySessionStateCoding.cpp:43 `static const uint32_t sessionStateDataVersion = 2;`, lines 520-523 write the 4-byte big-endian header, line 506 kCFPropertyListBinaryFormat_v1_0, lines 1153-1155 `uint32_t versionNumber = (data[0] << 24) + ...; if (versionNumber != sessionStateDataVersion) return false;`. SessionStateCoding.mm confirms encodeSessionState is still just a wrapper over encodeLegacySessionState — there is no newer format in main. Their format analysis is exact.

6. SessionState.h FrameState carries urlString, referrer, target, stateObjectData (pushState), scrollPosition, shouldRestoreScrollPosition, pageScaleFactor, httpBody (POST), title, m_documentState (form element state), children (subframes). No sessionStorage member. Their inventory of what is and is not captured is correct.

7. WKWebView.mm:1617-1620 contains the literal WebKit comment "Software snapshot will not capture elements rendered with hardware acceleration (WebGL, video, etc)." AND "This code doesn't consider snapshotConfiguration.afterScreenUpdates since the software snapshot always contains recent updates." Both of their snapshot claims are verbatim-correct, including afterScreenUpdates being ignored on macOS. takeSnapshotWithConfiguration: does carry THROW_IF_SUSPENDED (line 1571).

8. THROW_IF_SUSPENDED (WKWebView.mm:295-296) raises NSInternalInconsistencyException; 163 call sites. WebPageProxy::suspend (line 6502-6510) sets m_isSuspended = true. So the "-_suspendPage: poisons the object" warning is correct — I verified the macro is present on evaluateJavaScript, callAsyncJavaScript, requestMediaPlaybackStateWithCompletionHandler:, setAllMediaPlaybackSuspended:, reload, goBack and setInteractionState:.

9. Audio: exhaustive grep of ALL 216 public headers in MacOSX26.5.sdk/System/Library/Frameworks/WebKit.framework/Headers turns up exactly one audibility symbol — WKWebExtensionTab.h:188 `- (BOOL)isPlayingAudioForWebExtensionContext:`, which asks the host app. There is no public WKWebView audibility API on macOS 26. PageClientImplCocoa.mm:131-139 does willChangeValueForKey/didChangeValueForKey on NSStringFromSelector(@selector(_isPlayingAudio)) — KVO compliance is deliberate. WKWebView.mm:6556 `-_isPlayingAudio` returns `_page->isPlayingAudio()`; WebPageProxy.cpp:16549-16552 returns `mediaState.contains(MediaProducerMediaState::IsPlayingAudio)`; AudioContext.cpp:413-421 `mediaState()` returns IsPlayingAudio when audible — so WebAudio is covered, as claimed. And the public alternative really is not equivalent: WebPageProxy.cpp:11759-11767 returns `{}` (== None) when !hasRunningProcess(), and WebPage.cpp:1609-1620 decides Playing purely from mediaPlaybackExists/IsPaused/IsSuspended with no audibility or mute test — a muted autoplaying video does read Playing. Every part of their audio analysis holds.

10. WKWebViewConfigurationPrivate.h:59 declares _webViewToCloneSessionStorageFrom as `(nonatomic, weak) WKWebView *` — confirms it needs a live source view and is useless post-dealloc.

WHAT THEY MISSED THAT HELPS THEM (worth folding into the plan):
- WebPageProxy::updateThrottleState (WebPageProxy.cpp:3737-3803) already takes a foreground assertion for ActivityState::IsAudible (with an audibleActivityTimer grace period before release) and for IsCapturingMedia, plus a background assertion for muted capture. WebKit therefore already implements the audio/capture exemptions they prescribe by hand — for the freeze tier. Their gating heuristics remain necessary for the DISCARD tier only, because nothing stops the app from deallocating a view WebKit is protecting.
- The snapshot-ordering advice is stronger than they argued for. Once the view is out-of-window under .suspend, the WebContent process can already be RunningBoard-suspended, so a post-detach snapshot IPC may never be serviced at all — "snapshot first, while in-window" is mandatory, not merely preferable.

NET: three of their five majors and the fatal are fully source-confirmed. The interactionState-documentation major is right in conclusion but wrong in its stated evidence. The Orion citation is unverifiable. Add per-process (not per-tab) suspension accounting and replace the 50ms restore timer with a synchronous backForwardList.currentItem check. Verdict stays works-with-caveats.
