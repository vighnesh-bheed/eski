#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

ODIN="${ODIN:-}"
if [ -z "$ODIN" ]; then
	if command -v odin >/dev/null 2>&1; then
		ODIN="$(command -v odin)"
	elif [ -x "$HOME/odin/current/odin" ]; then
		ODIN="$HOME/odin/current/odin"
	else
		echo "odin compiler not found; set ODIN or put odin on PATH" >&2
		exit 1
	fi
fi

PORT="${ESKI_BITMAP_PORT:-6442}"
ESKI_PORT="${ESKI_BITMAP_ESKI_PORT:-6441}"
SERVER="${ESKI_BITMAP_SERVER:-1}"
ESKI_PID=""
IMAGE="docker.io/library/redis:7"
NAME="eski-bitmap-bench-$PORT"
CPUS="${ESKI_BENCH_CPUS-2}"
SIZES="${ESKI_BENCH_SIZES:-64 512}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eski-bitmap-bench.XXXXXX")"

cleanup() {
	if [ -n "$ESKI_PID" ] && kill -0 "$ESKI_PID" 2>/dev/null; then
		kill "$ESKI_PID" 2>/dev/null || true
		wait "$ESKI_PID" 2>/dev/null || true
	fi
	docker stop -t 2 "$NAME" >/dev/null 2>&1 || true
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	for _ in $(seq 1 100); do
		docker container inspect "$NAME" >/dev/null 2>&1 || break
		sleep 0.1
	done
	rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

LOAD=$(cat <<'PY'
import socket
import sys

port = int(sys.argv[1])
key = sys.argv[2].encode()
with open(sys.argv[3], 'rb') as f:
    data = f.read()
sock = socket.create_connection(('127.0.0.1', port))
sock.sendall(b'*3\r\n$3\r\nSET\r\n$%d\r\n%s\r\n$%d\r\n' % (len(key), key, len(data)))
sock.sendall(memoryview(data))
sock.sendall(b'\r\n')
reply = sock.recv(64)
sock.close()
if not reply.startswith(b'+OK'):
    raise SystemExit('SET failed: %r' % reply)
PY
)

mkdir -p bin
"$ODIN" build test/bitmap -o:speed -out:bin/bitmap-test
if [ "$SERVER" = "1" ]; then
	ODIN="$ODIN" ./build.sh >/dev/null
fi

port_busy() {
	(exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

if port_busy "$PORT"; then
	echo "port $PORT is already in use" >&2
	exit 1
fi
if [ "$SERVER" = "1" ] && port_busy "$ESKI_PORT"; then
	echo "port $ESKI_PORT is already in use" >&2
	exit 1
fi

PIN=()
DOCKER_PIN=()
if [ -n "$CPUS" ]; then
	if command -v taskset >/dev/null 2>&1 && taskset -c "$CPUS" true 2>/dev/null &&
		docker run --rm --cpuset-cpus "$CPUS" "$IMAGE" true >/dev/null 2>&1; then
		PIN=(taskset -c "$CPUS")
		DOCKER_PIN=(--cpuset-cpus "$CPUS")
		echo "pinning eski and Redis to CPU $CPUS"
	else
		echo "warning: cannot pin to CPU $CPUS, running unpinned" >&2
		CPUS=""
	fi
fi

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --rm --name "$NAME" --network host "${DOCKER_PIN[@]}" "$IMAGE" \
	redis-server --port "$PORT" --bind 127.0.0.1 --save "" --appendonly no >/dev/null

cli() {
	docker exec "$NAME" redis-cli -p "$PORT" "$@"
}

ready=0
for _ in $(seq 1 100); do
	if cli ping 2>/dev/null | grep -q PONG; then
		ready=1
		break
	fi
	sleep 0.1
done
if [ "$ready" -ne 1 ]; then
	echo "reference Redis did not start on port $PORT" >&2
	exit 1
fi
echo "reference: $(cli info server | grep -m1 '^redis_version' | tr -d '\r') on port $PORT"

now_ns() {
	date +%s%N
}

jcli() {
	docker exec "$NAME" redis-cli -p "$ESKI_PORT" "$@"
}

if [ "$SERVER" = "1" ]; then
	"${PIN[@]}" ./bin/eski --port "$ESKI_PORT" --enable-debug-command yes --bind 127.0.0.1 >"$WORK/eski.log" 2>&1 &
	ESKI_PID=$!
	ready=0
	for _ in $(seq 1 100); do
		if grep -q "listening on" "$WORK/eski.log" 2>/dev/null; then
			ready=1
			break
		fi
		sleep 0.05
	done
	if [ "$ready" -ne 1 ]; then
		echo "eski did not start on port $ESKI_PORT" >&2
		exit 1
	fi
	echo "eski: bin/eski on port $ESKI_PORT"
fi

around_call() {
	local fn="$1" key="$2" n="$3" t0 t1 t2 t3
	"$fn" set bitcount-bench-empty "" >/dev/null
	t0="$(now_ns)"
	"$fn" -r "$n" bitcount bitcount-bench-empty >/dev/null
	t1="$(now_ns)"
	"$fn" config resetstat >/dev/null
	t2="$(now_ns)"
	"$fn" -r "$n" bitcount "$key" >/dev/null
	t3="$(now_ns)"
	awk -v a=$((t3 - t2)) -v b=$((t1 - t0)) -v n="$n" 'BEGIN { w = (a - b) / n; if (w <= 0) w = a / n; printf "%.0f", w }'
}

ROWS=()
for MB in $SIZES; do
	BYTES=$((MB * 1024 * 1024))
	case "$MB" in
		64) JITERS=60 RITERS=40 ;;
		512) JITERS=12 RITERS=8 ;;
		*) JITERS=20 RITERS=10 ;;
	esac
	KEY="bitcount-bench-$MB"
	./bin/bitmap-test benchdata "$MB" "$WORK/data.bin" >/dev/null
	python3 -I -c "$LOAD" "$PORT" "$KEY" "$WORK/data.bin"
	if [ "$SERVER" = "1" ]; then
		python3 -I -c "$LOAD" "$ESKI_PORT" "$KEY" "$WORK/data.bin"
	fi
	rm -f "$WORK/data.bin"
	len="$(cli strlen "$KEY")"
	if [ "$len" != "$BYTES" ]; then
		echo "Redis holds $len bytes for $KEY, expected $BYTES" >&2
		exit 1
	fi

	jline="$("${PIN[@]}" ./bin/bitmap-test bench "$MB" "$JITERS")"
	echo "$jline"
	jcount="$(sed -E 's/.* count=([0-9]+).*/\1/' <<<"$jline")"
	jmean="$(sed -E 's/.* mean_bytes_per_sec=([0-9]+).*/\1/' <<<"$jline")"

	rcount="$(cli bitcount "$KEY")"
	if [ "$rcount" != "$jcount" ]; then
		echo "BITCOUNT mismatch: Redis $rcount, eski package $jcount" >&2
		exit 1
	fi
	rwall_ns="$(around_call cli "$KEY" "$RITERS")"
	stat="$(cli info commandstats | tr -d '\r' | grep '^cmdstat_bitcount:')"
	calls="$(sed -E 's/^cmdstat_bitcount:calls=([0-9]+),usec=([0-9]+),.*/\1/' <<<"$stat")"
	usec="$(sed -E 's/^cmdstat_bitcount:calls=([0-9]+),usec=([0-9]+),.*/\2/' <<<"$stat")"
	if [ "$calls" != "$RITERS" ]; then
		echo "unexpected commandstats line: $stat" >&2
		exit 1
	fi
	echo "redis  bytes=$BYTES calls=$RITERS around_call_ms=$(awk -v w="$rwall_ns" 'BEGIN { printf "%.3f", w / 1e6 }') server_usec_per_call=$(awk -v u="$usec" -v c="$calls" 'BEGIN { printf "%.1f", u / c }') count=$rcount"

	swall_ns=0
	if [ "$SERVER" = "1" ]; then
		jlen="$(jcli strlen "$KEY")"
		scount="$(jcli bitcount "$KEY")"
		if [ "$jlen" != "$BYTES" ] || [ "$scount" != "$rcount" ]; then
			echo "eski server holds $jlen bytes and counts $scount, Redis counts $rcount" >&2
			exit 1
		fi
		swall_ns="$(around_call jcli "$KEY" "$RITERS")"
		echo "server bytes=$BYTES calls=$RITERS around_call_ms=$(awk -v w="$swall_ns" 'BEGIN { printf "%.3f", w / 1e6 }') count=$scount"
		jcli del "$KEY" >/dev/null
	fi

	row="$(awk -v mb="$MB" -v bytes="$BYTES" -v rwall="$rwall_ns" -v swall="$swall_ns" \
		-v usec="$usec" -v calls="$calls" -v jmean="$jmean" 'BEGIN {
		rcall = bytes / (rwall / 1e9)
		rsrv = bytes / (usec / calls / 1e6)
		scall = swall > 0 ? bytes / (swall / 1e9) : 0
		printf "%-6s %16.0f %16.0f %16.0f %16.0f %8.2f %8.2f", mb "MB", jmean, scall, rcall, rsrv, jmean / rsrv, (swall > 0 ? scall / rcall : jmean / rcall)
	}')"
	ROWS+=("$row")
	cli del "$KEY" >/dev/null
done

echo
printf '%-6s %16s %16s %16s %16s %8s %8s\n' size package_B/s server_call_B/s redis_call_B/s redis_cmd_B/s r_pkg r_server
for row in "${ROWS[@]}"; do
	echo "$row"
done
echo
echo "package_B/s is the popcount inside bin/bitmap-test, server_call_B/s and redis_call_B/s are BITCOUNT timed around redis-cli calls"
echo "against bin/eski and Redis with the per call overhead of an empty key subtracted, and redis_cmd_B/s comes from INFO commandstats."
echo "r_pkg is package_B/s over redis_cmd_B/s and r_server is server_call_B/s over redis_call_B/s; above 0.5 meets the factor of two requirement"
fail=0
for row in "${ROWS[@]}"; do
	r1="$(awk '{print $6}' <<<"$row")"
	r2="$(awk '{print $7}' <<<"$row")"
	if awk -v a="$r1" -v b="$r2" 'BEGIN { exit !(a < 0.5 || b < 0.5) }'; then
		fail=1
	fi
done
if [ "$fail" -ne 0 ]; then
	echo "BITCOUNT throughput is not within a factor of two of Redis" >&2
	exit 1
fi
echo "BITCOUNT throughput is within a factor of two of Redis"
