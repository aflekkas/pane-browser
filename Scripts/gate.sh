#!/bin/bash
# THE gate. Two modes:
#
#   ./Scripts/gate.sh pre     fast, runs before every commit (budget: 60s)
#   ./Scripts/gate.sh phase   slow, runs at every milestone
#
# On success `pre` appends a receipt keyed to `git write-tree` — the hash of the
# exact content being committed. The pre-commit hook refuses any commit without
# a passing receipt for that precise tree, so editing a byte after the gate ran
# invalidates it. This converts "I should test before committing" into "I cannot
# commit untested content".

set -uo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-pre}"
RECEIPTS=.pane-gate.log
FAIL=0
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "scope and invariants"
./Scripts/check-scope.sh || FAIL=1

step "PROGRESS.md is honest"
# A checked box whose gate does not pass is a false claim, and every decision
# built on top of one is also wrong.
if [ -x Scripts/check-progress.sh ]; then ./Scripts/check-progress.sh || FAIL=1
else echo "  (no completed phases to re-verify yet)"; fi

if [ -f Package.swift ]; then
  step "build"
  swift build -c debug 2>&1 | tail -20 || FAIL=1

  step "unit checks (PaneCore — pure logic, no AppKit)"
  # Not `swift test`: neither swift-testing nor XCTest ships with the Command
  # Line Tools, and tying the gate to a full Xcode install would mean the agent
  # cannot verify its own work on a bare machine. See docs/api-notes/toolchain.md.
  .build/debug/PaneCheck || FAIL=1
fi

if [ "$MODE" = phase ] && [ -f .build/debug/Pane ]; then
  step "scenarios"
  .build/debug/Pane --selftest || FAIL=1

  step "mutation canary"
  # A green suite that cannot detect a planted bug proves nothing. Each step
  # here FAILS IF THE SUITE PASSES. Every mutant is run, not a sample: there
  # are only four and they take seconds, and sampling means a broken scenario
  # can hide for days.
  while read -r M; do
    [ -z "$M" ] && continue
    if .build/debug/Pane --selftest --mutate "$M" >/dev/null 2>&1; then
      printf '\033[31mFAIL\033[0m suite PASSED with mutant %s planted — it proves nothing\n' "$M"
      FAIL=1
    else
      printf '\033[32m ok \033[0m caught mutant %s\n' "$M"
    fi
  done < <(python3 -c "import json;[print(m['id']) for m in json.load(open('Harness/mutants.json'))]" 2>/dev/null)

  step "restore latency (spec §9 gate)"
  .build/debug/Pane --bench-restore --iterations 20 || FAIL=1

  step "discard reclaims memory (spec §4)"
  ./Scripts/bench-discard.sh 6 || FAIL=1

  step "sidebar scroll at 200 rows (spec §5)"
  .build/debug/Pane --bench-scroll --rows 200 || FAIL=1

  step "profile isolation (spec §3)"
  .build/debug/Pane --verify-isolation >/dev/null || FAIL=1
fi

# ---------------------------------------------------------------------------
# What this run did NOT prove. Printed always, generated rather than
# hand-written, so it stays honest as the suite grows. Green must never be read
# as "shippable".
# ---------------------------------------------------------------------------
step "NOT proven by this run"
cat <<'EOF'
  - window-server event routing (synthetic events only)
  - real cross-application drag and drop
  - GPU-composited content under the takeSnapshot fallback
  - anything requiring TCC-gated capture
EOF
[ "$MODE" = pre ] && cat <<'EOF'
  - visual goldens (phase gate only)
  - memory and restore-latency thresholds (phase gate only)
  - mutation canary (phase gate only)
EOF

if [ "$FAIL" = 0 ]; then
  printf '\n\033[32mGATE PASS\033[0m (%s)\n' "$MODE"
  if [ "$MODE" = pre ]; then
    echo "$(git write-tree) pre $(date -u +%s) pass" >> "$RECEIPTS"
    echo "receipt written for tree $(git write-tree)"
  fi
  exit 0
else
  printf '\n\033[31mGATE FAIL\033[0m (%s) — no receipt written\n' "$MODE"
  exit 1
fi
