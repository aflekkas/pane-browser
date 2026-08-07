#!/bin/bash
# Anti-drift enforcement. Every rule here is a script that fails, not a
# principle anyone promises to remember — an agent across a compaction boundary
# has no memory of its own good intentions.
#
# Run by gate.sh, the pre-commit hook, and CI. All three invoke THIS file so
# they cannot diverge.

set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
say()  { printf '  %s\n' "$*"; }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
ok()   { printf '\033[32m ok \033[0m %s\n' "$*"; }

SPEC=docs/pane-browser-spec.md
SRC=Sources

# ---------------------------------------------------------------------------
# 1. Every source file traces to a spec section.
#
# This is the strongest single anti-drift device available: you cannot write
# code that does not trace to the spec, so building something unspecced
# requires first writing it INTO the spec, which is a visible, reviewable
# commit rather than code quietly appearing.
# ---------------------------------------------------------------------------
if [ -d "$SRC" ]; then
  missing=0; badref=0
  # Sections that actually exist in the spec, e.g. "4", "6", "7"
  SECTIONS=$(grep -oE '^## [0-9]+\.' "$SPEC" | grep -oE '[0-9]+' | sort -u)
  while IFS= read -r f; do
    hdr=$(head -5 "$f" | grep -oE '// spec: §[0-9]+(\.[0-9]+)?' | head -1)
    if [ -z "$hdr" ]; then
      bad "no '// spec: §N' header: $f"; missing=$((missing+1)); continue
    fi
    n=$(echo "$hdr" | grep -oE '[0-9]+' | head -1)
    if ! echo "$SECTIONS" | grep -qx "$n"; then
      bad "cites spec §$n which does not exist: $f"; badref=$((badref+1))
    fi
  done < <(find "$SRC" -name '*.swift' 2>/dev/null)
  [ "$missing" = 0 ] && [ "$badref" = 0 ] && ok "all sources cite a real spec section"
else
  say "no Sources/ yet — skipping spec-header check"
fi

# ---------------------------------------------------------------------------
# 2. Invariants are grepped, not trusted.
#
# Exemptions live in Scripts/scope-allowlist.txt, one per line, each naming the
# ADR that authorised it. An allowlist entry with no ADR number fails.
# ---------------------------------------------------------------------------
ALLOW=Scripts/scope-allowlist.txt
allowed() { [ -f "$ALLOW" ] && grep -qF -- "$1" "$ALLOW"; }

# Match CODE, not prose. A rule that fires on the word appearing in a comment
# explaining why we never use it trains people to ignore the rule — which is
# worse than not having it. Comment-only lines are stripped before matching.
code_lines() { sed -E 's://.*$::' "$1"; }

check_grep() { # <label> <pattern> <path-glob>
  local label="$1" pat="$2" path="$3"
  [ -d "$SRC" ] || return 0
  local hits=""
  local f
  for f in $(find "$path" -name '*.swift' 2>/dev/null); do
    code_lines "$f" | grep -qE "$pat" && hits="$hits $f"
  done
  local any=0
  for h in $hits; do
    allowed "$h" && continue
    bad "$label: $h"; any=1
  done
  [ "$any" = 0 ] && ok "$label"
}

check_grep "no SwiftUI in the sidebar or any list"  '^import SwiftUI'         "$SRC"

# All SQLite through the single Store actor. Store.swift is the one file
# permitted to contain it — that is the whole point of the invariant, not an
# exception to it.
if [ -d "$SRC" ]; then
  hits=""
  for f in $(find "$SRC" -name '*.swift' 2>/dev/null | grep -v '/PaneCore/Store\.swift$'); do
    code_lines "$f" | grep -qE '\bsqlite3_' && hits="$hits $f"
  done
  if [ -n "$hits" ]; then
    for h in $hits; do allowed "$h" || bad "all SQLite through the Store actor: $h"; done
  else ok "all SQLite through the Store actor"; fi
fi

check_grep "injected JS stays in an isolated world" 'WKContentWorld\.page'    "$SRC"
check_grep "no private API (leading-underscore)"    '\._[a-z][A-Za-z0-9]*\('  "$SRC"

# No web content may render browser UI.
if [ -d "$SRC" ]; then
  hits=""
  for f in $(find "$SRC" -name '*.swift' 2>/dev/null | grep -v '/Fixtures/'); do
    code_lines "$f" | grep -q 'loadHTMLString' && hits="$hits $f"
  done
  if [ -n "$hits" ]; then
    for h in $hits; do allowed "$h" || bad "no web content renders browser UI: $h"; done
  else ok "no web content renders browser UI"; fi
fi

# Allowlist entries must each cite an ADR.
if [ -f "$ALLOW" ]; then
  n=0
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    echo "$line" | grep -qE 'ADR-[0-9]{4}' || { bad "allowlist entry without an ADR: $line"; n=1; }
  done < "$ALLOW"
  [ "$n" = 0 ] && ok "every allowlist entry cites an ADR"
fi

# ---------------------------------------------------------------------------
# 3. Zero third-party dependencies unless an ADR says otherwise.
# ---------------------------------------------------------------------------
if [ -f Package.swift ]; then
  deps=$(grep -cE '^\s*\.package\(' Package.swift 2>/dev/null || echo 0)
  adrs=$(ls docs/decisions/*dependenc* 2>/dev/null | wc -l | tr -d ' ')
  if [ "$deps" -gt 0 ] && [ "$adrs" = 0 ]; then
    bad "Package.swift declares $deps dependencies with no ADR authorising them"
  else ok "dependency budget ($deps declared)"; fi
fi

# ---------------------------------------------------------------------------
# 4. Hard LOC budget. Catches the drift no other check does: not wrong code,
#    just steadily more of it.
# ---------------------------------------------------------------------------
if [ -d "$SRC" ]; then
  loc=$(find "$SRC" -name '*.swift' ! -path '*/PaneHarness/*' -exec cat {} + 2>/dev/null \
        | grep -vE '^\s*(//|$)' | wc -l | tr -d ' ')
  phase=$(grep -m1 '^\*\*Current phase:\*\*' PROGRESS.md | sed 's/.*\*\* *//' | cut -c1)
  ceil=$(awk -F'|' -v p="$phase" '$2 ~ ("^ *" p " ") {gsub(/[ ,]/,"",$3); print $3; exit}' docs/budget.md)
  [ -z "${ceil:-}" ] && ceil=1200
  if [ "$loc" -gt "$ceil" ]; then
    bad "LOC budget: $loc > $ceil for phase $phase (docs/budget.md)"
  else ok "LOC budget: $loc / $ceil"; fi
fi

exit $FAIL
