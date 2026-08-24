#!/usr/bin/env bash
# Removes the block install-rows.sh added, leaving any hand-edits elsewhere alone.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_env HERDR_BIN_PATH

config="$(herdr_config_file)"

if ! grep -qF "$MARKER_BEGIN" "$config" 2>/dev/null; then
  echo "no last-used block found in $config"
  exit 0
fi

# Deleting from the opening marker to EOF would take the rest of the file with
# it, so refuse when the closing marker is gone rather than guessing.
grep -qF "$MARKER_END" "$config" \
  || die "found $MARKER_BEGIN in $config but no closing $MARKER_END; remove the block by hand"

# The colours the README tells you to customise live inside this block.
if ! sed -n "/^${MARKER_BEGIN}\$/,/^${MARKER_END}\$/p" "$config" \
     | sed '1d;$d' | diff -q - "$(asset rows.snippet.toml)" >/dev/null 2>&1; then
  echo "note: the managed block differs from the shipped default (customised colours?);" >&2
  echo "      it is being removed — recover from the backup below if that was a mistake." >&2
fi

backup="$(backup_config "$config")"
sed "/^${MARKER_BEGIN}\$/,/^${MARKER_END}\$/d" "$config" > "$config.tmp.$$"
mv "$config.tmp.$$" "$config"

echo "removed last-used rows from $config (backup: $backup)"
"$HERDR_BIN_PATH" server reload-config
