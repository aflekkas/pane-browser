# Passkeys — what is built and what is blocked

## What Pane does

**Nothing.** That is the correct amount (ADR 0003).

With `com.apple.developer.web-browser.public-key-credential`, WebKit's own
`WebAuthenticatorCoordinatorProxy` handles `navigator.credentials.create` and
`.get` inside `WKWebView` and talks to AuthenticationServices directly. Pane
writes no CBOR, no clientDataJSON, no attestation parsing, no PRF/largeBlob
extension handling — all of which it would do worse than WebKit.

The entitlement is declared in `Resources/Pane.entitlements`. That is the
entire implementation.

## Why §7's JS shim was deleted

The spec planned to shim `navigator.credentials` in an isolated
`WKContentWorld`. That cannot work, and measurement confirmed it
(`docs/api-notes/webkit.md`): an isolated world has its own global object, so a
`navigator.credentials` override there is **invisible to page script**. It
would have to live in `WKContentWorld.page`, where a hostile page can detect and
subvert it — a worse posture than not shipping the feature.

## What is blocked, and on what

The entitlement is **Apple-reviewed** and, per Apple's own text, requires:

- the **Account Holder** role on an **organization** Apple Developer account
  (an individual account cannot obtain it),
- which requires a **D-U-N-S number**,
- a request at `developer.apple.com/contact/request/macos-browsers-passkeys/`,
- and passing published criteria that require the app to **already behave as a
  browser**: `http` and `https` declared in `CFBundleURLTypes`, a URL field or
  search on launch, correct navigation.

**Pane satisfies the technical criteria today.** The blocker is the account
type. This is the only Apple-approval dependency in the project — ADR 0004 has
the detail.

## Verifying before any grant arrives

Without the entitlement, WebKit still does WebAuthn — restricted to relying
parties covered by `com.apple.developer.associated-domains`. So:

1. Serve `/.well-known/apple-app-site-association` on a domain you control,
   with a `webcredentials` entry for the app's team-prefixed bundle ID.
2. Put that domain in the `associated-domains` entitlement (currently the
   placeholder `pane.invalid`).
3. Register and assert a passkey against it in Pane.

That exercises the **same code path** the entitlement later widens to every
site. Nothing is stubbed and nothing waits on Apple — which is why passkeys
were built rather than deferred.

## Order of operations when you are ready

1. Confirm the developer account is an **organization**, not an individual.
   Check this first; it costs a minute and it is the thing that blocks.
2. Get a real signing identity. It is needed for the vault's Touch ID gate too
   (ADR 0007), so the two unblock together.
3. Submit the passkey entitlement request.
4. Until granted, verify against your own domain as above.
