#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' 'finish_pipeline.sh is a compatibility wrapper; resuming with run_pipeline.sh.' >&2
exec "$(dirname "$0")/run_pipeline.sh" resume "$@"
