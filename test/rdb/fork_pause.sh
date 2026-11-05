#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../.."

PORT="${ESKI_RDB_PORT:-6611}"
REF_PORT="${ESKI_RDB_REF_PORT:-6613}"
SERVER="${ESKI_RDB_SERVER:-bin/eski}"
IMAGE="${ESKI_REDIS_IMAGE:-docker.io/library/redis:7}"
MEMTIER="${ESKI_MEMTIER_IMAGE:-redislabs/memtier_benchmark:latest}"
SERVER_CPUS="${BENCH_SERVER_CPUS:-0-1}"
CLIENT_CPUS="${BENCH_CLIENT_CPUS:-4-11}"
KEYS="${FORK_KEYS:-1000000}"
DURATION="${FORK_DURATION:-20}"
SAVE_AT="${FORK_SAVE_AT:-8}"
OP="${FORK_OP:-bgsave}"
NAME="eski-rdb-fork-$REF_PORT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eski-rdb-fork.XXXXXX")"
PY=(python3 -I -B)
HERE="test/rdb"
SERVER_PID=""

cleanup() {
	if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill -9 "$SERVER_PID" 2>/dev/null
		wait "$SERVER_PID" 2>/dev/null
	fi
	docker rm -f "$NAME" >/dev/null 2>&1
	docker ps -q --filter "name=eski-rdb-fork-memtier" | xargs -r docker rm -f >/dev/null 2>&1
	rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/eski" "$WORK/ref"

call() {
	"${PY[@]}" -c "import sys; sys.path.insert(0, sys.argv[1]); import resp; c = resp.Client(int(sys.argv[2])); r = c.call(*sys.argv[3:]); print(r.decode() if isinstance(r, bytes) else r)" "$HERE" "$@"
}

info_field() {
	call "$1" INFO "$2" | tr -d '\r' | grep "^$3:" | cut -d: -f2
}

wait_port() {
	for _ in $(seq 1 100); do
		if call "$1" PING >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.1
	done
	return 1
}

memtier() {
	local port="$1" name="$2"
	shift 2
	docker run --rm --name "eski-rdb-fork-memtier-$name" --network=host --cpuset-cpus="$CLIENT_CPUS" "$MEMTIER" \
		-s 127.0.0.1 -p "$port" --hide-histogram "$@"
}

populate() {
	memtier "$1" populate --ratio=1:0 --key-pattern=P:P --key-minimum=1 --key-maximum="$KEYS" -n allkeys -d 100 -c 1 -t 4 --pipeline 64 >/dev/null 2>&1
}

measure() {
	local port="$1" label="$2" save="$3" out
	out="$WORK/$label.txt"
	memtier "$port" "$label" --ratio=1:10 --key-pattern=R:R --key-minimum=1 --key-maximum="$KEYS" -d 100 -c 25 -t 4 --pipeline 1 \
		--test-time="$DURATION" --print-percentiles=50,99,99.9,99.99,100 >"$out" 2>&1 &
	local mpid=$!
	taskset -c "$CLIENT_CPUS" "${PY[@]}" "$HERE/probe.py" "$port" "$DURATION" "$((SAVE_AT - 1))" "$((SAVE_AT + 4))" >"$WORK/$label.probe" 2>&1 &
	local ppid=$!
	if [ "$save" = "1" ]; then
		sleep "$SAVE_AT"
		if [ "$OP" = "bgrewriteaof" ]; then
			call "$port" BGREWRITEAOF >/dev/null
			for _ in $(seq 1 600); do
				[ "$(info_field "$port" persistence aof_rewrite_in_progress)" = "0" ] && break
				sleep 0.1
			done
		else
			call "$port" BGSAVE >/dev/null
			for _ in $(seq 1 600); do
				[ "$(info_field "$port" persistence rdb_bgsave_in_progress)" = "0" ] && break
				sleep 0.1
			done
		fi
	fi
	wait "$mpid"
	wait "$ppid"
	awk -v label="$label" '
		/^Type/ { for (i = 1; i <= NF; i++) h[i] = $i; next }
		/^Totals/ { printf "  %-28s ops/sec %10.0f  p50 %7.3f ms  p99 %7.3f ms  p99.9 %7.3f ms  p99.99 %7.3f ms  max %8.3f ms\n", label, $2, $6, $7, $8, $9, $10 }
	' "$out"
	sed 's/^/    /' "$WORK/$label.probe"
}

run_target() {
	local which="$1" port dir
	local aof_args=()
	if [ "$OP" = "bgrewriteaof" ]; then
		aof_args=(--appendonly yes --appendfsync everysec --auto-aof-rewrite-percentage 0)
	fi
	if [ "$which" = "eski" ]; then
		port="$PORT"
		dir="$WORK/eski"
		taskset -c "$SERVER_CPUS" "$SERVER" --port "$port" --enable-debug-command yes --bind 127.0.0.1 --dir "$WORK/eski" "${aof_args[@]}" >"$WORK/eski.log" 2>&1 &
		SERVER_PID=$!
	else
		port="$REF_PORT"
		dir="$WORK/ref"
		if [ "${#aof_args[@]}" -eq 0 ]; then
			aof_args=(--appendonly no)
		fi
		docker run --rm -d --name "$NAME" --network=host --cpuset-cpus="$SERVER_CPUS" --user "$(id -u):$(id -g)" -v "$WORK/ref:/data:z" "$IMAGE" \
			redis-server --port "$port" --bind 127.0.0.1 --dir /data --save "" "${aof_args[@]}" >/dev/null
	fi
	wait_port "$port" || { echo "$which did not start"; return 1; }
	populate "$port"
	echo "$which: $(call "$port" DBSIZE) keys, used_memory $(info_field "$port" memory used_memory_human), server cpus $SERVER_CPUS, client cpus $CLIENT_CPUS"
	measure "$port" "$which-baseline" 0
	measure "$port" "$which-$OP" 1
	if [ "$OP" = "bgrewriteaof" ]; then
		echo "  bgrewriteaof: status $(info_field "$port" persistence aof_last_bgrewrite_status), took $(info_field "$port" persistence aof_last_rewrite_time_sec) s, aof_current_size $(info_field "$port" persistence aof_current_size), files $(ls -l "$dir/appendonlydir" 2>/dev/null | awk 'NR > 1 {printf "%s:%s ", $9, $5}')"
	else
		echo "  bgsave: status $(info_field "$port" persistence rdb_last_bgsave_status), took $(info_field "$port" persistence rdb_last_bgsave_time_sec) s, file $(stat -c %s "$dir/dump.rdb" 2>/dev/null) bytes"
	fi
	echo "  $which latest_fork_usec $(info_field "$port" stats latest_fork_usec)"
	if [ "$which" = "reference" ]; then
		docker rm -f "$NAME" >/dev/null 2>&1
	else
		kill "$SERVER_PID" 2>/dev/null
		wait "$SERVER_PID" 2>/dev/null
		SERVER_PID=""
	fi
}

echo "fork pause under memtier load: $KEYS keys of 100 bytes, 100 clients at pipeline 1, $DURATION s runs, $OP at ${SAVE_AT} s"
run_target eski
run_target reference
