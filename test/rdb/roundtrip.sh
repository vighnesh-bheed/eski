#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../.."

PORT="${ESKI_RDB_PORT:-6611}"
REF_PORT="${ESKI_RDB_REF_PORT:-6613}"
SERVER="${ESKI_RDB_SERVER:-bin/eski}"
IMAGE="${ESKI_REDIS_IMAGE:-docker.io/library/redis:7}"
NAME="eski-rdb-roundtrip-$REF_PORT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eski-rdb-roundtrip.XXXXXX")"
PY=(python3 -I -B)
HERE="test/rdb"
SERVER_PID=""
STATUS=0

cleanup() {
	if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill -9 "$SERVER_PID" 2>/dev/null
		wait "$SERVER_PID" 2>/dev/null
	fi
	docker rm -f "$NAME" >/dev/null 2>&1
	if [ "${ESKI_RDB_KEEP:-0}" = "1" ]; then
		echo "kept work directory $WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT

if [ ! -x "$SERVER" ]; then
	./build.sh || exit 2
fi
mkdir -p "$WORK/eski" "$WORK/ref"

wait_port() {
	for _ in $(seq 1 100); do
		if "${PY[@]}" -c "import socket,sys; s=socket.create_connection(('127.0.0.1', int(sys.argv[1]))); s.sendall(b'PING\r\n'); sys.exit(0 if s.recv(64).startswith(b'+PONG') else 1)" "$1" 2>/dev/null; then
			return 0
		fi
		sleep 0.1
	done
	echo "nothing answers PING on port $1" >&2
	return 1
}

start_eski() {
	"$SERVER" --port "$PORT" --enable-debug-command yes --bind 127.0.0.1 --dir "$WORK/eski" "$@" >>"$WORK/eski.log" 2>&1 &
	SERVER_PID=$!
	wait_port "$PORT" || exit 2
}

stop_eski() {
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null
		wait "$SERVER_PID" 2>/dev/null
		SERVER_PID=""
	fi
}

REF_DIR=""

start_ref() {
	docker run --rm -d --name "$NAME" --network=host --user "$(id -u):$(id -g)" -v "${REF_DIR:-$WORK/ref}:/data:z" "$IMAGE" \
		redis-server --port "$REF_PORT" --bind 127.0.0.1 --dir /data --save "" --enable-debug-command yes "$@" >/dev/null || exit 2
	wait_port "$REF_PORT" || exit 2
}

stop_ref() {
	docker rm -f "$NAME" >/dev/null 2>&1
	for _ in $(seq 1 50); do
		docker container inspect "$NAME" >/dev/null 2>&1 || break
		sleep 0.1
	done
}

call() {
	"${PY[@]}" -c "import sys; sys.path.insert(0, sys.argv[1]); import resp; c = resp.Client(int(sys.argv[2])); r = c.call(*sys.argv[3:]); print(r); sys.exit(1 if isinstance(r, resp.Error) else 0)" "$HERE" "$@"
}

step() {
	echo
	echo "== $*"
}

run() {
	if ! "$@"; then
		STATUS=1
	fi
}

step "building the same dataset on eski ($PORT) and the reference ($REF_PORT)"
start_eski
start_ref
"${PY[@]}" "$HERE/dataset.py" "$PORT" || exit 1
"${PY[@]}" "$HERE/dataset.py" "$REF_PORT" || exit 1
call "$PORT" SAVE >/dev/null || exit 1
call "$REF_PORT" SAVE >/dev/null || exit 1
cp "$WORK/eski/dump.rdb" "$WORK/eski-own.rdb"
cp "$WORK/ref/dump.rdb" "$WORK/ref-own.rdb"
"${PY[@]}" "$HERE/snapshot.py" "$PORT" "$WORK/J0.json"
"${PY[@]}" "$HERE/snapshot.py" "$REF_PORT" "$WORK/R0.json" dump
run "${PY[@]}" "$HERE/compare.py" "$WORK/J0.json" "$WORK/R0.json" "live datasets built by commands" type,encoding,digest

step "byte comparison of the two files, rdbcompression yes"
run "${PY[@]}" "$HERE/rdbcmp.py" "$WORK/eski-own.rdb" "$WORK/ref-own.rdb"

step "byte comparison of the two files, rdbcompression no"
call "$PORT" CONFIG SET rdbcompression no >/dev/null
call "$REF_PORT" CONFIG SET rdbcompression no >/dev/null
call "$PORT" SAVE >/dev/null
call "$REF_PORT" SAVE >/dev/null
run "${PY[@]}" "$HERE/rdbcmp.py" "$WORK/eski/dump.rdb" "$WORK/ref/dump.rdb"
call "$PORT" CONFIG SET rdbcompression yes >/dev/null
call "$REF_PORT" CONFIG SET rdbcompression yes >/dev/null

step "eski writes, the reference loads"
stop_ref
cp "$WORK/eski-own.rdb" "$WORK/ref/dump.rdb"
start_ref
"${PY[@]}" "$HERE/snapshot.py" "$REF_PORT" "$WORK/R1.json" dump
run "${PY[@]}" "$HERE/compare.py" "$WORK/J0.json" "$WORK/R1.json" "reference loaded eski's file vs live eski" type,encoding,digest,xinfo --loaded
run "${PY[@]}" "$HERE/compare.py" "$WORK/R0.json" "$WORK/R1.json" "reference loaded eski's file vs the reference's own live dataset, DUMP payloads" dump,digest --loaded
call "$REF_PORT" SAVE >/dev/null
call "$REF_PORT" DEBUG RELOAD >/dev/null
"${PY[@]}" "$HERE/snapshot.py" "$REF_PORT" "$WORK/R2.json" dump
run "${PY[@]}" "$HERE/compare.py" "$WORK/R1.json" "$WORK/R2.json" "reference re-dump after a second save and load" dump,digest,xinfo

step "the reference writes, eski loads at startup"
stop_eski
cp "$WORK/ref-own.rdb" "$WORK/eski/dump.rdb"
start_eski
"${PY[@]}" "$HERE/snapshot.py" "$PORT" "$WORK/J1.json"
run "${PY[@]}" "$HERE/compare.py" "$WORK/R0.json" "$WORK/J1.json" "eski loaded the reference's file vs the live reference" type,encoding,digest,xinfo --loaded
run "${PY[@]}" "$HERE/compare.py" "$WORK/R1.json" "$WORK/J1.json" "eski loaded the reference's file vs the reference loaded eski's file" type,encoding,digest
call "$PORT" DEBUG RELOAD >/dev/null
"${PY[@]}" "$HERE/snapshot.py" "$PORT" "$WORK/J2.json"
run "${PY[@]}" "$HERE/compare.py" "$WORK/J1.json" "$WORK/J2.json" "eski after DEBUG RELOAD of its own save" type,encoding,digest,xinfo

step "eski with rdbchecksum no writes, the reference loads"
stop_eski
cp "$WORK/eski-own.rdb" "$WORK/eski/dump.rdb"
start_eski --rdbchecksum no
call "$PORT" SAVE >/dev/null
stop_eski
tail -c 8 "$WORK/eski/dump.rdb" | od -An -tx1 | tr -d ' \n' | grep -q '^0000000000000000$' && echo "checksum field is zero" || { echo "FAIL checksum field is not zero"; STATUS=1; }
stop_ref
cp "$WORK/eski/dump.rdb" "$WORK/ref/dump.rdb"
start_ref
"${PY[@]}" "$HERE/snapshot.py" "$REF_PORT" "$WORK/R3.json" dump
run "${PY[@]}" "$HERE/compare.py" "$WORK/R1.json" "$WORK/R3.json" "reference loaded eski's checksum-less file" type,encoding,digest,xinfo

step "the reference with rdbchecksum no and rdbcompression no writes, eski loads"
stop_ref
cp "$WORK/ref-own.rdb" "$WORK/ref/dump.rdb"
start_ref --rdbchecksum no --rdbcompression no
call "$REF_PORT" SAVE >/dev/null
stop_ref
cp "$WORK/ref/dump.rdb" "$WORK/eski/dump.rdb"
start_eski
"${PY[@]}" "$HERE/snapshot.py" "$PORT" "$WORK/J3.json"
run "${PY[@]}" "$HERE/compare.py" "$WORK/J1.json" "$WORK/J3.json" "eski loaded the reference's uncompressed checksum-less file" type,encoding,digest,xinfo
stop_eski

step "corrupt and edge case files, eski against the reference"
mkdir -p "$WORK/cases"
"${PY[@]}" "$HERE/craft.py" "$WORK/eski-own.rdb" "$WORK/cases" || { echo "FAIL could not craft the case files"; STATUS=1; }

answers() {
	"${PY[@]}" -c "import socket,sys; s=socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=1); s.sendall(b'PING\r\n'); sys.exit(0 if s.recv(64).startswith(b'+PONG') else 1)" "$1" 2>/dev/null
}

running() {
	local state
	state="$(sed -n 's/^.*) \([A-Za-z]\) .*$/\1/p' "/proc/$1/stat" 2>/dev/null)"
	[ -n "$state" ] && [ "$state" != Z ] && [ "$state" != X ]
}

case_eski() {
	"$SERVER" --port "$PORT" --enable-debug-command yes --bind 127.0.0.1 --dir "$1/j" >"$1/eski.log" 2>&1 &
	SERVER_PID=$!
	for _ in $(seq 1 200); do
		if ! running "$SERVER_PID"; then
			wait "$SERVER_PID"
			OUTCOME=$?
			SERVER_PID=""
			return
		fi
		if answers "$PORT"; then
			OUTCOME=started
			return
		fi
		sleep 0.1
	done
	OUTCOME="neither started nor exited"
	kill -9 "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	SERVER_PID=""
}

case_ref() {
	docker run -d --name "$NAME" --network=host --user "$(id -u):$(id -g)" -v "$1/r:/data:z" "$IMAGE" \
		redis-server --port "$REF_PORT" --bind 127.0.0.1 --dir /data --save "" >/dev/null || exit 2
	local state
	for _ in $(seq 1 600); do
		state="$(docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' "$NAME" 2>/dev/null)"
		if [ "${state%% *}" = false ]; then
			OUTCOME="${state#* }"
			return
		fi
		if answers "$REF_PORT"; then
			OUTCOME=started
			return
		fi
		sleep 0.1
	done
	OUTCOME="neither started nor exited"
}

describe() {
	case "$1" in
	started)
		echo "started"
		;;
	"" | *[!0-9]*)
		echo "$1"
		;;
	*)
		echo "exited with status $1"
		;;
	esac
}

case_fail() {
	echo "FAIL $CASE: $*"
	STATUS=1
	CASE_BAD=1
}

check_started() {
	local who="$1" port="$2" n idle
	if [ "$CASE" = idle ]; then
		idle="$(call "$port" OBJECT IDLETIME idle)"
		if [ "$idle" -ge 3599 ] 2>/dev/null && [ "$idle" -le 3700 ]; then echo "  idle: $who OBJECT IDLETIME after load is $idle"; else case_fail "$who OBJECT IDLETIME after load is $idle"; fi
	fi
	if [ "$CASE" = expired ]; then
		n="$(call "$port" DBSIZE)"
		if [ "$n" = "1" ]; then echo "  expired: $who loaded only the live key"; else case_fail "$who DBSIZE after load is $n"; fi
	fi
}

logged() {
	grep -m1 -E -- "$1" "$2" | sed -E 's/^[0-9]+:[A-Z] [^*#]*[*#] //'
}

while IFS=$'\t' read -r name category jexpect jpattern rexpect rpattern; do
	CASE="$name"
	CASE_BAD=0
	dir="$WORK/case-$name"
	mkdir -p "$dir/j" "$dir/r"
	cp "$WORK/cases/$name.rdb" "$dir/j/dump.rdb"
	cp "$WORK/cases/$name.rdb" "$dir/r/dump.rdb"
	case_eski "$dir"
	jout="$OUTCOME"
	if [ "$jout" = started ]; then
		check_started eski "$PORT"
		stop_eski
	fi
	case_ref "$dir"
	rout="$OUTCOME"
	if [ "$rout" = started ]; then
		check_started "the reference" "$REF_PORT"
	fi
	docker logs "$NAME" >"$dir/ref.log" 2>&1
	stop_ref
	if [ "$jout" != "$jexpect" ]; then
		case_fail "eski $(describe "$jout"), expected it to have $(describe "$jexpect")"
	fi
	if [ "$rout" != "$rexpect" ]; then
		case_fail "the reference $(describe "$rout"), expected it to have $(describe "$rexpect")"
	fi
	if { [ "$jout" = started ] && [ "$rout" != started ]; } || { [ "$jout" != started ] && [ "$rout" = started ]; }; then
		case_fail "the outcomes differ: eski $(describe "$jout"), the reference $(describe "$rout")"
	fi
	if ! grep -qE -- "$jpattern" "$dir/eski.log"; then
		case_fail "eski's log does not name $category, no line matches \"$jpattern\""
		sed 's/^/    /' "$dir/eski.log" | tail -5
	fi
	if ! grep -qE -- "$rpattern" "$dir/ref.log"; then
		case_fail "the reference's log does not name $category, no line matches \"$rpattern\""
		sed 's/^/    /' "$dir/ref.log" | grep -v "^    $" | tail -6
	fi
	if [ "$CASE_BAD" = 0 ]; then
		if [ "$jout" = started ]; then
			echo "  $name: both started and both logged $category"
		else
			echo "  $name: both refused to start, eski $(describe "$jout") and the reference $(describe "$rout"), and both logged $category"
		fi
		echo "    eski: $(logged "$jpattern" "$dir/eski.log")"
		echo "    reference: $(logged "$rpattern" "$dir/ref.log")"
	fi
done <"$WORK/cases/cases.txt"

step "older stream encodings, types 15, 19 and 21, loaded by eski and by the reference"
for version in 15 19 21; do
	dir="$WORK/stream-$version"
	mkdir -p "$dir/j" "$dir/r"
	cp "$WORK/cases/stream$version.rdb" "$dir/j/dump.rdb"
	cp "$WORK/cases/stream$version.rdb" "$dir/r/dump.rdb"
	"$SERVER" --port "$PORT" --enable-debug-command yes --bind 127.0.0.1 --dir "$dir/j" >"$dir/eski.log" 2>&1 &
	SERVER_PID=$!
	wait_port "$PORT" || exit 2
	"${PY[@]}" "$HERE/snapshot.py" "$PORT" "$dir/J.json" >/dev/null
	stop_eski
	REF_DIR="$dir/r"
	start_ref
	REF_DIR=""
	"${PY[@]}" "$HERE/snapshot.py" "$REF_PORT" "$dir/R.json" >/dev/null
	stop_ref
	run "${PY[@]}" "$HERE/compare.py" "$dir/R.json" "$dir/J.json" "stream type $version loaded by both servers, XINFO STREAM FULL" type,encoding,digest,xinfo
done

step "log lines"
grep -hE "Loading RDB produced|DB loaded from disk|Done loading RDB|checksum disabled|DB saved on disk" "$WORK/eski.log" | sed 's/^[0-9]*:M [^*#]*/  /' | sort | uniq -c

echo
if [ "$STATUS" = 0 ]; then
	echo "roundtrip: PASS"
else
	echo "roundtrip: FAIL"
fi
exit "$STATUS"
