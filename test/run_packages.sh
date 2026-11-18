#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
	cat <<'USAGE'
usage: test/run_packages.sh [--group GROUPS] [--only ITEMS] [--list]

Runs every package test and test driver, each as one item, reports every
failure by name at the end and exits 1 when any item failed.

  --group GROUPS  comma-separated groups to run: debug, sanitizer and release
                  (the package tests in each build mode) and drivers (every
                  test driver)
  --only ITEMS    comma-separated item names to run, as --list prints them
  --list          print every item as GROUP NAME and exit

An item's name is its two columns in the pass and FAIL lines joined by a
colon, for example sanitizer:src/hnsw or
owners-compact-workers:test/compatibility/owners_compact.py.
USAGE
}

groups=""
only=""
list=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--group|--only)
			if [ "$#" -lt 2 ] || [ -z "$2" ]; then
				echo "$1 needs a comma-separated list" >&2
				exit 2
			fi
			if [ "$1" = --group ]; then groups="$2"; else only="$2"; fi
			shift 2
			;;
		--list) list=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
done

ODIN="${ODIN:-}"
if [ "$list" = 0 ]; then
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
fi

server_binary="${ESKI_TEST_BIN:-${ESKI_THREADING_BIN:-bin/eski}}"
ran=0
failures=()
item_groups=()
item_names=()
phase=collect
work=""

test_dirs() {
	local root
	for root in src test; do
		if [ -d "$root" ]; then
			find "$root" -name '.*' -prune -o -type f -name '*_test.odin' -print | sed 's|/[^/]*$||'
		fi
	done | LC_ALL=C sort -u | grep -v -x -e test/storage -e test/slab || true
}

listed() {
	local wanted="$1" value="$2" part
	local -a parts
	IFS=, read -r -a parts <<<"$wanted"
	for part in "${parts[@]}"; do
		if [ "$part" = "$value" ]; then
			return 0
		fi
	done
	return 1
}

selected() {
	if [ -n "$groups" ] && ! listed "$groups" "$1"; then
		return 1
	fi
	if [ -n "$only" ] && ! listed "$only" "$2"; then
		return 1
	fi
	return 0
}

odin_test() {
	local mode="$1" dir="$2" log="$3" flags count
	case "$mode" in
		debug) flags="-debug" ;;
		sanitizer) flags="-debug -sanitize:address" ;;
		release) flags="-o:speed" ;;
	esac
	if "$ODIN" test "$dir" -thread-count:2 -define:ODIN_TEST_THREADS=1 $flags -out:"$work/odin-test" >"$log" 2>&1; then
		count="$(sed -n 's/^Finished \([0-9][0-9]*\) test.*/\1/p' "$log" | tail -n 1)"
		printf 'pass  %-14s %s (%s tests)\n' "$mode" "$dir" "${count:-0}"
		return 0
	fi
	return 1
}

driver() {
	local label="$1" script="$2" log="$3"
	shift 3
	if python3 -I "$script" "$@" >"$log" 2>&1; then
		printf 'pass  %-14s %s\n' "$label" "$script"
		return 0
	fi
	return 1
}

item() {
	local group="$1" label="$2" path="$3" kind="$4"
	shift 4
	local name="$label:$path" log
	if [ "$phase" = collect ]; then
		item_groups+=("$group")
		item_names+=("$name")
		return 0
	fi
	if ! selected "$group" "$name"; then
		return 0
	fi
	log="$work/$(printf '%s' "$name" | tr '/:+' '___').log"
	if "$kind" "$label" "$path" "$log" "$@"; then
		ran=$((ran + 1))
		return 0
	fi
	printf 'FAIL  %-14s %s\n' "$label" "$path"
	tail -n 40 "$log" >&2 || true
	failures+=("$name")
	return 0
}

script_item() {
	local label="$1" script="$2"
	shift 2
	item drivers "$label" "$script" driver "$@"
}

items() {
	local mode dir script selected_binary
	for mode in debug sanitizer release; do
		while IFS= read -r dir; do
			item "$mode" "$mode" "$dir" odin_test
		done < <(test_dirs)
	done

	for script in test/*/run.py; do
		if [ ! -f "$script" ]; then
			continue
		fi
		if grep -q -e '--odin' "$script"; then
			script_item "debug+release" "$script" --odin "$ODIN"
		elif grep -q -e '--mode' "$script"; then
			script_item "debug" "$script" --mode debug
			script_item "release" "$script" --mode release
		elif grep -q -e '--server' "$script"; then
			selected_binary="$server_binary"
			if [ "$script" = test/scripting/run.py ] && [ -z "${ESKI_TEST_BIN:-}" ]; then
				selected_binary="${ESKI_SCRIPTING_BIN:-$server_binary}"
			fi
			script_item "server" "$script" --server "$selected_binary"
		else
			script_item "debug+release" "$script"
		fi
	done

	script_item "managed-fixture" "test/conformance/test_managed_fixture.py"
	script_item "vector-set-normalisations" "test/vectorset/test_compare.py"
	script_item "search-normalisations" "test/search/test_compare.py"
	script_item "keyspace" "test/threading/keyspace.py" --server "$server_binary"
	script_item "datatype-workers" "test/threading/full_keyspace.py" --server "$server_binary"
	script_item "worker-features" "test/threading/features.py" --server "$server_binary"
	script_item "memory-frontend" "test/compatibility/memory_threading.py" --server "$server_binary"
	script_item "transport" "test/compatibility/transport.py" --server "$server_binary"
	script_item "aof-manifest" "test/compatibility/aof_manifest.py" --server "$server_binary"
	script_item "persistence" "test/compatibility/persistence_boundaries.py" --server "$server_binary"
	script_item "request-lifecycle" "test/compatibility/request_lifecycle.py" --server "$server_binary" --keyspace-threads 0
	script_item "request-workers" "test/compatibility/request_lifecycle.py" --server "$server_binary" --keyspace-threads 2
	script_item "process-title" "test/compatibility/process_title.py" --server "$server_binary"
	script_item "runtime-operations" "test/compatibility/runtime_operations.py" --server "$server_binary"
	script_item "runtime-tuning" "test/compatibility/runtime_tuning.py" --server "$server_binary"
	script_item "native-diagnostics" "test/compatibility/diagnostics.py" --server "$server_binary" --sanitizer "${ESKI_TEST_SANITIZER:-none}"
	script_item "propagation-errors-coordinator" "test/compatibility/propagation_errors.py" --server "$server_binary" --keyspace-threads 0
	script_item "propagation-errors-workers" "test/compatibility/propagation_errors.py" --server "$server_binary" --keyspace-threads 2
	script_item "server-defaults" "test/compatibility/server_defaults.py" --server "$server_binary"
	script_item "client-metadata" "test/compatibility/client_metadata.py" --server "$server_binary"
	script_item "lua-edges" "test/compatibility/lua_edges.py" --server "$server_binary"
	script_item "field-expiry-reads" "test/compatibility/hfe_workers.py" --server "$server_binary" --keyspace-threads 0
	script_item "field-expiry-worker-reads" "test/compatibility/hfe_workers.py" --server "$server_binary" --keyspace-threads 2
	script_item "worker-metadata-coordinator" "test/compatibility/worker_metadata.py" --server "$server_binary" --keyspace-threads 0
	script_item "worker-metadata-parallel" "test/compatibility/worker_metadata.py" --server "$server_binary" --keyspace-threads 2
	script_item "field-expiry-aof" "test/compatibility/hfe_aof.py" --server "$server_binary" --keyspace-threads 0
	script_item "field-expiry-workers" "test/compatibility/hfe_aof.py" --server "$server_binary" --keyspace-threads 2
	script_item "server-parity" "test/compatibility/server_parity.py" --server "$server_binary" --keyspace-threads 0
	script_item "server-parity-workers" "test/compatibility/server_parity.py" --server "$server_binary" --keyspace-threads 2
	script_item "datatype-parity" "test/compatibility/datatype_parity.py" --server "$server_binary" --keyspace-threads 0
	script_item "datatype-parity-workers" "test/compatibility/datatype_parity.py" --server "$server_binary" --keyspace-threads 2
	script_item "lua-debugger" "test/scripting/debugger.py" --server "$server_binary"
	script_item "labels-coordinator" "test/compatibility/labels_subjects.py" --server "$server_binary" --keyspace-threads 0
	script_item "labels-workers" "test/compatibility/labels_subjects.py" --server "$server_binary" --keyspace-threads 2
	script_item "owners-coordinator" "test/compatibility/owners_subjects.py" --server "$server_binary" --keyspace-threads 0
	script_item "owners-workers" "test/compatibility/owners_subjects.py" --server "$server_binary" --keyspace-threads 2
	script_item "owners-keyspace-coordinator" "test/compatibility/owners_keyspace.py" --server "$server_binary" --keyspace-threads 0
	script_item "owners-keyspace-workers" "test/compatibility/owners_keyspace.py" --server "$server_binary" --keyspace-threads 2
	script_item "owners-compact-coordinator" "test/compatibility/owners_compact.py" --server "$server_binary" --keyspace-threads 0
	script_item "owners-compact-workers" "test/compatibility/owners_compact.py" --server "$server_binary" --keyspace-threads 2
	script_item "labels-keyspace-coordinator" "test/compatibility/labels_keyspace.py" --server "$server_binary" --keyspace-threads 0
	script_item "labels-keyspace-workers" "test/compatibility/labels_keyspace.py" --server "$server_binary" --keyspace-threads 2
	script_item "labels-persistence-coordinator" "test/compatibility/labels_persistence.py" --server "$server_binary" --keyspace-threads 0
	script_item "labels-persistence-workers" "test/compatibility/labels_persistence.py" --server "$server_binary" --keyspace-threads 2
	script_item "owners-persistence-coordinator" "test/compatibility/owners_persistence.py" --server "$server_binary" --keyspace-threads 0
	script_item "owners-persistence-workers" "test/compatibility/owners_persistence.py" --server "$server_binary" --keyspace-threads 2
	script_item "search-definitions" "test/compatibility/search_definitions.py" --server "$server_binary"
	script_item "search-maintenance-coordinator" "test/compatibility/search_maintenance.py" --server "$server_binary" --keyspace-threads 0
	script_item "search-maintenance-workers" "test/compatibility/search_maintenance.py" --server "$server_binary" --keyspace-threads 2
	script_item "hash-search-coordinator" "test/compatibility/hash_search.py" --server "$server_binary" --keyspace-threads 0
	script_item "hash-search-workers" "test/compatibility/hash_search.py" --server "$server_binary" --keyspace-threads 2
	script_item "search-pipeline-coordinator" "test/compatibility/search_pipeline.py" --server "$server_binary" --keyspace-threads 0
	script_item "search-pipeline-workers" "test/compatibility/search_pipeline.py" --server "$server_binary" --keyspace-threads 2
	script_item "search-advanced-coordinator" "test/compatibility/search_advanced.py" --server "$server_binary" --keyspace-threads 0
	script_item "search-advanced-workers" "test/compatibility/search_advanced.py" --server "$server_binary" --keyspace-threads 2
	script_item "search-edges-coordinator" "test/compatibility/search_edges.py" --server "$server_binary" --keyspace-threads 0
	script_item "search-edges-workers" "test/compatibility/search_edges.py" --server "$server_binary" --keyspace-threads 2
	script_item "json-coordinator" "test/compatibility/json_commands.py" --server "$server_binary" --keyspace-threads 0
	script_item "json-workers" "test/compatibility/json_commands.py" --server "$server_binary" --keyspace-threads 2
	script_item "json-search-coordinator" "test/compatibility/json_search.py" --server "$server_binary" --keyspace-threads 0
	script_item "json-search-workers" "test/compatibility/json_search.py" --server "$server_binary" --keyspace-threads 2
	script_item "search-persistence" "test/compatibility/search_persistence.py" --server "$server_binary"
	script_item "search-quota" "test/compatibility/search_quota.py" --server "$server_binary"
}

items
duplicates="$(printf '%s\n' "${item_names[@]}" | LC_ALL=C sort | uniq -d)"
if [ -n "$duplicates" ]; then
	echo "item names repeat: $duplicates" >&2
	exit 2
fi
if [ "$list" = 1 ]; then
	for index in "${!item_names[@]}"; do
		printf '%s %s\n' "${item_groups[$index]}" "${item_names[$index]}"
	done
	exit 0
fi
unknown=()
if [ -n "$groups" ]; then
	IFS=, read -r -a wanted <<<"$groups"
	for part in "${wanted[@]}"; do
		listed "debug,sanitizer,release,drivers" "$part" || unknown+=("group $part")
	done
fi
if [ -n "$only" ]; then
	known="$(IFS=,; printf '%s' "${item_names[*]}")"
	IFS=, read -r -a wanted <<<"$only"
	for part in "${wanted[@]}"; do
		listed "$known" "$part" || unknown+=("item $part")
	done
fi
if [ "${#unknown[@]}" -gt 0 ]; then
	printf 'unknown %s\n' "${unknown[@]}" >&2
	exit 2
fi

bash tools/build_lua.sh all
bash tools/build_diagnostics.sh all

work="$(mktemp -d "${TMPDIR:-/tmp}/eski-packages.XXXXXX")"
trap 'rm -rf "$work"' EXIT
phase=run
items

if [ "${#failures[@]}" -gt 0 ]; then
	echo "${#failures[@]} of $((ran + ${#failures[@]})) runs failed:"
	printf 'failed %s\n' "${failures[@]}"
	exit 1
fi
if [ "$ran" -eq 0 ]; then
	if [ -n "$groups$only" ]; then
		echo "no item selected"
		exit 1
	fi
	echo "no test packages found yet"
elif [ -n "$groups$only" ]; then
	echo "all selected packages passed ($ran runs)"
else
	echo "all packages passed ($ran runs)"
fi
