#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../.."

RPORT="${ESKI_BENCH_REDIS_PORT:-6631}"
MPORT="${ESKI_BENCH_MC_PORT:-11311}"
REF_PORT="${ESKI_BENCH_REF_PORT:-11312}"
SERVER_CPUS="${BENCH_SERVER_CPUS:-0-3}"
REF_CPUS="${BENCH_REF_CPUS:-$SERVER_CPUS}"
REF_ARGS="${BENCH_REF_ARGS:-}"
CLIENT_CPUS="${BENCH_CLIENT_CPUS:-4-13}"
MEMTIER_IMAGE="${BENCH_MEMTIER_IMAGE:-docker.io/redislabs/memtier_benchmark:latest}"
MC_IMAGE="${ESKI_MEMCACHED_IMAGE:-docker.io/library/memcached:1.6}"
ROUNDS="${BENCH_ROUNDS:-2}"
TEST_TIME="${BENCH_TEST_TIME:-15}"
PIPELINE="${BENCH_PIPELINE:-1}"
KEYS="${BENCH_KEYS:-1000000}"
THREADS="${BENCH_THREADS:-5}"
CLIENTS="${BENCH_CLIENTS:-10}"
RATIO="${BENCH_RATIO:-1:1}"
DATA_SIZE="${BENCH_DATA_SIZE:-64}"
REF_CONTAINER="eski-mcbench-ref-$$"
SERVER_PID=""
LOG="$(mktemp -t eski-mcbench.XXXXXX)"

stop_all() {
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null
		wait "$SERVER_PID" 2>/dev/null
		SERVER_PID=""
	fi
	docker rm -f "$REF_CONTAINER" >/dev/null 2>&1
}

cleanup() {
	stop_all
	rm -f "$LOG"
}
trap cleanup EXIT

wait_port() {
	for _ in $(seq 1 100); do
		if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then
			return 0
		fi
		sleep 0.1
	done
	return 1
}

memtier() {
	docker run --rm --network=host --cpuset-cpus="$CLIENT_CPUS" "$MEMTIER_IMAGE" -s 127.0.0.1 -p "$1" \
		--protocol=memcache_text --hide-histogram -d "$DATA_SIZE" --key-maximum="$KEYS" "${@:2}" 2>&1
}

run_one() {
	local target="$1" port
	if [ "$target" == "eski" ]; then
		taskset -c "$SERVER_CPUS" ./bin/eski --port "$RPORT" --enable-debug-command yes --memcached-port "$MPORT" >"$LOG" 2>&1 &
		SERVER_PID=$!
		port="$MPORT"
	else
		docker run -d --rm --name "$REF_CONTAINER" --network=host --cpuset-cpus="$REF_CPUS" "$MC_IMAGE" memcached -p "$REF_PORT" -U 0 -l 127.0.0.1 -m 1024 $REF_ARGS >/dev/null
		port="$REF_PORT"
	fi
	if ! wait_port "$port"; then
		echo "$target did not start"
		stop_all
		return 1
	fi
	sleep 1
	memtier "$port" --ratio=1:0 --key-pattern=P:P --requests=allkeys --pipeline=32 --threads=4 --clients=5 >/dev/null
	out="$(memtier "$port" --ratio="$RATIO" --key-pattern=R:R --distinct-client-seed --pipeline="$PIPELINE" --threads="$THREADS" --clients="$CLIENTS" --test-time="$TEST_TIME")"
	stop_all
	ops="$(printf '%s\n' "$out" | awk '/^Totals/ {print $2}')"
	lat="$(printf '%s\n' "$out" | awk '/^Totals/ {print $5}')"
	echo "$target ops_per_sec=$ops avg_latency_ms=$lat"
}

if [ ! -x bin/eski ]; then
	./build.sh || exit 1
fi
for r in $(seq 1 "$ROUNDS"); do
	echo "round $r pipeline $PIPELINE ratio $RATIO threads $THREADS clients $CLIENTS eski cpus $SERVER_CPUS reference cpus $REF_CPUS reference args '$REF_ARGS' client cpus $CLIENT_CPUS"
	run_one eski
	run_one reference
done
