#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

PORT="${ESKI_LPEX_REF_PORT:-6491}"
IMAGE="docker.io/library/redis:7"
NAME="eski-lpex-capture-$PORT"

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

    def call(self, *args):
        out = bytearray(b'*%d\r\n' % len(args))
        for a in args:
            if isinstance(a, str):
                a = a.encode()
            out += b'$%d\r\n' % len(a) + a + b'\r\n'
        self.sock.sendall(out)
        return self.reply()

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


def token(t):
    if t == '@e':
        return b''
    if t.startswith('@r:'):
        _, ch, n = t.split(':')
        return ch.encode() * int(n)
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
    raise SystemExit('unsupported rdb length byte %02x' % b0)


def split_dump(payload):
    typ = payload[0]
    if typ == 25:
        header = int.from_bytes(payload[1:9], 'little')
        n, start = rdb_len(payload, 9)
    elif typ == 16:
        header = 0
        n, start = rdb_len(payload, 1)
    else:
        raise SystemExit('unexpected rdb type %d' % typ)
    lp = payload[start:start + n]
    if len(payload) - (start + n) != 10:
        raise SystemExit('unexpected dump trailer')
    if int.from_bytes(lp[0:4], 'little') != n:
        raise SystemExit('listpack total bytes header mismatch')
    return typ, header, lp


def main():
    c = Conn(int(sys.argv[1]))
    version = None
    for line in c.call('INFO', 'server').decode().splitlines():
        if line.startswith('redis_version:'):
            version = line.split(':', 1)[1].strip()
    out = ['redis_version|%s' % version]
    for raw in open(sys.argv[2]):
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
            elif parts[0] == 'incr':
                c.call('HINCRBY', 'k', token(parts[1]), parts[2])
            elif parts[0] == 'persist':
                fields = [token(f) for f in parts[1].split(',')]
                c.call('HPERSIST', 'k', 'FIELDS', str(len(fields)), *fields)
            elif parts[0] == 'pxat':
                fields = [token(f) for f in parts[3].split(',')]
                args = ['HPEXPIREAT', 'k', parts[1]]
                if parts[2] != '-':
                    args.append(parts[2])
                c.call(*args, 'FIELDS', str(len(fields)), *fields)
            else:
                raise SystemExit('bad op %r' % op)
        typ, header, lp = split_dump(c.call('DUMP', 'k'))
        enc = c.call('OBJECT', 'ENCODING', 'k').decode()
        out.append('%s|%s|%d|%d|%s' % (name, enc, typ, header, binascii.hexlify(lp).decode()))
    c.call('CONFIG', 'SET', 'hash-max-listpack-entries', '128')
    c.call('CONFIG', 'SET', 'hash-max-listpack-value', '64')
    with open(sys.argv[3], 'w') as f:
        f.write('\n'.join(out) + '\n')
    print('captured %d listpackex cases from redis %s' % (len(out) - 1, version))


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
python3 -I -c "$CAPTURE" "$PORT" lpex_cases.txt lpex_table.txt
