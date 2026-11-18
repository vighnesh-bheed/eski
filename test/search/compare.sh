#!/usr/bin/env bash
set -eu
exec python3 -IB "$(dirname "$0")/compare.py" "$@"
