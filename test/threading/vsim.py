import argparse
import fnmatch
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vsim_support as vs
from support import Client, ROOT, ServerError, wait_for

BINARY = ROOT / 'bin/eski'
THREADS = 2
SEED = 0
FORCE = ('--vset-force-single-threaded-execution', 'yes')


def norm(value):
    if isinstance(value, ServerError):
        return ('error', str(value))
    if isinstance(value, list):
        return [norm(v) for v in value]
    return value


def peer(client):
    host, port = client.socket.getsockname()
    return '%s:%d' % (host, port)


class Base(unittest.TestCase):
    def server(self, workers=None, mode='plain', arguments=(), memory=512 << 20):
        s = vs.Server(BINARY, THREADS if workers is None else workers, mode, arguments, memory)
        self.addCleanup(s.close)
        s.start()
        return s

    def rng(self, n):
        return vs.seeded(SEED + n)

    def run(self, result=None):
        mark = None if result is None else len(result.failures) + len(result.errors)
        outcome = super().run(result)
        if result is not None and len(result.failures) + len(result.errors) > mark:
            sys.stderr.write('seed %d: rerun with --seed %d --compute-threads %d --case %s\n' % (SEED, SEED, THREADS, self._testMethodName))
        return outcome

    def jobs(self, n):
        return n if THREADS > 0 else 0

    def needs_threads(self):
        if THREADS == 0:
            self.skipTest('the case needs compute threads: with none, every search and commit runs at once')

    def expect_jobs(self, client, before, at_least, mode='plain'):
        after = vs.compute(client, mode)
        if THREADS > 0:
            self.assertGreaterEqual(after['compute_jobs_submitted'] - before['compute_jobs_submitted'], at_least)
        else:
            self.assertEqual(after['compute_jobs_submitted'], 0)
        return after

    def settle(self, client, mode='plain'):
        seen = []

        def quiet():
            seen[:] = [vs.compute(client, mode)]
            return seen[0]['compute_jobs_pending'] == 0

        wait_for(quiet, 60, 'no pending compute job')
        info = seen[0]
        self.assertEqual(info['compute_jobs_submitted'], info['compute_jobs_completed'] + info['compute_jobs_cancelled'])
        return info

    def gone(self, client, count, mode='plain'):
        wait_for(lambda: vs.connected(client, mode) == count, 60, 'the server to close every client that went away')

    def moved(self, client, before, mode='plain'):
        after = vs.compute(client, mode)
        return (after['compute_jobs_submitted'] - before['compute_jobs_submitted'],
                after['compute_sync_fallbacks'] - before['compute_sync_fallbacks'])

    def same_pairs(self, results, missing=(), visible=None):
        for command, threaded, inline in results:
            self.assertEqual(threaded, inline, 'threaded and inline replies differ for %r' % (command[:12],))
        return vs.threaded_count(results, missing, visible)

    def digest(self, c, mode):
        if mode == 'plain':
            return c.call('DEBUG', 'DIGEST')
        return c.call(*vs.top(mode), 'DEBUG', 'DIGEST-SCOPES')


class Pairs(Base):
    def keys_of(self, c, prefix_args, mode, entries):
        out = []
        for key, dim, names in entries:
            out.append((key, dim, names, c.call(*vs.at(mode, *prefix_args) if mode != 'plain' else (), 'VCARD', key)))
        return out

    def check_plain(self, resp, noise=False, extra=()):
        s = self.server(arguments=extra)
        c = s.client()
        if resp == 3:
            c.call('HELLO', 3)
        rng = self.rng(11 + resp)
        sets = []
        for quant in vs.QUANTS:
            key = 'v-' + quant.lower()
            if noise:
                names = vs.build_set(c, (), key, rng, 8, 160, quant=quant)
            else:
                vs.fill(c, (), key, rng, 8, 160, quant=quant)
                c.call('VREM', key, 'e7')
                c.call('VREM', key, 'e40')
                names = ['e%d' % i for i in range(160)]
            sets.append((key, 8, names))
        reduced = 'v-reduce'
        commands = [('VADD', reduced, 'REDUCE', 4, 'VALUES', 12, *vs.vector(rng, 12), 'r%d' % i, 'SETATTR', '{"a":%d}' % (i % 5)) for i in range(90)]
        for value in c.pipeline(commands):
            self.assertNotIsInstance(value, ServerError)
        sets.append((reduced, 12, ['r%d' % i for i in range(90)]))
        if noise:
            for key in ('noise-a', 'noise-b'):
                vs.fill(c, (), key, rng, 6, 90)
        raw = vs.Raw(c)
        before = vs.compute(c)
        total = 0

        def run():
            nonlocal total
            for key, dim, names in sets:
                total += self.same_pairs(vs.pairs(raw, (), key, vs.queries(rng, dim, names)), visible=c.call('VCARD', key))
            total += self.same_pairs(vs.pairs(raw, (), 'v-missing', [['VALUES', 8, *vs.vector(rng, 8)]]), ('v-missing',))
            total += self.same_pairs(vs.pairs(raw, (), 'v-q8', [['ELE', 'nosuch'], ['VALUES', 3, 1, 2, 3], ['VALUES', 8, *vs.vector(rng, 8), 'FILTER', '.a ==']]))

        if noise:
            others = [('noise-a', 6, 'Q8', ()), ('noise-b', 6, 'Q8', ())]
            with vs.Noise(s, 'plain', others, SEED + 5):
                run()
        else:
            run()
        self.assertGreater(total, 150)
        self.expect_jobs(c, before, total)
        after = self.settle(c)
        if THREADS and not noise:
            self.assertEqual(after['compute_jobs_submitted'] - before['compute_jobs_submitted'], total)

    def test_pairs_match_with_labels_off_resp2(self):
        self.check_plain(2)

    def test_pairs_match_with_labels_off_resp3(self):
        self.check_plain(3)

    def test_pairs_match_over_sets_with_holes_and_twins_beside_writers_of_other_sets(self):
        self.check_plain(2, noise=True)

    def test_pairs_match_beside_writers_in_resp3_with_keyspace_workers(self):
        self.check_plain(3, noise=True, extra=('--keyspace-threads', '2'))

    def test_pairs_match_with_a_label_scheme(self):
        s = self.server(mode='labels')
        c = s.client()
        rng = self.rng(23)
        layers = [('S//A', range(0, 620)), ('C', range(30, 110)), ('U', range(80, 150))]
        for quant in ('Q8', 'BIN'):
            key = 'lv-' + quant.lower()
            for label, span in layers:
                vs.fill(c, vs.at('labels', label), key, rng, 6, len(span), quant=quant, names=['e%d' % i for i in span])
        raw = vs.Raw(c)
        before = vs.compute(c, 'labels')
        total = 0
        names = ['e%d' % i for i in range(620)]
        for quant in ('Q8', 'BIN'):
            for reader in ('U', 'C', 'S//A', 'S//A/B', 'S//B', 'C;VETTED'):
                prefix = vs.at('labels', reader)
                visible = c.call(*prefix, 'VCARD', 'lv-' + quant.lower()) if reader != 'C;VETTED' else None
                total += self.same_pairs(vs.pairs(raw, prefix, 'lv-' + quant.lower(), vs.queries(rng, 6, names, 12)), ('C;VETTED',), visible)
        self.assertGreater(total, 60)
        self.expect_jobs(c, before, total, 'labels')
        after = self.settle(c, 'labels')
        if THREADS:
            self.assertEqual(after['compute_jobs_submitted'] - before['compute_jobs_submitted'], total)

    def test_pairs_match_in_owner_mode(self):
        s = self.server(mode='owners')
        c = s.client()
        rng = self.rng(29)
        key = 'ov'
        vs.fill(c, vs.at('owners', owner='u1'), key, rng, 5, 40, names=['e%d' % i for i in range(0, 40)])
        vs.fill(c, vs.at('owners', owner='u2'), key, rng, 5, 300, names=['e%d' % i for i in range(20, 320)])
        vs.fill(c, vs.at('owners'), key, rng, 5, 640, names=['e%d' % i for i in range(10, 650)])
        raw = vs.Raw(c)
        before = vs.compute(c, 'owners')
        total = 0
        names = ['e%d' % i for i in range(650)]
        for owner in (None, 'u1', 'u2', 'u3'):
            prefix = vs.at('owners', owner=owner)
            total += self.same_pairs(vs.pairs(raw, prefix, key, vs.queries(rng, 5, names, 20)), visible=c.call(*prefix, 'VCARD', key))
        self.assertGreater(total, 40)
        self.expect_jobs(c, before, total, 'owners')
        self.settle(c, 'owners')

    def check_views(self, mode, layers, readers, seed):
        s = self.server(mode=mode)
        c = s.client()
        rng = self.rng(seed)
        sets = []
        for key, dim, quant in (('w-q8', 6, 'Q8'), ('w-nq', 5, 'NOQUANT'), ('w-bin', 16, 'BIN')):
            for prefix, count in layers:
                names = vs.build_set(c, prefix, key, rng, dim, count, quant=quant)
            sets.append((key, dim, ['e%d' % i for i in range(max(n for unused, n in layers))]))
        noise = [('wn-a', 6, 'Q8', readers[0][1]), ('wn-b', 5, 'NOQUANT', readers[0][1])]
        for key, dim, quant, scope in noise:
            for prefix, count in layers[:1]:
                vs.build_set(c, vs.at(mode, *scope) if mode != 'plain' else (), key, rng, dim, 120, quant=quant)
        raw = vs.Raw(c)
        before = vs.compute(c, mode)
        total = 0
        with vs.Noise(s, mode, noise, SEED + seed, writers=2):
            for label, scope in readers:
                prefix = vs.at(mode, *scope)
                for key, dim, names in sets:
                    visible = c.call(*prefix, 'VCARD', key)
                    total += self.same_pairs(vs.pairs(raw, prefix, key, vs.queries(rng, dim, names, 10)), visible=visible)
        self.assertGreater(total, 40)
        self.expect_jobs(c, before, total, mode)
        self.settle(c, mode)

    def test_pairs_match_in_every_label_view_over_sets_with_holes_and_twins_beside_writers(self):
        layers = [(vs.at('labels', 'S//A'), 620), (vs.at('labels', 'C'), 150), (vs.at('labels', 'U'), 90)]
        readers = [(r, (r,)) for r in ('U', 'C', 'S//A', 'S//A/B', 'S//B')]
        self.check_views('labels', layers, readers, 31)

    def test_pairs_match_in_every_view_of_labels_and_owners_together_beside_writers(self):
        layers = []
        for owner in ('u1', 'u2', None):
            for label, count in (('S//A', 300), ('C', 150), ('U', 90)):
                layers.append((vs.at('both', label, owner), count))
        readers = [('%s/%s' % (o, label), (label, o)) for o in ('u1', 'u2', None, 'u9') for label in ('U', 'C', 'S//A')]
        self.check_views('both', layers, readers, 41)

    def test_pairs_match_in_every_owner_view_over_sets_with_holes_and_twins_beside_writers(self):
        layers = [(vs.at('owners', owner='u1'), 90), (vs.at('owners', owner='u2'), 300), (vs.at('owners'), 640)]
        readers = [(str(o), ('UNCLASSIFIED', o)) for o in (None, 'u1', 'u2', 'u3')]
        self.check_views('owners', layers, readers, 37)


class Cas(Base):
    def stream(self, rng, mode, keys, steps):
        commands = []
        for step in range(steps):
            key, dim, quant, prefix_args = rng.choice(keys)
            prefix = vs.at(mode, *prefix_args) if mode != 'plain' else ()
            roll = rng.random()
            name = 'e%d' % rng.randint(0, 260)
            if roll < 0.62:
                extra = ('CAS',) + (('SETATTR', '{"a":%d}' % rng.randint(0, 4)) if rng.random() < 0.3 else ())
                commands.append(vs.vadd(prefix, key, rng, dim, name, *extra, quant=quant))
            elif roll < 0.72:
                commands.append(vs.vadd(prefix, key, rng, dim, name, quant=quant))
            elif roll < 0.84:
                commands.append((*prefix, 'VREM', key, name))
            elif roll < 0.92:
                commands.append((*prefix, 'VSETATTR', key, name, '{"a":%d}' % rng.randint(0, 4)))
            else:
                commands.append((*prefix, 'VSIM', key, 'VALUES', dim, *vs.vector(rng, dim), 'COUNT', 5, 'WITHSCORES'))
        return commands

    def snapshot(self, c, mode, keys):
        p = vs.top(mode)
        out = {'digest': self.digest(c, mode)}
        for key, dim, quant, unused in keys:
            names = c.call(*p, 'VRANGE', key, '-', '+', 10000) or []
            out[key] = {'names': names, 'info': c.call(*p, 'VINFO', key),
                        'links': [c.call(*p, 'VLINKS', key, n, 'WITHSCORES') for n in names],
                        'emb': [c.call(*p, 'VEMB', key, n, 'RAW') for n in names[:40]]}
        return out

    def check(self, mode, keys, seed, force=False):
        threaded = self.server(mode=mode)
        inline = self.server(workers=2, mode=mode, arguments=FORCE) if force else self.server(workers=0, mode=mode)
        ct, ci = threaded.client(), inline.client()
        rng = self.rng(seed)
        for key, dim, quant, prefix_args in keys:
            prefix = vs.at(mode, *prefix_args) if mode != 'plain' else ()
            for c in (ct, ci):
                vs.fill(c, prefix, key, vs.seeded(SEED + seed + len(key)), dim, 90 if mode == 'plain' else 700, quant=quant)
        before = vs.compute(ct, mode)
        rt, ri = vs.Raw(ct), vs.Raw(ci)
        cas = 0
        for _ in range(6):
            batch = self.stream(rng, mode, keys, 60)
            cas += sum(1 for command in batch if command[-1] == 'CAS' or 'CAS' in command[-3:])
            self.assertEqual(rt.pipeline(batch), ri.pipeline(batch))
        self.expect_jobs(ct, before, cas // 4, mode)
        self.settle(ct, mode)
        if force:
            self.assertEqual(vs.compute(ci, mode)['compute_jobs_submitted'], 0)
        self.assertEqual(self.snapshot(ct, mode, keys), self.snapshot(ci, mode, keys))

    PLAIN = [('c-q8', 8, 'Q8', ()), ('c-noquant', 6, 'NOQUANT', ()), ('c-bin', 16, 'BIN', ())]
    LABELS = [('lc', 6, 'Q8', ('C',)), ('lc', 6, 'Q8', ('U',)), ('lh', 4, 'NOQUANT', ('S//A',))]
    OWNERS = [('oc', 5, 'Q8', ('UNCLASSIFIED', 'u1')), ('oc', 5, 'Q8', ('UNCLASSIFIED', None)), ('ob', 8, 'BIN', ('UNCLASSIFIED', 'u2'))]

    def test_cas_stream_builds_the_inline_graphs_with_labels_off(self):
        self.check('plain', self.PLAIN, 41)

    def test_cas_stream_builds_the_inline_graphs_with_a_label_scheme(self):
        self.check('labels', self.LABELS, 43)

    def test_cas_stream_builds_the_inline_graphs_in_owner_mode(self):
        self.check('owners', self.OWNERS, 47)

    def test_cas_stream_equals_a_server_forced_inline_with_labels_off(self):
        self.check('plain', self.PLAIN, 141, force=True)

    def test_cas_stream_equals_a_server_forced_inline_with_a_label_scheme(self):
        self.check('labels', self.LABELS, 143, force=True)

    def test_cas_stream_equals_a_server_forced_inline_in_owner_mode(self):
        self.check('owners', self.OWNERS, 147, force=True)

    def test_cas_stream_with_keyspace_workers_builds_the_inline_graphs(self):
        threaded = self.server(arguments=('--keyspace-threads', '2'))
        inline = self.server(workers=0)
        ct, ci = threaded.client(), inline.client()
        rng = self.rng(149)
        for c in (ct, ci):
            vs.fill(c, (), 'c-q8', vs.seeded(SEED + 150), 8, 90)
        others = [('strings', 4, 'Q8', ())]
        before = vs.compute(ct)
        batch = self.stream(rng, 'plain', [('c-q8', 8, 'Q8', ())], 150)
        keyspace = threaded.client()

        def strings():
            for i in range(200):
                keyspace.call('SET', 'str%d' % i, 'x' * (i % 40))
                keyspace.call('GET', 'str%d' % i)

        import threading
        t = threading.Thread(target=strings)
        t.start()
        self.assertEqual(vs.Raw(ct).pipeline(batch), vs.Raw(ci).pipeline(batch))
        t.join(60)
        self.expect_jobs(ct, before, 10)
        self.settle(ct)
        self.assertEqual(ct.call('DEBUG', 'DIGEST-VALUE', 'c-q8'), ci.call('DEBUG', 'DIGEST-VALUE', 'c-q8'))


class SameSet(Base):
    def writer_commands(self, rng, key, dim, count, bound):
        out = []
        for i in range(count):
            roll = rng.random()
            name = 'e%d' % rng.randint(0, bound)
            if roll < 0.45:
                extra = ('CAS',) + (('SETATTR', '{"a":%d}' % rng.randint(0, 4)) if rng.random() < 0.3 else ())
                out.append(vs.vadd((), key, rng, dim, name, *extra))
            elif roll < 0.6:
                out.append(vs.vadd((), key, rng, dim, 'w%d' % rng.randint(0, 40)))
            elif roll < 0.75:
                out.append(('VREM', key, name))
            elif roll < 0.85:
                out.append(('VSETATTR', key, name, '{"a":%d}' % rng.randint(0, 4)))
            else:
                out.append(('VSIM', key, *vs.queries(rng, dim, ['e%d' % j for j in range(bound)], 1)[0]))
        return out

    def reader_commands(self, rng, key, dim, count, bound):
        names = ['e%d' % j for j in range(bound)] + ['w%d' % j for j in range(40)]
        return [('VSIM', key, *q) for q in vs.queries(rng, dim, names, count)]

    def check(self, mode, fills, writers, readers, seed, steps=70):
        threaded = self.server(mode=mode)
        twin = self.server(mode=mode, arguments=FORCE)
        key, dim = 'mix', 6
        for prefix, count, names in fills:
            for s in (threaded, twin):
                vs.fill(s.client(), prefix, key, vs.seeded(SEED + seed + count), dim, count, names=names)
        monitor = threaded.client(timeout=120)
        self.assertEqual(monitor.call(*vs.top(mode), 'MONITOR'), 'OK')
        rng = self.rng(seed)
        roles = []
        for prefix in writers:
            roles.append((threaded.client(timeout=120), prefix, self.writer_commands(rng, key, dim, steps, 130)))
        for prefix in readers:
            roles.append((threaded.client(timeout=120), prefix, self.reader_commands(rng, key, dim, steps, 130)))
        vs.warm([c for c, unused, unused2 in roles])
        before = vs.compute(threaded.client(), mode)
        for c, prefix, commands in roles:
            c.send_many([(*prefix, *command) for command in commands])
        replies = {}
        sent = {}
        scope = {}
        for c, prefix, commands in roles:
            name = peer(c)
            replies[name] = [norm(c.reply()) for unused in commands]
            sent[name] = commands
            scope[name] = prefix
        order = vs.monitor_collect(monitor, threaded.client())
        kinds = (b'VADD', b'VREM', b'VSETATTR', b'VSIM')
        order = [(who, argv) for who, argv in order if who in sent and argv and argv[0].upper() in kinds]
        total = sum(len(v) for v in sent.values())
        self.assertEqual(len(order), total, 'the monitor did not show every command exactly once')
        seen = {name: [] for name in sent}
        for who, argv in order:
            seen[who].append(argv)
        for name, commands in sent.items():
            wanted = [[x if isinstance(x, bytes) else str(x).encode() for x in command] for command in commands]
            self.assertEqual(seen[name], wanted, 'the monitor order of one connection is not its send order')
        replay = twin.client(timeout=120)
        results = replay.pipeline([(*scope[who], *argv) for who, argv in order])
        cursor = {name: 0 for name in sent}
        checked = 0
        for (who, argv), value in zip(order, results):
            expected = replies[who][cursor[who]]
            cursor[who] += 1
            self.assertEqual(norm(value), expected, 'the twin disagrees about %r of %s' % (argv[:4], who))
            checked += 1
        self.assertEqual(checked, total)
        self.expect_jobs(threaded.client(), before, total // 6, mode)
        self.settle(threaded.client(), mode)
        self.assertEqual(vs.compute(twin.client(), mode)['compute_jobs_submitted'], 0)
        self.assertEqual(self.digest(threaded.client(), mode), self.digest(twin.client(), mode))
        p = vs.top(mode)
        ct, ci = threaded.client(), twin.client()
        if mode == 'plain':
            names = ct.call('VRANGE', key, '-', '+', 10000)
            self.assertEqual(names, ci.call('VRANGE', key, '-', '+', 10000))
            self.assertEqual(ct.call('VINFO', key), ci.call('VINFO', key))
            for n in names:
                self.assertEqual(ct.call('VLINKS', key, n, 'WITHSCORES'), ci.call('VLINKS', key, n, 'WITHSCORES'))

    def test_writers_and_threaded_readers_on_one_set_replay_in_monitor_order(self):
        names = ['e%d' % i for i in range(130)]
        self.check('plain', [((), 130, names)], [(), ()], [(), (), ()], 53)

    def test_writers_and_threaded_readers_on_one_set_replay_in_monitor_order_with_a_label_scheme(self):
        a, u = vs.at('labels', 'S//A'), vs.at('labels', 'U')
        names = ['e%d' % i for i in range(130)]
        self.check('labels', [(u, 700, ['e%d' % i for i in range(700)]), (a, 700, ['f%d' % i for i in range(700)])], [u, a], [a, vs.at('labels', 'S//A/B')], 59)

    def test_writers_and_threaded_readers_on_one_set_replay_in_monitor_order_in_owner_mode(self):
        u1, u2, shared = vs.at('owners', owner='u1'), vs.at('owners', owner='u2'), vs.at('owners')
        self.check('owners', [(u1, 300, ['e%d' % i for i in range(300)]), (u2, 300, ['e%d' % i for i in range(300)])], [u1, u2], [u1, u2, u1], 61)


class Rules(Base):
    def wide(self, c, key='k', count=120, dim=8, prefix=(), n=1):
        vs.fill(c, prefix, key, self.rng(n), dim, count)

    def query(self, dim=8, n=5, tail=('COUNT', 10, 'WITHSCORES')):
        return ['VALUES', dim, *vs.vector(self.rng(n), dim), *tail]

    def cas(self, key, name, dim=8, n=9, prefix=()):
        return (*prefix, 'VADD', key, 'VALUES', dim, *vs.vector(self.rng(n + sum(str(name).encode()) % 1000), dim), name, 'CAS')

    def test_nothread_keeps_a_search_inline(self):
        s = self.server()
        c = s.client()
        self.wide(c)
        q = self.query()
        before = vs.compute(c)
        inline = [c.call('VSIM', 'k', *q, 'NOTHREAD') for unused in range(4)] + [c.call('VSIM', 'k', *q, 'nothread')]
        self.assertEqual(self.moved(c, before), (0, 0))
        threaded = c.call('VSIM', 'k', *q)
        self.assertEqual(self.moved(c, before)[0], self.jobs(1))
        self.assertEqual({str(x) for x in inline}, {str(threaded)})

    def test_a_search_with_compute_threads_zero_runs_inline(self):
        s = self.server(workers=0)
        c = s.client()
        self.wide(c)
        q = self.query()
        before = vs.compute(c)
        c.call(*self.cas('k', 'zero'))
        first = c.call('VSIM', 'k', *q)
        self.assertEqual(self.moved(c, before), (0, 0))
        self.assertEqual(first, c.call('VSIM', 'k', *q, 'NOTHREAD'))
        self.assertEqual(vs.compute(c)['compute_threads_configured'], 0)

    def test_the_force_setting_given_at_startup_keeps_vsim_and_cas_inline(self):
        s = self.server(arguments=FORCE)
        c = s.client()
        self.assertEqual(c.call('CONFIG', 'GET', 'vset-force-single-threaded-execution'), [b'vset-force-single-threaded-execution', b'yes'])
        self.wide(c)
        q = self.query()
        before = vs.compute(c)
        replies = [c.call('VSIM', 'k', *q) for unused in range(3)]
        for i in range(4):
            self.assertEqual(c.call(*self.cas('k', 'f%d' % i)), 1)
        self.assertEqual(self.moved(c, before), (0, 0))
        self.assertEqual(len({str(x) for x in replies[:1]}), 1)
        self.assertEqual(c.call('VCARD', 'k'), 124)
        self.assertEqual(c.call('VSIM', 'k', *q), c.call('VSIM', 'k', *q, 'NOTHREAD'))

    def test_the_force_setting_changes_at_runtime_in_both_directions(self):
        s = self.server()
        c = s.client()
        self.wide(c)
        q = self.query()
        self.assertEqual(c.call('CONFIG', 'GET', 'vset-force-single-threaded-execution'), [b'vset-force-single-threaded-execution', b'no'])
        step = 0
        for setting in ('no', 'yes', 'no', 'yes', 'no'):
            self.assertEqual(c.call('CONFIG', 'SET', 'vset-force-single-threaded-execution', setting), 'OK')
            self.assertEqual(c.call('CONFIG', 'GET', 'vset-force-single-threaded-execution'), [b'vset-force-single-threaded-execution', setting.encode()])
            before = vs.compute(c)
            first = c.call('VSIM', 'k', *q)
            self.assertEqual(first, c.call('VSIM', 'k', *q, 'NOTHREAD'))
            self.assertEqual(c.call(*self.cas('k', 'r%d' % step)), 1)
            step += 1
            submitted, fallbacks = self.moved(c, before)
            self.assertEqual(submitted, 0 if setting == 'yes' else self.jobs(2), 'setting %s' % setting)
            self.assertEqual(fallbacks, 0)
        self.settle(c)

    def check_setting_from_the_top(self, mode, prefix):
        s = self.server(mode=mode)
        c = s.client()
        vs.fill(c, prefix, 'k', self.rng(1), 8, 140)
        q = self.query()
        top = vs.top(mode)
        for setting in ('yes', 'no'):
            self.assertEqual(c.call(*top, 'CONFIG', 'SET', 'vset-force-single-threaded-execution', setting), 'OK')
            self.assertEqual(c.call(*top, 'CONFIG', 'GET', 'vset-force-single-threaded-execution'), [b'vset-force-single-threaded-execution', setting.encode()])
            before = vs.compute(c, mode)
            first = c.call(*prefix, 'VSIM', 'k', *q)
            self.assertEqual(first, c.call(*prefix, 'VSIM', 'k', *q, 'NOTHREAD'))
            self.assertEqual(self.moved(c, before, mode)[0], 0 if setting == 'yes' else self.jobs(1))
        self.settle(c, mode)

    def test_the_force_setting_is_changed_by_the_top_login_with_a_label_scheme(self):
        self.check_setting_from_the_top('labels', vs.at('labels', 'S//A'))

    def test_the_force_setting_is_changed_by_the_top_login_in_owner_mode(self):
        self.check_setting_from_the_top('owners', vs.at('owners', owner='u1'))

    def test_a_commit_in_flight_survives_the_force_setting_being_switched_on(self):
        s = self.server()
        a, b, c = s.client(), s.client(), s.client()
        self.wide(c)
        vs.warm([a, b])
        before = vs.compute(c)
        with vs.Hold(s):
            a.send(*self.cas('k', 'inflight'))
            b.send('CONFIG', 'SET', 'vset-force-single-threaded-execution', 'yes')
        self.assertEqual(a.reply(), 1)
        self.assertEqual(b.reply(), 'OK')
        self.assertEqual(c.call('VISMEMBER', 'k', 'inflight'), 1)
        self.assertEqual(self.moved(c, before)[0], self.jobs(1))
        self.assertEqual(c.call(*self.cas('k', 'after')), 1)
        self.assertEqual(self.moved(c, before)[0], self.jobs(1))
        self.settle(c)

    def test_the_size_threshold_is_the_visible_size_at_the_moment_of_the_command(self):
        floor = vs.threshold()
        s = self.server()
        c = s.client()
        self.wide(c, 'edge', floor - 1, 8)
        q = self.query()
        before = vs.compute(c)
        small = c.call('VSIM', 'edge', *q)
        self.assertEqual(self.moved(c, before), (0, 0))
        self.assertEqual(c.call(*self.cas('edge', 'add-a')), 1)
        self.assertEqual(self.moved(c, before), (0, 0))
        self.assertEqual(c.call('VCARD', 'edge'), floor)
        wide = c.call('VSIM', 'edge', *q)
        self.assertEqual(self.moved(c, before)[0], self.jobs(1))
        self.assertEqual(c.call(*self.cas('edge', 'add-b')), 1)
        self.assertEqual(self.moved(c, before)[0], self.jobs(2))
        self.assertEqual(c.call('VREM', 'edge', 'add-a'), 1)
        self.assertEqual(c.call('VREM', 'edge', 'add-b'), 1)
        self.assertEqual(c.call('VCARD', 'edge'), floor - 1)
        mark = self.moved(c, before)[0]
        c.call('VSIM', 'edge', *q)
        self.assertEqual(self.moved(c, before)[0], mark)
        self.settle(c)

    def hidden_size(self, mode, low, high, extra_low=()):
        floor = vs.threshold()
        moves = []
        for hidden in (0, 600):
            s = self.server(mode=mode)
            c = s.client()
            vs.fill(c, low, 'quiet', self.rng(3), 8, floor - 10, names=['q%d' % i for i in range(floor - 10)])
            vs.fill(c, low, 'busy', self.rng(4), 8, floor + 40, names=['b%d' % i for i in range(floor + 40)])
            if hidden:
                vs.fill(c, high, 'quiet', self.rng(5), 8, hidden, names=['h%d' % i for i in range(hidden)])
                vs.fill(c, high, 'busy', self.rng(6), 8, hidden, names=['h%d' % i for i in range(hidden)])
            self.assertEqual(c.call(*low, 'VCARD', 'quiet'), floor - 10)
            self.assertEqual(c.call(*low, 'VCARD', 'busy'), floor + 40)
            before = vs.compute(c, mode)
            q = self.query()
            replies = []
            for key in ('quiet', 'busy'):
                for unused in range(5):
                    replies.append(c.call(*low, 'VSIM', key, *q))
            moves.append((self.moved(c, before, mode), replies))
            self.settle(c, mode)
        self.assertEqual(moves[0][0], moves[1][0], 'whether a search ran on a worker depends on data the reader cannot see')
        self.assertEqual(moves[0][1], moves[1][1])
        self.assertEqual(moves[0][0][0], self.jobs(5))

    def test_the_decision_reads_only_the_visible_size_in_label_mode(self):
        self.hidden_size('labels', vs.at('labels', 'U'), vs.at('labels', 'S//A'))

    def test_the_decision_reads_only_the_visible_size_in_owner_mode(self):
        self.hidden_size('owners', vs.at('owners', owner='u1'), vs.at('owners', owner='u2'))

    def test_the_decision_reads_only_the_visible_size_for_a_reader_who_sees_the_shared_part(self):
        self.hidden_size('owners', vs.at('owners'), vs.at('owners', owner='u2'))

    def test_a_tracked_connection_keeps_vsim_and_cas_inline(self):
        s = self.server()
        c = s.client()
        self.wide(c)
        t = s.client()
        t.call('HELLO', 3)
        self.assertEqual(t.call('CLIENT', 'TRACKING', 'ON'), 'OK')
        q = self.query()
        before = vs.compute(c)
        first = t.call('VSIM', 'k', *q)
        self.assertEqual(t.call(*self.cas('k', 'tracked')), 1)
        submitted, fallbacks = self.moved(c, before)
        self.assertEqual(submitted, 0)
        self.assertEqual(fallbacks, 2 if THREADS else 0)
        self.assertEqual(t.call('CLIENT', 'TRACKING', 'OFF'), 'OK')
        t.call('VSIM', 'k', *q)
        self.assertEqual(self.moved(c, before)[0], self.jobs(1))
        self.settle(c)

    def test_an_invalidation_cannot_overtake_the_reply_of_a_tracked_search(self):
        s = self.server()
        c, w = s.client(), s.client()
        self.wide(c)
        t = s.client()
        t.call('HELLO', 3)
        t.call('CLIENT', 'TRACKING', 'ON')
        vs.warm([w])
        raw = vs.Raw(t)
        q = self.query()
        for i in range(8):
            with vs.Hold(s):
                t.send('VSIM', 'k', *q)
                w.send(*vs.vadd((), 'k', self.rng(40 + i), 8, 'inv%d' % i))
            first = raw.frame()
            self.assertNotEqual(first[:1], b'>', 'an invalidation reached the tracking client before its search reply')
            self.assertEqual(w.reply(), 1)
            t.send('PING')
            while raw.frame() != b'+PONG\r\n':
                pass
        self.settle(c)

    def test_a_transaction_runs_its_searches_and_insertions_inline(self):
        s = self.server()
        c = s.client()
        self.wide(c)
        q = self.query()
        before = vs.compute(c)
        replies = c.pipeline([('MULTI',), ('VSIM', 'k', *q), ('VSIM', 'k', *q, 'NOTHREAD'), self.cas('k', 'in-multi'), ('EXEC',)])
        self.assertEqual(replies[0], 'OK')
        self.assertEqual(replies[4][2], 1)
        self.assertEqual(replies[4][0], replies[4][1])
        self.assertEqual(self.moved(c, before)[0], 0)
        self.assertEqual(c.call('VISMEMBER', 'k', 'in-multi'), 1)
        after = c.call('VSIM', 'k', *q)
        self.assertEqual(after, c.call('VSIM', 'k', *q, 'NOTHREAD'))
        self.settle(c)

    def test_a_script_and_a_function_run_their_searches_and_insertions_inline(self):
        s = self.server()
        c = s.client()
        self.wide(c)
        q = self.query()
        before = vs.compute(c)
        script = "return redis.call('VSIM', KEYS[1], unpack(ARGV))"
        direct = c.call('EVAL', script, 1, 'k', *q)
        add = "return redis.call('VADD', KEYS[1], 'VALUES', 8, unpack(ARGV))"
        self.assertEqual(c.call('EVAL', add, 1, 'k', *vs.vector(self.rng(77), 8), 'in-script', 'CAS'), 1)
        library = "#!lua name=vlib\nredis.register_function('vs', function(keys, args) return redis.call('VSIM', keys[1], unpack(args)) end)\nredis.register_function('va', function(keys, args) return redis.call('VADD', keys[1], 'VALUES', 8, unpack(args)) end)"
        self.assertEqual(c.call('FUNCTION', 'LOAD', library), b'vlib')
        fun = c.call('FCALL', 'vs', 1, 'k', *q)
        self.assertEqual(c.call('FCALL', 'va', 1, 'k', *vs.vector(self.rng(78), 8), 'in-function', 'CAS'), 1)
        self.assertEqual(self.moved(c, before)[0], 0)
        self.assertEqual(c.call('VCARD', 'k'), 122)
        self.assertEqual(len(fun), len(direct))
        self.settle(c)

    def test_replaying_the_log_runs_cas_records_inline(self):
        s = self.server(arguments=('--appendonly', 'yes', '--appendfsync', 'always'))
        c = s.client()
        self.wide(c)
        for i in range(24):
            self.assertEqual(c.call(*self.cas('k', 'log%d' % i, n=100 + i)), 1)
        self.settle(c)
        digest = self.digest(c, 'plain')
        before = vs.compute(c)
        self.assertEqual(c.call('DEBUG', 'LOADAOF'), 'OK')
        self.assertEqual(self.moved(c, before)[0], 0)
        self.assertEqual(self.digest(c, 'plain'), digest)
        self.assertEqual(c.call('DEBUG', 'RELOAD'), 'OK')
        self.assertEqual(self.moved(c, before)[0], 0)
        self.assertEqual(self.digest(c, 'plain'), digest)
        q = self.query()
        self.assertEqual(c.call('VSIM', 'k', *q), c.call('VSIM', 'k', *q, 'NOTHREAD'))
        self.settle(c)

    def commit_point(self, s, c, conns, q, name):
        prober, reader = s.client(timeout=120), s.client(timeout=120)
        vs.warm([prober, reader])
        with vs.Hold(s):
            for x in conns:
                x.send('VSIM', 'k', *q)
            prober.send(*self.cas('k', name, n=300))
            reader.send('VISMEMBER', 'k', name)
        self.assertEqual(prober.reply(), 1)
        self.assertEqual(reader.reply(), 0 if THREADS else 1, 'a commit the pool could not take was applied before the tick')
        self.assertEqual(c.call('VISMEMBER', 'k', name), 1)

    def test_a_full_queue_runs_the_next_searches_on_the_coordinator_and_answers_them_at_the_tick(self):
        s = self.server()
        c = s.client()
        self.wide(c)
        q = self.query()
        want = c.call('VSIM', 'k', *q, 'NOTHREAD')
        conns = [s.client(timeout=120) for unused in range(70)]
        vs.warm(conns)
        before = vs.compute(c)
        self.commit_point(s, c, conns, q, 'queued')
        for x in conns:
            self.assertEqual(x.reply(), want)
        submitted, fallbacks = self.moved(c, before)
        self.assertEqual((submitted, fallbacks), (71, 7) if THREADS else (0, 0))
        self.settle(c)

    def test_a_search_that_does_not_fit_the_memory_budget_runs_on_the_coordinator_and_answers_at_the_tick(self):
        s = self.server(memory=1024)
        c = s.client()
        self.wide(c)
        q = self.query()
        want = c.call('VSIM', 'k', *q, 'NOTHREAD')
        before = vs.compute(c)
        for unused in range(4):
            self.assertEqual(c.call('VSIM', 'k', *q), want)
        self.assertEqual(c.call(*self.cas('k', 'nomem')), 1)
        submitted, fallbacks = self.moved(c, before)
        self.assertEqual((submitted, fallbacks), (5, 5) if THREADS else (0, 0))
        conns = [s.client(timeout=120) for unused in range(3)]
        vs.warm(conns)
        self.commit_point(s, c, conns, q, 'unbudgeted')
        for x in conns:
            self.assertEqual(x.reply(), want)
        self.settle(c)

    def test_a_budget_for_two_searches_runs_the_rest_on_the_coordinator(self):
        s = self.server(memory=8192)
        c = s.client()
        self.wide(c)
        q = self.query()
        want = c.call('VSIM', 'k', *q, 'NOTHREAD')
        conns = [s.client(timeout=120) for unused in range(6)]
        vs.warm(conns)
        before = vs.compute(c)
        with vs.Hold(s):
            for x in conns:
                x.send('VSIM', 'k', *q)
        for x in conns:
            self.assertEqual(x.reply(), want)
        submitted, fallbacks = self.moved(c, before)
        if THREADS:
            self.assertEqual(submitted, 6)
            self.assertTrue(0 < fallbacks < 6)
        else:
            self.assertEqual((submitted, fallbacks), (0, 0))
        self.settle(c)

    def test_reply_off_and_skip_leave_no_job_behind(self):
        s = self.server()
        c = s.client()
        self.wide(c)
        q = self.query()
        before = vs.compute(c)
        c.send_many([('CLIENT', 'REPLY', 'OFF'), ('VSIM', 'k', *q), self.cas('k', 'quiet'), ('CLIENT', 'REPLY', 'ON'), ('PING',)])
        self.assertEqual([c.reply(), c.reply()], ['OK', 'PONG'])
        self.assertEqual(c.call('VISMEMBER', 'k', 'quiet'), 1)
        c.send('CLIENT', 'REPLY', 'SKIP')
        c.send('VSIM', 'k', *q)
        c.send('PING')
        self.assertEqual(c.reply(), 'PONG')
        c.send('CLIENT', 'REPLY', 'SKIP')
        c.send(*self.cas('k', 'skipped'))
        c.send('PING')
        self.assertEqual(c.reply(), 'PONG')
        self.assertEqual(c.call('VISMEMBER', 'k', 'skipped'), 1)
        self.assertEqual(self.moved(c, before)[0], self.jobs(4))
        self.settle(c)


class Lifecycle(Base):
    def big(self, c, prefix=(), key='big', count=900, dim=24):
        vs.fill(c, prefix, key, vs.seeded(61), dim, count)
        return ['VALUES', dim, *vs.vector(vs.seeded(62), dim), 'COUNT', 50, 'EF', 400, 'WITHSCORES']

    def test_client_close_during_jobs_leaves_nothing_behind(self):
        s = self.server()
        admin = s.client()
        query = self.big(admin)
        base = vs.connected(admin)
        for unused in range(8):
            leaver = Client(s.port)
            leaver.call('PING')
            leaver.send_many([('VSIM', 'big', *query)] * 30)
            leaver.socket.shutdown(socket.SHUT_RDWR)
            leaver.close()
        self.gone(admin, base)
        info = self.settle(admin)
        self.assertEqual(admin.call('PING'), 'PONG')
        self.assertEqual(admin.call('VCARD', 'big'), 900)
        self.assertGreater(info['compute_jobs_submitted'], 0 if THREADS else -1)

    def test_client_kill_during_jobs_leaves_nothing_behind(self):
        s = self.server()
        admin = s.client()
        query = self.big(admin)
        for unused in range(6):
            victim = s.client()
            ident = victim.call('CLIENT', 'ID')
            victim.send_many([('VSIM', 'big', *query)] * 30)
            admin.call('CLIENT', 'KILL', 'ID', ident)
            try:
                for unused2 in range(30):
                    victim.reply()
            except (EOFError, ConnectionError):
                pass
        self.settle(admin)
        self.assertEqual(admin.call('VCARD', 'big'), 900)

    def test_client_close_during_cas_jobs_commits_what_the_log_of_the_monitor_shows(self):
        s = self.server()
        twin = self.server(workers=0)
        admin = s.client()
        for c in (admin, twin.client()):
            vs.fill(c, (), 'big', vs.seeded(61), 12, 300)
        monitor = s.client(timeout=60)
        monitor.call('MONITOR')
        rng = self.rng(65)
        base = vs.connected(admin)
        for unused in range(6):
            leaver = Client(s.port)
            leaver.call('PING')
            leaver.send_many([vs.vadd((), 'big', rng, 12, 'x%d' % rng.randint(0, 99), 'CAS') for unused2 in range(30)])
            leaver.socket.shutdown(socket.SHUT_RDWR)
            leaver.close()
        self.gone(admin, base)
        self.settle(admin)
        marker = s.client()
        order = vs.monitor_collect(monitor, marker)
        commits = [argv for who, argv in order if argv[:1] == [b'VADD']]
        replay = twin.client()
        for value in replay.pipeline(commits):
            self.assertNotIsInstance(value, ServerError)
        self.assertEqual(admin.call('DEBUG', 'DIGEST'), replay.call('DEBUG', 'DIGEST'))
        info = vs.compute(admin)
        self.assertEqual(info['compute_jobs_pending'], 0)

    def race(self, s, query, action, empty, rounds=1):
        admin = s.client()
        inline = admin.call('VSIM', 'big', *query, 'NOTHREAD')
        reader, writer = s.client(), s.client()
        reader.send('VSIM', 'big', *query)
        writer.send(*action)
        value = reader.reply()
        self.assertNotIsInstance(writer.reply(), ServerError)
        self.assertIn(value, (inline, empty))
        return value

    def test_del_of_the_searched_set_waits_for_the_job(self):
        s = self.server()
        admin = s.client()
        query = self.big(admin)
        for round in range(25):
            if round:
                self.big(admin)
            self.race(s, query, ('DEL', 'big'), [])
            self.assertEqual(admin.call('EXISTS', 'big'), 0)
        self.settle(admin)
        self.assertEqual(admin.call('PING'), 'PONG')

    def test_unlink_with_lazy_freeing_waits_for_the_job_before_the_hand_off(self):
        s = self.server(arguments=('--lazyfree-lazy-user-del', 'yes'))
        admin = s.client()
        query = self.big(admin)
        for round in range(25):
            if round:
                self.big(admin)
            self.race(s, query, ('UNLINK' if round % 2 else 'DEL', 'big'), [])
            self.assertEqual(admin.call('EXISTS', 'big'), 0)
        self.settle(admin)
        self.assertEqual(admin.call('PING'), 'PONG')

    def test_flushall_and_flushdb_of_the_searched_set_wait_for_the_job(self):
        s = self.server()
        admin = s.client()
        query = self.big(admin)
        for round in range(24):
            if round:
                self.big(admin)
            action = [('FLUSHALL', 'ASYNC'), ('FLUSHALL', 'SYNC'), ('FLUSHDB', 'ASYNC'), ('FLUSHDB',)][round % 4]
            self.race(s, query, action, [])
            self.assertEqual(admin.call('DBSIZE'), 0)
        self.settle(admin)

    def test_rename_and_move_of_the_searched_set_leave_the_job_a_set_it_can_read(self):
        s = self.server()
        admin = s.client()
        query = self.big(admin)
        for round in range(20):
            if round:
                self.big(admin)
            action = [('RENAME', 'big', 'moved'), ('MOVE', 'big', 1)][round % 2]
            before = admin.call('VSIM', 'big', *query, 'NOTHREAD')
            reader, writer = s.client(), s.client()
            reader.send('VSIM', 'big', *query)
            writer.send(*action)
            value = reader.reply()
            self.assertNotIsInstance(writer.reply(), ServerError)
            self.assertIn(value, (before, []))
            self.assertEqual(admin.call('EXISTS', 'big'), 0)
            if action[0] == 'RENAME':
                self.assertEqual(admin.call('VCARD', 'moved'), 900)
                admin.call('DEL', 'moved')
            else:
                admin.call('SELECT', 1)
                self.assertEqual(admin.call('VCARD', 'big'), 900)
                admin.call('DEL', 'big')
                admin.call('SELECT', 0)
        self.settle(admin)

    def test_rename_splits_a_label_set_while_a_high_reader_searches_it(self):
        s = self.server(mode='labels', arguments=('--slowlog-log-slower-than', '-1'))
        c = s.client()
        low, mid, high = vs.at('labels', 'U'), vs.at('labels', 'C'), vs.at('labels', 'S//A')
        for round in range(8):
            for prefix in (mid, low):
                vs.fill(c, prefix, 'big', vs.seeded(61 + round), 12, 600)
            query = ['VALUES', 12, *vs.vector(vs.seeded(62), 12), 'COUNT', 50, 'EF', 400, 'WITHSCORES']
            before = c.call(*high, 'VSIM', 'big', *query, 'NOTHREAD')
            readers = [s.client() for unused in range(3)]
            for r in readers:
                r.send_many([(*high, 'VSIM', 'big', *query)] * 6)
            writer = s.client()
            writer.send(*low, 'RENAME', 'big', 'moved')
            self.assertNotIsInstance(writer.reply(), ServerError)
            after = c.call(*high, 'VSIM', 'big', *query, 'NOTHREAD')
            for r in readers:
                for unused in range(6):
                    self.assertIn(r.reply(), (before, after))
            c.call(*vs.top('labels'), 'FLUSHALL')
        self.settle(c, 'labels')

    def readers_of_a_static_set(self, s, mode='plain', count=4, depth=40):
        admin = s.client()
        query = self.big(admin)
        want = admin.call('VSIM', 'big', *query, 'NOTHREAD')
        readers = [s.client(timeout=120) for unused in range(count)]
        for r in readers:
            r.send_many([('VSIM', 'big', *query)] * depth)
        return admin, readers, want, depth

    def test_a_snapshot_fork_during_jobs_loses_no_reply_and_no_pin(self):
        s = self.server()
        admin, readers, want, depth = self.readers_of_a_static_set(s)
        self.assertIn(admin.call('BGSAVE'), ('Background saving started',))
        for r in readers:
            for unused in range(depth):
                self.assertEqual(r.reply(), want)
        wait_for(lambda: b'rdb_bgsave_in_progress:0' in admin.call('INFO', 'persistence'), 60, 'the snapshot child to finish')
        self.settle(admin)
        digest = admin.call('DEBUG', 'DIGEST')
        self.assertEqual(admin.call('DEBUG', 'RELOAD'), 'OK')
        self.assertEqual(admin.call('DEBUG', 'DIGEST'), digest)
        self.assertEqual(admin.call('VSIM', 'big', *self.big_query(), 'NOTHREAD'), want)

    def big_query(self):
        return ['VALUES', 24, *vs.vector(vs.seeded(62), 24), 'COUNT', 50, 'EF', 400, 'WITHSCORES']

    def test_a_log_rewrite_during_jobs_loses_no_reply_and_no_pin(self):
        s = self.server(arguments=('--appendonly', 'yes', '--appendfsync', 'always'))
        admin, readers, want, depth = self.readers_of_a_static_set(s)
        self.assertEqual(admin.call('BGREWRITEAOF'), 'Background append only file rewriting started')
        for r in readers:
            for unused in range(depth):
                self.assertEqual(r.reply(), want)
        wait_for(lambda: b'aof_rewrite_in_progress:0' in admin.call('INFO', 'persistence'), 60, 'the rewrite child to finish')
        self.settle(admin)
        digest = admin.call('DEBUG', 'DIGEST')
        self.assertEqual(admin.call('DEBUG', 'LOADAOF'), 'OK')
        self.assertEqual(admin.call('DEBUG', 'DIGEST'), digest)

    def test_a_snapshot_fork_during_cas_jobs_keeps_every_commit(self):
        s = self.server()
        twin = self.server(workers=0)
        admin = s.client()
        for c in (admin, twin.client()):
            vs.fill(c, (), 'big', vs.seeded(61), 12, 300)
        monitor = s.client(timeout=60)
        monitor.call('MONITOR')
        rng = self.rng(66)
        writers = [s.client(timeout=120) for unused in range(3)]
        for w in writers:
            w.send_many([vs.vadd((), 'big', rng, 12, 'y%d' % rng.randint(0, 120), 'CAS') for unused in range(40)])
        self.assertEqual(admin.call('BGSAVE'), 'Background saving started')
        for w in writers:
            for unused in range(40):
                self.assertNotIsInstance(w.reply(), ServerError)
        wait_for(lambda: b'rdb_bgsave_in_progress:0' in admin.call('INFO', 'persistence'), 60, 'the snapshot child to finish')
        order = vs.monitor_collect(monitor, s.client())
        commits = [argv for who, argv in order if argv[:1] == [b'VADD']]
        replay = twin.client()
        for value in replay.pipeline(commits):
            self.assertNotIsInstance(value, ServerError)
        self.assertEqual(admin.call('DEBUG', 'DIGEST'), replay.call('DEBUG', 'DIGEST'))
        self.settle(admin)

    def test_a_scheme_extension_that_rewrites_the_log_during_jobs_loses_no_reply(self):
        s = self.server(mode='labels', arguments=('--appendonly', 'yes', '--appendfsync', 'always'))
        admin = s.client()
        high = vs.at('labels', 'S//A')
        vs.fill(admin, high, 'big', vs.seeded(61), 24, 900)
        query = ['VALUES', 24, *vs.vector(vs.seeded(62), 24), 'COUNT', 50, 'EF', 400, 'WITHSCORES']
        want = admin.call(*high, 'VSIM', 'big', *query, 'NOTHREAD')
        readers = [s.client(timeout=120) for unused in range(4)]
        for r in readers:
            r.send_many([(*high, 'VSIM', 'big', *query)] * 40)
        before = vs.compute(admin, 'labels')
        self.assertEqual(admin.call(*vs.top('labels'), 'CONFIG', 'SET', 'label-compartments', 'A,B,X'), 'OK')
        for r in readers:
            for unused in range(40):
                self.assertEqual(r.reply(), want)
        top = vs.at('labels', 'S//A/B/X')
        wait_for(lambda: vs.compute(admin, prefix=top)['compute_jobs_pending'] == 0, 60, 'no pending compute job')
        digest = admin.call(*top, 'DEBUG', 'DIGEST-SCOPES')
        self.assertEqual(admin.call(*top, 'DEBUG', 'LOADAOF'), 'OK')
        self.assertEqual(admin.call(*top, 'DEBUG', 'DIGEST-SCOPES'), digest)
        self.assertEqual(admin.call(*high, 'VSIM', 'big', *query), want)

    def test_debug_reload_during_jobs_answers_every_search_from_the_same_set(self):
        s = self.server()
        admin, readers, want, depth = self.readers_of_a_static_set(s)
        self.assertEqual(admin.call('DEBUG', 'RELOAD'), 'OK')
        for r in readers:
            for unused in range(depth):
                self.assertEqual(r.reply(), want)
        self.settle(admin)
        self.assertEqual(admin.call('VCARD', 'big'), 900)

    def test_a_shutdown_command_during_jobs_exits_cleanly(self):
        s = self.server()
        admin, readers, want, depth = self.readers_of_a_static_set(s, count=6)
        try:
            admin.send('SHUTDOWN', 'NOSAVE')
        except OSError:
            pass
        deadline = time.monotonic() + 60
        while s.process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(s.process.poll(), 0)

    def test_a_termination_signal_during_jobs_exits_cleanly(self):
        s = self.server()
        admin, readers, want, depth = self.readers_of_a_static_set(s, count=6)
        s.stop()

    def test_forget_of_the_jobs_owner_closes_its_work(self):
        s = self.server(mode='owners', arguments=('--slowlog-log-slower-than', '0', '--slowlog-max-len', '100000'))
        admin = s.client()
        mine = vs.at('owners', owner='u1')
        query = self.big(admin, mine, key='big', count=600)
        vs.fill(admin, vs.at('owners'), 'shared', vs.seeded(63), 4, 30)
        base = vs.connected(admin, 'owners')
        for round in range(6):
            if round:
                vs.fill(admin, mine, 'big', vs.seeded(61), 24, 600)
            owner = Client(s.port)
            owner.call('PING')
            at = query.index('COUNT') + 1
            owner.send_many([(*mine, 'VSIM', 'big', *query[:at], 30 + i, *query[at + 1:]) for i in range(20)])
            admin.call(*vs.top('owners'), 'OWNERS', 'FORGET', 'u1')
            got = 0
            try:
                for unused in range(20):
                    value = owner.reply()
                    if isinstance(value, ServerError):
                        break
                    got += 1
            except (EOFError, ConnectionError):
                pass
            owner.close()
            self.gone(admin, base, 'owners')
            self.settle(admin, 'owners')
            for entry in admin.call(*vs.top('owners'), 'SLOWLOG', 'GET', -1):
                args = entry[3]
                if args[:2] == [b'VSIM', b'big']:
                    tag = int(args[args.index(b'COUNT') + 1]) - 30
                    self.assertLess(tag, got, 'a slow log entry of work the forgotten owner never saw answered survived')
            self.assertEqual(admin.call(*mine, 'EXISTS', 'big'), 0)
        self.assertEqual(admin.call(*vs.at('owners'), 'VCARD', 'shared'), 30)

    def test_forget_of_the_owner_of_a_cas_job_commits_nothing_after_it(self):
        self.needs_threads()
        s = self.server(mode='owners')
        admin = s.client()
        mine = vs.at('owners', owner='u1')
        top = vs.top('owners')
        vs.fill(admin, vs.at('owners'), 'shared', vs.seeded(63), 4, 30)
        for round in range(6):
            vs.fill(admin, mine, 'big', vs.seeded(61), 12, 700)
            rng = self.rng(70 + round)
            owner, forgetter = s.client(timeout=60), s.client(timeout=60)
            vs.warm([owner, forgetter])
            before = vs.compute(admin, 'owners')
            with vs.Hold(s, 'owners'):
                owner.send(*vs.vadd(mine, 'big', rng, 12, 'z%d' % round, 'CAS'))
                forgetter.send(*top, 'OWNERS', 'FORGET', 'u1')
            self.assertNotIsInstance(forgetter.reply(), ServerError)
            with self.assertRaises((EOFError, OSError)):
                owner.reply()
            self.settle(admin, 'owners')
            self.assertEqual(self.moved(admin, before, 'owners')[0], self.jobs(1))
            self.assertEqual(admin.call(*mine, 'EXISTS', 'big'), 0, 'a commit after the forget recreated the forgotten owner data')
            self.assertEqual(admin.call(*mine, 'VCARD', 'big'), 0)
        self.assertEqual(admin.call(*vs.at('owners'), 'VCARD', 'shared'), 30)


class Pause(Base):
    def setUp(self):
        self.needs_threads()

    def prepared(self, count=120):
        s = self.server()
        c = s.client()
        vs.fill(c, (), 'k', vs.seeded(81), 8, count)
        a, b = s.client(timeout=60), s.client(timeout=60)
        vs.warm([a, b])
        return s, c, a, b

    def cas(self, name, n=1):
        return vs.vadd((), 'k', vs.seeded(82 + n), 8, name, 'CAS')

    def quiet(self, c, rounds=40):
        for unused in range(rounds):
            c.call('PING')

    def test_a_cas_commit_waits_for_a_write_pause_and_lands_after_it(self):
        s, c, a, b = self.prepared()
        digest = c.call('DEBUG', 'DIGEST')
        with vs.Hold(s):
            a.send(*self.cas('held'))
            b.send('CLIENT', 'PAUSE', 120000, 'WRITE')
        self.assertEqual(b.reply(), 'OK')
        self.quiet(c)
        self.assertFalse(a.available(0), 'a commit was answered while a write pause lasted')
        self.assertEqual(c.call('DEBUG', 'DIGEST'), digest, 'the dataset changed during a write pause')
        self.assertEqual(c.call('VCARD', 'k'), 120)
        info = vs.compute(c)
        self.assertEqual(info['compute_jobs_pending'], self.jobs(1))
        self.assertEqual(c.call('CLIENT', 'UNPAUSE'), 'OK')
        self.assertEqual(a.reply(), 1)
        self.assertNotEqual(c.call('DEBUG', 'DIGEST'), digest)
        self.assertEqual(c.call('VCARD', 'k'), 121)
        self.settle(c)

    def test_held_commits_land_in_the_order_the_monitor_shows(self):
        s, c, a, b = self.prepared()
        twin = self.server(workers=0)
        vs.fill(twin.client(), (), 'k', vs.seeded(81), 8, 120)
        d, e = s.client(timeout=60), s.client(timeout=60)
        vs.warm([d, e])
        monitor = s.client(timeout=60)
        monitor.call('MONITOR')
        with vs.Hold(s):
            a.send(*self.cas('one', 1))
            d.send(*self.cas('two', 2))
            e.send(*self.cas('three', 3))
            b.send('CLIENT', 'PAUSE', 120000, 'WRITE')
        self.assertEqual(b.reply(), 'OK')
        self.quiet(c)
        for x in (a, d, e):
            self.assertFalse(x.available(0))
        self.assertEqual(c.call('VCARD', 'k'), 120)
        c.call('CLIENT', 'UNPAUSE')
        for x in (a, d, e):
            self.assertEqual(x.reply(), 1)
        order = vs.monitor_collect(monitor, s.client())
        commits = [argv for who, argv in order if argv[:1] == [b'VADD']]
        self.assertEqual(len(commits), 3)
        replay = twin.client()
        for value in replay.pipeline(commits):
            self.assertEqual(value, 1)
        self.assertEqual(c.call('DEBUG', 'DIGEST'), replay.call('DEBUG', 'DIGEST'))
        self.settle(c)

    def test_a_cas_commit_waits_for_a_pause_of_all_commands_until_it_expires(self):
        s, c, a, b = self.prepared()
        with vs.Hold(s) as hold:
            a.send(*self.cas('late'))
            b.send('CLIENT', 'PAUSE', 700, 'ALL')
        self.assertEqual(b.reply(), 'OK')
        self.assertEqual(a.reply(), 1)
        self.assertGreaterEqual(time.monotonic() - hold.started, hold.seconds + 0.6)
        self.assertEqual(c.call('VISMEMBER', 'k', 'late'), 1)
        self.settle(c)

    def test_a_search_is_published_while_a_write_pause_lasts(self):
        s, c, a, b = self.prepared()
        q = ['VALUES', 8, *vs.vector(vs.seeded(83), 8), 'COUNT', 10, 'WITHSCORES']
        want = c.call('VSIM', 'k', *q, 'NOTHREAD')
        with vs.Hold(s):
            a.send('VSIM', 'k', *q)
            b.send('CLIENT', 'PAUSE', 120000, 'WRITE')
        self.assertEqual(b.reply(), 'OK')
        self.assertEqual(a.reply(), want)
        c.call('CLIENT', 'UNPAUSE')
        self.settle(c)

    def test_a_commit_held_by_a_pause_is_dropped_when_its_connection_is_killed(self):
        s, c, a, b = self.prepared()
        digest = c.call('DEBUG', 'DIGEST')
        ident = a.call('CLIENT', 'ID')
        with vs.Hold(s):
            a.send(*self.cas('orphan'))
            b.send('CLIENT', 'PAUSE', 120000, 'WRITE')
        self.assertEqual(b.reply(), 'OK')
        self.quiet(c)
        self.assertEqual(c.call('CLIENT', 'KILL', 'ID', ident), 1)
        self.quiet(c)
        c.call('CLIENT', 'UNPAUSE')
        self.settle(c)
        self.assertEqual(c.call('DEBUG', 'DIGEST'), digest)
        self.assertEqual(c.call('VISMEMBER', 'k', 'orphan'), 0)
        info = vs.compute(c)
        self.assertEqual(info['compute_jobs_cancelled'], self.jobs(1))

    def test_a_commit_held_by_a_pause_survives_a_client_that_only_closed_its_end(self):
        s, c, a, b = self.prepared()
        with vs.Hold(s):
            a.send(*self.cas('half'))
            b.send('CLIENT', 'PAUSE', 120000, 'WRITE')
        self.assertEqual(b.reply(), 'OK')
        self.quiet(c)
        a.socket.shutdown(socket.SHUT_WR)
        self.quiet(c)
        self.assertEqual(c.call('VISMEMBER', 'k', 'half'), 0)
        c.call('CLIENT', 'UNPAUSE')
        self.assertEqual(a.reply(), 1)
        self.assertEqual(c.call('VISMEMBER', 'k', 'half'), 1)
        self.settle(c)

    def test_a_shutdown_while_a_commit_is_held_exits_cleanly(self):
        s, c, a, b = self.prepared()
        with vs.Hold(s):
            a.send(*self.cas('shut'))
            b.send('CLIENT', 'PAUSE', 120000, 'WRITE')
        self.assertEqual(b.reply(), 'OK')
        self.quiet(c)
        c.send('SHUTDOWN', 'NOSAVE')
        deadline = time.monotonic() + 60
        while s.process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(s.process.poll(), 0)

    def test_a_forgotten_owners_held_commit_is_dropped(self):
        s = self.server(mode='owners')
        c = s.client()
        mine = vs.at('owners', owner='u1')
        vs.fill(c, mine, 'k', vs.seeded(81), 8, 120)
        a, b = s.client(timeout=60), s.client(timeout=60)
        vs.warm([a, b])
        top = vs.top('owners')
        with vs.Hold(s, 'owners'):
            a.send(*vs.vadd(mine, 'k', vs.seeded(85), 8, 'ghost', 'CAS'))
            b.send(*top, 'CLIENT', 'PAUSE', 120000, 'WRITE')
        self.assertEqual(b.reply(), 'OK')
        self.quiet(c)
        c.call(*top, 'OWNERS', 'FORGET', 'u1')
        c.call(*top, 'CLIENT', 'UNPAUSE')
        self.settle(c, 'owners')
        self.assertEqual(c.call(*mine, 'EXISTS', 'k'), 0)


def fields(text):
    out = {}
    for line in text.decode().splitlines():
        if ':' in line and not line.startswith('#'):
            k, v = line.split(':', 1)
            out[k] = v
    return out


def command_calls(text):
    out = {}
    for k, v in fields(text).items():
        if k.startswith('cmdstat_'):
            parts = dict(p.split('=') for p in v.split(','))
            out[k] = (parts['calls'], parts['rejected_calls'], parts['failed_calls'])
    return out


class Scope(Base):
    QUIET = ('--slowlog-log-slower-than', '0', '--slowlog-max-len', '1000000')

    def strings(self, n):
        return ''.join('abcd'[i * n % 4] for i in range(1100))

    def deferred(self, mode, hidden, high, low, low_login=None):
        s = self.server(mode=mode, arguments=self.QUIET)
        h, l, admin = s.client(timeout=120), s.client(timeout=120), s.client(timeout=120)
        self.assertEqual(admin.call(*vs.top(mode), 'SLOWLOG', 'RESET'), 'OK')
        if mode == 'owners':
            admin.call(*vs.top(mode), 'ACL', 'SETUSER', 'plainowner', *vs.OPERATOR, 'owners:*')
            self.assertEqual(l.call('AUTH', 'plainowner', 'x'), 'OK')
        vs.fill(h, high, 'secret', self.rng(71), 8, 620)
        h.call(*high, 'SET', 'left', self.strings(7))
        h.call(*high, 'SET', 'right', self.strings(5))
        vs.fill(l, low, 'pub', self.rng(72), 8, 120)
        l.call(*low, 'SET', 'mine-left', self.strings(3))
        l.call(*low, 'SET', 'mine-right', self.strings(7))
        l.call(*low, 'SET', 'mine', 'x')
        query = ('VSIM', 'secret', 'VALUES', 8, *vs.vector(self.rng(73), 8), 'COUNT', 20)
        low_query = ('VSIM', 'pub', 'VALUES', 8, *vs.vector(self.rng(74), 8), 'COUNT', 15, 'WITHSCORES')
        if hidden:
            h.send_many([(*high, *query), (*high, 'LCS', 'left', 'right', 'LEN')] * 20)
        seen = []
        for i in range(25):
            seen.append(l.call(*low, 'VSIM', 'pub', *low_query[2:]))
            seen.append(l.call(*low, 'LCS', 'mine-left', 'mine-right', 'LEN'))
            seen.append(l.call(*low, 'SET', 'k%d' % i, 'v%d' % i))
            seen.append(l.call(*low, 'GET', 'mine'))
            seen.append(l.call(*low, 'DBSIZE'))
            seen.append(l.call(*low, 'EXISTS', 'secret', 'left'))
        if hidden:
            for unused in range(40):
                self.assertNotIsInstance(h.reply(), ServerError)
        self.settle(admin, mode)
        view = {'replies': seen}
        for section in ('commandstats', 'stats', 'latencystats', 'errorstats', 'keyspace'):
            view[section] = l.call(*low, 'INFO', section)
        view['compute'] = vs.compute(l, prefix=low)
        view['slowlen'] = l.call(*low, 'SLOWLOG', 'LEN')
        view['slowlog'] = [e[3] for e in l.call(*low, 'SLOWLOG', 'GET', -1)]
        return view

    def twins(self, mode, high, low):
        with_work = self.deferred(mode, True, high, low)
        without = self.deferred(mode, False, high, low)
        self.assertEqual(with_work['replies'], without['replies'])
        for section in ('commandstats', 'stats', 'latencystats', 'errorstats', 'keyspace'):
            self.assertEqual(norm_info(with_work[section]), norm_info(without[section]), 'INFO %s differs for a low reader' % section)
        self.assertEqual(with_work['compute'], without['compute'])
        for name, value in with_work['compute'].items():
            if name != 'compute_threads_configured' and name != 'compute_threads_active':
                self.assertEqual(value, 0, 'a low reader sees %s' % name)
        self.assertEqual(with_work['slowlen'], without['slowlen'])
        self.assertEqual(with_work['slowlog'], without['slowlog'])
        for args in with_work['slowlog']:
            self.assertNotEqual(args[:2], [b'VSIM', b'secret'], 'a low reader sees the slow log entry of hidden work')
            self.assertNotEqual(args[:2], [b'LCS', b'left'], 'a low reader sees the slow log entry of hidden work')

    def test_a_low_readers_replies_statistics_and_slow_log_ignore_hidden_deferred_work_with_labels(self):
        self.twins('labels', vs.at('labels', 'S//A'), vs.at('labels', 'U'))

    def test_a_low_readers_replies_statistics_and_slow_log_ignore_hidden_deferred_work_in_owner_mode(self):
        self.twins('owners', vs.at('owners', owner='u1'), vs.at('owners', owner='u2'))

    def check_high(self, mode, high, low):
        s = self.server(mode=mode, arguments=self.QUIET)
        h, l = s.client(), s.client()
        if mode == 'owners':
            h.call(*vs.top(mode), 'ACL', 'SETUSER', 'plainowner', *vs.OPERATOR, 'owners:*')
            self.assertEqual(l.call('AUTH', 'plainowner', 'x'), 'OK')
        vs.fill(h, high, 'secret', self.rng(71), 8, 620)
        h.call(*high, 'SET', 'left', self.strings(7))
        h.call(*high, 'SET', 'right', self.strings(5))
        l.call(*low, 'SET', 'mine', 'x')
        before = vs.compute(s.client(), mode)
        query = ('VSIM', 'secret', 'VALUES', 8, *vs.vector(self.rng(72), 8), 'COUNT', 20)
        for round in range(30):
            h.send_many([(*high, *query), (*high, 'LCS', 'left', 'right', 'LEN')] * 3)
            for unused in range(6):
                l.call(*low, 'GET', 'mine')
            for unused in range(6):
                self.assertNotIsInstance(h.reply(), ServerError)
        self.settle(s.client(), mode)
        after = vs.compute(s.client(), mode)
        if THREADS:
            self.assertGreaterEqual(after['compute_jobs_submitted'] - before['compute_jobs_submitted'], 180)
        for entry in l.call(*low, 'SLOWLOG', 'GET', -1):
            args = entry[3]
            self.assertNotIn(args[0].upper(), (b'VSIM', b'LCS'), 'a low reader sees a deferred entry of a hidden scope: %r' % (args[:3],))
        seen = [e[3][0].upper() for e in h.call(*high, 'SLOWLOG', 'GET', -1)]
        self.assertIn(b'VSIM', seen)
        self.assertIn(b'LCS', seen)

    def test_deferred_work_keeps_its_label_in_the_slow_log(self):
        self.check_high('labels', vs.at('labels', 'S//A'), vs.at('labels', 'U'))

    def test_deferred_work_keeps_its_owner_in_the_slow_log(self):
        self.check_high('owners', vs.at('owners', owner='u1'), vs.at('owners', owner='u2'))


VOLATILE = ('process_id', 'run_id', 'tcp_port', 'server_time_usec', 'lru_clock', 'executable', 'listener0',
            'master_replid', 'uptime_in_seconds', 'uptime_in_days', 'config_file', 'monotonic_clock')


def low_info(text):
    if isinstance(text, (ServerError, str)):
        return text
    return [line for line in text.decode().splitlines() if line.split(':', 1)[0] not in VOLATILE]


def own_clients(text):
    if isinstance(text, (ServerError, str)):
        return text
    rows = []
    for line in text.decode().splitlines():
        if line:
            pairs = dict(p.split('=', 1) for p in line.split(' ') if '=' in p)
            kept = [p for p in line.split(' ') if p.split('=', 1)[0] not in ('addr', 'laddr', 'age', 'idle', 'rbs', 'rbp', 'qbuf-free', 'tot-mem')]
            buffers = int(pairs['rbs']) + int(pairs['qbuf']) + int(pairs['qbuf-free'])
            kept.append('tot-mem-beside-the-buffers=%d' % (int(pairs['tot-mem']) - buffers))
            rows.append(' '.join(kept))
    return rows


WRITES = (b'VADD', b'VREM', b'VSETATTR', b'DEL', b'SET')


def low_frame(frame):
    if isinstance(frame, bytes) and b'# Server' in frame:
        return low_info(frame.split(b'\r\n', 1)[1])
    return frame


def raw_or_end(raw):
    try:
        return raw.frame()
    except (EOFError, ConnectionError):
        return 'EOF'


class Twins(Base):
    HIDDEN = 64
    BUDGET_JOBS = 60

    def setup(self, mode, kind, memory, hidden_elements):
        s = self.server(mode=mode, arguments=('--slowlog-log-slower-than', '20000', '--slowlog-max-len', '1000'), memory=memory)
        admin = s.client(timeout=120)
        top = vs.top(mode)
        if mode == 'labels':
            admin.call(*top, 'ACL', 'SETUSER', 'low', 'on', '>pw', '~*', '&*', '+@all', 'clearance:U')
            high, low = vs.at('labels', 'S//A/B'), ()
        else:
            admin.call(*top, 'ACL', 'SETUSER', 'low', 'on', '>pw', '~*', '&*', '+@all', 'owner:u2')
            high, low = vs.at('owners', owner='u1'), ()
            vs.fill(admin, top, 'k', self.rng(80), 8, 64, names=['s%d' % i for i in range(64)])

        def login():
            x = s.client(timeout=120)
            self.assertEqual(x.call('AUTH', 'low', 'pw'), 'OK')
            return x
        first = login()
        vs.fill(first, low, 'k', self.rng(81), 8, 700)
        vs.fill(admin, high, 'k', self.rng(82), 8, hidden_elements, names=['h%d' % i for i in range(hidden_elements)])
        vs.fill(admin, high, 'hk', self.rng(83), 8, 300)
        hidden = [s.client(timeout=120) for unused in range(self.HIDDEN)]
        vs.warm(hidden)
        self.assertEqual(admin.call(*top, 'SLOWLOG', 'RESET'), 'OK')
        return s, admin, top, high, low, login, hidden

    def hidden_steps(self, kind, active, admin, top, high, hidden, rng):
        steps = []
        if kind == 'fork':
            steps.append((admin, [(*top, 'BGSAVE') if active else (*top, 'DBSIZE')]))
        for i, h in enumerate(hidden):
            if active and kind == 'queue':
                command = (*high, 'VSIM', 'hk', 'ELE', 'e%d' % i, 'COUNT', 5)
            elif active and kind == 'budget' and i < self.BUDGET_JOBS:
                command = (*high, 'VSIM', 'hk', 'ELE', 'e%d' % i, 'COUNT', 5)
            elif active and kind == 'search' and i < self.BUDGET_JOBS:
                command = (*high, 'VSIM', 'k', 'VALUES', 8, *vs.vector(rng, 8), 'COUNT', 5, 'TRUTH', 'FILTER', '.a >= 0')
            else:
                command = (*high, 'VCARD', 'hk')
            steps.append((h, [command]))
        return steps

    def batch(self, s, mode, steps, low_steps):
        with vs.Hold(s, mode, seconds=1.5):
            for client, commands in steps:
                client.send_many(commands)
            for client, commands in low_steps:
                client.send_many(commands)
        for client, commands in steps:
            for unused in commands:
                client.reply()
        return [[raw_or_end(vs.Raw(client)) for unused in commands] for client, commands in low_steps]

    def quiet_fork(self, admin, top):
        def done():
            return b'rdb_bgsave_in_progress:0' in admin.call(*top, 'INFO', 'persistence')
        wait_for(done, 60, 'the snapshot child to finish')

    def low_view(self, mode, kind, active, memory, hidden_elements):
        s, admin, top, high, low, login, hidden = self.setup(mode, kind, memory, hidden_elements)
        rng = self.rng(90)
        r2, r3 = login(), login()
        seen = []
        probe = ('VADD', 'k', 'VALUES', 8, *vs.vector(self.rng(91), 8), 'probe', 'CAS')
        r1 = login()
        seen.append(self.batch(s, mode, self.hidden_steps(kind, active, admin, top, high, hidden, rng),
                               [(r1, [(*low, *probe)]), (r2, [(*low, 'VISMEMBER', 'k', 'probe')]), (r3, [(*low, 'INFO', 'everything')])]))
        self.settle(admin, mode)
        self.quiet_fork(admin, top)
        killed = login()
        killed_id = killed.call(*low, 'CLIENT', 'ID')
        seen.append(self.batch(s, mode, self.hidden_steps(kind, active, admin, top, high, hidden, rng),
                               [(killed, [(*low, 'VSIM', 'k', 'ELE', 'e3', 'COUNT', 700, 'WITHSCORES')]), (r2, [(*low, 'CLIENT', 'KILL', 'ID', killed_id)]),
                                (r3, [(*low, 'INFO', 'everything')])]))
        self.settle(admin, mode)
        self.quiet_fork(admin, top)
        seen.append(self.batch(s, mode, self.hidden_steps(kind, active, admin, top, high, hidden, rng),
                               [(r2, [(*low, 'VSETATTR', 'k', 'e1', '{"x":1}')]), (r3, [(*low, 'VSIM', 'k', 'ELE', 'e5', 'COUNT', 4), (*low, 'INFO', 'everything')])]))
        self.settle(admin, mode)
        self.quiet_fork(admin, top)
        view = {'batches': []}
        for batch in seen:
            view['batches'].append([[low_frame(frame) for frame in replies] for replies in batch])
        r2.send(*low, 'SLOWLOG', 'GET', -1)
        view['slowlog'] = [norm(entry)[3] for entry in r2.reply() if norm(entry)[3][0].upper() in WRITES]
        view['info'] = low_info(r2.call(*low, 'INFO', 'everything'))
        view['clients'] = own_clients(r2.call(*low, 'CLIENT', 'LIST'))
        r2.send(*low, 'LATENCY', 'LATEST')
        view['latency'] = norm(r2.reply())
        return view

    def budget(self, mode):
        s, admin, top, high, low, login, hidden = self.setup(mode, 'budget', 512 << 20, 300)
        before = vs.compute(admin, mode)['compute_memory_reserved']
        steps = [(hidden[0], [(*high, 'VSIM', 'hk', 'ELE', 'e0', 'COUNT', 5)]), (admin, [(*top, 'INFO', 'server')])]
        with vs.Hold(s, mode, seconds=1.0):
            for client, commands in steps:
                client.send_many(commands)
        hidden[0].reply()
        text = admin.reply()
        reserved = int(dict(line.split(':', 1) for line in text.decode().splitlines() if ':' in line)['compute_memory_reserved']) - before
        self.settle(admin, mode)
        self.assertGreater(reserved, 0)
        return reserved * self.BUDGET_JOBS

    def twin(self, mode, kind):
        if THREADS == 0:
            self.skipTest('the hidden scope fills compute capacity only when there are compute threads')
        memory = self.budget(mode) if kind == 'budget' else 512 << 20
        hidden_elements = 40000 if kind == 'search' else 300
        quiet = self.low_view(mode, kind, False, memory, hidden_elements)
        busy = self.low_view(mode, kind, True, memory, hidden_elements)
        for n, (a, b) in enumerate(zip(quiet['batches'], busy['batches'])):
            self.assertEqual(a, b, 'batch %d: the low login reads different replies when a hidden scope fills %s' % (n, kind))
        for name in ('slowlog', 'info', 'clients', 'latency'):
            self.assertEqual(quiet[name], busy[name], 'the low login reads a different %s when a hidden scope fills %s' % (name, kind))
        self.assertEqual(quiet['batches'][0][1], [b':0\r\n'], 'a threaded commit is published at the tick, after the rest of its batch')
        self.assertEqual(quiet['batches'][1][0], ['EOF'], 'a killed connection gets no answer to a pending search')
        self.assertEqual(quiet['slowlog'], [], 'the low login has no slow write of its own')

    def test_a_hidden_scope_that_fills_the_queue_changes_nothing_a_low_login_reads_with_labels(self):
        self.twin('labels', 'queue')

    def test_a_hidden_scope_that_takes_the_memory_budget_changes_nothing_a_low_login_reads_with_labels(self):
        self.twin('labels', 'budget')

    def test_a_hidden_search_on_a_shared_set_changes_nothing_a_low_login_reads_with_labels(self):
        self.twin('labels', 'search')

    def test_a_fork_caused_above_a_low_login_changes_nothing_it_reads_with_labels(self):
        self.twin('labels', 'fork')

    def test_a_hidden_owner_that_fills_the_queue_changes_nothing_another_owner_reads(self):
        self.twin('owners', 'queue')

    def test_a_hidden_owner_that_takes_the_memory_budget_changes_nothing_another_owner_reads(self):
        self.twin('owners', 'budget')

    def test_a_hidden_owners_search_on_a_shared_set_changes_nothing_another_owner_reads(self):
        self.twin('owners', 'search')

    def test_a_fork_caused_by_the_operator_changes_nothing_an_owner_reads(self):
        self.twin('owners', 'fork')


def norm_info(text):
    drop = ('avg_ttl', 'uptime', 'usec')
    lines = []
    for line in text.decode().splitlines():
        if any(d in line for d in drop):
            line = ','.join(p for p in line.split(',') if not any(d in p for d in drop))
        lines.append(line)
    return lines


class Statistics(Base):
    QUIET = ('--slowlog-log-slower-than', '0', '--slowlog-max-len', '1000000')

    def long_strings(self):
        return ''.join('abcd'[i * 7 % 4] for i in range(1100)), ''.join('abcd'[i * 5 % 4] for i in range(1100))

    def observe(self, s):
        c = s.client()
        self.assertEqual(c.call('CONFIG', 'RESETSTAT'), 'OK')
        self.assertEqual(c.call('SLOWLOG', 'RESET'), 'OK')
        rng = self.rng(91)
        left, right = self.long_strings()
        c.call('SET', 'left', left)
        c.call('SET', 'right', right)
        vs.fill(c, (), 'k', rng, 8, 120)
        replies = []
        for i in range(20):
            replies.append(c.call('VSIM', 'k', 'VALUES', 8, *vs.vector(rng, 8), 'COUNT', 7, 'WITHSCORES'))
            replies.append(c.call('VSIM', 'k', 'ELE', 'e%d' % (i * 3), 'COUNT', 4))
            replies.append(c.call('VSIM', 'nosuch', 'VALUES', 8, *vs.vector(rng, 8)))
            replies.append(norm(c.pipeline([('VSIM', 'k', 'VALUES', 3, 1, 2, 3)])[0]))
            replies.append(c.call(*vs.vadd((), 'k', rng, 8, 'cas%d' % i, 'CAS')))
            replies.append(c.call('LCS', 'left', 'right', 'LEN'))
            replies.append(c.call('LCS', 'left', 'right'))
        calls = command_calls(c.call('INFO', 'commandstats'))
        stats = fields(c.call('INFO', 'stats'))
        keep = {k: stats[k] for k in ('total_commands_processed', 'keyspace_hits', 'keyspace_misses', 'total_error_replies', 'unexpected_error_replies')}
        errors = fields(c.call('INFO', 'errorstats'))
        slow = [e[3] for e in c.call('SLOWLOG', 'GET', -1)]
        return {'replies': replies, 'calls': calls, 'stats': keep, 'errors': errors, 'slowlog': slow, 'slowlen': c.call('SLOWLOG', 'LEN')}

    def test_commands_run_on_workers_count_and_log_exactly_like_inline_ones(self):
        threaded = self.server(arguments=self.QUIET)
        inline = self.server(workers=0, arguments=self.QUIET)
        a, b = self.observe(threaded), self.observe(inline)
        for name in ('replies', 'calls', 'stats', 'errors', 'slowlen'):
            self.assertEqual(a[name], b[name], name)
        self.assertEqual(a['slowlog'], b['slowlog'])
        for name in ('vsim', 'vadd', 'lcs'):
            self.assertIn('cmdstat_' + name, {k.lower() for k in a['calls']})
        if THREADS:
            info = vs.compute(threaded.client())
            self.assertGreater(info['compute_jobs_submitted'], 40)

    def test_commands_run_on_workers_count_and_log_exactly_like_forced_inline_ones(self):
        threaded = self.server(arguments=self.QUIET)
        inline = self.server(arguments=self.QUIET + FORCE)
        a, b = self.observe(threaded), self.observe(inline)
        for name in ('replies', 'calls', 'stats', 'errors', 'slowlen', 'slowlog'):
            self.assertEqual(a[name], b[name], name)


class Control(Base):
    def test_the_thread_sanitizer_still_detects_a_planted_race(self):
        head = BINARY.read_bytes()
        if b'__tsan_init' not in head:
            self.skipTest('the server under test is not a thread sanitizer build')
        odin = os.environ.get('ODIN') or shutil.which('odin')
        if not odin:
            self.fail('no odin compiler is available to build the planted race')
        control = ROOT / 'verification/scheduling/race_control.odin'
        with tempfile.TemporaryDirectory(prefix='eski-race-control-') as scratch:
            out = Path(scratch) / 'race-control'
            built = subprocess.run([odin, 'build', str(control), '-file', '-out:' + str(out), '-thread-count:2', '-vet', '-strict-style', '-sanitize:thread'],
                                   capture_output=True, text=True, cwd=scratch)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            env = dict(os.environ, TSAN_OPTIONS='halt_on_error=1:exitcode=66')
            ran = subprocess.run([str(out)], capture_output=True, text=True, env=env, timeout=60, cwd=scratch)
            report = ran.stdout + ran.stderr
            self.assertEqual(ran.returncode, 66, report)
            self.assertIn('WARNING: ThreadSanitizer: data race', report)
            self.assertIn('main::shared', report)


def main(argv=None):
    global BINARY, THREADS, SEED
    parser = argparse.ArgumentParser(description='Threaded vector search and compare-and-swap insertion against their inline replies; no performance collection.')
    parser.add_argument('--server', type=Path, default=Path(os.environ.get('ESKI_THREADING_BIN', ROOT / 'bin/eski')))
    parser.add_argument('--compute-threads', type=int, default=2)
    parser.add_argument('--seed', type=int, default=0, help='added to every random stream; printed again when a case fails')
    parser.add_argument('--ports', default='', help='inclusive port range such as 7000-7099; default: any free port')
    parser.add_argument('--case', default='*', help='unittest method glob')
    parser.add_argument('--timeout', type=int, default=900, help='whole-run wall-clock limit in seconds')
    args = parser.parse_args(argv)
    BINARY = args.server.resolve()
    THREADS = args.compute_threads
    SEED = args.seed
    if args.timeout <= 0 or not BINARY.is_file() or THREADS < 0:
        parser.error('positive timeout, a non-negative thread count and an existing --server binary are required')
    vs.use_ports(args.ports)
    loader = unittest.defaultTestLoader
    suite = unittest.TestSuite()
    for case in (Pairs, Cas, SameSet, Rules, Lifecycle, Pause, Scope, Twins, Statistics, Control):
        for name in loader.getTestCaseNames(case):
            if fnmatch.fnmatchcase(name, args.case):
                suite.addTest(case(name))
    if suite.countTestCases() == 0:
        parser.error('--case selected no tests')

    def expired(unused_signal, unused_frame):
        print('vector threading checks exceeded their wall-clock limit', file=sys.stderr)
        raise SystemExit(124)
    old = signal.signal(signal.SIGALRM, expired)
    signal.alarm(args.timeout)
    try:
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


if __name__ == '__main__':
    raise SystemExit(main())
