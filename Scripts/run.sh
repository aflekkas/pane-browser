#!/bin/bash
# Build, bundle, launch. This is the command that keeps the project honest —
# the app must be launchable from week one and never stop being launchable.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c "${CONFIG:-debug}" "$@"
./Scripts/bundle.sh "${CONFIG:-debug}"
# A locally built bundle carries no com.apple.quarantine xattr, so there is no
# Gatekeeper prompt to fight.
open Pane.app
