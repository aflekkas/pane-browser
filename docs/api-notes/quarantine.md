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
