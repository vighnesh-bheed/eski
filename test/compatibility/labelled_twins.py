import argparse
from pathlib import Path
import random
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
import labelled_files as lf
import labelled_log as ll
import scoped_log as sl
from support import ServerError

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0
MODES = ('labels', 'owners', 'both')

VISIBLE = {
    'labels': [('U', None), ('C', None)],
    'owners': [('UNCLASSIFIED', ''), ('UNCLASSIFIED', 'u1')],
    'both': [('U', ''), ('C', ''), ('U', 'u1'), ('C', 'u1')],
}
HIDDEN = {
    'labels': [('S//A', None), ('S//B', None), ('S', None)],
    'owners': [('UNCLASSIFIED', 'u2'), ('UNCLASSIFIED', 'u3'), ('UNCLASSIFIED', 'u4')],
    'both': [('S//A', 'u1'), ('C', 'u2'), ('S//A', 'u2'), ('S//B', 'u3'), ('U', 'u4'), ('S//A', '')],
}
READERS = {
    'labels': [('C', None), ('U', None)],
    'owners': [('UNCLASSIFIED', 'u1'), ('UNCLASSIFIED', 'u9')],
    'both': [('C', 'u1'), ('U', 'u9')],
}


class Rig:
    def __init__(self, test, name, mode, extra=()):
        self.test = test
        self.name = name
        self.mode = mode
        self.extra = tuple(extra)
        self.start()

    def start(self):
        self.server = self.test.server(self.name, self.mode, self.extra)
        self.c = self.server.up()
        self.pair = sl.Pair(self.c)
        if sl.MODES[self.mode]['owners']:
            self.pair.keeper = sl.Pair(self.server.client('keeper'))
        self.pair.call(*sl.top(self.mode), 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        self.reader = self.c
        if sl.MODES[self.mode]['owners']:
            self.c.call(*sl.top(self.mode), 'ACL', 'SETUSER', 'lowuser', 'on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*', 'owners:*')
            self.reader = self.server.client('lowuser')

    def bounce(self):
        self.server.kill()
        self.start()

    def rewrite(self):
        before = sl.rewrites(self.c, self.mode)
        self.c.call(*sl.top(self.mode), 'BGREWRITEAOF')
        sl.wait_rewritten(self.c, self.mode, before)

    def world(self):
        return ll.World(self.mode, self.pair)


def visible_workload(rig, variant):
    w = rig.world()
    mode = rig.mode
    for i, scope in enumerate(VISIBLE[mode]):
        w.ordinary(scope, 'v%d' % i)
        if variant == 'other':
            w.call(*w.p(scope), 'SET', 'extra-visible-%d' % i, 'different')
    if mode != 'owners':
        w.call(*w.p(VISIBLE[mode][0]), 'SET', 'to-expire-visible', 'x', 'PXAT', w.soon())
        w.pair.gone(w.p(VISIBLE[mode][0]), 'to-expire-visible')
    w.call(*w.p(VISIBLE[mode][-1]), 'MULTI')
    w.call('SET', 'visible-tx', 'in')
    w.call('INCR', 'visible-n')
    w.call('EXEC')


def hidden_workload(rig, variant):
    w = rig.world()
    mode = rig.mode
    rng = random.Random(variant)
    n = 5 if variant == 'a' else 13
    for i, scope in enumerate(HIDDEN[mode]):
        p = w.p(scope)
        tag = 'h%s%d' % (variant, i)
        for j in range(n):
            w.call(*p, 'SET', '%s-s%d' % (tag, j), 'value-%s-%d' % (tag, j) * (1 + j % 3))
        w.call(*p, 'RPUSH', tag + '-list', *range(n))
        w.call(*p, 'HSET', tag + '-hash', *[x for j in range(n) for x in ('f%d' % j, 'v%d' % j)])
        w.call(*p, 'ZADD', tag + '-z', *[x for j in range(n) for x in (j * 1.5, 'z%d' % j)])
        w.call(*p, 'XADD', tag + '-x', '1-1', 'a', variant)
        for j in range(n * 4):
            w.call(*p, 'VADD', tag + '-vec', 'VALUES', 3, *ll.vec(rng), 'e%d' % j)
        w.call(*p, 'SET', tag + '-short', 'gone-soon', 'PXAT', w.soon())
    if variant == 'b':
        w.call('SELECT', 2)
        for scope in HIDDEN[mode]:
            w.call(*w.p(scope), 'SET', 'hidden-in-db2-%s%s' % (scope[0].replace('/', ''), scope[1] or ''), 'x')
        w.call('SELECT', 0)
    t = sl.top(mode)
    if sl.MODES[mode]['labelled']:
        w.call(*t, 'LABEL', 'QUOTA', 'S//A', 'LIMIT', 40000000 if variant == 'a' else 50000000)
    if sl.MODES[mode]['owners']:
        w.call(*t, 'OWNERS', 'QUOTA', 'u2', 'LIMIT', 60000000 if variant == 'a' else 70000000)
        if variant == 'a':
            w.call(*t, 'OWNERS', 'FORGET', 'u4')
    if variant == 'b' and sl.MODES[mode]['labelled']:
        w.call(*w.p(HIDDEN[mode][0]), 'SET', 'declass-source', 'x')
        w.call(*w.p(HIDDEN[mode][0]), 'LABEL', 'DECLASSIFY', 'declass-source', 'S')
    for i, scope in enumerate(HIDDEN[mode]):
        tag = 'h%s%d' % (variant, i)
        w.call(*w.p(scope), 'EXISTS', tag + '-short')


def corpus_all(rig):
    return {r: sl.corpus(rig.reader, rig.mode, *r) for r in READERS[rig.mode]}


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='eski-twins-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.servers = []

    def tearDown(self):
        for s in self.servers:
            s.kill()

    def server(self, name, mode, extra=()):
        d = self.root / name
        d.mkdir(exist_ok=True)
        s = sl.Server(BINARY, d, mode, extra, KEYSPACE_THREADS)
        self.servers.append(s)
        return s

    def same(self, a, b, what):
        diff = sl.differences(a, b)
        detail = []
        for path in diff[:3]:
            x, y = a, b
            for step in path:
                x, y = x[step], y[step]
            if isinstance(x, list) and isinstance(y, list):
                x, y = [u for u, v in zip(x, y) if u != v][:3], [v for u, v in zip(x, y) if u != v][:3]
            detail.append((path, x, y))
        self.assertEqual(diff, [], '%s differ at %r' % (what, detail))


class LogTwins(Base):
    def twins(self, mode):
        a = Rig(self, 'a', mode)
        b = Rig(self, 'b', mode)
        visible_workload(a, 'base')
        visible_workload(b, 'base')
        hidden_workload(a, 'a')
        hidden_workload(b, 'b')
        return a, b

    def check_mode(self, mode):
        a, b = self.twins(mode)
        self.same(corpus_all(a), corpus_all(b), 'the readers corpus on the running twins')
        a.bounce()
        b.bounce()
        after_a, after_b = corpus_all(a), corpus_all(b)
        self.same(after_a, after_b, 'the readers corpus on the twins after a restart from the log')
        a.rewrite()
        b.rewrite()
        a.bounce()
        b.bounce()
        self.same(corpus_all(a), corpus_all(b), 'the readers corpus on the twins after a rewrite and a restart')
        a.rewrite()
        a.bounce()
        b.bounce()
        self.same(corpus_all(a), corpus_all(b), 'the readers corpus after a second rewrite on one twin only')
        return after_a

    def test_label_only_twins_show_a_reader_nothing_of_hidden_data(self):
        self.check_mode('labels')

    def test_owner_only_twins_show_a_user_nothing_of_other_users(self):
        self.check_mode('owners')

    def test_both_twins_show_a_reader_and_a_user_nothing_of_hidden_data(self):
        self.check_mode('both')

    def check_sensitivity(self, mode):
        a = Rig(self, 'a', mode)
        c = Rig(self, 'c', mode)
        visible_workload(a, 'base')
        visible_workload(c, 'other')
        hidden_workload(a, 'a')
        hidden_workload(c, 'a')
        before = sl.differences(corpus_all(a), corpus_all(c))
        self.assertGreater(len(before), 0, 'the comparison does not see a difference in the visible data')
        a.bounce()
        c.bounce()
        after = sl.differences(corpus_all(a), corpus_all(c))
        self.assertGreater(len(after), 0, 'the comparison after a restart does not see a difference in the visible data')
        a.rewrite()
        c.rewrite()
        a.bounce()
        c.bounce()
        self.assertGreater(len(sl.differences(corpus_all(a), corpus_all(c))), 0)

    def test_label_only_a_difference_in_visible_data_is_seen(self):
        self.check_sensitivity('labels')

    def test_owner_only_a_difference_in_visible_data_is_seen(self):
        self.check_sensitivity('owners')

    def test_both_a_difference_in_visible_data_is_seen(self):
        self.check_sensitivity('both')

    def test_a_hidden_user_forgotten_with_its_rewrite_leaves_the_readers_replies_unchanged(self):
        for mode in ('owners', 'both'):
            a = Rig(self, 'fa-' + mode, mode, extra=('--owners-forget-aof-delay', '0'))
            b = Rig(self, 'fb-' + mode, mode, extra=('--owners-forget-aof-delay', '0'))
            visible_workload(a, 'base')
            visible_workload(b, 'base')
            hidden_workload(b, 'b')
            hidden_workload(a, 'b')
            a.c.call(*sl.top(mode), 'OWNERS', 'FORGET', 'u3')
            a.rewrite()
            a.bounce()
            b.c.call(*sl.top(mode), 'OWNERS', 'FORGET', 'never-seen-id')
            b.rewrite()
            b.bounce()
            reader = READERS[mode][0]
            ca, cb = sl.corpus(a.reader, mode, *reader), sl.corpus(b.reader, mode, *reader)
            self.same(ca, cb, 'a reader corpus after a hidden forget and its rewrite (%s)' % mode)

    def test_hidden_keys_that_expire_during_downtime_leave_no_trace_for_a_reader(self):
        for mode in MODES:
            a = Rig(self, 'xa-' + mode, mode)
            b = Rig(self, 'xb-' + mode, mode)
            visible_workload(a, 'base')
            visible_workload(b, 'base')
            for rig, name in ((a, 'present'), (b, None)):
                if name:
                    w = rig.world()
                    for scope in HIDDEN[mode]:
                        w.call(*w.p(scope), 'SET', 'dying-' + scope[0].replace('/', ''), 'x', 'PXAT', w.soon())
            a.bounce()
            b.bounce()
            for scope in HIDDEN[mode]:
                a.pair.call(*sl.at(mode, *scope), 'EXISTS', 'dying-' + scope[0].replace('/', ''))
            self.same(corpus_all(a), corpus_all(b), 'the readers corpus when hidden keys expired during downtime (%s)' % mode)


MEMORY_READER = {'labels': ('C', None), 'owners': ('UNCLASSIFIED', 'u1'), 'both': ('C', 'u1')}
MEMORY_KEYS = ('r-str', 'r-hash', 'r-hash-big', 'r-set', 'r-set-int', 'r-set-big', 'r-zset', 'r-zset-big', 'r-list', 'r-list-big', 'r-stream', 'r-vec')


def memory_workload(rig, hidden):
    mode = rig.mode
    w = rig.world()
    r = sl.at(mode, *MEMORY_READER[mode])
    hide = [sl.at(mode, *scope) for scope in HIDDEN[mode]]
    rng = random.Random(29)
    w.call(*r, 'XADD', 'r-stream', '1-1', 'f', 'v')
    w.call(*r, 'XGROUP', 'CREATE', 'r-stream', 'grp', '0')
    for i in range(160):
        if hidden:
            k = i % len(hide)
            h = hide[k]
            w.call(*h, 'SET', 'hid%d-%d' % (k, i % 23), 'x' * (1 + i * 37 % 700))
            w.call(*h, 'HSET', 'hid%d-hash' % k, 'f%d' % i, 'y' * (i % 11))
            w.call(*h, 'SADD', 'hid%d-set' % k, 'm%d' % i)
            w.call(*h, 'RPUSH', 'hid%d-list-%d' % (k, i % 3), 'z' * (i % 13))
            w.call(*h, 'ZADD', 'hid%d-zset' % k, i, 'm%d' % i)
            if i % 5 == 0:
                w.call(*h, 'DEL', 'hid%d-%d' % (k, (i + 7) % 23))
        w.call(*r, 'APPEND', 'r-str', 'v' * (i % 9 + 1))
        if i < 60:
            w.call(*r, 'HSET', 'r-hash', 'f%d' % i, i)
            w.call(*r, 'SADD', 'r-set', 'm%d' % i)
            w.call(*r, 'SADD', 'r-set-int', i * 7)
            w.call(*r, 'ZADD', 'r-zset', i, 'm%d' % i)
            w.call(*r, 'RPUSH', 'r-list', 'e%d' % i)
        w.call(*r, 'HSET', 'r-hash-big', 'field-%d' % i, 'w' * (i % 17), 'extra-%d' % i, i)
        if i % 9 == 0:
            w.call(*r, 'HPEXPIREAT', 'r-hash-big', sl.FAR, 'FIELDS', 1, 'field-%d' % i)
        if i == 100:
            w.call(*r, 'HSET', 'r-hash-big', 'long', 'q' * 80)
        w.call(*r, 'SADD', 'r-set-big', 'member-%d' % i)
        w.call(*r, 'ZADD', 'r-zset-big', i * 0.5, 'member-%d' % i)
        w.call(*r, 'RPUSH', 'r-list-big', 'u' * (60 + i % 50))
        w.call(*r, 'XADD', 'r-stream', '%d-1' % (i + 2), 'f', 'v' * (i % 7))
        if i % 10 == 0:
            w.call(*r, 'XREADGROUP', 'GROUP', 'grp', 'reader-%d' % (i % 3), 'COUNT', 3, 'STREAMS', 'r-stream', '>')
        w.call(*r, 'VADD', 'r-vec', 'VALUES', 3, *ll.vec(rng), 'e%d' % i)
        if i % 13 == 0:
            w.call(*r, 'HDEL', 'r-hash-big', 'field-%d' % (i // 2))
            w.call(*r, 'SREM', 'r-set-big', 'member-%d' % (i // 2))
            w.call(*r, 'ZREM', 'r-zset-big', 'member-%d' % (i // 2))
            w.call(*r, 'LPOP', 'r-list-big')


def memory_figures(rig):
    r = sl.at(rig.mode, *MEMORY_READER[rig.mode])
    out = []
    for key in MEMORY_KEYS:
        plain = rig.reader.call(*r, 'MEMORY', 'USAGE', key)
        out.append((key, rig.reader.call(*r, 'OBJECT', 'ENCODING', key), plain))
        for samples in (0, 5):
            if rig.reader.call(*r, 'MEMORY', 'USAGE', key, 'SAMPLES', samples) != plain:
                out.append((key, 'samples', samples))
    return out


class MemoryTwins(Base):
    def check_mode(self, mode):
        a = Rig(self, 'ma-' + mode, mode)
        b = Rig(self, 'mb-' + mode, mode)
        memory_workload(a, False)
        memory_workload(b, True)
        figures = memory_figures(a)
        self.assertEqual([x[1] for x in figures], [b'raw', b'listpack', b'hashtable', b'listpack', b'intset', b'hashtable', b'listpack', b'skiplist', b'listpack', b'quicklist', b'stream', b'raw'])
        self.same(figures, memory_figures(b), 'MEMORY USAGE on the running twins (%s)' % mode)
        a.bounce()
        b.bounce()
        self.same(memory_figures(a), memory_figures(b), 'MEMORY USAGE after a restart from the log (%s)' % mode)
        a.rewrite()
        b.rewrite()
        self.same(memory_figures(a), memory_figures(b), 'MEMORY USAGE after a rewrite (%s)' % mode)
        a.bounce()
        b.bounce()
        self.same(memory_figures(a), memory_figures(b), 'MEMORY USAGE after a rewrite and a restart (%s)' % mode)
        extra = ('--appendonly', 'no', '--save', '3600 1')
        c = Rig(self, 'mc-' + mode, mode, extra)
        d = Rig(self, 'md-' + mode, mode, extra)
        memory_workload(c, False)
        memory_workload(d, True)
        for rig in (c, d):
            self.assertEqual(rig.c.call(*sl.top(mode), 'SAVE'), 'OK')
            rig.bounce()
        self.same(memory_figures(c), memory_figures(d), 'MEMORY USAGE after a restart from a snapshot (%s)' % mode)

    def test_label_only_memory_figures_show_a_reader_nothing_of_hidden_data(self):
        self.check_mode('labels')

    def test_owner_only_memory_figures_show_a_user_nothing_of_other_users(self):
        self.check_mode('owners')

    def test_both_memory_figures_show_a_reader_and_a_user_nothing_of_hidden_data(self):
        self.check_mode('both')


QUOTA_VISIBLE = {
    'labels': [('C', None)],
    'owners': [('UNCLASSIFIED', 'u1')],
    'both': [('C', 'u1'), ('C', '')],
}
QUOTA_HIDDEN = {
    'labels': [('S//A', None), ('S//B', None), ('S', None)],
    'owners': [('UNCLASSIFIED', 'u2'), ('UNCLASSIFIED', 'u3'), ('UNCLASSIFIED', '')],
    'both': [('C', 'u2'), ('S//A', 'u2'), ('S//B', 'u3'), ('U', 'u4'), ('S//A', '')],
}
QUOTA_FIGURES = {
    'labels': [('label', 'C')],
    'owners': [('owner', 'u1')],
    'both': [('owner', 'u1'), ('label', 'C')],
}


def quota_hidden_step(w, hide, i):
    h = hide[i % len(hide)]
    k = i % len(hide)
    w.call(*h, 'SET', 'q-hid%d-%d' % (k, i % 19), 'x' * (1 + i * 37 % 300))
    w.call(*h, 'HSET', 'q-hid%d-hash' % k, 'f%d' % i, 'y' * (i % 11))
    w.call(*h, 'SADD', 'q-hid%d-set' % k, 'm%d' % i, i)
    w.call(*h, 'ZADD', 'q-hid%d-zset' % k, i, 'm%d' % i)
    w.call(*h, 'RPUSH', 'q-hid%d-list' % k, 'z' * (i % 13))
    w.call(*h, 'XADD', 'q-hid%d-x' % k, '*', 'f', 'v' * (i % 7))
    if i % 4 == 0:
        w.call(*h, 'DEL', 'q-hid%d-%d' % (k, (i + 5) % 19))
        w.call(*h, 'SPOP', 'q-hid%d-set' % k)
        w.call(*h, 'LPOP', 'q-hid%d-list' % k)


def quota_visible_step(w, r, i):
    w.call(*r, 'SET', 'q-s%d' % (i % 23), 'v' * (1 + i % 50))
    w.call(*r, 'APPEND', 'q-grow', 'a' * (i % 9 + 1))
    w.call(*r, 'HSET', 'q-hash', 'field-%d' % i, 'w' * (i % 70))
    w.call(*r, 'SADD', 'q-ints', i * 3)
    w.call(*r, 'SADD', 'q-set', 'member-%d' % i)
    w.call(*r, 'ZADD', 'q-zset', i * 0.25, 'member-%d' % i)
    w.call(*r, 'RPUSH', 'q-list', 'u' * (i % 90))
    w.call(*r, 'XADD', 'q-x', '%d-1' % (i + 2), 'f', 'v' * (i % 30), 'g', i)
    if i % 11 == 0:
        w.call(*r, 'XREADGROUP', 'GROUP', 'grp', 'reader-%d' % (i % 3), 'COUNT', 4, 'STREAMS', 'q-x', '>')
    if i % 17 == 0:
        w.call(*r, 'HPEXPIREAT', 'q-hash', sl.FAR, 'FIELDS', 1, 'field-%d' % i)
        w.call(*r, 'PEXPIREAT', 'q-s%d' % (i % 23), sl.FAR)


def quota_shrink(w, r):
    for i in range(0, 600, 2):
        w.call(*r, 'HDEL', 'q-hash', 'field-%d' % i)
        w.call(*r, 'SREM', 'q-set', 'member-%d' % i)
        w.call(*r, 'SREM', 'q-ints', i * 3)
        w.call(*r, 'ZREM', 'q-zset', 'member-%d' % i)
    w.call(*r, 'LTRIM', 'q-list', 0, 40)
    w.call(*r, 'XTRIM', 'q-x', 'MAXLEN', 150)
    w.call(*r, 'XACK', 'q-x', 'grp', '0-1')
    w.call(*r, 'XGROUP', 'DELCONSUMER', 'q-x', 'grp', 'reader-1')
    w.call(*r, 'DEL', 'q-s3', 'q-s4')


def quota_expiry(w, r):
    soon = w.soon()
    w.call(*r, 'SET', 'q-short', 'gone-soon', 'PXAT', soon)
    w.call(*r, 'RPUSH', 'q-short-list', *range(30))
    w.call(*r, 'PEXPIREAT', 'q-short-list', soon)
    w.call(*r, 'HSET', 'q-hash', 'short-field', 'gone')
    w.call(*r, 'HPEXPIREAT', 'q-hash', soon, 'FIELDS', 1, 'short-field')
    w.past(soon)
    w.pair.gone(r, 'q-short')
    w.pair.gone(r, 'q-short-list')
    w.pair.until(lambda c: c.call(*r, 'HEXISTS', 'q-hash', 'short-field') == 0)


def quota_workload(rig, hidden):
    mode = rig.mode
    w = rig.world()
    visible = [sl.at(mode, *scope) for scope in QUOTA_VISIBLE[mode]]
    hide = [sl.at(mode, *scope) for scope in QUOTA_HIDDEN[mode]]
    for r in visible:
        w.call(*r, 'XADD', 'q-x', '1-1', 'f', 'v')
        w.call(*r, 'XGROUP', 'CREATE', 'q-x', 'grp', '0')
    for i in range(600):
        if hidden:
            quota_hidden_step(w, hide, i)
        for r in visible:
            quota_visible_step(w, r, i)
    for r in visible:
        quota_shrink(w, r)
        quota_expiry(w, r)
    if hidden:
        for k, h in enumerate(hide):
            w.call(*h, 'DEL', 'q-hid%d-hash' % k)


def quota_figures(rig):
    t = sl.top(rig.mode)
    out = []
    for kind, name in QUOTA_FIGURES[rig.mode]:
        if kind == 'owner':
            info = rig.c.call(*t, 'OWNERS', 'INFO', name)
            out.append((kind, name, dict(zip(info[0::2], info[1::2]))[b'bytes']))
        else:
            out.append((kind, name, rig.c.call(*t, 'LABEL', 'QUOTA', name)[1]))
    return out


def quota_answers(rig, figures):
    t = sl.top(rig.mode)
    out = []
    for kind, name, used in figures:
        for limit in (used, used - 1):
            if kind == 'owner':
                rig.c.call(*t, 'OWNERS', 'QUOTA', name, 'LIMIT', limit)
            else:
                rig.c.call(*t, 'LABEL', 'QUOTA', name, 'LIMIT', limit)
            p = sl.at(rig.mode, *[s for s in QUOTA_VISIBLE[rig.mode] if (kind == 'owner') == bool(s[1])][0])
            try:
                out.append((kind, limit - used, rig.c.call(*p, 'SET', 'q-probe', 'x')))
            except ServerError as e:
                out.append((kind, limit - used, str(e)))
            rig.c.call(*p, 'DEL', 'q-probe')
            if kind == 'owner':
                rig.c.call(*t, 'OWNERS', 'QUOTA', name, 'LIMIT', 0)
            else:
                rig.c.call(*t, 'LABEL', 'QUOTA', name, 'LIMIT', 0)
    return out


class QuotaTwins(Base):
    def stage(self, a, b, what):
        fa, fb = quota_figures(a), quota_figures(b)
        self.same(fa, fb, 'quota figures %s' % what)
        for rig in (a, b):
            checked = rig.c.call(*sl.top(rig.mode), 'DEBUG', 'CHARGE-CHECK')
            self.assertGreater(checked, 0, 'the running charges equal the content %s' % what)
        answers = quota_answers(a, fa)
        self.same(answers, quota_answers(b, fb), 'answers at the quota edge %s' % what)
        for kind, delta, answer in answers:
            if delta == 0:
                self.assertEqual(answer, 'OK', 'a write at the quota edge is accepted %s' % what)
            else:
                self.assertIn('OOM', answer, 'a write one byte past the quota edge is refused %s' % what)
        self.same(fa, quota_figures(a), 'quota figures after the probes %s' % what)

    def check_mode(self, mode):
        extra = ('--enable-debug-command', 'yes')
        a = Rig(self, 'qa-' + mode, mode, extra)
        b = Rig(self, 'qb-' + mode, mode, extra)
        quota_workload(a, False)
        quota_workload(b, True)
        self.stage(a, b, 'on the running twins (%s)' % mode)
        a.bounce()
        b.bounce()
        self.stage(a, b, 'after a restart from the log (%s)' % mode)
        a.rewrite()
        b.rewrite()
        self.stage(a, b, 'after a rewrite (%s)' % mode)
        a.bounce()
        b.bounce()
        self.stage(a, b, 'after a rewrite and a restart (%s)' % mode)
        snapshot = extra + ('--appendonly', 'no', '--save', '3600 1')
        c = Rig(self, 'qc-' + mode, mode, snapshot)
        d = Rig(self, 'qd-' + mode, mode, snapshot)
        quota_workload(c, False)
        quota_workload(d, True)
        for rig in (c, d):
            self.assertEqual(rig.c.call(*sl.top(mode), 'SAVE'), 'OK')
            rig.bounce()
        self.stage(c, d, 'after a restart from a snapshot (%s)' % mode)

    def test_label_only_quota_figures_and_refusals_follow_only_the_readers_data(self):
        self.check_mode('labels')

    def test_owner_only_quota_figures_and_refusals_follow_only_the_users_data(self):
        self.check_mode('owners')

    def test_both_quota_figures_and_refusals_follow_only_the_scopes_data(self):
        self.check_mode('both')

    def expiry_server(self, name, mode, policy='noeviction', extra=()):
        server = self.server(name, mode, ('--enable-debug-command', 'yes', '--maxmemory-policy', policy) + extra)
        client = server.up()
        self.addCleanup(client.close)
        self.assertEqual(client.call(*sl.top(mode), 'DEBUG', 'SET-ACTIVE-EXPIRE', 0), 'OK')
        return server, client

    def expiry_case(self, mode, policy, script=None):
        _, a = self.expiry_server('expiry-a-' + policy, mode, policy)
        b_server, b = self.expiry_server('expiry-b-' + policy, mode, policy)
        reader = sl.at(mode, *QUOTA_VISIBLE[mode][0])
        top = sl.top(mode)
        kind, name = QUOTA_FIGURES[mode][0]
        quota = top + ('OWNERS' if kind == 'owner' else 'LABEL', 'QUOTA', name)
        fields = ['f%d' % i for i in range(1050)]
        payload = [arg for field in fields for arg in (field, 'x' * 80)]
        hidden = [sl.at(mode, *scope) for scope in HIDDEN[mode]]
        for c in (a, b):
            self.assertEqual(c.call(*reader, 'SET', 'q-exp-victim', 'v', 'PXAT', sl.FAR - 1000), 'OK')
            self.assertEqual(c.call(*reader, 'SET', 'q-exp-keeper', 'v', 'PXAT', sl.FAR), 'OK')
            self.assertEqual(c.call(*reader, 'HSET', 'q-exp-hash', 'survivor', 'v', *payload), len(fields) + 1)
            self.assertEqual(c.call(*reader, 'HSET', 'q-exp-empty-hash', 'gone', 'v'), 1)
            self.assertEqual(c.call(*reader, 'VADD', 'q-exp-dead-vector', 'VALUES', 2, 1, 0, 'mine'), 1)
            self.assertEqual(c.call('SELECT', 2), 'OK')
            self.assertEqual(c.call(*reader, 'SET', 'q-exp-other-db', 'x' * 1024), 'OK')
            self.assertEqual(c.call('SELECT', 0), 'OK')
        for prefix in hidden:
            self.assertEqual(b.call(*prefix, 'HSET', 'q-exp-hidden-hash', *payload), len(fields))
        self.assertEqual(b.call(*hidden[0], 'VADD', 'q-exp-dead-vector', 'VALUES', 2, 0, 1, 'sibling'), 1)

        at = max(ll.server_ms(c, mode) for c in (a, b)) + 750
        for c in (a, b):
            self.assertEqual(c.call(*reader, 'PEXPIREAT', 'q-exp-dead-vector', at), 1)
            self.assertEqual(c.call(*reader, 'HPEXPIREAT', 'q-exp-hash', at, 'FIELDS', len(fields), *fields), [1] * len(fields))
            self.assertEqual(c.call(*reader, 'HPEXPIREAT', 'q-exp-empty-hash', at, 'FIELDS', 1, 'gone'), [1])
            self.assertEqual(c.call('SELECT', 2), 'OK')
            self.assertEqual(c.call(*reader, 'PEXPIREAT', 'q-exp-other-db', at), 1)
            self.assertEqual(c.call('SELECT', 0), 'OK')
            self.assertEqual(c.call(*reader, 'PEXPIRETIME', 'q-exp-dead-vector'), at)
        hidden_commands = []
        for prefix in hidden:
            hidden_commands += [prefix + ('SET', 'q-exp-hide-%d' % i, 'v', 'PXAT', at) for i in range(160)]
            hidden_commands.append(prefix + ('HPEXPIREAT', 'q-exp-hidden-hash', at, 'FIELDS', len(fields), *fields))
        self.assertEqual(b.pipeline(hidden_commands), (['OK'] * 160 + [[1] * len(fields)]) * len(hidden))

        self.assertEqual(a.call(*top, 'DEBUG', 'SET-ACTIVE-EXPIRE', 1), 'OK')
        sl.wait_for(lambda: ll.server_ms(b, mode) > at, what='the server clock to pass the expiry deadline')

        def reaped():
            stats = lf.info(a, *top, section='stats')
            return int(stats['expired_keys']) == 2 and int(stats['expired_subkeys']) == len(fields) + 1

        sl.wait_for(reaped, what='the first twin to reap both keys and all expired fields')
        held = b.call(*quota)[1]
        self.assertEqual(b.call(*quota, 'LIMIT', held), 'OK')
        self.assertEqual(b.call(*reader, 'SET', 'q-exp-keeper', 'v', 'KEEPTTL'), 'OK')
        self.assertEqual(b.call(*quota)[1], held)
        clean = a.call(*quota)[1]
        if script:
            expected = a.call(*reader, 'SCRIPT', 'LOAD', script)
            script_charge = a.call(*quota)[1] - clean
            self.assertGreater(script_charge, 0)
            probe = reader + ('SCRIPT', 'LOAD', script)
            limit = clean + script_charge
        else:
            probe = reader + ('SET', 'q-exp-probe', 'ok')
            expected = 'OK'
            limit = clean - (policy == 'volatile-ttl')

        replies = []
        for c in (a, b):
            self.assertEqual(c.call(*quota, 'LIMIT', limit), 'OK')
            if c is b and script:
                self.assertEqual(c.call(*top, 'CLIENT', 'PAUSE', 60000, 'WRITE'), 'OK')
                with self.assertRaisesRegex(ServerError, 'OOM.*owner-quota'):
                    c.call(*probe)
                self.assertEqual(c.call(*quota)[1], held)
                self.assertEqual(c.call(*top, 'CLIENT', 'UNPAUSE'), 'OK')
            activated, usage, answer = c.pipeline([
                top + ('DEBUG', 'SET-ACTIVE-EXPIRE', 1), quota, probe,
            ])
            self.assertEqual(activated, 'OK')
            if c is b:
                self.assertGreater(usage[1], limit, 'the second twin still holds expired data at the quota check')
            keys = sorted(c.call(*reader, 'KEYS', 'q-exp-*'))
            replies.append((sl.error_text(answer), keys))

        self.assertEqual(replies[0], replies[1])
        expected_keys = [b'q-exp-hash', b'q-exp-keeper']
        if not script:
            expected_keys.append(b'q-exp-probe')
        if policy != 'volatile-ttl':
            expected_keys.append(b'q-exp-victim')
        self.assertEqual(replies[0], (expected, expected_keys))
        self.assertEqual(b.call(*reader, 'HGETALL', 'q-exp-hash'), [b'survivor', b'v'])
        self.assertEqual(b.call(*hidden[0], 'VCARD', 'q-exp-dead-vector'), 1)
        self.assertEqual(a.call(*quota), b.call(*quota))
        b_server.kill()
        b = b_server.up()
        self.addCleanup(b.close)
        self.assertEqual(sorted(b.call(*reader, 'KEYS', 'q-exp-*')), expected_keys)
        self.assertEqual(b.call(*reader, 'HGETALL', 'q-exp-hash'), [b'survivor', b'v'])
        self.assertEqual(b.call(*hidden[0], 'VCARD', 'q-exp-dead-vector'), 1)

    def test_label_quota_reaps_expired_keys_and_fields_before_admission_and_eviction(self):
        for policy in ('noeviction', 'volatile-ttl'):
            with self.subTest(policy=policy):
                self.expiry_case('labels', policy)

    def test_owner_quota_reaps_expired_keys_and_fields_before_admission_and_eviction(self):
        for policy in ('noeviction', 'volatile-ttl'):
            with self.subTest(policy=policy):
                self.expiry_case('owners', policy)

    def test_scoped_eviction_samples_match_before_and_after_a_shrink(self):
        seed = 3
        print('scoped quota eviction seed', seed, file=sys.stderr)
        expired = ['gone%04d' % i for i in range(6000)]
        keepers = ['keep%02d' % i for i in range(24)]
        for mode, policy in (('owners', 'allkeys-random'), ('owners', 'volatile-random'),
                             ('owners', 'volatile-ttl'), ('labels', 'allkeys-random')):
            with self.subTest(mode=mode, policy=policy, seed=seed):
                self.quota_samples_after_expiry(mode, policy, seed, keepers, expired)

    def quota_samples_after_expiry(self, mode, policy, seed, keepers, expired):
        extra = ('--appendonly', 'no', '--debug-hash-seed', str(seed), '--maxmemory-samples', '1')
        name = mode + '-' + policy
        a_server, a = self.expiry_server('sample-a-' + name, mode, policy, extra)
        b_server, b = self.expiry_server('sample-b-' + name, mode, policy, extra)
        top = sl.top(mode)
        reader = sl.at(mode, *QUOTA_VISIBLE[mode][0])
        hidden = sl.at(mode, *HIDDEN[mode][0])
        kind, name = QUOTA_FIGURES[mode][0]
        quota = top + ('OWNERS' if kind == 'owner' else 'LABEL', 'QUOTA', name)
        for c in (a, b):
            self.assertEqual(c.pipeline([reader + ('SET', key, 'v', 'PXAT', sl.FAR + i)
                                         for i, key in enumerate(keepers)]), ['OK'] * len(keepers))
            self.assertEqual(c.call(*reader, 'MSET', *[v for key in expired for v in (key, 'v')]), 'OK')
        at = max(ll.server_ms(c, mode) for c in (a, b)) + 1500
        for c in (a, b):
            self.assertEqual(c.pipeline([reader + ('PEXPIREAT', key, at) for key in expired]), [1] * len(expired))
        self.assertEqual(b.pipeline([hidden + ('SET', 'hidden%d' % i, 'v', 'PXAT', at)
                                     for i in range(400)]), ['OK'] * 400)
        self.assertEqual(a.call(*top, 'DEBUG', 'SET-ACTIVE-EXPIRE', 1), 'OK')
        sl.wait_for(lambda: ll.server_ms(b, mode) > at, what='the server clock to pass the sample deadline')
        sl.wait_for(lambda: lf.info(a, *top, section='stats')['expired_keys'] == str(len(expired)),
                    what='the first twin to finish expiry')
        sl.wait_for(lambda: lf.info(a, *top, section='memory')['mem_overhead_db_hashtable_rehashing'] == '0',
                    what='the first twin to finish shrinking its table')
        used = a.call(*quota)[1]
        self.assertGreater(b.call(*quota)[1], used)
        remaining = []
        for c in (a, b):
            self.assertEqual(c.call(*quota, 'LIMIT', used - 1), 'OK')
            self.assertEqual(c.pipeline([top + ('DEBUG', 'SET-ACTIVE-EXPIRE', 1),
                                         reader + ('SET', 'probe', 'v')]), ['OK', 'OK'])
            remaining.append(sorted(c.call(*reader, 'KEYS', 'keep*')))
        self.assertEqual(len(remaining[0]), len(keepers) - 1)
        self.assertEqual(remaining[0], remaining[1])
        a_server.kill()
        b_server.kill()

    def test_owner_quota_reaps_expired_keys_and_fields_before_caching_a_script(self):
        self.expiry_case('owners', 'noeviction', script='return 123')

    def test_owner_quota_releases_the_context_of_an_emptied_destination(self):
        mode = 'owners'
        _, a = self.expiry_server('destination-a', mode)
        _, b = self.expiry_server('destination-b', mode)
        top = sl.top(mode)
        reader = sl.at(mode, 'UNCLASSIFIED', 'u1')
        quota = top + ('OWNERS', 'QUOTA', 'u1')
        at = max(ll.server_ms(c, mode) for c in (a, b)) + 250
        for c in (a, b):
            self.assertEqual(c.call(*reader, 'HSET', 'destination', 'gone', 'x' * 1024), 1)
            self.assertEqual(c.call(*reader, 'HPEXPIREAT', 'destination', at, 'FIELDS', 1, 'gone'), [1])
        self.assertEqual(a.call(*top, 'DEBUG', 'SET-ACTIVE-EXPIRE', 1), 'OK')
        sl.wait_for(lambda: ll.server_ms(b, mode) > at, what='the server clock to pass the destination deadline')
        sl.wait_for(lambda: lf.info(a, *top, section='stats')['expired_subkeys'] == '1',
                    what='the first twin to empty its destination partition')
        empty_partition_bytes = 376
        limit = a.call(*quota)[1] + empty_partition_bytes
        self.assertGreater(b.call(*quota)[1], limit)
        for c in (a, b):
            self.assertEqual(c.call(*quota, 'LIMIT', limit), 'OK')
            self.assertEqual(c.call(*reader, 'SET', 'destination', 'live'), 'OK')
        self.assertEqual(a.call(*quota), b.call(*quota))

    def test_owner_quota_expiry_is_logged_during_a_script_with_propagation_disabled(self):
        mode = 'owners'
        _, a = self.expiry_server('lua-a', mode)
        b_server, b = self.expiry_server('lua-b', mode)
        top = sl.top(mode)
        reader = sl.at(mode, 'UNCLASSIFIED', 'u1')
        quota = top + ('OWNERS', 'QUOTA', 'u1')
        body = ("redis.call('SELECT', 2); redis.set_repl(redis.REPL_NONE); "
                "return redis.call('INCR', 'lua-counter')")
        digests = []
        for c in (a, b):
            digests.append(c.call(*reader, 'SCRIPT', 'LOAD', body))
            self.assertEqual(c.call('SELECT', 2), 'OK')
            self.assertEqual(c.call(*reader, 'SET', 'lua-counter', 1), 'OK')
            self.assertEqual(c.call('SELECT', 0), 'OK')
            self.assertEqual(c.call(*reader, 'HSET', 'lua-due-hash', 'gone', 'x' * 1024), 1)
        at = max(ll.server_ms(c, mode) for c in (a, b)) + 250
        for c in (a, b):
            self.assertEqual(c.call(*reader, 'SET', 'lua-due-key', 'x' * 1024, 'PXAT', at), 'OK')
            self.assertEqual(c.call(*reader, 'HPEXPIREAT', 'lua-due-hash', at, 'FIELDS', 1, 'gone'), [1])
        self.assertEqual(a.call(*top, 'DEBUG', 'SET-ACTIVE-EXPIRE', 1), 'OK')
        sl.wait_for(lambda: ll.server_ms(b, mode) > at, what='the server clock to pass the Lua test deadline')
        sl.wait_for(lambda: lf.info(a, *top, section='stats')['expired_subkeys'] == '1',
                    what='the first twin to expire the hash field')
        sl.wait_for(lambda: lf.info(a, *top, section='stats')['expired_keys'] == '1',
                    what='the first twin to expire the key')
        clean = a.call(*quota)[1]
        self.assertGreater(b.call(*quota)[1], clean)
        for c, digest in zip((a, b), digests):
            self.assertEqual(c.call(*quota, 'LIMIT', clean), 'OK')
            self.assertEqual(c.call(*reader, 'EVALSHA', digest, 0), 2)
        self.assertEqual(a.call(*quota), b.call(*quota))
        scope = (b'UNCLASSIFIED', b'u1')
        path = sl.last_incr(b_server.run.directory)

        def has_expiry_records():
            rows = [argv for mark, argv in map(sl.scoped, sl.records(path.read_bytes())) if mark == scope]
            if [b'DEL', b'lua-due-key'] in rows and [b'HDEL', b'lua-due-hash', b'gone'] in rows:
                self.assertNotIn([b'INCR', b'lua-counter'], rows)
                return True
            return False

        sl.wait_for(has_expiry_records, what='the quota expiry effects to reach the append-only file')
        b_server.kill()
        b = b_server.up()
        self.addCleanup(b.close)
        self.assertEqual(b.call(*reader, 'DBSIZE'), 0)
        self.assertEqual(b.call('SELECT', 2), 'OK')
        self.assertEqual(b.call(*reader, 'GET', 'lua-counter'), b'1')

    def test_quota_expiry_rechecks_a_visible_copy_when_the_destination_hash_empties(self):
        mode = 'labels'
        _, c = self.expiry_server('preflight', mode)
        top = sl.top(mode)
        reader = sl.at(mode, 'C')
        lower = sl.at(mode, 'U')
        self.assertEqual(c.call(*reader, 'HSET', 'quota-copy', 'gone', 'x' * 1024), 1)
        self.assertEqual(c.call(*lower, 'SET', 'quota-copy', 'below'), 'OK')
        at = ll.server_ms(c, mode) + 200
        self.assertEqual(c.call(*reader, 'HPEXPIREAT', 'quota-copy', at, 'FIELDS', 1, 'gone'), [1])
        sl.wait_for(lambda: ll.server_ms(c, mode) > at, what='the server clock to pass the hash field deadline')
        used = c.call(*top, 'LABEL', 'QUOTA', 'C')[1]
        self.assertEqual(c.call(*top, 'LABEL', 'QUOTA', 'C', 'LIMIT', used - 1), 'OK')
        with self.assertRaisesRegex(ServerError, 'INUSE'):
            c.call(*reader, 'SET', 'quota-copy', 'overwrite')
        self.assertEqual(c.call(*reader, 'GET', 'quota-copy'), b'below')


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
