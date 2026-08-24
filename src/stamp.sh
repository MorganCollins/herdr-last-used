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
# than an edge case. Only one run may render at a time.
#
# A run that cannot take the lock still has something unique to contribute: the
# activity of the pane that triggered it. It appends that to a pending file for
# the winner to fold in, rather than dropping it.
lock="$state/lock"
pending="$state/pending"
now="$(date +%s)"
event_pane="${HERDR_PANE_ID:-}"

# Only ever release a lock we still own. Without this check, a holder whose
# lock was stolen goes on to delete the stealer's lock, admitting a third run.
release_lock() {
  [[ -d "$lock" ]] || return 0
  [[ "$(cat "$lock/pid" 2>/dev/null || true)" == "$$" ]] || return 0
  rm -f "$lock/pid" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
}

# Breaking a lock must be atomic, or two runs both "break" it and both proceed.
# Only the process whose rename succeeds owns the removal.
take_lock() {
  local attempt=0 holder age mtime steal
  while (( attempt < 5 )); do
    attempt=$(( attempt + 1 ))
    if mkdir "$lock" 2>/dev/null; then
      printf '%s' "$$" > "$lock/pid"
      return 0
    fi

    mtime="$(file_mtime "$lock")"
    case "$mtime" in ''|*[!0-9]*) mtime="$now" ;; esac
    age=$(( now - mtime ))
    (( age < 0 )) && age=0
    holder="$(cat "$lock/pid" 2>/dev/null || true)"

    if [[ -z "$holder" ]]; then
      # A holder that has not written its pid yet looks identical to debris.
      # Assume it is live until the lock is old enough that it cannot be.
      (( age < LOCK_GRACE_SECONDS )) && return 1
    elif kill -0 "$holder" 2>/dev/null; then
      # Alive — but a pid outlives its process and can be reused, which would
      # wedge every future event. A real run finishes in well under a second.
      (( age < LOCK_MAX_HOLD_SECONDS )) && return 1
      printf 'last-used: breaking a lock held for %ss by pid %s\n' "$age" "$holder" >&2
    fi

    # Steal by rename so exactly one contender wins, then retry mkdir. This also
    # covers the lock vanishing between the failed mkdir and here, and a $lock
    # that is somehow a plain file.
    steal="$lock.stale.$$"
    if mv "$lock" "$steal" 2>/dev/null; then
      rm -rf "$steal" 2>/dev/null || true
    fi
  done
  return 1
}

if ! take_lock; then
  # Hand the event to whoever holds the lock. Bounded, so a wedged lock cannot
  # grow this file without limit.
  if [[ -n "$event_pane" ]]; then
    queued=0
    [[ -f "$pending" ]] && queued="$(wc -l < "$pending")"
    if (( queued < PENDING_MAX_LINES )); then
      printf '%s\t%s\n' "$event_pane" "$now" >> "$pending"
    else
      printf 'last-used: %s already holds %s queued events; dropping this one\n' \
        "$pending" "$PENDING_MAX_LINES" >&2
    fi
  fi
  exit 0
fi

# bash 3.2 reports $? as 0 inside an EXIT trap for a set -u / set -e abort, so
# no $?-based trap can recover the real status and a crashed hook would be
# reported to herdr as a success. An explicit completion flag is the only
# reliable signal: reaching the end sets it, and anything else is a failure.
completed=0
cleanup() {
  cleanup_status=$?
  [[ -n "${next:-}" ]] && rm -f "$next" 2>/dev/null
  # Events claimed from the queue are only ours once we have committed them.
  # Deleting them on a failure path would silently discard the only record of
  # those panes' activity.
  if [[ -n "${claimed:-}" && -f "${claimed:-}" ]]; then
    (( completed == 1 )) || cat "$claimed" >> "$pending" 2>/dev/null
    rm -f "$claimed" 2>/dev/null
  fi
  release_lock
  if (( cleanup_status == 0 && completed == 0 )); then
    printf 'last-used: stamping aborted unexpectedly\n' >&2
    cleanup_status=1
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

load_thresholds

# Reading the herd is the plugin's one source of truth. Distinguish "no agents"
# from "could not read agents": swallowing the difference would make every path
# exit 0 having silently done nothing, freezing the sidebar with no diagnostic.
if ! agents_json="$("$HERDR_BIN_PATH" agent list 2>&1)"; then
  die "herdr agent list failed: $agents_json"
fi
[[ -n "$agents_json" ]] || die "herdr agent list produced no output"
# The CLI wraps its payload as {"id":..,"result":{"agents":[..]}}; the raw socket
# does the same. A bare {"agents":..} is accepted too so a future unwrapped
# response does not break this. Anything else — an error envelope has no agents
# key at either level — is a failure, not an empty herd.
if ! live="$(printf '%s' "$agents_json" | jq -r '
      (if type == "object" and (.result | type) == "object" then .result else . end) as $body
      | if ($body | type) != "object" or ($body | has("agents") | not) then
          "SHAPE_ERROR" | halt_error(3)
        elif $body.agents == null then
          empty
        elif ($body.agents | type) != "array" then
          "SHAPE_ERROR" | halt_error(3)
        else
          $body.agents[] | select(.pane_id != null and .pane_id != "")
          | [.pane_id, (.terminal_id // "")] | @tsv
        end' 2>&1)"; then
  die "could not parse herdr agent list output: ${live:-unexpected shape}"
fi

if [[ -z "$live" ]]; then
  completed=1
  exit 0
fi

# Per-run temp names: a fixed name would be truncated by a sibling run.
next="$stamps.next.$$"
: > "$next"

# Claim any activity recorded by runs that could not take the lock.
claimed="$next.pending"
if [[ -f "$pending" ]]; then
  mv "$pending" "$claimed" 2>/dev/null || true
fi

# Strictly increasing report sequence. Wall-clock seconds tie for every pane in
# a run and for any run in the same second, which orders nothing; this counter
# advances under the lock so it is monotonic per source.
seq_file="$state/seq"
seq_value="$(cat "$seq_file" 2>/dev/null || true)"
case "$seq_value" in ''|*[!0-9]*) seq_value=0 ;; esac

failures=0
reported=0
while IFS="$(printf '\t')" read -r pane terminal; do
  [[ -n "$pane" ]] || continue

  # Pane ids are reusable slots, so a new agent can land on a closed pane's id.
  # The terminal id distinguishes occupants: a change means a different agent,
  # which is stamped as first-seen rather than inheriting the dead one's age.
  stored="$(awk -F'\t' -v p="$pane" -v t="$terminal" \
    '$1 == p && $3 == t { v = $2 } END { if (v != "") print v }' "$stamps" 2>/dev/null || true)"
  # A corrupt line must not reach the arithmetic below, where set -u would
  # abort the run.
  case "$stored" in *[!0-9]*) stored="" ;; esac

  # A pending event from a run that lost the lock counts as activity too.
  pending_epoch=""
  if [[ -f "$claimed" ]]; then
    pending_epoch="$(awk -F'\t' -v p="$pane" \
      '$1 == p && $2 ~ /^[0-9]+$/ { if ($2 > v) v = $2 } END { if (v != "") print v }' "$claimed")"
  fi

  if [[ "$pane" == "$event_pane" || -z "$stored" ]]; then
    epoch="$now"
  else
    epoch="$stored"
  fi
  # A queued event can only make a pane more recent, never less. Preferring the
  # queued value outright would let an old event resurrect the age of a pane
  # that a different agent has since taken over.
  if [[ -n "$pending_epoch" ]] && (( pending_epoch > epoch )); then
    epoch="$pending_epoch"
  fi
  printf '%s\t%s\t%s\n' "$pane" "$epoch" "$terminal" >> "$next"

  # A clock-skewed future stamp is normalised, so it cannot sort ahead of
  # genuinely recent panes via the $used_at token.
  (( epoch > now )) && epoch="$now"
  age=$(( now - epoch ))

  # One bad pane must not abort the loop: the design depends on re-rendering
  # every pane, and an abort would also skip the state commit below.
  seq_value=$(( seq_value + 1 ))
  if report_stamp "$pane" \
      "$(bucket_for_age "$age" "$FRESH_SECS" "$STALE_SECS")" \
      "$STAMP_LABEL $(format_stamp "$epoch" "$now")" "$epoch" "$seq_value"; then
    reported=$(( reported + 1 ))
  else
    failures=$(( failures + 1 ))
    printf 'last-used: could not report metadata for pane %s\n' "$pane" >&2
  fi
done <<< "$live"

# A CLI that consumed stdin would have ended the loop early; committing a
# truncated file would destroy every remaining pane's recorded history.
expected_panes="$(printf '%s\n' "$live" | grep -c .)"
if (( reported + failures != expected_panes )); then
  die "processed $(( reported + failures )) of $expected_panes agents; refusing to commit a partial state file"
fi

mv "$next" "$stamps"
next=""
printf '%s' "$seq_value" > "$seq_file"

if (( reported == 0 && failures > 0 )); then
  die "every pane report failed ($failures panes)"
fi

completed=1
