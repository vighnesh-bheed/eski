#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

PORT="${ESKI_LISTPACK_REF_PORT:-6491}"
IMAGE="docker.io/library/redis:7"
NAME="eski-listpack-capture-$PORT"

cleanup() {
	docker stop -t 2 "$NAME" >/dev/null 2>&1 || true
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	for _ in $(seq 1 100); do
		docker container inspect "$NAME" >/dev/null 2>&1 || break
		sleep 0.1
	done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

CAPTURE=$(cat <<'PY'
import binascii
import socket
import sys


class Conn:
    def __init__(self, port):
        self.sock = socket.create_connection(('127.0.0.1', port))
        self.buf = bytearray()

    def send(self, *args):
        out = bytearray(b'*%d\r\n' % len(args))
        for a in args:
            if isinstance(a, str):
                a = a.encode()
            out += b'$%d\r\n' % len(a) + a + b'\r\n'
        self.sock.sendall(out)

    def fill(self):
        chunk = self.sock.recv(1 << 20)
        if not chunk:
            raise SystemExit('connection closed')
        self.buf += chunk

    def line(self):
        while True:
            j = self.buf.find(b'\r\n')
            if j >= 0:
                out = bytes(self.buf[:j])
                del self.buf[:j + 2]
                return out
            self.fill()

    def reply(self):
        head = self.line()
        kind = head[:1]
        if kind == b'$':
            n = int(head[1:])
            if n < 0:
                return None
            while len(self.buf) < n + 2:
                self.fill()
            out = bytes(self.buf[:n])
            del self.buf[:n + 2]
            return out
        if kind == b'*':
            return [self.reply() for _ in range(int(head[1:]))]
        if kind == b'-':
            raise SystemExit('error reply: %r' % head)
        return head[1:]

    def call(self, *args):
        self.send(*args)
        return self.reply()


def token(t):
    if t == '@e':
        return b''
    if t.startswith('@r:'):
        _, ch, n = t.split(':')
        return ch.encode() * int(n)
    if t.startswith('@h:'):
        return binascii.unhexlify(t[3:])
    return t.encode()


def rdb_len(p, i):
    b0 = p[i]
    t = (b0 & 0xC0) >> 6
    if t == 0:
        return b0 & 0x3F, i + 1
    if t == 1:
        return ((b0 & 0x3F) << 8) | p[i + 1], i + 2
    if b0 == 0x80:
        return int.from_bytes(p[i + 1:i + 5], 'big'), i + 5
    if b0 == 0x81:
        return int.from_bytes(p[i + 1:i + 9], 'big'), i + 9
    raise SystemExit('unsupported rdb length byte %02x' % b0)


def listpack_from_dump(payload):
    if payload[0] != 16:
        return payload[0], None
    n, start = rdb_len(payload, 1)
    lp = payload[start:start + n]
    trailer = payload[start + n:]
    if len(trailer) != 10:
        raise SystemExit('unexpected dump trailer length %d' % len(trailer))
    if int.from_bytes(lp[0:4], 'little') != n:
        raise SystemExit('listpack total bytes header mismatch')
    return 16, lp


def main():
    port = int(sys.argv[1])
    cases_path = sys.argv[2]
    out_path = sys.argv[3]
    c = Conn(port)
    version = None
    for line in c.call('INFO', 'server').decode().splitlines():
        if line.startswith('redis_version:'):
            version = line.split(':', 1)[1].strip()
    out = ['redis_version|%s' % version]
    for raw in open(cases_path):
        raw = raw.rstrip('\n')
        if not raw:
            continue
        name, entries, value, ops = raw.split('|', 3)
        c.call('FLUSHALL')
        c.call('CONFIG', 'SET', 'hash-max-listpack-entries', entries)
        c.call('CONFIG', 'SET', 'hash-max-listpack-value', value)
        for op in ops.split(';'):
            parts = op.split(' ')
            if parts[0] == 'set':
                c.call('HSET', 'k', token(parts[1]), token(parts[2]))
            elif parts[0] == 'del':
                c.call('HDEL', 'k', token(parts[1]))
            else:
                raise SystemExit('bad op %r' % op)
        enc = c.call('OBJECT', 'ENCODING', 'k').decode()
        typ, lp = listpack_from_dump(c.call('DUMP', 'k'))
        if lp is None or enc != 'listpack':
            raise SystemExit('case %s is not listpack encoded (%s, type %d)' % (name, enc, typ))
        if len(lp) > 65536:
            out.append('%s|crc32:%08x:%d' % (name, binascii.crc32(lp) & 0xffffffff, len(lp)))
        else:
            out.append('%s|%s' % (name, binascii.hexlify(lp).decode()))
    with open(out_path, 'w') as f:
        f.write('\n'.join(out) + '\n')
    print('captured %d cases from redis %s' % (len(out) - 1, version))


main()
PY
)

cleanup
docker run -d --rm --name "$NAME" --network host "$IMAGE" \
	redis-server --port "$PORT" --bind 127.0.0.1 --save "" --appendonly no --rdbcompression no >/dev/null
for _ in $(seq 1 100); do
	if docker exec "$NAME" redis-cli -p "$PORT" ping 2>/dev/null | grep -q PONG; then
		break
	fi
	sleep 0.1
done
python3 -I -c "$CAPTURE" "$PORT" cases.txt redis_table.txt
