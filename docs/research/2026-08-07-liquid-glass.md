# Research — liquid-glass

**Date:** 2026-08-07  
**Host:** macOS 26.5.2 (build 25F84), Apple Silicon, Swift 6.3.3, SDK MacOSX26.5  
**Target:** macOS 14+ deployment

**Area:** Liquid Glass on macOS 26 (Tahoe) in AppKit — NSGlassEffectView / NSGlassEffectContainerView, and whether glass can sample a WKWebView backdrop

**Verdict:** `works-with-caveats`  
*(not adversarially verified — treat every claim as one source deep)*


> Claims are tagged HARD FACT (fetched from a primary source) or INFERENCE.
> Findings are preserved as reported. Where a verifier disagreed, BOTH are kept —
> the disagreement is the information.


---

## Hard facts

- NSGlassEffectView EXISTS as public AppKit API, macOS 26.0+, `@interface NSGlassEffectView : NSView`. Exactly four own properties, verified against the shipping SDK header on this machine: `@property (nullable, strong) __kindof NSView *contentView;` `@property CGFloat cornerRadius;` `@property (nullable, copy) NSColor *tintColor;` `@property NSGlassEffectViewStyle style;`. No `spacing`, no `material`, no `blendingMode`, no `isEmphasized`.
  - min OS: `macOS 26.0`
  - file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSGlassEffectView.h
- The Style enum has exactly TWO cases and is an NS_ENUM, not an options set: `typedef NS_ENUM(NSInteger, NSGlassEffectViewStyle) { NSGlassEffectViewStyleRegular, NSGlassEffectViewStyleClear } API_AVAILABLE(macos(26.0)) NS_SWIFT_NAME(NSGlassEffectView.Style);` — so Regular == 0 (the default), Clear == 1. Swift spelling: `.regular`, `.clear`.
  - min OS: `macOS 26.0`
  - file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSGlassEffectView.h
- NSGlassEffectContainerView EXISTS, macOS 26.0+, `: NSView`, with exactly two properties: `contentView` and `spacing`. The header documents the semantics literally: it "1. Elevates the z-order of descendants of `contentView` to position them above the `contentView`. 2. Merges descendants together if the views are sufficiently similar and within the proximity specified in ``spacing``. 3. Processes similar glass effect views as a batch to improve performance."
  - min OS: `macOS 26.0`
  - file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSGlassEffectView.h
- `spacing` DEFAULTS TO ZERO and zero is not a no-op. Header: "The default value, zero, is sufficient for batch processing eligible glass effect views, while avoiding distortion and merging effects for other views in close proximity." So you get the perf win (single sampling pass) at spacing=0; you only raise spacing when you actually want the blobby melding animation.
  - min OS: `macOS 26.0`
  - file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSGlassEffectView.h
- Yes, the container really does merge sampling passes. WWDC25-310: "Using a glass effect container allows these elements to share their sampling region. Not only does this provide a more consistent visual result but it also improves the performance of the glass effect, since it only needs one sampling pass for the entire group."
  - min OS: `macOS 26.0`
  - https://developer.apple.com/videos/play/wwdc2025/310/
- GLASS CANNOT SAMPLE GLASS. WWDC25-310: "The glass material samples content from an area larger than itself. But what happens if that sampling region includes another glass element? Well, glass can't directly sample other glass, so the visual results in this case will not be consistent." This kills any design where a glass tab strip overlaps a glass URL bar overlaps a glass sidebar unless they all live in one NSGlassEffectContainerView.
  - min OS: `macOS 26.0`
  - https://developer.apple.com/videos/play/wwdc2025/310/
- `effectIsInteractive` is macOS 27.0 BETA ONLY. The docs JSON returns `"platforms":[{"beta":true,"introducedAt":"27.0","name":"macOS"}]`. Confirmed absent from the macOS 26.5 SDK header on this machine. Do not plan around it for a macOS 26 target.
  - min OS: `macOS 27.0 (beta)`
  - https://developer.apple.com/tutorials/data/documentation/appkit/nsglasseffectview/effectisinteractive.json
- Both classes are `APPKIT_API_UNAVAILABLE_BEGIN_MACCATALYST` — unavailable on Mac Catalyst. Irrelevant for a pure AppKit app but rules out any Catalyst escape hatch.
  - min OS: `macOS 26.0`
  - file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSGlassEffectView.h
- macOS WKWebView uses UI-SIDE COMPOSITING: `RemoteLayerTreeDrawingAreaProxyMac` materializes the web process's layer tree as REAL CALayers inside the host app's process (`remoteLayerTreeHost().layerForID()` returns actual CALayer objects that the UI process animates directly). Web content on macOS is NOT behind a CALayerHost/CAContext remoting boundary for the normal (non-video) case. This is the single most important fact for Pane.
  - min OS: `n/a`
  - https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/RemoteLayerTree/mac/RemoteLayerTreeDrawingAreaProxyMac.mm
- Glass/blur DOES sample WKWebView content in the shipping OS — and Apple DTS confirms it as intended behavior. In Apple forum thread 803917, a DTS Engineer acknowledged a KNOWN ISSUE (FB20655398, WebKit PR #52365) where `UIScrollEdgeElementContainerInteraction` over a WKWebView "stop[s] tracking the color of the content underneath it" after toggling `topEdgeEffect.style` .hard→.soft. Tracking the WKWebView content underneath is the expected behavior; it regressed. It re-regressed in iOS 27.0 seed 1 (FB23005490, June 2026).
  - min OS: `n/a`
  - https://developer.apple.com/forums/thread/803917
- VIDEO is the exception: WebKit's GPU Process hosts media layers across a process boundary via `LayerHostingContextManager` / `requestHostingContext(CompletionHandler<void(WebCore::HostingContext)>&&)` with `using LayerHostingContextID = uint32_t`. Media layers therefore ARE remote-hosted layers, unlike normal page content.
  - min OS: `n/a`
  - https://github.com/WebKit/WebKit/blob/main/Source/WebKit/GPUProcess/media/RemoteMediaPlayerProxy.h
- `WKWebView.obscuredContentInsets` is NEW public API in macOS 26.0 and exists precisely for the floating-chrome-over-web-content pattern: "Obscured content areas ... should be covered by UI elements managed by the client, such as a navigation bar or buttons. The web view automatically adjusts how fixed and sticky elements are rendered near edges with non-zero obscured insets." This is Apple sanctioning glass chrome overlaying a WKWebView.
  - min OS: `macOS 26.0`
  - file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/WebKit.framework/Versions/A/Headers/WKWebView.h
- There is NO `NSScrollView.topEdgeEffect` on macOS. `NSScrollEdgeEffectStyle` (macOS 26.1, with `automaticStyle`/`softStyle`/`hardStyle`) is exposed on exactly two surfaces in the whole 26.5 SDK: `NSTitlebarAccessoryViewController.preferredScrollEdgeEffectStyle` and `NSSplitViewItemAccessoryViewController.preferredScrollEdgeEffectStyle`, both macOS 26.1+. And macOS WKWebView exposes no `scrollView` (that property is `#if TARGET_OS_IPHONE`). The iOS recipe for scroll-edge glass over web content does not port.
  - min OS: `macOS 26.1`
  - file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSScrollEdgeEffect.h
- `NSBackgroundExtensionView` (macOS 26.0) is the companion API for the browser case — "A background extension view can be laid out to extend outside the safe area, such as under the titlebar, sidebar, or inspector" with `contentView` and `automaticallyPlacesContentView`. This is how you get page content mirrored/extended under glass chrome without literally stretching the web view.
  - min OS: `macOS 26.0`
  - file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSBackgroundExtensionView.h
- `NSGlassEffectView.Legibility` (cases `.standard` / `.increased`, plus `systemLegibility` and `setSystemLegibility(_:completionHandler:)`) is EXPORTED from the shipping AppKit binary on this machine but is NOT in the public header — it is SPI. Also SPI: `_variant`, `_subvariant`, `_scrimState`, `_subduedState`, `_contentLensing`, `_adaptiveAppearance`, `_groupIdentifier`, `_path` (CGPathRef, i.e. arbitrary glass shapes), `_useReducedShadowRadius`. Verified via `dyld_info -exports /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit | grep -i glass`.
  - min OS: `macOS 26.5 (observed)`
  - file:///System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
- `NSGlassEffectView` overrides `clipsToBounds` — confirmed in the exported symbol list (`NSGlassEffectView.clipsToBounds.getter/.setter`). Non-obvious and undocumented; relevant when you nest a web view or scroll view inside glass.
  - min OS: `macOS 26.0`
  - file:///System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
- OPEN, UNANSWERED BUG: "NSGlassEffectView issue on macOS 26.2" — background is cached and does not update when the window moves or when other windows are dragged underneath. Works on 26.0/26.1, broken on 26.2. Setting `movable`/`movableByWindowBackground = YES` fixes self-move but NOT other-window-move. Zero replies, no Apple response.
  - min OS: `macOS 26.2`
  - https://developer.apple.com/forums/thread/810314
- `NSGlassContainerView` was added inside `NSToolbarView` starting macOS 26 beta 1 and it INTERCEPTS MOUSE EVENTS, so overlaid interactive views in the titlebar/toolbar area stop receiving clicks. Directly hits any browser that puts a custom tab strip or URL field in the title bar area.
  - min OS: `macOS 26.0`
  - https://developer.apple.com/forums/thread/788928
- `.clear` style is NOT a drop-in for `.regular`. Per Apple's HIG guidance for Liquid Glass, Clear has no adaptive behavior, is permanently more transparent, and REQUIRES a dimming layer for legibility; use it only when the element sits on media-rich content, the content layer tolerates dimming, and the content above is bold and bright. For a browser toolbar over arbitrary web pages (which are usually white text-heavy documents) `.regular` is the only safe default.
  - min OS: `macOS 26.0`
  - https://developer.apple.com/videos/play/wwdc2025/219/
- Apple's only written performance guidance is qualitative: "If you apply these effects to custom elements, make sure to combine them using a GlassEffectContainer, which helps optimize performance" and "Avoid overusing Liquid Glass effects... Limit these effects to the most important functional elements in your app." There is no published cost budget, frame-time number, or guidance specifically about glass over rapidly-changing content.
  - min OS: `macOS 26.0`
  - https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- Only field measurement I could find (single anecdote, tool unnamed): scrolling a 230k-photo Photos library went from 5–6% GPU on Sequoia to 45% GPU on Tahoe. Reported as smooth but battery-hungry. Treat as directional, not a benchmark.
  - min OS: `macOS 26.0`
  - https://forums.macrumors.com/threads/liquid-glass-performance-gpu-battery.2463522/
- `accessibilityDisplayShouldReduceTransparency` is declared on `NSWorkspace` in NSAccessibility.h, `@property (readonly) BOOL`, API_AVAILABLE(macos(10.10)) — unchanged in the 26.5 SDK, still the correct thing to observe (alongside `accessibilityDisplayShouldIncreaseContrast` and `accessibilityDisplayShouldReduceMotion`). Apple's line on auto-degradation: "If you use standard components from system frameworks, this experience adapts automatically. Ensure you test your app's custom elements, colors, and animations with different configurations of these settings."
  - min OS: `macOS 10.10`
  - https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- Web content CANNOT opt into real Liquid Glass. The only mechanism is the private CSS `-apple-visual-effect: -apple-system-glass-material`, which is non-functional in public Safari and only works in WKWebView with the undocumented `useSystemAppearance` preference — "would result in App Store rejection if used in production." WebKit's internal name for the mechanism was "hosted blur" materials, renamed to "glass".
  - min OS: `n/a`
  - https://alastair.is/apple-has-a-private-css-property-to-add-liquid-glass-effects-to-web-content/
- The macOS Tahoe 26.0 release notes AppKit section contains exactly one entry (a TextKit `textRangeByIntersectingWithTextRange` fix, 138067979). There is no dedicated "AppKit release notes for macOS 26" page — /documentation/macos-release-notes/appkit-release-notes-for-macos-26 returns 404. There is no official errata list for glass; the bug surface is only discoverable via forums and FB numbers.
  - min OS: `n/a`
  - https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes

## Corrections to the spec


### (MAJOR) Glass will not work over a WKWebView because WKWebView content renders out-of-process in a remote layer tree that AppKit

**Spec said:** Glass will not work over a WKWebView because WKWebView content renders out-of-process in a remote layer tree that AppKit cannot sample.

**Reality:** Wrong for the general case on macOS. macOS WebKit uses UI-side compositing (`RemoteLayerTreeDrawingAreaProxyMac`); the web page's layer tree is materialized as real CALayers inside YOUR process, IOSurface-backed. There is no CALayerHost/CAContext boundary for ordinary page content, so glass sampling has nothing special to defeat it. The premise that the backdrop is a remote-hosted layer is an artifact of pre-2020 WebKit architecture. The exception is media: WebKit's GPU Process hosts video layers via `LayerHostingContextManager`, so video IS remote-hosted.

**Source:** https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/RemoteLayerTree/mac/RemoteLayerTreeDrawingAreaProxyMac.mm


### (MAJOR) Use `effectIsInteractive` to get the press/interaction response on Pane's glass controls.

**Spec said:** Use `effectIsInteractive` to get the press/interaction response on Pane's glass controls.

**Reality:** `effectIsInteractive` is macOS 27.0, still marked beta (`"beta":true,"introducedAt":"27.0"`). It is absent from the macOS 26.5 SDK header. On a macOS 26 target it does not exist. If you want an interactive-feeling glass control on 26, you must use standard AppKit controls (which get it via the toolbar/control glass path) or hand-animate.

**Source:** https://developer.apple.com/tutorials/data/documentation/appkit/nsglasseffectview/effectisinteractive.json


### (MAJOR) Add the glass view as a sibling/background behind your content views.

**Spec said:** Add the glass view as a sibling/background behind your content views.

**Reality:** Explicitly wrong per Apple. You MUST assign `glassView.contentView = yourView`. The header warns: "NSGlassEffectView only guarantees the contentView will be placed inside the glass effect; arbitrary subviews aren't guaranteed specific behavior with regard to z-order in relation to the content view or glass effect." WWDC25-310 adds that setting contentView is what lets AppKit apply the legibility treatments as the glass adapts. Sibling layout is unsupported and will break unpredictably across 26.x.

**Source:** https://developer.apple.com/videos/play/wwdc2025/310/


### (MAJOR) Stack/overlap glass chrome — glass sidebar, glass tab strip, glass URL bar, glass find bar — as independent views.

**Spec said:** Stack/overlap glass chrome — glass sidebar, glass tab strip, glass URL bar, glass find bar — as independent views.

**Reality:** Glass cannot sample glass. Any two overlapping-or-nearby NSGlassEffectViews that are not inside a shared NSGlassEffectContainerView will render inconsistently AND cost one sampling pass each. For Pane specifically, every piece of floating chrome in a window needs to live under one container per visual cluster.

**Source:** https://developer.apple.com/videos/play/wwdc2025/310/


### (MINOR) `spacing` is an optional tuning knob; leave it at the default and grouping does nothing.

**Spec said:** `spacing` is an optional tuning knob; leave it at the default and grouping does nothing.

**Reality:** Inverted. spacing=0 (the default) is exactly the mode that gives you batching/single-pass without side effects — the header says zero "is sufficient for batch processing eligible glass effect views, while avoiding distortion and merging effects for other views in close proximity." Raising spacing ADDS the melding/blob morph, which is a deliberate visual choice, not a perf knob.

**Source:** file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSGlassEffectView.h


### (MAJOR) Use `.clear` style for the toolbar so the page shows through.

**Spec said:** Use `.clear` style for the toolbar so the page shows through.

**Reality:** `.clear` has no adaptive appearance and requires you to supply your own dimming layer for legibility; the HIG scopes it to media-rich, bold, bright backdrops. Arbitrary web pages are mostly light text-on-white documents. `.clear` toolbar text will be unreadable on a large fraction of the web. Ship `.regular`; offer `.clear` only as a per-site/media-mode opt-in.

**Source:** https://developer.apple.com/videos/play/wwdc2025/219/


### (MAJOR) Mirror iOS: attach a scroll edge effect to the web view's scroll view so chrome fades over scrolling content.

**Spec said:** Mirror iOS: attach a scroll edge effect to the web view's scroll view so chrome fades over scrolling content.

**Reality:** Not possible on macOS. WKWebView's `scrollView` property is `#if TARGET_OS_IPHONE` only, and AppKit's `NSScrollEdgeEffectStyle` (26.1+) is only reachable through `NSTitlebarAccessoryViewController.preferredScrollEdgeEffectStyle` and `NSSplitViewItemAccessoryViewController.preferredScrollEdgeEffectStyle`. There is no `NSScrollView.topEdgeEffect`. If Pane wants the edge effect, its chrome must be a titlebar accessory or a split-view-item accessory — which constrains the whole window architecture.

**Source:** file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSScrollEdgeEffect.h


### (MAJOR) Glass will Just Work; the OS handles accessibility and we don't need our own fallback.

**Spec said:** Glass will Just Work; the OS handles accessibility and we don't need our own fallback.

**Reality:** Half true and dangerous. Apple only promises auto-adaptation for "standard components from system frameworks" and explicitly says "Ensure you test your app's custom elements, colors, and animations with different configurations of these settings." A custom NSGlassEffectView-based tab strip is a custom element. You must observe `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` (+ `...ShouldIncreaseContrast`) via the `NSWorkspace.didChangeAccessibilityDisplayOptionsNotification` and provide your own opaque fallback.

**Source:** https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass


### (MAJOR) Put Pane's tab strip / URL field in the window title bar area over the toolbar.

**Spec said:** Put Pane's tab strip / URL field in the window title bar area over the toolbar.

**Reality:** macOS 26 inserts a private `NSGlassContainerView` inside `NSToolbarView` that swallows mouse events, so interactive views overlaid on the titlebar/toolbar area stop receiving clicks. This is a shipped, reported regression that has been present since 26 beta 1. Budget real time for hit-testing workarounds or avoid the toolbar area entirely.

**Source:** https://developer.apple.com/forums/thread/788928


### (MAJOR) Use NSGlassEffectView (heavily tinted) to draw the whole window background, replacing NSVisualEffectView.

**Spec said:** Use NSGlassEffectView (heavily tinted) to draw the whole window background, replacing NSVisualEffectView.

**Reality:** Off-label. NSVisualEffectView is NOT deprecated in the 26.5 SDK (only the ancient 10.14-era materials are). NSGlassEffectView is a foreground effect for floating controls. Using it as the window background is what several shipping apps did and it produces the 26.2 stale-backdrop bug and unfocused-window artifacts. Keep NSVisualEffectView for window/sidebar background material and NSGlassEffectView for floating chrome.

**Source:** file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSVisualEffectView.h


### (MINOR) We can make web pages render with Liquid Glass via CSS.

**Spec said:** We can make web pages render with Liquid Glass via CSS.

**Reality:** No. `-apple-visual-effect: -apple-system-glass-material` is private, non-functional in public Safari, and requires the undocumented `useSystemAppearance` WKWebView preference — App Store rejection risk. Web content in Pane cannot participate in the glass material.

**Source:** https://alastair.is/apple-has-a-private-css-property-to-add-liquid-glass-effects-to-web-content/


### (MAJOR) Target macOS 26.0 and glass behavior will be stable across the 26.x line.

**Spec said:** Target macOS 26.0 and glass behavior will be stable across the 26.x line.

**Reality:** It demonstrably is not. NSGlassEffectView backdrop caching broke in 26.2 (works on 26.0/26.1, no Apple response). NSScrollEdgeEffectStyle only appeared in 26.1. The equivalent iOS glass-over-WKWebView sampling regressed in 26.1, was fixed, and regressed again in 27.0 seed 1. Pane needs per-minor-version visual QA and a kill switch.

**Source:** https://developer.apple.com/forums/thread/810314


## Recommended approach

Prototype the one unknown FIRST, in about 30 minutes, before any architecture commits: an NSWindow containing a full-bleed WKWebView, plus an `NSGlassEffectView` pinned over its top edge with `style = .regular`, `cornerRadius = 22`, `contentView` = a plain NSTextField. Load a page with a strong horizontal color gradient, scroll it, and watch whether the glass refracts and whether `.regular`'s adaptive light/dark flip tracks the page. Repeat with (a) a `<video>` element under the glass and (b) a DRM/EME stream. My strong inference is that (1) works — macOS is UI-side compositing, so page layers are real in-process CALayers and there is no remote-layer boundary — but (2)/(3) are genuinely at risk because WebKit's GPU Process hosts media layers cross-process via `LayerHostingContextManager`, and protected content is additionally marked no-capture. Assume glass over video may render as flat frosted gray or black.

Structure: one `NSGlassEffectContainerView` per visual cluster of chrome, `spacing = 0` unless you actually want melding. Assign `container.contentView = stackView`; each glass element is `NSGlassEffectView()` with `glass.contentView = control` — never a sibling background. Never overlap two containers.

Do not put chrome in the title bar. Use `NSWindow.titlebarAppearsTransparent = true` + `.fullSizeContentView` and float your own container, or make it an `NSTitlebarAccessoryViewController` if you want `preferredScrollEdgeEffectStyle = .softStyle` (26.1+). The private `NSGlassContainerView` inside `NSToolbarView` eats clicks.

Wire `webView.obscuredContentInsets = NSEdgeInsets(top: chromeHeight, ...)` (macOS 26.0+) so the page's layout viewport shrinks and `position: fixed`/sticky elements reflow correctly under your glass. This is the API Apple added for exactly this. Pair it with `NSBackgroundExtensionView` if you want the page's edge color to bleed under the sidebar/titlebar.

Accessibility: observe `NSWorkspace.didChangeAccessibilityDisplayOptionsNotification`, read `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` and `...ShouldIncreaseContrast`, and swap the whole container for an opaque `NSVisualEffectView`-or-solid variant. Apple only auto-degrades standard components; your custom tab strip is not one.

Availability: gate everything on `if #available(macOS 26.0, *)` with an NSVisualEffectView path. Skip `effectIsInteractive` (macOS 27 beta) and all `_`-prefixed SPI (`_variant`, `_path`, `Legibility`) — App Store risk. Ship a `PaneChrome.glassEnabled` kill switch, because glass demonstrably regressed within 26.x.


## Effort estimate

Roughly 6–10 dev days for a solo dev to ship production-quality glass chrome. Breakdown: ~0.5 day for the feasibility spike (glass over web content, glass over video, glass over DRM); ~2 days for the container/element architecture plus the NSVisualEffectView and Reduce-Transparency fallback paths; ~2–3 days fighting the titlebar/toolbar hit-testing problem and window-background/`backgroundColor = .clear` interactions, which is the single biggest time sink and has no documented solution; ~1 day on `obscuredContentInsets` + `NSBackgroundExtensionView` integration and getting sticky/fixed page elements to behave; ~1–2 days of cross-version visual QA on 26.0/26.1/26.2/26.5 (behavior differs) plus GPU/power profiling with Instruments. Cost is dominated by undocumented AppKit behavior and per-minor-version drift, not by the API itself — the API surface is genuinely tiny (4 + 2 properties).


## Open questions

- UNVERIFIED, HIGHEST PRIORITY: I found no direct empirical report of NSGlassEffectView visibly refracting live WKWebView page pixels on macOS 26. My conclusion is INFERENCE from (a) macOS using UI-side compositing and (b) Apple DTS confirming the equivalent iOS behavior is expected. Must be measured on the host machine.
- Does glass over a `<video>` element degrade? WebKit hosts media layers cross-process via LayerHostingContextManager. Untested. Same question for WebGL/canvas with GPU-process rasterization.
- Does glass over DRM/EME (Netflix, Apple TV+) content render black or gray? Protected surfaces are excluded from capture; backdrop sampling likely follows the same rule. This would be an ugly visible bug in a browser.
- Is the macOS 26.2 stale-backdrop bug (forum 810314) fixed in 26.5? It is unanswered by Apple. Needs to be reproduced on 26.5.2 directly. If still broken, that alone can sink the design.
- What is the actual frame-time cost of one glass sampling pass over a scrolling WKWebView at 120Hz on Apple Silicon? No Apple number exists. Needs an Instruments Metal System Trace on the prototype.
- Does `.regular`'s adaptive appearance sample the WKWebView backdrop continuously (per-frame) or does it latch? If it re-samples per frame over a scrolling page, that is a per-frame readback and the cost story changes completely.
- What is `NSGlassEffectView.Legibility` / `systemLegibility` actually for? It is exported from shipping AppKit 26.5 but absent from the public header — it may become public in 27 and may be the sanctioned answer to legibility over arbitrary web content. Worth watching, not worth using.
- Can Pane make the page background transparent so glass shows THROUGH web content (the Electron pattern)? macOS WKWebView has no public transparent-background API; `underPageBackgroundColor` (macOS 12+) only controls the under-page fill, and almost all real pages set their own opaque background. Probably a dead end but worth confirming.
- Does a WKWebView placed as the `contentView` of an NSGlassEffectView behave at all, given the class overrides `clipsToBounds`? Likely pathological, but should be ruled out explicitly rather than assumed.
