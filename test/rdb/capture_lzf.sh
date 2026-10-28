#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

PORT="${ESKI_RDB_REF_PORT:-6613}"
IMAGE="${ESKI_REDIS_IMAGE:-docker.io/library/redis:7}"
NAME="eski-rdb-lzf-capture-$PORT"
OUT="test/rdb/lzf_vectors.txt"

cleanup() {
	docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --rm -d --name "$NAME" --network=host "$IMAGE" redis-server --port "$PORT" --save "" >/dev/null
for _ in $(seq 1 50); do
	if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
		break
	fi
	sleep 0.1
done

python3 -I -B - "$PORT" "$OUT" test/rdb <<'PY'
import socket
import sys

port, out, gendir = int(sys.argv[1]), sys.argv[2], sys.argv[3]
sys.path.insert(0, gendir)
import gen


def cmd(sock, f, *args):
    parts = [b"*%d\r\n" % len(args)]
    for a in args:
        if isinstance(a, str):
            a = a.encode()
        parts.append(b"$%d\r\n%s\r\n" % (len(a), a))
    sock.sendall(b"".join(parts))
    line = f.readline()
    if line[:1] == b"$":
        n = int(line[1:])
        data = f.read(n + 2)
        return data[:-2]
    return line.rstrip(b"\r\n")


s = socket.create_connection(("127.0.0.1", port))
f = s.makefile("rb")
rows = []
for pattern, seed, length in gen.SPECS:
    value = gen.gen(pattern, seed, length)
    cmd(s, f, "SET", "k", value)
    payload = cmd(s, f, "DUMP", "k")
    assert payload[0] == 0
    enc = payload[1:-10]
    assert payload[-10:-8] == b"\x0c\x00"
    crc = int.from_bytes(payload[-8:], "little")
    kind = "lzf" if enc[0] == 0xC3 else "raw"
    rows.append("%s %d %d %d %s %016x" % (pattern, seed, length, len(enc), kind, crc))
with open(out, "w") as fh:
    fh.write("\n".join(rows) + "\n")
print("captured %d vectors into %s" % (len(rows), out))
PY
