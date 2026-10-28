#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

PORT="${ESKI_PUBSUB_PORT:-6491}"
REF_PORT="${ESKI_PUBSUB_REF_PORT:-6492}"
SERVER="${ESKI_PUBSUB_SERVER:-bin/eski}"
WITH_REF="${ESKI_PUBSUB_REF:-0}"
SUBSCRIBERS="${ESKI_PUBSUB_SUBSCRIBERS:-50}"
PUBLISHERS="${ESKI_PUBSUB_PUBLISHERS:-5}"
MESSAGES="${ESKI_PUBSUB_MESSAGES:-1000}"
SEED="${ESKI_PUBSUB_SEED:-43}"
IMAGE="docker.io/library/redis:7"
NAME="eski-pubsub-stress-$REF_PORT"
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

STRESS=$(cat <<'PY'
import fnmatch
import random
import selectors
import socket
import sys
import threading
import time

port = int(sys.argv[1])
n_subs = int(sys.argv[2])
n_pubs = int(sys.argv[3])
n_msgs = int(sys.argv[4])
rng = random.Random(int(sys.argv[5]))

CHANNELS = ["c%d" % i for i in range(10)] + ["news.%d" % i for i in range(4)]
PATTERNS = ["c1*", "c?", "*7", "c[2-4]", "news.*", "n*", "*.3", "c[6-9]"]


def connect():
    s = socket.create_connection(("127.0.0.1", port))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def encode(*args):
    out = [b"*%d\r\n" % len(args)]
    for a in args:
        a = a if isinstance(a, bytes) else str(a).encode()
        out.append(b"$%d\r\n%s\r\n" % (len(a), a))
    return b"".join(out)


class Parser:
    def __init__(self):
        self.buf = b""
        self.pos = 0

    def feed(self, data):
        self.buf = self.buf[self.pos:] + data
        self.pos = 0

    def line(self, p):
        nl = self.buf.find(b"\r\n", p)
        if nl < 0:
            return None, p
        return self.buf[p:nl], nl + 2

    def value(self, p):
        head, q = self.line(p)
        if head is None:
            return None, p
        t = head[:1]
        if t in (b"*", b">", b"%", b"~"):
            n = int(head[1:])
            if t == b"%":
                n *= 2
            items = []
            for _ in range(max(n, 0)):
                v, q2 = self.value(q)
                if q2 == q and v is None:
                    return None, p
                items.append(v)
                q = q2
            return (t.decode(), items), q
        if t == b"$":
            n = int(head[1:])
            if n < 0:
                return ("null", None), q
            if len(self.buf) < q + n + 2:
                return None, p
            return ("bulk", self.buf[q:q + n]), q + n + 2
        if t in (b":", b"+", b"-", b"_", b"#", b","):
            return (t.decode(), head[1:]), q
        raise SystemExit("unexpected reply type %r" % head[:20])

    def frames(self):
        out = []
        while True:
            v, q = self.value(self.pos)
            if v is None:
                return out
            self.pos = q
            out.append(v)


def read_frames(s, parser, want, timeout=10):
    got = []
    end = time.time() + timeout
    s.settimeout(0.5)
    while len(got) < want and time.time() < end:
        try:
            data = s.recv(65536)
        except socket.timeout:
            continue
        if not data:
            raise SystemExit("connection closed while waiting for replies")
        parser.feed(data)
        got.extend(parser.frames())
    if len(got) < want:
        raise SystemExit("timed out waiting for %d replies, got %d" % (want, len(got)))
    return got


def setup_subscriber(i):
    proto = 3 if i % 3 == 0 else 2
    channels = sorted(rng.sample(CHANNELS, rng.randint(0, 4)))
    patterns = sorted(rng.sample(PATTERNS, rng.randint(0 if channels else 1, 3)))
    s = connect()
    parser = Parser()
    want = 0
    if proto == 3:
        s.sendall(encode("HELLO", "3"))
        want += 1
    if channels:
        s.sendall(encode("SUBSCRIBE", *channels))
        want += len(channels)
    if patterns:
        s.sendall(encode("PSUBSCRIBE", *patterns))
        want += len(patterns)
    read_frames(s, parser, want)
    return {"id": i, "sock": s, "parser": parser, "proto": proto, "channels": set(channels), "patterns": patterns, "got": []}


subs = [setup_subscriber(i) for i in range(n_subs)]
observer = {"id": "observer", "sock": connect(), "parser": Parser(), "proto": 2, "channels": set(), "patterns": ["*"], "got": []}
observer["sock"].sendall(encode("PSUBSCRIBE", "*"))
read_frames(observer["sock"], observer["parser"], 1)
everyone = subs + [observer]


def matches(sub, channel):
    n = 1 if channel in sub["channels"] else 0
    return n + sum(1 for p in sub["patterns"] if fnmatch.fnmatchcase(channel, p))


plans = []
for p in range(n_pubs):
    count = n_msgs // n_pubs + (1 if p < n_msgs % n_pubs else 0)
    plans.append([rng.choice(CHANNELS) for _ in range(count)])
expected_receivers = {c: sum(matches(s, c) for s in everyone) for c in CHANNELS}
errors = []
lock = threading.Lock()


def publisher(p, plan, seed):
    local = random.Random(seed)
    s = connect()
    parser = Parser()
    seq = 0
    while seq < len(plan):
        batch = min(local.randint(1, 24), len(plan) - seq)
        payload = b"".join(encode("PUBLISH", plan[k], "p%d:%d:%s" % (p, k, plan[k])) for k in range(seq, seq + batch))
        s.sendall(payload)
        replies = read_frames(s, parser, batch)
        for k, r in zip(range(seq, seq + batch), replies):
            want = expected_receivers[plan[k]]
            if r != (":", str(want).encode()):
                with lock:
                    errors.append("publisher %d message %d to %s returned %r, expected %d" % (p, k, plan[k], r, want))
        seq += batch
        if local.random() < 0.3:
            time.sleep(local.random() * 0.002)
    s.close()


total_expected = {id(s): sum(matches(s, c) for plan in plans for c in plan) for s in everyone}
sel = selectors.DefaultSelector()
for s in everyone:
    s["sock"].setblocking(False)
    sel.register(s["sock"], selectors.EVENT_READ, s)

started = time.time()
threads = [threading.Thread(target=publisher, args=(p, plans[p], rng.random())) for p in range(n_pubs)]
for t in threads:
    t.start()
deadline = time.time() + 60
remaining = sum(total_expected.values())
while remaining > 0 and time.time() < deadline:
    for key, _ in sel.select(timeout=0.5):
        sub = key.data
        try:
            data = sub["sock"].recv(1 << 20)
        except BlockingIOError:
            continue
        if not data:
            errors.append("subscriber %s was disconnected" % sub["id"])
            sel.unregister(sub["sock"])
            continue
        sub["parser"].feed(data)
        for f in sub["parser"].frames():
            sub["got"].append(f)
            remaining -= 1
for t in threads:
    t.join()
elapsed = time.time() - started
time.sleep(0.2)
for sub in everyone:
    try:
        data = sub["sock"].recv(1 << 20)
        if data:
            sub["parser"].feed(data)
            sub["got"].extend(sub["parser"].frames())
    except BlockingIOError:
        pass


def decode(sub, frame):
    kind, items = frame
    want_kind = ">" if sub["proto"] == 3 else "*"
    if kind != want_kind:
        return None, "frame type %s, expected %s" % (kind, want_kind)
    words = [v for _, v in items]
    if words[0] == b"message" and len(words) == 3:
        return ("message", None, words[1].decode(), words[2].decode()), None
    if words[0] == b"pmessage" and len(words) == 4:
        return ("pmessage", words[1].decode(), words[2].decode(), words[3].decode()), None
    return None, "unexpected frame %r" % (words,)


order = []
for f in observer["got"]:
    m, err = decode(observer, f)
    if err:
        errors.append("observer: " + err)
        continue
    pub, seq, chan = m[3].split(":")
    order.append((int(pub[1:]), int(seq)))
position = {key: i for i, key in enumerate(order)}
if len(order) != n_msgs or len(position) != n_msgs:
    errors.append("observer saw %d messages (%d distinct), expected %d" % (len(order), len(position), n_msgs))
last_seq = {}
for pub, seq in order:
    if seq != last_seq.get(pub, -1) + 1:
        errors.append("observer saw publisher %d message %d after %d" % (pub, seq, last_seq.get(pub, -1)))
    last_seq[pub] = seq

deliveries = 0
for sub in subs:
    expected = []
    for pub, seq in order:
        chan = plans[pub][seq]
        payload = "p%d:%d:%s" % (pub, seq, chan)
        if chan in sub["channels"]:
            expected.append(("message", None, chan, payload))
        group = sorted(("pmessage", p, chan, payload) for p in sub["patterns"] if fnmatch.fnmatchcase(chan, p))
        expected.extend(group)
    got = []
    for f in sub["got"]:
        m, err = decode(sub, f)
        if err:
            errors.append("subscriber %d: %s" % (sub["id"], err))
            break
        got.append(m)
    deliveries += len(got)
    normalized = []
    i = 0
    while i < len(got):
        if got[i][0] == "pmessage":
            j = i
            while j < len(got) and got[j][0] == "pmessage" and got[j][3] == got[i][3]:
                j += 1
            normalized.extend(sorted(got[i:j]))
            i = j
        else:
            normalized.append(got[i])
            i += 1
    if normalized != expected:
        k = next((x for x in range(min(len(normalized), len(expected))) if normalized[x] != expected[x]), min(len(normalized), len(expected)))
        errors.append("subscriber %d (resp%d, channels %s, patterns %s): %d deliveries, expected %d, first difference at %d: got %r expected %r" % (
            sub["id"], sub["proto"], sorted(sub["channels"]), sub["patterns"], len(got), len(expected), k,
            normalized[k] if k < len(normalized) else None, expected[k] if k < len(expected) else None))

for s in everyone:
    s["sock"].close()
resp3 = sum(1 for s in subs if s["proto"] == 3)
print("subscribers %d (%d resp3) plus an observer, publishers %d, messages %d, deliveries checked %d, observer deliveries %d, %.2f s" % (
    n_subs, resp3, n_pubs, n_msgs, deliveries, len(observer["got"]), elapsed))
if errors:
    for e in errors[:20]:
        print("FAIL: " + e)
    print("%d errors" % len(errors))
    sys.exit(1)
print("every subscriber received every matching message once per matching subscription, in the observer's global order, with per-publisher sequence numbers in publish order")
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
status=0
echo "eski on $PORT:"
python3 -I -c "$STRESS" "$PORT" "$SUBSCRIBERS" "$PUBLISHERS" "$MESSAGES" "$SEED" || status=1
if [ "$WITH_REF" = "1" ]; then
	docker run -d --rm --name "$NAME" --network=host "$IMAGE" redis-server --port "$REF_PORT" --bind 127.0.0.1 --save "" >/dev/null
	wait_ping "$REF_PORT"
	echo "redis on $REF_PORT:"
	python3 -I -c "$STRESS" "$REF_PORT" "$SUBSCRIBERS" "$PUBLISHERS" "$MESSAGES" "$SEED" || status=1
fi
exit "$status"
