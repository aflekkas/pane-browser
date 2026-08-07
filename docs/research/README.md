# Research index

Before investigating anything, **check here first**. The whole point of this
directory is that no question gets researched twice.

Findings are preserved as reported, with citations. Where an adversarial
verifier disagreed with a researcher, **both are kept** — the disagreement is
the information, and collapsing it into a tidy conclusion destroys exactly what
makes the file worth having.

## Conventions

- Every claim is tagged **HARD FACT** (fetched from a primary source, with URL)
  or **INFERENCE** (reasoned, not confirmed).
- Filenames are dated. Every file states the OS and SDK versions it was true
  for, because Apple's API surface moves and a 2026 finding may be false by 2027.
- A superseded file gets `SUPERSEDED BY <file>` at the top. It is never deleted.
- Anything learned the hard way during the build lands here as a new dated file
  **at the moment of discovery**, not at the end of a session that may be
  truncated before it gets there.

## Index

| Question | File | Verdict | Adversarially verified |
| --- | --- | --- | --- |
| Can we get real per-profile isolation from `WKWebsiteDataStore`? | [profiles](2026-08-07-profiles.md) | works-with-caveats | yes — upheld |
| Can tabs be discarded and restored under 200ms, and does manual freezing help? | [lifecycle](2026-08-07-lifecycle.md) | works-with-caveats | yes — upheld |
| Can a third-party browser do passwords and passkeys on macOS? | [credentials](2026-08-07-credentials.md) | **partially-blocked** | yes — upheld |
| Does DRM work, and what entitlement does a macOS browser need? | [drm-entitlement](2026-08-07-drm-entitlement.md) | **partially-blocked** | yes — **researcher refuted** |
| Is Liquid Glass real API, and can it sample a WKWebView backdrop? | [liquid-glass](2026-08-07-liquid-glass.md) | works-with-caveats | no |
| What are the real APIs for downloads, auth, cert errors, find, context menus? | [boring-floor](2026-08-07-boring-floor.md) | works-with-caveats | no |
| What prior art should we read, and what can we legally reuse? | [prior-art](2026-08-07-prior-art.md) | works-with-caveats | no |
| Can we build and sign an entitled .app, and do we need Xcode? | [toolchain](2026-08-07-toolchain.md) | works-with-caveats | no |
| Does the Swift 6 / AppKit / single-actor-SQLite architecture hold up? | [architecture](2026-08-07-architecture.md) | works-with-caveats | no |
| How does an autonomous agent verify a GUI browser with no human watching? | [verification](2026-08-07-verification.md) | — | no |
| All of the above, merged into a decision document | [synthesis](2026-08-07-synthesis.md) | — | — |

## The five findings that changed the design

1. **Manual tab freezing is redundant.** `WKPreferences.inactiveSchedulingPolicy`
   defaults to `.suspend` when linked against the macOS 15+ SDK; a detached
   `WKWebView` already has JS paused, rAF stopped and `releaseMemory()` run.
   The spec's three-tier model collapses to two. → [lifecycle](2026-08-07-lifecycle.md)

2. **Per-profile *process* isolation is impossible.** The network process is a
   singleton (`NeverDestroyed<WeakPtr>`); every data store is a session inside
   it. Only WebContent processes partition. Data isolation is real and is what
   the product actually needs — but the words "process isolation" must not
   appear in any description of Pane. → [profiles](2026-08-07-profiles.md)

3. **The `navigator.credentials` JS shim cannot work.** A content world isolates
   JavaScript variable references; an override there is structurally invisible
   to page scripts. With the entitlement it is also unnecessary — WebKit handles
   WebAuthn natively. → [credentials](2026-08-07-credentials.md)

4. **Passkeys need an Apple-reviewed, organization-only entitlement**
   (`com.apple.developer.web-browser.public-key-credential`, macOS 13.3+),
   requiring the Account Holder role and a D-U-N-S number — and Apple's review
   criteria require the app to *already be a credible browser*. This is why it
   is built last. → [drm-entitlement](2026-08-07-drm-entitlement.md)

5. **Several confidently-cited APIs do not exist.** See the kill list in the
   [synthesis](2026-08-07-synthesis.md). Chief among them
   `NSOutlineViewDiffableDataSource`, which the spec's §5 sidebar design
   depended on.
