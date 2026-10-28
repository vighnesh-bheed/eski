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
IMAGE="docker.io/library/redis:7"
NAME="eski-bitmap-compare-$PORT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eski-bitmap-compare.XXXXXX")"
ESKI_PID=""

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
	if [ "${ESKI_BITMAP_KEEP:-0}" = "1" ]; then
		echo "kept work directory $WORK" >&2
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

EXCHANGE=$(cat <<'PY'
import socket
import sys
import threading


def count_commands(data):
    i = 0
    n = 0
    while i < len(data):
        if data[i:i + 1] != b'*':
            raise SystemExit('malformed script at byte %d' % i)
        j = data.index(b'\r\n', i)
        argc = int(data[i + 1:j])
        i = j + 2
        for _ in range(argc):
            j = data.index(b'\r\n', i)
            i = j + 2 + int(data[i + 1:j]) + 2
        n += 1
    return n


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

    def line(self):
        while True:
            j = self.buf.find(b'\r\n', self.pos)
            if j >= 0:
                out = bytes(self.buf[self.pos:j])
                self.pos = j + 2
                return out
            self.fill()

    def skip(self, n):
        while len(self.buf) - self.pos < n:
            self.fill()
        self.pos += n

    def reply(self):
        head = self.line()
        kind = head[:1]
        if kind == b'$':
            n = int(head[1:])
            if n >= 0:
                self.skip(n + 2)
        elif kind == b'*':
            for _ in range(max(int(head[1:]), 0)):
                self.reply()
        elif kind not in (b'+', b'-', b':'):
            raise SystemExit('unexpected reply %r' % head[:40])


def main():
    port = int(sys.argv[1])
    with open(sys.argv[2], 'rb') as f:
        data = f.read()
    total = count_commands(data)
    sock = socket.create_connection(('127.0.0.1', port))
    sender = threading.Thread(target=sock.sendall, args=(data,))
    sender.start()
    reader = Reader(sock)
    for _ in range(total):
        reader.reply()
    sender.join()
    sock.close()
    with open(sys.argv[3], 'wb') as f:
        f.write(bytes(reader.buf[:reader.pos]))
    print('%-8s %-18s %7d replies %10d bytes' % (sys.argv[5], sys.argv[4], total, reader.pos))


main()
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

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --rm --name "$NAME" --network host "$IMAGE" \
	redis-server --port "$PORT" --bind 127.0.0.1 --save "" --appendonly no >/dev/null

ready=0
for _ in $(seq 1 100); do
	if docker exec "$NAME" redis-cli -p "$PORT" ping 2>/dev/null | grep -q PONG; then
		ready=1
		break
	fi
	sleep 0.1
done
if [ "$ready" -ne 1 ]; then
	echo "reference Redis did not start on port $PORT" >&2
	exit 1
fi
echo "reference: $(docker exec "$NAME" redis-cli -p "$PORT" info server | grep -m1 '^redis_version' | tr -d '\r') on port $PORT"

./bin/bitmap-test gen "$WORK"

while IFS= read -r name; do
	[ -n "$name" ] || continue
	python3 -I -c "$EXCHANGE" "$PORT" "$WORK/$name.script" "$WORK/$name.redis" "$name" redis
	if [ "$SERVER" = "1" ]; then
		python3 -I -c "$EXCHANGE" "$PORT" "$WORK/$name.srv.script" "$WORK/$name.srv.redis" "$name.srv" redis
	fi
done < "$WORK/cases.txt"

./bin/bitmap-test compare "$WORK"

if [ "$SERVER" = "1" ]; then
	./bin/eski --port "$ESKI_PORT" --enable-debug-command yes --bind 127.0.0.1 >"$WORK/eski.log" 2>&1 &
	ESKI_PID=$!
	ready=0
	for _ in $(seq 1 100); do
		if grep -q "listening on" "$WORK/eski.log" 2>/dev/null; then
			ready=1
			break
		fi
		if ! kill -0 "$ESKI_PID" 2>/dev/null; then
			break
		fi
		sleep 0.05
	done
	if [ "$ready" -ne 1 ]; then
		echo "eski did not start on port $ESKI_PORT" >&2
		cat "$WORK/eski.log" >&2
		exit 1
	fi
	echo "eski: bin/eski on port $ESKI_PORT"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		python3 -I -c "$EXCHANGE" "$ESKI_PORT" "$WORK/$name.srv.script" "$WORK/$name.srv.eski" "$name.srv" eski
	done < "$WORK/cases.txt"
	if ! kill -0 "$ESKI_PID" 2>/dev/null; then
		echo "eski exited during the run" >&2
		cat "$WORK/eski.log" >&2
		exit 1
	fi
	kill "$ESKI_PID" 2>/dev/null || true
	wait "$ESKI_PID" 2>/dev/null || true
	ESKI_PID=""
	./bin/bitmap-test compare-server "$WORK"
fi
