# 0004 — Passkeys are gated on an organization Apple Developer account

**Status:** accepted · 2026-08-07 · corrects spec §8

## Context

Spec §8 claims Pane needs `com.apple.developer.web-browser`, and that this is
also what allows being set as default browser.

## Decision

Two separate corrections.

**`com.apple.developer.web-browser` is iOS/iPadOS 14.0 only.** There is no macOS
variant. It gates nothing here. Default-browser registration on macOS is
`CFBundleURLTypes` for http/https plus
`NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`. No entitlement.

**The entitlement that does matter is
`com.apple.developer.web-browser.public-key-credential`** (macOS 13.3+). It is
the only way a `WKWebView` browser can do WebAuthn for arbitrary relying
parties. Without it, passkeys work only for RP IDs declared in
`com.apple.developer.associated-domains`.

It is a managed capability requiring:

- the **Account Holder role on an organization** Apple Developer account
  (which requires a D-U-N-S number),
- a request at `developer.apple.com/contact/request/macos-browsers-passkeys/`,
- and passing Apple's published review criteria, which include that the app
  presents a URL field / web search / curated bookmarks on launch and navigates
  correctly.

It is a *restricted* entitlement, so it needs a provisioning profile. It is
unreachable with ad-hoc signing and unreachable with a free Apple ID.

## Consequences

- **Pane must already be a credible browser before it can apply.** This is why
  passkeys are built last rather than early — the ordering is forced by Apple's
  review criteria, not by preference.
- Milestone F is verified against an RP ID on a domain we control, via
  Associated Domains. The entitlement later widens the *same working code* to
  every site, so nothing is stubbed and nothing waits.
- Build it feature-flagged, behind a protocol with a no-op implementation.
- Calendar risk: weeks to never. It must not block any other milestone.
