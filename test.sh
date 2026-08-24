#!/usr/bin/env bash
# Test suite for the last-used plugin. Runs on bash 3.2.
#
# The herdr CLI is the plugin's only system boundary, so it is the only thing
# stubbed (test/fake-herdr). The socket path is exercised against a real unix
# socket rather than a mock, so the framing itself is under test.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Each test runs in a subshell, so results are tallied through a file.
RESULTS="$(mktemp)"
export RESULTS
trap 'rm -f "$RESULTS"' EXIT

pass() { printf 'P\n' >> "$RESULTS"; printf '  ok   %s\n' "$1"; }
fail() { printf 'F\n' >> "$RESULTS"; printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }

check() { # name actual expected
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "$3" "$2"; fi
}

group() { printf '\n%s\n' "$1"; }

# A fresh, fully isolated plugin environment per test.
new_env() {
  SANDBOX="$(mktemp -d)"
  export HERDR_PLUGIN_STATE_DIR="$SANDBOX/state"
  export HERDR_PLUGIN_CONFIG_DIR="$SANDBOX/config"
  export HERDR_PLUGIN_ID="test.last-used"
  export FAKE_HERDR_LOG="$SANDBOX/calls.log"
  export FAKE_HERDR_AGENTS="$SANDBOX/agents.json"
  export HERDR_BIN_PATH="$ROOT/test/fake-herdr"
  mkdir -p "$HERDR_PLUGIN_STATE_DIR" "$HERDR_PLUGIN_CONFIG_DIR"
  : > "$FAKE_HERDR_LOG"
  : > "$FAKE_HERDR_AGENTS"
  unset HERDR_PANE_ID
}

agents() { # pane_id...
  local first=1
  {
    printf '{"type":"agent_list","agents":['
    for pane in "$@"; do
      [[ $first -eq 1 ]] || printf ','
      first=0
      printf '{"pane_id":"%s","agent_status":"idle","terminal_id":"t","workspace_id":"w1","tab_id":"w1:t1","focused":false,"revision":1}' "$pane"
    done
    printf ']}\n'
  } > "$FAKE_HERDR_AGENTS"
}

# The report-metadata call recorded for one pane, normalised for comparison.
report_for() { grep "^pane report-metadata $1 " "$FAKE_HERDR_LOG" | tail -n 1; }

set_stamp() { printf '%s\t%s\n' "$1" "$2" >> "$HERDR_PLUGIN_STATE_DIR/stamps"; }

now_epoch() { date +%s; }

group "lib.sh: stamp formatting"
(
  cd "$ROOT"; source lib.sh
  base=$(date -j -f "%Y-%m-%d %H:%M:%S" "2026-08-24 15:00:00" +%s 2>/dev/null \
      || date -d "2026-08-24 15:00:00" +%s)
  check "same day renders time only"        "$(format_stamp $((base - 28*60)) $base)" "14:32"
  check "midnight boundary is still today"  "$(format_stamp $((base - 15*3600)) $base)" "00:00"
  check "three days renders weekday"        "$(format_stamp $((base - 3*86400)) $base)" "Fri 15:00"
  check "twelve days renders date"          "$(format_stamp $((base - 12*86400)) $base)" "12 Aug"
  check "single-digit day has no zero pad"  "$(format_stamp $((base - 19*86400)) $base)" "5 Aug"
)

group "lib.sh: age buckets"
(
  cd "$ROOT"; source lib.sh
  fresh=$((24*3600)); stale=$((168*3600))
  check "zero age is fresh"            "$(bucket_for_age 0 $fresh $stale)"             "used_fresh"
  check "one second before 24h"        "$(bucket_for_age $((fresh - 1)) $fresh $stale)" "used_fresh"
  check "exactly 24h is stale"         "$(bucket_for_age $fresh $fresh $stale)"        "used_stale"
  check "one second before one week"   "$(bucket_for_age $((stale - 1)) $fresh $stale)" "used_stale"
  check "exactly one week is inactive" "$(bucket_for_age $stale $fresh $stale)"        "used_old"
  check "a year is inactive"           "$(bucket_for_age $((365*86400)) $fresh $stale)" "used_old"
)

group "lib.sh: settings"
(
  cd "$ROOT"; source lib.sh
  new_env
  printf '# fresh_max_hours = 99\nfresh_max_hours = 12\nstale_max_hours=48\n' \
    > "$HERDR_PLUGIN_CONFIG_DIR/config.toml"
  check "reads configured value"        "$(read_int_setting fresh_max_hours 24)"  "12"
  check "tolerates missing whitespace"  "$(read_int_setting stale_max_hours 168)" "48"
  check "ignores commented duplicate"   "$(read_int_setting fresh_max_hours 24)"  "12"
  check "falls back on unknown key"     "$(read_int_setting nope 7)"              "7"
  rm -f "$HERDR_PLUGIN_CONFIG_DIR/config.toml"
  check "falls back with no config"     "$(read_int_setting fresh_max_hours 24)"  "24"
)

group "stamp.sh: reporting"
(
  new_env
  agents w1:p1
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/stamp.sh"
  expected="pane report-metadata w1:p1 --source plugin:test.last-used --token used_fresh=$(date +%H:%M) --clear-token used_stale --clear-token used_old"
  check "event pane reported as fresh with others cleared" "$(report_for w1:p1)" "$expected"
)

(
  new_env
  agents w1:p1 w1:p2 w2:p1
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/stamp.sh"
  check "every live pane is re-reported, not just the event pane" \
    "$(grep -c '^pane report-metadata' "$FAKE_HERDR_LOG")" "3"
)

(
  new_env
  agents w1:p1
  now="$(now_epoch)"
  set_stamp w1:p1 $((now - 30*3600))
  bash "$ROOT/stamp.sh"
  check "a stored epoch drives the bucket, not the event time" \
    "$(report_for w1:p1 | grep -c 'token used_stale=')" "1"
)

(
  new_env
  agents w1:p1
  now="$(now_epoch)"
  set_stamp w1:p1 $((now - 20*86400))
  bash "$ROOT/stamp.sh"
  check "a three-week-old pane reports inactive" \
    "$(report_for w1:p1 | grep -c 'token used_old=')" "1"
)

(
  new_env
  agents w1:p1
  now="$(now_epoch)"
  set_stamp w1:p1 $((now - 30*3600))
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/stamp.sh"
  check "an event resets a stale pane back to fresh" \
    "$(report_for w1:p1 | grep -c 'token used_fresh=')" "1"
)

group "stamp.sh: state file"
(
  new_env
  agents w1:p1 w1:p2
  set_stamp w1:p9 100
  set_stamp w1:p1 200
  bash "$ROOT/stamp.sh"
  check "closed panes are pruned from state" \
    "$(cut -f1 "$HERDR_PLUGIN_STATE_DIR/stamps" | sort | tr '\n' ' ')" "w1:p1 w1:p2 "
  check "an existing epoch is preserved verbatim" \
    "$(awk -F'\t' '$1=="w1:p1"{print $2}' "$HERDR_PLUGIN_STATE_DIR/stamps")" "200"
)

(
  new_env
  agents w1:p1
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/stamp.sh"
  first="$(awk -F'\t' '$1=="w1:p1"{print $2}' "$HERDR_PLUGIN_STATE_DIR/stamps")"
  unset HERDR_PANE_ID
  bash "$ROOT/stamp.sh"
  second="$(awk -F'\t' '$1=="w1:p1"{print $2}' "$HERDR_PLUGIN_STATE_DIR/stamps")"
  check "a pane-less run re-renders without restamping" "$second" "$first"
)

(
  new_env
  agents w1:p1
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/stamp.sh"
  check "state has exactly one line per pane after two events" \
    "$(bash "$ROOT/stamp.sh"; wc -l < "$HERDR_PLUGIN_STATE_DIR/stamps" | tr -d ' ')" "1"
)

group "stamp.sh: thresholds and edge cases"
(
  new_env
  printf 'fresh_max_hours = 1\nstale_max_hours = 2\n' > "$HERDR_PLUGIN_CONFIG_DIR/config.toml"
  agents w1:p1
  now="$(now_epoch)"
  set_stamp w1:p1 $((now - 90*60))
  bash "$ROOT/stamp.sh"
  check "configured thresholds are honoured" \
    "$(report_for w1:p1 | grep -c 'token used_stale=')" "1"
)

(
  new_env
  printf '{"type":"agent_list","agents":[]}\n' > "$FAKE_HERDR_AGENTS"
  export HERDR_PANE_ID=w1:p1
  bash "$ROOT/stamp.sh"
  check "no live agents means no metadata calls" \
    "$(grep -c '^pane report-metadata' "$FAKE_HERDR_LOG")" "0"
)

(
  new_env
  agents w1:p1
  now="$(now_epoch)"
  set_stamp w1:p1 $((now + 600))
  bash "$ROOT/stamp.sh"
  check "a clock-skewed future epoch clamps to fresh" \
    "$(report_for w1:p1 | grep -c 'token used_fresh=')" "1"
)

(
  new_env
  agents w1:p1
  export HERDR_PANE_ID=w1:p1
  # A PATH holding everything stamp.sh needs except jq.
  stub="$SANDBOX/bin"; mkdir -p "$stub"
  for tool in bash env date grep mv touch mkdir awk tail cut sed cat rm wc dirname; do
    ln -sf "$(command -v "$tool")" "$stub/$tool"
  done
  out="$(PATH="$stub" bash "$ROOT/stamp.sh" 2>&1)"; code=$?
  check "missing jq exits cleanly"  "$code" "0"
  check "missing jq explains itself" "$(printf '%s' "$out" | grep -c 'jq is required')" "1"
)

group "filter.sh: agent view requests"

# Runs filter.sh against a real unix socket and echoes the JSON Herdr would receive.
capture_request() { # mode
  local sock="$SANDBOX/api.sock" out="$SANDBOX/request.json"
  rm -f "$out"
  python3 "$ROOT/test/socket_recorder.py" "$sock" "$out" > "$SANDBOX/ready" 2>&1 &
  local recorder=$!
  local waited=0
  while [[ ! -s "$SANDBOX/ready" ]] && (( waited < 100 )); do
    waited=$((waited + 1)); sleep 0.05
  done
  HERDR_SOCKET_PATH="$sock" bash "$ROOT/filter.sh" "$1" > /dev/null 2>&1
  wait "$recorder" 2>/dev/null
  cat "$out"
}

(
  new_env
  request="$(capture_request active)"
  check "active filters on the fresh token" \
    "$(printf '%s' "$request" | jq -c '{m:.method,f:.params.filter,l:.params.label,s:.params.source}')" \
    '{"m":"agent.view.set","f":{"op":"exists","field":{"token":"used_fresh"}},"l":"active","s":"plugin:test.last-used"}'
)

(
  new_env
  request="$(capture_request stale)"
  check "stale filters on the stale token" \
    "$(printf '%s' "$request" | jq -c '.params.filter')" \
    '{"op":"exists","field":{"token":"used_stale"}}'
)

(
  new_env
  request="$(capture_request inactive)"
  check "inactive filters on the old token" \
    "$(printf '%s' "$request" | jq -c '.params.filter')" \
    '{"op":"exists","field":{"token":"used_old"}}'
)

(
  new_env
  request="$(capture_request all)"
  check "all clears the view, scoped to this plugin" \
    "$(printf '%s' "$request" | jq -c '{m:.method,p:.params}')" \
    '{"m":"agent.view.clear","p":{"source":"plugin:test.last-used"}}'
)

(
  new_env
  request="$(capture_request active)"
  check "the request carries no unexpected keys" \
    "$(printf '%s' "$request" | jq -c 'keys')" '["id","method","params"]'
)

(
  new_env
  out="$(bash "$ROOT/filter.sh" nonsense 2>&1)"; code=$?
  check "an unknown mode exits 2"      "$code" "2"
  check "an unknown mode shows usage"  "$(printf '%s' "$out" | grep -c 'usage: filter.sh')" "1"
)

(
  new_env
  capture_request stale > /dev/null
  check "the chosen mode is persisted" "$(cat "$HERDR_PLUGIN_STATE_DIR/filter")" "stale"
)

group "apply-filter.sh: replay after restart"
(
  new_env
  printf 'inactive\n' > "$HERDR_PLUGIN_STATE_DIR/filter"
  sock="$SANDBOX/api.sock"; out="$SANDBOX/request.json"
  python3 "$ROOT/test/socket_recorder.py" "$sock" "$out" > "$SANDBOX/ready" 2>&1 &
  recorder=$!
  waited=0
  while [[ ! -s "$SANDBOX/ready" ]] && (( waited < 100 )); do waited=$((waited+1)); sleep 0.05; done
  HERDR_SOCKET_PATH="$sock" bash "$ROOT/apply-filter.sh" > /dev/null 2>&1
  wait "$recorder" 2>/dev/null
  check "a saved filter is replayed" \
    "$(jq -c '.params.filter.field' < "$out")" '{"token":"used_old"}'
)

(
  new_env
  out="$(bash "$ROOT/apply-filter.sh" 2>&1)"; code=$?
  check "no saved filter is a clean no-op" "$code" "0"
  check "no saved filter sends nothing"    "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
)

(
  new_env
  printf 'all\n' > "$HERDR_PLUGIN_STATE_DIR/filter"
  bash "$ROOT/apply-filter.sh" > /dev/null 2>&1
  check "a saved 'all' needs no replay" "$?" "0"
)

group "install-rows.sh / uninstall-rows.sh"
(
  new_env
  export HERDR_CONFIG_PATH="$SANDBOX/herdr.toml"
  printf '[ui]\nagent_panel_scope = "all"\n\n[ui.toast]\ndelivery = "system"\n' > "$HERDR_CONFIG_PATH"
  original="$(cat "$HERDR_CONFIG_PATH")"
  bash "$ROOT/install-rows.sh" > /dev/null

  check "the layout has three rows" \
    "$(python3 "$ROOT/test/check_manifest.py" rows-count "$HERDR_CONFIG_PATH")" "3"
  check "the stamp row declares all three colours" \
    "$(python3 "$ROOT/test/check_manifest.py" rows-colours "$HERDR_CONFIG_PATH")" \
    '[{"token":"$used_fresh","fg":"#a6e3a1"},{"token":"$used_stale","fg":"#fab387"},{"token":"$used_old","fg":"#f38ba8"}]'
  check "existing settings survive" \
    "$(python3 "$ROOT/test/check_manifest.py" ui-preserved "$HERDR_CONFIG_PATH")" "all system"
  check "the config was backed up first" \
    "$(cat "$HERDR_CONFIG_PATH".bak.*)" "$original"
  check "the config was reloaded" \
    "$(grep -c 'server reload-config' "$FAKE_HERDR_LOG")" "1"

  before="$(cat "$HERDR_CONFIG_PATH")"
  bash "$ROOT/install-rows.sh" > /dev/null
  check "a second install is a no-op" "$(cat "$HERDR_CONFIG_PATH")" "$before"

  bash "$ROOT/uninstall-rows.sh" > /dev/null
  check "uninstall restores the original config" "$(cat "$HERDR_CONFIG_PATH")" "$original"

  out="$(bash "$ROOT/uninstall-rows.sh" 2>&1)"
  check "uninstalling twice is a clean no-op" "$(printf '%s' "$out" | grep -c 'no last-used block')" "1"
)

(
  new_env
  export HERDR_CONFIG_PATH="$SANDBOX/herdr.toml"
  printf '[ui.sidebar.agents]\nrows = [["agent"]]\n' > "$HERDR_CONFIG_PATH"
  before="$(cat "$HERDR_CONFIG_PATH")"
  out="$(bash "$ROOT/install-rows.sh" 2>&1)"; code=$?
  check "a hand-written layout is refused"        "$code" "1"
  check "a hand-written layout is left untouched" "$(cat "$HERDR_CONFIG_PATH")" "$before"
  check "the snippet to merge is printed"         "$(printf '%s' "$out" | grep -c 'used_fresh')" "1"
)

(
  new_env
  export HERDR_CONFIG_PATH="$SANDBOX/absent.toml"
  out="$(bash "$ROOT/install-rows.sh" 2>&1)"; code=$?
  check "a missing herdr config is an error" "$code" "1"
  check "a missing herdr config is explained" "$(printf '%s' "$out" | grep -c 'no Herdr config')" "1"
)

group "manifest"
(
  cd "$ROOT"
  check "the manifest is valid TOML" \
    "$(python3 -c "import tomllib;tomllib.load(open('herdr-plugin.toml','rb'));print('ok')")" "ok"
  check "required manifest keys are present" \
    "$(python3 test/check_manifest.py required-keys)" "none"
  check "every declared command exists" \
    "$(python3 test/check_manifest.py commands)" "none"
  check "hook events are all real herdr events" \
    "$(python3 test/check_manifest.py events)" "none"
  check "action ids are unique" \
    "$(python3 test/check_manifest.py action-ids)" "unique"
)

passed="$(grep -c '^P$' "$RESULTS" || true)"
failed="$(grep -c '^F$' "$RESULTS" || true)"
printf '\n%s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
