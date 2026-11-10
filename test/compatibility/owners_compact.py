import argparse
import hashlib
import random
import socket
import sys
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Server

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0
OPS = 2500
SEED = 11
FILLERS = 10
HASH_SEED = '7341'
STREAM_SEED = '91'
SCHEME = ('--label-levels', 'U,C,S', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED')
OPERATOR = ('on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*', 'owners:*', 'owner-shared', 'owner-operator')
LABELS = ('U', 'C', 'C//A', 'S', 'S//A/B')
TOP = 'S//A/B'
USERS = ('u0', 'u1', 'u2', 'u3', 'u4', 'u5')
NAMES = ('k', 'a1', 'zz', 'name07', 'profile:12345', 'session:abcdefghij', 'h', 's', 'z', 'l', 'x9', 'counter')
MEMBERS = tuple('m%d' % i for i in range(40))
FAR = '4000000000000'
QUOTA_OOM = "OOM command not allowed when used memory > 'owner-quota'."
TIME_CLASS = {('TTL',), ('PTTL',), ('OBJECT', 'IDLETIME'), ('OBJECT', 'FREQ')}


def encode(arguments):
    values = [value if isinstance(value, bytes) else str(value).encode() for value in arguments]
    return b'*%d\r\n' % len(values) + b''.join(b'$%d\r\n' % len(value) + value + b'\r\n' for value in values)


class Raw:
    def __init__(self, port, timeout=60):
        self.socket = socket.create_connection(('127.0.0.1', port), timeout=timeout)
        self.buffer = bytearray()

    def close(self):
        self.socket.close()

    def fill(self):
        chunk = self.socket.recv(1 << 20)
        if not chunk:
            raise EOFError('server closed the connection')
        self.buffer.extend(chunk)

    def line(self):
        while True:
            at = self.buffer.find(b'\r\n')
            if at >= 0:
                value = bytes(self.buffer[:at])
                del self.buffer[:at + 2]
                return value
            self.fill()

    def read(self):
        head = self.line()
        kind = head[:1]
        if kind in (b'+', b'-', b':', b'_', b',', b'#', b'('):
            return (kind, head[1:])
        if kind in (b'$', b'=', b'!'):
            n = int(head[1:])
            if n < 0:
                return None
            while len(self.buffer) < n + 2:
                self.fill()
            value = bytes(self.buffer[:n])
            del self.buffer[:n + 2]
            return value
        if kind in (b'*', b'~', b'>', b'%'):
            n = int(head[1:])
            if n < 0:
                return None
            return (kind, [self.read() for _ in range(n * (2 if kind == b'%' else 1))])
        raise ValueError('unexpected reply %r' % head)

    def call(self, *arguments):
        self.socket.sendall(encode(arguments))
        return self.read()


def items(reply):
    if isinstance(reply, tuple) and reply[0] in (b'*', b'~', b'>', b'%'):
        return reply[1]
    return None


def masked_bytes(reply):
    values = items(reply)
    if values is None:
        return reply
    out = list(values)
    for i in range(0, len(out) - 1):
        if out[i] == b'bytes':
            out[i + 1] = (b':', b'?')
    return (reply[0], out)


def server_arguments(compact, labelled, extra=()):
    arguments = ['--keyspace-threads', str(KEYSPACE_THREADS), '--memcached-port', '0', '--owners', 'yes', '--hz', '10',
                 '--label-stream-seed', STREAM_SEED, '--debug-hash-seed', HASH_SEED, '--owner-compact', 'yes' if compact else 'no']
    if labelled:
        arguments += list(SCHEME)
    return arguments + list(extra)


class Twin:
    def __init__(self, labelled):
        self.servers = []
        self.clients = []
        try:
            for compact in (True, False):
                server = Server(BINARY, workers=0, arguments=server_arguments(compact, labelled)).start()
                self.servers.append(server)
                client = Raw(server.port)
                self.clients.append(client)
                client.call('ACL', 'SETUSER', 'default', *OPERATOR)
        except BaseException:
            self.close()
            raise
        self.labelled = labelled
        self.operator = ('LABEL', 'AS', TOP, 'SHARED') if labelled else ('LABEL', 'AS', 'SHARED')
        self.both(*self.operator, 'DEBUG', 'SET-ACTIVE-EXPIRE', '0')

    def both(self, *arguments):
        return tuple(client.call(*arguments) for client in self.clients)

    def connect(self):
        return tuple(Raw(server.port) for server in self.servers)

    def close(self):
        for client in self.clients:
            client.close()
        self.clients = []
        problems = []
        for server in self.servers:
            try:
                server.close()
            except AssertionError as error:
                problems.append(str(error))
        self.servers = []
        if problems:
            raise AssertionError('\n'.join(problems))


class Streams:
    def __init__(self, rng, labelled):
        self.r = rng
        self.labelled = labelled

    def scope(self):
        owner = self.r.choice(USERS + ('',))
        tail = ['SHARED'] if owner == '' else ['OWNER', owner]
        if self.labelled:
            return ['LABEL', 'AS', self.r.choice(LABELS)] + tail
        return ['LABEL', 'AS'] + tail

    def name(self):
        return self.r.choice(NAMES)

    def member(self):
        return self.r.choice(MEMBERS)

    def command(self):
        r = self.r
        k = self.name()
        x = r.randrange(100)
        if x < 14:
            v = r.choice(['v', 'value-%d' % r.randrange(100), 'x' * r.choice([1, 7, 8, 32, 100]), str(r.randrange(20000))])
            return ['SET', k, v] + r.choice([[], [], [], ['NX'], ['XX'], ['EX', '100000'], ['KEEPTTL'], ['GET']])
        if x < 22:
            return ['GET', k]
        if x < 26:
            return ['DEL'] + [self.name() for _ in range(r.randrange(1, 3))]
        if x < 28:
            return ['EXISTS', k, self.name()]
        if x < 31:
            return ['MSET'] + sum([[self.name(), 'm%d' % r.randrange(9)] for _ in range(r.randrange(1, 4))], [])
        if x < 33:
            return ['APPEND', k, r.choice(['', 'ab', 'xxxxxxxxxx'])]
        if x < 35:
            return ['INCR', k]
        if x < 37:
            return ['EXPIRE', k, r.choice(['100000', '200000'])]
        if x < 38:
            return ['PERSIST', k]
        if x < 39:
            return ['PEXPIREAT', k, '1']
        if x < 44:
            return ['HSET', k] + sum([[self.member(), 'f%d' % r.randrange(5)] for _ in range(r.choice([1, 1, 2, 5, 30, 140]))], [])
        if x < 46:
            return ['HGETALL', k]
        if x < 47:
            return ['HDEL', k, self.member()]
        if x < 48:
            return ['HPEXPIREAT', k, FAR, 'FIELDS', '1', self.member()]
        if x < 53:
            return ['SADD', k] + [self.member() for _ in range(r.choice([1, 2, 5, 40]))]
        if x < 55:
            return ['SMEMBERS', k]
        if x < 56:
            return ['SPOP', k]
        if x < 57:
            return ['SRANDMEMBER', k, '-3']
        if x < 58:
            return ['SREM', k, self.member()]
        if x < 62:
            return ['ZADD', k] + sum([[str(r.randrange(50)), self.member()] for _ in range(r.choice([1, 3, 20, 140]))], [])
        if x < 64:
            return ['ZRANGE', k, '0', '-1', 'WITHSCORES']
        if x < 65:
            return ['ZREM', k, self.member()]
        if x < 67:
            return ['RPUSH', k] + [self.member() for _ in range(r.choice([1, 3]))]
        if x < 68:
            return ['LPOP', k]
        if x < 69:
            return ['LRANGE', k, '0', '-1']
        if x < 71:
            return ['RENAME', k, self.name()]
        if x < 72:
            return ['COPY', k, self.name()] + r.choice([[], ['REPLACE'], ['DB', '1']])
        if x < 73:
            return ['MOVE', k, r.choice(['0', '1'])]
        if x < 77:
            return ['SCAN', '0', 'COUNT', str(r.choice([1, 2, 10]))] + r.choice([[], ['MATCH', 'k*'], ['TYPE', 'string']])
        if x < 79:
            return ['KEYS', '*']
        if x < 81:
            return ['RANDOMKEY']
        if x < 83:
            return ['DBSIZE']
        if x < 84:
            return ['TYPE', k]
        if x < 85:
            return ['OBJECT', 'ENCODING', k]
        if x < 86:
            return ['FLUSHDB']
        if x < 87:
            return ['SELECT', r.choice(['0', '1'])]
        if x < 88:
            return ['DEBUG', 'DIGEST-VALUE', k]
        if x < 89:
            return ['GETDEL', k]
        if x < 90:
            return ['UNLINK', k]
        if x < 91:
            return ['INFO', 'keyspace']
        if x < 92:
            return ['TOUCH', k]
        if x < 93:
            return ['ZRANDMEMBER', k, '3']
        return ['GET', k]


class Churn(Streams):
    CHURN = tuple('c%d' % i for i in range(14)) + tuple('churn-long-name-%d' % i for i in range(4))

    def command(self):
        r = self.r
        k = r.choice(self.CHURN)
        x = r.randrange(100)
        if x < 34:
            return ['SET', k, r.choice(['v', 'longer-value-%d' % r.randrange(9)])] + r.choice([[], [], ['EX', '100000']])
        if x < 40:
            return ['MSET'] + sum([[r.choice(self.CHURN), 'w'] for _ in range(r.randrange(2, 6))], [])
        if x < 66:
            return ['DEL'] + [r.choice(self.CHURN) for _ in range(r.randrange(1, 5))]
        if x < 72:
            return ['SCAN', '0', 'COUNT', str(r.choice([1, 3, 20]))]
        if x < 77:
            return ['KEYS', '*']
        if x < 82:
            return ['RANDOMKEY']
        if x < 85:
            return ['DBSIZE']
        if x < 88:
            return ['SADD', k] + [self.member() for _ in range(r.choice([1, 3]))]
        if x < 90:
            return ['HSET', k, 'f', 'v']
        if x < 92:
            return ['ZADD', k, '1', 'a']
        if x < 94:
            return ['RENAME', k, r.choice(self.CHURN)]
        if x < 95:
            return ['MOVE', k, r.choice(['0', '1'])]
        if x < 96:
            return ['SELECT', r.choice(['0', '1'])]
        return ['GET', k]


class Compact(Churn):
    CHURN = tuple('c%d' % i for i in range(6)) + ('compact-long-0', 'compact-long-1')

    def command(self):
        r = self.r
        x = r.randrange(100)
        if x < 12:
            return ['MSET'] + sum([[n, 'v'] for n in self.CHURN[:r.randrange(3, 8)]], [])
        if x < 30:
            return ['DEL'] + r.sample(self.CHURN[2:], r.randrange(1, 5))
        return Churn.command(self)


def full_scan(client, head, count):
    cursor = b'0'
    out = []
    for _ in range(100000):
        reply = client.call(*head, 'SCAN', cursor, 'COUNT', count)
        values = items(reply)
        if values is None:
            return reply
        out.append(values[0])
        out.append(values[1])
        cursor = values[0]
        if cursor == b'0':
            return out
    raise AssertionError('SCAN did not finish')


class StreamTwins(unittest.TestCase):
    def run_stream(self, kind, labelled, seed):
        twin = Twin(labelled)
        rng = random.Random(seed)
        streams = kind(rng, labelled)
        differences = []
        compared = 0
        try:
            for i in range(OPS):
                head = streams.scope()
                command = streams.command()
                a, b = twin.both(*head, *command)
                if (command[0],) not in TIME_CLASS and tuple(command[:2]) not in TIME_CLASS:
                    compared += 1
                    if a != b:
                        differences.append((i, head + command, a, b))
                if i % 97 == 0:
                    a, b = twin.both(*twin.operator, 'DEBUG', 'DIGEST')
                    if a != b:
                        differences.append((i, 'DEBUG DIGEST', a, b))
                if i % 211 == 0:
                    scope = streams.scope()
                    count = rng.choice([1, 2, 5])
                    a, b = (full_scan(client, scope, count) for client in twin.clients)
                    if a != b:
                        differences.append((i, scope + ['SCAN*', count], a, b))
                if i % 499 == 0:
                    user = rng.choice(USERS)
                    a, b = (masked_bytes(r) for r in twin.both(*twin.operator, 'OWNERS', 'INFO', user))
                    if a != b:
                        differences.append((i, 'OWNERS INFO ' + user, a, b))
                if i % 1499 == 0 and i > 0:
                    user = rng.choice(USERS)
                    a, b = (masked_bytes(r) for r in twin.both(*twin.operator, 'OWNERS', 'FORGET', user))
                    if a != b:
                        differences.append((i, 'OWNERS FORGET ' + user, a, b))
                if len(differences) > 20:
                    break
        finally:
            twin.close()
        self.assertGreater(compared, OPS // 2)
        self.assertEqual([d[:2] for d in differences], [], differences[:1])

    def test_general_streams_match(self):
        self.run_stream(Streams, False, SEED)

    def test_general_streams_match_with_labels(self):
        self.run_stream(Streams, True, SEED + 1)

    def test_churn_streams_match(self):
        self.run_stream(Churn, False, SEED + 2)

    def test_churn_streams_match_with_labels(self):
        self.run_stream(Churn, True, SEED + 3)

    def test_compaction_streams_match(self):
        self.run_stream(Compact, False, SEED + 4)

    def test_compaction_streams_match_with_labels(self):
        self.run_stream(Compact, True, SEED + 5)


SOURCES = {
    'none': [],
    'string': [['SET', 'src', 'value-longer-than-seven']],
    'string2': [['SET', 'src', 'v1'], ['SET', 'src2', 'value-two-is-longer']],
    'bits': [['SET', 'src', 'abcdefghij'], ['SET', 'src2', 'zyxwvut']],
    'hash': [['HSET', 'src', 'f', 'v', 'g', 'w']],
    'hashttl': [['HSET', 'src', 'f', 'v', 'g', 'w'], ['HPEXPIREAT', 'src', FAR, 'FIELDS', '1', 'g']],
    'list': [['RPUSH', 'src', 'a', 'b', 'c']],
    'list2': [['RPUSH', 'src', 'a', 'b', 'c'], ['RPUSH', 'src2', 'd', 'e']],
    'set': [['SADD', 'src', 'a', 'b', 'c']],
    'set2': [['SADD', 'src', 'a', 'b', 'c'], ['SADD', 'src2', 'b', 'c', 'd']],
    'zset': [['ZADD', 'src', '1', 'a', '2', 'b', '3', 'c']],
    'zset2': [['ZADD', 'src', '1', 'a', '2', 'b'], ['ZADD', 'src2', '2', 'b', '3', 'c']],
    'geo': [['GEOADD', 'src', '13.361389', '38.115556', 'Palermo', '15.087269', '37.502669', 'Catania']],
    'hll': [['PFADD', 'src', 'a', 'b'], ['PFADD', 'src2', 'c']],
    'stream': [['XADD', 'src', '1-1', 'f', 'v'], ['XADD', 'src', '2-1', 'g', 'w']],
    'stream2': [['XADD', 'src', '1-1', 'f', 'v'], ['XADD', 'src2', '2-1', 'g', 'w']],
    'groups': [['XADD', 'src', '1-1', 'f', 'v'], ['XADD', 'src2', '2-1', 'g', 'w'], ['XGROUP', 'CREATE', 'src', 'g', '0'], ['XGROUP', 'CREATE', 'src2', 'g', '0']],
    'sortby': [['RPUSH', 'src', 'b', 'a', 'c'], ['SET', 'w_a', '3'], ['SET', 'w_b', '1'], ['SET', 'o_a', 'x'], ['SET', 'o_c', 'y']],
}

SCRIPT_COPY = "redis.call('SET', KEYS[2], redis.call('GET', KEYS[1]) or 'none') return redis.call('GET', KEYS[2])"
SCRIPT_READ = "return {redis.call('EXISTS', KEYS[1]), redis.call('EXISTS', KEYS[2])}"
FUNCTION = "#!lua name=compactlib\nredis.register_function('cp', function(keys, args) redis.call('SET', keys[2], redis.call('GET', keys[1]) or 'none') return redis.call('GET', keys[2]) end)\nredis.register_function{function_name='rd', callback=function(keys, args) return redis.call('EXISTS', keys[1], keys[2]) end, flags={'no-writes'}}"
CLOSED_PORT = 0

CASES = [
    ('bitop', 'bits', [['BITOP', 'AND', 'dst', 'src', 'src2']]),
    ('blmove', 'list', [['BLMOVE', 'src', 'dst', 'LEFT', 'RIGHT', '0.01']]),
    ('blmpop', 'list2', [['BLMPOP', '0.01', '2', 'src', 'src2', 'LEFT', 'COUNT', '2']]),
    ('blpop', 'list2', [['BLPOP', 'src2', 'src', '0.01']]),
    ('brpop', 'list', [['BRPOP', 'nope', 'src', '0.01']]),
    ('brpoplpush', 'list', [['BRPOPLPUSH', 'src', 'dst', '0.01']]),
    ('bzmpop', 'zset2', [['BZMPOP', '0.01', '2', 'src', 'src2', 'MIN', 'COUNT', '2']]),
    ('bzpopmax', 'zset2', [['BZPOPMAX', 'src', 'src2', '0.01']]),
    ('bzpopmin', 'zset', [['BZPOPMIN', 'nope', 'src', '0.01']]),
    ('copy', 'string', [['COPY', 'src', 'dst']]),
    ('copy', 'hash', [['COPY', 'src', 'dst']]),
    ('copy', 'hashttl', [['COPY', 'src', 'dst'], ['HPEXPIRETIME', 'dst', 'FIELDS', '1', 'g']]),
    ('copy', 'list', [['COPY', 'src', 'dst']]),
    ('copy', 'set', [['COPY', 'src', 'dst']]),
    ('copy', 'zset', [['COPY', 'src', 'dst']]),
    ('copy', 'stream', [['COPY', 'src', 'dst']]),
    ('copy', 'set2', [['COPY', 'src', 'src2', 'REPLACE']]),
    ('copy', 'zset', [['COPY', 'src', 'dst', 'DB', '1'], ['SELECT', '1'], ['ZRANGE', 'dst', '0', '-1'], ['SELECT', '0']]),
    ('del', 'string2', [['DEL', 'src', 'src2', 'f0', 'nope']]),
    ('eval', 'string', [['EVAL', SCRIPT_COPY, '2', 'src', 'dst']]),
    ('eval_ro', 'string', [['EVAL_RO', SCRIPT_READ, '2', 'src', 'dst']]),
    ('evalsha', 'string', [['SCRIPT', 'LOAD', SCRIPT_COPY], ['EVALSHA', hashlib.sha1(SCRIPT_COPY.encode()).hexdigest(), '2', 'src', 'dst']]),
    ('evalsha_ro', 'string', [['SCRIPT', 'LOAD', SCRIPT_READ], ['EVALSHA_RO', hashlib.sha1(SCRIPT_READ.encode()).hexdigest(), '2', 'src', 'dst']]),
    ('exists', 'string2', [['EXISTS', 'src', 'src2', 'dst', 'f0']]),
    ('fcall', 'string', [['FCALL', 'cp', '2', 'src', 'dst']]),
    ('fcall_ro', 'string', [['FCALL_RO', 'rd', '2', 'src', 'dst']]),
    ('georadius', 'geo', [['GEORADIUS', 'src', '15', '37', '200', 'km', 'STORE', 'dst']]),
    ('georadius', 'geo', [['GEORADIUS', 'src', '15', '37', '200', 'km', 'STOREDIST', 'dst']]),
    ('georadiusbymember', 'geo', [['GEORADIUSBYMEMBER', 'src', 'Palermo', '200', 'km', 'STORE', 'dst']]),
    ('geosearchstore', 'geo', [['GEOSEARCHSTORE', 'dst', 'src', 'FROMLONLAT', '15', '37', 'BYRADIUS', '200', 'km']]),
    ('lcs', 'bits', [['LCS', 'src', 'src2']]),
    ('lmove', 'list', [['LMOVE', 'src', 'dst', 'LEFT', 'RIGHT']]),
    ('lmpop', 'list2', [['LMPOP', '2', 'nope', 'src', 'LEFT', 'COUNT', '3']]),
    ('mget', 'string2', [['MGET', 'src', 'src2', 'f0', 'nope']]),
    ('migrate', 'string2', [['MIGRATE', '127.0.0.1', 'CLOSED', '', '0', '100', 'KEYS', 'src', 'src2']]),
    ('mset', 'none', [['MSET', 'dst', '1', 'dst2', '2', 'dst3', 'value-three-long', 'dst4', '4', 'dst5', '5']]),
    ('msetnx', 'string', [['MSETNX', 'dst', '1', 'dst2', '2', 'dst3', '3']]),
    ('pfcount', 'hll', [['PFCOUNT', 'src', 'src2']]),
    ('pfmerge', 'hll', [['PFMERGE', 'dst', 'src', 'src2']]),
    ('rename', 'hash', [['RENAME', 'src', 'dst']]),
    ('rename', 'string2', [['RENAME', 'src', 'src2']]),
    ('renamenx', 'string', [['RENAMENX', 'src', 'dst']]),
    ('rpoplpush', 'list', [['RPOPLPUSH', 'src', 'dst']]),
    ('sdiff', 'set2', [['SDIFF', 'src', 'src2']]),
    ('sdiffstore', 'set2', [['SDIFFSTORE', 'dst', 'src', 'src2']]),
    ('sinter', 'set2', [['SINTER', 'src', 'src2']]),
    ('sintercard', 'set2', [['SINTERCARD', '2', 'src', 'src2']]),
    ('sinterstore', 'set2', [['SINTERSTORE', 'dst', 'src', 'src2']]),
    ('smove', 'set', [['SMOVE', 'src', 'dst', 'a']]),
    ('sort', 'list', [['SORT', 'src', 'ALPHA', 'STORE', 'dst']]),
    ('sort', 'sortby', [['SORT', 'src', 'BY', 'w_*', 'GET', '#', 'GET', 'o_*', 'ALPHA', 'STORE', 'dst']]),
    ('sort_ro', 'sortby', [['SORT_RO', 'src', 'BY', 'w_*', 'GET', 'o_*', 'ALPHA']]),
    ('ssubscribe', 'none', [['SSUBSCRIBE', 'src', 'src2']]),
    ('sunion', 'set2', [['SUNION', 'src', 'src2']]),
    ('sunionstore', 'set2', [['SUNIONSTORE', 'dst', 'src', 'src2']]),
    ('sunsubscribe', 'none', [['SUNSUBSCRIBE', 'src', 'src2']]),
    ('touch', 'string2', [['TOUCH', 'src', 'src2', 'nope']]),
    ('unlink', 'string2', [['UNLINK', 'src', 'src2']]),
    ('watch', 'string2', [['WATCH', 'src', 'src2'], ['UNWATCH']]),
    ('xread', 'stream2', [['XREAD', 'COUNT', '5', 'STREAMS', 'src', 'src2', '0', '0']]),
    ('xreadgroup', 'groups', [['XREADGROUP', 'GROUP', 'g', 'c', 'COUNT', '5', 'STREAMS', 'src', 'src2', '>', '>']]),
    ('zdiff', 'zset2', [['ZDIFF', '2', 'src', 'src2', 'WITHSCORES']]),
    ('zdiffstore', 'zset2', [['ZDIFFSTORE', 'dst', '2', 'src', 'src2']]),
    ('zinter', 'zset2', [['ZINTER', '2', 'src', 'src2']]),
    ('zintercard', 'zset2', [['ZINTERCARD', '2', 'src', 'src2']]),
    ('zinterstore', 'zset2', [['ZINTERSTORE', 'dst', '2', 'src', 'src2']]),
    ('zmpop', 'zset2', [['ZMPOP', '2', 'src', 'src2', 'MAX', 'COUNT', '2']]),
    ('zrangestore', 'zset', [['ZRANGESTORE', 'dst', 'src', '0', '-1']]),
    ('zunion', 'zset2', [['ZUNION', '2', 'src', 'src2']]),
    ('zunionstore', 'zset2', [['ZUNIONSTORE', 'dst', '2', 'src', 'src2']]),
    ('move', 'string', [['MOVE', 'src', '1'], ['SELECT', '1'], ['GET', 'src'], ['SELECT', '0']]),
    ('move', 'set', [['MOVE', 'src', '1'], ['SELECT', '1'], ['SMEMBERS', 'src'], ['SELECT', '0']]),
    ('hexpire', 'hash', [['HPEXPIREAT', 'src', FAR, 'FIELDS', '1', 'f']]),
    ('append', 'string', [['APPEND', 'src', 'tail']]),
    ('setrange', 'string', [['SETRANGE', 'src', '40', 'x']]),
    ('getdel', 'string', [['GETDEL', 'src']]),
    ('xautoclaim', 'groups', [['XREADGROUP', 'GROUP', 'g', 'c', 'STREAMS', 'src', '>'], ['XAUTOCLAIM', 'src', 'g', 'c2', '0', '0']]),
    ('vadd', 'none', [['VADD', 'dst', 'VALUES', '2', '1', '2', 'e1'], ['VCARD', 'dst']]),
    ('hset', 'none', [['HSET', 'dst', 'f', 'v'], ['SADD', 'dst2', 'a'], ['ZADD', 'dst3', '1', 'a']]),
]

NOT_IN_SCRIPTS = {'ssubscribe', 'sunsubscribe', 'watch', 'migrate', 'blmove', 'blmpop', 'blpop', 'brpop', 'brpoplpush', 'bzmpop', 'bzpopmax', 'bzpopmin', 'eval', 'eval_ro', 'evalsha', 'evalsha_ro', 'fcall', 'fcall_ro', 'move', 'copy'}
SCRIPT_RUNNER = "local out = {} local n = 1 for i = 1, tonumber(ARGV[1]) do local c = tonumber(ARGV[n + 1]) local a = {} for j = 1, c do a[j] = ARGV[n + 1 + j] end n = n + 1 + c out[#out + 1] = redis.pcall(unpack(a)) end return out"


def key_names(sequence):
    names = set()
    for command in sequence:
        for word in command[1:]:
            if word in ('src', 'src2', 'dst', 'dst2', 'dst3', 'dst4', 'dst5', 'nope') or word.startswith(('f', 'w_', 'o_')) and len(word) <= 4:
                names.add(word)
    return sorted(names)


def multi_key_commands(client):
    found = {}
    for entry in items(client.call('LABEL', 'AS', 'SHARED', 'COMMAND')):
        for command in [entry] + list(items(items(entry)[9]) or []):
            fields = items(command)
            name = fields[0].decode()
            first, last, step = int(fields[3][1]), int(fields[4][1]), int(fields[5][1])
            specs = items(fields[8]) or []
            many = len(specs) >= 2 or last == -1 or (step > 0 and last - first >= step)
            for spec in specs:
                text = repr(spec)
                if "b'keynum'" in text:
                    many = True
                values = items(spec)
                for i in range(0, len(values) - 1, 2):
                    if values[i] == b'find_keys':
                        inner = items(values[i + 1])
                        for j in range(0, len(inner) - 1, 2):
                            if inner[j] == b'spec':
                                spec_values = items(inner[j + 1])
                                for m in range(0, len(spec_values) - 1, 2):
                                    if spec_values[m] == b'lastkey' and int(spec_values[m + 1][1]) != 0:
                                        many = True
            if many:
                found[name] = True
    return sorted(found)


class MultiKey(unittest.TestCase):
    def setUp(self):
        global CLOSED_PORT
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            CLOSED_PORT = probe.getsockname()[1]
        self.twin = Twin(False)
        loaded = self.twin.both('LABEL', 'AS', 'SHARED', 'FUNCTION', 'LOAD', 'REPLACE', FUNCTION)
        self.assertEqual(loaded[0], loaded[1])
        self.assertEqual(loaded[0], b'compactlib')

    def tearDown(self):
        self.twin.close()

    def words(self, command):
        return [str(CLOSED_PORT) if w == 'CLOSED' else w for w in command]

    def scenario(self, owner, name, sequence, mode):
        head = ['LABEL', 'AS', 'OWNER', owner]
        differences = []
        if mode == 'plain':
            for command in sequence:
                if command[0] in ('SSUBSCRIBE', 'SUNSUBSCRIBE'):
                    pair = self.twin.connect()
                    try:
                        a, b = (client.call(*head, *command) for client in pair)
                    finally:
                        for client in pair:
                            client.close()
                else:
                    a, b = self.twin.both(*head, *self.words(command))
                if a != b:
                    differences.append((owner, mode, command, a, b))
        elif mode == 'multi':
            pair = self.twin.connect()
            try:
                replies = []
                for client in pair:
                    out = [client.call(*head, 'MULTI')]
                    for command in sequence:
                        out.append(client.call(*self.words(command)))
                    out.append(client.call('EXEC'))
                    replies.append(out)
            finally:
                for client in pair:
                    client.close()
            if replies[0] != replies[1]:
                differences.append((owner, mode, name, replies[0], replies[1]))
        else:
            argv = [str(len(sequence))]
            for command in sequence:
                words = self.words(command)
                argv += [str(len(words))] + words
            keys = key_names(sequence)
            a, b = self.twin.both(*head, 'EVAL', SCRIPT_RUNNER, str(len(keys)), *keys, *argv)
            if a != b:
                differences.append((owner, mode, name, a, b))
        for probe in (['KEYS', '*'], ['SCAN', '0', 'COUNT', '20'], ['DBSIZE'], ['TYPE', 'dst'], ['RANDOMKEY'], ['DEBUG', 'DIGEST-VALUE', 'dst', 'src', 'src2']):
            a, b = self.twin.both(*head, *probe)
            if a != b:
                differences.append((owner, mode, probe, a, b))
        a, b = self.twin.both('LABEL', 'AS', 'SHARED', 'DEBUG', 'DIGEST')
        if a != b:
            differences.append((owner, mode, 'DIGEST', a, b))
        a, b = (masked_bytes(r) for r in self.twin.both('LABEL', 'AS', 'SHARED', 'OWNERS', 'FORGET', owner))
        if a != b:
            differences.append((owner, mode, 'FORGET', a, b))
        return differences

    def test_every_multi_key_command_is_covered(self):
        covered = {name for name, _, _ in CASES}
        missing = [name for name in multi_key_commands(self.twin.clients[0]) if name not in covered]
        self.assertEqual(missing, [])

    def test_multi_key_commands_match_at_every_key_count(self):
        differences = []
        scenarios = 0
        for index, (name, kind, commands) in enumerate(CASES):
            for mode in ('plain', 'multi', 'script'):
                if mode == 'script' and name in NOT_IN_SCRIPTS:
                    continue
                for fillers in range(FILLERS):
                    owner = 'mk%d_%s_%d' % (index, mode[0], fillers)
                    sequence = [['SET', 'f%d' % i, 'v'] for i in range(fillers)] + SOURCES[kind] + commands
                    differences += self.scenario(owner, name, sequence, mode)
                    scenarios += 1
        self.assertGreater(scenarios, len(CASES) * FILLERS * 2)
        self.assertEqual([d[:3] for d in differences], [], differences[:1])


class Settings(unittest.TestCase):
    def test_debug_hash_seed_needs_the_debug_command(self):
        server = Server(BINARY, workers=0, arguments=['--debug-hash-seed', '5', '--enable-debug-command', 'no', '--keyspace-threads', str(KEYSPACE_THREADS)])
        try:
            with self.assertRaises(AssertionError) as caught:
                server.start()
            self.assertIn('debug-hash-seed is a test setting and needs enable-debug-command set to yes or local', str(caught.exception))
            self.assertEqual(server.process.poll(), 1)
            server.stop(expected_exit=1)
        finally:
            server.close()

    def test_both_settings_are_hidden_and_startup_only(self):
        twin = Twin(False)
        try:
            client = twin.clients[0]
            op = ('LABEL', 'AS', 'SHARED')
            self.assertEqual(client.call(*op, 'CONFIG', 'GET', 'owner-compact'), (b'*', [b'owner-compact', b'yes']))
            self.assertEqual(twin.clients[1].call(*op, 'CONFIG', 'GET', 'owner-compact'), (b'*', [b'owner-compact', b'no']))
            self.assertEqual(client.call(*op, 'CONFIG', 'GET', 'debug-hash-seed'), (b'*', [b'debug-hash-seed', HASH_SEED.encode()]))
            listed = items(client.call(*op, 'CONFIG', 'GET', '*'))
            self.assertNotIn(b'owner-compact', listed)
            self.assertNotIn(b'debug-hash-seed', listed)
            for name, value in (('owner-compact', 'no'), ('debug-hash-seed', '9')):
                reply = client.call(*op, 'CONFIG', 'SET', name, value)
                self.assertEqual(reply[0], b'-')
                self.assertIn(b"can't set immutable config", reply[1])
        finally:
            twin.close()

    def test_released_partitions_return_their_bytes(self):
        twin = Twin(True)
        try:
            def owner_bytes():
                out = []
                for reply in twin.both(*twin.operator, 'OWNERS', 'INFO', 'cycle'):
                    values = items(reply)
                    out.append(int(values[values.index(b'bytes') + 1][1]))
                return out

            head = ('LABEL', 'AS', 'C', 'OWNER', 'cycle')
            twin.both(*head, 'GET', 'k')
            entry = owner_bytes()
            twin.both(*head, 'SET', 'k', 'v')
            twin.both(*head, 'DEL', 'k')
            empty = owner_bytes()
            self.assertTrue(all(0 < b - a <= 256 for a, b in zip(entry, empty)), (entry, empty))
            for _ in range(5):
                twin.both(*head, 'MSET', 'k', 'v', 'j', 'w', 'i', 'x', 'h', 'y', 'g', 'z')
                twin.both(*head, 'HSET', 'f', 'a', 'b')
                twin.both(*head, 'DEL', 'k', 'j', 'i', 'h', 'g', 'f')
                self.assertEqual(owner_bytes(), empty)
                twin.both(*head, 'SET', 'k', 'v')
                twin.both(*head, 'FLUSHDB')
                self.assertEqual(owner_bytes(), empty)
        finally:
            twin.close()

    def test_the_compact_form_is_smaller_and_compacts(self):
        twin = Twin(False)
        try:
            head = ('LABEL', 'AS', 'OWNER', 'small')

            def owner_bytes():
                out = []
                for reply in twin.both('LABEL', 'AS', 'SHARED', 'OWNERS', 'INFO', 'small'):
                    values = items(reply)
                    out.append(int(values[values.index(b'bytes') + 1][1]))
                return out

            twin.both(*head, 'SET', 'k', 'v')
            compact, full = owner_bytes()
            self.assertLess(compact + 400, full)
            twin.both(*head, 'MSET', 'a', '1', 'b', '2', 'c', '3', 'd', '4')
            grown, _ = owner_bytes()
            twin.both(*head, 'DEL', 'b', 'c', 'd')
            shrunk, full_after = owner_bytes()
            self.assertLess(shrunk + 200, grown)
            self.assertEqual(full_after, full)
            twin.both(*head, 'SADD', 's', 'x')
            with_set, _ = owner_bytes()
            self.assertGreater(with_set - shrunk, 152)
            a, b = twin.both(*head, 'KEYS', '*')
            self.assertEqual(a, b)
        finally:
            twin.close()


class OwnerFigure(unittest.TestCase):
    def setUp(self):
        self.twin = None

    def tearDown(self):
        if self.twin is not None:
            self.twin.close()

    def start(self, labelled):
        if self.twin is not None:
            self.twin.close()
            self.twin = None
        self.twin = Twin(labelled)
        self.twin.both(*self.twin.operator, 'DEBUG', 'SET-ACTIVE-EXPIRE', '1')
        self.label = ('C',) if labelled else ()
        self.shared_head = ('LABEL', 'AS') + self.label + ('SHARED',)

    def head(self, owner):
        return ('LABEL', 'AS') + self.label + ('OWNER', owner)

    def figures(self, owner, field=b'bytes'):
        out = []
        for reply in self.twin.both(*self.twin.operator, 'OWNERS', 'INFO', owner):
            values = items(reply)
            out.append(int(values[values.index(field) + 1][1]))
        return out

    def leave_work_lists(self, owner):
        h = self.head(owner)
        for command in (('SET', 'k', 'v'), ('SET', 't', 'v', 'EX', '1000'), ('HSET', 'h', 'f', 'v'), ('HPEXPIREAT', 'h', FAR, 'FIELDS', '1', 'f'),
                        ('SADD', 's', 'a', 'b'), ('ZADD', 'z', '1', 'a'), ('DEL', 't'), ('HPERSIST', 'h', 'FIELDS', '1', 'f')):
            a, b = self.twin.both(*h, *command)
            self.assertEqual(a, b)

    def unrelated(self):
        other = self.head('u2')
        for command in ((other + ('SET', 'gone', 'v', 'PX', '50')), (other + ('SET', 'a', 'v')), (other + ('MSET', 'b', '1', 'c', 'value-longer-than-seven', 'd', '3', 'e', '4')),
                        (other + ('HSET', 'h', 'f', 'v')), (other + ('DEL', 'b', 'c', 'd')), ('PING',), (self.shared_head + ('GET', 'k')),
                        (self.shared_head + ('SET', 'shared', 'v')), (self.head('u3') + ('SET', 't', 'v', 'EX', '1000')), (self.head('u3') + ('DEL', 't'))):
            a, b = self.twin.both(*command)
            self.assertEqual(a, b)
        time.sleep(1.2)
        self.assertEqual(self.figures('u2', b'keys'), [3, 3])
        self.twin.both('PING')

    def test_an_owner_figure_ignores_unrelated_activity(self):
        for labelled in (False, True):
            with self.subTest(labelled=labelled):
                self.start(labelled)
                self.leave_work_lists('u1')
                before = self.figures('u1')
                self.unrelated()
                self.assertEqual(self.figures('u1'), before)

    def test_the_quota_boundary_ignores_unrelated_activity(self):
        self.start(False)
        self.leave_work_lists('u1')
        before = self.figures('u1')
        for server, limit in enumerate(before):
            self.twin.clients[server].call(*self.twin.operator, 'OWNERS', 'QUOTA', 'u1', 'LIMIT', str(limit - 1))
        first = self.twin.both(*self.head('u1'), 'SET', 'k2', 'v')
        self.assertEqual(first[0], (b'-', QUOTA_OOM.encode()))
        self.assertEqual(first[1], first[0])
        self.unrelated()
        self.assertEqual(self.twin.both(*self.head('u1'), 'SET', 'k2', 'v'), first)
        self.assertEqual(self.figures('u1'), before)

    def test_owner_figures_add_up_to_the_owner_total(self):
        self.start(False)
        self.leave_work_lists('u1')
        for _ in range(2):
            known = []
            for reply in self.twin.both(*self.twin.operator, 'INFO', 'owners'):
                text = reply.decode()
                fields = dict(line.split(':', 1) for line in text.splitlines() if ':' in line)
                known.append((int(fields['owners_known']), int(fields['owner_bytes'])))
            owners = ['u1', 'u2', 'u3'][:known[0][0]]
            for server in range(2):
                self.assertEqual(known[server][0], len(owners))
                total = sum(self.figures(owner)[server] for owner in owners)
                self.assertEqual(total, known[server][1])
            self.unrelated()


def main():
    global BINARY, KEYSPACE_THREADS, OPS, SEED
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', default=str(BINARY))
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--ops', type=int, default=OPS)
    parser.add_argument('--seed', type=int, default=SEED)
    args, rest = parser.parse_known_args()
    BINARY = Path(args.server).resolve()
    KEYSPACE_THREADS = args.keyspace_threads
    OPS = args.ops
    SEED = args.seed
    unittest.main(argv=[sys.argv[0]] + rest, verbosity=1)


if __name__ == '__main__':
    main()
