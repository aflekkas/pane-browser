# Download quarantine

Security-critical, so written down precisely.

## What works

`LSFileQuarantineEnabled` = true in Info.plist. **This is the mechanism**, and
without it Pane applies no quarantine at all:

- WebKit does not quarantine. `DownloadCocoa.mm` has no quarantine code, so
  `WKDownload` will not do it for you.
- LaunchServices does it, reading that Info.plist flag.
  `CoreTypes.bundle/Exceptions.plist` force-enables it for known browsers by
  bundle ID — a new bundle ID like Pane's is in neither, so the flag is the
  only route.

**Verified end to end** by `Pane --verify-download <url>`: the file lands in
~/Downloads with `com.apple.quarantine` present. Gatekeeper will prompt.

## What does not work, after three attempts

Attaching **provenance** — `kLSQuarantineDataURLKey` and
`kLSQuarantineOriginURLKey`, the "downloaded from" attribution.

Attempts, all with the same outcome:

1. Set the properties as `String` values via `NSURLQuarantinePropertiesKey`.
2. Set them as `NSURL` objects (LSQuarantine.h types them `CFURLRef`).
3. Clear the existing quarantine (`nil`), then write the full dictionary.

In every case `setResourceValues` succeeds and the read-back contains only the
system-filled keys: `LSQuarantineAgentName`, `LSQuarantineEventIdentifier`,
`LSQuarantineIsOwnedByCurrentUser`, `LSQuarantineTimeStamp`, `LSQuarantineType`.

**Why.** The URLs are not stored in the xattr. The xattr is
`flags;timestamp;agent;uuid`, and the URLs are columns in
`~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2`
(`LSQuarantineDataURLString`, `LSQuarantineOriginURLString`), keyed by that
event UUID. Writing them through the URL resource key does not populate that
row when LaunchServices has already created the event.

**Observation worth keeping:** Arc's own rows in that database are also empty:

```
sqlite3 ~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2 \
  "SELECT LSQuarantineAgentName, LSQuarantineDataURLString FROM LSQuarantineEvent
   ORDER BY LSQuarantineTimeStamp DESC LIMIT 5;"
Pane||
Arc||
Arc||
```

So this is not a Pane defect so much as an undocumented corner. It is possible
Safari uses SPI, or writes the row directly.

## The distinction that matters

**Quarantine present is the security property, and it holds.** Gatekeeper
prompts on first open regardless of provenance. Provenance only affects the
wording of the prompt.

The gate therefore **fails** on a missing xattr and **reports** missing
provenance. Do not conflate them, and do not "fix" a failing gate by relaxing
the xattr assertion.

## If someone picks this up again

Do not try a fourth variation of `NSURLQuarantinePropertiesKey` — three are
recorded above. Investigate instead whether the row must be written before the
file is created, or whether `LSSetItemAttributes` (older, non-Swift) reaches the
database when the resource key does not.

---

## CORRECTION 2026-08-07 (later): WKDownload quarantines the file itself

Everything above about *who* applies the xattr was wrong, including the research
it was based on. Measured directly:

```swift
// A raw WKDownload. No Pane code, no applyQuarantine, no Info.plist
// (a bare binary, not a bundle).
let dl = await webView.startDownload(using: request)
// -> com.apple.quarantine: 0283;6a75c808;;
//    keys: LSQuarantineIsOwnedByCurrentUser, LSQuarantineTimeStamp, LSQuarantineType
```

And the control, proving it is not blanket sandbox behaviour:

```swift
try Data("plain write".utf8).write(to: downloadsDir.appending("x.bin"))
// -> quarantine ABSENT
```

**So `WKDownload` quarantines; a plain file write does not.** The research
claim — "WebKit does not quarantine, `DownloadCocoa.mm` contains no quarantine
code" — does not hold on macOS 26.5, whatever that file says.

**How this was found.** A mutation canary. `downloads.no_quarantine` disabled
Pane's own `applyQuarantine` and the gate stayed green — a gate passing for a
reason other than the code it was testing. That is precisely the failure the
canary exists to expose, and no amount of reading would have surfaced it.

**Consequences:**

- The mutant is **removed**, not "fixed". It is uncatchable by construction:
  it disables code that is not the source of the property being asserted, and
  an uncatchable mutant left in `mutants.json` fails the phase gate forever.
- `LSFileQuarantineEnabled` **stays** in Info.plist. It costs nothing, Safari
  sets it, and resting a security property solely on undocumented WebKit
  behaviour would be careless.
- `applyQuarantine` **stays**, but is now honestly documented as belt-and-braces
  for the xattr whose real purpose — provenance — does not work.
- The gate's assertion stands unchanged. It verifies the **user-facing security
  property** (Gatekeeper will prompt), which is true regardless of which layer
  provides it. It does **not** verify that Pane's own code provides it, and it
  should not be read as doing so.
