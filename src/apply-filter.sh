#!/usr/bin/env bash
# Reapplies the saved sidebar filter. Agent views are transient and do not
# survive a server restart, so the startup hook replays the last choice.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

state="$(state_dir)"
mode="$(cat "$state/filter" 2>/dev/null || true)"
[[ -n "$mode" && "$mode" != "all" ]] || exit 0

exec bash "$PLUGIN_DIR/filter.sh" "$mode"
