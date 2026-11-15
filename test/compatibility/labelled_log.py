import argparse
from pathlib import Path
import random
import signal
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
import labelled_files as lf
import scoped_log as sl
from support import ServerError

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0

SCOPES = {
    'labels': {'low': ('U', None), 'mid': ('C', None), 'high': ('S//A', None), 'side': ('S//B', None), 'gone': None},
    'owners': {'low': ('UNCLASSIFIED', ''), 'mid': ('UNCLASSIFIED', 'u2'), 'high': ('UNCLASSIFIED', 'u1'), 'side': ('UNCLASSIFIED', 'u2'), 'gone': ('UNCLASSIFIED', 'u3')},
    'both': {'low': ('U', ''), 'mid': ('C', 'u1'), 'high': ('S//A', 'u1'), 'side': ('S//B', 'u2'), 'gone': ('U', 'u3')},
}

LIBRARY = "#!lua name=scopedlib\nredis.register_function('touch', function(keys, args) return redis.call('SET', keys[1], args[1]) end)"


def server_ms(c, mode):
    sec, usec = c.call(*sl.top(mode), 'TIME') if mode else c.call('TIME')
    return int(sec) * 1000 + int(usec) // 1000


def vec(rng, dim=3):
    return ['%.3f' % rng.uniform(-1, 1) for _ in range(dim)]


class World:
    def __init__(self, mode, pair):
        self.mode = mode
        self.pair = pair
        self.expiring = []
        self.fields = []
        self.rng = random.Random(17)

    def p(self, scope):
        label, owner = scope
        return sl.at(self.mode, label, owner)

    def s(self, name):
        return SCOPES[self.mode][name]

    def call(self, *a):
        return self.pair.call(*a)

    def expire_soon(self, scope, key):
        self.expiring.append((scope, key))

    def soon(self):
        sec, usec = self.pair.clients[0].call(*sl.top(self.mode), 'TIME')
        return int(sec) * 1000 + int(usec) // 1000 + 40

    def past(self, at):
        for c in self.pair.clients:
            sl.wait_for(lambda c=c: server_ms(c, self.mode) > at, 10, 'the server clock to pass a deadline')

    def case_sort_over_expired_field(self):
        low, high = self.p(self.s('low')), self.p(self.s('high'))
        at = self.soon() + 300
        self.call(*low, 'HSET', 'hf1', 'f', 'secret', 'g', 'x')
        self.call(*low, 'HSET', 'hf2', 'f', '3', 'g', '1')
        self.call(*low, 'HSET', 'hf3', 'f', 'alone')
        for key in ('hf1', 'hf2', 'hf3'):
            if self.call(*low, 'HPEXPIREAT', key, at, 'FIELDS', 1, 'f') != [1]:
                raise AssertionError('the field deadline was not set')
        self.call(*high, 'RPUSH', 'fl', '1', '2')
        self.call(*high, 'RPUSH', 'fl3', '3')
        self.past(at)
        if self.call(*high, 'SORT', 'fl', 'BY', 'nosort', 'GET', 'hf*->f', 'GET', 'hf*->g', 'STORE', 'fd1') != 4:
            raise AssertionError('SORT GET did not store four values')
        if self.call(*high, 'SORT', 'fl', 'BY', 'hf*->f', 'STORE', 'fd2') != 2:
            raise AssertionError('SORT BY did not store two values')
        if self.call(*high, 'SORT', 'fl3', 'BY', 'nosort', 'GET', 'hf*->f', 'STORE', 'fd3') != 1:
            raise AssertionError('SORT GET over a hash of expired fields did not store one value')
        self.call(*high, 'COPY', 'hf1', 'fc1')
        self.call(*low, 'RENAME', 'hf3', 'hf3r')
        self.fields += [(self.s('low'), 'hf1'), (self.s('low'), 'hf2'), (self.s('low'), 'hf3r'), (self.s('high'), 'fc1')]

    def case_refill_over_lower_copy(self):
        low, high = self.p(self.s('low')), self.p(self.s('high'))
        at = self.soon() + 300
        for key in ('rh1', 'rh2', 'rh3'):
            self.call(*high, 'HSET', key, 'f', 1)
            self.call(*low, 'HSET', key, 'a', 1)
            if self.call(*high, 'HPEXPIREAT', key, at, 'FIELDS', 1, 'f') != [1]:
                raise AssertionError('the field deadline was not set')
        if sl.MODES[self.mode]['labelled']:
            beside = sl.at(self.mode, 'S//B', self.s('high')[1])
            self.call(*high, 'HSET', 'rh4', 'f', 'first')
            self.call(*beside, 'HSET', 'rh4', 'a', 'second')
            if self.call(*high, 'HPEXPIREAT', 'rh4', at, 'FIELDS', 1, 'f') != [1]:
                raise AssertionError('the field deadline was not set')
        self.call(*low, 'HSET', 'rq1', 'f', 'gone')
        self.call(*low, 'HPEXPIREAT', 'rq1', at, 'FIELDS', 1, 'f')
        self.call(*high, 'RPUSH', 'rdst', 'own')
        self.call(*low, 'RPUSH', 'rdst', 'lower')
        self.call(*high, 'RPUSH', 'rl', '1')
        self.past(at)
        if self.call(*high, 'HSETNX', 'rh1', 'f', 7) != 1 or self.call(*high, 'HINCRBY', 'rh2', 'f', 5) != 5 or self.call(*high, 'HINCRBYFLOAT', 'rh3', 'f', '1.5') != b'1.5':
            raise AssertionError('a write over the expired field did not start from nothing')
        if self.call(*high, 'SORT', 'rl', 'BY', 'nosort', 'GET', 'rq*->f', 'STORE', 'rdst') != 1:
            raise AssertionError('SORT did not replace its own copy')
        if sl.MODES[self.mode]['labelled']:
            if self.call(*high, 'HSETNX', 'rh4', 'f', 'refilled') != 1:
                raise AssertionError('a write over the expired field did not start from nothing')
            both = sl.at(self.mode, 'S//A/B', self.s('high')[1])
            if self.call(*both, 'HGETALL', 'rh4') != [b'f', b'refilled']:
                raise AssertionError('the older of two copies is not the one a reader above both sees')
        self.fields.append((self.s('low'), 'rq1'))

    def case_set_over_expired(self):
        low, high = self.p(self.s('low')), self.p(self.s('high'))
        self.call(*low, 'SET', 'e1', 'low', 'PXAT', self.soon())
        self.expire_soon(self.s('low'), 'e1')
        self.pair.gone(high, 'e1')
        self.call(*high, 'SET', 'e1', 'high')

    def case_set_nx(self):
        low, high = self.p(self.s('low')), self.p(self.s('high'))
        self.call(*low, 'SET', 'e2', 'low', 'PXAT', self.soon())
        self.expire_soon(self.s('low'), 'e2')
        self.pair.gone(high, 'e2')
        if self.call(*high, 'SET', 'e2', 'won', 'NX') != 'OK':
            raise AssertionError('SET NX over an expired copy did not write')

    def case_store_with_expired_source(self):
        low, high = self.p(self.s('low')), self.p(self.s('high'))
        self.call(*low, 'SADD', 'src2', 'a', 'b')
        self.call(*low, 'PEXPIREAT', 'src2', self.soon())
        self.expire_soon(self.s('low'), 'src2')
        self.call(*high, 'SADD', 'src1', 'x')
        self.pair.gone(high, 'src2')
        if self.call(*high, 'SUNIONSTORE', 'dst', 'src1', 'src2') != 1:
            raise AssertionError('SUNIONSTORE read an expired source')

    def case_vadd_over_expired_presence(self):
        low, high = self.p(self.s('low')), self.p(self.s('high'))
        self.call(*low, 'VADD', 'vk', 'VALUES', 3, 1, 0, 0, 'a1')
        self.call(*low, 'VADD', 'vk', 'VALUES', 3, 0.5, 0.5, 0, 'a2')
        self.call(*low, 'PEXPIREAT', 'vk', self.soon())
        self.expire_soon(self.s('low'), 'vk')
        self.pair.gone(high, 'vk')
        if self.call(*high, 'VADD', 'vk', 'VALUES', 3, 0, 1, 0, 'a1') != 1:
            raise AssertionError('VADD over an expired presence did not add')

    def case_declassify_onto_expired(self):
        if not sl.MODES[self.mode]['labelled']:
            return
        owner = self.s('high')[1]
        high = sl.at(self.mode, 'S', owner)
        target = sl.at(self.mode, 'U', owner)
        between = sl.at(self.mode, 'C', owner)
        self.call(*high, 'SET', 'd1', 'secret')
        self.call(*target, 'SET', 'd1', 'old', 'PXAT', self.soon())
        self.pair.gone(between, 'd1')
        self.call(*high, 'LABEL', 'DECLASSIFY', 'd1', 'U')

    def cases(self):
        self.case_sort_over_expired_field()
        self.case_refill_over_lower_copy()
        self.case_set_over_expired()
        self.case_set_nx()
        self.case_store_with_expired_source()
        self.case_vadd_over_expired_presence()
        self.case_declassify_onto_expired()

    def ordinary(self, scope, tag):
        p = self.p(scope)
        c = self.call
        rng = self.rng
        c(*p, 'SET', 's-' + tag, 'value-' + tag)
        c(*p, 'APPEND', 's-' + tag, '-more')
        c(*p, 'SET', 'n-' + tag, 10)
        c(*p, 'INCRBY', 'n-' + tag, 5)
        c(*p, 'INCRBYFLOAT', 'n-' + tag, '1.5')
        c(*p, 'SETRANGE', 'r-' + tag, 3, 'xyz')
        c(*p, 'SET', 't-' + tag, 'timed', 'EX', 100000)
        c(*p, 'PEXPIREAT', 't-' + tag, sl.FAR - 3)
        c(*p, 'SET', 'far-' + tag, 'far', 'PXAT', sl.FAR - 9)
        c(*p, 'GETSET', 'g-' + tag, 'one')
        c(*p, 'RPUSH', 'l-' + tag, *range(8))
        c(*p, 'LPOP', 'l-' + tag)
        c(*p, 'LMOVE', 'l-' + tag, 'l2-' + tag, 'LEFT', 'RIGHT')
        c(*p, 'SADD', 'set-' + tag, *['m%d' % i for i in range(20)])
        c(*p, 'SREM', 'set-' + tag, 'm3')
        c(*p, 'SPOP', 'set-' + tag, 2)
        c(*p, 'ZADD', 'z-' + tag, *[x for i in range(10) for x in (i * 1.25, 'z%d' % i)])
        c(*p, 'ZINCRBY', 'z-' + tag, 4, 'z1')
        c(*p, 'ZPOPMIN', 'z-' + tag)
        c(*p, 'HSET', 'h-' + tag, *[x for i in range(6) for x in ('f%d' % i, 'v%d' % i)])
        c(*p, 'HINCRBYFLOAT', 'h-' + tag, 'f9', '2.5')
        c(*p, 'HPEXPIREAT', 'h-' + tag, sl.FAR, 'FIELDS', 2, 'f1', 'f2')
        c(*p, 'XADD', 'x-' + tag, '1-1', 'a', 1)
        c(*p, 'XADD', 'x-' + tag, '2-1', 'b', 2)
        c(*p, 'XGROUP', 'CREATE', 'x-' + tag, 'grp', '0')
        c(*p, 'XREADGROUP', 'GROUP', 'grp', 'alice', 'COUNT', 1, 'STREAMS', 'x-' + tag, '>')
        c(*p, 'XACK', 'x-' + tag, 'grp', '1-1')
        c(*p, 'SETBIT', 'b-' + tag, 77, 1)
        c(*p, 'PFADD', 'hll-' + tag, 'a', 'b', 'c')
        c(*p, 'PFCOUNT', 'hll-' + tag)
        c(*p, 'GEOADD', 'geo-' + tag, 13.36, 38.11, 'palermo', 15.08, 37.5, 'catania')
        c(*p, 'EXPIRE', 'l2-' + tag, 200000)
        c(*p, 'PEXPIREAT', 'l2-' + tag, sl.FAR - 4)
        for i in range(24):
            c(*p, 'VADD', 'v-' + tag, 'VALUES', 3, *vec(rng), 'e%d' % i, 'SETATTR', '{"a": %d}' % (i % 5))
        c(*p, 'VREM', 'v-' + tag, 'e3')
        c(*p, 'VSETATTR', 'v-' + tag, 'e4', '{"a": 9}')
        c(*p, 'MULTI')
        c('SET', 'tx-' + tag, 'in-multi')
        c('INCR', 'txn-' + tag)
        c('RPUSH', 'txl-' + tag, 'a', 'b')
        c('EXEC')
        c(*p, 'EVAL', "redis.call('SET', KEYS[1], ARGV[1]) redis.call('RPUSH', KEYS[2], ARGV[1]) return 1", 2, 'sk-' + tag, 'sl-' + tag, 'scripted')

    def flushes(self):
        c = self.call
        c('SELECT', 2)
        for name in ('low', 'mid', 'high'):
            c(*self.p(self.s(name)), 'SET', 'f-' + name, name)
        c(*self.p(self.s('mid')), 'FLUSHDB')
        c('SELECT', 0)
        if sl.MODES[self.mode]['owners']:
            c('SELECT', 3)
            for name in ('low', 'high', 'side'):
                c(*self.p(self.s(name)), 'SET', 'k-' + name, name)
            keeper = self.pair.keeper
            keeper.call('SELECT', 3)
            keeper.call('LABEL', 'AS', sl.MODES[self.mode]['top'], 'SET', 'kept', 'by-keeper')
            keeper.call('LABEL', 'AS', sl.MODES[self.mode]['top'], 'FLUSHDB')
            keeper.call('LABEL', 'AS', sl.MODES[self.mode]['top'], 'SET', 'after', 'flush')
            keeper.call('SELECT', 0)
            flusher = sl.at(self.mode, sl.MODES[self.mode]['low'], 'u9')
            c(*flusher, 'SET', 'u9-a', 1)
            c('SELECT', 1)
            c(*flusher, 'RPUSH', 'u9-b', 1, 2)
            c(*self.p(self.s('low')), 'SET', 'u9-neighbour', 'stays')
            c(*flusher, 'FLUSHALL')
            c('SELECT', 0)

    def operators(self):
        t = sl.top(self.mode)
        c = self.call
        if sl.MODES[self.mode]['labelled']:
            c(*t, 'LABEL', 'QUOTA', 'C', 'LIMIT', 50000000)
            c(*t, 'LABEL', 'QUOTA', 'C', 'LIMIT', 7000000, 'TRUST', 'VETTED')
            c(*t, 'LABEL', 'QUOTA', 'S//A', 'LIMIT', 60000000)
        if sl.MODES[self.mode]['owners']:
            c(*t, 'OWNERS', 'QUOTA', 'u1', 'LIMIT', 80000000)
            c(*t, 'OWNERS', 'QUOTA', 'u9', 'LIMIT', 70000)
            gone = self.p(self.s('gone'))
            c(*gone, 'SET', 'forgotten', 'x')
            c(*gone, 'RPUSH', 'forgotten-list', 1, 2, 3)
            c(*gone, 'VADD', 'v-shared-name', 'VALUES', 3, 1, 1, 1, 'g1')
            c(*t, 'OWNERS', 'FORGET', 'u3')
        c(*t, 'FUNCTION', 'LOAD', LIBRARY)
        c(*t, 'SELECT', 1)
        c(*self.p(self.s('low')), 'SET', 'in-db1', 'one')
        c('SELECT', 0)

    def declassify(self):
        if not sl.MODES[self.mode]['labelled']:
            return
        owner = self.s('high')[1]
        src = sl.at(self.mode, 'S//A', owner)
        self.call(*src, 'SET', 'dk', 'to-c')
        self.call(*src, 'LABEL', 'DECLASSIFY', 'dk', 'C')
        for i in range(6):
            self.call(*src, 'VADD', 'dv', 'VALUES', 3, *vec(self.rng), 'x%d' % i)
        self.call(*src, 'LABEL', 'DECLASSIFY', 'dv', 'C', 'ELEMENT', 'x1')

    def shared_names(self):
        for name in ('high', 'side', 'low'):
            self.call(*self.p(self.s(name)), 'SET', 'same', name)
        for name in ('side', 'low'):
            for i in range(5):
                self.call(*self.p(self.s(name)), 'VADD', 'vsame', 'VALUES', 3, *vec(self.rng), '%s-%d' % (name, i))

    def build(self):
        self.cases()
        for name in ('low', 'mid', 'high', 'side'):
            self.ordinary(self.s(name), name)
        self.shared_names()
        self.declassify()
        self.flushes()
        self.operators()

    def reap(self):
        for scope, key in self.expiring:
            self.call(*self.p(scope), 'EXISTS', key)
        if not self.fields:
            return
        self.call(*sl.top(self.mode), 'DEBUG', 'SET-ACTIVE-EXPIRE', 1)

        def reaped(c):
            for scope, key in self.fields:
                p = self.p(scope)
                if c.call(*p, 'HLEN', key) * 2 != len(c.call(*p, 'HGETALL', key)):
                    return False
            return True
        self.pair.until(reaped)
        self.call(*sl.top(self.mode), 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)

    def later(self):
        for name in ('low', 'high', 'side'):
            p = self.p(self.s(name))
            for i in range(30, 40):
                self.call(*p, 'VADD', 'v-' + name, 'VALUES', 3, *vec(self.rng), 'e%d' % i)
            self.call(*p, 'VREM', 'v-' + name, 'e7')
            self.call(*p, 'RPUSH', 'l-' + name, 'later')
            self.call(*p, 'SET', 'later-' + name, 'yes')
        self.call(*self.p(self.s('high')), 'VADD', 'vk', 'VALUES', 3, 0, 0, 1, 'b2')


class Base(unittest.TestCase):
    mode = None

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='eski-scoped-log-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.servers = []

    def tearDown(self):
        for s in self.servers:
            s.kill()

    def server(self, name, mode=None, extra=()):
        d = self.root / name
        d.mkdir(exist_ok=True)
        s = sl.Server(BINARY, d, self.mode if mode is None else mode, extra, KEYSPACE_THREADS)
        self.servers.append(s)
        return s

    def same(self, a, b, what):
        diff = sl.differences(a, b)
        self.assertEqual(diff, [], '%s differ at %r' % (what, diff[:8]))


class Restart(Base):
    def twins(self):
        a = self.server('a')
        t = self.server('t')
        ca, ct = a.up(), t.up()
        pair = sl.Pair(ca, ct)
        if sl.MODES[self.mode]['owners']:
            pair.keeper = sl.Pair(a.client('keeper'), t.client('keeper'))
        pair.call(*sl.top(self.mode), 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        return a, t, ca, ct, pair

    def check_mode(self):
        a, t, ca, ct, pair = self.twins()
        world = World(self.mode, pair)
        world.build()
        world.reap()
        before = sl.state(ca, self.mode)
        self.same(before, sl.state(ct, self.mode), 'the twins')
        rows = sl.records(sl.last_incr(a.run.directory).read_bytes())
        self.assertEqual(rows[0], [sl.MARKER, b'1', b'1' if sl.MODES[self.mode]['labelled'] else b'0', b'1' if sl.MODES[self.mode]['owners'] else b'0'])
        a.kill()
        b = self.server('a')
        cb = b.up()
        after = sl.state(cb, self.mode)
        self.same(before, after, 'the state before and after the restart')
        later = sl.Pair(cb, ct)
        if sl.MODES[self.mode]['owners']:
            later.keeper = sl.Pair(b.client('keeper'), t.client('keeper'))
        World(self.mode, later).later()
        self.same(sl.state(cb, self.mode), sl.state(ct, self.mode), 'the restarted server and its twin after further writes')
        return rows

    def check_records(self, rows):
        low = SCOPES[self.mode]['low']
        heads = [sl.scoped(r) for r in rows]

        def position(scope, inner):
            for i, (s, rest) in enumerate(heads):
                if s is not None and s[0] == scope[0].encode() and (scope[1] is None or s[1] == scope[1].encode()) and rest[:len(inner)] == inner:
                    return i
            return -1

        for key, command in ((b'e1', [b'SET', b'e1', b'high']), (b'e2', [b'SET', b'e2', b'won']), (b'src2', [b'SUNIONSTORE', b'dst']), (b'vk', [b'VADD', b'vk', b'VALUES', b'3', b'0', b'1', b'0', b'a1'])):
            deletion = position(low, [b'DEL', key])
            later = next((i for i, (s, rest) in enumerate(heads) if s is not None and rest[:len(command)] == command), -1)
            self.assertGreaterEqual(deletion, 0, 'no deletion record for the expired copy %r' % key)
            self.assertGreater(later, deletion, 'the deletion of %r does not come before its command' % key)
        if sl.MODES[self.mode]['labelled']:
            deletion = position(('U', SCOPES[self.mode]['high'][1]), [b'DEL', b'd1'])
            later = next((i for i, (s, rest) in enumerate(heads) if s is not None and rest[:3] == [b'LABEL', b'DECLASSIFY', b'd1']), -1)
            self.assertGreaterEqual(deletion, 0)
            self.assertGreater(later, deletion)
        high = SCOPES[self.mode]['high']
        for dst in (b'fd1', b'fd2', b'fd3'):
            self.assertEqual([rest for s, rest in heads if s is not None and rest[:1] == [b'SORT'] and dst in rest], [], 'a SORT that stepped over an expired field is logged as given')
            deletion = position(high, [b'DEL', dst])
            pushes = [i for i, (s, rest) in enumerate(heads) if s is not None and rest[:2] == [b'RPUSH', dst]]
            self.assertGreaterEqual(deletion, 0, 'no deletion of %r in the effect form' % dst)
            self.assertTrue(pushes and min(pushes) > deletion, 'the pushes of %r do not follow its deletion' % dst)
        self.assertEqual([rest for s, rest in heads if rest[:1] == [b'HDEL'] and rest[1:2] in ([b'hf1'], [b'hf2'], [b'hf3']) and s is not None and s[0] != SCOPES[self.mode]['low'][0].encode()], [])
        seeds = [r for r in rows if r[0] == sl.SEED]
        self.assertEqual(len(seeds), 1)
        for s, rest in heads:
            if s is None:
                self.assertIn(rest[0].upper(), (sl.MARKER, sl.SEED, b'SELECT', b'MULTI', b'EXEC', b'FUNCTION', b'OWNERS', b'LABEL'))


class LabelsRestart(Restart):
    mode = 'labels'

    def test_restart_from_the_log_reaches_the_running_state(self):
        self.check_records(self.check_mode())


class OwnersRestart(Restart):
    mode = 'owners'

    def test_restart_from_the_log_reaches_the_running_state(self):
        self.check_records(self.check_mode())


class BothRestart(Restart):
    mode = 'both'

    def test_restart_from_the_log_reaches_the_running_state(self):
        self.check_records(self.check_mode())


class Cases(Restart):
    def check_case(self, mode, case):
        self.mode = mode
        a, t, ca, ct, pair = self.twins()
        world = World(mode, pair)
        getattr(world, case)()
        world.reap()
        before = sl.state(ca, mode)
        self.same(before, sl.state(ct, mode), 'the twins')
        a.kill()
        cb = self.server('a').up()
        self.same(before, sl.state(cb, mode), 'the state before and after the restart')
        later = sl.Pair(cb, ct)
        World(mode, later).call(*sl.at(mode, *SCOPES[mode]['high']), 'SET', 'after', 'restart')
        self.same(sl.state(cb, mode), sl.state(ct, mode), 'the restarted server and its twin')


def case_test(mode, case):
    def test(self):
        self.check_case(mode, case)
    return test


for _mode in ('labels', 'owners', 'both'):
    for _case in ('case_sort_over_expired_field', 'case_refill_over_lower_copy', 'case_set_over_expired', 'case_set_nx', 'case_store_with_expired_source', 'case_vadd_over_expired_presence', 'case_declassify_onto_expired'):
        if _case == 'case_declassify_onto_expired' and not sl.MODES[_mode]['labelled']:
            continue
        setattr(Cases, 'test_%s_%s' % (_case[5:], _mode), case_test(_mode, _case))


class LogOnly(Base):
    def check_mode(self, mode):
        self.mode = mode
        logged = self.server('logged')
        plain = self.server('plain', extra=('--appendonly', 'no'))
        cl, cp = logged.up(), plain.up()
        pair = sl.Pair(cl, cp)
        t = sl.top(mode)
        pair.call(*t, 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        for c in (cl, cp):
            c.call(*t, 'CONFIG', 'SET', 'notify-keyspace-events', 'KEA')
        watchers = [logged.client(), plain.client()]
        for w in watchers:
            w.send('PSUBSCRIBE', '__key*', 'done')
            w.read()
            w.read()
        World(mode, pair).cases()
        for c in (cl, cp):
            c.call(*t, 'PUBLISH', 'done', 'x')
        events = []
        for w in watchers:
            got = []
            while True:
                m = w.read()
                if m[0] == b'pmessage' and m[2] == b'done':
                    break
                got.append(m)
            events.append(got)
        self.assertEqual(events[0], events[1])
        self.same(sl.state(cl, mode), sl.state(cp, mode), 'the servers with and without the log')
        stats = [{k: v for k, v in lf.info(c, *t, section='stats').items() if k in ('expired_keys', 'evicted_keys', 'expired_subkeys')} for c in (cl, cp)]
        self.assertEqual(stats[0], stats[1])

    def test_label_only(self):
        self.check_mode('labels')

    def test_owner_only(self):
        self.check_mode('owners')

    def test_both(self):
        self.check_mode('both')


LAZY_READS = (
    ('scan', 0, ('SCAN', 0, 'COUNT', 1000)),
    ('scan-type', 0, ('SCAN', 0, 'TYPE', 'string', 'COUNT', 1000)),
    ('scan-match', 0, ('SCAN', 0, 'MATCH', 'lz*', 'COUNT', 1000)),
    ('sort-by', 0, ('SORT', 'lzl', 'BY', 'lz*')),
    ('sort-ro-get', 0, ('SORT_RO', 'lzl', 'BY', 'nosort', 'GET', 'lz*')),
    ('sort-store', 0, ('SORT', 'lzl', 'BY', 'nosort', 'GET', 'lz*', 'STORE', 'lzd')),
    ('randomkey', 1, ('RANDOMKEY',)),
    ('active', 2, None),
    ('reload', 3, ('DEBUG', 'RELOAD')),
)


class LazyDeletions(Base):
    def run_reads(self, mode, c, p):
        t = sl.top(mode) if mode else ()
        c.call(*t, 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        acked = {}
        for name, db, read in LAZY_READS:
            c.call('SELECT', db)
            c.call(*p, 'RPUSH', 'lzl', 'k')
            c.call(*p, 'SET', 'lzk', 'old', 'PX', 1)
            at = server_ms(c, mode) + 1
            sl.wait_for(lambda: server_ms(c, mode) > at, 10, 'the server clock to pass a deadline')
            if read is None:
                c.call(*t, 'DEBUG', 'SET-ACTIVE-EXPIRE', 1)
                sl.wait_for(lambda: c.call(*p, 'DBSIZE') == 1, 20, 'active expiry')
                c.call(*t, 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
            elif read[0] == 'DEBUG':
                c.call(*t, *read)
                c.call(*t, 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
            else:
                c.call(*p, *read)
            acked[name] = c.call(*p, 'SET', 'lzk', 'new-' + name, 'NX')
            c.call(*p, 'RENAME', 'lzk', 'lz-kept-' + name)
            c.call(*p, 'DEL', 'lzl')
        c.call('SELECT', 0)
        return acked

    def kept(self, mode, c, p):
        out = {}
        for name, db, read in LAZY_READS:
            c.call('SELECT', db)
            out[name] = c.call(*p, 'GET', 'lz-kept-' + name)
        c.call('SELECT', 0)
        return out

    def check_mode(self, mode):
        self.mode = mode
        if mode:
            s = self.server('lazy')
            p = sl.at(mode, *SCOPES[mode]['low'])
        else:
            d = self.root / 'lazy'
            d.mkdir()
            s = sl.plain_server(BINARY, d, (), KEYSPACE_THREADS)
            self.servers.append(s)
            p = ()
        c = s.up()
        acked = self.run_reads(mode, c, p)
        self.assertEqual(acked, {name: 'OK' for name, db, read in LAZY_READS})
        expected = {name: ('new-' + name).encode() for name, db, read in LAZY_READS}
        self.assertEqual(self.kept(mode, c, p), expected)
        rows = []
        for f in sl.incr_files(s.run.directory):
            rows += sl.records(f.read_bytes())
        last = {}
        for row in rows:
            scope, rest = sl.scoped(row)
            if rest[:1] == [b'SELECT']:
                continue
            if len(rest) >= 2 and rest[1] == b'lzk':
                if rest[0] == b'SET' and rest[-1] == b'NX':
                    self.assertEqual(last.get('lzk'), [b'DEL', b'lzk'], 'the lazy deletion before %r was not logged' % rest)
                    if mode:
                        self.assertEqual(scope[0], SCOPES[mode]['low'][0].encode())
                last['lzk'] = rest
        s.kill()
        c = s.up()
        self.assertEqual(self.kept(mode, c, p), expected)
        t = sl.top(mode) if mode else ()
        self.assertEqual(c.call(*t, 'DEBUG', 'LOADAOF'), 'OK')
        self.assertEqual(self.kept(mode, c, p), expected)

    def test_plain(self):
        self.check_mode('')

    def test_a_write_at_another_scope_after_a_reload_loads(self):
        for mode in ('labels', 'owners', 'both'):
            self.mode = mode
            s = self.server('reload-' + mode)
            c = s.up()
            t = sl.top(mode)
            low, high = sl.at(mode, *SCOPES[mode]['low']), sl.at(mode, *SCOPES[mode]['high'])
            c.call(*t, 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
            c.call(*low, 'SET', 'rk', 'old', 'PX', 1)
            at = server_ms(c, mode) + 1
            sl.wait_for(lambda: server_ms(c, mode) > at, 10, 'the server clock to pass a deadline')
            self.assertEqual(c.call(*t, 'DEBUG', 'RELOAD'), 'OK')
            self.assertEqual(c.call(*high, 'SET', 'rk', 'high'), 'OK')
            s.kill()
            c = s.up()
            self.assertEqual(c.call(*high, 'GET', 'rk'), b'high', mode)
            self.assertIsNone(c.call(*low, 'GET', 'rk'), mode)
            s.kill()

    def test_label_only(self):
        self.check_mode('labels')

    def test_owner_only(self):
        self.check_mode('owners')

    def test_both(self):
        self.check_mode('both')

    def test_the_deletion_records_change_nothing_a_reader_observes(self):
        for mode in ('', 'labels', 'both'):
            self.mode = mode
            servers = []
            for name, extra in (('on-' + mode, ()), ('off-' + mode, ('--appendonly', 'no'))):
                if mode:
                    servers.append(self.server(name, extra=extra))
                else:
                    d = self.root / name
                    d.mkdir()
                    servers.append(sl.plain_server(BINARY, d, (), KEYSPACE_THREADS))
                    if extra:
                        servers[-1].run.arguments += list(extra)
                    self.servers.append(servers[-1])
            clients = [x.up() for x in servers]
            t = sl.top(mode) if mode else ()
            p = sl.at(mode, *SCOPES[mode]['low']) if mode else ()
            watchers = [x.client() for x in servers]
            for c in clients:
                c.call(*t, 'CONFIG', 'SET', 'notify-keyspace-events', 'KEA')
            for w in watchers:
                w.send('PSUBSCRIBE', '__key*', 'done')
                w.read()
                w.read()
            acked = [self.run_reads(mode, c, p) for c in clients]
            self.assertEqual(acked[0], acked[1])
            for c in clients:
                c.call(*t, 'PUBLISH', 'done', 'x')
            events = []
            for w in watchers:
                got = []
                while True:
                    m = w.read()
                    if m[0] == b'pmessage' and m[2] == b'done':
                        break
                    got.append(m)
                events.append(got)
            self.assertEqual(events[0], events[1], mode)
            stats = [{k: v for k, v in lf.info(c, *t, section='stats').items() if k in ('expired_keys', 'evicted_keys', 'expired_subkeys', 'keyspace_hits', 'keyspace_misses')} for c in clients]
            self.assertEqual(stats[0], stats[1], mode)


class Forms(Base):
    def test_operator_unnamed_records_carry_no_owner_word(self):
        self.mode = 'both'
        s = self.server('a')
        c = s.up()
        keeper = s.client('keeper')
        keeper.call('LABEL', 'AS', 'S//A/B', 'SET', 'k', 'v')
        c.call('LABEL', 'AS', 'C', 'OWNER', 'u1', 'SET', 'k', 'mine')
        c.call('LABEL', 'AS', 'C;VETTED', 'SHARED', 'SET', 'k2', 'shared')
        rows = sl.records(sl.last_incr(s.run.directory).read_bytes())
        self.assertIn([b'LABEL', b'AS', b'S//A/B', b'SET', b'k', b'v'], rows)
        self.assertIn([b'LABEL', b'AS', b'C', b'OWNER', b'u1', b'SET', b'k', b'mine'], rows)
        self.assertIn([b'LABEL', b'AS', b'C;VETTED', b'SHARED', b'SET', b'k2', b'shared'], rows)

    def test_a_label_only_log_holds_no_owner_words(self):
        self.mode = 'labels'
        s = self.server('a')
        c = s.up()
        c.call('LABEL', 'AS', 'S//A', 'SET', 'k', 'v')
        c.call('LABEL', 'AS', 'S//A/B', 'LABEL', 'QUOTA', 'C', 'TRUST', 'VETTED', 'LIMIT', 1000)
        rows = sl.records(sl.last_incr(s.run.directory).read_bytes())
        self.assertEqual(rows[0], [sl.MARKER, b'1', b'1', b'0'])
        self.assertIn([b'LABEL', b'AS', b'S//A', b'SET', b'k', b'v'], rows)
        self.assertIn([b'LABEL', b'QUOTA', b'C', b'TRUST', b'VETTED', b'LIMIT', b'1000'], rows)

    def test_an_empty_log_file_is_given_its_marker_on_open(self):
        self.mode = 'owners'
        s = self.server('a')
        s.up()
        s.kill()
        incr = sl.last_incr(s.run.directory)
        incr.write_bytes(b'')
        s.up()
        self.assertEqual(sl.records(incr.read_bytes()), [[sl.MARKER, b'1', b'0', b'1']])

    def test_a_drawn_seed_survives_a_restart(self):
        for mode in ('labels', 'owners', 'both'):
            self.mode = mode
            s = self.server('seed-' + mode, extra=('--label-stream-seed', '0'))
            c = s.up()
            p = sl.at(mode, *SCOPES[mode]['high'])
            rng = random.Random(8)
            added = c.pipeline([(*p, 'VADD', 'g', 'VALUES', 3, *vec(rng), 'e%d' % i) for i in range(900)])
            self.assertEqual(added, [1] * 900)
            links = [(*p, 'VLINKS', 'g', 'e%d' % i) for i in range(900)]
            before = c.pipeline(links)
            s.kill()
            c = self.server('seed-' + mode, extra=('--label-stream-seed', '0')).up()
            self.assertEqual(c.pipeline(links), before)

    def test_a_command_form_base_is_refused_at_startup(self):
        self.mode = 'labels'
        s = self.server('a', extra=('--aof-use-rdb-preamble', 'no'))
        code, text = s.refused()
        self.assertEqual(code, 1)
        self.assertIn('the append-only base of a server with a label scheme or owner mode is always a snapshot', text)


def crafted_rows(mode):
    return [[sl.MARKER, b'1', b'1' if sl.MODES[mode]['labelled'] else b'0', b'1' if sl.MODES[mode]['owners'] else b'0'], [b'SELECT', b'0']]


class Rejections(Base):
    made = 0

    def prepared(self, mode):
        self.made += 1
        s = self.server('r%d' % self.made, mode=mode)
        s.up()
        s.kill()
        return s

    def refused_with(self, mode, rows, reason, raw=None):
        s = self.prepared(mode)
        sl.last_incr(s.run.directory).write_bytes(raw if raw is not None else sl.encode_records(rows))
        code, text = s.refused()
        self.assertEqual(code, 1, text[-2000:])
        self.assertIn(sl.REFUSED, text)
        self.assertIn(reason, text)
        return text

    def accepted(self, mode, rows):
        s = self.prepared(mode)
        sl.last_incr(s.run.directory).write_bytes(sl.encode_records(rows))
        return s.up()

    def test_a_log_without_the_marker_is_refused(self):
        self.refused_with('labels', [[b'SELECT', b'0'], [b'LABEL', b'AS', b'U', b'SET', b'k', b'v']], 'does not start with the access marker')

    def test_a_marker_of_another_mode_is_refused(self):
        rows = crafted_rows('both')
        self.refused_with('labels', rows, 'names another mode')
        self.refused_with('owners', crafted_rows('labels'), 'names another mode')

    def test_a_marker_of_another_version_is_refused(self):
        self.refused_with('labels', [[sl.MARKER, b'2', b'1', b'0']], 'version')

    def test_a_marker_later_in_the_file_is_refused(self):
        self.refused_with('labels', crafted_rows('labels') + [crafted_rows('labels')[0]], 'not the first record')

    def test_a_scoped_log_on_a_server_without_labels_is_refused(self):
        s = self.server('plain', mode='')
        s.run.arguments += list(sl.SEEDS + sl.LOG)
        s.up()
        s.kill()
        incr = sl.last_incr(s.run.directory)
        incr.write_bytes(sl.encode_records([[b'SELECT', b'0'], [b'LABEL', b'AS', b'U', b'SET', b'k', b'v']]))
        code, text = s.refused()
        self.assertEqual(code, 1)
        self.assertIn('written by a server with a label scheme or owner mode', text)
        incr.write_bytes(sl.encode_records(crafted_rows('labels')))
        code, text = s.refused()
        self.assertEqual(code, 1)
        self.assertIn('written by a server with a label scheme or owner mode', text)

    def test_a_marking_outside_the_scheme_is_refused(self):
        self.refused_with('labels', crafted_rows('labels') + [[b'LABEL', b'AS', b'TOPSECRET', b'SET', b'k', b'v']], 'does not parse')

    def test_an_owner_word_in_label_only_mode_is_refused(self):
        self.refused_with('labels', crafted_rows('labels') + [[b'LABEL', b'AS', b'U', b'OWNER', b'u1', b'SET', b'k', b'v']], 'owner mode is off')
        self.refused_with('labels', crafted_rows('labels') + [[b'LABEL', b'AS', b'U', b'SHARED', b'SET', b'k', b'v']], 'owner mode is off')

    def test_a_malformed_owner_id_is_refused(self):
        for bad in (b'*', b'has space', b'x' * 129, b''):
            self.refused_with('both', crafted_rows('both') + [[b'LABEL', b'AS', b'U', b'OWNER', bad, b'SET', b'k', b'v']], 'malformed owner id')

    def test_a_nested_prefix_is_refused(self):
        self.refused_with('labels', crafted_rows('labels') + [[b'LABEL', b'AS', b'S', b'LABEL', b'AS', b'U', b'SET', b'k', b'v']], 'wraps another scope prefix')

    def test_a_group_with_two_scopes_is_refused(self):
        rows = crafted_rows('both') + [[b'MULTI'], [b'LABEL', b'AS', b'U', b'OWNER', b'u1', b'SET', b'a', b'1'],
                                        [b'LABEL', b'AS', b'U', b'OWNER', b'u2', b'SET', b'b', b'1'], [b'EXEC']]
        self.refused_with('both', rows, 'name two scopes')

    def test_a_maintenance_deletion_inside_a_group_keeps_its_own_scope(self):
        rows = crafted_rows('both') + [[b'LABEL', b'AS', b'U', b'SHARED', b'SET', b'a', b'old'], [b'MULTI'],
                                        [b'LABEL', b'AS', b'U', b'SHARED', b'DEL', b'a'], [b'LABEL', b'AS', b'S', b'OWNER', b'u1', b'SET', b'a', b'new'], [b'EXEC']]
        c = self.accepted('both', rows)
        self.assertEqual(c.call('LABEL', 'AS', 'S', 'OWNER', 'u1', 'GET', 'a'), b'new')
        self.assertIsNone(c.call('LABEL', 'AS', 'U', 'SHARED', 'GET', 'a'))

    def test_a_prefix_around_a_loader_record_is_refused(self):
        for inner in ([b'MULTI'], [b'EXEC'], [b'SELECT', b'1'], [sl.SEED, b'7'], [sl.MARKER, b'1', b'1', b'0']):
            self.refused_with('labels', crafted_rows('labels') + [[b'LABEL', b'AS', b'U'] + inner], 'only the loader reads')

    def test_records_without_a_scope_must_be_operator_records(self):
        for row in ([b'SET', b'k', b'v'], [b'CONFIG', b'SET', b'maxmemory', b'1'], [b'FLUSHALL'], [b'OWNERS', b'FORGET', b'u1']):
            self.refused_with('labels', crafted_rows('labels') + [row], 'not an operator record')

    def test_operator_records_inside_a_prefix_are_refused(self):
        self.refused_with('labels', crafted_rows('labels') + [[b'LABEL', b'AS', b'S//A/B', b'SWAPDB', b'0', b'1']], 'wraps an operator record')

    def test_scoped_records_of_commands_that_write_nothing_are_refused(self):
        self.refused_with('labels', crafted_rows('labels') + [[b'LABEL', b'AS', b'U', b'GET', b'k']], 'changes no data')
        self.refused_with('labels', crafted_rows('labels') + [[b'LABEL', b'AS', b'U', b'EVAL', b'return 1', b'0']], 'never holds')

    def test_a_record_that_fails_at_replay_stops_the_load(self):
        rows = crafted_rows('labels') + [[b'LABEL', b'AS', b'U', b'SET', b'k', b'text'], [b'LABEL', b'AS', b'U', b'INCR', b'k']]
        self.refused_with('labels', rows, 'failed at replay')

    def test_a_partition_beyond_the_cap_is_refused(self):
        s = self.server('a', mode='labels', extra=('--label-partitions-max', '1'))
        s.up()
        s.kill()
        sl.last_incr(s.run.directory).write_bytes(sl.encode_records(crafted_rows('labels') + [[b'LABEL', b'AS', b'C', b'SET', b'k', b'v'], [b'LABEL', b'AS', b'S', b'SET', b'k2', b'v']]))
        code, text = s.refused()
        self.assertEqual(code, 1)
        self.assertIn('beyond label-partitions-max', text)

    def test_a_seed_record_must_hold_one_seed(self):
        for row in ([sl.SEED], [sl.SEED, b'0'], [sl.SEED, b'018'], [sl.SEED, b'18446744073709551616'], [sl.SEED, b'12', b'13']):
            self.refused_with('labels', crafted_rows('labels') + [row], 'seed record')
        self.refused_with('labels', crafted_rows('labels') + [[sl.SEED, b'5'], [sl.SEED, b'6']], 'disagrees')

    def test_a_logged_seed_builds_the_logged_graph(self):
        rng = random.Random(4)
        rows = crafted_rows('labels') + [[sl.SEED, b'987654321']]
        rows += [[b'LABEL', b'AS', b'C', b'VADD', b'v', b'VALUES', b'3'] + [x.encode() for x in vec(rng)] + [b'e%d' % i] for i in range(40)]
        first = self.accepted('labels', rows)
        links = [first.call('LABEL', 'AS', 'C', 'VLINKS', 'v', 'e%d' % i) for i in range(40)]
        second = self.accepted('labels', rows)
        self.assertEqual([second.call('LABEL', 'AS', 'C', 'VLINKS', 'v', 'e%d' % i) for i in range(40)], links)


def main():
    global BINARY, KEYSPACE_THREADS
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', default=str(BINARY))
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--ports', default='')
    args, rest = parser.parse_known_args()
    BINARY = Path(args.server).resolve()
    KEYSPACE_THREADS = args.keyspace_threads
    if args.ports:
        sl.use_ports(args.ports)
    unittest.main(argv=[sys.argv[0]] + rest, verbosity=1)


if __name__ == '__main__':
    main()
