#!/usr/bin/env bash
set -uo pipefail

CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CONF_DIR/../.." && pwd)"
REDIS_TAG="7.4.11"
REDIS_SHA256="e973da69febfea096ab94690b44bf976482788a1b5e070df373b4f27697d57d4"
REDIS_URL="https://github.com/redis/redis/archive/refs/tags/${REDIS_TAG}.tar.gz"
VALKEY_TAG="8.1.10"
VALKEY_SHA256="c74e50cd83f6d398a3dc570e04ac2fe538249585d021f76ee2449bbf9ebd04ed"
VALKEY_URL="https://github.com/valkey-io/valkey/archive/refs/tags/${VALKEY_TAG}.tar.gz"
REDIS_UNITS="keyspace,expire,type/string,type/incr,type/hash,type/hash-field-expire,type/list,type/list-2,type/list-3,type/set,type/zset,type/stream,type/stream-cgroups,bitops,bitfield,hyperloglog,geo,sort,scan,dump,multi,pubsub,pubsubshard,protocol,querybuf,auth,acl,acl-v2,tracking,info,info-command,introspection,introspection-2,latency-monitor,slowlog,limits,maxmemory,memefficiency,lazyfree,networking,pause,quit,other"
VALKEY_UNITS="${REDIS_UNITS/,type\/hash-field-expire/}"
REDIS_LIFTS="tests/unit/type/hash-field-expire.tcl:59,886,998 tests/unit/maxmemory.tcl:1,146,430,593 tests/unit/memefficiency.tcl:27 tests/unit/info.tcl:26,503 tests/unit/acl.tcl:1 tests/unit/acl-v2.tcl:1 tests/unit/auth.tcl:1,13"
VALKEY_LIFTS="tests/unit/acl.tcl:1 tests/unit/acl-v2.tcl:1 tests/unit/auth.tcl:1,13"
RESULTS_DIR="$CONF_DIR/results"
PARSER="$CONF_DIR/parse_results.py"
TCL_IMAGE="eski-conformance-tcl:8.6"
TCL_BASE_IMAGE="docker.io/library/debian:bookworm-slim"
DEFAULT_TAGS="-needs:repl"

suite="redis"
units=""
units_given=0
tags="$DEFAULT_TAGS"
port=""
server="$ROOT/bin/eski"
server_given=0
external=""
extra_summary=""
baseline=""
known_file="$CONF_DIR/known-failures.txt"
verbose=0
tcl_choice="auto"
unit_timeout=600
stall_timeout=120

SERVER_PID=""
SERVER_LOG=""
UNIT_PID=""
TAIL_PID=""
TCL_CONTAINER=""
TCL_MODE=""
TCLSH=""
TCL_DESC=""

usage() {
	cat <<EOF
usage: ./test/conformance/run.sh [options]

Runs the Tcl test suite of a pinned server release against eski, one unit at
a time, and writes a JSON summary to test/conformance/results/latest-SUITE.json,
with a copy at results/latest.json. The redis suite is the one from Redis
$REDIS_TAG, the release eski targets; the valkey suite is the one from Valkey
$VALKEY_TAG. A server started by this script is restarted for every unit, so no
state leaks between units; an --external server is shared by all units.

Every unit runs in the suite's external server mode, which ignores blocks
tagged external:skip. Redis $REDIS_TAG tags every block of
type/hash-field-expire that way, along with the top-level blocks of a few
other units, so after extracting the suite the runner removes the tag from the
top-level start_server lines at
$REDIS_LIFTS, leaving the nested blocks that need
servers of their own skipped. The lifted blocks pass against a stock Redis
$REDIS_TAG in external mode, except one auth test that needs a client opened
after requirepass is set, and the summary records the change.

  --suite redis|valkey    which release's suite to run (default: redis)
  --units a,b,c           units to run (default: the curated in-scope list of the suite)
  --tags "..."            suite tag filter; prefix a tag with - to exclude it
                          (default: "$DEFAULT_TAGS"; pass "" to run every tag)
  --port N                port for the server this script starts (default: a free port)
  --server PATH           server binary to start (default: bin/eski, built when missing)
  --external HOST:PORT    test an already running server instead of starting one
  --summary PATH          also write the JSON summary to PATH
  --baseline PATH         compare with a recorded summary of the same suite; fail only on regressions
  --known-failures PATH   out of scope units and tests (default: test/conformance/known-failures.txt)
  --tcl auto|docker|PATH  how to run the suite (default: auto, native tclsh first)
  --unit-timeout SECS     hard time limit per unit (default: $unit_timeout)
  --verbose               stream the suite output while it runs

Default redis units: $REDIS_UNITS
Default valkey units: $VALKEY_UNITS

Exit status: 0 when the run passes, 1 when it fails, 2 on a setup error.
Without --baseline the run fails when any test or unit error is not in the
known failures file. With --baseline it fails only when a test that passed in
the baseline does not pass now. A baseline recorded with the other suite is
refused.
EOF
}

die() {
	echo "conformance: $*" >&2
	exit 2
}

abspath() {
	case "$1" in
		/*) printf '%s' "$1" ;;
		*) printf '%s/%s' "$PWD" "$1" ;;
	esac
}

need_value() {
	if [ $# -lt 2 ]; then
		die "missing value for $1"
	fi
}

while [ $# -gt 0 ]; do
	case "$1" in
		--suite) need_value "$@"; suite="$2"; shift 2 ;;
		--units) need_value "$@"; units="$2"; units_given=1; shift 2 ;;
		--tags) need_value "$@"; tags="$2"; shift 2 ;;
		--port) need_value "$@"; port="$2"; shift 2 ;;
		--server) need_value "$@"; server="$(abspath "$2")"; server_given=1; shift 2 ;;
		--external) need_value "$@"; external="$2"; shift 2 ;;
		--summary) need_value "$@"; extra_summary="$(abspath "$2")"; shift 2 ;;
		--baseline) need_value "$@"; baseline="$(abspath "$2")"; shift 2 ;;
		--known-failures) need_value "$@"; known_file="$(abspath "$2")"; shift 2 ;;
		--tcl) need_value "$@"; tcl_choice="$2"; shift 2 ;;
		--unit-timeout) need_value "$@"; unit_timeout="$2"; shift 2 ;;
		--verbose) verbose=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "conformance: unknown option $1" >&2; usage >&2; exit 2 ;;
	esac
done

case "$suite" in
	redis)
		SUITE_LABEL="Redis"
		SUITE_TAG="$REDIS_TAG"
		SUITE_SHA256="$REDIS_SHA256"
		SUITE_URL="$REDIS_URL"
		SUITE_UNITS="$REDIS_UNITS"
		SUITE_LIFTS="$REDIS_LIFTS"
		STUB_NAME="redis-server"
		;;
	valkey)
		SUITE_LABEL="Valkey"
		SUITE_TAG="$VALKEY_TAG"
		SUITE_SHA256="$VALKEY_SHA256"
		SUITE_URL="$VALKEY_URL"
		SUITE_UNITS="$VALKEY_UNITS"
		SUITE_LIFTS="$VALKEY_LIFTS"
		STUB_NAME="valkey-server"
		;;
	*) die "--suite must be redis or valkey" ;;
esac
CACHE_DIR="$CONF_DIR/.$suite"
TREE_NAME="$suite-$SUITE_TAG"
TREE="$CACHE_DIR/$TREE_NAME"
STAMP_VALUE="$SUITE_SHA256${SUITE_LIFTS:+ lifted $SUITE_LIFTS}"
if [ "$suite" = "redis" ]; then
	STUB_DIR="$TREE/src"
else
	STUB_DIR="$CACHE_DIR/stub-bin"
fi
if [ "$units_given" = 0 ]; then
	units="$SUITE_UNITS"
fi

case "$unit_timeout" in
	''|*[!0-9]*) die "--unit-timeout must be a number of seconds" ;;
esac
if [ -n "$port" ]; then
	case "$port" in
		''|*[!0-9]*) die "--port must be a number" ;;
	esac
fi
if [ -n "$baseline" ] && [ ! -f "$baseline" ]; then
	die "baseline $baseline does not exist"
fi
if [ ! -f "$known_file" ]; then
	die "known failures file $known_file does not exist"
fi
for tool in python3 curl tar timeout; do
	command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
if [ -n "$baseline" ]; then
	python3 -I "$PARSER" check-baseline --baseline "$baseline" --root "$ROOT" \
		"--suite-name=$suite" "--suite-tag=$SUITE_TAG" || exit 2
fi

if [ -n "$external" ]; then
	host="${external%:*}"
	target_port="${external##*:}"
	if [ -z "$host" ] || [ "$host" = "$external" ]; then
		die "--external needs HOST:PORT"
	fi
	case "$target_port" in
		''|*[!0-9]*) die "--external needs a numeric port" ;;
	esac
else
	host="127.0.0.1"
	if [ -z "$port" ]; then
		port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')" || die "could not find a free port"
	fi
	target_port="$port"
fi

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

lift_external_skip() {
	[ -n "$SUITE_LIFTS" ] || return 0
	python3 -I - "$1" "$SUITE_LIFTS" <<'PYLIFT'
import os
import sys
tree, spec = sys.argv[1], sys.argv[2]
for item in spec.split():
    name, numbers = item.rsplit(":", 1)
    path = os.path.join(tree, name)
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    for number in numbers.split(","):
        index = int(number) - 1
        line = lines[index]
        if not line.startswith("start_server ") or line.count("external:skip") != 1:
            sys.exit("line %s of %s is not a start_server line tagged external:skip: %s" % (number, name, line))
        lines[index] = line.replace("external:skip ", "").replace(" external:skip", "").replace("external:skip", "")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
PYLIFT
}

fetch_suite() {
	local stamp="$CACHE_DIR/$TREE_NAME.sha256"
	local tarball="$CACHE_DIR/$TREE_NAME.tar.gz"
	local got listing entry staging
	if [ -f "$TREE/tests/test_helper.tcl" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$STAMP_VALUE" ]; then
		return 0
	fi
	mkdir -p "$CACHE_DIR" || die "could not create $CACHE_DIR"
	if [ ! -f "$tarball" ] || [ "$(sha256_of "$tarball")" != "$SUITE_SHA256" ]; then
		echo "fetching $SUITE_LABEL $SUITE_TAG from $SUITE_URL"
		rm -f "$tarball.part"
		if ! curl --fail --location --silent --show-error --retry 3 --output "$tarball.part" "$SUITE_URL"; then
			rm -f "$tarball.part"
			die "download of $SUITE_URL failed"
		fi
		mv "$tarball.part" "$tarball"
	fi
	got="$(sha256_of "$tarball")"
	if [ "$got" != "$SUITE_SHA256" ]; then
		rm -f "$tarball"
		die "sha256 mismatch for $TREE_NAME.tar.gz: expected $SUITE_SHA256, got $got"
	fi
	listing="$(tar -tzf "$tarball")" || die "could not list $tarball"
	while IFS= read -r entry; do
		case "$entry" in
			"$TREE_NAME/"*) ;;
			*) die "unexpected path $entry in $tarball" ;;
		esac
		case "$entry" in
			*../*|*/..) die "unexpected path $entry in $tarball" ;;
		esac
	done <<<"$listing"
	staging="$(mktemp -d "$CACHE_DIR/extract.XXXXXX")" || die "could not create a staging directory"
	if ! tar -xzf "$tarball" -C "$staging" --no-same-owner; then
		rm -rf "$staging"
		die "could not extract $tarball"
	fi
	if ! lift_external_skip "$staging/$TREE_NAME"; then
		rm -rf "$staging"
		die "could not lift external:skip in the $SUITE_LABEL suite"
	fi
	rm -f "$stamp"
	rm -rf "$TREE"
	mv "$staging/$TREE_NAME" "$TREE" || die "could not move the suite into place"
	rmdir "$staging"
	printf '%s\n' "$STAMP_VALUE" >"$stamp"
}

prepare_stub() {
	mkdir -p "$STUB_DIR" || die "could not create $STUB_DIR"
	printf '#!/bin/sh\necho "%s binaries are not available to the conformance runner" >&2\nexit 127\n' "$suite" >"$STUB_DIR/$STUB_NAME"
	chmod 755 "$STUB_DIR/$STUB_NAME"
}

tcl_version_of() {
	local version
	version="$(printf 'puts [info patchlevel]\n' | "$1" 2>/dev/null)" || return 1
	case "$version" in
		8.5*|8.6*|9.*) printf '%s' "$version" ;;
		*) return 1 ;;
	esac
}

resolve_tcl() {
	local candidate path version
	case "$tcl_choice" in
		auto)
			for candidate in tclsh8.6 tclsh9.0 tclsh8.5 tclsh; do
				path="$(type -P "$candidate" 2>/dev/null)" || continue
				if version="$(tcl_version_of "$path")"; then
					TCL_MODE="native"
					TCLSH="$path"
					TCL_DESC="native $path (Tcl $version)"
					return 0
				fi
			done
			command -v docker >/dev/null 2>&1 || die "no tclsh 8.5 or newer found and docker is not available"
			TCL_MODE="docker"
			;;
		docker)
			command -v docker >/dev/null 2>&1 || die "--tcl docker needs docker"
			TCL_MODE="docker"
			;;
		*)
			version="$(tcl_version_of "$tcl_choice")" || die "--tcl $tcl_choice is not a tclsh 8.5 or newer"
			TCL_MODE="native"
			TCLSH="$tcl_choice"
			TCL_DESC="native $tcl_choice (Tcl $version)"
			return 0
			;;
	esac
	if ! docker image inspect "$TCL_IMAGE" >/dev/null 2>&1; then
		echo "building $TCL_IMAGE from $TCL_BASE_IMAGE"
		printf 'FROM %s\nRUN apt-get update && apt-get install -y --no-install-recommends tcl8.6 && rm -rf /var/lib/apt/lists/*\n' "$TCL_BASE_IMAGE" |
			docker build -q -t "$TCL_IMAGE" - >/dev/null || die "could not build $TCL_IMAGE"
	fi
	version="$(docker run --rm "$TCL_IMAGE" sh -c 'echo "puts [info patchlevel]" | tclsh8.6')" || die "tclsh8.6 does not run in $TCL_IMAGE"
	TCL_DESC="docker $TCL_IMAGE (Tcl $version)"
}

pick_baseport() {
	python3 -I -c '
import random
import socket
import sys
for _ in range(200):
    base = random.randrange(20032, 55000)
    free = True
    for port in (base - 32, base - 32 + 10000):
        probe = socket.socket()
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            free = False
        finally:
            probe.close()
    if free:
        print(base)
        sys.exit(0)
sys.exit(1)
'
}

ping_server() (
	exec 3<>"/dev/tcp/$1/$2" || exit 1
	printf 'PING\r\n' >&3
	reply=""
	IFS= read -r -t 2 reply <&3 || exit 1
	[[ "$reply" == "+PONG"* ]]
) 2>/dev/null

start_server() {
	if ping_server "$host" "$port"; then
		die "something already answers PING on port $port"
	fi
	"$server" --port "$port" --bind 127.0.0.1 --enable-debug-command yes --enable-protected-configs yes >>"$SERVER_LOG" 2>&1 </dev/null &
	SERVER_PID=$!
	for _ in $(seq 1 100); do
		if ping_server "$host" "$port"; then
			return 0
		fi
		if ! kill -0 "$SERVER_PID" 2>/dev/null; then
			SERVER_PID=""
			echo "conformance: the server exited during startup, log follows" >&2
			cat "$SERVER_LOG" >&2
			exit 2
		fi
		sleep 0.1
	done
	die "the server on port $port never answered PING"
}

stop_server() {
	local pid="$SERVER_PID"
	SERVER_PID=""
	if [ -z "$pid" ]; then
		return 0
	fi
	kill "$pid" 2>/dev/null
	for _ in $(seq 1 50); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	kill -9 "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	return 0
}

stop_unit() {
	if [ -n "$UNIT_PID" ]; then
		kill -TERM -- "-$UNIT_PID" 2>/dev/null || kill -TERM "$UNIT_PID" 2>/dev/null
		wait "$UNIT_PID" 2>/dev/null
		UNIT_PID=""
	fi
	if [ -n "$TCL_CONTAINER" ]; then
		docker rm -f "$TCL_CONTAINER" >/dev/null 2>&1
		TCL_CONTAINER=""
	fi
	if [ -n "$TAIL_PID" ]; then
		kill "$TAIL_PID" 2>/dev/null
		wait "$TAIL_PID" 2>/dev/null
		TAIL_PID=""
	fi
	return 0
}

cleanup() {
	stop_unit
	stop_server
}

on_signal() {
	trap '' PIPE
	trap - INT TERM HUP
	cleanup
	echo "conformance: interrupted, stopped the suite and the server" >&2
	exit 130
}

trap on_signal INT TERM HUP PIPE
trap cleanup EXIT

fetch_suite
prepare_stub
resolve_tcl

plan_output="$(python3 -I "$PARSER" plan --tree "$TREE" --known "$known_file" --units "$units" "--suite=$suite")" || die "invalid unit selection or known failures file"

run_canonical=()
run_display=()
run_action=()
declare -A known_tests=()
while IFS=$'\t' read -r kind canonical rest; do
	case "$kind" in
		run|skip)
			run_canonical+=("$canonical")
			run_display+=("$rest")
			run_action+=("$kind")
			;;
		test)
			known_tests["$canonical"]+="$rest"$'\n'
			;;
	esac
done <<<"$plan_output"
[ "${#run_canonical[@]}" -gt 0 ] || die "no units selected"

mkdir -p "$RESULTS_DIR" || die "could not create $RESULTS_DIR"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="$RESULTS_DIR/logs-$suite-$stamp"
suffix=1
while [ -e "$LOG_DIR" ]; do
	suffix=$((suffix + 1))
	LOG_DIR="$RESULTS_DIR/logs-$suite-$stamp-$suffix"
done
if [ "$suffix" -gt 1 ]; then
	stamp="$stamp-$suffix"
fi
mkdir -p "$LOG_DIR" || die "could not create $LOG_DIR"
META="$LOG_DIR/units.tsv"
: >"$META"

if [ -n "$external" ]; then
	ping_server "$host" "$target_port" || die "no server answers PING at $host:$target_port"
	server_desc="external $host:$target_port"
else
	if [ ! -x "$server" ]; then
		if [ "$server_given" = 1 ]; then
			die "server binary $server is not executable"
		fi
		echo "bin/eski is missing, building it"
		"$ROOT/build.sh" || die "build failed"
	fi
	SERVER_LOG="$LOG_DIR/server.log"
	: >"$SERVER_LOG"
	server_desc="${server#"$ROOT"/} on $host:$port, restarted for every unit"
fi

suite_baseport="$(pick_baseport)" || die "could not find a free port range for the suite's own test server"

suite_env=(TERM=dumb)
docker_mounts=(-v "$TREE:/suite:z")
if [ "$suite" = "valkey" ]; then
	suite_env+=("VALKEY_BIN_DIR=$STUB_DIR")
	docker_mounts+=(-v "$STUB_DIR:/stub:z" -e VALKEY_BIN_DIR=/stub)
fi

echo "$SUITE_LABEL $SUITE_TAG suite, $TCL_DESC, server $server_desc, tags \"$tags\""

total="${#run_canonical[@]}"
for index in "${!run_canonical[@]}"; do
	canonical="${run_canonical[$index]}"
	display="${run_display[$index]}"
	action="${run_action[$index]}"
	position="[$((index + 1))/$total]"
	if [ "$action" = "skip" ]; then
		printf '%s\t%s\t\t0\t\t0\t0\n' "$canonical" "skip" >>"$META"
		printf '%-8s %-22s out of scope, listed in %s\n' "$position" "$display" "${known_file#"$ROOT"/}"
		continue
	fi
	log="$LOG_DIR/${display//\//_}.log"
	args=(tests/test_helper.tcl --host "$host" --port "$target_port" --baseport "$suite_baseport"
		--single "$canonical" --durable --timeout "$stall_timeout")
	if [ -n "$tags" ]; then
		args+=(--tags "$tags")
	fi
	if [ "$verbose" = 1 ]; then
		args+=(--verbose)
	fi
	if [ -n "${known_tests[$canonical]+set}" ]; then
		while IFS= read -r name; do
			if [ -n "$name" ]; then
				args+=(--skiptest "$name")
			fi
		done <<<"${known_tests[$canonical]}"
	fi
	printf '%-8s %-22s ' "$position" "$display"
	if [ "$verbose" = 1 ]; then
		echo
	fi
	if [ -z "$external" ]; then
		printf '=== %s\n' "$display" >>"$SERVER_LOG"
		start_server
	fi
	started="$(date +%s)"
	if [ "$TCL_MODE" = "docker" ]; then
		TCL_CONTAINER="eski-conformance-tcl-$$-$index"
		timeout -k 10 "$unit_timeout" docker run --rm --name "$TCL_CONTAINER" --network=host \
			--user "$(id -u):$(id -g)" -e TERM=dumb "${docker_mounts[@]}" -w /suite \
			"$TCL_IMAGE" tclsh8.6 "${args[@]}" >"$log" 2>&1 </dev/null &
		UNIT_PID=$!
	else
		cd "$TREE" || die "could not enter $TREE"
		env "${suite_env[@]}" timeout -k 10 "$unit_timeout" "$TCLSH" "${args[@]}" >"$log" 2>&1 </dev/null &
		UNIT_PID=$!
		cd "$ROOT" || die "could not return to $ROOT"
	fi
	if [ "$verbose" = 1 ]; then
		tail -n +1 -f --pid="$UNIT_PID" "$log" &
		TAIL_PID=$!
	fi
	wait "$UNIT_PID"
	rc=$?
	kill -TERM -- "-$UNIT_PID" 2>/dev/null
	UNIT_PID=""
	if [ -n "$TAIL_PID" ]; then
		wait "$TAIL_PID" 2>/dev/null
		TAIL_PID=""
	fi
	if [ -n "$TCL_CONTAINER" ]; then
		docker rm -f "$TCL_CONTAINER" >/dev/null 2>&1
		TCL_CONTAINER=""
	fi
	seconds=$(($(date +%s) - started))
	killed=0
	if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
		killed=1
	fi
	crashed=0
	if [ -n "$external" ]; then
		if ! ping_server "$host" "$target_port"; then
			crashed=1
		fi
	else
		if [ -z "$SERVER_PID" ] || ! kill -0 "$SERVER_PID" 2>/dev/null; then
			crashed=1
			echo "the server exited during $display" >>"$SERVER_LOG"
		fi
		stop_server
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$canonical" "run" "$rc" "$seconds" "$log" "$crashed" "$killed" >>"$META"
	ok_count="$(grep -c '^\[ok\]' "$log" 2>/dev/null)"
	err_count="$(grep -c '^\[err\]' "$log" 2>/dev/null)"
	note=""
	if grep -q '^\[exception\]' "$log" 2>/dev/null; then
		note=", exception"
	fi
	if [ "$killed" = 1 ]; then
		note="$note, killed after ${unit_timeout}s"
	fi
	if [ "$crashed" = 1 ]; then
		note="$note, server died"
	fi
	printf '%s ok, %s err%s (%ss)\n' "${ok_count:-0}" "${err_count:-0}" "$note" "$seconds"
done

stop_server

summary_args=(summarize --meta "$META" --known "$known_file" --root "$ROOT"
	--out "$RESULTS_DIR/summary-$suite-$stamp.json" --latest "$RESULTS_DIR/latest-$suite.json"
	--extra "$RESULTS_DIR/latest.json"
	"--suite-name=$suite" "--suite-tag=$SUITE_TAG" "--suite-sha256=$SUITE_SHA256" "--suite-url=$SUITE_URL"
	"--external-skip-lifted=$SUITE_LIFTS"
	"--tags=$tags" "--server=$server_desc" "--tcl=$TCL_DESC")
if [ -n "$extra_summary" ]; then
	summary_args+=(--extra "$extra_summary")
fi
if [ -n "$baseline" ]; then
	summary_args+=(--baseline "$baseline")
fi
echo
python3 -I "$PARSER" "${summary_args[@]}"
exit $?
