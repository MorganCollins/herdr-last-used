#!/usr/bin/env bash
# Filters the Agent sidebar to one age bucket by installing a declarative
# agent view. Because stamp.sh sets exactly one of the three colour tokens per
# pane, "which bucket" is just an exists test on that token.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mode="${1:-}"
case "$mode" in
  active)   token="$TOKEN_FRESH" ;;
  stale)    token="$TOKEN_STALE" ;;
  inactive) token="$TOKEN_OLD" ;;
  all)      token="" ;;
  *)
    echo "usage: filter.sh active|stale|inactive|all" >&2
    exit 2
    ;;
esac

state="$(state_dir)"
mkdir -p "$state"
printf '%s\n' "$mode" > "$state/filter"

# An agent view only lives until the server exits, so the chosen mode is saved
# above and reapplied by apply-filter.sh from the startup hook.
if [[ "$mode" == "all" ]]; then
  request="$(jq -nc --arg source "$METADATA_SOURCE" \
    '{id:"last-used:view-clear",method:"agent.view.clear",params:{source:$source}}')"
else
  request="$(jq -nc --arg source "$METADATA_SOURCE" --arg label "$mode" --arg token "$token" \
    '{id:"last-used:view-set",method:"agent.view.set",params:{
        source:$source,
        label:$label,
        filter:{op:"exists",field:{token:$token}},
        sort:[{field:"attention",order:"desc"},{field:{token:$token},order:"desc"}]
      }}')"
fi

python3 "$PLUGIN_DIR/socket_request.py" "$request"
