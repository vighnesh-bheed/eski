#!/usr/bin/env bash
set -euo pipefail
BENCH_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$(dirname "$BENCH_DIR")")"
if [ "$(basename "$(dirname "$BENCH_DIR")")" != workspace ] || [ ! -f "$ROOT/workspace/profile.json" ]; then
  printf 'exam.sh: error: run the copy installed by bench/testbed/install.py, at <root>/exam.sh on the test machine\n' >&2
  exit 2
fi
exec python3 -B -I "$BENCH_DIR/exam_workflow.py" --root "$ROOT" "$@"
