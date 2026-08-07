# 0001 — Two-tier tab lifecycle, not three

**Status:** accepted · 2026-08-07 · reverses spec §4

## Context

Spec §4 defines `live | frozen | discarded`, with "freeze" doing
`setAllMediaPlaybackSuspended(true)`, injecting a `freeze` event, and setting
`isHidden = true`. This was presented as core differentiating work.

## Options

1. Build the three-tier model as specced.
2. Collapse to two tiers and set `inactiveSchedulingPolicy` explicitly.

## Decision

Option 2. `WKPreferences.inactiveSchedulingPolicy` is public API (macOS 14+) and
**already defaults to `.suspend`** for anything linked against the macOS 15+ SDK.
A `WKWebView` detached from the view hierarchy already has JS execution paused,
page layout paused, rAF stopped, CSS/SVG animations suspended, layer trees
frozen, rendering resources destroyed, and `releaseMemory()` run.

Source: `WebPreferencesDefaultValues.cpp` —
`defaultShouldTakeNearSuspendedAssertion()` and
`defaultRunningBoardThrottlingEnabled()`.

## Consequences

- "Frozen" becomes one line setting the policy explicitly, for intent and
  older-OS safety.
- All engineering budget moves to discard/restore, the only tier that reclaims
  memory — which requires actually deallocating the `WKWebView`.
- The memory claim becomes *more* defensible, because it now rests on the tier
  that does real work rather than on duplicating WebKit's own throttling.
