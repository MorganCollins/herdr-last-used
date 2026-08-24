#!/usr/bin/env bash
# Records the event pane's activity time, then re-renders every live agent's
# stamp. Re-rendering all of them is what keeps the colour buckets and the
# day-aware format current as time passes, without a background daemon.
# Written for bash 3.2, which is what macOS ships.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools jq
require_env HERDR_BIN_PATH
state="$(state_dir)"
mkdir -p "$state"
stamps="$state/stamps"

# Herdr spawns one hook process per event, and pane.agent_detected fires
# alongside pane.agent_status_changed, so overlapping runs are the norm rather
# than an edge case. Every run is a full idempotent re-render, so a run that
# loses the lock has nothing to add — it exits instead of queueing a duplicate.
# mkdir is the portable test-and-set; flock is not on stock macOS.
lock="$state/lock"
if ! mkdir "$lock" 2>/dev/null; then
  # A lock left by a killed process would block every future run, so break one
  # that is clearly stale rather than failing forever.
  if [[ -n "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ]]; then
    rmdir "$lock" 2>/dev/null || true
    mkdir "$lock" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

now="$(date +%s)"
load_thresholds

# Reading the herd is the plugin's one source of truth. Distinguish "no agents"
# from "could not read agents": swallowing the difference would make every path
# exit 0 having silently done nothing, freezing the sidebar with no diagnostic.
if ! agents_json="$("$HERDR_BIN_PATH" agent list 2>&1)"; then
  die "herdr agent list failed: $agents_json"
fi
[[ -n "$agents_json" ]] || die "herdr agent list produced no output"
if ! live="$(printf '%s' "$agents_json" | jq -r '
      if type != "object" or has("agents") != true then
        "SHAPE_ERROR" | halt_error(3)
      else
        .agents[] | select(.pane_id != null and .pane_id != "")
        | [.pane_id, (.terminal_id // "")] | @tsv
      end' 2>&1)"; then
  die "could not parse herdr agent list output: ${live:-unexpected shape}"
fi

[[ -n "$live" ]] || exit 0

# Per-run temp names: a fixed name would be truncated by a sibling run.
next="$stamps.next.$$"
trap 'rm -f "$next"; rmdir "$lock" 2>/dev/null || true' EXIT
: > "$next"

# The pane that triggered this event counts as used now. Startup and the
# refresh action carry no pane and only re-render.
event_pane="${HERDR_PANE_ID:-}"

failures=0
reported=0
while IFS="$(printf '\t')" read -r pane terminal; do
  [[ -n "$pane" ]] || continue

  # Pane ids are reusable slots, so a new agent can land on a closed pane's id.
  # The terminal id distinguishes occupants: a change means a different agent,
  # which is stamped as first-seen rather than inheriting the dead one's age.
  stored="$(awk -F'\t' -v p="$pane" -v t="$terminal" \
    '$1 == p && $3 == t { v = $2 } END { if (v != "") print v }' "$stamps" 2>/dev/null || true)"

  if [[ "$pane" == "$event_pane" || -z "$stored" ]]; then
    epoch="$now"
  else
    epoch="$stored"
  fi
  printf '%s\t%s\t%s\n' "$pane" "$epoch" "$terminal" >> "$next"

  age=$(( now - epoch ))
  (( age < 0 )) && age=0

  # One bad pane must not abort the loop: the design depends on re-rendering
  # every pane, and an abort would also skip the state commit below.
  if report_stamp "$pane" \
      "$(bucket_for_age "$age" "$FRESH_SECS" "$STALE_SECS")" \
      "$(format_stamp "$epoch" "$now")" "$epoch" "$now"; then
    reported=$(( reported + 1 ))
  else
    failures=$(( failures + 1 ))
    printf 'last-used: could not report metadata for pane %s\n' "$pane" >&2
  fi
done <<< "$live"

mv "$next" "$stamps"
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

if (( reported == 0 && failures > 0 )); then
  die "every pane report failed ($failures panes)"
fi
