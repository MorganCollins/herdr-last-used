#!/usr/bin/env bash
# Test suite for the last-used plugin. Runs on bash 3.2.
#
# The herdr CLI is the plugin's only system boundary, so it is the only thing
# stubbed (test/fake-herdr). The socket path is exercised against a real unix
# socket rather than a mock, so the framing itself is under test.
#
# Fixed TZ so date formatting is machine-independent.
set -uo pipefail
export TZ=Europe/London

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Each test runs in a subshell, so results are tallied through files. A crashing
# subshell writes no result at all, so the count is also asserted at the end.
TALLY="$(mktemp -d)"
SANDBOX_ROOT="$(mktemp -d)"
export TALLY SANDBOX_ROOT
trap 'rm -rf "$TALLY" "$SANDBOX_ROOT"' EXIT

pass() { printf 'P\n' >> "$TALLY/results"; printf '%s\n' "$1" >> "$TALLY/names"; printf '  ok   %s\n' "$1"; }
fail() { printf 'F\n' >> "$TALLY/results"; printf '%s\n' "$1" >> "$TALLY/names"; printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$3" "$2"; }

check() { # name actual expected
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

group() { printf '\n%s\n' "$1"; }

new_env() {
  SANDBOX="$(mktemp -d "$SANDBOX_ROOT/case.XXXXXX")"
  export HERDR_PLUGIN_STATE_DIR="$SANDBOX/state"
  export HERDR_PLUGIN_CONFIG_DIR="$SANDBOX/config"
  export HERDR_PLUGIN_ID="test.last-used"
  export FAKE_HERDR_LOG="$SANDBOX/calls.log"
  export FAKE_HERDR_AGENTS="$SANDBOX/agents.json"
  export HERDR_BIN_PATH="$ROOT/test/fake-herdr"
  mkdir -p "$HERDR_PLUGIN_STATE_DIR" "$HERDR_PLUGIN_CONFIG_DIR"
  : > "$FAKE_HERDR_LOG"
  : > "$FAKE_HERDR_AGENTS"
  # Never inherit a real server socket or config: a test must not be able to
  # reach the developer's running herdr. Point at a path with no listener.
  export HERDR_SOCKET_PATH="$SANDBOX/no-such.sock"
  export HERDR_CONFIG_PATH="$SANDBOX/herdr.toml"
  unset HERDR_PANE_ID FAKE_HERDR_FAIL FAKE_HERDR_FAIL_AFTER
  unset XDG_STATE_HOME XDG_CONFIG_HOME
}

agents() { # pane_id[:terminal_id]...
  local first=1 pane terminal
  {
    printf '{"type":"agent_list","agents":['
    for spec in "$@"; do
      pane="${spec%%:terminal=*}"
      if [[ "$spec" == *:terminal=* ]]; then terminal="${spec##*:terminal=}"; else terminal="t-$pane"; fi
      [[ $first -eq 1 ]] || printf ','
      first=0
      printf '{"pane_id":"%s","terminal_id":"%s","agent_status":"idle","workspace_id":"w1","tab_id":"w1:t1","focused":false,"revision":1}' \
        "$pane" "$terminal"
    done
    printf ']}\n'
  } > "$FAKE_HERDR_AGENTS"
}

report_for() { grep "^pane report-metadata $1 " "$FAKE_HERDR_LOG" | tail -n 1; }
reported_panes() { grep '^pane report-metadata' "$FAKE_HERDR_LOG" | awk '{print $3}' | sort | tr '\n' ' '; }
set_stamp() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-t-$1}" >> "$HERDR_PLUGIN_STATE_DIR/stamps"; }

# The exact call report_stamp should produce, so tests assert the whole line
# rather than grepping for one fragment of it.
expect_report() { # pane bucket label epoch seq
  local pane="$1" bucket="$2" label="$3" epoch="$4" seq="$5" out token
  out="pane report-metadata $pane --source plugin:test.last-used --seq $seq"
  for token in used_fresh used_stale used_old; do
    if [[ "$token" == "$bucket" ]]; then out="$out --token $token=$label"; else out="$out --clear-token $token"; fi
  done
  printf '%s --token used_at=%010d' "$out" "$epoch"
}

# Tools the fixtures need. Checked up front so a missing one is reported as
# itself rather than surfacing as an aborted test.
STUB_TOOLS="bash env date grep mv touch mkdir awk tail cut sed cat rm wc dirname find rmdir printf kill ls diff"
for tool in $STUB_TOOLS jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'PREFLIGHT: host is missing %s\n' "$tool"; exit 1; }
done

seed_config() {
  printf '[ui]\nagent_panel_scope = "all"\n\n[ui.toast]\ndelivery = "system"\n' > "$HERDR_CONFIG_PATH"
}

# Anything the plugin should never leave in its state directory.
state_residue() { ls "$HERDR_PLUGIN_STATE_DIR" 2>/dev/null | grep -cE 'next|tmp|live|lock|pending' || true; }

# A fixed epoch, so nothing depends on the wall clock at assertion time.
FIXED_NOW="$(TZ=Europe/London date -j -f '%Y-%m-%d %H:%M:%S' '2026-08-24 15:00:00' +%s 2>/dev/null \
  || TZ=Europe/London date -d '2026-08-24 15:00:00' +%s)"

group "lib.sh: stamp formatting"
(
  source "$ROOT/src/lib.sh"
  base="$FIXED_NOW"
  check "same day renders time only"        "$(format_stamp $((base - 28*60)) $base)"   "14:32"
  check "midnight boundary is still today"  "$(format_stamp $((base - 15*3600)) $base)" "00:00"
  check "three days renders weekday"        "$(format_stamp $((base - 3*86400)) $base)" "Fri 15:00"
  check "twelve days renders date"          "$(format_stamp $((base - 12*86400)) $base)" "12 Aug"
  check "single-digit day has no zero pad"  "$(format_stamp $((base - 19*86400)) $base)" "5 Aug"
  # The 6-day cutoff between weekday and date form.
  check "one second inside six days"        "$(format_stamp $((base - (6*86400 - 1))) $base)" "Tue 15:00"
  check "exactly six days switches to date" "$(format_stamp $((base - 6*86400)) $base)" "18 Aug"

  # DST: London springs forward 2026-03-29 01:00 and falls back 2026-10-25 02:00.
  # A calendar day is not always 86400 seconds, so a fixed-seconds age and a
  # calendar-day comparison can disagree. These pin the rendered local time.
  spring="$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-03-29 12:00:00' +%s 2>/dev/null || date -d '2026-03-29 12:00:00' +%s)"
  # 24h before noon on transition day is 11:00 the previous day, not 12:00:
  # the clocks moved forward in between.
  check "24h back across spring forward shifts an hour" \
    "$(format_stamp $((spring - 86400)) $spring)" "Sat 11:00"
  # Same calendar day either side of the jump still renders as today — and 11
  # hours before noon is midnight, not 01:00, because an hour disappeared.
  check "same day across spring forward stays today" \
    "$(format_stamp $((spring - 11*3600)) $spring)" "00:00"
  autumn="$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-10-25 12:00:00' +%s 2>/dev/null || date -d '2026-10-25 12:00:00' +%s)"
  check "24h back across autumn fallback shifts an hour" \
    "$(format_stamp $((autumn - 86400)) $autumn)" "Sat 13:00"
  # Six calendar days back across a transition is 6*86400 minus an hour, which
  # must still land inside the weekday window rather than flipping to a date.
  six="$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-03-31 12:00:00' +%s 2>/dev/null || date -d '2026-03-31 12:00:00' +%s)"
  check "six calendar days across a transition stays weekday form" \
    "$(format_stamp $((six - (6*86400 - 3600))) $six)" "Wed 12:00"
)

group "lib.sh: age buckets"
(
  source "$ROOT/src/lib.sh"
  fresh=$((24*3600)); stale=$((168*3600))
  check "an agent used just now is active"            "$(bucket_for_age 0 $fresh $stale)"              "used_fresh"
  check "an agent used just under a day ago is active"        "$(bucket_for_age $((fresh - 1)) $fresh $stale)" "used_fresh"
  check "an agent used a day ago is stale"         "$(bucket_for_age $fresh $fresh $stale)"         "used_stale"
  check "an agent used just under a week ago is stale"   "$(bucket_for_age $((stale - 1)) $fresh $stale)" "used_stale"
  check "an agent used a week ago is inactive" "$(bucket_for_age $stale $fresh $stale)"         "used_old"
  check "an agent used a year ago is inactive"           "$(bucket_for_age $((365*86400)) $fresh $stale)" "used_old"
)

group "lib.sh: settings"
(
  source "$ROOT/src/lib.sh"; new_env
  settings="$HERDR_PLUGIN_CONFIG_DIR/config.toml"

  printf '# fresh_max_hours = 99\nfresh_max_hours = 12\nstale_max_hours=48\n' > "$settings"
  check "a configured threshold is used"        "$(read_int_setting fresh_max_hours 24)"  "12"
  check "a setting without spaces around = is read"  "$(read_int_setting stale_max_hours 168)" "48"
  check "a commented-out setting is ignored"   "$(read_int_setting fresh_max_hours 24)"  "12"
  check "an absent setting uses the default"     "$(read_int_setting nope 7)"              "7"

  # Hostile values must not be silently truncated or silently accepted.
  printf 'fresh_max_hours = 1.5\n' > "$settings"
  check "a fraction is rejected, not truncated" "$(read_int_setting fresh_max_hours 24)" "24"
  printf 'fresh_max_hours = -1\n' > "$settings"
  check "a negative is rejected"        "$(read_int_setting fresh_max_hours 24)" "24"
  printf 'fresh_max_hours = abc\n' > "$settings"
  check "a non-number is rejected"      "$(read_int_setting fresh_max_hours 24)" "24"
  printf 'fresh_max_hours = 0\n' > "$settings"
  check "a zero setting is read as zero"       "$(read_int_setting fresh_max_hours 24)" "0"
  printf 'fresh_max_hours = 6 # trailing comment\n' > "$settings"
  check "a setting with a trailing comment is read" "$(read_int_setting fresh_max_hours 24)" "6"
  rm -f "$settings"
  check "no config file means defaults"     "$(read_int_setting fresh_max_hours 24)" "24"
)

group "lib.sh: threshold validation"
(
  source "$ROOT/src/lib.sh"; new_env
  settings="$HERDR_PLUGIN_CONFIG_DIR/config.toml"

  printf 'fresh_max_hours = 12\nstale_max_hours = 48\n' > "$settings"
  load_thresholds
  check "a valid threshold pair is used"  "$FRESH_SECS $STALE_SECS" "43200 172800"

  # An inverted pair would make the stale bucket, and the show-stale action,
  # permanently unreachable. Defaults with a warning beats a silent dead bucket.
  printf 'fresh_max_hours = 48\nstale_max_hours = 12\n' > "$settings"
  err="$(load_thresholds 2>&1 >/dev/null)"
  load_thresholds 2>/dev/null
  check "an inverted threshold pair falls back to defaults"     "$FRESH_SECS $STALE_SECS" "86400 604800"
  check "an inverted threshold pair is explained"          "$(printf '%s' "$err" | grep -c 'ignoring thresholds')" "1"

  printf 'fresh_max_hours = 0\nstale_max_hours = 48\n' > "$settings"
  load_thresholds 2>/dev/null
  check "a zero threshold falls back to defaults"        "$FRESH_SECS $STALE_SECS" "86400 604800"
)

group "lib.sh: required environment"
(
  source "$ROOT/src/lib.sh"; new_env
  unset HERDR_PLUGIN_STATE_DIR
  out="$(state_dir 2>&1)"; code=$?
  check "running outside herdr fails loudly" "$code" "1"
  check "running outside herdr says what is missing" "$(printf '%s' "$out" | grep -c 'HERDR_PLUGIN_STATE_DIR')" "1"
)

group "stamp.sh: reporting"
(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  # Seed a known epoch and take no event, so the expected label is computed
  # from that epoch rather than read off the clock after the run.
  seeded=$(( $(date +%s) - 30*3600 ))
  set_stamp w1:p1 "$seeded"
  bash "$ROOT/src/stamp.sh"
  check "a stale agent is stamped with its band and time" "$(report_for w1:p1)" \
    "$(expect_report w1:p1 used_stale "$(format_stamp "$seeded" "$(date +%s)")" "$seeded" 1)"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1 w1:p2
  # Reports must carry a strictly increasing sequence, or herdr falls back to
  # arrival order and a slow older run can overwrite a newer stamp.
  bash "$ROOT/src/stamp.sh"
  check "each report carries an increasing sequence" \
    "$(grep -oE '\-\-seq [0-9]+' "$FAKE_HERDR_LOG" | awk '{print $2}' | tr '\n' ' ')" "1 2 "
  bash "$ROOT/src/stamp.sh"
  check "sequences keep increasing across runs" \
    "$(grep -oE '\-\-seq [0-9]+' "$FAKE_HERDR_LOG" | awk '{print $2}' | tr '\n' ' ')" "1 2 3 4 "
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1 w1:p2 w2:p1
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/src/stamp.sh"
  check "every live agent is stamped, not only the one that changed" \
    "$(reported_panes)" "w1:p1 w1:p2 w2:p1 "
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  seeded=$(( $(date +%s) - 20*86400 ))
  set_stamp w1:p1 "$seeded"
  bash "$ROOT/src/stamp.sh"
  check "an agent untouched for three weeks reads as inactive" "$(report_for w1:p1)" \
    "$(expect_report w1:p1 used_old "$(format_stamp "$seeded" "$(date +%s)")" "$seeded" 1)"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  set_stamp w1:p1 $(( $(date +%s) - 30*3600 ))
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/src/stamp.sh"
  stamped="$(awk -F'\t' '/^w1:p1\t/{print $2}' "$HERDR_PLUGIN_STATE_DIR/stamps")"
  check "using a stale agent makes it active again" "$(report_for w1:p1)" \
    "$(expect_report w1:p1 used_fresh "$(format_stamp "$stamped" "$stamped")" "$stamped" 1)"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/src/stamp.sh"
  # The sortable token must be the zero-padded epoch, not the display label.
  epoch="$(awk -F'\t' '/^w1:p1\t/{print $2}' "$HERDR_PLUGIN_STATE_DIR/stamps")"
  check "each agent carries a value that sorts by recency" \
    "$(report_for w1:p1 | grep -oE '\-\-token used_at=[0-9]+' )" \
    "--token used_at=$(printf '%010d' "$epoch")"
)

group "stamp.sh: pane identity"
(
  source "$ROOT/src/lib.sh"; new_env
  # A closed pane's id can be reused by a new agent. Inheriting the dead
  # agent's timestamp would show a brand-new agent as inactive.
  old=$(( $(date +%s) - 30*86400 ))
  set_stamp w1:p1 "$old" "t-old"
  agents "w1:p1:terminal=t-new"
  bash "$ROOT/src/stamp.sh"
  check "a new agent in a reused slot does not inherit an age" \
    "$(report_for w1:p1 | grep -oE '\-\-token used_(fresh|stale|old)=')" "--token used_fresh="
)

(
  source "$ROOT/src/lib.sh"; new_env
  old=$(( $(date +%s) - 30*86400 ))
  set_stamp w1:p1 "$old" "t-same"
  agents "w1:p1:terminal=t-same"
  bash "$ROOT/src/stamp.sh"
  check "an agent that stayed put keeps its age" "$(report_for w1:p1)" \
    "$(expect_report w1:p1 used_old "$(format_stamp "$old" "$(date +%s)")" "$old" 1)"
)

group "stamp.sh: state file"
(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1 w1:p2
  set_stamp w1:p9 100
  set_stamp w1:p1 200
  bash "$ROOT/src/stamp.sh"
  check "an agent that has gone away is forgotten" \
    "$(cut -f1 "$HERDR_PLUGIN_STATE_DIR/stamps" | sort | tr '\n' ' ')" "w1:p1 w1:p2 "
  check "an agent that was not used keeps its earlier time" \
    "$(awk -F'\t' '$1=="w1:p1"{print $2}' "$HERDR_PLUGIN_STATE_DIR/stamps")" "200"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/src/stamp.sh"
  first="$(awk -F'\t' '$1=="w1:p1"{print $2}' "$HERDR_PLUGIN_STATE_DIR/stamps")"
  unset HERDR_PANE_ID
  bash "$ROOT/src/stamp.sh"
  second="$(awk -F'\t' '$1=="w1:p1"{print $2}' "$HERDR_PLUGIN_STATE_DIR/stamps")"
  check "refreshing does not make idle agents look used" "$second" "$first"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/src/stamp.sh"
  bash "$ROOT/src/stamp.sh"
  code=$?
  check "refreshing twice succeeds" "$code" "0"
  check "an agent is remembered once, not once per event" "$(wc -l < "$HERDR_PLUGIN_STATE_DIR/stamps" | tr -d ' ')" "1"
  check "a completed run leaves no working files" \
    "$(ls "$HERDR_PLUGIN_STATE_DIR" | grep -cE 'next|tmp|live')" "0"
)

group "stamp.sh: concurrency"
(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1 w1:p2 w2:p1
  # Seed every pane as stale, so an event that gets dropped is visible: its
  # pane keeps the old epoch instead of being refreshed. Without this the test
  # passes for a single run, because an unseeded pane is stamped "now" anyway.
  old=$(( $(date +%s) - 30*3600 ))
  set_stamp w1:p1 "$old"; set_stamp w1:p2 "$old"; set_stamp w2:p1 "$old"
  start="$(date +%s)"

  # Both hooks fire together when an agent appears, so overlapping runs are the
  # normal case. Losing runs hand their event to the winner via the pending
  # file; a final run folds in anything recorded after the last winner started.
  for pane in w1:p1 w1:p2 w2:p1; do
    HERDR_PANE_ID="$pane" bash "$ROOT/src/stamp.sh" &
  done
  wait
  bash "$ROOT/src/stamp.sh"

  stale_rows=0
  while IFS="$(printf '\t')" read -r pane epoch terminal; do
    [[ -n "$epoch" ]] || continue
    (( epoch < start )) && stale_rows=$(( stale_rows + 1 ))
  done < "$HERDR_PLUGIN_STATE_DIR/stamps"
  check "no concurrent event loses its stamp" "$stale_rows" "0"

  check "simultaneous events remember each agent once" \
    "$(cut -f1 "$HERDR_PLUGIN_STATE_DIR/stamps" | sort | tr '\n' ' ')" "w1:p1 w1:p2 w2:p1 "
  check "simultaneous events do not duplicate an agent" "$(wc -l < "$HERDR_PLUGIN_STATE_DIR/stamps" | tr -d ' ')" "3"
  check "simultaneous runs leave no working files" "$(state_residue)" "0"
)

group "stamp.sh: locking"
(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  # A live holder must be respected, and the contender's event preserved for
  # the holder to fold in rather than dropped.
  mkdir -p "$HERDR_PLUGIN_STATE_DIR/lock"
  printf '%s' "$$" > "$HERDR_PLUGIN_STATE_DIR/lock/pid"
  HERDR_PANE_ID=w1:p1 bash "$ROOT/src/stamp.sh"; code=$?
  check "an event arriving mid-render succeeds"      "$code" "0"
  check "an event arriving mid-render does not stamp twice"    "$(grep -c '^pane report-metadata' "$FAKE_HERDR_LOG")" "0"
  check "an event arriving mid-render is kept, not lost"  "$(cut -f1 "$HERDR_PLUGIN_STATE_DIR/pending")" "w1:p1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  # A killed run never runs its trap. Its lock names a dead pid, and must not
  # blackhole every later event.
  mkdir -p "$HERDR_PLUGIN_STATE_DIR/lock"
  printf '%s' "999999" > "$HERDR_PLUGIN_STATE_DIR/lock/pid"
  HERDR_PANE_ID=w1:p1 bash "$ROOT/src/stamp.sh"; code=$?
  check "a killed run does not block the next event"   "$code" "0"
  check "an event after a killed run is still stamped" "$(reported_panes)" "w1:p1 "
  check "recovering from a killed run leaves no working files"      "$(state_residue)" "0"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  # A lock directory with no pid file at all is also unowned.
  mkdir -p "$HERDR_PLUGIN_STATE_DIR/lock"
  HERDR_PANE_ID=w1:p1 bash "$ROOT/src/stamp.sh"
  check "an unowned leftover does not block events" "$(reported_panes)" "w1:p1 "
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  # A run that aborts must not report success, or herdr records the hook as fine.
  # lib.sh must resolve beside the copy, or sourcing fails before the trap is
  # installed and the exit code would be right for the wrong reason.
  ln -sf "$ROOT/src/lib.sh" "$SANDBOX/lib.sh"
  sed 's/^load_thresholds$/load_thresholds\nboom=$(( 1 - THIS_IS_UNSET ))/' "$ROOT/src/stamp.sh" \
    > "$SANDBOX/broken.sh"
  out="$(bash "$SANDBOX/broken.sh" 2>&1)"; code=$?
  check "a run that crashes reports failure" "$code" "1"
  check "a run that crashes explains itself"    "$(printf '%s' "$out" | grep -c 'aborted unexpectedly')" "1"
  check "a run that crashes does not block later events"      "$(state_residue)" "0"
)

group "stamp.sh: herdr failures"
(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  export FAKE_HERDR_FAIL="agent list"
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"; code=$?
  check "an unreadable herd reports failure"   "$code" "1"
  check "an unreadable herd explains itself" "$(printf '%s' "$out" | grep -c 'agent list failed')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1 w1:p2 w2:p1
  # One bad pane must not stop the rest: the whole design is a full re-render.
  export FAKE_HERDR_FAIL="pane report-metadata" FAKE_HERDR_FAIL_AFTER=1
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"
  check "one unstampable agent does not stop the others" "$(reported_panes)" "w1:p1 w1:p2 w2:p1 "
  check "each unstampable agent is named" \
    "$(printf '%s' "$out" | sed -n 's/.*could not report metadata for pane \(.*\)/\1/p' | sort | tr '\n' ' ')" \
    "w1:p2 w2:p1 "
  check "a partial failure still records what worked"               "$(wc -l < "$HERDR_PLUGIN_STATE_DIR/stamps" | tr -d ' ')" "3"
  check "the simulated failure actually fired" \
    "$([[ -f "${FAKE_HERDR_LOG}.failmatch" ]] && echo fired || echo never)" "fired"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  export FAKE_HERDR_FAIL="pane report-metadata"
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"; code=$?
  check "a herd that cannot be stamped at all reports failure" "$code" "1"
  check "a herd that cannot be stamped at all explains itself"  "$(printf '%s' "$out" | grep -c 'every pane report failed')" "1"
)

group "stamp.sh: malformed agent list"
(
  source "$ROOT/src/lib.sh"; new_env
  printf '{"type":"agent_list","agents":[]}\n' > "$FAKE_HERDR_AGENTS"
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/src/stamp.sh"; code=$?
  check "no agents means nothing to do"  "$code" "0"
  check "no agents means nothing is stamped" "$(grep -c '^pane report-metadata' "$FAKE_HERDR_LOG")" "0"
)

(
  source "$ROOT/src/lib.sh"; new_env
  printf 'not json at all\n' > "$FAKE_HERDR_AGENTS"
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"; code=$?
  check "unreadable herd output reports failure"   "$code" "1"
  check "unreadable herd output explains itself" "$(printf '%s' "$out" | grep -c 'could not parse')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  printf '{"error":{"code":1,"message":"nope"}}\n' > "$FAKE_HERDR_AGENTS"
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"; code=$?
  check "an error from herdr reports failure"    "$code" "1"
  check "an error from herdr stamps nothing" "$(grep -c '^pane report-metadata' "$FAKE_HERDR_LOG")" "0"
)

(
  source "$ROOT/src/lib.sh"; new_env
  : > "$FAKE_HERDR_AGENTS"
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"; code=$?
  check "silence from herdr is a failure, not an empty herd" "$code" "1"
  check "silence from herdr explains itself" "$(printf '%s' "$out" | grep -c 'no output')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  printf '{"agents":[{"pane_id":null},{"pane_id":""},{"pane_id":"w1:p1","terminal_id":"t1"}]}\n' > "$FAKE_HERDR_AGENTS"
  bash "$ROOT/src/stamp.sh"
  check "agents without an identity are skipped" "$(reported_panes)" "w1:p1 "
)

group "stamp.sh: edge cases"
(
  source "$ROOT/src/lib.sh"; new_env
  printf 'fresh_max_hours = 1\nstale_max_hours = 2\n' > "$HERDR_PLUGIN_CONFIG_DIR/config.toml"
  agents w1:p1
  set_stamp w1:p1 $(( $(date +%s) - 90*60 ))
  bash "$ROOT/src/stamp.sh"
  check "configured thresholds change which band an agent lands in" \
    "$(report_for w1:p1 | grep -oE '\-\-token used_(fresh|stale|old)=')" "--token used_stale="
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  set_stamp w1:p1 $(( $(date +%s) + 600 ))
  bash "$ROOT/src/stamp.sh"
  check "an agent timestamped in the future reads as just used" \
    "$(report_for w1:p1 | grep -oE '\-\-token used_(fresh|stale|old)=')" "--token used_fresh="
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  stub="$SANDBOX/bin"; mkdir -p "$stub"
  # A PATH holding everything stamp.sh needs except jq.
  for tool in bash env date grep mv touch mkdir awk tail cut sed cat rm wc dirname find rmdir printf; do
    resolved="$(command -v "$tool" || true)"
    if [[ -z "$resolved" ]]; then fail "jq guard fixture" "missing host tool $tool" "present"; exit 0; fi
    ln -sf "$resolved" "$stub/$tool"
  done
  out="$(PATH="$stub" bash "$ROOT/src/stamp.sh" 2>&1)"; code=$?
  check "a missing dependency reports failure" "$code" "1"
  check "a missing dependency names what to install" "$(printf '%s' "$out" | grep -c 'jq is required')" "1"
)

group "stamp.sh: preconditions"
(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  unset HERDR_BIN_PATH
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"; code=$?
  check "stamping without the herdr binary reports failure" "$code" "1"
  check "stamping without the herdr binary says which setting is missing" \
    "$(printf '%s' "$out" | grep -c 'HERDR_BIN_PATH')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  unset HERDR_BIN_PATH
  out="$(bash "$ROOT/src/install-rows.sh" 2>&1)"; code=$?
  check "installing without the herdr binary reports failure" "$code" "1"
  check "installing without the herdr binary changes nothing" \
    "$(grep -c 'herdr-last-used' "$HERDR_CONFIG_PATH")" "0"
)

group "socket_request.py"

# Starts the recorder, returns once it is listening. Bounded so a hang in the
# recorder cannot wedge the suite.
start_recorder() { # [response-json]
  RECORDER_SOCK="$SANDBOX/api.sock"
  RECORDER_OUT="$SANDBOX/request.json"
  rm -f "$RECORDER_OUT"
  : > "$SANDBOX/ready"
  python3 "$ROOT/test/socket_recorder.py" "$RECORDER_SOCK" "$RECORDER_OUT" ${1:+"$1"} > "$SANDBOX/ready" 2>&1 &
  RECORDER_PID=$!
  local waited=0
  # Gate on the literal token: a crashed recorder writes a traceback, which is
  # also non-empty, and would read as ready.
  while ! grep -q '^ready$' "$SANDBOX/ready" 2>/dev/null && (( waited < 200 )); do
    waited=$((waited + 1)); sleep 0.05
  done
  grep -q '^ready$' "$SANDBOX/ready" 2>/dev/null \
    || fail "recorder failed to start" "$(cat "$SANDBOX/ready")" "ready"
}

# Pass "no-request" when the test expects nothing to connect, so it does not
# pay the recorder's full accept timeout.
stop_recorder() {
  local waited=0 limit=100
  [[ "${1:-}" == "no-request" ]] && limit=0
  while kill -0 "$RECORDER_PID" 2>/dev/null && (( waited < limit )); do waited=$((waited + 1)); sleep 0.05; done
  kill "$RECORDER_PID" 2>/dev/null || true
  wait "$RECORDER_PID" 2>/dev/null || true
}

(
  source "$ROOT/src/lib.sh"; new_env
  start_recorder
  HERDR_SOCKET_PATH="$RECORDER_SOCK" python3 "$ROOT/src/socket_request.py" '{"id":"a","method":"ping","params":{}}' >/dev/null
  code=$?
  stop_recorder
  check "a request herdr accepts succeeds" "$code" "0"
  check "the request reaches herdr unchanged" "$(cat "$RECORDER_OUT")" '{"id":"a","method":"ping","params":{}}'
)

(
  source "$ROOT/src/lib.sh"; new_env
  # The old substring check failed any response containing the text "error".
  start_recorder '{"id":"a","result":{"type":"agent_view","label":"error","active":true}}'
  out="$(HERDR_SOCKET_PATH="$RECORDER_SOCK" python3 "$ROOT/src/socket_request.py" '{"id":"a"}' 2>&1)"; code=$?
  stop_recorder
  check "a successful reply mentioning the word error still succeeds" "$code" "0"
)

(
  source "$ROOT/src/lib.sh"; new_env
  start_recorder '{"id":"a","error":{"code":-32601,"message":"unknown method"}}'
  out="$(HERDR_SOCKET_PATH="$RECORDER_SOCK" python3 "$ROOT/src/socket_request.py" '{"id":"a"}' 2>&1)"; code=$?
  stop_recorder
  check "a reply carrying an error fails"      "$code" "1"
  check "a reply carrying an error is explained" "$(printf '%s' "$out" | grep -c 'herdr returned an error')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  start_recorder 'this is not json'
  out="$(HERDR_SOCKET_PATH="$RECORDER_SOCK" python3 "$ROOT/src/socket_request.py" '{"id":"a"}' 2>&1)"; code=$?
  stop_recorder
  check "a reply that cannot be understood fails" "$code" "1"
  check "a reply that cannot be understood is explained" "$(printf '%s' "$out" | grep -c 'not JSON')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  start_recorder "CLOSE_WITHOUT_REPLY"
  out="$(HERDR_SOCKET_PATH="$RECORDER_SOCK" python3 "$ROOT/src/socket_request.py" '{"id":"a"}' 2>&1)"; code=$?
  stop_recorder
  check "herdr hanging up without replying fails" "$code" "1"
  check "herdr hanging up without replying is explained" \
    "$(printf '%s' "$out" | grep -c 'without responding')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  out="$(HERDR_SOCKET_PATH="$SANDBOX/nothing-here.sock" python3 "$ROOT/src/socket_request.py" '{"id":"a"}' 2>&1)"; code=$?
  check "no herdr listening fails"          "$code" "1"
  check "no herdr listening is explained"   "$(printf '%s' "$out" | grep -c 'socket error')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  unset HERDR_SOCKET_PATH
  out="$(python3 "$ROOT/src/socket_request.py" '{"id":"a"}' 2>&1)"; code=$?
  check "no socket configured fails"       "$code" "1"
  check "no socket configured is explained" "$(printf '%s' "$out" | grep -c 'HERDR_SOCKET_PATH is not set')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  out="$(HERDR_SOCKET_PATH="$SANDBOX/x.sock" python3 "$ROOT/src/socket_request.py" 2>&1)"; code=$?
  check "calling with no request fails"        "$code" "1"
  check "calling with no request shows how to call it"  "$(printf '%s' "$out" | grep -c 'usage:')" "1"
)

group "filter.sh: agent view requests"

run_filter() { # mode -> sets FILTER_CODE, leaves request in $RECORDER_OUT
  start_recorder ${2:+"$2"}
  HERDR_SOCKET_PATH="$RECORDER_SOCK" bash "$ROOT/src/filter.sh" "$1" > "$SANDBOX/out" 2> "$SANDBOX/err"
  FILTER_CODE=$?
  stop_recorder
}

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter active
  check "choosing active succeeds" "$FILTER_CODE" "0"
  check "active shows only recently used agents, newest first" \
    "$(jq -c '{m:.method,f:.params.filter,s:.params.sort,l:.params.label,src:.params.source}' < "$RECORDER_OUT")" \
    '{"m":"agent.view.set","f":{"op":"exists","field":{"token":"used_fresh"}},"s":[{"field":"attention","order":"desc"},{"field":{"token":"used_at"},"order":"desc"}],"l":"active","src":"plugin:test.last-used"}'
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter stale
  # Cleanup buckets sort oldest first, and never on the display label.
  check "stale shows only day-old agents, oldest first" \
    "$(jq -c '{f:.params.filter.field,s:.params.sort[1]}' < "$RECORDER_OUT")" \
    '{"f":{"token":"used_stale"},"s":{"field":{"token":"used_at"},"order":"asc"}}'
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter inactive
  check "inactive shows only week-old agents, oldest first" \
    "$(jq -c '{f:.params.filter.field,s:.params.sort[1].order}' < "$RECORDER_OUT")" \
    '{"f":{"token":"used_old"},"s":"asc"}'
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter all
  check "clearing removes only this plugin's filter" \
    "$(jq -c '{m:.method,p:.params}' < "$RECORDER_OUT")" \
    '{"m":"agent.view.clear","p":{"source":"plugin:test.last-used"}}'
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter active
  check "the filter request carries nothing extra" "$(jq -c 'keys' < "$RECORDER_OUT")" '["id","method","params"]'
)

(
  source "$ROOT/src/lib.sh"; new_env
  out="$(bash "$ROOT/src/filter.sh" nonsense 2>&1)"; code=$?
  check "an unknown filter name is rejected"     "$code" "2"
  check "an unknown filter name lists the valid ones" "$(printf '%s' "$out" | grep -c 'usage: filter.sh')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter stale
  check "a chosen filter is remembered" "$(cat "$HERDR_PLUGIN_STATE_DIR/filter")" "stale"
)

(
  source "$ROOT/src/lib.sh"; new_env
  # A failed set must not be persisted, or startup replays it forever.
  code=0
  HERDR_SOCKET_PATH="$SANDBOX/no-listener.sock" bash "$ROOT/src/filter.sh" active >/dev/null 2>&1 || code=$?
  check "a filter herdr never received reports failure" "$code" "1"
  check "a filter herdr never received is not remembered" "$([[ -f "$HERDR_PLUGIN_STATE_DIR/filter" ]] && echo present || echo absent)" "absent"
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter active '{"id":"a","error":{"code":-32601,"message":"no such method"}}'
  check "a filter herdr rejected reports failure"  "$FILTER_CODE" "1"
  check "a filter herdr rejected is not remembered" "$([[ -f "$HERDR_PLUGIN_STATE_DIR/filter" ]] && echo present || echo absent)" "absent"
)

(
  source "$ROOT/src/lib.sh"; new_env
  # Herdr keeps one global view; replacing another owner's is worth saying.
  run_filter active '{"id":"a","result":{"type":"agent_view","active":true,"source":"plugin:someone.else"}}'
  check "taking the filter from another plugin is announced" "$(grep -c 'replaced the agent view owned by plugin:someone.else' "$SANDBOX/err")" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter active '{"id":"a","result":{"type":"agent_view","active":true,"source":"plugin:test.last-used"}}'
  check "replacing our own filter says nothing" "$(grep -c 'replaced the agent view' "$SANDBOX/err")" "0"
)

group "startup.sh"
(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  printf 'inactive\n' > "$HERDR_PLUGIN_STATE_DIR/filter"
  # ORDER_LOG makes the recorder append to the same sink as the CLI stub, so the
  # sequence is observable. Asserting on two separate artefacts proved nothing:
  # it held whichever order they happened in.
  export ORDER_LOG="$FAKE_HERDR_LOG"
  start_recorder
  HERDR_SOCKET_PATH="$RECORDER_SOCK" bash "$ROOT/src/startup.sh" >/dev/null 2>&1
  code=$?
  stop_recorder
  check "starting up succeeds" "$code" "0"
  check "starting up restores the last chosen filter" "$(jq -c '.params.filter.field' < "$RECORDER_OUT")" '{"token":"used_old"}'
  # Tokens must exist before a view that filters on them is installed.
  check "starting up stamps agents before restoring the filter" \
    "$(grep -nE '^(pane report-metadata|SOCKET agent.view)' "$FAKE_HERDR_LOG" \
       | sed -n 's/^[0-9]*:\([A-Za-z]*\).*/\1/p' | tr '\n' ' ')" \
    "pane SOCKET "
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  start_recorder
  HERDR_SOCKET_PATH="$RECORDER_SOCK" bash "$ROOT/src/startup.sh" >/dev/null 2>&1
  code=$?
  stop_recorder
  check "starting up with no saved filter still stamps agents" "$(reported_panes)" "w1:p1 "
  check "starting up with no saved filter applies no filter" "$([[ -f "$RECORDER_OUT" ]] && echo sent || echo nothing)" "nothing"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  printf 'all\n' > "$HERDR_PLUGIN_STATE_DIR/filter"
  start_recorder
  HERDR_SOCKET_PATH="$RECORDER_SOCK" bash "$ROOT/src/startup.sh" >/dev/null 2>&1
  stop_recorder
  check "starting up after clearing applies no filter" "$([[ -f "$RECORDER_OUT" ]] && echo sent || echo nothing)" "nothing"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  printf 'inactive\n' > "$HERDR_PLUGIN_STATE_DIR/filter"
  # Startup runs once per server, so a transient stamping failure must not cost
  # the user their filter for the whole session.
  export FAKE_HERDR_FAIL="agent list"
  start_recorder
  err="$(HERDR_SOCKET_PATH="$RECORDER_SOCK" bash "$ROOT/src/startup.sh" 2>&1 >/dev/null)"
  stop_recorder
  check "a failed stamp still restores the filter" \
    "$(jq -c '.params.filter.field' < "$RECORDER_OUT")" '{"token":"used_old"}'
  check "a failed stamp is explained" \
    "$(printf '%s' "$err" | grep -c 'initial stamping failed')" "1"
)

group "install-rows.sh"

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  original="$(cat "$HERDR_CONFIG_PATH")"
  bash "$ROOT/src/install-rows.sh" > /dev/null
  check "herdr can still load the config after installing" \
    "$(python3 "$ROOT/src/config_toml.py" parses "$HERDR_CONFIG_PATH")" "ok"
  # The property, not the fixture: one row binds all three colour tokens, each
  # with a colour. The palette itself is free to change.
  check "every age band gets its own colour" \
    "$(python3 "$ROOT/src/config_toml.py" coloured-tokens "$HERDR_CONFIG_PATH")" \
    '$used_fresh $used_stale $used_old'
  check "existing settings are left alone" \
    "$(python3 "$ROOT/test/check_manifest.py" ui-preserved "$HERDR_CONFIG_PATH")" "all system"
  check "installing keeps a copy of the previous config" "$(cat "$HERDR_CONFIG_PATH".bak.*)" "$original"
  check "installing keeps a single copy" "$(ls "$HERDR_CONFIG_PATH".bak.* | wc -l | tr -d ' ')" "1"
  check "installing takes effect immediately" "$(grep -c 'server reload-config' "$FAKE_HERDR_LOG")" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  bash "$ROOT/src/install-rows.sh" > /dev/null
  before="$(cat "$HERDR_CONFIG_PATH")"
  bash "$ROOT/src/install-rows.sh" > /dev/null
  check "installing twice changes nothing" "$(cat "$HERDR_CONFIG_PATH")" "$before"
  check "installing twice keeps no extra copy" "$(ls "$HERDR_CONFIG_PATH".bak.* | wc -l | tr -d ' ')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  # grep could not see these spellings, so the block was appended as a
  # duplicate key and reload-config was handed an unparseable file.
  printf '\n[ui.sidebar]\nagents = { rows = [["agent"]] }\n' >> "$HERDR_CONFIG_PATH"
  before="$(cat "$HERDR_CONFIG_PATH")"
  out="$(bash "$ROOT/src/install-rows.sh" 2>&1)"; code=$?
  check "a layout written inline is recognised" "$code" "1"
  check "a layout written inline is left alone"         "$(cat "$HERDR_CONFIG_PATH")" "$before"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  printf '\n[ui.sidebar.agents]\nrows = [["agent"]]\n' >> "$HERDR_CONFIG_PATH"
  before="$(cat "$HERDR_CONFIG_PATH")"
  out="$(bash "$ROOT/src/install-rows.sh" 2>&1)"; code=$?
  check "a hand-written layout is refused"        "$code" "1"
  check "a hand-written layout is left untouched" "$(cat "$HERDR_CONFIG_PATH")" "$before"
  check "the rows to merge by hand are shown"         "$(printf '%s' "$out" | grep -c 'used_fresh')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  printf 'this is [not valid TOML\n' > "$HERDR_CONFIG_PATH"
  before="$(cat "$HERDR_CONFIG_PATH")"
  out="$(bash "$ROOT/src/install-rows.sh" 2>&1)"; code=$?
  check "an already-broken config is refused"   "$code" "1"
  check "an already-broken config is untouched" "$(cat "$HERDR_CONFIG_PATH")" "$before"
)

(
  source "$ROOT/src/lib.sh"; new_env
  rm -f "$HERDR_CONFIG_PATH"
  out="$(bash "$ROOT/src/install-rows.sh" 2>&1)"; code=$?
  check "no herdr config to patch reports failure"  "$code" "1"
  check "no herdr config to patch explains itself" "$(printf '%s' "$out" | grep -c 'no Herdr config')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  # This table exists but has no rows key, so the existing-layout guard says
  # "no" and the append then duplicates the table header.
  printf '\n[ui.sidebar.agents]\nrow_gap = 1\n' >> "$HERDR_CONFIG_PATH"
  original="$(cat "$HERDR_CONFIG_PATH")"
  out="$(bash "$ROOT/src/install-rows.sh" 2>&1)"; code=$?
  check "an install that would break the config reports failure" "$code" "1"
  check "an install that would break the config is rolled back" \
    "$(cat "$HERDR_CONFIG_PATH")" "$original"
  check "a rolled-back install leaves no partial block" \
    "$(grep -c 'herdr-last-used' "$HERDR_CONFIG_PATH")" "0"
  check "a rolled-back install does not reload herdr" \
    "$(grep -c 'server reload-config' "$FAKE_HERDR_LOG")" "0"
)

group "uninstall-rows.sh"
(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  original="$(cat "$HERDR_CONFIG_PATH")"
  bash "$ROOT/src/install-rows.sh" > /dev/null
  bash "$ROOT/src/uninstall-rows.sh" > /dev/null
  check "uninstall restores the original config" "$(cat "$HERDR_CONFIG_PATH")" "$original"
  check "uninstall takes effect immediately" \
    "$(grep -c 'server reload-config' "$FAKE_HERDR_LOG")" "2"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  # A config symlinked into a dotfiles checkout must stay a symlink, and the
  # block must be removed from the file it points at.
  mkdir -p "$SANDBOX/dotfiles"
  mv "$HERDR_CONFIG_PATH" "$SANDBOX/dotfiles/config.toml"
  ln -s "$SANDBOX/dotfiles/config.toml" "$HERDR_CONFIG_PATH"
  bash "$ROOT/src/install-rows.sh" > /dev/null
  bash "$ROOT/src/uninstall-rows.sh" > /dev/null
  check "a symlinked config stays a symlink" \
    "$([[ -L "$HERDR_CONFIG_PATH" ]] && echo symlink || echo replaced)" "symlink"
  check "a symlinked config is edited where it points" \
    "$(grep -c 'herdr-last-used' "$SANDBOX/dotfiles/config.toml")" "0"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  out="$(bash "$ROOT/src/uninstall-rows.sh" 2>&1)"; code=$?
  check "uninstalling when nothing is installed changes nothing" "$code" "0"
  check "uninstalling when nothing is installed says so" "$(printf '%s' "$out" | grep -c 'no last-used block')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  bash "$ROOT/src/install-rows.sh" > /dev/null
  # A hand-edit that drops the closing marker previously made sed delete from
  # the opening marker to end of file.
  grep -v "^$MARKER_END\$" "$HERDR_CONFIG_PATH" > "$HERDR_CONFIG_PATH.x" && mv "$HERDR_CONFIG_PATH.x" "$HERDR_CONFIG_PATH"
  before="$(cat "$HERDR_CONFIG_PATH")"
  out="$(bash "$ROOT/src/uninstall-rows.sh" 2>&1)"; code=$?
  check "a half-edited block is refused"  "$code" "1"
  check "a half-edited block is left intact" "$(cat "$HERDR_CONFIG_PATH")" "$before"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  printf '\n[zz]\ntrailing = true\n' >> "$HERDR_CONFIG_PATH"
  original="$(cat "$HERDR_CONFIG_PATH")"
  bash "$ROOT/src/install-rows.sh" > /dev/null
  bash "$ROOT/src/uninstall-rows.sh" > /dev/null
  check "content after the block survives uninstall" "$(cat "$HERDR_CONFIG_PATH")" "$original"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  bash "$ROOT/src/install-rows.sh" > /dev/null
  # The README tells users to edit colours, which live inside the block.
  sed 's/#a6e3a1/#00ff00/' "$HERDR_CONFIG_PATH" > "$HERDR_CONFIG_PATH.x" && mv "$HERDR_CONFIG_PATH.x" "$HERDR_CONFIG_PATH"
  err="$(bash "$ROOT/src/uninstall-rows.sh" 2>&1 >/dev/null)"
  check "removing a customised block warns" "$(printf '%s' "$err" | grep -c 'differs from the shipped default')" "1"
)

group "manifest and asset consistency"
(
  cd "$ROOT"
  check "herdr can load the manifest" \
    "$(python3 -c "import tomllib,sys;tomllib.load(open(sys.argv[1],'rb'));print('ok')" "$ROOT/herdr-plugin.toml")" "ok"
  check "required manifest keys are present" "$(python3 "$ROOT/test/check_manifest.py" required-keys)" "none"
  check "every declared command exists"      "$(python3 "$ROOT/test/check_manifest.py" commands)" "none"
  # A typo'd event name links with only a warning, so it would silently never
  # fire; this is the guard against that.
  check "every hook listens for an event herdr can fire" "$(python3 "$ROOT/test/check_manifest.py" events)" "none"
  check "action ids are unique"               "$(python3 "$ROOT/test/check_manifest.py" action-ids)" "unique"
  # The token names are the contract between the plugin and the user's config.
  # A rename on one side alone renders nothing, with no error anywhere.
  check "the shipped layout shows exactly the values the plugin reports" \
    "$(python3 "$ROOT/test/check_manifest.py" token-contract)" "match"
)

passed="$(grep -c '^P$' "$TALLY/results" 2>/dev/null || true)"
failed="$(grep -c '^F$' "$TALLY/results" 2>/dev/null || true)"
printf '\n%s passed, %s failed\n' "$passed" "$failed"

# A subshell that aborts before its assertions contributes no result at all, so
# the suite would otherwise stay green while silently losing coverage. Compare
# the SET of check names rather than a total: a count can be balanced out by a
# check that ran twice, hiding the one that never ran.
sed -n 's/^  check "\([^"]*\)".*/\1/p' "$ROOT/test/run.sh" | sort > "$TALLY/expected"
sort -u "$TALLY/names" 2>/dev/null > "$TALLY/seen" || : > "$TALLY/seen"

if [[ "$(sort -u "$TALLY/expected" | wc -l | tr -d ' ')" != "$(wc -l < "$TALLY/expected" | tr -d ' ')" ]]; then
  printf 'ERROR: duplicate check names — set comparison is unsound:\n'
  uniq -d < "$TALLY/expected"
  exit 1
fi

missing="$(comm -23 "$TALLY/expected" "$TALLY/seen")"
if [[ -n "$missing" ]]; then
  printf 'ERROR: these checks never ran (a test aborted early):\n%s\n' "$missing"
  exit 1
fi

[[ "$failed" -eq 0 ]]
