#!/usr/bin/env bash
# Shared helpers for the last-used plugin. Targets bash 3.2 (macOS default).

# Resolve our own location so scripts work from any cwd. Herdr runs plugin
# commands from the plugin root, but the tests and manual runs do not.
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"

# Display tokens. Exactly one of the three colour tokens carries a value at a
# time; the sidebar row declares all three with different fg, so one shows.
# TOKEN_SORT holds a zero-padded epoch that never renders — display labels sort
# lexicographically, which is meaningless for recency, so views sort on this.
TOKEN_FRESH="used_fresh"
TOKEN_STALE="used_stale"
TOKEN_OLD="used_old"
TOKEN_SORT="used_at"

# Delimiters for the block install-rows.sh manages in the user's config.
# Both scripts must agree or uninstall silently stops matching.
MARKER_BEGIN="# >>> herdr-last-used"
MARKER_END="# <<< herdr-last-used"

DEFAULT_FRESH_HOURS=24
DEFAULT_STALE_HOURS=168

die() {
  printf 'last-used: %s\n' "$1" >&2
  exit 1
}

# Herdr always injects these. Guessing a fallback path would silently read and
# write a different directory than the real one, so require them instead.
require_env() {
  local name
  for name in "$@"; do
    eval "[[ -n \"\${$name:-}\" ]]" || die "$name is not set; this must run as a herdr plugin command"
  done
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required but not installed"
  done
}

plugin_id() {
  require_env HERDR_PLUGIN_ID
  printf '%s' "$HERDR_PLUGIN_ID"
}

metadata_source() {
  printf 'plugin:%s' "$(plugin_id)"
}

state_dir() {
  require_env HERDR_PLUGIN_STATE_DIR
  printf '%s' "$HERDR_PLUGIN_STATE_DIR"
}

herdr_config_file() {
  printf '%s' "${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"
}

asset() {
  printf '%s/assets/%s' "$PLUGIN_ROOT" "$1"
}

# BSD date takes -r, GNU date takes -d @epoch. Probe once at source time; this
# is called several times per pane inside stamp.sh's loop.
if date -r 0 +%s >/dev/null 2>&1; then
  DATE_STYLE=bsd
else
  DATE_STYLE=gnu
fi

fmt_epoch() {
  if [[ "$DATE_STYLE" == "bsd" ]]; then
    date -r "$1" +"$2"
  else
    date -d "@$1" +"$2"
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

# One flat `key = <integer>` pair from the plugin's config.toml. A value that is
# not a whole number is rejected rather than truncated, and comments are
# stripped first so a commented-out line never matches.
read_int_setting() {
  local key="$1" fallback="$2" file value
  require_env HERDR_PLUGIN_CONFIG_DIR
  file="$HERDR_PLUGIN_CONFIG_DIR/config.toml"
  [[ -f "$file" ]] || { printf '%s' "$fallback"; return; }
  value="$(awk -v key="$key" '
    { sub(/[[:space:]]*#.*$/, "") }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      candidate = $0
      sub(/^[^=]*=[[:space:]]*/, "", candidate)
      sub(/[[:space:]]*$/, "", candidate)
      if (candidate ~ /^[0-9]+$/) { found = candidate }
    }
    END { if (found != "") print found }
  ' "$file")"
  [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$fallback"
}

# Sets FRESH_SECS and STALE_SECS. The whole three-bucket design rests on
# 0 < fresh < stale, so an invalid pair falls back to defaults loudly rather
# than making a bucket silently unreachable.
load_thresholds() {
  local fresh stale
  fresh="$(read_int_setting fresh_max_hours "$DEFAULT_FRESH_HOURS")"
  stale="$(read_int_setting stale_max_hours "$DEFAULT_STALE_HOURS")"
  if (( fresh <= 0 || stale <= fresh )); then
    printf 'last-used: ignoring thresholds in %s/config.toml (need 0 < fresh_max_hours < stale_max_hours, got %s and %s); using %s and %s\n' \
      "$HERDR_PLUGIN_CONFIG_DIR" "$fresh" "$stale" "$DEFAULT_FRESH_HOURS" "$DEFAULT_STALE_HOURS" >&2
    fresh="$DEFAULT_FRESH_HOURS"
    stale="$DEFAULT_STALE_HOURS"
  fi
  FRESH_SECS=$(( fresh * 3600 ))
  STALE_SECS=$(( stale * 3600 ))
}

# Set one colour token, clear the other two, and carry a sortable epoch.
# --seq makes ordering explicit: concurrent runs share one source, and the
# platform keeps the latest report by arrival, not by event time.
report_stamp() {
  local pane_id="$1" bucket="$2" label="$3" epoch="$4" seq="$5" args=() token
  for token in "$TOKEN_FRESH" "$TOKEN_STALE" "$TOKEN_OLD"; do
    if [[ "$token" == "$bucket" ]]; then
      args+=(--token "${token}=${label}")
    else
      args+=(--clear-token "$token")
    fi
  done
  args+=(--token "$(printf '%s=%010d' "$TOKEN_SORT" "$epoch")")
  "${HERDR_BIN_PATH:?HERDR_BIN_PATH is not set}" pane report-metadata "$pane_id" \
    --source "$(metadata_source)" --seq "$seq" "${args[@]}" >/dev/null
}

backup_config() {
  local file="$1" backup
  backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$file" "$backup" || die "could not back up $file"
  printf '%s' "$backup"
}
