#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

threads=0
mode=labelled
conformance_ref=""
scripting_ref=""
vectorset_ref=""
out=""
runners=()

usage() {
	cat <<'USAGE'
usage: ./test/labelled/run.sh [options] [conformance] [scripting] [vectorset] [compare] [smoke]

Runs the named runners (default: all five) against a server started through
test/labelled/eski.sh in the chosen mode and compares every result with
labels-off. Each difference must be listed in the mode's expected file for the
runner, and every listed difference must still occur; the run fails otherwise.

  --mode M                    labelled (default), owners-shared, owners-user or owners-only-user
  --keyspace-threads N        keyspace worker threads of the server under test (default: 0)
  --conformance-reference P   labels-off summary of the 7.4.11 suite from the same binary
                              and worker mode (default: run it first)
  --scripting-reference P     the same for the suite's scripting unit
  --vectorset-reference P     the same for the vector set unit
  --out DIR                   where the logs, the summaries and smoke's full differing strings go
                              (default: a new directory under TMPDIR)

Modes and their expected files:
  labelled          the scheme and a default login at the top label: expected/RUNNER.json
  owners-shared     the scheme and owner mode, a default login without an owner rule and with
                    the operator scope, so every command runs as SHARED: expected/owners-shared/
  owners-user       the scheme and owner mode, a default login owner:suite-user owner-operator
                    clearance:*, so the suite runs as one user: expected/owners-user/
  owners-only-user  owner mode without a scheme and the same login: expected/owners-only-user/

The suite, its scripting unit and the vector set unit are compared test by
test with a labels-off run of the same binary and worker mode; compare and
smoke pass with no failures without labels, so their failures in the mode are
the differences. The labels-off references do not depend on the mode.
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--mode) mode="${2:?}"; shift 2 ;;
		--keyspace-threads) threads="${2:?}"; shift 2 ;;
		--conformance-reference) conformance_ref="${2:?}"; shift 2 ;;
		--scripting-reference) scripting_ref="${2:?}"; shift 2 ;;
		--vectorset-reference) vectorset_ref="${2:?}"; shift 2 ;;
		--out) out="${2:?}"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		conformance|scripting|vectorset|compare|smoke) runners+=("$1"); shift ;;
		*) echo "labelled: unknown argument $1" >&2; usage >&2; exit 2 ;;
	esac
done
case "$mode" in
	labelled|owners-shared|owners-user|owners-only-user) ;;
	*) echo "labelled: unknown mode $mode" >&2; usage >&2; exit 2 ;;
esac
if [ ${#runners[@]} -eq 0 ]; then
	runners=(conformance scripting vectorset compare smoke)
fi
if [ -z "$out" ]; then
	out="$(mktemp -d "${TMPDIR:-/tmp}/eski-labelled.XXXXXX")" || exit 2
fi
mkdir -p "$out" || exit 2
wrapper="$PWD/test/labelled/eski.sh"
export ESKI_LABELLED_KEYSPACE_THREADS="$threads"
mkdir -p "$out/server-dir" || exit 2
status=0

check() {
	if ! python3 -I test/labelled/check.py --mode "$mode" "$@"; then
		status=1
	fi
}

suite() {
	local name="$1" ref="$2"
	shift 2
	if [ -z "$ref" ]; then
		ref="$out/$name-off.json"
		ESKI_LABELLED_MODE=off ./test/conformance/run.sh "$@" --server "$wrapper" --summary "$ref" >"$out/$name-off.log" 2>&1
	fi
	ESKI_LABELLED_MODE="$mode" ESKI_LABELLED_DIR="$out/server-dir" ./test/conformance/run.sh "$@" --server "$wrapper" --summary "$out/$name.json" >"$out/$name.log" 2>&1
	check "$name" --result "$out/$name.json" --reference "$ref"
}

for runner in "${runners[@]}"; do
	echo "labelled $runner, mode $mode, $threads keyspace threads, logs in $out"
	case "$runner" in
		conformance) suite conformance "$conformance_ref" --suite redis ;;
		scripting) suite scripting "$scripting_ref" --suite redis --units scripting ;;
		vectorset) suite vectorset "$vectorset_ref" --suite vectorset ;;
		compare)
			ESKI_LABELLED_MODE="$mode" ESKI_LABELLED_DIR="$out/server-dir" ESKI_VSET_SERVER="$wrapper" bash test/vectorset/compare.sh --quiet --summary "$out/compare.json" >"$out/compare.log" 2>&1
			check compare --result "$out/compare.json"
			;;
		smoke)
			ESKI_LABELLED_MODE="$mode" ESKI_LABELLED_DIR="$out/server-dir" ESKI_SMOKE_BINARY="$wrapper" ESKI_SMOKE_KEYSPACE_THREADS="$threads" ESKI_SMOKE_FULL_DIR="$out/smoke-full" bash test/smoke.sh >"$out/smoke.log" 2>&1
			check smoke --result "$out/smoke.log"
			;;
	esac
done
exit "$status"
