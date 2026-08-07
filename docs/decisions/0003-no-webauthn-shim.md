# 0003 — No `navigator.credentials` shim; WebKit does WebAuthn

**Status:** accepted · 2026-08-07 · reverses spec §7

## Context

Spec §7 plans to shim `navigator.credentials.create` and `.get` in an isolated
`WKContentWorld`, marshal options to native, drive `ASAuthorizationController`,
and reconstruct the `PublicKeyCredential` shape in JS.

## Decision

Delete the shim entirely. Write zero WebAuthn code.

**It cannot work.** `WKContentWorld` documentation, verbatim: *"The content world
doesn't apply to the current document or DOM of a webpage… The content world
affects only references to other JavaScript variables."* An override of
`navigator.credentials` in an isolated world is structurally invisible to page
scripts. It would have to live in `WKContentWorld.page`, where a hostile page
can detect and subvert it — which is a worse security posture than not shipping
the feature.

**It is also unnecessary.** With
`com.apple.developer.web-browser.public-key-credential`, WebKit's own
`WebAuthenticatorCoordinatorProxy` handles `navigator.credentials.create/get`
natively and talks to AuthenticationServices directly.

## Consequences

- Milestone F is entitlement plumbing and UI, not a WebAuthn implementation. We
  do not write CBOR, clientDataJSON, attestation parsing, or PRF/largeBlob
  extension handling — all of which we would have done worse than WebKit.
- Risk moves from engineering to Apple business approval. See ADR 0004.
- The spec's warning to "validate the RP ID yourself" no longer applies, because
  we are no longer the ones asserting. WebKit validates.
