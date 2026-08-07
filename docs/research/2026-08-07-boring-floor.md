> **[SUPERSEDED IN PART 2026-08-07]** The quarantine finding below — "WebKit
> does not quarantine; `DownloadCocoa.mm` contains no quarantine code" — was
> **measured to be false** on macOS 26.5. A raw `WKDownload` with no app code
> and no Info.plist lands `com.apple.quarantine` on its own. Found by a mutation
> canary, not by reading. See `docs/api-notes/quarantine.md` for the
> measurement. The rest of this file stands.

# Research — boring-floor

**Date:** 2026-08-07  
**Host:** macOS 26.5.2 (build 25F84), Apple Silicon, Swift 6.3.3, SDK MacOSX26.5  
**Target:** macOS 14+ deployment

**Area:** The unglamorous browser floor: downloads, uploads, auth, cert errors, find-in-page, context menus, crash recovery (Swift 6 + AppKit + WKWebView, macOS 26 Tahoe)

**Verdict:** `works-with-caveats`  
*(not adversarially verified — treat every claim as one source deep)*


> Claims are tagged HARD FACT (fetched from a primary source) or INFERENCE.
> Findings are preserved as reported. Where a verifier disagreed, BOTH are kept —
> the disagreement is the information.


---

## Hard facts

- WKDownloadDelegate has exactly ONE @required method — download(_:decideDestinationUsing:suggestedFilename:completionHandler:) — and five @optional: willPerformHTTPRedirection:newRequest:decisionHandler:, didReceiveAuthenticationChallenge:completionHandler:, downloadDidFinish:, didFailWithError:resumeData:, plus the placeholder trio. Verified by reading the shipped header at /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/WebKit.framework/Headers/WKDownloadDelegate.h on the host (SDK 26.5).
  - min OS: `macOS 11.3`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKDownloadDelegate.h
- The download placeholder API — WKDownloadPlaceholderPolicy, download(_:decidePlaceholderPolicy:), download(_:didReceivePlaceholderURL:completionHandler:), download(_:didReceiveFinalURL:) — is annotated API_AVAILABLE(ios(18.2), visionos(2.2)) with NO macOS availability. It does not exist on macOS. Pane must draw its own in-progress download UI.
  - min OS: `n/a on macOS`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKDownloadDelegate.h
- WKDownload conforms to NSProgressReporting (so `download.progress` is a Foundation Progress you can KVO or wrap in an NSProgress observer). It exposes originalRequest, weak webView, weak delegate, and cancel(_: (Data?) -> Void) whose completion hands back resumeData. `isUserInitiated` and `originatingFrame` are macOS 15.2+.
  - min OS: `macOS 11.3 (15.2 for userInitiated/originatingFrame)`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKDownload.h
- Downloads are initiated three ways: (1) return .download from decidePolicyForNavigationAction → webView(_:navigationAction:didBecomeDownload:); (2) return .download from decidePolicyForNavigationResponse → webView(_:navigationResponse:didBecomeDownload:); (3) webView.startDownload(using:completionHandler:). Resume uses webView.resumeDownload(fromResumeData:completionHandler:). All are macOS 11.3+. In all cases you MUST set download.delegate inside the completion/callback or you get no events.
  - min OS: `macOS 11.3`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKNavigationDelegate.h
- Every WebKit delegate protocol and callback block in the modern headers is annotated WK_SWIFT_UI_ACTOR, which WKFoundation.h defines as NS_SWIFT_UI_ACTOR (i.e. @MainActor). Under Swift 6 strict concurrency, WKDownloadDelegate/WKUIDelegate/WKNavigationDelegate conformances and their completion handlers are all main-actor-isolated. Verified in WKFoundation.h lines 55-63 of the local SDK.
  - min OS: `macOS 11+`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/Shared/API/Cocoa/WKFoundation.h
- WKOpenPanelParameters, the PUBLIC class, has exactly two properties: allowsMultipleSelection and allowsDirectories (macOS 10.13.4+). There is NO public property exposing the HTML `accept` attribute. Signature: webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:) with completion ([URL]?) -> Void, API_AVAILABLE(macos(10.12), ios(18.4)).
  - min OS: `macOS 10.12 (10.13.4 for allowsDirectories)`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKOpenPanelParameters.h
- The accept-filter data exists only as SPI on WKOpenPanelParameters: _acceptedMIMETypes and _acceptedFileExtensions (macos 10.13.4+) and _allowedFileExtensions (macos 11.0+).
  - min OS: `macOS 10.13.4`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKOpenPanelParametersPrivate.h
- WKUIDelegate's contextMenuConfigurationForElement / contextMenuWillPresentForElement / contextMenuForElement:willCommitWithAnimator: / contextMenuDidEndForElement are ALL annotated API_AVAILABLE(ios(13.0)) with no macOS availability. They take UIContextMenuConfiguration. They are unavailable on macOS.
  - min OS: `n/a on macOS`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegate.h
- The macOS context-menu hook in WebKit is SPI: - (void)_webView:getContextMenuFromProposedMenu:(NSMenu *)menu forElement:(_WKContextMenuElementInfo *)element userInfo:(id<NSSecureCoding>)userInfo completionHandler:(void(^)(NSMenu *))handler, WK_API_AVAILABLE(macos(10.14)). The older _webView:contextMenu:forElement: variants are deprecated as of macOS 10.14.4.
  - min OS: `macOS 10.14 (SPI)`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegatePrivate.h
- The supported public macOS path for customizing a WKWebView context menu is AppKit: WKWebView is an NSView subclass, so a subclass can override willOpenMenu(_:with:) and didCloseMenu(_:with:) and mutate the NSMenu in place (identify items by NSMenuItem.identifier / tag).
  - min OS: `macOS 10.11 (NSView API)`
  - https://icab.de/blog/2022/06/12/customize-the-contextual-menu-of-wkwebview-on-macos/
- WKFindResult has exactly one property: `matchFound: Bool`. There is no match count and no current-match index. init is NS_UNAVAILABLE. WKFindConfiguration exposes only backwards, caseSensitive, wraps. Both are macOS 10.15.4+; findString(_:with:completionHandler:) is macOS 11.0+ and NS_REFINED_FOR_SWIFT (Swift name: find(_:configuration:)).
  - min OS: `macOS 11.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKFindResult.h
- WKWebView.isFindInteractionEnabled and .findInteraction (the system find bar) are API_AVAILABLE(ios(16.0)) only — not on macOS. On macOS, WKWebView instead declares `@interface WKWebView (WKNSTextFinderClient) <NSTextFinderClient>` API_AVAILABLE(macos(10.15.4)), so you drive the standard AppKit find bar via NSTextFinder with the web view as client.
  - min OS: `macOS 10.15.4 for NSTextFinderClient`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.h
- Match counting exists only as SPI: WKWebView _countStringMatches:options:maxCount: with a _findDelegate conforming to _WKFindDelegate (callback _webView:didCountMatches:), backed by _WKFindOptions.
  - min OS: `macOS (SPI, undated)`
  - https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewPrivate.h
- The exact quarantine keys, from LSQuarantine.h in the local SDK: kLSQuarantineAgentNameKey, kLSQuarantineAgentBundleIdentifierKey, kLSQuarantineTimeStampKey, kLSQuarantineTypeKey, kLSQuarantineDataURLKey, kLSQuarantineOriginURLKey; type values kLSQuarantineTypeWebDownload, kLSQuarantineTypeOtherDownload, kLSQuarantineTypeEmailAttachment, kLSQuarantineTypeInstantMessageAttachment, kLSQuarantineTypeCalendarEventAttachment, kLSQuarantineTypeOtherAttachment. All macOS 10.5+, API_UNAVAILABLE(ios). Header explicitly says AgentName, AgentBundleIdentifier and TimeStamp are filled in automatically if you omit them.
  - min OS: `macOS 10.5`
  - https://developer.apple.com/documentation/coreservices/klsquarantinetypekey
- The supported way to read/write them is the URL resource key NSURLQuarantinePropertiesKey (CFURL: kCFURLQuarantinePropertiesKey), macOS 10.10+, read-write, value type NSDictionary. Foundation's NSURL.h comment: "The quarantine properties as defined in LSQuarantine.h. To remove quarantine information from a file, pass NSNull as the value when setting this property." Use url.setResourceValues / (url as NSURL).setResourceValue(dict, forKey: .quarantinePropertiesKey). LSSetItemAttribute is NOT the modern path.
  - min OS: `macOS 10.10`
  - https://developer.apple.com/documentation/foundation/nsurlquarantinepropertieskey
- LSFileQuarantineEnabled — "A Boolean value indicating whether the files this app creates are quarantined by default" — is macOS 10.0+ and is NOT deprecated as of the current documentation.
  - min OS: `macOS 10.0`
  - https://developer.apple.com/documentation/bundleresources/information-property-list/lsfilequarantineenabled
- Verified locally on the host (macOS 26.5.2): /Applications/Safari.app/Contents/Info.plist contains LSFileQuarantineEnabled = true. Safari also carries com.apple.security.app-sandbox AND the private entitlement com.apple.private.app-sandbox.unquarantine (from `codesign -d --entitlements -`).
  - min OS: `macOS 26.5`
  - https://developer.apple.com/documentation/bundleresources/information-property-list/lsfilequarantineenabled
- Verified locally: /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/Exceptions.plist contains per-bundle-ID overrides that force LSFileQuarantineEnabled=true for known download-heavy apps (e.g. com.operasoftware.opera, com.panic.Transmit, Microsoft apps). LaunchServices decides quarantine from the app's Info.plist flag or this override list — a NEW bundle ID like Pane's is in neither, so it gets NO automatic quarantine unless it sets the flag itself.
  - min OS: `macOS 26.5`
  - https://eclecticlight.co/2025/12/08/who-decides-to-quarantine-files/
- WebKit's own download implementation (Source/WebKit/NetworkProcess/Downloads/cocoa/DownloadCocoa.mm) contains no reference to com.apple.quarantine, kLSQuarantine, or NSURLQuarantineProperties. WKDownload does not apply quarantine itself.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/NetworkProcess/Downloads/cocoa/DownloadCocoa.mm
- App Sandbox does apply com.apple.quarantine broadly: Microsoft's Erik Schwiebert, "The OS adds the quarantine xattr to any file created by an app that has been sandboxed"; Howard Oakley, "Since Apple introduced sandboxing for apps, the quarantine xattr has been used ... to flag which document files have been opened by sandboxed apps." Michael Tsai notes it does NOT apply when saving into a folder the app already has access to via a security-scoped bookmark.
  - min OS: `macOS 10.7+`
  - https://mjtsai.com/blog/2019/04/16/sandboxing-makes-quarantine-flags-almost-meaningless/
- WKNavigationDelegate.webView(_:didReceive:completionHandler:) (Swift: webView(_:respondTo:)) takes a full NSURLAuthenticationChallenge and a completion of (URLSession.AuthChallengeDisposition, URLCredential?). Header states the default when unimplemented: "the web view will respond to the authentication challenge with the NSURLSessionAuthChallengeRejectProtectionSpace disposition." All auth methods reach it, including NSURLAuthenticationMethodServerTrust, HTTPBasic/Digest/NTLM/Negotiate and ClientCertificate.
  - min OS: `macOS 10.10`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKNavigationDelegate.h
- WKDownload has its OWN separate auth challenge method — download(_:didReceive:completionHandler:) — with the same RejectProtectionSpace default. A download that redirects to an auth-protected host will NOT route through the navigation delegate; you must implement both.
  - min OS: `macOS 11.3`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKDownloadDelegate.h
- WebKit's network process, when a WKWebsiteDataStore has a dataStoreIdentifier, explicitly installs a per-identifier credential store on its NSURLSessionConfiguration: `configuration.get().URLCredentialStorage = adoptNS([[NSURLCredentialStorage alloc] _initWithIdentifier:parameters.dataStoreIdentifier->toString().createNSString().get() private:NO]).get();` (guarded by CFNETWORK_SEPARATE_CREDENTIAL_STORAGE). Per-profile credential isolation is therefore automatic when you use WKWebsiteDataStore(forIdentifier:), and is NOT something you can inject.
  - min OS: `macOS 14.0 (dataStoreForIdentifier:)`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/NetworkProcess/cocoa/NetworkSessionCocoa.mm
- WKWebsiteDataStore.dataStore(forIdentifier: UUID), removeDataStore(forIdentifier:completionHandler:) and fetchAllDataStoreIdentifiers are macOS 14.0+. New in macOS 26.0: fetchData(of:completionHandler:) and restoreData(_:completionHandler:) on WKWebsiteDataStore — useful for profile export/migration and recovery.
  - min OS: `macOS 14.0 / 26.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStore.h
- Accepting a bad server certificate via the public delegate is Apple's sanctioned path: the SPI -_allowTLSCertificateChain:forHost: is marked WK_API_DEPRECATED_WITH_REPLACEMENT("WKNavigationDelegate.didReceiveAuthenticationChallenge", macos(12.0, 14.2), ios(15.0, 17.2)). The replacement named by WebKit itself is the public didReceiveAuthenticationChallenge method.
  - min OS: `macOS 12.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStorePrivate.h
- The working recipe (confirmed in WebKit Bugzilla 140197, VERIFIED DUPLICATE of 135327 RESOLVED FIXED) is: in didReceiveAuthenticationChallenge, take challenge.protectionSpace.serverTrust, call SecTrustCopyExceptions() / SecTrustSetExceptions(), then complete with .useCredential and URLCredential(trust:).
  - min OS: `macOS 10.11+`
  - https://bugs.webkit.org/show_bug.cgi?id=140197
- SecTrustEvaluateWithError(SecTrustRef, CFErrorRef*) -> Bool is the current evaluation API (SecTrustEvaluate and SecTrustEvaluateAsync are API_DEPRECATED_WITH_REPLACEMENT to it). SecTrustCopyExceptions/SecTrustSetExceptions are NOT deprecated in the macOS 26.5 SDK. SecTrustGetTrustResult and SecTrustCopyResult (returns kSecTrustResultDetails) remain available; SecTrustCopyCertificateChain replaces SecTrustGetCertificateAtIndex (deprecated macOS 12.0). SecTrust.h states trust decisions "are persisted through the use of SecTrustCopyExceptions() and SecTrustSetExceptions()".
  - min OS: `macOS 10.14`
  - https://developer.apple.com/documentation/security/sectrustevaluatewitherror(_:_:)
- webViewWebContentProcessDidTerminate(_:) is macOS 10.11+ and carries NO reason parameter. The reason is SPI only: -_webView:webContentProcessDidTerminateWithReason:(_WKProcessTerminationReason) WK_API_AVAILABLE(macos(10.14)), with cases ExceededMemoryLimit, ExceededCPULimit, RequestedByClient, Crash, and ExceededSharedProcessCrashLimit (macOS 15.2+).
  - min OS: `macOS 10.11 public / 10.14 SPI`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKNavigationDelegatePrivate.h
- WKNavigationDelegate also offers webView(_:authenticationChallenge:shouldAllowDeprecatedTLS:) (macOS 11.0+) — a separate opt-in gate for TLS 1.0/1.1 that is distinct from the trust challenge and needs its own UI decision.
  - min OS: `macOS 11.0`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKNavigationDelegate.h

## Corrections to the spec


### (FATAL) Use WKUIDelegate's contextMenuConfigurationForElement (and the contextMenuWillPresent/willCommit/didEnd family) to build

**Spec said:** Use WKUIDelegate's contextMenuConfigurationForElement (and the contextMenuWillPresent/willCommit/didEnd family) to build Pane's page context menu.

**Reality:** Those four methods are annotated API_AVAILABLE(ios(13.0)) with no macOS availability and traffic in UIContextMenuConfiguration — a UIKit type. They do not exist on macOS and will never fire. On macOS the only public path is AppKit: subclass WKWebView and override NSView.willOpenMenu(_:with:) / didCloseMenu(_:with:), mutating the NSMenu WebKit hands you. The only WebKit-level hook is SPI (_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:, macos 10.14), which additionally gives you _WKContextMenuElementInfo (the hit-tested link/image URL) that willOpenMenu does not. Without SPI you must recover the hit-test target yourself — e.g. a WKUserScript contextmenu listener posting the target element to a WKScriptMessageHandler before the menu opens.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegate.h


### (MAJOR) Scope authentication per profile by giving each profile its own URLCredentialStorage.

**Spec said:** Scope authentication per profile by giving each profile its own URLCredentialStorage.

**Reality:** Two things are wrong. (1) WKWebView does not use your process's URLSession or URLCredentialStorage.shared at all — networking happens in the com.apple.WebKit.Networking process, and there is no public API to hand it a URLCredentialStorage. (2) You do not need to: WebKit already does per-profile credential isolation for you. NetworkSessionCocoa.mm sets configuration.URLCredentialStorage = [[NSURLCredentialStorage alloc] _initWithIdentifier:<dataStoreIdentifier> private:NO] whenever the WKWebsiteDataStore was created with an identifier. So the correct design is: one WKWebsiteDataStore(forIdentifier: UUID) per profile (macOS 14+), and credential scoping falls out. Writing to URLCredentialStorage.shared from Pane's app process is a no-op as far as WKWebView is concerned.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/NetworkProcess/cocoa/NetworkSessionCocoa.mm


### (MAJOR) You must set com.apple.quarantine on downloaded files yourself, because the sandbox/system will not do it.

**Spec said:** You must set com.apple.quarantine on downloaded files yourself, because the sandbox/system will not do it.

**Reality:** Half right, and the fix is one Info.plist line rather than code. WebKit genuinely does not quarantine (DownloadCocoa.mm has no quarantine code), so it will not happen for free from WKDownload. But the mechanism that does it is LaunchServices reading LSFileQuarantineEnabled from your Info.plist — Safari sets exactly this (verified on the host), and CoreTypes.bundle/Exceptions.plist force-enables it for other browsers by bundle ID. Set LSFileQuarantineEnabled=true and files Pane creates get quarantined automatically, with agent name/bundle ID/timestamp filled in by the system. Separately, App Sandbox quarantines files a sandboxed app writes (except into security-scoped-bookmark locations), which means without care you can end up quarantining every file Pane touches, not just downloads. Manual setting is still needed to attach kLSQuarantineOriginURLKey and kLSQuarantineDataURLKey — the provenance Safari shows in its 'downloaded from' warning — and that is the real reason to write the dictionary yourself.

**Source:** https://developer.apple.com/documentation/bundleresources/information-property-list/lsfilequarantineenabled


### (MAJOR) Find-in-page via WKWebView.find(_:configuration:) gives you what you need for a Safari-style find bar.

**Spec said:** Find-in-page via WKWebView.find(_:configuration:) gives you what you need for a Safari-style find bar.

**Reality:** WKFindResult exposes exactly one property, matchFound: Bool. There is no total match count and no current-match index, so the '3 of 17' counter every shipping browser has is impossible with public API. Options: (a) SPI _countStringMatches:options:maxCount: + _WKFindDelegate; (b) drive AppKit's NSTextFinder against WKWebView's NSTextFinderClient conformance (macOS 10.15.4+), which gives the native find bar for free but has known WebKit bugs around highlight/hole positioning vs scroll offset (bug 191702); (c) inject JS that walks the DOM and counts. Also note isFindInteractionEnabled/findInteraction are iOS 16-only and are not an option here.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKFindResult.h


### (MAJOR) runOpenPanelWith gives you the file-type filter from the page's <input accept=...>.

**Spec said:** runOpenPanelWith gives you the file-type filter from the page's <input accept=...>.

**Reality:** Public WKOpenPanelParameters has only allowsMultipleSelection and allowsDirectories. The accept list is SPI-only (_acceptedMIMETypes, _acceptedFileExtensions, _allowedFileExtensions). Without SPI, Pane's NSOpenPanel cannot set allowedContentTypes to match the page and will show all files — a visible fidelity gap vs Safari/Chrome. Directory upload does work: check allowsDirectories, set panel.canChooseDirectories, and return the directory URL; WebKit enumerates it. Also note the completion handler must be called exactly once — calling it twice or never wedges the page's file input permanently.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKOpenPanelParameters.h


### (MINOR) Use the WKDownload placeholder API so downloads show up in the Downloads folder while in flight.

**Spec said:** Use the WKDownload placeholder API so downloads show up in the Downloads folder while in flight.

**Reality:** The entire placeholder family (WKDownloadPlaceholderPolicy, decidePlaceholderPolicy, didReceivePlaceholderURL, didReceiveFinalURL) is API_AVAILABLE(ios(18.2), visionos(2.2)) — no macOS availability at all. On macOS you get none of it; write to a .download temp path yourself and move into place on downloadDidFinish, and publish an NSProgress with the file URL if you want Finder/Dock integration.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKDownloadDelegate.h


### (MINOR) Handle webViewWebContentProcessDidTerminate and branch on why the process died to decide whether to reload.

**Spec said:** Handle webViewWebContentProcessDidTerminate and branch on why the process died to decide whether to reload.

**Reality:** The public callback carries no reason — it is just webViewWebContentProcessDidTerminate(_ webView: WKWebView). The reason (_WKProcessTerminationReason: ExceededMemoryLimit, ExceededCPULimit, RequestedByClient, Crash, ExceededSharedProcessCrashLimit) is SPI on WKNavigationDelegatePrivate. With public API only, you cannot distinguish a jetsam from a real crash, so crash-loop protection must be heuristic: track terminations per tab in a sliding window, auto-reload at most ~2 times within ~60s, then show a static 'this page keeps crashing' interstitial instead of reloading. Note webView.url is typically still populated after termination, which is what you reload.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKNavigationDelegatePrivate.h


### (MINOR) Returning .useCredential(URLCredential(trust:)) persists the certificate exception so WebKit accepts it on retry.

**Spec said:** Returning .useCredential(URLCredential(trust:)) persists the certificate exception so WebKit accepts it on retry.

**Reality:** It works, but nothing persists. The credential applies to that one challenge. WebKit re-challenges on subsequent sessions, and the SecTrust object you get each time is a fresh one — the exception blob from SecTrustCopyExceptions is tied to that specific SecTrust, not to a host. Pane must own the persistence: keep a dictionary keyed by host (ideally host + leaf cert SHA-256, so the exception dies if the cert rotates), store the CFData from SecTrustCopyExceptions, and on every future challenge for that host call SecTrustSetExceptions(trust, storedData) before handing back URLCredential(trust:). Scope that dictionary per profile and never persist it across launches for a non-explicit user decision.

**Source:** https://bugs.webkit.org/show_bug.cgi?id=140197


## Recommended approach

Downloads. One `@MainActor final class DownloadCoordinator: NSObject, WKDownloadDelegate` per profile — every WebKit protocol is `NS_SWIFT_UI_ACTOR`, so under Swift 6 don't fight it, keep the delegates main-actor and hop off for disk work. Wire all three entry points: `.download` from `decidePolicyFor navigationAction`/`navigationResponse` → `webView(_:navigationResponse:didBecomeDownload:)`, plus `startDownload(using:)` for "Save link as". Set `download.delegate` immediately. In `decideDestinationUsing:suggestedFilename:` sanitize the filename (strip `/`, leading `.`, uniquify), return a non-existent path in an existing writable dir. Keep `download.progress` (NSProgressReporting) per row. Persist `resumeData` from both `didFailWithError:resumeData:` and `cancel(_:)`; resume via `webView.resumeDownload(fromResumeData:)`. Skip the placeholder API — iOS-only.

Quarantine. Set `LSFileQuarantineEnabled = true` in Info.plist, then additionally write provenance in `downloadDidFinish` via `NSURLQuarantinePropertiesKey`: merge into the existing dict, setting `kLSQuarantineTypeKey = kLSQuarantineTypeWebDownload`, `kLSQuarantineDataURLKey` = final URL, `kLSQuarantineOriginURLKey` = referring page. Never `NSNull` it out.

Auth. Implement `didReceive challenge` on both the navigation delegate and `WKDownloadDelegate` (defaults are `RejectProtectionSpace` = silent failure). Branch on `challenge.protectionSpace.authenticationMethod`. Drop the per-profile `URLCredentialStorage` plan: use `WKWebsiteDataStore(forIdentifier:)` and WebKit isolates credentials itself.

Cert errors. On `NSURLAuthenticationMethodServerTrust`, call `SecTrustEvaluateWithError(trust, &err)`; on failure read the CFError's `localizedDescription` plus `SecTrustCopyResult`/`kSecTrustResultDetails` for the specific reason, `.cancelAuthenticationChallenge`, then `loadHTMLString` an interstitial with the failing origin as `baseURL`. On user override: `SecTrustCopyExceptions` → store keyed by host+leaf-cert-hash → `.useCredential(URLCredential(trust:))`, and re-apply `SecTrustSetExceptions` on every later challenge.

Find. `NSTextFinder` with the WKWebView as `NSTextFinderClient` for the native bar; drive `find(_:configuration:)` with `WKFindConfiguration(backwards:caseSensitive:wraps:)` for next/prev. Accept no match count or inject counting JS.

Context menus. Subclass WKWebView, override `willOpenMenu(_:with:)`, and capture the hit-test target beforehand with a `contextmenu` WKUserScript posting to a `WKScriptMessageHandler`.

Crash. `webViewWebContentProcessDidTerminate` → sliding-window reload limiter, then a static interstitial.


## Effort estimate

Roughly 18-26 solo dev-days for a credible v1 of this whole floor. Breakdown: downloads incl. resume, persistence, and a downloads panel 5-7d; quarantine + provenance 0.5d (trivial once you know it is an Info.plist flag); upload open panel 1-2d (2d if you take the SPI route for accept= and need a public fallback); auth challenges incl. HTTP Basic/Digest sheet, client-cert picker, and proxy auth 3-4d; cert interstitial with real failure-reason extraction, per-host exception store, and cert-detail viewer 4-5d; find-in-page 3-4d (NSTextFinder integration is fiddly and has known WebKit highlight/scroll-offset bugs); context menus 3-4d, dominated entirely by the fact that the documented iOS path does not exist and you must rebuild hit-testing via injected JS; crash recovery 1-2d. Cost is dominated by three things, none of which are the "happy path" API calls: (1) reimplementing context-menu hit-testing that WebKit gives iOS for free, (2) certificate exception persistence and the interstitial UX, which is security-sensitive and where the public API deliberately gives you nothing durable, and (3) Swift 6 main-actor plumbing across delegate callbacks that must reach a background download store. Add 3-5d if you decide to take on WebKit SPI (accept= filters, match counts, termination reason) — the code is short but you inherit a compatibility burden every macOS release and lose Mac App Store distribution.


## Open questions

- Mac App Store or Developer ID? This decides everything about SPI. Three of the gaps (upload accept= filters, find match counts, process-termination reason) have short SPI fixes that are fine for Developer ID and instant rejection for MAS. Decide before writing any of this code.
- Does Pane ship sandboxed? If yes, App Sandbox quarantines essentially every file Pane writes, not just downloads — verify empirically what a plain 'Save Page As' produces, and check whether you need security-scoped bookmarks for the downloads directory to avoid over-quarantining. Safari carries a private com.apple.private.app-sandbox.unquarantine entitlement that you cannot get.
- Confirm on-device whether WebKit re-issues a server-trust challenge for a host already accepted earlier in the same session, or caches it in the network process. This determines whether the per-host exception store is a correctness requirement or only a cross-launch convenience. Test with a self-signed host, accept, then navigate away and back.
- Verify that WKWebsiteDataStore(forIdentifier:) actually isolates HTTP auth credentials end-to-end on macOS 26 — the code path is real in NetworkSessionCocoa.mm but gated on CFNETWORK_SEPARATE_CREDENTIAL_STORAGE, which may not be enabled in the shipping build. Test: authenticate to an httpbin basic-auth endpoint in profile A, confirm profile B re-prompts.
- Does NSTextFinder against WKWebView still exhibit WebKit bug 191702 (highlight and hole positions ignoring scroll offset and insets) on macOS 26? If so, the native find bar may look broken in Pane's inset/rounded pane layout and you fall back to a custom bar plus injected JS highlighting.
- How should client-certificate auth (NSURLAuthenticationMethodClientCertificate) behave per profile? Identities live in the keychain, not in the website data store, so per-profile isolation of client certs is almost certainly NOT automatic and needs an explicit design.
- What is the intended behavior for downloads when the originating profile's data store is deleted mid-download via removeDataStore(forIdentifier:)? Untested territory and a likely crash source.
- Worth evaluating the new macOS 26 WKWebsiteDataStore.fetchData(of:)/restoreData(_:) for profile backup and crash-state recovery — it is brand new, undocumented in depth, and may cover more of session restore than expected.
