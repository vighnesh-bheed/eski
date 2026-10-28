#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../.."

usage() {
	echo "usage: test/memcached/run_upstream.sh MEMCACHED_SOURCE_DIR [FILE.t ...]" >&2
	echo "  runs text protocol files of the memcached test suite against a fresh eski per file" >&2
	echo "  ESKI_UPSTREAM_TARGET=reference runs the same files against the reference memcached image" >&2
	exit 2
}

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -d "$SRC/t" ] || [ ! -f "$SRC/t/lib/MemcachedTest.pm" ]; then
	usage
fi
SRC="$(cd "$SRC" && pwd)"
shift
TARGET="${ESKI_UPSTREAM_TARGET:-eski}"
RPORT="${ESKI_UPSTREAM_REDIS_PORT:-6631}"
MPORT="${ESKI_UPSTREAM_MC_PORT:-11311}"
REF_PORT="${ESKI_UPSTREAM_REF_PORT:-11312}"
PROXY_PORT="${ESKI_UPSTREAM_PROXY_PORT:-11313}"
PERL_IMAGE="${ESKI_PERL_IMAGE:-docker.io/library/perl:5.40-slim}"
MC_IMAGE="${ESKI_MEMCACHED_IMAGE:-docker.io/library/memcached:1.6}"
FILE_TIMEOUT="${ESKI_UPSTREAM_TIMEOUT:-300}"
DEFAULT_FILES="getset.t cas.t incrdecr.t noreply.t flags.t expirations.t flush-all.t touch.t getandtouch.t bogus-commands.t malicious-commands.t strtol-testing.t quit.t stats.t multiversioning.t chunked-items.t item_size_max.t issue_3.t issue_29.t issue_41.t issue_61.t issue_68.t issue_70.t issue_104.t issue_108.t issue_152.t issue_183.t issue_192.t"
if [ "$#" -gt 0 ]; then
	FILES="$*"
else
	FILES="$DEFAULT_FILES"
fi
WORK="$(mktemp -d -t eski-upstream.XXXXXX)"
SERVER_PID=""
PROXY_PID=""
REF_CONTAINER="eski-upstream-ref-$$"
TARGET_PORT=""
SERVER_ARGS=""

stop_target() {
	if [ -n "$PROXY_PID" ]; then
		kill "$PROXY_PID" 2>/dev/null
		wait "$PROXY_PID" 2>/dev/null
		PROXY_PID=""
	fi
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null
		wait "$SERVER_PID" 2>/dev/null
		SERVER_PID=""
	fi
	docker rm -f "$REF_CONTAINER" >/dev/null 2>&1
}

cleanup() {
	stop_target
	rm -rf "$WORK"
}
trap cleanup EXIT

port_open() {
	(exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

wait_port() {
	for _ in $(seq 1 100); do
		if port_open "$1"; then
			return 0
		fi
		sleep 0.1
	done
	return 1
}

start_target() {
	if [ "$TARGET" == "reference" ]; then
		docker run -d --rm --name "$REF_CONTAINER" --network=host "$MC_IMAGE" memcached -p "$REF_PORT" -U 0 -l 127.0.0.1 $SERVER_ARGS >/dev/null || return 1
		wait_port "$REF_PORT" || return 1
		sleep 3
		TARGET_PORT="$REF_PORT"
	else
		extra=()
		if [[ "$SERVER_ARGS" =~ -I[[:space:]]+([^[:space:]]+) ]]; then
			extra=(--memcached-max-item-size "${BASH_REMATCH[1]}")
		fi
		./bin/eski --port "$RPORT" --enable-debug-command yes --memcached-port "$MPORT" "${extra[@]}" >"$WORK/eski.log" 2>&1 &
		SERVER_PID=$!
		wait_port "$MPORT" || return 1
		TARGET_PORT="$MPORT"
	fi
}

if [ "$TARGET" != "reference" ] && [ ! -x bin/eski ]; then
	./build.sh || exit 1
fi

total_pass=0
total_fail=0
for f in $FILES; do
	if [ ! -f "$SRC/t/$f" ]; then
		echo "$f: missing from $SRC/t"
		total_fail=$((total_fail + 1))
		continue
	fi
	SERVER_ARGS="$(grep -m1 -oE 'new_memcached\([^)]*\)' "$SRC/t/$f" | sed -E "s/^new_memcached\\(//; s/\\)$//; s/['\"]//g")"
	if ! start_target; then
		echo "$f: could not start the $TARGET target"
		total_fail=$((total_fail + 1))
		stop_target
		continue
	fi
	port="$TARGET_PORT"
	if grep -q "mem_move_time" "$SRC/t/$f"; then
		python3 -I test/memcached/debugtime_proxy.py "$PROXY_PORT" "$TARGET_PORT" &
		PROXY_PID=$!
		wait_port "$PROXY_PORT"
		port="$PROXY_PORT"
	fi
	docker run --rm --network=host -v "$SRC/t:/run/upstream/t:ro,z" -e "T_MEMD_USE_DAEMON=127.0.0.1:$port" "$PERL_IMAGE" \
		sh -c "ln -sf /bin/true /run/upstream/memcached-debug && cd /run/upstream && exec timeout $FILE_TIMEOUT perl t/$f" >"$WORK/out" 2>"$WORK/err"
	status=$?
	stop_target
	pass=$(grep -c -E '^ok [0-9]+' "$WORK/out")
	failc=$(grep -c -E '^not ok [0-9]+' "$WORK/out")
	plan=$(grep -m1 -E '^1\.\.[0-9]+' "$WORK/out" | sed -E 's/^1\.\.([0-9]+).*/\1/')
	skipped=$(grep -m1 -E '^1\.\.0 ' "$WORK/out")
	note=""
	if [ -n "$skipped" ]; then
		note=" (${skipped#1..0 })"
	elif [ -n "$plan" ] && [ "$((pass + failc))" -lt "$plan" ]; then
		note=" (planned $plan, ran $((pass + failc)), exit $status)"
		failc=$((failc + plan - pass - failc))
	elif [ -z "$plan" ] && [ "$status" -ne 0 ]; then
		note=" (no plan, exit $status)"
	fi
	echo "$f: $pass passed, $failc failed$note"
	grep -E '^not ok [0-9]+' "$WORK/out" | sed 's/^/    /'
	grep -E '^.[[:space:]]+(Failed|got|expected|Looks)' "$WORK/out" "$WORK/err" 2>/dev/null | sed -E 's/^[^:]*:/      /' | head -40
	total_pass=$((total_pass + pass))
	total_fail=$((total_fail + failc))
done
echo "total: $total_pass passed, $total_fail failed"
