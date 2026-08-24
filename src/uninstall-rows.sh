#!/usr/bin/env bash
# Removes the block install-rows.sh added, leaving any hand-edits elsewhere alone.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

config="$(herdr_config_file)"
marker="# >>> herdr-last-used"

if ! grep -q "^${marker}" "$config" 2>/dev/null; then
  echo "no last-used block found in $config"
  exit 0
fi

backup="${config}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$config" "$backup"
sed -i.sedtmp '/^# >>> herdr-last-used$/,/^# <<< herdr-last-used$/d' "$config"
rm -f "${config}.sedtmp"

echo "removed last-used rows from $config (backup: $backup)"
"$HERDR_BIN" server reload-config
