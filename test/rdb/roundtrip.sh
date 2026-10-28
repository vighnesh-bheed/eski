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
while IFS=$'\t' read -r name code msg withref refcode; do
	dir="$WORK/case-$name"
	mkdir -p "$dir/j" "$dir/r"
	cp "$WORK/cases/$name.rdb" "$dir/j/dump.rdb"
	cp "$WORK/cases/$name.rdb" "$dir/r/dump.rdb"
	if [ "$code" = "1" ]; then
		timeout 20 "$SERVER" --port "$PORT" --enable-debug-command yes --bind 127.0.0.1 --dir "$dir/j" >"$dir/eski.log" 2>&1
		jcode=$?
	else
		"$SERVER" --port "$PORT" --enable-debug-command yes --bind 127.0.0.1 --dir "$dir/j" >"$dir/eski.log" 2>&1 &
		SERVER_PID=$!
		wait_port "$PORT" || exit 2
		jcode=0
		if [ "$name" = "idle" ]; then
			idle="$(call "$PORT" OBJECT IDLETIME idle)"
			if [ "$idle" -ge 3599 ] && [ "$idle" -le 3700 ]; then echo "  idle: OBJECT IDLETIME after load is $idle"; else echo "FAIL idle time after load is $idle"; STATUS=1; fi
		fi
		if [ "$name" = "expired" ]; then
			n="$(call "$PORT" DBSIZE)"
			if [ "$n" = "1" ]; then echo "  expired: only the live key was loaded"; else echo "FAIL expired: dbsize $n"; STATUS=1; fi
		fi
		stop_eski
	fi
	if [ "$jcode" != "$code" ]; then
		echo "FAIL $name: eski exit status $jcode, expected $code"
		STATUS=1
	fi
	if grep -qF -- "$msg" "$dir/eski.log"; then
		echo "  $name: eski logged \"$msg\" and exited with $jcode"
	else
		echo "FAIL $name: eski did not log \"$msg\""
		sed 's/^/    /' "$dir/eski.log" | tail -5
		STATUS=1
	fi
	if [ "$withref" = "1" ]; then
		if [ "$code" = "1" ]; then
			timeout 60 docker run --rm --name "$NAME" --network=host --user "$(id -u):$(id -g)" -v "$dir/r:/data:z" "$IMAGE" \
				redis-server --port "$REF_PORT" --bind 127.0.0.1 --dir /data --save "" >"$dir/ref.log" 2>&1
			rcode=$?
		else
			REF_DIR="$dir/r"
			start_ref
			REF_DIR=""
			if [ "$name" = "expired" ]; then
				echo "  expired: the reference loaded $(call "$REF_PORT" DBSIZE) key"
			fi
			if [ "$name" = "idle" ]; then
				echo "  idle: reference OBJECT IDLETIME after load is $(call "$REF_PORT" OBJECT IDLETIME idle)"
			fi
			docker logs "$NAME" >"$dir/ref.log" 2>&1
			stop_ref
			rcode=0
		fi
		jline="$(grep -o 'Internal error in RDB reading.*' "$dir/eski.log" | head -1)"
		rline="$(grep -o 'Internal error in RDB reading.*' "$dir/ref.log" | head -1)"
		if [ "$jline" != "$rline" ]; then
			echo "FAIL $name: eski logged \"$jline\", the reference logged \"$rline\""
			STATUS=1
		elif [ -n "$jline" ]; then
			echo "  $name: both logged \"$jline\""
		fi
		if [ "$rcode" = "$refcode" ] && grep -qF -- "$msg" "$dir/ref.log"; then
			if [ "$refcode" = "$code" ]; then
				echo "  $name: the reference logged the same line and exited with $rcode"
			else
				echo "  $name: the reference logged the same line and exited with $rcode (eski exits with $code)"
			fi
		else
			echo "FAIL $name: the reference exited with $rcode, log follows"
			sed 's/^/    /' "$dir/ref.log" | grep -v "^    $" | tail -6
			STATUS=1
		fi
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
