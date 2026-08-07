# 0002 — Data isolation, not process isolation

**Status:** accepted · 2026-08-07 · corrects spec §3

## Context

Spec §3: *"Each profile also owns its own `WKProcessPool`. Same pool means
shared renderer processes; separate pools means hard isolation."*

## Decision

Delete all process-pool code. Do not replace it.

`WKProcessPool` and `WKWebViewConfiguration.processPool` are
`API_DEPRECATED("Creating and using multiple instances of WKProcessPool no
longer has any effect.", macos(10.10, 12.0))`.

More importantly, the isolation being claimed is not available at all:
`NetworkProcessProxy::ensureDefaultNetworkProcess()` returns a single app-wide
process held in a `NeverDestroyed<WeakPtr>`, and every data store is added as a
**session inside that one process**. The GPU process is likewise a singleton.
**Only WebContent processes partition per profile.**

Nuance worth keeping: multiple pools are not inert. They still create real
`WebProcessPool` objects with fragmented process caches and prewarm pools. They
cost something and buy nothing.

## Consequences

- Per-profile **data** isolation via `WKWebsiteDataStore(forIdentifier:)` is
  real, and is what the product actually needs: separate cookie jars, separate
  storage, separate logins.
- **The phrase "process isolation" must never appear in any description of
  Pane.** Marketing copy that claims it would be false.
- One less subsystem to build.
