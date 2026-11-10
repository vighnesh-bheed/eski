#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

threads=0
conformance_ref=""
vectorset_ref=""
out=""
runners=()

usage() {
	cat <<'USAGE'
usage: ./test/labelled/run.sh [options] [conformance] [vectorset] [compare] [smoke]

Runs the named runners (default: all four) against a labelled server started
through test/labelled/eski.sh and compares every result with labels-off. Each
difference must be listed in test/labelled/expected/RUNNER.json, and every
listed difference must still occur; the run fails otherwise.

  --keyspace-threads N        keyspace worker threads of the labelled server (default: 0)
  --conformance-reference P   labels-off summary of the 7.4.11 suite from the same binary
                              and worker mode (default: run it first)
  --vectorset-reference P     the same for the vector set unit (default: run it first)
  --out DIR                   where the logs, the summaries and smoke's full differing strings go
                              (default: a new directory under TMPDIR)

The suite and the unit are compared test by test with a labels-off run of
the same binary and worker mode; compare and smoke pass with no failures
without labels, so their failures under labels are the differences.
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--keyspace-threads) threads="${2:?}"; shift 2 ;;
		--conformance-reference) conformance_ref="${2:?}"; shift 2 ;;
		--vectorset-reference) vectorset_ref="${2:?}"; shift 2 ;;
		--out) out="${2:?}"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		conformance|vectorset|compare|smoke) runners+=("$1"); shift ;;
		*) echo "labelled: unknown argument $1" >&2; usage >&2; exit 2 ;;
	esac
done
if [ ${#runners[@]} -eq 0 ]; then
	runners=(conformance vectorset compare smoke)
fi
if [ -z "$out" ]; then
	out="$(mktemp -d "${TMPDIR:-/tmp}/eski-labelled.XXXXXX")" || exit 2
fi
mkdir -p "$out" || exit 2
wrapper="$PWD/test/labelled/eski.sh"
export ESKI_LABELLED_KEYSPACE_THREADS="$threads"
status=0

check() {
	if ! python3 -I test/labelled/check.py "$@"; then
		status=1
	fi
}

for runner in "${runners[@]}"; do
	echo "labelled $runner, $threads keyspace threads, logs in $out"
	case "$runner" in
		conformance)
			ref="$conformance_ref"
			if [ -z "$ref" ]; then
				ref="$out/conformance-off.json"
				ESKI_LABELLED_MODE=off ./test/conformance/run.sh --suite redis --server "$wrapper" --summary "$ref" >"$out/conformance-off.log" 2>&1
			fi
			./test/conformance/run.sh --suite redis --server "$wrapper" --summary "$out/conformance.json" >"$out/conformance.log" 2>&1
			check conformance --result "$out/conformance.json" --reference "$ref"
			;;
		vectorset)
			ref="$vectorset_ref"
			if [ -z "$ref" ]; then
				ref="$out/vectorset-off.json"
				ESKI_LABELLED_MODE=off ./test/conformance/run.sh --suite vectorset --server "$wrapper" --summary "$ref" >"$out/vectorset-off.log" 2>&1
			fi
			./test/conformance/run.sh --suite vectorset --server "$wrapper" --summary "$out/vectorset.json" >"$out/vectorset.log" 2>&1
			check vectorset --result "$out/vectorset.json" --reference "$ref"
			;;
		compare)
			ESKI_VSET_SERVER="$wrapper" bash test/vectorset/compare.sh --quiet --summary "$out/compare.json" >"$out/compare.log" 2>&1
			check compare --result "$out/compare.json"
			;;
		smoke)
			ESKI_SMOKE_BINARY="$wrapper" ESKI_SMOKE_KEYSPACE_THREADS="$threads" ESKI_SMOKE_FULL_DIR="$out/smoke-full" bash test/smoke.sh >"$out/smoke.log" 2>&1
			check smoke --result "$out/smoke.log"
			;;
	esac
done
exit "$status"
