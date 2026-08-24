#!/usr/bin/env bash
# Filters the Agent sidebar to one age bucket by installing a declarative
# agent view. Because stamp.sh sets exactly one of the three colour tokens per
# pane, "which bucket" is just an exists test on that token.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools jq python3

mode="${1:-}"
case "$mode" in
  # Newest first when looking at what you are using; oldest first for the
  # cleanup buckets, so the worst offenders are at the top of the list.
  active)   token="$TOKEN_FRESH"; order="desc" ;;
  stale)    token="$TOKEN_STALE"; order="asc" ;;
  inactive) token="$TOKEN_OLD";   order="asc" ;;
  all)      token=""; order="" ;;
  *)
    echo "usage: filter.sh active|stale|inactive|all" >&2
    exit 2
    ;;
esac

source_id="$(metadata_source)"

if [[ "$mode" == "all" ]]; then
  # Source-scoped: an unconditional clear would steal another owner's view.
  request="$(jq -nc --arg source "$source_id" \
    '{id:"last-used:view-clear",method:"agent.view.clear",params:{source:$source}}')"
else
  # Sort on the zero-padded epoch token, never on the display label: labels are
  # compared lexicographically, where "Sat 09:07" outranks "14:32".
  request="$(jq -nc --arg source "$source_id" --arg label "$mode" \
      --arg token "$token" --arg sort "$TOKEN_SORT" --arg order "$order" \
    '{id:"last-used:view-set",method:"agent.view.set",params:{
        source:$source,
        label:$label,
        filter:{op:"exists",field:{token:$token}},
        sort:[{field:"attention",order:"desc"},{field:{token:$sort},order:$order}]
      }}')"
fi

response="$(python3 "$PLUGIN_DIR/socket_request.py" "$request")"

# Herdr keeps one global agent view, and a set atomically replaces whoever held
# it. Say so when we displaced someone else, since it is otherwise invisible.
displaced="$(printf '%s' "$response" | jq -r '.result.source // empty' 2>/dev/null || true)"
if [[ -n "$displaced" && "$displaced" != "$source_id" ]]; then
  printf 'last-used: replaced the agent view owned by %s\n' "$displaced" >&2
fi

# Persisted only after the request succeeded, so a failed set is not replayed
# from the startup hook forever.
state="$(state_dir)"
mkdir -p "$state"
printf '%s\n' "$mode" > "$state/filter"
