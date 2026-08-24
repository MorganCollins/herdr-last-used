#!/usr/bin/env bash
# Adds the [ui.sidebar.agents] row layout that renders the three colour tokens.
# Styling lives in Herdr's config by design: metadata reporters supply values
# only, so the colour has to be declared per token occurrence there.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools python3
require_env HERDR_BIN_PATH

config="$(herdr_config_file)"
snippet="$(asset rows.snippet.toml)"

[[ -f "$config" ]] || die "no Herdr config at $config"

if grep -qF "$MARKER_BEGIN" "$config"; then
  echo "last-used rows already installed in $config"
  exit 0
fi

python3 "$PLUGIN_DIR/config_toml.py" parses "$config" >/dev/null \
  || die "$config is not valid TOML; fix it before installing"

if [[ "$(python3 "$PLUGIN_DIR/config_toml.py" has-agent-rows "$config")" == "yes" ]]; then
  cat >&2 <<MSG
$config already defines ui.sidebar.agents.rows.
Merge these rows into your existing layout by hand, then re-run
'herdr server reload-config':

$(cat "$snippet")
MSG
  exit 1
fi

backup="$(backup_config "$config")"

{
  printf '\n%s\n' "$MARKER_BEGIN"
  cat "$snippet"
  printf '%s\n' "$MARKER_END"
} >> "$config"

# Never leave a config that will not load. Appending after a later [table]
# could also capture following keys, which only a real parse would catch.
if ! python3 "$PLUGIN_DIR/config_toml.py" parses "$config" >/dev/null 2>&1; then
  cp "$backup" "$config"
  die "patching $config produced invalid TOML; restored from $backup"
fi

echo "added last-used rows to $config (backup: $backup)"
echo "note: rows is a full replacement, so your agent sidebar layout is now"
echo "pinned to this one. Re-run install-rows after a herdr upgrade to pick up"
echo "changes to herdr's defaults. Your colours live inside the managed block."
"$HERDR_BIN_PATH" server reload-config
