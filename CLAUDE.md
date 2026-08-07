# Pane — working rules

Assume you remember nothing. Context gets compacted, sessions end mid-phase.
Anything true but unwritten is gone. This repo carries the whole project's
understanding of itself; your memory is not part of the system.

## Start here, every session, before touching code

1. Read this file.
2. Read `PROGRESS.md` — current phase and its gate.
3. Read the last three entries of `docs/journal.md` — recent narrative, open threads.
4. `git log --oneline -20` — what actually landed, versus what the docs claim.
5. Run `./Scripts/gate.sh pre` **on a clean tree**. If it fails on code you did
   not touch, that is the real state of the world and it comes before new work.
6. Only then read the spec section for the area you are about to work on.

Step 5 exists because docs drift and tests do not. If `PROGRESS.md` claims a
phase passed and its gate now fails, **the gate wins** and `PROGRESS.md` gets
corrected in that session.

## Invariants — never violate

- **No web content renders browser UI.** Sidebar, error pages, panels, settings,
  interstitials are all AppKit. A web-rendered error page inside a compromised
  renderer is a real attack surface.
- **No SwiftUI for the sidebar or any list.**
- **All SQLite goes through the single `Store` actor.**
- **Injected JS lives in an isolated `WKContentWorld`, never the page world.**
- **Do not guess on security.** Keychain access control, passkey RP-ID
  validation, download quarantine xattrs, cert exception scoping — check the
  spec, check `docs/research/`, or ask. Never infer.
- **Do not build anything not in the spec.**

## The spec is the source of truth

`docs/pane-browser-spec.md`. Numbered sections; cite them as `spec §4.2`.

**Re-read the relevant section before touching a new area. Never re-derive a
design decision from memory.** A decision recalled rather than read is a
decision being quietly reinvented.

The spec is **living, not frozen** — parts of it were already provably wrong on
day one. But edits are ceremonial:

- A spec change is **its own commit**, never bundled with code.
- Every changed claim carries its evidence inline — an Apple doc URL, a WebKit
  source link, or probe output. A claim with no citation is a guess in a spec's
  clothing.
- **Reversing a decision needs an ADR.** Correcting a factual error does not.
  "This API does not exist" is a correction. "We no longer isolate profiles by
  process pool" is a reversal.
- **Scope only shrinks without asking.** Cutting is a judgment call you may make
  and record. Adding is not — ask. The entire thesis is that Pane is small, and
  a spec that grows is the failure this project is built against.
- Superseded claims get struck through with a one-line note where the wrongness
  is instructive, rather than deleted. Someone will wonder why we didn't just
  use `_isPlayingAudio`; the answer should already be written.

## Where things live

| File | Holds | Never holds |
| --- | --- | --- |
| `CLAUDE.md` | Invariants, procedure, delegation doctrine | Design detail |
| `docs/pane-browser-spec.md` | What and why | Status |
| `PROGRESS.md` | Where we are, gates, honest results | Design rationale |
| `docs/decisions/` | ADRs — context, options, decision, consequences | Status |
| `docs/journal.md` | Append-only narrative, **including dead ends** | State |
| `docs/research/` | Findings with citations, both sides of disputes | Opinions |
| `docs/api-notes/` | Framework gotchas found the hard way | Design |
| `docs/ui-parity.md` | Standing Arc-parity checklist | Feature scope |

`PROGRESS.md` records *state*. `docs/journal.md` records *narrative*. Dead ends
are the highest-value journal entries — the only record of work that produced no
artifact. Without them it gets repeated.

## Standing goal: UI parity with Arc

Pane should reach visual and interaction parity with Arc on the **basic browser
features** — layout, proportions, density, how interactions feel. Tracked in
`docs/ui-parity.md`; measure against a real screenshot before ticking anything.

**Not** custom theming, **not** transparency (that is milestone G), and **not**
Arc's feature set. Parity means the basic features look right. Spec §0 still
governs what exists at all.

## Anti-drift is enforced, not promised

You will not remember your own good intentions after a compaction. So the rules
are scripts that fail:

- **Every `.swift` file opens with `// spec: §N.N`.** `check-scope.sh` fails if
  it is missing or cites a section that does not exist. You cannot write code
  that does not trace to the spec — building something unspecced requires
  writing it into the spec first, which is a visible commit.
- **Invariants are grepped**, not trusted: `import SwiftUI` in list code,
  `sqlite3_` outside `Store.swift`, `.page` content worlds, private-API-shaped
  identifiers. Exemptions live in `Scripts/scope-allowlist.txt` and each needs
  an ADR number; an entry without one fails.
- **`./Scripts/gate.sh pre` writes a receipt keyed to `git write-tree`.** The
  pre-commit hook refuses any commit without a passing receipt for that exact
  tree. Edit a byte after the gate ran and the receipt is void. CI re-runs the
  same script on push, so `--no-verify` surfaces within one push.
- **A hard LOC budget** in `docs/budget.md`. "Fast and small" is unfalsifiable
  as a slogan and trivial as a number. Raising it is a spec commit with a reason.
- **Zero third-party dependencies** unless an ADR says otherwise.
- **`PROGRESS.md` cannot lie** — a script re-runs the gate for every phase marked
  complete. A checked box whose gate fails is a false claim, and false claims
  about finished work are the most expensive failure mode here: every decision
  built on top of one is also wrong.

## Commit format

`area: what changed (spec §N)`

e.g. `lifecycle: discard ephemeral tabs after 5m idle (spec §4)`

Small, frequent, real messages saying *why*. `git log` is the one record that
cannot drift from what happened, so it is primary documentation. **Never leave
the tree broken** — a broken tree is a lie told to the next session, which will
assume a red gate is its own fault and burn a cycle bisecting.

## Delegating to subagents

Written down because this judgment does not survive compaction, and the wrong
default is costly both ways: too much delegation burns tokens on trivia, too
little means grinding solo through work eight parallel agents finish in one pass.

| Model | For |
| --- | --- |
| **Haiku** | Mechanical sweeps — grep a symbol tree-wide, check every file has its `// spec:` header, bulk inventory. |
| **Sonnet** | Well-specified self-contained work where the shape is known — a test fixture from a stated contract, one delegate method against a documented signature, a runbook. |
| **Opus** | Anything needing judgment: implementing a spec section, designing a state machine, debugging real misbehaviour, review. **When unsure, this.** |
| **Fable** | Genuinely stuck, or being wrong is unacceptable — passkey RP-ID validation, keychain access control, cert exception scoping, an expensive-to-reverse architectural call. |

**Escalation trigger, not a vibe: after two failed attempts at the same problem,
stop.** Do not try a third time. Spawn a Fable subagent with both failures and
what you ruled out. Three consecutive solo attempts at one bug is the signature
of grinding, and grinding is where long autonomous runs die.

**Fan out** when work is wide (many independent subsystems), needs adversarial
checking (costly if wrong), or exceeds one context. **Do not** fan out for a
single well-understood edit — orchestration costs more than the work.

Shapes worth reusing:

- **Adversarial verify** — for security-relevant or expensive-to-reverse claims,
  spawn skeptics prompted to *refute*; require a majority to survive. This is
  how the planning research ran, and it caught four APIs that do not exist.
- **Multi-modal sweep** — for "did I miss anything", agents searching different
  ways at once rather than one agent searching four times.
- **Loop-until-dry** — for unbounded discovery, keep going until two consecutive
  rounds find nothing new. Fixed counts miss the tail.

Cost is not the binding constraint. **Being wrong is.** Record what you spent
and what it bought in `docs/journal.md`.

## Known hard constraints

Do not rediscover these. Full detail and citations in `docs/research/`.

- **Per-profile *process* isolation is impossible.** The network process is a
  singleton; data stores are sessions inside it. Only WebContent partitions.
  Data isolation is real and sufficient — but never describe Pane as having
  "process isolation".
- **`WKProcessPool` is deprecated and does nothing.** No process-pool code.
- **Passkeys need `com.apple.developer.web-browser.public-key-credential`** —
  Apple-reviewed, needs Account Holder on an *organization* account and a D-U-N-S
  number, and Apple's criteria require Pane to already be a credible browser.
  Built last, feature-flagged, behind a protocol with a no-op implementation.
- **There is no way to read the user's existing Safari passwords.**
  `ASSavePasswordRequest` is iOS-only. The only sanctioned path is a one-time
  user-initiated `ASCredentialImportManager` FIDO CXP import (macOS 26+).
- **These do not exist:** `NSOutlineViewDiffableDataSource`,
  `WKPreferencesPrivate.h`, `webView.mediaPlaybackState()`,
  `com.apple.developer.web-browser` on macOS.
- **These are iOS-only:** `contextMenuConfigurationForElement` (use
  `NSView.willOpenMenu(_:with:)`), `isFindInteractionEnabled` (use
  `NSTextFinderClient`), `WKDownloadPlaceholderPolicy`.
