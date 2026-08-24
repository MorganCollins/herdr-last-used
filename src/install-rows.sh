#!/usr/bin/env bash
# Adds the [ui.sidebar.agents] row layout that renders the three colour tokens.
# Styling lives in Herdr's config by design: metadata reporters supply values
# only, so the colour has to be declared per token occurrence here.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

config="$(herdr_config_file)"
marker="# >>> herdr-last-used"

if [[ ! -f "$config" ]]; then
  echo "no Herdr config at $config" >&2
  exit 1
fi

if grep -q "^${marker}" "$config"; then
  echo "last-used rows already installed in $config"
  exit 0
fi

if grep -qE '^\[ui\.sidebar\.agents\]' "$config"; then
  cat >&2 <<MSG
$config already defines [ui.sidebar.agents].
Merge these three rows into your existing layout by hand, then re-run
'herdr server reload-config':

$(cat "$(asset rows.snippet.toml)")
MSG
  exit 1
fi

backup="${config}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$config" "$backup"

{
  printf '\n%s\n' "$marker"
  cat "$(asset rows.snippet.toml)"
  printf '%s\n' "# <<< herdr-last-used"
} >> "$config"

echo "added last-used rows to $config (backup: $backup)"
"$HERDR_BIN" server reload-config
