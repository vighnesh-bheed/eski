#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../.."

PORT="${ESKI_AOF_PORT:-6611}"
REF_PORT="${ESKI_AOF_REF_PORT:-6613}"
SERVER="${ESKI_AOF_SERVER:-bin/eski}"
IMAGE="${ESKI_REDIS_IMAGE:-docker.io/library/redis:7}"
NAME="eski-aof-roundtrip-$REF_PORT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eski-aof-roundtrip.XXXXXX")"
PY=(python3 -I -B)
SERVER_PID=""
STATUS=0
PASSED=0

cleanup() {
	if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill -9 "$SERVER_PID" 2>/dev/null
		wait "$SERVER_PID" 2>/dev/null
	fi
	docker rm -f "$NAME" >/dev/null 2>&1
	if [ "${ESKI_AOF_KEEP:-0}" = "1" ]; then
		echo "kept work directory $WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT

if [ ! -x "$SERVER" ]; then
	./build.sh || exit 2
fi

wait_port() {
	for _ in $(seq 1 100); do
		if "${PY[@]}" -c "import socket,sys; s=socket.create_connection(('127.0.0.1', int(sys.argv[1]))); s.sendall(b'PING\r\n'); sys.exit(0 if s.recv(64).startswith(b'+PONG') else 1)" "$1" 2>/dev/null; then
			return 0
		fi
		sleep 0.1
	done
	return 1
}

start_eski() {
	local dir="$1"
	shift
	mkdir -p "$dir"
	"$SERVER" --port "$PORT" --enable-debug-command yes --bind 127.0.0.1 --dir "$dir" "$@" >>"$dir.log" 2>&1 &
	SERVER_PID=$!
	wait_port "$PORT"
}

stop_eski() {
	if [ -n "$SERVER_PID" ]; then
		kill "$1" "$SERVER_PID" 2>/dev/null
		wait "$SERVER_PID" 2>/dev/null
		SERVER_PID=""
	fi
}

start_ref() {
	local dir="$1"
	shift
	mkdir -p "$dir"
	docker rm -f "$NAME" >/dev/null 2>&1
	docker run -d --name "$NAME" --user "$(id -u):$(id -g)" --network host -v "$dir:/data" "$IMAGE" \
		redis-server --port "$REF_PORT" --bind 127.0.0.1 --save "" --enable-debug-command yes "$@" >/dev/null
	wait_port "$REF_PORT"
}

stop_ref() {
	docker stop -t 10 "$NAME" >/dev/null 2>&1
	docker logs "$NAME" >"$1" 2>&1
	docker rm -f "$NAME" >/dev/null 2>&1
}

check() {
	local label="$1"
	shift
	if "$@"; then
		PASSED=$((PASSED + 1))
	else
		echo "FAILED: $label"
		STATUS=1
	fi
}

snap() {
	"${PY[@]}" test/rdb/snapshot.py "$1" "$2" >/dev/null
}

same() {
	"${PY[@]}" test/aof/snapcmp.py "$1" "$2" "$3" "${4:-type,digest,xinfo,encoding}"
}

info_field() {
	"${PY[@]}" -c "
import sys
sys.path.insert(0, 'test/rdb')
import resp
c = resp.Client(int(sys.argv[1]))
for l in c.call('INFO', 'persistence').decode().split('\r\n'):
    if l.startswith(sys.argv[2] + ':'):
        print(l.split(':', 1)[1])
" "$1" "$2"
}

wait_rewrite() {
	for _ in $(seq 1 600); do
		if [ "$(info_field "$1" aof_rewrite_in_progress)" = "0" ] && [ "$(info_field "$1" aof_rewrite_scheduled)" = "0" ]; then
			return 0
		fi
		sleep 0.05
	done
	return 1
}

rcall() {
	"${PY[@]}" -c "
import sys
sys.path.insert(0, 'test/rdb')
import resp
c = resp.Client(int(sys.argv[1]))
r = c.call(*sys.argv[2:])
print(r.decode() if isinstance(r, bytes) else r)
" "$@"
}

echo "== restart and kill under each fsync policy"
for policy in always everysec no; do
	d="$WORK/fsync-$policy"
	start_eski "$d" --appendonly yes --appendfsync "$policy" || exit 2
	"${PY[@]}" test/aof/workload.py "$PORT" build || exit 2
	snap "$PORT" "$d-a.json"
	stop_eski -TERM
	start_eski "$d" --appendonly yes --appendfsync "$policy" || exit 2
	snap "$PORT" "$d-b.json"
	check "restart $policy" same "$d-a.json" "$d-b.json" "appendfsync $policy, SHUTDOWN and restart"
	"${PY[@]}" test/aof/workload.py "$PORT" more || exit 2
	snap "$PORT" "$d-c.json"
	stop_eski -KILL
	start_eski "$d" --appendonly yes --appendfsync "$policy" || exit 2
	snap "$PORT" "$d-d.json"
	check "kill $policy" same "$d-c.json" "$d-d.json" "appendfsync $policy, kill -9 right after the last reply and restart"
	stop_eski -TERM
done

echo "== rewrites and DEBUG LOADAOF"
d="$WORK/rewrite"
start_eski "$d" || exit 2
"${PY[@]}" test/aof/workload.py "$PORT" build || exit 2
rcall "$PORT" CONFIG SET appendonly yes >/dev/null
"${PY[@]}" test/aof/workload.py "$PORT" more || exit 2
wait_rewrite "$PORT"
snap "$PORT" "$d-a.json"
rcall "$PORT" DEBUG LOADAOF >/dev/null
snap "$PORT" "$d-b.json"
check "enable at runtime" same "$d-a.json" "$d-b.json" "CONFIG SET appendonly yes with writes during the first rewrite, then DEBUG LOADAOF"
rcall "$PORT" BGREWRITEAOF >/dev/null
wait_rewrite "$PORT"
rcall "$PORT" SET after:rdb-base 1 >/dev/null
snap "$PORT" "$d-c.json"
rcall "$PORT" DEBUG LOADAOF >/dev/null
snap "$PORT" "$d-d.json"
check "rdb base" same "$d-c.json" "$d-d.json" "BGREWRITEAOF with an RDB preamble base, then DEBUG LOADAOF"
rcall "$PORT" CONFIG SET aof-use-rdb-preamble no >/dev/null
rcall "$PORT" BGREWRITEAOF >/dev/null
wait_rewrite "$PORT"
rcall "$PORT" SET after:aof-base 1 >/dev/null
snap "$PORT" "$d-e.json"
rcall "$PORT" DEBUG LOADAOF >/dev/null
snap "$PORT" "$d-f.json"
check "command base" same "$d-e.json" "$d-f.json" "BGREWRITEAOF with a command base, then DEBUG LOADAOF" type,digest
stop_eski -TERM
echo "files after the rewrites: $(ls "$d/appendonlydir" | tr '\n' ' ')"

echo "== eski's files loaded by the reference"
for src in fsync-always rewrite; do
	r="$WORK/ref-loads-$src"
	mkdir -p "$r"
	cp -r "$WORK/$src/appendonlydir" "$r/"
	start_ref "$r" --appendonly yes || exit 2
	snap "$REF_PORT" "$r.json"
	last="$WORK/fsync-always-d.json"
	fields=type,digest,xinfo,encoding
	if [ "$src" = rewrite ]; then
		last="$WORK/rewrite-f.json"
		fields=type,digest,xinfo
	fi
	check "ref loads $src" same "$last" "$r.json" "reference loads eski's $src directory ($(ls "$r/appendonlydir" | tr '\n' ' '))" "$fields"
	stop_ref "$r.log"
done

echo "== the reference's files loaded by eski"
for preamble in yes no; do
	r="$WORK/ref-preamble-$preamble"
	start_ref "$r" --appendonly yes --aof-use-rdb-preamble "$preamble" || exit 2
	"${PY[@]}" test/aof/workload.py "$REF_PORT" build || exit 2
	rcall "$REF_PORT" BGREWRITEAOF >/dev/null
	wait_rewrite "$REF_PORT"
	"${PY[@]}" test/aof/workload.py "$REF_PORT" more || exit 2
	rcall "$REF_PORT" DEBUG LOADAOF >/dev/null
	snap "$REF_PORT" "$r-live.json"
	stop_ref "$r.log"
	j="$WORK/eski-loads-$preamble"
	mkdir -p "$j"
	cp -r "$r/appendonlydir" "$j/"
	start_eski "$j" --appendonly yes || exit 2
	snap "$PORT" "$j.json"
	fields=type,digest,xinfo,encoding
	check "eski loads ref $preamble" same "$r-live.json" "$j.json" "eski loads the reference's directory with aof-use-rdb-preamble $preamble ($(ls "$j/appendonlydir" | tr '\n' ' ')) against the reference's own DEBUG LOADAOF" "$fields"
	stop_eski -TERM
done

echo "== damaged files, both servers"
seed="$WORK/seed"
start_eski "$seed" --appendonly yes || exit 2
for i in 1 2 3 4 5; do rcall "$PORT" SET "k$i" "v$i" >/dev/null; done
stop_eski -TERM
incr="appendonlydir/appendonly.aof.1.incr.aof"
full="$WORK/seed-incr.aof"
cp "$seed/$incr" "$full"
size=$(wc -c <"$full")
damage() {
	local name="$1" dir="$2"
	rm -rf "$dir"
	mkdir -p "$dir"
	cp -r "$seed/appendonlydir" "$dir/"
	case "$name" in
	truncated | truncated-strict) head -c $((size - 5)) "$full" >"$dir/$incr" ;;
	garbage) { head -c 50 "$full"; printf 'garbage\r\n'; tail -c +51 "$full"; } >"$dir/$incr" ;;
	unknown) { cat "$full"; printf '*2\r\n$6\r\nFOOBAR\r\n$1\r\nx\r\n'; } >"$dir/$incr" ;;
	multi) { cat "$full"; printf '*1\r\n$5\r\nMULTI\r\n*3\r\n$3\r\nSET\r\n$1\r\nx\r\n$1\r\ny\r\n'; } >"$dir/$incr" ;;
	annotated) { printf '#TS:1700000000\r\n'; cat "$full"; printf '#TS:1700000001\r\n*3\r\n$3\r\nSET\r\n$1\r\nz\r\n$1\r\nz\r\n'; } >"$dir/$incr" ;;
	esac
}
loglines() {
	sed -n 's/^[0-9]*:[A-Z] [0-9]* [A-Za-z]* [0-9]* [0-9:.]* \([*#] .*\)$/\1/p' "$1" | grep -E 'AOF|append only|aof|Truncating|short read|MULTI|Unknown command|Bad file format|Unexpected end' | grep -v 'Opening AOF incr\|Creating AOF' | sed -E -e 's/[0-9]+\.[0-9]+ seconds/N seconds/' -e 's/^([*#] (Bad file format|Unexpected end of file) reading the append only file [^ :]*[.:]).*$/\1/' || true
}
for case_ in truncated truncated-strict garbage unknown multi annotated; do
	extra=()
	if [ "$case_" = truncated-strict ]; then
		extra=(--aof-load-truncated no)
	fi
	jd="$WORK/damage-$case_-eski"
	rd="$WORK/damage-$case_-ref"
	damage "$case_" "$jd"
	damage "$case_" "$rd"
	"$SERVER" --port "$PORT" --enable-debug-command yes --bind 127.0.0.1 --dir "$jd" --appendonly yes "${extra[@]}" >"$jd.log" 2>&1 &
	SERVER_PID=$!
	jup=0
	if wait_port "$PORT"; then
		jup=1
		jkeys="$(rcall "$PORT" DBSIZE)"
	else
		jkeys="-"
	fi
	stop_eski -TERM
	docker rm -f "$NAME" >/dev/null 2>&1
	docker run -d --name "$NAME" --user "$(id -u):$(id -g)" --network host -v "$rd:/data" "$IMAGE" \
		redis-server --port "$REF_PORT" --bind 127.0.0.1 --save "" --appendonly yes "${extra[@]}" >/dev/null
	rup=0
	if wait_port "$REF_PORT"; then
		rup=1
		rkeys="$(rcall "$REF_PORT" DBSIZE)"
	else
		rkeys="-"
	fi
	docker stop -t 5 "$NAME" >/dev/null 2>&1
	docker logs "$NAME" >"$rd.log" 2>&1
	docker rm -f "$NAME" >/dev/null 2>&1
	jl="$(loglines "$jd.log")"
	rl="$(loglines "$rd.log")"
	js=$(wc -c <"$jd/$incr")
	rs=$(wc -c <"$rd/$incr")
	if [ "$jup:$jkeys:$js" = "$rup:$rkeys:$rs" ] && [ "$jl" = "$rl" ]; then
		echo "damaged file $case_: same outcome (started $jup, keys $jkeys, incr size after $js) and the same log lines"
		PASSED=$((PASSED + 1))
	else
		echo "FAILED: damaged file $case_"
		echo "  eski: started $jup keys $jkeys size $js"
		echo "$jl" | sed 's/^/    /'
		echo "  reference: started $rup keys $rkeys size $rs"
		echo "$rl" | sed 's/^/    /'
		STATUS=1
	fi
done

echo "aof roundtrip: $PASSED checks passed"
if [ "$STATUS" -ne 0 ]; then
	echo "aof roundtrip: FAILED"
	exit 1
fi
echo "aof roundtrip: PASS"
