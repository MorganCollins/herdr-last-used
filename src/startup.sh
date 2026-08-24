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

# Install the sidebar rows once, on the first startup after linking. Herdr has
# no post-install hook — build commands do not run for a linked plugin and get
# no socket — so this is the only place it can happen automatically.
#
# The recorded choice is what stops this fighting the user: once rows have been
# installed or deliberately removed, startup leaves the config alone forever.
rows_state="$(cat "$(state_dir)/rows" 2>/dev/null || true)"
if [[ -z "$rows_state" ]]; then
  if bash "$PLUGIN_DIR/install-rows.sh"; then
    printf 'last-used: added the sidebar rows to your herdr config (run the\n'      >&2
    printf '           uninstall-rows action to remove them; they will not come\n'  >&2
    printf '           back once you do)\n'                                        >&2
  else
    # A config we must not touch, or one we could not patch. Record it so this
    # is not retried on every server start.
    printf 'skipped\n' > "$(state_dir)/rows"
    printf 'last-used: left your herdr config alone; run the install-rows action\n' >&2
    printf '           to add the sidebar rows by hand\n'                          >&2
  fi
fi

mode="$(cat "$(state_dir)/filter" 2>/dev/null || true)"
[[ -n "$mode" && "$mode" != "all" ]] || exit 0

exec bash "$PLUGIN_DIR/filter.sh" "$mode"
