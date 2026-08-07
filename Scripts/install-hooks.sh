#!/bin/bash
# Installs the hooks that make the gate structurally unskippable.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .git/hooks

cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/sh
# Refuse any commit lacking a passing gate receipt for THIS EXACT TREE.
# Editing a file after the gate ran changes the tree hash and voids the receipt.
if ! git diff --quiet; then
  echo "pre-commit: unstaged changes present — the gate would not match the commit."
  echo "            stage everything, then run ./Scripts/gate.sh pre"
  exit 1
fi
TREE=$(git write-tree)
if ! grep -q "^$TREE pre .* pass$" .pane-gate.log 2>/dev/null; then
  echo "pre-commit: no passing gate receipt for tree $TREE"
  echo "            run ./Scripts/gate.sh pre"
  exit 1
fi

# No session ends without a journal entry.
if [ -n "$(git diff --cached --name-only | grep -v '^docs/journal.md$')" ]; then
  TODAY=$(date -u +%Y-%m-%d)
  if ! grep -q "^## $TODAY" docs/journal.md 2>/dev/null; then
    echo "pre-commit: no docs/journal.md entry for $TODAY"
    exit 1
  fi
fi
HOOK
chmod +x .git/hooks/pre-commit

cat > .git/hooks/commit-msg <<'HOOK'
#!/bin/sh
# Enforce: "area: what changed (spec §N)". Makes git log a queryable index into
# the spec, which matters enormously when reorienting with no context.
head -1 "$1" | grep -qE '^[a-z][a-z0-9-]*: .+' || {
  echo "commit-msg: subject must be 'area: what changed', e.g."
  echo "            lifecycle: discard ephemeral tabs after 5m idle (spec §4)"
  exit 1
}
HOOK
chmod +x .git/hooks/commit-msg
echo "hooks installed: pre-commit, commit-msg"
