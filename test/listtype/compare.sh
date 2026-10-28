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

REF_PORT="${ESKI_LIST_REF_PORT:-6562}"
PORT="${ESKI_LIST_PORT:-6561}"
SERVER="${ESKI_LIST_SERVER:-bin/eski}"
SERVER_PID=""
IMAGE="docker.io/library/redis:7"
NAME="eski-list-compare-$REF_PORT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eski-list-compare.XXXXXX")"

cleanup() {
	if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	docker stop -t 2 "$NAME" >/dev/null 2>&1 || true
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	for _ in $(seq 1 100); do
		docker container inspect "$NAME" >/dev/null 2>&1 || break
		sleep 0.1
	done
	if [ "${ESKI_LIST_KEEP:-0}" = "1" ]; then
		echo "kept work directory $WORK" >&2
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

EXCHANGE=$(cat <<'PY'
import socket
import sys


def split_commands(data):
    cmds = []
    i = 0
    while i < len(data):
        if data[i:i + 1] != b'*':
            raise SystemExit('malformed script at byte %d' % i)
        j = data.index(b'\r\n', i)
        argc = int(data[i + 1:j])
        start = i
        i = j + 2
        for _ in range(argc):
            j = data.index(b'\r\n', i)
            n = int(data[i + 1:j])
            i = j + 2 + n + 2
        cmds.append(data[start:i])
    return cmds


class Reader:
    def __init__(self, sock):
        self.sock = sock
        self.buf = bytearray()
        self.pos = 0

    def fill(self):
        chunk = self.sock.recv(1 << 20)
        if not chunk:
            raise SystemExit('connection closed by server')
        self.buf += chunk

    def skip_line(self):
        while True:
            j = self.buf.find(b'\r\n', self.pos)
            if j >= 0:
                head = bytes(self.buf[self.pos:j])
                self.pos = j + 2
                return head
            self.fill()

    def need(self, n):
        while len(self.buf) - self.pos < n:
            self.fill()
        self.pos += n

    def reply(self):
        head = self.skip_line()
        kind = head[:1]
        if kind in (b'$', b'=', b'!'):
            n = int(head[1:])
            if n >= 0:
                self.need(n + 2)
            return
        if kind in (b'*', b'~', b'>', b'%', b'|'):
            n = int(head[1:])
            if kind in (b'%', b'|'):
                n *= 2
            for _ in range(max(n, 0)):
                self.reply()
            return
        if kind in (b'+', b'-', b':', b'_', b',', b'#', b'('):
            return
        raise SystemExit('unexpected reply %r' % head[:40])

    def raw_reply(self):
        start = self.pos
        self.reply()
        raw = bytes(self.buf[start:self.pos])
        if self.pos > (1 << 22):
            del self.buf[:self.pos]
            self.pos = 0
        return raw


def main():
    port = int(sys.argv[1])
    with open(sys.argv[2], 'rb') as f:
        cmds = split_commands(f.read())
    sock = socket.create_connection(('127.0.0.1', port))
    reader = Reader(sock)
    out = open(sys.argv[3], 'wb')
    i = 0
    while i < len(cmds):
        batch = cmds[i:i + 256]
        i += len(batch)
        sock.sendall(b''.join(batch))
        for _ in batch:
            out.write(reader.raw_reply())
    out.close()
    sock.close()
    print('exchanged %d commands' % len(cmds))


main()
PY
)

mkdir -p bin
"$ODIN" build test/listtype -o:speed -out:bin/listtype-test
if [ "$SERVER" = "bin/eski" ]; then
	./build.sh >/dev/null
fi

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --rm --name "$NAME" --network host "$IMAGE" \
	redis-server --port "$REF_PORT" --bind 127.0.0.1 --save "" --appendonly no --rdbcompression no --enable-debug-command yes >/dev/null
ready=0
for _ in $(seq 1 100); do
	if docker exec "$NAME" redis-cli -p "$REF_PORT" ping 2>/dev/null | grep -q PONG; then
		ready=1
		break
	fi
	sleep 0.1
done
if [ "$ready" != "1" ]; then
	echo "reference Redis did not start on port $REF_PORT" >&2
	exit 1
fi
echo "reference: $(docker exec "$NAME" redis-cli -p "$REF_PORT" info server | grep -m1 '^redis_version' | tr -d '\r') on port $REF_PORT"

if [ "$SERVER" != "none" ]; then
	"$SERVER" --port "$PORT" --enable-debug-command yes --bind 127.0.0.1 >"$WORK/server.log" 2>&1 &
	SERVER_PID=$!
	up=0
	for _ in $(seq 1 100); do
		if docker exec "$NAME" redis-cli -p "$PORT" ping 2>/dev/null | grep -q PONG; then
			up=1
			break
		fi
		sleep 0.1
	done
	if [ "$up" != "1" ]; then
		echo "$SERVER did not answer PING on port $PORT" >&2
		cat "$WORK/server.log" >&2
		exit 1
	fi
	if ! docker exec "$NAME" redis-cli -p "$PORT" config set rdbcompression no 2>/dev/null | grep -q OK; then
		echo "$SERVER did not accept CONFIG SET rdbcompression no, its DUMP replies will not match" >&2
	fi
	echo "server: $SERVER on port $PORT"
fi

./bin/listtype-test unit
./bin/listtype-test gen "$WORK"
python3 -I -c "$EXCHANGE" "$REF_PORT" "$WORK/script.resp" "$WORK/redis.out"
if [ -n "$SERVER_PID" ]; then
	python3 -I -c "$EXCHANGE" "$PORT" "$WORK/script.resp" "$WORK/eski.out"
	if ! kill -0 "$SERVER_PID" 2>/dev/null; then
		echo "$SERVER exited during the exchange" >&2
		cat "$WORK/server.log" >&2
		exit 1
	fi
fi
status=0
./bin/listtype-test compare "$WORK" || status=1
if [ -n "$SERVER_PID" ]; then
	./bin/listtype-test compare-server "$WORK" || status=1
fi
if [ "$status" != "0" ]; then
	exit 1
fi
echo "listtype compare passed"
