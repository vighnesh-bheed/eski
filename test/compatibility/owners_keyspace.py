import argparse
import random
from pathlib import Path
import socket
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Client, Push, Server, ServerError

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0
SCHEME = ('--label-levels', 'U,C,S', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED')
OPERATOR = ('on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*', 'owners:*', 'owner-shared', 'owner-operator')
WRONGTYPE = 'WRONGTYPE Operation against a key holding the wrong kind of value'
TOP_ERROR = 'ERR this command needs a label that dominates the whole label scheme'
QUOTA_OOM = "OOM command not allowed when used memory > 'owner-quota'."
PARTITION_LIMIT = 'ERR owner partition limit reached'
SHARED = ''
LEVELS = {'U': 0, 'C': 1, 'S': 2}
TRUSTS = {'WEB': 0, 'VETTED': 1}
TRUST_NAMES = ['WEB', 'VETTED']


def parse_label(text):
    trust = 0
    if ';' in text:
        text, name = text.split(';')
        trust = TRUSTS[name]
    comps = frozenset()
    if '//' in text:
        text, rest = text.split('//')
        comps = frozenset(rest.split('/'))
    return LEVELS[text], comps, trust


def format_label(text):
    level, comps, trust = parse_label(text)
    out = [k for k, v in LEVELS.items() if v == level][0]
    if comps:
        out += '//' + '/'.join(sorted(comps))
    if trust:
        out += ';' + TRUST_NAMES[trust]
    return out


def dominates(a, b):
    x, y = parse_label(a), parse_label(b)
    return x[0] >= y[0] and x[1] >= y[1] and x[2] <= y[2]


def rank(a, b):
    x, y = parse_label(a), parse_label(b)
    for p, q in ((x[0], y[0]), (len(x[1]), len(y[1])), (x[2], y[2])):
        if p != q:
            return 1 if p > q else -1
    return 0


def scope_text(owner):
    return ' SHARED' if owner == SHARED else ' OWNER ' + owner


def drained(client):
    try:
        client.socket.settimeout(2)
        client.send('PING')
        while True:
            client.read()
    except (OSError, EOFError):
        return True
    return False


def prefix(label, owner):
    head = ('LABEL', 'AS') if label is None else ('LABEL', 'AS', label)
    if owner == SHARED:
        return head + ('SHARED',)
    return head + ('OWNER', owner)


def pinned(client, label, owner, *arguments):
    if label is not None:
        client.call('LABEL', 'SESSION', label)
    if owner is None:
        client.send(*arguments)
    else:
        client.send(*prefix(None, owner), *arguments)
    value = client.read()
    if isinstance(value, ServerError):
        raise value
    return value


def parse_info(value):
    if not isinstance(value, bytes):
        raise AssertionError('INFO did not return a bulk string: %r' % (value,))
    return dict(line.split(':', 1) for line in value.decode().splitlines() if ':' in line and not line.startswith('#'))


def error_text(value):
    return str(value) if isinstance(value, ServerError) else None


class Copy:
    def __init__(self, kind, value, seq):
        self.kind = kind
        self.value = value
        self.seq = seq


class Model:
    def __init__(self):
        self.names = {}
        self.seq = 0

    def visible(self, name, reader, owner):
        out = []
        for (label, w), cp in self.names.get(name, {}).items():
            if (w == SHARED or w == owner) and dominates(reader, label):
                out.append((label, w, cp))
        return out

    def resolve(self, name, reader, owner):
        copies = self.names.get(name, {})
        if owner != SHARED and (reader, owner) in copies:
            return reader, owner, copies[(reader, owner)]
        if (reader, SHARED) in copies:
            return reader, SHARED, copies[(reader, SHARED)]
        best = None
        for label, w, cp in self.visible(name, reader, owner):
            if best is None:
                best = (label, w, cp)
                continue
            r = rank(label, best[0])
            if r > 0 or (r == 0 and w != SHARED and best[1] == SHARED) or (r == 0 and w == best[1] and cp.seq < best[2].seq):
                best = (label, w, cp)
        return best

    def create(self, name, label, owner, kind, value):
        self.seq += 1
        self.names.setdefault(name, {})[(label, owner)] = Copy(kind, value, self.seq)

    def delete(self, name, label, owner):
        copies = self.names.get(name, {})
        copies.pop((label, owner), None)
        if not copies:
            self.names.pop(name, None)

    def listed(self, reader, owner):
        return sorted(n for n in self.names if self.visible(n, reader, owner))


class OwnerServer(unittest.TestCase):
    extra = ()
    scheme = SCHEME

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='eski-owners-keyspace-')
        self.addCleanup(self.directory.cleanup)
        self.audit = Path(self.directory.name) / 'audit.log'
        arguments = ('--keyspace-threads', str(KEYSPACE_THREADS), '--memcached-port', '0', '--owners', 'yes', '--label-stream-seed', '91',
                     '--label-audit-file', str(self.audit)) + self.scheme + tuple(self.extra)
        self.server = Server(BINARY, workers=0, arguments=arguments)
        self.addCleanup(self.server.close)
        self.server.start()
        self.c = self.connect()
        self.c.call('ACL', 'SETUSER', 'default', *OPERATOR)

    def connect(self, protocol=2):
        client = Client(self.server.port)
        self.addCleanup(client.close)
        if protocol == 3:
            client.call('HELLO', 3)
        return client

    def at(self, label, owner, *arguments, client=None):
        target = client or self.c
        target.send(*prefix(label, owner), *arguments)
        return target.reply()

    def ok(self, label, owner, *arguments):
        value = self.at(label, owner, *arguments)
        if isinstance(value, ServerError):
            raise AssertionError('%r at %s/%r failed: %s' % (arguments, label, owner, value))
        return value

    def refused(self, label, owner, *arguments):
        value = self.at(label, owner, *arguments)
        if not isinstance(value, ServerError):
            raise AssertionError('expected an error from %r at %s/%r, got %r' % (arguments, label, owner, value))
        return str(value)

    top = 'S//A/B'

    def op(self, *arguments):
        return self.ok(self.top, SHARED, *arguments)

    def info(self, section):
        return parse_info(self.op('INFO', section))

    def scan_all(self, label, owner, count=1, client=None):
        names = []
        cursors = []
        cursor = 0
        for _ in range(100000):
            cursor, batch = self.at(label, owner, 'SCAN', cursor, 'COUNT', count, client=client)
            cursors.append(cursor)
            names += batch
            if int(cursor) == 0:
                return names, cursors
        raise AssertionError('scan did not finish')

    def warm_lazy_free(self):
        self.ok('U', 'warm-up', 'SET', 'warm', 1)
        self.op('OWNERS', 'FORGET', 'warm-up')
        last = None
        deadline = time.time() + 5
        while time.time() < deadline:
            memory = self.info('memory')
            now = int(memory['used_memory'])
            if memory.get('lazyfree_pending_objects') == '0' and now == last:
                return
            last = now
            time.sleep(0.05)
        raise AssertionError('lazy free did not settle')

    def owners_info(self, owner):
        value = self.op('OWNERS', 'INFO', owner)
        return dict(zip(value[0::2], value[1::2])) if isinstance(value, list) else value


class Resolution(OwnerServer):
    def test_reads_follow_own_exact_then_shared_exact_then_rank(self):
        self.ok('S', 'u1', 'SET', 'k', 'own-s')
        self.ok('C', SHARED, 'SET', 'k', 'shared-c')
        self.assertEqual(self.ok('C', 'u1', 'GET', 'k'), b'shared-c')
        self.assertEqual(self.ok('S', 'u1', 'GET', 'k'), b'own-s')
        self.assertEqual(self.ok('S', 'u2', 'GET', 'k'), b'shared-c')
        self.ok('C', SHARED, 'SET', 'trusted', 'web')
        self.ok('C;VETTED', SHARED, 'SET', 'trusted', 'vetted')
        self.assertEqual(self.ok('C', 'u1', 'GET', 'trusted'), b'web')
        self.assertEqual(self.ok('C', 'u1', 'LABEL', 'OF', 'trusted'), b'C SHARED')
        self.assertEqual(self.ok('C', SHARED, 'GET', 'trusted'), b'web')
        self.assertEqual(self.ok('S', 'u1', 'GET', 'trusted'), b'vetted')
        self.assertEqual(self.refused('C', 'u1', 'SET', 'trusted', 'mine'), 'INUSE name in use at C SHARED')
        self.ok('C;VETTED', 'u1', 'SET', 'corner', 'own-vetted')
        self.ok('C', SHARED, 'SET', 'corner', 'shared-web')
        self.assertEqual(self.ok('C', 'u1', 'GET', 'corner'), b'shared-web')
        self.assertEqual(self.ok('C;VETTED', 'u1', 'GET', 'corner'), b'own-vetted')
        self.assertEqual(self.ok('S', 'u1', 'GET', 'corner'), b'own-vetted')
        self.assertEqual(self.ok('S', 'u2', 'GET', 'corner'), b'shared-web')
        self.ok('C//A', 'u1', 'SET', 'tie', 'own-a')
        self.ok('C//B', SHARED, 'SET', 'tie', 'shared-b')
        self.assertEqual(self.ok('C//A/B', 'u1', 'GET', 'tie'), b'own-a')
        self.assertEqual(self.ok('C//A/B', 'u2', 'GET', 'tie'), b'shared-b')
        self.ok('C//B', 'u1', 'SET', 'older', 'first')
        self.ok('C//A', 'u1', 'SET', 'older', 'second')
        self.assertEqual(self.ok('C//A/B', 'u1', 'GET', 'older'), b'first')
        self.ok('C//B', 'u1', 'DEL', 'older')
        self.ok('C//B', 'u1', 'SET', 'older', 'third')
        self.assertEqual(self.ok('C//A/B', 'u1', 'GET', 'older'), b'second')

    def test_another_owner_is_exactly_missing(self):
        self.ok('U', 'u1', 'SET', 'secret', 'v')
        self.ok('U', 'u1', 'HSET', 'h', 'f', 'v')
        self.ok('U', 'u1', 'RPUSH', 'l', 'a')
        for command in (('GET', 'secret'), ('HGET', 'h', 'f'), ('LPOP', 'l')):
            self.assertIsNone(self.ok('S', 'u2', *command))
        self.assertEqual(self.ok('S', 'u2', 'EXISTS', 'secret', 'h', 'l'), 0)
        self.assertEqual(self.ok('S', 'u2', 'TYPE', 'h'), 'none')
        self.assertEqual(self.ok('S', 'u2', 'DBSIZE'), 0)
        self.assertEqual(self.ok('S', 'u2', 'KEYS', '*'), [])
        self.assertIsNone(self.ok('S', 'u2', 'RANDOMKEY'))
        self.assertEqual(self.ok('S', SHARED, 'DBSIZE'), 0)
        self.assertEqual(self.ok('U', 'u2', 'SET', 'secret', 'mine'), 'OK')
        self.assertEqual(self.ok('U', 'u2', 'RPUSH', 'h', 'x'), 1)
        self.assertEqual(self.ok('U', 'u1', 'GET', 'secret'), b'v')
        self.assertEqual(self.ok('U', 'u2', 'GET', 'secret'), b'mine')
        self.assertIsNone(self.ok('S', 'u3', 'LABEL', 'OF', 'secret'))
        self.assertEqual(self.ok('S', 'u1', 'LABEL', 'OF', 'secret'), b'U OWNER u1')

    def test_writes_land_exactly_and_inuse_names_the_resolved_copy(self):
        self.ok('U', SHARED, 'SET', 'k', 'shared')
        self.assertEqual(self.refused('U', 'u1', 'SET', 'k', 'v'), 'INUSE name in use at U SHARED')
        self.assertEqual(self.refused('S', 'u1', 'INCR', 'k'), 'INUSE name in use at U SHARED')
        self.ok('C', 'u1', 'SET', 'mine', '1')
        self.assertEqual(self.refused('S', 'u1', 'SET', 'mine', 'v'), 'INUSE name in use at C OWNER u1')
        self.assertEqual(self.refused('S', 'u1', 'DEL', 'mine'), 'INUSE name in use at C OWNER u1')
        self.assertIsNone(self.ok('S', 'u1', 'SET', 'mine', 'v', 'NX'))
        self.assertEqual(self.ok('S', 'u1', 'SETNX', 'k', 'v'), 0)
        self.assertEqual(self.ok('S', 'u1', 'MSETNX', 'k', 'v', 'fresh', 'w'), 0)
        self.assertEqual(self.ok('S', SHARED, 'SET', 'mine', 'shared-s'), 'OK')
        self.assertEqual(self.ok('S', 'u1', 'GET', 'mine'), b'shared-s')
        self.assertEqual(self.ok('C', 'u1', 'GET', 'mine'), b'1')
        self.ok('C', 'u1', 'SET', 'typed', 'x')
        self.assertEqual(self.refused('C', 'u1', 'LPUSH', 'typed', 'y'), WRONGTYPE)
        self.assertEqual(self.refused('S', 'u2', 'SET', 'k', 'v'), 'INUSE name in use at U SHARED')
        self.assertEqual(self.ok('S', SHARED, 'LABEL', 'OF', 'k'), b'U SHARED')

    def test_every_key_family_is_private_per_owner(self):
        for owner in ('u1', 'u2'):
            self.ok('C', owner, 'SET', 's', owner)
            self.ok('C', owner, 'HSET', 'h', 'f', owner)
            self.ok('C', owner, 'RPUSH', 'l', owner)
            self.ok('C', owner, 'SADD', 'set', owner)
            self.ok('C', owner, 'ZADD', 'z', 1, owner)
            self.ok('C', owner, 'XADD', 'x', '1-1', 'f', owner)
            self.ok('C', owner, 'PFADD', 'p', owner, owner + 'b')
            self.ok('C', owner, 'SETBIT', 'b', 3 if owner == 'u1' else 5, 1)
            self.ok('C', owner, 'SET', 'long', owner * 300)
            self.ok('C', owner, 'APPEND', 'grown', owner * 50)
        for owner, other in (('u1', 'u2'), ('u2', 'u1')):
            self.assertEqual(self.ok('C', owner, 'GET', 's'), owner.encode())
            self.assertEqual(self.ok('C', owner, 'HGET', 'h', 'f'), owner.encode())
            self.assertEqual(self.ok('C', owner, 'LRANGE', 'l', 0, -1), [owner.encode()])
            self.assertEqual(self.ok('C', owner, 'SMEMBERS', 'set'), [owner.encode()])
            self.assertEqual(self.ok('C', owner, 'ZRANGE', 'z', 0, -1), [owner.encode()])
            self.assertEqual(self.ok('C', owner, 'XLEN', 'x'), 1)
            self.assertEqual(self.ok('C', owner, 'PFCOUNT', 'p'), 2)
            self.assertEqual(self.ok('C', owner, 'GETBIT', 'b', 3), 1 if owner == 'u1' else 0)
            self.assertEqual(self.ok('C', owner, 'GET', 'long'), (owner * 300).encode())
            self.assertEqual(self.ok('C', owner, 'STRLEN', 'grown'), 100)
            self.assertEqual(self.ok('C', owner, 'DBSIZE'), 10)
        self.assertEqual(self.ok('C', SHARED, 'DBSIZE'), 0)
        self.ok('C', 'u1', 'SET', 'empty', '')
        self.ok('C', 'u1', 'APPEND', 'empty', '')
        self.ok('C', 'u1', 'SETRANGE', 'empty', 0, '')
        self.assertEqual(self.ok('C', 'u1', 'GET', 'empty'), b'')
        self.ok('C', 'u1', 'SET', 'tiny', 'abc', 'EX', 1000)
        self.assertEqual(self.ok('C', 'u1', 'GET', 'tiny'), b'abc')
        self.ok('C', 'u1', 'SET', 'longer-key-name-for-the-heap', 'abcdefghijklmnop', 'PX', 100000)
        self.assertEqual(self.ok('C', 'u1', 'GET', 'longer-key-name-for-the-heap'), b'abcdefghijklmnop')
        self.ok('C', 'u1', 'PERSIST', 'longer-key-name-for-the-heap')
        self.assertEqual(self.ok('C', 'u1', 'TTL', 'longer-key-name-for-the-heap'), -1)

    def test_empty_values_return_their_memory(self):
        self.ok('C', 'u1', 'SET', 'anchor', 'x')
        self.warm_lazy_free()

        def cycle():
            self.ok('C', 'u1', 'SET', 'e1', '')
            self.ok('C', 'u1', 'APPEND', 'e2', '')
            self.ok('C', 'u1', 'SET', 'e3', '')
            self.ok('C', 'u1', 'APPEND', 'e3', '')
            self.ok('C', 'u1', 'APPEND', 'e3', 'abc')
            self.ok('C', 'u1', 'SETRANGE', 'e4', 0, '')
            self.assertEqual([self.ok('C', 'u1', 'GET', k) for k in ('e1', 'e2', 'e3')], [b'', b'', b'abc'])
            self.assertEqual(self.ok('C', 'u1', 'DEL', 'e1', 'e2', 'e3', 'e4'), 3)
        cycle()
        used = int(self.info('memory')['used_memory'])
        owner = self.owners_info('u1')[b'bytes']
        cycle()
        self.assertEqual(int(self.info('memory')['used_memory']), used)
        self.assertEqual(self.owners_info('u1')[b'bytes'], owner)

    def test_timed_keys_of_every_short_length_are_found(self):
        for name, hname in (('a', 'h'), ('abcdefg', 'hashkey'), ('abcdefgh', 'hashkey8')):
            self.assertEqual(self.ok('C', 'u1', 'SET', name, 'v1', 'EX', 1000), 'OK')
            self.assertEqual(self.ok('C', 'u1', 'GET', name), b'v1')
            self.assertGreater(self.ok('C', 'u1', 'TTL', name), 0)
            self.assertEqual(self.ok('C', 'u1', 'EXISTS', name), 1)
            self.assertEqual(self.ok('C', 'u1', 'SET', name, 'v2', 'EX', 1000), 'OK')
            self.assertEqual(self.ok('C', 'u1', 'GET', name), b'v2')
            self.assertEqual(self.ok('C', 'u1', 'DBSIZE'), 1)
            self.assertEqual(self.scan_all('C', 'u1', 1)[0], [name.encode()])
            self.assertEqual(self.ok('C', 'u1', 'DEL', name), 1)
            self.assertEqual(self.ok('C', 'u1', 'EXISTS', name), 0)
            self.assertEqual(self.ok('C', 'u1', 'SET', name, 'p'), 'OK')
            self.assertEqual(self.ok('C', 'u1', 'EXPIRE', name, 100), 1)
            self.assertEqual(self.ok('C', 'u1', 'GET', name), b'p')
            self.assertEqual(self.ok('C', 'u1', 'PERSIST', name), 1)
            self.assertEqual(self.ok('C', 'u1', 'TTL', name), -1)
            self.assertEqual(self.ok('C', 'u1', 'HSET', hname, 'f', 1), 1)
            self.assertEqual(self.ok('C', 'u1', 'EXPIRE', hname, 100), 1)
            self.assertEqual(self.ok('C', 'u1', 'HSET', hname, 'g', 2), 1)
            self.assertEqual(self.ok('C', 'u1', 'HLEN', hname), 2)
            self.assertGreater(self.ok('C', 'u1', 'TTL', hname), 0)
            self.assertEqual(self.ok('C', 'u1', 'DBSIZE'), 2)
            self.assertEqual(sorted(self.scan_all('C', 'u1', 1)[0]), sorted([name.encode(), hname.encode()]))
            self.assertEqual(self.ok('C', 'u1', 'DEL', name, hname), 2)
            self.assertEqual(self.ok('C', 'u1', 'DBSIZE'), 0)
        self.assertEqual(self.owners_info('u1')[b'keys'], 0)

    def test_short_timed_keys_are_found_in_owner_partitions(self):
        for i in range(3):
            self.assertEqual(self.ok('C', 'u1', 'SET', 'tk', 'v%d' % i, 'EX', 1000), 'OK')
        self.assertEqual(self.ok('C', 'u1', 'GET', 'tk'), b'v2')
        self.assertEqual(self.ok('C', 'u1', 'DBSIZE'), 1)
        self.ok('C', 'u1', 'SET', 'p', 'v')
        self.ok('C', 'u1', 'RPUSH', 'l', 'a')
        self.ok('C', 'u1', 'SET', '', 'empty-name')
        for name in ('p', 'l', ''):
            self.assertEqual(self.ok('C', 'u1', 'EXPIRE', name, 100), 1)
            self.assertGreater(self.ok('C', 'u1', 'TTL', name), 0)
        self.assertEqual(self.ok('C', 'u1', 'GET', 'p'), b'v')
        self.assertEqual(self.ok('C', 'u1', 'GET', ''), b'empty-name')
        self.assertEqual(self.ok('C', 'u1', 'LRANGE', 'l', 0, -1), [b'a'])
        self.assertEqual(self.ok('C', 'u1', 'DBSIZE'), 4)
        self.assertIn(b'db0:keys=4,expires=4,', self.ok('C', 'u1', 'INFO', 'keyspace'))
        self.assertEqual(self.ok('C', 'u1', 'PERSIST', 'p'), 1)
        self.assertEqual(self.ok('C', 'u1', 'TTL', 'p'), -1)
        self.assertEqual(self.ok('C', 'u1', 'DEL', 'tk', 'l', ''), 3)
        self.assertEqual(self.owners_info('u1')[b'keys'], 1)
        self.ok('U', SHARED, 'SET', 'tk', 'shared')
        self.assertEqual(self.refused('U', 'u2', 'SET', 'tk', 'mine', 'EX', 1000), 'INUSE name in use at U SHARED')
        self.ok('U', 'u3', 'SET', 'tk3', 'own', 'EX', 1000)
        self.ok('U', SHARED, 'SET', 'tk3', 'shared')
        self.assertEqual(self.ok('U', 'u3', 'GET', 'tk3'), b'own')
        self.assertEqual(sorted(self.ok('U', 'u3', 'KEYS', '*')), [b'tk', b'tk3'])
        self.assertIn(b'db0:keys=2,expires=1,', self.ok('U', 'u3', 'INFO', 'keyspace'))

    def test_counts_and_listings_show_each_name_once(self):
        self.ok('C//A', 'u1', 'SET', 'both', 3)
        self.ok('C', 'u1', 'SET', 'both', 2)
        self.ok('U', SHARED, 'SET', 'both', 1)
        self.ok('C//A', 'u1', 'SET', 'own', 1)
        self.ok('C', SHARED, 'SET', 'shared', 1, 'EX', 1000)
        self.ok('U', 'u1', 'SET', 'timed', 1, 'EX', 1000)
        self.ok('U', SHARED, 'SET', 'timed', 1)
        for i in range(30):
            self.ok('U', 'u2', 'SET', 'other%d' % i, i)
        expected = sorted([b'both', b'own', b'shared', b'timed'])
        self.assertEqual(self.ok('C//A', 'u1', 'DBSIZE'), 4)
        self.assertEqual(sorted(self.ok('C//A', 'u1', 'KEYS', '*')), expected)
        names, _ = self.scan_all('C//A', 'u1')
        self.assertEqual(sorted(set(names)), expected)
        self.assertIn(b'db0:keys=4,expires=2,', self.ok('C//A', 'u1', 'INFO', 'keyspace'))
        self.assertEqual(self.ok('C//A', SHARED, 'DBSIZE'), 3)
        self.assertEqual(self.ok('U', 'u1', 'DBSIZE'), 2)
        self.assertEqual(self.ok('U', 'u2', 'DBSIZE'), 32)
        self.assertEqual(self.ok('C//A', 'u1', 'DBSIZE'), 4)
        self.ok('U', SHARED, 'DEL', 'both')
        self.assertEqual(self.ok('C//A', 'u1', 'DBSIZE'), 4)
        self.ok('C', 'u1', 'DEL', 'both')
        self.ok('C//A', 'u1', 'DEL', 'both')
        self.assertEqual(self.ok('C//A', 'u1', 'DBSIZE'), 3)
        self.assertIn(b'db0:keys=3,expires=2,', self.ok('C//A', 'u1', 'INFO', 'keyspace'))

    def test_keyspace_info_resolves_expiry_across_scopes(self):
        self.c.call('SELECT', 2)
        self.ok('C//A', 'u1', 'SET', 'x', 1)
        self.ok('C', SHARED, 'SET', 'x', 1)
        self.ok('C', SHARED, 'SET', 'y', 1)
        self.assertIn(b'db2:keys=2,expires=0,', self.ok('C//A', 'u1', 'INFO', 'keyspace'))
        self.ok('C', SHARED, 'EXPIRE', 'x', 1000)
        self.assertIn(b'db2:keys=2,expires=0,', self.ok('C//A', 'u1', 'INFO', 'keyspace'))
        self.assertIn(b'db2:keys=2,expires=1,', self.ok('C', 'u1', 'INFO', 'keyspace'))
        self.ok('C', SHARED, 'PERSIST', 'x')
        self.ok('C//A', 'u1', 'EXPIRE', 'x', 1000)
        self.assertIn(b'db2:keys=2,expires=1,', self.ok('C//A', 'u1', 'INFO', 'keyspace'))
        self.assertIn(b'db2:keys=2,expires=0,', self.ok('C', 'u1', 'INFO', 'keyspace'))
        self.ok('C', SHARED, 'EXPIRE', 'x', 1000)
        self.ok('C//B', 'u1', 'SET', 'z', 1, 'EX', 1000)
        self.ok('C', SHARED, 'SET', 'z', 1)
        self.assertIn(b'db2:keys=3,expires=1,', self.ok('C//A', 'u1', 'INFO', 'keyspace'))
        self.assertIn(b'db2:keys=3,expires=2,', self.ok('C//A/B', 'u1', 'INFO', 'keyspace'))
        self.assertIn(b'db2:keys=3,expires=1,', self.ok('C', 'u1', 'INFO', 'keyspace'))
        self.assertEqual([self.ok(label, 'u1', 'DBSIZE') for label in ('C', 'C//A', 'C//B', 'C//A/B')], [3, 3, 3, 3])

    def test_scan_cursor_has_a_phase_bit_for_users_only(self):
        for i in range(40):
            self.ok('U', SHARED, 'SET', 's%d' % i, i)
            self.ok('U', 'u1', 'SET', 'o%d' % i, i)
        seen = set()
        phases = set()
        cursor = 0
        while True:
            cursor, batch = self.ok('U', 'u1', 'SCAN', cursor, 'COUNT', 5)
            value = int(cursor)
            self.assertLess(value, 1 << 63)
            seen.update(batch)
            if value:
                phases.add(value & 1)
            if value == 0:
                break
        self.assertEqual(len(seen), 80)
        self.assertEqual(phases, {0, 1})
        shared_cursors = []
        cursor = 0
        while True:
            cursor, batch = self.ok('U', SHARED, 'SCAN', cursor, 'COUNT', 5)
            shared_cursors.append(int(cursor))
            if int(cursor) == 0:
                break
        self.assertTrue(all(c < 1 << 63 for c in shared_cursors), shared_cursors)
        self.assertEqual(shared_cursors[-1], 0)

    def test_scan_never_misses_across_release_and_forget(self):
        for i in range(60):
            self.ok('U', SHARED, 'SET', 'keep%d' % i, i)
            self.ok('C', 'u1', 'SET', 'mine%d' % i, i)
            self.ok('U', 'u1', 'SET', 'gone%d' % i, i)
        names = []
        cursor = 0
        step = 0
        while True:
            cursor, batch = self.ok('C', 'u1', 'SCAN', cursor, 'COUNT', 3)
            self.assertLess(int(cursor), 1 << 63)
            names += batch
            step += 1
            if step == 5:
                for i in range(60):
                    self.ok('U', 'u1', 'DEL', 'gone%d' % i)
            if step == 9:
                self.ok('S', 'u1', 'SET', 'late', 1)
                self.ok('S', 'u2', 'SET', 'mine0', 'hidden')
            if int(cursor) == 0:
                break
        found = set(names)
        for i in range(60):
            self.assertIn(b'keep%d' % i, found)
            self.assertIn(b'mine%d' % i, found)
        names = []
        cursor = 0
        step = 0
        while True:
            cursor, batch = self.ok('C', 'u1', 'SCAN', cursor, 'COUNT', 3)
            self.assertLess(int(cursor), 1 << 63)
            names += batch
            step += 1
            if step == 4:
                self.op('OWNERS', 'FORGET', 'u1')
            if int(cursor) == 0:
                break
        found = set(names)
        for i in range(60):
            self.assertIn(b'keep%d' % i, found)

    CRAFTED_CURSORS = (0, 1, 1 << 48, (1 << 48) | 1, 2 << 48, (2 << 48) | 1, 3 << 48)

    def scan_replies(self, label, owner):
        out = []
        for count in (1, 1000):
            cursor = 0
            for _ in range(10000):
                reply = self.at(label, owner, 'SCAN', cursor, 'COUNT', count)
                out.append((count, cursor, reply))
                cursor = int(reply[0])
                if cursor == 0:
                    break
        return out

    def assert_scan_twins(self, label, plain, hidden):
        replies = self.scan_replies(label, plain)
        self.assertEqual(replies, self.scan_replies(label, hidden))
        cursors = sorted({int(r[2][0]) for r in replies} | set(self.CRAFTED_CURSORS))
        for cursor in cursors:
            for count in (1, 1000):
                self.assertEqual(self.at(label, plain, 'SCAN', cursor, 'COUNT', count),
                                 self.at(label, hidden, 'SCAN', cursor, 'COUNT', count), (cursor, count))
        return replies

    def test_scan_cursor_space_ignores_hidden_history(self):
        self.ok('U', SHARED, 'SET', 'pub', 1)
        self.ok('C', SHARED, 'SET', 'pub2', 1)
        self.ok('S', 'u2', 'SET', 'h', 1)
        for owner in ('u1', 'u2'):
            self.ok('C', owner, 'SET', 'a', 1)
            self.ok('U', owner, 'SET', 'b', 1)
            self.ok('U', owner, 'DEL', 'b')
            self.ok('C', owner, 'DEL', 'a')
            for i in range(5):
                self.ok('U', owner, 'SET', 'c%d' % i, i)
        replies = self.assert_scan_twins('C', 'u1', 'u2')
        names = {n for r in replies for n in r[2][1]}
        self.assertEqual(names, {b'c%d' % i for i in range(5)} | {b'pub', b'pub2'})
        self.assertEqual(self.at('C', 'u1', 'SCAN', 1 << 48, 'COUNT', 1000), self.at('C', 'u2', 'SCAN', 1 << 48, 'COUNT', 1000))

    def test_scan_cursor_space_ignores_hidden_removal(self):
        self.ok('U', SHARED, 'SET', 'pub', 1)
        steps = [
            ([('C', 'SET', 'a', 1)], [('S', 'SET', 'h', 1)]),
            ([('C', 'DEL', 'a')], []),
            ([('U', 'SET', 'x', 1), ('U', 'SET', 'x2', 1)], []),
            ([], [('S', 'DEL', 'h')]),
            ([('C', 'SET', 'a', 1)], []),
            ([('U', 'DEL', 'x', 'x2'), ('C', 'DEL', 'a')], [('S', 'SET', 'h2', 1)]),
            ([('U', 'SET', 'y', 1)], [('S', 'DEL', 'h2')]),
            ([('C', 'SET', 'z', 1)], []),
        ]
        for visible, hidden in steps:
            for label, *command in hidden:
                self.ok(label, 'u2', *command)
            for owner in ('u1', 'u2'):
                for label, *command in visible:
                    self.ok(label, owner, *command)
            self.assert_scan_twins('C', 'u1', 'u2')
            self.assert_scan_twins('U', 'u1', 'u2')

    def test_scan_cursor_space_ignores_a_late_hidden_write(self):
        self.ok('C', SHARED, 'SET', 'pub', 1)
        for owner in ('u1', 'u2'):
            self.ok('C', owner, 'SET', 'a', 1)
            self.ok('U', owner, 'SET', 'b', 1)
        self.ok('S//A/B', 'u2', 'SET', 'h', 1)
        for owner in ('u1', 'u2'):
            self.ok('U', owner, 'DEL', 'b')
            self.ok('C', owner, 'DEL', 'a')
            self.ok('U', owner, 'SET', 'c', 1)
        self.assert_scan_twins('C', 'u1', 'u2')
        self.ok('S//A/B', 'u2', 'DEL', 'h')
        self.assert_scan_twins('C', 'u1', 'u2')

    def test_retained_cursor_space_is_counted_and_forgotten(self):
        self.ok('C', 'u5', 'SET', 'k', 1)
        self.ok('C', 'u5', 'DEL', 'k')
        self.ok('C', 'u6', 'GET', 'k')
        five, six = self.owners_info('u5'), self.owners_info('u6')
        self.assertEqual((five[b'keys'], five[b'partitions'], six[b'keys']), (0, 0, 0))
        self.assertGreater(five[b'bytes'], six[b'bytes'])
        self.assertEqual(self.info('owners')['owners_holding_data'], '0')
        self.assertEqual(self.op('OWNERS', 'LIST', 0), [b'0', []])
        reply = self.op('OWNERS', 'FORGET', 'u5')
        self.assertEqual(dict(zip(reply[0::2], reply[1::2]))[b'bytes'], five[b'bytes'])
        self.ok('C', 'u5', 'GET', 'k')
        self.assertEqual(self.owners_info('u5')[b'bytes'], six[b'bytes'])

    def test_scan_cursors_and_counts_ignore_other_owners(self):
        for i in range(25):
            self.ok('C', SHARED, 'SET', 'sh%d' % i, i)
            self.ok('C', 'u1', 'SET', 'me%d' % i, i)
        before = [self.scan_all('C', 'u1', 2), self.scan_all('C', SHARED, 2), self.ok('C', 'u1', 'DBSIZE'),
                  sorted(self.ok('C', 'u1', 'KEYS', '*')), self.ok('C', 'u1', 'INFO', 'keyspace')]
        for owner in ('u2', 'u3'):
            for label in ('S', 'C//A', 'C', 'U'):
                for i in range(25):
                    self.ok(label, owner, 'SET', 'me%d' % i, owner)
                    self.ok(label, owner, 'HSET', 'x%d' % i, 'f', 1)
                    if label == 'U':
                        self.ok(label, owner, 'SET', 'sh%d' % i, owner)
                    else:
                        self.assertEqual(self.refused(label, owner, 'SET', 'sh%d' % i, owner), 'INUSE name in use at C SHARED')
        self.ok('C', 'u2', 'FLUSHDB')
        self.op('OWNERS', 'FORGET', 'u3')
        after = [self.scan_all('C', 'u1', 2), self.scan_all('C', SHARED, 2), self.ok('C', 'u1', 'DBSIZE'),
                 sorted(self.ok('C', 'u1', 'KEYS', '*')), self.ok('C', 'u1', 'INFO', 'keyspace')]
        self.assertEqual(before, after)
        self.ok('C', SHARED, 'SET', 'new', 1)
        self.assertNotEqual(before[2], self.ok('C', 'u1', 'DBSIZE'))

    def test_randomkey_is_uniform_over_visible_names(self):
        names = ['own%d' % i for i in range(6)] + ['shared%d' % i for i in range(6)]
        for i in range(3):
            self.ok('U', 'u1', 'SET', 'shared%d' % i, 'own copy')
        for i in range(6):
            self.ok('C', 'u1', 'SET', 'own%d' % i, i)
            self.ok('U', SHARED, 'SET', 'shared%d' % i, i)
        for i in range(40):
            self.ok('C', 'u2', 'SET', 'hidden%d' % i, i)
        counts = dict.fromkeys(names, 0)
        draws = 2400
        for _ in range(draws):
            name = self.ok('C', 'u1', 'RANDOMKEY').decode()
            self.assertIn(name, counts)
            counts[name] += 1
        expected = draws / len(names)
        chi = sum((v - expected) ** 2 / expected for v in counts.values())
        self.assertLess(chi, 31.3, counts)

    def test_random_draws_come_from_the_owner_scope_stream(self):
        def draws(owner):
            return [self.ok('C', owner, 'SRANDMEMBER', 'pool', 3) for _ in range(20)]
        for owner in ('u1', 'u2'):
            for i in range(40):
                self.ok('C', owner, 'SADD', 'pool', i)
        first = draws('u1')
        self.op('OWNERS', 'FORGET', 'u1')
        for i in range(40):
            self.ok('C', 'u1', 'SADD', 'pool', i)
        draws('u2')
        second = draws('u1')
        self.assertEqual(first, second)

    def test_commands_that_draw_nothing_allocate_no_stream(self):
        self.ok('C', 'u1', 'SET', 'k', 1)
        self.ok('C', 'u1', 'SADD', 's', *range(20))
        self.ok('C', 'u1', 'VADD', 'v', 'VALUES', 2, 0.5, 0.5, 'e')
        self.ok('C', 'u1', 'SRANDMEMBER', 's')
        self.warm_lazy_free()
        used = int(self.info('memory')['used_memory'])
        owner = self.owners_info('u1')[b'bytes']
        for label in ('U', 'S', 'C//A', 'C//B', 'S//A/B', 'C;VETTED'):
            for command in (('GET', 'k'), ('EXISTS', 'k'), ('DBSIZE',), ('SCAN', 0), ('KEYS', '*'), ('TYPE', 's'), ('SMEMBERS', 's'),
                            ('VCARD', 'v'), ('VSIM', 'v', 'VALUES', 2, 0.5, 0.5), ('VEMB', 'v', 'e'), ('LABEL', 'OF', 'k'), ('INFO', 'keyspace')):
                self.at(label, 'u1', *command)
            self.at(label, 'u9', 'GET', 'k')
        self.assertEqual(self.owners_info('u1')[b'bytes'], owner)
        nine = self.owners_info('u9')[b'bytes']
        self.assertLessEqual(int(self.info('memory')['used_memory']) - used, nine)
        first = self.ok('S', 'u1', 'SRANDMEMBER', 's', -5)
        self.assertGreater(self.owners_info('u1')[b'bytes'], owner)
        grown = self.owners_info('u1')[b'bytes']
        self.ok('S', 'u1', 'GET', 'k')
        self.assertEqual(self.owners_info('u1')[b'bytes'], grown)
        self.op('OWNERS', 'FORGET', 'u1')
        self.ok('C', 'u1', 'SADD', 's', *range(20))
        self.ok('S', 'u1', 'SCAN', 0)
        self.assertEqual(self.ok('S', 'u1', 'SRANDMEMBER', 's', -5), first)

    def test_flush_follows_the_scope_rules(self):
        self.op('ACL', 'SETUSER', 'plain', *OPERATOR[:-1])
        self.op('ACL', 'SETUSER', 'root', 'on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*', 'owner-operator')
        self.op('ACL', 'SETUSER', 'sharer', 'on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*')
        logins = {}
        for name in ('plain', 'root', 'sharer'):
            logins[name] = self.connect()
            logins[name].call('AUTH', name, 'x')
        plain, root, sharer = logins['plain'], logins['root'], logins['sharer']

        def fill():
            self.ok('U', SHARED, 'SET', 'su', 1)
            self.ok('C', SHARED, 'SET', 'sc', 1)
            self.ok('U', 'u1', 'SET', 'u1u', 1)
            self.ok('C', 'u1', 'SET', 'u1c', 1)
            self.ok('C', 'u2', 'SET', 'u2c', 1)
            self.c.call('SELECT', 1)
            self.ok('C', 'u1', 'SET', 'db1', 1)
            self.ok('C', 'u2', 'SET', 'db1', 2)
            self.ok('C', SHARED, 'SET', 'd1s', 1)
            self.c.call('SELECT', 0)

        def alive():
            out = set()
            for db in (0, 1):
                self.c.call('SELECT', db)
                for owner in (SHARED, 'u1', 'u2'):
                    for name in self.ok(self.top, owner, 'KEYS', '*'):
                        out.add((db, name.decode(), self.ok(self.top, owner, 'LABEL', 'OF', name).decode()))
            self.c.call('SELECT', 0)
            return out

        def watch(label, owner, key):
            client = self.connect()
            self.assertEqual(self.at(label, owner, 'WATCH', key, client=client), 'OK')
            return client, label, owner, key

        def aborted(w):
            client, label, owner, key = w
            self.at(label, owner, 'MULTI', client=client)
            self.at(label, owner, 'GET', key, client=client)
            return self.at(label, owner, 'EXEC', client=client) is None

        def flushed(client, command, scopes=('u1c', 'u2c', 'sc')):
            fill()
            watchers = [watch('C', 'u1', 'u1c'), watch('C', 'u2', 'u2c'), watch('C', SHARED, 'sc')]
            tracker = self.connect(3)
            pinned(tracker, 'C', 'u2', 'CLIENT', 'TRACKING', 'ON')
            self.at('C', 'u2', 'GET', 'u2c', client=tracker)
            client.send(*command)
            self.assertEqual(client.reply(), 'OK', command)
            tracker.call(*prefix('C', 'u2'), 'PING')
            invalidated = any(p[0] == b'invalidate' for p in tracker.pushes)
            marks = {name for w, name in zip(watchers, scopes) if aborted(w)}
            return full - alive(), marks, invalidated

        u1_all = {(0, 'u1u', 'U OWNER u1'), (0, 'u1c', 'C OWNER u1'), (1, 'db1', 'C OWNER u1')}
        u2_all = {(0, 'u2c', 'C OWNER u2'), (1, 'db1', 'C OWNER u2')}
        shared_all = {(0, 'su', 'U SHARED'), (0, 'sc', 'C SHARED'), (1, 'd1s', 'C SHARED')}
        db0 = lambda entries: {e for e in entries if e[0] == 0}
        fill()
        full = alive()
        self.assertEqual(full, u1_all | u2_all | shared_all)
        self.assertEqual(flushed(self.c, prefix('C', 'u1') + ('FLUSHDB',)), ({(0, 'u1c', 'C OWNER u1')}, {'u1c'}, False))
        self.assertEqual(flushed(plain, prefix('C', 'u1') + ('FLUSHALL',)), ({(0, 'u1c', 'C OWNER u1'), (1, 'db1', 'C OWNER u1')}, {'u1c'}, False))
        self.assertEqual(flushed(plain, prefix('C', SHARED) + ('FLUSHALL',)), ({(0, 'sc', 'C SHARED'), (1, 'd1s', 'C SHARED')}, {'sc'}, True))
        self.assertEqual(flushed(plain, prefix(self.top, 'u1') + ('FLUSHALL',)), (u1_all, {'u1c'}, False))
        self.assertEqual(flushed(plain, prefix(self.top + ';WEB', 'u1') + ('FLUSHDB',)), (db0(u1_all), {'u1c'}, False))
        self.assertEqual(flushed(plain, prefix(self.top, SHARED) + ('FLUSHDB',)), (db0(shared_all), {'sc'}, True))
        self.assertEqual(flushed(plain, prefix(self.top, SHARED) + ('FLUSHALL',)), (shared_all, {'sc'}, True))
        self.assertEqual(flushed(self.c, prefix(self.top, 'u2') + ('FLUSHALL',)), (u2_all, {'u2c'}, True))
        self.assertEqual(flushed(self.c, prefix(self.top, SHARED) + ('FLUSHDB',)), (db0(shared_all), {'sc'}, True))
        self.assertEqual(flushed(self.c, prefix(self.top, SHARED) + ('FLUSHALL',)), (shared_all, {'sc'}, True))
        self.assertEqual(flushed(root, prefix(self.top, SHARED) + ('FLUSHALL',)), (shared_all, {'sc'}, True))
        self.assertEqual(flushed(sharer, ('LABEL', 'AS', self.top, 'FLUSHALL')), (shared_all, {'sc'}, True))
        self.assertEqual(flushed(sharer, ('FLUSHALL',)), (shared_all, {'sc'}, True))
        self.assertEqual(flushed(root, ('LABEL', 'AS', 'C', 'FLUSHALL')), ({(0, 'sc', 'C SHARED'), (1, 'd1s', 'C SHARED')}, {'sc'}, True))
        self.assertEqual(flushed(root, ('LABEL', 'AS', self.top, 'FLUSHDB')), (db0(full), {'u1c', 'u2c', 'sc'}, True))
        self.assertEqual(self.owners_info('u2')[b'keys'], 1)
        self.assertEqual(flushed(root, ('FLUSHALL',)), (full, {'u1c', 'u2c', 'sc'}, True))
        self.assertEqual(self.owners_info('u2')[b'keys'], 0)
        self.assertEqual(self.info('owners').get('owner_partitions'), '0')
        self.c.send('FLUSHALL')
        self.assertEqual(str(self.c.reply()), 'ERR this login must name an owner with every command')
        for command, expected in (((), full), ((prefix(self.top, SHARED)), shared_all)):
            fill()
            root.call(*command, 'MULTI')
            self.assertEqual(root.call(*command, 'FLUSHALL'), 'QUEUED')
            self.assertEqual(root.call(*command, 'EXEC'), ['OK'])
            self.assertEqual(full - alive(), expected)
        fill()
        root.call('MULTI')
        self.assertEqual(root.call(*prefix(self.top, SHARED), 'FLUSHALL'), 'QUEUED')
        self.assertEqual(root.call('EXEC'), ['OK'])
        self.assertEqual(full - alive(), shared_all)

    def test_move_copy_and_rename_stay_with_the_owner(self):
        self.ok('C', 'u1', 'SET', 'k', 'v')
        self.assertEqual(self.ok('C', 'u1', 'MOVE', 'k', 1), 1)
        self.c.call('SELECT', 1)
        self.assertEqual(self.ok('C', 'u1', 'GET', 'k'), b'v')
        self.assertIsNone(self.ok('C', 'u2', 'GET', 'k'))
        self.assertIsNone(self.ok('C', SHARED, 'GET', 'k'))
        self.assertEqual(self.ok('C', 'u1', 'RENAME', 'k', 'k2'), 'OK')
        self.assertEqual(self.ok('C', 'u1', 'COPY', 'k2', 'k3', 'DB', 0), 1)
        self.c.call('SELECT', 0)
        self.assertEqual(self.ok('C', 'u1', 'GET', 'k3'), b'v')
        self.assertIsNone(self.ok('C', 'u2', 'GET', 'k3'))
        self.ok('U', SHARED, 'SET', 'pub', 'shared')
        self.assertEqual(self.ok('C', 'u1', 'COPY', 'pub', 'mine'), 1)
        self.assertEqual(self.ok('C', 'u1', 'LABEL', 'OF', 'mine'), b'C OWNER u1')
        self.ok('C', 'u2', 'SET', 'theirs', 'x')
        self.assertEqual(self.ok('C', 'u1', 'COPY', 'theirs', 'got'), 0)
        self.assertEqual(self.refused('C', 'u1', 'RENAME', 'pub', 'p2'), 'INUSE name in use at U SHARED')
        self.assertEqual(self.refused('C', 'u1', 'MOVE', 'pub', 1), 'INUSE name in use at U SHARED')
        self.assertEqual(self.ok('C', 'u2', 'MOVE', 'k3', 1), 0)
        self.assertEqual(self.ok('C', 'u1', 'GET', 'k3'), b'v')

    def test_swapdb_moves_the_owner_directories(self):
        self.ok('C', 'u1', 'SET', 'k', 'zero')
        self.c.call('SELECT', 1)
        self.ok('C', 'u1', 'SET', 'k', 'one')
        self.c.call('SELECT', 0)
        self.assertEqual(self.refused('C', 'u1', 'SWAPDB', 0, 1), TOP_ERROR)
        self.op('SWAPDB', 0, 1)
        self.assertEqual(self.ok('C', 'u1', 'GET', 'k'), b'one')
        self.c.call('SELECT', 1)
        self.assertEqual(self.ok('C', 'u1', 'GET', 'k'), b'zero')
        self.ok('C', 'u1', 'DEL', 'k')
        self.c.call('SELECT', 0)
        self.assertEqual(self.ok('C', 'u1', 'DBSIZE'), 1)

    def test_debug_digest_covers_owner_data(self):
        empty = self.op('DEBUG', 'DIGEST')
        self.ok('C', 'u1', 'SET', 'k', 'v')
        one = self.op('DEBUG', 'DIGEST')
        self.assertNotEqual(empty, one)
        self.ok('C', 'u2', 'SET', 'k', 'v')
        self.assertNotEqual(one, self.op('DEBUG', 'DIGEST'))
        self.op('OWNERS', 'FORGET', 'u2')
        self.assertEqual(one, self.op('DEBUG', 'DIGEST'))
        self.ok('C', 'u2', 'SET', 'k', 'other')
        mine = self.op('DEBUG', 'DIGEST-VALUE', 'k')
        self.assertEqual(mine, ['0' * 40])
        self.assertNotEqual(self.ok(self.top, 'u2', 'DEBUG', 'DIGEST-VALUE', 'k'), ['0' * 40])
        self.assertNotEqual(self.ok(self.top, 'u2', 'DEBUG', 'DIGEST-VALUE', 'k'), self.ok(self.top, 'u1', 'DEBUG', 'DIGEST-VALUE', 'k'))


class Maintenance(OwnerServer):
    extra = ('--hz', '50')

    def test_owner_keys_expire_actively(self):
        for i in range(200):
            self.ok('C', 'u%d' % (i % 20), 'SET', 'k%d' % i, i, 'PX', 50)
        self.ok('C', 'u1', 'SET', 'stay', 1)
        deadline = time.time() + 5
        while time.time() < deadline and int(self.info('owners').get('owner_partitions', '0')) > 1:
            time.sleep(0.05)
        self.assertEqual(self.info('owners').get('owner_partitions'), '1')
        self.assertEqual(self.owners_info('u1')[b'keys'], 1)

    def test_owner_hash_fields_expire_actively(self):
        self.ok('C', 'u1', 'HSET', 'h', 'f', 1, 'g', 2)
        self.ok('C', 'u1', 'HPEXPIRE', 'h', 50, 'FIELDS', 1, 'f')
        self.ok('C', 'u2', 'HSET', 'h2', 'f', 1)
        self.ok('C', 'u2', 'HPEXPIRE', 'h2', 50, 'FIELDS', 1, 'f')
        time.sleep(0.6)
        self.assertEqual(self.owners_info('u2')[b'keys'], 0)
        self.assertEqual(self.owners_info('u1')[b'keys'], 1)
        self.assertEqual(self.ok('C', 'u1', 'HLEN', 'h'), 1)

    def test_global_eviction_reaches_owner_keys(self):
        self.op('CONFIG', 'SET', 'maxmemory-policy', 'allkeys-random')
        for i in range(300):
            self.ok('C', 'u%d' % (i % 30), 'SET', 'key%d' % i, 'v' * 200)
        used = int(self.info('memory')['used_memory'])
        self.op('CONFIG', 'SET', 'maxmemory', used - 20000)
        self.ok('C', SHARED, 'SET', 'trigger', 1)
        self.op('CONFIG', 'SET', 'maxmemory', 0)
        total = sum(self.owners_info('u%d' % i)[b'keys'] for i in range(30))
        self.assertLess(total, 300)
        self.assertGreater(int(self.info('stats')['evicted_keys']), 0)


class Quotas(OwnerServer):
    def test_owner_quota_evicts_inside_the_owner_then_refuses(self):
        self.op('CONFIG', 'SET', 'maxmemory-policy', 'allkeys-lru')
        for i in range(50):
            self.ok('C', 'u2', 'SET', 'n%d' % i, 'x' * 100)
            self.ok('C', SHARED, 'SET', 's%d' % i, 'x' * 100)
        for i in range(50):
            self.ok('C', 'u1', 'SET', 'n%d' % i, 'x' * 100)
        used = self.owners_info('u1')[b'bytes']
        self.assertEqual(self.op('OWNERS', 'QUOTA', 'u1', 'LIMIT', used // 2), 'OK')
        self.assertEqual(self.op('OWNERS', 'QUOTA', 'u1')[0], used // 2)
        self.ok('C', 'u1', 'SET', 'more', 'y')
        self.assertLessEqual(self.owners_info('u1')[b'bytes'], used // 2 + 400)
        self.assertLess(self.owners_info('u1')[b'keys'], 50)
        self.assertEqual(self.owners_info('u2')[b'keys'], 50)
        self.assertEqual(self.ok('C', SHARED, 'DBSIZE'), 50)
        self.op('CONFIG', 'SET', 'maxmemory-policy', 'noeviction')
        self.op('OWNERS', 'QUOTA', 'u1', 'LIMIT', 100)
        self.assertEqual(self.refused('C', 'u1', 'SET', 'again', 'y'), QUOTA_OOM)
        self.assertEqual(self.ok('C', 'u1', 'GET', 'more'), b'y')
        self.assertEqual(self.ok('C', 'u1', 'DEL', 'more'), 1)
        self.op('OWNERS', 'QUOTA', 'u1', 'LIMIT', 0)
        self.assertEqual(self.ok('C', 'u1', 'SET', 'again', 'y'), 'OK')

    def test_default_quota_applies_to_owners_without_their_own(self):
        self.op('CONFIG', 'SET', 'owner-quota-default', 3000)
        self.assertEqual(self.op('OWNERS', 'QUOTA', 'u9'), [3000, 0])
        self.ok('C', 'u9', 'SET', 'first', 'y')
        for i in range(60):
            self.at('C', 'u9', 'SET', 'n%d' % i, 'z' * 64)
        self.assertEqual(self.refused('C', 'u9', 'SET', 'last', 'z'), QUOTA_OOM)
        self.assertEqual(self.ok('C', 'u8', 'SET', 'first', 'y'), 'OK')
        self.op('OWNERS', 'QUOTA', 'u9', 'LIMIT', 1 << 30)
        self.assertEqual(self.ok('C', 'u9', 'SET', 'last', 'z'), 'OK')

    def test_label_quota_counts_shared_data_only(self):
        self.op('CONFIG', 'SET', 'maxmemory-policy', 'allkeys-random')
        for i in range(40):
            self.ok('C', 'u1', 'SET', 'big%d' % i, 'x' * 500)
        self.ok('C', SHARED, 'SET', 'seed', 1)
        base = self.op('LABEL', 'QUOTA', 'C')[1]
        self.assertLess(base, 40 * 500)
        limit = base + 8000
        self.op('LABEL', 'QUOTA', 'C', 'LIMIT', limit)
        for i in range(40):
            self.ok('C', SHARED, 'SET', 'shared%d' % i, 'x' * 500)
        self.assertLess(self.ok('C', SHARED, 'DBSIZE'), 30)
        self.assertEqual(self.owners_info('u1')[b'keys'], 40)
        self.assertEqual(self.ok('C', 'u1', 'SET', 'more', 'x' * 500), 'OK')
        self.assertEqual(self.owners_info('u1')[b'keys'], 41)
        used = self.op('LABEL', 'QUOTA', 'C')[1]
        self.assertLessEqual(used, limit + 2048)

    def test_owner_entries_count_in_memory_and_in_quota_use(self):
        self.warm_lazy_free()
        before = int(self.info('memory')['used_memory'])
        for i in range(200):
            self.assertIsNone(self.ok('C', 'reader%d' % i, 'GET', 'missing'))
        after = int(self.info('memory')['used_memory'])
        entries = [self.owners_info('reader%d' % i)[b'bytes'] for i in range(200)]
        self.assertGreater(entries[0], 100)
        self.assertEqual(entries[100] - entries[10], 1)
        self.assertEqual(entries[10] - entries[0], 1)
        self.assertGreaterEqual(after - before, sum(entries))
        self.assertLessEqual(after - before, sum(entries) + 16384)
        self.assertEqual(self.op('OWNERS', 'QUOTA', 'reader0'), [0, entries[0]])
        self.assertGreaterEqual(int(self.info('owners')['owner_bytes']), sum(entries))
        self.assertEqual(self.info('owners')['owners_holding_data'], '0')
        self.op('OWNERS', 'QUOTA', 'reader0', 'LIMIT', entries[0] - 1)
        self.assertEqual(self.refused('C', 'reader0', 'SET', 'k', 'v'), QUOTA_OOM)
        for i in range(200):
            self.op('OWNERS', 'FORGET', 'reader%d' % i)
        spare = int(self.info('memory')['used_memory']) - before
        self.assertLessEqual(spare, 32768)
        self.assertEqual(self.info('owners')['owner_bytes'], '0')
        for i in range(200):
            self.ok('C', 'again%d' % i, 'GET', 'missing')
        for i in range(200):
            self.op('OWNERS', 'FORGET', 'again%d' % i)
        self.assertEqual(int(self.info('memory')['used_memory']) - before, spare)

    def test_partition_limit_counts_owner_partitions(self):
        self.op('CONFIG', 'SET', 'owner-partitions-max', 2)
        self.ok('C', 'u1', 'SET', 'a', 1)
        self.ok('U', 'u1', 'SET', 'b', 1)
        self.assertEqual(self.refused('S', 'u1', 'SET', 'c', 1), PARTITION_LIMIT)
        self.assertEqual(self.refused('C', 'u2', 'SET', 'c', 1), PARTITION_LIMIT)
        self.assertIsNone(self.ok('C', 'u2', 'GET', 'c'))
        self.assertEqual(self.ok('C', 'u1', 'SET', 'a2', 1), 'OK')
        self.ok('C', 'u1', 'DEL', 'a', 'a2')
        self.assertEqual(self.ok('C', 'u2', 'SET', 'c', 1), 'OK')
        self.assertEqual(self.ok('U', SHARED, 'SET', 'shared', 1), 'OK')


class Forget(OwnerServer):
    def test_forget_removes_every_copy_of_the_owner_and_nothing_else(self):
        self.ok('U', SHARED, 'SET', 'pub', 1)
        for label in ('U', 'C', 'S//A'):
            self.ok(label, 'u1', 'SET', 'k-' + label, 'v')
            self.ok(label, 'u1', 'HSET', 'h-' + label, 'f', 'v' * 100)
            self.ok(label, 'u2', 'SET', 'k-' + label, 'w')
        self.c.call('SELECT', 3)
        self.ok('C', 'u1', 'RPUSH', 'list', *range(100))
        self.c.call('SELECT', 0)
        self.warm_lazy_free()
        baseline_used = int(self.info('memory')['used_memory'])
        before = self.owners_info('u1')
        self.assertEqual(before[b'keys'], 7)
        self.assertEqual(before[b'partitions'], 4)
        self.assertEqual(before[b'labels'], 3)
        reply = self.op('OWNERS', 'FORGET', 'u1')
        result = dict(zip(reply[0::2], reply[1::2]))
        self.assertEqual(result[b'keys'], 7)
        self.assertEqual(result[b'bytes'], before[b'bytes'])
        self.assertEqual(self.owners_info('u1')[b'keys'], 0)
        self.assertEqual(self.ok('S//A', 'u2', 'DBSIZE'), 4)
        self.assertEqual(self.ok('S//A', 'u1', 'DBSIZE'), 1)
        self.assertEqual(self.ok('U', SHARED, 'GET', 'pub'), b'1')
        self.assertLess(int(self.info('memory')['used_memory']), baseline_used)
        self.assertEqual(self.info('owners').get('owners_holding_data'), '1')
        text = self.audit.read_text()
        self.assertIn('owner-forget', text)

    def test_owners_list_names_the_owners_holding_data(self):
        self.ok('C', 'u1', 'SET', 'k', 1)
        self.ok('C', 'u2', 'VADD', 'v', 'VALUES', 2, 0.5, 0.5, 'e')
        self.ok('C', 'u3', 'GET', 'nothing')
        self.ok('C', 'u4', 'SET', 'gone', 1)
        self.ok('C', 'u4', 'DEL', 'gone')
        self.ok('C', 'u5', 'HSET', 'h', 'f', 'x' * 300)
        self.op('OWNERS', 'FORGET', 'u5')
        self.c.call('SELECT', 4)
        self.ok('S//A', 'u6', 'RPUSH', 'l', *range(200))
        self.c.call('SELECT', 0)
        listed = []
        cursor = 0
        while True:
            cursor, batch = self.op('OWNERS', 'LIST', cursor, 'COUNT', 2)
            listed += batch
            if int(cursor) == 0:
                break
        self.assertEqual(sorted(listed), [b'u1', b'u2', b'u6'])
        self.assertEqual(self.info('owners')['owners_holding_data'], '3')
        self.assertEqual(self.owners_info('u2')[b'elements'], 1)

    def test_forget_sends_events_at_the_owner_scope_and_marks_watchers(self):
        self.op('CONFIG', 'SET', 'notify-keyspace-events', 'KEA')
        owner_pin = self.connect(3)
        pinned(owner_pin, 'C', 'u1', 'SUBSCRIBE', '__keyevent@0__:del')
        other_pin = self.connect(3)
        pinned(other_pin, 'C', 'u2', 'SUBSCRIBE', '__keyevent@0__:del')
        every_pin = self.connect(3)
        pinned(every_pin, None, None, 'PSUBSCRIBE', '__keyevent@0__:del')
        self.ok('C', 'u1', 'SET', 'a', 1)
        self.ok('C', 'u1', 'SET', 'b', 1)
        self.ok('C', 'u2', 'SET', 'a', 'theirs')
        watcher = self.connect()
        self.at('C', 'u2', 'WATCH', 'a', client=watcher)
        mine = self.connect()
        self.at('C', 'u1', 'WATCH', 'a', client=mine)
        self.op('OWNERS', 'FORGET', 'u1')
        time.sleep(0.2)
        seen = []
        while every_pin.available(0.3):
            value = every_pin.read()
            if isinstance(value, Push) and value[0] == b'pmessage':
                seen.append(value[-1])
        self.assertEqual(sorted(seen), [b'a', b'b'])
        self.assertFalse(other_pin.available(0.3))
        self.at('C', 'u2', 'MULTI', client=watcher)
        self.at('C', 'u2', 'GET', 'a', client=watcher)
        self.assertEqual(self.at('C', 'u2', 'EXEC', client=watcher), [b'theirs'])
        self.assertTrue(drained(mine))
        self.assertTrue(drained(owner_pin))


class Channels(OwnerServer):
    def test_watch_aborts_on_dominated_scopes_only(self):
        def transaction(label, owner, key, writer):
            watcher = self.connect()
            self.at(label, owner, 'WATCH', key, client=watcher)
            writer()
            self.at(label, owner, 'MULTI', client=watcher)
            self.at(label, owner, 'GET', key, client=watcher)
            return self.at(label, owner, 'EXEC', client=watcher)
        self.ok('C', 'u1', 'SET', 'k', 1)
        self.assertIsNotNone(transaction('C', 'u1', 'k', lambda: self.ok('C', 'u2', 'SET', 'k', 2)))
        self.assertIsNone(transaction('C', 'u1', 'k', lambda: self.ok('C', 'u1', 'SET', 'k', 3)))
        self.assertIsNone(transaction('C', 'u1', 'fresh', lambda: self.ok('U', SHARED, 'SET', 'fresh', 1)))
        self.assertIsNotNone(transaction('C', SHARED, 'k', lambda: self.ok('C', 'u1', 'SET', 'k', 4)))
        self.assertIsNotNone(transaction('U', 'u1', 'x', lambda: self.ok('C', 'u1', 'SET', 'x', 1)))

    def test_blocking_pops_wake_on_their_exact_scope(self):
        waiter = self.connect()
        waiter.send(*prefix('C', 'u1'), 'BLPOP', 'q', 2)
        time.sleep(0.1)
        self.ok('C', 'u2', 'RPUSH', 'q', 'other')
        time.sleep(0.1)
        self.assertFalse(waiter.available(0.1))
        self.ok('C', 'u1', 'RPUSH', 'q', 'mine')
        self.assertEqual(waiter.reply(), [b'q', b'mine'])
        self.assertEqual(self.ok('C', 'u2', 'LRANGE', 'q', 0, -1), [b'other'])
        reader = self.connect()
        reader.send(*prefix('S', 'u3'), 'XREAD', 'BLOCK', 2000, 'STREAMS', 'st', '$')
        time.sleep(0.1)
        self.ok('C', 'u4', 'XADD', 'st', '*', 'f', 1)
        time.sleep(0.1)
        self.assertFalse(reader.available(0.1))
        self.ok('C', SHARED, 'XADD', 'st', '*', 'f', 2)
        value = reader.reply()
        self.assertEqual(value[0][0], b'st')

    def test_keyspace_notifications_reach_pins_that_dominate_the_scope(self):
        self.op('CONFIG', 'SET', 'notify-keyspace-events', 'KEA')
        mine = self.connect(3)
        pinned(mine, 'S', 'u1', 'PSUBSCRIBE', '__keyspace@0__:*')
        theirs = self.connect(3)
        pinned(theirs, 'S', 'u2', 'PSUBSCRIBE', '__keyspace@0__:*')
        shared = self.connect(3)
        pinned(shared, 'S', SHARED, 'PSUBSCRIBE', '__keyspace@0__:*')
        self.ok('C', 'u1', 'SET', 'private', 1)
        self.ok('C', SHARED, 'SET', 'public', 1)
        time.sleep(0.2)

        def channels(client):
            out = []
            while client.available(0.2):
                value = client.read()
                if isinstance(value, Push) and value[0] == b'pmessage':
                    out.append(value[2])
            return sorted(out)
        self.assertEqual(channels(mine), [b'__keyspace@0__:private', b'__keyspace@0__:public'])
        self.assertEqual(channels(theirs), [b'__keyspace@0__:public'])
        self.assertEqual(channels(shared), [b'__keyspace@0__:public'])

    def test_tracking_invalidates_only_pins_that_dominate_the_scope(self):
        mine = self.connect(3)
        pinned(mine, 'C', 'u1', 'CLIENT', 'TRACKING', 'ON')
        self.at('C', 'u1', 'GET', 'k', client=mine)
        theirs = self.connect(3)
        pinned(theirs, 'C', 'u2', 'CLIENT', 'TRACKING', 'ON')
        self.at('C', 'u2', 'GET', 'k', client=theirs)
        self.ok('C', 'u2', 'SET', 'k', 1)
        mine.call(*prefix('C', 'u1'), 'PING')
        theirs.call(*prefix('C', 'u2'), 'PING')
        self.assertEqual(len(mine.pushes), 0)
        self.assertEqual(len(theirs.pushes), 1)
        self.ok('C', SHARED, 'SET', 'k2', 1)
        bcast = self.connect(3)
        pinned(bcast, 'C', 'u1', 'CLIENT', 'TRACKING', 'ON', 'BCAST', 'PREFIX', 'b')
        self.ok('C', 'u2', 'SET', 'b1', 1)
        self.ok('C', 'u1', 'SET', 'b2', 1)
        bcast.call(*prefix('C', 'u1'), 'PING')
        time.sleep(0.1)
        bcast.call(*prefix('C', 'u1'), 'PING')
        keys = [k for p in bcast.pushes for k in p[1]]
        self.assertIn(b'b2', keys)
        self.assertNotIn(b'b1', keys)

    def test_redirect_targets_receive_only_scopes_they_dominate(self):
        target = self.connect()
        target_id = target.call('CLIENT', 'ID')
        pinned(target, 'C', 'u2', 'SUBSCRIBE', '__redis__:invalidate')
        mine = self.connect()
        pinned(mine, 'C', 'u1', 'CLIENT', 'TRACKING', 'ON', 'REDIRECT', target_id)
        self.at('C', 'u1', 'GET', 'k', client=mine)
        theirs = self.connect()
        pinned(theirs, 'C', 'u2', 'CLIENT', 'TRACKING', 'ON', 'REDIRECT', target_id)
        self.at('C', 'u2', 'GET', 'k2', client=theirs)
        self.ok('C', 'u1', 'SET', 'k', 1)
        self.ok('C', 'u2', 'SET', 'k2', 1)
        time.sleep(0.2)
        seen = []
        while target.available(0.3):
            value = target.read()
            seen.append(value[-1])
        self.assertEqual(seen, [[b'k2']])


class VectorSets(OwnerServer):
    def vadd(self, label, owner, key, name, x=0.5, y=0.5):
        return self.ok(label, owner, 'VADD', key, 'VALUES', 2, x, y, name)

    def test_presence_follows_each_owner_and_label(self):
        self.vadd('U', SHARED, 'v', 'pub')
        self.vadd('C', 'u1', 'v', 'mine', 0.1, 0.9)
        self.vadd('C', 'u2', 'v', 'theirs', 0.9, 0.1)
        self.assertEqual(self.ok('C', 'u1', 'VCARD', 'v'), 2)
        self.assertEqual(self.ok('C', 'u2', 'VCARD', 'v'), 2)
        self.assertEqual(self.ok('C', SHARED, 'VCARD', 'v'), 1)
        self.assertEqual(self.ok('C', 'u1', 'VISMEMBER', 'v', 'theirs'), 0)
        self.assertEqual(sorted(self.ok('C', 'u1', 'VSIM', 'v', 'VALUES', 2, 0.1, 0.9)), [b'mine', b'pub'])
        self.assertEqual(self.ok('C', 'u1', 'LABEL', 'OF', 'v', 'mine'), b'C OWNER u1')
        self.assertEqual(self.ok('C', 'u1', 'LABEL', 'OF', 'v', 'pub'), b'U SHARED')
        self.assertEqual(self.refused('C', 'u1', 'VREM', 'v', 'pub'), 'INUSE element in use at U SHARED')
        self.assertEqual(self.ok('C', 'u1', 'DBSIZE'), 1)
        self.assertEqual(self.owners_info('u1')[b'elements'], 1)
        self.assertEqual(self.ok('C', 'u1', 'DEL', 'v'), 1)
        self.assertEqual(self.ok('C', 'u1', 'VCARD', 'v'), 1)
        self.assertEqual(self.ok('C', 'u2', 'VCARD', 'v'), 2)
        self.assertEqual(self.owners_info('u1')[b'keys'], 0)

    def test_forget_removes_the_owner_elements_and_memory_returns(self):
        self.vadd('U', SHARED, 'v', 'pub')
        self.warm_lazy_free()
        before = int(self.info('memory')['used_memory'])
        for i in range(30):
            self.vadd('C', 'u1', 'v', 'e%d' % i, i / 30.0, 1 - i / 30.0)
            self.vadd('S', 'u1', 'w', 'e%d' % i, i / 30.0, 1 - i / 30.0)
        self.vadd('C', 'u2', 'v', 'x')
        reply = self.op('OWNERS', 'FORGET', 'u1')
        result = dict(zip(reply[0::2], reply[1::2]))
        self.assertEqual(result[b'elements'], 60)
        self.assertEqual(result[b'keys'], 2)
        self.assertEqual(self.ok('S', 'u1', 'VCARD', 'v'), 1)
        self.assertEqual(self.ok('S', 'u1', 'EXISTS', 'w'), 0)
        self.assertEqual(self.ok('C', 'u2', 'VCARD', 'v'), 2)
        self.op('OWNERS', 'FORGET', 'u2')
        after = int(self.info('memory')['used_memory'])
        self.assertLess(abs(after - before), 4096)

    def test_owner_only_set_is_counted_and_released(self):
        before = int(self.info('memory')['used_memory'])
        for i in range(10):
            self.vadd('C', 'u1', 'solo', 'e%d' % i, i, 1)
        self.assertEqual(self.ok('C', SHARED, 'EXISTS', 'solo'), 0)
        self.assertEqual(self.ok('C', 'u1', 'VCARD', 'solo'), 10)
        self.assertGreater(int(self.info('memory')['used_memory']), before)
        self.ok('C', 'u1', 'DEL', 'solo')
        after = int(self.info('memory')['used_memory'])
        self.assertLess(abs(after - before), 2048)

    def test_exact_copy_rule_holds_in_the_trust_corner(self):
        self.vadd('C;VETTED', 'u1', 'v', 'e', 1, 0)
        self.vadd('C', SHARED, 'v', 'e', 0, 1)

        def seen(label, owner):
            x, y = (float(t) for t in self.ok(label, owner, 'VEMB', 'v', 'e'))
            return 'own' if x > y else 'shared'

        def score(label, owner):
            reply = self.ok(label, owner, 'VSIM', 'v', 'VALUES', 2, 0, 1, 'WITHSCORES')
            self.assertEqual(reply[0::2], [b'e'])
            return round(float(reply[1]), 2)
        self.assertEqual(seen('C', 'u1'), 'shared')
        self.assertEqual(self.ok('C', 'u1', 'LABEL', 'OF', 'v', 'e'), b'C SHARED')
        self.assertEqual(self.ok('C', 'u1', 'LABEL', 'OF', 'v'), b'C SHARED')
        self.assertEqual(score('C', 'u1'), 1.0)
        self.assertEqual(self.ok('C', 'u1', 'VRANGE', 'v', '-', '+'), [b'e'])
        self.assertEqual(self.ok('C', 'u1', 'VCARD', 'v'), 1)
        self.assertEqual(seen('C;VETTED', 'u1'), 'own')
        self.assertEqual(seen('S', 'u1'), 'own')
        self.assertEqual(score('S', 'u1'), 0.5)
        self.assertEqual(self.ok('S', 'u1', 'VCARD', 'v'), 1)
        self.assertEqual(seen('S', 'u2'), 'shared')
        self.assertEqual(seen('C', SHARED), 'shared')
        own_text = self.ok('S', 'u1', 'LABEL', 'OF', 'v', 'e')
        self.assertTrue(own_text.endswith(b' OWNER u1') and own_text.startswith(b'C'), own_text)
        self.assertEqual(self.refused('C', 'u1', 'VADD', 'v', 'VALUES', 2, 1, 1, 'e'), 'INUSE element in use at C SHARED')
        self.assertEqual(self.refused('C', 'u1', 'VREM', 'v', 'e'), 'INUSE element in use at C SHARED')
        self.op('OWNERS', 'FORGET', 'u1')
        self.assertEqual(seen('S', 'u1'), 'shared')
        self.assertEqual(score('S', 'u1'), 1.0)


class OwnersWithoutLabels(OwnerServer):
    scheme = ()
    top = None

    def test_one_level_owner_mode_isolates_users(self):
        self.op('ACL', 'SETUSER', 'app', 'on', 'nopass', '~*', '&*', '+@all', 'owners:*', 'owner-shared')
        app = self.connect()
        app.call('AUTH', 'app', 'x')
        app.call('LABEL', 'AS', 'OWNER', 'u1', 'SET', 'k', 'one')
        app.call('LABEL', 'AS', 'OWNER', 'u2', 'SET', 'k', 'two')
        app.call('LABEL', 'AS', 'SHARED', 'SET', 'pub', 'p')
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u1', 'GET', 'k'), b'one')
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u2', 'GET', 'k'), b'two')
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u2', 'GET', 'pub'), b'p')
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u2', 'DBSIZE'), 2)
        self.assertEqual(app.call('LABEL', 'AS', 'SHARED', 'DBSIZE'), 1)
        app.send('LABEL', 'AS', 'OWNER', 'u1', 'SET', 'pub', 'mine')
        text = str(app.reply())
        self.assertTrue(text.startswith('INUSE name in use at ') and text.endswith(' SHARED'), text)
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u3', 'KEYS', '*'), [b'pub'])


    def test_flush_without_a_scheme_follows_the_naming(self):
        self.op('ACL', 'SETUSER', 'root', 'on', 'nopass', '~*', '&*', '+@all', 'owner-operator')
        root = self.connect()
        root.call('AUTH', 'root', 'x')

        def flushed(client, *command):
            self.ok(None, 'u1', 'SET', 'a', 1)
            self.ok(None, 'u2', 'SET', 'b', 1)
            self.ok(None, SHARED, 'SET', 's', 1)
            self.assertEqual(client.call(*command), 'OK')
            return [self.ok(None, 'u1', 'EXISTS', 'a'), self.ok(None, 'u2', 'EXISTS', 'b'), self.ok(None, SHARED, 'EXISTS', 's')]
        self.assertEqual(flushed(self.c, 'LABEL', 'AS', 'OWNER', 'u1', 'FLUSHDB'), [0, 1, 1])
        self.assertEqual(flushed(self.c, 'LABEL', 'AS', 'OWNER', 'u2', 'FLUSHALL'), [1, 0, 1])
        self.assertEqual(flushed(self.c, 'LABEL', 'AS', 'SHARED', 'FLUSHALL'), [1, 1, 0])
        self.assertEqual(flushed(root, 'LABEL', 'AS', 'SHARED', 'FLUSHDB'), [1, 1, 0])
        self.assertEqual(flushed(root, 'FLUSHDB'), [0, 0, 0])
        self.assertEqual(flushed(root, 'FLUSHALL'), [0, 0, 0])
        self.c.send('FLUSHALL')
        self.assertEqual(str(self.c.reply()), 'ERR this login must name an owner with every command')


class ModelOracle(OwnerServer):
    LABELS = ('U', 'C', 'C//A', 'C//B', 'C;VETTED', 'S', 'S//A/B')
    OWNERS = (SHARED, 'u1', 'u2')
    NAMES = ['n%d' % i for i in range(7)]

    def model_write(self, model, label, owner, name, kind, value, create_only=False):
        copies = model.names.get(name, {})
        if (label, owner) in copies:
            cp = copies[(label, owner)]
            if cp.kind != kind and kind != 'string':
                return ('ERR', WRONGTYPE)
            return ('EXISTS', cp)
        seen = model.resolve(name, label, owner)
        if seen is not None:
            if create_only:
                return ('SEEN', None)
            return ('ERR', 'INUSE name in use at %s%s' % (format_label(seen[0]), scope_text(seen[1])))
        return ('NEW', None)

    def step(self, rng, model):
        label = rng.choice(self.LABELS)
        owner = rng.choice(self.OWNERS)
        name = rng.choice(self.NAMES)
        choice = rng.randrange(14)
        value = 'v%d' % rng.randrange(1000)
        if choice <= 2:
            state, cp = self.model_write(model, label, owner, name, 'string', value)
            got = self.at(label, owner, 'SET', name, value)
            if state == 'ERR':
                self.assertEqual(error_text(got), cp, (label, owner, name))
                return
            self.assertEqual(got, 'OK', (label, owner, name, state))
            if state == 'EXISTS':
                cp.kind = 'string'
                cp.value = value
            else:
                model.create(name, label, owner, 'string', value)
        elif choice == 3:
            state, cp = self.model_write(model, label, owner, name, 'string', value, create_only=True)
            got = self.at(label, owner, 'SET', name, value, 'NX')
            if state == 'NEW':
                self.assertEqual(got, 'OK')
                model.create(name, label, owner, 'string', value)
            else:
                self.assertIsNone(got, (label, owner, name, state))
        elif choice == 4:
            state, cp = self.model_write(model, label, owner, name, 'list', value)
            got = self.at(label, owner, 'RPUSH', name, value)
            if state == 'ERR':
                self.assertEqual(error_text(got), cp, (label, owner, name))
                return
            if state == 'EXISTS':
                cp.value.append(value)
                self.assertEqual(got, len(cp.value))
            else:
                model.create(name, label, owner, 'list', [value])
                self.assertEqual(got, 1)
        elif choice == 5:
            state, cp = self.model_write(model, label, owner, name, 'hash', value)
            got = self.at(label, owner, 'HSET', name, 'f', value)
            if state == 'ERR':
                self.assertEqual(error_text(got), cp, (label, owner, name))
                return
            if state == 'EXISTS':
                cp.value = value
                self.assertEqual(got, 0)
            else:
                model.create(name, label, owner, 'hash', value)
                self.assertEqual(got, 1)
        elif choice == 6:
            copies = model.names.get(name, {})
            got = self.at(label, owner, 'DEL', name)
            if (label, owner) in copies:
                self.assertEqual(got, 1)
                model.delete(name, label, owner)
            else:
                seen = model.resolve(name, label, owner)
                if seen is None:
                    self.assertEqual(got, 0)
                else:
                    self.assertEqual(error_text(got), 'INUSE name in use at %s%s' % (format_label(seen[0]), scope_text(seen[1])))
        elif choice <= 9:
            seen = model.resolve(name, label, owner)
            got = self.at(label, owner, 'TYPE', name)
            self.assertEqual(got, 'none' if seen is None else seen[2].kind, (label, owner, name))
            if seen is not None and seen[2].kind == 'string':
                self.assertEqual(self.at(label, owner, 'GET', name), seen[2].value.encode())
            if seen is not None and seen[2].kind == 'list':
                self.assertEqual(self.at(label, owner, 'LRANGE', name, 0, -1), [v.encode() for v in seen[2].value])
            if seen is not None:
                self.assertEqual(self.at(label, owner, 'LABEL', 'OF', name), (format_label(seen[0]) + scope_text(seen[1])).encode())
        elif choice == 10:
            self.assertEqual(self.at(label, owner, 'DBSIZE'), len(model.listed(label, owner)), (label, owner))
        elif choice == 11:
            self.assertEqual(sorted(self.at(label, owner, 'KEYS', '*')), [n.encode() for n in model.listed(label, owner)])
        elif choice == 12:
            names, _ = self.scan_all(label, owner, rng.choice((1, 2, 5)))
            self.assertEqual(sorted(set(names)), [n.encode() for n in model.listed(label, owner)])
        else:
            got = self.at(label, owner, 'RANDOMKEY')
            listed = model.listed(label, owner)
            if listed:
                self.assertIn(got.decode(), listed)
            else:
                self.assertIsNone(got)

    def test_random_histories_match_the_model(self):
        for seed in range(3):
            self.op('FLUSHALL')
            for owner in self.OWNERS[1:]:
                self.op('OWNERS', 'FORGET', owner)
            model = Model()
            rng = random.Random(seed)
            for _ in range(700):
                self.step(rng, model)


class NonInterference(unittest.TestCase):
    OBSERVER = ('C', 'u1')
    SECOND = ('S//A', 'u1')
    READER = ('C', SHARED)
    NAMES = ['n%d' % i for i in range(6)]

    def observed(self, rng):
        k = rng.choice(self.NAMES)
        return rng.choice([
            ('SET', k, rng.randrange(50)), ('GET', k), ('DEL', k), ('INCR', k), ('EXISTS', k), ('TYPE', k), ('RPUSH', k, 'x'),
            ('LRANGE', k, 0, -1), ('SADD', k, rng.randrange(6)), ('SMEMBERS', k), ('SRANDMEMBER', k, 2), ('SPOP', k), ('HSET', k, 'f', 1),
            ('HGETALL', k), ('DBSIZE',), ('KEYS', '*'), ('APPEND', k, 'z'), ('LABEL', 'OF', k), ('OBJECT', 'FREQ', k), ('SCAN', 0, 'COUNT', 100)])

    def hidden(self, rng):
        k = rng.choice(self.NAMES)
        label = rng.choice(('C', 'S', 'U', 'S//A', 'C//B'))
        owner = rng.choice(('u2', 'u3'))
        return label, owner, rng.choice([
            ('SET', k, 'h'), ('DEL', k), ('GET', k), ('RPUSH', k, 'y'), ('SADD', k, 'm'), ('HSET', k, 'g', 2), ('SPOP', k),
            ('SRANDMEMBER', k, 3), ('RANDOMKEY',), ('EXPIRE', k, 50), ('FLUSHDB',), ('RENAME', k, k + 'r'), ('SCAN', 0)])

    def normalise(self, command, value):
        name = command[0].upper()
        if isinstance(value, ServerError):
            return 'ERR:' + str(value)
        if name in ('SMEMBERS', 'KEYS', 'HGETALL') and isinstance(value, list):
            return sorted(repr(v) for v in value)
        if name == 'SCAN':
            return sorted(repr(v) for v in value[1]), value[0] == b'0'
        return repr(value)

    def run_world(self, seed, interleave):
        arguments = ('--keyspace-threads', str(KEYSPACE_THREADS), '--memcached-port', '0', '--owners', 'yes', '--label-stream-seed', '5',
                     '--lfu-log-factor', '0') + SCHEME
        server = Server(BINARY, workers=0, arguments=arguments)
        server.start()
        try:
            admin = Client(server.port)
            admin.call('ACL', 'SETUSER', 'default', *OPERATOR)
            admin.call(*prefix('S//A/B', SHARED), 'CONFIG', 'SET', 'notify-keyspace-events', 'KEA')
            admin.call(*prefix('S//A/B', SHARED), 'CONFIG', 'SET', 'maxmemory-policy', 'allkeys-lfu')
            low = Client(server.port)
            watcher = Client(server.port)
            watcher.call('HELLO', 3)
            pinned(watcher, *self.OBSERVER, 'PSUBSCRIBE', '__key*@0__:*')
            tracker = Client(server.port)
            tracker.call('HELLO', 3)
            pinned(tracker, *self.OBSERVER, 'CLIENT', 'TRACKING', 'ON')
            for i in range(4):
                admin.call(*prefix('U', SHARED), 'SET', 'n%d' % i, 'shared')
            rng = random.Random(seed)
            noise = random.Random(seed * 31 + 7)
            replies = []
            for step in range(300):
                scope = rng.choice((self.OBSERVER, self.OBSERVER, self.SECOND, self.READER))
                command = self.observed(rng)
                low.send(*prefix(*scope), *command)
                replies.append((scope, self.normalise(command, low.reply())))
                if command[0] == 'GET' and scope == self.OBSERVER:
                    tracker.send(*prefix(*self.OBSERVER), 'GET', command[1])
                    tracker.reply()
                if interleave:
                    for _ in range(noise.randrange(4)):
                        label, owner, extra = self.hidden(noise)
                        admin.send(*prefix(label, owner), *extra)
                        admin.reply()
                    if noise.randrange(60) == 0:
                        admin.call(*prefix('S//A/B', SHARED), 'OWNERS', 'FORGET', noise.choice(('u2', 'u3')))
            replies.append(('info', low.call(*prefix(*self.OBSERVER), 'INFO', 'keyspace')))
            low.call(*prefix(*self.OBSERVER), 'SET', 'fence', 1)
            tracker.call(*prefix(*self.OBSERVER), 'PING')
            time.sleep(0.2)
            messages = []
            while watcher.available(0.3):
                messages.append(repr(watcher.read()))
            result = replies, messages, [repr(p) for p in tracker.pushes]
            for client in (low, admin, watcher, tracker):
                client.close()
            return result
        finally:
            server.close()

    def test_hidden_owners_change_nothing_an_observer_sees(self):
        for seed in range(3):
            quiet = self.run_world(seed, False)
            noisy = self.run_world(seed, True)
            for k, (a, b) in enumerate(zip(quiet[0], noisy[0])):
                self.assertEqual(a, b, 'reply %d, seed %d' % (k, seed))
            self.assertEqual(quiet[1], noisy[1], 'notifications, seed %d' % seed)
            self.assertEqual(quiet[2], noisy[2], 'tracking, seed %d' % seed)

    def test_a_shared_write_is_visible_to_the_observer(self):
        def world(extra):
            arguments = ('--keyspace-threads', str(KEYSPACE_THREADS), '--memcached-port', '0', '--owners', 'yes', '--label-stream-seed', '5') + SCHEME
            server = Server(BINARY, workers=0, arguments=arguments)
            server.start()
            try:
                admin = Client(server.port)
                admin.call('ACL', 'SETUSER', 'default', *OPERATOR)
                if extra:
                    admin.call(*prefix('U', SHARED), 'SET', 'n1', 'shared')
                out = [admin.call(*prefix(*self.OBSERVER), 'DBSIZE'), admin.call(*prefix(*self.OBSERVER), 'GET', 'n1')]
                admin.close()
                return out
            finally:
                server.close()
        self.assertNotEqual(world(False), world(True))


def main():
    global BINARY, KEYSPACE_THREADS
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', default=str(BINARY))
    parser.add_argument('--keyspace-threads', type=int, default=0)
    args, rest = parser.parse_known_args()
    BINARY = Path(args.server).resolve()
    KEYSPACE_THREADS = args.keyspace_threads
    unittest.main(argv=[sys.argv[0]] + rest, verbosity=1)


if __name__ == '__main__':
    main()
