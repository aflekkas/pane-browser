# Toolchain gotchas

Things learned the hard way. Written at the moment of discovery so the hour is
only paid once.

## Neither swift-testing nor XCTest ships with Command Line Tools

**Found:** 2026-08-07, macOS 26.5.2, CLT 26.5, Swift 6.3.3.

`import Testing` fails with `no such module 'Testing'`, and there is no
`XCTest.framework` in `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/`.
Both ship with full Xcode, not CLT. So **`swift test` cannot work at all** on a
machine with only Command Line Tools installed.

**Why this matters more than it looks.** The whole point of the verification
design (ADR 0006) is that the agent can prove its own work on a bare machine.
Making the unit-test layer depend on a 10GB GUI install would defeat that: a
fresh clone on a new machine could not run its own gate.

**What we do instead.** A `PaneCheck` executable target and an `Expect` type in
`PaneHarness` — a dependency-free assertion runner that counts assertions and
exits nonzero. `Scripts/gate.sh` runs `.build/debug/PaneCheck`, not `swift test`.

This is the same principle as ADR 0006 applied one level down, and it has a
second benefit: `Expect` counts assertions, so a suite that asserts nothing
fails. `swift test` would happily report a green empty suite.

**Do not "fix" this by adding swift-testing as a package dependency** — it would
be the first entry against a zero-dependency budget, to replace something that
already works.

## The macOS 26.5 SDK is present even without Xcode

`/Library/Developer/CommandLineTools/SDKs/` contains `MacOSX15.sdk`,
`MacOSX15.4.sdk`, `MacOSX26.sdk` and `MacOSX26.5.sdk`.

This is why macOS 26-only API (Liquid Glass, milestone G) can be **compiled
against** while the deployment target stays at macOS 14, behind
`if #available(macOS 26, *)`. There is no need to choose between the glass and
the deployment target.

AppKit, WebKit, AuthenticationServices, Security, LocalAuthentication,
UniformTypeIdentifiers and CoreServices are all present in the CLT SDK.

## Swift 6 strict concurrency: isolate the protocol, not the implementation

**Symptom:** `main actor-isolated instance method 'load' cannot satisfy
nonisolated requirement`.

A `@MainActor` type conforming to a nonisolated protocol fails in Swift 6
language mode. The fix that is *wrong* is scattering `nonisolated` or
`MainActor.assumeIsolated` at each conformance point.

**The fix:** mark the **protocol** `@MainActor`. Everything wrapping
AppKit/WebKit is main-actor-isolated in the macOS 26 SDK anyway, so isolating
the protocol keeps the test fake on the same actor as the real engine — which
means the checks exercise the real isolation rules rather than a laxer parallel
set.

## KVO observers on WKWebView need `MainActor.assumeIsolated`

`webView.observe(\.title) { ... }` gives a nonisolated closure. Touching
main-actor state inside it needs `MainActor.assumeIsolated { }`. This is sound
because WebKit posts these on the main thread — but the compiler cannot know
that, so it must be asserted.
