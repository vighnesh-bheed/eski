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

PORT="${ESKI_HLL_PORT:-6431}"
REF_PORT="${ESKI_HLL_REF_PORT:-6432}"
SERVER="${ESKI_HLL_SERVER:-bin/eski}"
IMAGE="${ESKI_HLL_REF_IMAGE:-docker.io/library/redis:7}"
NAME="eski-hll-compare-$REF_PORT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eski-hll-compare.XXXXXX")"
SERVER_PID=""

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
	if [ "${ESKI_HLL_KEEP:-0}" = "1" ]; then
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


main()
PY
)

mkdir -p bin
"$ODIN" build test/hll -o:speed -out:bin/hll-test
if [ "$SERVER" = "bin/eski" ]; then
	./build.sh >/dev/null
fi

wait_ping() {
	for _ in $(seq 1 100); do
		if docker exec "$NAME" redis-cli -p "$1" ping 2>/dev/null | grep -q PONG; then
			return 0
		fi
		sleep 0.1
	done
	return 1
}

load_into() {
	local port="$1" file="$2" label="$3" out
	out="$(docker exec -i "$NAME" redis-cli -p "$port" --pipe < "$file" 2>&1)"
	if ! printf '%s\n' "$out" | grep -q 'errors: 0,'; then
		echo "loading $file into $label failed: $out" >&2
		exit 1
	fi
}

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --rm --name "$NAME" --network host "$IMAGE" \
	redis-server --port "$REF_PORT" --bind 127.0.0.1 --save "" --appendonly no >/dev/null
if ! wait_ping "$REF_PORT"; then
	echo "reference Redis did not start on port $REF_PORT" >&2
	exit 1
fi
echo "reference: $(docker exec "$NAME" redis-cli -p "$REF_PORT" info server | grep -m1 '^redis_version' | tr -d '\r') on port $REF_PORT"

if [ "$SERVER" != "none" ]; then
	"$SERVER" --port "$PORT" --enable-debug-command yes --bind 127.0.0.1 >"$WORK/server.log" 2>&1 &
	SERVER_PID=$!
	if ! wait_ping "$PORT"; then
		echo "$SERVER did not answer PING on port $PORT" >&2
		cat "$WORK/server.log" >&2
		exit 1
	fi
	echo "server: $SERVER on port $PORT"
fi

./bin/hll-test gen "$WORK"

while IFS= read -r name; do
	[ -n "$name" ] || continue
	if [ -s "$WORK/$name.load" ]; then
		load_into "$REF_PORT" "$WORK/$name.load" "Redis"
		if [ -n "$SERVER_PID" ]; then
			load_into "$PORT" "$WORK/$name.load" "$SERVER"
		fi
	fi
	python3 -I -c "$EXCHANGE" "$REF_PORT" "$WORK/$name.script" "$WORK/$name.redis"
	if [ -n "$SERVER_PID" ]; then
		python3 -I -c "$EXCHANGE" "$PORT" "$WORK/$name.script" "$WORK/$name.eski"
	fi
done < "$WORK/cases.txt"

if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
	echo "$SERVER exited during the comparison" >&2
	cat "$WORK/server.log" >&2
	exit 1
fi

./bin/hll-test compare "$WORK"
echo "hll compare passed"
