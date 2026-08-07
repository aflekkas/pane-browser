# DRM probe — measured result

**Date:** 2026-08-07 · **Host:** macOS 26.5.2 (25F84), Apple Silicon
**Binary:** ad-hoc signed, no entitlements, deployment target macOS 14
**Command:** `.build/debug/Pane --drm-probe`

This is milestone A′ from `PROGRESS.md`, and it is the cheapest decision point
in the project. Spec §8: *"Build `drm-probe.html` first… five minutes instead of
a week of manual testing."*

## Verdict: GO — FairPlay is available to a third-party WKWebView

| Key system | Result |
| --- | --- |
| `com.apple.fps` | **AVAILABLE** |
| `com.apple.fps.1_0` | **AVAILABLE** |
| `com.apple.fps.2_0` | **AVAILABLE** |
| `com.apple.fps.3_0` | **AVAILABLE** |
| `org.w3.clearkey` | AVAILABLE (control — proves EME itself is live) |
| `com.widevine.alpha` | `NotSupportedError` |
| `com.microsoft.playready` | `NotSupportedError` |

**No entitlement was needed.** The binary is ad-hoc signed with no entitlements
file at all. This confirms `docs/research/2026-08-07-drm-entitlement.md`:
`com.apple.developer.web-browser` is iOS-only and gates nothing here.

ClearKey succeeding matters — it is the control. Without it, four FairPlay
successes could have been an artefact of the probe rather than real EME.

## The caveat that shapes the UI copy

Every granted system resolved to:

```
sessionTypes:          ["temporary"]
persistentState:       "not-allowed"
distinctiveIdentifier: "not-allowed"
```

Requested as `optional`, resolved to `not-allowed`. So:

- **Streaming works.** Netflix, Disney+, Apple TV+ and Max use temporary
  sessions. This is the common case and it is fine.
- **Offline downloads do not.** Persistent-license flows need
  `persistentState: "required"`, which was refused.

This matches `CDMPrivateFairPlayStreaming::supportsSessionTypeWithConfiguration()`,
which permits `Temporary` whenever `persistentState != Required`.

**Honest UI copy is "offline downloads unavailable", not "DRM is broken".** The
adversarial verifier specifically flagged the latter as an overstatement worth
avoiding.

## Codec support

`canPlayType` returned `probably` for H.264, HEVC, VP9 and AV1.

## Still unverified — do not claim these

The probe proves the **CDM is reachable**. It does not prove any specific
service works, because vendors gate on user agent, licence-server policy and
HDCP in ways a capability check cannot see.

Outstanding, requires manual testing with real accounts:

- [ ] Netflix — actual playback, 1080p and 4K separately (HDCP path differs)
- [ ] Disney+
- [ ] Apple TV+
- [ ] YouTube (no DRM on standard content; expected to work)
- [ ] Spotify web (Widevine — expected to fail, and now confirmed impossible)

The UA is currently `Version/18.0 Safari/605.1.15`, hardcoded per spec §8's
correction — deriving it from `WebKit.framework` yields the nonsense
`Version/21624`.
