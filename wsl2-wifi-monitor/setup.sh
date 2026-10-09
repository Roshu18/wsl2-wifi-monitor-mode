#!/usr/bin/env bash
set -euo pipefail
_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
printf '%s\n' "setup.sh now forwards to './wifimon setup' - see README.md" >&2
exec "${_dir}/wifimon" setup "$@"
