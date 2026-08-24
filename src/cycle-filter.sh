#!/usr/bin/env bash
# Advances the sidebar filter one step: all -> active -> stale -> inactive -> all.
#
# Herdr has no picker for plugin actions, so a single cycling keybinding is the
# only way to make the filters reachable without spending four keys on them.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

state="$(state_dir)"
current="$(cat "$state/filter" 2>/dev/null || true)"

case "$current" in
  active)   next="stale" ;;
  stale)    next="inactive" ;;
  inactive) next="all" ;;
  *)        next="active" ;;
esac

bash "$PLUGIN_DIR/filter.sh" "$next" >/dev/null

# A keypress with no feedback is indistinguishable from a keypress that did
# nothing, and the filter itself is only visible as agents disappearing.
case "$next" in
  active)   summary="showing agents used in the last day" ;;
  stale)    summary="showing agents idle for over a day" ;;
  inactive) summary="showing agents idle for over a week" ;;
  all)      summary="showing every agent" ;;
esac

"${HERDR_BIN_PATH:?HERDR_BIN_PATH is not set}" notification show \
  "Agents: $next" --body "$summary" >/dev/null 2>&1 || true
