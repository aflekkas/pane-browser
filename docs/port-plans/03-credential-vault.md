# 03 — Credential vault & import: porting Pane into Ora (rebranded "Pane")

Status: plan only, no code written. Nothing here compiles yet (no Xcode on this machine);
every step names its files so it can be implemented without re-deciding.

Scope: Pane's credential vault + import only. Ora's UI stays. Passkeys are entitlement
plumbing, not code (see §2.4) — no WebAuthn work is planned.

---

## 1. What Ora does today

### 1.1 Password storage — its own vault, not iCloud Keychain Passwords

`ROADMAP.md:9` lists "iCloud Keychain password autofill" under *Available Today*.
The code does not use Apple Passwords / `ASCredentialIdentityStore` at all. It is a
home-grown Keychain vault:

- `ora/ora/Features/Passwords/Services/PasswordManagerService.swift:76` — service
  `com.orabrowser.app.passwords`; `:261-271` stores `kSecClassGenericPassword` with
  `kSecAttrSynchronizable = true` and `kSecAttrAccessibleAfterFirstUnlock`. The
  "iCloud" claim reduces to "this generic item is marked synchronizable". It is not
  readable by Safari/Apple Passwords and does not participate in system AutoFill.
- Metadata (origin/host/username/dates/`containerID`) is JSON-encoded into
  `kSecAttrGeneric` (`:233-238`); the item is addressed later by
  `kSecValuePersistentRef` (`:180-186`, `:240-243`).
- Scoping: per-`TabContainer` via `containerID` in the metadata blob
  (`SavedPasswordMetadata`, `:7-16`; filter at `:537-549`), plus a legacy migration
  that re-homes unscoped items into the first container (`:551-586`).
- Matching (`:99-136`, `:435-452`): origin is `scheme://host[:port]` for **both http
  and https**; legacy host-only items also match `www.`/bare-host variants. Subdomains
  otherwise do not match.
- Read gate is app-level only: `authenticate(reason:)` runs `LAContext`
  (`.deviceOwnerAuthentication`) at `:387-401`, then `revealPassword` does a plain
  `SecItemCopyMatching` with **no access control on the item** (`:180-202`). If the
  app process is compromised, the Keychain item itself does not demand Touch ID.
- Password generation via `SecCreateSharedWebCredentialPassword` with a fallback
  generator (`:358-385`). Email suggestions and `lastUsedAt` ranking are built on the
  same store (`:138-174`).

### 1.2 Autofill flow

- `PasswordAutofillCoordinator.swift:146-177` decodes JSON bridge events
  (`focus`/`blur`/`rect`/`keyCommand`/`submit`); `:284-331` builds an overlay state,
  `:199-227` authenticates, reveals, then fills; `:347-406` handles submit →
  save prompt; `:408-435` presents the prompt as an `NSAlert` sheet.
- Save on insecure pages is allowed with a warning ("Save Anyway"),
  `savePromptDetails` at `:574-608`. Existing tests pin this behaviour
  (`oraTests/oraTests.swift:84-99`).
- Provider indirection exists but only Ora is live; 1Password/Bitwarden descriptors
  are commented out (`PasswordManagerProviderRegistry.swift:51-66`).

### 1.3 Content world — the important finding

**All Ora injected scripts run in the page world.** `BrowserUserScript`
(`ora/ora/Core/BrowserEngine/BrowserEngineTypes.swift:15-20`) has no content-world
field, and `BrowserPage.swift:62-67` constructs `WKUserScript` with the 3-argument
initializer, which defaults to `WKContentWorld.pageWorld`. The password script is
registered the same way (`OraBrowserScripts.swift:20-29`, `.atDocumentEnd`,
main-frame only). Consequences, visible in the code:

- `password-manager.js:7` reads `window.webkit.messageHandlers.passwordManager`
  from page-visible JS; any page script can find and call that handler.
- Fill goes back through page-world `evaluateJavaScript`
  (`PasswordAutofillCoordinator.swift:495-508` calls `window.__oraPasswordManager.*`;
  `BrowserPage.swift:154-156` is the default-world evaluate).
- The bridge message is a JSON string parsed natively (`TabBrowserPageDelegate.swift:120-122`).

This is exactly the posture Pane's invariants forbid (see §2.3). It is the single
largest security delta in this port.

### 1.4 Import — tabs only, no credentials

- `Importer.swift:153-165` reads `~/Library/Application Support/Arc/StorableSidebar.json`
  directly; `inspectItems` (`:187-271`) extracts spaces/tabs/favourites only.
- `ImportDataButton.swift:92-103`: "Arc" works; **"Safari" and "Chrome" buttons are
  empty commented stubs**. There is no password/CSV import anywhere in Ora.

### 1.5 UI surfaces that already exist (reuse, don't rebuild)

- Autofill overlay: `ora/ora/Features/Browser/Views/PasswordAutofillOverlayView.swift`
  (320pt card, `BlurEffectView(.popover)`, anchored at the field rect, `:12-32`).
- Management window: `Passwords/Views/PasswordsWindow.swift` (SwiftUI, themed via
  `.withTheme()`, Touch ID unlock gate, search, per-container filter).
- Settings section: `Features/Settings/Sections/PasswordsSettingsView.swift`.
- Save prompt: `NSAlert` sheet (above). Settings flags already exist in
  `SettingsStore.swift:240-257` (`passwordsEnabled`, `passwordAutofillEnabled`,
  `passwordAutofillSubmitEnabled`, `passwordSavePromptsEnabled`) plus per-host
  "never" suppression (`:476-482`).

---

## 2. What Pane does — security rules, quoted

Sources: Pane `CLAUDE.md`, `docs/pane-browser-spec.md` §7, ADR 0003/0004/0007,
`docs/research/2026-08-07-credentials.md`. Rule for this whole area, `CLAUDE.md:29-31`:

> "Do not guess on security. Keychain access control, passkey RP-ID validation,
> download quarantine xattrs, cert exception scoping — check the spec, check
> `docs/research/`, or ask. Never infer."

Anything below that the sources do not settle is marked **OPEN QUESTION**, not filled in.

### 2.1 Storage (spec §7, "Passwords (your own vault)")

> "one `kSecClassInternetPassword` keychain item per credential, in the app's own
> keychain access group, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
> `SecAccessControlCreateWithFlags(.userPresence)` so reads require Touch ID."
> "`kSecAttrServer` = origin, `kSecAttrAccount` = username, `kSecAttrLabel` carries
> the profile UUID so vaults are per-profile."

Implemented in `Sources/PaneCore/CredentialVault.swift`:

- Service `com.aflekkas.pane.vault` (`:59`); save at `:110-146`, read at `:153-182`,
  list (attributes only, no prompt) at `:187-222`, delete at `:224-239`.
- Writes deliberately do **not** require Touch ID — "the secret is already in the
  page" (`:107-109`) — and updates delete-then-add so changing a password never
  prompts to read the old value (`:139-142`).
- `.userPresence`, explicitly **not** `.biometryCurrentSet`, which "invalidates every
  item the moment the user adds a fingerprint" (`:125-127`).
- Read passes `kSecUseOperationPrompt` and an optional shared `LAContext` so a batch
  prompts once (`:150-165`); `errSecUserCanceled`/`errSecAuthFailed` →
  `VaultError.userCancelled` (`:175-176`).

### 2.2 Origin policy (the rule a bug would silently break)

`CredentialVault.originKey` (`CredentialVault.swift:244-249`): **host only; https
only**, except `localhost`/`127.0.0.1`; non-default port is part of the key;
default 443 is not. Comment at `:241-243`:

> "a credential saved on https must never be offered to the same host over http,
> because an attacker who can serve plaintext could then harvest it."

Subdomains are distinct origins — never share up or down (pinned by
`Sources/PaneCheck/VaultChecks.swift:34-38`). This is stricter than Ora on three
axes: Ora allows http storage, `www.` fallback, and full-origin keys.

### 2.3 Content-world isolation (`CLAUDE.md:28`)

> "Injected JS lives in an isolated `WKContentWorld`, never the page world."

`CredentialBridge.swift:8-17`: world `pane.credentials`, handler `paneCredentials`;
script at `.atDocumentEnd`, **main frame only** — "offering the page's credentials to
[a third-party iframe] would be a handout" (`:26-28`). Fill returns via
`callAsyncJavaScript … in: CredentialBridge.world`
(`Sources/PaneWeb/WKWebEngine.swift:104-115`) using the native value setter plus
`input`/`change` events so controlled inputs notice (`CredentialBridge.swift:79-97`).
Native UI only: "a credential UI drawn by the renderer could be forged"
(`Sources/PaneUI/CredentialPrompt.swift:7-8`; also `CLAUDE.md:23-25`).

### 2.4 Passkeys — write zero code (ADR 0003, ADR 0004)

ADR 0003: "Delete the shim entirely. Write zero WebAuthn code." An isolated-world
`navigator.credentials` override is invisible to page script; in the page world it
"can detect and subvert it — a worse security posture than not shipping the feature."
With `com.apple.developer.web-browser.public-key-credential`, "WebKit's own
`WebAuthenticatorCoordinatorProxy` handles `navigator.credentials.create/get`
natively". **RP-ID validation is therefore WebKit's job, not ours** — the spec's old
"validate the RP ID yourself" instruction is superseded and must not be reintroduced.
ADR 0004: the entitlement is macOS 13.3+, Apple-reviewed, needs Account Holder on an
**organization** account (D-U-N-S) and a browser that already passes review; without
it, passkeys work only for `associated-domains` RPs. Also from `CLAUDE.md:170-172`:
"There is no way to read the user's existing Safari passwords… The only sanctioned
path is a one-time user-initiated `ASCredentialImportManager` FIDO CXP import
(macOS 26+)." → **OPEN QUESTION:** adopt CXP import later, or CSV-only? Not decided
by any source; out of scope here.

### 2.5 Protection must be stated, not assumed (ADR 0007)

Measured: `SecAccessControl(.userPresence)` and the data-protection keychain fail
with `errSecMissingEntitlement (-34018)` without a real signing identity, and adding
`keychain-access-groups` to an ad-hoc build makes launchd refuse to spawn the app.
Decision (option 3): probe once with a real throwaway write
(`CredentialVault.swift:83-101`) → `.userPresence` or `.deviceUnlockedOnly`, and
"Any UI that surfaces the vault must show the degraded state". The save prompt
states the level at decision time (`CredentialPrompt.swift:23-33`). Silent fallback
was "rejected outright".

### 2.6 Import (spec §7: "not optional")

`Sources/PaneCore/CredentialImport.swift`: Safari CSV (`Title,URL,Username,Password,
Notes,OTPAuth`) and Chrome CSV (`name,url,username,password,note`) matched **by
header name, never position** (`:40-63`); RFC-4180 quoting incl. embedded commas/
newlines/`""` (`:92-128`); 1Password `.1pux` unzipped via `/usr/bin/unzip`
(`:135-192`); non-https rows skipped **with a named reason** (`:77-83`); unknown
headers fail loudly (`:57-62`).

---

## 3. Recommendation: combine — keep Ora's shell, replace its engine

| Layer | Verdict | Why |
| --- | --- | --- |
| Storage + origin policy | **Replace** with Pane's vault | Item-level Touch ID beats app-level gate; https-only, no `www.` bleed |
| Bridge content world | **Replace** (page → isolated) | §1.3 is the exploitable gap; Pane's leak test proves the fix |
| Coordinator + overlay + windows | **Keep** Ora's | Richer than Pane's `NSAlert` picker; UI must stay as-is |
| Save-prompt | **Keep** Ora's sheet, add ADR 0007 line | Same shape; must state protection level |
| Password import | **Add** Pane's parser | Ora has none; Safari/Chrome buttons are stubs waiting for it |
| Passkeys | **Keep** entitlement, write no code | ADR 0003/0004; Ora already declares it (§4) |
| Email suggestions, generated passwords, `lastUsedAt` | **Keep** (Ora-only features) | Pane has no equivalent; dropping them is a regression |

Rejected: (a) keep Ora's vault and just move the script to an isolated world —
leaves synchronizable, non-access-controlled items and http storage in place;
(b) wholesale Pane UI (`NSAlert` picker) — violates "Ora's UI stays as-is".

### 3.1 Concrete steps (in order; each is independently reviewable)

1. **Engine: teach scripts about worlds.** Add an optional `contentWorldName` to
   `BrowserUserScript` (`BrowserEngineTypes.swift:15-20`); in `BrowserPage.swift:61-68`
   use `WKUserScript(source:injectionTime:forMainFrameOnly:in: .world(name:))` when set,
   and register the `passwordManager` handler with
   `addScriptMessageHandler(_:contentWorld:name:)` instead of `add(_:name:)`
   (`:58-60`). Default stays page world for the other scripts (no behaviour change).
   Add a matching `evaluateJavaScript(_:inWorld:)` / `callAsyncJavaScript` path on
   `BrowserPage` (`:154-156`) for the fill return trip.
2. **New vault file (copy, then adapt).** Add
   `ora/ora/Features/Passwords/Services/CredentialVault.swift` copied from Pane
   `CredentialVault.swift` with only these adaptations: service string → **OPEN
   QUESTION** (§6.1; placeholder `com.pane.vault` until bundle ID is fixed);
   `profileID: String` → Ora `containerID: UUID?` (store `uuidString` in
   `kSecAttrLabel`, `""` for unscoped); keep probe, delete-then-add, error enum.
   Do not add timestamps/`lastUsedAt` to the Keychain item — keep those in a small
   non-secret metadata sidecar only if step 4 needs them (see risk §6.4).
3. **Rewire `PasswordManagerService` onto the vault.** Keep its public API
   (`matchingEntries`, `revealPassword`, `upsertCredential`, `delete`,
   `emailSuggestions`, `generateStrongPassword`, `authenticate`) so the coordinator,
   overlay, window and settings compile unchanged; reimplement internals over
   `CredentialVault`. `revealPassword` now triggers the item's own Touch ID prompt —
   delete the now-redundant pre-auth in
   `PasswordAutofillCoordinator.swift:203-205` and in
   `PasswordsWindow.swift:423` / `PasswordsSettingsView.swift:399` (keep one
   `LAContext` shared per batch via the vault's `context:` parameter). One-time
   migration: on first launch read legacy `com.orabrowser.app.passwords` items,
   write them into the new vault, delete the old item only after the new write
   succeeds; http-origin legacy entries are **not** migrated silently — list them
   in the import report (step 5) for a user decision.
4. **Bridge script: replace, keeping Ora's richer detection.** New
   `ora/ora/Resources/WebScripts/password-manager.js`: keep Ora's field heuristics
   (username/new-password classification, field IDs, rect + keyboard events) but run
   it in the isolated world from step 1, rename the exposed fill entry to
   Pane's pattern (`window.__paneFill`-equivalent, e.g. `__oraFill`), and have fill
   called via `callAsyncJavaScript` in that world (Pane `WKWebEngine.swift:104-115`
   is the reference, including its read-back verification). Keep the bridge payload
   types in `PasswordAutofillCoordinator.swift:22-73`; add a closed native parse
   (Pane `LoginFormInfo`, `CredentialBridge.swift:119-138`) so page-supplied JSON is
   validated field-by-field. Main-frame only stays.
5. **Import: copy Pane's parser, wire Ora's stubs.** Add
   `ora/ora/Features/Passwords/Services/CredentialImport.swift` copied from Pane
   `CredentialImport.swift` unchanged except the `originKey` reference. Add an
   "Import Passwords…" action (file picker → parse → vault writes → report sheet
   showing imported count + every `skipped` reason) and point the existing Safari /
   Chrome stubs (`ImportDataButton.swift:96-102`) at it; 1Password `.1pux` joins the
   same picker by extension. Reuse the Arc importer's container choice: imported
   credentials land in the currently selected container.
6. **Prompt copy (ADR 0007).** In `PasswordAutofillCoordinator.savePromptDetails`
   (`:574-608`) append Pane's protection sentence (`CredentialPrompt.swift:27-33`):
   `.deviceUnlockedOnly` → "readable by Pane whenever your Mac is unlocked… never
   synced"; else "Reading it later will require Touch ID." Also surface the level in
   `PasswordsSettingsView` header. Keep Ora's insecure-page warning, but note the
   new policy: http pages get no autofill and no save (the warning path becomes
   unreachable for storage; keep the copy only for the migration report in step 3).
7. **Rebrand strings in this area only where the vault touches them:** service
   string (step 2), prompt copy ("Ora" → "Pane"), `PasswordManagerProviderRegistry`
   title "Ora Passwords" (`:45`). Bundle-ID rename itself is a separate plan.
8. **Delete** the synchronizable generic-password write path and `SecItemUpdate`
   update path in `PasswordManagerService` once migration (step 3) ships; keep
   `PasswordManagerError` mapped from `VaultError` for existing UI error display.

### 3.2 How Pane's prompt should look in Ora's design

Pane's UI is two `NSAlert`s (`CredentialPrompt.swift:15-57`) — do **not** copy them.
Keep: Ora's SwiftUI overlay (`PasswordAutofillOverlayView`, blur card, hover/keyboard
selection) for picking; Ora's `NSAlert` sheet for save/update (same buttons:
Save/Update, Not Now, Never for This Site); `PasswordsWindow` for management.
Only the *copy* and the *gate* come from Pane: protection-level sentence (step 6)
and single-credential direct fill (Pane `:41-45`: "a menu of one is a speed bump" —
Ora's overlay already effectively does this; keep it).

---

## 4. Entitlements & signing (`project.yml`)

Current state: `project.yml` entitlements properties and `ora/Info/ora.entitlements`
already declare `com.apple.developer.web-browser.public-key-credential: true`
(and `com.apple.developer.web-browser`, which ADR 0004 notes is iOS-only and inert
on macOS — harmless, leave it). App Sandbox is on. **No `keychain-access-groups`
anywhere** — today the vault works only because legacy generic-password items don't
need it.

Required change (both places, they must stay in sync):

```yaml
keychain-access-groups:
  - "$(AppIdentifierPrefix)<NEW_BUNDLE_ID>"   # value is OPEN QUESTION §6.2
```

Notes:

- Without this group, the first `SecAccessControl` write returns `-34018` and the
  vault silently degrades to `.deviceUnlockedOnly` (probe handles it, UI must say so).
- Ora signs with a real Developer ID team (`DEVELOPMENT_TEAM: 3Y566D2A4G`, Manual,
  `project.yml` Debug/Release), unlike Pane's ad-hoc dev builds — so the ADR 0007
  launch-refusal failure mode should not occur; still gate the entitlement change
  behind a launch smoke test on a clean machine/profile before shipping it.
- Keep the keys in `ora.entitlements` only; `ora-debug.entitlements` (Inject/hot
  reload) must not gain the group unless Debug signing is verified to honour it.
- No `associated-domains` addition in this plan. Add `webcredentials:` only when
  testing passkeys against a controlled RP before the entitlement grant (ADR 0004).
- Rebrand changes `PRODUCT_BUNDLE_IDENTIFIER` (`com.orabrowser.app` today) — the
  access group and vault service string must change in the same commit, or existing
  users' vaults become unreachable (see §6.1).

---

## 5. Verification (port of Pane's checks)

Xcode is absent, so nothing runs today; write the tests with the code so the first
Xcode session is mechanical. Ora uses Swift Testing (`oraTests/oraTests.swift`).

1. **Port `VaultChecks.swift` 1:1** into `oraTests` as `@Test`s against
   `CredentialVault.originKey`: https→host, http→nil, localhost/loopback exempt,
   `:8443` kept, `:443` dropped, subdomain ≠ parent. (Ora's existing
   `normalizedOrigin` tests at `oraTests.swift:63-75` pin the *opposite* http
   behaviour — update them deliberately in the same commit, with the §2.2 quote as
   the commit rationale; do not just make them pass.)
2. **Port `ImportChecks.swift` 1:1** (7 suites): Safari/Chrome detection, by-name
   columns incl. password-before-username, quoted comma/newline/`""` passwords,
   non-https skipped-with-reason, bare-host/malformed rows, unknown header fails
   loudly. Pure `Foundation` — these run headless with no Keychain.
3. **Vault round-trip** (Pane `VaultChecks.swift:41-68`): save two, list without a
   secret read, cross-container isolation, delete. Runs against the real Keychain;
   keep it out of CI if the runner is ad-hoc signed (protection will be
   `.deviceUnlockedOnly` — assert that branch explicitly rather than skipping).
4. **Bridge leak test** (port of `Sources/PaneHarness/VaultCheck.swift`): load a
   fixture login page in a real `WKWebView`; assert (a) form detected, (b) page-world
   probe `typeof window.__oraFill` / `messageHandlers.passwordManager` is
   **undefined**, (c) fill via the isolated world reads back correctly from the page
   world. (b) is the security assertion; a pass without it proves nothing.
5. **Manual, un-automatable** (state this in the PR, per ADR 0007's honesty rule):
   with a Developer-ID build, save a credential, lock/unlock, autofill and confirm
   exactly one Touch ID prompt per fill, none on save, none on list. Secret *reads*
   cannot be covered headlessly — do not claim coverage for them.
6. Existing Ora tests (`oraTests.swift:77-123`: generation, prompts, email,
   suggestion filtering) must still pass against the rewired service (step 3.3).

---

## 6. Risks & open questions

1. **OPEN QUESTION — bundle ID & vault identity.** Rebrand target bundle ID is not
   specified in either repo. Vault service string, `keychain-access-groups` value and
   the legacy-migration source all depend on it. Decide before step 3.2; changing it
   after users have vaults orphans them (items are addressed by service+group).
2. **OPEN QUESTION — access-group string form.** Pane's release file uses a bare
   `com.aflekkas.pane`; TN3137-style team-prefixed `$(AppIdentifierPrefix)<id>` is
   the other common form. Sources read here do not settle which Ora's provisioning
   profile will honour. Resolve by a signed probe build asserting
   `availableProtection == .userPresence`, not by documentation alone.
3. **Behaviour break: http & `www.` matching disappear.** Existing Ora users with
   http-saved or host-only credentials lose autofill under §2.2. Mitigation is the
   migration report (step 3.3), not a matching exception — do not re-add `www.`
   fallback "temporarily"; that is precisely the harvest vector the rule exists for.
4. **Metadata loss.** Pane's item has no room for `createdAt`/`lastUsedAt`/email-
   suggestion ranking. Options: (a) drop the features, (b) non-secret sidecar
   (SwiftData/UserDefaults keyed by origin+username). (b) leaks *which sites* a user
   has accounts on to anyone reading the sidecar — acceptable? **OPEN QUESTION** for
   the user; default to (b) with host+username only, never passwords, flagged in UI.
5. **`.1pux` under App Sandbox.** Pane shells to `/usr/bin/unzip`
   (`CredentialImport.swift:151-153`); Ora is sandboxed with only
   user-selected read access. Whether `Process` to `/usr/bin/unzip` survives the
   sandbox must be tested on a signed build; fallback is a minimal in-process ZIP
   reader for `export.data` only. Do not assume either way.
6. **Double Touch ID prompts.** Ora currently authenticates in the coordinator *and*
   would prompt again at the item. Step 3.3 removes the app-level gate; if any call
   site is missed the user gets two prompts and will blame the vault. Grep for
   `authenticate(reason:` at the end of the step and account for every hit.
7. **Profile semantics differ.** Pane `kSecAttrLabel` = profile UUID string; Ora
   scopes by `TabContainer.id` with a nil-container legacy class. Mapping nil →
   `""` label is a choice made in step 3.2; private (ephemeral) tabs must never
   write — Ora already guards `isPrivate == false`
   (`PasswordAutofillCoordinator.swift:289,352`); keep both guards.
8. **GPL-3.0.** Ora is GPL-3.0 and Pane is the user's own earlier code; copying
   Pane files into the fork is unproblematic, but keep Pane's spec-citation header
   comments (they carry the security rationale) rather than stripping them.
9. **Not verified here:** any claim about what a signed Ora build's Keychain
   actually honours. The probe pattern exists precisely because entitlements on
   disk ≠ behaviour; §5.5 is a shipping gate, not a formality.
