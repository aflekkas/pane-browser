# Research — drm-entitlement

**Date:** 2026-08-07  
**Host:** macOS 26.5.2 (build 25F84), Apple Silicon, Swift 6.3.3, SDK MacOSX26.5  
**Target:** macOS 14+ deployment

**Area:** DRM playback (FairPlay/EME) and the browser entitlement on macOS 26

**Verdict:** `works-with-caveats` → **adversarially corrected to `partially-blocked`** (researcher upheld: `False`)


> Claims are tagged HARD FACT (fetched from a primary source) or INFERENCE.
> Findings are preserved as reported. Where a verifier disagreed, BOTH are kept —
> the disagreement is the information.


---

## Hard facts

- `com.apple.developer.web-browser` is available on iOS 14.0 and iPadOS 14.0 ONLY. macOS is not in the platform list. There is no macOS variant of this entitlement.
  - min OS: `iOS 14.0 / iPadOS 14.0 (macOS: n/a)`
  - https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.developer.web-browser.json
- What the iOS entitlement grants: eligibility to be set as default browser; load pages from all domains with full script access (bypasses App-Bound Domains); Service Workers in WKWebView; 'Add to Home Screen' via UIActivityViewController. It grants NOTHING media/DRM-related. Requested via a form; it also forbids certain Info.plist usage-description keys (NSPhotoLibraryUsageDescription, NSLocationAlways*, NSHomeKit*, NSBluetoothAlways*, NSHealth*) and disables Universal Link claims.
  - min OS: `iOS 14.0`
  - https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser
- The EU alternative-browser-engine rules use a DIFFERENT entitlement family entirely: com.apple.developer.web-browser-engine.{host,networking,rendering,webcontent}, com.apple.developer.embedded-web-browser-engine(.engine-association), plus BrowserEngineKit. WebKit's own source checks these separately from com.apple.developer.web-browser.
  - min OS: `iOS 17.4 (EU only)`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/Shared/Cocoa/DefaultWebBrowserChecks.mm
- DECISIVE: On macOS, WebKit does NOT use any entitlement to decide whether the host app is a 'full web browser'. `isFullWebBrowserOrRunningTest()` under `#elif PLATFORM(MAC)` calls `[NSWorkspace URLsForApplicationsToOpenURL:]` for `http:` and `https:` and returns true iff the app's own bundleURL is in BOTH lists. Registering http+https in CFBundleURLTypes is literally the whole gate.
  - min OS: `n/a (all macOS)`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/Shared/Cocoa/DefaultWebBrowserChecks.mm
- `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:completion:)` is macOS 12.0+, not 14+. Async variant `setDefaultApplication(at:toOpenURLsWithScheme:) async throws` exists. Docs: 'If a change requires user consent, the system asks for consent asynchronously before invoking the completion handler.' No entitlement mentioned.
  - min OS: `macOS 12.0`
  - https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopenurlswithscheme:completion:)
- The macOS browser entitlement that DOES exist is `com.apple.developer.web-browser.public-key-credential` (macOS 13.3+, Mac Catalyst 16.3+): 'lets your app make registration and assertion requests for passkeys and security keys for any relying party identifier.' Requires Account Holder role and an approval form; criteria include declaring HTTP+HTTPS schemes in Info.plist and presenting a URL field / search / bookmarks on launch.
  - min OS: `macOS 13.3`
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential
- Without that entitlement, a WKWebView-based app can only use passkeys for RP IDs it has declared via Associated Domains (`webcredentials`). Arbitrary-site passkey sign-in fails.
  - min OS: `macOS 13.3`
  - https://passkeys.dev/docs/reference/macos/
- EME is ON by default in WKWebView. `EncryptedMediaAPIEnabled`: WebKit default `true` (false only for GTK/WPE); WebKitLegacy false. `LegacyEncryptedMediaAPIEnabled` (WebKitMediaKeys): default true everywhere. `MediaCapabilitiesEnabled` and `MediaCapabilitiesExtensionsEnabled`: WebKit default true. `MediaSourceEnabled`: true on non-iOS.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml
- `NeedsSiteSpecificQuirks` defaults to **true** in WebKit (WKWebView), false in WebKitLegacy/WebCore. So the Netflix/Hulu/Disney+/HBO Max site quirks in WebCore/page/Quirks.cpp DO apply in a third-party WKWebView — this is not a hidden Safari-only advantage.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml
- Key system string: `CDMFactoryFairPlayStreaming::supportsKeySystem()` returns `keySystem == "com.apple.fps" || keySystem.startsWith("com.apple.fps.")`. Both `com.apple.fps` and `com.apple.fps.1_0` are accepted; it is a prefix match, not an exact-string whitelist.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/graphics/avfoundation/CDMFairPlayStreaming.cpp
- WebKit's GPU process sandbox profile contains unconditional allowances explicitly commented ';; Needed to support encrypted media playback <rdar://problem/40038478>' and ';; These are needed for Encrypted Media on some hardware'. There is no host-app entitlement predicate on any of it. The GPU/WebContent helper processes are Apple-signed and ship inside WebKit.framework.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/GPUProcess/mac/com.apple.WebKit.GPUProcess.sb.in
- macOS UA construction: `standardUserAgentWithApplicationName()` returns exactly `"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"` plus `' ' + applicationName`. The OS token is hardcoded to 10_15_7 — the real macOS version is never in the UA.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/mac/UserAgentMac.mm
- `defaultApplicationNameForUserAgent()` returns `@"Mobile/15E148"` on iOS and **nil on macOS**. So a stock macOS WKWebView sends a UA with NO `Version/` and NO `Safari/` token at all.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewConfiguration.mm
- `WebPageProxy::setCustomUserAgent()` fully overrides; `setApplicationNameForUserAgent()` early-returns and does nothing while `m_customUserAgent` is non-empty. Clearing customUserAgent to empty restores `standardUserAgent(m_applicationNameForUserAgent)`. Custom UA is tagged `IsCustomUserAgent::Yes` internally.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/WebPageProxy.cpp
- Safari 26 on macOS 26 sends `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15`. Setting applicationNameForUserAgent = "Version/26.0 Safari/605.1.15" produces a byte-identical string.
  - min OS: `macOS 26`
  - https://nielsleenheer.com/articles/2025/the-user-agent-string-of-safari-on-ios-26-and-macos-26/
- Netflix's supported-browser matrix for macOS lists ONLY: Safari 14+ (up to 2160p), Chrome 117+ (1080p), Edge 118+ (720p), Firefox 111+ (1080p), Opera 92+ (1080p). Non-Safari WebKit browsers are not listed — access is gated on presenting as one of these.
  - min OS: `n/a`
  - https://help.netflix.com/en/node/23742
- Google's OAuth policy explicitly names `WKWebView` on iOS/macOS as a non-compliant embedded webview; violations get a `disallowed_useragent` error. You can test your build by appending `disallow_webview=true` to the OAuth 2.0 authorization endpoint URI.
  - min OS: `n/a`
  - https://developers.googleblog.com/upcoming-security-changes-to-googles-oauth-20-authorization-endpoint-in-embedded-webviews/
- There is a real, filed instance of this hitting a shipping WebKit browser: 'Google Sheets blocks login: This browser or app may not be secure' on Kagi's Orion issue tracker.
  - min OS: `n/a`
  - https://orionfeedback.org/d/7103-google-sheets-blocks-login-this-browser-or-app-may-not-be-secure
- WebKit implements no UA Client Hints at all — grep of UnifiedWebPreferences.yaml for 'clienthint' returns zero matches. Sec-CH-UA-based blocking therefore cannot fingerprint Pane; sites must fall back to the UA string.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml
- MediaKeys persistent storage has a working per-app default: `WebsiteDataStore::defaultMediaKeysStorageDirectory()` / `defaultMediaKeysHashSaltsStorageDirectory()` resolve under the app's own WebKit data directory. No configuration needed for a persistent data store.
  - min OS: `n/a`
  - https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm

## Corrections to the spec


### (FATAL) Pane needs (or should investigate obtaining) the `com.apple.developer.web-browser` entitlement.

**Spec said:** Pane needs (or should investigate obtaining) the `com.apple.developer.web-browser` entitlement.

**Reality:** That entitlement does not exist on macOS. Apple's own metadata lists only iOS 14.0 and iPadOS 14.0. Requesting it for a Mac app is a dead end — there is nothing to request. Budget zero time for it.

**Source:** https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.developer.web-browser.json


### (MAJOR) The web-browser entitlement is tied to the EU alternative-browser-engine rules.

**Spec said:** The web-browser entitlement is tied to the EU alternative-browser-engine rules.

**Reality:** Wrong entitlement family. `com.apple.developer.web-browser` predates the DMA by four years (iOS 14, 2020) and only concerns default-browser eligibility. The EU alternative-engine regime is `com.apple.developer.web-browser-engine.*` + `com.apple.developer.embedded-web-browser-engine` + BrowserEngineKit, is iOS-only, EU-only, and is irrelevant to Pane since Pane uses system WebKit rather than shipping its own engine.

**Source:** https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.embedded-web-browser-engine


### (MAJOR) An entitlement may be needed to get FairPlay/EME in a third-party WKWebView.

**Spec said:** An entitlement may be needed to get FairPlay/EME in a third-party WKWebView.

**Reality:** No entitlement gates DRM. EncryptedMediaAPIEnabled and LegacyEncryptedMediaAPIEnabled both default to true for WebKit (WKWebView), and the encrypted-media allowances in the GPU process sandbox profile are unconditional. The CDM runs in Apple-signed helper processes inside WebKit.framework, so it carries its own privileges regardless of the host app. FairPlay is available to Pane out of the box.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/GPUProcess/mac/com.apple.WebKit.GPUProcess.sb.in


### (MINOR) Use `LSSetDefaultHandlerForURLScheme` / `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` on macOS 14+.

**Spec said:** Use `LSSetDefaultHandlerForURLScheme` / `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` on macOS 14+.

**Reality:** `LSSetDefaultHandlerForURLScheme` is long-deprecated private-ish LaunchServices API — do not ship it. The NSWorkspace replacement is macOS **12.0**+, not 14+, so it is unconditionally available on a macOS 26 target with no availability guard. It triggers a system consent prompt.

**Source:** https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopenurlswithscheme:completion:)


### (MINOR) `navigator.requestMediaKeySystemAccess('com.apple.fps.1_0')` vs `'com.apple.fps'` — pick the correct one.

**Spec said:** `navigator.requestMediaKeySystemAccess('com.apple.fps.1_0')` vs `'com.apple.fps'` — pick the correct one.

**Reality:** It is not either/or. WebKit prefix-matches: `keySystem == "com.apple.fps" || keySystem.startsWith("com.apple.fps.")`. Both are accepted, as is `com.apple.fps.2_0`/`3_0`. The real split is by API, not by string: modern EME (`requestMediaKeySystemAccess`) conventionally uses `com.apple.fps`; the legacy `WebKitMediaKeys` path uses `com.apple.fps.1_0`. Pane does not choose this — the site's player does. Pane's job is only to leave both API surfaces enabled.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/graphics/avfoundation/CDMFairPlayStreaming.cpp


### (MAJOR) Register as default browser via Info.plist CFBundleURLTypes for http/https — presumably a formality.

**Spec said:** Register as default browser via Info.plist CFBundleURLTypes for http/https — presumably a formality.

**Reality:** It is far more load-bearing than a formality. WebKit's `isFullWebBrowserOrRunningTest()` on macOS decides browser status by asking NSWorkspace whether Pane's bundle is a registered handler for BOTH `http:` and `https:`. Miss either scheme and WebKit silently treats Pane as a non-browser embedder, changing defaults for iframe resource monitoring, the non-standard search-input `results` attribute, and ITP/TCC tracking-prevention behavior.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/Shared/Cocoa/DefaultWebBrowserChecks.mm


### (MAJOR) Widevine on macOS WebKit: confirm dead.

**Spec said:** Widevine on macOS WebKit: confirm dead.

**Reality:** Confirmed dead, but the consequence is milder than 'those services are unplayable'. Netflix, Disney+, HBO Max, Hulu and Prime Video all ship FairPlay for the Safari/WebKit path — WebCore/page/Quirks.cpp carries active, recently-dated rdar-referenced quirks for netflix.com, disneyplus, hulu.com and hbomax.com, which is direct evidence Apple actively maintains those services against WebKit. The blocker is UA-based service gating, not the absence of Widevine.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/page/Quirks.cpp


### (MAJOR) Spoofing Safari's UA might break Google login ('unsupported browser').

**Spec said:** Spoofing Safari's UA might break Google login ('unsupported browser').

**Reality:** Backwards. The stock WKWebView UA on macOS has no `Version/` or `Safari/` token at all (applicationNameForUserAgent defaults to nil on macOS) — that bare string is exactly the embedded-webview signature Google blocks with `disallowed_useragent`. Spoofing Safari is the *fix*, not the risk. Not spoofing is the risk.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewConfiguration.mm


## Recommended approach

Do not chase any entitlement for DRM or default-browser status on macOS. Both are free.

**Default browser.** In Info.plist, declare `CFBundleURLTypes` with one entry whose `CFBundleURLSchemes` contains BOTH `http` and `https`, `CFBundleTypeRole = Viewer`. This is not cosmetic — WebKit's `isFullWebBrowserOrRunningTest()` on macOS resolves browser status by checking `[NSWorkspace URLsForApplicationsToOpenURL:]` for both schemes against your own `[NSBundle mainBundle].bundleURL`. To prompt the user, call `try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https")` (macOS 12+; do it for both schemes). Handle incoming URLs via `NSApplicationDelegate.application(_:open:)`.

**FairPlay.** Nothing to do. `EncryptedMediaAPIEnabled` and `LegacyEncryptedMediaAPIEnabled` both default true in WKWebView; the GPU-process sandbox carries unconditional encrypted-media allowances. Use a **persistent** `WKWebsiteDataStore.default()` for normal tabs so `defaultMediaKeysStorageDirectory()` resolves — `.nonPersistent()` will break persistent licenses, so expect DRM failures in private windows and message that honestly. Do not add app-level certificate pinning to `WKNavigationDelegate`'s auth challenge handler; it breaks the FairPlay application-certificate fetch. Never touch the key-system string — the site's player picks `com.apple.fps` (modern EME) or `com.apple.fps.1_0` (legacy `WebKitMediaKeys`); WebKit prefix-matches `com.apple.fps.` and accepts both.

**User agent.** Set `WKWebViewConfiguration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"` and leave `WKWebView.customUserAgent` nil. WebKit composes `"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)" + " " + applicationName`, yielding a byte-identical Safari 26 string. Prefer this over `customUserAgent`, which hard-overrides and makes `setApplicationNameForUserAgent` a silent no-op. Reserve `customUserAgent` for a per-tab "request desktop/Chrome UA" override, and read the Safari version from `WebKit.framework`'s `CFBundleShortVersionString` rather than hardcoding, so Pane tracks OS updates.

Verify with `https://accounts.google.com/o/oauth2/v2/auth?...&disallow_webview=true` — Google's own documented self-test. Then manually smoke-test netflix.com, tv.apple.com, disneyplus.com, max.com.


## Effort estimate

2-4 dev days of actual code — the DRM and entitlement work is near-zero (three Info.plist lines, one `applicationNameForUserAgent` assignment, one `setDefaultApplication` call). Cost is dominated by empirical verification, not implementation: manually exercising Netflix / Disney+ / HBO Max / Prime Video / Apple TV+ playback with a paid account on each, plus Google/Microsoft OAuth flows, is 1-2 days and cannot be automated (DRM refuses to run under most CI/VM environments). Add 3-5 days if you discover a service fingerprints beyond the UA and you have to build per-site UA overrides plus a user-visible fallback. Separately, budget calendar time (not dev days) for the `com.apple.developer.web-browser.public-key-credential` passkey request — it needs the Account Holder role and Apple review, so start it in week one even though no code depends on it.


## Open questions

- Does Netflix actually serve a WKWebView app presenting a byte-identical Safari 26 UA? Netflix issues a per-client ESN and may fingerprint beyond the UA. Unverified empirically — this is the single highest-value test to run first, and the only finding here I could not confirm from a primary source.
- Does Netflix's 4K/2160p tier (Safari-only on macOS) require something a third-party WKWebView cannot supply — a hardware-secured HDCP path or a Safari-specific attestation — or does Pane just silently cap at 1080p? Degradation mode matters for user expectations.
- Will Apple actually grant `com.apple.developer.web-browser.public-key-credential` to a solo/indie developer? Apple 'reviews each application using predefined criteria' and it requires the Account Holder role on an *organization* account. If Pane ships under an individual account, this may be unobtainable, which would kill passkey sign-in on all non-associated domains.
- Does tv.apple.com gate its own web player on Safari, and does it use FairPlay or Widevine for the WebKit path? Apple's support page says 'any web browser, such as Chrome or Firefox' but does not enumerate a supported matrix.
- Do Netflix/Disney+ EME flows behave differently when WebKit's `IsCustomUserAgent::Yes` flag is set (via `customUserAgent`) versus the `applicationNameForUserAgent` path? Worth confirming the recommendation to prefer the latter is not merely stylistic.
- Is Google's embedded-webview detection purely UA-based, or does it use additional signals (window.chrome absence, WebGL/Canvas fingerprints, TLS JA3)? Google documents only the `disallow_webview=true` self-test and never states the mechanism.
- macOS 26 introduces `EnhancedSecurityHeuristicsEnabled` / `EnhancedSecurityForceDisabled` preferences in WebKit — unexamined whether Enhanced Security mode interacts with EME/media decode in a third-party WKWebView.


---

## Adversarial verification

A second agent was instructed to **refute** the above, defaulting to 'refuted' absent primary-source confirmation.

**Upheld:** `False` · **Corrected verdict:** `partially-blocked`


### APIs cited that could NOT be found in any documentation

- disallow_webview=true (claimed as 'Google's own documented self-test' URL parameter - zero occurrences across developers.google.com/identity/protocols/oauth2/{native-app,policies,web-server}; the documented parameter is suppress_webview_warning=true and the documented error is disallowed_useragent)
- com.apple.developer.web-browser on macOS (correctly identified by the researcher as nonexistent - confirmed: Apple's metadata lists only iOS 14.0 and iPadOS 14.0, and 'Preparing your app to be the default browser' never mentions macOS)

### APIs confirmed to exist

- `com.apple.developer.web-browser (entitlement; iOS 14.0 / iPadOS 14.0 only - macOS absent, researcher correct)`
- `com.apple.developer.web-browser.public-key-credential (entitlement; macOS 13.3+, Mac Catalyst 16.3+ - managed capability, Apple-reviewed, org account required)`
- `com.apple.developer.web-browser-engine.rendering / .networking / .webcontent (entitlements; iOS 17.4 / iPadOS 17.4 only)`
- `com.apple.developer.embedded-web-browser-engine (entitlement; iOS 17.4 / iPadOS 17.4 only)`
- `BrowserEngineKit (framework; iOS 17.4, iPadOS 18.0 only - no macOS)`
- `ASAuthorizationWebBrowserPublicKeyCredentialManager (AuthenticationServices; macOS 13.3+, iOS 17.4+, Mac Catalyst 16.4+)`
- `WebKit::isFullWebBrowserOrRunningTest(const String&) - Source/WebKit/Shared/Cocoa/DefaultWebBrowserChecks.mm:272, macOS branch exactly as described`
- `WebKit::isParentProcessAFullWebBrowser(AuxiliaryProcess&) - same file:242, entitlement-only, no macOS branch`
- `WebKit::shouldEvaluateJavaScriptWithoutTransientActivation() - same file:298`
- `-[NSWorkspace URLsForApplicationsToOpenURL:] - API_AVAILABLE(macos(12.0)), AppKit NSWorkspace.h:123`
- `-[NSWorkspace setDefaultApplicationAtURL:toOpenURLsWithScheme:completionHandler:] - API_AVAILABLE(macos(12.0)), NSWorkspace.h:129 (Swift: setDefaultApplication(at:toOpenURLsWithScheme:))`
- `WKWebViewConfiguration.applicationNameForUserAgent - API_AVAILABLE(macos(10.11), ios(9.0)), WKWebViewConfiguration.h:136`
- `WKWebView.customUserAgent - API_AVAILABLE(macos(10.11), ios(9.0)), WKWebView.h:458`
- `WebCore::standardUserAgentWithApplicationName - Source/WebCore/platform/mac/UserAgentMac.mm, returns "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)" + " " + appName`
- `EncryptedMediaAPIEnabled - UnifiedWebPreferences.yaml:2951, WebKit default: true (false only on GTK/WPE), condition ENABLE(ENCRYPTED_MEDIA)`
- `LegacyEncryptedMediaAPIEnabled - UnifiedWebPreferences.yaml:5032, default true for WebKit/WebKitLegacy/WebCore`
- `WebsiteDataStore::defaultMediaKeysStorageDirectory(const String&) - WebsiteDataStore.cpp:2450 (internal C++, not public API)`
- `CDMPrivateFairPlayStreaming::supportsSessionTypeWithConfiguration - CDMFairPlayStreaming.cpp:391`
- `Quirks.cpp active site quirks: netflix (rdar://155498882, rdar://178545839), disneyplus (rdar://137613110, rdar://151715964), hulu (rdar://126096361), hbomax (rdar://138424489, rdar://158430821), Prime Video (rdar://128962002)`
- `Google OAuth error code disallowed_useragent - documented, explicitly names WKWebView on macOS`

### Refutations


**Claim:** 'com.apple.developer.web-browser' does not exist on macOS ... Requesting it for a Mac app is a dead end - there is nothing to request. Budget zero time for it.' (rated fatal)

**Why it is wrong:** HARD FACT. The exact string 'com.apple.developer.web-browser' is indeed iOS/iPadOS 14.0 only - but the researcher generalised that into 'there is no macOS browser entitlement, budget zero time', which is false. 'com.apple.developer.web-browser.public-key-credential' is documented with platforms macOS 13.3+ and Mac Catalyst 16.3+ (no iOS entry on the macOS variant page), and Apple's own discussion text reads verbatim: 'Only add this entitlement if your app can act as a user's web browser. To request this entitlement, you must hold the Account Holder role for an organization's Apple Developer account and complete the request form at [macOS Browsers Passkeys]. Apple reviews each application using predefined criteria... Apple adds the entitlement to your developer account using managed capabilities.' Apple then lists browser criteria that are the macOS analogue of the iOS default-browser review: 'Your app needs to specify the HTTP and HTTPS schemes in its [Info.plist] file. On launch, the app needs to provide a text field for entering a URL, search tools for finding relevant links on the internet, or curated lists of bookmarks...' I independently confirmed the request form is real and gated: https://developer.apple.com/contact/request/macos-browsers-passkeys/ returns HTTP 302 to idmsa.apple.com sign-in. I also confirmed the literal string 'com.apple.developer.web-browser.public-key-credential' is present in the macOS 26.5.2 dyld shared cache on this host (grep -a hit in /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e.05), i.e. a shipping system framework reads it. WebKit's own WebAuthn path routes through ASCWebKitSPISupport's 'getCanCurrentProcessAccessPasskeysForRelyingParty:' and ASAuthorizationWebBrowserPublicKeyCredentialManager (macOS 13.3+), a per-process capability check (Source/WebKit/UIProcess/WebAuthentication/Cocoa/WebAuthenticatorCoordinatorProxy.mm lines ~1283-1360). CONSEQUENCE: without this entitlement Pane has no passkey/WebAuthn support for arbitrary relying parties - Apple's 'Supporting passkeys' doc says WKWebView passkeys otherwise require the RP ID to be declared as an associated domain, which a general browser cannot do. And it is unobtainable by an individual developer account (Account Holder of an *organization* required). That is a real, weeks-long, possibly-refused gate on a headline browser feature. 'Budget zero time' is the single most damaging line in their report.

**Source:** https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential.json


**Claim:** 'Miss either scheme and WebKit silently treats Pane as a non-browser embedder, changing defaults for ... ITP/TCC tracking-prevention behavior.'

**Why it is wrong:** HARD FACT, refuted for macOS. determineTrackingPreventionStateInternal() reads verbatim: '#if ENABLE(APP_BOUND_DOMAINS) / bool isFullWebBrowser = isFullWebBrowserOrRunningTest(bundleIdentifier); / #else / bool isFullWebBrowser = isRunningTest(bundleIdentifier); / #endif'. ENABLE_APP_BOUND_DOMAINS is defined only under '#if !defined(ENABLE_APP_BOUND_DOMAINS) && PLATFORM(IOS_FAMILY)' (Source/WTF/wtf/PlatformEnableCocoa.h), so on macOS this branch collapses to isRunningTest(), which is false for Pane no matter how it registers http/https. macOS ITP/TCC state is therefore driven by linkedOnOrAfter + the presence of 'NSCrossWebsiteTrackingUsageDescription' in Info.plist, NOT by the NSWorkspace browser check. They also missed two things worth knowing: (a) shouldEvaluateJavaScriptWithoutTransientActivation() DOES consult isFullWebBrowserOrRunningTest() on macOS - a real consequence they omitted; (b) isParentProcessAFullWebBrowser() (used inside WebContent/GPU/Networking) has no PLATFORM(MAC) branch at all - it calls WTF::hasEntitlement(auditToken, "com.apple.developer.web-browser") unconditionally, so inside Pane's child processes browser status is permanently false on macOS regardless of URL registration. The two 'is this a browser' checks disagree on macOS; the researcher presented one unified story.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/Shared/Cocoa/DefaultWebBrowserChecks.mm


**Claim:** 'read the Safari version from WebKit.framework's CFBundleShortVersionString rather than hardcoding, so Pane tracks OS updates.'

**Why it is wrong:** HARD FACT, measured on this host (macOS 26.5.2, build 25F84). WebKit.framework's Info.plist has CFBundleShortVersionString = "21624" and CFBundleVersion = "21624.2.5.11.8". Following their instruction literally produces the UA suffix 'Version/21624 Safari/605.1.15' - a nonsense string that is neither Safari's marketing version nor the AppleWebKit token. Safari's actual version lives in /Applications/Safari.app/Contents/Info.plist (CFBundleShortVersionString = "26.5.2" here; note Safari's CFBundleVersion is 21624.2.5.11.8, the same WebKit build number - which is probably where the confusion came from). The obvious repair (read Safari.app's Info.plist) is itself blocked for a sandboxed / Mac App Store build, since App Sandbox denies reads outside the container. So this recommendation is wrong and its natural fix is also unavailable. Related: their literal 'Version/26.0' is not byte-identical to this machine's Safari either (26.5.2). INFERENCE (weak sourcing - the only UA reference I could reach, whatismybrowser.com, is user-submitted and even contradicts WebKit source on the OS token, claiming '15_7_9' where UserAgentMac.mm hardcodes '10_15_7'): treat the Version token as something to determine empirically against a real Safari on the target OS, not something to derive from a framework bundle.

**Source:** file:///System/Library/Frameworks/WebKit.framework/Resources/Info.plist


**Claim:** 'Verify with https://accounts.google.com/o/oauth2/v2/auth?...&disallow_webview=true - Google's own documented self-test.'

**Why it is wrong:** HARD FACT. I fetched Google's three relevant OAuth pages (identity/protocols/oauth2/native-app, .../policies, .../web-server) and grepped the rendered HTML: 'disallow_webview' appears zero times on all three. What IS documented is the error code 'disallowed_useragent' (2 hits on native-app and web-server) and, in the 2016 announcement, a different parameter 'suppress_webview_warning=true'. So the researcher asserted a Google-documented test parameter that I cannot find documented anywhere; treat it as fabricated until someone produces a URL. Separately, their framing 'Spoofing Safari is the *fix*' is INFERENCE contradicted by Google's own stated remedy. Google's verbatim text: 'disallowed_useragent - The authorization endpoint is displayed inside an embedded user-agent disallowed by Google's OAuth 2.0 Policies. iOS and macOS developers may encounter this error when opening authorization requests in WKWebView. Developers should instead use iOS libraries such as Google Sign-In for iOS or OpenID Foundation's AppAuth for iOS... Developers should allow general links to open in the default link handler of the operating system.' Note this confirms their diagnosis (WKWebView on macOS does hit disallowed_useragent - upheld) but the remedy Google publishes is 'don't use an embedded webview', not 'change the UA string'. Google's policy bans embedded user agents as a category; a UA spoof is an undocumented workaround against a policy that is not defined in terms of the UA string, and can be tightened at any time. This should be logged as a live risk, not as a solved problem.

**Source:** https://developers.google.com/identity/protocols/oauth2/native-app


**Claim:** 'the encrypted-media allowances in the GPU process sandbox profile are unconditional.'

**Why it is wrong:** HARD FACT, unsupported citation + platform confusion. WebKit's repo has exactly one sandbox-profile directory: Source/WebKit/Resources/SandboxProfiles/**ios** (confirmed via GitHub contents API - the only child is 'ios'). There is no macOS GPU profile in the tree to have read. And the iOS GPU profile they must have been looking at (321 lines) contains zero occurrences of 'encrypted', 'fairplay', 'fps', 'sinf' or 'drm' (case-insensitive); the media-related rules are '(play-media)', '(media-remote)', '(asset-access 'with-media-playback)', '(media-accessibility-support)', '(media-capture-support)' and a mediaserverd extension-class. On the host machine the macOS GPU process bundle /System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc contains no .sb file at all (only Info.plist, version.plist, CodeResources, MacOS/com.apple.WebKit.GPU), so the macOS profile is compiled in and not inspectable this way. The conclusion (FairPlay works in WKWebView without an entitlement) is probably right, but this specific supporting evidence is invented.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/Resources/SandboxProfiles/ios/com.apple.WebKit.GPU.sb.in


**Claim:** '.nonPersistent() will break persistent licenses, so expect DRM failures in private windows and message that honestly.'

**Why it is wrong:** HARD FACT (source) + INFERENCE (consequence). Overstated. CDMPrivateFairPlayStreaming::supportsSessionTypeWithConfiguration() explicitly permits CDMSessionType::Temporary whenever configuration.persistentState is not CDMRequirement::Required, and the persistent-state gates at lines 342-350 fire only when persistentState == Required or when the site requests PersistentLicense *without* also listing Temporary. Streaming playback (Netflix/Disney+/Max) uses temporary sessions; only offline downloads / persistent-license flows touch WebsiteDataStore::defaultMediaKeysStorageDirectory(). So 'expect DRM failures in private windows' is not the right expectation to bake into UI copy - the honest statement is 'offline/persistent-license content will not work in an ephemeral store; streaming should'. Also note defaultMediaKeysStorageDirectory() is WebsiteDataStore::defaultMediaKeysStorageDirectory(const String&), an internal WebKit C++ function (Source/WebKit/UIProcess/WebsiteData/WebsiteDataStore.cpp:2450) - not a public API a Swift developer can call, which their prose reads as if it were.

**Source:** https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/graphics/avfoundation/CDMFairPlayStreaming.cpp


### Verifier notes

METHOD NOTE: the WebSearch budget for this session was already exhausted (200/200) before I started, so every fact below comes from direct WebFetch/curl of primary sources or from read-only inspection of this host (macOS 26.5.2, build 25F84, Apple Silicon). No files were written; no repos cloned.

VERDICT: the researcher is a good mechanic and a bad risk-assessor. Every WebKit-internals claim I could check held up verbatim - the macOS isFullWebBrowserOrRunningTest() implementation, the frozen UA base string, both EME preference defaults, the streaming-site quirks, the iOS-only scope of the DMA engine entitlements and BrowserEngineKit. But their headline, fatal-rated conclusion ("no macOS browser entitlement exists, budget zero time") is wrong, and it is wrong in the direction that costs a shipping browser the most.

WHAT ACTUALLY BLOCKS PANE (the thing they missed):
com.apple.developer.web-browser.public-key-credential is a real, macOS-13.3+, Apple-reviewed managed capability. Its request form (https://developer.apple.com/contact/request/macos-browsers-passkeys/) 302s to Apple ID sign-in, and Apple's own text requires the Account Holder role on an ORGANIZATION developer account. Without it, WKWebView passkeys only work for relying parties the app declares via com.apple.developer.associated-domains - impossible for a general-purpose browser. In 2026, shipping a browser where google.com/github.com/icloud.com passkey sign-in silently fails is not a caveat, it is a missing feature. Budget: an org Apple Developer account (if Pane is a solo project, this is a hard prerequisite, not paperwork), plus an unbounded Apple review cycle, plus a real chance of refusal. Start this on day one, not at beta.

USEFUL SIDE EFFECT: Apple's criteria for that entitlement include "Your app needs to specify the HTTP and HTTPS schemes in its Info.plist file" plus a URL field / search / bookmarks on launch. That is independent corroboration that the CFBundleURLTypes work the researcher recommends is load-bearing - just for a different reason than the one they gave.

WHERE THEY OVERSOLD (fix the plan, not the verdict): the ITP/TCC consequence of URL-scheme registration does not exist on macOS (APP_BOUND_DOMAINS is iOS-only, so determineTrackingPreventionStateInternal falls through to isRunningTest()); the real macOS consequence they missed is shouldEvaluateJavaScriptWithoutTransientActivation(). The GPU-sandbox "unconditional encrypted-media allowances" citation is invented - WebKit ships no macOS sandbox profile in-tree and the iOS one has no encrypted-media rules. The private-window DRM warning is overstated: temporary FairPlay sessions are explicitly supported without persistent state, so streaming should work in ephemeral stores; only offline/persistent-license downloads break.

WHERE THEY ARE OUTRIGHT WRONG AND IT WILL BITE: "read the Safari version from WebKit.framework's CFBundleShortVersionString" yields "21624" on this machine. Ship that and Pane's UA becomes "...Version/21624 Safari/605.1.15". Safari's real version (26.5.2 here) is only in /Applications/Safari.app/Contents/Info.plist, which a sandboxed build cannot read. There is no clean programmatic source for the Version token - pin a constant, verify it against a real Safari on the target OS, and put it behind a remote-configurable value.

FINALLY, the Google claim needs a downgrade in confidence. Their diagnosis is confirmed by Google's own docs ("iOS and macOS developers may encounter this error when opening authorization requests in WKWebView"), so yes, the bare WKWebView UA is a problem and spoofing is the plausible mitigation. But the verification recipe they handed over (disallow_webview=true) does not exist in Google's documentation, and Google's published remedy is "open in the OS default link handler / use AppAuth", not "change your UA". Google's policy bans embedded user agents as a class, not as a string match. Plan for a real, manual OAuth smoke test on a spoofed build early, and treat continued Google sign-in as a monitored risk rather than a closed item.

Corrected verdict: partially-blocked. DRM/FairPlay, default-browser registration and UA spoofing are all free and work as they described. Passkeys are gated behind an Apple-reviewed, organization-only managed entitlement that they told the team to spend zero time on.
