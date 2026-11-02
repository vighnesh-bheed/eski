#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."

PORT="${ESKI_SMOKE_PORT:-6399}"
IMAGE="${ESKI_REDIS_IMAGE:-docker.io/library/redis:7}"
EXTERNAL="${ESKI_SMOKE_EXTERNAL:-0}"
BENCH="${ESKI_SMOKE_BENCH:-0}"
KEYSPACE_THREADS="${ESKI_SMOKE_KEYSPACE_THREADS:-0}"
BINARY="${ESKI_SMOKE_BINARY:-./bin/eski}"
if [ -n "${ESKI_SMOKE_BINARY:-}" ] && [ ! -x "$BINARY" ]; then
	printf 'ESKI_SMOKE_BINARY is not executable: %s\n' "$BINARY" >&2
	exit 1
fi
PASS=0
FAIL=0
SERVER_PID=""
ACL_SERVER_PID=""
ACL_REF_CONTAINER="eski-smoke-acl-$$"
CLI_CONTAINER="eski-smoke-cli-$$"
REF_PORT="${ESKI_SMOKE_REF_PORT:-$((PORT + 1))}"
REF_CONTAINER="eski-smoke-ref-$$"
MIGRATE_PORT="${ESKI_SMOKE_MIGRATE_PORT:-$REF_PORT}"
MIGRATE_PID=""
MIGRATE_REF_OUTPUT=""
MC_PORT="${ESKI_SMOKE_MC_PORT:-11311}"
MC_REF_PORT="${ESKI_SMOKE_MC_REF_PORT:-11312}"
MC_IMAGE="${ESKI_MEMCACHED_IMAGE:-docker.io/library/memcached:1.6}"
MC_REF_CONTAINER="eski-smoke-mcref-$$"
MC_REF_CLOCK_SETTLE_SECONDS=3
LOG="$(mktemp -t eski-smoke.XXXXXX)"
PERSIST_DIR="$(mktemp -d -t eski-smoke-rdb.XXXXXX)"

cleanup() {
	if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill "$SERVER_PID" 2>/dev/null
		wait "$SERVER_PID" 2>/dev/null
	fi
	if [ -n "$MIGRATE_PID" ] && kill -0 "$MIGRATE_PID" 2>/dev/null; then
		kill "$MIGRATE_PID" 2>/dev/null
		wait "$MIGRATE_PID" 2>/dev/null
	fi
	if [ -n "$ACL_SERVER_PID" ] && kill -0 "$ACL_SERVER_PID" 2>/dev/null; then
		kill "$ACL_SERVER_PID" 2>/dev/null
		wait "$ACL_SERVER_PID" 2>/dev/null
	fi
	docker rm -f "$CLI_CONTAINER" >/dev/null 2>&1
	docker rm -f "$REF_CONTAINER" >/dev/null 2>&1
	docker rm -f "$MC_REF_CONTAINER" >/dev/null 2>&1
	docker rm -f "$ACL_REF_CONTAINER" >/dev/null 2>&1
	rm -f "$LOG"
	chmod -R u+rwx "$PERSIST_DIR" 2>/dev/null
	rm -rf "$PERSIST_DIR"
}
trap cleanup EXIT

cli() {
	docker exec "$CLI_CONTAINER" redis-cli -p "$PORT" "$@" 2>&1
}

cli_pipe() {
	docker exec -i "$CLI_CONTAINER" redis-cli -p "$PORT" 2>&1
}

ref_cli() {
	docker exec "$CLI_CONTAINER" redis-cli -p "$REF_PORT" "$@" 2>&1
}

ref_pipe() {
	docker exec -i "$CLI_CONTAINER" redis-cli -p "$REF_PORT" 2>&1
}

pass() {
	PASS=$((PASS + 1))
}

fail() {
	FAIL=$((FAIL + 1))
	echo "FAIL: $1"
	echo "  expected: $(printf '%q' "$2")"
	echo "  got:      $(printf '%q' "$3")"
}

expect() {
	local name="$1" exp="$2"
	shift 2
	local got
	got="$(cli "$@")"
	if [ "$got" == "$exp" ]; then pass; else fail "$name" "$exp" "$got"; fi
}

expect_pipe() {
	local name="$1" exp="$2" input="$3"
	local got
	got="$(printf '%s\n' "$input" | cli_pipe)"
	if [ "$got" == "$exp" ]; then pass; else fail "$name" "$exp" "$got"; fi
}

expect_match() {
	local name="$1" re="$2"
	shift 2
	local got
	got="$(cli "$@")"
	if [[ "$got" =~ $re ]]; then pass; else fail "$name" "$re" "$got"; fi
}

expect_sorted() {
	local name="$1" exp="$2"
	shift 2
	local got
	got="$(cli "$@" | sort)"
	if [ "$got" == "$exp" ]; then pass; else fail "$name" "$exp" "$got"; fi
}

info_field() {
	cli info "$1" | tr -d '\r' | grep "^$2:" | cut -d: -f2
}

raw_line() {
	local fd="$1" secs="$2" line rc
	IFS= read -r -t "$secs" -u "$fd" line
	rc=$?
	if [ "$rc" -eq 0 ]; then
		printf '%s\n' "${line%$'\r'}"
	elif [ "$rc" -le 128 ]; then
		printf '%s<EOF>' "$line"
	fi
	return "$rc"
}

raw_collect() {
	local fd="$1" secs="$2" out=""
	while out+="$(raw_line "$fd" "$secs")"; do
		out+=$'\n'
	done
	printf '%s' "$out"
}

elapsed_ms() {
	local now="${EPOCHREALTIME/./}"
	echo $(((now - $1) / 1000))
}

slab_check="$(python3 -I test/slab/run.py 2>&1)"
if [ "$?" -eq 0 ]; then
	pass
else
	fail "slab allocation boundaries" "all allocator regressions pass" "$slab_check"
fi

hash_check="$(python3 -I test/hashtype/run.py 2>&1)"
if [ "$?" -eq 0 ]; then
	pass
else
	fail "hash member migration" "all bounded hash regressions pass" "$hash_check"
fi

set_check="$(python3 -I test/settype/run.py 2>&1)"
if [ "$?" -eq 0 ]; then
	pass
else
	fail "set member migration" "all bounded set regressions pass" "$set_check"
fi

zset_check="$(python3 -I test/zsettype/run.py 2>&1)"
if [ "$?" -eq 0 ]; then
	pass
else
	fail "zset dictionary migration" "all bounded sorted-set regressions pass" "$zset_check"
fi

storage_check="$(python3 -I test/storage/run.py 2>&1)"
if [ "$?" -eq 0 ]; then
	pass
else
	fail "storage allocation ownership" "all storage ownership regressions pass" "$storage_check"
fi

if [ "$EXTERNAL" != "1" ]; then
	if [ ! -x "$BINARY" ]; then
		./build.sh || exit 1
	fi
	"$BINARY" --port "$PORT" --enable-debug-command yes --dir "$PERSIST_DIR" --memcached-port "$MC_PORT" --keyspace-threads "$KEYSPACE_THREADS" >"$LOG" 2>&1 &
	SERVER_PID=$!
fi

storage_server_check="$(python3 -I test/storage/server.py --server "$BINARY" --port "${ESKI_STORAGE_PORT:-$((PORT + 20))}" 2>&1)"
if [ "$?" -eq 0 ]; then
	pass
else
	fail "storage memory reports and persistence" "all bounded server regressions pass" "$storage_server_check"
fi

hash_idle_check="$(python3 -I test/hashtype/idle.py --server "$BINARY" --port "${ESKI_HASH_IDLE_PORT:-$((PORT + 21))}" 2>&1)"
if [ "$?" -eq 0 ]; then
	pass
else
	fail "idle hash member migration" "hashes finish bounded quiet work with expiry disabled" "$hash_idle_check"
fi

set_idle_check="$(python3 -I test/settype/idle.py --server "$BINARY" --port "${ESKI_SET_IDLE_PORT:-$((PORT + 22))}" 2>&1)"
if [ "$?" -eq 0 ]; then
	pass
else
	fail "idle set member migration" "sets in nonzero databases finish quiet work with expiry disabled" "$set_idle_check"
fi

zset_idle_check="$(python3 -I test/zsettype/idle.py --server "$BINARY" --port "${ESKI_ZSET_IDLE_PORT:-$((PORT + 23))}" 2>&1)"
if [ "$?" -eq 0 ]; then
	pass
else
	fail "idle zset dictionary migration" "multiple zsets finish quiet work in nonzero databases with expiry disabled" "$zset_idle_check"
fi

slab_server_check="$(python3 -I test/slab/server.py --server "$BINARY" --port "${ESKI_SLAB_PORT:-$((PORT + 24))}" 2>&1)"
if [ "$?" -eq 0 ]; then
	pass
else
	fail "slab reclaim lifecycle" "partial and whole-zero idle reclaim preserve binary and independent heap/object keys" "$slab_server_check"
fi

if ! docker run -d --rm --name "$CLI_CONTAINER" --network=host --entrypoint sleep "$IMAGE" infinity >/dev/null; then
	echo "could not start the redis-cli helper container from $IMAGE"
	exit 1
fi

ready=0
for _ in $(seq 1 100); do
	if [ "$(cli ping)" == "PONG" ]; then
		ready=1
		break
	fi
	if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
		echo "eski exited during startup:"
		cat "$LOG"
		exit 1
	fi
	sleep 0.1
done
if [ "$ready" != "1" ]; then
	echo "server on port $PORT never answered PING"
	exit 1
fi
echo "server is up on port $PORT"

expect "flushall" "OK" flushall
expect "ping" "PONG" ping
expect "ping message" "hello" ping hello
expect "ping mixed case" "PONG" PiNg
expect "ping arity" $'ERR wrong number of arguments for \'ping\' command' ping a b
expect "echo" "hi there" echo "hi there"
expect "echo arity" $'ERR wrong number of arguments for \'echo\' command' echo
expect "unknown command" $'ERR unknown command \'FOOBAR\', with args beginning with: \'a\' \'b\' ' FOOBAR a b
expect "unknown command no args" $'ERR unknown command \'nosuch\', with args beginning with: ' nosuch
expect "get arity" $'ERR wrong number of arguments for \'get\' command' get

expect_pipe "set and get" $'OK\nv1\n\nOK\nv2\nv2\n\nv3\nv3\nOK\nv5' "$(cat <<'CMDS'
SET k1 v1
GET k1
SET k1 v2 NX
SET k1 v2 XX
GET k1
SET k1 v3 GET
SET newk v GET
SET k1 v4 NX GET
GET k1
set k1 v5
get k1
CMDS
)"

expect_pipe "set errors" $'ERR invalid expire time in \'set\' command\n\nERR invalid expire time in \'set\' command\n\nERR value is not an integer or out of range\n\nERR syntax error\n\nERR syntax error\n\nERR syntax error\n\nERR syntax error\n\nERR invalid expire time in \'set\' command' "$(cat <<'CMDS'
SET k3 v EX 0
SET k3 v PX -5
SET k3 v EX abc
SET k3 v NX XX
SET k3 v EX 10 PX 100
SET k3 v BOGUS
SET k3 v EX
SET k3 v EX 9999999999999999
CMDS
)"

expect_pipe "set expiry options" $'OK\n100\nOK\n-1\nOK\n100\nOK\n100\nOK\n1\nv\n-2' "$(cat <<'CMDS'
SET t1 v EX 100
TTL t1
SET t1 v
TTL t1
SET t1 v PX 100000
TTL t1
SET t1 v KEEPTTL
TTL t1
SET t2 v EXAT 99999999999
EXISTS t2
SET t2 v PXAT 99999999999000 XX GET
TTL nonexistent-key-check
CMDS
)"
expect_match "pttl after pxat" '^[0-9]+$' pttl t2

expect_pipe "getdel getset setnx" $'v5\n\n\na\nb\n1\n0\na' "$(cat <<'CMDS'
GETDEL k1
GETDEL k1
GETSET gs a
GETSET gs b
GET gs
SETNX nx1 a
SETNX nx1 b
GET nx1
CMDS
)"

expect_pipe "setex psetex" $'OK\n100\nOK\nOK\nv\nERR invalid expire time in \'setex\' command\n\nERR value is not an integer or out of range\n\nERR invalid expire time in \'psetex\' command' "$(cat <<'CMDS'
SETEX se 100 v
TTL se
PSETEX pse 100000 v
SETEX se 50 v
GET pse
SETEX se 0 v
SETEX se x v
PSETEX pse -1 v
CMDS
)"
expect_match "psetex pttl" '^(99[0-9]{3}|100000)$' pttl pse

expect_pipe "mset mget msetnx" $'OK\na\nb\n\nc\nERR wrong number of arguments for \'mset\' command\n\n0\n1\nx\ny' "$(cat <<'CMDS'
MSET m1 a m2 b m3 c
MGET m1 m2 nope m3
MSET m1 a m2
MSETNX m1 x m9 y
MSETNX m8 x m9 y
MGET m8 m9
CMDS
)"

expect_pipe "append strlen" $'5\n11\nhello world\n11\n0' "$(cat <<'CMDS'
APPEND ap hello
APPEND ap " world"
GET ap
STRLEN ap
STRLEN nope
CMDS
)"

expect_pipe "incr decr" $'1\n2\n12\n11\n6\nERR value is not an integer or out of range\n\nERR value is not an integer or out of range\n\nOK\nERR increment or decrement would overflow\n\nOK\nERR increment or decrement would overflow\n\nERR decrement would overflow\n\nOK\nERR value is not an integer or out of range\n\n-5\n-5' "$(cat <<'CMDS'
INCR cnt
INCR cnt
INCRBY cnt 10
DECR cnt
DECRBY cnt 5
INCRBY cnt abc
INCR ap
SET big 9223372036854775807
INCR big
SET small -9223372036854775808
DECR small
DECRBY cnt -9223372036854775808
SET z 01
INCR z
DECRBY neg 5
GET neg
CMDS
)"

expect_pipe "del unlink exists type" $'2\n1\n3\nstring\nnone\n0' "$(cat <<'CMDS'
DEL m1 m2 nope
UNLINK m3 nope
EXISTS m8 m9 m8 nope
TYPE m8
TYPE nope
DEL nope
CMDS
)"

expect_pipe "expire family" $'OK\n1\n100\n0\n1\n200\n0\n1\n1\n10\nERR NX and XX, GT or LT options at the same time are not compatible\n\nERR GT and LT options at the same time are not compatible\n\nERR Unsupported option FOO\n\n0\nERR value is not an integer or out of range\n\n1\n1\n1\n1\n0\n-1\n-2\n-2' "$(cat <<'CMDS'
SET e1 v
EXPIRE e1 100
TTL e1
EXPIRE e1 100 NX
EXPIRE e1 200 XX
TTL e1
EXPIRE e1 50 GT
EXPIRE e1 500 GT
EXPIRE e1 10 LT
TTL e1
EXPIRE e1 10 NX XX
EXPIRE e1 10 GT LT
EXPIRE e1 10 FOO
EXPIRE nope 10
EXPIRE e1 abc
PEXPIRE e1 100000
EXPIREAT e1 99999999999
PEXPIREAT e1 99999999999000
PERSIST e1
PERSIST e1
TTL e1
TTL nope
PTTL nope
CMDS
)"

expect_pipe "expire in the past deletes" $'OK\n1\n0\nOK\n1\n\nOK\n1\n0' "$(cat <<'CMDS'
SET e2 v
EXPIRE e2 -1
EXISTS e2
SET e3 v
EXPIREAT e3 1
GET e3
SET e4 v
PEXPIREAT e4 0
EXISTS e4
CMDS
)"

expect_pipe "lazy expiry" $'OK\nv' "$(cat <<'CMDS'
SET lazy v PX 300
GET lazy
CMDS
)"
sleep 0.6
expect "lazy expiry after deadline" "" get lazy
expect "lazy expiry ttl" "-2" ttl lazy

expect_pipe "touch" $'2' "TOUCH m8 m9 nope"

expect_pipe "rename" $'OK\n1\nOK\nval\n1000\n0\nERR no such key\n\nOK\nOK\nOK\nval\n1000' "$(cat <<'CMDS'
SET r1 val
EXPIRE r1 1000
RENAME r1 r2
GET r2
TTL r2
EXISTS r1
RENAME nope r3
RENAME r2 r2
SET r4 other
RENAME r2 r4
GET r4
TTL r4
CMDS
)"

expect_pipe "access clock setup" $'OK\nOK\nOK\nOK\nOK\nOK\nOK\nOK' "$(cat <<'CMDS'
SET idle:a v
SET idle:b v
SET idle:c v
SET idle:d v
SET idle:e v
SET idle:f v
SET idle:g v
SET idle:m v
CMDS
)"
sleep 2.2
expect_match "idle time grows without access" '^[23]$' object idletime idle:a
got="$(printf 'TTL idle:a\nPTTL idle:a\nTYPE idle:a\nEXISTS idle:a\nEXPIRETIME idle:a\nOBJECT ENCODING idle:a\nOBJECT REFCOUNT idle:a\nSCAN 0 MATCH idle:a TYPE string COUNT 1000\nOBJECT IDLETIME idle:a\n' | cli_pipe | tail -n 1)"
if [[ "$got" =~ ^[23]$ ]]; then pass; else fail "ttl type exists object and scan type leave the access time alone" "2 or 3" "$got"; fi
expect_pipe "get and touch reset the idle time" $'v\n0\n1\n0\nOK\n0\n1\n0\n1\nOK\n0\n1\nOK' "$(cat <<'CMDS'
GET idle:b
OBJECT IDLETIME idle:b
TOUCH idle:c
OBJECT IDLETIME idle:c
RENAME idle:d idle:d2
OBJECT IDLETIME idle:d2
COPY idle:e idle:e2
OBJECT IDLETIME idle:e2
MOVE idle:m 3
SELECT 3
OBJECT IDLETIME idle:m
DEL idle:m
SELECT 0
CMDS
)"
got="$(printf 'CLIENT NO-TOUCH on\nGET idle:f\nOBJECT IDLETIME idle:f\nTOUCH idle:g\nOBJECT IDLETIME idle:g\nCLIENT NO-TOUCH off\n' | cli_pipe | tr '\n' ' ')"
if [[ "$got" =~ ^OK\ v\ [23]\ 1\ 0\ OK\ $ ]]; then pass; else fail "no-touch keeps the access time except for TOUCH" "OK v 2|3 1 0 OK" "$got"; fi

expect_pipe "select" $'OK\nOK\nERR DB index is out of range\n\nERR value is not an integer or out of range' "$(cat <<'CMDS'
SELECT 0
SELECT 15
SELECT 16
SELECT x
CMDS
)"

expect "flushall before databases" "OK" flushall
expect_pipe "databases keep separate keyspaces" $'OK\nOK\nOK\nOK\nOK\nOK\nOK\n2\nOK\n0\n1\nOK\nOK\n0' "$(cat <<'CMDS'
SET dbk 0
SELECT 7
SET dbk 7
SET dbk2 7
SELECT 13
SET dbk 13
SELECT 7
DBSIZE
SELECT 0
GET dbk
DBSIZE
SELECT 13
FLUSHDB
DBSIZE
CMDS
)"
expect "flushdb leaves other databases" "2" -n 7 dbsize
expect "flushall clears every database" "OK" flushall
expect "database 7 empty after flushall" "0" -n 7 dbsize
active_cmds="SELECT 7"$'\n'
for i in $(seq 1 40); do
	active_cmds+="SET dbae$i v PX 800"$'\n'
done
active_cmds+="SELECT 12"$'\n'
for i in $(seq 1 40); do
	active_cmds+="SET dbae$i v PX 800"$'\n'
done
active_cmds+="SET dbkeep v EX 1000"$'\n'
printf '%s' "$active_cmds" | cli_pipe >/dev/null
expect_match "info keyspace lists every non empty database" $'db7:keys=40,expires=40,avg_ttl=[0-9]+,subexpiry=0\r?\ndb12:keys=41,expires=41,avg_ttl=[0-9]+,subexpiry=0' info keyspace
sleep 2
expect "active expiry visits database 7" "0" -n 7 dbsize
expect "active expiry visits database 12" "1" -n 12 dbsize
expect_match "info keyspace drops emptied databases" $'^# Keyspace\r?\ndb12:keys=1,expires=1,avg_ttl=[0-9]+,subexpiry=0\r?$' info keyspace
expect "flushall after active expiry" "OK" flushall
if [ -x "$BINARY" ]; then
	for bad in 0:"argument must be between 1 and 2147483647 inclusive" 1025:"eski supports at most 1024 databases" x:"argument couldn't be parsed into an integer"; do
		got="$("$BINARY" --port "$PORT" --databases "${bad%%:*}" 2>&1)"
		rc=$?
		want="$(printf '\n*** FATAL CONFIG FILE ERROR (eski 0.1.0) ***\nReading the configuration file, at line 3\n>>> '"'"'databases "%s"'"'"'\n%s' "${bad%%:*}" "${bad#*:}")"
		if [ "$rc" == "1" ] && [ "$got" == "$want" ]; then pass; else fail "databases option rejects ${bad%%:*}" "exit 1 with $want" "$rc $got"; fi
	done
fi

expect "flushdb" "OK" flushdb
expect "dbsize empty" "0" dbsize
expect "randomkey empty" "" randomkey
expect_pipe "randomkey single" $'OK\nonly1\n1' "$(cat <<'CMDS'
SET only1 v
RANDOMKEY
DBSIZE
CMDS
)"
expect "flushall sync" "OK" flushall sync
expect "flushall bad arg" $'ERR syntax error' flushall foo

expect "mset glob keys" "OK" mset hello 1 hallo 1 hxllo 1 hllo 1 heeeello 1 other 1
expect_sorted "keys star" $'hallo\nheeeello\nhello\nhllo\nhxllo\nother' keys '*'
expect_sorted "keys question" $'hallo\nhello\nhxllo' keys 'h?llo'
expect_sorted "keys star mid" $'hallo\nheeeello\nhello\nhllo\nhxllo' keys 'h*llo'
expect_sorted "keys class" $'hallo\nhello' keys 'h[ae]llo'
expect_sorted "keys negated class" $'hallo\nhxllo' keys 'h[^e]llo'
expect_sorted "keys range" $'hallo' keys 'h[a-b]llo'
expect "keys none" "" keys 'zzz*'

scan_all() {
	local cursor=0 out keys=""
	while :; do
		out="$(cli scan "$cursor" "$@")"
		cursor="$(printf '%s\n' "$out" | head -n1)"
		keys+="$(printf '%s\n' "$out" | tail -n +2)"$'\n'
		if [ "$cursor" == "0" ]; then break; fi
	done
	printf '%s' "$keys" | grep -v '^$' | sort
}
got="$(scan_all count 2)"
if [ "$got" == $'hallo\nheeeello\nhello\nhllo\nhxllo\nother' ]; then pass; else fail "scan full iteration" "all six keys" "$got"; fi
got="$(scan_all match 'h?llo' count 3)"
if [ "$got" == $'hallo\nhello\nhxllo' ]; then pass; else fail "scan match" "h?llo keys" "$got"; fi
expect "scan bad cursor" $'ERR invalid cursor' scan abc
expect "scan bad count" $'ERR syntax error' scan 0 count 0
expect "dbsize" "6" dbsize

expect "flushall before active expiry" "OK" flushall
expire_cmds=""
for i in $(seq 1 50); do
	expire_cmds+="SET ae$i v PX 100"$'\n'
done
printf '%s' "$expire_cmds" | cli_pipe >/dev/null
expect "persistent key alongside volatile" "OK" set keeper v
sleep 1
expect "active expiry removed volatile keys without access" "1" dbsize
expired="$(info_field stats expired_keys)"
if [ -n "$expired" ] && [ "$expired" -ge 50 ]; then pass; else fail "expired_keys counter" ">= 50" "$expired"; fi

expect "command" "get" command list filterby pattern get
expect "command docs" "" command docs nosuchcmd
expect "command info" "" command info nosuchcmd
expect_match "command count" '^[1-9][0-9]*$' command count

expect_match "hello 3" $'^server eski\nversion 7\\.4\\.11\nproto 3\nid [0-9]+\nmode standalone\nrole master\nmodules $' hello 3
expect "hello 4" $'NOPROTO unsupported protocol version' hello 4
got="$(printf 'HELLO 3 SETNAME r3conn\nCLIENT INFO\nRESET\nCLIENT INFO\n' | docker exec -i "$CLI_CONTAINER" redis-cli -p "$PORT" 2>&1)"
if [[ "$got" =~ name=r3conn\ [^$'\n']*\ resp=3\  ]] && [[ "$got" =~ RESET$'\n'id=[0-9]+\ [^$'\n']*\ name=\ [^$'\n']*\ resp=2\  ]]; then pass; else fail "hello 3 switches the connection and reset switches it back" "resp=3 then resp=2" "$got"; fi
expect "hello bad version" $'ERR Protocol version is not an integer or out of range' hello abc
expect_match "hello 2" $'^server\neski\nversion\n7\\.4\\.11\nproto\n2\nid\n[0-9]+\nmode\nstandalone\nrole\nmaster\nmodules$' hello 2
expect_match "hello no args" $'^server\neski\n' hello

expect_pipe "client name" $'\nOK\nmyname\nOK\nERR Client names cannot contain spaces, newlines or special characters.\n\nmyname' "$(cat <<'CMDS'
CLIENT GETNAME
CLIENT SETNAME myname
CLIENT GETNAME
CLIENT SETINFO lib-name smoke
CLIENT SETNAME "bad name"
CLIENT GETNAME
CMDS
)"
expect_match "client id" '^[0-9]+$' client id
CLIENT_LINE_RE='id=[0-9]+ addr=[0-9.]+:[0-9]+ laddr=[0-9.]+:[0-9]+ fd=[0-9]+ name=listed age=[0-9]+ idle=[0-9]+ flags=N db=0 sub=0 psub=0 ssub=0 multi=-1 watch=0 qbuf=[0-9]+ qbuf-free=[0-9]+ argv-mem=[0-9]+ multi-mem=0 rbs=[0-9]+ rbp=[0-9]+ obl=0 oll=0 omem=0 tot-mem=[0-9]+ events=r cmd=client\|list user=default redir=-1 resp=2 lib-name= lib-ver='
got="$(printf 'CLIENT SETNAME listed\nCLIENT LIST\n' | cli_pipe)"
if [[ "$got" =~ $CLIENT_LINE_RE ]]; then pass; else fail "client list format" "$CLIENT_LINE_RE" "$got"; fi
got="$(printf 'CLIENT SETNAME listed\nCLIENT LIST TYPE normal\n' | cli_pipe)"
if [[ "$got" =~ $CLIENT_LINE_RE ]]; then pass; else fail "client list type normal" "$CLIENT_LINE_RE" "$got"; fi
exec {raw}<>"/dev/tcp/127.0.0.1/$PORT"
printf 'CLIENT ID\r\n' >&"$raw"
myid="$(raw_line "$raw" 1)"
myid="${myid#:}"
myid="${myid%$'\n'}"
printf 'CLIENT LIST ID 999999 %s\r\n' "$myid" >&"$raw"
got="$(raw_collect "$raw" 0.5)"
exec {raw}>&-
if [[ "$got" =~ ^\$[0-9]+$'\n'id=$myid\ [^$'\n']*\ cmd=client\|list\ [^$'\n']*\ lib-ver=$ ]]; then pass; else fail "client list id" "only id=$myid" "$got"; fi
expect "client unknown subcommand" $'ERR unknown subcommand \'FOO\'. Try CLIENT HELP.' client FOO
expect_match "client help" $'^CLIENT <subcommand> \\[<arg> \\[value\\] \\[opt\\] \\.\\.\\.\\]\\. Subcommands are:\n' client help
got="$(cli client help | wc -l)"
if [ "$got" == "58" ]; then pass; else fail "client help lines" "58" "$got"; fi

expect_pipe "connection command errors" $'ERR AUTH <password> called without any password configured for the default user. Are you sure your configuration is correct?\n\nOK\nWRONGPASS invalid username-password pair or user is disabled.\n\nERR syntax error\n\nWRONGPASS invalid username-password pair or user is disabled.\n\nERR Syntax error in HELLO option \'SETNAME\'\n\nERR Client names cannot contain spaces, newlines or special characters.\n\nERR Syntax error in HELLO option \'BOGUS\'\n\nNOPROTO unsupported protocol version\n\n-1\nERR CLIENT CACHING can be called only when the client is in tracking mode with OPTIN or OPTOUT mode enabled\n\nERR wrong number of arguments for \'client|caching\' command\n\nOK\nOK\nERR syntax error\n\nOK\nOK\nERR wrong number of arguments for \'client|no-touch\' command\n\n0\n0\n0\nERR CLIENT UNBLOCK reason should be TIMEOUT or ERROR\n\nERR value is not an integer or out of range\n\nERR unknown subcommand or wrong number of arguments for \'UNBLOCK\'. Try CLIENT HELP.\n\nOK\nERR LIB-NAME cannot contain spaces, newlines or special characters.\n\nERR Unrecognized option \'badger\'\n\nERR wrong number of arguments for \'client|setinfo\' command\n\nERR Client names cannot contain spaces, newlines or special characters.\n\nOK\nok-name\nOK\n\nERR timeout is not an integer or out of range\n\nERR timeout is negative\n\nERR CLIENT PAUSE mode must be WRITE or ALL\n\nERR unknown subcommand or wrong number of arguments for \'PAUSE\'. Try CLIENT HELP.\n\nOK\nOK\nERR wrong number of arguments for \'client|unpause\' command\n\nERR wrong number of arguments for \'client|kill\' command\n\nERR No such client\n\n0\nERR client-id should be greater than 0\n\nERR client-id should be greater than 0\n\nERR syntax error\n\nERR Unknown client type \'bogus\'\n\n0\nERR No such user \'nobody\'\n\n0\nERR syntax error\n\nERR maxage should be greater than 0\n\nERR maxage is not an integer or out of range\n\n0\nERR Unknown client type \'bogus\'\nERR Invalid client ID\nERR syntax error\nERR syntax error\n\nERR unknown subcommand \'FOO\'. Try CLIENT HELP.\n\nERR wrong number of arguments for \'client|id\' command\n\nRESET\nERR wrong number of arguments for \'reset\' command' "$(cat <<'CMDS'
AUTH pass
AUTH default pass
AUTH someone pass
AUTH a b c
HELLO 2 AUTH someone pw
HELLO 2 SETNAME
HELLO 2 SETNAME "bad name"
HELLO 2 BOGUS
HELLO 1
CLIENT GETREDIR
CLIENT CACHING yes
CLIENT CACHING yes x
CLIENT NO-EVICT on
CLIENT NO-EVICT off
CLIENT NO-EVICT maybe
CLIENT NO-TOUCH on
CLIENT NO-TOUCH off
CLIENT NO-TOUCH on x
CLIENT UNBLOCK 999999
CLIENT UNBLOCK 999999 TIMEOUT
CLIENT UNBLOCK 999999 ERROR
CLIENT UNBLOCK 999999 BOGUS
CLIENT UNBLOCK x
CLIENT UNBLOCK 1 timeout extra
CLIENT SETINFO lib-ver 1.0
CLIENT SETINFO LIB-NAME "a b"
CLIENT SETINFO badger x
CLIENT SETINFO lib-name
CLIENT SETNAME "a b"
CLIENT SETNAME ok-name
CLIENT GETNAME
CLIENT SETNAME ""
CLIENT GETNAME
CLIENT PAUSE abc
CLIENT PAUSE -1
CLIENT PAUSE 10 bogus
CLIENT PAUSE 10 write extra
CLIENT PAUSE 0
CLIENT UNPAUSE
CLIENT UNPAUSE x
CLIENT KILL
CLIENT KILL 1.2.3.4:5
CLIENT KILL ID 999999
CLIENT KILL ID 0
CLIENT KILL ID x
CLIENT KILL ID 1 extra
CLIENT KILL TYPE bogus
CLIENT KILL TYPE master
CLIENT KILL USER nobody
CLIENT KILL USER default ID 999999
CLIENT KILL SKIPME maybe
CLIENT KILL MAXAGE -1
CLIENT KILL MAXAGE x
CLIENT KILL ADDR 1.2.3.4:5 LADDR 1.2.3.4:6
CLIENT LIST TYPE bogus
CLIENT LIST ID x
CLIENT LIST ID 999999
CLIENT LIST TYPE master
CLIENT LIST foo
CLIENT REPLY bogus
CLIENT FOO
CLIENT ID x
RESET
RESET x
CMDS
)"

expect "client list rejects an addr filter" "ERR syntax error" client list addr 1.2.3.4:5
expect "client list rejects type with addr" "ERR syntax error" client list type normal addr 1.2.3.4:5
expect "client list rejects a maxage filter" "ERR syntax error" client list maxage 100000
expect "client list rejects a user filter" "ERR syntax error" client list user nobody
expect "client list rejects maxage zero" "ERR syntax error" client list maxage 0
expect "client list rejects a word maxage" "ERR syntax error" client list maxage x
expect "client list rejects skipme" "ERR syntax error" client list skipme maybe
exec {raw}<>"/dev/tcp/127.0.0.1/$PORT"
printf 'CLIENT ID\r\nCLIENT INFO\r\n' >&"$raw"
got="$(raw_collect "$raw" 0.5)"
myid=""
myaddr=""
myladdr=""
if [[ "$got" =~ ^:([0-9]+)$'\n'.*\ addr=([^ ]+)\ laddr=([^ ]+)\  ]]; then
	myid="${BASH_REMATCH[1]}"
	myaddr="${BASH_REMATCH[2]}"
	myladdr="${BASH_REMATCH[3]}"
fi
printf 'CLIENT LIST ADDR %s LADDR %s USER default SKIPME no\r\nCLIENT LIST ADDR %s SKIPME yes\r\n' "$myaddr" "$myladdr" "$myaddr" >&"$raw"
got="$(raw_collect "$raw" 0.5)"
exec {raw}>&-
if [ -n "$myid" ] && [ "$got" = $'-ERR syntax error\n-ERR syntax error' ]; then pass; else fail "client list rejects addr, laddr, user and skipme filters" "two syntax errors" "$got"; fi

got="$(printf 'CLIENT SETNAME infoname\nSELECT 3\nCLIENT NO-EVICT on\nCLIENT NO-TOUCH on\nCLIENT SETINFO lib-name smokelib\nCLIENT SETINFO lib-ver 2.0\nCLIENT INFO\nRESET\nCLIENT GETNAME\nCLIENT INFO\n' | cli_pipe)"
INFO_RE='^OK
OK
OK
OK
OK
OK
id=[0-9]+ addr=[0-9.]+:[0-9]+ laddr=[0-9.]+:[0-9]+ fd=[0-9]+ name=infoname age=[0-9]+ idle=[0-9]+ flags=eT db=3 sub=0 psub=0 ssub=0 multi=-1 watch=0 qbuf=26 qbuf-free=[0-9]+ argv-mem=10 multi-mem=0 rbs=[0-9]+ rbp=[0-9]+ obl=0 oll=0 omem=0 tot-mem=[0-9]+ events=r cmd=client\|info user=default redir=-1 resp=2 lib-name=smokelib lib-ver=2\.0
RESET

id=[0-9]+ addr=[0-9.]+:[0-9]+ laddr=[0-9.]+:[0-9]+ fd=[0-9]+ name= age=[0-9]+ idle=[0-9]+ flags=N db=0 sub=0 psub=0 ssub=0 multi=-1 watch=0 qbuf=26 qbuf-free=[0-9]+ argv-mem=10 multi-mem=0 rbs=[0-9]+ rbp=[0-9]+ obl=0 oll=0 omem=0 tot-mem=[0-9]+ events=r cmd=client\|info user=default redir=-1 resp=2 lib-name=smokelib lib-ver=2\.0
?$'
if [[ "$got" =~ $INFO_RE ]]; then pass; else fail "client info tracks state and reset clears it" "$INFO_RE" "$got"; fi

exec {raw}<>"/dev/tcp/127.0.0.1/$PORT"
printf 'CLIENT REPLY OFF\r\nPING a\r\nCLIENT REPLY ON\r\nPING b\r\nCLIENT REPLY SKIP\r\nPING c\r\nPING d\r\nCLIENT REPLY SKIP\r\nCLIENT REPLY ON\r\nPING e\r\n' >&"$raw"
got="$(raw_collect "$raw" 0.5)"
exec {raw}>&-
if [ "$got" == $'+OK\n$1\nb\n$1\nd\n+OK\n$1\ne' ]; then pass; else fail "client reply off, on and skip" $'+OK\n$1\nb\n$1\nd\n+OK\n$1\ne' "$got"; fi

exec {victim}<>"/dev/tcp/127.0.0.1/$PORT"
printf 'CLIENT ID\r\n' >&"$victim"
vid="$(raw_line "$victim" 1)"
vid="${vid#:}"
vid="${vid%$'\n'}"
expect "client kill id from another connection" "1" client kill id "$vid"
got="$(raw_collect "$victim" 1)"
exec {victim}>&-
if [ "$got" == "<EOF>" ]; then pass; else fail "killed connection is closed" "<EOF>" "$got"; fi
expect "client kill id of a closed client" "0" client kill id "$vid"

expect "flushall before pause" "OK" flushall
exec {held}<>"/dev/tcp/127.0.0.1/$PORT"
expect "client pause write" "OK" client pause 10000 write
printf 'SET pausekey v1\r\nGET pausekey\r\n' >&"$held"
got="$(raw_collect "$held" 0.4)"
if [ "$got" == "" ]; then pass; else fail "write is held during pause write" "" "$got"; fi
expect "read passes during pause write" "" get pausekey
expect "client unpause" "OK" client unpause
got="$(raw_collect "$held" 0.5)"
if [ "$got" == $'+OK\n$2\nv1' ]; then pass; else fail "held pipeline runs in order after unpause" $'+OK\n$2\nv1' "$got"; fi
expect "client pause write with timeout" "OK" client pause 600 write
start="${EPOCHREALTIME/./}"
printf 'SET pausekey v2\r\n' >&"$held"
got="$(raw_line "$held" 3)"
waited="$(elapsed_ms "$start")"
if [ "$got" == "+OK" ] && [ "$waited" -ge 300 ]; then pass; else fail "pause timeout releases the held write" "+OK after >= 300 ms" "$got after $waited ms"; fi
expect "client pause all with timeout" "OK" client pause 600 all
start="${EPOCHREALTIME/./}"
printf 'GET pausekey\r\n' >&"$held"
got="$(raw_line "$held" 3)"$'\n'"$(raw_line "$held" 1)"
waited="$(elapsed_ms "$start")"
if [ "$got" == $'$2\nv2' ] && [ "$waited" -ge 300 ]; then pass; else fail "pause all holds reads until the timeout" "v2 after >= 300 ms" "$got after $waited ms"; fi
exec {held}>&-

expect "config get save" $'save\n3600 1 300 100 60 10000' config get save
expect "config get appendonly" $'appendonly\nno' config get appendonly
expect "config get maxmemory" $'maxmemory\n0' config get maxmemory
expect "config get unknown" "" config get nonexistentparam
expect "config get arity" $'ERR wrong number of arguments for \'config|get\' command' config get
expect "config set" "OK" config set maxmemory 100mb
expect "config get maxmemory after set" $'maxmemory\n104857600' config get maxmemory
expect "config set maxmemory back to 0" "OK" config set maxmemory 0
expect "config resetstat" "OK" config resetstat

info="$(cli info | tr -d '\r')"
for field in redis_version:7.4.11 eski_version:0.1.0 redis_mode:standalone os:Linux arch_bits:64 process_id: tcp_port:$PORT uptime_in_seconds: connected_clients: used_memory: used_memory_human: used_memory_rss: used_memory_rss_human: total_connections_received: total_commands_processed: instantaneous_ops_per_sec: expired_keys: keyspace_hits: keyspace_misses:; do
	if printf '%s\n' "$info" | grep -q "^$field"; then pass; else fail "info has $field" "$field" "missing"; fi
done
if printf '%s\n' "$info" | grep -q '^db0:keys=1,expires=0,avg_ttl=0,subexpiry=0$'; then pass; else fail "info keyspace line" "db0:keys=1,expires=0,avg_ttl=0,subexpiry=0" "$(printf '%s\n' "$info" | grep db0)"; fi
expect "flushall for keyspace" "OK" flushall
if cli info keyspace | tr -d '\r' | grep -q '^db0:'; then fail "info keyspace empty" "no db0 line" "db0 present"; else pass; fi
expect_match "info section" '^# Memory' info memory
rss="$(info_field memory used_memory_rss)"
if [ -n "$rss" ] && [ "$rss" -gt 0 ]; then pass; else fail "used_memory_rss positive" ">0" "$rss"; fi

expect "debug sleep" "OK" debug sleep 0
expect_match "time" $'^[0-9]{10,}\n[0-9]+$' time
expect_match "lastsave" '^[0-9]{10,}$' lastsave
expect "save" "OK" save
expect "bgsave" "Background saving started" bgsave
expect "set for object" "OK" set objkey abcdef
expect "object encoding" "embstr" object encoding objkey
expect "object encoding missing" "" object encoding nope
expect_pipe "object encoding int embstr raw" $'OK\nint\nOK\nint\nOK\nembstr\nOK\nembstr\nOK\nembstr\nOK\nraw\nOK\n2\nraw\n13\nint\n0\n1\nint\nOK\n4\nraw\nOK\nraw' "$(cat <<'CMDS'
SET enc 12345
OBJECT ENCODING enc
SET enc -9223372036854775808
OBJECT ENCODING enc
SET enc 9223372036854775808
OBJECT ENCODING enc
SET enc 012
OBJECT ENCODING enc
SET enc aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OBJECT ENCODING enc
SET enc aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OBJECT ENCODING enc
SET enc 1
APPEND enc 2
OBJECT ENCODING enc
INCR enc
OBJECT ENCODING enc
DEL newenc
APPEND newenc 7
OBJECT ENCODING newenc
SET enc abc
APPEND enc d
OBJECT ENCODING enc
RENAME enc enc2
OBJECT ENCODING enc2
CMDS
)"
expect_match "memory usage" '^[0-9]+$' memory usage objkey
expect "memory usage missing" "" memory usage nope

proto_flags() {
	printf '%s' "-$1"
}

proto_label() {
	if [ "$2" == "3" ]; then
		printf '%s (resp3)' "$1"
	else
		printf '%s' "$1"
	fi
}

expect_same() {
	local name="$1" proto got want
	shift
	for proto in 2 3; do
		got="$(cli "$(proto_flags "$proto")" --no-raw "$@")"
		want="$(ref_cli "$(proto_flags "$proto")" --no-raw "$@")"
		if [ -n "$want" ] && [ "$got" == "$want" ]; then
			pass
		else
			fail "$(proto_label "$name" "$proto") (eski ${#got} bytes, redis ${#want} bytes)" "${want:0:160}" "${got:0:160}"
		fi
	done
}

expect_same_pipe_proto() {
	local name="$1" feed="$2" proto="$3" got want line
	got="$(printf '%s\n' "$feed" | docker exec -i "$CLI_CONTAINER" redis-cli "$(proto_flags "$proto")" --no-raw -p "$PORT" 2>&1 | mask_tree_nodes)"
	want="$(printf '%s\n' "$feed" | docker exec -i "$CLI_CONTAINER" redis-cli "$(proto_flags "$proto")" --no-raw -p "$REF_PORT" 2>&1 | mask_tree_nodes)"
	if [ -n "$want" ] && [ "$got" == "$want" ]; then
		pass
		return
	fi
	line="$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 6 | tr '\n' ' ')"
	fail "$(proto_label "$name" "$proto") differs from redis: $line" "${want:0:160}" "${got:0:160}"
}

mask_tree_nodes() {
	awk '{ if ($0 ~ /"radix-tree-nodes" =>/ || prev ~ /"radix-tree-nodes"$/) { sub(/[0-9]+$/, "N") } prev = $0; print }'
}

expect_same_pipe() {
	expect_same_pipe_proto "$1" "$2" 2
	expect_same_pipe_proto "$1" "$2" 3
}

segment_sort() {
	awk -v cmd="LC_ALL=C sort" '$0 == "---" { close(cmd); print "---"; fflush(); next } { print | cmd } END { close(cmd) }'
}

expect_same_sorted_pipe() {
	local name="$1" feed="$2" proto got want line
	for proto in 2 3; do
		got="$(printf '%s\n' "$feed" | docker exec -i "$CLI_CONTAINER" redis-cli "$(proto_flags "$proto")" -p "$PORT" 2>&1 | segment_sort)"
		want="$(printf '%s\n' "$feed" | docker exec -i "$CLI_CONTAINER" redis-cli "$(proto_flags "$proto")" -p "$REF_PORT" 2>&1 | segment_sort)"
		if [ -n "$want" ] && [ "$got" == "$want" ]; then
			pass
		else
			line="$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 6 | tr '\n' ' ')"
			fail "$(proto_label "$name" "$proto") differs from redis: $line" "${want:0:160}" "${got:0:160}"
		fi
	done
}

raw_resp3() {
	local port="$1" feed="$2" fd out
	exec {fd}<>"/dev/tcp/127.0.0.1/$port"
	printf 'HELLO 3\r\n%s' "$feed" >&"$fd"
	out="$(raw_collect "$fd" 0.5)"
	exec {fd}>&-
	printf '%s' "$out" | tail -n +27
}

expect_same_raw3() {
	local name="$1" feed got want line
	feed="$(printf '%s\r\n' "${@:2}")"
	got="$(raw_resp3 "$PORT" "$feed")"
	want="$(raw_resp3 "$REF_PORT" "$feed")"
	if [ -n "$want" ] && [ "$got" == "$want" ]; then
		pass
		return
	fi
	line="$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 6 | tr '\n' ' ')"
	fail "$name bytes differ from redis under resp3: $line" "${want:0:160}" "${got:0:160}"
}

raw_resp2() {
	local port="$1" feed="$2" fd out
	exec {fd}<>"/dev/tcp/127.0.0.1/$port"
	printf '%s' "$feed" >&"$fd"
	out="$(raw_collect "$fd" 0.5)"
	exec {fd}>&-
	printf '%s' "$out"
}

resp_shape() {
	awk '/^:/ { print ":integer"; next } /^,/ { print ",double"; next } /^\$[0-9]+$/ { len = $0; if ((getline v) > 0 && v ~ /^-?[0-9]/) { print "$number" } else { print len; print v }; next } { print }'
}

expect_same_raw_proto() {
	local name="$1" proto="$2" filter="$3" feed got want line
	printf -v feed '%s\r\n' "${@:4}"
	got="$("raw_resp$proto" "$PORT" "$feed" | "$filter")"
	want="$("raw_resp$proto" "$REF_PORT" "$feed" | "$filter")"
	if [ -n "$want" ] && [ "$got" == "$want" ]; then
		pass
		return
	fi
	line="$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 6 | tr '\n' ' ')"
	fail "$(proto_label "$name" "$proto") bytes differ from redis: $line" "${want:0:160}" "${got:0:160}"
}

expect_same_raw() {
	expect_same_raw_proto "$1" 2 cat "${@:2}"
	expect_same_raw_proto "$1" 3 cat "${@:2}"
}

expect_same_raw_shape() {
	expect_same_raw_proto "$1" 2 resp_shape "${@:2}"
	expect_same_raw_proto "$1" 3 resp_shape "${@:2}"
}

string_float_values() {
	local v
	for v in 1 0.25 1.5 -1.1 17179869184 0.1 0.2 0.3 -0.1 1e-7 1e21 1e20 1e-17 5e-18 1.5e-17 2.5e-17 -1e-18 \
		0.024390243902439025 -0.024390243902439025 3.14159265358979323846 123456789012345678901234567890 \
		-9223372036854775808 9223372036854775807 -1.7976931348623157e308 1e300 -1e-300 0.12345678901234567 \
		1.2345678901234567 12345678901234567 9.9999999999999999 0.999999999999999995 0x10 0x1p-3 0X1.8P1 \
		0x1p-16445 1e-4940 1.8e-4951 1.9e-4951 1.18973149535723176502e+4932 .5 5. 1e+2 -0 +1 0e100000 \
		inf -inf +inf infinity nan 1e5000 1e-5000 1e 0x '" 1.5"' '"1.5 "' abc '""'; do
		printf 'DEL str:f\nINCRBYFLOAT str:f %s\nGET str:f\nSET str:g 10.5\nINCRBYFLOAT str:g %s\n' "$v" "$v"
	done
	printf 'DEL str:acc\n'
	for v in $(seq 1 40); do
		printf 'INCRBYFLOAT str:acc 0.1\nINCRBYFLOAT str:acc2 -1.1\nINCRBYFLOAT str:acc3 3.3333333333333333\n'
	done
}

hll_elements() {
	local key="$1" prefix="$2" count="$3" per_line=250 i j line
	for ((i = 1; i <= count; i += per_line)); do
		line="PFADD $key"
		for ((j = i; j < i + per_line && j <= count; j++)); do
			line+=" $prefix$j"
		done
		printf '%s\n' "$line"
	done
}

PARSER_CASES_PY="$(cat <<'PY'
import concurrent.futures
import socket
import sys
import threading

BIG = 70000
WAIT = 0.5
MSET = b"*201\r\n$4\r\nMSET\r\n" + b"".join(b"$9\r\nparser:k%d\r\n$1\r\nv\r\n" % (i % 10) for i in range(100))

CASES = [
    ("multibulk ping", [b"*1\r\n$4\r\nPING\r\n"]),
    ("count with a leading zero", [b"*01\r\n$4\r\nPING\r\n"]),
    ("count of two zeros", [b"*00\r\nPING\r\n"]),
    ("count of zero then ping", [b"*0\r\n*1\r\n$4\r\nPING\r\n"]),
    ("count of minus one then ping", [b"*-1\r\n*1\r\n$4\r\nPING\r\n"]),
    ("count of minus zero", [b"*-0\r\nPING\r\n"]),
    ("count with a plus sign", [b"*+1\r\n$4\r\nPING\r\n"]),
    ("empty count", [b"*\r\nPING\r\n"]),
    ("count of a lone minus", [b"*-\r\nPING\r\n"]),
    ("negative count with a leading zero", [b"*-01\r\nPING\r\n"]),
    ("negative count below minus one million", [b"*-1048577\r\nPING\r\n"]),
    ("negative count of eleven digits", [b"*-99999999999\r\nPING\r\n"]),
    ("count at the smallest long long", [b"*-9223372036854775808\r\nPING\r\n"]),
    ("count below the smallest long long", [b"*-9223372036854775809\r\nPING\r\n"]),
    ("count at int max waits", [b"*2147483647\r\n$4\r\nPING\r\n"]),
    ("count above int max", [b"*2147483648\r\nPING\r\n"]),
    ("count above one million waits", [b"*1048577\r\n$4\r\nPING\r\n"]),
    ("count of ten digits waits", [b"*1000000000\r\n"]),
    ("count of eleven digits", [b"*12345678901\r\nPING\r\n"]),
    ("count overflowing long long", [b"*99999999999999999999\r\nPING\r\n"]),
    ("count with trailing junk", [b"*1x\r\nPING\r\n"]),
    ("count with a trailing space", [b"*1 \r\nPING\r\n"]),
    ("count ended by a lone carriage return", [b"*1\rX$4\r\nPING\r\n"]),
    ("count with a carriage return as the last byte waits", [b"*1\r"]),
    ("count carriage return split across writes", [b"*1\r", b"X$4\r\nPING\r\n"]),
    ("count followed by two carriage returns", [b"*1\r\r\n$4\r\nPING\r\n"]),
    ("count with a nul byte waits", [b"*1\x00\r\n$4\r\nPING\r\n"]),
    ("count ended by a line feed only", [b"*1\n$4\r\nPING\r\n"]),
    ("count with a line feed and no carriage return waits", [b"*1\n"]),
    ("count without a line end waits", [b"*1"]),
    ("count line too big", [b"*" + b"1" * BIG]),
    ("count line with a nul byte too big", [b"*1\x00" + b"\r\n" * 35000]),
    ("bad count then lone carriage return", [b"*1x\rX$4\r\nPING\r\n"]),
    ("bulk length with a leading zero", [b"*1\r\n$04\r\nPING\r\n"]),
    ("bulk length of two zeros", [b"*1\r\n$00\r\n\r\n"]),
    ("bulk length of zero", [b"*1\r\n$0\r\n\r\n"]),
    ("set an empty value", [b"*3\r\n$3\r\nSET\r\n$12\r\nparser:empty\r\n$0\r\n\r\n*2\r\n$6\r\nSTRLEN\r\n$12\r\nparser:empty\r\n"]),
    ("bulk length of minus one", [b"*1\r\n$-1\r\nPING\r\n"]),
    ("negative bulk length on the second argument", [b"*2\r\n$4\r\nECHO\r\n$-10\r\n"]),
    ("bulk length with a plus sign", [b"*1\r\n$+4\r\nPING\r\n"]),
    ("empty bulk length", [b"*1\r\n$\r\nPING\r\n"]),
    ("bulk length of minus zero", [b"*1\r\n$-0\r\nPING\r\n"]),
    ("bulk length above the maximum", [b"*1\r\n$536870913\r\n"]),
    ("bulk length of ten digits", [b"*1\r\n$1000000000\r\n"]),
    ("bulk length of eleven digits", [b"*1\r\n$12345678901\r\n"]),
    ("bulk length with trailing junk", [b"*1\r\n$4x\r\nPING\r\n"]),
    ("bulk length ended by a lone carriage return", [b"*1\r\n$4\rXPING\r\n"]),
    ("empty bulk ended by a lone carriage return", [b"*2\r\n$4\r\nECHO\r\n$0\rXab"]),
    ("bulk data followed by two other bytes", [b"*1\r\n$4\r\nPINGXY"]),
    ("bulk data followed by a lone carriage return", [b"*1\r\n$4\r\nPING\rX*1\r\n$4\r\nPING\r\n"]),
    ("bulk data followed by two line feeds", [b"*1\r\n$4\r\nPING\n\n"]),
    ("bulk data missing one trailing byte waits", [b"*1\r\n$4\r\nPING\r"]),
    ("bulk length with a nul byte waits", [b"*1\r\n$4\x00\r\nPING\r\n"]),
    ("bulk length without a line end waits", [b"*1\r\n$4"]),
    ("bulk length line too big", [b"*1\r\n$" + b"1" * BIG]),
    ("bulk data with a nul byte", [b"*2\r\n$4\r\nECHO\r\n$3\r\na\x00b\r\n"]),
    ("bulk data split across writes", [b"*1\r\n$4\r\nPI", b"NG\r\n"]),
    ("many arguments in one write", [MSET + b"*2\r\n$4\r\nECHO\r\n$2\r\nok\r\n"]),
    ("many arguments split across writes", [MSET[:900], MSET[900:]]),
    ("int max count with a thousand arguments then junk", [b"*2147483647\r\n" + b"$1\r\nx\r\n" * 1000, b"X\r\n"]),
    ("wrong byte instead of a dollar waits for the line", [b"*1\r\nX"]),
    ("wrong byte and a carriage return waits", [b"*1\r\nX\r"]),
    ("wrong byte with a full line", [b"*1\r\nX\r\n"]),
    ("wrong byte ended by a lone carriage return", [b"*1\r\nX\rY"]),
    ("wrong byte with the line end in a second write", [b"*1\r\nX", b"\r\n"]),
    ("wrong byte sent one byte at a time", [bytes([b]) for b in b"*1\r\nX\rY"]),
    ("carriage return instead of a dollar", [b"*1\r\n\r\n"]),
    ("line feed instead of a dollar", [b"*1\r\n\n\r\n"]),
    ("wrong byte then a nul byte waits", [b"*1\r\nX\x00\r\n"]),
    ("colon instead of a dollar on the second argument", [b"*2\r\n$4\r\nECHO\r\n:1\r\n"]),
    ("inline text inside a multibulk", [b"*1\r\nPING\r\n"]),
    ("wrong byte on the third of a hundred arguments", [b"*100\r\n$1\r\na\r\n$1\r\nb\r\nX\r\n"]),
    ("wrong byte line too big", [b"*1\r\n" + b"X" * BIG]),
    ("high byte instead of a dollar", [b"*1\r\n\xff\r\n"]),
    ("ping then a waiting wrong byte", [b"PING\r\n*1\r\nX"]),
    ("inline ping", [b"PING\r\n"]),
    ("inline ping with a line feed only", [b"PING\n"]),
    ("inline nul byte before the line end waits", [b"PING\x00\r\n"]),
    ("inline leading nul byte waits", [b"\x00PING\r\n"]),
    ("inline nul byte after a command", [b"PING\r\n\x00"]),
    ("inline nul byte line too big", [b"PING\x00" + b"\r\n" * 35000]),
    ("inline line too big", [b"x" * BIG]),
    ("inline escaped newline", [b'ECHO "a\\nb"\r\n']),
    ("inline hex escapes", [b'ECHO "\\x41\\x42"\r\n']),
    ("inline hex escapes for nul and ff", [b'ECHO "\\x00\\xff"\r\n']),
    ("inline hex escapes in both cases", [b'ECHO "\\x4A\\x4a"\r\n']),
    ("inline invalid hex escape", [b'ECHO "\\xZZ"\r\n']),
    ("inline hex escape with a bad second digit", [b'ECHO "\\x4G"\r\n']),
    ("inline short hex escape", [b'ECHO "a\\x4"\r\n']),
    ("inline escaped backslash before x", [b'ECHO "\\\\x41"\r\n']),
    ("inline escaped double quote", [b'ECHO "a\\"b"\r\n']),
    ("inline other escapes", [b'ECHO "\\t\\r\\a\\b\\z\\\\"\r\n']),
    ("inline escaped single quote", [b"ECHO 'a\\'b'\r\n"]),
    ("inline backslash kept in single quotes", [b"ECHO 'a\\nb'\r\n"]),
    ("inline hex kept in single quotes", [b"ECHO '\\x41'\r\n"]),
    ("inline unbalanced double quote", [b'ECHO "abc\r\n']),
    ("inline unbalanced single quote", [b"ECHO 'abc\r\n"]),
    ("inline unterminated after a hex escape", [b'ECHO "\\x41\r\n']),
    ("inline closing quote followed by text", [b'ECHO "a"b\r\n']),
    ("inline closing quote followed by a single quote", [b"ECHO \"a\"'b'\r\n"]),
    ("inline text then a quoted part", [b'ECHO a"b c"\r\n']),
    ("inline text then a single quoted part", [b"ECHO a'b c'\r\n"]),
    ("inline text then a quoted hex escape", [b'ECHO a"\\x41"\r\n']),
    ("inline quote in the middle of an argument", [b"ECHO x'y'\r\n"]),
    ("inline empty quotes", [b'ECHO ""\r\n']),
    ("inline empty command and argument", [b'"" ""\r\n']),
    ("inline escaped quote at the end", [b'ECHO "a\\"\r\n']),
    ("inline backslash at the end", [b'ECHO "a\\\r\n']),
    ("inline closing quote then a vertical tab", [b'ECHO "a"\x0b\r\n']),
    ("inline closing quote then a form feed", [b'ECHO "a"\x0cPING\r\n']),
    ("inline leading vertical tab", [b"\x0bPING\r\n"]),
    ("inline trailing vertical tab", [b"PING\x0b\r\n"]),
    ("inline form feed inside an argument", [b"ECHO\x0ca\r\n"]),
    ("inline carriage return between arguments", [b"PING\rX\r\n"]),
    ("inline carriage return inside quotes", [b'ECHO "a\rb"\r\n']),
    ("inline carriage return after a closing quote", [b'ECHO "a"\rPING\r\n']),
    ("inline two carriage returns", [b"PING\r\r\n"]),
    ("inline carriage return only line", [b"\r\r\nPING\r\n"]),
    ("inline lone carriage return waits", [b"\r"]),
    ("inline empty line", [b"\r\nPING\r\n"]),
    ("inline line feed only line", [b"\nPING\r\n"]),
    ("inline blank line", [b"   \t\r\nPING\r\n"]),
    ("inline two quoted arguments", [b"ECHO \"a b\"  'c d'\r\n"]),
    ("inline quoted command", [b'"PING"\r\n']),
    ("inline tab separator", [b"ECHO\thello\r\n"]),
    ("inline quoted space", [b'ECHO " "\r\n']),
    ("inline high bytes", [b'ECHO "\xc3\xa9" \xff\r\n']),
    ("inline long line", [b"ECHO " + b"a" * BIG + b"\r\n"]),
    ("inline long quoted line", [b'ECHO "' + b"a" * BIG + b'"\r\n']),
    ("inline pipeline then a bad count", [b"PING\r\nPING\r\n*01\r\n"]),
]


def run(port, chunks):
    out = []
    state = "open"
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    except OSError as exc:
        return "connect failed: %s" % exc
    with sock:
        for chunk in chunks:
            if state != "open":
                out.append(None)
                continue
            try:
                sock.sendall(chunk)
            except OSError:
                state = "closed"
                out.append(None)
                continue
            data = b""
            sock.settimeout(WAIT)
            while True:
                try:
                    got = sock.recv(1 << 20)
                except socket.timeout:
                    break
                except OSError:
                    state = "closed"
                    break
                if not got:
                    state = "closed"
                    break
                data += got
            out.append(data)
    return "%s %r" % (state, out)


def compare(case):
    name, chunks = case
    res = {}
    threads = [threading.Thread(target=lambda p=p: res.__setitem__(p, run(p, chunks))) for p in PORTS]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return name, res[PORTS[0]], res[PORTS[1]]


def short(s):
    return s if len(s) <= 200 else s[:200] + "...(%d chars)" % len(s)


PORTS = (int(sys.argv[1]), int(sys.argv[2]))
with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
    for name, mine, ref in pool.map(compare, CASES):
        status = "same" if mine == ref and not ref.startswith("connect failed") else "differs"
        print("%s\t%s\t%s\t%s" % (status, name, short(ref), short(mine)))
PY
)"

BLOCKING_CASES_PY="$(cat <<'PY'
import socket
import sys
import threading
import time

TOL = 0.1


def enc(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        a = a if isinstance(a, bytes) else str(a).encode()
        out += b"$%d\r\n" % len(a) + a + b"\r\n"
    return out


class Conn:
    def __init__(self, port):
        self.port = port
        self.sock = socket.create_connection(("127.0.0.1", port))
        self.buf = b""

    def send(self, *args):
        self.sock.sendall(enc(*args))

    def raw(self, data):
        self.sock.sendall(data)

    def parse(self, i):
        j = self.buf.find(b"\r\n", i)
        if j < 0:
            return None
        head = self.buf[i:j]
        kind = head[:1]
        if kind == b"$":
            n = int(head[1:])
            if n < 0:
                return j + 2
            if len(self.buf) < j + 4 + n:
                return None
            return j + 4 + n
        if kind in (b"*", b"%", b"~", b">"):
            n = int(head[1:])
            if n < 0:
                return j + 2
            if kind == b"%":
                n *= 2
            p = j + 2
            for _ in range(n):
                p = self.parse(p)
                if p is None:
                    return None
            return p
        return j + 2

    def read(self, limit=3.0):
        start = time.time()
        self.sock.settimeout(limit)
        while True:
            end = self.parse(0)
            if end is not None:
                out = self.buf[:end]
                self.buf = self.buf[end:]
                return out, time.time() - start
            try:
                got = self.sock.recv(65536)
            except socket.timeout:
                return b"<no reply>", time.time() - start
            if not got:
                return b"<closed>", time.time() - start
            self.buf += got

    def call(self, *args):
        self.send(*args)
        return self.read()[0]

    def close(self):
        self.sock.close()


def info_field(c, name):
    data = c.call("INFO", "clients").decode()
    for line in data.split("\r\n"):
        if line.startswith(name + ":"):
            return int(line.split(":")[1])
    return -1


def wait_blocked(c, n):
    for _ in range(300):
        if info_field(c, "blocked_clients") == n:
            return True
        time.sleep(0.01)
    return False


def case_served_by_push(port):
    out = []
    a, b = Conn(port), Conn(port)
    a.call("FLUSHALL")
    b.send("BLPOP", "bk:q", "0")
    out.append(("blocked", wait_blocked(a, 1), None))
    out.append(("blocking keys", info_field(a, "total_blocking_keys"), None))
    out.append(("rpush", a.call("RPUSH", "bk:q", "x", "y"), None))
    out.append(("served", b.read()[0], None))
    out.append(("rest", a.call("LRANGE", "bk:q", "0", "-1"), None))
    out.append(("after", info_field(a, "blocked_clients"), None))
    a.close(); b.close()
    return out


def case_timeouts(port):
    out = []
    a, b, c = Conn(port), Conn(port), Conn(port)
    b.send("BRPOP", "bk:n1", "bk:n2", "0.3")
    v, t = b.read()
    out.append(("brpop timeout", v, (t, 0.3)))
    b.send("BRPOPLPUSH", "bk:n1", "bk:n2", "0.2")
    v, t = b.read()
    out.append(("brpoplpush timeout", v, (t, 0.2)))
    c.call("HELLO", "3")
    c.send("BLMPOP", "0.2", "2", "bk:n1", "bk:n2", "LEFT", "COUNT", "2")
    v, t = c.read()
    out.append(("blmpop timeout resp3", v, (t, 0.2)))
    b.send("BLPOP", "bk:n1", "0.001")
    v, t = b.read()
    out.append(("tiny timeout", v, (t, 0.001)))
    b.send("BLMOVE", "bk:n1", "bk:n2", "LEFT", "RIGHT", "0.25")
    v, t = b.read()
    out.append(("blmove timeout", v, (t, 0.25)))
    out.append(("none left", info_field(a, "blocked_clients"), None))
    a.close(); b.close(); c.close()
    return out


def case_chained(port):
    out = []
    a, b, c = Conn(port), Conn(port), Conn(port)
    a.call("FLUSHALL")
    b.send("BLMOVE", "bk:src", "bk:dst", "LEFT", "RIGHT", "0")
    wait_blocked(a, 1)
    c.send("BLPOP", "bk:dst", "0")
    wait_blocked(a, 2)
    out.append(("push src", a.call("RPUSH", "bk:src", "foo"), None))
    out.append(("blmove served", b.read()[0], None))
    out.append(("blpop served", c.read()[0], None))
    out.append(("dst gone", a.call("EXISTS", "bk:dst", "bk:src"), None))
    b.send("BRPOPLPUSH", "bk:l1", "bk:l2", "0")
    wait_blocked(a, 1)
    c.send("BRPOPLPUSH", "bk:l2", "bk:l1", "0")
    wait_blocked(a, 2)
    a.call("RPUSH", "bk:l1", "circ")
    out.append(("circular 1", b.read()[0], None))
    out.append(("circular 2", c.read()[0], None))
    out.append(("circular l1", a.call("LRANGE", "bk:l1", "0", "-1"), None))
    out.append(("circular l2", a.call("LRANGE", "bk:l2", "0", "-1"), None))
    a.close(); b.close(); c.close()
    return out


def case_unblock(port):
    out = []
    a, b = Conn(port), Conn(port)
    a.call("FLUSHALL")
    bid = b.call("CLIENT", "ID")[1:-2]
    b.send("BLPOP", "bk:u", "0")
    wait_blocked(a, 1)
    out.append(("list flags", b"flags=b" in a.call("CLIENT", "LIST", "ID", bid), None))
    out.append(("unblock", a.call("CLIENT", "UNBLOCK", bid), None))
    out.append(("unblocked reply", b.read()[0], None))
    b.send("BLMPOP", "0", "1", "bk:u", "RIGHT")
    wait_blocked(a, 1)
    out.append(("unblock error", a.call("CLIENT", "UNBLOCK", bid, "ERROR"), None))
    out.append(("error reply", b.read()[0], None))
    out.append(("not blocked", a.call("CLIENT", "UNBLOCK", bid, "TIMEOUT"), None))
    out.append(("bad id", a.call("CLIENT", "UNBLOCK", "abc"), None))
    out.append(("bad reason", a.call("CLIENT", "UNBLOCK", bid, "FOO"), None))
    b.send("BLPOP", "bk:u", "0")
    wait_blocked(a, 1)
    out.append(("kill", a.call("CLIENT", "KILL", "ID", bid), None))
    out.append(("after kill", info_field(a, "blocked_clients"), None))
    out.append(("keys after kill", info_field(a, "total_blocking_keys"), None))
    a.close(); b.close()
    return out


def case_pipeline(port):
    out = []
    a, b, c = Conn(port), Conn(port), Conn(port)
    a.call("FLUSHALL")
    b.raw(enc("BLPOP", "bk:p", "0") + enc("PING") + enc("LLEN", "bk:p"))
    wait_blocked(a, 1)
    out.append(("push", a.call("LPUSH", "bk:p", "1", "2", "3"), None))
    out.append(("first", b.read()[0], None))
    out.append(("second", b.read()[0], None))
    out.append(("third", b.read()[0], None))
    a.call("DEL", "bk:p")
    b.send("BLPOP", "bk:f", "0")
    wait_blocked(a, 1)
    c.raw(enc("LPUSH", "bk:f", "1") + enc("BLPOP", "bk:f", "0"))
    out.append(("fair first", b.read()[0], None))
    out.append(("fair push", c.read()[0], None))
    out.append(("fair blocked", wait_blocked(a, 1), None))
    a.call("LPUSH", "bk:f", "2")
    out.append(("fair second", c.read()[0], None))
    a.close(); b.close(); c.close()
    return out


def case_errors(port):
    out = []
    a = Conn(port)
    a.call("FLUSHALL")
    a.call("SET", "bk:s", "str")
    for args in [
        ("BLPOP", "bk:none", "bk:s", "1"),
        ("BLPOP", "bk:k", "-1"),
        ("BLPOP", "bk:k", "abc"),
        ("BLPOP", "bk:k", "0x7FFFFFFFFFFFFF"),
        ("BLPOP", "bk:k", "inf"),
        ("BLPOP", "bk:k", "-inf"),
        ("BLPOP", "bk:k", "nan"),
        ("BLPOP", "bk:k", " 1"),
        ("BRPOP", "bk:k"),
        ("BLMPOP", "0", "1", "bk:k", "MIDDLE"),
        ("BLMPOP", "abc", "0", "bk:k", "LEFT"),
        ("BLMPOP", "abc", "1", "bk:k", "LEFT"),
        ("BLMPOP", "0", "1", "bk:k", "LEFT", "COUNT", "0"),
        ("BLMPOP", "0", "2", "bk:k", "LEFT"),
        ("BLMOVE", "bk:a", "bk:b", "UP", "LEFT", "0"),
        ("BLMOVE", "bk:a", "bk:b", "LEFT", "LEFT", "-2"),
        ("BLMOVE", "bk:s", "bk:b", "LEFT", "LEFT", "0"),
        ("BRPOPLPUSH", "bk:a", "bk:b"),
        ("BRPOPLPUSH", "bk:s", "bk:b", "0"),
    ]:
        out.append((" ".join(args), a.call(*args), None))
    a.call("RPUSH", "bk:ready", "r1", "r2", "r3")
    out.append(("ready pop", a.call("BLPOP", "bk:none", "bk:ready", "0"), None))
    out.append(("ready mpop", a.call("BLMPOP", "0", "2", "bk:none", "bk:ready", "RIGHT", "COUNT", "5"), None))
    a.call("RPUSH", "bk:ready", "m1")
    out.append(("ready move", a.call("BRPOPLPUSH", "bk:ready", "bk:s", "0"), None))
    out.append(("ready move ok", a.call("BLMOVE", "bk:ready", "bk:ready2", "RIGHT", "LEFT", "0"), None))
    a.close()
    return out


def case_moved_into_place(port):
    out = []
    a, b = Conn(port), Conn(port)
    a.call("FLUSHALL")
    a.call("SET", "bk:dstr", "x")
    b.send("BRPOPLPUSH", "bk:srcx", "bk:dstr", "0")
    wait_blocked(a, 1)
    a.call("RPUSH", "bk:srcx", "e1")
    out.append(("wrong dest after wake", b.read()[0], None))
    out.append(("element kept", a.call("LRANGE", "bk:srcx", "0", "-1"), None))
    a.call("SELECT", "1"); a.call("RPUSH", "bk:sk", "hello"); a.call("SELECT", "0")
    b.send("BRPOP", "bk:sk", "5")
    wait_blocked(a, 1)
    out.append(("swapdb", a.call("SWAPDB", "0", "1"), None))
    out.append(("swapdb served", b.read()[0], None))
    a.call("SWAPDB", "0", "1")
    b.send("BLPOP", "bk:mv", "0")
    wait_blocked(a, 1)
    a.call("RPUSH", "bk:tmp", "m1", "m2"); a.call("RENAME", "bk:tmp", "bk:mv")
    out.append(("rename served", b.read()[0], None))
    b.send("BLPOP", "bk:mv2", "0")
    wait_blocked(a, 1)
    a.call("SELECT", "2"); a.call("RPUSH", "bk:mv2", "z"); a.call("MOVE", "bk:mv2", "0"); a.call("SELECT", "0")
    out.append(("move served", b.read()[0], None))
    b.send("BLPOP", "bk:cp", "0")
    wait_blocked(a, 1)
    a.call("COPY", "bk:mv", "bk:cp")
    out.append(("copy served", b.read()[0], None))
    b.send("BLPOP", "bk:srt", "0")
    wait_blocked(a, 1)
    a.call("RPUSH", "bk:uns", "c", "a", "b"); a.call("SORT", "bk:uns", "ALPHA", "STORE", "bk:srt")
    out.append(("sort store served", b.read()[0], None))
    b.send("BLPOP", "bk:fl", "0")
    wait_blocked(a, 1)
    a.call("FLUSHALL")
    out.append(("flushall keeps blocked", info_field(a, "blocked_clients"), None))
    a.call("SET", "bk:fl", "string")
    out.append(("string does not wake", info_field(a, "blocked_clients"), None))
    a.call("DEL", "bk:fl"); a.call("RPUSH", "bk:fl", "after")
    out.append(("list after flush served", b.read()[0], None))
    a.close(); b.close()
    return out


def case_pause(port):
    out = []
    a, b, c = Conn(port), Conn(port), Conn(port)
    a.call("FLUSHALL")
    bid = b.call("CLIENT", "ID")[1:-2]
    cid = c.call("CLIENT", "ID")[1:-2]
    a.call("CLIENT", "PAUSE", "100000", "WRITE")
    b.send("BLPOP", "bk:pz", "0")
    c.send("BLPOP", "bk:pz", "0")
    out.append(("paused count", wait_blocked(a, 2), None))
    out.append(("unblock paused", a.call("CLIENT", "UNBLOCK", bid, "TIMEOUT"), None))
    out.append(("unblock paused error", a.call("CLIENT", "UNBLOCK", cid, "ERROR"), None))
    a.call("CLIENT", "UNPAUSE")
    time.sleep(0.05)
    out.append(("unblock after unpause", a.call("CLIENT", "UNBLOCK", bid, "TIMEOUT"), None))
    out.append(("unblock error after unpause", a.call("CLIENT", "UNBLOCK", cid, "ERROR"), None))
    out.append(("timeout reply", b.read()[0], None))
    out.append(("error reply", c.read()[0], None))
    a.call("CLIENT", "PAUSE", "100000", "WRITE")
    b.send("BLPOP", "bk:pz", "0.3")
    wait_blocked(a, 1)
    time.sleep(0.2)
    a.call("CLIENT", "UNPAUSE")
    v, t = b.read()
    out.append(("timeout counts from unpause", v, (t, 0.3)))
    a.close(); b.close(); c.close()
    return out


def case_stream_reads(port):
    out = []
    a, b, c = Conn(port), Conn(port), Conn(port)
    a.call("FLUSHALL")
    a.call("XADD", "bs:s", "666", "f", "v")
    b.send("XREAD", "BLOCK", "0", "STREAMS", "bs:s", "$")
    out.append(("xread blocked", wait_blocked(a, 1), None))
    out.append(("del", a.call("DEL", "bs:s"), None))
    out.append(("recreate", a.call("XADD", "bs:s", "667", "f", "v"), None))
    out.append(("dollar kept across reprocessing", b.read()[0], None))
    a.call("DEL", "bs:s")
    a.call("XADD", "bs:s", "666", "f", "v")
    b.send("XREAD", "BLOCK", "0", "STREAMS", "bs:s", "$")
    wait_blocked(a, 1)
    a.call("SET", "bs:s", "x")
    out.append(("type change does not wake xread", info_field(a, "blocked_clients"), None))
    a.call("DEL", "bs:s")
    a.call("XADD", "bs:s", "667", "f", "v")
    out.append(("served after set del xadd", b.read()[0], None))
    a.call("DEL", "bs:x")
    b.send("XREAD", "BLOCK", "0", "STREAMS", "bs:x", "1-18446744073709551615")
    wait_blocked(a, 1)
    a.call("XADD", "bs:x", "1-1", "f", "v")
    a.call("XADD", "bs:x", "1-18446744073709551615", "f", "v")
    out.append(("still blocked below the id", info_field(a, "blocked_clients"), None))
    a.call("XADD", "bs:x", "2-1", "f", "v")
    out.append(("id edge", b.read()[0], None))
    c.call("HELLO", "3")
    c.send("XREAD", "COUNT", "5", "BLOCK", "0", "STREAMS", "bs:r3", "bs:none", "$", "$")
    wait_blocked(a, 1)
    a.call("XADD", "bs:r3", "1-1", "a", "b")
    out.append(("resp3 map", c.read()[0], None))
    c.send("XREAD", "BLOCK", "150", "STREAMS", "bs:r3", "$")
    v, t = c.read()
    out.append(("xread timeout resp3", v, (t, 0.15)))
    b.send("XREAD", "BLOCK", "120", "STREAMS", "bs:none", "+")
    v, t = b.read()
    out.append(("xread timeout plus", v, (t, 0.12)))
    b.send("XREAD", "BLOCK", "0", "STREAMS", "bs:r3", "bs:r3", "$", "$")
    wait_blocked(a, 1)
    a.call("XADD", "bs:r3", "2-1", "c", "d")
    out.append(("same stream twice", b.read()[0], None))
    b.send("XREAD", "BLOCK", "0", "STREAMS", "bs:l", "$")
    wait_blocked(a, 1)
    a.call("LPUSH", "bs:l", "x")
    out.append(("list does not wake xread", info_field(a, "blocked_clients"), None))
    a.call("DEL", "bs:l")
    a.call("XADD", "bs:l", "5-5", "k", "v")
    out.append(("served after list removed", b.read()[0], None))
    out.append(("none left", info_field(a, "blocked_clients"), None))
    a.close(); b.close(); c.close()
    return out


def case_stream_groups(port):
    out = []
    a, b, c = Conn(port), Conn(port), Conn(port)
    a.call("FLUSHALL")
    for op in (("DEL", "bs:g"), ("SET", "bs:g", "v1"), ("FLUSHALL",), ("XGROUP", "DESTROY", "bs:g", "grp"), ("RENAME", "bs:g", "bs:moved"), ("EXPIRE", "bs:g", "0")):
        a.call("DEL", "bs:g", "bs:moved")
        a.call("XADD", "bs:g", "666", "f", "v")
        a.call("XGROUP", "CREATE", "bs:g", "grp", "$")
        b.send("XREADGROUP", "GROUP", "grp", "Alice", "BLOCK", "0", "STREAMS", "bs:g", ">")
        out.append(("blocked " + op[0], wait_blocked(a, 1), None))
        out.append(("nokey keys " + op[0], info_field(a, "total_blocking_keys_on_nokey"), None))
        a.call(*op)
        out.append(("woken by " + op[0], b.read()[0], None))
    a.call("DEL", "bs:g")
    a.call("XGROUP", "CREATE", "bs:g", "grp", "$", "MKSTREAM")
    b.send("XREADGROUP", "GROUP", "grp", "Alice", "BLOCK", "0", "STREAMS", "bs:g", ">")
    c.send("XREADGROUP", "GROUP", "grp", "Bob", "COUNT", "10", "BLOCK", "400", "STREAMS", "bs:g", ">")
    out.append(("two consumers blocked", wait_blocked(a, 2), None))
    out.append(("xadd", a.call("XADD", "bs:g", "5-0", "k", "v"), None))
    out.append(("first consumer served", b.read()[0], None))
    v, t = c.read()
    out.append(("second times out on its first deadline", v, (t, 0.4)))
    out.append(("pending", a.call("XPENDING", "bs:g", "grp"), None))
    a.call("DEL", "bs:g{t}", "bs:g2{t}")
    a.call("XGROUP", "CREATE", "bs:g{t}", "grp", "$", "MKSTREAM")
    b.send("XREADGROUP", "GROUP", "grp", "Alice", "BLOCK", "0", "STREAMS", "bs:g{t}", ">")
    wait_blocked(a, 1)
    a.call("XGROUP", "CREATE", "bs:g2{t}", "grp", "$", "MKSTREAM")
    a.call("XADD", "bs:g2{t}", "100", "f1", "v1")
    a.call("RENAME", "bs:g2{t}", "bs:g{t}")
    out.append(("rename with the group serves", b.read()[0], None))
    a.call("DEL", "bs:g")
    a.call("XGROUP", "CREATE", "bs:g", "grp", "$", "MKSTREAM")
    a.call("XADD", "bs:g", "666", "key", "value")
    a.call("XDEL", "bs:g", "666")
    b.send("XREADGROUP", "GROUP", "grp", "c1", "BLOCK", "100", "STREAMS", "bs:g", ">")
    v, t = b.read()
    out.append(("ran dry times out", v, (t, 0.1)))
    for i in ("0", "600", "700"):
        out.append(("history ignores block " + i, b.call("XREADGROUP", "GROUP", "grp", "c1", "BLOCK", "0", "STREAMS", "bs:g", i), None))
    b.send("XREADGROUP", "GROUP", "grp", "c1", "BLOCK", "0", "NOACK", "STREAMS", "bs:g", ">")
    wait_blocked(a, 1)
    a.call("XADD", "bs:g", "667", "key", "value")
    out.append(("noack served", b.read()[0], None))
    out.append(("noack pending", a.call("XPENDING", "bs:g", "grp"), None))
    a.call("DEL", "bs:q")
    b.send("BLPOP", "bs:q", "0")
    wait_blocked(a, 1)
    a.call("XADD", "bs:q", "666", "key", "value")
    a.call("XGROUP", "CREATE", "bs:q", "grp", "$")
    c.send("XREADGROUP", "GROUP", "grp", "c", "BLOCK", "0", "STREAMS", "bs:q", ">")
    wait_blocked(a, 2)
    out.append(("keys", info_field(a, "total_blocking_keys"), None))
    out.append(("keys on nokey", info_field(a, "total_blocking_keys_on_nokey"), None))
    a.call("DEL", "bs:q")
    out.append(("group reader woken", c.read()[0], None))
    out.append(("keys on nokey after", info_field(a, "total_blocking_keys_on_nokey"), None))
    b.close()
    wait_blocked(a, 0)
    out.append(("keys after close", info_field(a, "total_blocking_keys"), None))
    c.call("HELLO", "3")
    a.call("DEL", "bs:h")
    a.call("XGROUP", "CREATE", "bs:h", "grp", "$", "MKSTREAM")
    c.send("XREADGROUP", "GROUP", "grp", "c", "BLOCK", "0", "STREAMS", "bs:h", ">")
    wait_blocked(a, 1)
    a.call("XADD", "bs:h", "1-1", "a", "b")
    out.append(("group resp3 map", c.read()[0], None))
    c.send("XREADGROUP", "GROUP", "grp", "c", "BLOCK", "100", "STREAMS", "bs:h", ">")
    v, t = c.read()
    out.append(("group timeout resp3", v, (t, 0.1)))
    a.close(); c.close()
    return out


CASES = [
    ("blocking pop served by a push", case_served_by_push),
    ("blocking timeouts", case_timeouts),
    ("chained and circular moves", case_chained),
    ("client unblock and kill", case_unblock),
    ("pipelined input and fairness", case_pipeline),
    ("blocking argument errors and ready keys", case_errors),
    ("keys moved into place wake clients", case_moved_into_place),
    ("pause and unblock", case_pause),
    ("blocking stream reads", case_stream_reads),
    ("blocking stream group reads", case_stream_groups),
]


def show(items):
    parts = []
    for label, value, t in items:
        if isinstance(value, bytes):
            value = value.decode("latin-1")
        s = "%s=%r" % (label, value)
        if t is not None:
            s += "@%.3fs" % t[0]
        parts.append(s)
    return " ".join(parts)


def run_case(fn):
    res = {}
    threads = [threading.Thread(target=lambda p=p: res.__setitem__(p, fn(p))) for p in PORTS]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return res[PORTS[0]], res[PORTS[1]]


PORTS = (int(sys.argv[1]), int(sys.argv[2]))
for name, fn in CASES:
    try:
        mine, ref = run_case(fn)
    except Exception as e:
        print("differs\t%s\t%s\t%s" % (name, "exception", repr(e)))
        continue
    same = len(mine) == len(ref)
    for m, r in zip(mine, ref):
        if m[0] != r[0] or m[1] != r[1]:
            same = False
        if m[2] is not None:
            want = m[2][1]
            if not (want - 0.005 <= m[2][0] <= want + TOL and want - 0.005 <= r[2][0] <= want + 2 * TOL):
                same = False
    print("%s\t%s\t%s\t%s" % ("same" if same else "differs", name, show(ref)[:600], show(mine)[:600]))
PY
)"

BLOCKING_STRESS_PY="$(cat <<'PY'
import socket
import sys
import threading
import time

PORT = int(sys.argv[1])
CONSUMERS = 50
PRODUCERS = 4
PER_PRODUCER = 5000


def enc(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        a = a if isinstance(a, bytes) else str(a).encode()
        out += b"$%d\r\n" % len(a) + a + b"\r\n"
    return out


class Reader:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def fill(self):
        got = self.sock.recv(65536)
        if not got:
            raise EOFError("closed")
        self.buf += got

    def line(self):
        while b"\r\n" not in self.buf:
            self.fill()
        i = self.buf.index(b"\r\n")
        out = self.buf[:i]
        self.buf = self.buf[i + 2:]
        return out

    def reply(self):
        head = self.line()
        if head[:1] == b"$":
            n = int(head[1:])
            if n < 0:
                return None
            while len(self.buf) < n + 2:
                self.fill()
            out = self.buf[:n]
            self.buf = self.buf[n + 2:]
            return out
        if head[:1] == b"*":
            n = int(head[1:])
            if n < 0:
                return None
            return [self.reply() for _ in range(n)]
        if head[:1] == b"-":
            raise RuntimeError(head.decode())
        return head


received = [[] for _ in range(CONSUMERS)]
stop = threading.Event()
errors = []


def consumer(i):
    sock = socket.create_connection(("127.0.0.1", PORT))
    r = Reader(sock)
    mode = i % 3
    try:
        while True:
            if mode == 0:
                sock.sendall(enc("BLPOP", "stress:q", "0.3"))
            elif mode == 1:
                sock.sendall(enc("BLMPOP", "0.3", "1", "stress:q", "LEFT", "COUNT", "3"))
            else:
                sock.sendall(enc("BLMOVE", "stress:q", "stress:out%d" % i, "LEFT", "RIGHT", "0.3"))
            v = r.reply()
            if v is None:
                if stop.is_set():
                    break
                continue
            if mode == 0:
                received[i].append(v[1])
            elif mode == 1:
                received[i].extend(v[1])
            else:
                received[i].append(v)
    except Exception as e:
        errors.append(repr(e))
    sock.close()


def producer(p):
    sock = socket.create_connection(("127.0.0.1", PORT))
    r = Reader(sock)
    n = 0
    while n < PER_PRODUCER:
        k = min(1 + (n % 7), PER_PRODUCER - n)
        sock.sendall(enc("RPUSH", "stress:q", *[b"p%d:%d" % (p, n + j) for j in range(k)]))
        r.reply()
        n += k
        if n % 500 < 7:
            time.sleep(0.002)
    sock.close()


admin = socket.create_connection(("127.0.0.1", PORT))
ar = Reader(admin)
admin.sendall(enc("DEL", "stress:q"))
ar.reply()
consumers = [threading.Thread(target=consumer, args=(i,)) for i in range(CONSUMERS)]
for t in consumers:
    t.start()
blocked = 0
for _ in range(300):
    admin.sendall(enc("INFO", "clients"))
    info = ar.reply()
    for line in info.split(b"\r\n"):
        if line.startswith(b"blocked_clients:"):
            blocked = int(line.split(b":")[1])
    if blocked >= CONSUMERS:
        break
    time.sleep(0.01)
producers = [threading.Thread(target=producer, args=(p,)) for p in range(PRODUCERS)]
for t in producers:
    t.start()
for t in producers:
    t.join()
total = PRODUCERS * PER_PRODUCER
deadline = time.time() + 30
while sum(len(x) for x in received) < total and time.time() < deadline:
    time.sleep(0.05)
stop.set()
for t in consumers:
    t.join()
values = [v for x in received for v in x]
dups = len(values) - len(set(values))
missing = total - len(set(values))
in_order = True
for x in received:
    last = {}
    for v in x:
        p, n = v.split(b":")
        n = int(n)
        if n <= last.get(p, -1):
            in_order = False
        last[p] = n
admin.sendall(enc("EXISTS", "stress:q"))
left = ar.reply()
admin.sendall(enc("DEL", "stress:q", *["stress:out%d" % i for i in range(CONSUMERS)]))
ar.reply()
ok = blocked >= CONSUMERS and dups == 0 and missing == 0 and in_order and not errors and left == b":0"
print("%s blocked=%d elements=%d received=%d duplicates=%d missing=%d in_order=%s errors=%d" % ("ok" if ok else "bad", blocked, total, len(values), dups, missing, in_order, len(errors)))
PY
)"

STREAM_GROUP_STRESS_PY="$(cat <<'PY'
import socket
import sys
import threading
import time

PORT = int(sys.argv[1])
CONSUMERS = 40
PRODUCERS = 4
PER_PRODUCER = 3000


def enc(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        a = a if isinstance(a, bytes) else str(a).encode()
        out += b"$%d\r\n" % len(a) + a + b"\r\n"
    return out


class Reader:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def fill(self):
        got = self.sock.recv(65536)
        if not got:
            raise EOFError("closed")
        self.buf += got

    def line(self):
        while b"\r\n" not in self.buf:
            self.fill()
        i = self.buf.index(b"\r\n")
        out = self.buf[:i]
        self.buf = self.buf[i + 2:]
        return out

    def reply(self):
        head = self.line()
        if head[:1] == b"$":
            n = int(head[1:])
            if n < 0:
                return None
            while len(self.buf) < n + 2:
                self.fill()
            out = self.buf[:n]
            self.buf = self.buf[n + 2:]
            return out
        if head[:1] == b"*":
            n = int(head[1:])
            if n < 0:
                return None
            return [self.reply() for _ in range(n)]
        if head[:1] == b"-":
            raise RuntimeError(head.decode())
        return head


received = [[] for _ in range(CONSUMERS)]
stop = threading.Event()
errors = []


def consumer(i):
    sock = socket.create_connection(("127.0.0.1", PORT))
    r = Reader(sock)
    try:
        while True:
            if i % 2 == 0:
                sock.sendall(enc("XREADGROUP", "GROUP", "g", "c%d" % i, "COUNT", "3", "BLOCK", "300", "STREAMS", "gs:q", ">"))
            else:
                sock.sendall(enc("XREADGROUP", "GROUP", "g", "c%d" % i, "COUNT", "2", "NOACK", "BLOCK", "300", "STREAMS", "gs:q", ">"))
            v = r.reply()
            if v is None:
                if stop.is_set():
                    break
                continue
            for entry in v[0][1]:
                received[i].append(entry[1][1])
                if i % 2 == 0:
                    sock.sendall(enc("XACK", "gs:q", "g", entry[0]))
                    r.reply()
    except Exception as e:
        errors.append(repr(e))
    sock.close()


def producer(p):
    sock = socket.create_connection(("127.0.0.1", PORT))
    r = Reader(sock)
    for n in range(PER_PRODUCER):
        sock.sendall(enc("XADD", "gs:q", "*", "v", b"p%d:%d" % (p, n)))
        r.reply()
        if n % 400 == 0:
            time.sleep(0.002)
    sock.close()


admin = socket.create_connection(("127.0.0.1", PORT))
ar = Reader(admin)
admin.sendall(enc("DEL", "gs:q"))
ar.reply()
admin.sendall(enc("XGROUP", "CREATE", "gs:q", "g", "$", "MKSTREAM"))
ar.reply()
consumers = [threading.Thread(target=consumer, args=(i,)) for i in range(CONSUMERS)]
for t in consumers:
    t.start()
blocked = 0
for _ in range(300):
    admin.sendall(enc("INFO", "clients"))
    info = ar.reply()
    for line in info.split(b"\r\n"):
        if line.startswith(b"blocked_clients:"):
            blocked = int(line.split(b":")[1])
    if blocked >= CONSUMERS:
        break
    time.sleep(0.01)
producers = [threading.Thread(target=producer, args=(p,)) for p in range(PRODUCERS)]
t0 = time.time()
for t in producers:
    t.start()
for t in producers:
    t.join()
total = PRODUCERS * PER_PRODUCER
deadline = time.time() + 30
while sum(len(x) for x in received) < total and time.time() < deadline:
    time.sleep(0.05)
elapsed = time.time() - t0
stop.set()
for t in consumers:
    t.join()
values = [v for x in received for v in x]
dups = len(values) - len(set(values))
missing = total - len(set(values))
in_order = True
for x in received:
    last = {}
    for v in x:
        p, n = v.split(b":")
        n = int(n)
        if n <= last.get(p, -1):
            in_order = False
        last[p] = n
admin.sendall(enc("XPENDING", "gs:q", "g"))
pend = ar.reply()
admin.sendall(enc("XINFO", "GROUPS", "gs:q"))
groups = ar.reply()
admin.sendall(enc("DEL", "gs:q"))
ar.reply()
ok = blocked >= CONSUMERS and dups == 0 and missing == 0 and in_order and not errors and pend[0] == b":0"
print("%s blocked=%d entries=%d received=%d duplicates=%d missing=%d in_order=%s errors=%d pending=%s secs=%.2f group=%s" % ("ok" if ok else "bad", blocked, total, len(values), dups, missing, in_order, len(errors), pend[0], elapsed, groups[0][-5:]))
PY
)"

expect_same_blocking() {
	local status name want got n=0
	while IFS=$'\t' read -r status name want got; do
		n=$((n + 1))
		if [ "$status" == "same" ]; then
			pass
		else
			fail "blocking case '$name' differs from redis" "$want" "$got"
		fi
	done < <(python3 -I -c "$BLOCKING_CASES_PY" "$PORT" "$REF_PORT" 2>&1)
	if [ "$n" -lt 8 ]; then
		fail "blocking cases ran" "8 cases" "$n"
	fi
}

expect_blocking_stress() {
	local port got
	for port in "$PORT" "$REF_PORT"; do
		got="$(timeout 120 python3 -I -c "$BLOCKING_STRESS_PY" "$port" 2>&1)"
		if [[ "$got" == ok\ * ]]; then pass; else fail "fifty blocked clients on port $port receive every element once in order" "ok" "$got"; fi
	done
}

expect_stream_group_stress() {
	local port got
	for port in "$PORT" "$REF_PORT"; do
		got="$(timeout 120 python3 -I -c "$STREAM_GROUP_STRESS_PY" "$port" 2>&1)"
		if [[ "$got" == ok\ * ]]; then pass; else fail "forty blocked group consumers on port $port receive every entry once in order" "ok" "$got"; fi
	done
}

expect_same_parser() {
	local status name want got n=0
	while IFS=$'\t' read -r status name want got; do
		n=$((n + 1))
		if [ "$status" == "same" ]; then
			pass
		else
			fail "request parser case '$name' differs from redis" "$want" "$got"
		fi
	done < <(python3 -I -c "$PARSER_CASES_PY" "$PORT" "$REF_PORT" 2>&1)
	if [ "$n" -lt 100 ]; then
		fail "request parser cases ran" "at least 100 cases" "$n"
	fi
}

expect_same_dump() {
	local status name want got n=0
	while IFS=$'\t' read -r status name want got; do
		case "$status" in
		PASS)
			n=$((n + 1))
			pass
			;;
		FAIL)
			n=$((n + 1))
			fail "dump case '$name' differs from redis" "$want" "$got"
			;;
		SUMMARY)
			echo "dump and restore over RESP$1: $name"
			;;
		*)
			fail "dump comparison over RESP$1 printed an unexpected line" "PASS, FAIL or SUMMARY" "$status $name"
			;;
		esac
	done < <(timeout 300 python3 -I test/rdb/dumpcmp.py "$PORT" "$REF_PORT" "$1" 2>&1)
	if [ "$n" -lt 300 ]; then
		fail "dump and restore cases ran over RESP$1" "at least 300 cases" "$n"
	fi
}

expect_same_corrupt() {
	local suite status name want got n=0
	suite="$(ls -d test/conformance/.redis/redis-*/tests/integration 2>/dev/null | head -1)"
	if [ -z "$suite" ] || [ ! -f "$suite/corrupt-dump.tcl" ]; then
		echo "skipping the corrupt payload comparison, run test/conformance/run.sh once to download the suite"
		return
	fi
	suite="${suite%/tests/integration}"
	while IFS=$'\t' read -r status name want got; do
		case "$status" in
		PASS)
			n=$((n + 1))
			pass
			;;
		FAIL)
			n=$((n + 1))
			fail "corrupt payload case '$name' differs from redis" "$want" "$got"
			;;
		INFO | SUMMARY)
			echo "corrupt payloads: $name"
			;;
		*)
			fail "corrupt payload comparison printed an unexpected line" "PASS, FAIL, INFO or SUMMARY" "$status $name"
			;;
		esac
	done < <(timeout 600 python3 -I test/rdb/corruptcmp.py "$PORT" "$REF_PORT" "$suite" 5000 1 2>&1)
	if [ "$n" -lt 200 ]; then
		fail "corrupt payload cases ran" "at least 200 cases" "$n"
	fi
}

migrate_cached() {
	docker exec "$CLI_CONTAINER" redis-cli -p "$1" info stats 2>/dev/null | tr -d '\r' | sed -n 's/^migrate_cached_sockets://p'
}

wait_migrate_idle() {
	local i
	for i in $(seq 1 300); do
		if [ "$(migrate_cached "$1")" == "0" ]; then
			return 0
		fi
		sleep 0.1
	done
	return 1
}

compare_lines() {
	local label="$1" i
	local -a w g
	mapfile -t w <<<"$2"
	mapfile -t g <<<"$3"
	if [ "${#w[@]}" -lt 30 ]; then
		fail "$label ran" "at least 30 lines" "${#w[@]}: $2"
		return
	fi
	if [ "${#w[@]}" != "${#g[@]}" ]; then
		fail "$label line count" "${#w[@]}" "${#g[@]}"
	fi
	for i in "${!w[@]}"; do
		if [ "${w[$i]}" == "${g[$i]:-}" ]; then pass; else fail "$label: ${w[$i]%%$'\t'*}" "${w[$i]}" "${g[$i]:-}"; fi
	done
}

expect_same_migrate() {
	local mine theirs
	if wait_migrate_idle "$PORT"; then pass; else fail "eski has no cached migrate socket before the comparison" "0" "$(migrate_cached "$PORT")"; fi
	mine="$(timeout 120 python3 -I test/rdb/migratecmp.py "$PORT" "$REF_PORT" 2>&1)"
	theirs="$(timeout 120 python3 -I test/rdb/migratecmp.py "$REF_PORT" "$PORT" 2>&1)"
	MIGRATE_REF_OUTPUT="$theirs"
	compare_lines "migrate from eski into redis against redis into eski" "$theirs" "$mine"
}

PUBSUB_CASES_PY="$(cat <<'PY'
import socket
import sys
import time

SETTLE = 0.05
BIG = "x" * 20000


class Conn:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.s.setblocking(False)
        self.out = b""
        self.eof = False
        self.closed = False

    def drain(self):
        while not self.eof and not self.closed:
            try:
                data = self.s.recv(65536)
            except BlockingIOError:
                return
            except ConnectionResetError:
                data = b""
            if not data:
                self.eof = True
                self.out += b"<EOF>"
                return
            self.out += data

    def send(self, text):
        data = text.encode("latin1")
        while data:
            try:
                n = self.s.send(data)
                data = data[n:]
            except BlockingIOError:
                self.drain()
                time.sleep(0.001)

    def wait_for(self, marker):
        end = time.time() + 3
        while marker not in self.out and not self.eof and time.time() < end:
            self.drain()
            time.sleep(0.002)

    def bulk_int(self, text):
        start = len(self.out)
        self.send(text)
        end = time.time() + 3
        while time.time() < end:
            self.drain()
            buf = self.out[start:]
            nl = buf.find(b"\r\n")
            if nl > 0 and buf[:1] == b":":
                self.out = self.out[:start]
                return int(buf[1:nl])
            time.sleep(0.002)
        return -1

    def bulk(self, text):
        start = len(self.out)
        self.send(text)
        end = time.time() + 3
        while time.time() < end:
            self.drain()
            buf = self.out[start:]
            nl = buf.find(b"\r\n")
            if nl > 0 and buf[:1] in (b"$", b"="):
                n = int(buf[1:nl])
                if len(buf) >= nl + 4 + n:
                    self.out = self.out[:start]
                    return buf[nl + 2:nl + 2 + n].decode("latin1")
            time.sleep(0.002)
        return ""


def run(port, steps):
    conns = {}
    order = []
    notes = []
    ids = []
    for step in steps:
        op = step[0]
        if op == "open":
            conns[step[1]] = Conn(port)
            order.append(step[1])
        elif op == "hello3":
            c = conns[step[1]]
            c.send("HELLO 3\r\n")
            c.wait_for(b"$7\r\nmodules\r\n*0\r\n")
            c.out = b""
        elif op == "send":
            conns[step[1]].send(step[2])
        elif op == "close":
            conns[step[1]].s.close()
            conns[step[1]].closed = True
        elif op == "redir":
            ident = conns[step[2]].bulk_int("CLIENT ID\r\n")
            ids.append(ident)
            conns[step[1]].send("CLIENT TRACKING on REDIRECT %d%s\r\n" % (ident, step[3]))
        elif op == "sleep":
            time.sleep(step[1])
        elif op == "info":
            text = conns[step[1]].bulk("INFO " + step[2] + "\r\n")
            for line in text.split("\r\n"):
                if line.split(":")[0] in step[3]:
                    notes.append(line)
        elif op == "clients":
            text = conns[step[1]].bulk("CLIENT LIST TYPE " + step[2] + "\r\n")
            for line in text.splitlines():
                fields = dict(kv.split("=", 1) for kv in line.split(" ") if "=" in kv)
                notes.append(" ".join(k + "=" + fields.get(k, "?") for k in ("flags", "db", "sub", "psub", "ssub", "cmd", "resp")))
        time.sleep(SETTLE)
        for c in conns.values():
            c.drain()
    time.sleep(0.2)
    for c in conns.values():
        c.drain()
    for name in order:
        if not conns[name].closed:
            conns[name].s.close()
    for name in order:
        for ident in ids:
            conns[name].out = conns[name].out.replace(b":%d\r\n" % ident, b":ID\r\n")
    return " | ".join([name + "=" + repr(conns[name].out) for name in order] + notes)


def subscribe_mode(proto):
    if proto == 2:
        return [
            ("open", "s"),
            ("send", "s", "SUBSCRIBE a b\r\nPING\r\nPING x\r\nGET k\r\nSET k v\r\nCLIENT LIST\r\nCLIENT FOO\r\nCLIENT REPLY\r\nCONFIG GET\r\nCONFIG GET a\r\nCOMMAND\r\nCOMMAND FOO\r\nHELLO 3\r\nNOSUCH x\r\nGET\r\nPUBSUB NUMPAT\r\nPUBSUB FOO\r\nPUBLISH a b\r\nOBJECT ENCODING k\r\nMEMORY USAGE k\r\nFUNCTION LIST\r\nSELECT 1\r\n"),
            ("send", "s", "UNSUBSCRIBE a\r\nGET k\r\nPSUBSCRIBE p*\r\nUNSUBSCRIBE\r\nGET k\r\nSSUBSCRIBE s\r\nPUNSUBSCRIBE\r\nGET k\r\nSUNSUBSCRIBE\r\nGET k\r\nPING\r\nQUIT\r\n"),
        ]
    return [
        ("open", "s"),
        ("hello3", "s"),
        ("send", "s", "SUBSCRIBE a b\r\nPING\r\nPING x\r\nGET pubsub:k\r\nSET pubsub:k v\r\nGET pubsub:k\r\nCONFIG GET a\r\nPUBLISH a hi\r\nPUBLISH b there\r\nUNSUBSCRIBE a\r\nUNSUBSCRIBE\r\nPING\r\nDEL pubsub:k\r\nSUBSCRIBE c\r\nGET pubsub:k\r\nRESET\r\nGET pubsub:k\r\n"),
    ]


def delivery(proto):
    steps = [("open", "s")]
    if proto == 3:
        steps.append(("hello3", "s"))
    return steps + [
        ("open", "s2"),
        ("open", "p"),
        ("send", "s", "SUBSCRIBE news sports\r\nPSUBSCRIBE n* x?y\r\nSSUBSCRIBE shard1\r\n"),
        ("send", "s2", "SUBSCRIBE news\r\n"),
        ("send", "p", "PUBLISH news 1\r\nPUBLISH sports 2\r\nPUBLISH nope 3\r\nPUBLISH xay 4\r\nPUBLISH other 5\r\nSPUBLISH shard1 6\r\nSPUBLISH news 7\r\nPUBLISH shard1 8\r\n"),
        ("send", "p", "PUBLISH news " + BIG + "\r\nPUBLISH news \"\"\r\nPUBLISH \"\" empty\r\n"),
        ("send", "s", "UNSUBSCRIBE news\r\n"),
        ("send", "p", "PUBLISH news 9\r\nPUBLISH sports 10\r\n"),
    ]


def reply_off(proto):
    if proto == 3:
        return [
            ("open", "s"),
            ("hello3", "s"),
            ("open", "p"),
            ("send", "s", "CLIENT REPLY OFF\r\nSUBSCRIBE a\r\nPSUBSCRIBE a*\r\nGET k\r\nPUBLISH a self\r\nCLIENT REPLY SKIP\r\nPING\r\n"),
            ("send", "p", "PUBLISH a other\r\n"),
            ("send", "s", "CLIENT REPLY ON\r\nCLIENT REPLY SKIP\r\nPUBLISH a skipped\r\nPING\r\nUNSUBSCRIBE a\r\nPUNSUBSCRIBE a*\r\nPING\r\n"),
        ]
    return [
        ("open", "s"),
        ("open", "p"),
        ("send", "s", "CLIENT REPLY OFF\r\nSUBSCRIBE a\r\nPING\r\nGET k\r\nCLIENT REPLY ON\r\n"),
        ("send", "p", "PUBLISH a other\r\n"),
        ("send", "s", "UNSUBSCRIBE a\r\nCLIENT REPLY ON\r\nPING\r\nCLIENT REPLY SKIP\r\nSUBSCRIBE b\r\nPING\r\nUNSUBSCRIBE b\r\nPING\r\n"),
    ]


STATS = ("pubsub_channels", "pubsub_patterns", "pubsubshard_channels")


def introspection(proto):
    steps = [("open", "s")]
    if proto == 3:
        steps.append(("hello3", "s"))
    return steps + [
        ("open", "q"),
        ("send", "s", "SUBSCRIBE a\r\nPSUBSCRIBE p*\r\nSSUBSCRIBE s1\r\n"),
        ("send", "q", "PUBSUB NUMSUB a b\r\nPUBSUB NUMPAT\r\nPUBSUB CHANNELS\r\nPUBSUB CHANNELS a*\r\nPUBSUB CHANNELS z*\r\nPUBSUB SHARDCHANNELS\r\nPUBSUB SHARDCHANNELS s?\r\nPUBSUB SHARDNUMSUB s1 a\r\nPUBSUB NUMSUB\r\n"),
        ("info", "q", "clients", ("pubsub_clients",)),
        ("info", "q", "stats", STATS),
        ("clients", "q", "pubsub"),
        ("send", "s", "RESET\r\n"),
        ("send", "q", "PUBSUB NUMSUB a\r\nPUBSUB NUMPAT\r\nPUBSUB SHARDNUMSUB s1\r\n"),
        ("info", "q", "stats", STATS),
        ("clients", "q", "pubsub"),
        ("send", "s", "SUBSCRIBE a\r\n"),
        ("clients", "q", "pubsub"),
        ("send", "q", "CLIENT KILL TYPE pubsub\r\nPUBSUB NUMSUB a\r\n"),
        ("open", "t"),
        ("send", "t", "PSUBSCRIBE q*\r\nSSUBSCRIBE t1\r\n"),
        ("send", "q", "PUBSUB NUMPAT\r\nPUBSUB SHARDNUMSUB t1\r\n"),
        ("close", "t"),
        ("sleep", 0.1),
        ("send", "q", "PUBSUB NUMPAT\r\nPUBSUB SHARDNUMSUB t1\r\n"),
        ("info", "q", "clients", ("pubsub_clients",)),
        ("info", "q", "stats", STATS),
    ]


def hello(proto, name):
    return [("hello3", name)] if proto == 3 else []


def tracking_basic(proto):
    return [("open", "r"), ("open", "w")] + hello(proto, "r") + [
        ("send", "w", "FLUSHALL\r\n"),
        ("send", "r", "CLIENT TRACKING on\r\nCLIENT TRACKINGINFO\r\nCLIENT GETREDIR\r\nGET k1\r\nMGET k2 k3\r\nHGET h f\r\nEXISTS k4\r\nLRANGE l 0 -1\r\nZSCORE z m\r\n"),
        ("send", "w", "SET k1 1\r\nMSET k2 1 k3 1\r\nHSET h f v\r\nDEL k4\r\nSET k4 1\r\nRPUSH l a\r\nZADD z 1 m\r\n"),
        ("send", "r", "SET k1 self\r\nGET k1\r\nPING\r\n"),
        ("send", "r", "SET k1 again\r\nPING\r\nCLIENT TRACKING off\r\nCLIENT TRACKINGINFO\r\nCLIENT GETREDIR\r\n"),
        ("send", "w", "SET k2 2\r\nFLUSHALL\r\n"),
    ]


def tracking_redirect(proto):
    return [("open", "rd"), ("open", "r"), ("open", "w")] + hello(proto, "rd") + [
        ("send", "rd", "SUBSCRIBE __redis__:invalidate\r\n"),
        ("redir", "r", "rd", ""),
        ("send", "r", "GET a\r\nGET b\r\nCLIENT TRACKINGINFO\r\n"),
        ("send", "w", "SET a 1\r\nSET b 2\r\nSET a 3\r\n"),
        ("send", "r", "GET a\r\n"),
        ("send", "w", "FLUSHDB\r\n"),
        ("send", "r", "CLIENT TRACKING off\r\n"),
    ]


def tracking_bcast(proto):
    return [("open", "r"), ("open", "w"), ("open", "x")] + hello(proto, "r") + [
        ("send", "w", "FLUSHALL\r\n"),
        ("send", "r", "CLIENT TRACKING on BCAST PREFIX a: PREFIX b:\r\nCLIENT TRACKINGINFO\r\n"),
        ("send", "w", "MSET a:2 1 a:1 2 b:1 3 c:1 4\r\n"),
        ("send", "w", "SET a:3 1\r\nSET b:2 1\r\n"),
        ("send", "r", "CLIENT TRACKING on BCAST PREFIX c:\r\nCLIENT TRACKING on BCAST PREFIX a\r\nCLIENT TRACKING on BCAST PREFIX ab: PREFIX a\r\nCLIENT TRACKING on\r\n"),
        ("send", "w", "SET c:9 1\r\n"),
        ("send", "x", "CLIENT TRACKING on BCAST PREFIX FOOBAR PREFIX FOO\r\nCLIENT TRACKING on BCAST PREFIX FOO PREFIX BAR\r\nCLIENT TRACKING on BCAST PREFIX FO\r\nCLIENT TRACKING on BCAST PREFIX BARB\r\nCLIENT TRACKINGINFO\r\nCLIENT TRACKING off\r\n"),
        ("send", "r", "CLIENT TRACKING off\r\nCLIENT TRACKING on BCAST NOLOOP\r\nSET own 1\r\n"),
        ("send", "w", "SET other 1\r\n"),
        ("send", "r", "SET own2 1\r\nPING\r\nCLIENT TRACKING off\r\n"),
    ]


def tracking_optin(proto):
    return [("open", "r"), ("open", "w")] + hello(proto, "r") + [
        ("send", "w", "FLUSHALL\r\n"),
        ("send", "r", "CLIENT TRACKING on OPTIN\r\nGET k1\r\nCLIENT CACHING yes\r\nCLIENT TRACKINGINFO\r\nGET k2\r\nCLIENT CACHING no\r\n"),
        ("send", "w", "SET k1 1\r\nSET k2 1\r\n"),
        ("send", "r", "PING\r\nCLIENT TRACKING on OPTOUT\r\nCLIENT TRACKING off\r\nCLIENT TRACKING on OPTOUT\r\nCLIENT CACHING no\r\nGET k3\r\nGET k4\r\nCLIENT CACHING yes\r\n"),
        ("send", "w", "SET k3 1\r\nSET k4 1\r\n"),
        ("send", "r", "PING\r\nCLIENT TRACKING off\r\nCLIENT TRACKING on OPTIN OPTOUT\r\nCLIENT TRACKING on BCAST OPTIN\r\nCLIENT TRACKING on PREFIX x\r\nCLIENT TRACKING on REDIRECT 999999\r\nCLIENT TRACKING on REDIRECT x\r\nCLIENT TRACKING maybe\r\nCLIENT TRACKING on BOGUS\r\nCLIENT CACHING yes\r\nCLIENT TRACKING\r\nCLIENT TRACKINGINFO x\r\nCLIENT GETREDIR x\r\n"),
    ]


def tracking_broken(proto):
    return [("open", "rd"), ("open", "r"), ("open", "w")] + hello(proto, "r") + [
        ("send", "w", "FLUSHALL\r\n"),
        ("redir", "r", "rd", ""),
        ("send", "r", "GET k1\r\n"),
        ("close", "rd"),
        ("sleep", 0.1),
        ("send", "w", "SET k1 2\r\n"),
        ("send", "r", "PING\r\nCLIENT TRACKINGINFO\r\nCLIENT TRACKING off\r\n"),
    ]


def notify_self(proto):
    steps = [("open", "s"), ("open", "w")] + hello(proto, "s") + [
        ("send", "w", "FLUSHALL\r\nCONFIG SET notify-keyspace-events KEA\r\n"),
        ("send", "s", "PSUBSCRIBE __key*\r\n"),
    ]
    if proto == 3:
        steps.append(("send", "s", "SET a 1\r\nLPUSH l x\r\nCLIENT TRACKING on\r\nGET a\r\nSET a 2\r\nCLIENT REPLY OFF\r\nSET a 3\r\nGET a\r\nINCR a\r\nCLIENT REPLY ON\r\nPING\r\nCLIENT TRACKING off\r\n"))
    return steps + [
        ("send", "w", "SET b 1\r\nEXPIRE b 100\r\nDEL b\r\n"),
        ("send", "w", "CONFIG SET notify-keyspace-events \"\"\r\n"),
    ]


EVENT_COMMANDS = [
    "SET a 1", "SET a 2 EX 100", "GETEX a PERSIST", "APPEND a x", "SETRANGE a 0 zz", "INCR n", "INCRBYFLOAT f 1.5",
    "MSET m1 1 m2 2", "GETDEL m1", "SETBIT b 1 1", "SETBIT b 1 1", "PFADD h x", "LPUSH l a b", "RPOP l",
    "LMOVE l l2 LEFT RIGHT", "SADD s a b", "SREM s a", "SPOP s", "ZADD z 1 a 2 b", "ZINCRBY z 1 a", "ZPOPMIN z",
    "ZREM z b", "HSET h1 f v", "HINCRBY h1 c 1", "HDEL h1 f c", "RENAME a a2", "EXPIRE a2 100", "PERSIST a2",
    "COPY a2 a3", "MOVE a3 2", "DEL a2 nokey", "SORT l2 STORE st", "GEOADD g 13.3 38.1 p", "LINSERT st BEFORE a x",
    "SET r1 1", "SET r2 2", "RENAME r1 r2", "GET nokey", "BITOP OR dst r2 nokey", "BITOP AND dst2 nokey",
    "PFADD p1 a", "PFADD p2 b", "PFMERGE p3 p1 p2", "RPUSH lt a b c d e", "LTRIM lt 0 3", "LREM lt 1 a", "LSET lt 0 z",
    "LPUSHX nol a", "RPUSHX lt q", "LMPOP 1 lt LEFT COUNT 2", "ZADD zz 1 a 2 b 3 c 4 d", "ZREMRANGEBYSCORE zz 0 1",
    "ZREMRANGEBYRANK zz 0 0", "ZREMRANGEBYLEX zz - +", "ZADD z1 1 a", "ZADD z2 1 b", "ZUNIONSTORE zu 2 z1 z2",
    "ZINTERSTORE zi 2 z1 z2", "ZDIFFSTORE zd 1 z1", "ZRANGESTORE zr z1 0 -1", "ZRANGESTORE zr nozset 0 -1", "ZMPOP 1 z1 MIN",
    "SADD s1 a b c", "SADD s2 b", "SINTERSTORE si s1 s2", "SUNIONSTORE su s1 s2", "SDIFFSTORE sd s2 s1", "SMOVE s1 s9 a",
    "SMOVE s2 s1 b", "SPOP s1 10", "EXPIRE r2 -1", "SET g1 1", "GETEX g1 EXAT 1", "HSET hh a 1 b 2", "HSETNX hh a 2",
    "HSETNX hh c 3", "HINCRBYFLOAT hh a 1.5", "HEXPIRE hh 100 FIELDS 2 a nofield", "HPERSIST hh FIELDS 1 a",
    "HPEXPIRE hh 0 FIELDS 1 b", "HPEXPIRE hh 0 FIELDS 2 a c", "GEOSEARCHSTORE gs g FROMLONLAT 13 38 BYRADIUS 200 km",
    "GEORADIUS g 13 38 200 km STORE gr", "BITFIELD bf SET u8 0 255 GET u8 0", "SETNX nx1 v", "PSETEX px 100000 v",
    "MSETNX q1 1 q2 2", "GETSET q1 3", "DECRBY q2 5", "FLUSHALL",
]


def keyspace_events(proto):
    steps = [("open", "s"), ("open", "w")] + hello(proto, "s") + [
        ("send", "w", "FLUSHALL\r\nCONFIG SET notify-keyspace-events KEAnm\r\n"),
        ("send", "s", "PSUBSCRIBE *\r\n"),
    ]
    for i in range(0, len(EVENT_COMMANDS), 10):
        steps.append(("send", "w", "".join(c + "\r\n" for c in EVENT_COMMANDS[i:i + 10])))
    return steps + [("send", "w", "CONFIG SET notify-keyspace-events \"\"\r\n")]


def expiry_events(proto):
    return [("open", "s"), ("open", "w")] + hello(proto, "s") + [
        ("send", "w", "FLUSHALL\r\nCONFIG SET notify-keyspace-events KEAnm\r\nDEBUG SET-ACTIVE-EXPIRE 0\r\n"),
        ("send", "s", "PSUBSCRIBE *\r\n"),
        ("send", "w", "SET k1 v PX 50\r\nSET k2 v PX 50\r\nSET k3 v PX 50\r\nSET k4 v PX 50\r\nSET k5 v PX 50\r\nSET k6 v PX 50\r\nSET k7 v PX 50\r\n"),
        ("send", "w", "HSET h a 1 b 2 c 3 d 4\r\nHPEXPIRE h 50 FIELDS 3 a b c\r\nHSET h2 x 1\r\nHPEXPIRE h2 50 FIELDS 1 x\r\nHSET h3 x 1 y 2\r\nHPEXPIRE h3 50 FIELDS 2 x y\r\nHSET h4 x 1 y 2\r\nHPEXPIRE h4 50 FIELDS 1 x\r\nHSET h5 x 1\r\nHPEXPIRE h5 50 FIELDS 1 x\r\n"),
        ("sleep", 0.2),
        ("send", "w", "GET k1\r\nDEL k2\r\nSET k3 new\r\nRENAME k4 k9\r\nAPPEND k5 x\r\nEXISTS k6\r\nTYPE k7\r\n"),
        ("send", "w", "HGET h a\r\nHMGET h b c d\r\nHINCRBY h2 x 1\r\nHMGET h3 x y\r\nHRANDFIELD h4\r\nHSETNX h5 x 9\r\n"),
        ("send", "w", "DEBUG SET-ACTIVE-EXPIRE 1\r\nSET a 1 PX 30\r\n"),
        ("sleep", 0.6),
        ("send", "w", "HSET hx f 1 g 2\r\nHPEXPIRE hx 30 FIELDS 1 f\r\n"),
        ("sleep", 0.6),
        ("send", "w", "HPEXPIRE hx 30 FIELDS 1 g\r\n"),
        ("sleep", 0.6),
        ("send", "w", "CONFIG SET notify-keyspace-events \"\"\r\n"),
    ]


STREAM_COMMANDS = [
    "XADD s 1-1 f v", "XADD s 2-1 f v", "XADD s 1-1 f v", "XADD nos NOMKSTREAM 1-1 f v", "XADD s MAXLEN 1 3-1 f v",
    "XADD s MAXLEN 5 4-1 f v", "XADD s MINID 4 5-1 f v", "XDEL s 4-1", "XDEL s 99-1", "XDEL nos 1-1",
    "XADD t 1-1 a 1", "XADD t 2-1 a 1", "XADD t 3-1 a 1", "XTRIM t MAXLEN 1", "XTRIM t MAXLEN 1", "XTRIM nos MAXLEN 1",
    "XSETID s 10-1", "XSETID s 10-1 ENTRIESADDED 20 MAXDELETEDID 9-1", "XSETID nos 1-1", "XSETID t 1-0",
    "XGROUP CREATE s g $", "XGROUP CREATE s g $", "XGROUP CREATE ms g $ MKSTREAM", "XGROUP CREATE nos g $",
    "XGROUP CREATECONSUMER s g c1", "XGROUP CREATECONSUMER s g c1", "XGROUP CREATECONSUMER s nog c1",
    "XGROUP SETID s g 0", "XGROUP SETID s g 0 ENTRIESREAD 1", "XADD s 11-1 f v",
    "XREADGROUP GROUP g c2 COUNT 1 STREAMS s >", "XREADGROUP GROUP g c2 COUNT 1 STREAMS s >",
    "XREADGROUP GROUP g c3 STREAMS s 0", "XREADGROUP GROUP g c2 NOACK COUNT 1 STREAMS s >",
    "XREADGROUP GROUP g c9 STREAMS s nokey > >", "XACK s g 10-1 11-1", "XADD s 12-1 f v",
    "XREADGROUP GROUP g c2 COUNT 5 STREAMS s >", "XCLAIM s g c1 0 12-1", "XCLAIM s g c4 0 12-1", "XCLAIM s g c4 0 99-1",
    "XCLAIM s g c5 0 12-1 JUSTID", "XCLAIM s g newc 0 99-1", "XAUTOCLAIM s g c6 0 0", "XAUTOCLAIM s g c6 0 0 JUSTID",
    "XDEL s 12-1", "XAUTOCLAIM s g c7 0 0", "XRANGE nos - +", "XLEN nos", "XREAD STREAMS nos 0",
    "XREAD COUNT 1 STREAMS s a 0 0", "XGROUP DELCONSUMER s g c1", "XGROUP DELCONSUMER s g nosuch",
    "XGROUP DESTROY s g", "XGROUP DESTROY s g", "XGROUP CREATE s g2 0", "XREADGROUP GROUP g2 cc STREAMS s >",
    "SET str v", "XADD str 1-1 a 1", "XADD n3 MAXLEN 0 1-1 f v", "DEL s", "XTRIM ms MAXLEN 0", "FLUSHALL",
]


def stream_events(proto):
    steps = [("open", "s"), ("open", "w"), ("open", "r")] + hello(proto, "s") + [
        ("hello3", "r"),
        ("send", "w", "FLUSHALL\r\nCONFIG SET notify-keyspace-events KEAnm\r\n"),
        ("send", "s", "PSUBSCRIBE *\r\n"),
        ("send", "r", "CLIENT TRACKING on\r\nXLEN s\r\nXLEN t\r\nXLEN ms\r\n"),
    ]
    for i in range(0, len(STREAM_COMMANDS), 8):
        steps.append(("send", "w", "".join(c + "\r\n" for c in STREAM_COMMANDS[i:i + 8])))
    return steps + [("send", "r", "PING\r\nCLIENT TRACKING off\r\n"), ("send", "w", "CONFIG SET notify-keyspace-events \"\"\r\n")]


def blocking_events(proto):
    steps = [("open", "s"), ("open", "b"), ("open", "w")] + hello(proto, "b") + [
        ("send", "w", "FLUSHALL\r\nCONFIG SET notify-keyspace-events KEAn\r\n"),
        ("send", "s", "PSUBSCRIBE __key*\r\n"),
        ("send", "b", "BLPOP l1 0\r\n"),
        ("send", "w", "RPUSH l1 a\r\n"),
        ("send", "b", "BRPOP l2 0\r\n"),
        ("send", "w", "LPUSH l2 x y\r\n"),
        ("send", "b", "BLMPOP 0 1 l3 LEFT COUNT 2\r\n"),
        ("send", "w", "RPUSH l3 a b c\r\n"),
        ("send", "b", "BLMOVE l4 l5 LEFT RIGHT 0\r\n"),
        ("send", "w", "RPUSH l4 a\r\n"),
        ("send", "b", "BRPOPLPUSH l6 l7 0\r\n"),
        ("send", "w", "RPUSH l6 z\r\n"),
        ("send", "b", "XREAD BLOCK 0 STREAMS x1 $\r\n"),
        ("send", "w", "XADD x1 1-1 f v\r\n"),
        ("send", "w", "XGROUP CREATE x2 g $ MKSTREAM\r\n"),
        ("send", "b", "XREADGROUP GROUP g c BLOCK 0 STREAMS x2 >\r\n"),
        ("send", "w", "XADD x2 1-1 f v\r\n"),
        ("send", "b", "BLPOP l10 0.05\r\n"),
        ("sleep", 0.2),
    ]
    if proto == 3:
        steps += [
            ("send", "b", "CLIENT TRACKING on\r\nLRANGE l9 0 -1\r\nBLMOVE l8 l9 LEFT LEFT 0\r\n"),
            ("send", "w", "RPUSH l8 foo\r\n"),
            ("send", "b", "PING\r\nCLIENT TRACKING off\r\n"),
        ]
    return steps + [("send", "w", "CONFIG SET notify-keyspace-events \"\"\r\n")]


SCENARIOS = [
    ("subscribe mode", subscribe_mode),
    ("delivery order", delivery),
    ("reply off and skip", reply_off),
    ("introspection and teardown", introspection),
    ("tracking basic", tracking_basic),
    ("tracking redirect", tracking_redirect),
    ("tracking bcast", tracking_bcast),
    ("tracking optin optout", tracking_optin),
    ("tracking broken redirect", tracking_broken),
    ("notifications to self", notify_self),
    ("keyspace events", keyspace_events),
    ("expiry events", expiry_events),
    ("stream events", stream_events),
    ("blocking events", blocking_events),
]

port = int(sys.argv[1])
for name, build in SCENARIOS:
    for proto in (2, 3):
        print("%s\t%d\t%s" % (name, proto, run(port, build(proto))))
PY
)"

expect_same_pubsub() {
	local mine theirs name proto want got n=0
	mine="$(python3 -I -c "$PUBSUB_CASES_PY" "$PORT" 2>&1)"
	theirs="$(python3 -I -c "$PUBSUB_CASES_PY" "$REF_PORT" 2>&1)"
	while IFS=$'\t' read -r name proto want; do
		n=$((n + 1))
		got="$(printf '%s\n' "$mine" | awk -F'\t' -v n="$name" -v p="$proto" '$1 == n && $2 == p { print $3 }')"
		if [ -n "$want" ] && [ "$got" == "$want" ]; then
			pass
		else
			fail "$(proto_label "pubsub raw socket bytes for $name" "$proto") differ from redis" "${want:0:400}" "${got:0:400}"
		fi
	done <<<"$theirs"
	if [ "$n" -ne 28 ]; then
		fail "pubsub raw socket scenarios ran" "28 scenarios" "$n"
	fi
}

TX_CASES_PY="$(cat <<'PY'
import re
import socket
import sys
import time

SETTLE = 0.04


class Conn:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.s.setblocking(False)
        self.out = b""
        self.eof = False
        self.closed = False
        self.id = self.ask_int(b"CLIENT ID\r\n")

    def drain(self):
        while not self.eof and not self.closed:
            try:
                data = self.s.recv(65536)
            except BlockingIOError:
                return
            except ConnectionResetError:
                data = b""
            if not data:
                self.eof = True
                self.out += b"<EOF>"
                return
            self.out += data

    def send(self, data):
        while data:
            try:
                n = self.s.send(data)
                data = data[n:]
            except BlockingIOError:
                self.drain()
                time.sleep(0.001)

    def wait_for(self, marker):
        end = time.time() + 3
        while marker not in self.out and not self.eof and time.time() < end:
            self.drain()
            time.sleep(0.002)

    def ask_int(self, text):
        start = len(self.out)
        self.send(text)
        end = time.time() + 3
        while time.time() < end:
            self.drain()
            buf = self.out[start:]
            nl = buf.find(b"\r\n")
            if nl > 0 and buf[:1] == b":":
                self.out = self.out[:start]
                return int(buf[1:nl])
            time.sleep(0.002)
        return -1

    def ask_bulk(self, text):
        start = len(self.out)
        self.send(text.encode("latin1"))
        end = time.time() + 3
        while time.time() < end:
            self.drain()
            buf = self.out[start:]
            nl = buf.find(b"\r\n")
            if nl > 0 and buf[:1] in (b"$", b"="):
                n = int(buf[1:nl])
                if len(buf) >= nl + 4 + n:
                    self.out = self.out[:start]
                    body = buf[nl + 2:nl + 2 + n]
                    if buf[:1] == b"=":
                        body = body[4:]
                    return body.decode("latin1")
            time.sleep(0.002)
        return ""


def client_line(m):
    fields = dict(kv.split(b"=", 1) for kv in m.group(3).split(b" ") if b"=" in kv)
    keep = b" ".join(k + b"=" + fields.get(k, b"?") for k in (b"flags", b"db", b"multi", b"watch", b"multi-mem", b"cmd"))
    return b"<client " + keep + b">"


def normalize(out):
    return re.sub(rb"(\$|=)(\d+)\r\n(?:txt:)?(id=[^\n]*)\n\r\n", client_line, out)


def run(port, steps):
    conns = {}
    order = []
    notes = []
    for step in steps:
        op = step[0]
        if op == "open":
            conns[step[1]] = Conn(port)
            order.append(step[1])
        elif op == "hello3":
            c = conns[step[1]]
            c.send(b"HELLO 3\r\n")
            c.wait_for(b"$7\r\nmodules\r\n*0\r\n")
            c.out = b""
        elif op == "send":
            text = step[2]
            for name, c in conns.items():
                text = text.replace("{id:%s}" % name, str(c.id))
            conns[step[1]].send(text.replace("\n", "\r\n").encode("latin1"))
        elif op == "close":
            conns[step[1]].s.close()
            conns[step[1]].closed = True
        elif op == "sleep":
            time.sleep(step[1])
        elif op == "clients":
            ids = " ".join(str(conns[n].id) for n in step[2])
            text = conns[step[1]].ask_bulk("CLIENT LIST ID %s\r\n" % ids)
            by_id = {}
            for line in text.splitlines():
                fields = dict(kv.split("=", 1) for kv in line.split(" ") if "=" in kv)
                by_id[fields.get("id")] = fields
            for n in step[2]:
                fields = by_id.get(str(conns[n].id), {})
                notes.append(n + ":" + " ".join(k + "=" + fields.get(k, "?") for k in ("flags", "db", "multi", "watch", "multi-mem", "cmd", "sub")))
        elif op == "info":
            text = conns[step[1]].ask_bulk("INFO " + step[2] + "\r\n")
            for line in text.split("\r\n"):
                if line.split(":")[0] in step[3]:
                    notes.append(line)
        time.sleep(SETTLE)
        for c in conns.values():
            c.drain()
    time.sleep(0.15)
    for c in conns.values():
        c.drain()
    for name in order:
        if not conns[name].closed:
            conns[name].s.close()
    for name in order:
        conns[name].out = normalize(conns[name].out)
    return " | ".join([name + "=" + repr(conns[name].out) for name in order] + notes)


def base(proto, names):
    steps = [("open", n) for n in names]
    if proto == 3:
        steps += [("hello3", n) for n in names]
    return steps


def queue_and_exec(proto):
    return base(proto, ["a"]) + [
        ("send", "a", "DEL tx:a tx:h tx:z\nMULTI\nSET tx:a 1\nGET tx:a\nINCR tx:a\nLPUSH tx:a x\nHSET tx:h f v\nHGETALL tx:h\nSMEMBERS tx:none\nZADD tx:z 1.5 m\nZRANGE tx:z 0 -1 WITHSCORES\nGET tx:missing\nEXEC\n"),
        ("send", "a", "MULTI\nEXEC\nEXEC\nDISCARD\nMULTI\nSET tx:a 2\nDISCARD\nGET tx:a\nMULTI\nSELECT 3\nSET tx:a 3\nEXEC\nGET tx:a\nDEL tx:a\nSELECT 0\nDEL tx:a tx:h tx:z\n"),
    ]


def queue_errors(proto):
    return base(proto, ["a"]) + [
        ("send", "a", "DEL tx:e tx:f\nMULTI\nSET tx:e 1\nMULTI\nWATCH tx:e\nNOSUCH x y\nGET\nCONFIG FOO\nCLIENT KILL\nOBJECT\nSAVE\nSHUTDOWN\nCLIENT GETNAME\nEXEC\nGET tx:e\n"),
        ("send", "a", "MULTI\nSET tx:f 1\nEXEC x\nEXEC\nGET tx:f\nEXEC x\nDISCARD x\nMULTI x\nWATCH\nUNWATCH x\nMULTI\nDISCARD x\nEXEC\nMULTI\nMULTI x\nEXEC\nPING\n"),
    ]


def watch_basics(proto):
    return base(proto, ["a", "b"]) + [
        ("send", "b", "DEL tx:w tx:w2 tx:w3\nSET tx:w3 1\n"),
        ("send", "a", "WATCH tx:w tx:w2\nMULTI\nGET tx:w\n"),
        ("send", "b", "SET tx:w2 1\n"),
        ("send", "a", "EXEC\nWATCH tx:w tx:w tx:w2\nMULTI\nPING\nEXEC\n"),
        ("send", "a", "WATCH tx:w\n"),
        ("send", "b", "DEL tx:w\nSET tx:w3 2 NX\nPERSIST tx:w3\nGETEX tx:w3\n"),
        ("send", "a", "MULTI\nINCR tx:w\nEXEC\nWATCH tx:w3\n"),
        ("send", "b", "EXPIRE tx:w3 100\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nWATCH tx:w\nSET tx:w 5\nMULTI\nPING\nEXEC\nWATCH tx:w\nSET tx:w 6\nUNWATCH\nMULTI\nPING\nEXEC\n"),
        ("send", "a", "WATCH tx:w\nSET tx:w 7\nWATCH tx:w2\nMULTI\nDISCARD\nMULTI\nINCR tx:w\nEXEC\nWATCH tx:w\nMULTI\nSET tx:w 1\nSET tx:w 2\nEXEC\nGET tx:w\n"),
        ("send", "a", "WATCH tx:w\nSET tx:w 1\nMULTI\nUNWATCH\nEXEC\nDEL tx:w tx:w2 tx:w3\n"),
    ]


def watch_writes(proto):
    return base(proto, ["a", "b"]) + [
        ("send", "b", "DEL tx:k tx:l tx:m tx:n tx:o\nSET tx:k 1\nRPUSH tx:l a\nSET tx:m 1\n"),
        ("send", "a", "WATCH tx:l\n"),
        ("send", "b", "LPOP tx:l\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nWATCH tx:k\n"),
        ("send", "b", "RENAME tx:k tx:n\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nWATCH tx:o\n"),
        ("send", "b", "COPY tx:m tx:o\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nWATCH tx:m\n"),
        ("send", "b", "MOVE tx:m 7\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nWATCH tx:n\n"),
        ("send", "b", "INCRBYFLOAT tx:n 0\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nWATCH tx:o\n"),
        ("send", "b", "SORT tx:empty STORE tx:o\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nSELECT 5\nSET tx:d 30\nWATCH tx:d\nSELECT 1\nSET tx:d 10\nSELECT 5\nMULTI\nPING\nEXEC\nDEL tx:d\nSELECT 1\nDEL tx:d\nSELECT 7\nDEL tx:m\nSELECT 0\n"),
        ("send", "b", "DEL tx:k tx:l tx:m tx:n tx:o\n"),
    ]


def watch_expiry(proto):
    return base(proto, ["a", "b"]) + [
        ("send", "b", "DEBUG SET-ACTIVE-EXPIRE 0\nDEL tx:x tx:s\nSET tx:s 1 PX 1\n"),
        ("sleep", 0.02),
        ("send", "a", "SET tx:x 1 PX 300\nWATCH tx:x tx:s\n"),
        ("sleep", 0.4),
        ("send", "a", "MULTI\nPING\nEXEC\n"),
        ("send", "b", "SET tx:s 1 PX 1\n"),
        ("sleep", 0.02),
        ("send", "a", "WATCH tx:s\nMULTI\nPING\nEXEC\nWATCH tx:s\nEXISTS tx:s\nMULTI\nPING\nEXEC\n"),
        ("send", "b", "SET tx:s 1 PX 1\n"),
        ("sleep", 0.02),
        ("send", "a", "WATCH tx:s\nSET tx:s 2\nMULTI\nPING\nEXEC\nSET tx:x 1 PX 300\nWATCH tx:x\n"),
        ("sleep", 0.4),
        ("send", "a", "GET tx:x\nMULTI\nPING\nEXEC\n"),
        ("send", "b", "DEBUG SET-ACTIVE-EXPIRE 1\n"),
        ("send", "a", "SET tx:x 1 PX 200\nWATCH tx:x\n"),
        ("sleep", 0.8),
        ("send", "b", "DBSIZE\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nDEL tx:s tx:x\n"),
    ]


def watch_flush_swap(proto):
    return base(proto, ["a", "b"]) + [
        ("send", "b", "DEBUG SET-ACTIVE-EXPIRE 0\nSELECT 9\nFLUSHDB\nSELECT 10\nFLUSHDB\nSELECT 9\n"),
        ("send", "a", "SELECT 9\nSET tx:y 1\nWATCH tx:y\n"),
        ("send", "b", "FLUSHDB\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nWATCH tx:y\n"),
        ("send", "b", "FLUSHDB\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nSET tx:y 1 PX 1\n"),
        ("sleep", 0.02),
        ("send", "a", "WATCH tx:y\n"),
        ("send", "b", "FLUSHDB\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nSET tx:y 1\nWATCH tx:y\n"),
        ("send", "b", "SWAPDB 9 10\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nWATCH tx:y\n"),
        ("send", "b", "SWAPDB 9 10\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nFLUSHDB\nSET tx:y 1 PX 1\n"),
        ("sleep", 0.02),
        ("send", "a", "WATCH tx:y\n"),
        ("send", "b", "SWAPDB 9 10\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nWATCH tx:y\n"),
        ("send", "b", "SWAPDB 9 10\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nSELECT 10\nSET tx:y 2\nSELECT 9\nWATCH tx:y\n"),
        ("send", "b", "SWAPDB 9 10\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nWATCH tx:z\n"),
        ("send", "b", "SWAPDB 11 12\nFLUSHALL\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nSET tx:y 1\nWATCH tx:y\n"),
        ("send", "b", "FLUSHALL\nDEBUG SET-ACTIVE-EXPIRE 1\n"),
        ("send", "a", "MULTI\nPING\nEXEC\nSELECT 0\n"),
    ]


def blocking(proto):
    return base(proto, ["a", "b"]) + [
        ("send", "a", "DEL tx:l tx:l2 tx:z tx:zz tx:s tx:q tx:src tx:dst\nXGROUP CREATE tx:s g $ MKSTREAM\nZADD tx:zz 1 m\nRPUSH tx:l2 x\n"),
        ("send", "a", "MULTI\nBLPOP tx:l 0\nBRPOP tx:l 0\nBRPOPLPUSH tx:l tx:l9 0\nBLMOVE tx:l tx:l9 LEFT LEFT 0\nBZPOPMIN tx:z 0\nBZPOPMAX tx:z 0\nXREAD BLOCK 0 STREAMS tx:s $\nXREADGROUP GROUP g c BLOCK 0 STREAMS tx:s >\nBLMPOP 0 1 tx:l LEFT\nBZMPOP 0 1 tx:z MIN\nBLPOP tx:l -1\nBZPOPMIN tx:zz 0\nBLPOP tx:l2 0.5\nEXEC\n"),
        ("send", "b", "BLPOP tx:q 0\n"),
        ("send", "a", "MULTI\nLPUSH tx:q a\nLPUSH tx:q b\nLPUSH tx:q c\nEXEC\n"),
        ("send", "b", "BRPOPLPUSH tx:src tx:dst 0\n"),
        ("send", "a", "WATCH tx:dst\nMULTI\nPING\n"),
        ("send", "b", "PING\n"),
        ("send", "a", "EXEC\nWATCH tx:dst\nMULTI\nPING\nEXEC\nLPUSH tx:src e\n"),
        ("sleep", 0.05),
        ("send", "a", "WATCH tx:dst\nMULTI\nPING\n"),
        ("send", "b", "BRPOPLPUSH tx:src tx:dst 0\n"),
        ("send", "a", "LPUSH tx:src f\nEXEC\nDEL tx:l tx:l2 tx:l9 tx:z tx:zz tx:s tx:q tx:src tx:dst\n"),
    ]


def pubsub_tracking(proto):
    return base(proto, ["a", "b"]) + [
        ("send", "a", "SUBSCRIBE tx:c\nMULTI\nPING abc\nPUBLISH tx:c bar\nPUBLISH tx:c vaz\nPING def\nEXEC\nUNSUBSCRIBE\n"),
        ("send", "a", "MULTI\nSUBSCRIBE tx:c1 tx:c2\nPING\nEXEC\n"),
        ("send", "b", "PUBLISH tx:c1 m\n"),
        ("send", "a", "RESET\n"),
        ("send", "b", "DEL tx:ta tx:tb tx:tc\nMSET tx:ta 1 tx:tb 2\n"),
        ("send", "a", "CLIENT TRACKING on\nGET tx:ta\nMULTI\nINCR tx:ta\nGET tx:tb\nEXEC\nPING\n"),
        ("send", "b", "SET tx:tb 9\n"),
        ("send", "a", "CLIENT TRACKING off\nCLIENT TRACKING on OPTIN\nCLIENT CACHING yes\nMULTI\nGET tx:ta\nGET tx:tb\nEXEC\nGET tx:tc\n"),
        ("send", "b", "SET tx:ta 1\nSET tx:tb 1\nSET tx:tc 1\n"),
        ("send", "a", "MULTI\nGET tx:ta\nCLIENT CACHING yes\nGET tx:tb\nEXEC\n"),
        ("send", "b", "SET tx:ta 2\nSET tx:tb 2\n"),
        ("send", "a", "CLIENT TRACKING off\nCLIENT TRACKING on NOLOOP\nMULTI\nGET tx:ta\nSET tx:ta 2\nGET tx:tb\nEXEC\n"),
        ("send", "b", "SET tx:ta 3\nSET tx:tb 3\n"),
        ("send", "a", "RESET\n"),
        ("send", "b", "DEL tx:ta tx:tb tx:tc\n"),
    ]


def reply_modes(proto):
    return base(proto, ["a"]) + [
        ("send", "a", "MULTI\nCLIENT REPLY OFF\nPING\nCLIENT REPLY ON\nPING x\nEXEC\nPING y\n"),
        ("send", "a", "MULTI\nCLIENT REPLY SKIP\nPING\nPING x\nEXEC\nPING y\nPING z\n"),
        ("send", "a", "CLIENT REPLY OFF\nMULTI\nPING\nEXEC\nCLIENT REPLY ON\nPING w\n"),
        ("send", "a", "MULTI\nPING\nCLIENT REPLY OFF\nPING\nEXEC\nCLIENT REPLY ON\nPING v\n"),
        ("send", "a", "CLIENT REPLY SKIP\nMULTI\nPING\nEXEC\n"),
        ("send", "a", "DEL tx:ro\nCLIENT TRACKING on\nGET tx:ro\nMULTI\nPING\nSET tx:ro 1\nCLIENT REPLY OFF\nPING\nEXEC\nCLIENT REPLY ON\nPING z\nCLIENT TRACKING off\nDEL tx:ro\n"),
        ("send", "a", "MULTI\nSUBSCRIBE tx:rc\nCLIENT REPLY OFF\nSUBSCRIBE tx:rd\nCLIENT REPLY ON\nPING\nEXEC\nPING z\nUNSUBSCRIBE tx:rc tx:rd\n"),
        ("send", "a", "SUBSCRIBE tx:re\nMULTI\nPING\nPUBLISH tx:re m\nCLIENT REPLY OFF\nPUBLISH tx:re n\nEXEC\nCLIENT REPLY ON\nPING z\nRESET\n"),
    ]


def introspection(proto):
    return base(proto, ["a", "b", "o"]) + [
        ("send", "b", "DEL tx:i tx:j\n"),
        ("send", "a", "WATCH tx:i tx:j\nSELECT 3\nWATCH tx:i\nSELECT 0\nMULTI\nGET tx:i\nSET tx:abc defgh\n"),
        ("clients", "o", ["a"]),
        ("info", "o", "clients", ["watching_clients", "total_watched_keys", "blocked_clients"]),
        ("send", "a", "NOSUCH x\n"),
        ("clients", "o", ["a"]),
        ("send", "a", "CLIENT INFO\n"),
        ("clients", "o", ["a"]),
        ("send", "b", "SET tx:j 1\n"),
        ("clients", "o", ["a"]),
        ("info", "o", "clients", ["watching_clients", "total_watched_keys"]),
        ("send", "a", "DISCARD\nWATCH tx:i\nMULTI\nSET tx:i 1\nCLIENT INFO\n"),
        ("send", "a", "EXEC\n"),
        ("clients", "o", ["a"]),
        ("send", "b", "WATCH tx:i\nSET tx:i 2\n"),
        ("clients", "o", ["b"]),
        ("send", "b", "WATCH tx:z\nMULTI\nCLIENT INFO\n"),
        ("clients", "o", ["b"]),
        ("info", "o", "clients", ["watching_clients", "total_watched_keys"]),
        ("send", "b", "UNWATCH\nMULTI\nCLIENT INFO\nEXEC\nDEL tx:i tx:j tx:abc\n"),
    ]


def oom(proto):
    return base(proto, ["a", "b"]) + [
        ("send", "a", "SET tx:o v\nMULTI\nGET tx:o\nPING\n"),
        ("send", "b", "CONFIG SET maxmemory 1\n"),
        ("send", "a", "EXEC\nMULTI\nGET tx:o\nSET tx:p 1\nLPUSH tx:q x\nPING\nEXEC\nMULTI\nDISCARD\nSET tx:p 1\nGET tx:o\n"),
        ("send", "b", "CONFIG SET maxmemory 0\n"),
        ("send", "a", "MULTI\nSET tx:p 1\nGET tx:p\n"),
        ("send", "b", "CONFIG SET maxmemory 1\n"),
        ("send", "a", "EXEC\nGET tx:p\n"),
        ("send", "b", "CONFIG SET maxmemory 0\nDEL tx:o tx:p\n"),
    ]


def pause(proto):
    return base(proto, ["a", "b", "o"]) + [
        ("send", "b", "DEL tx:pa tx:pb tx:pc\nCLIENT PAUSE 400 WRITE\n"),
        ("send", "a", "MULTI\nGET tx:pa\nSET tx:pa 1\nPING\n"),
        ("sleep", 0.1),
        ("clients", "o", ["a"]),
        ("info", "o", "clients", ["blocked_clients"]),
        ("sleep", 0.4),
        ("send", "a", "EXEC\nMULTI\nGET tx:pa\nINCR tx:pa\n"),
        ("send", "b", "CLIENT PAUSE 400 WRITE\n"),
        ("send", "a", "EXEC\n"),
        ("sleep", 0.1),
        ("clients", "o", ["a"]),
        ("info", "o", "clients", ["blocked_clients"]),
        ("send", "b", "CLIENT UNPAUSE\n"),
        ("send", "a", "MULTI\nGET tx:pa\nPING\n"),
        ("send", "b", "CLIENT PAUSE 400 WRITE\n"),
        ("send", "a", "EXEC\n"),
        ("send", "b", "CLIENT UNPAUSE\n"),
        ("send", "a", "MULTI\nSET tx:pb BAR\nCLIENT PAUSE 400 WRITE\nSET tx:pc BAR\nEXEC\n"),
        ("send", "b", "SET tx:pd BAR\n"),
        ("sleep", 0.1),
        ("send", "a", "MGET tx:pb tx:pc tx:pd\n"),
        ("sleep", 0.4),
        ("send", "a", "MGET tx:pb tx:pc tx:pd\nDEL tx:pa tx:pb tx:pc tx:pd\n"),
    ]


def teardown(proto):
    return base(proto, ["a", "b", "c", "o"]) + [
        ("send", "b", "DEL tx:r\n"),
        ("send", "a", "WATCH tx:r\nMULTI\nSET tx:r 1\nRESET\nEXEC\nGET tx:r\n"),
        ("info", "o", "clients", ["watching_clients", "total_watched_keys"]),
        ("send", "b", "WATCH tx:r\nMULTI\nSET tx:r 1\n"),
        ("send", "o", "CLIENT KILL ID {id:b}\n"),
        ("info", "o", "clients", ["watching_clients", "total_watched_keys", "connected_clients"]),
        ("send", "c", "MULTI\nSET tx:r 2\nQUIT\n"),
        ("send", "o", "GET tx:r\n"),
        ("send", "a", "MULTI\nSET tx:r 3\nCLIENT KILL ID {id:a} SKIPME no\nSET tx:r 4\nEXEC\n"),
        ("send", "o", "GET tx:r\nDEL tx:r\n"),
    ]


SCENARIOS = [
    ("queue and exec", queue_and_exec),
    ("queue errors", queue_errors),
    ("watch basics", watch_basics),
    ("watch writes", watch_writes),
    ("watch expiry", watch_expiry),
    ("watch flush and swap", watch_flush_swap),
    ("blocking inside a transaction", blocking),
    ("pubsub and tracking", pubsub_tracking),
    ("reply modes", reply_modes),
    ("introspection", introspection),
    ("out of memory", oom),
    ("client pause", pause),
    ("reset kill and quit", teardown),
]

port = int(sys.argv[1])
only = sys.argv[2] if len(sys.argv) > 2 else ""
for name, build in SCENARIOS:
    if only and only not in name:
        continue
    for proto in (2, 3):
        print("%s\t%d\t%s" % (name, proto, run(port, build(proto))))
PY
)"

TX_STRESS_PY="$(cat <<'PY'
import selectors
import socket
import sys
import time

PORT = int(sys.argv[1])
WATCHERS = int(sys.argv[2]) if len(sys.argv) > 2 else 40
WRITERS = int(sys.argv[3]) if len(sys.argv) > 3 else 10
ROUNDS = int(sys.argv[4]) if len(sys.argv) > 4 else 100
ACCOUNTS = 8
START = 1000


def enc(*args):
    out = [b"*%d\r\n" % len(args)]
    for a in args:
        if not isinstance(a, bytes):
            a = str(a).encode()
        out.append(b"$%d\r\n%s\r\n" % (len(a), a))
    return b"".join(out)


def parse(buf, i):
    nl = buf.find(b"\r\n", i)
    if nl < 0:
        return None
    t = buf[i:i + 1]
    line = buf[i + 1:nl]
    j = nl + 2
    if t in (b"+", b"-", b":"):
        return (t, line), j
    if t == b"$":
        n = int(line)
        if n < 0:
            return (t, None), j
        if len(buf) < j + n + 2:
            return None
        return (t, buf[j:j + n]), j + n + 2
    if t == b"*":
        n = int(line)
        if n < 0:
            return (t, None), j
        items = []
        for _ in range(n):
            r = parse(buf, j)
            if r is None:
                return None
            items.append(r[0])
            j = r[1]
        return (t, items), j
    raise ValueError("unexpected reply type %r" % t)


class Client:
    def __init__(self, sel, role, idx):
        self.s = socket.create_connection(("127.0.0.1", PORT))
        self.s.setblocking(False)
        self.sel = sel
        self.role = role
        self.idx = idx
        self.inbuf = b""
        self.want = 0
        self.replies = []
        self.done = 0
        self.retries = 0
        self.state = None
        self.out = b""
        sel.register(self.s, selectors.EVENT_READ, self)

    def send(self, data, nreplies):
        self.out += data
        self.want = nreplies
        self.replies = []
        self.flush()

    def flush(self):
        while self.out:
            try:
                n = self.s.send(self.out)
                self.out = self.out[n:]
            except BlockingIOError:
                break

    def on_read(self):
        data = self.s.recv(65536)
        if not data:
            raise EOFError("server closed a connection")
        self.inbuf += data
        while self.want > 0:
            r = parse(self.inbuf, 0)
            if r is None:
                break
            self.replies.append(r[0])
            self.inbuf = self.inbuf[r[1]:]
            self.want -= 1
        return self.want == 0


errors = []
stale = 0


def pair(i, k):
    a = (i * 7 + k * 3) % ACCOUNTS
    b = (a + 1 + (i + k) % (ACCOUNTS - 1)) % ACCOUNTS
    return b"acct:%d" % a, b"acct:%d" % b


def start(c):
    if c.role == "watcher":
        a, b = pair(c.idx, c.done + c.retries)
        c.state = (a, b)
        c.send(enc("WATCH", a, b, b"counter:" + a) + enc("MGET", a, b, b"counter:" + a), 2)
    else:
        a, b = pair(c.idx + 100, c.done)
        c.state = (a, b)
        c.send(enc("MULTI") + enc("DECRBY", a, 1) + enc("INCRBY", b, 1) + enc("INCR", b"counter:" + a) + enc("INCR", "writes") + enc("EXEC"), 6)


def step(c):
    global stale
    if c.role == "watcher" and c.state is not None and len(c.state) == 2:
        if c.replies[0] != (b"+", b"OK"):
            errors.append("watch reply %r" % (c.replies[0],))
        vals = c.replies[1][1]
        va = int(vals[0][1])
        vb = int(vals[1][1])
        counter = int(vals[2][1] or b"0")
        a, b = c.state
        c.state = (a, b, va, vb, counter)
        c.send(enc("MULTI") + enc("SET", a, va - 3) + enc("SET", b, vb + 3) + enc("SET", b"counter:" + a, counter + 1) + enc("INCR", "commits") + enc("EXEC"), 6)
        return
    if c.role == "watcher":
        res = c.replies[5]
        if res[0] == b"*" and res[1] is None:
            c.retries += 1
        elif res[0] == b"*":
            got = res[1]
            if len(got) != 4 or got[0] != (b"+", b"OK"):
                errors.append("exec reply %r" % (got,))
            c.done += 1
        else:
            errors.append("exec reply %r" % (res,))
    else:
        res = c.replies[5]
        if res[0] != b"*" or res[1] is None or len(res[1]) != 4:
            errors.append("writer exec reply %r" % (res,))
        c.done += 1
    if c.done < ROUNDS:
        start(c)
    else:
        c.state = None


def main():
    setup = socket.create_connection(("127.0.0.1", PORT))
    cmds = enc("DEL", "commits", "writes", *["counter:acct:%d" % i for i in range(ACCOUNTS)]) + b"".join(enc("SET", "acct:%d" % i, START) for i in range(ACCOUNTS))
    setup.sendall(cmds)
    need = 1 + ACCOUNTS
    buf = b""
    while buf.count(b"\r\n") < need:
        buf += setup.recv(65536)
    sel = selectors.DefaultSelector()
    clients = [Client(sel, "watcher", i) for i in range(WATCHERS)] + [Client(sel, "writer", i) for i in range(WRITERS)]
    t0 = time.time()
    for c in clients:
        start(c)
    active = len(clients)
    while active > 0 and time.time() - t0 < 120:
        for key, _ in sel.select(timeout=1):
            c = key.data
            if c.on_read():
                step(c)
                if c.state is None:
                    active -= 1
        for c in clients:
            if c.out:
                c.flush()
    elapsed = time.time() - t0
    setup.sendall(enc("MGET", "commits", "writes", *["acct:%d" % i for i in range(ACCOUNTS)], *["counter:acct:%d" % i for i in range(ACCOUNTS)]))
    buf = b""
    r = None
    while r is None:
        buf += setup.recv(65536)
        r = parse(buf, 0)
    vals = [int(v[1] or b"0") for v in r[0][1]]
    commits, writes = vals[0], vals[1]
    total = sum(vals[2:2 + ACCOUNTS])
    counter = sum(vals[2 + ACCOUNTS:])
    watcher_done = sum(c.done for c in clients if c.role == "watcher")
    retries = sum(c.retries for c in clients if c.role == "watcher")
    ok = (
        active == 0
        and not errors
        and commits == watcher_done == WATCHERS * ROUNDS
        and writes == WRITERS * ROUNDS
        and counter == commits + writes
        and total == START * ACCOUNTS
    )
    print(
        "%s watchers=%d writers=%d commits=%d writes=%d counter=%d expected=%d balance=%d expected=%d aborted=%d errors=%d secs=%.2f"
        % ("ok" if ok else "bad", WATCHERS, WRITERS, commits, writes, counter, commits + writes, total, START * ACCOUNTS, retries, len(errors), elapsed)
    )
    if errors:
        print(errors[:3])


main()
PY
)"

expect_same_transactions() {
	local mine theirs name proto want got n=0
	mine="$(python3 -I -c "$TX_CASES_PY" "$PORT" 2>&1)"
	theirs="$(python3 -I -c "$TX_CASES_PY" "$REF_PORT" 2>&1)"
	while IFS=$'\t' read -r name proto want; do
		n=$((n + 1))
		got="$(printf '%s\n' "$mine" | awk -F'\t' -v n="$name" -v p="$proto" '$1 == n && $2 == p { print $3 }')"
		if [ -n "$want" ] && [ "$got" == "$want" ]; then
			pass
		else
			fail "$(proto_label "transaction raw socket bytes for $name" "$proto") differ from redis" "${want:0:400}" "${got:0:400}"
		fi
	done <<<"$theirs"
	if [ "$n" -ne 26 ]; then
		fail "transaction raw socket scenarios ran" "26 scenarios" "$n"
	fi
}

ACL_CASES_PY="$(cat <<'PY'
import hashlib
import re
import socket
import sys
import time

SETTLE = 0.05


def resp(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        if isinstance(a, str):
            a = a.encode("latin1")
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out.decode("latin1")


def cmds(*lines):
    return "".join(line + "\r\n" for line in lines)


def each(name, *lines):
    return [("send", name, line if line.endswith("\r\n") else line + "\r\n") for line in lines]


class Conn:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.s.setblocking(False)
        self.out = b""
        self.eof = False
        self.closed = False

    def drain(self):
        while not self.eof and not self.closed:
            try:
                data = self.s.recv(65536)
            except BlockingIOError:
                return
            except ConnectionResetError:
                data = b""
            if not data:
                self.eof = True
                self.out += b"<EOF>"
                return
            self.out += data

    def send(self, text):
        data = text.encode("latin1")
        while data:
            try:
                n = self.s.send(data)
                data = data[n:]
            except BlockingIOError:
                self.drain()
                time.sleep(0.001)
            except (BrokenPipeError, ConnectionResetError):
                self.out += b"<SENDERR>"
                return

    def wait_for(self, marker):
        end = time.time() + 3
        while marker not in self.out and not self.eof and time.time() < end:
            self.drain()
            time.sleep(0.002)

    def bulk(self, text):
        start = len(self.out)
        self.send(text)
        end = time.time() + 3
        while time.time() < end:
            self.drain()
            buf = self.out[start:]
            nl = buf.find(b"\r\n")
            if nl > 0 and buf[:1] in (b"$", b"="):
                n = int(buf[1:nl])
                if len(buf) >= nl + 4 + n:
                    self.out = self.out[:start]
                    return buf[nl + 2:nl + 2 + n].decode("latin1")
            if nl > 0 and buf[:1] == b"-":
                self.out = self.out[:start]
                return buf[:nl].decode("latin1")
            time.sleep(0.002)
        return ""

    def array(self, text):
        start = len(self.out)
        self.send(text)
        end = time.time() + 3
        items = None
        while time.time() < end:
            self.drain()
            buf = self.out[start:]
            items = parse_flat(buf)
            if items is not None:
                self.out = self.out[:start]
                return items
            time.sleep(0.002)
        return []


def parse_flat(buf):
    nl = buf.find(b"\r\n")
    if nl < 0:
        return None
    if buf[:1] == b"-":
        return [buf[:nl].decode("latin1")]
    if buf[:1] not in (b"*", b"~"):
        return None
    n = int(buf[1:nl])
    pos = nl + 2
    items = []
    for _ in range(n):
        nl = buf.find(b"\r\n", pos)
        if nl < 0:
            return None
        ln = int(buf[pos + 1:nl])
        if len(buf) < nl + 4 + ln:
            return None
        items.append(buf[nl + 2:nl + 2 + ln].decode("latin1"))
        pos = nl + 4 + ln
    return items


CLIENT_INFO = re.compile(rb"\$(\d+)\r\n(id=\d+ addr=[^\r\n]*)\r\n")
KEEP_FIELDS = ("name", "flags", "db", "sub", "psub", "ssub", "multi", "watch", "cmd", "user", "redir", "resp", "lib-name", "lib-ver")


def client_fields(line):
    fields = dict(kv.split("=", 1) for kv in line.split(" ") if "=" in kv)
    return " ".join(k + "=" + fields.get(k, "?") for k in KEEP_FIELDS)


def normalize(data):
    data = CLIENT_INFO.sub(lambda m: b"$CI\r\n" + client_fields(m.group(2).decode("latin1")).encode("latin1") + b"\r\n", data)
    data = re.sub(rb"age-seconds\r\n(\$\d+\r\n[0-9.e+-]+|,[0-9.e+-]+)\r\n", b"age-seconds\r\nAGE\r\n", data)
    data = re.sub(rb"(timestamp-created|timestamp-last-updated)\r\n:\d+\r\n", rb"\1\r\n:TS\r\n", data)
    ids = [int(x) for x in re.findall(rb"entry-id\r\n:(\d+)\r\n", data)]
    if ids:
        low = min(ids)
        data = re.sub(rb"entry-id\r\n:(\d+)\r\n", lambda m: b"entry-id\r\n:E+%d\r\n" % (int(m.group(1)) - low), data)
    data = re.sub(rb"server\r\n\$\d+\r\n\w+\r\n\$7\r\nversion\r\n\$\d+\r\n[0-9.]+\r\n\$5\r\nproto\r\n:(\d)\r\n\$2\r\nid\r\n:\d+\r\n", rb"server\r\nS\r\nversion\r\nV\r\nproto\r\n:\1\r\nid\r\n:ID\r\n", data)
    return data


def run(port, steps):
    conns = {}
    order = []
    notes = []
    base = {}
    for step in steps:
        op = step[0]
        if op == "open":
            conns[step[1]] = Conn(port)
            order.append(step[1])
        elif op == "hello3":
            c = conns[step[1]]
            c.send("HELLO 3\r\n")
            c.wait_for(b"$7\r\nmodules\r\n*0\r\n")
            c.out = b""
        elif op == "send":
            conns[step[1]].send(step[2])
        elif op == "close":
            conns[step[1]].s.close()
            conns[step[1]].closed = True
        elif op == "sleep":
            time.sleep(step[1])
        elif op == "info":
            text = conns[step[1]].bulk("INFO " + step[2] + "\r\n")
            picked = []
            for line in text.split("\r\n"):
                key = line.split(":")[0]
                if key in base:
                    line = "%s:+%d" % (key, int(line.split(":")[1]) - base[key])
                if key in step[3] or any(key.startswith(p) for p in step[3] if p.endswith("_")):
                    picked.append(re.sub(r",usec=\d+,usec_per_call=[0-9.]+", "", line))
            notes.extend(sorted(picked))
        elif op == "mark":
            text = conns[step[1]].bulk("INFO stats\r\n")
            for line in text.split("\r\n"):
                if line.startswith("acl_access_denied_"):
                    base[line.split(":")[0]] = int(line.split(":")[1])
        elif op == "clients":
            c = conns[step[1]]
            prefix = step[3] if len(step) > 3 else ""
            start = len(c.out)
            c.send(prefix + "CLIENT LIST\r\n")
            text = ""
            end = time.time() + 3
            while time.time() < end:
                c.drain()
                buf = c.out[start:]
                m = re.search(rb"[$=](\d+)\r\n(?=(txt:)?id=)", buf)
                if m and len(buf) >= m.end() + int(m.group(1)) + 2:
                    text = buf[m.end():m.end() + int(m.group(1))].decode("latin1")
                    if text.startswith("txt:"):
                        text = text[4:]
                    notes.append("before[" + repr(buf[:m.start()]) + "]")
                    c.out = c.out[:start]
                    break
                time.sleep(0.002)
            rows = []
            for line in text.splitlines():
                fields = dict(kv.split("=", 1) for kv in line.split(" ") if "=" in kv)
                if fields.get("name", "").startswith(step[2]):
                    rows.append(" ".join(k + "=" + fields.get(k, "?") for k in ("name", "user", "cmd", "flags")))
            notes.append("clients[" + ";".join(sorted(rows)) + "]")
        elif op == "genpass":
            items = conns[step[1]].bulk(step[2] + "\r\n")
            ok = all(ch in "0123456789abcdef" for ch in items) and not items.startswith("-")
            notes.append("genpass %s len=%d hex=%s" % (step[2], len(items), ok) if not items.startswith("-") else "genpass %s %s" % (step[2], items))
        elif op == "cat":
            items = conns[step[1]].array("ACL CAT " + step[2] + "\r\n")
            notes.append("cat %s %s" % (step[2], ",".join(sorted(items))))
        time.sleep(SETTLE)
        for c in conns.values():
            c.drain()
    time.sleep(0.2)
    for c in conns.values():
        c.drain()
    for name in order:
        if not conns[name].closed:
            conns[name].s.close()
    return " | ".join([name + "=" + repr(normalize(conns[name].out)) for name in order] + notes)


def hello(proto, *names):
    return [("hello3", n) for n in names] if proto == 3 else []


CLEAN = cmds(
    "CONFIG SET requirepass \"\"",
    "ACL SETUSER default reset on nopass ~* &* +@all",
    "ACL LOG RESET",
    "CONFIG SET acllog-max-len 128",
    "CONFIG SET acl-pubsub-default resetchannels",
)


def cleanup(*users):
    text = CLEAN
    if users:
        text = "ACL DELUSER " + " ".join(users) + "\r\n" + text
    return ("send", "a", text)


def grammar(proto):
    return [("open", "a")] + hello(proto, "a") + [
        ("send", "a", cmds(
            "ACL SETUSER \"a b\"",
            "ACL SETUSER \"a\\x00b\"",
            "ACL SETUSER e1 +nosuch",
            "ACL SETUSER e1 -nosuch",
            "ACL SETUSER e1 +@nosuch",
            "ACL SETUSER e1 -@nosuch",
            "ACL SETUSER e1 +@",
            "ACL SETUSER e1 +",
            "ACL SETUSER e1 -",
            "ACL SETUSER e1 bogus",
            "ACL SETUSER e1 ~* ~foo",
            "ACL SETUSER e1 &* &foo",
            "ACL SETUSER e1 <nopw",
            "ACL SETUSER e1 !abc",
            "ACL SETUSER e1 #abc",
            "ACL SETUSER e1 #34344E4D60C2B6D639B7BD22E18F2B0B91BC34BF0AC5F9952744435093CFB4E6",
            "ACL SETUSER e1 +config|get|x",
            "ACL SETUSER e1 +debug|",
            "ACL SETUSER e1 +get|x|y",
            "ACL SETUSER e1 +config|nosuch",
            "ACL SETUSER e1 -config|nosuch",
            "ACL SETUSER e1 -select|0",
            "ACL SETUSER e1 (+get",
            "ACL SETUSER e1 (+get ~x) )",
            "ACL SETUSER e1 (bogus)",
            "ACL SETUSER e1 \" () \"",
            "ACL SETUSER e1 )",
            "ACL SETUSER e1 \"(&* &fail)\"",
            "ACL SETUSER e1 (+PING (+SELECT (+DEL ) ) )",
            "ACL SETUSER e1 \"~a b\"",
            "ACL SETUSER e1 \"&a b\"",
            "ACL SETUSER e1 %X~a",
            "ACL SETUSER e1 %RR~a",
            "ACL SETUSER e1 %~a",
            "ACL SETUSER e1 %",
            "ACL SETUSER e1 on >ok \"bad rule\"",
            "ACL GETUSER e1",
            "ACL SETUSER e1 on >p1 >p2 >p1 #6b86b273ff34fce19d6b804eff5a3f5747ada4e1f9e9a7b9b4d8b5a5c1a5e7e7 <p2",
            "ACL GETUSER e1",
            "ACL SETUSER e1 nopass",
            "ACL GETUSER e1",
            "ACL SETUSER e1 resetpass >x !2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881",
            "ACL GETUSER e1",
            "ACL SETUSER s1 on nopass ~k1 %R~r* %W~w* %RW~rw* &ch1 &ch* +get +set -@all +@hash -hset +client|id +select|0 +select|1 +debug|digest (~x +get) (%R~y* &z +@read -@write) ( ~q +ping )",
            "ACL GETUSER s1",
            "ACL LIST",
            "ACL SETUSER s1 clearselectors",
            "ACL GETUSER s1",
            "ACL SETUSER s1 reset",
            "ACL GETUSER s1",
            "ACL SETUSER s2 %R~a %W~a %RW~b ~c %W~c %R",
            "ACL GETUSER s2",
            "ACL SETUSER s3 allkeys allchannels allcommands",
            "ACL GETUSER s3",
            "ACL SETUSER s3 resetkeys resetchannels nocommands",
            "ACL GETUSER s3",
            "ACL SETUSER s4 +@all -@dangerous +flushall -debug +debug|object",
            "ACL GETUSER s4",
            "ACL SETUSER s5 -@all +@set +@set -sadd +sadd +@hash -@hash",
            "ACL GETUSER s5",
            "ACL SETUSER s6 +CLIENT|ID +Client|SetName -CLIENT",
            "ACL GETUSER s6",
            "ACL SETUSER s7 \"\" on ON Off sanitize-payload skip-sanitize-payload",
            "ACL GETUSER s7",
            "ACL SETUSER s8 -@all +config +config|get -config|set +config +eval +script|kill",
            "ACL GETUSER s8",
            "ACL SETUSER s9 +@all -@all +@all -client +client|list -client|list +client",
            "ACL GETUSER s9",
            "ACL GETUSER nosuch",
            "ACL USERS",
            "ACL LIST",
            "ACL DELUSER s1 s2 nosuch s3",
            "ACL DELUSER default s4",
            "ACL DELUSER s4 default",
            "ACL USERS",
        )),
        cleanup("e1", "s4", "s5", "s6", "s7", "s8", "s9"),
    ]


def auth(proto):
    dave = hashlib.sha256(b"x").hexdigest()
    return [("open", "a"), ("open", "u")] + hello(proto, "a", "u") + [
        ("send", "a", cmds(
            "ACL SETUSER alice on >pw1 >pw2 +@all ~* &*",
            "ACL SETUSER bob off >pw +@all",
            "ACL SETUSER carol on nopass +@all ~*",
            "ACL SETUSER dave on #" + dave + " +acl",
            "AUTH x",
            "AUTH a b c",
            "AUTH default anything",
        )),
    ] + each("u",
        "AUTH alice pw1", "ACL WHOAMI", "AUTH alice pw2", "AUTH alice bad", "ACL WHOAMI", "AUTH bob pw",
        "AUTH carol anything", "ACL WHOAMI", "AUTH dave x", "ACL WHOAMI", "AUTH nosuch x", "AUTH Alice pw1",
    ) + each("u",
        "HELLO 2 AUTH alice bad", "HELLO " + str(proto) + " AUTH alice pw1 SETNAME n1", "CLIENT GETNAME",
        "HELLO " + str(proto) + " AUTH alice pw1 AUTH carol x", "ACL WHOAMI",
        "HELLO " + str(proto) + " SETNAME n2 SETNAME \"bad name\" AUTH alice pw1", "CLIENT GETNAME", "ACL WHOAMI",
        "HELLO " + str(proto) + " AUTH alice", "HELLO " + str(proto) + " FOO", "HELLO 9 AUTH alice pw1",
        "HELLO " + str(proto) + " AUTH alice bad SETNAME n3", "CLIENT GETNAME",
    ) + [
        ("send", "a", cmds("ACL SETUSER alice <pw1")),
    ] + each("u", "AUTH alice pw1", "AUTH alice pw2", "ACL WHOAMI", "RESET", "ACL WHOAMI") + [
        ("send", "a", resp("CONFIG", "SET", "requirepass", "abc\x00def")),
        ("open", "b"),
    ] + each("b", "PING", "AUTH abc", resp("AUTH", "abc\x00def"), "PING", "ACL WHOAMI") + [
        ("send", "a", cmds("ACL GETUSER default")),
        cleanup("alice", "bob", "carol", "dave"),
    ]


def permissions(proto):
    return [("open", "a"), ("open", "u"), ("open", "s"), ("open", "w")] + hello(proto, "a", "u", "w") + [
        ("send", "a", cmds(
            "FLUSHALL",
            "ACL SETUSER lim on nopass -@all +get +set +mget +copy +lpush +multi +exec +discard +ping +client|setname "
            "+client|getname +select|0 +debug|digest +publish +subscribe +psubscribe +ssubscribe +spublish +unsubscribe "
            "+sort +sort_ro +object +hello +acl|whoami %R~r* %W~w* ~rw* resetchannels &news.* &chat",
            "SET r1 a", "SET w1 b", "SET rw1 c", "RPUSH rwl 3 1 2",
        )),
        ("send", "u", cmds(
            "AUTH lim x", "GET r1", "GET w1", "GET rw1", "SET w1 v", "SET r1 v", "SET rw1 v", "SET w1 v GET",
            "MGET r1 rw1 w1", "COPY r1 w2", "COPY w1 r2", "LPUSH w3 a", "DEL r1", "CLIENT SETNAME limc",
            "CLIENT GETNAME", "CLIENT KILL ID 999999", "CLIENT LIST", "CLIENT NOSUCH", "CLIENT", "SELECT 0", "SELECT 1",
            "DEBUG SLEEP 0", "PUBLISH news.a hi", "PUBLISH sport x", "SPUBLISH chat x", "SPUBLISH other x",
            "OBJECT ENCODING r1", "OBJECT ENCODING w1", "OBJECT FREQ rw1", "SORT rwl BY x*", "SORT rwl GET #",
            "SORT_RO rwl", "SORT rwl", "SORT rwl STORE w9", "SORT rwl STORE r9", "ACL WHOAMI", "ACL LIST", "PING",
        )),
        ("send", "u", cmds("MULTI", "GET r1", "SET r1 x", "FLUSHALL", "PUBLISH sport x", "EXEC")),
        ("send", "u", cmds("MULTI", "GET r1", "GET rw1", "PUBLISH news.x m")),
        ("send", "a", cmds("ACL SETUSER lim -get resetchannels &chat")),
        ("send", "u", cmds("EXEC", "GET r1")),
        ("send", "a", cmds("ACL SETUSER lim +get &news.*")),
        ("send", "s", cmds("AUTH lim x", "SUBSCRIBE news.1 chat", "SUBSCRIBE other", "PSUBSCRIBE news.*",
                           "PSUBSCRIBE news.?", "SSUBSCRIBE chat", "SSUBSCRIBE news.2 nope")),
        ("send", "a", cmds("ACL SETUSER lim &extra", "PUBLISH news.1 m1", "SPUBLISH chat m2")),
        ("send", "a", cmds("ACL SETUSER lim resetchannels &chat &news.*", "PUBLISH news.1 m3")),
        ("send", "a", cmds("ACL SETUSER lim resetchannels &chat", "PUBLISH news.1 m4")),
        ("send", "a", cmds(
            "ACL SETUSER sel on nopass -@all (+get ~g*) (+set ~s*) (+hello +ping +acl|whoami)",
            "SET g1 G", "SET s1 S",
        )),
        ("send", "w", cmds("AUTH sel x", "GET g1", "GET s1", "SET s1 v", "SET g1 v", "PING", "MGET g1 s1",
                           "ACL WHOAMI", "INCR g1")),
        ("send", "a", cmds(
            "ACL SETUSER sel (+mget ~g* ~s*)",
        )),
        ("send", "w", cmds("MGET g1 s1", "MGET g1 x1")),
        cleanup("lim", "sel"),
        ("send", "a", cmds("FLUSHALL")),
    ]


def dryrun(proto):
    return [("open", "a")] + hello(proto, "a") + [
        ("send", "a", cmds(
            "ACL SETUSER dr +@all %R~read* %W~write* %RW~rw* resetchannels &chan",
            "ACL DRYRUN dr GET read", "ACL DRYRUN dr GET write", "ACL DRYRUN dr SET write v", "ACL DRYRUN dr SET read v",
            "ACL DRYRUN dr SET rw v GET", "ACL DRYRUN dr COPY read write", "ACL DRYRUN dr COPY write read",
            "ACL DRYRUN dr MIGRATE h p rw 0 500", "ACL DRYRUN dr MIGRATE h p read 0 500",
            "ACL DRYRUN dr MIGRATE h p \"\" 0 5000 KEYS rw read", "ACL DRYRUN dr MIGRATE h p \"\" 0 5000 AUTH KEYS KEYS write",
            "ACL DRYRUN dr SORT read STORE write", "ACL DRYRUN dr SORT read STORE read", "ACL DRYRUN dr SORT read STORE by STORE read2",
            "ACL DRYRUN dr EVAL \"\" 1 rw1", "ACL DRYRUN dr EVAL \"\" 1 read", "ACL DRYRUN dr EVAL_RO \"\" 1 read",
            "ACL DRYRUN dr EVAL \"\" -1 read", "ACL DRYRUN dr GEORADIUS read 1 2 3 M STOREDIST write",
            "ACL DRYRUN dr GEORADIUS read 1 2 3 M STORE write1 STORE read2",
            "ACL DRYRUN dr XREADGROUP GROUP g c STREAMS write2 >", "ACL DRYRUN dr XREADGROUP NOACK GROUP g STREAMS STREAMS read2 >",
            "ACL DRYRUN dr HEXISTS nothing f", "ACL DRYRUN dr SINTERCARD 2 write read", "ACL DRYRUN dr MEMORY USAGE nothing",
            "ACL DRYRUN dr PUBLISH chan m", "ACL DRYRUN dr PUBLISH other m", "ACL DRYRUN dr SUBSCRIBE chan other",
            "ACL DRYRUN dr PSUBSCRIBE chan ch*", "ACL DRYRUN dr SSUBSCRIBE chan", "ACL DRYRUN dr SUNSUBSCRIBE other",
            "ACL DRYRUN dr SPUBLISH other m",
            "ACL SETUSER dr2 -@all +get +client|id +select|0",
            "ACL DRYRUN dr2 SET k v", "ACL DRYRUN dr2 GET k", "ACL DRYRUN dr2 CLIENT ID", "ACL DRYRUN dr2 CLIENT KILL ID 1",
            "ACL DRYRUN dr2 SELECT 0", "ACL DRYRUN dr2 SELECT 1", "ACL DRYRUN dr2 AUTH a b", "ACL DRYRUN dr2 HELLO",
            "ACL DRYRUN nosuch GET k", "ACL DRYRUN dr NOSUCH k", "ACL DRYRUN dr GET", "ACL DRYRUN dr CLIENT",
            "ACL DRYRUN dr CLIENT FOO", "ACL DRYRUN dr CONFIG GET", "ACL DRYRUN dr", "ACL DRYRUN dr CLIENT|ID",
        )),
        cleanup("dr", "dr2"),
    ]


def log_entries(proto):
    return [("open", "a"), ("open", "u")] + hello(proto, "a", "u") + [
        ("send", "a", cmds("ACL LOG RESET", "ACL SETUSER logu on >p +get +multi +exec +discard +publish +client|setname ~k* resetchannels &c")),
        ("send", "u", cmds("AUTH logu p", "CLIENT SETNAME lu", "GET x", "GET x", "SET k v")),
        ("send", "u", cmds("AUTH logu bad", "PUBLISH d m")),
        ("send", "u", cmds("MULTI", "GET y", "DISCARD", "CLIENT ID")),
        ("send", "a", cmds("ACL LOG", "ACL LOG 2", "ACL LOG 0", "ACL LOG -5", "ACL LOG abc", "ACL LOG RESET", "ACL LOG")),
        ("send", "a", cmds("CONFIG SET acllog-max-len 2")),
        ("send", "u", cmds("GET z1", "GET z2", "GET z3")),
        ("send", "a", cmds("ACL LOG", "CONFIG SET acllog-max-len 0")),
        ("send", "u", cmds("GET z4")),
        ("send", "a", cmds("ACL LOG", "CONFIG SET acllog-max-len 128")),
        ("send", "u", cmds("MULTI", "GET k1")),
        ("send", "a", cmds("ACL SETUSER logu -get")),
        ("send", "u", cmds("EXEC")),
        ("send", "a", cmds("ACL LOG 1")),
        cleanup("logu"),
    ]


def requirepass(proto):
    return [("open", "a")] + hello(proto, "a") + [
        ("send", "a", cmds("CONFIG SET requirepass secret", "ACL GETUSER default", "ACL LIST", "CONFIG GET requirepass")),
        ("open", "n"),
        ("send", "n", cmds(
            "PING", "HELLO", "HELLO 3", "HELLO 3 SETNAME x", "HELLO 4", "HELLO x", "CLIENT SETNAME x", "CLIENT FOO",
            "CLIENT", "CONFIG GET", "GET", "NOSUCH", "MULTI",
        )),
    ] + each("n", "AUTH wrong", "AUTH default wrong") + [
        ("send", "n", cmds("AUTH secret", "PING", "RESET", "PING", "AUTH default secret", "ACL WHOAMI", "RESET")),
        ("send", "n", cmds("HELLO " + str(proto) + " AUTH default secret", "PING")),
        ("open", "m"),
        ("send", "m", "*11\r\n"),
        ("open", "l"),
        ("send", "l", "*1\r\n$20000\r\n"),
        ("open", "k"),
        ("send", "k", "*2\r\n$4\r\nAUTH\r\n$16384\r\n" + "x" * 16384 + "\r\n"),
        ("send", "a", cmds("ACL SETUSER default off", "ACL SETUSER default >other", "ACL GETUSER default")),
        ("open", "o"),
    ] + each("o", "PING", "AUTH default secret", "AUTH default other", "PING") + [
        ("send", "a", cmds("ACL SETUSER default on", "CONFIG SET requirepass \"\"", "ACL GETUSER default", "CONFIG GET requirepass")),
        ("open", "p"),
        ("send", "p", cmds("PING", "AUTH x", "ACL WHOAMI")),
        cleanup(),
    ]


def clients(proto):
    return [("open", "a"), ("open", "k1"), ("open", "k2"), ("open", "k3")] + hello(proto, "a") + [
        ("send", "a", cmds("ACL SETUSER killme on nopass +@all ~* &*", "CLIENT SETNAME acl-admin")),
        ("send", "k1", cmds("AUTH killme x", "CLIENT SETNAME acl-k1")),
        ("send", "k2", cmds("AUTH killme x", "CLIENT SETNAME acl-k2")),
        ("send", "k3", cmds("CLIENT SETNAME acl-k3")),
        ("clients", "a", "acl-"),
        ("send", "a", cmds("CLIENT KILL USER nosuch", "CLIENT KILL USER killme SKIPME yes MAXAGE 1000", "CLIENT KILL USER killme SKIPME yes", "CLIENT KILL USER")),
        ("clients", "a", "acl-"),
        ("send", "k3", cmds("AUTH killme x", "ACL DELUSER killme", "PING")),
        ("clients", "a", "acl-"),
        ("send", "a", cmds("ACL SETUSER gone on nopass +@all")),
        ("open", "g"),
        ("send", "g", cmds("AUTH gone x", "CLIENT SETNAME acl-g")),
        ("clients", "a", "acl-"),
        ("clients", "a", "acl-", "ACL DELUSER gone\r\n"),
        ("clients", "a", "acl-"),
        ("send", "a", cmds("ACL SETUSER subs on nopass +@all ~* resetchannels &n1")),
        ("open", "q"),
        ("send", "q", cmds("AUTH subs x", "CLIENT SETNAME acl-q", "SUBSCRIBE n1")),
        ("clients", "a", "acl-", "ACL SETUSER subs resetchannels\r\nPUBLISH n1 m\r\n"),
        ("clients", "a", "acl-"),
        cleanup("subs"),
    ]


def pubsub_default(proto):
    return [("open", "a")] + hello(proto, "a") + [
        ("send", "a", cmds(
            "CONFIG SET acl-pubsub-default allchannels", "ACL SETUSER pd1", "ACL GETUSER pd1", "ACL SETUSER pd1 &x",
            "ACL SETUSER pd2 resetchannels &x", "ACL GETUSER pd2", "ACL SETUSER pd3 resetchannels reset", "ACL GETUSER pd3",
            "ACL SETUSER pd4 (+get)", "ACL GETUSER pd4", "CONFIG SET acl-pubsub-default resetchannels", "ACL SETUSER pd5 reset",
            "ACL GETUSER pd5", "ACL GETUSER pd1", "ACL LIST",
        )),
        ("send", "a", cmds(
            "ACL HELP", "ACL HELP x", "ACL FOO", "ACL", "ACL CAT", "ACL CAT nosuch", "ACL CAT a b", "ACL WHOAMI",
            "ACL WHOAMI x", "ACL USERS", "ACL USERS x", "ACL LIST x", "ACL GETUSER", "ACL GETUSER a b", "ACL GENPASS x",
            "ACL GENPASS 0", "ACL GENPASS -1", "ACL GENPASS 4097", "ACL GENPASS 1 2", "ACL LOAD", "ACL SAVE", "ACL LOAD x",
            "ACL LOG 1 2", "ACL DELUSER", "ACL SETUSER", "acl whoami",
        )),
        ("genpass", "a", "ACL GENPASS"),
        ("genpass", "a", "ACL GENPASS 1"),
        ("genpass", "a", "ACL GENPASS 5"),
        ("genpass", "a", "ACL GENPASS 128"),
        ("genpass", "a", "ACL GENPASS 4096"),
        ("cat", "a", "keyspace"),
        ("cat", "a", "HASH"),
        ("cat", "a", "dangerous"),
        ("cat", "a", "pubsub"),
        ("cat", "a", "scripting"),
        cleanup("pd1", "pd2", "pd3", "pd4", "pd5"),
    ]


def counters(proto):
    fields = ["acl_access_denied_auth", "acl_access_denied_cmd", "acl_access_denied_key", "acl_access_denied_channel",
              "total_error_replies", "errorstat_", "cmdstat_"]
    return [("open", "a"), ("open", "u")] + hello(proto, "a", "u") + [
        ("send", "a", cmds("CONFIG RESETSTAT", "ACL SETUSER cnt on nopass +get +set +subscribe ~k* resetchannels")),
        ("mark", "a"),
    ] + each("u", "AUTH nosuch x", "HELLO 2 AUTH nosuch x") + [
        ("send", "u", cmds("AUTH cnt x", "SET k1 v", "SET x v", "GET k1", "DEL k1", "SUBSCRIBE c", "CLIENT GETNAME",
                           "MULTI", "SET y v", "EXEC")),
        ("info", "a", "stats", fields),
        ("info", "a", "errorstats", fields),
        ("info", "a", "commandstats", fields),
        ("send", "a", cmds("CONFIG SET requirepass pw")),
        ("open", "n"),
        ("send", "n", cmds("GET k", "CLIENT ID", "AUTH pw")),
        ("info", "a", "errorstats", fields),
        ("info", "a", "commandstats", fields),
        ("send", "a", cmds("CONFIG RESETSTAT")),
        ("info", "a", "stats", fields),
        cleanup("cnt"),
        ("send", "a", cmds("CONFIG RESETSTAT")),
    ]


SCENARIOS = [
    ("setuser grammar", grammar),
    ("auth and hello", auth),
    ("permissions", permissions),
    ("dryrun", dryrun),
    ("log entries", log_entries),
    ("requirepass", requirepass),
    ("client filters", clients),
    ("pubsub default and errors", pubsub_default),
    ("counters", counters),
]

port = int(sys.argv[1])
for name, build in SCENARIOS:
    for proto in (2, 3):
        print("%s\t%d\t%s" % (name, proto, run(port, build(proto))))
PY
)"

expect_same_acl() {
	local mine theirs name proto want got n=0
	mine="$(python3 -I -c "$ACL_CASES_PY" "$PORT" 2>&1)"
	theirs="$(python3 -I -c "$ACL_CASES_PY" "$REF_PORT" 2>&1)"
	while IFS=$'\t' read -r name proto want; do
		n=$((n + 1))
		got="$(printf '%s\n' "$mine" | awk -F'\t' -v n="$name" -v p="$proto" '$1 == n && $2 == p { print $3 }')"
		if [ -n "$want" ] && [ "$got" == "$want" ]; then
			pass
		else
			fail "$(proto_label "acl raw socket bytes for $name" "$proto") differ from redis" "${want:0:400}" "${got:0:400}"
		fi
	done <<<"$theirs"
	if [ "$n" -ne 18 ]; then
		fail "acl raw socket scenarios ran" "18 scenarios" "$n"
	fi
}

acl_cli() {
	docker exec -i "$CLI_CONTAINER" redis-cli -p "$1" "${@:2}" 2>&1
}

acl_wait() {
	local _
	ACL_WAIT_LAST=""
	for _ in $(seq 1 50); do
		ACL_WAIT_LAST="$(docker exec "$CLI_CONTAINER" redis-cli -p "$1" "${@:2}" ping 2>&1)"
		[ "$ACL_WAIT_LAST" == "PONG" ] && return 0
		sleep 0.1
	done
	return 1
}

acl_pair_ready() {
	local phase="$1" jport="$2" rport="$3" jpid="$4" name="$5" startup="$6" launched="$7"
	shift 7
	local jready=0 rready=0 jlast="not checked" rlast="reference launch failed" diagnostics process_state="exited" reference_running
	if acl_wait "$jport" "$@"; then jready=1; fi
	jlast="$ACL_WAIT_LAST"
	if [ "$launched" -eq 1 ]; then
		if acl_wait "$rport" "$@"; then rready=1; fi
		rlast="$ACL_WAIT_LAST"
	fi
	if kill -0 "$jpid" 2>/dev/null; then process_state="running"; fi
	reference_running="$(docker inspect --format '{{.State.Running}}' "$name" 2>&1)"
	if [ "$jready" -eq 1 ] && [ "$rready" -eq 1 ] && [ "$process_state" == "running" ] && [ "$reference_running" == "true" ]; then
		return 0
	fi
	docker logs --tail 80 "$name" >"$startup.redis.log" 2>&1
	docker inspect --format '{{json .State}}' "$name" >"$startup.state.log" 2>&1
	diagnostics="$(
		printf 'Eski port=%s pid=%s state=%s PING=%s\n' "$jport" "$jpid" "$process_state" "$jlast"
		printf 'Reference port=%s container=%s launch=%s running=%s PING=%s\n' "$rport" "$name" "$launched" "$reference_running" "$rlast"
		printf 'Reference launch output:\n'
		tail -n 20 "$startup.run.log"
		printf 'Reference state:\n'
		cat "$startup.state.log"
		printf 'Reference startup log:\n'
		cat "$startup.redis.log"
		printf 'Eski startup log:\n'
		tail -n 80 "$startup.eski.log"
	)"
	fail "ACL $phase setup" "Eski and reference both ready with PONG" "$diagnostics"
	return 1
}

acl_stop_pair() {
	kill "$1" 2>/dev/null
	wait "$1" 2>/dev/null
	ACL_SERVER_PID=""
	cat "$3.eski.log" >>"$LOG"
	docker rm -f "$2" >/dev/null 2>&1
}

acl_same() {
	local name="$1" want="$2" got="$3" line
	if [ -n "$want" ] && [ "$got" == "$want" ]; then
		pass
		return
	fi
	line="$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 6 | tr '\n' ' ')"
	fail "$name differs from redis: $line" "${want:0:300}" "${got:0:300}"
}

acl_log_tail() {
	tail -n "$1" | sed 's/^[0-9]*:[A-Z] [^#*]* [#*] //'
}

acl_eski_wording() {
	sed -e 's/^Aborting Redis startup because of ACL errors: /Aborting Eski startup because of ACL errors: /' \
		-e 's/^Configuring Redis with users defined in redis\.conf and at the same setting an ACL file path is invalid\. This setup is very likely to lead to configuration errors and security holes, please define either an ACL file or declare users directly in your redis\.conf, but not both\.$/Configuring Eski with users defined in the configuration file and at the same time an ACL file path is invalid. This setup is very likely to lead to configuration errors and security holes, please define either an ACL file or declare users directly in your configuration file, but not both./'
}

expect_acl_files() {
	local jport="$((REF_PORT + 4))" rport="$((REF_PORT + 5))" adir="$PERSIST_DIR/acl" jpid name="$ACL_REF_CONTAINER" hash feed got want content args startup launched
	mkdir -p "$adir/eski" "$adir/ref"
	hash="$(printf 'alicepw' | sha256sum | cut -d' ' -f1)"
	printf 'user alice on #%s ~a* &chan -@all +get +set\nuser bob off nopass resetchannels (+get ~b*) (+set %%W~w*)\nuser default on nopass ~* &* +@all\n' "$hash" >"$adir/eski/users.acl"
	cp "$adir/eski/users.acl" "$adir/ref/users.acl"
	startup="$adir/acl-file-startup"
	"$BINARY" --port "$jport" --dir "$adir/eski" --aclfile users.acl >"$startup.eski.log" 2>&1 &
	jpid=$!
	ACL_SERVER_PID="$jpid"
	launched=0
	if docker run -d --name "$name" --network=host --user "$(id -u):$(id -g)" -v "$adir/ref:/data" "$IMAGE" redis-server --port "$rport" --dir /data --aclfile users.acl --save "" --appendonly no >"$startup.run.log" 2>&1; then launched=1; fi
	if ! acl_pair_ready "ACL file" "$jport" "$rport" "$jpid" "$name" "$startup" "$launched"; then
		acl_stop_pair "$jpid" "$name" "$startup"
		return
	fi
	feed=$'ACL LIST\nACL USERS\nAUTH alice alicepw\nACL WHOAMI\nGET a1\nGET b1\nAUTH default x\nACL SETUSER carol on >c (+get ~x*) %R~r* resetchannels &ch\nACL SETUSER dave skip-sanitize-payload +@all -@dangerous ~*\nACL DELUSER bob\nACL SAVE\nACL LIST'
	acl_same "acl file load, setuser and save replies" "$(printf '%s\n' "$feed" | acl_cli "$rport")" "$(printf '%s\n' "$feed" | acl_cli "$jport")"
	acl_same "ACL SAVE file contents" "$(cat "$adir/ref/users.acl")" "$(cat "$adir/eski/users.acl")"
	printf 'ACL SETUSER erin on nopass %%RW~e* &e* +@hash (+ping)\nACL SAVE\n' | acl_cli "$jport" >/dev/null
	cp "$adir/eski/users.acl" "$adir/ref/users.acl"
	acl_same "redis loads an ACL file saved by eski" "OK"$'\n'"$(printf 'ACL LIST\n' | acl_cli "$jport")" "$(printf 'ACL LOAD\nACL LIST\n' | acl_cli "$rport")"
	printf 'ACL SETUSER frank on >f ~f* resetchannels -@all +@string (%%R~g* +get)\nACL DELUSER carol\nACL SAVE\n' | acl_cli "$rport" >/dev/null
	cp "$adir/ref/users.acl" "$adir/eski/users.acl"
	acl_same "eski loads an ACL file saved by redis" "OK"$'\n'"$(printf 'ACL LIST\n' | acl_cli "$rport")" "$(printf 'ACL LOAD\nACL LIST\n' | acl_cli "$jport")"
	for content in 'user alice on\nfoo bar\nuser default on nopass ~* &* +@all\n' 'user alice on\nuser alice off\n' \
		'user alice on +nocmd +nocmd2 badrule badrule2\n' 'user alice on badrule +nocmd\n' 'user alice on "unbalanced\n' 'user\n' \
		'\n\n   \nuser alice on\nuser default on nopass ~* &* +@all\n' '# comment\nuser alice on\n' 'user  alice  on\n' 'USER alice on\n' \
		'user a\tb on\n' 'user alice on ~* ~x\n' 'user alice on &* &x\n' 'user alice on <nopw\n' 'user alice on #abc\n' \
		'user alice on +config|get|x\n' 'user alice on >p\tq\r\nuser default on nopass ~* &* +@all\r\n'; do
		printf "$content" >"$adir/eski/users.acl"
		printf "$content" >"$adir/ref/users.acl"
		acl_same "ACL LOAD of $(printf '%q' "$content")" "$(printf 'ACL LOAD\nACL USERS\n' | acl_cli "$rport")" "$(printf 'ACL LOAD\nACL USERS\n' | acl_cli "$jport")"
	done
	rm -f "$adir/eski/users.acl" "$adir/ref/users.acl"
	acl_same "ACL LOAD of a missing file" "$(printf 'ACL LOAD\n' | acl_cli "$rport")" "$(printf 'ACL LOAD\n' | acl_cli "$jport")"
	acl_stop_pair "$jpid" "$name" "$startup"
	printf 'requirepass secret\nuser dave on >pw ~d* +@read\nuser eve off nopass (+get ~e*)\n' >"$adir/eski/acl.conf"
	cp "$adir/eski/acl.conf" "$adir/ref/acl.conf"
	startup="$adir/acl-config-startup"
	"$BINARY" "$adir/eski/acl.conf" --port "$jport" --dir "$adir/eski" >"$startup.eski.log" 2>&1 &
	jpid=$!
	ACL_SERVER_PID="$jpid"
	launched=0
	if docker run -d --name "$name" --network=host --user "$(id -u):$(id -g)" -v "$adir/ref:/data" "$IMAGE" redis-server /data/acl.conf --port "$rport" --dir /data --save "" --appendonly no >"$startup.run.log" 2>&1; then launched=1; fi
	if ! acl_pair_ready "configuration file" "$jport" "$rport" "$jpid" "$name" "$startup" "$launched" -a secret --no-auth-warning; then
		acl_stop_pair "$jpid" "$name" "$startup"
		return
	fi
	feed=$'PING\nAUTH dave pw\nACL WHOAMI\nAUTH secret\nACL LIST\nACL SETUSER fred on >x +ping\nCONFIG SET requirepass other\nACL LIST\nCONFIG REWRITE\nACL GETUSER default'
	acl_same "users from a configuration file" "$(printf '%s\n' "$feed" | acl_cli "$rport")" "$(printf '%s\n' "$feed" | acl_cli "$jport")"
	acl_same "CONFIG REWRITE user and requirepass lines" "$(grep -E '^(user|requirepass) ' "$adir/ref/acl.conf")" "$(grep -E '^(user|requirepass) ' "$adir/eski/acl.conf")"
	acl_stop_pair "$jpid" "$name" "$startup"
	printf 'user alice on +nocmd\n' >"$adir/eski/bad.acl"
	cp "$adir/eski/bad.acl" "$adir/ref/bad.acl"
	for args in "3|--user foo on badrule" "3|--user foo on --user foo off" "3|--user default on --user default off" "3|--user foo (on" "3|--user" "2|--user foo on +nocmd" "1|--aclfile bad.acl" "1|--aclfile bad.acl --user foo on" "1|--aclfile nofile.acl"; do
		got="$(timeout 5 "$BINARY" --port "$jport" --dir "$adir/eski" ${args#*|} 2>&1 | acl_log_tail "${args%%|*}")"
		want="$(timeout 20 docker run --rm --network=none --user "$(id -u):$(id -g)" -v "$adir/ref:/data" "$IMAGE" redis-server --port 0 --dir /data ${args#*|} 2>&1 | grep -v 'Configured to not listen anywhere' | acl_log_tail "${args%%|*}" | acl_eski_wording)"
		acl_same "startup with ${args#*|}" "$want" "$got"
	done
}

CONFIG_PY="$(cat <<'PY'
import socket
import sys

ESKI = int(sys.argv[1])
REF = int(sys.argv[2])
MASKED = {"port", "dir", "bind"}
COMPUTE_DEFAULTS = {"compute-threads": b"0", "compute-max-memory": b"134217728"}
COMPUTE_INFO = ("compute_threads_configured", "compute_threads_active", "compute_jobs_pending", "compute_memory_reserved",
                "compute_jobs_submitted", "compute_jobs_completed", "compute_jobs_cancelled", "compute_sync_fallbacks", "compute_worker_nanoseconds")
KEYSPACE_DEFAULTS = {"keyspace-threads": str(int(sys.argv[4])).encode(), "keyspace-max-memory": b"134217728"}
LUA_DEFAULTS = {"lua-max-memory": b"9223372036854775807", "lua-max-output": b"536870912",
                "lua-max-bridge-memory": b"9223372036854775807", "lua-max-cache-memory": b"9223372036854775807"}
KEYSPACE_INFO = ("keyspace_threads_configured", "keyspace_threads_active", "keyspace_jobs_pending", "keyspace_memory_used",
                 "keyspace_records", "keyspace_jobs_submitted", "keyspace_jobs_completed", "keyspace_gets", "keyspace_sets",
                 "keyspace_sync_fallbacks", "keyspace_barriers", "keyspace_worker_nanoseconds")
SKIP_SET = {"port", "dir", "bind", "requirepass", "masterauth", "tls-cluster", "tls-replication"}
PROBES = ["abc", "-1", "-9223372036854775808", "9223372036854775807", "18446744073709551615",
          "99999999999999999999", "", "1%", "-5%", "0", "1k", "1kb", "yes", "no", "100 10", "normal 1 2 3"]
HIDDEN = ["use-exit-on-panic", "aof-disable-auto-gc", "rdb-key-save-delay", "key-load-delay",
          "watchdog-period", "loading-process-events-interval-bytes", "cluster-ping-interval"]
PATTERNS = [["*"], ["*max*"], ["maxmemory*"], ["*of"], ["hash-*"], ["?z"], ["[a-c]*"], ["*ziplist*"],
            ["list-*"], ["nonexistent"], ["MAXMEMORY"], ["maxmemory", "MAXMEMORY"],
            ["maxmemory", "maxmemory*", "bind", "*of"], ["*", "maxmemory"], ["slave*"], ["*-*-*-*"],
            ["\\*"], ["[^a]*"], ["*lazy*"], ["tls-*"], ["cluster-*"], ["*cpulist"], ["*_*"],
            ["lua-max-*"], ["LUA-MAX-*"]]


class Conn:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.buf = b""

    def fill(self):
        d = self.s.recv(65536)
        if not d:
            raise EOFError
        self.buf += d

    def line(self):
        while b"\r\n" not in self.buf:
            self.fill()
        l, self.buf = self.buf.split(b"\r\n", 1)
        return l

    def take(self, n):
        while len(self.buf) < n + 2:
            self.fill()
        d, self.buf = self.buf[:n], self.buf[n + 2:]
        return d

    def read(self):
        l = self.line()
        t, rest = l[:1], l[1:]
        if t == b"$":
            n = int(rest)
            return None if n < 0 else self.take(n)
        if t == b"*":
            n = int(rest)
            return None if n < 0 else [self.read() for _ in range(n)]
        return l

    def cmd(self, *args):
        out = [b"*%d\r\n" % len(args)]
        for a in args:
            a = a if isinstance(a, bytes) else str(a).encode()
            out.append(b"$%d\r\n%s\r\n" % (len(a), a))
        self.s.sendall(b"".join(out))
        return self.read()


def as_dict(reply):
    if not isinstance(reply, list):
        return reply
    d = {}
    for i in range(0, len(reply), 2):
        k = reply[i].decode()
        d[k] = "<masked>" if k.lower() in MASKED else reply[i + 1]
    return (len(reply), d)


def allocator(conn):
    fields = [line.split(b":", 1) for line in conn.cmd("info", "memory").splitlines() if b":" in line]
    values = [value for key, value in fields if key == b"mem_allocator"]
    return values[0] if len(values) == 1 else None


j, r = Conn(ESKI), Conn(REF)
failures = []
checks = 0
allocator_j, allocator_r = allocator(j), allocator(r)
allocator_difference = allocator_j == b"libc" and isinstance(allocator_r, bytes) and allocator_r.startswith(b"jemalloc-")
checks += 1
if not allocator_difference:
    failures.append("allocator capability fixture: expected Eski libc and Redis jemalloc, observed %r and %r" % (allocator_j, allocator_r))
compute_config = {}
for name, default in (COMPUTE_DEFAULTS | KEYSPACE_DEFAULTS | LUA_DEFAULTS).items():
    checks += 1
    actual = j.cmd("config", "get", name)
    if not isinstance(actual, list) or len(actual) != 2 or actual[0] != name.encode() or not isinstance(actual[1], bytes) or not actual[1].isdigit():
        failures.append("Eski CONFIG GET %s has invalid metadata: %r" % (name, actual))
        continue
    compute_config[name] = int(actual[1])
    if (sys.argv[3] != "1" or name == "keyspace-threads" or name in LUA_DEFAULTS) and actual[1] != default:
        failures.append("Eski CONFIG GET %s default: expected %r observed %r" % (name, default, actual[1]))
for name, default in LUA_DEFAULTS.items():
    checks += 1
    actual = j.cmd("config", "get", name.upper())
    if actual != [name.upper().encode(), default]:
        failures.append("Eski exact uppercase CONFIG GET %s: expected %r observed %r" % (name, default, actual))
server_fields = [line.split(b":", 1) for line in j.cmd("info", "server").splitlines() if b":" in line]
for name in COMPUTE_INFO + KEYSPACE_INFO:
    checks += 1
    values = [value for key, value in server_fields if key == name.encode()]
    if len(values) != 1 or not values[0].isdigit():
        failures.append("Eski INFO %s must occur once with a nonnegative integer: %r" % (name, values))
    elif name == "compute_threads_configured" and int(values[0]) != compute_config.get("compute-threads"):
        failures.append("Eski INFO compute_threads_configured disagrees with CONFIG GET compute-threads")
    elif name == "keyspace_threads_configured" and int(values[0]) != compute_config.get("keyspace-threads"):
        failures.append("Eski INFO keyspace_threads_configured disagrees with CONFIG GET keyspace-threads")
names = sorted(as_dict(r.cmd("config", "get", "*"))[1].keys())
for pat in PATTERNS + [[n] for n in names] + [[n.upper()] for n in names[:20]] + [[h] for h in HIDDEN]:
    checks += 1
    a, b = as_dict(j.cmd("config", "get", *pat)), as_dict(r.cmd("config", "get", *pat))
    if a != b:
        failures.append("CONFIG GET %s: eski %r redis %r" % (" ".join(pat), a, b))
for n in names:
    if n in SKIP_SET:
        continue
    cur_j = j.cmd("config", "get", n)[1]
    cur_r = r.cmd("config", "get", n)[1]
    if cur_j != cur_r:
        failures.append("CONFIG GET %s before probing: eski %r redis %r" % (n, cur_j, cur_r))
        continue
    for v in [cur_r] + PROBES:
        checks += 1
        try:
            a, b = j.cmd("config", "set", n, v), r.cmd("config", "set", n, v)
            ga, gb = j.cmd("config", "get", n), r.cmd("config", "get", n)
            if allocator_difference and n == "activedefrag" and v == "yes":
                expected = b"-ERR CONFIG SET failed (possibly related to argument 'activedefrag') - Active defragmentation cannot be enabled: this build uses libc without allocator relocation support."
                if a != expected or b != b"+OK":
                    failures.append("CONFIG SET activedefrag yes allocator capability: eski %r redis %r" % (a, b))
                if ga != [b"activedefrag", b"no"] or gb != [b"activedefrag", b"yes"]:
                    failures.append("CONFIG GET activedefrag after allocator-specific SET: eski %r redis %r" % (ga, gb))
            else:
                if a != b:
                    failures.append("CONFIG SET %s %r: eski %r redis %r" % (n, v, a, b))
                if ga != gb:
                    failures.append("CONFIG GET %s after SET %r: eski %r redis %r" % (n, v, ga, gb))
        finally:
            try:
                j.cmd("config", "set", n, cur_j)
            finally:
                r.cmd("config", "set", n, cur_r)
        restored_j, restored_r = j.cmd("config", "get", n), r.cmd("config", "get", n)
        if restored_j != [n.encode(), cur_j] or restored_r != [n.encode(), cur_r]:
            failures.append("CONFIG GET %s after restoring both fixtures: eski %r redis %r" % (n, restored_j, restored_r))
final_j, final_r = as_dict(j.cmd("config", "get", "*")), as_dict(r.cmd("config", "get", "*"))
checks += 1
if final_j != final_r:
    failures.append("CONFIG GET * after probing differs")
for f in failures[:20]:
    print(f)
print("checks %d failures %d" % (checks, len(failures)))
sys.exit(1 if failures else 0)
PY
)"

expect_config_parity() {
	local got
	got="$(timeout 300 python3 -I -c "$CONFIG_PY" "$PORT" "$REF_PORT" "$EXTERNAL" "$KEYSPACE_THREADS" 2>&1)"
	if [ $? -eq 0 ]; then pass; else fail "CONFIG GET and SET of every parameter match redis" "no differences" "$got"; fi
}

config_conf_value() {
	docker exec "$CLI_CONTAINER" redis-cli -p "$1" config get '*' 2>&1 | paste - - | awk -F '\t' '$1 != "port" && $1 != "dir" && $1 != "bind"' | LC_ALL=C sort
}

expect_config_files() {
	local cport="$((REF_PORT + 2))" rport="$((REF_PORT + 3))" cdir="$PERSIST_DIR/conf" cpid got want
	local name="eski-smoke-conf-$$"
	mkdir -p "$cdir/eski" "$cdir/ref"
	printf '# written by the smoke test\nport %s\n\nmaxmemory 100mb\nsave 900 1\nsave 300 10\nhash-max-ziplist-entries 20\nrename-command flushdb badger\ninclude %s\n' "$cport" "$cdir/eski/inc.conf" >"$cdir/eski/eski.conf"
	printf 'hz 20\n' >"$cdir/eski/inc.conf"
	"$BINARY" "$cdir/eski/eski.conf" --dir "$cdir/eski" >>"$LOG" 2>&1 &
	cpid=$!
	for _ in $(seq 1 50); do
		[ "$(docker exec "$CLI_CONTAINER" redis-cli -p "$cport" ping 2>&1)" == "PONG" ] && break
		sleep 0.1
	done
	got="$(printf 'CONFIG GET hz\nCONFIG GET save\nCONFIG GET hash-max-listpack-entries\nFLUSHDB\nBADGER\nDEBUG HELP\nCONFIG SET maxmemory 200mb notify-keyspace-events KEA hz 50\nCONFIG SET client-output-buffer-limit "normal 1mb 2kb 3"\nCONFIG SET maxmemory-clients 5%%\nCONFIG SET save "100 1 200 2"\nCONFIG SET latency-tracking-info-percentiles ""\nCONFIG SET shutdown-on-sigint "nosave now"\nCONFIG SET bind "127.0.0.1 -::1"\nCONFIG REWRITE\n' | docker exec -i "$CLI_CONTAINER" redis-cli -p "$cport" 2>&1)"
	want="$(printf 'hz\n20\nsave\n900 1 300 10\nhash-max-listpack-entries\n20\nERR unknown command '"'"'FLUSHDB'"'"', with args beginning with: \n\nOK\nERR DEBUG command not allowed. If the enable-debug-command option is set to "local", you can run it from a local connection, otherwise you need to set this option in the configuration file, and then restart the server.\n\nOK\nOK\nOK\nOK\nOK\nOK\nOK\nOK')"
	if [ "$got" == "$want" ]; then pass; else fail "config file, include, rename-command and CONFIG REWRITE in eski" "$want" "$got"; fi
	got="$(sed -n '1,9p' "$cdir/eski/eski.conf")"
	want="$(printf '# written by the smoke test\nport %s\n\nmaxmemory 200mb\nsave 100 1\nsave 200 2\nhash-max-listpack-entries 20\nrename-command flushdb badger\ninclude %s' "$cport" "$cdir/eski/inc.conf")"
	if [ "$got" == "$want" ]; then pass; else fail "CONFIG REWRITE keeps comments, order and rewrites in place" "$want" "$got"; fi
	jconf="$(config_conf_value "$cport")"
	kill "$cpid" 2>/dev/null
	wait "$cpid" 2>/dev/null
	sed -i -e '/^include /d' -e '/^rename-command /d' -e '/^dir /d' "$cdir/eski/eski.conf"
	cp "$cdir/eski/eski.conf" "$cdir/ref/from-eski.conf"
	if docker run -d --rm --name "$name" --network=host --user "$(id -u):$(id -g)" -v "$cdir/ref:/data" "$IMAGE" redis-server /data/from-eski.conf --port "$rport" --dir /data --protected-mode yes >/dev/null; then
		for _ in $(seq 1 50); do
			[ "$(docker exec "$CLI_CONTAINER" redis-cli -p "$rport" ping 2>&1)" == "PONG" ] && break
			sleep 0.1
		done
		got="$(config_conf_value "$rport")"
		if [ "$got" == "$jconf" ]; then pass; else fail "a configuration file written by eski loads in redis with the same CONFIG GET" "$jconf" "$(diff <(printf '%s\n' "$jconf") <(printf '%s\n' "$got") | head -n 8)"; fi
		printf 'CONFIG SET maxmemory 300mb tracking-table-max-keys 7 list-max-listpack-size -3\nCONFIG SET client-output-buffer-limit "pubsub 2mb 1mb 30"\nCONFIG SET save ""\nCONFIG SET appendfsync no\nCONFIG REWRITE\n' | docker exec -i "$CLI_CONTAINER" redis-cli -p "$rport" >/dev/null 2>&1
		want="$(config_conf_value "$rport")"
		docker rm -f "$name" >/dev/null 2>&1
		sed -i '/^dir /d' "$cdir/ref/from-eski.conf"
		"$BINARY" "$cdir/ref/from-eski.conf" --port "$cport" --dir "$cdir/eski" >>"$LOG" 2>&1 &
		cpid=$!
		for _ in $(seq 1 50); do
			[ "$(docker exec "$CLI_CONTAINER" redis-cli -p "$cport" ping 2>&1)" == "PONG" ] && break
			sleep 0.1
		done
		got="$(config_conf_value "$cport")"
		if [ "$got" == "$want" ]; then pass; else fail "a configuration file written by redis loads in eski with the same CONFIG GET" "$want" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 8)"; fi
		kill "$cpid" 2>/dev/null
		wait "$cpid" 2>/dev/null
	else
		fail "reference Redis with a configuration file" "container started" "docker run failed"
	fi
}

COMMAND_PY="$(cat <<'PY'
import random
import socket
import sys

ESKI = int(sys.argv[1])
REF = int(sys.argv[2])
CATEGORIES = ["keyspace", "read", "write", "set", "sortedset", "list", "hash", "string", "bitmap", "hyperloglog",
              "geo", "stream", "pubsub", "admin", "fast", "slow", "blocking", "dangerous", "connection",
              "transaction", "scripting", "READ", "SortedSet", "@read", "nosuch", ""]
PATTERNS = ["*", "set", "get", "config*", "config|*re*", "cl*help", "x*", "*|*", "*|help", "Z*", "XINFO|*", "?et",
            "[a-c]*", "h*expire*", "*-*", "*_*", "non_exists", "non_exists*", "", "\\*", "[^a-y]*"]
POOL = ["k1", "k2", "k3", "2", "1", "0", "3", "-1", "01", "+1", "2x", " 1", "4294967297", "99999999999999999999",
        "store", "STOREDIST", "storedist", "streams", "STREAMS", "keys", "KEYS", "get", "GET", "by", "limit",
        "auth", "auth2", "count", "block", "group", "noack", "set", "incrby", "overflow", "$", "", "copy",
        "replace", "u8", "left", "withscores", "weights", "aggregate", "ex", "nx"]


class Conn:
    def __init__(self, port, proto):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.buf = b""
        if proto == 3:
            self.cmd("HELLO", "3")

    def fill(self):
        d = self.s.recv(1 << 20)
        if not d:
            raise EOFError
        self.buf += d

    def line(self):
        while b"\r\n" not in self.buf:
            self.fill()
        l, self.buf = self.buf.split(b"\r\n", 1)
        return l

    def take(self, n):
        while len(self.buf) < n + 2:
            self.fill()
        d, self.buf = self.buf[:n], self.buf[n + 2:]
        return d

    def read(self):
        l = self.line()
        t, rest = l[:1].decode(), l[1:]
        if t in "$=!":
            n = int(rest)
            return ("_", None) if n < 0 else (t, self.take(n))
        if t in "*~>":
            n = int(rest)
            return ("_", None) if n < 0 else (t, [self.read() for _ in range(n)])
        if t in "%|":
            return (t, [(self.read(), self.read()) for _ in range(int(rest))])
        return (t, rest)

    def cmd(self, *args):
        self.raw_start = len(self.buf)
        out = [b"*%d\r\n" % len(args)]
        for a in args:
            a = a if isinstance(a, bytes) else str(a).encode()
            out.append(b"$%d\r\n%s\r\n" % (len(a), a))
        self.s.sendall(b"".join(out))
        return self.read()


def ser(t):
    k, v = t
    if k == "_":
        return b"_\r\n"
    if k in "$=!":
        return b"%s%d\r\n%s\r\n" % (k.encode(), len(v), v)
    if k in "*~>":
        return b"%s%d\r\n" % (k.encode(), len(v)) + b"".join(ser(x) for x in v)
    if k in "%|":
        return b"%s%d\r\n" % (k.encode(), len(v)) + b"".join(ser(a) + ser(b) for a, b in v)
    return k.encode() + v + b"\r\n"


def canon_info(t):
    if t[0] != "*" or len(t[1]) != 10:
        return t
    items = list(t[1])
    items[9] = (items[9][0], sorted([canon_info(x) for x in items[9][1]], key=lambda x: x[1][0][1]))
    return ("*", items)


def pairs_of(t):
    if t[0] == "%":
        return list(t[1])
    return [(t[1][i], t[1][i + 1]) for i in range(0, len(t[1]), 2)]


def from_pairs(kind, pairs):
    if kind == "%":
        return ("%", pairs)
    return ("*", [x for p in pairs for x in p])


def canon_docs(t):
    if t[0] not in "%*":
        return t
    out = []
    for a, b in pairs_of(t):
        if a[1] == b"subcommands":
            b = from_pairs(b[0], sorted([(x, canon_docs(y)) for x, y in pairs_of(b)], key=lambda p: p[0][1]))
        out.append((a, b))
    return from_pairs(t[0], out)


def canon_reply(t):
    return from_pairs(t[0], [(x, canon_docs(y)) for x, y in pairs_of(t)])


def names_of(t):
    return [x[1].decode() for x in t[1]]


failures = []
checks = 0


def check(ok, msg):
    global checks
    checks += 1
    if not ok:
        failures.append(msg)


def run(proto):
    j, r = Conn(ESKI, proto), Conn(REF, proto)
    jl = names_of(j.cmd("COMMAND", "LIST"))
    rl = names_of(r.cmd("COMMAND", "LIST"))
    check(jl, "resp%d COMMAND LIST is empty" % proto)
    if not jl:
        return
    check(len(jl) == len(set(jl)), "resp%d COMMAND LIST has duplicates" % proto)
    check(set(jl) <= set(rl), "resp%d COMMAND LIST names redis lacks: %s" % (proto, sorted(set(jl) - set(rl))))
    top = [n for n in jl if "|" not in n]
    for n in top:
        subs_j = sorted(x for x in jl if x.startswith(n + "|"))
        subs_r = sorted(x for x in rl if x.startswith(n + "|"))
        check(subs_j == subs_r, "resp%d subcommands of %s: eski %s redis %s" % (proto, n, subs_j, subs_r))
    count = j.cmd("COMMAND", "COUNT")
    check(count == (":", str(len(top)).encode()), "resp%d COMMAND COUNT %r for %d commands" % (proto, count, len(top)))
    for n in jl:
        a, b = j.cmd("COMMAND", "INFO", n), r.cmd("COMMAND", "INFO", n)
        check(ser(canon_info(a[1][0])) == ser(canon_info(b[1][0])), "resp%d COMMAND INFO %s differs" % (proto, n))
        a, b = j.cmd("COMMAND", "DOCS", n), r.cmd("COMMAND", "DOCS", n)
        check(ser(canon_reply(a)) == ser(canon_reply(b)), "resp%d COMMAND DOCS %s differs" % (proto, n))
    for args in (["COMMAND"], ["COMMAND", "INFO"]):
        a, b = j.cmd(*args), r.cmd(*args)
        ra = dict((x[1][0][1].decode(), ser(canon_info(x))) for x in a[1])
        rb = dict((x[1][0][1].decode(), ser(canon_info(x))) for x in b[1])
        check(len(a[1]) == len(top) and sorted(ra) == sorted(top), "resp%d %s lists other commands" % (proto, " ".join(args)))
        bad = [n for n in ra if ra[n] != rb.get(n)]
        check(not bad, "resp%d %s entries differ: %s" % (proto, " ".join(args), bad[:10]))
    a, b = j.cmd("COMMAND", "DOCS"), r.cmd("COMMAND", "DOCS")
    da = dict((x[1].decode(), ser(canon_docs(y))) for x, y in pairs_of(a))
    db = dict((x[1].decode(), ser(canon_docs(y))) for x, y in pairs_of(b))
    check(sorted(da) == sorted(top), "resp%d COMMAND DOCS lists other commands" % proto)
    bad = [n for n in da if da[n] != db.get(n)]
    check(not bad, "resp%d COMMAND DOCS entries differ: %s" % (proto, bad[:10]))
    mixed = ["get", "nosuch", "CONFIG|GET", "client|LIST", "get|key", "config|get|key", "", "Set", "xinfo|help"]
    a, b = j.cmd("COMMAND", "INFO", *mixed), r.cmd("COMMAND", "INFO", *mixed)
    check(ser(("*", [canon_info(x) for x in a[1]])) == ser(("*", [canon_info(x) for x in b[1]])), "resp%d COMMAND INFO of several names differs" % proto)
    a, b = j.cmd("COMMAND", "DOCS", *mixed), r.cmd("COMMAND", "DOCS", *mixed)
    check(ser(canon_reply(a)) == ser(canon_reply(b)), "resp%d COMMAND DOCS of several names differs" % proto)
    for kind, values in (("ACLCAT", CATEGORIES), ("PATTERN", PATTERNS), ("MODULE", ["nosuch", ""])):
        for v in values:
            fa = names_of(j.cmd("COMMAND", "LIST", "FILTERBY", kind, v))
            fb = names_of(r.cmd("COMMAND", "LIST", "FILTERBY", kind, v))
            want = sorted(set(fb) & set(jl))
            check(sorted(fa) == want, "resp%d COMMAND LIST FILTERBY %s %r: eski %s redis %s" % (proto, kind, v, sorted(fa)[:8], want[:8]))
    rnd = random.Random(52 + proto)
    for _ in range(3000):
        name = rnd.choice(jl)
        args = name.split("|") + [rnd.choice(POOL) for _ in range(rnd.randint(0, 9))]
        if rnd.random() < 0.1:
            args = [x.upper() for x in args]
        sub = rnd.choice(["GETKEYS", "GETKEYSANDFLAGS"])
        a, b = ser(j.cmd("COMMAND", sub, *args)), ser(r.cmd("COMMAND", sub, *args))
        check(a == b, "resp%d COMMAND %s %s: eski %r redis %r" % (proto, sub, " ".join(args), a[:80], b[:80]))

for proto in (2, 3):
    try:
        run(proto)
    except Exception as e:
        failures.append("resp%d stopped: %r" % (proto, e))
for f in failures[:20]:
    print(f)
print("checks %d failures %d" % (checks, len(failures)))
sys.exit(1 if failures else 0)
PY
)"

expect_command_parity() {
	local got
	got="$(timeout 300 python3 -I -c "$COMMAND_PY" "$PORT" "$REF_PORT" 2>&1)"
	if [ $? -eq 0 ]; then pass; else fail "COMMAND INFO, DOCS, LIST, COUNT and GETKEYS of every command match redis" "no differences" "$got"; fi
}

expect_transaction_stress() {
	local port got
	for port in "$PORT" "$REF_PORT"; do
		got="$(timeout 150 python3 -I -c "$TX_STRESS_PY" "$port" 2>&1)"
		if [[ "$got" == ok\ * ]]; then pass; else fail "watchers and writers on port $port never commit a stale read" "ok" "$got"; fi
	done
}

info_fields() {
	docker exec "$CLI_CONTAINER" redis-cli -p "$1" info "$2" 2>&1 | tr -d '\r' | awk -F: -v keep=" ${3:-} " -v only="${4:-}" '$1 !~ only { next } index(keep, " " $1 " ") { print; next } { print $1 }'
}

expect_same_info() {
	local name="$1" got want line
	got="$(info_fields "$PORT" "${@:2}")"
	want="$(info_fields "$REF_PORT" "${@:2}")"
	if [ -n "$want" ] && [ "$got" == "$want" ]; then
		pass
		return
	fi
	line="$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 6 | tr '\n' ' ')"
	fail "$name differs from redis: $line" "${want:0:160}" "${got:0:160}"
}

expect_same_eviction() {
	local val port label used limit after evicted
	val="$(printf 'v%.0s' $(seq 1 1000))"
	for port in "$PORT" "$REF_PORT"; do
		label="eski"
		[ "$port" == "$REF_PORT" ] && label="redis"
		printf 'FLUSHALL\nCONFIG RESETSTAT\nCONFIG SET maxmemory-policy allkeys-lru\n' | docker exec -i "$CLI_CONTAINER" redis-cli -p "$port" >/dev/null 2>&1
		used="$(info_fields "$port" memory used_memory '^used_memory$' | cut -d: -f2)"
		limit=$((used + 1048576))
		docker exec "$CLI_CONTAINER" redis-cli -p "$port" config set maxmemory "$limit" >/dev/null 2>&1
		for i in $(seq 1 3000); do
			printf 'SET mem:ev:%s %s\n' "$i" "$val"
		done | docker exec -i "$CLI_CONTAINER" redis-cli -p "$port" >/dev/null 2>&1
		after="$(info_fields "$port" memory used_memory '^used_memory$' | cut -d: -f2)"
		evicted="$(info_fields "$port" stats evicted_keys '^evicted_keys$' | cut -d: -f2)"
		if [ -n "$after" ] && [ "$after" -le $((limit + 65536)) ] && [ "${evicted:-0}" -gt 0 ]; then pass; else fail "$label keeps used_memory under maxmemory with allkeys-lru" "at most $((limit + 65536)) with keys evicted" "used_memory $after with ${evicted:-no} keys evicted"; fi
	done
}

if docker run -d --rm --name "$REF_CONTAINER" --network=host "$IMAGE" redis-server --port "$REF_PORT" --bind 127.0.0.1 --protected-mode yes --save "3600 1 300 100 60 10000" --appendonly no --enable-debug-command yes >/dev/null; then
	ref_ready=0
	for _ in $(seq 1 100); do
		if [ "$(ref_cli ping)" == "PONG" ]; then
			ref_ready=1
			break
		fi
		sleep 0.1
	done
	if [ "$ref_ready" == "1" ]; then
		echo "reference Redis is up on port $REF_PORT for the HyperLogLog, string, hash and pubsub comparisons"
		hll_feed="$(
			printf 'PFADD hll:empty\n'
			hll_elements hll:one one- 1
			hll_elements hll:small small- 100
			hll_elements hll:mid mid- 1500
			hll_elements hll:big big- 20000
			hll_elements hll:dup dup- 300
			hll_elements hll:dup dup- 300
			hll_elements hll:mid big- 700
			printf 'PFADD hll:bin "\\x00\\x01\\xff" "" "a b"\n'
		)"
		got="$(printf '%s\n' "$hll_feed" | cli_pipe)"
		want="$(printf '%s\n' "$hll_feed" | ref_pipe)"
		if [ "$got" == "$want" ]; then pass; else fail "hll PFADD replies match redis" "$want" "$got"; fi
		for key in hll:empty hll:one hll:small hll:mid hll:big hll:dup hll:bin; do
			expect_same "hll strlen $key" strlen "$key"
			expect_same "hll GET bytes before PFCOUNT $key" get "$key"
			expect_same "hll encoding $key" pfdebug encoding "$key"
			expect_same "hll PFCOUNT $key" pfcount "$key"
			expect_same "hll GET bytes with cached cardinality $key" get "$key"
		done
		expect_same "hll decode sparse" pfdebug decode hll:small
		expect_same "hll decode dense error" pfdebug decode hll:big
		expect_same "hll multi-key PFCOUNT" pfcount hll:one hll:small hll:mid hll:big hll:missing
		expect_same "hll PFMERGE into new key" pfmerge hll:merged hll:small hll:mid hll:big
		expect_same "hll merged GET bytes" get hll:merged
		expect_same "hll merged PFCOUNT" pfcount hll:merged
		expect_same "hll PFMERGE sparse sources" pfmerge hll:sparsemerge hll:one hll:small hll:dup
		expect_same "hll sparse merge GET bytes" get hll:sparsemerge
		expect_same "hll PFMERGE dest as source" pfmerge hll:small hll:one
		expect_same "hll dest as source GET bytes" get hll:small
		expect_same "hll PFMERGE missing sources" pfmerge hll:fresh hll:nope1 hll:nope2
		expect_same "hll fresh merge GET bytes" get hll:fresh
		expect_same "hll TODENSE" pfdebug todense hll:mid
		expect_same "hll TODENSE GET bytes" get hll:mid
		expect_same "hll GETREG" pfdebug getreg hll:one
		expect_same "hll GETREG converts" get hll:one
		expect_same "hll set string" set hll:str notanhll
		expect_same "hll PFADD wrongtype" pfadd hll:str x
		expect_same "hll PFCOUNT wrongtype" pfcount hll:str
		expect_same "hll PFMERGE wrongtype" pfmerge hll:merged hll:str
		expect_same "hll PFDEBUG missing key" pfdebug encoding hll:nope
		expect_same "hll PFDEBUG unknown subcommand" pfdebug nosuch hll:big
		expect_same "hll PFDEBUG arity" pfdebug encoding hll:big extra
		expect_same "hll corrupt append" append hll:dup hello
		expect_same "hll corrupt PFCOUNT" pfcount hll:dup
		expect_same "hll corrupt PFADD keeps partial changes" pfadd hll:dup zz1 zz2
		expect_same "hll corrupt GET bytes" get hll:dup
		expect_same "hll sparse max bytes config" config set hll-sparse-max-bytes 30
		expect_same "hll PFADD over lowered limit" pfadd hll:sparsemerge newelement
		expect_same "hll encoding after lowered limit" pfdebug encoding hll:sparsemerge
		expect_same "hll restore sparse max bytes" config set hll-sparse-max-bytes 3000
		expect "hll PFSELFTEST" "OK" pfselftest
		expect_same_pipe "string SET options" "$(cat <<'CMDS'
FLUSHALL
SET str:k v EX 10 EX 100
TTL str:k
SET str:k v NX NX
SET str:k v2 GET GET
SET str:k v3 KEEPTTL KEEPTTL
TTL str:k
SET str:k v EX abc NX XX
SET str:k v EX 10 EX abc
SET str:k v EX 0 GET
SET str:k v PX -5
SET str:k v EX 9223372036854775
SET str:k v EX 9223372036854776
SET str:k v PX 9223372036854775807
SET str:k v EXAT 9223372036854775807
SET str:k v EX 10 PX 100
SET str:k v KEEPTTL EX 10
SET str:k v EX 10 KEEPTTL
SET str:k v NX XX
SET str:k v xx nx get
SET str:k v PX
SET str:k v BOGUS
SET str:k v PERSIST
SET str:k v EX -0
SET str:k v EX 01
SET str:k v EX +5
SET str:k v GET NX
SET str:new v GET NX
GET str:new
SET str:new2 v GET XX
EXISTS str:new2
SET str:k v4 GET XX
SET str:k v5 XX PX 100000
TTL str:k
SET str:k v6 KEEPTTL GET
TTL str:k
SET str:k v7
TTL str:k
SET str:k v8 EXAT 1
EXISTS str:k
SET str:k
SET str:k v GET extra
CMDS
)"
		expect_same_pipe "string GETEX" "$(cat <<'CMDS'
SET str:g bar
GETEX str:g
GETEX str:g EX 100
TTL str:g
GETEX str:g PX 200000
TTL str:g
GETEX str:g EX 10 EX 300
TTL str:g
GETEX str:g PERSIST
TTL str:g
GETEX str:g PERSIST PERSIST
GETEX str:g EXAT 99999999999
PERSIST str:g
GETEX str:g PXAT 99999999999000
PERSIST str:g
GETEX str:g KEEPTTL
GETEX str:g NX
GETEX str:g GET
GETEX str:g EX
GETEX str:g PERSIST EX 10
GETEX str:g EX 10 PERSIST
GETEX str:g EX abc
GETEX str:g EX 0
GETEX str:g PX -1
GETEX str:g EX 9223372036854776
GETEX str:g EXAT 9223372036854775807
GETEX str:missing EX abc
GETEX str:missing BOGUS
GETEX str:missing
GETEX str:g EXAT 1
EXISTS str:g
SET str:g bar
GETEX str:g PXAT 1
EXISTS str:g
GETEX
CMDS
)"
		expect_same_pipe "string GETRANGE SUBSTR" "$(cat <<'CMDS'
SET str:s "Hello World"
GETRANGE str:s 0 3
GETRANGE str:s 0 -1
GETRANGE str:s -4 -1
GETRANGE str:s 5 3
GETRANGE str:s 5 5000
GETRANGE str:s -5000 10000
GETRANGE str:s -1 -5
GETRANGE str:s 0 -100
GETRANGE str:s -100 -50
GETRANGE str:s 11 11
GETRANGE str:s 10 10
GETRANGE str:s 0 4294967297
GETRANGE str:s -9223372036854775808 9223372036854775807
GETRANGE str:s 9223372036854775807 -9223372036854775808
GETRANGE str:s a 1
GETRANGE str:s 1 b
GETRANGE str:s 1.5 2
GETRANGE str:nokey 0 -1
GETRANGE str:nokey a b
GETRANGE str:s 0
SET str:n 1234
GETRANGE str:n 0 2
GETRANGE str:n -3 -1
SET str:e ""
GETRANGE str:e 0 -1
SUBSTR str:s 0 3
SUBSTR str:s -1 -3
SUBSTR str:s 7 8
SUBSTR str:nokey 0 1
SUBSTR str:s
CMDS
)"
		expect_same_pipe "string SETRANGE" "$(cat <<'CMDS'
SETRANGE str:r 0 foo
SETRANGE str:r2 0 ""
EXISTS str:r2
SETRANGE str:r3 1 foo
GET str:r3
SETRANGE str:r 4 bar
GET str:r
SETRANGE str:r 0 ""
SETRANGE str:r 1 X
GET str:r
SETRANGE str:r -1 x
SETRANGE str:r abc x
SETRANGE str:r 536870908 world
SETRANGE str:r 536870911 ab
SETRANGE str:r4 536870911 ab
SETRANGE str:r4 536870912 ""
SETRANGE str:r4 9223372036854775807 A
SETRANGE str:r4 2147483647 A
SETRANGE str:r4 -1 ""
EXISTS str:r4
SET str:n 1234
SETRANGE str:n 0 2
SETRANGE str:n 5 2
GET str:n
SET str:t v EX 100
SETRANGE str:t 3 x
TTL str:t
SETRANGE str:r
CMDS
)"
		expect_same_pipe "string APPEND STRLEN" "$(cat <<'CMDS'
APPEND str:a hello
APPEND str:a " world"
APPEND str:a ""
GET str:a
STRLEN str:a
STRLEN str:nokey
APPEND str:newa ""
EXISTS str:newa
SET str:i 1
APPEND str:i 2
GET str:i
INCR str:i
STRLEN str:i
SET str:i -555
STRLEN str:i
APPEND
STRLEN
STRLEN a b
CMDS
)"
		expect_same_pipe "string INCR family" "$(cat <<'CMDS'
INCR str:c
INCR str:c
INCRBY str:c 10
DECR str:c
DECRBY str:c 5
DECR str:cnew
INCRBY str:cnew2 17179869184
SET str:ws " 11"
INCR str:ws
SET str:ws "11 "
INCR str:ws
SET str:ws " 11 "
DECR str:ws
SET str:lz 01
INCR str:lz
SET str:mz -0
INCR str:mz
SET str:pz +1
INCR str:pz
SET str:mx 9223372036854775807
INCR str:mx
INCRBY str:mx 0
INCRBY str:mx -1
SET str:mn -9223372036854775808
DECR str:mn
DECRBY str:mn 1
DECRBY str:mn -9223372036854775808
INCRBY str:mn -1
INCRBY str:mn 9223372036854775807
INCRBY str:x 9223372036854775808
INCRBY str:x -9223372036854775809
INCRBY str:x 1.5
INCRBY str:x ""
INCRBY str:x v
DECRBY str:x v
DECRBY str:x 1.5
DECRBY str:x " 1"
SET str:big 12345678901234567890
INCR str:big
SET str:z "0 "
INCR str:z
SET str:t 5 EX 100
INCR str:t
TTL str:t
INCR str:x y
DECR str:x y
INCR
CMDS
)"
		expect_same_pipe "string INCRBYFLOAT" "$(string_float_values; cat <<'CMDS'
SET str:s 1
SETRANGE str:s 2 2
INCRBYFLOAT str:s 1
SET str:t 1.5 EX 100
INCRBYFLOAT str:t 1.5
TTL str:t
SET str:big 17179869184
INCRBYFLOAT str:big 1.5
INCRBYFLOAT str:big 17179869184
INCRBYFLOAT str:s
INCRBYFLOAT str:s 1 2
CMDS
)"
		expect_same_pipe "string LCS" "$(cat <<'CMDS'
SET str:la ohmytext
SET str:lb mynewtext
LCS str:la str:lb
LCS str:la str:lb LEN
LCS str:la str:lb IDX
LCS str:la str:lb IDX WITHMATCHLEN
LCS str:la str:lb IDX MINMATCHLEN 4
LCS str:la str:lb IDX MINMATCHLEN 4 WITHMATCHLEN
LCS str:la str:lb IDX MINMATCHLEN -5 WITHMATCHLEN
LCS str:la str:lb IDX LEN
LCS str:la str:lb LEN IDX
LCS str:la str:lb MINMATCHLEN
LCS str:la str:lb MINMATCHLEN x
LCS str:la str:lb FOO
LCS str:la str:lb LEN WITHMATCHLEN
LCS str:la str:lb WITHMATCHLEN
LCS str:la str:nokey
LCS str:nokey str:la IDX
LCS str:nokey str:nokey2 LEN
LCS str:nokey str:nokey2 IDX WITHMATCHLEN
LCS str:la str:la IDX WITHMATCHLEN
SET str:lc aaaaabbbbbcccccdddddeeeee
SET str:ld xaaxxbbbxcccdxeexabcde
LCS str:lc str:ld
LCS str:lc str:ld IDX WITHMATCHLEN
LCS str:ld str:lc IDX WITHMATCHLEN MINMATCHLEN 2
SET str:le "\x00\x01\xff"
SET str:lf "\xff\x00"
LCS str:le str:lf IDX
LCS str:la
CMDS
)"
		expect_same_pipe "string MSET MGET SETNX SETEX GETSET GETDEL" "$(cat <<'CMDS'
MSET str:m1 a str:m2 b
MSET str:m1
MSET str:m1 a str:m2
MSETNX str:m1 x str:m3 y
MSETNX str:m3 x str:m4 y
MSETNX str:m5 x str:m5 y
MSETNX str:m6 x str:m6
MGET str:m1 str:m2 str:m3 str:m4 str:m5 str:nokey
MGET
SETNX str:m1 x
SETNX str:m9 x
SETNX str:m9
GETSET str:m9 y
GETSET str:m10 y
SET str:m11 v EX 100
GETSET str:m11 w
TTL str:m11
GETSET str:m11
GETDEL str:m10
GETDEL str:m10
GETDEL
SETEX str:se 100 v
TTL str:se
SETEX str:se 0 v
SETEX str:se -1 v
SETEX str:se x v
SETEX str:se 1.5 v
SETEX str:se 9223372036854775 v
SETEX str:se 9223372036854776 v
PSETEX str:pse 9223372036854775807 v
PSETEX str:pse 0 v
PSETEX str:pse 100000 v
GET str:pse
SETEX str:se 100
PSETEX str:pse 100
CMDS
)"
		expect_same_pipe_proto "connection family" "$(cat <<'CMDS'
PING
PING hello
ECHO "hi there"
SELECT 0
CLIENT GETNAME
CLIENT SETNAME r3name
CLIENT GETNAME
CLIENT SETNAME ""
CLIENT GETNAME
CLIENT GETREDIR
CLIENT NO-EVICT on
CLIENT NO-EVICT off
CLIENT NO-TOUCH on
CLIENT NO-TOUCH off
CLIENT UNBLOCK 999999
CLIENT KILL ID 999999
CLIENT LIST ID 999999
CLIENT LIST TYPE master
CLIENT LIST TYPE bogus
CLIENT SETINFO lib-name r3lib
CLIENT CACHING yes
CLIENT FOO
CLIENT HELP
AUTH pass
AUTH someone pass
HELLO 4
HELLO abc
HELLO 3 BOGUS
HELLO 3 SETNAME
HELLO 3 SETNAME "bad name"
HELLO 3 AUTH someone pw
CMDS
)" 3
		expect_same_pipe_proto "server family" "$(cat <<'CMDS'
FLUSHALL
DBSIZE
CONFIG GET maxmemory
CONFIG GET nonexistentparam
CONFIG GET appendonly
CONFIG GET
INFO bogus
MEMORY USAGE nope
COMMAND DOCS nosuchcmd
FUNCTION STATS
FUNCTION LIST
FUNCTION DUMP
FUNCTION FLUSH
FUNCTION DELETE nolib
FUNCTION KILL
FUNCTION RESTORE bogus
FUNCTION HELP
DEBUG SLEEP 0
DEBUG PROTOCOL string
DEBUG PROTOCOL integer
DEBUG PROTOCOL double
DEBUG PROTOCOL null
DEBUG PROTOCOL array
DEBUG PROTOCOL set
DEBUG PROTOCOL map
DEBUG PROTOCOL push
DEBUG PROTOCOL verbatim
DEBUG PROTOCOL true
DEBUG PROTOCOL false
DEBUG PROTOCOL bogus
DEBUG PROTOCOL
CMDS
)" 3
		expect_same_pipe_proto "generic family" "$(cat <<'CMDS'
FLUSHALL
SET r3:k v
EXPIRE r3:k 100
TTL r3:k
PTTL r3:nope
PERSIST r3:k
PERSIST r3:k
TTL r3:k
EXISTS r3:k r3:nope
TYPE r3:k
TYPE r3:nope
TOUCH r3:k r3:nope
RENAME r3:k r3:k2
RENAME r3:nope r3:x
OBJECT ENCODING r3:k2
OBJECT ENCODING r3:nope
KEYS r3:*
SCAN 0 MATCH r3:* COUNT 1000
RANDOMKEY
DEL r3:k2 r3:nope
UNLINK r3:nope
RANDOMKEY
EXPIREAT r3:nope 1
PEXPIRE r3:nope 100
SCAN 0
CMDS
)" 3
		expect_same_pipe "generic expire family" "$(cat <<'CMDS'
FLUSHALL
SET g:a hello
SET g:n 42
EXPIRE g:a 100
TTL g:a
EXPIRE g:a 100 NX
EXPIRE g:a 200 XX
TTL g:a
EXPIRE g:a 50 GT
EXPIRE g:a 300 GT
TTL g:a
EXPIRE g:a 400 LT
EXPIRE g:a 100 LT
TTL g:a
EXPIRE g:n 100 XX
EXPIRE g:n 100 GT
EXPIRE g:n 100 LT
TTL g:n
PERSIST g:n
EXPIRE g:n 100 NX
TTL g:n
PERSIST g:n
PERSIST g:n
TTL g:n
EXPIRE g:a 10 NX XX
EXPIRE g:a 10 NX GT
EXPIRE g:a 10 nx lt
EXPIRE g:a 10 GT LT
EXPIRE g:a 10 XX GT LT
EXPIRE g:a 10 FOO
EXPIRE g:a 10 "bad\r\n"
EXPIRE g:a 10 ""
EXPIRE g:a abc
EXPIRE g:a abc FOO
EXPIRE g:a abc NX XX
EXPIRE g:a ""
EXPIRE g:a 1.5
EXPIRE g:a 9223370399119966
EXPIRE g:a 9223372036854776
EXPIRE g:a 10000000000000000
EXPIRE g:a 18446744073709561
EXPIRE g:a -9223372036854776
EXPIRE g:a -9999999999999999
PEXPIRE g:a 9223372036854770000
EXPIREAT g:a 9223372036854776
PEXPIREAT g:a 9223372036854775808
EXPIRE g:missing 100
EXPIRE g:missing -1
EXPIRE g:a
PEXPIRE g:a
EXPIREAT g:a
PEXPIREAT g:a
SET g:p v
PEXPIREAT g:p 99999999999000
PEXPIRETIME g:p
EXPIRETIME g:p
EXPIREAT g:p 99999999999
EXPIRETIME g:p
PEXPIRETIME g:p
EXPIREAT g:p 99999999999 GT
EXPIREAT g:p 99999999998 LT
PEXPIREAT g:p 99999999998500 GT
PEXPIRETIME g:p
EXPIRETIME g:p
PEXPIRETIME g:n
EXPIRETIME g:n
PTTL g:missing
EXPIRETIME g:missing
PEXPIRETIME g:missing
EXPIRETIME
PEXPIRETIME a b
TTL
PTTL a b
SET g:neg v
EXPIRE g:neg -1
EXISTS g:neg
SET g:neg v
EXPIREAT g:neg 1
EXISTS g:neg
SET g:neg v
PEXPIRE g:neg 0
EXISTS g:neg
SET g:neg v
PEXPIREAT g:neg -9223372036854770000
EXISTS g:neg
SET g:neg v
EXPIRE g:neg -1 XX
EXISTS g:neg
EXPIRE g:neg 100
EXPIRE g:neg -1 GT
EXPIRE g:neg -1 LT
EXISTS g:neg
SET g:neg v
EXPIRE g:neg -5 NX
EXISTS g:neg
PERSIST g:missing
PERSIST
CMDS
)"
		expect_same_pipe "generic rename and copy" "$(cat <<'CMDS'
FLUSHALL
SET g:emb abcdefghijklmnopqrstuvwxyz
SET g:n 42
SET g:big 123456789012
APPEND g:raw abc
SET g:e ""
SET g:long xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
SETRANGE g:sr 5000 x
RENAME g:missing g:x
RENAME g:missing g:missing
RENAME g:big g:big
RENAME g:big g:big2
GET g:big2
OBJECT ENCODING g:big2
RENAMENX g:missing g:x
RENAMENX g:missing g:missing
RENAMENX g:big2 g:big2
RENAMENX g:big2 g:n
RENAMENX g:big2 g:fresh
GET g:fresh
EXISTS g:big2
RENAMENX g:fresh
RENAMENX a b c
SET g:t1 v
EXPIRE g:t1 1000
RENAMENX g:t1 g:t2
TTL g:t2
SET g:t3 w
EXPIRE g:t3 500
RENAME g:t2 g:t3
TTL g:t3
SET g:t4 x
RENAME g:t4 g:t3
TTL g:t3
COPY g:emb g:emb2
GET g:emb2
OBJECT ENCODING g:emb2
OBJECT REFCOUNT g:emb2
COPY g:raw g:raw2
OBJECT ENCODING g:raw2
GET g:raw2
COPY g:n g:n2
OBJECT ENCODING g:n2
OBJECT REFCOUNT g:n2
OBJECT REFCOUNT g:n
INCR g:n2
OBJECT REFCOUNT g:n2
COPY g:fresh g:n3
OBJECT ENCODING g:n3
OBJECT REFCOUNT g:n3
COPY g:emb g:emb2
COPY g:emb g:emb2 REPLACE
COPY g:n g:emb2 replace
GET g:emb2
OBJECT ENCODING g:emb2
COPY g:emb g:emb
COPY g:missing g:emb
COPY g:missing g:missing
COPY g:emb g:x DB
COPY g:emb g:x DB notanumber
COPY g:emb g:x DB 2147483648
COPY g:emb g:x DB -2147483649
COPY g:emb g:x DB -1
COPY g:emb g:x DB 16
COPY g:emb g:x DB 99999999999999999999
COPY g:emb g:x FOO
COPY g:emb g:x REPLACE FOO
COPY g:emb g:emb DB 0
COPY g:emb g:copied DB 0
EXISTS g:copied
COPY g:emb
SET g:ttl v
PEXPIREAT g:ttl 99999999999000
COPY g:ttl g:ttl2
PEXPIRETIME g:ttl2
COPY g:emb g:ttl2 REPLACE
PEXPIRETIME g:ttl2
COPY g:e g:e2
GET g:e2
OBJECT ENCODING g:e2
COPY g:long g:long2
GET g:long2
OBJECT ENCODING g:long2
COPY g:sr g:sr2
STRLEN g:sr2
OBJECT ENCODING g:sr2
APPEND g:sr2 tail
STRLEN g:sr
CMDS
)"
		expect_same_pipe "generic object sort wait and scan" "$(cat <<'CMDS'
FLUSHALL
SET g:a hello
SET g:n 7
SET g:i 12345
TYPE g:a
TYPE g:missing
TYPE
EXISTS g:a g:n g:missing g:a
EXISTS
TOUCH g:a g:n g:missing g:a
TOUCH
OBJECT ENCODING g:a
OBJECT ENCODING g:n
OBJECT ENCODING g:i
OBJECT ENCODING g:missing
OBJECT REFCOUNT g:a
OBJECT REFCOUNT g:n
OBJECT REFCOUNT g:i
OBJECT REFCOUNT g:missing
OBJECT IDLETIME g:missing
OBJECT FREQ g:missing
OBJECT FREQ g:a
OBJECT FREQ
OBJECT IDLETIME
OBJECT REFCOUNT a b
OBJECT HELP
OBJECT help
OBJECT HELP extra
OBJECT
OBJECT NOSUCH
OBJECT NOSUCH a b c
SORT g:missing
SORT g:a
SORT g:missing BY nosort
SORT g:missing BY w_* GET # GET g_* LIMIT 0 10 DESC ALPHA
SET g:dst x
SORT g:missing STORE g:dst
EXISTS g:dst
SORT g:missing STORE g:nothing
SORT g:a STORE g:dst2
SORT g:missing LIMIT
SORT g:missing LIMIT 1
SORT g:missing LIMIT a 1
SORT g:missing LIMIT 1 a
SORT g:missing LIMIT 0 1 2
SORT g:missing BY
SORT g:missing GET
SORT g:missing STORE
SORT g:missing FOO
SORT g:missing ASC DESC ALPHA asc
SORT
SORT_RO g:missing
SORT_RO g:a
SORT_RO g:missing STORE g:x
SORT_RO g:missing BY w_* GET # LIMIT 0 -1
SORT_RO
SORT g:a FOO
SORT g:a LIMIT a 1
WAIT 0 0
WAIT 0 100
WAIT 1 50
WAIT -1 0
WAIT x 0
WAIT 0 x
WAIT 0 -5
WAIT 0 9223372036854775807
WAIT 0
WAITAOF 0 0 0
WAITAOF 0 1 50
WAITAOF 1 0 0
WAITAOF 2 0 0
WAITAOF -1 0 0
WAITAOF 0 -1 0
WAITAOF a 0 0
WAITAOF 0 a 0
WAITAOF 0 0 a
WAITAOF 0 0 -1
WAITAOF 0 0
DEL g:missing g:n
UNLINK g:missing g:missing
DEL
UNLINK
RANDOMKEY extra
KEYS
KEYS a b
SCAN
SCAN x
SCAN -1
SCAN 18446744073709551616
SCAN 0x10
SCAN 1.5
SCAN 0 COUNT
SCAN 0 COUNT 0
SCAN 0 COUNT -1
SCAN 0 COUNT abc
SCAN 0 MATCH
SCAN 0 TYPE
SCAN 0 NOVALUES
SCAN 0 FOO bar
SCAN 0 COUNT 10 FOO
SCAN 0 TYPE list COUNT 1000
SCAN 0 TYPE hash COUNT 1000
SCAN 0 TYPE nosuchtype COUNT 1000
SCAN 0 MATCH g:a COUNT 1000
SCAN 0 MATCH g:? TYPE string COUNT 1000 MATCH g:[a]
SCAN 0 MATCH g:a TYPE STRING COUNT 1000
SCAN 0 MATCH g:a TYPE zset COUNT 1000
SCAN " 0" MATCH g:a COUNT 1000
SCAN +0 MATCH g:a COUNT 1000
SCAN -0 MATCH g:a COUNT 1000
FLUSHALL
SET "" emptykey
KEYS *
KEYS **
KEYS ?
KEYS ""
SCAN 0 MATCH ** COUNT 100
SCAN 0 MATCH "" COUNT 100
SCAN 0 COUNT 100
RANDOMKEY
DEL ""
RANDOMKEY
CMDS
)"
		expect_same_pipe "generic copy across databases and hashes" "$(cat <<'CMDS'
FLUSHALL
SET k v
SET n 42
COPY k k DB 0
COPY k k DB 1
SELECT 1
GET k
OBJECT ENCODING k
COPY k k DB 0
COPY k k DB 0 REPLACE
SELECT 0
COPY n n DB 1
SELECT 1
OBJECT REFCOUNT n
OBJECT ENCODING n
SELECT 0
COPY k x DB 1 FOO
SET t v
PEXPIREAT t 99999999999000
COPY t t DB 2
SELECT 2
PEXPIRETIME t
SELECT 0
HSET h a 1 b 2
COPY h h2
HGETALL h2
OBJECT ENCODING h2
TYPE h2
COPY h h DB 3
SELECT 3
HGETALL h
SELECT 0
HSET hx f1 v1 f2 v2
HPEXPIREAT hx 99999999999000 FIELDS 1 f1
COPY hx hx2 DB 4
SELECT 4
OBJECT ENCODING hx2
HPEXPIRETIME hx2 FIELDS 2 f1 f2
HGETALL hx2
SELECT 0
COPY h k
COPY h k REPLACE
TYPE k
HGETALL k
COPY k h REPLACE
TYPE h
MOVE n 5
SELECT 5
GET n
OBJECT REFCOUNT n
SELECT 0
FLUSHALL
CMDS
)"
		printf 'FLUSHALL\nDEBUG SET-ACTIVE-EXPIRE 0\nSET sx:a 1 PX 1\nSET sx:b 1 PX 1\nSET sx:keep 1\nHSET sx:h f v\nPEXPIRE sx:h 1\n' | cli_pipe >/dev/null
		printf 'FLUSHALL\nDEBUG SET-ACTIVE-EXPIRE 0\nSET sx:a 1 PX 1\nSET sx:b 1 PX 1\nSET sx:keep 1\nHSET sx:h f v\nPEXPIRE sx:h 1\n' | ref_pipe >/dev/null
		sleep 0.1
		expect_same_pipe "generic scan deletes expired keys" "$(cat <<'CMDS'
DBSIZE
SCAN 0 MATCH sx:a COUNT 100
DBSIZE
SCAN 0 TYPE string COUNT 100
DBSIZE
SCAN 0 COUNT 100
DBSIZE
CMDS
)"
		printf 'DEBUG SET-ACTIVE-EXPIRE 1\nFLUSHALL\n' | cli_pipe >/dev/null
		printf 'DEBUG SET-ACTIVE-EXPIRE 1\nFLUSHALL\n' | ref_pipe >/dev/null
		sort_comparison="$(python3 -I test/sort/compare.py "$PORT" "$REF_PORT" 2>&1)"
		if [ "$?" -eq 0 ]; then
			pass
		else
			fail "SORT binary and option comparisons" "all focused comparisons pass" "$sort_comparison"
		fi
		expect_same_sorted_pipe "generic glob dialect" "$(cat <<'CMDS'
FLUSHALL
MSET hello 1 hallo 1 hxllo 1 hllo 1 heeeello 1 "h*llo" 1 "h?llo" 1 "h[a]llo" 1 "h\\llo" 1 "h-llo" 1 "h^llo" 1 "h]llo" 1 "{a}x" 1 "{a}y" 1 "{b}a" 1 "\xff\x80" 1 ab 1 aab 1 abab 1
KEYS *
ECHO ---
KEYS h?llo
ECHO ---
KEYS h*llo
ECHO ---
KEYS h[ae]llo
ECHO ---
KEYS h[^e]llo
ECHO ---
KEYS h[a-b]llo
ECHO ---
KEYS h[b-a]llo
ECHO ---
KEYS h\*llo
ECHO ---
KEYS h\?llo
ECHO ---
KEYS h\[a]llo
ECHO ---
KEYS h[\]]llo
ECHO ---
KEYS h[\\]llo
ECHO ---
KEYS h\\llo
ECHO ---
KEYS h[-]llo
ECHO ---
KEYS h[x-]llo
ECHO ---
KEYS h[^]llo
ECHO ---
KEYS h[^^]llo
ECHO ---
KEYS h[
ECHO ---
KEYS h[^
ECHO ---
KEYS h[a-
ECHO ---
KEYS "h*llo\\"
ECHO ---
KEYS {a}*
ECHO ---
KEYS *{b}*
ECHO ---
KEYS "[\x80-\xff]*"
ECHO ---
KEYS "*[a-\xff]"
ECHO ---
KEYS "a?b"
ECHO ---
KEYS *ab
ECHO ---
KEYS *a*b
ECHO ---
KEYS ***b
ECHO ---
SCAN 0 MATCH h[^e]llo COUNT 1000
ECHO ---
SCAN 0 MATCH *ab COUNT 1000
ECHO ---
SCAN 0 TYPE string MATCH h?llo COUNT 1000
CMDS
)"
		expect_same_pipe_proto "bitmap family" "$(cat <<'CMDS'
FLUSHALL
SETBIT r3:bm 7 1
GETBIT r3:bm 7
GETBIT r3:nobm 0
BITCOUNT r3:bm
BITCOUNT r3:nobm
BITPOS r3:bm 1
BITPOS r3:nobm 1
SET r3:a foobar
BITOP AND r3:d r3:a r3:bm
BITOP NOT r3:d r3:a r3:bm
BITFIELD r3:bf SET u8 0 255 GET u8 0 OVERFLOW FAIL INCRBY u8 0 300
BITFIELD r3:bf GET u64 0
BITFIELD r3:nobf GET u8 0
BITFIELD_RO r3:bf GET u8 0
BITFIELD_RO r3:bf SET u8 0 1
SETBIT r3:bm -1 1
CMDS
)" 3
		expect_same_pipe "hash family" "$(cat <<'CMDS'
FLUSHALL
HSET h:a f1 v1 f2 2 f3 ""
HGET h:a f1
HGET h:a nofield
HGET h:nokey f
HMGET h:a f1 nofield f2
HMGET h:nokey a b
HMSET h:a f4 4 f5 5
HSETNX h:a f1 x
HSETNX h:a f6 6
HGETALL h:a
HKEYS h:a
HVALS h:a
HLEN h:a
HLEN h:nokey
HEXISTS h:a f1
HEXISTS h:a zz
HSTRLEN h:a f2
HSTRLEN h:a f3
HSTRLEN h:a zz
HINCRBY h:a f2 10
HINCRBY h:a f2 abc
HINCRBY h:a f3 1
HINCRBY h:a big 9223372036854775807
HINCRBY h:a big 1
HINCRBYFLOAT h:a f5 1.5
HINCRBYFLOAT h:a f1 1
HINCRBYFLOAT h:a f5 inf
HINCRBYFLOAT h:a f5 abc
HINCRBYFLOAT h:a fl 0.1
HINCRBYFLOAT h:a fl 0.2
HRANDFIELD h:a 100
HRANDFIELD h:a 100 WITHVALUES
HRANDFIELD h:a 0
HRANDFIELD h:a 0 WITHVALUES
HRANDFIELD h:nokey 3
HRANDFIELD h:nokey
HRANDFIELD h:a -9223372036854775808
HRANDFIELD h:a -9223372036854770000 WITHVALUES
HRANDFIELD h:a 5 WITHVALUE
HRANDFIELD h:a abc
HSCAN h:a 0
HSCAN h:a 0 MATCH f* NOVALUES
HSCAN h:a 0 MATCH f[1-3] COUNT 1
HSCAN h:a abc
HSCAN h:a 0 COUNT 0
HSCAN h:a 0 FOO
HSCAN h:nokey 0
OBJECT ENCODING h:a
TYPE h:a
HGETALL h:nokey
HKEYS h:nokey
HVALS h:nokey
HSET h:a f1
HSET h:a f1 v f2
HMSET h:a f1 v f2
HDEL h:a f1 zz
HDEL h:nokey a
HDEL h:a f2 f3 f4 f5 f6 big fl
EXISTS h:a
TYPE h:a
CMDS
)"
		expect_same_pipe "hash wrongtype" "$(cat <<'CMDS'
FLUSHALL
SET h:s str
HSET h:h f v
HGET h:s f
HSET h:s f v
HMSET h:s f v
HMGET h:s f
HGETALL h:s
HKEYS h:s
HVALS h:s
HLEN h:s
HEXISTS h:s f
HSTRLEN h:s f
HDEL h:s f
HINCRBY h:s f 1
HINCRBYFLOAT h:s f 1
HSETNX h:s f v
HRANDFIELD h:s
HRANDFIELD h:s 2
HSCAN h:s 0
HEXPIRE h:s 10 FIELDS 1 f
HPEXPIREAT h:s 10 FIELDS 1 f
HTTL h:s FIELDS 1 f
HPEXPIRETIME h:s FIELDS 1 f
HPERSIST h:s FIELDS 1 f
GET h:h
SET h:h x GET
GETEX h:h
GETDEL h:h
GETSET h:h x
APPEND h:h x
STRLEN h:h
SETRANGE h:h 0 x
GETRANGE h:h 0 1
SUBSTR h:h 0 1
INCR h:h
DECR h:h
INCRBY h:h 2
DECRBY h:h 2
INCRBYFLOAT h:h 1
MGET h:h h:s
LCS h:h h:s
SETBIT h:h 0 1
GETBIT h:h 0
BITCOUNT h:h
BITPOS h:h 1
BITOP AND h:d h:h
BITFIELD h:h GET u8 0
BITFIELD_RO h:h GET u8 0
PFADD h:h a
PFCOUNT h:h
PFCOUNT h:h h:s
PFMERGE h:d h:h
PFDEBUG encoding h:h
SETNX h:h x
MSETNX h:h x
TYPE h:h
OBJECT ENCODING h:h
HGET h:h f
SET h:h overwritten
TYPE h:h
GET h:h
HSET h:h2 f v
SETEX h:h2 100 now-a-string
TYPE h:h2
HSET h:h3 f v
MSET h:h3 str
TYPE h:h3
CMDS
)"
		expect_same_pipe "hash field expiration" "$(cat <<'CMDS'
FLUSHALL
HSET h:x a 1 b 2 c 3 d 4
HPEXPIREAT h:x 4102444800000 FIELDS 2 a nofield
OBJECT ENCODING h:x
HPEXPIRETIME h:x FIELDS 3 a b nofield
HEXPIRETIME h:x FIELDS 1 a
HTTL h:x FIELDS 2 b nofield
HPTTL h:x FIELDS 1 c
HPTTL h:nokey FIELDS 2 a b
HEXPIRETIME h:nokey FIELDS 1 a
HEXPIREAT h:x 4102444801 NX FIELDS 2 a b
HPEXPIREAT h:x 4102444700000 GT FIELDS 1 a
HPEXPIREAT h:x 4102444700000 LT FIELDS 3 a c zz
HPEXPIREAT h:x 4102444900000 XX FIELDS 2 a d
HPEXPIRETIME h:x FIELDS 4 a b c d
HPERSIST h:x FIELDS 3 a d zz
HPERSIST h:x FIELDS 1 a
HPERSIST h:nokey FIELDS 2 a b
HPEXPIREAT h:x 1000 FIELDS 1 b
HGETALL h:x
HPEXPIRETIME h:x FIELDS 4 a b c d
HSET h:x c 30
HPEXPIRETIME h:x FIELDS 1 c
HPEXPIREAT h:x 4102444800000 FIELDS 1 a
HINCRBY h:x a 5
HINCRBYFLOAT h:x a 0.5
HPEXPIRETIME h:x FIELDS 1 a
HPEXPIRE h:x 0 FIELDS 3 a c d
EXISTS h:x
HEXPIRE h:nokey 10 FIELDS 2 a b
HEXPIREAT h:nokey 10 FIELDS 1 a
HSET h:y a 1
HEXPIRE h:y -1 FIELDS 1 a
HEXPIRE h:y abc FIELDS 1 a
HEXPIRE h:y 70368744178 FIELDS 1 a
HEXPIREAT h:y 70368744178 FIELDS 1 a
HPEXPIRE h:y 70368744177663 FIELDS 1 a
HPEXPIREAT h:y 70368744177664 FIELDS 1 a
HEXPIRE h:y 10 FIELD 1 a
HEXPIRE h:y 10 NX FIELDS 0 a
HEXPIRE h:y 10 NX FIELDS abc a
HEXPIRE h:y 10 FIELDS 2 a
HEXPIRE h:y 10 FIELDS 1 a b
HEXPIRE h:y 10 XX 1 a
HEXPIRE h:y 10 FIELDS 1
HTTL h:y FIELDS 2 a
HTTL h:y FIELD 1 a
HTTL h:y FIELDS 0 a
HPERSIST h:y FIELDS 0 a
HPERSIST h:y FIELDS 1
HPERSIST h:y
HPEXPIREAT h:y 70368744177663 FIELDS 1 a
HPEXPIRETIME h:y FIELDS 1 a
OBJECT ENCODING h:y
CONFIG SET hash-max-listpack-entries 2
HSET h:c a 1 b 2
OBJECT ENCODING h:c
HPEXPIREAT h:c 4102444800000 FIELDS 1 a
OBJECT ENCODING h:c
HSET h:c c 3
OBJECT ENCODING h:c
HPEXPIRETIME h:c FIELDS 3 a b c
CONFIG SET hash-max-listpack-entries 512
CONFIG GET hash-max-listpack-entries
CONFIG GET hash-max-ziplist-entries
CONFIG GET hash-max-listpack-value
CONFIG GET hash-max-ziplist-value
CONFIG SET hash-max-ziplist-value 1kb
CONFIG GET hash-max-listpack-value
CONFIG SET hash-max-listpack-value abc
CONFIG SET hash-max-listpack-value -1
CONFIG SET hash-max-listpack-entries 1k
CONFIG SET hash-max-ziplist-entries -1
CONFIG SET hash-max-listpack-value 4
HSET h:v a 12345
OBJECT ENCODING h:v
CONFIG SET hash-max-listpack-value 64
DEBUG SET-ACTIVE-EXPIRE 0
DEBUG SET-ACTIVE-EXPIRE 1
CMDS
)"
		for proto in 2 3; do
			expect_same_pipe_proto "hash lazy expiry setup" "$(cat <<'CMDS'
FLUSHALL
DEBUG SET-ACTIVE-EXPIRE 0
HSET h:l f1 v1 f2 v2 f3 v3
HPEXPIRE h:l 300 FIELDS 3 f1 f2 f3
HSET h:m a 10 b 2 keep 1
HPEXPIRE h:m 300 FIELDS 2 a b
HSET h:n a 1
HPEXPIRE h:n 300 FIELDS 1 a
HSET h:o a 1 b 2
HPEXPIRE h:o 300 FIELDS 2 a b
HSET h:p a 1 b 2 c 3
HPEXPIRE h:p 300 FIELDS 1 a
CMDS
)" "$proto"
			sleep 0.6
			expect_same_pipe_proto "hash lazy expiry" "$(cat <<'CMDS'
EXISTS h:l
HLEN h:l
HEXISTS h:l f1
HLEN h:l
HGET h:l f2
HLEN h:l
HSTRLEN h:l f3
EXISTS h:l
HGETALL h:m
HLEN h:m
HTTL h:m FIELDS 3 a b keep
HPERSIST h:m FIELDS 2 a keep
HINCRBY h:m a 1
HGETALL h:m
HINCRBY h:n a 1
OBJECT ENCODING h:n
HRANDFIELD h:o 5
EXISTS h:o
HSCAN h:p 0
HLEN h:p
HMGET h:p a b c
HLEN h:p
DEBUG SET-ACTIVE-EXPIRE 1
CMDS
)" "$proto"
		done
		expect_same_raw3 "hash resp3 replies" "FLUSHALL" "HSET h:r a 1 b 2" "HGETALL h:r" "HRANDFIELD h:r 5 WITHVALUES" "HRANDFIELD h:r 5" "HGET h:r zz" "HMGET h:r a zz" "HGETALL h:nokey" "HKEYS h:nokey" "HRANDFIELD h:nokey" "HSCAN h:r 0" "HTTL h:r FIELDS 2 a zz" "HPERSIST h:nokey FIELDS 1 a" "HINCRBYFLOAT h:r a 1.5"
		db_mid="$(printf 'm%.0s' $(seq 1 300))"
		db_big="$(printf 'b%.0s' $(seq 1 5000))"
		expect_same_pipe "databases select and isolation" "$(cat <<'CMDS'
FLUSHALL
SELECT 16
SELECT -1
SELECT abc
SELECT 4294967296
SELECT 2147483648
SELECT -2147483649
SELECT 2147483647
SELECT 01
SELECT +1
SELECT 15
DBSIZE
SET db:a hello
SET db:b world
SELECT 10
SET db:a foo
SET db:b bared
GET db:a
GET db:b
DBSIZE
SELECT 15
GET db:a
GET db:b
DBSIZE
KEYS db:a
SELECT 0
DBSIZE
GET db:a
RANDOMKEY
KEYS *
SCAN 0
INFO keyspace
CONFIG GET databases
CONFIG SET databases 4
CONFIG SET DATABASES 4
CONFIG SET maxmemory 0 databases 4
FLUSHALL
CMDS
)"
		expect_same_pipe "databases move" "$(cat <<CMDS
FLUSHALL
SET db:m hello
MOVE db:m 0
MOVE db:m 16
MOVE db:m -1
MOVE db:m abc
MOVE db:m 4294967296
MOVE db:nope 0
MOVE db:nope 1
MOVE db:m 1
EXISTS db:m
DBSIZE
SELECT 1
GET db:m
DBSIZE
SET db:m again
SELECT 0
SET db:m here
MOVE db:m 1
GET db:m
SET db:t v EX 100
MOVE db:t 1
TTL db:t
SET db:p 12345
MOVE db:p 2
SET db:longer_key_in_the_slab $db_mid
MOVE db:longer_key_in_the_slab 2
SET db:big $db_big
MOVE db:big 2
SET db:append abc
APPEND db:append $db_mid
MOVE db:append 2
DBSIZE
SELECT 1
TTL db:t
GET db:t
GET db:m
SELECT 2
TTL db:p
GET db:p
OBJECT ENCODING db:p
STRLEN db:longer_key_in_the_slab
OBJECT ENCODING db:longer_key_in_the_slab
STRLEN db:big
OBJECT ENCODING db:big
STRLEN db:append
OBJECT ENCODING db:append
APPEND db:big tail
STRLEN db:big
MOVE db:big 0
DBSIZE
SELECT 0
STRLEN db:big
GETRANGE db:big -4 -1
DBSIZE
FLUSHALL
CMDS
)"
		expect_same_pipe "databases swapdb and flush" "$(cat <<'CMDS'
FLUSHALL
SELECT 0
SET db:s v1
SELECT 1
DBSIZE
SWAPDB 0 1
DBSIZE
GET db:s
SELECT 0
DBSIZE
SWAPDB 0 0
SWAPDB 44 55
SWAPDB 44 a
SWAPDB a 55
SWAPDB a b
SWAPDB 0 16
SWAPDB -1 0
SWAPDB 4294967296 0
SWAPDB 0 4294967296
SWAPDB 16 abc
FLUSHALL
SELECT 0
SET db:s v1
SELECT 1
SET db:s1 v1
SWAPDB 0 2
SELECT 0
DBSIZE
SELECT 2
GET db:s
FLUSHDB
DBSIZE
INFO keyspace
SELECT 1
KEYS *
SCAN 0 COUNT 100
RANDOMKEY
FLUSHDB ASYNC
FLUSHDB SYNC
FLUSHDB bogus
FLUSHDB sync async
DBSIZE
SET db:s2 v
FLUSHALL ASYNC
FLUSHALL SYNC
FLUSHALL bogus
INFO keyspace
CMDS
)"
		expect_same_pipe "databases reset returns to database 0" "$(cat <<'CMDS'
FLUSHALL
SELECT 5
SET db:r 1
RESET
GET db:r
DBSIZE
SELECT 5
GET db:r
DBSIZE
FLUSHALL
CMDS
)"
		db_setup=$'FLUSHALL\nSELECT 3\nSET db:x v PX 50\nSET db:y v\nSELECT 4\nSET db:y old PX 50\nSET db:z v\n'
		printf '%s' "$db_setup" | cli_pipe >/dev/null
		printf '%s' "$db_setup" | ref_pipe >/dev/null
		sleep 0.3
		expect_same_pipe "databases move with expired keys" "$(cat <<'CMDS'
SELECT 3
MOVE db:x 4
MOVE db:y 4
DBSIZE
SELECT 4
GET db:y
TTL db:y
GET db:x
DBSIZE
MOVE db:z 3
SELECT 3
GET db:z
CMDS
)"
		expect_same_raw3 "databases resp3 replies" "FLUSHALL" "SELECT 3" "SET db:k v" "MOVE db:k 4" "MOVE db:k 4" "SWAPDB 3 4" "DBSIZE" "SELECT 99" "SWAPDB 0 x" "INFO keyspace" "FLUSHALL"
		expect_same_raw3 "null and array replies" "FLUSHALL" "GET r3:nokey" "SET r3:k v" "MGET r3:k r3:nokey" "SET r3:k v NX" "SET r3:k w XX GET" "GETDEL r3:nokey" "GETEX r3:nokey" "RANDOMKEY" "OBJECT ENCODING r3:nokey" "MEMORY USAGE r3:nokey" "CLIENT GETNAME" "BITFIELD r3:bf GET u8 0 OVERFLOW FAIL INCRBY u8 0 300" "GETRANGE r3:nokey 0 -1"
		expect_same_raw3 "map replies" "SET r3:la ohmytext" "SET r3:lb mynewtext" "LCS r3:la r3:lb IDX WITHMATCHLEN" "LCS r3:nokey r3:nokey2 IDX" "CONFIG GET maxmemory" "CONFIG GET nonexistentparam" "FUNCTION STATS" "COMMAND DOCS nosuchcmd"
		expect_same_raw3 "verbatim replies" "INFO bogus" "CLIENT LIST ID 999999" "CLIENT LIST TYPE master"
		expect_same_raw3 "every reply type" "DEBUG PROTOCOL string" "DEBUG PROTOCOL integer" "DEBUG PROTOCOL double" "DEBUG PROTOCOL bignum" "DEBUG PROTOCOL null" "DEBUG PROTOCOL array" "DEBUG PROTOCOL set" "DEBUG PROTOCOL map" "DEBUG PROTOCOL attrib" "DEBUG PROTOCOL push" "DEBUG PROTOCOL verbatim" "DEBUG PROTOCOL true" "DEBUG PROTOCOL false"
		expect_same_raw3 "error replies" "HELLO 4" "HELLO abc" "HELLO 3 BOGUS" "NOSUCHCOMMAND a" "GET" "INCR r3:k" "CLIENT FOO"
		expect_same_raw3 "integer replies stay integers" "SETNX r3:k x" "MSETNX r3:k x" "EXPIRE r3:k 100" "PERSIST r3:k" "EXISTS r3:k" "PFADD r3:h a" "PFCOUNT r3:h" "INCRBYFLOAT r3:f 1.5" "DBSIZE"
		expect_same_raw3 "reset returns to resp2" "RESET" "GET r3:nokey" "DEBUG PROTOCOL map" "DEBUG PROTOCOL set" "CLIENT GETNAME"
		expect_same_pipe "set family" "$(cat <<'CMDS'
FLUSHALL
SADD s:i 3 1 2 -5 70000
SADD s:i 2 3
SMEMBERS s:i
OBJECT ENCODING s:i
SISMEMBER s:i 70000
SISMEMBER s:i 4
SMISMEMBER s:i 1 4 -5
SCARD s:i
SCARD s:nokey
SADD s:i abc
OBJECT ENCODING s:i
SMEMBERS s:i
SADD s:w 1 -40000 5000000000
SMEMBERS s:w
SADD s:l a b c 1 d
SMEMBERS s:l
OBJECT ENCODING s:l
SREM s:l b zz 1
SMEMBERS s:l
SREM s:l a c d e
EXISTS s:l
SADD s:a 1 2 3 4 5
SADD s:b 4 5 6 x
SINTER s:a s:b
SINTER s:a s:nokey
SUNION s:a s:b s:nokey
SDIFF s:a s:b
SDIFF s:b s:a
SDIFF s:a s:a
SINTERCARD 2 s:a s:b
SINTERCARD 2 s:a s:b LIMIT 1
SINTERCARD 1 s:nokey LIMIT 5
SINTERSTORE s:d s:a s:b
OBJECT ENCODING s:d
SMEMBERS s:d
SUNIONSTORE s:d s:a s:b
SMEMBERS s:d
OBJECT ENCODING s:d
SDIFFSTORE s:d s:b s:a
SMEMBERS s:d
SDIFFSTORE s:a s:a s:b
SMEMBERS s:a
SINTERSTORE s:d s:a s:nokey
EXISTS s:d
SET s:str x
SUNIONSTORE s:str s:a
TYPE s:str
SMOVE s:b s:a x
SMEMBERS s:a
OBJECT ENCODING s:a
SMOVE s:b s:new 6
OBJECT ENCODING s:new
SMOVE s:nokey s:a 1
SMOVE s:a s:a 1
SRANDMEMBER s:a 100
SRANDMEMBER s:a 0
SRANDMEMBER s:nokey 3
SRANDMEMBER s:nokey
SPOP s:nokey
SPOP s:nokey 2
SPOP s:a 0
SPOP s:a 100
EXISTS s:a
SSCAN s:i 0
SSCAN s:i 0 MATCH *a*
SSCAN s:i 0 MATCH -* COUNT 1
SSCAN s:nokey 0
SADD s:big m000 m001 m002 m003 m004 m005 m006 m007 m008 m009 m010 m011 m012 m013 m014 m015 m016 m017 m018 m019 m020 m021 m022 m023 m024 m025 m026 m027 m028 m029 m030 m031 m032 m033 m034 m035 m036 m037 m038 m039 m040 m041 m042 m043 m044 m045 m046 m047 m048 m049 m050 m051 m052 m053 m054 m055 m056 m057 m058 m059 m060 m061 m062 m063 m064 m065 m066 m067 m068 m069 m070 m071 m072 m073 m074 m075 m076 m077 m078 m079 m080 m081 m082 m083 m084 m085 m086 m087 m088 m089 m090 m091 m092 m093 m094 m095 m096 m097 m098 m099 m100 m101 m102 m103 m104 m105 m106 m107 m108 m109 m110 m111 m112 m113 m114 m115 m116 m117 m118 m119 m120 m121 m122 m123 m124 m125 m126 m127 m128 m129
SCARD s:big
OBJECT ENCODING s:big
SISMEMBER s:big m077
SORT s:i ALPHA
SORT s:w
SORT s:w DESC LIMIT 0 2
SORT s:big ALPHA LIMIT 0 5
SORT s:big ALPHA DESC LIMIT 3 4
COPY s:w s:copy
SMEMBERS s:copy
OBJECT ENCODING s:copy
COPY s:big s:bigcopy
SCARD s:bigcopy
OBJECT ENCODING s:bigcopy
CONFIG SET set-max-intset-entries 2
SADD s:c 1 2 3
OBJECT ENCODING s:c
CONFIG SET set-max-intset-entries 512
CONFIG GET set-max-intset-entries
CONFIG SET set-max-listpack-entries 1
SADD s:e a b
OBJECT ENCODING s:e
CONFIG SET set-max-listpack-entries 128
CONFIG GET set-max-listpack-entries
CONFIG SET set-max-listpack-value 3
SADD s:v abcd
OBJECT ENCODING s:v
CONFIG SET set-max-listpack-value 64
CONFIG GET set-max-listpack-value
CONFIG SET set-max-listpack-value abc
CONFIG SET set-max-intset-entries -1
TYPE s:i
CMDS
)"
		expect_same_pipe "set errors and wrongtype" "$(cat <<'CMDS'
FLUSHALL
SET s:str x
SADD s:set 1 2 3
SADD s:str a
SREM s:str a
SMOVE s:str s:set a
SMOVE s:set s:str 1
SMOVE s:nokey s:str 1
SISMEMBER s:str a
SMISMEMBER s:str a
SCARD s:str
SMEMBERS s:str
SPOP s:str
SPOP s:str 2
SRANDMEMBER s:str
SRANDMEMBER s:str 2
SINTER s:set s:str
SINTER s:nokey s:str
SUNION s:str s:set
SDIFF s:nokey s:str
SINTERCARD 2 s:set s:str
SINTERSTORE s:d s:set s:str
SUNIONSTORE s:d s:str
SDIFFSTORE s:d s:nokey s:str
SSCAN s:str 0
SSCAN s:str abc
SPOP s:set abc
SPOP s:set -1
SPOP s:nokey -1
SPOP s:set 1 2
SRANDMEMBER s:set abc
SRANDMEMBER s:set -9223372036854775808
SRANDMEMBER s:set 1 2
SINTERCARD 0 s:set
SINTERCARD a s:set
SINTERCARD 2 s:set
SINTERCARD 1 s:set FOO
SINTERCARD 1 s:set LIMIT
SINTERCARD 1 s:set LIMIT -1
SINTERCARD 1 s:set LIMIT a
SSCAN s:set abc
SSCAN s:set -1
SSCAN s:set 0 COUNT 0
SSCAN s:set 0 COUNT x
SSCAN s:set 0 NOVALUES
SSCAN s:set 0 TYPE set
SSCAN s:set 0 FOO
SADD s:set
SREM s:set
SMOVE s:a s:b
SISMEMBER s:set
SMISMEMBER s:set
SCARD
SPOP
SRANDMEMBER
SMEMBERS
SINTER
SINTERCARD 1
SINTERSTORE s:d
SUNION
SUNIONSTORE s:d
SDIFF
SDIFFSTORE s:d
SSCAN s:set
CMDS
)"
		expect_same_raw3 "set resp3 replies" "FLUSHALL" "SADD s:r 1 2 3" "SMEMBERS s:r" "SINTER s:r" "SUNION s:r s:nokey" "SDIFF s:r s:nokey" "SPOP s:r 0" "SPOP s:nokey 1" "SRANDMEMBER s:r 0" "SRANDMEMBER s:r 10" "SRANDMEMBER s:nokey 2" "SRANDMEMBER s:nokey" "SPOP s:nokey" "SSCAN s:r 0" "SMISMEMBER s:r 1 4" "SMEMBERS s:nokey" "SINTERCARD 1 s:r" "SISMEMBER s:r 2" "SPOP s:r 5"
		expect_same_pipe "list family" "$(cat <<'CMDS'
FLUSHALL
LPUSH l:a a b c
RPUSH l:a d e 1 -2 9223372036854775807 ""
LPUSHX l:a x
RPUSHX l:a y z
LPUSHX l:none x
RPUSHX l:none x
EXISTS l:none
LLEN l:a
LLEN l:none
LRANGE l:a 0 -1
LRANGE l:a -100 100
LRANGE l:a 5 2
LRANGE l:a -2 -1
LRANGE l:a -9223372036854775808 9223372036854775807
LRANGE l:a abc 1
LRANGE l:none 0 -1
LINDEX l:a 0
LINDEX l:a -1
LINDEX l:a 100
LINDEX l:a -9223372036854775808
LINDEX l:a abc
LINDEX l:none abc
LPOP l:a
RPOP l:a
LPOP l:a 2
RPOP l:a 2
LPOP l:a 0
LPOP l:none
LPOP l:none 0
RPOP l:none 3
LPOP l:a -1
LPOP l:a abc
LPOP l:a 1 2
RPOP l:a 1 2
LSET l:a 0 first
LSET l:a -1 last
LSET l:a 10 x
LSET l:a 4294967296 wrapped
LSET l:a 9223372036854775807 wrapped2
LSET l:none 0 x
LSET l:a abc x
LRANGE l:a 0 -1
LINSERT l:a BEFORE first before
LINSERT l:a after last after
LINSERT l:a middle first x
LINSERT l:a before nopivot x
LINSERT l:none before a b
LRANGE l:a 0 -1
RPUSH l:p a b c 1 2 3 c c a
LPOS l:p c
LPOS l:p c RANK 2
LPOS l:p c RANK -1
LPOS l:p c RANK 4
LPOS l:p c RANK 0
LPOS l:p c RANK -9223372036854775808
LPOS l:p c COUNT 0
LPOS l:p c COUNT 2 RANK -1
LPOS l:p c COUNT 0 MAXLEN 3
LPOS l:p c COUNT 0 MAXLEN 3 RANK -1
LPOS l:p c COUNT -1
LPOS l:p c MAXLEN -1
LPOS l:p c COUNT abc
LPOS l:p x
LPOS l:p x COUNT 1
LPOS l:p c FOO
LPOS l:none c
LPOS l:none c COUNT 1
RPUSH l:r a b a c a d a 1 01
LREM l:r 2 a
LREM l:r -1 a
LREM l:r 0 1
LREM l:r 0 zz
LREM l:r abc a
LREM l:r -9223372036854775808 a
LREM l:none 1 a
LRANGE l:r 0 -1
LTRIM l:r 1 -2
LRANGE l:r 0 -1
LTRIM l:r 5 1
EXISTS l:r
LTRIM l:none 0 1
LTRIM l:p abc 1
RPUSH l:m 1 2 3 4 5
LMOVE l:m l:m LEFT RIGHT
LMOVE l:m l:m RIGHT LEFT
LMOVE l:m l:m LEFT LEFT
LMOVE l:m l:m RIGHT RIGHT
LRANGE l:m 0 -1
LMOVE l:m l:n LEFT RIGHT
LMOVE l:m l:n RIGHT LEFT
LMOVE l:m l:n LEFT LEFT
LMOVE l:m l:n RIGHT RIGHT
RPOPLPUSH l:m l:n
EXISTS l:m
LRANGE l:n 0 -1
RPOPLPUSH l:none l:n
LMOVE l:none l:n LEFT RIGHT
LMOVE l:n l:m up down
RPOPLPUSH l:n l:n
RPUSH l:k1 1 2 3
RPUSH l:k2 4 5 6
LMPOP 2 l:none l:k1 LEFT
LMPOP 2 l:none l:k1 RIGHT COUNT 10
EXISTS l:k1
LMPOP 2 l:k1 l:k2 RIGHT COUNT 2
LMPOP 2 l:none l:none2 LEFT
LMPOP 0 l:k2 LEFT
LMPOP abc l:k2 LEFT
LMPOP 5 l:k2 LEFT
LMPOP 1 l:k2 LEFT COUNT 0
LMPOP 1 l:k2 LEFT COUNT 1 COUNT 2
LMPOP 1 l:k2 MIDDLE
LMPOP 1 l:k2 left count 5
LPUSH
LPUSH l:a
LINSERT l:a before a
LMPOP 1 l:k2
LMOVE l:a l:b LEFT
TYPE l:a
OBJECT ENCODING l:a
DEBUG LISTPACK l:a
DEBUG LISTPACK l:none
DEBUG LISTPACK
CMDS
)"
		expect_same_pipe "list wrongtype" "$(cat <<'CMDS'
FLUSHALL
SET l:s str
RPUSH l:l a b
HSET l:h f v
LPUSH l:s a
RPUSH l:s a
LPUSHX l:s a
RPUSHX l:s a
LINSERT l:s before a b
LLEN l:s
LINDEX l:s 0
LSET l:s 0 a
LPOP l:s
RPOP l:s 2
LMPOP 1 l:s LEFT
LMPOP 2 l:l l:s LEFT
LMPOP 2 l:none l:s LEFT
LRANGE l:s 0 -1
LTRIM l:s 0 -1
LPOS l:s a
LREM l:s 0 a
LMOVE l:s l:l LEFT RIGHT
LMOVE l:l l:s LEFT RIGHT
RPOPLPUSH l:l l:h
LLEN l:h
LRANGE l:l 0 -1
GET l:l
SET l:l x GET
GETEX l:l
GETDEL l:l
GETSET l:l x
APPEND l:l x
STRLEN l:l
SETRANGE l:l 0 x
GETRANGE l:l 0 1
INCR l:l
DECRBY l:l 2
INCRBYFLOAT l:l 1
MGET l:l l:s
LCS l:l l:s
SETBIT l:l 0 1
GETBIT l:l 0
BITCOUNT l:l
BITPOS l:l 1
BITOP AND l:d l:l
BITFIELD l:l GET u8 0
BITFIELD_RO l:l GET u8 0
PFADD l:l a
PFCOUNT l:l
PFMERGE l:d l:l
HGET l:l f
HSET l:l f v
HLEN l:l
SETNX l:l x
MSETNX l:l x
TYPE l:l
SET l:l overwritten
TYPE l:l
GET l:l
RPUSH l:l2 a
SETEX l:l2 100 now-a-string
TYPE l:l2
CMDS
)"
		expect_same_pipe "list encodings" "$(cat <<'CMDS'
FLUSHALL
CONFIG GET list-max-listpack-size
CONFIG GET list-max-ziplist-size
CONFIG GET list-compress-depth
CONFIG SET list-max-listpack-size abc
CONFIG SET list-max-ziplist-size 99999999999
CONFIG SET list-compress-depth -1
CONFIG SET list-max-listpack-size 3
RPUSH l:c a b c
OBJECT ENCODING l:c
RPUSH l:c d
OBJECT ENCODING l:c
RPOP l:c
OBJECT ENCODING l:c
RPOP l:c
OBJECT ENCODING l:c
RPOP l:c
OBJECT ENCODING l:c
CONFIG SET list-max-ziplist-size -1
CONFIG GET list-max-listpack-size
DEL l:c
RPUSH l:c a b c
LSET l:c 0 xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
OBJECT ENCODING l:c
LINSERT l:c after b yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
OBJECT ENCODING l:c
LRANGE l:c 0 -1
CONFIG SET list-max-listpack-size 0
DEL l:c
RPUSH l:c a
OBJECT ENCODING l:c
RPUSH l:c b
OBJECT ENCODING l:c
LPOP l:c
OBJECT ENCODING l:c
CONFIG SET list-max-listpack-size -6
CONFIG GET list-max-listpack-size
CONFIG SET list-max-listpack-size 2
DEL l:c
RPUSH l:c 1 2 3 4 5 6 7
OBJECT ENCODING l:c
LTRIM l:c 0 0
OBJECT ENCODING l:c
DEL l:c
RPUSH l:c a a a d
LREM l:c 3 a
OBJECT ENCODING l:c
CONFIG SET list-max-listpack-size -2
DEBUG QUICKLIST-PACKED-THRESHOLD 1b
DEL l:c
LPUSH l:c 9 xxxxxxxxxx xxxxxxxxxx
OBJECT ENCODING l:c
RPOP l:c
LPOP l:c
LRANGE l:c 0 -1
DEBUG QUICKLIST-PACKED-THRESHOLD 5b
CONFIG SET list-max-listpack-size 4
DEL l:c
RPUSH l:c aa bb cc dd ee
LSET l:c 2 eeeeeeeeee
LINSERT l:c before bb ffffffffff
LRANGE l:c 0 -1
LPOS l:c eeeeeeeeee
LREM l:c 0 ffffffffff
LRANGE l:c 0 -1
DEBUG QUICKLIST-PACKED-THRESHOLD abc
DEBUG QUICKLIST-PACKED-THRESHOLD 5gb
DEBUG QUICKLIST-PACKED-THRESHOLD
DEBUG QUICKLIST-PACKED-THRESHOLD 0
CONFIG SET list-max-listpack-size -2
CONFIG SET list-compress-depth 0
CMDS
)"
		expect_same_pipe "list sort copy and keyspace" "$(cat <<'CMDS'
FLUSHALL
RPUSH l:n 3 1 2 10
SORT l:n
SORT l:n DESC
SORT l:n ALPHA
SORT l:n LIMIT 1 2
SORT l:n BY nosort
SORT l:n BY nosort DESC
SORT l:n BY nosort LIMIT 1 2
SORT l:n BY nosort DESC LIMIT 1 2
SORT l:n BY nosort LIMIT 5 2
SORT l:n STORE l:dst
LRANGE l:dst 0 -1
OBJECT ENCODING l:dst
SET l:dst2 x EX 100
SORT l:n BY nosort STORE l:dst2
TTL l:dst2
TYPE l:dst2
LRANGE l:dst2 0 -1
SORT l:none STORE l:dst2
EXISTS l:dst2
SORT_RO l:n
SORT_RO l:n STORE l:x
RPUSH l:w a b
SORT l:w
SET l:w:a 2
SET l:w:b 1
SORT l:w BY l:w:* GET # GET l:w:*
SORT l:w BY l:w:* GET # GET l:w:* STORE l:dst3
LRANGE l:dst3 0 -1
RENAME l:n l:n2
LRANGE l:n2 0 -1
COPY l:n2 l:n3
LRANGE l:n3 0 -1
OBJECT ENCODING l:n3
COPY l:n2 l:n3
COPY l:n2 l:n3 REPLACE
COPY l:n2 l:n4 DB 1
SELECT 1
LRANGE l:n4 0 -1
SELECT 0
MOVE l:n3 2
SELECT 2
LRANGE l:n3 0 -1
LPUSH l:n3 z
LLEN l:n3
FLUSHDB
SELECT 0
EXPIRE l:n2 100
TTL l:n2
LPUSH l:n2 q
TTL l:n2
DEL l:n2
EXISTS l:n2
SCAN 0 TYPE list MATCH l:dst
DBSIZE
FLUSHALL
CMDS
)"
		expect_same_raw3 "list resp3 replies" "FLUSHALL" "RPUSH r3:l a b c" "LPOP r3:none" "LPOP r3:none 2" "LPOP r3:l 0" "LPOP r3:l 2" "LINDEX r3:none 0" "LPOS r3:l zz" "LPOS r3:l zz COUNT 1" "LMPOP 1 r3:none LEFT" "LMPOP 1 r3:l RIGHT COUNT 3" "LMOVE r3:none r3:l LEFT LEFT" "LRANGE r3:none 0 -1" "FLUSHALL"
		expect_same_pipe "zset family" "$(cat <<'CMDS'
FLUSHALL
ZADD z:a 1 a 2 b 3 c
ZADD z:a 1.5 d -inf e +inf f 0 g 0 aa -0 h 10 007 1e2 x
ZCARD z:a
ZCARD z:nokey
ZSCORE z:a a
ZSCORE z:a e
ZSCORE z:a h
ZSCORE z:a nope
ZSCORE z:nokey a
ZMSCORE z:a a nope f
ZMSCORE z:nokey a b
ZRANGE z:a 0 -1 WITHSCORES
ZRANGE z:a 0 -1 REV
ZRANGE z:a -3 -1 WITHSCORES
ZRANGE z:a 5 2
ZREVRANGE z:a 0 2 WITHSCORES
ZRANK z:a c
ZRANK z:a c WITHSCORE
ZREVRANK z:a c WITHSCORE
ZRANK z:a nope
ZRANK z:a nope WITHSCORE
ZRANK z:nokey a WITHSCORE
ZRANK z:a c WITHSCORES
ZRANK z:a c WITHSCORE extra
ZINCRBY z:a 2.5 a
ZINCRBY z:a 1 newm
ZINCRBY z:a 0.1 newm
ZINCRBY z:a 0.2 newm
ZINCRBY z:a -inf f
ZINCRBY z:a abc a
ZINCRBY z:a nan a
ZADD z:a XX NX 1 a
ZADD z:a GT LT 1 a
ZADD z:a NX GT 1 a
ZADD z:a INCR 1 a 2 b
ZADD z:a INCR 5 a
ZADD z:a INCR XX 5 nope
ZADD z:a GT CH 100 a 0 b 1 brandnew
ZADD z:a LT CH 100 a 0 b
ZADD z:a NX CH 7 a 8 nx1
ZADD z:a XX CH 9 a 9 nx2
ZADD z:a 1 a 2
ZADD z:a nan a
ZADD z:a 1e400 a
ZADD z:a 0x10 hex
ZADD z:a " 1" sp
ZADD z:a "" empty
ZADD z:inf inf a
ZINCRBY z:inf -inf a
ZADD z:xx XX 1 a
EXISTS z:xx
ZINCRBY z:new 3 m
ZADD z:a CH CH
ZREM z:a a nope b
ZREM z:nokey a
ZREM z:one m
ZADD z:one 1 m
ZREM z:one m other
EXISTS z:one
TYPE z:a
OBJECT ENCODING z:a
ZRANGE z:a 0 -1 WITHSCORES
CMDS
)"
		expect_same_pipe "zset ranges" "$(cat <<'CMDS'
FLUSHALL
ZADD z:r -inf a 1 b 2 c 3 d 4 e 5 f +inf g
ZRANGEBYSCORE z:r -inf 2
ZRANGEBYSCORE z:r (0 (3 WITHSCORES
ZRANGEBYSCORE z:r (-inf (+inf
ZRANGEBYSCORE z:r 2 (2
ZRANGEBYSCORE z:r "" ""
ZRANGEBYSCORE z:r ( 3
ZRANGEBYSCORE z:r " 2" 3
ZRANGEBYSCORE z:r 1e400 -1e400
ZRANGEBYSCORE z:r 0 10 LIMIT 2 3
ZRANGEBYSCORE z:r 0 10 LIMIT -1 3
ZRANGEBYSCORE z:r 0 10 LIMIT 20 3
ZRANGEBYSCORE z:r 0 10 LIMIT 1 -1 WITHSCORES
ZRANGEBYSCORE z:r 0 10 LIMIT 1
ZRANGEBYSCORE z:r 0 10 LIMIT a 1
ZRANGEBYSCORE z:r str 1
ZRANGEBYSCORE z:r 1 nan
ZREVRANGEBYSCORE z:r +inf 4
ZREVRANGEBYSCORE z:r (6 (3 LIMIT 1 2 WITHSCORES
ZRANGE z:r (1 5 BYSCORE
ZRANGE z:r 5 (1 BYSCORE REV LIMIT 1 2 WITHSCORES
ZRANGE z:r 0 -1 LIMIT 0 1
ZRANGE z:r 0 -1 LIMIT 0 -1
ZRANGE z:r 0 -1 BYSCORE BYLEX
ZRANGE z:r 0 -1 REV REV
ZRANGE z:r - + BYLEX WITHSCORES
ZRANGE z:r a 1
ZCOUNT z:r -inf +inf
ZCOUNT z:r (1 (5
ZCOUNT z:r 3 1
ZCOUNT z:r a 1
ZCOUNT z:nokey 0 1
ZADD z:l 0 alpha 0 bar 0 cool 0 down 0 elephant 0 foo 0 great 0 hill 0 omega
ZRANGEBYLEX z:l - [cool
ZRANGEBYLEX z:l [bar [down
ZRANGEBYLEX z:l (bar (down
ZRANGEBYLEX z:l [g +
ZRANGEBYLEX z:l + -
ZRANGEBYLEX z:l - + LIMIT 2 3
ZRANGEBYLEX z:l - + LIMIT 2 -1
ZRANGEBYLEX z:l - + WITHSCORES
ZRANGEBYLEX z:l a +
ZRANGEBYLEX z:l [a +a
ZREVRANGEBYLEX z:l [cool -
ZREVRANGEBYLEX z:l + (great LIMIT 0 1
ZRANGE z:l [d (h BYLEX REV
ZRANGE z:l (h [d BYLEX REV LIMIT 1 1
ZLEXCOUNT z:l - +
ZLEXCOUNT z:l [ele [h
ZLEXCOUNT z:l + -
ZLEXCOUNT z:l foo +
ZLEXCOUNT z:nokey - +
ZREMRANGEBYLEX z:l [alpha (cool
ZREMRANGEBYLEX z:l foo +
ZREMRANGEBYSCORE z:r (1 3
ZREMRANGEBYSCORE z:r str 3
ZREMRANGEBYRANK z:r -2 -1
ZREMRANGEBYRANK z:r 5 1
ZREMRANGEBYRANK z:r a 1
ZRANGE z:r 0 -1 WITHSCORES
ZRANGE z:l 0 -1
ZREMRANGEBYRANK z:r 0 -1
EXISTS z:r
ZRANGESTORE z:dst z:l 0 2
ZRANGE z:dst 0 -1 WITHSCORES
ZRANGESTORE z:dst z:l [f + BYLEX REV
ZRANGESTORE z:dst z:l (1 2 BYSCORE
EXISTS z:dst
ZRANGESTORE z:dst z:nokey 0 -1
ZRANGESTORE z:dst z:l 0 -1 WITHSCORES
ZRANGESTORE z:dst z:l 0 -1 LIMIT 0 1
CMDS
)"
		expect_same_pipe "zset algebra" "$(cat <<'CMDS'
FLUSHALL
ZADD z:ua 1 a 2 b 3 c
ZADD z:ub 1 b 2 c 3 d
ZADD z:ia inf x -inf y 1 z
ZADD z:ib -inf x inf y 0 z
SET z:str v
ZUNION 2 z:ua z:ub WITHSCORES
ZUNION 2 z:ua z:ub WEIGHTS 2 3 AGGREGATE MIN WITHSCORES
ZUNION 2 z:ua z:ub AGGREGATE MAX
ZINTER 2 z:ua z:ub WITHSCORES
ZINTER 2 z:ua z:ub WEIGHTS 2 3 WITHSCORES
ZINTERCARD 2 z:ua z:ub
ZINTERCARD 2 z:ua z:ub LIMIT 1
ZINTERCARD 1 z:ua LIMIT -1
ZDIFF 2 z:ua z:ub WITHSCORES
ZDIFF 2 z:ua z:ua
ZUNION 2 z:ia z:ib WITHSCORES
ZINTER 2 z:ia z:ib WITHSCORES
ZINTER 2 z:ia z:ib WEIGHTS 0 1 WITHSCORES
ZUNION 2 z:ia z:ib WEIGHTS 0 0 AGGREGATE MAX WITHSCORES
ZUNION 2 z:ia z:ib WEIGHTS nan 1
ZUNION 2 z:ia z:ib WEIGHTS 1
ZUNION 2 z:ia z:ib AGGREGATE AVG
ZUNION 0 z:ia
ZUNION 3 z:ia z:ib
ZUNION 1 z:str
ZINTERCARD 0 z:ua
ZUNIONSTORE z:dst 2 z:ua z:ub
ZRANGE z:dst 0 -1 WITHSCORES
ZINTERSTORE z:dst 2 z:ua z:ub WEIGHTS 1 -1
ZRANGE z:dst 0 -1 WITHSCORES
ZDIFFSTORE z:dst 2 z:ub z:ua
ZRANGE z:dst 0 -1 WITHSCORES
ZUNIONSTORE z:ua 2 z:ua z:ub
ZRANGE z:ua 0 -1 WITHSCORES
ZINTERSTORE z:dst 2 z:ua z:nokey
EXISTS z:dst
ZUNIONSTORE z:str 1 z:ub
TYPE z:str
ZUNIONSTORE z:dst 1 z:ub WITHSCORES
SADD z:set a b x 1 007 -3
SADD z:int 1 2 3 1000000
ZUNION 2 z:set z:ub WITHSCORES
ZUNION 3 z:set z:ub z:int WEIGHTS 2 3 0.5 AGGREGATE MAX WITHSCORES
ZINTER 2 z:ub z:set WITHSCORES
ZINTER 2 z:set z:set WEIGHTS 1 2 WITHSCORES
ZINTERCARD 2 z:set z:ub
ZINTERCARD 2 z:set z:int LIMIT 1
ZDIFF 2 z:set z:ub WITHSCORES
ZDIFF 2 z:set z:set
ZDIFF 2 z:ub z:set WITHSCORES
ZUNIONSTORE z:dst 2 z:int z:set
ZRANGE z:dst 0 -1 WITHSCORES
OBJECT ENCODING z:dst
ZINTERSTORE z:dst 2 z:int z:ub
EXISTS z:dst
ZDIFFSTORE z:set 2 z:set z:ub
TYPE z:set
ZRANGE z:set 0 -1 WITHSCORES
CMDS
)"
		expect_same_pipe "zset pops and random" "$(cat <<'CMDS'
FLUSHALL
ZADD z:p 1 a 2 b 3 c 4 d 5 e 6 f
ZPOPMIN z:p
ZPOPMAX z:p 2
ZPOPMIN z:p 0
ZPOPMIN z:p -1
ZPOPMIN z:p a
ZPOPMIN z:p 1 2
ZMPOP 2 z:nokey z:p MIN COUNT 2
ZMPOP 1 z:p MAX
ZMPOP 1 z:nokey MIN
ZMPOP 0 z:p MIN
ZMPOP 1 z:p MIDDLE
ZMPOP 1 z:p MIN COUNT 0
ZMPOP 1 z:p MIN COUNT 1 COUNT 2
ZMPOP 2 z:p MIN
ZPOPMAX z:p 10
EXISTS z:p
ZPOPMIN z:nokey
ZADD z:q 3 c 1 a 2 b
ZRANDMEMBER z:q 0
ZRANDMEMBER z:q 3
ZRANDMEMBER z:q 10 WITHSCORES
ZRANDMEMBER z:nokey
ZRANDMEMBER z:nokey 3
ZRANDMEMBER z:q abc
ZRANDMEMBER z:q 1 WITHSCORE
ZRANDMEMBER z:q -9223372036854775808
ZRANDMEMBER z:q -9223372036854770000 WITHSCORES
CMDS
)"
		expect_same_pipe "zset encodings and config" "$(cat <<'CMDS'
FLUSHALL
CONFIG GET zset-max-listpack-entries
CONFIG GET zset-max-ziplist-entries
CONFIG GET zset-max-listpack-value
CONFIG GET zset-max-ziplist-value
CONFIG SET zset-max-listpack-entries 2
ZADD z:e 1 a 2 b
OBJECT ENCODING z:e
ZADD z:e 3 c
OBJECT ENCODING z:e
ZREM z:e a b
OBJECT ENCODING z:e
ZUNIONSTORE z:e2 1 z:e
OBJECT ENCODING z:e2
ZADD z:e3 1 a 2 b 3 c
OBJECT ENCODING z:e3
CONFIG SET zset-max-ziplist-entries 128
CONFIG SET zset-max-listpack-value 4
ZADD z:v 1 abcd
OBJECT ENCODING z:v
ZADD z:v 1 abcde
OBJECT ENCODING z:v
ZADD z:v2 1 abcde
OBJECT ENCODING z:v2
CONFIG SET zset-max-ziplist-value 1kb
CONFIG GET zset-max-listpack-value
CONFIG SET zset-max-listpack-value abc
CONFIG SET zset-max-listpack-value -1
CONFIG SET zset-max-listpack-entries 1k
CONFIG SET zset-max-ziplist-entries -1
CONFIG SET zset-max-listpack-value 64
ZRANGESTORE z:e4 z:e3 0 -1
OBJECT ENCODING z:e4
SORT z:e3
OBJECT ENCODING z:e3
SORT z:e3 BY nosort DESC
CONFIG GET zset-max-listpack-value
CMDS
)"
		expect_same_pipe "zset wrongtype and generic" "$(cat <<'CMDS'
FLUSHALL
SET z:s str
HSET z:h f v
ZADD z:z 1 a 2 b 3 c
ZADD z:s 1 a
ZADD z:h 1 a
ZSCORE z:s a
ZRANGE z:h 0 -1
ZCARD z:s
ZRANK z:h a
ZPOPMIN z:s
ZMPOP 2 z:nokey z:s MIN
ZRANDMEMBER z:h 2
ZSCAN z:s 0
ZUNION 2 z:z z:h
ZRANGESTORE z:dst z:s 0 -1
ZINCRBY z:s 1 a
ZREMRANGEBYRANK z:h 0 1
GET z:z
APPEND z:z x
INCR z:z
HSET z:z f v
HGET z:z f
SETBIT z:z 1 1
PFADD z:z a
LCS z:z z:s
SET z:z overwritten
TYPE z:z
ZADD z:z 1 a 2 b 3 c
TYPE z:z
OBJECT ENCODING z:z
EXISTS z:z
COPY z:z z:copy
ZRANGE z:copy 0 -1 WITHSCORES
COPY z:z z:copy
COPY z:z z:copy REPLACE
COPY z:z z:copy DB 3
SELECT 3
ZRANGE z:copy 0 -1 WITHSCORES
SELECT 0
RENAME z:z z:renamed
ZRANGE z:renamed 0 -1 WITHSCORES
MOVE z:renamed 5
SELECT 5
ZSCORE z:renamed b
SELECT 0
SCAN 0 TYPE zset COUNT 1000
SORT z:copy
SORT z:copy DESC ALPHA
SORT z:copy BY nosort
SORT z:copy BY nosort DESC LIMIT 1 1
SORT z:copy BY nosort LIMIT 5 10
ZADD z:sortme 1 3 2 1 3 2
SORT z:sortme
SORT z:sortme BY nosort
EXPIRE z:copy 100
TTL z:copy
DEL z:copy z:sortme
FLUSHALL
CMDS
)"
		expect_same_pipe "zset scan" "$(cat <<'CMDS'
FLUSHALL
ZADD z:sc 1 m1 2 m2 3.5 m3 0.1 x1 inf y -0 z 1e300 big
ZSCAN z:sc 0
ZSCAN z:sc 0 MATCH m*
ZSCAN z:sc 7 COUNT 1
ZSCAN z:sc abc
ZSCAN z:sc 0 COUNT 0
ZSCAN z:sc 0 NOVALUES
ZSCAN z:sc 0 TYPE zset
ZSCAN z:nokey 0
CONFIG SET zset-max-listpack-entries 0
ZADD z:ss 1 m1
ZSCAN z:ss 0
ZADD z:ss 0.1 m2
ZSCAN z:ss 0 MATCH m2
CONFIG SET zset-max-listpack-entries 128
CMDS
)"
		zset_big="$(printf 'ZADD z:big'; for i in $(seq 1 300); do printf ' %s.%s m%s' "$((i % 37))" "$i" "$i"; done; printf '\n')"
		expect_same_sorted_pipe "zset scan over the skiplist" "$(printf '%s\n' 'FLUSHALL' "$zset_big" 'ZSCAN z:big 0 COUNT 100000' 'ECHO ---' 'ZSCAN z:big 0 MATCH m1* COUNT 100000')"
		expect_same_pipe "zset skiplist reads" "$(printf '%s\n' 'FLUSHALL' "$zset_big" 'OBJECT ENCODING z:big' 'ZCARD z:big' 'ZRANGE z:big 100 120 WITHSCORES' 'ZRANGE z:big 0 4 REV WITHSCORES' 'ZRANGEBYSCORE z:big (5 6 LIMIT 3 4 WITHSCORES' 'ZREVRANGEBYSCORE z:big 30 (20 LIMIT 15 3' 'ZCOUNT z:big (10 20' 'ZRANK z:big m150 WITHSCORE' 'ZREVRANK z:big m150' 'ZSCORE z:big m77' 'ZRANDMEMBER z:big 400 WITHSCORES' 'ZPOPMIN z:big 3' 'ZPOPMAX z:big' 'ZMPOP 1 z:big MAX COUNT 2' 'ZREMRANGEBYRANK z:big 0 9' 'ZREMRANGEBYSCORE z:big 30 +inf' 'ZINTERSTORE z:i 1 z:big WEIGHTS 0.5' 'OBJECT ENCODING z:i' 'ZRANGE z:i 0 4 WITHSCORES' 'ZRANGESTORE z:rs z:big 0 99' 'OBJECT ENCODING z:rs' 'ZRANGESTORE z:rs z:big 0 199' 'OBJECT ENCODING z:rs' 'ZCARD z:big')"
		expect_same_raw3 "zset resp3 replies" "FLUSHALL" "ZADD z:r3 1 a 2.5 b" "ZRANGE z:r3 0 -1 WITHSCORES" "ZSCORE z:r3 b" "ZSCORE z:r3 nope" "ZMSCORE z:r3 a nope" "ZINCRBY z:r3 0.5 a" "ZADD z:r3 INCR GT 0 a" "ZADD z:r3 INCR 1 a" "ZRANK z:r3 b WITHSCORE" "ZRANK z:r3 nope WITHSCORE" "ZRANK z:r3 nope" "ZRANDMEMBER z:r3 5 WITHSCORES" "ZUNION 1 z:r3 WITHSCORES" "ZRANGEBYSCORE z:r3 -inf +inf WITHSCORES LIMIT 0 1" "ZPOPMIN z:r3" "ZADD z:r3 3 c 4 d" "ZPOPMAX z:r3 2" "ZMPOP 1 z:r3 MIN COUNT 5" "ZMPOP 1 z:r3 MIN" "ZPOPMIN z:nokey" "ZRANDMEMBER z:nokey" "ZSCAN z:nokey 0"
		expect_same_pipe "geo family" "$(cat <<'CMDS'
FLUSHALL
GEOADD g:s 13.361389 38.115556 Palermo 15.087269 37.502669 Catania
GEOADD g:s CH 13.361389 38.115556 Palermo 15.1 37.5 Catania
GEOADD g:s NX 1 1 Palermo 2 2 New
GEOADD g:s XX CH 13.361389 38.115556 Palermo 3 3 Other
GEOADD g:s XX NX 1 1 a
GEOADD g:s 1 1 a 2
GEOADD g:s 200 100 bad
GEOADD g:s 1e300 1 bad
GEOADD g:s abc 1 bad
GEOADD g:s 180 85.05112878 corner
ZRANGE g:s 0 -1 WITHSCORES
GEOPOS g:s Palermo nope Catania corner
GEOPOS g:nokey a
GEOHASH g:s Palermo nope corner
GEOHASH g:nokey a
GEODIST g:s Palermo Catania
GEODIST g:s Palermo Catania km
GEODIST g:s Palermo Catania MI
GEODIST g:s Palermo Catania ft
GEODIST g:s Palermo nope
GEODIST g:s Palermo Catania parsec
GEODIST g:s Palermo Catania km extra
GEORADIUS g:s 15 37 200 km ASC WITHDIST WITHCOORD WITHHASH
GEORADIUS g:s 15 37 200 km COUNT 1 DESC
GEORADIUS g:s 15 37 200 km COUNT 1 ANY
GEORADIUS g:s 15 37 200 km ANY
GEORADIUS g:s 15 37 -1 km
GEORADIUS g:s 15 37 1 parsec
GEORADIUS g:s 15 37 1 km COUNT 0
GEORADIUS g:s 15 37 200 km STORE g:dst WITHDIST
GEORADIUS g:s 15 37 200 km STOREDIST g:dst
ZRANGE g:dst 0 -1 WITHSCORES
GEORADIUS_RO g:s 15 37 200 km STORE g:dst
GEORADIUSBYMEMBER g:s Palermo 200 km WITHDIST
GEORADIUSBYMEMBER g:s nope 200 km
GEORADIUSBYMEMBER_RO g:s Palermo 200 km DESC
GEOSEARCH g:s FROMLONLAT 15 37 BYBOX 400 400 km ASC WITHDIST WITHCOORD
GEOSEARCH g:s FROMMEMBER Palermo BYRADIUS 200 km WITHHASH
GEOSEARCH g:s FROMMEMBER nope BYRADIUS 200 km
GEOSEARCH g:s BYRADIUS 200 km
geosearch g:s FROMLONLAT 15 37 ASC
GEOSEARCH g:s FROMLONLAT 15 37 FROMMEMBER Palermo BYRADIUS 1 km
GEOSEARCH g:s FROMLONLAT 15 37 BYRADIUS 1 km BYBOX 1 1 km
GEOSEARCH g:s FROMLONLAT 15 37 BYBOX -1 1 km
GEOSEARCH g:s FROMLONLAT 15 37 BYRADIUS 200 km STOREDIST
GEOSEARCHSTORE g:dst g:s FROMLONLAT 15 37 BYRADIUS 200 km STOREDIST
ZRANGE g:dst 0 -1 WITHSCORES
GEOSEARCHSTORE g:dst g:s FROMLONLAT 15 37 BYRADIUS 200 km WITHDIST
GEOSEARCHSTORE g:dst g:s FROMLONLAT 100 0 BYRADIUS 1 km
EXISTS g:dst
GEOSEARCHSTORE g:dst g:nokey FROMLONLAT 15 37 BYRADIUS 1 km
SET g:str v
GEOADD g:str 1 1 a
GEOPOS g:str a
GEORADIUS g:str 15 37 1 km
GEOSEARCH g:str FROMLONLAT 15 37 BYRADIUS 1 km
GEOADD g:pole 45 65 n1 -135 85.05 n2 179.5 36 p1 -179.5 36 p2
GEORADIUSBYMEMBER g:pole n1 5009431 m
GEOSEARCH g:pole FROMLONLAT 179 37 BYBOX 400 400 km ASC
GEOSEARCH g:pole FROMLONLAT -179 37 BYBOX 400 400 km ASC WITHCOORD
GEORADIUS g:pole 0 0 50000 km WITHCOORD
TYPE g:s
OBJECT ENCODING g:s
FLUSHALL
CMDS
)"
		expect_same_raw3 "geo resp3 replies" "FLUSHALL" "GEOADD g:r 13.361389 38.115556 Palermo 15.087269 37.502669 Catania" "GEOPOS g:r Palermo nope" "GEODIST g:r Palermo Catania km" "GEOHASH g:r Palermo nope" "GEORADIUS g:r 15 37 200 km WITHDIST WITHCOORD WITHHASH ASC" "GEOSEARCH g:r FROMMEMBER Catania BYBOX 300 300 km WITHCOORD" "GEOSEARCH g:nokey FROMMEMBER x BYRADIUS 1 km" "GEODIST g:nokey a b"
		expect_same_blocking
		expect_blocking_stress
		expect_stream_group_stress
		expect_same_pipe "stream family" "$(cat <<'CMDS'
FLUSHALL
XADD x:s 1-1 a 1 b 2
XADD x:s 1-2 a 3 b 4
XADD x:s 1-* a 5 c 6
XADD x:s 2 x y
XADD x:s 2 x y
XADD x:s 0-0 x y
XADD x:s 3-* 7 -1 007 abc
XADD x:none NOMKSTREAM 5-5 a b
EXISTS x:none
XADD x:z 0-* a b
XADD x:z 18446744073709551615-18446744073709551615 a b
XADD x:z 18446744073709551615-* a b
XLEN x:s
XRANGE x:s - +
XRANGE x:s (1-1 + COUNT 2
XREVRANGE x:s + - COUNT 2
XREVRANGE x:s (3 (1-1
XRANGE x:s (- +
XRANGE x:s - (+
XRANGE x:s - (0-0
XRANGE x:s (18446744073709551615-18446744073709551615 +
XRANGE x:s 1 1
XRANGE x:s - + COUNT 0
XRANGE x:s - + COUNT -1
XRANGE x:s - + COUNT x
XRANGE x:s - + LIMIT 1
XRANGE x:nokey - +
XDEL x:s 1-2 9-9
XDEL x:s abc
XDEL x:nokey abc
XINFO STREAM x:s
XINFO STREAM x:s FULL
XINFO STREAM x:s FULL COUNT 1
XINFO STREAM x:s FULL COUNT
XINFO STREAM x:s FULLY
XINFO STREAM x:nokey
XINFO STREAM
XINFO GROUPS x:s
XINFO CONSUMERS x:s g
XINFO HELP
XINFO HELP x
XINFO FOO x:s
XTRIM x:s MAXLEN 3
XTRIM x:s MAXLEN 1 LIMIT 5
XTRIM x:s LIMIT 5
XTRIM x:s
XTRIM x:s MINID -
XTRIM x:s MAXLEN -1
XTRIM x:nokey MAXLEN 1
XADD x:s MAXLEN 1 MINID 1 3 a b
XADD x:s MAXLEN ~ 1 LIMIT 1 4 a b
XADD x:s MAXLEN 1 4 a
XRANGE x:s - +
XSETID x:s 1-0
XSETID x:s 10-0 ENTRIESADDED 50 MAXDELETEDID 9-0
XSETID x:s 10-0 ENTRIESADDED -1
XSETID x:s 10-0 MAXDELETEDID 11-0
XSETID x:s 10-0 0
XSETID x:nokey 1-1
XINFO STREAM x:s
XREAD STREAMS x:s 0
XREAD COUNT 1 STREAMS x:nokey x:s 0 0
XREAD STREAMS x:s x:s 0 3
XREAD STREAMS x:s +
XREAD STREAMS x:s $
XREAD STREAMS x:nokey +
XREAD STREAMS x:s x:t 0
XREAD STREAMS x:s >
XREAD STREAMS x:s abc
XREAD COUNT x STREAMS x:s 0
XREAD BLOCK -1 STREAMS x:s 0
XREAD BLOCK x STREAMS x:s 0
XREAD BLOCK 100 STREAMS x:s 0
XREAD GROUP g c STREAMS x:s 0
XREAD NOACK STREAMS x:s 0
XREAD FOO STREAMS x:s 0
TYPE x:s
OBJECT ENCODING x:s
XADD x:s
XRANGE x:s -
XDEL x:s
XTRIM x:s MAXLEN
XSETID x:s
XREAD STREAMS x:s
XLEN
XINFO
CMDS
)"
		stream_feed="$(
			printf 'FLUSHALL\nCONFIG GET stream-node-max-entries\nCONFIG GET stream-node-max-bytes\n'
			printf 'CONFIG SET stream-node-max-entries -1\nCONFIG SET stream-node-max-bytes 1x\nCONFIG SET stream-node-max-entries 7\n'
			for i in $(seq 1 120); do
				if [ $((i % 9)) -eq 0 ]; then
					printf 'XADD x:n %d-%d item %d otherfield foo\n' $((i / 3 + 1)) $((i % 3)) "$i"
				else
					printf 'XADD x:n %d-%d item %d\n' $((i / 3 + 1)) $((i % 3)) "$i"
				fi
			done
			printf 'XINFO STREAM x:n\nXTRIM x:n MAXLEN ~ 100\nXINFO STREAM x:n\nXTRIM x:n MINID ~ 20\nXINFO STREAM x:n\nXTRIM x:n MINID 25-1\nXINFO STREAM x:n\n'
			for i in $(seq 30 3 90); do
				printf 'XDEL x:n %d-%d\n' $((i / 3 + 1)) $((i % 3))
			done
			printf 'XINFO STREAM x:n FULL COUNT 3\nXRANGE x:n 20 25\nXREVRANGE x:n 35 (30\nXTRIM x:n MAXLEN ~ 0 LIMIT 14\nXINFO STREAM x:n\n'
			printf 'CONFIG SET stream-node-max-entries 100\nCONFIG SET stream-node-max-bytes 120\n'
			for i in $(seq 1 40); do
				printf 'XADD x:b %d f %s\n' "$i" "$(printf '%*s' $((i * 3)) '' | tr ' ' v)"
			done
			printf 'XINFO STREAM x:b\nXRANGE x:b 10 12\nCONFIG SET stream-node-max-bytes 4096\nCONFIG GET stream-node-max-bytes\n'
		)"
		expect_same_pipe "stream nodes and trimming" "$stream_feed"
		expect_same_pipe "stream wrongtype and keyspace" "$(cat <<'CMDS'
FLUSHALL
SET x:str v
XADD x:s 1-1 a 1
XADD x:str 1-1 a b
XLEN x:str
XRANGE x:str - +
XREVRANGE x:str + -
XDEL x:str 1-1
XTRIM x:str MAXLEN 1
XSETID x:str 1-1
XINFO STREAM x:str
XREAD STREAMS x:str 0
GET x:s
APPEND x:s x
LPUSH x:s x
HSET x:s f v
SADD x:s m
SORT x:s
TYPE x:s
COPY x:s x:c
COPY x:s x:c
XADD x:c 2-2 b 2
XRANGE x:s - +
XRANGE x:c - +
COPY x:c x:d DB 1
SELECT 1
XRANGE x:d - +
SELECT 0
RENAME x:c x:r
XRANGE x:r - +
MOVE x:r 2
SELECT 2
XINFO STREAM x:r
FLUSHDB
SELECT 0
EXPIRE x:s 100
TTL x:s
XADD x:s 2-2 b 2
TTL x:s
SCAN 0 TYPE stream
DEL x:s
EXISTS x:s
XADD x:e MAXLEN 0 1-1 a b
EXISTS x:e
XLEN x:e
XINFO STREAM x:e
FLUSHALL
CMDS
)"
		expect_same_raw3 "stream resp3 replies" "FLUSHALL" "XADD r3:s 1-1 a 1" "XADD r3:s 2-1 b 2" "XREAD STREAMS r3:s r3:none 0 0" "XREAD STREAMS r3:none 0" "XRANGE r3:s - + COUNT 0" "XINFO STREAM r3:s" "XINFO STREAM r3:s FULL" "XADD r3:none NOMKSTREAM 1-1 a b" "XDEL r3:s 1-1 2-1" "XINFO STREAM r3:s" "FLUSHALL"
		expect_same_pipe "stream consumer groups" "$(cat <<'CMDS'
FLUSHALL
SET x:str v
XADD x:g 1-1 a 1
XADD x:g 1-2 b 2
XADD x:g 1-3 c 3
XADD x:g 2-0 d 4
XGROUP CREATE x:g g1 0
XGROUP CREATE x:g g1 0
XGROUP CREATE x:g g2 $ ENTRIESREAD 3
XGROUP CREATE x:g g3 0 ENTRIESREAD -3
XGROUP CREATE x:g g3 abc
XGROUP CREATE x:g g3 0 FOO
XGROUP CREATE x:nokey g 0
XGROUP CREATE x:nokey g $ MKSTREAM
XGROUP CREATE x:str g 0
XGROUP SETID x:g nog 0
XGROUP SETID x:g g2 - ENTRIESREAD 0
XGROUP HELP
XGROUP HELP x
XGROUP FOO
XGROUP CREATE x:g
XINFO GROUPS x:g
XREADGROUP GROUP g1 alice COUNT 2 STREAMS x:g >
XREADGROUP GROUP g1 bob STREAMS x:g >
XREADGROUP GROUP g1 alice STREAMS x:g 0
XREADGROUP GROUP g1 bob STREAMS x:g 0
XREADGROUP GROUP g1 bob STREAMS x:g >
XREADGROUP GROUP g1 bob BLOCK 10 STREAMS x:g 0
XREADGROUP GROUP nog alice STREAMS x:g >
XREADGROUP GROUP g1 alice STREAMS x:nope >
XREADGROUP GROUP g1 alice STREAMS x:g $
XREADGROUP GROUP g1 alice STREAMS x:g +
XREADGROUP COUNT 1 NOACK STREAMS x:g 0
XREADGROUP GROUP g1 alice COUNT 1 STREAMS x:g
XREAD GROUP g1 a STREAMS x:g 0
XACK x:g g1 1-2 1-3 9-9
XACK x:g g1 abc
XACK x:g nog abc
XPENDING x:g g1
XPENDING x:g g1 IDLE 99999999 - + 10
XPENDING x:g g1 - + abc
XPENDING x:g g1 -
XPENDING x:g nog
XGROUP CREATECONSUMER x:g g1 carol
XGROUP CREATECONSUMER x:g g1 carol
XGROUP DELCONSUMER x:g g1 bob
XGROUP DELCONSUMER x:g g1 bob
XCLAIM x:g g1 carol 0 1-1 1-2 2-0 JUSTID
XCLAIM x:g g1 carol 0 1-3 FORCE JUSTID RETRYCOUNT 7
XCLAIM x:g g1 carol 0 1-1
XCLAIM x:g g1 carol abc 1-1
XCLAIM x:g g1 carol 0 1-1 FOO
XCLAIM x:g g1 carol 0 1-1 IDLE x
XCLAIM x:nokey2 g1 carol 0 1-1
XAUTOCLAIM x:g g1 dave 0 - COUNT 1
XAUTOCLAIM x:g g1 dave 0 0 JUSTID
XAUTOCLAIM x:g g1 dave 0 - COUNT 0
XAUTOCLAIM x:g g1 dave abc -
XAUTOCLAIM x:g g1 dave 0 - FOO
XDEL x:g 1-1
XAUTOCLAIM x:g g1 dave 0 0
XPENDING x:g g1
XINFO GROUPS x:g
XINFO CONSUMERS x:g nog
XGROUP DESTROY x:g g2
XGROUP DESTROY x:g g2
COPY x:g x:g2
XINFO GROUPS x:g2
XPENDING x:g2 g1
XADD x:lag 1-0 data a
XADD x:lag 2-0 data b
XADD x:lag 3-0 data c
XDEL x:lag 2-0
XGROUP CREATE x:lag lg 0
XINFO GROUPS x:lag
XREADGROUP GROUP lg c COUNT 1 STREAMS x:lag >
XINFO GROUPS x:lag
XREADGROUP GROUP lg c STREAMS x:lag >
XINFO GROUPS x:lag
XADD x:lag 4-0 data d
XTRIM x:lag MAXLEN 1
XINFO GROUPS x:lag
FLUSHALL
CMDS
)"
		expect_same_raw3 "stream group resp3 replies" "FLUSHALL" "XADD r3:g 1-1 a 1" "XGROUP CREATE r3:g g 0" "XREADGROUP GROUP g c STREAMS r3:g >" "XREADGROUP GROUP g c STREAMS r3:g 0" "XREADGROUP GROUP g c STREAMS r3:g >" "XPENDING r3:g g" "XACK r3:g g 1-1" "XPENDING r3:g g" "XINFO GROUPS r3:g" "XAUTOCLAIM r3:g g c 0 -" "XGROUP CREATE r3:e g $ MKSTREAM" "XINFO GROUPS r3:e" "FLUSHALL"
		expect "stream group setup" "OK" xgroup create x:c g1 '$' MKSTREAM
		expect "stream group consumer created" "1" xgroup createconsumer x:c g1 alice
		expect_match "stream group consumer idle" '^name.alice.pending.0.idle.[0-9]+.inactive.-1$' xinfo consumers x:c g1
		expect "stream group flush" "OK" flushall
		expect_match "stream auto id" '^[0-9]+-0$' xadd x:auto '*' f v
		expect_match "stream auto id in the same millisecond" '^[0-9]+-[0-9]+$' xadd x:auto '*' f v
		expect_match "stream debug object" 'encoding:stream serializedlength:[0-9]+ ' debug object x:auto
		expect_match "stream memory usage" '^[0-9]+$' memory usage x:auto
		expect "stream flush" "OK" flushall
		expect_same_parser
		expect_same "config get client-output-buffer-limit" config get client-output-buffer-limit
		expect_same "obuf limit wrong number" config set client-output-buffer-limit "wrong number"
		expect_same "obuf limit invalid class" config set client-output-buffer-limit "invalid_class 10mb 10mb 60"
		expect_same "obuf limit master class" config set client-output-buffer-limit "master 10mb 10mb 60"
		expect_same "obuf limit bad hard" config set client-output-buffer-limit "normal 10mbs 10mb 60"
		expect_same "obuf limit bad soft" config set client-output-buffer-limit "replica 10mb 10mbs 60"
		expect_same "obuf limit bad seconds" config set client-output-buffer-limit "pubsub 10mb 10mb 60s"
		expect_same "obuf limit negative seconds" config set client-output-buffer-limit "pubsub 10mb 10mb -1"
		expect_same "obuf limit double space" config set client-output-buffer-limit "pubsub 1mb  2mb 3"
		expect_same "obuf limit set all classes" config set client-output-buffer-limit "normal 1mb 2mb 60 replica 3mb 4mb 70 pubsub 5mb 6mb 80"
		expect_same "obuf limit get after set" config get client-output-buffer-limit
		expect_same "obuf limit set one class" config set client-output-buffer-limit "PUBSUB 1kb 2k 3"
		expect_same "obuf limit get after one class" config get client-output-buffer-limit
		expect_same "obuf limit restore" config set client-output-buffer-limit "normal 0 0 0 slave 268435456 67108864 60 pubsub 33554432 8388608 60"
		expect_same "obuf limit get restored" config get client-output-buffer-limit
		expect_same "maxmemory bad value" config set maxmemory 12abc
		expect_same "maxmemory negative" config set maxmemory -1
		expect_same "maxmemory set" config set maxmemory 1gb
		expect_same "maxmemory get" config get maxmemory
		expect_same "maxmemory restore" config set maxmemory 0
		expect_same "notify events default" config get notify-keyspace-events
		expect_same "notify events set KEA" config set notify-keyspace-events KEA
		expect_same "notify events get after KEA" config get notify-keyspace-events
		expect_same "notify events set gKE" config set notify-keyspace-events gKE
		expect_same "notify events get after gKE" config get notify-keyspace-events
		expect_same "notify events set every class" config set notify-keyspace-events '$lshzxeKEtmdn'
		expect_same "notify events get every class" config get notify-keyspace-events
		expect_same "notify events set KA" config set notify-keyspace-events KA
		expect_same "notify events get after KA" config get notify-keyspace-events
		expect_same "notify events set Em" config set notify-keyspace-events Em
		expect_same "notify events get after Em" config get notify-keyspace-events
		expect_same "notify events bad class" config set notify-keyspace-events KEX
		expect_same "notify events clear" config set notify-keyspace-events ""
		expect_same "notify events get cleared" config get notify-keyspace-events
		expect_same "tracking table max keys get" config get tracking-table-max-keys
		expect_same "tracking table max keys bad" config set tracking-table-max-keys x
		expect_same "tracking table max keys negative" config set tracking-table-max-keys -1
		expect_same "tracking table max keys set" config set tracking-table-max-keys 500
		expect_same "tracking table max keys get after set" config get tracking-table-max-keys
		expect_same "tracking table max keys restore" config set tracking-table-max-keys 1000000
		expect_same "maxmemory policy get" config get maxmemory-policy
		expect_same "maxmemory policy bad" config set maxmemory-policy lru
		expect_same "maxmemory policy set" config set maxmemory-policy allkeys-lru
		expect_same "maxmemory policy get after set" config get maxmemory-policy
		expect_same "maxmemory policy restore" config set maxmemory-policy noeviction
		expect_same "maxmemory samples bad" config set maxmemory-samples 0
		expect_same "maxmemory samples get" config get maxmemory-samples
		expect_same "client tracking without arguments" client tracking
		expect_same "client trackinginfo" client trackinginfo
		expect_same "client getredir" client getredir
		expect_same "client caching without tracking" client caching yes
		expect_same_pubsub
		expect_same "pubsub help" pubsub help
		expect_same "pubsub unknown subcommand" pubsub foo
		expect_same "pubsub numpat arity" pubsub numpat x
		expect_same "pubsub help arity" pubsub help x
		expect_same "pubsub channels arity" pubsub channels a b
		expect_same "pubsub shardchannels arity" pubsub shardchannels a b
		expect_same "pubsub arity" pubsub
		expect_same "pubsub numsub without channels" pubsub numsub
		expect_same "pubsub numsub" pubsub numsub a b
		expect_same "pubsub shardnumsub" pubsub shardnumsub a b
		expect_same "pubsub numpat" pubsub numpat
		expect_same "pubsub channels" pubsub channels
		expect_same "pubsub shardchannels with a pattern" pubsub shardchannels "*"
		expect_same "publish to nobody" publish nobody hello
		expect_same "spublish to nobody" spublish nobody hello
		expect_same "publish arity" publish a
		expect_same "spublish arity" spublish a b c
		expect_same_dump 2
		expect_same_dump 3
		expect_same_corrupt
		expect_same_migrate
		expect_same "exec without multi" exec
		expect_same "discard without multi" discard
		expect_same "exec arity" exec x
		expect_same "multi arity" multi x
		expect_same "watch arity" watch
		expect_same "unwatch" unwatch
		expect_same_pipe "transaction through redis-cli" "$(cat <<'CMDS'
DEL tx:cli tx:clih
MULTI
SET tx:cli 1
INCR tx:cli
HSET tx:clih f v
HGETALL tx:clih
GET tx:none
LPUSH tx:cli x
EXEC
WATCH tx:cli
SET tx:cli 5
MULTI
GET tx:cli
EXEC
MULTI
NOSUCH
EXEC
DEL tx:cli tx:clih
CMDS
)"
		expect_same_transactions
		expect_transaction_stress
		expect_same_pipe "config command errors" "$(cat <<'CMDS'
CONFIG SET maxmemory
CONFIG SET maxmemory 1 maxmemory
CONFIG SET nosuch 1
CONFIG SET daemonize yes
CONFIG SET maxmemory 1 maxmemory 2
CONFIG SET hash-max-ziplist-entries 100 hash-max-listpack-entries 200
CONFIG GET hash-max-listpack-entries
CONFIG SET hash-max-listpack-entries 512
CONFIG SET maxmemory 10000001 maxmemory-clients 200% client-query-buffer-limit invalid
CONFIG GET maxmemory
CONFIG SET dir /tmp
CONFIG SET dbfilename x.rdb
CONFIG SET unixsocketperm 777
CONFIG SET slaveof 1.2.3.4 5
CONFIG GET
CONFIG RESETSTAT x
CONFIG REWRITE
CONFIG REWRITE x
CONFIG HELP
CONFIG HELP x
CONFIG FOO
CONFIG SET shutdown-on-sigint "nosave force now"
CONFIG GET shutdown-on-sigint
CONFIG SET shutdown-on-sigint default
CONFIG SET maxmemory-clients 99999999999999999999
CONFIG GET maxmemory-clients
CONFIG SET maxmemory-clients 0
CONFIG SET proc-title-template "{title}"
CONFIG SET proc-title-template "{title} {port}"
CONFIG GET proc-title-template
CONFIG SET proc-title-template "{title} {listen-addr} {server-mode}"
CONFIG SET bind 999.999.999.999
CONFIG SET port abc
CONFIG SET hz 0
CONFIG GET hz
CONFIG SET hz 100000
CONFIG GET hz
CONFIG SET hz 10
CMDS
)"
		expect_config_parity
		expect_config_files
		expect_command_parity
		expect_same_raw "command info and docs bytes" "COMMAND INFO set" "COMMAND DOCS set" "COMMAND INFO nosuch get|key" "COMMAND DOCS nosuch" "COMMAND GETKEYSANDFLAGS set k v get" "COMMAND LIST FILTERBY pattern hexpire?t"
		expect_same_pipe "command family" "$(cat <<'CMDS'
COMMAND HELP
command help
COMMAND HELP extra
COMMAND COUNT extra
COMMAND FOO
COMMAND ""
COMMAND INFO get|key
COMMAND INFO config|get|key
COMMAND INFO nosuch
COMMAND INFO config|
COMMAND INFO |get
COMMAND INFO ""
COMMAND INFO GET Set CONFIG|GET client|LIST xinfo|nosuch hexpire
COMMAND INFO ZUNIONSTORE XREAD SORT SORT_RO MIGRATE GEORADIUS
COMMAND INFO SET GET MSET BITFIELD LMOVE LPOP BLPOP PING MEMORY|USAGE RENAME GEORADIUS_RO
COMMAND DOCS nosuch
COMMAND DOCS nosuch get|x GET|
COMMAND DOCS GET config|get Set migrate
COMMAND LIST bad_arg
COMMAND LIST FILTERBY
COMMAND LIST FILTERBY bad_arg
COMMAND LIST FILTERBY bad_arg bad_arg2
COMMAND LIST FILTERBY pattern
COMMAND LIST FILTERBY pattern a b
COMMAND LIST FILTERBY pattern set
COMMAND LIST FILTERBY PATTERN GET
COMMAND LIST FILTERBY pattern get filterby aclcat read
COMMAND LIST FILTERBY module nosuch
COMMAND LIST FILTERBY aclcat nosuch
COMMAND LIST FILTERBY aclcat @read
COMMAND GETKEYS
COMMAND GETKEYSANDFLAGS
COMMAND GETKEYS get
COMMAND GETKEYS get key
COMMAND GETKEYS GET key
COMMAND GETKEYS get a b
COMMAND GETKEYS ping
COMMAND GETKEYS nosuch a
COMMAND GETKEYS memory
COMMAND GETKEYS memory usage key
COMMAND GETKEYS memory nosuch k
COMMAND GETKEYS config get x
COMMAND GETKEYS config|get k
COMMAND GETKEYS client nosuch
COMMAND GETKEYS publish c m
COMMAND GETKEYS xgroup create key groupname $
COMMAND GETKEYS xinfo stream k full
COMMAND GETKEYS lcs key1 key2
COMMAND GETKEYS ZUNIONSTORE target 2 key1 key2
COMMAND GETKEYS sort abc store def
COMMAND GETKEYS sort_ro abc
COMMAND GETKEYS sort abc store invalid store stillbad store def
COMMAND GETKEYS sort k store limit store x
COMMAND GETKEYSANDFLAGS set k1 v1
COMMAND GETKEYSANDFLAGS set k1 v1 get
COMMAND GETKEYSANDFLAGS mset k1 v1 k2 v2
COMMAND GETKEYSANDFLAGS LMOVE k1 k2 left right
COMMAND GETKEYSANDFLAGS sort k1 store k2
COMMAND GETKEYSANDFLAGS ZINTERSTORE zz 1443677133621497600 asdf
COMMAND GETKEYSANDFLAGS zunionstore d 4294967297 a
COMMAND GETKEYSANDFLAGS zunionstore d 4294967296 a
COMMAND GETKEYSANDFLAGS xread streams a b 0 0
COMMAND GETKEYSANDFLAGS xread streams streams a 0 0
COMMAND GETKEYSANDFLAGS xread foo streams a 0
COMMAND GETKEYSANDFLAGS xreadgroup group g c streams a b 0 0
COMMAND GETKEYSANDFLAGS georadius k 0 0 1 km store d storedist e
COMMAND GETKEYSANDFLAGS georadiusbymember k m 1 km storedist d
COMMAND GETKEYSANDFLAGS migrate h 1 "" 0 1 keys a b
COMMAND GETKEYSANDFLAGS migrate h 1 k 0 1 keys a
COMMAND GETKEYSANDFLAGS migrate h 1 "" 0 1 auth2 u p keys a
COMMAND GETKEYSANDFLAGS bitfield k get u8 0
COMMAND GETKEYSANDFLAGS bitfield k set u8 0 1
COMMAND GETKEYSANDFLAGS bitfield_ro k get u8 0
COMMAND GETKEYSANDFLAGS blmpop 0 2 a b left
COMMAND GETKEYSANDFLAGS lmpop 2 a b left
COMMAND GETKEYSANDFLAGS sintercard 2 a b
COMMAND GETKEYSANDFLAGS hexpire h 10 fields 1 f
COMMAND GETKEYSANDFLAGS object encoding k
MULTI
COMMAND INFO get
COMMAND GETKEYS get k
EXEC
MULTI
COMMAND HELP x
EXEC
CMDS
)"
		MONITOR_CASES_PY="$(cat <<'PY'
import re
import socket
import sys
import time

SETTLE = 0.05


class Conn:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.s.setblocking(False)
        self.out = b""
        self.eof = False

    def drain(self):
        while not self.eof:
            try:
                data = self.s.recv(65536)
            except BlockingIOError:
                return
            except ConnectionResetError:
                data = b""
            if not data:
                self.eof = True
                self.out += b"<EOF>"
                return
            self.out += data

    def send(self, text):
        self.s.sendall(text.encode("latin1"))

    def wait_for(self, marker):
        end = time.time() + 3
        while marker not in self.out and not self.eof and time.time() < end:
            self.drain()
            time.sleep(0.002)


def norm(data):
    return re.sub(rb"\+\d+\.\d{6} \[(\d+) [0-9.]+:\d+\]", rb"+T [\1 A]", data)


def run(port, steps):
    conns = {}
    order = []
    notes = []
    for step in steps:
        op = step[0]
        if op == "open":
            conns[step[1]] = Conn(port)
            order.append(step[1])
        elif op == "monitor":
            c = conns[step[1]]
            c.send("MONITOR\r\n")
            c.wait_for(b"+OK\r\n")
            c.out = b""
        elif op == "hello3":
            c = conns[step[1]]
            c.send("HELLO 3\r\n")
            c.wait_for(b"$7\r\nmodules\r\n*0\r\n")
            c.out = b""
        elif op == "send":
            conns[step[1]].send(step[2])
        elif op == "mute":
            conns[step[1]].drain()
            conns[step[1]].out = b""
        elif op == "sleep":
            time.sleep(step[1])
        elif op == "flags":
            c = conns[step[1]]
            c.drain()
            c.out = b""
            c.send("CLIENT LIST\r\n")
            c.wait_for(b"\n\r\n")
            text = c.out.decode("latin1")
            c.out = b""
            for line in text.split("\n"):
                fields = dict(kv.split("=", 1) for kv in line.split(" ") if "=" in kv)
                if fields.get("name") == step[2]:
                    notes.append(" ".join(k + "=" + fields.get(k, "?") for k in ("flags", "db", "sub", "cmd", "resp")))
        time.sleep(SETTLE)
        for c in conns.values():
            c.drain()
    time.sleep(0.2)
    for c in conns.values():
        c.drain()
    for name in order:
        conns[name].s.close()
    return " | ".join([name + "=" + repr(norm(conns[name].out)) for name in order if name.startswith("m")] + notes)


def basic():
    return [
        ("open", "c"),
        ("send", "c", "FLUSHALL\r\n"),
        ("open", "m"),
        ("monitor", "m"),
        ("send", "c", "SET foo bar\r\nGET foo\r\n*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$14\r\na b\"c\\d\r\n\t\x01\x7f\xff\x80\r\n"),
        ("send", "c", "SET 12 345\r\nINCR 12\r\nSELECT 3\r\nSET x y\r\nSELECT 0\r\nNOSUCH a\r\nGET\r\nGET a b\r\nLPUSH foo x\r\n"),
        ("send", "c", "CLIENT ID\r\nCLIENT LIST\r\nCLIENT NOSUCH\r\nCLIENT ID x\r\nCLIENT SETNAME abc\r\nCONFIG GET maxmemory\r\nDEBUG SLEEP 0\r\nINFO keyspace\r\n"),
        ("send", "c", "PING\r\nECHO hi\r\nOBJECT ENCODING foo\r\nOBJECT NOSUCH x\r\nMEMORY USAGE foo\r\nLASTSAVE\r\nDBSIZE\r\nSWAPDB 0 1\r\nSWAPDB 0 1\r\nMONITOR\r\nPUBLISH ch m\r\nQUIT\r\n"),
    ]


def redaction():
    return [
        ("open", "c"),
        ("open", "m"),
        ("monitor", "m"),
        ("send", "c", "AUTH x\r\nAUTH x y\r\nAUTH a b c\r\nAUTH default \"\"\r\nHELLO 2 AUTH a b\r\nHELLO 3 AUTH default b SETNAME nm\r\n"),
        ("send", "c", "HELLO 2\r\nHELLO 2 SETNAME x AUTH a\r\nHELLO 2 AUTH\r\nHELLO 9 AUTH a b\r\nHELLO abc AUTH a b\r\nHELLO 3 AUTH default x SETNAME \"a b\"\r\n"),
        ("send", "c", "HELLO 3 SETNAME \"a b\" AUTH default x\r\nHELLO 3 AUTH default x bogus\r\nHELLO 2 AUTH a b AUTH c d\r\n"),
        ("send", "c", "MIGRATE 127.0.0.1 1 key 9 5000\r\nMIGRATE 127.0.0.1 1 key 9 5000 AUTH user\r\nMIGRATE 127.0.0.1 1 key 9 5000 AUTH2 user pw\r\n"),
        ("send", "c", "MIGRATE 127.0.0.1 1 key 9 5000 auth user keys a\r\nMIGRATE 127.0.0.1 1 \"\" 9 5000 copy replace auth2 u p keys a\r\nMIGRATE 127.0.0.1 1 key 9 5000 AUTH\r\n"),
        ("send", "c", "MIGRATE 127.0.0.1 1 key 9 5000 AUTH2 u\r\nMIGRATE 127.0.0.1 1 \"\" 9 5000 keys auth x\r\nMIGRATE 127.0.0.1 1 k 9 5000 bogus auth x\r\n"),
        ("send", "c", "MIGRATE 127.0.0.1 1 k 9 5000 auth x bogus\r\nMIGRATE 127.0.0.1 1 k x 5000 auth x\r\nCONFIG SET maxmemory 0\r\n"),
    ]


def transactions():
    return [
        ("open", "c"),
        ("open", "m"),
        ("monitor", "m"),
        ("send", "c", "MULTI\r\nSET foo bar\r\nGET foo\r\nEXEC\r\nMULTI\r\nSYNTAX error\r\nEXEC\r\nMULTI\r\nGET\r\nDISCARD\r\n"),
        ("send", "c", "WATCH w\r\nSET w 1\r\nMULTI\r\nINCR w\r\nEXEC\r\nMULTI\r\nMULTI\r\nPING\r\nEXEC\r\nEXEC\r\nEXEC extra\r\nMULTI\r\nEXEC extra\r\n"),
        ("send", "c", "MULTI\r\nSELECT 2\r\nSET a b\r\nAUTH zz\r\nEXEC\r\nSELECT 0\r\nMULTI\r\nCLIENT ID\r\nCONFIG GET port\r\nDEBUG SLEEP 0\r\nMONITOR\r\nEXEC\r\nUNWATCH\r\nDISCARD\r\n"),
    ]


def blocking():
    return [
        ("open", "c"),
        ("open", "b"),
        ("send", "c", "DEL l1 l2 l3 l4 l5 s1\r\n"),
        ("open", "m"),
        ("monitor", "m"),
        ("send", "b", "BLPOP l1 0\r\n"),
        ("sleep", 0.1),
        ("send", "c", "LPUSH l1 a\r\n"),
        ("send", "b", "BLPOP l2 0.05\r\n"),
        ("sleep", 0.2),
        ("send", "b", "BLMOVE l4 l5 LEFT RIGHT 0\r\nGET after\r\n"),
        ("sleep", 0.1),
        ("send", "c", "RPUSH l4 q\r\n"),
        ("send", "b", "BRPOP l1 l3 0\r\n"),
        ("sleep", 0.1),
        ("send", "c", "MULTI\r\nRPUSH l1 1\r\nRPUSH l3 2\r\nEXEC\r\n"),
        ("send", "b", "XREAD BLOCK 0 STREAMS s1 $\r\n"),
        ("sleep", 0.1),
        ("send", "c", "XADD s1 1-1 f v\r\n"),
    ]


def monitor_client():
    return [
        ("open", "c"),
        ("open", "m"),
        ("send", "m", "CLIENT SETNAME mon\r\n"),
        ("mute", "m"),
        ("monitor", "m"),
        ("flags", "c", "mon"),
        ("send", "m", "PING\r\nGET foo\r\nSET x y\r\nPUBLISH c x\r\nDBSIZE\r\nECHO hi\r\nMULTI\r\nGET a\r\nPING\r\nEXEC\r\nMONITOR\r\nSELECT 1\r\nCLIENT LIST ID 0\r\n"),
        ("send", "c", "CLIENT PAUSE 300 ALL\r\n"),
        ("send", "m", "PING\r\n"),
        ("sleep", 0.4),
        ("send", "m", "SUBSCRIBE ch\r\nPING\r\n"),
        ("flags", "c", "mon"),
        ("send", "m", "RESET\r\n"),
        ("send", "c", "SET after reset\r\n"),
    ]


def teardown():
    return [
        ("open", "c"),
        ("open", "m1"),
        ("open", "m2"),
        ("open", "m3"),
        ("open", "m4"),
        ("monitor", "m1"),
        ("hello3", "m2"),
        ("monitor", "m2"),
        ("send", "m3", "SUBSCRIBE ch\r\nMONITOR\r\n"),
        ("send", "m4", "CLIENT REPLY OFF\r\nMONITOR\r\n"),
        ("send", "c", "SET r3 x\r\n"),
        ("send", "m1", "QUIT\r\n"),
        ("send", "c", "PING\r\nFLUSHALL\r\n"),
    ]


SCENARIOS = [
    ("basic feed", basic),
    ("redaction", redaction),
    ("transactions", transactions),
    ("blocked commands", blocking),
    ("monitoring client", monitor_client),
    ("teardown and modes", teardown),
]

port = int(sys.argv[1])
for name, build in SCENARIOS:
    print("%s\t%s" % (name, run(port, build())))
PY
)"
		mon_mine="$(python3 -I -c "$MONITOR_CASES_PY" "$PORT" 2>&1)"
		mon_theirs="$(python3 -I -c "$MONITOR_CASES_PY" "$REF_PORT" 2>&1)"
		mon_n=0
		while IFS=$'\t' read -r mon_name mon_want; do
			mon_n=$((mon_n + 1))
			mon_got="$(printf '%s\n' "$mon_mine" | awk -F'\t' -v n="$mon_name" '$1 == n { print $2 }')"
			if [ -n "$mon_want" ] && [ "$mon_got" == "$mon_want" ]; then
				pass
			else
				fail "monitor output for $mon_name differs from redis" "${mon_want:0:400}" "${mon_got:0:400}"
			fi
		done <<<"$mon_theirs"
		if [ "$mon_n" -ne 6 ]; then
			fail "monitor scenarios ran" "6 scenarios" "$mon_n"
		fi
		expect_same_pipe "debug subcommands" "$(cat <<'CMDS'
FLUSHALL
CONFIG SET hash-max-listpack-entries 0
HSET dbg:h1 a 1
CONFIG SET hash-max-listpack-entries 128
HSET dbg:hs f v n 12
RPUSH dbg:l a b 7
SET dbg:s v
SADD dbg:set a b
SADD dbg:ints 1 2
ZADD dbg:z 1 a
DEBUG HTSTATS-KEY dbg:h1
DEBUG HTSTATS-KEY dbg:h1 full
DEBUG HTSTATS-KEY dbg:h1 x y
DEBUG HTSTATS-KEY dbg:hs
DEBUG HTSTATS-KEY dbg:l
DEBUG HTSTATS-KEY dbg:s
DEBUG HTSTATS-KEY dbg:nokey
DEBUG HTSTATS-KEY
DEBUG LISTPACK dbg:l
DEBUG LISTPACK dbg:hs
DEBUG LISTPACK dbg:set
DEBUG LISTPACK dbg:z
DEBUG LISTPACK dbg:ints
DEBUG LISTPACK dbg:h1
DEBUG LISTPACK dbg:s
DEBUG LISTPACK dbg:nokey
DEBUG LISTPACK
DEBUG LISTPACK a b
CONFIG SET list-max-listpack-size 2
RPUSH dbg:ql a b c d e
CONFIG SET list-max-listpack-size -2
DEBUG QUICKLIST dbg:ql
DEBUG QUICKLIST dbg:ql 1
DEBUG QUICKLIST dbg:ql x
DEBUG QUICKLIST dbg:l
DEBUG QUICKLIST dbg:nokey
DEBUG QUICKLIST
DEBUG QUICKLIST a b c
DEBUG OBJECT dbg:s extra
DEBUG OBJECT
DEBUG OBJECT dbg:nokey
DEBUG POPULATE 3
DEBUG POPULATE 2 dbg:pop 10
DEBUG POPULATE 3 dbg:pop
MGET key:0 key:1 key:2 key:3
MGET dbg:pop:0 dbg:pop:1 dbg:pop:2
DEBUG POPULATE 0
DEBUG POPULATE -1
DEBUG POPULATE abc
DEBUG POPULATE 2 p abc
DEBUG POPULATE 2 p -1
DEBUG POPULATE 2 p 1 x
DEBUG POPULATE
DBSIZE
DEBUG ERROR "my error"
DEBUG ERROR "ERR two\nlines"
DEBUG ERROR
DEBUG LOG "smoke debug log"
DEBUG LOG
DEBUG LOG a b
DEBUG LEAK abc
DEBUG CHANGE-REPL-ID
DEBUG CHANGE-REPL-ID x
DEBUG REPLICATE set a b
DEBUG AOF-FLUSH-SLEEP 0
DEBUG AOF-FLUSH-SLEEP
DEBUG REPLYBUFFER peak-reset-time 100
DEBUG REPLYBUFFER peak-reset-time never
DEBUG REPLYBUFFER peak-reset-time abc
DEBUG REPLYBUFFER peak-reset-time reset
DEBUG REPLYBUFFER resizing 0
DEBUG REPLYBUFFER resizing 1
DEBUG REPLYBUFFER bogus 1
DEBUG REPLYBUFFER resizing
DEBUG DICT-RESIZING 0
DEBUG DICT-RESIZING 1
DEBUG DICT-RESIZING
DEBUG CLIENT-EVICTION
DEBUG CLIENT-EVICTION x
DEBUG STRINGMATCH-TEST x
DEBUG STRINGMATCH-LEN
DEBUG SLEEP
DEBUG SLEEP 0 x
DEBUG SLEEP inf
DEBUG SLEEP -1
DEBUG SLEEP abc
DEBUG HELP x
DEBUG NOSUCH
DEBUG CONFIG-REWRITE-FORCE-ALL x
FLUSHALL
CMDS
)"
		dbg_help="$(cli debug help)"
		dbg_ref_help="$(ref_cli debug help)"
		if python3 -I -c '
import sys
mine = sys.argv[1].split("\n")
theirs = sys.argv[2].split("\n")
i = 0
for line in mine:
    while i < len(theirs) and theirs[i] != line:
        i += 1
    if i == len(theirs):
        sys.exit(1)
    i += 1
sys.exit(0 if mine[0] == theirs[0] and mine[-2:] == theirs[-2:] and len(mine) > 60 else 1)
' "$dbg_help" "$dbg_ref_help"; then pass; else fail "debug help lines are the reference lines of the implemented subcommands" "${dbg_ref_help:0:160}" "${dbg_help:0:160}"; fi
		cli config set maxmemory-clients 1g >/dev/null
		ref_cli config set maxmemory-clients 1g >/dev/null
		dbg_got="$(cli debug client-eviction | sed -E 's/tot-mem: +[0-9]+, clients: [0-9]+/tot-mem: N, clients: N/')"
		dbg_want="$(ref_cli debug client-eviction | sed -E 's/tot-mem: +[0-9]+, clients: [0-9]+/tot-mem: N, clients: N/')"
		if [ -n "$dbg_want" ] && [ "$dbg_got" == "$dbg_want" ]; then pass; else fail "debug client-eviction bucket layout matches redis" "${dbg_want:0:160}" "${dbg_got:0:160}"; fi
		cli config set maxmemory-clients 0 >/dev/null
		ref_cli config set maxmemory-clients 0 >/dev/null
		expect "debug stringmatch-test" "Apparently Redis did not crash: test passed" debug stringmatch-test
		if [ "$EXTERNAL" != "1" ]; then
			cli rpush dbg:one a >/dev/null
			expect "debug listpack on a list" "Listpack structure printed on stdout" debug listpack dbg:one
			sleep 0.1
			dbg_repr="$(grep -A 12 '^{total bytes 10} {num entries 1}$' "$LOG" | tail -n 13 | sed -E 's/addr: 0x[0-9a-f]+/addr: X/')"
			dbg_repr_want="$(printf '%s\n' '{total bytes 10} {num entries 1}' '{' '	addr: X,' '	index:  0,' '	offset: 6,' '	hdr+entrylen+backlen:  3,' '	hdrlen:   1,' '	backlen:  1,' '	payload: 1' '	bytes: 81|61|02|' '	[str]a' '}' '{end}')"
			if [ "$dbg_repr" == "$dbg_repr_want" ]; then pass; else fail "debug listpack prints the reference's listpack dump" "$dbg_repr_want" "$dbg_repr"; fi
			if grep -q 'DEBUG LOG: smoke debug log' "$LOG"; then pass; else fail "debug log writes to the server log" "DEBUG LOG: smoke debug log" "$(tail -n 3 "$LOG")"; fi
			cli del dbg:one >/dev/null
		fi
		expect_same_pipe "memory family" "$(cat <<'CMDS'
FLUSHALL
MEMORY HELP
memory help
MEMORY HELP extra
MEMORY STATS extra
MEMORY DOCTOR extra
MEMORY PURGE extra
MEMORY MALLOC-STATS extra
MEMORY USAGE
MEMORY USAGE mem:k SAMPLES 5 extra
MEMORY NOSUCH
MEMORY nosuch a b
MEMORY ""
MEMORY
SET mem:k v
MEMORY USAGE mem:k SAMPLES
MEMORY USAGE mem:k SAMPLES -1
MEMORY USAGE mem:k SAMPLES -9223372036854775808
MEMORY USAGE mem:k SAMPLES abc
MEMORY USAGE mem:k SAMPLES 1.5
MEMORY USAGE mem:k SAMPLES ""
MEMORY USAGE mem:k SAMPLES 99999999999999999999
MEMORY USAGE mem:k BOGUS 5
MEMORY USAGE mem:k BOGUS
MEMORY USAGE mem:k samples
MEMORY USAGE mem:nokey
MEMORY USAGE mem:nokey SAMPLES 0
MEMORY USAGE mem:nokey SAMPLES -1
MEMORY USAGE mem:nokey SAMPLES abc
MEMORY USAGE mem:nokey BOGUS 1
MEMORY PURGE
CONFIG RESETSTAT
FLUSHALL
MEMORY DOCTOR
CMDS
)"
		expect_same_raw "memory reply types" "CONFIG RESETSTAT" "FLUSHALL" "MEMORY HELP" "MEMORY PURGE" "MEMORY DOCTOR" "MEMORY USAGE mem:nokey" "MEMORY USAGE mem:nokey SAMPLES 3" "MEMORY USAGE mem:nokey SAMPLES -1" "MEMORY USAGE mem:nokey SAMPLES x" "MEMORY USAGE mem:nokey FOO 1" "MEMORY STATS x" "MEMORY DOCTOR x" "MEMORY PURGE x" "MEMORY MALLOC-STATS x" "MEMORY HELP x" "MEMORY USAGE" "MEMORY FOO"
		got="$(raw_resp2 "$PORT" $'MEMORY MALLOC-STATS\r\n' | head -n 1)"
		if [[ "$got" =~ ^\$[1-9][0-9]*$ ]]; then pass; else fail "memory malloc-stats replies with a bulk string" '$<length>' "$got"; fi
		got="$(raw_resp3 "$PORT" $'MEMORY MALLOC-STATS\r\n' | head -n 1)"
		if [[ "$got" =~ ^[\$=][1-9][0-9]*$ ]]; then pass; else fail "memory malloc-stats replies with a bulk string (resp3)" '$<length> or =<length>' "$got"; fi
		expect_same_raw_shape "memory stats shape" "FLUSHALL" "MEMORY STATS" "SET mem:a 1" "SELECT 9" "SET mem:b v EX 1000" "SET mem:c v" "SELECT 0" "MEMORY STATS" "SELECT 9" "FLUSHDB" "MEMORY STATS" "FLUSHALL"
		expect_same_pipe "memory policy and object freq" "$(cat <<'CMDS'
FLUSHALL
CONFIG SET maxmemory-policy noeviction
SET of:a v
OBJECT FREQ of:a
OBJECT FREQ of:nokey
OBJECT IDLETIME of:nokey
CONFIG SET maxmemory-policy allkeys-lfu
SET of:b v
OBJECT FREQ of:b
OBJECT FREQ of:nokey
OBJECT IDLETIME of:b
OBJECT IDLETIME of:nokey
CONFIG SET maxmemory-policy volatile-lfu
OBJECT IDLETIME of:b
SET of:c v
OBJECT FREQ of:c
CONFIG SET maxmemory-policy volatile-ttl
OBJECT FREQ of:c
CONFIG SET maxmemory-policy allkeys-random
OBJECT FREQ of:a
CONFIG SET maxmemory-policy lfu
CONFIG SET maxmemory-policy ""
CONFIG SET maxmemory-policy allkeys-lfu volatile-lru
CONFIG SET maxmemory-policy NOEVICTION
CONFIG GET maxmemory-policy
CONFIG SET maxmemory-policy Allkeys-LFU
CONFIG GET maxmemory-policy
CONFIG SET maxmemory-policy noeviction
CONFIG GET maxmemory-policy
FLUSHALL
CMDS
)"
		for mm in 1234567890:allkeys-lfu 104857599:volatile-ttl 3gb:volatile-lru 0:noeviction; do
			printf 'CONFIG SET maxmemory %s\nCONFIG SET maxmemory-policy %s\n' "${mm%%:*}" "${mm#*:}" | cli_pipe >/dev/null
			printf 'CONFIG SET maxmemory %s\nCONFIG SET maxmemory-policy %s\n' "${mm%%:*}" "${mm#*:}" | ref_pipe >/dev/null
			expect_same_info "info memory fields with maxmemory ${mm%%:*} and ${mm#*:}" memory "maxmemory maxmemory_human maxmemory_policy mem_clients_slaves mem_cluster_links mem_replication_backlog"
		done
		printf 'CONFIG RESETSTAT\n' | cli_pipe >/dev/null
		printf 'CONFIG RESETSTAT\n' | ref_pipe >/dev/null
		evict_fields="evicted_keys evicted_clients evicted_scripts total_eviction_exceeded_time current_eviction_exceeded_time"
		expect_same_info "info stats eviction fields after a reset" stats "$evict_fields" "^(${evict_fields// /|})$"
		expect_same_eviction
		expect_same_info "info stats eviction fields after evicting" stats "" "^(${evict_fields// /|})$"
		expect_same_pipe "memory oom under noeviction" "$(cat <<'CMDS'
CONFIG SET maxmemory-policy noeviction
CONFIG SET maxmemory 1
SET mem:x y
LPUSH mem:l a
INCR mem:n
SETEX mem:y 10 v
APPEND mem:z v
EXISTS mem:x
GET mem:x
DEL mem:x
MULTI
SET mem:x y
EXEC
CONFIG SET maxmemory 0
SET mem:x y
DEL mem:x
FLUSHALL
CMDS
)"
		printf 'CONFIG SET maxmemory 0\nCONFIG SET maxmemory-policy noeviction\nCONFIG RESETSTAT\nFLUSHALL\n' | cli_pipe >/dev/null
		printf 'CONFIG SET maxmemory 0\nCONFIG SET maxmemory-policy noeviction\nCONFIG RESETSTAT\nFLUSHALL\n' | ref_pipe >/dev/null
		expect_same "maxmemory restored after the memory family" config get maxmemory
		expect_same "maxmemory policy restored after the memory family" config get maxmemory-policy
		info_stat_values="redis_git_sha1 redis_git_dirty redis_mode arch_bits multiplexing_api atomicvar_api process_supervised config_file io_threads_active cluster_connections maxclients blocked_clients tracking_clients pubsub_clients watching_clients clients_in_timeout_table total_watched_keys total_blocking_keys total_blocking_keys_on_nokey total_net_repl_input_bytes total_net_repl_output_bytes instantaneous_input_repl_kbps instantaneous_output_repl_kbps rejected_connections sync_full sync_partial_ok sync_partial_err expired_subkeys expired_keys evicted_keys evicted_clients evicted_scripts keyspace_hits keyspace_misses pubsub_channels pubsub_patterns pubsubshard_channels slave_expires_tracked_keys active_defrag_hits active_defrag_misses active_defrag_key_hits active_defrag_key_misses total_active_defrag_time current_active_defrag_time tracking_total_keys tracking_total_items tracking_total_prefixes unexpected_error_replies total_error_replies dump_payload_sanitizations io_threaded_reads_processed io_threaded_writes_processed client_query_buffer_limit_disconnections client_output_buffer_limit_disconnections role connected_slaves master_failover_state master_replid2 second_repl_offset repl_backlog_active repl_backlog_size repl_backlog_first_byte_offset repl_backlog_histlen cluster_enabled"
		stats_reset_both() {
			printf 'CONFIG SET slowlog-log-slower-than 10000\nCONFIG SET slowlog-max-len 128\nCONFIG SET latency-monitor-threshold 0\nCONFIG SET latency-tracking yes\nFLUSHALL\nSLOWLOG RESET\nLATENCY RESET\nCONFIG RESETSTAT\n' | cli_pipe >/dev/null
			printf 'CONFIG SET slowlog-log-slower-than 10000\nCONFIG SET slowlog-max-len 128\nCONFIG SET latency-monitor-threshold 0\nCONFIG SET latency-tracking yes\nFLUSHALL\nSLOWLOG RESET\nLATENCY RESET\nCONFIG RESETSTAT\n' | ref_pipe >/dev/null
		}
		info_layout() {
			docker exec "$CLI_CONTAINER" redis-cli -p "$1" info "${@:2}" 2>&1 | tr -d '\r' | awk -F: -v keep=" $info_stat_values " -v extra=" eski_version compute_threads_configured compute_threads_active compute_jobs_pending compute_memory_reserved compute_jobs_submitted compute_jobs_completed compute_jobs_cancelled compute_sync_fallbacks compute_worker_nanoseconds keyspace_threads_configured keyspace_threads_active keyspace_jobs_pending keyspace_memory_used keyspace_records keyspace_jobs_submitted keyspace_jobs_completed keyspace_gets keyspace_sets keyspace_sync_fallbacks keyspace_barriers keyspace_worker_nanoseconds " '/^#/ || $0 == "" { print; next } index(extra, " " $1 " ") || $1 ~ /^(cmdstat_|errorstat_|latency_percentiles_usec_)/ { next } index(keep, " " $1 " ") { print; next } { print $1 }'
		}
		info_headers() {
			docker exec "$CLI_CONTAINER" redis-cli -p "$1" info "${@:2}" 2>&1 | tr -d '\r' | grep '^#'
		}
		expect_same_info_layout() {
			local name="$1" got want line
			got="$(info_layout "$PORT" "${@:2}")"
			want="$(info_layout "$REF_PORT" "${@:2}")"
			if [ -n "$want" ] && [ "$got" == "$want" ]; then
				pass
				return
			fi
			line="$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 6 | tr '\n' ' ')"
			fail "$name differs from redis: $line" "${want:0:160}" "${got:0:160}"
		}
		expect_same_info_sections() {
			local got want
			got="$(info_headers "$PORT" "$@" | tr '\n' ' ')"
			want="$(info_headers "$REF_PORT" "$@" | tr '\n' ' ')"
			if [ "$got" == "$want" ]; then pass; else fail "info $* selects the reference's sections" "$want" "$got"; fi
		}
		stat_lines() {
			docker exec "$CLI_CONTAINER" redis-cli -p "$1" info "$2" 2>&1 | tr -d '\r' | grep "^#\|^$3" | sed -e 's/,usec=[0-9]*,usec_per_call=[0-9.]*//' -e '/^latency_percentiles_usec_/s/=[0-9.]*/=N/g' | LC_ALL=C sort
		}
		expect_same_stat_lines() {
			local name="$1" got want line
			got="$(stat_lines "$PORT" "$2" "$3")"
			want="$(stat_lines "$REF_PORT" "$2" "$3")"
			if [ -n "$want" ] && [ "$got" == "$want" ]; then
				pass
				return
			fi
			line="$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 8 | tr '\n' ' ')"
			fail "$name differs from redis: $line" "${want:0:200}" "${got:0:200}"
		}
		digits_norm() {
			sed 's/[0-9][0-9]*/N/g'
		}
		stats_reset_both
		expect_same_info_layout "info everything layout" everything
		expect_same_info_layout "info debug layout" debug
		expect_same_info_layout "info default layout"
		for sel in "" default all everything "cpu sentinel" "cpu all" "cpu default" commandSTATS "server clients" "clients server" nosuch "all nosuch" modules module_list debug "all debug" "everything debug" "keyspace keyspace" "default commandstats latencystats" sentinel; do
			expect_same_info_sections $sel
		done
		stats_reset_both
		stats_feed="$(cat <<'CMDS'
SET st:a 1
GET st:a
GET st:missing
SET st:a
INCR st:a
LPUSH st:a x
NOSUCHCOMMAND x
CONFIG GET
CONFIG NOSUCH
CLIENT GETNAME
OBJECT ENCODING st:a
OBJECT ENCODING
XGROUP CREATECONSUMER st:none g c
MULTI
SET st:b 2
GET
EXEC
MULTI
SET st:b 2
LPUSH st:b x
EXPIRE st:b 100
EXEC
EXEC
DISCARD
BLPOP st:list 0.01
LPUSH st:list a
BLPOP st:list 0
CONFIG SET maxmemory 1
SET st:c 1
CONFIG SET maxmemory 0
SLOWLOG LEN
LATENCY LATEST
DEBUG SLEEP 0
CMDS
)"
		printf '%s\n' "$stats_feed" | cli_pipe >/dev/null
		printf '%s\n' "$stats_feed" | ref_pipe >/dev/null
		expect_same_stat_lines "commandstats after a known sequence" commandstats cmdstat_
		expect_same_stat_lines "errorstats after a known sequence" errorstats errorstat_
		expect_same_stat_lines "latencystats after a known sequence" latencystats latency_percentiles_usec_
		expect_same_info "stats counters after a known sequence" stats "total_commands_processed total_error_replies unexpected_error_replies keyspace_hits keyspace_misses expired_keys" "^(total_commands_processed|total_error_replies|unexpected_error_replies|keyspace_hits|keyspace_misses|expired_keys)$"
		printf 'CONFIG SET latency-tracking no\nSET st:t 1\nGET st:t\n' | cli_pipe >/dev/null
		printf 'CONFIG SET latency-tracking no\nSET st:t 1\nGET st:t\n' | ref_pipe >/dev/null
		expect_same_stat_lines "latencystats with latency tracking off" latencystats latency_percentiles_usec_
		printf 'CONFIG SET latency-tracking yes\nCONFIG SET latency-tracking-info-percentiles "0 50 99.99 100"\n' | cli_pipe >/dev/null
		printf 'CONFIG SET latency-tracking yes\nCONFIG SET latency-tracking-info-percentiles "0 50 99.99 100"\n' | ref_pipe >/dev/null
		expect_same_stat_lines "latencystats with custom percentiles" latencystats latency_percentiles_usec_
		printf 'CONFIG SET latency-tracking-info-percentiles "50 99 99.9"\nCONFIG RESETSTAT\n' | cli_pipe >/dev/null
		printf 'CONFIG SET latency-tracking-info-percentiles "50 99 99.9"\nCONFIG RESETSTAT\n' | ref_pipe >/dev/null
		expect_same_stat_lines "commandstats after a reset" commandstats cmdstat_
		expect_same_stat_lines "errorstats after a reset" errorstats errorstat_
		expect_same_raw "slowlog errors" "SLOWLOG" "SLOWLOG FOO" "SLOWLOG HELP" "SLOWLOG HELP X" "SLOWLOG LEN X" "SLOWLOG RESET X" "SLOWLOG GET -2" "SLOWLOG GET X" "SLOWLOG GET 99999999999999999999" "SLOWLOG GET 1 2" "SLOWLOG GET 0" "SLOWLOG RESET" "SLOWLOG LEN"
		long_arg="$(printf 'L%.0s' $(seq 1 130))"
		sadd_args="$(seq -s ' ' 1 35)"
		expect_same_raw_shape "slowlog entries" "CONFIG SET slowlog-log-slower-than 0" "SLOWLOG RESET" "CLIENT SETNAME smokeslow" "SET sl:k v" "SADD sl:set $sadd_args" "SET sl:long $long_arg" "MULTI" "PING" "EXEC" "AUTH x" "CONFIG SET requirepass \"\"" "CONFIG SET slowlog-log-slower-than -1" "SLOWLOG LEN" "SLOWLOG GET 3" "SLOWLOG GET -1" "SLOWLOG RESET"
		expect_same_raw_shape "slowlog max len" "CONFIG SET slowlog-max-len 2" "CONFIG SET slowlog-log-slower-than 0" "SLOWLOG RESET" "PING" "PING" "PING" "CONFIG SET slowlog-log-slower-than -1" "SLOWLOG LEN" "SLOWLOG GET" "CONFIG SET slowlog-max-len 128" "SLOWLOG RESET"
		expect_same_raw "latency errors" "LATENCY" "LATENCY FOO" "LATENCY HELP" "LATENCY HELP X" "LATENCY LATEST X" "LATENCY DOCTOR X" "LATENCY GRAPH nope" "LATENCY HISTORY nope" "LATENCY HISTORY" "LATENCY RESET nope" "LATENCY HISTOGRAM nope" "LATENCY DOCTOR"
		expect_same_raw_proto "latency doctor with monitoring on and no events" 2 digits_norm "CONFIG SET latency-monitor-threshold 30" "LATENCY RESET" "LATENCY DOCTOR"
		expect_same_raw_shape "latency events" "CONFIG SET latency-monitor-threshold 30" "LATENCY RESET" "CONFIG RESETSTAT" "DEBUG SLEEP 0.04" "LATENCY LATEST" "LATENCY HISTORY command" "LATENCY RESET command fast-command"
		expect_same_raw "latency histogram of one command" "CONFIG RESETSTAT" "DEBUG SLEEP 0.04" "LATENCY HISTOGRAM debug nope"
		expect_same_raw_proto "latency doctor and graph" 2 digits_norm "CONFIG SET latency-monitor-threshold 30" "LATENCY RESET" "DEBUG SLEEP 0.04" "LATENCY GRAPH command" "LATENCY DOCTOR" "CONFIG SET slowlog-log-slower-than -1" "LATENCY DOCTOR" "CONFIG SET slowlog-log-slower-than 10000" "LATENCY RESET" "CONFIG SET latency-monitor-threshold 0" "LATENCY DOCTOR"
		stats_reset_both
		expect_same_acl
		expect_acl_files
		expect_same "acl users after the acl family" acl list
		stats_reset_both
	else
		fail "reference Redis for the comparisons" "PONG on port $REF_PORT" "no answer"
	fi
	docker rm -f "$REF_CONTAINER" >/dev/null 2>&1
else
	fail "reference Redis for the comparisons" "container started" "docker run failed"
fi
expect "flushall before bitmaps" "OK" flushall
expect_pipe "setbit getbit" $'0\n1\n0\n1\n0\n0\n0\n0\n13\n2\nERR bit offset is not an integer or out of range\n\nERR bit offset is not an integer or out of range\n\nERR bit is not an integer or out of range\n\nERR bit offset is not an integer or out of range\n\nERR bit offset is not an integer or out of range\n\nERR wrong number of arguments for \'setbit\' command\n\nERR wrong number of arguments for \'getbit\' command\n\n0\n536870912\n4294967295\n1' "$(cat <<'CMDS'
SETBIT bm 7 1
SETBIT bm 7 0
SETBIT bm 7 1
GETBIT bm 7
GETBIT bm 6
GETBIT bm 100
GETBIT nobm 0
SETBIT bm 100 1
STRLEN bm
BITCOUNT bm
SETBIT bm -1 1
SETBIT bm 4294967296 1
SETBIT bm 0 2
SETBIT bm abc 1
GETBIT bm abc
SETBIT bm 1
GETBIT bm
SETBIT sb 4294967295 1
STRLEN sb
BITPOS sb 1
DEL sb
CMDS
)"
expect_pipe "bitcount bitpos" $'OK\n26\n4\n6\n18\n17\n26\n0\n26\n0\n0\nERR syntax error\n\nERR syntax error\n\nERR value is not an integer or out of range\n\nERR wrong number of arguments for \'bitcount\' command\n\nOK\n12\n0\n12\n-1\n12\n12\nOK\n24\n24\n-1\nOK\n-1\n0\n-1\nERR The bit argument must be 1 or 0.\n\nERR value is not an integer or out of range\n\nERR syntax error\n\nERR syntax error\n\nERR wrong number of arguments for \'bitpos\' command' "$(cat <<'CMDS'
SET bc foobar
BITCOUNT bc
BITCOUNT bc 0 0
BITCOUNT bc 1 1
BITCOUNT bc 1 -2
BITCOUNT bc 5 30 BIT
BITCOUNT bc 0 -1 bit
BITCOUNT bc -6 -7
BITCOUNT bc 0 1000
BITCOUNT nobc
BITCOUNT nobc 0 10 BIT
BITCOUNT bc 0
BITCOUNT bc 0 1 BITS
BITCOUNT bc a 1
BITCOUNT
SET bp "\xff\xf0\x00"
BITPOS bp 0
BITPOS bp 1
BITPOS bp 0 1
BITPOS bp 1 2
BITPOS bp 0 0 -1 BIT
BITPOS bp 0 12 15 bit
SET ones "\xff\xff\xff"
BITPOS ones 0
BITPOS ones 0 0
BITPOS ones 0 0 -1
SET empty ""
BITPOS empty 0
BITPOS nobp 0
BITPOS nobp 1
BITPOS bp 2
BITPOS bp a
BITPOS bp 1 0 1 BITS
BITPOS bp 1 0 1 2 3
BITPOS bp
CMDS
)"
expect_pipe "bitop" $'OK\nOK\n4\n4\n4\n4\n10\n18\n8\n14\n4\nOK\nOK\n1\n2\nOK\n1\n4\n-1\n0\n0\n0\n0\nERR BITOP NOT must be called with a single source key.\n\nERR syntax error\n\nERR wrong number of arguments for \'bitop\' command' "$(cat <<'CMDS'
SET a "\x01\x02\xff\xff"
SET b "\x01\x02\xff"
BITOP AND dand a b
BITOP or dor a b missing
BITOP XOR dxor a b
BITOP NOT dnot a
BITCOUNT dand
BITCOUNT dor
BITCOUNT dxor
BITCOUNT dnot
STRLEN dand
SET n1 1
SET n2 2
BITOP XOR dn n1 n2 n1
GET dn
SET d1 v
EXPIRE d1 1000
BITOP OR d1 a
TTL d1
BITOP AND d1 missing1 missing2
EXISTS d1
BITOP NOT dself dself
EXISTS dself
BITOP NOT d a b
BITOP FOO d a
BITOP AND d
CMDS
)"
expect_pipe "bitfield" $'0\n0\n0\nABC\n65\n-100\n9\n1\n3\n\n-56\n-56\n200\n99\n99\nERR Invalid bitfield type. Use something like i16 u8. Note that u64 is not supported but i64 is.\n\nERR Invalid OVERFLOW type specified\n\nERR bit offset is not an integer or out of range\n\nERR syntax error\n\n\n66\nERR BITFIELD_RO only supports the GET subcommand\n\n\n0\n0\n0\n0\n0\n\n1\nERR wrong number of arguments for \'bitfield\' command\n\nERR wrong number of arguments for \'bitfield_ro\' command\n\nOK\n0\n0' "$(cat <<'CMDS'
BITFIELD bf SET u8 #0 65 SET u8 #1 66 SET u8 #2 67
GET bf
BITFIELD bf SET i8 0 -100 GET i8 0 GET u4 0
BITFIELD bf INCRBY u2 100 1 OVERFLOW SAT INCRBY u2 102 5 OVERFLOW FAIL INCRBY u2 102 1
BITFIELD bf OVERFLOW WRAP INCRBY i8 #0 300 GET i8 #0
BITFIELD bf SET u8 0 255 INCRBY u8 0 100 GET u8 0
BITFIELD bf GET u64 0
BITFIELD bf OVERFLOW BAD GET u8 0
BITFIELD bf GET u8 -1
BITFIELD bf FOO
BITFIELD bf
BITFIELD_RO bf GET u8 #1
BITFIELD_RO bf SET u8 0 1
BITFIELD_RO bf
BITFIELD nobf GET u8 0 GET i64 100
EXISTS nobf
BITFIELD_RO nobf GET u8 0
EXISTS nobf
BITFIELD nobf2 OVERFLOW FAIL SET u8 0 256
EXISTS nobf2
BITFIELD
BITFIELD_RO
SET ttlbf x EX 1000
BITFIELD ttlbf SET u8 #1 7
SETBIT ttlbf 30 1
CMDS
)"
expect_match "setbit and bitfield keep the ttl" '^(99[0-9]|1000)$' ttl ttlbf
expect "bitmap keys are strings" "string" type bf

got="$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/'"$PORT"'; printf "PING\r\nQUIT\r\n" >&3; cat <&3' 2>/dev/null | tr -d '\r')"
if [ "$got" == $'+PONG\n+OK' ]; then pass; else fail "quit replies OK and closes" $'+PONG\n+OK' "$got"; fi
expect "server alive after quit" "PONG" ping

expect "function flush" "OK" function flush
expect "function flush async" "OK" function flush async
expect "function flush bad mode" "ERR FUNCTION FLUSH only supports SYNC|ASYNC option" function flush lazy
expect "function flush too many args" $'ERR unknown subcommand or wrong number of arguments for \'flush\'. Try FUNCTION HELP.' function flush sync extra
expect "function list" "" function list
expect "function list bad arg" "ERR Unknown argument foo" function list foo
expect "function stats" $'running_script\n\nengines\nLUA\nlibraries_count\n0\nfunctions_count\n0' function stats
expect "function delete" "ERR Library not found" function delete mylib
expect "function load" "ERR Missing library metadata" function load "return 1"
expect "function load bad option" "ERR Unknown option given: FORCE" function load FORCE "return 1"
expect "function restore bad payload" "ERR DUMP payload version or checksum are wrong" function restore notapayload
expect "function kill" "NOTBUSY No scripts in execution right now." function kill
expect "function stats arity" $'ERR wrong number of arguments for \'function|stats\' command' function stats x
expect "function unknown subcommand" $'ERR unknown subcommand \'FOO\'. Try FUNCTION HELP.' function FOO
expect_match "function help" '^FUNCTION <subcommand> ' function help

got="$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/'"$PORT"'; printf "*1\r\n\$4\r\nPING\r\n*1\r\n\$4\r\nPING\rX*1\r\n\$4\r\nQUIT\r\n" >&3; cat <&3' 2>/dev/null | tr -d '\r')"
if [ "$got" == $'+PONG\n+PONG\n+OK' ]; then pass; else fail "lone carriage return after a bulk ends the bulk as in redis 7.4" $'+PONG\n+PONG\n+OK' "$got"; fi
got="$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/'"$PORT"'; printf "*1\r\n\$4\rXPING\r\n*1\r\n\$4\r\nQUIT\r\n" >&3; cat <&3' 2>/dev/null | tr -d '\r')"
if [ "$got" == $'+PONG\n+OK' ]; then pass; else fail "lone carriage return after a bulk length ends the line as in redis 7.4" $'+PONG\n+OK' "$got"; fi
got="$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/'"$PORT"'; printf "*01\r\n\$4\r\nPING\r\n" >&3; cat <&3' 2>/dev/null | tr -d '\r')"
if [ "$got" == $'-ERR Protocol error: invalid multibulk length' ]; then pass; else fail "multibulk count with a leading zero is rejected" $'-ERR Protocol error: invalid multibulk length' "$got"; fi
got="$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/'"$PORT"'; printf "*1\r\n\$04\r\nPING\r\n" >&3; cat <&3' 2>/dev/null | tr -d '\r')"
if [ "$got" == $'-ERR Protocol error: invalid bulk length' ]; then pass; else fail "bulk length with a leading zero is rejected" $'-ERR Protocol error: invalid bulk length' "$got"; fi
got="$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/'"$PORT"'; printf "ECHO \"a\\\\nb\\\\x41\\\\\"\"\r\nQUIT\r\n" >&3; cat <&3' 2>/dev/null | od -An -c | tr -s ' \n' ' ')"
if [ "$got" == ' $ 5 \r \n a \n b A " \r \n + O K \r \n ' ]; then pass; else fail "inline escapes are decoded" ' $ 5 \r \n a \n b A " \r \n + O K \r \n ' "$got"; fi
expect "server alive after protocol errors" "PONG" ping

check_eq() {
	if [ "$3" == "$2" ]; then pass; else fail "$1" "$2" "$3"; fi
}

wait_bgsave() {
	local i
	for i in $(seq 1 100); do
		if [ "$(info_field persistence rdb_bgsave_in_progress)" == "0" ]; then
			return 0
		fi
		sleep 0.05
	done
	return 1
}

restart_eski() {
	cli shutdown "$@" >/dev/null 2>&1
	if [ -n "$SERVER_PID" ]; then
		wait "$SERVER_PID" 2>/dev/null
	fi
	"$BINARY" --port "$PORT" --enable-debug-command yes --dir "$PERSIST_DIR" --memcached-port "$MC_PORT" --keyspace-threads "$KEYSPACE_THREADS" >>"$LOG" 2>&1 &
	SERVER_PID=$!
	for _ in $(seq 1 100); do
		if [ "$(cli ping)" == "PONG" ]; then
			return 0
		fi
		sleep 0.05
	done
	return 1
}

if [ "$EXTERNAL" != "1" ]; then
	echo "persistence: save, restart and verify every type"
	wait_bgsave
	expect "persist flushall" "OK" flushall
	cli set p:int 12345 >/dev/null
	cli set p:embstr hello >/dev/null
	cli set p:raw "$(printf 'a%.0s' $(seq 1 120))" >/dev/null
	cli set p:ttl will-expire-later >/dev/null
	cli pexpireat p:ttl 4102444800000 >/dev/null
	echo 'SET p:bin "\x00\xff\r\n"' | cli_pipe >/dev/null
	cli set p:bigint 9223372036854775807 >/dev/null
	cli set 12345 numeric-key >/dev/null
	cli rpush p:lp a b 1 2 -3 >/dev/null
	for i in $(seq 1 2000); do echo "RPUSH p:ql item-$i"; done | cli_pipe >/dev/null
	cli sadd p:intset 1 2 3 >/dev/null
	cli sadd p:setlp a b c >/dev/null
	for i in $(seq 1 300); do echo "SADD p:setht m$i"; done | cli_pipe >/dev/null
	cli zadd p:zlp 1 a 2.5 b -3 c >/dev/null
	for i in $(seq 1 200); do echo "ZADD p:zsl $i m$i"; done | cli_pipe >/dev/null
	cli hset p:hlp f1 v1 f2 v2 >/dev/null
	cli hset p:hlpex a 1 b 2 c 3 >/dev/null
	cli hpexpireat p:hlpex 4102444800000 fields 1 b >/dev/null
	for i in $(seq 1 600); do echo "HSET p:hht f$i v$i"; done | cli_pipe >/dev/null
	for i in $(seq 1 600); do echo "HSET p:hhtex f$i v$i"; done | cli_pipe >/dev/null
	cli hpexpireat p:hhtex 4102444800000 fields 2 f1 f2 >/dev/null
	cli xadd p:stream 1-1 a 1 >/dev/null
	cli xadd p:stream 2-1 b 2 c 3 >/dev/null
	cli xgroup create p:stream g 0 >/dev/null
	cli xreadgroup group g alice count 1 streams p:stream ">" >/dev/null
	cli -n 3 set p:db3 in-db-three >/dev/null
	cli -n 3 pexpireat p:db3 4102444800000 >/dev/null
	persist_keys="p:int p:embstr p:raw p:ttl p:bin p:bigint 12345 p:lp p:ql p:intset p:setlp p:setht p:zlp p:zsl p:hlp p:hlpex p:hht p:hhtex p:stream"
	persist_encodings() {
		local k out=""
		for k in $persist_keys; do
			out+="$k=$(cli object encoding "$k") "
		done
		printf '%s' "$out"
	}
	enc_before="$(persist_encodings)"
	check_eq "persist encodings cover every type" "p:int=int p:embstr=embstr p:raw=raw p:ttl=embstr p:bin=embstr p:bigint=int 12345=embstr p:lp=listpack p:ql=quicklist p:intset=intset p:setlp=listpack p:setht=hashtable p:zlp=listpack p:zsl=skiplist p:hlp=listpack p:hlpex=listpackex p:hht=hashtable p:hhtex=hashtable p:stream=stream " "$enc_before"
	digest_before="$(cli debug digest)"
	xinfo_before="$(cli xinfo stream p:stream full)"
	expect_match "persist digest is not empty" '^[0-9a-f]{40}$' debug digest
	expect "persist save" "OK" save
	check_eq "persist changes reset by save" "0" "$(info_field persistence rdb_changes_since_last_save)"
	check_eq "persist last bgsave status" "ok" "$(info_field persistence rdb_last_bgsave_status)"
	if [ -s "$PERSIST_DIR/dump.rdb" ] && [ "$(head -c 9 "$PERSIST_DIR/dump.rdb")" == "REDIS0012" ]; then pass; else fail "persist file has the REDIS0012 header" "REDIS0012" "$(head -c 9 "$PERSIST_DIR/dump.rdb" 2>/dev/null)"; fi
	expect "persist set bumps the change counter" "OK" set p:after-save 1
	check_eq "persist changes since last save" "1" "$(info_field persistence rdb_changes_since_last_save)"
	expect "persist del of the extra key" "1" del p:after-save
	if restart_eski nosave; then pass; else fail "persist restart after shutdown nosave" "PONG" "no answer"; fi
	expect "persist digest after restart" "$digest_before" debug digest
	check_eq "persist encodings after restart" "$enc_before" "$(persist_encodings)"
	check_eq "persist stream groups and pending entries after restart" "$xinfo_before" "$(cli xinfo stream p:stream full)"
	expect_match "persist key ttl after restart" '^[0-9]{6,}$' ttl p:ttl
	expect_match "persist db3 ttl after restart" '^[0-9]{6,}$' -n 3 ttl p:db3
	expect_match "persist hash field ttl after restart" '^4102444800000$' hpexpiretime p:hlpex fields 1 b
	check_eq "persist keys loaded" "20" "$(info_field persistence rdb_last_load_keys_loaded)"
	if grep -q "DB loaded from disk" "$LOG"; then pass; else fail "persist load log line" "DB loaded from disk" "missing"; fi
	expect "persist set before shutdown save" "OK" set p:int 54321
	if restart_eski save; then pass; else fail "persist restart after shutdown save" "PONG" "no answer"; fi
	expect "persist shutdown save kept the write" "54321" get p:int
	expect "persist config rdb-key-save-delay" "OK" config set rdb-key-save-delay 50000
	expect "persist bgsave starts" "Background saving started" bgsave
	check_eq "persist bgsave in progress" "1" "$(info_field persistence rdb_bgsave_in_progress)"
	expect "persist bgsave while one runs" "ERR Background save already in progress" bgsave
	expect "persist bgsave schedule while one runs" "ERR Background save already in progress" bgsave schedule
	expect "persist save while bgsave runs" "ERR Background save already in progress" save
	check_eq "persist keys total while saving" "20" "$(info_field persistence current_save_keys_total)"
	expect "persist config rdb-key-save-delay back" "OK" config set rdb-key-save-delay 0
	if wait_bgsave; then pass; else fail "persist bgsave finishes" "rdb_bgsave_in_progress:0" "still running"; fi
	check_eq "persist bgsave status ok" "ok" "$(info_field persistence rdb_last_bgsave_status)"
	if [[ "$(info_field persistence rdb_last_bgsave_time_sec)" =~ ^[0-9]+$ ]]; then pass; else fail "persist last bgsave time" "seconds" "$(info_field persistence rdb_last_bgsave_time_sec)"; fi
	expect "persist bgsave syntax" "ERR syntax error" bgsave foo
	digest_before="$(cli debug digest)"
	expect "persist debug reload" "OK" debug reload
	check_eq "persist digest after debug reload" "$digest_before" "$(cli debug digest)"
	expect "persist debug reload nosave" "OK" debug reload nosave
	expect "persist debug reload merge noflush" "OK" debug reload nosave noflush merge
	expect "persist debug reload bad option" "ERR DEBUG RELOAD only supports the MERGE, NOFLUSH and NOSAVE options." debug reload bogus
	expect "persist digest-value missing key" "0000000000000000000000000000000000000000" debug digest-value no-such-key
	expect "persist shutdown abort" "ERR No shutdown in progress." shutdown abort
	expect "persist shutdown abort with flags" "ERR syntax error" shutdown abort nosave
	expect "persist shutdown save nosave" "ERR syntax error" shutdown save nosave
	expect "persist shutdown bad flag" "ERR syntax error" shutdown bogus
	expect "persist config get dbfilename" $'dbfilename\ndump.rdb' config get dbfilename
	expect "persist config get rdbcompression" $'rdbcompression\nyes' config get rdbcompression
	expect "persist config set dir is protected" "ERR CONFIG SET failed (possibly related to argument 'dir') - can't set protected config" config set dir /tmp
	expect "persist config set rdbchecksum is immutable" "ERR CONFIG SET failed (possibly related to argument 'rdbchecksum') - can't set immutable config" config set rdbchecksum no
	expect "persist config set save" "OK" config set save "900 1 300 10"
	expect "persist config get save" $'save\n900 1 300 10' config get save
	expect "persist config set save odd" "ERR CONFIG SET failed (possibly related to argument 'save') - Invalid save parameters" config set save "1 2 3"
	expect "persist config set save zero seconds" "ERR CONFIG SET failed (possibly related to argument 'save') - Invalid save parameters" config set save "0 1"
	expect "persist config set sanitize" "OK" config set sanitize-dump-payload clients
	expect "persist config set sanitize bad" "ERR CONFIG SET failed (possibly related to argument 'sanitize-dump-payload') - argument(s) must be one of the following: no, yes, clients" config set sanitize-dump-payload maybe
	expect "persist config set bool bad" "ERR CONFIG SET failed (possibly related to argument 'rdbcompression') - argument must be 'yes' or 'no'" config set rdbcompression maybe
	expect "persist flushall with save points" "OK" flushall
	check_eq "persist flushall resets changes when save points exist" "0" "$(info_field persistence rdb_changes_since_last_save)"
	expect "persist flushall wrote an empty dataset" "0" dbsize
	if restart_eski nosave; then pass; else fail "persist restart after flushall" "PONG" "no answer"; fi
	expect "persist empty file loads empty" "0" dbsize
	expect "persist config save off" "OK" config set save ""
	expect "persist set then flushall without save points" "OK" set p:x 1
	expect "persist flushall" "OK" flushall
	if [[ "$(info_field persistence rdb_changes_since_last_save)" =~ ^[1-9][0-9]*$ ]]; then pass; else fail "persist flushall keeps changes without save points" "positive" "$(info_field persistence rdb_changes_since_last_save)"; fi
	if [ "$(id -u)" != "0" ]; then
		expect "persist config save for misconf" "OK" config set save "3600 1"
		chmod 555 "$PERSIST_DIR"
		expect "persist bgsave into a read only dir" "Background saving started" bgsave
		wait_bgsave
		check_eq "persist bgsave status err" "err" "$(info_field persistence rdb_last_bgsave_status)"
		expect "persist misconf rejects writes" "MISCONF Redis is configured to save RDB snapshots, but it's currently unable to persist to disk. Commands that may modify the data set are disabled, because this instance is configured to report errors during writes if RDB snapshotting fails (stop-writes-on-bgsave-error option). Please check the Redis logs for details about the RDB error." set p:y 1
		expect_match "persist misconf rejects ping" '^MISCONF ' ping
		expect "persist misconf allows reads" "" get p:y
		expect "persist save fails in a read only dir" "ERR" save
		expect "persist stop writes off" "OK" config set stop-writes-on-bgsave-error no
		expect "persist write allowed with stop writes off" "OK" set p:y 1
		expect "persist stop writes on" "OK" config set stop-writes-on-bgsave-error yes
		chmod 755 "$PERSIST_DIR"
		expect "persist bgsave after fixing the dir" "Background saving started" bgsave
		wait_bgsave
		check_eq "persist bgsave status recovered" "ok" "$(info_field persistence rdb_last_bgsave_status)"
		expect "persist writes accepted again" "OK" set p:y 2
		expect "persist config save off again" "OK" config set save ""
	fi
	expect "persist flushall at the end" "OK" flushall
	expect "persist save at the end" "OK" save
fi

if [ "$EXTERNAL" != "1" ]; then
	echo "persistence: append only file restart, kill and rewrite for every type"
	aof_restart() {
		local sig="$1"
		shift
		if [ "$sig" = KILL ]; then
			kill -9 "$SERVER_PID" 2>/dev/null
		else
			cli shutdown >/dev/null 2>&1
		fi
		wait "$SERVER_PID" 2>/dev/null
		"$BINARY" --port "$PORT" --enable-debug-command yes --dir "$PERSIST_DIR" --memcached-port "$MC_PORT" --keyspace-threads "$KEYSPACE_THREADS" "$@" >>"$LOG" 2>&1 &
		SERVER_PID=$!
		for _ in $(seq 1 100); do
			if [ "$(cli ping)" == "PONG" ]; then
				return 0
			fi
			sleep 0.05
		done
		return 1
	}
	aof_tail() {
		python3 -I -c '
import os
import sys
d = sys.argv[1]
m = open(os.path.join(d, "appendonly.aof.manifest")).read().split("\n")
name = [l.split()[1] for l in m if l.endswith("type i")][-1]
data = open(os.path.join(d, name), "rb").read()
cmds = []
i = 0
while i < len(data):
    j = data.index(b"\r\n", i)
    if data[i:i + 1] == b"#":
        i = j + 2
        continue
    n = int(data[i + 1:j])
    i = j + 2
    args = []
    for _ in range(n):
        j = data.index(b"\r\n", i)
        ln = int(data[i + 1:j])
        args.append(data[j + 2:j + 2 + ln].decode("latin-1"))
        i = j + 4 + ln
    cmds.append(" ".join(args))
print("|".join(cmds[-int(sys.argv[2]):]))
' "$PERSIST_DIR/appendonlydir" "$1" 2>&1
	}
	mc_feed() {
		python3 -I -c '
import socket
import sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(sys.argv[2].replace("|", "\r\n").encode() + b"quit\r\n")
out = b""
while True:
    d = s.recv(65536)
    if not d:
        break
    out += d
print(out.decode("latin-1").replace("\r\n", "|"))
' "$MC_PORT" "$1" 2>&1
	}
	aof_snap() {
		python3 -I -B test/rdb/snapshot.py "$PORT" "$PERSIST_DIR/$1.json" >/dev/null 2>&1
	}
	aof_same() {
		local out
		out="$(python3 -I -B test/aof/snapcmp.py "$PERSIST_DIR/$1.json" "$PERSIST_DIR/$2.json" "$3" "${4:-type,digest,xinfo,encoding}" 2>&1)"
		if [ $? -eq 0 ]; then
			pass
			echo "  $out"
		else
			fail "$3" "identical snapshots" "$out"
		fi
	}
	aof_wait_rewrite() {
		for _ in $(seq 1 600); do
			if [ "$(info_field persistence aof_rewrite_in_progress)" == "0" ] && [ "$(info_field persistence aof_rewrite_scheduled)" == "0" ]; then
				return 0
			fi
			sleep 0.05
		done
		return 1
	}
	for policy in always everysec no; do
		rm -rf "$PERSIST_DIR/appendonlydir"
		if aof_restart TERM --appendonly yes --appendfsync "$policy"; then pass; else fail "aof start with appendfsync $policy" "PONG" "no answer"; fi
		check_eq "aof $policy enabled" "1" "$(info_field persistence aof_enabled)"
		expect "aof $policy config appendfsync" $'appendfsync\n'"$policy" config get appendfsync
		if [ -s "$PERSIST_DIR/appendonlydir/appendonly.aof.manifest" ]; then pass; else fail "aof $policy manifest created on start" "manifest" "missing"; fi
		python3 -I -B test/aof/workload.py "$PORT" build >/dev/null 2>&1
		aof_snap "aof-$policy-a"
		if aof_restart TERM --appendonly yes --appendfsync "$policy"; then pass; else fail "aof $policy restart" "PONG" "no answer"; fi
		aof_snap "aof-$policy-b"
		aof_same "aof-$policy-a" "aof-$policy-b" "aof appendfsync $policy, every type through SHUTDOWN and restart"
		python3 -I -B test/aof/workload.py "$PORT" more >/dev/null 2>&1
		aof_snap "aof-$policy-c"
		if aof_restart KILL --appendonly yes --appendfsync "$policy"; then pass; else fail "aof $policy restart after kill" "PONG" "no answer"; fi
		aof_snap "aof-$policy-d"
		aof_same "aof-$policy-c" "aof-$policy-d" "aof appendfsync $policy, every type through kill -9 and restart"
	done
	expect "aof rewrite starts" "Background append only file rewriting started" bgrewriteaof
	aof_wait_rewrite
	check_eq "aof rewrite status" "ok" "$(info_field persistence aof_last_bgrewrite_status)"
	check_eq "aof rewrites counted" "1" "$(info_field persistence aof_rewrites)"
	expect "aof set after the rdb base rewrite" "OK" set aof:after-rdb-base 1
	aof_snap aof-rw-a
	expect "aof debug loadaof after the rdb base rewrite" "OK" debug loadaof
	aof_snap aof-rw-b
	aof_same aof-rw-a aof-rw-b "aof BGREWRITEAOF with an RDB base then DEBUG LOADAOF"
	expect "aof preamble off" "OK" config set aof-use-rdb-preamble no
	expect "aof slow rewrite" "OK" config set rdb-key-save-delay 5000
	expect "aof command base rewrite starts" "Background append only file rewriting started" bgrewriteaof
	expect "aof rewrite already running" "ERR Background append only file rewriting already in progress" bgrewriteaof
	check_eq "aof rewrite in progress" "1" "$(info_field persistence aof_rewrite_in_progress)"
	expect "aof rewrite delay off" "OK" config set rdb-key-save-delay 0
	aof_wait_rewrite
	expect "aof set after the command base rewrite" "OK" set aof:after-aof-base 1
	aof_snap aof-rw-c
	expect "aof debug loadaof after the command base rewrite" "OK" debug loadaof
	aof_snap aof-rw-d
	aof_same aof-rw-c aof-rw-d "aof BGREWRITEAOF with a command base then DEBUG LOADAOF" type,digest
	check_eq "aof files after two rewrites" "appendonly.aof.3.base.aof appendonly.aof.3.incr.aof appendonly.aof.manifest" "$(ls "$PERSIST_DIR/appendonlydir" | tr '\n' ' ' | sed 's/ $//')"
	expect "aof appendfsync rejects other values" "ERR CONFIG SET failed (possibly related to argument 'appendfsync') - argument(s) must be one of the following: everysec, always, no" config set appendfsync sometimes
	expect "aof appenddirname is immutable" "ERR CONFIG SET failed (possibly related to argument 'appenddirname') - can't set immutable config" config set appenddirname other
	expect "aof percentage range" "ERR CONFIG SET failed (possibly related to argument 'auto-aof-rewrite-percentage') - argument must be between 0 and 2147483647 inclusive" config set auto-aof-rewrite-percentage -1
	expect "aof min size memory value" "ERR CONFIG SET failed (possibly related to argument 'auto-aof-rewrite-min-size') - argument must be a memory value" config set auto-aof-rewrite-min-size 1x
	expect "aof preamble back on" "OK" config set aof-use-rdb-preamble yes
	expect "aof off at runtime" "OK" config set appendonly no
	check_eq "aof disabled" "0" "$(info_field persistence aof_enabled)"
	expect "aof on at runtime" "OK" config set appendonly yes
	aof_wait_rewrite
	check_eq "aof enabled again" "1" "$(info_field persistence aof_enabled)"
	expect "aof write before the transactions" "OK" set aof:tx:pre 1
	printf 'MULTI\nSET aof:tx:a 1\nINCR aof:tx:b\nEXEC\n' | cli_pipe >/dev/null
	check_eq "aof transaction wrapped in one MULTI and EXEC" "MULTI|SET aof:tx:a 1|INCR aof:tx:b|EXEC" "$(aof_tail 4)"
	printf 'MULTI\nSET aof:tx:c 1\nGET aof:tx:a\nEXEC\n' | cli_pipe >/dev/null
	check_eq "aof transaction with one write is not wrapped" "EXEC|SET aof:tx:c 1" "$(aof_tail 2)"
	printf 'MULTI\nGET aof:tx:a\nEXEC\nMULTI\nSET aof:tx:d 1\nDISCARD\nMULTI\nSET aof:tx:e\nEXEC\nWATCH aof:tx:a\nSET aof:tx:a 2\nMULTI\nSET aof:tx:f 1\nEXEC\n' | cli_pipe >/dev/null
	check_eq "aof read only, discarded, aborted and watch failed transactions write nothing" "SET aof:tx:c 1|SET aof:tx:a 2" "$(aof_tail 2)"
	printf 'MULTI\nSET aof:tx:g 1\nSELECT 2\nSET aof:tx:h 1\nSELECT 0\nEXEC\n' | cli_pipe >/dev/null
	check_eq "aof transaction across databases selects inside MULTI" "MULTI|SET aof:tx:g 1|SELECT 2|SET aof:tx:h 1|EXEC" "$(aof_tail 5)"
	aof_snap aof-tx-a
	expect "aof debug loadaof after transactions" "OK" debug loadaof
	aof_snap aof-tx-b
	aof_same aof-tx-a aof-tx-b "aof transactions through DEBUG LOADAOF"
	check_eq "aof memcached writes" "STORED|STORED|STORED|STORED|15|STORED|TOUCHED|STORED|TOUCHED|STORED|DELETED|STORED|" "$(mc_feed 'set mc:a 5 0 3|abc|append mc:a 0 0 2|de|prepend mc:a 0 0 1|z|set mc:n 0 0 2|10|incr mc:n 5|set mc:t 0 1000 1|t|touch mc:t 2000|set mc:p 0 1000 1|p|touch mc:p 0|set mc:d 0 0 1|d|delete mc:d|set mc:x 0 -1 1|x|')"
	if aof_restart TERM --appendonly yes; then pass; else fail "aof restart after memcached writes" "PONG" "no answer"; fi
	expect "aof memcached append and prepend survive a restart" "zabcde" get mc:a
	expect "aof memcached incr survives a restart" "15" get mc:n
	mc_ttl="$(cli pttl mc:t)"
	if [ "$mc_ttl" -gt 1000000 ] && [ "$mc_ttl" -le 2000000 ]; then pass; else fail "aof memcached touch survives a restart" "pttl in (1000000, 2000000]" "$mc_ttl"; fi
	expect "aof memcached touch 0 survives a restart" "-1" pttl mc:p
	expect "aof memcached delete and dead set survive a restart" "0" exists mc:d mc:x
	check_eq "aof memcached flush_all" "OK|" "$(mc_feed 'flush_all|')"
	check_eq "aof memcached flush_all propagated as FLUSHDB" "FLUSHDB" "$(aof_tail 1)"
	expect "aof flushall at the end" "OK" flushall
	if aof_restart TERM; then pass; else fail "restart without the append only file" "PONG" "no answer"; fi
	check_eq "aof disabled after restart" "0" "$(info_field persistence aof_enabled)"
fi

if [ -n "$MIGRATE_REF_OUTPUT" ]; then
	echo "migrate: eski into a second eski on port $MIGRATE_PORT"
	mkdir -p "$PERSIST_DIR/second"
	"$BINARY" --port "$MIGRATE_PORT" --enable-debug-command yes --bind 127.0.0.1 --dir "$PERSIST_DIR/second" --keyspace-threads "$KEYSPACE_THREADS" >>"$LOG" 2>&1 &
	MIGRATE_PID=$!
	up=0
	for _ in $(seq 1 100); do
		if [ "$(docker exec "$CLI_CONTAINER" redis-cli -p "$MIGRATE_PORT" ping 2>&1)" == "PONG" ]; then
			up=1
			break
		fi
		sleep 0.05
	done
	if [ "$up" == "1" ]; then
		pass
		if wait_migrate_idle "$PORT"; then pass; else fail "eski has no cached migrate socket before the second run" "0" "$(migrate_cached "$PORT")"; fi
		compare_lines "migrate from eski into eski against redis into eski" "$MIGRATE_REF_OUTPUT" "$(timeout 120 python3 -I test/rdb/migratecmp.py "$PORT" "$MIGRATE_PORT" 2>&1)"
		check_eq "migrate cached sockets after the run" "1" "$(migrate_cached "$PORT")"
		expect "migrate keys into the second eski" "OK" mset m:a 1 m:b 2 m:c 3
		expect "migrate keys option" "OK" migrate 127.0.0.1 "$MIGRATE_PORT" "" 0 5000 keys m:a m:b m:c m:missing
		expect "migrate keys moved out of the source" "0" exists m:a m:b m:c
		check_eq "migrate keys arrived on the target" "3" "$(docker exec "$CLI_CONTAINER" redis-cli -p "$MIGRATE_PORT" exists m:a m:b m:c 2>&1)"
		expect "migrate nokey with only missing keys" "NOKEY" migrate 127.0.0.1 "$MIGRATE_PORT" "" 0 5000 keys m:a m:b
		cli set m:dump-src hello >/dev/null
		expect "migrate to a closed port" "IOERR error or timeout writing to target instance" migrate 127.0.0.1 1 m:dump-src 0 300 copy
		expect "migrate copy keeps the source" "OK" migrate 127.0.0.1 "$MIGRATE_PORT" m:dump-src 0 5000 copy
		expect "migrate copy source still there" "hello" get m:dump-src
		check_eq "migrate copy target value" "hello" "$(docker exec "$CLI_CONTAINER" redis-cli -p "$MIGRATE_PORT" get m:dump-src 2>&1)"
		expect "migrate onto a busy key" "ERR Target instance replied with error: BUSYKEY Target key name already exists." migrate 127.0.0.1 "$MIGRATE_PORT" m:dump-src 0 5000 copy
		expect "migrate replace" "OK" migrate 127.0.0.1 "$MIGRATE_PORT" m:dump-src 0 5000 replace
		expect "migrate replace removed the source" "0" exists m:dump-src
		expect "migrate cleanup" "OK" flushall
	else
		fail "second eski for migrate" "PONG on port $MIGRATE_PORT" "no answer"
	fi
	kill "$MIGRATE_PID" 2>/dev/null
	wait "$MIGRATE_PID" 2>/dev/null
	MIGRATE_PID=""
fi

mc_port_open() {
	(exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

expect_memcached_report() {
	local label="$1" minimum="$2" line name n=0 summary=0
	shift 2
	while IFS= read -r line; do
		case "$line" in
		PASS\ *)
			n=$((n + 1))
			pass
			;;
		FAIL\ *)
			n=$((n + 1))
			name="${line#FAIL }"
			fail "memcached $label check: ${name%% eski=*}" "same as expected" "$name"
			;;
		passed:\ *)
			summary=1
			;;
		*)
			echo "  $line"
			;;
		esac
	done < <(timeout 300 python3 -I test/memcached/compare.py "$@" 2>&1)
	if [ "$summary" != "1" ] || [ "$n" -lt "$minimum" ]; then
		fail "memcached $label checks ran to completion" "at least $minimum checks" "$n"
	fi
}

if mc_port_open "$MC_PORT"; then
	echo "comparing the memcached port $MC_PORT with a reference memcached on $MC_REF_PORT"
	if docker run -d --rm --name "$MC_REF_CONTAINER" --network=host "$MC_IMAGE" memcached -p "$MC_REF_PORT" -U 0 -l 127.0.0.1 >/dev/null; then
		mc_ready=0
		for _ in $(seq 1 100); do
			if mc_port_open "$MC_REF_PORT"; then
				mc_ready=1
				break
			fi
			sleep 0.1
		done
		if [ "$mc_ready" == "1" ]; then
			sleep "$MC_REF_CLOCK_SETTLE_SECONDS"
			expect_memcached_report "byte for byte" 300 compare "$MC_PORT" "$MC_REF_PORT"
		else
			fail "reference memcached for the comparisons" "answer on port $MC_REF_PORT" "no answer"
		fi
		docker rm -f "$MC_REF_CONTAINER" >/dev/null 2>&1
	else
		fail "reference memcached for the comparisons" "container started" "docker run failed"
	fi
	expect_memcached_report "cross protocol" 35 cross "$PORT" "$MC_PORT"
	expect "server alive after memcached checks" "PONG" ping
elif [ "$EXTERNAL" == "1" ]; then
	echo "skipping the memcached checks, nothing listens on port $MC_PORT"
else
	fail "memcached port" "listening on $MC_PORT" "closed"
fi

if [ "$BENCH" == "1" ]; then
	echo "running redis-benchmark"
	bench_out="$(docker exec "$CLI_CONTAINER" redis-benchmark -p "$PORT" -t ping,set,get,incr,mset -n 200000 -c 50 -P 16 -q 2>&1 | tr '\r' '\n')"
	printf '%s\n' "$bench_out" | grep 'requests per second'
	nres="$(printf '%s\n' "$bench_out" | grep -c 'requests per second')"
	if [ "$nres" -ge 6 ] && ! printf '%s\n' "$bench_out" | grep -qiE 'error|ERR '; then pass; else fail "redis-benchmark" "6 result lines, no errors" "$bench_out"; fi
	expect "server alive after benchmark" "PONG" ping
else
	echo "skipping redis-benchmark step, set ESKI_SMOKE_BENCH=1 to run it"
fi

if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
	fail "server still running at end" "running" "exited"
fi

echo "passed: $PASS failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
	exit 1
fi
exit 0
