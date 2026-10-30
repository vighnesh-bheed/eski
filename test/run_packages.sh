#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ODIN="${ODIN:-}"
if [ -n "$ODIN" ]; then
	found="$(command -v "$ODIN" 2>/dev/null || true)"
	if [ -z "$found" ] || [ ! -x "$found" ]; then
		echo "ODIN is set to $ODIN but that is not an executable odin compiler" >&2
		exit 1
	fi
	ODIN="$found"
elif command -v odin >/dev/null 2>&1; then
	ODIN="$(command -v odin)"
elif [ -x "$HOME/odin/current/odin" ]; then
	ODIN="$HOME/odin/current/odin"
else
	echo "odin compiler not found; set ODIN, put odin on PATH or install it at $HOME/odin/current/odin" >&2
	exit 1
fi
export ODIN

if ! command -v clang >/dev/null 2>&1; then
	echo "clang not found on PATH; odin links with clang, install it first" >&2
	exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
	echo "python3 not found on PATH; the runner scripts need it" >&2
	exit 1
fi

bash tools/build_lua.sh all

ran=0
work="$(mktemp -d "${TMPDIR:-/tmp}/eski-packages.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
	printf 'FAIL  %-14s %s\n' "$1" "$2"
	tail -n 40 "$3" >&2
	exit 1
}

test_dirs() {
	local root
	for root in src test; do
		if [ -d "$root" ]; then
			find "$root" -name '.*' -prune -o -type f -name '*_test.odin' -print | sed 's|/[^/]*$||'
		fi
	done | LC_ALL=C sort -u | grep -v -x -e test/storage -e test/slab || true
}

run_odin_test() {
	local mode="$1" dir="$2" flags count log
	case "$mode" in
		debug)
			flags="-debug"
			;;
		sanitizer)
			flags="-debug -sanitize:address"
			;;
		release)
			flags="-o:speed"
			;;
	esac
	log="$work/$mode-$(echo "$dir" | tr / _).log"
	if "$ODIN" test "$dir" -thread-count:2 -define:ODIN_TEST_THREADS=1 $flags -out:"$work/odin-test" >"$log" 2>&1; then
		count="$(sed -n 's/^Finished \([0-9][0-9]*\) test.*/\1/p' "$log" | tail -n 1)"
		printf 'pass  %-14s %s (%s tests)\n' "$mode" "$dir" "${count:-0}"
		ran=$((ran + 1))
	else
		fail "$mode" "$dir" "$log"
	fi
}

run_script() {
	local script="$1" label="$2"
	shift 2
	local log="$work/$(echo "$script" | tr / _)-$label.log"
	if python3 -I "$script" "$@" >"$log" 2>&1; then
		printf 'pass  %-14s %s\n' "$label" "$script"
		ran=$((ran + 1))
	else
		fail "$label" "$script" "$log"
	fi
}

for mode in debug sanitizer release; do
	while IFS= read -r dir; do
		run_odin_test "$mode" "$dir"
	done < <(test_dirs)
done

for script in test/*/run.py; do
	if [ ! -f "$script" ]; then
		continue
	fi
	if grep -q -e '--odin' "$script"; then
		run_script "$script" "debug+release" --odin "$ODIN"
	elif grep -q -e '--mode' "$script"; then
		run_script "$script" "debug" --mode debug
		run_script "$script" "release" --mode release
	else
		run_script "$script" "debug+release"
	fi
done

run_script "test/threading/keyspace.py" "keyspace"

if [ "$ran" -eq 0 ]; then
	echo "no test packages found yet"
else
	echo "all packages passed ($ran runs)"
fi
