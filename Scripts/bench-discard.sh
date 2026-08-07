#!/bin/bash
# spec §4 — the measurement the memory claim actually rests on.
#
# WebContent processes are launchd-owned (PPID 1), NOT our children, so they
# cannot be attributed by process tree. This identifies ours as "WebContent pids
# that did not exist before we launched", which is sound on a machine where
# nothing else starts a WebKit process mid-run and is stated as a limitation
# rather than hidden.
#
# Reports phys_footprint, never RSS. Also samples vm_stat, because footprint
# counts COMPRESSED pages — a discard that merely let the compressor squeeze the
# tab is not a win, and switching to a metric that hides that would be cheating.

set -uo pipefail
cd "$(dirname "$0")/.."
TABS="${1:-8}"
OUT="${2:-/dev/stdout}"

fp() {  # summed phys_footprint in MB for a list of pids
  local total=0
  for p in $1; do
    local v
    v=$(footprint -p "$p" 2>/dev/null | awk '/phys_footprint:/ {print $2; exit}')
    [ -n "${v:-}" ] && total=$((total + v))
  done
  echo "$total"
}
compressed() { vm_stat | awk '/Pages occupied by compressor/ {gsub(/\./,"",$5); print $5}'; }
webcontent() { pgrep -f 'WebKit.WebContent' 2>/dev/null | sort; }

BASELINE=$(webcontent)
C0=$(compressed)

swift build -c debug >/dev/null 2>&1
LOG=$(mktemp)
.build/debug/Pane --bench-discard "$TABS" --store "$(mktemp -u)/bench.sqlite" > "$LOG" 2>&1 &
APP=$!

wait_for() {  # marker, timeout seconds
  local i=0
  while [ $i -lt "$2" ]; do
    grep -q "$1" "$LOG" 2>/dev/null && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

if ! wait_for BENCH_LOADED 60; then
  echo "bench: app never reported BENCH_LOADED" >&2; kill $APP 2>/dev/null; exit 1
fi

MINE=$(comm -13 <(echo "$BASELINE") <(webcontent))
N_BEFORE=$(echo "$MINE" | grep -c . || echo 0)
APP_BEFORE=$(fp "$APP")
WEB_BEFORE=$(fp "$MINE")
C1=$(compressed)

if ! wait_for BENCH_DISCARDED 60; then
  echo "bench: app never reported BENCH_DISCARDED" >&2; kill $APP 2>/dev/null; exit 1
fi

STILL=$(comm -12 <(echo "$MINE") <(webcontent))
N_AFTER=$(echo "$STILL" | grep -c . || echo 0)
APP_AFTER=$(fp "$APP")
WEB_AFTER=$(fp "$STILL")
C2=$(compressed)

LOADED=$(grep BENCH_LOADED "$LOG" | tail -1)
DISC=$(grep BENCH_DISCARDED "$LOG" | tail -1)
kill $APP 2>/dev/null; rm -f "$LOG"

TOTAL_BEFORE=$((APP_BEFORE + WEB_BEFORE))
TOTAL_AFTER=$((APP_AFTER + WEB_AFTER))
FREED=$((TOTAL_BEFORE - TOTAL_AFTER))
# Compressor pages are 4KiB. If the "saving" is mostly compression rather than
# release, this is where it shows up.
COMP_DELTA_MB=$(( (C2 - C1) * 4 / 1024 ))

cat > "$OUT" <<EOF
{"rec":"bench","metric":"discard_reclaims_memory","tabs":$TABS,
 "app_state":{"loaded":"$LOADED","discarded":"$DISC"},
 "webcontent_processes":{"before":$N_BEFORE,"after":$N_AFTER},
 "phys_footprint_mb":{"app_before":$APP_BEFORE,"app_after":$APP_AFTER,
   "webcontent_before":$WEB_BEFORE,"webcontent_after":$WEB_AFTER,
   "total_before":$TOTAL_BEFORE,"total_after":$TOTAL_AFTER,"freed":$FREED},
 "compressor_pages":{"before":$C1,"after":$C2,"delta_mb":$COMP_DELTA_MB},
 "note":"WebContent pids attributed as those absent before launch; they are launchd-owned (PPID 1), not our children",
 "pass":$([ "$N_AFTER" -lt "$N_BEFORE" ] && [ "$FREED" -gt 0 ] && echo true || echo false)}
EOF
