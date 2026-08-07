# WebKit gotchas

## `callAsyncJavaScript` and the three-argument `evaluateJavaScript` return `Void`

**Found:** 2026-08-07, macOS 26.5.2. Cost about an hour, chasing a feature that
was already working.

```swift
// Returns the value. Fine.
let t: Any? = try await webView.evaluateJavaScript("document.title")
// -> Optional("Sign in")

// Returns Void, whatever the JS actually returns.
let a: Any? = try await webView.evaluateJavaScript("document.title", in: nil, in: world)
// -> Optional(())
let b: Any? = try await webView.callAsyncJavaScript("return document.title;",
                                                    arguments: [:], in: nil, in: world)
// -> Optional(())
```

Swift resolves the world-scoped calls to a `Void`-returning overload, so
`result as? Bool` and `as? String` are always `nil`.

**Why this was expensive:** the credential fill *worked*. The JS ran, the DOM
was written, the password field held the right value — and `fillCredentials`
returned `false` because it trusted the return value. The verification check
then reported "fill returned false" on a feature that was fine, which sent me
looking for a bug in world isolation that did not exist.

**The rule:** never trust the return value of a world-scoped JS call. Perform
the action there, then **confirm by reading state back** through the
one-argument `evaluateJavaScript`. In this case reading from the *page* world
is better than the isolated one anyway: it proves the isolated world's DOM
write actually crossed the boundary, which is the property that matters.

## An unparented WKWebView still runs scripts

Worth knowing, since it briefly looked like the cause: a `WKWebView` that is
never added to a window does navigate, does run user scripts, and does execute
`evaluateJavaScript`. Adding it to an offscreen window changes nothing here.
The `Optional(())` results were the overload, not the view hierarchy.

## Isolated worlds: DOM crosses, globals do not

Confirmed by measurement, not just by reading the docs:

- A `window.*` function defined in an isolated world is **invisible** to page
  script (`typeof window.__paneFill` is `undefined` in the page world) — which
  is exactly the security property the credential bridge needs.
- DOM reads and writes from that world **do** affect the real document.

This is the same asymmetry that killed §7's `navigator.credentials` shim
(ADR 0003): you cannot override a page global from an isolated world, because
the page never sees it.
