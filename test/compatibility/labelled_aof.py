import argparse
import os
from pathlib import Path
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
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
SLOW = ('--rdb-key-save-delay', '30000')


def fingerprint(c, mode, full=False):
    t = sl.top(mode)
    out = {
        'scopes': c.call(*t, 'DEBUG', 'DIGEST-SCOPES'),
        'digest': c.call(*t, 'DEBUG', 'DIGEST'),
        'quotas': sl.quotas(c, mode),
        'owners': sl.owners_listed(c, mode),
    }
    if full:
        out['views'] = {r: sl.view(c, mode, *r) for r in sl.READERS[mode]}
    return out


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='eski-labelled-aof-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.servers = []

    def tearDown(self):
        for s in self.servers:
            s.kill()

    def directory(self, name):
        d = self.root / name
        d.mkdir(exist_ok=True)
        return d

    def server(self, name, mode, extra=()):
        d = self.directory(name)
        s = sl.Server(BINARY, d, mode, extra, KEYSPACE_THREADS)
        self.servers.append(s)
        return s

    def plain(self, name, extra=()):
        s = sl.plain_server(BINARY, self.directory(name), extra, KEYSPACE_THREADS)
        self.servers.append(s)
        return s

    def same(self, a, b, what):
        diff = sl.differences(a, b)
        self.assertEqual(diff, [], '%s differ at %r' % (what, diff[:8]))

    def log_text(self, s):
        return s.run.log()


class Rig:
    def __init__(self, test, name, mode, extra=()):
        self.test = test
        self.name = name
        self.mode = mode
        self.extra = tuple(extra)
        self.world = None
        self.start()

    def start(self):
        self.server = self.test.server(self.name, self.mode, self.extra)
        self.c = self.server.up()
        self.pair = sl.Pair(self.c)
        if sl.MODES[self.mode]['owners']:
            self.keeper = self.server.client('keeper')
            self.pair.keeper = sl.Pair(self.keeper)
        self.pair.call(*sl.top(self.mode), 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        if self.world is None:
            self.world = ll.World(self.mode, self.pair)
        else:
            self.world.pair = self.pair

    def bounce(self):
        self.server.kill()
        self.start()

    def t(self):
        return sl.top(self.mode)

    def info(self):
        return sl.persistence(self.c, self.mode)

    def wait_rewrite(self, before):
        sl.wait_rewritten(self.c, self.mode, before)

    def rewrite(self):
        before = sl.rewrites(self.c, self.mode)
        self.c.call(*self.t(), 'BGREWRITEAOF')
        self.wait_rewrite(before)


class KillChain(Base):
    def check_chain(self, mode, rewrite_between=False):
        rig = Rig(self, 'a', mode)
        w = rig.world
        steps = [
            ('cases', lambda: (w.cases(), w.reap())),
            ('low', lambda: w.ordinary(w.s('low'), 'low')),
            ('mid', lambda: w.ordinary(w.s('mid'), 'mid')),
            ('high', lambda: w.ordinary(w.s('high'), 'high')),
            ('side', lambda: w.ordinary(w.s('side'), 'side')),
            ('shared names', w.shared_names),
            ('declassify', w.declassify),
            ('flushes', w.flushes),
            ('operators', w.operators),
            ('later', w.later),
        ]
        for i, (name, step) in enumerate(steps):
            step()
            before = fingerprint(rig.c, mode, full=name in ('cases', 'flushes', 'later'))
            if rewrite_between and i % 3 == 2:
                rig.rewrite()
                before = fingerprint(rig.c, mode, full=name in ('cases', 'flushes', 'later'))
            rig.bounce()
            after = fingerprint(rig.c, mode, full=name in ('cases', 'flushes', 'later'))
            self.same(before, after, 'the state before the kill and after the restart following %s' % name)

    def test_label_only_every_record_kind_survives_a_kill_at_each_step(self):
        self.check_chain('labels')

    def test_owner_only_every_record_kind_survives_a_kill_at_each_step(self):
        self.check_chain('owners')

    def test_both_every_record_kind_survives_a_kill_at_each_step(self):
        self.check_chain('both')

    def test_kills_alternate_with_rewrites_in_both_modes(self):
        self.check_chain('both', rewrite_between=True)

    def test_kills_alternate_with_rewrites_in_label_only_mode(self):
        self.check_chain('labels', rewrite_between=True)


LIBRARY_TWO = "#!lua name=extralib\nredis.register_function('extra', function(keys, args) return redis.call('SET', keys[1], args[1]) end)"


def more_kinds(rig):
    mode = rig.mode
    w = rig.world
    c = w.call
    p = w.p(w.s('high'))
    low = w.p(w.s('low'))
    t = rig.t()
    c(*p, 'SET', 'm-str', 'v', 'EX', 100000)
    c(*p, 'SETEX', 'm-setex', 100000, 'v')
    c(*p, 'GETEX', 'm-str', 'EX', 200000)
    c(*p, 'RPUSH', 'm-list', 5, 6, 3, 4, 1, 2)
    c(*p, 'LMPOP', 2, 'm-list', 'm-nolist', 'LEFT', 'COUNT', 2)
    c(*p, 'LMOVE', 'm-list', 'm-list2', 'LEFT', 'RIGHT')
    c(*p, 'LINSERT', 'm-list', 'BEFORE', 1, 'ins')
    c(*p, 'BLPOP', 'm-list', 0.1)
    c(*p, 'SADD', 'm-set', 'a', 'b', 'c', 'd')
    c(*p, 'SMOVE', 'm-set', 'm-set2', 'a')
    c(*p, 'SPOP', 'm-set', 2)
    c(*p, 'ZADD', 'm-z', 1, 'a', 2, 'b', 3, 'c')
    c(*p, 'ZMPOP', 1, 'm-z', 'MIN')
    c(*p, 'ZINCRBY', 'm-z', 2, 'b')
    c(*p, 'HSET', 'm-h', 'f1', 'v1', 'f2', 'v2', 'f3', 'v3')
    c(*p, 'HEXPIRE', 'm-h', 100000, 'FIELDS', 1, 'f1')
    c(*p, 'HPERSIST', 'm-h', 'FIELDS', 1, 'f1')
    c(*p, 'HINCRBY', 'm-h', 'n', 5)
    c(*p, 'HPEXPIRE', 'm-h', 30, 'FIELDS', 1, 'f2')
    w.pair.until(lambda cl: cl.call(*p, 'HEXISTS', 'm-h', 'f2') == 0)
    c(*p, 'XADD', 'm-x', '1-1', 'a', 1)
    c(*p, 'XADD', 'm-x', '2-1', 'b', 2)
    c(*p, 'XADD', 'm-x', '3-1', 'c', 3)
    c(*p, 'XGROUP', 'CREATE', 'm-x', 'g', '0')
    c(*p, 'XREADGROUP', 'GROUP', 'g', 'alice', 'COUNT', 2, 'STREAMS', 'm-x', '>')
    c(*p, 'XCLAIM', 'm-x', 'g', 'bob', 0, '1-1')
    c(*p, 'XAUTOCLAIM', 'm-x', 'g', 'carol', 0, '0-0', 'COUNT', 1)
    c(*p, 'XACK', 'm-x', 'g', '1-1')
    c(*p, 'XTRIM', 'm-x', 'MAXLEN', 2)
    c(*p, 'COPY', 'm-str', 'm-str-copy')
    c(*p, 'RENAME', 'm-str-copy', 'm-str-renamed')
    c(*p, 'MOVE', 'm-str-renamed', 3)
    c(*p, 'RESTORE', 'm-restored', 0, c(*p, 'DUMP', 'm-setex'))
    c(*p, 'SORT', 'm-list2', 'STORE', 'm-sorted')
    c(*p, 'BITFIELD', 'm-bf', 'SET', 'u8', 0, 200, 'INCRBY', 'u8', 0, 100)
    c(*p, 'PFADD', 'm-hll', 'a', 'b')
    c(*p, 'PFMERGE', 'm-hll2', 'm-hll')
    c(*p, 'GEOADD', 'm-geo', 13.3, 38.1, 'p', 15.0, 37.5, 'c')
    c(*p, 'GEOSEARCHSTORE', 'm-geo2', 'm-geo', 'FROMLONLAT', 14, 38, 'BYRADIUS', 500, 'km')
    c(*p, 'APPEND', 'm-app', 'x')
    c(*p, 'SETRANGE', 'm-app', 4, 'y')
    c(*t, 'SWAPDB', 2, 3)
    c(*t, 'FUNCTION', 'LOAD', LIBRARY_TWO)
    c(*p, 'FCALL', 'extra', 1, 'm-fcall', 'viafunction')
    c(*t, 'FUNCTION', 'DELETE', 'extralib')
    c(*t, 'FUNCTION', 'LOAD', 'REPLACE', ll.LIBRARY)
    c(*t, 'CONFIG', 'SET', 'maxmemory-policy', 'allkeys-lru')
    if sl.MODES[mode]['labelled']:
        c(*t, 'LABEL', 'QUOTA', w.s('high')[0], 'LIMIT', 4000)
    if sl.MODES[mode]['owners']:
        c(*t, 'OWNERS', 'QUOTA', w.s('high')[1] or 'u1', 'LIMIT', 4000)
    for i in range(40):
        try:
            c(*p, 'SET', 'evict-%d' % i, 'x' * 150)
        except ServerError:
            pass
    c(*t, 'LABEL', 'QUOTA', w.s('high')[0], 'LIMIT', 0) if sl.MODES[mode]['labelled'] else None
    c(*t, 'CONFIG', 'SET', 'maxmemory-policy', 'noeviction')


class MoreKinds(Base):
    def check_more(self, mode, rewrite):
        rig = Rig(self, 'a', mode)
        more_kinds(rig)
        kinds = set()
        for f in sl.incr_files(rig.server.run.directory):
            for row in sl.records(f.read_bytes()):
                kinds.add(sl.scoped(row)[1][0].upper())
        wanted = {b'SET', b'PEXPIREAT', b'HPEXPIREAT', b'RPUSH', b'LPOP', b'LMOVE', b'LINSERT', b'SADD', b'SMOVE', b'SREM', b'ZADD', b'ZPOPMIN', b'ZINCRBY',
                  b'HSET', b'HINCRBY', b'HPERSIST', b'HDEL', b'XADD', b'XGROUP', b'XCLAIM', b'XACK', b'XTRIM', b'COPY', b'RENAME', b'MOVE', b'RESTORE',
                  b'SORT', b'BITFIELD', b'PFADD', b'PFMERGE', b'GEOADD', b'GEOSEARCHSTORE', b'APPEND', b'SETRANGE', b'SWAPDB', b'FUNCTION', b'DEL'}
        self.assertEqual(sorted(wanted - kinds), [], 'record kinds the workload did not produce: %r' % sorted(kinds))
        state = fingerprint(rig.c, mode, full=True)
        if rewrite:
            rig.rewrite()
            self.same(state, fingerprint(rig.c, mode, full=True), 'the state before and after the rewrite')
        rig.bounce()
        self.same(state, fingerprint(rig.c, mode, full=True), 'the state after the kill and the restart')

    def test_label_only_every_remaining_record_kind_survives_a_kill(self):
        self.check_more('labels', False)

    def test_owner_only_every_remaining_record_kind_survives_a_kill(self):
        self.check_more('owners', False)

    def test_both_every_remaining_record_kind_survives_a_kill(self):
        self.check_more('both', False)

    def test_label_only_every_remaining_record_kind_survives_a_rewrite(self):
        self.check_more('labels', True)

    def test_both_every_remaining_record_kind_survives_a_rewrite(self):
        self.check_more('both', True)


class Burst(Base):
    def scope_for(self, mode):
        return sl.at(mode, *ll.SCOPES[mode]['high'])

    def check_burst(self, mode, grouped):
        name = 'burst-%s-%d' % (mode, grouped)
        s = self.server(name, mode)
        c = s.up()
        p = self.scope_for(mode)
        total = 300
        acked_target = 117
        if grouped:
            units = []
            for i in range(total):
                units += [(*p, 'MULTI'), ('RPUSH', 'burst', i), ('INCR', 'counter'), ('EXEC',)]
            c.send_many(units)
            acked = 0
            while acked < acked_target:
                reply = c.reply()
                if isinstance(reply, list):
                    acked += 1
        else:
            c.send_many([(*p, 'RPUSH', 'burst', i) for i in range(total)])
            for _ in range(acked_target):
                c.reply()
            acked = acked_target
        s.kill()
        c2 = self.server(name, mode).up()
        values = c2.call(*p, 'LRANGE', 'burst', 0, -1)
        k = len(values)
        self.assertGreaterEqual(k, acked, 'an acknowledged write is missing after the kill')
        self.assertEqual([int(v) for v in values], list(range(k)), 'the list is not a prefix of the written sequence')
        if grouped:
            counter = c2.call(*p, 'GET', 'counter')
            self.assertEqual(int(counter) if counter else 0, k, 'a transaction was replayed in part')

    def test_a_pipelined_burst_keeps_every_acknowledged_write_and_a_prefix(self):
        for mode in MODES:
            self.check_burst(mode, False)

    def test_a_burst_of_transactions_keeps_each_group_whole(self):
        for mode in MODES:
            self.check_burst(mode, True)


class Rewrites(Base):
    def check_rewrite(self, mode):
        rig = Rig(self, 'a', mode)
        w = rig.world
        w.cases()
        w.reap()
        for name in ('low', 'mid', 'high', 'side'):
            w.ordinary(w.s(name), name)
        w.shared_names()
        w.declassify()
        w.flushes()
        w.operators()
        before_rewrite = fingerprint(rig.c, mode, full=True)
        rig.rewrite()
        base = Path(rig.server.run.directory) / 'appendonlydir'
        manifest = (base / 'appendonly.aof.manifest').read_text()
        self.assertIn('base.rdb', manifest)
        incr = sl.last_incr(rig.server.run.directory)
        self.assertEqual(sl.records(incr.read_bytes())[:1], [[sl.MARKER, b'1', b'1' if sl.MODES[mode]['labelled'] else b'0', b'1' if sl.MODES[mode]['owners'] else b'0']])
        self.same(before_rewrite, fingerprint(rig.c, mode, full=True), 'the state before and after the rewrite')
        sl.wait_history_gone(rig.server.run.directory)
        w.later()
        after_later = fingerprint(rig.c, mode, full=True)
        rig.bounce()
        self.same(after_later, fingerprint(rig.c, mode, full=True), 'the state before the kill and after the restart following a rewrite')
        rig.rewrite()
        rig.bounce()
        self.same(after_later, fingerprint(rig.c, mode, full=True), 'the state after a second rewrite and a restart')

    def test_label_only_rewrite_with_a_snapshot_base(self):
        self.check_rewrite('labels')

    def test_owner_only_rewrite_with_a_snapshot_base(self):
        self.check_rewrite('owners')

    def test_both_rewrite_with_a_snapshot_base(self):
        self.check_rewrite('both')

    def check_writes_during_the_rewrite(self, mode):
        rig = Rig(self, 'a', mode, extra=SLOW)
        w = rig.world
        for name in ('low', 'high'):
            w.ordinary(w.s(name), name)
        c = rig.c
        before = sl.rewrites(c, mode)
        c.call(*rig.t(), 'BGREWRITEAOF')
        sl.wait_for(lambda: rig.info()['aof_rewrite_in_progress'] == '1', 20, 'the rewrite child')
        p_low, p_high = w.p(w.s('low')), w.p(w.s('high'))
        c.call(*p_low, 'SET', 'during-low', 'a')
        c.call(*p_high, 'RPUSH', 'during-list', 'x', 'y')
        c.call(*p_high, 'VADD', 'during-vec', 'VALUES', 3, 1, 2, 3, 'e1')
        c.call(*p_low, 'MULTI')
        c.call('SET', 'during-tx', 'v')
        c.call('INCR', 'during-n')
        c.call('EXEC')
        self.assertEqual(rig.info()['aof_rewrite_in_progress'], '1')
        c.call(*rig.t(), 'CONFIG', 'SET', 'rdb-key-save-delay', 0)
        rig.wait_rewrite(before)
        rows = sl.records(sl.last_incr(rig.server.run.directory).read_bytes())
        heads = [sl.scoped(r) for r in rows]
        scoped_during = [(s, rest) for s, rest in heads if s is not None and rest[:2] in ([b'SET', b'during-low'], [b'RPUSH', b'during-list'], [b'VADD', b'during-vec'], [b'SET', b'during-tx'])]
        self.assertEqual(len(scoped_during), 4, rows)
        self.assertEqual(rows[0][0], sl.MARKER)
        state = fingerprint(c, mode, full=True)
        rig.bounce()
        self.same(state, fingerprint(rig.c, mode, full=True), 'the state with writes made during a rewrite')
        self.assertEqual(rig.c.call(*p_high, 'LRANGE', 'during-list', 0, -1), [b'x', b'y'])

    def test_label_only_writes_during_the_rewrite_reach_the_new_file_with_their_scope(self):
        self.check_writes_during_the_rewrite('labels')

    def test_owner_only_writes_during_the_rewrite_reach_the_new_file_with_their_scope(self):
        self.check_writes_during_the_rewrite('owners')

    def test_both_writes_during_the_rewrite_reach_the_new_file_with_their_scope(self):
        self.check_writes_during_the_rewrite('both')

    def test_a_kill_during_the_rewrite_loses_nothing_and_leaves_no_temporary_file(self):
        for mode in MODES:
            rig = Rig(self, 'k-' + mode, mode, extra=SLOW)
            w = rig.world
            for name in ('low', 'high'):
                w.ordinary(w.s(name), name)
            before = sl.rewrites(rig.c, mode)
            rig.c.call(*rig.t(), 'BGREWRITEAOF')
            sl.wait_for(lambda: rig.info()['aof_rewrite_in_progress'] == '1', 20, 'the rewrite child')
            rig.c.call(*w.p(w.s('high')), 'SET', 'while-rewriting', 'kept')
            sl.wait_for(lambda: any(p.name.startswith('temp-rewriteaof-bg-') for p in Path(rig.server.run.directory).iterdir()), 20, 'the temporary base')
            state = fingerprint(rig.c, mode, full=True)
            rig.server.kill()
            rig.start()
            self.same(state, fingerprint(rig.c, mode, full=True), 'the state after a kill during a rewrite')
            leftovers = [p.name for p in Path(rig.server.run.directory).iterdir() if p.name.startswith('temp-')]
            self.assertEqual(leftovers, [])
            self.assertIn('Removed the stale temporary file', rig.server.run.log())

    def check_automatic(self, mode):
        rig = Rig(self, 'a', mode, extra=('--auto-aof-rewrite-percentage', '1', '--auto-aof-rewrite-min-size', '1000'))
        p = rig.world.p(rig.world.s('high'))
        before = sl.rewrites(rig.c, mode)
        i = 0
        while sl.rewrites(rig.c, mode) == before and i < 400:
            rig.c.call(*p, 'SET', 'auto-%d' % i, 'x' * 100)
            i += 1
            if i % 20 == 0:
                time.sleep(0.05)
        sl.wait_rewritten(rig.c, mode, before)
        self.assertGreater(len(sl.manifest_files(rig.server.run.directory)), 2)
        rig.c.call(*p, 'SET', 'after-auto', 'yes')
        state = fingerprint(rig.c, mode, full=True)
        rig.bounce()
        self.same(state, fingerprint(rig.c, mode, full=True), 'the state after an automatic rewrite')
        self.assertEqual(rig.c.call(*p, 'GET', 'after-auto'), b'yes')

    def test_label_only_automatic_rewrite(self):
        self.check_automatic('labels')

    def test_owner_only_automatic_rewrite(self):
        self.check_automatic('owners')

    def test_both_automatic_rewrite(self):
        self.check_automatic('both')

    def test_the_base_is_a_snapshot_and_a_command_form_base_is_refused_at_runtime(self):
        for mode in MODES:
            rig = Rig(self, 'p-' + mode, mode)
            error = None
            try:
                rig.c.call(*rig.t(), 'CONFIG', 'SET', 'aof-use-rdb-preamble', 'no')
            except ServerError as e:
                error = str(e)
            self.assertIsNotNone(error)
            self.assertIn('the append-only base of a server with a label scheme or owner mode is always a snapshot', error)
            self.assertEqual(rig.c.call(*rig.t(), 'CONFIG', 'GET', 'aof-use-rdb-preamble'), [b'aof-use-rdb-preamble', b'yes'])

    def test_timestamp_lines_follow_the_marker_and_replay_skips_them(self):
        for mode in MODES:
            rig = Rig(self, 't-' + mode, mode, extra=('--aof-timestamp-enabled', 'yes'))
            p = sl.at(mode, *ll.SCOPES[mode]['high'])
            rig.c.call(*p, 'SET', 'a', '1')
            rig.c.call(*p, 'MULTI')
            rig.c.call('SET', 'b', '2')
            rig.c.call('INCR', 'n')
            rig.c.call('EXEC')
            data = sl.last_incr(rig.server.run.directory).read_bytes()
            self.assertTrue(data.startswith(b'*4\r\n$11\r\nESKI-ACCESS\r\n'), data[:60])
            self.assertIn(b'#TS:', data)
            self.assertLess(data.index(sl.MARKER), data.index(b'#TS:'))
            rig.rewrite()
            rig.c.call(*p, 'SET', 'c', '3')
            state = fingerprint(rig.c, mode, full=True)
            incr = sl.last_incr(rig.server.run.directory).read_bytes()
            self.assertTrue(incr.startswith(b'*4\r\n$11\r\nESKI-ACCESS\r\n'))
            rig.bounce()
            self.same(state, fingerprint(rig.c, mode, full=True), 'the state of a log with timestamp lines (%s)' % mode)

    def test_a_server_without_labels_still_takes_a_command_form_base(self):
        s = self.plain('plain')
        c = s.up()
        c.call('SET', 'a', '1')
        self.assertEqual(c.call('CONFIG', 'SET', 'aof-use-rdb-preamble', 'no'), 'OK')
        before = sl.rewrites(c, '')
        c.call('BGREWRITEAOF')
        sl.wait_for(lambda: int(lf.info(c)['aof_rewrites']) > before and lf.info(c)['aof_rewrite_in_progress'] == '0', 20, 'the rewrite')
        self.assertIn('base.aof', (Path(s.run.directory) / 'appendonlydir/appendonly.aof.manifest').read_text())

    def test_below_top_a_rewrite_is_refused_and_leaves_no_trace(self):
        for mode in ('labels', 'both'):
            rig = Rig(self, 'b-' + mode, mode)
            low = sl.at(mode, *ll.SCOPES[mode]['low'])
            c = rig.c
            error = None
            try:
                c.call(*low, 'BGREWRITEAOF')
            except ServerError as e:
                error = str(e)
            self.assertIn('needs a label that dominates the whole label scheme', error or '')
            before = lf.info(c, *low)
            c.call(*rig.t(), 'BGREWRITEAOF')
            sl.wait_for(lambda: rig.info()['aof_rewrites'] == '1' and rig.info()['aof_rewrite_in_progress'] == '0', 20, 'the rewrite')
            after = lf.info(c, *low)
            self.assertEqual({k: v for k, v in before.items() if k.startswith('aof_')}, {k: v for k, v in after.items() if k.startswith('aof_')})
            self.assertEqual(c.call(*low, 'LASTSAVE'), c.call(*low, 'LASTSAVE'))


class TurnOn(Base):
    def check_turn_on(self, mode):
        s = self.server('a', mode, extra=('--appendonly', 'no'))
        c = s.up()
        t = sl.top(mode)
        w = ll.World(mode, sl.Pair(c))
        if sl.MODES[mode]['owners']:
            w.pair.keeper = sl.Pair(s.client('keeper'))
        c.call(*t, 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        w.ordinary(w.s('low'), 'low')
        w.ordinary(w.s('high'), 'high')
        w.shared_names()
        self.assertEqual(lf.info(c, *t)['aof_enabled'], '0')
        self.assertEqual(c.call(*t, 'CONFIG', 'SET', 'appendonly', 'yes'), 'OK')
        sl.wait_for(lambda: lf.info(c, *t)['aof_enabled'] == '1' and lf.info(c, *t)['aof_rewrite_in_progress'] == '0' and lf.info(c, *t)['aof_rewrite_scheduled'] == '0', 30, 'the log to be on')
        w.pair = sl.Pair(c)
        if sl.MODES[mode]['owners']:
            w.pair.keeper = sl.Pair(s.client('keeper'))
        w.later()
        w.flushes()
        state = fingerprint(c, mode, full=True)
        s.kill()
        d = s.run.directory
        s2 = self.server('a', mode)
        c2 = s2.up()
        self.same(state, fingerprint(c2, mode, full=True), 'the state of a log turned on at runtime')

    def test_label_only_the_log_can_be_turned_on_at_runtime(self):
        self.check_turn_on('labels')

    def test_owner_only_the_log_can_be_turned_on_at_runtime(self):
        self.check_turn_on('owners')

    def test_both_the_log_can_be_turned_on_at_runtime(self):
        self.check_turn_on('both')

    def test_turning_the_log_on_below_top_is_refused(self):
        s = self.server('a', 'labels', extra=('--appendonly', 'no'))
        c = s.up()
        try:
            c.call('LABEL', 'AS', 'U', 'CONFIG', 'SET', 'appendonly', 'yes')
        except ServerError as e:
            self.assertIn('dominates the whole label scheme', str(e))
        else:
            self.fail('a login below top turned the log on')

    def test_the_log_cannot_be_turned_on_with_a_command_form_base(self):
        s = self.server('a', 'labels', extra=('--appendonly', 'no', '--aof-use-rdb-preamble', 'no'))
        c = s.up()
        with self.assertRaises(ServerError) as caught:
            c.call(*sl.top('labels'), 'CONFIG', 'SET', 'appendonly', 'yes')
        self.assertIn('always a snapshot', str(caught.exception))
        self.assertEqual(c.call(*sl.top('labels'), 'CONFIG', 'GET', 'appendonly'), [b'appendonly', b'no'])

    SCHEME_ARGS = ('label-levels', 'U,C,S', 'label-compartments', 'A,B', 'label-trust-levels', 'WEB,VETTED')

    def marker_flags(self, d):
        rows = sl.records(sl.last_incr(d).read_bytes())
        self.assertEqual(rows[0][0], sl.MARKER)
        return rows[0][2:]

    def check_scheme_on(self, owners_first):
        d = self.directory('a')
        s = self.plain('a')
        c = s.up()
        c.call('SET', 'plain-key', 'v')
        c.call('FLUSHALL')
        c.call('FUNCTION', 'LOAD', ll.LIBRARY)
        steps = []
        if owners_first:
            self.assertEqual(c.call('CONFIG', 'SET', 'owners', 'yes'), 'OK')
            files = sorted(p.name for p in sl.log_dir(d).iterdir())
            self.assertTrue(any(f.endswith('.base.rdb') for f in files), files)
            self.assertEqual(self.marker_flags(d), [b'0', b'1'])
            c.call('ACL', 'SETUSER', 'default', *sl.OWNER_OPERATOR)
            self.assertEqual(c.call(*sl.top('owners'), 'CONFIG', 'SET', *self.SCHEME_ARGS), 'OK')
            mode = 'both'
            self.assertEqual(self.marker_flags(d), [b'1', b'1'])
        else:
            self.assertEqual(c.call('CONFIG', 'SET', *self.SCHEME_ARGS), 'OK')
            mode = 'labels'
            self.assertEqual(self.marker_flags(d), [b'1', b'0'])
        c.call(*(sl.top(mode) if owners_first else ()), 'ACL', 'SETUSER', 'default', *(sl.OWNER_OPERATOR if sl.MODES[mode]['owners'] else sl.OPERATOR))
        low = sl.at(mode, *ll.SCOPES[mode]['low'])
        high = sl.at(mode, *ll.SCOPES[mode]['high'])
        c.call(*low, 'SET', 'after-turn-on', 'v')
        c.call(*high, 'RPUSH', 'list', 1, 2, 3)
        state = fingerprint(c, mode)
        s.kill()
        c2 = self.server('a', mode).up()
        self.same(state, fingerprint(c2, mode), 'the state after the scheme was turned on with the log on')
        self.assertEqual(c2.call(*low, 'GET', 'after-turn-on'), b'v')
        self.assertEqual(c2.call(*sl.top(mode), 'FUNCTION', 'LIST')[0][1], b'scopedlib')

    def test_a_label_scheme_can_be_turned_on_while_the_log_is_on(self):
        self.check_scheme_on(False)

    def test_owner_mode_and_then_a_scheme_can_be_turned_on_while_the_log_is_on(self):
        self.check_scheme_on(True)

    def test_owner_mode_cannot_be_turned_on_inside_a_transaction_while_the_log_is_on(self):
        s = self.plain('a')
        c = s.up()
        c.call('MULTI')
        c.call('FUNCTION', 'LOAD', ll.LIBRARY)
        c.call('CONFIG', 'SET', 'owners', 'yes')
        reply = c.call('EXEC')
        self.assertEqual(reply[0], b'scopedlib')
        self.assertIsInstance(reply[1], ServerError)
        self.assertIn('could not be written', str(reply[1]))
        self.assertEqual(c.call('CONFIG', 'GET', 'owners'), [b'owners', b'no'])
        s.kill()
        c2 = self.plain('a').up()
        self.assertEqual(c2.call('FUNCTION', 'LIST')[0][1], b'scopedlib')

    def test_a_mode_can_be_turned_on_while_the_log_is_still_being_switched_on(self):
        s = self.plain('a', extra=('--appendonly', 'no'))
        c = s.up()
        replies = c.pipeline([('CONFIG', 'SET', 'appendonly', 'yes'), ('CONFIG', 'SET', 'owners', 'yes')])
        self.assertEqual(replies, ['OK', 'OK'])
        c.call(*sl.top('owners'), 'ACL', 'SETUSER', 'default', *sl.OWNER_OPERATOR)
        sl.wait_for(lambda: lf.info(c, *sl.top('owners')).get('aof_rewrite_in_progress') == '0' and lf.info(c, *sl.top('owners')).get('aof_enabled') == '1', 30, 'the log to settle')
        self.assertEqual(self.marker_flags(s.run.directory), [b'0', b'1'])
        p = sl.at('owners', 'UNCLASSIFIED', 'u1')
        c.call(*p, 'SET', 'k', 'v')
        s.kill()
        c2 = self.server('a', 'owners').up()
        self.assertEqual(c2.call(*p, 'GET', 'k'), b'v')

    def test_a_scheme_cannot_be_turned_on_while_keys_exist_even_with_the_log_on(self):
        s = self.plain('a')
        c = s.up()
        c.call('SET', 'k', 'v')
        with self.assertRaises(ServerError) as caught:
            c.call('CONFIG', 'SET', 'label-levels', 'U,C,S')
        self.assertIn('needs a server without keys', str(caught.exception))
        self.assertEqual(c.call('GET', 'k'), b'v')
        rows = sl.records(sl.last_incr(s.run.directory).read_bytes())
        self.assertFalse(any(r[0] == sl.MARKER for r in rows), rows)


def user_scope(mode, user, label=None):
    label = label or ('UNCLASSIFIED' if mode == 'owners' else 'C')
    return sl.at(mode, label, user)


def populate(c, mode, user, tag):
    p = user_scope(mode, user)
    q = user_scope(mode, user, 'UNCLASSIFIED' if mode == 'owners' else 'S//A')
    c.call(*p, 'SET', 'key-' + tag, 'value-' + tag)
    c.call(*p, 'RPUSH', 'list-' + tag, 'item-' + tag, 'two')
    c.call(*q, 'HSET', 'hash-' + tag, 'field-' + tag, 'v-' + tag)
    c.call(*q, 'VADD', 'vec-' + tag, 'VALUES', 3, 1, 2, 3, 'element-' + tag)
    c.call('SELECT', 2)
    c.call(*p, 'SET', 'db2-' + tag, 'two-' + tag)
    c.call('SELECT', 0)


class Forget(Base):
    ID = 'forgotten-user-77'

    def setup(self, mode, extra=(), name='a'):
        rig = Rig(self, name, mode, extra=extra)
        populate(rig.c, mode, self.ID, 'FORGOTTEN77')
        populate(rig.c, mode, 'stays-user-5', 'STAYS5')
        rig.c.call(*sl.top(mode), 'OWNERS', 'QUOTA', self.ID, 'LIMIT', 9000000)
        rig.c.call(*sl.at(mode, 'UNCLASSIFIED' if mode == 'owners' else 'C'), 'SET', 'shared-key', 'shared-value')
        return rig

    def wait_covered(self, rig, value):
        sl.wait_for(lambda: rig.info()['owners_forget_in_aof'] == value, 20, 'the forget to count as covered once the files before the rewrite are gone')
        self.assertTrue(sl.log_files_match_manifest(rig.server.run.directory))
        self.assertEqual(sl.manifest_history(rig.server.run.directory), [])

    def covered(self, rig):
        i = rig.info()
        return i['owners_forget_in_aof'] == i['owners_forget_sequence'] and i['aof_rewrite_in_progress'] == '0' and i['aof_rewrite_scheduled'] == '0'

    def assert_clean(self, rig, what=''):
        sl.wait_history_gone(rig.server.run.directory)
        for needle in (self.ID, 'FORGOTTEN77'):
            self.assertEqual(sl.holding(rig.server.run.directory, needle), [], 'a file still holds %s %s' % (needle, what))

    def assert_dirty(self, rig):
        self.assertTrue(sl.holding(rig.server.run.directory, self.ID), 'the id was never in a file, so the test shows nothing')

    def check_timer(self, mode):
        rig = self.setup(mode, extra=('--owners-forget-aof-delay', '1'))
        c, t = rig.c, rig.t()
        self.assert_dirty(rig)
        i = rig.info()
        self.assertEqual((i['owners_forget_sequence'], i['owners_forget_in_aof']), ('0', '0'))
        before = sl.rewrites(c, mode)
        reply = c.call(*t, 'OWNERS', 'FORGET', self.ID)
        self.assertEqual(reply[-1], 1)
        self.assertNotEqual(rig.info()['owners_forget_in_aof'], '1')
        sl.wait_for(lambda: self.covered(rig), 40, 'the log to cover the forget')
        self.assertEqual(sl.rewrites(c, mode), before + 1)
        self.assert_clean(rig, 'after the timed rewrite')
        state = fingerprint(c, mode, full=True)
        self.assertNotIn(self.ID.encode(), b''.join(c.call(*t, 'OWNERS', 'LIST', 0)[1]))
        rig.bounce()
        self.same(state, fingerprint(rig.c, mode, full=True), 'the state after the forget, its rewrite and a restart')
        self.assertEqual(rig.c.call(*user_scope(mode, 'stays-user-5'), 'GET', 'key-STAYS5'), b'value-STAYS5')
        self.assertIsNone(rig.c.call(*user_scope(mode, self.ID), 'GET', 'key-FORGOTTEN77'))

    def test_owner_only_a_forget_is_followed_by_one_rewrite_and_the_id_leaves_every_file(self):
        self.check_timer('owners')

    def test_both_a_forget_is_followed_by_one_rewrite_and_the_id_leaves_every_file(self):
        self.check_timer('both')

    def test_several_forgets_in_a_row_cause_one_rewrite(self):
        rig = Rig(self, 'a', 'both', extra=('--owners-forget-aof-delay', '2'))
        c, t = rig.c, rig.t()
        ids = ['forgotten-user-77', 'forgotten-user-78', 'forgotten-user-79']
        for i in ids:
            populate(c, 'both', i, 'FORGOTTEN' + i[-2:])
        before = sl.rewrites(c, 'both')
        for n, i in enumerate(ids):
            self.assertEqual(c.call(*t, 'OWNERS', 'FORGET', i)[-1], n + 1)
        self.assertEqual(rig.info()['owners_forget_in_aof'], '0')
        sl.wait_for(lambda: self.covered(rig), 40, 'the log to cover the forgets')
        self.assertEqual(rig.info()['owners_forget_in_aof'], '3')
        self.assertEqual(sl.rewrites(c, 'both'), before + 1)
        sl.wait_history_gone(rig.server.run.directory)
        for i in ids:
            self.assertEqual(sl.holding(rig.server.run.directory, i), [])

    def test_a_forget_while_a_rewrite_runs_is_covered_by_the_next_rewrite(self):
        rig = self.setup('both', extra=('--owners-forget-aof-delay', '1') + SLOW)
        c, t = rig.c, rig.t()
        before = sl.rewrites(c, 'both')
        c.call(*t, 'BGREWRITEAOF')
        sl.wait_for(lambda: rig.info()['aof_rewrite_in_progress'] == '1', 20, 'the first rewrite')
        c.call(*t, 'OWNERS', 'FORGET', self.ID)
        sl.wait_for(lambda: int(rig.info()['aof_rewrites']) == before + 1 and rig.info()['aof_rewrite_in_progress'] == '0', 60, 'the first rewrite to end')
        self.assertEqual(rig.info()['owners_forget_in_aof'], '0')
        c.call(*t, 'CONFIG', 'SET', 'rdb-key-save-delay', 0)
        sl.wait_for(lambda: self.covered(rig), 60, 'the second rewrite')
        self.assertEqual(sl.rewrites(c, 'both'), before + 2)
        self.assert_clean(rig, 'after the second rewrite')

    def test_a_manual_rewrite_completes_a_forget_when_the_delay_is_zero(self):
        rig = self.setup('both', extra=('--owners-forget-aof-delay', '0'))
        c, t = rig.c, rig.t()
        c.call(*t, 'OWNERS', 'FORGET', self.ID)
        before = sl.rewrites(c, 'both')
        self.assertEqual(rig.info()['owners_forget_in_aof'], '0')
        self.assertTrue(sl.holding(rig.server.run.directory, self.ID))
        c.call(*t, 'BGREWRITEAOF')
        sl.wait_rewritten(c, 'both', before)
        self.wait_covered(rig, '1')
        self.assert_clean(rig, 'after the manual rewrite')

    def test_a_forget_of_an_id_that_never_held_data_is_logged_and_covered(self):
        rig = Rig(self, 'a', 'owners', extra=('--owners-forget-aof-delay', '0'))
        c, t = rig.c, rig.t()
        c.call(*t, 'OWNERS', 'FORGET', 'never-seen-id-42')
        self.assertEqual(rig.info()['owners_forget_sequence'], '1')
        self.assertTrue(sl.holding(rig.server.run.directory, 'never-seen-id-42'))
        rig.rewrite()
        self.wait_covered(rig, '1')
        sl.wait_history_gone(rig.server.run.directory)
        self.assertEqual(sl.holding(rig.server.run.directory, 'never-seen-id-42'), [])

    def test_a_kill_after_a_forget_is_followed_by_the_rewrite_after_the_restart(self):
        rig = self.setup('both', extra=('--owners-forget-aof-delay', '0'))
        c, t = rig.c, rig.t()
        c.call(*t, 'OWNERS', 'FORGET', self.ID)
        self.assert_dirty(rig)
        state = fingerprint(c, 'both', full=True)
        rig.extra = ('--owners-forget-aof-delay', '1')
        rig.bounce()
        self.same(state, fingerprint(rig.c, 'both', full=True), 'the state after a kill following a forget')
        self.assertEqual(rig.info()['owners_forget_sequence'], '1')
        self.assertEqual(rig.info()['owners_forget_in_aof'], '0')
        sl.wait_for(lambda: self.covered(rig), 40, 'the rewrite after the restart')
        self.assert_clean(rig, 'after the restart and its rewrite')

    def test_a_covered_forget_is_read_from_the_base_after_a_restart(self):
        rig = self.setup('both', extra=('--owners-forget-aof-delay', '0'))
        c, t = rig.c, rig.t()
        c.call(*t, 'OWNERS', 'FORGET', self.ID)
        rig.rewrite()
        self.wait_covered(rig, '1')
        rig.bounce()
        i = rig.info()
        self.assertEqual((i['owners_forget_sequence'], i['owners_forget_in_aof']), ('1', '1'))
        c = rig.c
        c.call(*rig.t(), 'OWNERS', 'FORGET', 'second-forget')
        i = rig.info()
        self.assertEqual((i['owners_forget_sequence'], i['owners_forget_in_aof']), ('2', '1'))
        rig.bounce()
        i = rig.info()
        self.assertEqual((i['owners_forget_sequence'], i['owners_forget_in_aof']), ('2', '1'))

    def test_a_clean_shutdown_after_a_forget_rewrites_the_log_first(self):
        rig = self.setup('both', extra=('--owners-forget-aof-delay', '0'))
        c, t = rig.c, rig.t()
        c.call(*t, 'OWNERS', 'FORGET', self.ID)
        self.assert_dirty(rig)
        d = rig.server.run.directory
        code = rig.server.stop()
        self.assertEqual(code, 0)
        self.assertEqual(sl.holding(d, self.ID), [])
        self.assertEqual(sl.holding(d, 'FORGOTTEN77'), [])
        self.assertTrue(sl.log_files_match_manifest(d))
        rig.start()
        self.assertEqual(rig.c.call(*user_scope('both', 'stays-user-5'), 'GET', 'key-STAYS5'), b'value-STAYS5')
        self.assertEqual(rig.info()['owners_forget_in_aof'], rig.info()['owners_forget_sequence'])

    def test_shutdown_nosave_after_a_forget_keeps_the_files_and_warns(self):
        rig = self.setup('both', extra=('--owners-forget-aof-delay', '0'))
        c, t = rig.c, rig.t()
        c.call(*t, 'OWNERS', 'FORGET', self.ID)
        try:
            c.call(*t, 'SHUTDOWN', 'NOSAVE')
        except (ServerError, EOFError, OSError):
            pass
        sl.wait_for(lambda: rig.server.run.process.poll() is not None, 20, 'the server to exit')
        self.assertIn('Exiting without a rewrite although OWNERS FORGET ran', rig.server.run.log())
        self.assertTrue(sl.holding(rig.server.run.directory, self.ID))

    def test_the_fields_are_top_only_and_equal_the_sequence_when_the_log_is_off(self):
        rig = Rig(self, 'a', 'both', extra=('--appendonly', 'no'))
        c, t = rig.c, rig.t()
        c.call(*t, 'OWNERS', 'FORGET', 'some-id')
        i = rig.info()
        self.assertEqual(i['owners_forget_in_aof'], i['owners_forget_sequence'])
        low = sl.at('both', 'U', 'u1')
        self.assertNotIn('owners_forget_in_aof', lf.info(c, *low))
        with self.assertRaises(ServerError):
            c.call(*low, 'OWNERS', 'FORGET', 'x')

    def test_the_fields_read_the_log_state_when_it_is_on(self):
        rig = Rig(self, 'a', 'both', extra=('--owners-forget-aof-delay', '0'))
        c, t = rig.c, rig.t()
        c.call(*t, 'OWNERS', 'FORGET', 'some-id')
        i = rig.info()
        self.assertEqual((i['owners_forget_sequence'], i['owners_forget_in_aof']), ('1', '0'))
        rig.rewrite()
        self.wait_covered(rig, '1')
        c.call(*t, 'OWNERS', 'FORGET', 'other-id')
        self.assertEqual((rig.info()['owners_forget_sequence'], rig.info()['owners_forget_in_aof']), ('2', '1'))
        c.call(*t, 'CONFIG', 'SET', 'appendonly', 'no')
        i = rig.info()
        self.assertEqual((i['owners_forget_sequence'], i['owners_forget_in_aof']), ('2', '1'))
        for p in sl.log_dir(rig.server.run.directory).iterdir():
            p.unlink()
        i = rig.info()
        self.assertEqual(i['owners_forget_in_aof'], i['owners_forget_sequence'])


class Quotas(Base):
    def check_quotas(self, mode):
        rig = Rig(self, 'a', mode)
        c, t = rig.c, rig.t()
        if sl.MODES[mode]['labelled']:
            c.call(*t, 'LABEL', 'QUOTA', 'C', 'LIMIT', 50000000)
            c.call(*t, 'LABEL', 'QUOTA', 'C', 'LIMIT', 7000000, 'TRUST', 'VETTED')
            c.call(*t, 'LABEL', 'QUOTA', 'S//A', 'LIMIT', 60000000)
        if sl.MODES[mode]['owners']:
            c.call(*t, 'OWNERS', 'QUOTA', 'u1', 'LIMIT', 80000000)
            c.call(*t, 'OWNERS', 'QUOTA', 'u9', 'LIMIT', 70000)
        quotas = sl.quotas(c, mode)
        self.assertTrue(any(v for v in quotas.values()), quotas)
        rig.bounce()
        self.assertEqual(sl.quotas(rig.c, mode), quotas)
        rig.rewrite()
        rig.bounce()
        self.assertEqual(sl.quotas(rig.c, mode), quotas)
        if sl.MODES[mode]['labelled']:
            rig.c.call(*rig.t(), 'LABEL', 'QUOTA', 'C', 'LIMIT', 0)
            quotas = sl.quotas(rig.c, mode)
            rig.bounce()
            self.assertEqual(sl.quotas(rig.c, mode), quotas)

    def test_label_only_quotas_survive_a_replay_and_a_rewrite(self):
        self.check_quotas('labels')

    def test_owner_only_quotas_survive_a_replay_and_a_rewrite(self):
        self.check_quotas('owners')

    def test_both_quotas_survive_a_replay_and_a_rewrite(self):
        self.check_quotas('both')

    def test_a_quota_is_still_enforced_after_a_restart(self):
        rig = Rig(self, 'a', 'both')
        c, t = rig.c, rig.t()
        c.call(*t, 'OWNERS', 'QUOTA', 'tiny', 'LIMIT', 3000)
        p = user_scope('both', 'tiny')
        rig.bounce()
        with self.assertRaises(ServerError) as caught:
            for i in range(200):
                rig.c.call(*p, 'SET', 'k%d' % i, 'x' * 100)
        self.assertIn('quota', str(caught.exception).lower())


class Scheme(Base):
    NEW_NAMES = ['--label-levels', 'U,C,S,TS', '--label-compartments', 'A,Z', '--label-trust-levels', 'WEB,VETTED,GOLD']
    READS = [('U', None), ('C', None), ('S//A', None), ('TS//A/Z', None), ('C;VETTED', None)]

    def new_state(self, c, top='TS//A/Z', reads=None):
        t = ('LABEL', 'AS', top)
        return {'scopes': c.call(*t, 'DEBUG', 'DIGEST-SCOPES'), 'digest': c.call(*t, 'DEBUG', 'DIGEST'),
                'views': {r: sl.view(c, 'labels', *r) for r in (self.READS if reads is None else reads)}}

    def seed_old(self, c):
        t = ('LABEL', 'AS', 'S//A/B')
        c.call(*t, 'SET', 'before-rename', 'x')
        c.call(*t, 'RPUSH', 'list', 1, 2, 3)
        c.call('LABEL', 'AS', 'C', 'SET', 'c-key', 'c')
        c.call('LABEL', 'AS', 'U', 'SET', 'u-key', 'u')
        c.call('LABEL', 'AS', 'S//A', 'HSET', 'h', 'f', 'v')
        c.call('LABEL', 'AS', 'S//A/B', 'VADD', 'vec', 'VALUES', 3, 1, 2, 3, 'e1')

    def change_all(self, c):
        steps = [(('LABEL', 'AS', 'S//A/B'), ('LABEL', 'AS', 'S//A/Z'), 'label-compartments', 'A,Z'),
                 (('LABEL', 'AS', 'S//A/Z'), ('LABEL', 'AS', 'TS//A/Z'), 'label-levels', 'U,C,S,TS'),
                 (('LABEL', 'AS', 'TS//A/Z'), ('LABEL', 'AS', 'TS//A/Z'), 'label-trust-levels', 'WEB,VETTED,GOLD')]
        done = []
        for t, new_t, name, value in steps:
            before = sl.rewrites(c, 'labels', t)
            self.assertEqual(c.call(*t, 'CONFIG', 'SET', name, value), 'OK')
            after = sl.persistence(c, 'labels', new_t)
            self.assertEqual((int(after['aof_rewrites']), after['aof_rewrite_in_progress']), (before + 1, '0'), 'the log was not rewritten before the reply to ' + name)
            done.append(name)
        return done

    def test_a_rename_and_an_extension_rewrite_the_log_before_the_reply_and_a_restart_with_the_new_names_starts(self):
        s = self.server('a', 'labels')
        c = s.up()
        self.seed_old(c)
        self.change_all(c)
        t = ('LABEL', 'AS', 'TS//A/Z')
        c.call(*t, 'SET', 'after', 'y')
        c.call('LABEL', 'AS', 'S//A/Z', 'SET', 'at-renamed', 'z')
        rows = sl.records(sl.last_incr(s.run.directory).read_bytes())
        self.assertEqual(rows[0][0], sl.MARKER)
        self.assertIn([b'CONFIG', b'SET', b'label-trust-levels', b'WEB,VETTED,GOLD'], rows)
        self.assertTrue(all(sl.scoped(r)[0] is None for r in rows if r[:2] == [b'CONFIG', b'SET']))
        state = self.new_state(c)
        s.kill()
        s2 = self.server('a', 'labels')
        s2.run.arguments += self.NEW_NAMES
        c2 = s2.up()
        self.same(state, self.new_state(c2), 'the state before the kill and after a restart with the new names')
        self.assertEqual(c2.call('LABEL', 'AS', 'S//A/Z', 'GET', 'before-rename'), b'x')
        self.assertNotIn('Truncating', s2.run.log())

    def test_a_restart_with_the_old_names_after_a_rename_is_refused_as_for_a_snapshot_and_the_files_names_start_it(self):
        s = self.server('a', 'labels')
        c = s.up()
        self.seed_old(c)
        self.assertEqual(c.call('LABEL', 'AS', 'S//A/B', 'CONFIG', 'SET', 'label-compartments', 'A,Z'), 'OK')
        s.kill()
        code, text = self.server('a', 'labels').refused()
        self.assertEqual(code, 1)
        self.assertIn('names compartment 2 Z and the configured scheme names it B; configure the file', text)
        s2 = self.server('a', 'labels')
        s2.run.arguments += ['--label-compartments', 'A,Z']
        c2 = s2.up()
        self.assertEqual(c2.call('LABEL', 'AS', 'S//A/Z', 'GET', 'before-rename'), b'x')

    def test_a_restart_with_the_old_names_after_an_extension_adopts_the_files_scheme(self):
        s = self.server('a', 'labels')
        c = s.up()
        self.seed_old(c)
        self.assertEqual(c.call('LABEL', 'AS', 'S//A/B', 'CONFIG', 'SET', 'label-levels', 'U,C,S,TS'), 'OK')
        self.assertEqual(c.call('LABEL', 'AS', 'TS//A/B', 'CONFIG', 'SET', 'label-trust-levels', 'WEB,VETTED,GOLD'), 'OK')
        c.call('LABEL', 'AS', 'TS//A/B', 'SET', 'k', 'v')
        t = ('LABEL', 'AS', 'TS//A/B')
        state = (c.call(*t, 'DEBUG', 'DIGEST-SCOPES'), c.call(*t, 'DEBUG', 'DIGEST'))
        s.kill()
        s2 = self.server('a', 'labels')
        c2 = s2.up()
        self.assertIn('extends the configured label scheme', s2.run.log())
        self.assertEqual((c2.call(*t, 'DEBUG', 'DIGEST-SCOPES'), c2.call(*t, 'DEBUG', 'DIGEST')), state)
        self.assertEqual(c2.call(*t, 'GET', 'k'), b'v')
        self.assertEqual(c2.call('CONFIG', 'GET', 'label-levels')[1], b'U,C,S,TS')

    def test_the_loader_applies_a_logged_scheme_record_to_an_older_base(self):
        s = self.server('a', 'labels')
        c = s.up()
        c.call('LABEL', 'AS', 'S//A/B', 'SET', 'k', 'v')
        s.kill()
        incr = sl.last_incr(s.run.directory)
        rows = [[b'CONFIG', b'SET', b'label-compartments', b'A,Z'], [b'CONFIG', b'SET', b'label-levels', b'U,C,S,TS'],
                [b'LABEL', b'AS', b'TS//A/Z', b'SET', b'in-new-names', b'y']]
        incr.write_bytes(incr.read_bytes() + sl.encode_records(rows))
        c2 = self.server('a', 'labels').up()
        self.assertEqual(c2.call('CONFIG', 'GET', 'label-compartments')[1], b'A,Z')
        self.assertEqual(c2.call('CONFIG', 'GET', 'label-levels')[1], b'U,C,S,TS')
        self.assertEqual(c2.call('LABEL', 'AS', 'TS//A/Z', 'MGET', 'k', 'in-new-names'), [b'v', b'y'])

    def test_debug_loadaof_right_after_a_rename_and_an_extension_works(self):
        s = self.server('a', 'labels')
        c = s.up()
        self.seed_old(c)
        self.change_all(c)
        t = ('LABEL', 'AS', 'TS//A/Z')
        c.call(*t, 'SET', 'after', 'y')
        state = self.new_state(c)
        self.assertEqual(c.call(*t, 'DEBUG', 'LOADAOF'), 'OK')
        self.same(state, self.new_state(c), 'the state before and after DEBUG LOADAOF after the changes')

    def test_with_snapshots_and_the_log_both_files_load_after_a_rename(self):
        s = self.server('a', 'labels', extra=('--save', '900 1'))
        c = s.up()
        self.seed_old(c)
        self.assertEqual(c.call('LABEL', 'AS', 'S//A/B', 'CONFIG', 'SET', 'label-compartments', 'A,Z'), 'OK')
        state = self.new_state(c, 'S//A/Z', self.READS[:3])
        d = s.run.directory
        self.assertTrue((d / 'dump.rdb').exists())
        s.kill()
        with_log = self.server('a', 'labels', extra=('--save', '900 1'))
        with_log.run.arguments += ['--label-compartments', 'A,Z']
        c2 = with_log.up()
        t = ('LABEL', 'AS', 'S//A/Z')
        self.assertEqual((c2.call(*t, 'DEBUG', 'DIGEST-SCOPES'), c2.call(*t, 'DEBUG', 'DIGEST')), (state['scopes'], state['digest']))
        with_log.kill()
        snapshot_only = self.server('a', 'labels', extra=('--appendonly', 'no', '--label-compartments', 'A,Z'))
        c3 = snapshot_only.up()
        self.assertEqual((c3.call(*t, 'DEBUG', 'DIGEST-SCOPES'), c3.call(*t, 'DEBUG', 'DIGEST')), (state['scopes'], state['digest']))
        self.assertEqual(c3.call(*t, 'GET', 'before-rename'), b'x')

    def test_a_log_that_cannot_be_rewritten_refuses_the_change_and_both_files_load_with_the_old_scheme(self):
        s = self.server('a', 'labels', extra=('--save', '900 1'))
        c = s.up()
        self.seed_old(c)
        d = s.run.directory
        log = d / 'appendonlydir'
        t = ('LABEL', 'AS', 'S//A/B')
        old = (c.call(*t, 'DEBUG', 'DIGEST-SCOPES'), c.call(*t, 'DEBUG', 'DIGEST'))
        os.chmod(log, 0o500)
        try:
            with self.assertRaises(ServerError) as caught:
                c.call(*t, 'CONFIG', 'SET', 'label-compartments', 'A,Z')
            self.assertIn('the append-only file with the new label scheme or owner mode could not be written', str(caught.exception))
            self.assertEqual(c.call('CONFIG', 'GET', 'label-compartments')[1], b'A,B')
            self.assertEqual(c.call(*t, 'SET', 'still-works', 'yes'), 'OK')
            self.assertEqual(c.call(*t, 'GET', 'before-rename'), b'x')
        finally:
            os.chmod(log, 0o700)
        after_old = (c.call(*t, 'DEBUG', 'DIGEST-SCOPES'), c.call(*t, 'DEBUG', 'DIGEST'))
        s.kill()
        again = self.server('a', 'labels', extra=('--save', '900 1'))
        c2 = again.up()
        self.assertEqual(c2.call(*t, 'GET', 'still-works'), b'yes')
        self.assertEqual(c2.call(*t, 'GET', 'before-rename'), b'x')
        self.assertEqual(c2.call(*t, 'DEBUG', 'DIGEST'), after_old[1])
        self.assertEqual(c2.call('CONFIG', 'GET', 'label-compartments')[1], b'A,B')
        again.kill()
        snapshot_only = self.server('a', 'labels', extra=('--appendonly', 'no'))
        c3 = snapshot_only.up()
        self.assertEqual(c3.call(*t, 'GET', 'before-rename'), b'x')
        self.assertEqual(c3.call('CONFIG', 'GET', 'label-compartments')[1], b'A,B')

    def test_a_scheme_change_inside_a_transaction_is_refused_while_the_log_is_on(self):
        s = self.server('a', 'labels')
        c = s.up()
        self.seed_old(c)
        t = ('LABEL', 'AS', 'S//A/B')
        c.call(*t, 'MULTI')
        c.call('SET', 'in-tx', '1')
        c.call('CONFIG', 'SET', 'label-compartments', 'A,Z')
        reply = c.call('EXEC')
        self.assertEqual(reply[0], 'OK')
        self.assertIsInstance(reply[1], ServerError)
        self.assertIn('could not be written', str(reply[1]))
        self.assertEqual(c.call('CONFIG', 'GET', 'label-compartments')[1], b'A,B')
        state = (c.call(*t, 'DEBUG', 'DIGEST-SCOPES'), c.call(*t, 'DEBUG', 'DIGEST'))
        s.kill()
        c2 = self.server('a', 'labels').up()
        self.assertEqual((c2.call(*t, 'DEBUG', 'DIGEST-SCOPES'), c2.call(*t, 'DEBUG', 'DIGEST')), state)

    def test_a_replayed_scheme_change_writes_no_audit_record_and_no_snapshot(self):
        d = self.directory('a')
        audit = d / 'audit.json'
        s = self.server('a', 'labels', extra=('--label-audit-file', str(audit), '--save', '900 1'))
        c = s.up()
        t = ('LABEL', 'AS', 'S//A/B')
        c.call(*t, 'SET', 'k', 'v')
        self.assertEqual(c.call(*t, 'CONFIG', 'SET', 'label-compartments', 'A,B,KB'), 'OK')
        lines = audit.read_text().count('scheme-change')
        self.assertEqual(lines, 1)
        dump = d / 'dump.rdb'
        s.kill()
        dump.unlink(missing_ok=True)
        s2 = self.server('a', 'labels', extra=('--label-audit-file', str(audit), '--save', '900 1'))
        c2 = s2.up()
        self.assertEqual(c2.call('CONFIG', 'GET', 'label-compartments')[1], b'A,B,KB')
        self.assertEqual(audit.read_text().count('scheme-change'), 1)
        self.assertFalse(dump.exists(), 'the replay of a scheme change saved a snapshot in the middle of the load')

    def test_a_client_cannot_change_the_scheme_while_the_log_loads(self):
        s = self.server('a', 'labels')
        c = s.up()
        p = sl.at('labels', 'C')
        for i in range(80):
            c.call(*p, 'SET', 'k%d' % i, 'v')
        s.kill()
        slow = self.server('a', 'labels', extra=('--key-load-delay', '30000', '--loading-process-events-interval-bytes', '1024', '--user', 'default', *sl.OPERATOR))
        client = slow.run.launch()
        refused = None
        try:
            client.call('CONFIG', 'SET', 'label-levels', 'U,C,S,TS')
        except ServerError as e:
            refused = str(e)
        self.assertIsNotNone(refused, 'a client changed the scheme while the log was loading')
        self.assertIn('LOADING', refused)

        def served():
            try:
                return client.call('PING') == 'PONG'
            except ServerError as e:
                if 'LOADING' in str(e):
                    return False
                raise
        sl.wait_for(served, 60, 'the load to end')
        client.call('ACL', 'SETUSER', 'default', *sl.OPERATOR)
        self.assertEqual(client.call('CONFIG', 'GET', 'label-levels')[1], b'U,C,S')
        self.assertEqual(client.call(*p, 'DBSIZE'), 80)

    def test_a_scheme_extension_in_the_log_extends_a_shorter_configuration(self):
        s = self.server('a', 'labels')
        c = s.up()
        self.assertEqual(c.call('LABEL', 'AS', 'S//A/B', 'CONFIG', 'SET', 'label-levels', 'U,C,S,TS'), 'OK')
        c.call('LABEL', 'AS', 'TS//A/B', 'SET', 'k', 'v')
        s.kill()
        c2 = self.server('a', 'labels').up()
        self.assertEqual(c2.call('LABEL', 'AS', 'TS//A/B', 'GET', 'k'), b'v')

    def test_a_scheme_extension_survives_a_rewrite_then_a_restart_with_the_extended_configuration(self):
        s = self.server('a', 'labels')
        c = s.up()
        self.assertEqual(c.call('LABEL', 'AS', 'S//A/B', 'CONFIG', 'SET', 'label-levels', 'U,C,S,TS'), 'OK')
        c.call('LABEL', 'AS', 'TS//A/B', 'SET', 'k', 'v')
        ts = ('LABEL', 'AS', 'TS//A/B')
        before = sl.rewrites(c, 'labels', ts)
        c.call(*ts, 'BGREWRITEAOF')
        sl.wait_rewritten(c, 'labels', before, prefix=ts)
        s.kill()
        s2 = self.server('a', 'labels')
        s2.run.arguments += ['--label-levels', 'U,C,S,TS']
        c2 = s2.up()
        self.assertEqual(c2.call('LABEL', 'AS', 'TS//A/B', 'GET', 'k'), b'v')


class Mismatch(Base):
    KINDS = ('plain', 'labels', 'owners', 'both')

    def make(self, kind, name):
        s = self.plain(name) if kind == 'plain' else self.server(name, kind)
        c = s.up()
        if kind == 'plain':
            c.call('SET', 'k', 'v')
        else:
            c.call(*sl.at(kind, *ll.SCOPES[kind]['low']), 'SET', 'k', 'v')
        s.kill()
        return s

    def reopen(self, kind, name):
        if kind == 'plain':
            return self.plain(name)
        return self.server(name, kind)

    def check_matrix(self, rewritten):
        for written in self.KINDS:
            for run in self.KINDS:
                if written == run:
                    continue
                name = 'm-%s-%s-%d' % (written, run, rewritten)
                s = self.make(written, name)
                if rewritten:
                    s2 = self.reopen(written, name)
                    c = s2.up()
                    t = sl.top(written) if written != 'plain' else ()
                    before = sl.rewrites(c, written if written != 'plain' else '')
                    c.call(*t, 'BGREWRITEAOF')
                    sl.wait_for(lambda: int(sl.persistence(c, written if written != 'plain' else '')['aof_rewrites']) > before and sl.persistence(c, written if written != 'plain' else '')['aof_rewrite_in_progress'] == '0', 30, 'the rewrite')
                    s2.kill()
                code, text = self.reopen(run, name).refused()
                self.assertEqual(code, 1, '%s log on a %s server: %s' % (written, run, text[-800:]))
                if written == 'plain':
                    self.assertIn('carries no labels or owners', text)
                elif run == 'plain':
                    self.assertIn('holds data with labels or owners', text)
                else:
                    self.assertIn('was written with', text)
                    self.assertIn('and this server runs with', text)
                self.assertNotIn('panic', text.lower())
                self.assertEqual(self.reopen(written, name).up().call(*(sl.at(written, *ll.SCOPES[written]['low']) if written != 'plain' else ()), 'GET', 'k'), b'v')

    def test_every_mode_mismatch_is_refused_in_both_directions(self):
        self.check_matrix(False)

    def test_every_mode_mismatch_is_refused_after_a_rewrite_too(self):
        self.check_matrix(True)


class Torn(Base):
    def build(self, mode):
        rig = Rig(self, 'src', mode)
        w = rig.world
        p = sl.at(mode, *ll.SCOPES[mode]['high'])
        w.pair.call(*p, 'SET', 'first', 'one')
        w.pair.call(*p, 'MULTI')
        w.pair.call('SET', 'group-a', '1')
        w.pair.call('INCR', 'group-n')
        w.pair.call('EXEC')
        w.case_set_nx()
        w.reap()
        w.pair.call(*p, 'RPUSH', 'list', 'x', 'y')
        w.pair.call(*p, 'SET', 'last', 'tail')
        rig.server.kill()
        incr = sl.last_incr(rig.server.run.directory)
        return rig, incr.read_bytes(), incr.name

    def load(self, mode, name, source, incr_name, content, extra=()):
        d = self.root / name
        sl.copy_tree(source, d)
        (d / 'appendonlydir' / incr_name).write_bytes(content)
        s = sl.Server(BINARY, d, mode, extra, KEYSPACE_THREADS)
        self.servers.append(s)
        return s

    def cases(self, data):
        spans = [x for x in sl.record_spans(data) if x[2] is not None]
        out = [('inside the marker', spans[0][0] + 12, 0)]
        i = 1
        while i < len(spans):
            a, b, argv = spans[i]
            if argv[0] == b'MULTI':
                j = next(k for k in range(i, len(spans)) if spans[k][2][0] == b'EXEC')
                group = spans[i:j + 1]
                out.append(('after MULTI of the group at %d' % i, group[0][1], a))
                for k in range(1, len(group) - 1):
                    inner = sl.scoped(group[k][2])[1]
                    kind = 'a log-only deletion record' if inner[:1] == [b'DEL'] else 'inner record %d' % k
                    out.append(('after %s of the group at %d' % (kind, i), group[k][1], a))
                    out.append(('inside inner record %d of the group at %d' % (k, i), group[k][0] + 9, a))
                out.append(('inside EXEC of the group at %d' % i, group[-1][0] + 7, a))
                out.append(('one byte short of EXEC of the group at %d' % i, group[-1][1] - 1, a))
                i = j + 1
                continue
            out.append(('inside the head of record %d' % i, a + 3, a))
            out.append(('inside the command of record %d' % i, b - 4, a))
            out.append(('one byte short of record %d' % i, b - 1, a))
            i += 1
        return out

    def check_cases(self, mode):
        rig, data, incr_name = self.build(mode)
        source = rig.server.run.directory
        cases = self.cases(data)
        self.assertGreater(len(cases), 14)
        self.assertTrue(any('log-only deletion' in what for what, _, _ in cases), 'the log holds no deletion record inside a group')
        for n, (what, cut, boundary) in enumerate(cases):
            torn = self.load(mode, 'torn%d' % n, source, incr_name, data[:cut])
            clean = self.load(mode, 'clean%d' % n, source, incr_name, data[:boundary])
            ct = torn.up()
            cc = clean.up()
            for c in (ct, cc):
                c.call(*sl.at(mode, *ll.SCOPES[mode]['low']), 'EXISTS', 'e2')
                c.call(*sl.at(mode, *ll.SCOPES[mode]['high']), 'SET', 'probe', 'p')
            full = n % 6 == 0
            self.same(fingerprint(ct, mode, full=full), fingerprint(cc, mode, full=full), 'the torn load (%s, cut at %d, boundary %d) and a clean load of the boundary' % (what, cut, boundary))
            self.assertIn('Truncating the AOF', torn.run.log(), what)
            expected = data[:boundary] if boundary else sl.encode_records([[sl.MARKER, b'1', b'1' if sl.MODES[mode]['labelled'] else b'0', b'1' if sl.MODES[mode]['owners'] else b'0']])
            for server in (torn, clean):
                written = (server.run.directory / 'appendonlydir' / incr_name).read_bytes()
                self.assertEqual(written[:len(expected)], expected, what)
                spans = sl.record_spans(written)
                self.assertEqual(spans[-1][1], len(written), what)
                self.assertIn(len(expected), [0] + [end for _, end, _ in spans], 'the file was cut inside a record: ' + what)
            torn.kill()
            clean.kill()

    def test_label_only_every_torn_tail_loads_the_last_complete_state(self):
        self.check_cases('labels')

    def test_owner_only_every_torn_tail_loads_the_last_complete_state(self):
        self.check_cases('owners')

    def test_both_every_torn_tail_loads_the_last_complete_state(self):
        self.check_cases('both')

    def test_a_complete_log_loads_without_truncating(self):
        rig, data, incr_name = self.build('both')
        s = self.load('both', 'whole', rig.server.run.directory, incr_name, data)
        s.up()
        self.assertNotIn('Truncating the AOF', s.run.log())

    def test_a_torn_tail_is_refused_when_truncation_is_not_allowed(self):
        rig, data, incr_name = self.build('both')
        spans = [x for x in sl.record_spans(data) if x[2] is not None]
        cut = spans[-1][1] - 2
        s = self.load('both', 'strict', rig.server.run.directory, incr_name, data[:cut], extra=('--aof-load-truncated', 'no'))
        code, text = s.refused()
        self.assertEqual(code, 1)
        self.assertIn('Unexpected end of file', text)
        self.assertEqual((s.run.directory / 'appendonlydir' / incr_name).read_bytes(), data[:cut])

    def test_a_torn_tail_in_a_file_that_is_not_the_last_is_fatal(self):
        rig = Rig(self, 'src', 'both', extra=SLOW)
        w = rig.world
        p = sl.at('both', *ll.SCOPES['both']['high'])
        c = rig.c
        for i in range(30):
            c.call(*p, 'SET', 'seed-%d' % i, 'v')
        before = sl.rewrites(c, 'both')
        c.call(*rig.t(), 'BGREWRITEAOF')
        sl.wait_for(lambda: rig.info()['aof_rewrite_in_progress'] == '1', 20, 'the rewrite child')
        c.call(*p, 'SET', 'during', 'x')
        rig.server.kill()
        files = sl.incr_files(rig.server.run.directory)
        self.assertEqual(len(files), 2)
        first, second = files
        data = first.read_bytes()
        spans = [x for x in sl.record_spans(data) if x[2] is not None]
        d = self.root / 'second'
        sl.copy_tree(rig.server.run.directory, d)
        (d / 'appendonlydir' / first.name).write_bytes(data[:spans[-1][1] - 3])
        s = sl.Server(BINARY, d, 'both', (), KEYSPACE_THREADS)
        self.servers.append(s)
        code, text = s.refused()
        self.assertEqual(code, 1)
        self.assertIn('the truncated file is not the last file', text)
        d2 = self.root / 'third'
        sl.copy_tree(rig.server.run.directory, d2)
        tail = second.read_bytes()
        (d2 / 'appendonlydir' / second.name).write_bytes(tail + b'*3\r\n$3\r\nSET\r\n$2\r\nab')
        s2 = sl.Server(BINARY, d2, 'both', (), KEYSPACE_THREADS)
        self.servers.append(s2)
        c2 = s2.up()
        self.assertEqual(c2.call(*p, 'GET', 'during'), b'x')
        self.assertIn('Truncating the AOF', s2.run.log())


class LoadAof(Base):
    def check_loadaof(self, mode):
        rig = Rig(self, 'a', mode)
        w = rig.world
        w.cases()
        w.reap()
        for name in ('low', 'high', 'side'):
            w.ordinary(w.s(name), name)
        w.shared_names()
        w.declassify()
        w.operators()
        before = fingerprint(rig.c, mode, full=True)
        self.assertEqual(rig.c.call(*rig.t(), 'DEBUG', 'LOADAOF'), 'OK')
        self.same(before, fingerprint(rig.c, mode, full=True), 'the state before and after DEBUG LOADAOF')
        rig.world.pair = rig.pair
        w.later()
        later = fingerprint(rig.c, mode, full=True)
        before_rewrite = sl.rewrites(rig.c, mode)
        rig.c.call(*rig.t(), 'BGREWRITEAOF')
        sl.wait_rewritten(rig.c, mode, before_rewrite)
        self.assertEqual(rig.c.call(*rig.t(), 'DEBUG', 'LOADAOF'), 'OK')
        self.same(later, fingerprint(rig.c, mode, full=True), 'the state before and after DEBUG LOADAOF over a rewritten log')
        rig.c.call(*rig.t(), 'ACL', 'SETUSER', 'lowuser', 'on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*', *(('owners:*',) if sl.MODES[mode]['owners'] else ()))
        low_client = rig.server.client('lowuser')
        low = sl.at(mode, *sl.READERS[mode][1])
        with self.assertRaises(ServerError) as caught:
            low_client.call(*low, 'DEBUG', 'LOADAOF')
        self.assertTrue('dominates' in str(caught.exception) or 'owner-operator' in str(caught.exception), str(caught.exception))
        with self.assertRaises(ServerError) as caught:
            low_client.call(*low, 'BGREWRITEAOF')
        self.assertTrue('dominates' in str(caught.exception) or 'owner-operator' in str(caught.exception), str(caught.exception))

    def test_label_only_debug_loadaof_reloads_the_state(self):
        self.check_loadaof('labels')

    def test_owner_only_debug_loadaof_reloads_the_state(self):
        self.check_loadaof('owners')

    def test_both_debug_loadaof_reloads_the_state(self):
        self.check_loadaof('both')

    def test_loadaof_keeps_the_forget_sequence_and_the_forgotten_stay_gone(self):
        rig = Rig(self, 'a', 'both', extra=('--owners-forget-aof-delay', '0'))
        c, t = rig.c, rig.t()
        populate(c, 'both', 'gone-user', 'GONE')
        populate(c, 'both', 'kept-user', 'KEPT')
        c.call(*t, 'OWNERS', 'FORGET', 'gone-user')
        c.call(*t, 'OWNERS', 'FORGET', 'never-seen')
        before = rig.info()
        self.assertEqual(c.call(*t, 'DEBUG', 'LOADAOF'), 'OK')
        after = rig.info()
        for k in ('owners_forget_sequence', 'owners_forget_in_aof'):
            self.assertEqual(before[k], after[k], k)
        self.assertIsNone(c.call(*user_scope('both', 'gone-user'), 'GET', 'key-GONE'))
        self.assertEqual(c.call(*user_scope('both', 'kept-user'), 'GET', 'key-KEPT'), b'value-KEPT')

    def refused_load(self, mode, content, reason):
        rig = Rig(self, 'refused-' + mode, mode)
        c = rig.c
        p = sl.at(mode, *ll.SCOPES[mode]['high'])
        c.call(*p, 'SET', 'present', 'yes')
        incr = sl.last_incr(rig.server.run.directory)
        good = incr.read_bytes()
        mark = len(rig.server.run.log())
        incr.write_bytes(content)
        with self.assertRaises(ServerError) as caught:
            c.call(*rig.t(), 'DEBUG', 'LOADAOF')
        self.assertIn('Error trying to load the AOF files', str(caught.exception))
        self.assertIn(reason, rig.server.run.log()[mark:])
        for db in range(4):
            c.call('SELECT', db)
            self.assertEqual(c.call(*rig.t(), 'DBSIZE'), 0, 'the keyspace is not empty after a refused load (database %d)' % db)
        c.call('SELECT', 0)
        self.assertEqual(c.call('PING'), 'PONG')
        self.assertEqual(rig.server.run.process.poll(), None)
        return rig, good

    def test_a_refused_runtime_load_leaves_the_keyspace_empty_and_the_server_up(self):
        for mode in MODES:
            rows = [[sl.MARKER, b'1', b'1' if sl.MODES[mode]['labelled'] else b'0', b'1' if sl.MODES[mode]['owners'] else b'0'], [b'SELECT', b'0'],
                    [b'LABEL', b'AS', b'TOPSECRET', b'SET', b'k', b'v']]
            rig, good = self.refused_load(mode, sl.encode_records(rows), 'does not parse')
            sl.last_incr(rig.server.run.directory).write_bytes(good)
            self.assertEqual(rig.c.call(*rig.t(), 'DEBUG', 'LOADAOF'), 'OK')
            self.assertEqual(rig.c.call(*sl.at(mode, *ll.SCOPES[mode]['high']), 'GET', 'present'), b'yes')

    def test_a_runtime_load_of_a_base_with_another_scheme_is_refused_before_the_flush(self):
        rig = Rig(self, 'a', 'labels')
        c = rig.c
        t = ('LABEL', 'AS', 'S//A/B')
        c.call(*t, 'SET', 'k', 'v')
        old_base = None
        for line in (rig.server.run.directory / 'appendonlydir' / 'appendonly.aof.manifest').read_text().splitlines():
            parts = line.split()
            if 'type' in parts and parts[parts.index('type') + 1] == 'b':
                old_base = rig.server.run.directory / 'appendonlydir' / parts[parts.index('file') + 1]
        old_bytes = old_base.read_bytes()
        self.assertEqual(c.call(*t, 'CONFIG', 'SET', 'label-compartments', 'A,Z'), 'OK')
        t = ('LABEL', 'AS', 'S//A/Z')
        current = sl.manifest_files(rig.server.run.directory)
        base = [n for n in current if n.endswith('.base.rdb')][0]
        (rig.server.run.directory / 'appendonlydir' / base).write_bytes(old_bytes)
        with self.assertRaises(ServerError) as caught:
            c.call(*t, 'DEBUG', 'LOADAOF')
        self.assertIn('Error trying to load the AOF files', str(caught.exception))
        self.assertIn('Refusing to load the append-only base', rig.server.run.log())
        self.assertEqual(c.call(*t, 'GET', 'k'), b'v')


class Misc(Base):
    def test_a_replayed_flushall_does_not_save_in_the_middle_of_the_load(self):
        for mode in MODES:
            rig = Rig(self, 'f-' + mode, mode, extra=('--save', '900 1'))
            p = sl.at(mode, *ll.SCOPES[mode]['high'])
            rig.c.call(*p, 'SET', 'before', 'x')
            if sl.MODES[mode]['owners']:
                rig.keeper.call('LABEL', 'AS', sl.MODES[mode]['top'], 'FLUSHALL')
            else:
                rig.c.call(*rig.t(), 'FLUSHALL')
            rig.c.call(*p, 'SET', 'after', 'y')
            d = rig.server.run.directory
            rig.server.kill()
            (d / 'dump.rdb').unlink(missing_ok=True)
            rig.start()
            self.assertFalse((d / 'dump.rdb').exists(), 'the load saved a snapshot of a part of the data')
            self.assertEqual(rig.c.call(*p, 'MGET', 'before', 'after'), [None, b'y'])

    def test_scan_cursors_and_owner_list_cursors_are_the_same_after_a_restart(self):
        for mode in MODES:
            rig = Rig(self, 'c-' + mode, mode)
            w = rig.world
            for name in ('low', 'mid', 'high', 'side'):
                w.ordinary(w.s(name), name)
            w.shared_names()
            w.operators()
            traces = {}

            def trace(c):
                out = {}
                for r in sl.READERS[mode]:
                    p = sl.at(mode, *r)
                    steps = []
                    cursor = b'0'
                    while True:
                        cursor, batch = c.call(*p, 'SCAN', cursor, 'COUNT', 3)
                        steps.append((cursor, tuple(batch)))
                        if cursor == b'0':
                            break
                    out[r] = steps
                if sl.MODES[mode]['owners']:
                    steps = []
                    cursor = b'0'
                    while True:
                        cursor, batch = c.call(*sl.top(mode), 'OWNERS', 'LIST', cursor, 'COUNT', 2)
                        steps.append((cursor, tuple(batch)))
                        if cursor == b'0':
                            break
                    out['owners'] = steps
                return out
            before = trace(rig.c)
            rig.bounce()
            after = trace(rig.c)
            for key in before:
                self.assertEqual(before[key], after[key], 'cursor sequence of %r differs after the restart (%s)' % (key, mode))

    def test_a_write_refused_after_its_partition_was_made_leaves_the_same_view_after_a_restart(self):
        for mode in ('labels', 'both'):
            rig = Rig(self, 'r-' + mode, mode)
            owner = '' if mode == 'labels' else 'u1'
            low = sl.at(mode, 'C', owner or None)
            high = sl.at(mode, 'S//A', owner or None)
            rig.c.call(*low, 'SET', 'name', 'low')
            with self.assertRaises(ServerError):
                rig.c.call(*high, 'SET', 'name', 'high')
            state = fingerprint(rig.c, mode, full=True)
            rig.bounce()
            after = fingerprint(rig.c, mode, full=True)
            views_before = state.pop('views')
            views_after = after.pop('views')
            self.same(views_before, views_after, 'the readers views after a refused write and a restart (%s)' % mode)
            self.same(state, after, 'the digests after a refused write and a restart (%s)' % mode)

    def test_a_stale_temporary_file_and_an_orphan_log_file_are_removed_at_startup(self):
        rig = Rig(self, 'a', 'both')
        rig.c.call(*sl.at('both', 'C', 'u1'), 'SET', 'k', 'v')
        d = rig.server.run.directory
        rig.server.kill()
        log = d / 'appendonlydir'
        (log / 'temp-appendonly.aof.incr').write_bytes(b'secret-u1')
        (log / 'appendonly.aof.9.incr.aof').write_bytes(b'secret-orphan')
        (log / 'appendonly.aof.9.base.rdb').write_bytes(b'secret-orphan')
        (d / 'temp-rewriteaof-bg-99999999.aof').write_bytes(b'secret-orphan')
        (log / 'notes.txt').write_bytes(b'kept')
        rig.start()
        self.assertEqual(sorted(p.name for p in log.iterdir()), sorted(sl.manifest_files(d) | {'notes.txt'}))
        self.assertFalse((d / 'temp-rewriteaof-bg-99999999.aof').exists())
        self.assertEqual(rig.c.call(*sl.at('both', 'C', 'u1'), 'GET', 'k'), b'v')

    def test_log_files_are_left_alone_when_the_manifest_is_missing(self):
        rig = Rig(self, 'a', 'both')
        rig.c.call(*sl.at('both', 'C', 'u1'), 'SET', 'k', 'v')
        d = rig.server.run.directory
        rig.server.kill()
        log = d / 'appendonlydir'
        (log / 'appendonly.aof.manifest').unlink()
        (log / 'appendonly.aof.7.incr.aof').write_bytes(b'keep-me')
        rig.start()
        self.assertEqual((log / 'appendonly.aof.7.incr.aof').read_bytes(), b'keep-me')

    def test_the_files_of_a_labelled_log_are_private(self):
        for mode in MODES:
            rig = Rig(self, 'p-' + mode, mode)
            rig.c.call(*sl.at(mode, *ll.SCOPES[mode]['high']), 'SET', 'k', 'v')
            rig.rewrite()
            d = rig.server.run.directory / 'appendonlydir'
            for p in d.iterdir():
                try:
                    bits = p.stat().st_mode
                except FileNotFoundError:
                    continue
                self.assertEqual(bits & 0o077, 0, '%s is readable by others' % p.name)
            self.assertEqual(d.stat().st_mode & 0o077, 0)

    def test_a_server_without_labels_keeps_the_usual_file_modes(self):
        s = self.plain('a')
        c = s.up()
        c.call('SET', 'k', 'v')
        for p in (s.run.directory / 'appendonlydir').iterdir():
            self.assertEqual(p.stat().st_mode & 0o044, 0o044, p.name)


RENAMED = ('--label-compartments', 'A,Z')
CHANGES = {
    'labels': ('', None, ('CONFIG', 'SET') + TurnOn.SCHEME_ARGS, 'labels', ()),
    'owners': ('', None, ('CONFIG', 'SET', 'owners', 'yes'), 'owners', ()),
    'owners-onto-labels': ('labels', (), ('CONFIG', 'SET', 'owners', 'yes'), 'both', ()),
    'rename': ('labels', (), ('CONFIG', 'SET', 'label-compartments', 'A,Z'), 'labels', RENAMED),
}
KILL_STEPS = (
    ('temp', 'open,openat', 1),
    ('temp', 'write', 1),
    ('incr', 'open,openat', 1),
    ('temp', 'rename,renameat,renameat2', 1),
    ('manifest', 'open,openat', 1),
    ('manifest', 'rename,renameat,renameat2', 1),
    ('incr', 'write', 1),
    ('manifest', 'open,openat', 2),
)


class ModeChangeFiles(Base):
    def start(self, name, mode, extra=()):
        s = self.server(name, mode, extra) if mode else self.plain(name)
        return s, s.up()

    def prefix(self, mode, extra=()):
        if not mode:
            return ()
        if extra == RENAMED:
            return ('LABEL', 'AS', 'S//A/Z')
        return sl.top(mode)

    def fill(self, c, mode, keys):
        p = self.prefix(mode)
        c.call(*p, 'FUNCTION', 'LOAD', ll.LIBRARY)
        c.call(*p, 'SET', 'warm', '1')
        c.call(*p, 'DEL', 'warm')
        if keys:
            for label in ('U', 'C', 'S//A', 'S//A/B'):
                c.call(*sl.at(mode, label), 'SET', 'k-' + label, 'v-' + label)

    def state(self, c, mode, extra=()):
        p = self.prefix(mode, extra)
        return c.call(*p, 'DEBUG', 'DIGEST'), c.call(*p, 'DBSIZE'), c.call(*p, 'FUNCTION', 'LIST')[0][1]

    def test_a_change_whose_base_cannot_be_written_leaves_the_log_in_the_old_mode(self):
        for name, (mode, _, trigger, _, _) in CHANGES.items():
            with self.subTest(change=name):
                s, c = self.start('w-' + name, mode)
                self.fill(c, mode, name == 'rename')
                d = s.run.directory
                os.chmod(d, 0o500)
                try:
                    with self.assertRaises(ServerError) as caught:
                        c.call(*self.prefix(mode), *trigger)
                    self.assertIn('could not be written', str(caught.exception))
                finally:
                    os.chmod(d, 0o700)
                p = self.prefix(mode)
                self.assertEqual(c.call(*p, 'SET', 'after-refusal', 'yes'), 'OK')
                want = self.state(c, mode)
                for f in sl.incr_files(d):
                    rows = sl.records(f.read_bytes())
                    markers = [r[2:] for r in rows if r and r[0] == sl.MARKER]
                    self.assertEqual(markers, [[b'1', b'0']] * len(markers) if mode else [], f.name)
                s.kill()
                s2, c2 = self.start('w-' + name, mode)
                self.assertEqual(c2.call(*p, 'GET', 'after-refusal'), b'yes')
                self.assertEqual(self.state(c2, mode), want)
                s2.kill()

    def test_a_change_refused_because_another_setting_of_the_command_fails_leaves_the_log_in_the_old_mode(self):
        for name in ('labels', 'owners'):
            with self.subTest(change=name):
                s, c = self.start('f-' + name, '')
                self.fill(c, '', False)
                with self.assertRaises(ServerError) as caught:
                    c.call(*CHANGES[name][2], 'bind', '192.0.2.1')
                self.assertIn('bind', str(caught.exception))
                self.assertEqual(c.call('CONFIG', 'GET', 'owners'), [b'owners', b'no'])
                self.assertEqual(c.call('SET', 'after-refusal', 'yes'), 'OK')
                want = self.state(c, '')
                for f in sl.incr_files(s.run.directory):
                    self.assertFalse([r for r in sl.records(f.read_bytes()) if r and r[0] == sl.MARKER], f.name)
                s.kill()
                s2, c2 = self.start('f-' + name, '')
                self.assertEqual(c2.call('GET', 'after-refusal'), b'yes')
                self.assertEqual(self.state(c2, ''), want)
                s2.kill()

    def kill_at(self, s, step, d, nxt):
        what, calls, when = step
        pid = s.run.process.pid
        paths = {
            'temp': ['temp-rewriteaof-bg-%d.aof' % pid, str(d / ('temp-rewriteaof-bg-%d.aof' % pid))],
            'incr': ['appendonlydir/appendonly.aof.%d.incr.aof' % nxt, str(d / 'appendonlydir' / ('appendonly.aof.%d.incr.aof' % nxt))],
            'manifest': ['appendonlydir/temp-appendonly.aof.manifest', str(d / 'appendonlydir' / 'temp-appendonly.aof.manifest')],
        }[what]
        cmd = ['strace', '-f', '-qq', '-o', '/dev/null', '-p', str(pid)]
        for p in paths:
            cmd += ['-P', p]
        cmd += ['-e', 'trace=' + calls, '-e', 'inject=%s:signal=KILL:when=%d' % (calls, when)]
        tracer = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: tracer.poll() is None and tracer.kill())
        end = time.monotonic() + 20
        while not re.search(r'TracerPid:\s*[1-9]', Path('/proc/%d/status' % pid).read_text()):
            if tracer.poll() is not None or time.monotonic() > end:
                self.skipTest('strace cannot attach to the server here')
            time.sleep(0.01)
        return tracer

    @unittest.skipUnless(shutil.which('strace'), 'needs strace')
    def test_a_kill_at_each_step_of_the_synchronous_rewrite_restarts_in_exactly_one_mode(self):
        for name in ('labels', 'rename'):
            mode, _, trigger, new_mode, new_extra = CHANGES[name]
            for i, step in enumerate(KILL_STEPS):
                with self.subTest(change=name, step=i):
                    run_name = 'k-%s-%d' % (name, i)
                    s, c = self.start(run_name, mode)
                    self.fill(c, mode, name == 'rename')
                    want = self.state(c, mode)
                    d = s.run.directory
                    nxt = max(int(f.name.split('.')[2]) for f in sl.incr_files(d)) + 1
                    tracer = self.kill_at(s, step, d, nxt)
                    try:
                        c.call(*self.prefix(mode), *trigger)
                    except (ServerError, EOFError, OSError):
                        pass
                    sl.wait_for(lambda: s.run.process.poll() is not None, 30, 'the kill')
                    self.assertEqual(s.run.process.poll(), -signal.SIGKILL)
                    s.run.process = None
                    tracer.wait(timeout=10)
                    after = i >= 6
                    load_mode, load_extra = (new_mode, new_extra) if after else (mode, ())
                    other_mode, other_extra = (mode, ()) if after else (new_mode, new_extra)
                    s2 = self.server(run_name, load_mode, load_extra) if load_mode else self.plain(run_name)
                    c2 = s2.up()
                    got = self.state(c2, load_mode, load_extra)
                    self.assertEqual(got[1:], want[1:])
                    if mode and load_mode == mode:
                        self.assertEqual(got[0], want[0])
                    s2.kill()
                    s3 = self.server(run_name, other_mode, other_extra) if other_mode else self.plain(run_name)
                    code, text = s3.refused()
                    self.assertEqual(code, 1)

    def private(self, d):
        self.assertEqual(d.stat().st_mode & 0o777, 0o700)
        for p in d.iterdir():
            try:
                bits = p.stat().st_mode & 0o777
            except FileNotFoundError:
                continue
            self.assertEqual(bits, 0o600, p.name)

    def test_the_log_directory_and_files_turn_private_on_every_path_that_takes_a_mode(self):
        for name in ('labels', 'owners'):
            with self.subTest(path='turn-on ' + name):
                s, c = self.start('m-' + name, '')
                c.call('SET', 'warm', '1')
                c.call('DEL', 'warm')
                self.assertEqual(sl.log_dir(s.run.directory).stat().st_mode & 0o777, 0o755)
                self.assertEqual(c.call(*CHANGES[name][2]), 'OK')
                self.private(sl.log_dir(s.run.directory))
                s.kill()
        with self.subTest(path='the log turned on with a mode on'):
            d = self.directory('m-log-on')
            (d / 'appendonlydir').mkdir()
            os.chmod(d / 'appendonlydir', 0o755)
            s = self.server('m-log-on', 'labels', ('--appendonly', 'no'))
            c = s.up()
            t = sl.top('labels')
            self.assertEqual(c.call(*t, 'CONFIG', 'SET', 'appendonly', 'yes'), 'OK')
            sl.wait_for(lambda: lf.info(c, *t)['aof_enabled'] == '1' and lf.info(c, *t)['aof_rewrite_in_progress'] == '0' and lf.info(c, *t)['aof_rewrite_scheduled'] == '0', 30, 'the log to be on')
            self.private(sl.log_dir(d))
            s.kill()
        with self.subTest(path='an old single-file log moved in at a start'):
            d = self.directory('m-old')
            (d / 'appendonlydir').mkdir()
            os.chmod(d / 'appendonlydir', 0o755)
            (d / 'appendonly.aof').write_bytes(b'*1\r\n$4\r\nPING\r\n')
            os.chmod(d / 'appendonly.aof', 0o644)
            s = self.server('m-old', 'labels')
            s.refused()
            self.assertFalse((d / 'appendonly.aof').exists())
            self.private(sl.log_dir(d))

    def test_a_refused_base_of_the_log_is_named_in_the_refusal(self):
        s, c = self.start('r', '')
        c.call('SET', 'k', 'v')
        before = sl.rewrites(c, '')
        c.call('BGREWRITEAOF')
        sl.wait_rewritten(c, '', before)
        s.kill()
        code, text = self.server('r', 'labels').refused()
        self.assertIn('Refusing to load the data file appendonlydir/appendonly.aof.2.base.rdb: it holds data that carries no labels', text)
        self.assertNotIn('data file dump.rdb', text)


def stream_view(c, key):
    def mask(v):
        if isinstance(v, list):
            out = []
            i = 0
            while i < len(v):
                if v[i] in (b'seen-time', b'active-time'):
                    out += [v[i], b'*']
                    i += 2
                    continue
                out.append(mask(v[i]))
                i += 1
            return out
        return v
    return mask(c.call('XINFO', 'STREAM', key, 'FULL'))


class CommandFormRewrite(Base):
    def rig(self, name):
        s = self.plain(name, extra=('--aof-use-rdb-preamble', 'no'))
        c = s.up()
        c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        return s, c

    def rewrite(self, c):
        before = sl.rewrites(c, '')
        c.call('BGREWRITEAOF')
        sl.wait_rewritten(c, '', before)

    def base_rows(self, d):
        return [r for p in sl.log_dir(d).iterdir() if p.name.endswith('.base.aof') for r in sl.records(p.read_bytes())]

    def test_a_command_form_rewrite_keeps_expired_hash_fields_and_the_hash_they_leave(self):
        s, c = self.rig('h')
        c.call('HSET', 'h', 'f', 'v')
        c.call('HPEXPIRE', 'h', 30, 'FIELDS', 1, 'f')
        c.call('HSET', 'h2', 'a', '1', 'b', '2')
        c.call('HPEXPIRE', 'h2', 30, 'FIELDS', 1, 'a')
        deadline = max(c.call('HPEXPIRETIME', 'h', 'FIELDS', 1, 'f')[0], c.call('HPEXPIRETIME', 'h2', 'FIELDS', 1, 'a')[0])
        sl.wait_for(lambda: (lambda now: int(now[0]) * 1000 + int(now[1]) // 1000)(c.call('TIME')) > deadline + 5, 10, 'the fields to expire')
        want = (c.call('EXISTS', 'h'), c.call('HLEN', 'h'), c.call('HLEN', 'h2'), c.call('HGETALL', 'h2'))
        self.assertEqual(want, (1, 1, 2, [b'b', b'2']))
        self.rewrite(c)
        rows = self.base_rows(s.run.directory)
        self.assertIn([b'HMSET', b'h', b'f', b'v'], rows)
        self.assertTrue(any(r[:2] == [b'HPEXPIREAT', b'h'] and r[3:] == [b'FIELDS', b'1', b'f'] for r in rows), rows)
        self.assertEqual(c.call('RENAME', 'h', 'z'), 'OK')
        self.assertEqual(c.call('DEBUG', 'LOADAOF'), 'OK')
        self.assertEqual((c.call('EXISTS', 'z'), c.call('HLEN', 'z'), c.call('HLEN', 'h2'), c.call('HGETALL', 'h2')), want)
        s.kill()

    def test_a_command_form_rewrite_keeps_pending_entries_whose_stream_entry_was_deleted(self):
        s, c = self.rig('x')
        c.call('XADD', 'one', '1-1', 'a', 'b')
        c.call('XGROUP', 'CREATE', 'one', 'g', '0')
        c.call('XREADGROUP', 'GROUP', 'g', 'c1', 'COUNT', 1, 'STREAMS', 'one', '>')
        c.call('XDEL', 'one', '1-1')
        c.call('XGROUP', 'CREATECONSUMER', 'one', 'g', 'idle')
        for i in range(1, 6):
            c.call('XADD', 'mixed', '1-%d' % i, 'a', i)
        c.call('XGROUP', 'CREATE', 'mixed', 'g1', '0')
        c.call('XGROUP', 'CREATE', 'mixed', 'g2', '0')
        c.call('XREADGROUP', 'GROUP', 'g1', 'c1', 'STREAMS', 'mixed', '>')
        c.call('XREADGROUP', 'GROUP', 'g2', 'c2', 'COUNT', 2, 'STREAMS', 'mixed', '>')
        c.call('XDEL', 'mixed', '1-2', '1-4')
        c.call('XACK', 'mixed', 'g1', '1-3')
        c.call('XADD', 'lowered', '3-1', 'a', 'b')
        c.call('XGROUP', 'CREATE', 'lowered', 'g', '0')
        c.call('XREADGROUP', 'GROUP', 'g', 'c', 'STREAMS', 'lowered', '>')
        c.call('XDEL', 'lowered', '3-1')
        c.call('XSETID', 'lowered', '3-1', 'ENTRIESADDED', 1, 'MAXDELETEDID', '0-0')
        keys = ('one', 'mixed', 'lowered')
        want = {k: stream_view(c, k) for k in keys}
        self.assertEqual(c.call('XPENDING', 'one', 'g')[0], 1)
        self.rewrite(c)
        self.assertEqual(c.call('DEBUG', 'LOADAOF'), 'OK')
        self.assertEqual({k: stream_view(c, k) for k in keys}, want)
        s.kill()
        c2 = self.plain('x', extra=('--aof-use-rdb-preamble', 'no')).up()
        self.assertEqual({k: stream_view(c2, k) for k in keys}, want)
        self.assertEqual(c2.call('XACK', 'one', 'g', '1-1'), 1)


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
