# Profile isolation — measured result

**Date:** 2026-08-07 · **Host:** macOS 26.5.2, Apple Silicon
**Command:** `.build/debug/Pane --verify-isolation`

Milestone D's gate: *"log into the same site in two spaces as two different
users, simultaneously. Cookie jars verified disjoint on disk."*

## Result: PASS

```json
{"stores_distinct": true,
 "fell_back_to_default": false,
 "work_session": "work-user-alice",
 "personal_session": "personal-user-bob",
 "simultaneously_distinct": true,
 "work_dir":     "~/Library/WebKit/Pane/WebsiteDataStore/11111111-1111-4111-8111-111111111111",
 "personal_dir": "~/Library/WebKit/Pane/WebsiteDataStore/22222222-2222-4222-8222-222222222222",
 "failures": [], "pass": true}
```

The cookie named `session` holds a **different value in each store at the same
moment**. That is what "two different users at once" means concretely, and it is
asserted in both directions — neither profile can see the other's.

## The failure this was written to catch

`fell_back_to_default: false` is the important assertion. The plausible silent
failure is `WKWebsiteDataStore(forIdentifier:)` returning the default store —
whereupon every space shares one cookie jar and the product's central feature is
a lie that looks fine in casual use. The check compares object identity against
`WKWebsiteDataStore.default()` explicitly.

No entitlement was required. The binary is ad-hoc signed.

## On-disk layout (undocumented, so found by searching)

```
~/Library/WebKit/Pane/WebsiteDataStore/<profile-uuid>/
```

Apple does not document this shape, so the check enumerates rather than assuming
it — if WebKit moves the layout the check degrades to "not found on disk" rather
than silently passing against a stale path.

## What this does NOT prove

**Process isolation, which is not available at all.** The network process is a
singleton held in a `NeverDestroyed<WeakPtr>`; every data store is a session
inside it, and the GPU process is likewise shared. Only WebContent partitions.
See ADR 0002 and `docs/research/2026-08-07-profiles.md`.

Data isolation is what the product needs and what it now has. **"Process
isolation" must never appear in any description of Pane.**
