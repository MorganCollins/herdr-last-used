#!/usr/bin/env bash
# Removes the block install-rows.sh added, leaving any hand-edits elsewhere alone.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_env HERDR_BIN_PATH

config="$(herdr_config_file)"

# The guards must be anchored exactly like the sed address below. An unanchored
# match would pass here for a marker line carrying stray whitespace while the
# sed range failed to match it, and a range whose end never matches deletes to
# end of file.
if ! grep -qxF "$MARKER_BEGIN" "$config" 2>/dev/null; then
  if grep -qF "$MARKER_BEGIN" "$config" 2>/dev/null; then
    die "$config has a modified '$MARKER_BEGIN' line (extra whitespace?); remove the block by hand"
  fi
  echo "no last-used block found in $config"
  exit 0
fi

grep -qxF "$MARKER_END" "$config" \
  || die "found $MARKER_BEGIN in $config but no exact closing $MARKER_END; remove the block by hand"

# The colours the README tells you to customise live inside this block.
if ! sed -n "/^${MARKER_BEGIN}\$/,/^${MARKER_END}\$/p" "$config" \
     | sed '1d;$d' | diff -q - "$(asset rows.snippet.toml)" >/dev/null 2>&1; then
  echo "note: the managed block differs from the shipped default (customised colours?);" >&2
  echo "      it is being removed — recover from the backup below if that was a mistake." >&2
fi

tmp="$config.tmp.$$"
sed "/^${MARKER_BEGIN}\$/,/^${MARKER_END}\$/d" "$config" > "$tmp"

# Never claim success without having changed anything.
if [[ "$(wc -l < "$tmp")" -ge "$(wc -l < "$config")" ]]; then
  rm -f "$tmp"
  die "the managed block in $config did not match for removal; remove it by hand"
fi

backup="$(backup_config "$config")"
# Write through the path rather than renaming over it, so a symlinked config
# stays a symlink and file permissions are preserved.
cat "$tmp" > "$config"
rm -f "$tmp"

echo "removed last-used rows from $config (backup: $backup)"
"$HERDR_BIN_PATH" server reload-config
