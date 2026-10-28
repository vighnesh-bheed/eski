#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

PORT="${ESKI_PUBSUB_PORT:-6491}"
REF_PORT="${ESKI_PUBSUB_REF_PORT:-6492}"
SERVER="${ESKI_PUBSUB_SERVER:-bin/eski}"
WITH_REF="${ESKI_PUBSUB_REF:-1}"
LONG="${ESKI_PUBSUB_LONG:-0}"
IMAGE="docker.io/library/redis:7"
NAME="eski-pubsub-obuf-$REF_PORT"
SERVER_PID=""

cleanup() {
	if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	if [ "$WITH_REF" = "1" ]; then
		docker rm -f "$NAME" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

OBUF=$(cat <<'PY'
import socket
import sys
import threading
import time

MSG = 65536
targets = [(name, int(port)) for name, port in (a.split("=") for a in sys.argv[2].split(","))]
long_mode = sys.argv[1] == "1"


def encode(*args):
    out = [b"*%d\r\n" % len(args)]
    for a in args:
        a = a if isinstance(a, bytes) else str(a).encode()
        out.append(b"$%d\r\n%s\r\n" % (len(a), a))
    return b"".join(out)


class Client:
    def __init__(self, port, rcvbuf=0):
        self.s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        if rcvbuf:
            self.s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        self.s.connect(("127.0.0.1", port))
        self.buf = b""

    def line(self):
        while b"\r\n" not in self.buf:
            data = self.s.recv(65536)
            if not data:
                raise EOFError
            self.buf += data
        head, self.buf = self.buf.split(b"\r\n", 1)
        return head

    def reply(self):
        head = self.line()
        if head[:1] == b"$":
            n = int(head[1:])
            while len(self.buf) < n + 2:
                self.buf += self.s.recv(65536)
            body, self.buf = self.buf[:n], self.buf[n + 2:]
            return body
        if head[:1] == b"*":
            return [self.reply() for _ in range(int(head[1:]))]
        return head

    def call(self, *args):
        self.s.sendall(encode(*args))
        return self.reply()


def numsub(ctl, channel):
    r = ctl.call("PUBSUB", "NUMSUB", channel)
    return int(r[1][1:])


def disconnections(ctl):
    for line in ctl.call("INFO", "stats").decode().split("\r\n"):
        if line.startswith("client_output_buffer_limit_disconnections:"):
            return int(line.split(":")[1])
    return -1


def hard_case(port, out):
    ctl = Client(port)
    ctl.call("CONFIG", "SET", "client-output-buffer-limit", "pubsub 32mb 8mb 60")
    before = disconnections(ctl)
    stalled = Client(port, rcvbuf=4096)
    stalled.call("SUBSCRIBE", "hard")
    reader = Client(port)
    reader.call("SUBSCRIBE", "hard")
    got = [0]
    stop = threading.Event()

    def drain():
        reader.s.settimeout(0.2)
        total = len(reader.buf)
        while not stop.is_set():
            try:
                data = reader.s.recv(1 << 20)
            except socket.timeout:
                continue
            if not data:
                break
            total += len(data)
        got[0] = total

    t = threading.Thread(target=drain)
    t.start()
    pub = Client(port)
    payload = b"h" * MSG
    batch = encode("PUBLISH", "hard", payload) * 16
    published = 0
    dropped_at = None
    started = time.time()
    while published < 256 * MSG * 16 and dropped_at is None:
        pub.s.sendall(batch)
        for _ in range(16):
            n = int(pub.reply()[1:])
            published += 1
            if n < 2 and dropped_at is None:
                dropped_at = published
    elapsed = time.time() - started
    time.sleep(0.5)
    stop.set()
    t.join()
    frame = len(encode("message", "hard", payload))
    out["hard"] = (dropped_at, (dropped_at or 0) * frame / 1048576.0, elapsed, numsub(ctl, "hard"), got[0] >= published * frame, disconnections(ctl) - before)
    ctl.call("CONFIG", "SET", "client-output-buffer-limit", "pubsub 32mb 8mb 60")


def soft_case(port, out, key, limit, volume, seconds):
    ctl = Client(port)
    ctl.call("CONFIG", "SET", "client-output-buffer-limit", limit)
    stalled = Client(port, rcvbuf=4096)
    stalled.call("SUBSCRIBE", key)
    pub = Client(port)
    payload = b"s" * MSG
    started = time.time()
    for _ in range(volume // (MSG * 16)):
        pub.s.sendall(encode("PUBLISH", key, payload) * 16)
        for _ in range(16):
            pub.reply()
    published = time.time()
    gone = None
    while time.time() - published < seconds + 5:
        if numsub(ctl, key) == 0:
            gone = time.time()
            break
        time.sleep(0.02)
    out[key] = (published - started, None if gone is None else gone - published)
    ctl.call("CONFIG", "SET", "client-output-buffer-limit", "pubsub 32mb 8mb 60")


def run(name, port, results):
    out = {}
    hard_case(port, out)
    soft_case(port, out, "soft", "pubsub 0 1mb 2", 8 * 1048576, 2)
    if long_mode:
        soft_case(port, out, "soft-default", "pubsub 32mb 8mb 60", 16 * 1048576, 60)
    results[name] = out


results = {}
threads = [threading.Thread(target=run, args=(name, port, results)) for name, port in targets]
for t in threads:
    t.start()
for t in threads:
    t.join()
ok = True
for name, _ in targets:
    r = results.get(name)
    if r is None:
        print("%s: did not finish" % name)
        ok = False
        continue
    dropped, mb, elapsed, left, reader_ok, counted = r["hard"]
    print("%s hard limit 32mb: stalled subscriber dropped after %s messages (%.1f MB published), %.2f s, numsub after %d, reading subscriber got everything %s, disconnections counted %d" % (
        name, dropped, mb, elapsed, left, reader_ok, counted))
    if dropped is None or left != 1 or not reader_ok or counted != 1:
        ok = False
    for key, label, window in (("soft", "soft limit 1mb for 2 s", 2), ("soft-default", "default soft limit 8mb for 60 s", 60)):
        if key not in r:
            continue
        pub_time, gone = r[key]
        print("%s %s: published in %.2f s, disconnected %s after the last publish" % (name, label, pub_time, "never" if gone is None else "%.2f s" % gone))
        if gone is None or gone < window - 0.2 or gone > window + 1.5:
            ok = False
if len(targets) == 2 and all(n in results for n, _ in targets):
    a, b = (results[n] for n, _ in targets)
    for key in ("soft", "soft-default"):
        if key in a and key in b and a[key][1] is not None and b[key][1] is not None:
            diff = abs(a[key][1] - b[key][1])
            print("%s disconnect time difference between servers: %.2f s" % (key, diff))
            if diff > 1.0:
                ok = False
sys.exit(0 if ok else 1)
PY
)

wait_ping() {
	local port="$1"
	for _ in $(seq 1 100); do
		if (exec 3<>"/dev/tcp/127.0.0.1/$port" && printf 'PING\r\n' >&3 && IFS= read -r -t 1 reply <&3 && [[ "$reply" == "+PONG"* ]]) 2>/dev/null; then
			return 0
		fi
		sleep 0.1
	done
	echo "nothing answered PING on port $port" >&2
	return 1
}

if [ ! -x "$SERVER" ]; then
	./build.sh >/dev/null
fi
"$SERVER" --port "$PORT" --enable-debug-command yes --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER_PID=$!
wait_ping "$PORT"
targets="eski=$PORT"
if [ "$WITH_REF" = "1" ]; then
	docker run -d --rm --name "$NAME" --network=host "$IMAGE" redis-server --port "$REF_PORT" --bind 127.0.0.1 --save "" >/dev/null
	wait_ping "$REF_PORT"
	targets="$targets,redis=$REF_PORT"
fi
python3 -I -c "$OBUF" "$LONG" "$targets"
