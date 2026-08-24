#!/usr/bin/env bash
# Runs once after herdr restores the session. Stamping must finish before the
# saved filter is replayed: a view that filters on tokens matches nothing until
# those tokens exist, and herdr does not restore token metadata across a restart.
# Agent views are transient too, so the last chosen filter is replayed here.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Tolerate a stamping failure: [[startup]] runs once, so aborting here would
# leave the saved filter unapplied for the whole session.
bash "$PLUGIN_DIR/stamp.sh" \
  || printf 'last-used: initial stamping failed; restoring the saved filter anyway\n' >&2

mode="$(cat "$(state_dir)/filter" 2>/dev/null || true)"
[[ -n "$mode" && "$mode" != "all" ]] || exit 0

exec bash "$PLUGIN_DIR/filter.sh" "$mode"
