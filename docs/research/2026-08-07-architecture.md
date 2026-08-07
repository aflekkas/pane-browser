# Research — architecture

**Date:** 2026-08-07  
**Host:** macOS 26.5.2 (build 25F84), Apple Silicon, Swift 6.3.3, SDK MacOSX26.5  
**Target:** macOS 14+ deployment

**Area:** Architectural pressure-test: Swift 6 strict concurrency + AppKit shell + WKWebView content + single-actor SQLite store + NSOutlineView sidebar (macOS 26 / Tahoe)

**Verdict:** `works-with-caveats`  
*(not adversarially verified — treat every claim as one source deep)*


> Claims are tagged HARD FACT (fetched from a primary source) or INFERENCE.
> Findings are preserved as reported. Where a verifier disagreed, BOTH are kept —
> the disagreement is the information.


---

## Hard facts

- NSOutlineViewDiffableDataSource DOES NOT EXIST in the macOS 26.5 SDK. AppKit ships exactly two diffable data sources: NSCollectionViewDiffableDataSource (NSDiffableDataSource.h:86) and NSTableViewDiffableDataSource (NSTableViewDiffableDataSource.h:19). Verified by grepping /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers/ on the host (SDK 26.5).
  - min OS: `n/a`
  - https://developer.apple.com/documentation/appkit/nstableviewdiffabledatasource
- NSTableViewDiffableDataSource cannot be substituted: its header declares `@interface NSTableViewDiffableDataSource<...> : NSObject<NSTableViewDataSource>` (only NSTableViewDataSource), while NSOutlineView.h:35 declares `@property (nullable, weak) id <NSOutlineViewDataSource> dataSource;`. The types are incompatible even though NSOutlineView subclasses NSTableView.
  - min OS: `n/a`
  - https://developer.apple.com/documentation/appkit/nsoutlineview/datasource
- NSOutlineView.h and NSTableView.h in the macOS 26.5 SDK contain ZERO API_AVAILABLE(macos(15..26)) declarations — i.e. AppKit's outline/table views received no new API in macOS 15, 16, or 26. The supported animated-update path remains the macOS 10.7-era beginUpdates/insertItemsAtIndexes:inParent:withAnimation:/removeItemsAtIndexes:inParent:withAnimation:/moveItemAtIndex:inParent:toIndex:inParent:/endUpdates (NSOutlineView.h:132-142).
  - min OS: `macOS 10.7`
  - https://developer.apple.com/documentation/appkit/nsoutlineview/insertitems(at:inparent:withanimation:)
- WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate, WKHTTPCookieStore, WKWebView, WKWebViewConfiguration and WKWebsiteDataStore are ALL annotated WK_SWIFT_UI_ACTOR in the macOS 26.5 SDK. WK_SWIFT_UI_ACTOR is #defined to NS_SWIFT_UI_ACTOR (WKFoundation.h:60), which is #defined to NS_SWIFT_MAIN_ACTOR (Foundation/NSObjCRuntime.h:253). So the entire WebKit surface you touch is @MainActor — including the configuration objects.
  - min OS: `n/a`
  - https://developer.apple.com/documentation/webkit/wkwebviewconfiguration
- The decision/completion handler BLOCK PARAMETERS inside WKNavigationDelegate are themselves WK_SWIFT_UI_ACTOR, e.g. WKNavigationDelegate.h:82 `decisionHandler:(WK_SWIFT_UI_ACTOR void (^)(WKNavigationActionPolicy))decisionHandler`. In Swift this means the parameter type is `@escaping @MainActor (WKNavigationActionPolicy) -> Void`. A pre-Swift-6 signature without @MainActor SILENTLY FAILS TO MATCH the optional protocol requirement and the delegate method is never called at runtime — @preconcurrency import does NOT fix it and there is no warning.
  - min OS: `macOS 15 / iOS 18 (annotation added)`
  - https://developer.apple.com/forums/thread/773449
- NSResponder is declared NS_SWIFT_UI_ACTOR (NSResponder.h:20), so NSView, NSViewController, NSOutlineView, NSSplitViewController and WKWebView are all @MainActor by inheritance. NSOutlineViewDataSource / NSOutlineViewDelegate methods are individually annotated NS_SWIFT_UI_ACTOR (NSOutlineView.h:175-232). AppKit is correctly annotated for Swift 6 — 276 AppKit headers use NS_HEADER_AUDIT_BEGIN(nullability, sendability).
  - min OS: `n/a`
  - https://developer.apple.com/documentation/appkit/nsresponder
- WKPreferences.inactiveSchedulingPolicy (WKInactiveSchedulingPolicySuspend / Throttle / None) is the public API that actually stops a background web view. Header text: 'scheduling behavior when a web view is idle AND DETACHED FROM ALL WINDOWS ... A suspended web view will pause JavaScript execution and page layout.' Note the precondition: detached from all windows — merely setting isHidden=YES on a view still in a window does NOT qualify.
  - min OS: `macOS 14.0`
  - https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy
- macOS 26 adds WKWebView.fetchData(of:completionHandler:) / restoreData(_:completionHandler:) with WKWebViewDataType.sessionStorage (WKWebView.h:684-702), letting you serialize a live web view's session-storage blob and rehydrate it into a different WKWebView instance. This is the missing piece that makes a real (evicting) WKWebView pool viable rather than a pool that can only hold live views.
  - min OS: `macOS 26.0`
  - https://developer.apple.com/documentation/webkit/wkwebview/fetchdata(of:completionhandler:)
- macOS 26 adds webView(_:shouldGoToBackForwardListItem:willUseInstantBack:completionHandler:) to WKNavigationDelegate (WKNavigationDelegate.h:207), exposing WebKit's 'Instant Back' suspended-page resume to third-party clients.
  - min OS: `macOS 26.0`
  - https://developer.apple.com/documentation/webkit/wknavigationdelegate
- macOS 26 ships a first-party Swift-native WebKit overlay: `@MainActor final public class WebPage` conforming to Observation.Observable, with `WebPage.NavigationDeciding` and `WebPage.DialogPresenting` protocols replacing WKNavigationDelegate/WKUIDelegate, an AsyncSequence `navigations` stream, and Sendable-audited value types (WebPage.Configuration, NavigationAction, NavigationResponse, FrameInfo, NavigationPreferences). Verified in .../WebKit.framework/Modules/WebKit.swiftmodule/arm64e-apple-macos.swiftinterface (605 lines).
  - min OS: `macOS 26.0`
  - https://developer.apple.com/documentation/webkit/webpage
- WKProcessPool is API_DEPRECATED since macOS 12 with the note 'Creating and using multiple instances of WKProcessPool no longer has any effect.' (WKProcessPool.h:37). Any pooling strategy premised on sharing/segregating process pools is dead.
  - min OS: `deprecated macOS 12.0`
  - https://developer.apple.com/documentation/webkit/wkprocesspool
- NSFilePromiseProvider is the correct drag-out API and is unchanged; but NSFilePromiseProviderDelegate.filePromiseProvider(_:writePromiseTo:completionHandler:) is annotated NS_SWIFT_NONISOLATED (NSFilePromiseProvider.h:45) while the other two delegate methods (fileNameForType:, operationQueueForFilePromiseProvider:) are NS_SWIFT_UI_ACTOR. The write callback runs off the main actor on your NSOperationQueue.
  - min OS: `macOS 10.12`
  - https://developer.apple.com/documentation/appkit/nsfilepromiseprovider
- WWDC25 'What's new in SwiftUI': 'On macOS, lists of over 100,000 items now load 6x faster' and 'these lists update up to 16x faster.' SwiftUI List performance on macOS materially improved in the macOS 26 SDK.
  - min OS: `macOS 26.0`
  - https://developer.apple.com/videos/play/wwdc2025/256/
- Counter-evidence for HIERARCHICAL SwiftUI lists specifically: the lemonmojo/swiftui-hierarchical-list-performance repro was updated 2025-06-10 with 'Despite WWDC 25 announcements of much improved SwiftUI List performance, hierarchical lists, or at least the kind of list in this sample project are still slow on both iOS and macOS 26 beta 1.'
  - min OS: `macOS 26 beta 1`
  - https://github.com/lemonmojo/swiftui-hierarchical-list-performance
- SE-0466 (-default-isolation MainActor / SwiftSetting.defaultIsolation, Xcode setting SWIFT_DEFAULT_ACTOR_ISOLATION) shipped in Swift 6.2 and is present in the host's Swift 6.3.3 toolchain — `swiftc -help` lists `-default-isolation MainActor|nonisolated`. This is the setting that makes Swift 6 language mode tractable for an AppKit app.
  - min OS: `n/a (Swift 6.2+)`
  - https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
- GRDB 7.11.1 (June 2026) requires Swift 6.1+ / Xcode 16.3+, macOS 10.15+. DatabasePool opens the database in WAL mode and allows concurrent reads during writes; DatabaseQueue serializes everything on one connection. GRDB's own rule 1: 'Open one single DatabaseQueue or DatabasePool per database file, for the whole duration of your use of the database' — violating it causes SQLITE_BUSY and breaks ValueObservation. It has native async/await (`await dbPool.read {}`) that honors task cancellation.
  - min OS: `macOS 10.15`
  - https://github.com/groue/GRDB.swift
- GRDB 7's Swift Concurrency guide requires record types to be Sendable and explicitly states the legacy `Record` class 'is not Sendable, and its use is actively discouraged since GRDB 7'; it recommends structs of Sendable properties.
  - min OS: `n/a`
  - https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/SwiftConcurrency.md
- macOS 26 AppKit did add NSSplitViewItem.topAlignedAccessoryViewControllers / bottomAlignedAccessoryViewControllers / NSSplitViewItemAccessoryViewController and automaticallyAdjustsSafeAreaInsets (NSSplitViewItem.h:140-155), plus NSGlassEffectView — these are the Tahoe-native way to build a sidebar with pinned header/footer chrome under Liquid Glass.
  - min OS: `macOS 26.0`
  - https://developer.apple.com/documentation/appkit/nssplitviewitem
- Known macOS 26 AppKit regression in the wild: NSTableView rows scroll OVER the header view instead of clipping beneath it when the enclosing NSScrollView is flush to the top of its superview. Radar FB21850950; workaround is 1pt inset or disabling the scroll view border. NSOutlineView is an NSTableView subclass and is a likely inheritor of this bug.
  - min OS: `macOS 26.0`
  - https://troz.net/post/2026/appkit-table-scroll-bug-in-macos-tahoe/
- Community consensus is that Swift 6 language mode remains hard even with Approachable Concurrency. Steve Troughton-Smith: 'Swift 6 language mode is still a no-go, even with approachable concurrency turned on. I would be surprised if any full-featured UIKit app is able to use it.' GRDB's own author Gwendal Roué on the new dialect: 'This new language dialect creates incomprehensible compiler errors, and is so incompatible with the normal language that I'm supposed to rewrite all sample codes.'
  - min OS: `n/a`
  - https://mjtsai.com/blog/2025/11/03/swift-6-2-approachable-concurrency/

## Corrections to the spec


### (FATAL) NSOutlineView sidebar with a diffable data source.

**Spec said:** NSOutlineView sidebar with a diffable data source.

**Reality:** NSOutlineViewDiffableDataSource does not exist and never has. The macOS 26.5 SDK has only NSCollectionViewDiffableDataSource and NSTableViewDiffableDataSource, and the latter cannot be assigned to NSOutlineView.dataSource because it conforms only to NSTableViewDataSource while the property is typed id<NSOutlineViewDataSource>. The only third-party fill-in (cocoabits/OutlineViewDiffableDataSource) is years stale. The spec names an API that cannot be written down.

**Source:** https://developer.apple.com/forums/thread/770408


### (MAJOR) SwiftUI List will stutter at 200 rows with drag reorder, therefore use AppKit.

**Spec said:** SwiftUI List will stutter at 200 rows with drag reorder, therefore use AppKit.

**Reality:** The conclusion is right but the stated reason is wrong and will not survive contact with a reviewer. macOS 26 made flat SwiftUI List 6x faster to load and 16x faster to update at 100,000 items; 200 rows is nowhere near a perf cliff in macOS 26. The real disqualifiers are (a) HIERARCHICAL lists are still slow on macOS 26 per an actively-maintained repro, and (b) SwiftUI has no supported hierarchical drag-reorder: .onMove only works on ForEach and cannot be combined with List's `children:` keypath. Argue from the drag-reorder API gap, not from a 200-row perf claim you cannot substantiate.

**Source:** https://github.com/lemonmojo/swiftui-hierarchical-list-performance


### (MAJOR) Keep a hidden NSViewController hierarchy alive per space (implying hidden WKWebViews stop costing anything).

**Spec said:** Keep a hidden NSViewController hierarchy alive per space (implying hidden WKWebViews stop costing anything).

**Reality:** Hiding does not suspend. WKPreferences.inactiveSchedulingPolicy — the only public lever that pauses JS and layout — explicitly requires the web view to be 'idle AND detached from all windows'. A view that is merely isHidden=YES, or in a collapsed NSSplitViewItem, or in a child view controller whose view is still in the window, is still attached and still animating, still compositing in WindowServer, and still holds a WebContent process. Also: web views are not idle while playing media or loading, so an autoplaying background space never suspends at all.

**Source:** https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy


### (MAJOR) One SQLite file in WAL mode behind a single 'Store' actor.

**Spec said:** One SQLite file in WAL mode behind a single 'Store' actor.

**Reality:** WAL exists to let readers proceed concurrently with a writer. Putting a single Swift `actor` in front of it serializes every read behind every write and throws that away — you get the operational cost of WAL (-wal/-shm sidecar files, checkpointing, backup complexity) with none of the concurrency benefit. Worse, GRDB's ValueObservation and DatabasePool assume they own the connection; wrapping them in a bespoke actor adds a second serialization layer and a reentrancy hazard (actor hops inside a synchronous transaction block). Use DatabasePool as the concurrency primitive and keep 'Store' as a non-actor @MainActor-agnostic Sendable facade.

**Source:** https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Concurrency.md


### (MAJOR) Swift 6 strict concurrency (implied: Swift 6 language mode from day one).

**Spec said:** Swift 6 strict concurrency (implied: Swift 6 language mode from day one).

**Reality:** Realistic, but ONLY with -default-isolation MainActor (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor) plus SWIFT_APPROACHABLE_CONCURRENCY = YES. Without it you will spend weeks annotating a codebase that is 95% main-thread by nature. And there is one genuinely dangerous trap: WebKit's decision-handler blocks are @MainActor-typed, so a delegate method written with a plain `@escaping (WKNavigationActionPolicy) -> Void` silently stops matching the optional protocol requirement and is NEVER CALLED — no warning, no crash, just a browser that navigates to everything. Mitigate by using the async delegate variants exclusively.

**Source:** https://developer.apple.com/forums/thread/773449


### (MAJOR) WKWebView pool (unqualified).

**Spec said:** WKWebView pool (unqualified).

**Reality:** Two things the spec does not account for. First, WKWebViewConfiguration and WKWebsiteDataStore are themselves @MainActor in the macOS 26 SDK, so the pool is main-actor-bound end to end and the Store actor can never own, vend, or cache a configuration. Second, if the pool's purpose is memory reclamation via eviction, macOS 26's new WKWebView.fetchData(of:.sessionStorage)/restoreData(_:) is the API that makes eviction non-lossy — without it, evicting a view loses sessionStorage and you get user-visible data loss on space switch.

**Source:** https://developer.apple.com/documentation/webkit/wkwebview/fetchdata(of:completionhandler:)


### (MINOR) NSPasteboard custom UTI + NSFilePromiseProvider for drag-out (as the modern API).

**Spec said:** NSPasteboard custom UTI + NSFilePromiseProvider for drag-out (as the modern API).

**Reality:** Correct and current — no correction to the API choice. Two additions the spec misses: the custom UTI must be declared as an exported type identifier in Info.plist or cross-app drags silently fail, and NSFilePromiseProviderDelegate's writePromiseTo:completionHandler: is annotated NS_SWIFT_NONISOLATED, so under Swift 6 it runs off the main actor and cannot touch your @MainActor model. You must capture a Sendable value snapshot at drag-begin time.

**Source:** https://developer.apple.com/documentation/appkit/nsfilepromiseprovider


### (MINOR) (Implicit, if the pool design assumes process sharing) shared WKProcessPool.

**Spec said:** (Implicit, if the pool design assumes process sharing) shared WKProcessPool.

**Reality:** WKProcessPool has been deprecated since macOS 12 with the SDK note 'Creating and using multiple instances of WKProcessPool no longer has any effect.' Process placement is now WebKit's business. Isolation between spaces comes from WKWebsiteDataStore (default vs nonPersistent vs, on macOS 14+, identifier-based persistent stores), not from process pools.

**Source:** https://developer.apple.com/documentation/webkit/wkprocesspool


## Recommended approach

Start in Swift 6 language mode, but only with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES` (SE-0466; verified present in the host's 6.3.3 toolchain). Everything AppKit/WebKit is then implicitly main-actor and you annotate only what leaves — the store and the disk I/O. Do NOT use `@preconcurrency import WebKit`; it masks the fatal signature trap. Adopt the async delegate forms exclusively: `func webView(_:decidePolicyFor:) async -> WKNavigationActionPolicy` and `func webView(_:decidePolicyFor:preferences:) async -> (WKNavigationActionPolicy, WKWebpagePreferences)`. Write one integration test that asserts each optional delegate method actually fires — a silently-unmatched selector is otherwise invisible.

Sidebar: hand-roll a diff. Keep a `Sendable` value-type tree (`struct Node: Identifiable, Hashable`), compute an old→new script with `CollectionDifference` per expanded parent, and apply it inside `outlineView.beginUpdates()` / `insertItems(at:inParent:withAnimation:)` / `removeItems(at:inParent:withAnimation:)` / `moveItem(at:inParent:to:inParent:)` / `endUpdates()`. Wrap that as your own ~200-line `OutlineDiffableDataSource<Item>`. Avoid `reloadItem(_:reloadChildren:)` for structural change — it is the documented crash vector. Drag: `outlineView(_:pasteboardWriterForItem:)` returning an `NSPasteboardItem` with your exported UTI for internal reorder, plus an `NSFilePromiseProvider` for drag-out; validate with `outlineView(_:validateDrop:proposedItem:proposedChildIndex:)` and `setDropItem(_:dropChildIndex:)` to retarget.

Store: use GRDB 7 `DatabasePool` directly as the concurrency primitive — one instance, app lifetime. Make `Store` a `final class: Sendable` facade holding the pool, not an `actor`. Reads go `try await pool.read { }`; live sidebar updates come from `ValueObservation`, not from your own change notifications.

Spaces: do not keep hidden view controllers in the window. Remove the inactive space's container view from the hierarchy (`removeFromSuperview()` + `removeChild`), keep the `WKWebView` retained off-window, and set `configuration.preferences.inactiveSchedulingPolicy = .suspend` (macOS 14+) so detachment actually pauses JS and layout. Before evicting a web view entirely, snapshot with `fetchData(of: .sessionStorage)` and rehydrate with `restoreData(_:)` (macOS 26+). Use `NSSplitViewItem.topAlignedAccessoryViewControllers` (macOS 26) for sidebar chrome, and inset the outline's scroll view 1pt to dodge the Tahoe header-overlap bug.


## Effort estimate

Roughly 25-35 dev days for a solo dev to get a credible shell skeleton (not a browser). Breakdown: hand-rolled outline diffing + animated apply + expansion-state preservation, 4-6d (this is the piece the spec assumed was free); drag/drop with custom UTI, internal reorder, and NSFilePromiseProvider drag-out under Swift 6 nonisolated callbacks, 4-6d; WKWebView pool with detach/suspend/evict + sessionStorage snapshot-restore + per-space WKWebsiteDataStore, 6-9d; GRDB store, schema, migrations, ValueObservation wiring, 4-6d; Swift 6 concurrency tax across the whole thing, 5-8d amortized. Cost is dominated by two things: (1) the concurrency tax, which is not a one-time migration but a per-feature drag every time an AppKit callback, a WebKit block, and your store meet in one function; and (2) the webview lifecycle state machine (live / detached-suspended / evicted-with-snapshot), which is where the real bugs will live and where no framework helps you. The SQLite layer is the cheapest part and should not be where the design energy goes.


## Open questions

- Should Pane build on the new macOS 26 `WebKit.WebPage` (@MainActor, Observable, NavigationDeciding, AsyncSequence navigations) instead of raw WKWebView + delegates? It is dramatically better Swift 6 ergonomics and is first-party, but it is 26.0-only, its SwiftUI `WebView` presentation may not expose the AppKit-level hooks a browser needs (custom context menus, find UI, per-view data stores), and it is one OS release old with unknown coverage of WKWebView's full surface. This is the single highest-leverage unresolved decision in the whole design.
- Does the macOS 26 NSTableView header-overlap scroll bug (FB21850950) reproduce on NSOutlineView in a source-list-styled sidebar? Needs a 30-minute empirical check before committing to AppKit, because the workaround (1pt inset) is visually incompatible with a flush Liquid Glass sidebar.
- What is the actual per-WKWebView resident cost on Apple Silicon under macOS 26 with inactiveSchedulingPolicy = .suspend and the view detached? No public number exists. This determines whether the pool holds 5 views or 50 and therefore whether eviction+sessionStorage-restore is even needed. Measure before designing the pool.
- Does `restoreData(_:)` restore back-forward history and scroll position, or only sessionStorage? The header only documents WKWebViewDataType.sessionStorage. If back-forward list is not covered, evicting a web view still loses history and you need a parallel WKWebView.interactionState (macOS 12+) snapshot alongside it.
- Does WebKit consider a web view attached to an off-screen or zero-sized window as 'detached from all windows' for suspension purposes? The header says 'detached from all windows', which suggests the common trick of parking views in an off-screen NSWindow defeats suspension entirely.
- Is per-space isolation supposed to mean separate cookie jars? If yes, that forces per-space WKWebsiteDataStore (identifier-based, macOS 14+), which multiplies networking process count and interacts badly with the pool — a pooled view cannot be reused across spaces with different data stores, because the data store is fixed at configuration time.
- Does the project want Swift 6 language mode as a hard gate, or as a direction of travel? Multiple credible practitioners report full-featured UIKit/AppKit apps still cannot reach clean Swift 6 mode even with Approachable Concurrency. A fallback plan (Swift 5 mode + strict-concurrency=complete as warnings, flip the mode at v1.1) should be explicitly blessed or explicitly rejected now, not discovered in month three.
