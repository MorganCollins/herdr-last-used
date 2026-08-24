#!/usr/bin/env bash
# One startup hook, so stamping happens before the saved filter is reapplied.
# A view that filters on tokens is useless until those tokens exist.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$here/stamp.sh"
bash "$here/apply-filter.sh"
