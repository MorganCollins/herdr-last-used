#!/usr/bin/env bash
# Records the event pane's activity time, then re-renders every live agent's
# stamp. Re-rendering all of them is what keeps the colour buckets and the
# day-aware format current as time passes, without a background daemon.
# Written for bash 3.2, which is what macOS ships.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source lib.sh

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required: brew install jq" >&2
  exit 0
fi

fresh_secs=$(( $(read_int_setting fresh_max_hours 24) * 3600 ))
stale_secs=$(( $(read_int_setting stale_max_hours 168) * 3600 ))

state="$(state_dir)"
mkdir -p "$state"
stamps="$state/stamps"
touch "$stamps"

now="$(date +%s)"

# The pane that triggered this event counts as used now. Startup hooks and the
# refresh action carry no pane, and only re-render.
event_pane="${HERDR_PANE_ID:-}"
if [[ -n "$event_pane" ]]; then
  grep -v "^${event_pane}	" "$stamps" > "$stamps.tmp" 2>/dev/null || true
  touch "$stamps.tmp"
  printf '%s\t%s\n' "$event_pane" "$now" >> "$stamps.tmp"
  mv "$stamps.tmp" "$stamps"
fi

live="$state/live"
live_pane_ids > "$live"
[[ -s "$live" ]] || exit 0

# Rebuild the state file from live panes only, so closed panes drop out.
: > "$stamps.next"
while IFS= read -r pane; do
  [[ -n "$pane" ]] || continue
  epoch="$(awk -F'\t' -v p="$pane" '$1 == p { print $2 }' "$stamps" | tail -n 1)"
  # A pane already running when the plugin was installed has no recorded
  # epoch; treat first sight as now rather than inventing history.
  [[ -n "$epoch" ]] || epoch="$now"
  printf '%s\t%s\n' "$pane" "$epoch" >> "$stamps.next"

  age=$(( now - epoch ))
  (( age < 0 )) && age=0
  report_stamp "$pane" \
    "$(bucket_for_age "$age" "$fresh_secs" "$stale_secs")" \
    "$(format_stamp "$epoch" "$now")"
done < "$live"
mv "$stamps.next" "$stamps"
rm -f "$live"
