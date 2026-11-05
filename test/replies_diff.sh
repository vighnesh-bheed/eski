#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."

FIRST="${1:-${ESKI_DIFF_FIRST:-bin/eski-first}}"
SECOND="${2:-${ESKI_DIFF_SECOND:-bin/eski}}"
FIRST_PORT="${ESKI_DIFF_FIRST_PORT:-6422}"
SECOND_PORT="${ESKI_DIFF_SECOND_PORT:-$FIRST_PORT}"
IMAGE="${ESKI_REDIS_IMAGE:-docker.io/library/redis:7}"
KEEP="${ESKI_DIFF_KEEP:-0}"
RESP3="${ESKI_DIFF_RESP3:-1}"
WORK="$(mktemp -d -t eski-replies.XXXXXX)"
CLI_CONTAINER="eski-replies-cli-$$"
SERVER_PID=""

cleanup() {
	if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill "$SERVER_PID" 2>/dev/null
		wait "$SERVER_PID" 2>/dev/null
	fi
	docker rm -f "$CLI_CONTAINER" >/dev/null 2>&1
	if [ "$KEEP" == "1" ]; then
		echo "outputs kept in $WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT

for bin in "$FIRST" "$SECOND"; do
	if [ ! -x "$bin" ]; then
		echo "missing executable $bin"
		echo "usage: test/replies_diff.sh [first-binary] [second-binary]"
		exit 2
	fi
done

LONG_NAME="$(printf 'x%.0s' $(seq 1 140))"
LONG_ARG="$(printf 'a%.0s' $(seq 1 150))"
BIG_VALUE="$(printf 'v%.0s' $(seq 1 3000))"

cat >"$WORK/commands.txt" <<CMDS
FLUSHALL
PING
PING hello
PiNg
ping a b
ECHO "hi there"
ECHO
echo ""
ECHO "\x00\x01\xff bytes"
FOOBAR a b
nosuch
""
NOPE "a\r\nb" c
$LONG_NAME arg
UNKNOWNCMD $LONG_ARG b c
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
GeT k1
SET k3 v EX 0
SET k3 v PX -5
SET k3 v EX abc
SET k3 v NX XX
SET k3 v EX 10 PX 100
SET k3 v BOGUS
SET k3 v EX
SET k3 v EX 9999999999999999
SET k3 v KEEPTTL EX 10
SET k3 v EX 10 KEEPTTL
SET k3 v GET GET
SET k3 v xx nx
SET k3
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
SET t3 v EXAT 1
EXISTS t3
SET "key with spaces" "value\twith\ttabs"
GET "key with spaces"
SET empty ""
GET empty
STRLEN empty
APPEND empty ""
SET bigv $BIG_VALUE
GET bigv
STRLEN bigv
GETDEL k1
GETDEL k1
GETDEL
GETSET gs a
GETSET gs b
GET gs
GETSET gs
SETNX nx1 a
SETNX nx1 b
GET nx1
SETNX nx1
SETEX se 100 v
TTL se
PSETEX pse 100000 v
SETEX se 50 v
GET pse
SETEX se 0 v
SETEX se x v
PSETEX pse -1 v
SETEX se 99999999999999999 v
SETEX se 100
MSET m1 a m2 b m3 c
MGET m1 m2 nope m3
MSET m1 a m2
MSETNX m1 x m9 y
MSETNX m8 x m9 y
MSETNX m8 x m9
MGET m8 m9
MGET
APPEND ap hello
APPEND ap " world"
GET ap
STRLEN ap
STRLEN nope
APPEND newap x
STRLEN
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
INCRBY cnt " 1"
INCRBY cnt 99999999999999999999
SET sp " 5"
INCR sp
INCR
DECR
DEL m1 m2 nope
UNLINK m3 nope
EXISTS m8 m9 m8 nope
TYPE m8
TYPE nope
DEL nope
DEL
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
EXPIRE e1 10 "bad\r\nopt"
EXPIRE nope 10
EXPIRE e1 abc
EXPIRE e1 99999999999999999
PEXPIRE e1 100000
EXPIREAT e1 99999999999
PEXPIREAT e1 99999999999000
PERSIST e1
PERSIST e1
PERSIST nope
TTL e1
TTL nope
PTTL nope
PTTL e1
SET e2 v
EXPIRE e2 -1
EXISTS e2
SET e3 v
EXPIREAT e3 1
GET e3
SET e4 v
PEXPIREAT e4 0
EXISTS e4
SET e5 v
EXPIRE e5 100 XX
EXPIRE e5 100 LT
EXPIRE e5 200 GT
TTL e5
EXPIRE
PEXPIRE e5
TOUCH m8 m9 nope
TOUCH
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
RENAME r4
OBJECT ENCODING r4
OBJECT encoding nope
OBJECT ENCODING
OBJECT FREQ r4
OBJECT
SET encint 12345
OBJECT ENCODING encint
SET encneg -9223372036854775808
OBJECT ENCODING encneg
SET encbig 9223372036854775808
OBJECT ENCODING encbig
SET enczero 012
OBJECT ENCODING enczero
SET encraw aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OBJECT ENCODING encraw
APPEND encint 6
OBJECT ENCODING encint
INCR encint
OBJECT ENCODING encint
APPEND encnew 42
OBJECT ENCODING encnew
FUNCTION FLUSH
FUNCTION FLUSH ASYNC
function flush sync
FUNCTION FLUSH bogus
FUNCTION FLUSH SYNC extra
FUNCTION LIST
FUNCTION LIST WITHCODE LIBRARYNAME lib
FUNCTION LIST LIBRARYNAME
FUNCTION LIST bogus
FUNCTION STATS
FUNCTION STATS x
FUNCTION DUMP
FUNCTION RESTORE "\x0c\x00\x96\xedh\x80\xf5U<\x93"
FUNCTION RESTORE bogus
FUNCTION RESTORE bogus BADPOLICY
FUNCTION RESTORE bogus FLUSH extra
FUNCTION DELETE lib
FUNCTION DELETE
FUNCTION LOAD "return 1"
FUNCTION LOAD REPLACE "#!lua name=lib\nreturn 1"
FUNCTION LOAD BOGUS code
FUNCTION LOAD
FUNCTION KILL
FUNCTION HELP
FUNCTION FOO
FUNCTION
FLUSHDB
DBSIZE
RANDOMKEY
SET only1 v
RANDOMKEY
DBSIZE
MSET hello 1 hallo 1 hxllo 1 hllo 1 heeeello 1 other 1
KEYS zzz*
KEYS hello
KEYS h[a-b]llo
KEYS H*
KEYS h\\*llo
ECHO __sorted__
KEYS *
KEYS h?llo
KEYS h*llo
KEYS h[ae]llo
KEYS h[^e]llo
SCAN 0 COUNT 1000
SCAN 0 MATCH h?llo COUNT 1000
SCAN 0 MATCH * COUNT 1000 TYPE string
ECHO __exact__
SCAN 0 COUNT 1000 TYPE hash
SCAN 99999999
SCAN abc
SCAN -1
SCAN 0 COUNT 0
SCAN 0 COUNT x
SCAN 0 MATCH
SCAN 0 BOGUS 1
SCAN
DBSIZE
DBSIZE x
FLUSHDB ASYNC
FLUSHALL SYNC
FLUSHALL foo
FLUSHALL a b
FLUSHDB sync
SELECT 0
SELECT 15
SELECT 16
SELECT -1
SELECT x
SELECT
AUTH pass
AUTH user pass
AUTH a b c
AUTH
HELLO 3
HELLO abc
HELLO 2 SETNAME
HELLO 2 BOGUS
HELLO 2 SETNAME "bad name"
HELLO 2 AUTH default pw
HELLO 2 SETNAME hn
CLIENT GETNAME
HELLO
HELLO 2
CLIENT SETNAME myname
CLIENT GETNAME
CLIENT SETINFO lib-name smoke
CLIENT SETINFO lib-name
CLIENT SETNAME "bad name"
CLIENT SETNAME
CLIENT SETNAME ""
CLIENT GETNAME
CLIENT ID
CLIENT NO-EVICT on
CLIENT NO-TOUCH on
CLIENT FOO
CLIENT "bad\nsub"
CLIENT
ECHO __volatile__
CLIENT LIST
CLIENT INFO
ECHO __exact__
COMMAND
COMMAND COUNT
COMMAND DOCS
COMMAND DOCS get
COMMAND INFO get
COMMAND LIST
CONFIG GET save
CONFIG GET appendonly
CONFIG GET maxmemory
CONFIG GET *
CONFIG GET SAVE
CONFIG GET *max*
CONFIG GET save appendonly
CONFIG GET nonexistentparam
CONFIG GET
CONFIG SET maxmemory 100mb
CONFIG SET maxmemory
CONFIG SET a b c
CONFIG REWRITE
CONFIG FOO
CONFIG
DEBUG SLEEP 0
DEBUG FOO
DEBUG
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
DEBUG PROTOCOL map extra
SAVE
SAVE x
BGSAVE
BGSAVE SCHEDULE
BGSAVE a b
LASTSAVE x
TIME x
SET objkey abcdef
MEMORY USAGE objkey
MEMORY USAGE nope
MEMORY USAGE
MEMORY DOCTOR
MEMORY
SET exp1 v EX 1000
INFO keyspace
INFO clients
INFO replication
INFO bogus
ECHO __volatile__
TIME
LASTSAVE
PTTL exp1
INFO
INFO all
INFO server
INFO memory
INFO stats
INFO persistence
INFO server clients
INFO everything
INFO default
ECHO __exact__
CONFIG RESETSTAT
PING
DEBUG PROTOCOL bignum
DEBUG PROTOCOL attrib
CMDS

cat >"$WORK/client.py" <<'PY'
import hashlib
import re
import socket
import sys
import time


def split_args(line):
    s = line + b"\0"
    i = 0
    args = []
    while True:
        while s[i:i + 1] != b"\0" and s[i:i + 1].isspace():
            i += 1
        if s[i:i + 1] == b"\0":
            return args
        inq = insq = done = False
        cur = bytearray()
        while not done:
            ch = s[i:i + 1]
            nx = s[i + 1:i + 2]
            if inq:
                if ch == b"\\" and nx == b"x" and re.match(rb"[0-9a-fA-F]{2}", s[i + 2:i + 4]):
                    cur += bytes([int(s[i + 2:i + 4], 16)])
                    i += 3
                elif ch == b"\\" and nx not in (b"", b"\0"):
                    i += 1
                    cur += {b"n": b"\n", b"r": b"\r", b"t": b"\t", b"b": b"\b", b"a": b"\a"}.get(s[i:i + 1], s[i:i + 1])
                elif ch == b'"':
                    if nx not in (b"", b"\0") and not nx.isspace():
                        raise ValueError("bad quotes")
                    done = True
                elif ch == b"\0":
                    raise ValueError("unbalanced quotes")
                else:
                    cur += ch
            elif insq:
                if ch == b"\\" and nx == b"'":
                    i += 1
                    cur += b"'"
                elif ch == b"'":
                    if nx not in (b"", b"\0") and not nx.isspace():
                        raise ValueError("bad quotes")
                    done = True
                elif ch == b"\0":
                    raise ValueError("unbalanced quotes")
                else:
                    cur += ch
            else:
                if ch in (b" ", b"\n", b"\r", b"\t", b"\0"):
                    done = True
                elif ch == b'"':
                    inq = True
                elif ch == b"'":
                    insq = True
                else:
                    cur += ch
            if ch != b"\0":
                i += 1
        args.append(bytes(cur))


def encode(args):
    out = [b"*%d\r\n" % len(args)]
    for a in args:
        out.append(b"$%d\r\n%s\r\n" % (len(a), a))
    return b"".join(out)


class Incomplete(Exception):
    pass


def parse(buf, pos):
    if pos >= len(buf):
        raise Incomplete()
    t = buf[pos:pos + 1]
    eol = buf.find(b"\r\n", pos)
    if eol < 0:
        raise Incomplete()
    head = buf[pos + 1:eol]
    nxt = eol + 2
    if t in (b"+", b"-", b":", b"_", b",", b"#", b"("):
        return nxt, []
    if t in (b"$", b"=", b"!"):
        n = int(head)
        if n < 0:
            return nxt, []
        end = nxt + n + 2
        if end > len(buf):
            raise Incomplete()
        return end, []
    if t in (b"*", b"~", b">", b"%", b"|"):
        n = int(head)
        if n < 0:
            return nxt, []
        if t in (b"%", b"|"):
            n *= 2
        kids = []
        p = nxt
        for _ in range(n):
            q, k = parse(buf, p)
            kids.append((p, q, k))
            p = q
        if t == b"|":
            q, k = parse(buf, p)
            kids.append((p, q, k))
            p = q
        return p, kids
    raise ValueError("unknown reply type %r at %d" % (t, pos))


def canon_sorted(buf, start, end, kids):
    if not kids:
        return buf[start:end]
    parts = sorted(canon_sorted(buf, a, b, k) for a, b, k in kids)
    return buf[start:kids[0][0]] + b"".join(parts)


def show(b):
    if len(b) > 4096:
        return "%d bytes sha256 %s" % (len(b), hashlib.sha256(b).hexdigest())
    return repr(b)


def recv_all(sock, deadline, want=None):
    data = b""
    while time.time() < deadline:
        if want is not None and want(data):
            break
        try:
            chunk = sock.recv(1 << 20)
        except socket.timeout:
            if want is None:
                break
            continue
        except OSError:
            break
        if not chunk:
            break
        data += chunk
    return data


HELLO3 = encode([b"HELLO", b"3"])


def resp3_line(line):
    return re.sub(rb"^(\s*hello\s+)2(?=\s|$)", rb"\g<1>3", line, flags=re.I)


def mode_resp3_commands(src, dst):
    lines = open(src, "rb").read().split(b"\n")
    open(dst, "wb").write(b"\n".join(resp3_line(l) for l in lines))


def mode_raw(port, path, proto=2):
    lines = [l for l in open(path, "rb").read().split(b"\n") if l.strip()]
    cmds = [split_args(l) for l in lines]
    sock = socket.create_connection(("127.0.0.1", port))
    sock.settimeout(0.5)
    sock.sendall((HELLO3 if proto == 3 else b"") + b"".join(encode(a) for a in cmds))
    buf = b""
    pos = 0
    replies = []
    skip = 1 if proto == 3 else 0
    deadline = time.time() + 30
    while len(replies) < len(cmds) and time.time() < deadline:
        try:
            end, kids = parse(buf, pos)
            if skip:
                skip -= 1
            elif buf[pos:pos + 1] == b">" and replies:
                replies[-1] = (replies[-1][0], end, replies[-1][2])
            else:
                replies.append((pos, end, kids))
            pos = end
            continue
        except Incomplete:
            pass
        try:
            chunk = sock.recv(1 << 20)
        except socket.timeout:
            continue
        if not chunk:
            break
        buf += chunk
    sock.close()
    mode = "exact"
    for idx, (line, args) in enumerate(zip(lines, cmds)):
        if idx >= len(replies):
            print("%d MISSING REPLY for %r" % (idx, line))
            continue
        start, end, kids = replies[idx]
        if len(args) == 2 and args[0].lower() == b"echo" and args[1] in (b"__exact__", b"__sorted__", b"__volatile__"):
            mode = args[1].strip(b"_").decode()
        raw = re.sub(rb"master_replid:[0-9a-f]{40}", b"master_replid:X", buf[start:end])
        if mode == "sorted":
            raw = canon_sorted(buf, start, end, kids)
        elif mode == "volatile":
            raw = re.sub(rb"[0-9]+", b"N", re.sub(rb"run_id:[0-9a-f]+", b"run_id:X", raw))
        label = line if len(line) <= 80 else line[:60] + b"...(%d bytes)" % len(line)
        print("%d %s %s => %s" % (idx, mode, label.decode("latin1"), show(raw)))
    if pos != len(buf):
        print("TRAILING BYTES %s" % show(buf[pos:]))


WIRE_CASES = [
    ("inline ping", [b"PING\r\n"]),
    ("inline lf only", [b"ping\n"]),
    ("inline double quotes", [b'ECHO "hello world"\r\n']),
    ("inline single quotes", [b"SET 'a b' c\r\nGET 'a b'\r\n"]),
    ("inline escapes decoded", [b'ECHO "a\\r\\nb"\r\n']),
    ("inline tabs and blanks", [b"\r\n  \r\n\tPING\t\r\n"]),
    ("inline unbalanced quotes", [b'SET k "unbalanced\r\nPING\r\n']),
    ("inline quote followed by text", [b"ECHO 'x'y\r\nPING\r\n"]),
    ("inline pipeline", [b"SET a 1\r\nINCR a\r\nGET a\r\nDEL a\r\n"]),
    ("inline unknown with args", [b"NOPE x y\r\n"]),
    ("inline too big", [b"a" * 70000]),
    ("multibulk ping", [b"*1\r\n$4\r\nPING\r\n"]),
    ("multibulk bad count", [b"*abc\r\nPING\r\n"]),
    ("multibulk count too many digits", [b"*99999999999\r\n"]),
    ("multibulk count over limit", [b"*2000000\r\n"]),
    ("multibulk expected dollar", [b"*1\r\nPING\r\n"]),
    ("multibulk bad bulk length", [b"*1\r\n$abc\r\n"]),
    ("multibulk bulk too long", [b"*1\r\n$600000000\r\n"]),
    ("multibulk negative count", [b"*-1\r\nPING\r\n"]),
    ("multibulk zero count", [b"*0\r\nPING\r\n"]),
    ("multibulk junk after bulk data", [b"*1\r\n$4\r\nPINGxx*1\r\n$4\r\nPING\r\n"]),
    ("multibulk lone cr after count", [b"*1\rX$4\r\nPING\r\n"]),
    ("multibulk lone cr after bulk length", [b"*1\r\n$4\rXPING\r\n"]),
    ("multibulk lone cr after bulk data", [b"*1\r\n$4\r\nPING\r\n*1\r\n$4\r\nPING\rX"]),
    ("multibulk lf without cr after bulk data", [b"*1\r\n$4\r\nPINGX\n"]),
    ("multibulk bad count then lone cr", [b"*1x\rX$4\r\nPING\r\n"]),
    ("multibulk bad count waits for line end", [b"*1x", b"\r\n$4\r\nPING\r\n"]),
    ("multibulk cr and lf split across writes", [b"*1\r\n$4\r\nPING\r", b"\n*1\r\n$4\r\nPING\r\n"]),
    ("multibulk split across writes", [b"*2\r\n$4\r\nEC", b"HO\r\n$2\r\nhi\r\n"]),
    ("multibulk split header", [b"*3\r\n$3\r\nSET\r", b"\n$1\r\nk\r\n$3\r\nabc\r\n*2\r\n$3\r\nGET\r\n$1\r\nk\r\n"]),
    ("multibulk incomplete then close", [b"*2\r\n$4\r\nPING\r\n"]),
    ("hello 3 over resp", [b"*2\r\n$5\r\nHELLO\r\n$1\r\n3\r\n"]),
    ("quit closes", [b"*1\r\n$4\r\nQUIT\r\nPING\r\n"]),
    ("inline quit closes", [b"PING\r\nQUIT\r\nPING\r\n"]),
    ("pipelined burst", [b"*1\r\n$4\r\nPING\r\n" * 5000]),
    ("large value round trip", [encode([b"SET", b"wirebig", b"x" * 1500000]) + encode([b"GET", b"wirebig"]) + encode([b"STRLEN", b"wirebig"]) + encode([b"DEL", b"wirebig"])]),
    ("many args unknown", [encode([b"NOPE"] + [b"arg%d" % i for i in range(100)])]),
    ("mget many", [encode([b"MSET"] + [b"k%d" % (i // 2) if i % 2 == 0 else b"v" for i in range(400)]) + encode([b"MGET"] + [b"k%d" % i for i in range(250)])]),
    ("multibulk count leading zero", [b"*01\r\n$4\r\nPING\r\n"]),
    ("multibulk count two zeros", [b"*00\r\nPING\r\n"]),
    ("multibulk count minus zero", [b"*-0\r\nPING\r\n"]),
    ("multibulk count plus sign", [b"*+1\r\n$4\r\nPING\r\n"]),
    ("multibulk count empty", [b"*\r\nPING\r\n"]),
    ("multibulk negative count leading zero", [b"*-01\r\nPING\r\n"]),
    ("multibulk negative count below one million", [b"*-1048577\r\nPING\r\n"]),
    ("multibulk negative count eleven digits", [b"*-99999999999\r\nPING\r\n"]),
    ("multibulk count smallest long long", [b"*-9223372036854775808\r\nPING\r\n"]),
    ("multibulk count below smallest long long", [b"*-9223372036854775809\r\nPING\r\n"]),
    ("multibulk count int max waits", [b"*2147483647\r\n$4\r\nPING\r\n"]),
    ("multibulk count above int max", [b"*2147483648\r\nPING\r\n"]),
    ("multibulk count above one million waits", [b"*1048577\r\n$4\r\nPING\r\n"]),
    ("multibulk count trailing space", [b"*1 \r\nPING\r\n"]),
    ("multibulk count cr at the end waits", [b"*1\r"]),
    ("multibulk count cr split across writes", [b"*1\r", b"X$4\r\nPING\r\n"]),
    ("multibulk count followed by two crs", [b"*1\r\r\n$4\r\nPING\r\n"]),
    ("multibulk count nul byte waits", [b"*1\x00\r\n$4\r\nPING\r\n"]),
    ("multibulk count lf only", [b"*1\n$4\r\nPING\r\n"]),
    ("multibulk count line too big", [b"*" + b"1" * 70000]),
    ("multibulk count nul byte too big", [b"*1\x00" + b"\r\n" * 35000]),
    ("multibulk bulk length leading zero", [b"*1\r\n$04\r\nPING\r\n"]),
    ("multibulk bulk length two zeros", [b"*1\r\n$00\r\n\r\n"]),
    ("multibulk bulk length zero", [b"*2\r\n$4\r\nECHO\r\n$0\r\n\r\n"]),
    ("multibulk bulk length minus one", [b"*1\r\n$-1\r\nPING\r\n"]),
    ("multibulk bulk length plus sign", [b"*1\r\n$+4\r\nPING\r\n"]),
    ("multibulk bulk length empty", [b"*1\r\n$\r\nPING\r\n"]),
    ("multibulk bulk length above maximum", [b"*1\r\n$536870913\r\n"]),
    ("multibulk empty bulk ended by lone cr", [b"*2\r\n$4\r\nECHO\r\n$0\rXab"]),
    ("multibulk bulk data followed by two lfs", [b"*1\r\n$4\r\nPING\n\n"]),
    ("multibulk bulk length nul byte waits", [b"*1\r\n$4\x00\r\nPING\r\n"]),
    ("multibulk bulk length line too big", [b"*1\r\n$" + b"1" * 70000]),
    ("multibulk bulk data with nul byte", [b"*2\r\n$4\r\nECHO\r\n$3\r\na\x00b\r\n"]),
    ("multibulk int max count then junk", [b"*2147483647\r\n" + b"$1\r\nx\r\n" * 1000, b"X\r\n"]),
    ("multibulk expected dollar waits for the line", [b"*1\r\nX"]),
    ("multibulk expected dollar waits after cr", [b"*1\r\nX\r"]),
    ("multibulk expected dollar full line", [b"*1\r\nX\r\n"]),
    ("multibulk expected dollar lone cr", [b"*1\r\nX\rY"]),
    ("multibulk expected dollar split", [b"*1\r\nX", b"\r\n"]),
    ("multibulk expected dollar got cr", [b"*1\r\n\r\n"]),
    ("multibulk expected dollar got lf", [b"*1\r\n\n\r\n"]),
    ("multibulk expected dollar nul byte waits", [b"*1\r\nX\x00\r\n"]),
    ("multibulk expected dollar second argument", [b"*2\r\n$4\r\nECHO\r\n:1\r\n"]),
    ("multibulk expected dollar line too big", [b"*1\r\n" + b"X" * 70000]),
    ("multibulk ping then waiting wrong byte", [b"PING\r\n*1\r\nX"]),
    ("inline nul byte before line end waits", [b"PING\x00\r\n"]),
    ("inline leading nul byte waits", [b"\x00PING\r\n"]),
    ("inline nul byte too big", [b"PING\x00" + b"\r\n" * 35000]),
    ("inline escaped newline", [b'ECHO "a\\nb"\r\n']),
    ("inline hex escapes", [b'ECHO "\\x41\\x42\\x00\\xff\\x4a"\r\n']),
    ("inline invalid hex escapes", [b'ECHO "\\xZZ \\x4G a\\x4"\r\n']),
    ("inline escaped double quote", [b'ECHO "a\\"b"\r\n']),
    ("inline other escapes", [b'ECHO "\\t\\r\\a\\b\\z\\\\"\r\n']),
    ("inline escaped single quote", [b"ECHO 'a\\'b'\r\n"]),
    ("inline backslashes kept in single quotes", [b"ECHO 'a\\nb\\x41'\r\n"]),
    ("inline text then quoted part", [b'ECHO a"b c"\r\n']),
    ("inline text then single quoted part", [b"ECHO x'y z'\r\n"]),
    ("inline escaped quote at the end", [b'ECHO "a\\"\r\n']),
    ("inline backslash at the end", [b'ECHO "a\\\r\n']),
    ("inline closing quote then vertical tab", [b'ECHO "a"\x0b\r\n']),
    ("inline closing quote then single quote", [b"ECHO \"a\"'b'\r\n"]),
    ("inline leading vertical tab", [b"\x0bPING\r\n"]),
    ("inline cr between arguments", [b"PING\rX\r\n"]),
    ("inline cr after closing quote", [b'ECHO "a"\rPING\r\n']),
    ("inline two crs", [b"PING\r\r\n"]),
    ("inline pipeline then bad count", [b"PING\r\nPING\r\n*01\r\n"]),
]


def wire_state(sock):
    sock.settimeout(0.05)
    try:
        return "open" if sock.recv(1) else "closed"
    except socket.timeout:
        return "open"
    except OSError:
        return "closed"


def mode_wire(port, proto=2):
    for name, chunks in WIRE_CASES:
        sock = socket.create_connection(("127.0.0.1", port))
        sock.settimeout(0.3)
        if proto == 3:
            sock.sendall(HELLO3)
            recv_all(sock, time.time() + 5, lambda d: d.endswith(b"\r\n") and (d.startswith(b"-") or d.endswith(b"*0\r\n")))
        for i, ch in enumerate(chunks):
            sock.sendall(ch)
            if i + 1 < len(chunks):
                time.sleep(0.05)
        if name == "multibulk incomplete then close":
            time.sleep(0.1)
            sock.shutdown(socket.SHUT_WR)
        data = recv_all(sock, time.time() + 5)
        print("%s => %s %s" % (name, wire_state(sock), show(data)))
        sock.close()


def mode_cli_normalize(path):
    mode = "exact"
    held = []
    out = []

    def flush():
        if held:
            out.extend(sorted(held))
            held.clear()

    for line in open(path, "rb").read().decode("latin1").split("\n"):
        line = re.sub(r"master_replid:[0-9a-f]{40}", "master_replid:X", line)
        m = re.fullmatch(r'"__(exact|sorted|volatile)__"', line)
        if m:
            flush()
            mode = m.group(1)
            out.append(line)
            continue
        if mode == "sorted":
            held.append(re.sub(r"^(\s*[0-9]+\) )+", "", line))
        elif mode == "volatile":
            out.append(re.sub(r"[0-9]+", "N", re.sub(r"run_id:[0-9a-f]+", "run_id:X", line)))
        else:
            out.append(line)
    flush()
    sys.stdout.write("\n".join(out))


if __name__ == "__main__":
    if sys.argv[1] == "raw":
        mode_raw(int(sys.argv[2]), sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 2)
    elif sys.argv[1] == "wire":
        mode_wire(int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 2)
    elif sys.argv[1] == "resp3-commands":
        mode_resp3_commands(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "cli-normalize":
        mode_cli_normalize(sys.argv[2])
PY

port_busy() {
	(exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

run_suite() {
	local label="$1" bin="$2" port="$3"
	local out="$WORK/$label"
	if port_busy "$port"; then
		echo "port $port is already in use"
		return 1
	fi
	"$bin" --port "$port" --enable-debug-command yes --bind 127.0.0.1 >"$out.log" 2>&1 &
	SERVER_PID=$!
	local ready=0
	for _ in $(seq 1 100); do
		if grep -q "listening on" "$out.log" 2>/dev/null; then
			ready=1
			break
		fi
		if ! kill -0 "$SERVER_PID" 2>/dev/null; then
			break
		fi
		sleep 0.05
	done
	if [ "$ready" != "1" ]; then
		echo "$bin did not start on port $port"
		cat "$out.log"
		return 1
	fi
	docker exec -i "$CLI_CONTAINER" redis-cli -p "$port" --no-raw <"$WORK/commands.txt" >"$out.cli.raw" 2>&1
	python3 -I "$WORK/client.py" cli-normalize "$out.cli.raw" >"$out.cli"
	python3 -I "$WORK/client.py" raw "$port" "$WORK/commands.txt" >"$out.resp" 2>&1
	python3 -I "$WORK/client.py" wire "$port" >"$out.wire" 2>&1
	if [ "$RESP3" == "1" ]; then
		docker exec -i "$CLI_CONTAINER" redis-cli -3 -p "$port" --no-raw <"$WORK/commands3.txt" >"$out.cli3.raw" 2>&1
		python3 -I "$WORK/client.py" cli-normalize "$out.cli3.raw" >"$out.cli3"
		python3 -I "$WORK/client.py" raw "$port" "$WORK/commands3.txt" 3 >"$out.resp3" 2>&1
		python3 -I "$WORK/client.py" wire "$port" 3 >"$out.wire3" 2>&1
	fi
	if ! kill -0 "$SERVER_PID" 2>/dev/null; then
		echo "$bin exited during the run"
		cat "$out.log"
		return 1
	fi
	kill "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	SERVER_PID=""
	return 0
}

python3 -I "$WORK/client.py" resp3-commands "$WORK/commands.txt" "$WORK/commands3.txt"

if ! docker run -d --rm --name "$CLI_CONTAINER" --network=host --entrypoint sleep "$IMAGE" infinity >/dev/null; then
	echo "could not start the redis-cli helper container from $IMAGE"
	exit 1
fi

run_suite first "$FIRST" "$FIRST_PORT" || exit 1
run_suite second "$SECOND" "$SECOND_PORT" || exit 1

ncmds="$(grep -c . "$WORK/commands.txt")"
echo "first:  $FIRST on port $FIRST_PORT"
echo "second: $SECOND on port $SECOND_PORT"
echo "command lines: $ncmds, wire cases: $(grep -c . "$WORK/first.wire")"
kinds="cli resp wire"
if [ "$RESP3" == "1" ]; then
	kinds="$kinds cli3 resp3 wire3"
fi
total=0
for kind in $kinds; do
	lines="$(wc -l <"$WORK/first.$kind")"
	if diff -u "$WORK/first.$kind" "$WORK/second.$kind" >"$WORK/diff.$kind"; then
		echo "$kind: identical ($lines lines)"
	else
		n=$(($(grep -c '^[-+]' "$WORK/diff.$kind") - 2))
		if [ "$n" -lt 1 ]; then
			n=1
		fi
		total=$((total + n))
		echo "$kind: $n differing lines"
		cat "$WORK/diff.$kind"
	fi
done
for kind in $kinds; do
	if [ "$kind" == "wire" ] || [ "$kind" == "wire3" ]; then
		continue
	fi
	if grep -q "MISSING REPLY\|TRAILING BYTES\|Invalid argument\|Could not connect" "$WORK/first.$kind"; then
		echo "$kind: the first run did not complete cleanly"
		total=$((total + 1))
	fi
done
echo "differences: $total"
if [ "$total" -ne 0 ]; then
	exit 1
fi
exit 0
