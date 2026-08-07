#!/bin/bash
# spec §5 visual goldens.
#
#   ./Scripts/visual.sh check     capture and diff against Goldens/
#   ./Scripts/visual.sh record    write the goldens (first time only)
#
# Uses Capture.composite: no Screen Recording permission, no activation, so it
# runs unattended from the gate with any window frontmost. See
# docs/api-notes/appkit.md for the six approaches that did not work.
set -uo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-check}"
OUT=".pane-artifacts/visual"
mkdir -p "$OUT" Goldens

swift build -c debug >/dev/null 2>&1

SCENE="sidebar-populated"
DB=$(mktemp -u)/visual.sqlite
CAND="$OUT/$SCENE.png"
rm -f "$CAND"

.build/debug/Pane --golden-scene --no-restore --store "$DB" --capture "$(pwd)/$CAND" >/dev/null 2>&1
if [ ! -f "$CAND" ]; then
  echo "visual: capture produced no file"; exit 1
fi

GOLDEN="Goldens/${SCENE}@1280x800@1x.png"

if [ "$MODE" = record ]; then
  cp "$CAND" "$GOLDEN"
  echo "recorded $GOLDEN"
  exit 0
fi

if [ ! -f "$GOLDEN" ]; then
  echo "visual: no golden for $SCENE — run ./Scripts/visual.sh record"
  exit 1
fi

# Sidebar only (left 232pt of a 1280pt-wide window at 1x). The content area
# shows a live third-party page; including it makes the golden fail against
# itself, and a check that cries wolf is one people learn to ignore.
.build/debug/paneshot diff "$GOLDEN" "$CAND" --region 0,0,232,800
