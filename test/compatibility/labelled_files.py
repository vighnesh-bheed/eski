import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/rdb'))
sys.path.insert(0, str(ROOT / 'test/threading'))
import rdbcmp
from support import Client, ServerError

CHARSET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
UINT = 2
STRING = 5
HEADER = 1
PARTITION = 2
ORDER = 3
LABELLED = 1
OWNERS = 2
FAILED = 'Loading the RDB file failed at byte offset '
REFUSED = 'Refusing to start: the data file '


def module_id(name, version):
    value = 0
    for ch in name:
        value = (value << 6) | CHARSET.index(ch)
    return (value << 10) | version


ACCESS_ID = module_id('eski-labl', 1)


def length(n):
    if n < 64:
        return bytes([n])
    if n < 16384:
        return bytes([0x40 | (n >> 8), n & 0xFF])
    if n <= 0xFFFFFFFF:
        return b'\x80' + n.to_bytes(4, 'big')
    return b'\x81' + n.to_bytes(8, 'big')


def string(s):
    if isinstance(s, str):
        s = s.encode()
    return length(len(s)) + s


def uint(v):
    return length(UINT) + length(v)


def text(s):
    return length(STRING) + string(s)


def record(*fields, when=2, when_op=UINT, end=True):
    out = b'\xf7' + length(ACCESS_ID) + length(when_op) + length(when)
    for f in fields:
        out += f
    if end:
        out += length(0)
    return out


def eslt(levels, compartments=(), trusts=(), labels=()):
    out = b'ESLT\x02'
    for names in (levels, compartments, trusts):
        out += len(names).to_bytes(2, 'little')
        for n in names:
            out += bytes([len(n)]) + n.encode()
    rows = [(0, 0, ())] + list(labels)
    out += len(rows).to_bytes(2, 'little')
    for level, trust, comps in rows:
        out += bytes([level, trust]) + len(comps).to_bytes(2, 'little') + bytes(sorted(comps))
    return out


def header_record(flags, scheme, quotas=(), owners=(), forget=0, seed=7, version=1):
    fields = [uint(HEADER), uint(version), uint(flags), text(scheme), uint(len(quotas))]
    for label, value in quotas:
        fields += [uint(label), uint(value)]
    fields.append(uint(len(owners)))
    for name, quota in owners:
        fields += [text(name), uint(quota)]
    fields += [uint(forget), uint(seed)]
    return record(*fields)


def partition_record(label, owner=0):
    return record(uint(PARTITION), uint(label), uint(owner))


def order_record(entries):
    fields = [uint(ORDER), uint(len(entries))]
    for owner, name, labels in entries:
        fields += [uint(owner), text(name), uint(len(labels))] + [uint(x) for x in labels]
    return record(*fields)


def aux_head():
    out = b'REDIS0012'
    for k, v in ((b'redis-ver', b'7.4.11'), (b'redis-bits', b'64'), (b'ctime', b'1700000000'), (b'used-mem', b'1000000'), (b'aof-base', b'0')):
        out += b'\xfa' + string(k) + string(v)
    return out


def select(db, size=1, expires=0):
    return b'\xfe' + length(db) + b'\xfb' + length(size) + length(expires)


def string_key(name, value, expire_ms=None):
    out = b''
    if expire_ms is not None:
        out += b'\xfc' + int(expire_ms).to_bytes(8, 'little')
    return out + b'\x00' + string(name) + string(value)


def seal(body):
    data = body + b'\xff'
    return data + rdbcmp.crc64(data).to_bytes(8, 'little')


def reseal(data):
    body = data[:-8]
    return body + rdbcmp.crc64(body).to_bytes(8, 'little')


def unseal(data):
    return data[:-8] + bytes(8)


def plain_string(raw):
    head = raw[0]
    kind = head >> 6
    if kind == 0:
        return raw[1:]
    if kind == 1:
        return raw[2:]
    if head == 0x80:
        return raw[5:]
    if head == 0x81:
        return raw[9:]
    if head == 0xC0:
        return str(int.from_bytes(raw[1:2], 'little', signed=True)).encode()
    if head == 0xC1:
        return str(int.from_bytes(raw[1:3], 'little', signed=True)).encode()
    if head == 0xC2:
        return str(int.from_bytes(raw[1:5], 'little', signed=True)).encode()
    raise ValueError('compressed string in a labelled record')


def records(data):
    p = rdbcmp.Parser(data)
    p.raw(9)
    out = []
    while True:
        start = p.i
        op = p.u8()
        if op == 0xfa:
            p.string()
            p.string()
            out.append(('aux', start, p.i, None))
            continue
        if op == 0xf7:
            mid, _ = p.length()
            p.length()
            p.length()
            fields = []
            while True:
                at = p.i
                code, _ = p.length()
                if code == 0:
                    break
                if code == UINT:
                    value = p.length()[0]
                elif code == STRING:
                    value = p.string()
                else:
                    raise ValueError('field opcode %d' % code)
                fields.append((value, at, p.i))
            out.append(('access' if mid == ACCESS_ID else 'module', start, p.i, fields))
            continue
        if op == 0xfe:
            p.length()
            out.append(('select', start, p.i, None))
            continue
        if op == 0xfb:
            p.length()
            p.length()
            out.append(('resize', start, p.i, None))
            continue
        if op == 0xf5:
            p.string()
            out.append(('function', start, p.i, None))
            continue
        if op == 0xff:
            out.append(('eof', start, p.i, None))
            return out
        if op in (0xfc, 0xfd, 0xf8, 0xf9):
            if op == 0xfc:
                p.raw(8)
            elif op == 0xfd:
                p.raw(4)
            elif op == 0xf8:
                p.length()
            else:
                p.raw(1)
            out.append(('meta', start, p.i, None))
            continue
        p.string()
        if op == 7:
            module_value(p)
            out.append(('vset', start, p.i, None))
            continue
        rdbcmp.parse_value(p, op)
        out.append(('key', start, p.i, None))


def module_value(p):
    p.length()
    while True:
        code, _ = p.length()
        if code == 0:
            return
        if code == UINT:
            p.length()
        elif code == STRING:
            p.string()
        else:
            raise ValueError('module field opcode %d' % code)


def aux_fields(data):
    p = rdbcmp.Parser(data)
    p.raw(9)
    out = {}
    for kind, start, stop, _ in records(data):
        if kind == 'aux':
            p.i = start + 1
            name = plain_string(p.string())
            out[name] = plain_string(p.string())
    return out


def header_fields(data):
    for kind, start, stop, fields in records(data):
        if kind == 'access' and fields[0][0] == HEADER:
            return fields
    return None


def without_seed(data):
    fields = header_fields(data)
    if fields is None:
        return data
    _, at, stop = fields[-1]
    return data[:at] + uint(0) + data[stop:]


def access_bytes(data):
    rows = records(data)
    start = next(r[1] for r in rows if r[0] == 'access')
    stop = next(r[1] for r in rows if r[0] == 'eof')
    return data[start:stop]


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


class Run:
    def __init__(self, binary, directory, arguments=(), keyspace_threads=0):
        self.binary = str(binary)
        self.directory = Path(directory)
        self.arguments = list(arguments)
        self.keyspace_threads = keyspace_threads
        self.process = None
        self.port = None
        self.log_path = self.directory / 'server.log'
        self.clients = []

    def command(self, extra=()):
        return [self.binary, '--bind', '127.0.0.1', '--port', str(self.port), '--dir', str(self.directory),
                '--appendonly', 'no', '--enable-debug-command', 'yes', '--enable-protected-configs', 'yes',
                '--keyspace-threads', str(self.keyspace_threads), '--memcached-port', '0'] + self.arguments + list(extra)

    def start(self, extra=(), expect_exit=False, timeout=20):
        self.port = free_port()
        log = self.log_path.open('ab')
        mark = self.log_path.stat().st_size
        self.process = subprocess.Popen(self.command(extra), stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                        start_new_session=True, cwd=str(self.directory))
        log.close()
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            code = self.process.poll()
            if code is not None:
                self.process = None
                return code, self.log_path.read_bytes()[mark:].decode(errors='replace')
            try:
                probe = Client(self.port, timeout=0.3)
                try:
                    if probe.call('PING') == 'PONG':
                        return None, self.log_path.read_bytes()[mark:].decode(errors='replace')
                finally:
                    probe.close()
            except ServerError as error:
                if not str(error).startswith('LOADING'):
                    raise
            except (OSError, EOFError):
                pass
            time.sleep(0.02)
        self.kill()
        raise AssertionError('server neither started nor exited')

    def launch(self, extra=()):
        self.port = free_port()
        log = self.log_path.open('ab')
        self.process = subprocess.Popen(self.command(extra), stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                        start_new_session=True, cwd=str(self.directory))
        log.close()
        end = time.monotonic() + 20
        while time.monotonic() < end:
            if self.process.poll() is not None:
                raise AssertionError('server exited while it was launched: ' + self.log()[-2000:])
            try:
                c = Client(self.port, timeout=10)
                self.clients.append(c)
                return c
            except OSError:
                time.sleep(0.01)
        raise AssertionError('server did not accept a connection')

    def client(self):
        c = Client(self.port)
        self.clients.append(c)
        return c

    def stop(self, signal_number=signal.SIGTERM, timeout=20):
        for c in self.clients:
            try:
                c.close()
            except OSError:
                pass
        self.clients = []
        if self.process is None:
            return None
        try:
            os.killpg(self.process.pid, signal_number)
        except ProcessLookupError:
            pass
        try:
            code = self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            code = self.process.wait(timeout=5)
            self.process = None
            raise AssertionError('server did not stop')
        self.process = None
        return code

    def kill(self):
        if self.process is not None:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=5)
            self.process = None

    def log(self):
        return self.log_path.read_text(errors='replace') if self.log_path.exists() else ''


def workdir(prefix):
    return tempfile.TemporaryDirectory(prefix=prefix)


def info(client, *prefix, section='persistence'):
    value = client.call(*prefix, 'INFO', section)
    return dict(line.split(':', 1) for line in value.decode().splitlines() if ':' in line and not line.startswith('#'))


def loading(client, *prefix):
    return info(client, *prefix)['loading'] == '1'


def wait_loaded(client, *prefix, timeout=120):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if not loading(client, *prefix):
            return
        time.sleep(0.02)
    raise AssertionError('the load did not end')


def answers(client, commands):
    out = []
    for value in client.pipeline(commands):
        out.append(('error', str(value)) if isinstance(value, ServerError) else value)
    return out


def vector(rng, dim):
    return ['%.3f' % rng.uniform(-1, 1) for _ in range(dim)]


def varint(v):
    out = bytearray()
    while True:
        low = v & 0x7F
        v >>= 7
        if not v:
            out.append(low)
            return bytes(out)
        out.append(low | 0x80)


def dump_payload(body):
    body += bytes([12, 0])
    return body + rdbcmp.crc64(body).to_bytes(8, 'little')


def vset_dump(evs, version=2):
    return dump_payload(b'\x07' + length(module_id('eski-vset', version)) + length(5) + string(evs) + length(0))


def evs_flat_head(count, arena_cap, slot_high, dim=3, m=16):
    return b'EVS\x02\x00\x00' + varint(dim) + varint(0) + varint(m) + varint(count) + varint(count) + bytes(8) + b'\x01' + \
        varint(arena_cap) + varint(slot_high)


def evs_v1_head(count, dim=3, m=16):
    return b'EVS\x01\x00' + varint(dim) + varint(0) + varint(m) + varint(count) + varint(count)


def malformed_vset_dumps():
    out = []
    for count, arena_cap in ((1, 16), (1, 1 << 20), (4, 1 << 23), (1 << 20, 1 << 20), (1 << 23, 1 << 23)):
        out.append(vset_dump(evs_flat_head(count, arena_cap, count)))
        out.append(vset_dump(evs_flat_head(count, arena_cap, count) + bytes(8)))
    for count in (1, 1 << 10, 1 << 20, 1 << 23):
        out.append(vset_dump(evs_v1_head(count), version=1))
        out.append(vset_dump(evs_v1_head(count) + bytes(8), version=1))
    return out


MALFORMED_LIST = dump_payload(b'\x0e\x01')


def vadd(key, rng, dim, name, *extra, width=None):
    if width:
        return ('VADD', key, 'REDUCE', dim, 'VALUES', width, *vector(rng, width), name) + extra
    return ('VADD', key, 'VALUES', dim, *vector(rng, dim), name) + extra


def interleave(rng, chains):
    chains = [list(x) for x in chains if x]
    out = []
    while chains:
        k = rng.randrange(len(chains))
        out.append(chains[k].pop(0))
        if not chains[k]:
            chains.pop(k)
    return out


def vector_queries(dim, count=4, seed=99):
    rng = __import__('random').Random(seed)
    return [vector(rng, dim) for _ in range(count)]


def vector_reads(client, prefix, key, dim, names, randoms=True, width=None):
    width = width or dim
    cmds = [(*prefix, 'VCARD', key), (*prefix, 'VDIM', key), (*prefix, 'VINFO', key), (*prefix, 'TYPE', key),
            (*prefix, 'EXISTS', key), (*prefix, 'LABEL', 'OF', key), (*prefix, 'PEXPIRETIME', key),
            (*prefix, 'VRANGE', key, '-', '+', 40)]
    for q in vector_queries(width):
        cmds.append((*prefix, 'VSIM', key, 'VALUES', width, *q, 'WITHSCORES', 'COUNT', 12))
        cmds.append((*prefix, 'VSIM', key, 'VALUES', width, *q, 'WITHSCORES', 'WITHATTRIBS', 'COUNT', 40, 'EF', 30))
        cmds.append((*prefix, 'VSIM', key, 'VALUES', width, *q, 'COUNT', 25, 'FILTER', '.a > 2', 'FILTER-EF', 60))
        cmds.append((*prefix, 'VSIM', key, 'VALUES', width, *q, 'WITHSCORES', 'COUNT', 15, 'TRUTH'))
        cmds.append((*prefix, 'VSIM', key, 'VALUES', width, *q, 'COUNT', 30, 'EPSILON', 0.4))
    for i, name in enumerate(names):
        cmds += [(*prefix, 'VEMB', key, name), (*prefix, 'VEMB', key, name, 'RAW'), (*prefix, 'VGETATTR', key, name),
                 (*prefix, 'VLINKS', key, name, 'WITHSCORES'), (*prefix, 'VISMEMBER', key, name)]
        if i % 4 == 0:
            cmds.append((*prefix, 'VSIM', key, 'ELE', name, 'WITHSCORES', 'COUNT', 10))
    if randoms:
        cmds += [(*prefix, 'VRANDMEMBER', key), (*prefix, 'VRANDMEMBER', key, 6), (*prefix, 'VRANDMEMBER', key, -9)]
    return answers(client, cmds)
