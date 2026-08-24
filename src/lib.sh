#!/usr/bin/env bash
# Shared helpers for the last-used plugin.

# Resolve our own location so scripts work from any cwd. Herdr runs plugin
# commands from the plugin root, but the tests and manual runs do not.
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"

HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
PLUGIN_ID="${HERDR_PLUGIN_ID:-morgancollins.last-used}"
METADATA_SOURCE="plugin:${PLUGIN_ID}"

TOKEN_FRESH="used_fresh"
TOKEN_STALE="used_stale"
TOKEN_OLD="used_old"

state_dir() {
  printf '%s' "${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr/$PLUGIN_ID}"
}

plugin_config_file() {
  printf '%s/config.toml' "${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/$PLUGIN_ID}"
}

asset() {
  printf '%s/assets/%s' "$PLUGIN_ROOT" "$1"
}

herdr_config_file() {
  printf '%s' "${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"
}

# Read one flat `key = <integer>` pair from the plugin's config.toml.
# Commented lines never match because the pattern is anchored to the key.
read_int_setting() {
  local key="$1" fallback="$2" file value
  file="$(plugin_config_file)"
  [[ -f "$file" ]] || { printf '%s' "$fallback"; return; }
  value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$file" | tail -n 1)"
  [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$fallback"
}

# BSD date takes -r, GNU date takes -d @epoch. Detect once per run.
fmt_epoch() {
  local epoch="$1" format="$2"
  if date -r 0 +%s >/dev/null 2>&1; then
    date -r "$epoch" +"$format"
  else
    date -d "@$epoch" +"$format"
  fi
}

# Adaptive absolute stamp: time today, weekday+time this week, date beyond that.
format_stamp() {
  local epoch="$1" now="$2" age
  age=$(( now - epoch ))
  if [[ "$(fmt_epoch "$epoch" %F)" == "$(fmt_epoch "$now" %F)" ]]; then
    fmt_epoch "$epoch" "%H:%M"
  elif (( age < 6 * 86400 )); then
    fmt_epoch "$epoch" "%a %H:%M"
  else
    fmt_epoch "$epoch" "%d %b" | sed 's/^0//'
  fi
}

# Which of the three colour tokens this age belongs in.
bucket_for_age() {
  local age="$1" fresh_secs="$2" stale_secs="$3"
  if (( age < fresh_secs )); then
    printf '%s' "$TOKEN_FRESH"
  elif (( age < stale_secs )); then
    printf '%s' "$TOKEN_STALE"
  else
    printf '%s' "$TOKEN_OLD"
  fi
}

# Set exactly one colour token and clear the other two, so the sidebar row
# renders a single value in one colour. Empty tokens and their separators vanish.
report_stamp() {
  local pane_id="$1" bucket="$2" label="$3" args=() token
  for token in "$TOKEN_FRESH" "$TOKEN_STALE" "$TOKEN_OLD"; do
    if [[ "$token" == "$bucket" ]]; then
      args+=(--token "${token}=${label}")
    else
      args+=(--clear-token "$token")
    fi
  done
  "$HERDR_BIN" pane report-metadata "$pane_id" --source "$METADATA_SOURCE" "${args[@]}" >/dev/null
}

live_pane_ids() {
  "$HERDR_BIN" agent list 2>/dev/null | jq -r '.agents[]?.pane_id' 2>/dev/null || true
}
