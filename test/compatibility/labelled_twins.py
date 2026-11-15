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
