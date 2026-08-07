# Journal

Append-only, newest last. One entry per session.

This records **narrative**; `PROGRESS.md` records state. Write what you
attempted, what actually happened, what surprised you, and what the next
session should do first.

**Dead ends are the most valuable entries here.** They are the only record of
work that produced no artifact, and without them they get repeated by a session
that has no memory of the first attempt.

---

## 2026-08-07 — planning, research, repo standup

**Attempted:** turn a conversational spec into a repo that can survive an
autonomous build across compaction boundaries.

**What happened.** Started from an empty directory — no git, no spec on disk,
the whole design living in a context window. Found the spec had actually been
written already, sitting in `~/Downloads/Arc Browser Spec.md` under a stale
name. Committed it verbatim first so every later correction is a visible diff.

Ran two research fleets: 14 agents on feasibility (9 researchers, 4 adversarial
verifiers, 1 synthesis) and 5 on the self-verification harness. ~1.6M tokens.
It was worth it — see below.

**What surprised me.**

*The adversarial pass was the highest-value part by a wide margin.* Three of
four verifiers upheld their researcher, which felt like wasted spend until the
fourth overturned the DRM researcher's headline conclusion — and it was wrong in
the direction that costs a shipping browser the most ("no macOS browser
entitlement exists, budget zero time"). The verifiers also caught four APIs that
were cited confidently and do not exist. Those would each have been discovered
at compile time, days later, with the surrounding design already built on them.

*Three findings made the project smaller, not bigger.* The manual freeze tier is
redundant because WebKit already suspends detached webviews by default. The
passkey JS shim is both impossible (content worlds isolate JS variable
references, so a `navigator.credentials` override is invisible to page scripts)
and unnecessary (WebKit does WebAuthn natively given the entitlement). Both are
deletions from the critical path.

*The isolation story is weaker than the spec claims.* The network process is a
singleton; every data store is a session inside it. Only WebContent processes
partition per profile. Data isolation — separate cookie jars, separate logins —
is real and is what the product actually needs. But "process isolation" must
never appear in a description of Pane.

**Dead ends, recorded so they are not retried.**

- I initially concluded Xcode was unnecessary and SPM-only was correct. That was
  right for the requirements at the time and wrong once autonomous
  self-verification was added — Instruments is the only honest way to prove the
  memory claim. Reversed. The lesson is that the toolchain decision depends on
  the verification requirement, not on the build requirement.
- I set up two background waiters polling the workflow journal for
  `"type":"completed"`. The journal writes `"type":"result"`. Both would have
  hung forever. Check the actual event vocabulary before writing a poll loop.
- I recommended `duckduckgo/macos-browser` as the phase-E reference. It was
  archived 2025-02-24 and moved to `duckduckgo/apple-browsers`.
- I described Zen as a source to "steal code from". It is a Firefox fork —
  Gecko, JS/XUL/CSS. Zero portable code for a Swift/WKWebView project. It is
  worth reading for UX mechanics only, and it is MPL-2.0 (file-level copyleft),
  so literal translation would be a derivative work.

**Next session, do this first:** finish Phase 0 — the enforcement scripts and
hooks, the public repo, and the spec-correction commit. Then milestone A. Do not
start milestone A before the hooks are installed; the whole anti-drift design
depends on enforcement existing before the code it governs.
