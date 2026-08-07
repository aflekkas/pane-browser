# 0005 — SPM is the build system; Xcode is a tool, not the project

**Status:** accepted · 2026-08-07

## Context

The dev machine had Command Line Tools only. The initial decision was SPM-only
with a hand-rolled bundle script, on the reasoning that a ~10GB GUI dependency
bought mostly convenience in a CLI-shaped project.

## Decision

Install Xcode, but keep `Package.swift` as the build definition.

The initial reasoning was correct for the requirements as they stood and became
wrong when autonomous self-verification was added. Instruments is the only
honest way to profile the memory claim that is this product's entire thesis, and
restricted entitlements (ADR 0004) need provisioning profiles.

`xcodebuild` is invoked only for what SPM cannot do: Instruments profiling,
notarization, and provisioning. **If Xcode ever becomes load-bearing for a
normal build, that is a regression.**

## Consequences

- `Package.swift` stays diffable, scriptable, reviewable in a PR.
- `Scripts/bundle.sh` assembles the `.app` by hand: `Contents/MacOS`,
  `Info.plist`, `codesign --entitlements`.
- CI can build without Xcode; only the profiling and release paths need it.
- The lesson, recorded because it will recur: **the toolchain decision depends
  on the verification requirement, not the build requirement.**
