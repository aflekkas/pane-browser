# 0006 — The shipped binary is the test runner

**Status:** accepted · 2026-08-07

## Context

An autonomous agent building a GUI browser with no human watching needs to prove
to itself that what it built works. XCUITest needs `xcodebuild` and a test
runner app; Accessibility-API driving needs TCC permission that cannot be
granted non-interactively; external screenshot tools need Screen Recording
permission.

## Options

1. XCUITest via `xcodebuild`.
2. Drive the app externally via the Accessibility API.
3. Compile the harness into the app itself, driven by `--selftest`.

## Decision

Option 3. `Pane --selftest` runs scenarios in-process against real `WKWebView`s
and emits NDJSON to stdout with a nonzero exit on failure. **No TCC permission
is on the critical path anywhere.**

`CommandBus.dispatch` is the only mutator of app state — menus, keymap, and
scenarios all route through it. Because there is no second path, a scenario
dispatching `.closeTab` exercises exactly the code ⌘W exercises. This is what
makes scripted coverage real coverage rather than a parallel universe.

Harness code is `#if PANE_HARNESS` and compiles to empty stubs in a ship build.
CI greps the release binary to prove benchmark-only SPI did not leak into it.

## Consequences

- Works with or without Xcode, and works in CI.
- Requires the discipline that all state mutation goes through `CommandBus`,
  enforced by lint.
- Cannot catch what the app cannot observe about itself: window-server event
  routing, real cross-application drag and drop. `gate.sh` prints these as
  explicitly *not proven* rather than letting green imply they were.
