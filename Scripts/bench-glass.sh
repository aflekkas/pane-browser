#!/bin/bash
# spec §5 / milestone G gate — "Measured CPU/energy delta vs the flat build."
#
# §0 warns that Liquid Glass "does real-time backdrop sampling with refraction …
# more expensive than the old NSVisualEffectView blur, and continuous rather
# than one-shot". That was an assertion. This measures it.
#
# Runs the same scenario twice — once with glass, once with --no-glass — and
# compares CPU time. Same window, same tabs, same duration; the only variable
# is the material.

set -uo pipefail
cd "$(dirname "$0")/.."

SECONDS_PER_RUN="${1:-20}"
swift build -c debug >/dev/null 2>&1

measure() {  # $1 = extra flag, echoes cpu-seconds
  local flag="$1"
  local db; db=$(mktemp -u)/glass.sqlite
  .build/debug/Pane --seed-demo --no-restore --store "$db" $flag >/dev/null 2>&1 &
  local pid=$!
  sleep 8                       # let pages load; do not measure loading
  # Reset the baseline by sampling twice and taking the delta.
  local t0; t0=$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ')
  sleep "$SECONDS_PER_RUN"
  local t1; t1=$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ')
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  python3 - "$t0" "$t1" <<'PY'
import sys
def secs(t):
    if not t: return 0.0
    parts = t.replace('.', ':').split(':')
    parts = [float(p) for p in parts]
    while len(parts) < 4: parts.insert(0, 0.0)
    h, m, s, cs = parts[-4:]
    return h*3600 + m*60 + s + cs/100
print(round(max(0.0, secs(sys.argv[2]) - secs(sys.argv[1])), 3))
PY
}

GLASS=$(measure "")
FLAT=$(measure "--no-glass")

python3 - "$GLASS" "$FLAT" "$SECONDS_PER_RUN" <<'PY'
import json, sys
glass, flat, dur = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
delta = glass - flat
pct = (delta / flat * 100) if flat > 0 else 0.0
# The sidebar is static while idle, so glass should sample rarely. A large
# delta would mean it is resampling continuously, which is the failure §0
# warned about and the reason content-area glass is forbidden outright.
print(json.dumps({
    "rec": "bench", "metric": "glass_cpu_delta",
    "window_s": dur,
    "glass_cpu_s": glass, "flat_cpu_s": flat,
    "delta_s": round(delta, 3), "delta_pct": round(pct, 1),
    "note": "idle sidebar; both runs load the same pages and are killed after the same window",
    "pass": delta < 2.0,
}, sort_keys=True))
PY
