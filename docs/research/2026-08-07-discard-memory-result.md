# Discard reclaims memory — measured result

**Date:** 2026-08-07 · **Host:** macOS 26.5.2 (25F84), Apple Silicon
**Command:** `./Scripts/bench-discard.sh 8`

This is the measurement the product's central claim rests on. Everything before
it was suggestive.

## Result: PASS

```json
{"tabs":8,
 "app_state":{"loaded":"tabs=9 engines=9","discarded":"tabs=9 engines=1"},
 "webcontent_processes":{"before":9,"after":1},
 "phys_footprint_mb":{"app_before":30,"app_after":30,
   "webcontent_before":185,"webcontent_after":28,
   "total_before":215,"total_after":58,"freed":157},
 "compressor_pages":{"before":340262,"after":340208,"delta_mb":0},
 "pass":true}
```

**157 MB of 215 MB freed — 73%.** Nine WebContent processes collapsed to one.

## Why the compressor line is the important one

`phys_footprint` **counts compressed pages**. A discard that merely let the
memory compressor squeeze an idle tab would show a falling footprint while the
pages were still resident — a real-looking win that is not one.

Compressor pages went from 340,262 to 340,208. It went **down**, by 54 pages.
The memory was genuinely released, not compressed.

Switching to a metric that hides this would be the easiest way to fake this
result, which is exactly why the harness design forbids it.

## The one engine that survives is correct

`engines=1` after a forced sweep is not a leak. The selected tab is never a
discard candidate at any age — discarding what the user is looking at would be
visible, and no memory policy is worth that. The forced sweep skips only the
*idle threshold*; the never-discard conditions and the selection rule still
apply, because a benchmark that discards things the product never would measures
nothing the product does.

## Attribution limitation, stated rather than hidden

WebContent processes are **launchd-owned (PPID 1)**, not children of Pane —
verified directly, and consistent with `docs/research/2026-08-07-profiles.md`.
There is no process-tree attribution available.

The benchmark therefore identifies "our" WebContent pids as *those that did not
exist before Pane launched*. This is sound on a machine where nothing else
starts a WebKit process mid-run, and is wrong if something does. It is stated
here rather than buried so a future surprising number has somewhere to look.

The app's own footprint is flat at 30 MB before and after, which is the expected
shape: the memory is in the renderers, not the shell.
