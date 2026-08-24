#!/usr/bin/env bash
# One startup hook, so stamping happens before the saved filter is reapplied.
# A view that filters on tokens is useless until those tokens exist.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
bash stamp.sh
bash apply-filter.sh
