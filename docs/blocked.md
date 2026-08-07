# Blocked and deferred

Things that are **not** engineering problems, or are deliberately postponed.
Kept separate from `PROGRESS.md` so a phase never looks incomplete because of
something no amount of code will fix.

## Blocked on an Apple Developer account

### Touch ID for the password vault

**Blocker:** `SecAccessControl(.userPresence)` forces the data-protection
keychain, which needs `keychain-access-groups`, which needs a **real signing
identity**. Ad-hoc signing is rejected with `errSecMissingEntitlement (-34018)`
*even with the entitlement present in the bundle*.

Worse: the entitlement makes an ad-hoc-signed app **un-launchable** — launchd
refuses to spawn it (`RBSRequestErrorDomain 5`, POSIX 163). So dev builds carry
no entitlements at all.

**Meanwhile:** the vault works and stores real credentials, running
`deviceUnlockedOnly` and saying so in the save dialog. See ADR 0007.

**To unblock:** any paid Apple Developer account (individual is enough here).
Then `PANE_RELEASE=1 ./Scripts/bundle.sh` picks up
`Resources/Pane-release.entitlements`. One signing change, no code change — the
write path already branches on the probed protection level.

### Passkeys for arbitrary sites

**Blocker:** `com.apple.developer.web-browser.public-key-credential` is
Apple-reviewed and needs the **Account Holder role on an ORGANIZATION** account,
which needs a **D-U-N-S number**. An individual account cannot get it.

**Meanwhile:** the entitlement is declared in
`Resources/Pane-release.entitlements`. With it, WebKit does all the WebAuthn —
Pane writes none (ADR 0003). Pre-grant, it can be verified against a domain we
control via `associated-domains`, exercising the *same* code path.

**Check first:** whether the account is an organization. It costs a minute and
it is the thing that blocks. Runbook: `docs/runbooks/passkeys.md`.

### Notarization and distribution

Needs a Developer ID and `notarytool`. Nothing is built for this yet — the app
runs locally because a locally built bundle carries no quarantine xattr.

## Deferred by choice

### Download provenance URLs

`kLSQuarantineOriginURLKey` / `DataURLKey` — the "downloaded from" attribution.
Three approaches failed; the URLs live in the LaunchServices events database,
not the xattr, and Arc's own rows are empty too.

**The security property is unaffected**: quarantine is present and Gatekeeper
prompts. This only changes the prompt's wording.
`docs/api-notes/quarantine.md` says explicitly not to try a fourth variation of
`NSURLQuarantinePropertiesKey`, and what to investigate instead.

### DRM playback against real services

The probe proves the CDM is reachable — all four `com.apple.fps` variants, no
entitlement. It does **not** prove Netflix, Disney+ or Apple TV+ will play;
those gate on user agent and licence-server policy in ways a capability check
cannot see. Needs manual testing with real accounts.

### Find bar styling

Uses the raw `NSTextFinder` bar. Styling it means either living with AppKit's
appearance or building a custom find UI, and `WKFindResult` exposes only
`matchFound: Bool` — no total, no index — so a "3 of 17" counter is impossible
with public API anyway.

### Sidebar auto-hide / hover-reveal

On the Arc parity list but genuinely a **feature**, not a proportion. Adding it
needs an explicit decision, per the rule that scope only shrinks unasked.

## Not blocked, just not done

Tracked in `PROGRESS.md` and `docs/ui-parity.md`:

- Per-space accent applied to more than the selection pill
- Empty states (a space with no tabs)
- Window focus/blur dimming
- 1Password `.1pux` import is written but never run against a real export
