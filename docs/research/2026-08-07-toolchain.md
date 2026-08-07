# Research — toolchain

**Date:** 2026-08-07  
**Host:** macOS 26.5.2 (build 25F84), Apple Silicon, Swift 6.3.3, SDK MacOSX26.5  
**Target:** macOS 14+ deployment

**Area:** Build, sign, ship — local toolchain reality (Xcode-less macOS 26 browser)

**Verdict:** `works-with-caveats`  
*(not adversarially verified — treat every claim as one source deep)*


> Claims are tagged HARD FACT (fetched from a primary source) or INFERENCE.
> Findings are preserved as reported. Where a verifier disagreed, BOTH are kept —
> the disagreement is the information.


---

## Hard facts

- Command Line Tools 26.5 ships a COMPLETE macOS 26.5 SDK, not a stripped one. /Library/Developer/CommandLineTools/SDKs/ contains MacOSX26.5.sdk (symlinked as MacOSX.sdk and MacOSX26.sdk) plus MacOSX15.4.sdk, with 298 frameworks in System/Library/Frameworks. AppKit, WebKit, AuthenticationServices, Security, SwiftUI, LocalAuthentication, CryptoKit, Network, UserNotifications, ServiceManagement are all present, each with a .swiftmodule (AppKit.swiftmodule, WebKit.swiftmodule, plus WebKit.swiftcrossimport). Verified: `plutil -extract CanonicalName raw .../SDKSettings.plist` returns `macosx26.5`.
  - min OS: `n/a`
  - file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/SDKSettings.plist
- Verified by compilation, not inspection: a Swift 6 language-mode typecheck of `import AppKit/WebKit/AuthenticationServices/Security/SwiftUI` plus `NSGlassEffectView()`, `g.cornerRadius`, `WKWebView(frame:configuration:)`, `w.pageZoom`, and `ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier:)` succeeds against the CLT SDK with `swiftc -typecheck -target arm64-apple-macos26.0 -swift-version 6`. Exit 0; only MainActor-isolation warnings. Full Xcode is NOT needed to compile a macOS 26 AppKit+WebKit browser.
  - min OS: `26.0`
  - file:///Library/Developer/CommandLineTools/usr/bin/swiftc
- NSGlassEffectView is macOS 26.0+ (introducedAt 26.0, not beta). Properties: contentView (NSView?), cornerRadius (CGFloat), tintColor (NSColor?), style (NSGlassEffectView.Style), effectIsInteractive (Bool, still marked Beta). Companion NSGlassEffectContainerView merges nearby glass views. The header NSGlassEffectView.h IS present in the local CLT SDK at AppKit.framework/Headers/ and is exported from AppKit.h — so a macOS 26 SDK is required and CLT 26.5 has it.
  - min OS: `26.0`
  - https://developer.apple.com/tutorials/data/documentation/appkit/nsglasseffectview.json
- XCTest is NOT available without Xcode. `import XCTest` fails with "no such module 'XCTest'" against the CLT SDK. XCTest.framework does not exist in MacOSX26.5.sdk/System/Library/Frameworks/, and /Library/Developer/CommandLineTools/Library/Frameworks/ is empty. The only XCTest artifacts present are libswiftXCTest.dylib (an overlay shim, useless alone) and the private XCTestSupport.framework (.tbd stub only). XCTest.framework ships exclusively inside Xcode.app/Contents/Developer/Library/Frameworks/.
  - min OS: `n/a`
  - file:///Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/
- swift-testing IS fully available. Testing.framework exists at /Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework, alongside cross-import overlays _Testing_AppKit.framework, _Testing_Foundation.framework, _Testing_CoreGraphics.framework, _Testing_CoreImage.framework, _Testing_UIKit.framework. The macro plugin is at usr/lib/swift/host/plugins/testing/libTestingMacros.dylib. `@Test func t() { #expect(1 == 1) }` typechecks cleanly when the plugin is loaded. `swift test` exposes `--enable-xctest/--disable-xctest` and `--enable-swift-testing/--disable-swift-testing`, so `swift test --disable-xctest` is the supported Xcode-less path.
  - min OS: `n/a`
  - file:///Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework
- actool and ibtool are NOT usable. `xcrun -f actool` and `xcrun -f ibtool` both fail with "unable to find utility ... not a developer tool or in PATH" (the /usr/bin/actool hit is only the xcrun shim). Same for `metal` and `metallib`. Consequence: no asset-catalog compilation (no Assets.car), no .xib/.storyboard compilation, no Metal shader compilation. iconutil IS present (/usr/bin/iconutil), so .iconset -> .icns app icons still work.
  - min OS: `n/a`
  - file:///Library/Developer/CommandLineTools/usr/bin/
- codesign, notarytool, and stapler are all present in CLT and work without Xcode. notarytool is at /Library/Developer/CommandLineTools/usr/bin/notarytool, version 1.1.2 (41). `codesign --entitlements path` is documented in the local man page: "take the file at the given path and embed its contents in the signature as entitlement data." /usr/bin/syspolicy_check and /usr/sbin/spctl are also available for validating signatures.
  - min OS: `n/a`
  - file:///Library/Developer/CommandLineTools/usr/bin/notarytool
- TN3125: on macOS most entitlements are UNRESTRICTED and need no provisioning profile. Explicitly unrestricted: com.apple.security.get-task-allow, com.apple.security.application-groups, ALL App Sandbox entitlements, and ALL Hardened Runtime entitlements. Apple states: "A Mac app that uses no restricted entitlements doesn't need a provisioning profile. This is true even if the app is distributed on the App Store. The only exception to this rule is TestFlight, which always requires a profile." keychain-access-groups IS restricted: "the fact that the keychain-access-groups entitlement must be authorized by a profile means that other developers can't impersonate your app in order to steal its keychain items."
  - min OS: `n/a`
  - https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
- TN3127: ad-hoc signed code has a designated requirement tied to the cdhash, which changes on every rebuild, so macOS cannot track code identity across builds. Apple: "Ad hoc signed code, called Sign to Run Locally by Xcode, has a DR but it's tied to that specific version of the code... macOS can't reliably track the identity of the code." And: "If you tweak the code and run it again, macOS repeats that prompt." This breaks TCC persistence (camera, mic, screen recording, location) and keychain authorization across rebuilds — acutely painful for a browser, where all of those are requested on behalf of web content.
  - min OS: `n/a`
  - https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- Apple DTS (Quinn) confirms two specific drawbacks of ad-hoc "Sign to Run Locally" and recommends Apple Development certificates for day-to-day macOS development: (1) "Your code cannot use restricted entitlements when using ad-hoc signing" (ref TN3125); (2) "Your code's identity isn't stable with ad-hoc signing, causing TCC problems" (ref TN3127).
  - min OS: `n/a`
  - https://developer.apple.com/forums/thread/751658
- Passkeys in third-party browser content require com.apple.developer.web-browser.public-key-credential, macOS 13.3+ / Mac Catalyst 16.3+. It "lets your app make registration and assertion requests for passkeys and security keys for any relying party identifier." It is a MANAGED capability: it requires the Account Holder role, submission of the request form at developer.apple.com/contact/request/macos-browsers-passkeys/, and Apple review against published browser-eligibility criteria (must declare HTTP/HTTPS schemes in Info.plist; must present a URL field, search, or curated bookmarks on launch; must navigate HTTP/HTTPS URLs directly to the specified destination). Managed capabilities are provisioned via App ID and delivered through a provisioning profile.
  - min OS: `13.3`
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential
- Locally verified against shipping browsers: Google Chrome claims com.apple.developer.web-browser.public-key-credential:true plus six keychain-access-groups (EQHXZ8M8AV.com.google.Chrome.webauthn, .webauthn-uvk, .unexportable-keys, .secure-payment-confirmation, .devicetrust, com.google.common.folsom). Arc claims the same public-key-credential entitlement plus keychain-access-groups S6N382Y83G.company.thebrowser.browser.webauthn/.auth and associated-domains webcredentials:arc.net. Both entitlement sets are restricted and both are tied to a Team ID prefix — neither is reachable ad-hoc.
  - min OS: `13.3`
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential
- Neither Chrome nor Arc is App-Sandboxed. `codesign -d --entitlements` shows no com.apple.security.app-sandbox key on either (Chrome's device.camera/audio-input/usb/bluetooth keys are inert without it). Both DO enable Hardened Runtime: Chrome flags=0x12a00(kill,restrict,library-validation,runtime), Arc flags=0x10000(runtime). Directly relevant precedent: a shipping macOS browser does not sandbox itself.
  - min OS: `n/a`
  - https://developer.apple.com/documentation/security/hardened-runtime
- com.apple.security.cs.allow-jit is required on Apple Silicon when a Hardened Runtime app uses JavaScriptCore (i.e. WKWebView), or the app crashes when the web view initializes JSC. The entitlements form a cascade allow-jit -> allow-unsigned-executable-memory -> disable-executable-page-protection and only one should be set; allow-jit is the most secure. Because it is a Hardened Runtime entitlement, TN3125 classes it as unrestricted — it works with ad-hoc signing.
  - min OS: `10.14`
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit
- Notarization requires a paid Apple Developer Program membership. Apple requires a "Developer ID" application/installer certificate and explicitly excludes "Mac Distribution, ad hoc, Apple Developer, or local development certificates." It also mandates Hardened Runtime, a secure timestamp (`codesign --timestamp`), linking against macOS 10.9+ SDK, valid signatures on every nested executable, and forbids com.apple.security.get-task-allow with any true value. A free Apple ID cannot obtain a Developer ID certificate.
  - min OS: `n/a`
  - https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- This machine currently has ZERO signing identities and ZERO provisioning profiles. `security find-identity -v -p codesigning` and `security find-identity -v` both return "0 valid identities found". Neither ~/Library/Developer/Xcode/UserData/Provisioning Profiles/ nor ~/Library/MobileDevice/Provisioning Profiles/ exists. Day one, ad-hoc (`codesign -s -`) is the only option available without further setup.
  - min OS: `n/a`
  - file:///Users/aflekkas
- macOS 26 Liquid Glass app icons use the new .icon format authored in Icon Composer, which must be compiled by actool into Assets.car; Icon Composer ships with Xcode 26. Xcode also auto-generates a legacy .icns from the .icon for backward compatibility, and both Assets.car and .icns are placed in Contents/Resources. Without actool the .icns path (via the locally-present iconutil) still works and still yields a valid, if legacy-styled, icon.
  - min OS: `26.0`
  - https://successfulsoftware.net/2025/09/26/updating-application-icons-for-macos-26-tahoe-and-liquid-glass/

## Corrections to the spec


### (MINOR) Implicitly, that a macOS 26 AppKit + WebKit + Swift 6 app needs full Xcode — or conversely that the Command Line Tools S

**Spec said:** Implicitly, that a macOS 26 AppKit + WebKit + Swift 6 app needs full Xcode — or conversely that the Command Line Tools SDK is a reduced/CLI-only SDK missing GUI frameworks.

**Reality:** Wrong in the pessimistic direction. CLT 26.5 ships the complete macOS 26.5 SDK: 298 frameworks including AppKit, WebKit, AuthenticationServices, Security, SwiftUI, with Swift modules. A Swift 6 typecheck touching NSGlassEffectView, WKWebView, and ASAuthorizationPlatformPublicKeyCredentialProvider compiles clean. There is no compilation blocker whatsoever.

**Source:** file:///Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk


### (MAJOR) Testing via XCTest (or unqualified 'unit tests') for a package with AppKit dependencies.

**Spec said:** Testing via XCTest (or unqualified 'unit tests') for a package with AppKit dependencies.

**Reality:** XCTest is flatly unavailable without Xcode — `import XCTest` errors with "no such module 'XCTest'". XCTest.framework ships only inside Xcode.app. Any XCTest-based test target will fail to build on this machine. swift-testing is the only option, and it IS fully present (Testing.framework plus a _Testing_AppKit cross-import overlay), driven by `swift test --disable-xctest`. This forces a testing-framework decision before the first test is written; retrofitting later is a rewrite of every test file.

**Source:** file:///Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework


### (FATAL) Passkeys / AuthenticationServices as a browser feature — implicitly that adding Associated Domains and calling ASAuthori

**Spec said:** Passkeys / AuthenticationServices as a browser feature — implicitly that adding Associated Domains and calling ASAuthorization* is sufficient.

**Reality:** Fatal for the feature as specced. A browser authenticating on behalf of arbitrary websites needs com.apple.developer.web-browser.public-key-credential, a MANAGED capability requiring the Account Holder role, a written application to Apple, and Apple's approval against browser-eligibility criteria. Associated Domains (webcredentials:) is a different thing entirely — it scopes passkeys to YOUR OWN domain (Arc uses it for arc.net logins), not for browsing. Both are restricted entitlements requiring a provisioning profile, so both are unreachable with ad-hoc signing and unreachable with a free Apple ID. Chrome and Arc both carry the entitlement; you cannot ship passkey support without it.

**Source:** https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential


### (MAJOR) App Sandbox listed as an entitlement area to solve for, implying Pane should be sandboxed.

**Spec said:** App Sandbox listed as an entitlement area to solve for, implying Pane should be sandboxed.

**Reality:** Real macOS browsers are not sandboxed. Direct inspection of the installed Chrome and Arc shows neither claims com.apple.security.app-sandbox; both use Hardened Runtime only. Sandboxing a browser fights you on downloads, profile/cache directories, native messaging, and helper processes for no distribution benefit outside the Mac App Store — which a browser cannot realistically target anyway. Drop sandbox from the plan; keep Hardened Runtime.

**Source:** https://developer.apple.com/documentation/security/hardened-runtime


### (MAJOR) Ad-hoc signing as the day-one local development path (implied by 'what can a solo dev actually run locally on day one').

**Spec said:** Ad-hoc signing as the day-one local development path (implied by 'what can a solo dev actually run locally on day one').

**Reality:** It works, but with a cost the spec does not anticipate. Ad-hoc signatures have a designated requirement bound to the cdhash, which changes on every build. macOS therefore treats each rebuild as different code and re-prompts for every TCC permission. For a browser — camera, microphone, screen recording, location, all requested on behalf of web content — that means re-granting permissions on literally every build. It is a productivity tax, not a correctness blocker, and the fix (an Apple Development cert) normally requires Xcode to provision.

**Source:** https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements


### (MINOR) Asset catalog compilation via actool listed as 'genuinely lost' — treated as an open question.

**Spec said:** Asset catalog compilation via actool listed as 'genuinely lost' — treated as an open question.

**Reality:** Confirmed lost, and it is worse than asset catalogs alone: actool, ibtool, metal, and metallib are all absent (xcrun -f fails for each). Practical impact is smaller than it sounds. You lose the macOS 26 Liquid Glass .icon app icon (Icon Composer + actool only), .xib/.storyboard compilation, and your own Metal shaders. You do NOT lose the app icon entirely — iconutil is present, so .iconset -> .icns works. WebKit's internal Metal use is prebuilt in system frameworks and unaffected. Build UI programmatically (correct for AppKit in 2026 anyway) and this costs you an icon fidelity downgrade, nothing more.

**Source:** file:///Library/Developer/CommandLineTools/usr/bin/


### (MAJOR) 'Keychain access groups' grouped with sandbox and hardened runtime as entitlements to evaluate.

**Spec said:** 'Keychain access groups' grouped with sandbox and hardened runtime as entitlements to evaluate.

**Reality:** They are in fundamentally different tiers and the spec flattens them. Per TN3125, App Sandbox entitlements, Hardened Runtime entitlements, get-task-allow, AND application-groups are all UNRESTRICTED on macOS — no provisioning profile, work fine ad-hoc. keychain-access-groups is RESTRICTED and requires a profile, and is Team-ID-prefixed, so it needs a paid account. Note the specific correction: application-groups is unrestricted on macOS even though it is Team-ID-prefixed on iOS.

**Source:** https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles


### (MINOR) 'XcodeGen or Tuist (neither installed)' offered as a serious layout option.

**Spec said:** 'XcodeGen or Tuist (neither installed)' offered as a serious layout option.

**Reality:** Both are dead ends here, for the same reason: they generate .xcodeproj files, which are inert without xcodebuild. Generating a project you cannot build buys nothing. They only become useful the day full Xcode is installed, and at that point Xcode can open a Package.swift directly. Skip both.

**Source:** https://developer.apple.com/documentation/xcode


## Recommended approach

**Layout: hand-rolled Package.swift + a bundle-assembly script. Not XcodeGen, not Tuist, not a thin .xcodeproj** — all three generate artifacts only `xcodebuild` can consume, and it does not exist here.

Structure the package as a thin `.executableTarget("Pane")` over fat library targets: `PaneCore` (tab lifecycle state machine, session model — zero AppKit imports), `PaneUI` (AppKit/NSGlassEffectView), `PaneWeb` (WKWebView wrapper). Test `PaneCore` headlessly; that is the whole trick for testing a tab state machine — keep it a pure `struct`/`enum` reducer (`func reduce(_ state: TabState, _ event: TabEvent) -> TabState`) with no `WKWebView` reference, and no window server is ever needed.

**Testing: swift-testing only. Delete XCTest from your vocabulary.** Write `import Testing` / `@Test` / `#expect`, run `swift test --disable-xctest`. Decide this before the first test file — retrofitting is a full rewrite. `_Testing_AppKit` is available if you later need NSImage attachments.

**Bundle assembly script** (`Scripts/bundle.sh`, ~60 lines):
1. `swift build -c release --product Pane`
2. `mkdir -p Pane.app/Contents/{MacOS,Resources}`
3. Copy binary to `Contents/MacOS/Pane`; copy any SPM `*.bundle` resource dirs into `Contents/Resources/` so `Bundle.module` resolves.
4. Write `Contents/Info.plist` with `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundlePackageType=APPL`, `NSPrincipalClass=NSApplication`, `LSMinimumSystemVersion=26.0`, and — required later for the passkeys entitlement application — `CFBundleURLTypes` declaring `http`/`https`.
5. Icon: `iconutil -c icns Pane.iconset -o Contents/Resources/Pane.icns`.
6. `codesign --force --sign - --entitlements Pane.entitlements --deep Pane.app`

Use `@main` + `NSApplicationDelegate`, and always launch via `open Pane.app` (never the raw binary) or you get no menu bar and wrong activation policy.

**Day-one entitlements (all unrestricted, all work ad-hoc):** skip App Sandbox entirely (Chrome and Arc do). Skip Hardened Runtime at first — then you don't even need `allow-jit`. When you do enable it (`codesign -o runtime`), add `com.apple.security.cs.allow-jit` or WKWebView crashes on Apple Silicon when JavaScriptCore initializes.

**Blocked until $99/yr + approval:** `keychain-access-groups`, `associated-domains`, and critically `com.apple.developer.web-browser.public-key-credential`. Architect passkeys behind a protocol with a no-op implementation now; do not design the credential UI around an entitlement you may not get.

**Notarization:** unreachable today (zero identities). Once you hold Developer ID: `codesign -o runtime --timestamp`, zip, `notarytool submit --wait --apple-id ... --team-id ... --password <app-specific>`, then `stapler staple`. Both binaries are already installed.


## Effort estimate

Build/sign/ship infrastructure: ~3-5 solo dev days. Breakdown: Package.swift + three-target split, 0.5d; bundle.sh assembly script (Info.plist, resource bundle copying, iconutil, ad-hoc codesign), 1-1.5d — most of the cost is trial-and-error on Info.plist keys and getting SPM resource bundles to land where Bundle.module expects; swift-testing harness for the headless state machine, 0.5d; iterating on entitlements + Hardened Runtime + allow-jit until WKWebView stops crashing, 1d. Notarization pipeline is a further 1d but is GATED, not costed — it cannot start until a $99/yr Developer ID exists. The dominant NON-code cost is calendar time, not dev time: the web-browser.public-key-credential entitlement requires enrollment plus an Apple review with no published SLA, so passkeys should be assumed weeks-to-never out and must not sit on the critical path. Second-largest hidden tax is the ad-hoc TCC re-prompt loop (permissions re-requested every rebuild), which quietly costs minutes per day forever until a stable signing identity exists.


## Open questions

- Can a FREE Apple ID (Personal Team) produce a usable macOS Apple Development certificate WITHOUT Xcode? Every documented path to a personal-team cert runs through Xcode's automatic signing UI; the Developer Portal certificate section is understood to be paid-only. If there is no Xcode-less path, the ONLY way off unstable ad-hoc identity (and its per-build TCC re-prompts) is the $99/yr program. Worth 30 minutes of testing before committing to the ad-hoc workflow.
- Does the web-browser.public-key-credential request form accept an INDIVIDUAL developer account, or strictly an Organization (D-U-N-S required)? Apple's doc says 'Account Holder role for your organization's Apple Developer account'. An individual is the Account Holder of their own account, so this may be boilerplate — but if Organization is genuinely required, passkeys are permanently blocked for a solo dev and that should reshape the product plan now, not later.
- Does `swift test --disable-xctest` actually link and run cleanly on macOS with no Xcode present, or does SwiftPM's macOS test-product path still try to build an XCTest bundle? The flags exist and Testing.framework is present, but this was not executed end-to-end (read-only constraint). This is the single highest-value 10-minute experiment — if it fails, the testing story needs rethinking entirely.
- Does WKWebView instantiate and render successfully in an ad-hoc-signed, non-sandboxed app on macOS 26? The WebContent/Networking XPC helper processes must launch, and there are scattered reports of RunningBoard entitlement errors (com.apple.runningboard.assertions.webkit) in unusually-signed apps. No authoritative source found either way. This is the one remaining thing that could turn the verdict from works-with-caveats to blocked — test it first, before writing any other code.
- On macOS 26, how does a legacy .icns icon actually render given Tahoe's Liquid Glass icon system — is it auto-masked into the rounded-rect shape, or does it render unmasked and visibly wrong next to every other app in the Dock? Determines whether the missing actool is a cosmetic footnote or a genuine reason to borrow a Mac with Xcode once per release to compile the .icon.
