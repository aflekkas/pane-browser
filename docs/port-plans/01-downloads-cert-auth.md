# Plan 01 — Downloads + Certificate/Auth: Pane → Ora ("Pane" fork)

Status: research only. No code changed. Xcode is not installed; nothing below has been compiled.
Ora UI stays as-is. Only Ora's engine/feature plumbing gains Pane behaviour.

Repos: `repos/ora` (target, GPL-3.0 upstream), `repos/pane` (source of behaviour).
Pane file headers cite `spec: §6`; keep that traceability in ported files as a comment.

---

## 1. What Ora currently does

### 1.1 Downloads

| Piece | Where | Behaviour today |
|---|---|---|
| Trigger | [BrowserPage.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Core/BrowserEngine/BrowserPage.swift:365) `decidePolicyFor navigationResponse` | `canShowMIMEType == false` → `.download` (`:386`); `navigationAction:didBecomeDownload:` is **not** implemented, so action-initiated downloads have no second route. |
| Handoff | [BrowserPage.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Core/BrowserEngine/BrowserPage.swift:390) | Wraps `WKDownload` in `BrowserDownloadTask`, fires `BrowserPageDelegate.browserPage(_:didStartDownload:)` ([BrowserPageDelegate.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Core/BrowserEngine/BrowserPageDelegate.swift:32)). |
| Per-tab glue | [TabBrowserPageDelegate.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Tabs/Browser/TabBrowserPageDelegate.swift:195) | `tab?.downloadManager?.handleDownload(download)`; go-back / close-tab dance for download navigations. |
| `WKDownloadDelegate` | [BrowserDownloadTask.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Core/BrowserEngine/BrowserDownloadTask.swift:4) | Callbacks only: `onDestinationRequest` (`:29`), `onRedirect` (`:42`), `onFinish` (`:55`), `onFail` (`:59`, old `didFailWithError:` **without `resumeData`**). No `download(_:respondTo:)` — download-time auth challenges are unhandled. |
| Manager | [DownloadManager.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Downloads/Services/DownloadManager.swift:133) `handleDownload` | Destination = `~/Downloads/<suggestedFilename>` uniquified by `createUniqueFilename` (`:254`, `name (1).ext` style). Progress via 0.1 s `Timer` polling `task.progress` (`:271`), not KVO. `onFinish` → `completeDownload` + toast (`:91`). |
| Model | [Download.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Downloads/Models/Download.swift:12) | SwiftData `@Model`: `pending/downloading/completed/failed/cancelled`, `destinationURL`, byte counts. No `resumeData`, no source-page URL, no quarantine flag. |
| Retry | [DownloadManager.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Downloads/Services/DownloadManager.swift:235) | Deletes the record and re-opens the original URL via `.openURL` notification. No `resumeDownload(fromResumeData:)`. |
| UI (keep) | `Features/Downloads/Views/DownloadsHistoryView.swift`, `DownloadsListView.swift`, `DownloadHistoryRow.swift`, `DownloadProgressView.swift`, `Features/Sidebar/Views/DownloadsWidget.swift`, sidebar swipe in `Features/Sidebar/Views/SidebarView.swift:32,122,135` | Full SwiftUI history/search/widget already exists. **Do not port Pane's panel UI** (§3.3). |
| Quarantine | — | **Absent.** No `quarantine`/`LSFileQuarantineEnabled` anywhere in `repos/ora` (grep: zero hits). [Info.plist](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Info/Info.plist:1) has no `LSFileQuarantineEnabled`; [project.yml](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/project.yml:96) entitlements do grant `com.apple.security.files.downloads.read-write` (`project.yml:106`). No filename sanitisation beyond uniquing; `suggestedFilename` is used verbatim at `DownloadManager.swift:141`. No Dock-tile progress. |

### 1.2 Certificate / auth

- Single seam: [BrowserPage.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Core/BrowserEngine/BrowserPage.swift:350) `webView(_:didReceive:completionHandler:)`.
  If `NSURLAuthenticationMethodServerTrust` **and** host ∈ `sslBypassedHosts` → `.useCredential, URLCredential(trust:)` (`:355-359`); otherwise `.performDefaultHandling` for **everything** (`:361`) — including HTTP Basic/Digest/NTLM. There is no Ora auth prompt of its own.
- Bypass is **host-only**: `sslBypassedHosts: Set<String>` ([BrowserPage.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Core/BrowserEngine/BrowserPage.swift:13)), populated by `bypassSSL(for:)` (`:186`), called only from `Tab.continueToInsecureSite()` ([Tab.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Tabs/Models/Tab.swift:327)). No cert fingerprint, no chain, no `SecTrustEvaluateWithError`, no expiry/revocation distinction, no per-profile or persistent store. Lifetime = that `BrowserPage` instance.
- Flow is **post-failure**, not at challenge time: navigation fails → `Tab.setNavigationError` ([Tab.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Tabs/Models/Tab.swift:302)) → [BrowserWebContentView.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Browser/Views/BrowserWebContentView.swift:52) swaps web content for `StatusPageView` → "Continue Anyway" (ghost `OraButton`) shown only when the `NSError` maps to `.security` (`NSURLErrorServerCertificateUntrusted/ClientCertificateRequired/SecureConnectionFailed`, [StatusPageView.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Browser/Views/StatusPageView.swift:137)) → `continueToInsecureSite()` re-loads.
- Grep confirms: no `SecTrust`, `SHA-256`/fingerprint, cert-exception store, `URLCredentialStorage`, or download-challenge handling in Ora.

---

## 2. What Pane does, and what governs it

Governing text: `docs/pane-browser-spec.md` **§6 "The boring floor"** (Downloads :211-220, Basic auth :225-226, Cert errors :228-229), plus §1/CLAUDE.md invariant "**No web content renders browser UI** — interstitials are native" (`repos/pane/CLAUDE.md:23`, restated `CertInterstitial.swift:8-10`, `AuthChallengeHandler.swift:181-183`). Security invariants below are quoted/paraphrased exactly; do not improvise beyond them.

### 2.1 Downloads (spec §6, `Sources/PaneUI/DownloadManager.swift`, header `// spec: §6`)

- `WKDownloadDelegate` with uniquing pass, `download.progress` KVO, `resumeData` persisted on failure, `NSPopover` panel + `NSApp.dockTile` progress (spec :220; Dock tile actually wired in `BrowserWindow.swift:356-375`, badge = aggregate %, cleared when idle).
- **Quarantine — read the correction chain before coding.** Spec :220 says set `com.apple.quarantine` yourself "or you have built a malware vector". Measured reality (`docs/api-notes/quarantine.md:75-117`, summarised `DownloadManager.swift:8-26`): on macOS 26.5 `WKDownload` **itself** quarantines (`0283;…`); a plain `Data.write` does not. Pane's `applyQuarantine` (`DownloadManager.swift:92-127`) is therefore **belt-and-braces for the xattr**; its intended extra — provenance via `kLSQuarantineDataURLKey`/`kLSQuarantineOriginURLKey` as **NSURL objects** (`:104-105`, strings are silently dropped) after clear-then-set (`:114-120`) — **does not populate the LaunchServices DB** after 3 recorded attempts. "Do not try a fourth variation" (`quarantine.md:68`). `LSFileQuarantineEnabled` stays in Info.plist regardless (`quarantine.md:109`, `Scripts/bundle.sh:55`). Failure to set quarantine is **loud** (`NSLog`, :121-126), never silent. `hasQuarantine(_:)` read-back is the verifiable property (`:131-134`).
- Never silently overwrite: `uniqueDestination` → `name 2.ext`, `name 3.ext`… (`:75-87`).
- Failed downloads keep `resumeData` (`Item.resumeData`, `:39-40`; set in `didFailWithError:resumeData:` `:168-176`).
- **Downloads have their own auth challenge**: `download(_:respondTo:)` (`:181-185`) — omitting it "rejects the protection space silently". Delegates to the same `AuthChallengeHandler`.
- Panel surfaces quarantine state per item: `"checked by macOS"` vs `"NOT quarantined"` (`DownloadsPanel.swift:121-134`).

### 2.2 Cert/auth (spec §6, `AuthChallengeHandler.swift` + `CertInterstitial.swift`)

- One entry for both navigation and download challenges: `AuthChallengeHandler.respond(to:window:)` (`AuthChallengeHandler.swift:21`). ServerTrust → `serverTrust`; HTTPBasic/Digest/NTLM → `basicAuth`; anything else → `.performDefaultHandling` (`:25-36`).
- Server trust: `SecTrustEvaluateWithError` first; valid → `.performDefaultHandling` (`:94-97`). Exceptions keyed by **host + leaf SHA-256, never wildcard** (`:102-108`); on user proceed, `CertExceptions.allowForSession` — "**never permanent by default**. Session-scoped" (`:117-118`; store `:241-260`, in-memory `Set<"host|sha256">`).
- Interstitial: native **full-content-area** view, red/amber by severity, "Advanced" disclosure showing the actual chain + SHA-256 (`CertInterstitial.swift:5-6,70-80`). Severity: expired / not-yet-valid / hostname-mismatch → `.amber`; **everything else → `.red`** ("guessing low on an unrecognised failure is the wrong direction to err", `:123-136`). Safe action ("Go Back") is the default/Return key; "Continue for This Session" is never default (`:53-62`). Fallback when no content host exists (e.g. download challenges): critical `NSAlert`, proceed is second button (`AuthChallengeHandler.swift:210-231`).
- HTTP auth: sheet-attached `NSAlert`, username + secure password fields, `previousFailureCount < 3` guard against credential loops (`:45`), credential persistence **`.forSession`, not `.permanent`** — "writing to the keychain here would be a credential store, which is milestone F" (`:72-77`).
- **Spec-vs-code corrections (must carry into the port, not the stale spec text):**
  1. Spec §6 :226 says scope credentials to a per-profile `URLCredentialStorage`. Code comment `:12-17` (from `docs/research/2026-08-07-boring-floor.md`): neither needed nor possible — WebKit installs a per-identifier credential store automatically when the data store has `dataStoreIdentifier`. Per-profile isolation is **automatic** with `WKWebsiteDataStore(forIdentifier:)`; it cannot be injected.
  2. Spec §6 :229 says exceptions "stored per profile in SQLite". Shipped code is an **in-memory, session-only singleton**, not per-profile, not persisted; PROGRESS.md:228 records "session-scoped" as the delivered behaviour. Port the code's semantics; treat per-profile/SQLite as an open question (§5), not a requirement.
  3. Pane depends on a test mutant `Mutants.isActive("security.trust_all_certs")` (`AuthChallengeHandler.swift:91`) — harness-only, **strip on port** (Ora has no `Mutants`/`PaneCore`).

### 2.3 Pane checks that prove it

- `Sources/PaneHarness/DownloadCheck.swift`: real `WKDownload` via fixture URL; polls to completion; **fails if `com.apple.quarantine` xattr absent** (read back, not trusted `:51-54`); provenance reported, not failed (`:55-62`); uniquing asserted (`:64-67`); JSON verdict on stdout.
- `Sources/PaneHarness/Scenarios.swift:146-195`: `net.auth_challenge_is_answered` (401 fixture resolves, doesn't hang), `net.attachment_becomes_a_download`, `net.untrusted_cert_does_not_silently_load` (self-signed/mismatched fixture must not load). PROGRESS.md:237-249, 267-269 records these gates passing.

---

## 3. Integration plan

Order matters: (A) quarantine+resume are small and self-contained; (B) auth handler; (C) cert interstitial last (touches tab state + UI).

### 3.1 Downloads

Modify:
- [BrowserDownloadTask.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Core/BrowserEngine/BrowserDownloadTask.swift:59) — change `onFail` to carry `resumeData: Data?` (new `download(_:didFailWithError:resumeData:)` signature); add `download(_:respondTo:) async` forwarding to a new `onAuthChallenge` closure; add `cancel(completion:)` variant surfacing resume data if adopted. Keep the closure-callback shape — it's Ora's seam.
- [DownloadManager.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Downloads/Services/DownloadManager.swift:164) — in `onFinish`, call `DownloadQuarantine.apply(to:source:page:)` **before** `completeDownload`; if it fails, log loudly (Pane :121-126) and mark the record (below). Keep Ora's `createUniqueFilename` (`name (1).ext`) — do **not** switch to Pane's `name 2.ext`; uniquing semantics, not spelling, is the invariant. Keep Timer progress (works; Pane KVO is an optional later swap, note `@MainActor (URL?) -> Void` completion-handler gotcha at Pane `DownloadManager.swift:142-145` if swapped).
- [Download.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Downloads/Models/Download.swift:14) — add `pageURLString: String?`, `resumeData: Data?`, `quarantineVerified: Bool`. SwiftData migration is lightweight-additive; verify on a pre-existing store (§4).
- [BrowserPage.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Core/BrowserEngine/BrowserPage.swift:390) — pass `webView.url` as page URL into `BrowserDownloadTask` (Pane `WKWebEngine.swift:269-277` passes `w.url`); add `resumeDownload(fromResumeData:)` wrapper (`webView.resumeDownload(fromResumeData:completionHandler:)`, macOS 11.3+) routing the new `WKDownload` back through `delegate?.browserPage(_:didStartDownload:)`. Also implement `webView(_:navigationAction:didBecome:)` → same delegate call (Pane :274-277) **only if** a fixture shows action-initiated downloads are currently dropped; otherwise note as verified-unneeded.
- [TabBrowserPageDelegate.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Tabs/Browser/TabBrowserPageDelegate.swift:195) / DownloadManager `retryDownload` (`:235`) — if `resumeData != nil`, resume via the tab's `BrowserPage` instead of delete-and-reopen-URL; keep URL-reopen as fallback when no resume data.
- [Info.plist](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Info/Info.plist:83) + [project.yml](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/project.yml:59) `info.properties` — add `LSFileQuarantineEnabled: true` in **both** (project.yml regenerates the plist; editing only one will drift).

Add:
- `ora/ora/Core/BrowserEngine/DownloadQuarantine.swift` — **near-verbatim copy** of Pane `applyQuarantine` + `hasQuarantine` (`DownloadManager.swift:92-134`), minus `PaneCore` import. ~40 lines. This is the highest-value, lowest-risk file in the plan.

UI fit (no new surfaces): add quarantine text to the existing row detail in `Features/Downloads/Views/DownloadHistoryRow.swift` / `DownloadsListView.swift:194-206` — port `DownloadsPanel.detailText` logic (`:121-134`): completed → `"<size> · checked by macOS"` or `"NOT quarantined"` using `theme.destructive` for the latter. Optional: Dock-tile badge in `DownloadManager` mirroring Pane `BrowserWindow.swift:364-375`, updated wherever `activeDownloads` mutates; Ora has no dock-progress today, so this is additive, not parity-required.

### 3.2 HTTP auth

Add:
- `ora/ora/Core/BrowserEngine/BrowserAuthHandler.swift` — adapted copy of Pane `basicAuth` (`AuthChallengeHandler.swift:41-78`): same `previousFailureCount < 3` guard, sheet `NSAlert` with `NSTextField`/`NSSecureTextField` accessory, `.forSession` credential. Present via `page.window` (`BrowserPage.window`, `BrowserPage.swift:94`).

Modify:
- [BrowserPage.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Core/BrowserEngine/BrowserPage.swift:350) — route Basic/Digest/NTLM to a new delegate method (below) instead of blanket `.performDefaultHandling`; keep `.performDefaultHandling` for valid server trust and unknown methods (Pane :35, :96).
- [BrowserPageDelegate.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Core/BrowserEngine/BrowserPageDelegate.swift:32) — add `browserPage(_:respondTo:completion:)` with a default implementation returning `.performDefaultHandling` (matches the file's existing default-extension pattern `:35-83`, so other conformers don't break).
- [TabBrowserPageDelegate.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Tabs/Browser/TabBrowserPageDelegate.swift:129) — implement it by calling `BrowserAuthHandler`. Ora's delegate is completion-handler-based while Pane's is async (`WKWebEngine.swift:257-261` uses the async delegate form); **stay with Ora's completionHandler form** in `BrowserPage` and bridge with a `Task { completion(await …) }` inside the handler. Do not switch `BrowserPage` to the async delegate variant in the same change.

### 3.3 Cert interstitial

Decide the shape first (recommendation): **SwiftUI, reusing Ora's existing error surface** — not a port of Pane's AppKit `NSView`. Rationale: Ora's invariant-equivalent is already satisfied (SwiftUI here is native chrome, never web content; [BrowserWebContentView.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Browser/Views/BrowserWebContentView.swift:52) already replaces the `WKWebView` with native UI on error). Porting `CertInterstitialView` verbatim would introduce a second, visually foreign error system.

Add:
- `ora/ora/Core/BrowserEngine/CertExceptions.swift` — **near-verbatim** `CertExceptions` (`AuthChallengeHandler.swift:243-260`): host+SHA-256 key, session scope, `clear()`. Plus `fingerprint(of:)`/`sha256Hex` (`:122-179`) copied verbatim (self-contained, no dependency; swapping in CryptoKit is a separate, optional decision — see §5).
- `ora/ora/Features/Browser/Views/CertificateInterstitialView.swift` (new SwiftUI view) — Pane's content, Ora's clothes:
  - Title/body/icon from Pane `CertInterstitial.swift:41-51` ("This Connection Is Not Private", host, reason, red-text vs misconfiguration text).
  - Severity colours from [Theme.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Core/Constants/Theme.swift:80): `.destructive` (red) / `.warning` (amber); icon `exclamationmark.shield.fill` / `exclamationmark.triangle.fill` (Pane :35-36); text in `theme.foreground`/`mutedForeground` on `theme.background` — exactly how [StatusPageView.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Browser/Views/StatusPageView.swift:75) already lays out.
  - Buttons: primary safe action reusing `StatusPageView`'s `.borderedProminent` "Go Back" pattern (`StatusPageView.swift:47-59`) as the default; "Continue for This Session" as ghost `OraButton` (`StatusPageView.swift:64-71` already does this for "Continue Anyway") — never prominent, never default.
  - "Advanced" → SwiftUI `DisclosureGroup` showing chain lines (`Leaf:`/`Issuer n:`) + grouped SHA-256 in monospaced 11 pt (Pane :71-80).

Modify:
- [BrowserPage.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Core/BrowserEngine/BrowserPage.swift:350) — server-trust path becomes: `SecTrustEvaluateWithError` → valid: `.performDefaultHandling`; invalid + `CertExceptions.isAllowed(host, fingerprint)`: `.useCredential`; else ask delegate (new `BrowserPageDelegate` method carrying host/reason/severity/chain/fingerprint + completion). **Delete `sslBypassedHosts`/`bypassSSL(for:)`** (`:13,186-188`) once the delegate path lands — host-only bypass is strictly weaker than host+fingerprint and must not survive as a parallel mechanism.
- [Tab.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Tabs/Models/Tab.swift:48) — add `@Transient @Published var certificateChallenge: CertificateChallengeInfo?`; `continueToInsecureSite()` (`:327-333`) is replaced by: record `CertExceptions.allowForSession(host, fingerprint)` then retry the failed URL. Keep `retryNavigation()` for non-cert errors.
- [BrowserWebContentView.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/ora/Features/Browser/Views/BrowserWebContentView.swift:52) — when `tab.certificateChallenge != nil`, show `CertificateInterstitialView` instead of `StatusPageView`; other errors keep `StatusPageView` untouched.
- Timing note: Pane intercepts **at challenge time** (page never loads). Ora today only reacts **after** `didFailProvisionalNavigation`. The delegate-completion design above intercepts at challenge time and never triggers the failure path for certs — so `StatusPageView`'s `.security` branch (`StatusPageView.swift:137-140`) becomes defence-in-depth for direct `NSURLError` failures, not the primary flow. State this in the PR description; test both paths (§4).

Copy-verbatim vs adapt summary:

| Pane source | Disposition |
|---|---|
| `DownloadManager.applyQuarantine/hasQuarantine/uniqueDestination` (:75-134) | Verbatim (drop `PaneCore`); uniquing not adopted (Ora spelling kept). |
| `CertExceptions`, `fingerprint`, `sha256Hex` (`AuthChallengeHandler.swift:122-260`) | Verbatim; strip `Mutants` line :91. |
| `CertInterstitialView.severity(for:)` / `chainSummary` (`CertInterstitial.swift:126-141`) | Verbatim (pure functions). |
| `basicAuth` sheet (`AuthChallengeHandler.swift:41-78`) | Adapt: completion-handler bridge, `page.window`. |
| `CertInterstitialView` NSView (`CertInterstitial.swift:12-121`) | **Do not copy.** Rebuild as SwiftUI per above. |
| `DownloadsPanel.swift` (whole file) | **Do not copy.** Ora's Downloads UI already exceeds it; only `detailText` logic ports. |
| `DownloadCheck.swift`, `Scenarios.swift` net cases | Port as tests (§4), not app code. |

Suggested commit slicing (separate commits, spec-traceable): 1) `LSFileQuarantineEnabled` + `DownloadQuarantine` + row label; 2) `resumeData` plumbing + resume-retry; 3) `BrowserAuthHandler` (HTTP auth); 4) `CertExceptions` + interstitial + remove `sslBypassedHosts`.

---

## 4. Verification (nothing runs until Xcode exists)

Existing target: `oraTests` ([project.yml](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/project.yml:150)), Swift Testing style (`@Test`/`#expect`, [oraTests.swift](/Users/aflekkas/.cogenly/scratch/2026-10-22-uninstall-nook-and-ora-browsers-a9aec1d6/repos/ora/oraTests/oraTests.swift:57)). Add `ora/oraTests/DownloadsCertAuthTests.swift`:

Unit (no network, no `WKWebView`):
- `sha256Hex` against a known vector (empty input + `"abc"`).
- `CertExceptions`: allow → `isAllowed` true for same host+fingerprint; **false for same host, different fingerprint** (the anti-wildcard invariant, Pane :102-105); false for different host; `clear()` resets.
- `severity(for:)`: expired/hostname-mismatch codes → `.amber`; untrusted-root code and `nil` → `.red` (construct `CFError` via `CFErrorCreate(nil, kCFErrorDomainOSStatus, errSec…, nil)`).
- Quarantine round-trip: write temp file, `applyQuarantine`, assert `hasQuarantine == true` and read-back `kLSQuarantineTypeKey == kLSQuarantineTypeWebDownload`. Assert provenance keys only if present — **report, don't fail** (known limitation, `quarantine.md:56-64`).
- Uniquing: Ora's `createUniqueFilename` against a temp dir with collisions (existing behaviour, lock it in).

Integration / manual checklist (local fixture server, e.g. Pane's `Fixtures` approach or `python3 -m http.server` + a self-signed `openssl`/`mkcert`-less cert):
- [ ] Download a file → `xattr -p com.apple.quarantine <file>` in Terminal shows the xattr; row reads "checked by macOS". (Port of `DownloadCheck.swift:53-54` assertion.)
- [ ] Download same filename twice → second file uniquified, first untouched.
- [ ] Start a large download, kill mid-flight (or fail via fixture), retry → resumes from `resumeData` where the server supports ranges; falls back to re-download otherwise.
- [ ] 401 Basic-auth fixture → sheet appears; correct creds load; 3 wrong attempts → challenge cancelled, no loop (Pane `Scenarios.swift:146-160`).
- [ ] Self-signed/mismatched cert fixture → page does **not** load; interstitial shows (red or amber correctly), Advanced shows chain + fingerprint; Go Back returns; Continue loads; navigating away and back does **not** re-prompt (session exception); **rotating the cert on the fixture re-prompts** (fingerprint keying works); app relaunch re-prompts (session scope).
- [ ] Download from an auth-protected URL → download challenge prompt appears (not silent failure).
- [ ] Regression: normal HTTPS, Ora ad-block/password tests (`oraTests.swift`) still pass; pre-existing SwiftData store with downloads opens without migration error.

---

## 5. Risks / open questions

1. **Spec vs shipped Pane code disagree twice** (§2.2): per-profile SQLite exceptions + `URLCredentialStorage` scoping (spec) vs session in-memory + automatic per-identifier stores (code/research). Plan follows the **code**. Owner should confirm session-only exceptions are acceptable for the fork, or spec a per-Space (Ora container) store as a follow-up — Ora Spaces map to data stores, so per-Space keying would be `host|fingerprint|containerID`; not in Pane, hence not invented here.
2. **Quarantine provenance does not work** in Pane after 3 attempts (`quarantine.md:20-41`). Port asserts xattr presence only. Do not let anyone "fix" the gate by relaxing it (`quarantine.md:62-64`), and do not attempt a 4th `NSURLQuarantinePropertiesKey` variation.
3. `WKDownload` self-quarantining is **measured on macOS 26.5, undocumented** (`quarantine.md:75-97`). Ora's deployment target is macOS 15.0 (`project.yml:23`). Belt-and-braces `applyQuarantine` + `LSFileQuarantineEnabled` must both ship; verify the xattr on a 15.x machine if available.
4. **Delegate-shape mismatch**: Ora `BrowserPage` uses completion-handler delegates everywhere; Pane uses Swift's async `respondTo`. Bridging with `Task` ( §3.2) risks completion-handler-called-twice / never-called bugs. Add a `guard`/`withCheckedContinuation`-style single-fire wrapper and a unit test with a fake delegate.
5. `BrowserDownloadTask` currently uses the pre-`resumeData` `WKDownloadDelegate` failure signature (`BrowserDownloadTask.swift:59`). Switching signatures changes what WebKit calls; confirm no other conformer relies on the old one (grep shows this file is the only `WKDownloadDelegate` in Ora).
6. SwiftData additive migration for `Download` (`resumeData: Data?` etc.) — test against a store created by the unmodified build (§4). If it fails, `@Transient` + sidecar storage is the fallback; decide before shipping, not after.
7. Hand-rolled SHA-256 copied from Pane (`AuthChallengeHandler.swift:131-177`) vs CryptoKit (already available on Ora's target, one import). Copying verbatim is lower-risk for fidelity to Pane's tested code; CryptoKit is less code to audit. Pick one; if CryptoKit, the known-vector test (§4) is mandatory.
8. GPL-3.0: Ora is GPL-3.0 and the fork keeps its UI — ported Pane code lands in a GPL codebase. Confirm Pane's own licence permits this (both are the user's projects, but the plan does not assume; check `repos/pane/LICENSE` before copying verbatim).
9. No Xcode in this environment: every signature above (esp. `@MainActor` download completion handler, Pane `DownloadManager.swift:142-145`) must be compile-checked as step zero of implementation. Treat any signature surprise as a plan amendment, not an improvisation.
