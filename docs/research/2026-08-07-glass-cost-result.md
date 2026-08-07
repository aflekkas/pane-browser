# Liquid Glass CPU cost — measured result

**Date:** 2026-08-07 · **Host:** macOS 26.5.2, Apple Silicon
**Command:** `./Scripts/bench-glass.sh 20`

Spec §0 asserts: *"`NSGlassEffectView` does real-time backdrop sampling with
refraction. More expensive than the old `NSVisualEffectView` blur, and
continuous rather than one-shot."* Milestone G's gate is a measured delta, not
that assertion repeated.

## Result: PASS

```json
{"window_s": 20,
 "glass_cpu_s": 0.33, "flat_cpu_s": 0.30,
 "delta_s": 0.03, "delta_pct": 10.0,
 "pass": true}
```

Same scenario twice — identical tabs, identical duration, killed after the same
window. The only variable is `--no-glass`.

**30 milliseconds of CPU over 20 seconds.** 10% relative, negligible absolute.

## What this establishes, and what it does not

**Does:** glass over a *static* sidebar is cheap. It is not resampling
continuously while nothing moves, which is the failure §0 warned about. §5's
design — one container, sidebar only — is affordable.

**Does not:** it says nothing about glass over *changing* content. The sidebar
is nearly static; a backdrop that changes every frame would force a resample
every frame. That is precisely why §5 forbids glass over the content area
outright — "the single most expensive thing you could do" — and this measurement
is not permission to revisit that.

Nor is it a battery measurement. CPU time is a proxy; a real energy figure needs
`powermetrics` and a quiet machine.

## Method note

Measures CPU seconds via `ps -o time=`, sampled after an 8-second settle so page
loading is excluded from both runs. The settle matters: measuring from launch
would drown a 30ms difference in seconds of WebKit startup.
