# 0007 — The vault states its actual protection level

**Status:** accepted · 2026-08-07 · implements spec §7

## Context

§7 requires `SecAccessControlCreateWithFlags(.userPresence)` so reading a stored
password needs Touch ID. Measured on this host:

| Keychain path | Unsigned / ad-hoc |
| --- | --- |
| Plain `kSecClassInternetPassword` | **OK** |
| `+ kSecAttrAccessible` | **OK** |
| `+ SecAccessControl(.userPresence)` | **FAIL** `errSecMissingEntitlement` (-34018) |
| `kSecUseDataProtectionKeychain: true` | **FAIL** (-34018) |

`SecAccessControl` forces the data-protection keychain, which requires
`keychain-access-groups`. Adding the entitlement is not enough: ad-hoc signing
(`codesign --sign -`) is still rejected, because the group needs a team
identifier from a real signing identity. Verified — the entitlement is present
in the ad-hoc-signed bundle and the write still fails.

So **a development build cannot gate reads on Touch ID.**

## Options

1. Require a paid Developer ID before the vault works at all.
2. Silently fall back to a weaker keychain item.
3. Fall back, but make the actual protection level explicit everywhere.

## Decision

Option 3.

`CredentialVault.availableProtection` is probed once at startup by attempting a
real access-controlled write to a throwaway item. Asking the keychain is the
only reliable answer — inspecting the binary's entitlements tells you what was
requested, not what the OS honours.

- `.userPresence` — reads require Touch ID / Watch / login password.
- `.deviceUnlockedOnly` — readable by this app whenever the Mac is unlocked.
  Still device-only, still `WhenUnlockedThisDeviceOnly`, still never synced.
  **No biometric gate.**

Option 2 is rejected outright. **A vault the user believes is biometrically
protected but is not is worse than one that says so** — it invites them to store
things they otherwise would not. Any UI that surfaces the vault must show the
degraded state; that is a requirement of this decision, not a nicety.

Option 1 was rejected because it makes the whole of §7 untestable and
unbuildable until a business relationship exists, which is the same trap ADR
0004 avoids for passkeys.

## Consequences

- The vault is usable and testable today, storing real credentials.
- Shipping requires a Developer ID for the Touch ID gate; that is one signing
  change, not a code change, because the write path already branches.
- 112 headless assertions cover origin policy, per-profile isolation and the
  save/list/delete round trip. They do **not** cover reading a secret, because
  a read prompts for user presence and cannot run unattended — stated here so
  the coverage is not mistaken for more than it is.

## Addendum 2026-08-07: the entitlement also prevents launching

Worse than "the entitlement does not help": **it actively breaks the app.**

Isolated one at a time on macOS 26.5.2, ad-hoc signed:

| Entitlements | Result |
| --- | --- |
| none | app **launches** |
| `keychain-access-groups` | **launchd refuses to spawn it** — `RBSRequestErrorDomain 5`, POSIX 163 |
| `+ com.apple.developer.web-browser.public-key-credential` | same failure |

Ad-hoc signing cannot satisfy an entitlement requiring a team identifier, and
rather than being ignored the entitlement makes the binary un-launchable.

So a development build must carry **no entitlements at all**. Not "the ones
that work" — none.

This strengthens the case for this ADR rather than weakening it. Option 1
(require a Developer ID before the vault works) would have meant the app could
not even start on a machine without one. The probe-and-declare design means it
runs, stores credentials, and tells the user exactly what protection they are
getting.

`Scripts/bundle.sh` uses `Resources/Pane.entitlements` (empty) by default and
`Resources/Pane-release.entitlements` (the full set) under `PANE_RELEASE=1`.
