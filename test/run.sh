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

pass() { printf 'P\n' >> "$TALLY/results"; printf '  ok   %s\n' "$1"; }
fail() { printf 'F\n' >> "$TALLY/results"; printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$3" "$2"; }

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
  check "zero age is fresh"            "$(bucket_for_age 0 $fresh $stale)"              "used_fresh"
  check "one second before 24h"        "$(bucket_for_age $((fresh - 1)) $fresh $stale)" "used_fresh"
  check "exactly 24h is stale"         "$(bucket_for_age $fresh $fresh $stale)"         "used_stale"
  check "one second before one week"   "$(bucket_for_age $((stale - 1)) $fresh $stale)" "used_stale"
  check "exactly one week is inactive" "$(bucket_for_age $stale $fresh $stale)"         "used_old"
  check "a year is inactive"           "$(bucket_for_age $((365*86400)) $fresh $stale)" "used_old"
)

group "lib.sh: settings"
(
  source "$ROOT/src/lib.sh"; new_env
  settings="$HERDR_PLUGIN_CONFIG_DIR/config.toml"

  printf '# fresh_max_hours = 99\nfresh_max_hours = 12\nstale_max_hours=48\n' > "$settings"
  check "reads configured value"        "$(read_int_setting fresh_max_hours 24)"  "12"
  check "tolerates missing whitespace"  "$(read_int_setting stale_max_hours 168)" "48"
  check "ignores commented duplicate"   "$(read_int_setting fresh_max_hours 24)"  "12"
  check "falls back on unknown key"     "$(read_int_setting nope 7)"              "7"

  # Hostile values must not be silently truncated or silently accepted.
  printf 'fresh_max_hours = 1.5\n' > "$settings"
  check "a fraction is rejected, not truncated" "$(read_int_setting fresh_max_hours 24)" "24"
  printf 'fresh_max_hours = -1\n' > "$settings"
  check "a negative is rejected"        "$(read_int_setting fresh_max_hours 24)" "24"
  printf 'fresh_max_hours = abc\n' > "$settings"
  check "a non-number is rejected"      "$(read_int_setting fresh_max_hours 24)" "24"
  printf 'fresh_max_hours = 0\n' > "$settings"
  check "zero is read as written"       "$(read_int_setting fresh_max_hours 24)" "0"
  printf 'fresh_max_hours = 6 # trailing comment\n' > "$settings"
  check "a trailing comment is stripped" "$(read_int_setting fresh_max_hours 24)" "6"
  rm -f "$settings"
  check "falls back with no config"     "$(read_int_setting fresh_max_hours 24)" "24"
)

group "lib.sh: threshold validation"
(
  source "$ROOT/src/lib.sh"; new_env
  settings="$HERDR_PLUGIN_CONFIG_DIR/config.toml"

  printf 'fresh_max_hours = 12\nstale_max_hours = 48\n' > "$settings"
  load_thresholds
  check "valid pair is applied"  "$FRESH_SECS $STALE_SECS" "43200 172800"

  # An inverted pair would make the stale bucket, and the show-stale action,
  # permanently unreachable. Defaults with a warning beats a silent dead bucket.
  printf 'fresh_max_hours = 48\nstale_max_hours = 12\n' > "$settings"
  err="$(load_thresholds 2>&1 >/dev/null)"
  load_thresholds 2>/dev/null
  check "inverted pair falls back"     "$FRESH_SECS $STALE_SECS" "86400 604800"
  check "inverted pair warns"          "$(printf '%s' "$err" | grep -c 'ignoring thresholds')" "1"

  printf 'fresh_max_hours = 0\nstale_max_hours = 48\n' > "$settings"
  load_thresholds 2>/dev/null
  check "zero fresh falls back"        "$FRESH_SECS $STALE_SECS" "86400 604800"
)

group "lib.sh: required environment"
(
  source "$ROOT/src/lib.sh"; new_env
  unset HERDR_PLUGIN_STATE_DIR
  out="$(state_dir 2>&1)"; code=$?
  check "missing state dir fails loudly" "$code" "1"
  check "missing state dir names the var" "$(printf '%s' "$out" | grep -c 'HERDR_PLUGIN_STATE_DIR')" "1"
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
  now="$(awk -F'\t' '/^w1:p1\t/{print $2}' "$HERDR_PLUGIN_STATE_DIR/stamps")"
  check "the full report line is exact" "$(report_for w1:p1)" \
    "$(expect_report w1:p1 used_stale "$(format_stamp "$seeded" "$(date +%s)")" "$seeded" "$(grep -o '\-\-seq [0-9]*' "$FAKE_HERDR_LOG" | head -1 | awk '{print $2}')")"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1 w1:p2 w2:p1
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/src/stamp.sh"
  check "every live pane is reported, by identity not count" \
    "$(reported_panes)" "w1:p1 w1:p2 w2:p1 "
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  seeded=$(( $(date +%s) - 20*86400 ))
  set_stamp w1:p1 "$seeded"
  bash "$ROOT/src/stamp.sh"
  check "a three-week-old pane reports inactive" \
    "$(report_for w1:p1 | grep -oE '\-\-token used_(fresh|stale|old)=')" "--token used_old="
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  set_stamp w1:p1 $(( $(date +%s) - 30*3600 ))
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/src/stamp.sh"
  check "an event resets a stale pane to fresh" \
    "$(report_for w1:p1 | grep -oE '\-\-token used_(fresh|stale|old)=')" "--token used_fresh="
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/src/stamp.sh"
  # The sortable token must be the zero-padded epoch, not the display label.
  epoch="$(awk -F'\t' '/^w1:p1\t/{print $2}' "$HERDR_PLUGIN_STATE_DIR/stamps")"
  check "a zero-padded sortable epoch is reported" \
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
  check "a recycled pane id does not inherit an age" \
    "$(report_for w1:p1 | grep -oE '\-\-token used_(fresh|stale|old)=')" "--token used_fresh="
)

(
  source "$ROOT/src/lib.sh"; new_env
  old=$(( $(date +%s) - 30*86400 ))
  set_stamp w1:p1 "$old" "t-same"
  agents "w1:p1:terminal=t-same"
  bash "$ROOT/src/stamp.sh"
  check "the same occupant keeps its age" \
    "$(report_for w1:p1 | grep -oE '\-\-token used_(fresh|stale|old)=')" "--token used_old="
)

group "stamp.sh: state file"
(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1 w1:p2
  set_stamp w1:p9 100
  set_stamp w1:p1 200
  bash "$ROOT/src/stamp.sh"
  check "closed panes are pruned from state" \
    "$(cut -f1 "$HERDR_PLUGIN_STATE_DIR/stamps" | sort | tr '\n' ' ')" "w1:p1 w1:p2 "
  check "an existing epoch is preserved verbatim" \
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
  check "a pane-less run re-renders without restamping" "$second" "$first"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/src/stamp.sh"
  bash "$ROOT/src/stamp.sh"
  code=$?
  check "a second run exits cleanly" "$code" "0"
  check "state has one line per pane" "$(wc -l < "$HERDR_PLUGIN_STATE_DIR/stamps" | tr -d ' ')" "1"
  check "no scratch files are left behind" \
    "$(ls "$HERDR_PLUGIN_STATE_DIR" | grep -cE 'next|tmp|live')" "0"
)

group "stamp.sh: concurrency"
(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1 w1:p2 w2:p1
  # Both hooks fire together when an agent appears, so overlapping runs are
  # normal. Interleaved writes previously lost stamps and truncated scratch files.
  for pane in w1:p1 w1:p2 w2:p1; do
    HERDR_PANE_ID="$pane" bash "$ROOT/src/stamp.sh" &
  done
  wait
  check "state has exactly one line per live pane" \
    "$(cut -f1 "$HERDR_PLUGIN_STATE_DIR/stamps" | sort | tr '\n' ' ')" "w1:p1 w1:p2 w2:p1 "
  check "no duplicate rows" "$(wc -l < "$HERDR_PLUGIN_STATE_DIR/stamps" | tr -d ' ')" "3"
  check "no scratch or lock residue" \
    "$(ls "$HERDR_PLUGIN_STATE_DIR" | grep -cE 'next|tmp|live|lock')" "0"
)

group "stamp.sh: herdr failures"
(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  export FAKE_HERDR_FAIL="agent list"
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"; code=$?
  check "a failing agent list is fatal"   "$code" "1"
  check "a failing agent list is reported" "$(printf '%s' "$out" | grep -c 'agent list failed')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1 w1:p2 w2:p1
  # One bad pane must not stop the rest: the whole design is a full re-render.
  export FAKE_HERDR_FAIL="pane report-metadata" FAKE_HERDR_FAIL_AFTER=1
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"
  check "the loop continues past a failing pane" "$(reported_panes)" "w1:p1 w1:p2 w2:p1 "
  check "the failure is reported"                "$(printf '%s' "$out" | grep -c 'could not report metadata')" "2"
  check "state is still committed"               "$(wc -l < "$HERDR_PLUGIN_STATE_DIR/stamps" | tr -d ' ')" "3"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  export FAKE_HERDR_FAIL="pane report-metadata"
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"; code=$?
  check "every pane failing is fatal" "$code" "1"
  check "total failure is explained"  "$(printf '%s' "$out" | grep -c 'every pane report failed')" "1"
)

group "stamp.sh: malformed agent list"
(
  source "$ROOT/src/lib.sh"; new_env
  printf '{"type":"agent_list","agents":[]}\n' > "$FAKE_HERDR_AGENTS"
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/src/stamp.sh"; code=$?
  check "an empty herd exits cleanly"  "$code" "0"
  check "an empty herd reports nothing" "$(grep -c '^pane report-metadata' "$FAKE_HERDR_LOG")" "0"
)

(
  source "$ROOT/src/lib.sh"; new_env
  printf 'not json at all\n' > "$FAKE_HERDR_AGENTS"
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"; code=$?
  check "unparseable output is fatal"   "$code" "1"
  check "unparseable output is explained" "$(printf '%s' "$out" | grep -c 'could not parse')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  printf '{"error":{"code":1,"message":"nope"}}\n' > "$FAKE_HERDR_AGENTS"
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"; code=$?
  check "an error envelope is fatal"    "$code" "1"
  check "an error envelope reports nothing" "$(grep -c '^pane report-metadata' "$FAKE_HERDR_LOG")" "0"
)

(
  source "$ROOT/src/lib.sh"; new_env
  : > "$FAKE_HERDR_AGENTS"
  out="$(bash "$ROOT/src/stamp.sh" 2>&1)"; code=$?
  check "empty output is fatal, not an empty herd" "$code" "1"
  check "empty output is explained" "$(printf '%s' "$out" | grep -c 'no output')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  printf '{"agents":[{"pane_id":null},{"pane_id":""},{"pane_id":"w1:p1","terminal_id":"t1"}]}\n' > "$FAKE_HERDR_AGENTS"
  bash "$ROOT/src/stamp.sh"
  check "null and empty pane ids are skipped" "$(reported_panes)" "w1:p1 "
)

group "stamp.sh: edge cases"
(
  source "$ROOT/src/lib.sh"; new_env
  printf 'fresh_max_hours = 1\nstale_max_hours = 2\n' > "$HERDR_PLUGIN_CONFIG_DIR/config.toml"
  agents w1:p1
  set_stamp w1:p1 $(( $(date +%s) - 90*60 ))
  bash "$ROOT/src/stamp.sh"
  check "configured thresholds are honoured" \
    "$(report_for w1:p1 | grep -oE '\-\-token used_(fresh|stale|old)=')" "--token used_stale="
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  set_stamp w1:p1 $(( $(date +%s) + 600 ))
  bash "$ROOT/src/stamp.sh"
  check "a clock-skewed future epoch clamps to fresh" \
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
  check "missing jq is fatal, not a silent success" "$code" "1"
  check "missing jq explains itself" "$(printf '%s' "$out" | grep -c 'jq is required')" "1"
)

group "socket_request.py"

# Starts the recorder, returns once it is listening. Bounded so a hang in the
# recorder cannot wedge the suite.
start_recorder() { # [response-json]
  RECORDER_SOCK="$SANDBOX/api.sock"
  RECORDER_OUT="$SANDBOX/request.json"
  rm -f "$RECORDER_OUT"
  python3 "$ROOT/test/socket_recorder.py" "$RECORDER_SOCK" "$RECORDER_OUT" ${1:+"$1"} > "$SANDBOX/ready" 2>&1 &
  RECORDER_PID=$!
  local waited=0
  while [[ ! -s "$SANDBOX/ready" ]] && (( waited < 100 )); do waited=$((waited + 1)); sleep 0.05; done
}

stop_recorder() {
  local waited=0
  while kill -0 "$RECORDER_PID" 2>/dev/null && (( waited < 100 )); do waited=$((waited + 1)); sleep 0.05; done
  kill "$RECORDER_PID" 2>/dev/null || true
  wait "$RECORDER_PID" 2>/dev/null || true
}

(
  source "$ROOT/src/lib.sh"; new_env
  start_recorder
  HERDR_SOCKET_PATH="$RECORDER_SOCK" python3 "$ROOT/src/socket_request.py" '{"id":"a","method":"ping","params":{}}' >/dev/null
  code=$?
  stop_recorder
  check "a successful request exits 0" "$code" "0"
  check "the request arrives byte-exact" "$(cat "$RECORDER_OUT")" '{"id":"a","method":"ping","params":{}}'
)

(
  source "$ROOT/src/lib.sh"; new_env
  # The old substring check failed any response containing the text "error".
  start_recorder '{"id":"a","result":{"type":"agent_view","label":"error","active":true}}'
  out="$(HERDR_SOCKET_PATH="$RECORDER_SOCK" python3 "$ROOT/src/socket_request.py" '{"id":"a"}' 2>&1)"; code=$?
  stop_recorder
  check "a success payload containing 'error' still succeeds" "$code" "0"
)

(
  source "$ROOT/src/lib.sh"; new_env
  start_recorder '{"id":"a","error":{"code":-32601,"message":"unknown method"}}'
  out="$(HERDR_SOCKET_PATH="$RECORDER_SOCK" python3 "$ROOT/src/socket_request.py" '{"id":"a"}' 2>&1)"; code=$?
  stop_recorder
  check "a real error envelope fails"      "$code" "1"
  check "a real error envelope is explained" "$(printf '%s' "$out" | grep -c 'herdr returned an error')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  start_recorder 'this is not json'
  out="$(HERDR_SOCKET_PATH="$RECORDER_SOCK" python3 "$ROOT/src/socket_request.py" '{"id":"a"}' 2>&1)"; code=$?
  stop_recorder
  check "a non-JSON response fails" "$code" "1"
  check "a non-JSON response is explained" "$(printf '%s' "$out" | grep -c 'not JSON')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  out="$(HERDR_SOCKET_PATH="$SANDBOX/nothing-here.sock" python3 "$ROOT/src/socket_request.py" '{"id":"a"}' 2>&1)"; code=$?
  check "no listener fails"          "$code" "1"
  check "no listener is explained"   "$(printf '%s' "$out" | grep -c 'socket error')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  unset HERDR_SOCKET_PATH
  out="$(python3 "$ROOT/src/socket_request.py" '{"id":"a"}' 2>&1)"; code=$?
  check "an unset socket path fails"       "$code" "1"
  check "an unset socket path is explained" "$(printf '%s' "$out" | grep -c 'HERDR_SOCKET_PATH is not set')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  out="$(HERDR_SOCKET_PATH="$SANDBOX/x.sock" python3 "$ROOT/src/socket_request.py" 2>&1)"; code=$?
  check "a missing argument fails"        "$code" "1"
  check "a missing argument shows usage"  "$(printf '%s' "$out" | grep -c 'usage:')" "1"
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
  check "active exits 0" "$FILTER_CODE" "0"
  check "active filters on the fresh token and sorts newest first" \
    "$(jq -c '{m:.method,f:.params.filter,s:.params.sort,l:.params.label,src:.params.source}' < "$RECORDER_OUT")" \
    '{"m":"agent.view.set","f":{"op":"exists","field":{"token":"used_fresh"}},"s":[{"field":"attention","order":"desc"},{"field":{"token":"used_at"},"order":"desc"}],"l":"active","src":"plugin:test.last-used"}'
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter stale
  # Cleanup buckets sort oldest first, and never on the display label.
  check "stale filters on the stale token and sorts oldest first" \
    "$(jq -c '{f:.params.filter.field,s:.params.sort[1]}' < "$RECORDER_OUT")" \
    '{"f":{"token":"used_stale"},"s":{"field":{"token":"used_at"},"order":"asc"}}'
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter inactive
  check "inactive filters on the old token and sorts oldest first" \
    "$(jq -c '{f:.params.filter.field,s:.params.sort[1].order}' < "$RECORDER_OUT")" \
    '{"f":{"token":"used_old"},"s":"asc"}'
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter all
  check "all clears the view, scoped to this plugin" \
    "$(jq -c '{m:.method,p:.params}' < "$RECORDER_OUT")" \
    '{"m":"agent.view.clear","p":{"source":"plugin:test.last-used"}}'
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter active
  check "the request carries no unexpected keys" "$(jq -c 'keys' < "$RECORDER_OUT")" '["id","method","params"]'
)

(
  source "$ROOT/src/lib.sh"; new_env
  out="$(bash "$ROOT/src/filter.sh" nonsense 2>&1)"; code=$?
  check "an unknown mode exits 2"     "$code" "2"
  check "an unknown mode shows usage" "$(printf '%s' "$out" | grep -c 'usage: filter.sh')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter stale
  check "a successful mode is persisted" "$(cat "$HERDR_PLUGIN_STATE_DIR/filter")" "stale"
)

(
  source "$ROOT/src/lib.sh"; new_env
  # A failed set must not be persisted, or startup replays it forever.
  code=0
  HERDR_SOCKET_PATH="$SANDBOX/no-listener.sock" bash "$ROOT/src/filter.sh" active >/dev/null 2>&1 || code=$?
  check "a failed request exits non-zero" "$code" "1"
  check "a failed request is not persisted" "$([[ -f "$HERDR_PLUGIN_STATE_DIR/filter" ]] && echo present || echo absent)" "absent"
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter active '{"id":"a","error":{"code":-32601,"message":"no such method"}}'
  check "an error response exits non-zero"  "$FILTER_CODE" "1"
  check "an error response is not persisted" "$([[ -f "$HERDR_PLUGIN_STATE_DIR/filter" ]] && echo present || echo absent)" "absent"
)

(
  source "$ROOT/src/lib.sh"; new_env
  # Herdr keeps one global view; replacing another owner's is worth saying.
  run_filter active '{"id":"a","result":{"type":"agent_view","active":true,"source":"plugin:someone.else"}}'
  check "displacing another owner warns" "$(grep -c 'replaced the agent view owned by plugin:someone.else' "$SANDBOX/err")" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env
  run_filter active '{"id":"a","result":{"type":"agent_view","active":true,"source":"plugin:test.last-used"}}'
  check "replacing our own view is silent" "$(grep -c 'replaced the agent view' "$SANDBOX/err")" "0"
)

group "startup.sh"
(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  printf 'inactive\n' > "$HERDR_PLUGIN_STATE_DIR/filter"
  start_recorder
  HERDR_SOCKET_PATH="$RECORDER_SOCK" bash "$ROOT/src/startup.sh" >/dev/null 2>&1
  code=$?
  stop_recorder
  check "startup exits 0" "$code" "0"
  # The ordering guarantee startup.sh exists for: tokens must be reported
  # before a view that filters on them is installed.
  check "startup stamps before replaying" "$(reported_panes)" "w1:p1 "
  check "startup replays the saved filter" "$(jq -c '.params.filter.field' < "$RECORDER_OUT")" '{"token":"used_old"}'
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  start_recorder
  HERDR_SOCKET_PATH="$RECORDER_SOCK" bash "$ROOT/src/startup.sh" >/dev/null 2>&1
  code=$?
  stop_recorder
  check "no saved filter still stamps" "$(reported_panes)" "w1:p1 "
  check "no saved filter sends nothing" "$([[ -f "$RECORDER_OUT" ]] && echo sent || echo nothing)" "nothing"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  printf 'all\n' > "$HERDR_PLUGIN_STATE_DIR/filter"
  start_recorder
  HERDR_SOCKET_PATH="$RECORDER_SOCK" bash "$ROOT/src/startup.sh" >/dev/null 2>&1
  stop_recorder
  check "a saved 'all' needs no replay" "$([[ -f "$RECORDER_OUT" ]] && echo sent || echo nothing)" "nothing"
)

(
  source "$ROOT/src/lib.sh"; new_env
  agents w1:p1
  printf 'inactive\n' > "$HERDR_PLUGIN_STATE_DIR/filter"
  export FAKE_HERDR_FAIL="agent list"
  code=0
  bash "$ROOT/src/startup.sh" >/dev/null 2>&1 || code=$?
  check "a failing stamp aborts startup before the replay" "$code" "1"
)

group "install-rows.sh"

seed_config() {
  printf '[ui]\nagent_panel_scope = "all"\n\n[ui.toast]\ndelivery = "system"\n' > "$HERDR_CONFIG_PATH"
}

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  original="$(cat "$HERDR_CONFIG_PATH")"
  bash "$ROOT/src/install-rows.sh" > /dev/null
  check "the patched config is valid TOML" \
    "$(python3 "$ROOT/src/config_toml.py" parses "$HERDR_CONFIG_PATH")" "ok"
  # The property, not the fixture: one row binds all three colour tokens, each
  # with a colour. The palette itself is free to change.
  check "each colour token is bound with an fg" \
    "$(python3 "$ROOT/src/config_toml.py" coloured-tokens "$HERDR_CONFIG_PATH")" \
    '$used_fresh $used_stale $used_old'
  check "existing settings survive" \
    "$(python3 "$ROOT/test/check_manifest.py" ui-preserved "$HERDR_CONFIG_PATH")" "all system"
  check "the config was backed up first" "$(cat "$HERDR_CONFIG_PATH".bak.*)" "$original"
  check "exactly one backup was made" "$(ls "$HERDR_CONFIG_PATH".bak.* | wc -l | tr -d ' ')" "1"
  check "the config was reloaded" "$(grep -c 'server reload-config' "$FAKE_HERDR_LOG")" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  bash "$ROOT/src/install-rows.sh" > /dev/null
  before="$(cat "$HERDR_CONFIG_PATH")"
  bash "$ROOT/src/install-rows.sh" > /dev/null
  check "a second install is a no-op" "$(cat "$HERDR_CONFIG_PATH")" "$before"
  check "a second install makes no extra backup" "$(ls "$HERDR_CONFIG_PATH".bak.* | wc -l | tr -d ' ')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  # grep could not see these spellings, so the block was appended as a
  # duplicate key and reload-config was handed an unparseable file.
  printf '\n[ui.sidebar]\nagents = { rows = [["agent"]] }\n' >> "$HERDR_CONFIG_PATH"
  before="$(cat "$HERDR_CONFIG_PATH")"
  out="$(bash "$ROOT/src/install-rows.sh" 2>&1)"; code=$?
  check "an inline table is recognised as existing" "$code" "1"
  check "an inline table is left untouched"         "$(cat "$HERDR_CONFIG_PATH")" "$before"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  printf '\n[ui.sidebar.agents]\nrows = [["agent"]]\n' >> "$HERDR_CONFIG_PATH"
  before="$(cat "$HERDR_CONFIG_PATH")"
  out="$(bash "$ROOT/src/install-rows.sh" 2>&1)"; code=$?
  check "a hand-written layout is refused"        "$code" "1"
  check "a hand-written layout is left untouched" "$(cat "$HERDR_CONFIG_PATH")" "$before"
  check "the snippet to merge is printed"         "$(printf '%s' "$out" | grep -c 'used_fresh')" "1"
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
  check "a missing herdr config is an error"  "$code" "1"
  check "a missing herdr config is explained" "$(printf '%s' "$out" | grep -c 'no Herdr config')" "1"
)

group "uninstall-rows.sh"
(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  original="$(cat "$HERDR_CONFIG_PATH")"
  bash "$ROOT/src/install-rows.sh" > /dev/null
  bash "$ROOT/src/uninstall-rows.sh" > /dev/null
  check "uninstall restores the original config" "$(cat "$HERDR_CONFIG_PATH")" "$original"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  out="$(bash "$ROOT/src/uninstall-rows.sh" 2>&1)"; code=$?
  check "uninstalling when absent is a clean no-op" "$code" "0"
  check "uninstalling when absent says so" "$(printf '%s' "$out" | grep -c 'no last-used block')" "1"
)

(
  source "$ROOT/src/lib.sh"; new_env; seed_config
  bash "$ROOT/src/install-rows.sh" > /dev/null
  # A hand-edit that drops the closing marker previously made sed delete from
  # the opening marker to end of file.
  grep -v "^$MARKER_END\$" "$HERDR_CONFIG_PATH" > "$HERDR_CONFIG_PATH.x" && mv "$HERDR_CONFIG_PATH.x" "$HERDR_CONFIG_PATH"
  before="$(cat "$HERDR_CONFIG_PATH")"
  out="$(bash "$ROOT/src/uninstall-rows.sh" 2>&1)"; code=$?
  check "a missing closing marker is refused"  "$code" "1"
  check "a missing closing marker deletes nothing" "$(cat "$HERDR_CONFIG_PATH")" "$before"
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
  check "the manifest is valid TOML" \
    "$(python3 -c "import tomllib,sys;tomllib.load(open(sys.argv[1],'rb'));print('ok')" "$ROOT/herdr-plugin.toml")" "ok"
  check "required manifest keys are present" "$(python3 "$ROOT/test/check_manifest.py" required-keys)" "none"
  check "every declared command exists"      "$(python3 "$ROOT/test/check_manifest.py" commands)" "none"
  # A typo'd event name links with only a warning, so it would silently never
  # fire; this is the guard against that.
  check "hook events are all real herdr events" "$(python3 "$ROOT/test/check_manifest.py" events)" "none"
  check "action ids are unique"               "$(python3 "$ROOT/test/check_manifest.py" action-ids)" "unique"
  # The token names are the contract between the plugin and the user's config.
  # A rename on one side alone renders nothing, with no error anywhere.
  check "the shipped rows reference exactly the reported tokens" \
    "$(python3 "$ROOT/test/check_manifest.py" token-contract)" "match"
)

expected_checks=$(grep -c '^  check "' "$ROOT/test/run.sh")
passed="$(grep -c '^P$' "$TALLY/results" 2>/dev/null || true)"
failed="$(grep -c '^F$' "$TALLY/results" 2>/dev/null || true)"
printf '\n%s passed, %s failed\n' "$passed" "$failed"

# A subshell that aborts before its assertions contributes no result at all, so
# the suite would stay green while silently losing coverage. Assert the count.
total=$(( passed + failed ))
if (( total != expected_checks )); then
  printf 'ERROR: ran %s checks but the file defines %s — a test aborted early\n' "$total" "$expected_checks"
  exit 1
fi
[[ "$failed" -eq 0 ]]
