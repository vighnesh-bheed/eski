import argparse
import os
from pathlib import Path
import random
import signal
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
import labelled_files as lf
from support import Client, ServerError

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0
OLDER = None
FIXTURES = ROOT / 'test/compatibility/fixtures'
WRITE_FIXTURES = False
SCHEME = ('--label-levels', 'U,C,S', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED')
SEEDS = ('--debug-hash-seed', '11', '--label-stream-seed', '5')
OPERATOR = ('on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*')
TOP = ('LABEL', 'AS', 'S//A/B')
TOP_ERROR = 'ERR this command needs a label that dominates the whole label scheme'
MIGRATE_ERROR = 'ERR MIGRATE is off while a label scheme is configured; move keys with DUMP and RESTORE'
STARTUP_REFUSED = 'holds data that carries no labels or owners, and a server with a label scheme or owner mode never loads it'
LABELLED_REFUSED = 'holds data with labels or owners; start the server with the label scheme and owner mode it was written with'
READERS = ('U', 'C', 'S', 'S//A', 'S//B', 'S//A/B', 'C;VETTED', 'U;VETTED', 'S//A/B;VETTED')
FAR = 4102444800000
SCHEME_BLOB = lf.eslt(['U', 'C', 'S'], ['A', 'B'], ['WEB', 'VETTED'], [(1, 0, ()), (2, 0, (0,)), (2, 0, (1,))])
WIDE_BLOB = lf.eslt(['L%d' % i for i in range(256)], (), ['T%d' % i for i in range(256)], [(i // 256, i % 256, ()) for i in range(1, 65535)])
DEEP_PAYLOAD = bytes.fromhex('100d0d00000002008166028f7602ff0c0074a8454cbe340d07')
SLOW = ('--key-load-delay', '2000', '--loading-process-events-interval-bytes', '1024')


def error_of(client, *arguments):
    try:
        value = client.call(*arguments)
    except ServerError as error:
        return str(error)
    raise AssertionError('expected an error from %r, got %r' % (arguments, value))


def at(label):
    return ('LABEL', 'AS', label)


def read_value(c, p, key, kind):
    if kind == 'string':
        return c.call(*p, 'GET', key)
    if kind == 'list':
        return c.call(*p, 'LRANGE', key, 0, -1)
    if kind == 'set':
        return sorted(c.call(*p, 'SMEMBERS', key))
    if kind == 'zset':
        return c.call(*p, 'ZRANGE', key, 0, -1, 'WITHSCORES')
    if kind == 'hash':
        flat = c.call(*p, 'HGETALL', key)
        fields = sorted(flat[0::2])
        times = c.call(*p, 'HPEXPIRETIME', key, 'FIELDS', len(fields), *fields)
        return sorted(zip(flat[0::2], flat[1::2])), times
    if kind == 'stream':
        groups = c.call(*p, 'XINFO', 'GROUPS', key)
        return c.call(*p, 'XRANGE', key, '-', '+'), [g[1] for g in groups]
    return kind


def full_scan(c, p, *extra):
    seen = []
    cursor = b'0'
    cursors = []
    while True:
        cursor, batch = c.call(*p, 'SCAN', cursor, 'COUNT', 7, *extra)
        cursors.append(cursor)
        seen.extend(batch)
        if cursor == b'0':
            return sorted(set(seen)), cursors


def view(c, reader, dbs=(0, 1)):
    p = at(reader)
    out = {}
    for db in dbs:
        c.call('SELECT', db)
        keys, _ = full_scan(c, p)
        out[(db, 'scan')] = keys
        out[(db, 'dbsize')] = c.call(*p, 'DBSIZE')
        out[(db, 'keys')] = sorted(c.call(*p, 'KEYS', '*'))
        for k in keys:
            kind = c.call(*p, 'TYPE', k)
            out[(db, k, 'type')] = kind
            out[(db, k, 'value')] = read_value(c, p, k, kind)
            out[(db, k, 'expire')] = c.call(*p, 'PEXPIRETIME', k)
            out[(db, k, 'label')] = c.call(*p, 'LABEL', 'OF', k)
    c.call('SELECT', 0)
    out['keyspace'] = [keyspace_line(l) for l in c.call(*p, 'INFO', 'keyspace').decode().splitlines() if l.startswith('db')]
    return out


def keyspace_line(line):
    return ','.join(part for part in line.split(',') if not part.startswith('avg_ttl='))


def state(c, readers=READERS):
    return {
        'scopes': c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'),
        'digest': c.call(*TOP, 'DEBUG', 'DIGEST'),
        'quota': c.call(*TOP, 'LABEL', 'QUOTA', 'C'),
        'views': {r: view(c, r) for r in readers},
    }


def populate(c, rng):
    for label in ('U', 'C', 'S//A', 'C;VETTED'):
        p = at(label)
        tag = label.replace('/', '').replace(';', '-')
        c.call(*p, 'SET', 's-' + tag, 'value at ' + label)
        c.call(*p, 'SET', 'n-' + tag, 12345)
        c.call(*p, 'RPUSH', 'l-' + tag, *['e%d' % i for i in range(5)])
        c.call(*p, 'RPUSH', 'bigl-' + tag, *['x' * 40 + str(i) for i in range(200)])
        c.call(*p, 'SADD', 'set-' + tag, *range(10))
        c.call(*p, 'SADD', 'bigset-' + tag, *['m%d' % i for i in range(300)])
        c.call(*p, 'ZADD', 'z-' + tag, *[x for i in range(6) for x in (i * 1.5, 'z%d' % i)])
        c.call(*p, 'ZADD', 'bigz-' + tag, *[x for i in range(200) for x in (rng.random(), 'w%d' % i)])
        c.call(*p, 'HSET', 'h-' + tag, *[x for i in range(5) for x in ('f%d' % i, 'v%d' % i)])
        c.call(*p, 'HSET', 'bigh-' + tag, *[x for i in range(300) for x in ('g%d' % i, 'v' * 70)])
        c.call(*p, 'HPEXPIREAT', 'h-' + tag, FAR, 'FIELDS', 2, 'f1', 'f3')
        c.call(*p, 'HPEXPIREAT', 'bigh-' + tag, FAR - 5, 'FIELDS', 1, 'g7')
        c.call(*p, 'XADD', 'x-' + tag, '1-1', 'a', 1)
        c.call(*p, 'XADD', 'x-' + tag, '2-1', 'b', 2)
        c.call(*p, 'XGROUP', 'CREATE', 'x-' + tag, 'grp', '0')
        c.call(*p, 'SET', 't-' + tag, 'timed', 'PXAT', FAR - 1000)
    for label, value in (('S//A', 'sa'), ('S//B', 'sb'), ('C', 'c'), ('U', 'u'), ('C;VETTED', 'cv')):
        c.call(*at(label), 'SET', 'dup', value)
    for label, value in (('S//B', 'sb'), ('S//A', 'sa')):
        c.call(*at(label), 'SET', 'dup2', value)
    c.call(*at('S//A'), 'SET', 'mixed', 'string at S//A')
    c.call(*at('U'), 'RPUSH', 'mixed', 'list at U')
    c.call(*at('C//A'), 'SET', 'gone', 'x')
    c.call(*at('C//A'), 'DEL', 'gone')
    c.call('SELECT', 1)
    c.call(*at('C'), 'SET', 'other-db', 'one')
    c.call(*at('S'), 'SET', 'dup', 'db1')
    c.call(*at('U'), 'SET', 'dup', 'db1u')
    c.call('SELECT', 0)
    c.call(*TOP, 'LABEL', 'QUOTA', 'C', 'LIMIT', 50000000)
    c.call(*TOP, 'LABEL', 'QUOTA', 'S//A', 'LIMIT', 60000000)


class Base(unittest.TestCase):
    arguments = SCHEME + SEEDS + ('--save', '3600 1')

    def setUp(self):
        self.temp = lf.workdir('eski-labels-persist-')
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.runs = []

    def tearDown(self):
        for run in self.runs:
            run.kill()

    def run_server(self, arguments=None, directory=None, binary=None):
        run = lf.Run(binary or BINARY, directory or self.dir, self.arguments if arguments is None else arguments, KEYSPACE_THREADS)
        self.runs.append(run)
        return run

    def up(self, run, extra=()):
        code, text = run.start(extra)
        self.assertIsNone(code, 'server exited with %r: %s' % (code, text[-3000:]))
        c = run.client()
        c.call('ACL', 'SETUSER', 'default', *OPERATOR)
        return c

    def refused(self, run, extra=()):
        code, text = run.start(extra)
        if code is None:
            run.stop()
            self.fail('server started on a file it must refuse')
        self.assertEqual(code, 1, text[-3000:])
        return text


class RoundTrip(Base):
    def check_round_trip(self, how):
        run = self.run_server()
        c = self.up(run)
        populate(c, random.Random(3))
        before = state(c)
        if how == 'save':
            self.assertEqual(c.call(*TOP, 'SAVE'), 'OK')
            run.stop(signal.SIGKILL)
        elif how == 'bgsave':
            self.assertEqual(c.call(*TOP, 'BGSAVE'), 'Background saving started')
            lf_wait(lambda: lf.info(c, *TOP)['rdb_bgsave_in_progress'] == '0')
            self.assertEqual(lf.info(c, *TOP)['rdb_last_bgsave_status'], 'ok')
            run.stop(signal.SIGKILL)
        elif how == 'shutdown':
            self.assertEqual(run.stop(signal.SIGTERM), 0)
        elif how == 'savepoint':
            saves = int(lf.info(c, *TOP)['rdb_saves'])
            c.call(*TOP, 'CONFIG', 'SET', 'save', '1 1')
            lf_wait(lambda: int(lf.info(c, *TOP)['rdb_saves']) > saves and lf.info(c, *TOP)['rdb_bgsave_in_progress'] == '0', 20)
            run.stop(signal.SIGKILL)
        if how == 'reload':
            self.assertEqual(c.call(*TOP, 'DEBUG', 'RELOAD'), 'OK')
        else:
            c = self.up(run)
        after = state(c)
        self.assertEqual(before['scopes'], after['scopes'])
        self.assertEqual(before['digest'], after['digest'])
        self.assertEqual(before['quota'][0], after['quota'][0])
        for reader in READERS:
            self.assertEqual(before['views'][reader], after['views'][reader], 'reader %s after %s' % (reader, how))
        if how != 'reload':
            loaded = int(lf.info(c, *TOP)['rdb_last_load_keys_loaded'])
            self.assertEqual(loaded, 60)
        return c, run

    def test_save_and_restart(self):
        self.check_round_trip('save')

    def test_bgsave_and_restart(self):
        self.check_round_trip('bgsave')

    def test_shutdown_save_and_restart(self):
        self.check_round_trip('shutdown')

    def test_save_point_and_restart(self):
        self.check_round_trip('savepoint')

    def test_debug_reload(self):
        c, _ = self.check_round_trip('reload')
        self.assertEqual(c.call(*at('S//A/B'), 'GET', 'dup'), b'sa')

    def test_saving_the_same_state_twice_gives_the_same_bytes(self):
        run = self.run_server(SCHEME + SEEDS + ('--save', '', '--rdbcompression', 'no'))
        c = self.up(run)
        populate(c, random.Random(4))
        c.call(*TOP, 'SAVE')
        first = (self.dir / 'dump.rdb').read_bytes()
        c.call(*TOP, 'SAVE')
        second = (self.dir / 'dump.rdb').read_bytes()
        self.assertEqual(lf.access_bytes(first), lf.access_bytes(second))

    def test_access_policy_hints_survive_per_copy(self):
        run = self.run_server(SCHEME + SEEDS + ('--save', '', '--maxmemory-policy', 'allkeys-lfu', '--lfu-decay-time', '0'))
        c = self.up(run)
        c.call(*at('S//A'), 'SET', 'f', 'high')
        c.call(*at('U'), 'SET', 'f', 'low')
        c.call(*at('S//A'), 'OBJECT', 'FREQ', 'f')
        for _ in range(200):
            c.call(*at('S//A'), 'GET', 'f')
        before = (c.call(*at('U'), 'OBJECT', 'FREQ', 'f'), c.call(*at('S//A'), 'OBJECT', 'FREQ', 'f'))
        self.assertNotEqual(before[0], before[1])
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        c = self.up(run)
        self.assertEqual((c.call(*at('U'), 'OBJECT', 'FREQ', 'f'), c.call(*at('S//A'), 'OBJECT', 'FREQ', 'f')), before)


def lf_wait(predicate, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError('condition not reached')


class CopyAge(Base):
    def test_equal_rank_copies_keep_their_age(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*at('S//A'), 'SET', 'first-a', 'a')
        c.call(*at('S//B'), 'SET', 'first-a', 'b')
        c.call(*at('S//B'), 'SET', 'first-b', 'b')
        c.call(*at('S//A'), 'SET', 'first-b', 'a')
        c.call(*at('S//B'), 'SET', 'third', 'b')
        c.call(*at('S//A'), 'SET', 'third', 'a')
        c.call(*at('U'), 'SET', 'third', 'u')
        c.call(*at('U'), 'DEL', 'third')
        reader = at('S//A/B')
        want = [b'a', b'b', b'b']
        self.assertEqual([c.call(*reader, 'GET', k) for k in ('first-a', 'first-b', 'third')], want)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        c = self.up(run)
        self.assertEqual([c.call(*reader, 'GET', k) for k in ('first-a', 'first-b', 'third')], want)
        self.assertEqual(c.call(*TOP, 'DEBUG', 'RELOAD'), 'OK')
        self.assertEqual([c.call(*reader, 'GET', k) for k in ('first-a', 'first-b', 'third')], want)

    def test_a_copy_that_expired_during_downtime_leaves_the_order(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*at('S//A'), 'SET', 'n', 'a', 'PX', 1500)
        c.call(*at('S//B'), 'SET', 'n', 'b')
        c.call(*at('U'), 'SET', 'n', 'u')
        self.assertEqual(c.call(*at('S//A/B'), 'GET', 'n'), b'a')
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        time.sleep(1.7)
        c = self.up(run)
        self.assertEqual(c.call(*at('S//A/B'), 'GET', 'n'), b'b')
        self.assertEqual(c.call(*at('S//A'), 'GET', 'n'), b'u')
        self.assertEqual(lf.info(c, *TOP)['rdb_last_load_keys_expired'], '1')


class Twins(Base):
    arguments = SCHEME + SEEDS + ('--save', '', '--label-partitions-max', '3')
    NAMES = ['n%d' % i for i in range(12)] + ['hidden-%d' % i for i in range(4)]

    def world(self, hidden, expire_hidden=False, sensitive=False):
        directory = self.dir / ('world-%d-%d-%d' % (hidden, expire_hidden, sensitive))
        directory.mkdir()
        run = self.run_server(directory=directory)
        c = self.up(run)
        rng = random.Random(9)
        noise = random.Random(17)
        for i in range(12):
            label = rng.choice(('U', 'C', 'C;VETTED'))
            c.call(*at(label), 'SET', 'n%d' % i, 'v%d' % i)
            if i % 3 == 0:
                c.call(*at(label), 'RPUSH', 'list%d' % i, *range(i + 2))
        if sensitive:
            c.call(*at('C'), 'SET', 'n0', 'changed')
        if hidden:
            ttl = ('PX', 1200) if expire_hidden else ()
            for step in range(60):
                label = noise.choice(('S', 'S//A', 'S//B', 'C//A'))
                name = noise.choice(self.NAMES)
                c.send(*at(label), 'SET', name, 'secret%d' % step, 'NX', *ttl)
                c.reply()
                if step % 7 == 0:
                    c.send(*at(label), 'DEL', noise.choice(self.NAMES))
                    c.reply()
            if not expire_hidden:
                c.call(*TOP, 'LABEL', 'QUOTA', 'S', 'LIMIT', 9000000)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        if expire_hidden:
            time.sleep(1.5)
        c = self.up(run)
        low = at('C')
        corpus = []
        keys, cursors = full_scan(c, low)
        corpus += [keys, cursors, c.call(*low, 'DBSIZE'), sorted(c.call(*low, 'KEYS', '*'))]
        for name in self.NAMES + ['list%d' % i for i in range(12)]:
            corpus.append((name, c.call(*low, 'EXISTS', name), c.call(*low, 'TYPE', name), c.call(*low, 'PEXPIRETIME', name)))
            if c.call(*low, 'TYPE', name) == 'string':
                corpus.append(c.call(*low, 'GET', name))
        corpus.append([c.call(*low, 'RANDOMKEY') for _ in range(6)])
        corpus.append([l for l in c.call(*low, 'INFO', 'keyspace').decode().splitlines() if l.startswith('db')])
        corpus.append(c.call(*low, 'LASTSAVE') == c.call(*at('U'), 'LASTSAVE'))
        corpus.append(sorted(lf.info(c, *low).items()))
        if expire_hidden or not hidden:
            corpus.append([str(self.try_write(c, label)) for label in ('U;VETTED', 'U', 'C')])
        run.stop(signal.SIGKILL)
        return corpus

    def try_write(self, c, label):
        try:
            return c.call(*at(label), 'SET', 'probe', 1)
        except ServerError as error:
            return error

    def test_hidden_data_changes_nothing_after_a_restart(self):
        quiet = self.world(False)
        noisy = self.world(True)
        self.assertEqual(len(quiet), len(noisy) + 1)
        self.assertEqual(quiet[:-1], noisy)

    def test_hidden_data_that_expired_during_downtime_leaves_nothing(self):
        quiet = self.world(False)
        gone = self.world(True, expire_hidden=True)
        self.assertEqual(quiet, gone)

    def test_a_visible_difference_shows(self):
        self.assertNotEqual(self.world(False), self.world(False, sensitive=True))


class Mismatch(Base):
    MODES = {
        'plain': ('--save', ''),
        'labels': SCHEME + ('--save', ''),
        'owners': ('--owners', 'yes', '--save', ''),
        'both': SCHEME + ('--owners', 'yes', '--save', ''),
    }

    def make_file(self, mode):
        directory = self.dir / ('make-' + mode)
        directory.mkdir()
        run = self.run_server(self.MODES[mode], directory)
        c = run.start()
        self.assertIsNone(c[0], c[1])
        client = run.client()
        if mode == 'plain':
            client.call('SET', 'k', 'v')
            client.call('SAVE')
        else:
            rules = OPERATOR + (('owners:*', 'owner-shared', 'owner-operator') if 'owners' in mode or mode == 'both' else ())
            client.call('ACL', 'SETUSER', 'default', *rules)
            head = ('LABEL', 'AS', 'S//A/B' if mode in ('labels', 'both') else 'UNCLASSIFIED') + (('SHARED',) if mode in ('owners', 'both') else ())
            client.call(*head, 'SET', 'k', 'v')
            client.call(*head, 'SAVE')
        run.stop(signal.SIGKILL)
        return (directory / 'dump.rdb').read_bytes()

    def test_files_load_only_in_their_own_mode(self):
        files = {mode: self.make_file(mode) for mode in self.MODES}
        for file_mode, data in files.items():
            for server_mode in self.MODES:
                directory = self.dir / ('run-%s-%s' % (file_mode, server_mode))
                directory.mkdir()
                (directory / 'dump.rdb').write_bytes(data)
                run = self.run_server(self.MODES[server_mode], directory)
                if file_mode == server_mode:
                    code, text = run.start()
                    self.assertIsNone(code, text)
                    client = run.client()
                    head = ()
                    if server_mode != 'plain':
                        client.call('ACL', 'SETUSER', 'default', *(OPERATOR + (('owners:*', 'owner-shared', 'owner-operator') if server_mode in ('owners', 'both') else ())))
                        head = ('LABEL', 'AS', 'S//A/B' if server_mode in ('labels', 'both') else 'UNCLASSIFIED') + (('SHARED',) if server_mode in ('owners', 'both') else ())
                    self.assertEqual(client.call(*head, 'DBSIZE'), 1)
                    run.stop(signal.SIGKILL)
                    continue
                text = self.refused(run)
                self.assertIn(lf.REFUSED + 'dump.rdb in ', text)
                if file_mode == 'plain':
                    self.assertIn(STARTUP_REFUSED, text)
                elif server_mode == 'plain':
                    self.assertIn(LABELLED_REFUSED, text)
                else:
                    self.assertIn('and this server runs with', text, (file_mode, server_mode))

    def test_debug_reload_of_a_foreign_file_keeps_the_data(self):
        files = {mode: self.make_file(mode) for mode in ('plain', 'owners', 'both')}
        for server_mode, foreign in (('labels', ('plain', 'owners', 'both')), ('plain', ('owners', 'both'))):
            directory = self.dir / ('reload-' + server_mode)
            directory.mkdir()
            for name, data in files.items():
                (directory / (name + '.rdb')).write_bytes(data)
            run = self.run_server(self.MODES[server_mode], directory)
            code, text = run.start()
            self.assertIsNone(code, text)
            c = run.client()
            if server_mode == 'labels':
                c.call('ACL', 'SETUSER', 'default', *OPERATOR)
            c.call('SET', 'mine', 'kept')
            for name in foreign:
                c.call('CONFIG', 'SET', 'dbfilename', name + '.rdb')
                self.assertEqual(error_of(c, 'DEBUG', 'RELOAD', 'NOSAVE'), 'ERR Error trying to load the RDB dump, check server logs.')
                self.assertEqual(c.call('GET', 'mine'), b'kept')
            self.assertIn('Refusing to load the data file ', run.log())
            run.stop(signal.SIGKILL)

    def test_an_older_server_refuses_a_labelled_file(self):
        if OLDER is None:
            self.skipTest('no older server given')
        data = self.make_file('labels')
        directory = self.dir / 'older'
        directory.mkdir()
        (directory / 'dump.rdb').write_bytes(data)
        text = self.refused(self.run_server(('--save', ''), directory, OLDER))
        self.assertIn("unknown module type 'eski-labl'", text)
        text = self.refused(self.run_server(SCHEME + ('--save', ''), directory, OLDER))
        self.assertIn(lf.REFUSED, text)


class Scheme(Base):
    def saved(self, levels, compartments='A,B', trusts='WEB,VETTED'):
        run = self.run_server(('--label-levels', levels, '--label-compartments', compartments, '--label-trust-levels', trusts, '--save', ''))
        c = self.up(run)
        c.call(*at('C'), 'SET', 'k', 'c')
        c.call('SAVE')
        run.stop(signal.SIGKILL)
        return run

    def restart(self, levels, compartments='A,B', trusts='WEB,VETTED'):
        return self.run_server(('--label-levels', levels, '--label-compartments', compartments, '--label-trust-levels', trusts, '--save', ''))

    def test_renamed_or_reordered_positions_refuse(self):
        self.saved('U,C,S')
        text = self.refused(self.restart('U,C,S2'))
        self.assertIn('names level 3 S and the configured scheme names it S2; configure the file', text)
        text = self.refused(self.restart('U,S,C'))
        self.assertIn('names level 2 C and the configured scheme names it S', text)
        text = self.refused(self.restart('U,C,S', 'B,A'))
        self.assertIn('names compartment 1 A and the configured scheme names it B', text)
        text = self.refused(self.restart('U,C,S', 'A,B', 'WEB,OPEN'))
        self.assertIn('names trust level 2 VETTED', text)

    def test_a_configured_extension_loads(self):
        self.saved('U,C,S', 'A')
        run = self.restart('U,C,S,TS', 'A,B,X')
        c = self.up(run)
        self.assertEqual(c.call(*at('C'), 'GET', 'k'), b'c')
        self.assertEqual(c.call('CONFIG', 'GET', 'label-levels'), [b'label-levels', b'U,C,S,TS'])

    def test_a_file_that_extends_the_configuration_is_adopted(self):
        self.saved('U,C,S,TS', 'A,B,X')
        run = self.restart('U,C,S', 'A')
        c = self.up(run)
        self.assertEqual(c.call(*at('C'), 'GET', 'k'), b'c')
        self.assertEqual(c.call('CONFIG', 'GET', 'label-levels'), [b'label-levels', b'U,C,S,TS'])
        self.assertEqual(c.call('CONFIG', 'GET', 'label-compartments'), [b'label-compartments', b'A,B,X'])
        self.assertIn('The data file extends the configured label scheme', run.log())
        self.assertEqual(c.call(*at('TS//X'), 'SET', 'deep', 1), 'OK')


class Caps(Base):
    def test_partition_cap_is_enforced_at_load(self):
        run = self.run_server()
        c = self.up(run)
        for label in ('S//A', 'S//B', 'C'):
            c.call(*at(label), 'SET', 'k', label)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        tight = self.run_server(SCHEME + ('--save', '', '--label-partitions-max', '2'))
        self.assertIn('label-partitions-max', self.refused(tight))
        roomy = self.run_server(SCHEME + ('--save', '', '--label-partitions-max', '3'))
        c = self.up(roomy)
        self.assertEqual(c.call(*at('S//A'), 'GET', 'k'), b'S//A')

    def test_byte_quotas_are_not_enforced_at_load(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*at('C'), 'SET', 'big', 'x' * 100000)
        c.call(*TOP, 'LABEL', 'QUOTA', 'C', 'LIMIT', 1000)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        c = self.up(run)
        self.assertEqual(len(c.call(*at('C'), 'GET', 'big')), 100000)
        self.assertEqual(c.call(*TOP, 'LABEL', 'QUOTA', 'C')[0], 1000)
        self.assertIn('OOM', error_of(c, *at('C'), 'SET', 'more', 'y' * 1000))


def crafted(*parts, flags=lf.LABELLED, scheme=SCHEME_BLOB, quotas=(), owners=(), head=None):
    body = lf.aux_head()
    body += lf.header_record(flags, scheme, quotas, owners) if head is None else head
    for p in parts:
        body += p
    return lf.seal(body)


P = lf.partition_record
K = lf.string_key
SEL = lf.select


CASES = [
    ('version', crafted(head=lf.header_record(1, SCHEME_BLOB, version=2)), 'labelled header of format version 2'),
    ('flags zero', crafted(flags=0), 'unknown mode flags'),
    ('flags unknown', crafted(flags=5), 'unknown mode flags'),
    ('scheme', crafted(scheme=b'ESLX'), 'label scheme does not decode'),
    ('scheme trailing', crafted(scheme=SCHEME_BLOB + b'\x00'), 'label scheme does not decode'),
    ('quota label', crafted(quotas=[(9, 10)]), 'quota for label 9 beyond its label table'),
    ('quota zero', crafted(quotas=[(1, 0)]), 'invalid label quota'),
    ('quota twice', crafted(quotas=[(1, 10), (1, 20)]), 'two quotas for one label'),
    ('owners without owner mode', crafted(owners=[('u1', 0)]), 'lists owners without owner mode'),
    ('header twice', crafted(lf.header_record(1, SCHEME_BLOB)), 'second labelled header'),
    ('record first', lf.seal(lf.aux_head() + P(0) + lf.header_record(1, SCHEME_BLOB)), 'before its labelled header'),
    ('unknown kind', crafted(lf.record(lf.uint(9))), 'unknown kind 9'),
    ('placement', crafted(lf.record(lf.uint(2), lf.uint(0), lf.uint(0), when=1)), 'unknown placement'),
    ('field kind', crafted(SEL(0), lf.record(lf.uint(2), lf.text('x'), lf.uint(0))), 'malformed partition record'),
    ('extra field', crafted(SEL(0), lf.record(lf.uint(2), lf.uint(0), lf.uint(0), lf.uint(5)), K('k', 'v')), 'malformed partition record'),
    ('header short', lf.seal(lf.aux_head() + lf.record(lf.uint(1), lf.uint(1), lf.uint(1), lf.text(SCHEME_BLOB), lf.uint(0), lf.uint(0), lf.uint(0))), 'malformed labelled header'),
    ('partition outside db', crafted(P(0), SEL(0), K('k', 'v')), 'partition record outside any database'),
    ('partition label', crafted(SEL(0), P(7), K('k', 'v')), 'partition record for label 7 beyond its label table'),
    ('partition owner', crafted(SEL(0), P(0, 1), K('k', 'v')), 'names an owner without owner mode'),
    ('partition twice', crafted(SEL(0, 2), P(1), K('a', 'v'), P(1), K('b', 'v')), 'two partition records for label 1'),
    ('key outside', crafted(SEL(0), K('k', 'v')), "holds key 'k' outside any partition"),
    ('no order', crafted(SEL(0, 2), P(0), K('n', 'a'), P(1), K('n', 'b')), "holds key 'n' in two or more partitions of database 0 without their copy order"),
    ('no order expired', crafted(SEL(0, 2), P(0), K('n', 'a', 1000), P(1), K('n', 'b', 1000)), "holds key 'n' in two or more partitions"),
    ('order partition', crafted(SEL(0, 2), P(0), K('n', 'a'), P(1), K('n', 'b'), lf.order_record([(0, 'n', [0, 2])])), 'names a partition the file does not hold'),
    ('order absent', crafted(SEL(0, 2), P(0), K('n', 'a'), P(1), K('m', 'b'), lf.order_record([(0, 'n', [0, 1])])), "copy order for key 'n' that does not match"),
    ('order short', crafted(SEL(0, 3), P(0), K('n', 'a'), P(1), K('n', 'b'), P(2), K('n', 'c'), lf.order_record([(0, 'n', [0, 1])])), "copy order for key 'n' that does not match"),
    ('order one', crafted(SEL(0, 2), P(0), K('n', 'a'), P(1), K('m', 'b'), lf.order_record([(0, 'n', [0])])), 'does not list two or more copies'),
    ('order repeat', crafted(SEL(0, 2), P(0), K('n', 'a'), P(1), K('n', 'b'), lf.order_record([(0, 'n', [0, 0])])), 'lists one copy twice'),
    ('order name twice', crafted(SEL(0, 4), P(0), K('n', 'a'), K('m', 'a'), P(1), K('n', 'b'), K('m', 'b'), lf.order_record([(0, 'n', [0, 1]), (0, 'n', [1, 0])])), "lists key 'n' twice"),
    ('order twice', crafted(SEL(0, 2), P(0), K('n', 'a'), P(1), K('n', 'b'), lf.order_record([(0, 'n', [0, 1])]), lf.order_record([])), 'two copy orders'),
    ('partition after order', crafted(SEL(0, 2), P(0), K('n', 'a'), lf.order_record([]), P(1), K('m', 'b')), 'after the copy order'),
    ('key after order', crafted(SEL(0, 2), P(0), K('n', 'a'), lf.order_record([]), K('m', 'b')), "holds key 'm' outside any partition"),
    ('order outside db', crafted(lf.order_record([]), SEL(0), P(0), K('k', 'v')), 'copy order outside any database'),
    ('order owner', crafted(SEL(0, 2), P(0), K('n', 'a'), P(1), K('n', 'b'), lf.order_record([(1, 'n', [0, 1])])), 'names an owner without owner mode'),
    ('select twice', crafted(SEL(0), P(0), K('a', 'v'), SEL(0), P(1), K('b', 'v')), 'selects database 0 twice'),
    ('duplicate', crafted(SEL(0, 2), P(1), K('k', 'a'), K('k', 'b')), "duplicated key 'k' in database 0"),
    ('duplicate expired', crafted(SEL(0, 2), P(1), K('k', 'a', 1000), K('k', 'b')), "duplicated key 'k' in database 0"),
    ('duplicate expired twice', crafted(SEL(0, 2), P(1), K('k', 'a', 1000), K('k', 'b', 1000)), "duplicated key 'k' in database 0"),
    ('vector set version 1', crafted(SEL(0), P(0), b'\x07' + lf.string('vs') + lf.length(lf.module_id('eski-vset', 1)) + lf.length(5) + lf.string('x') + lf.length(0)), 'unknown encoding version'),
    ('vector set signature', crafted(SEL(0), P(0), b'\x07' + lf.string('vs') + lf.length(lf.module_id('eski-vset', 2)) + lf.length(5) + lf.string('xyz') + lf.length(0)), 'vector set'),
    ('vector set module', crafted(SEL(0), P(0), b'\x07' + lf.string('vs') + lf.length(lf.module_id('eski-zzzz', 2)) + lf.length(5) + lf.string('x') + lf.length(0)), "unknown module type 'eski-zzzz'"),
    ('vector set seed field', lf.seal(lf.aux_head() + b'\xfa' + lf.string('eski-vset-seed') + lf.string('77') + lf.header_record(1, SCHEME_BLOB)), 'vector set seed field outside its labelled header'),
    ('flags without labels', crafted(scheme=lf.eslt(['UNCLASSIFIED'])), 'mode flags do not match its label scheme'),
    ('quotas at the most', crafted(head=lf.header_record(1, WIDE_BLOB, [(i, 10) for i in range(1, 65535)] + [(1, 10)])), 'two quotas for one label'),
    ('order longer than its keys', crafted(SEL(0, 2), P(0), K('n', 'a'), P(1), K('n', 'b'), lf.order_record([(0, 'n', [0, 1]), (0, 'm', [0, 1])])), 'more entries than its database has copies'),
    ('library twice', crafted(b'\xf5' + lf.string("#!lua name=lib\nredis.register_function('f', function() return 1 end)"), b'\xf5' + lf.string("#!lua name=lib\nredis.register_function('f', function() return 1 end)")), 'one function library twice'),
]


class Validation(Base):
    arguments = SCHEME + ('--save', '')

    def test_every_crafted_failure_is_refused_with_its_reason(self):
        for name, data, words in CASES:
            directory = self.dir / name.replace(' ', '-')
            directory.mkdir()
            (directory / 'dump.rdb').write_bytes(data)
            text = self.refused(self.run_server(directory=directory))
            self.assertIn(words, text, name)

    def test_a_crafted_file_with_an_expired_copy_loads_pruned(self):
        data = crafted(SEL(0, 3), P(0), K('n', 'u'), K('only-expired', 'x', 1000), P(2), K('n', 'sa', 1000), P(3), K('n', 'sb'),
                       lf.order_record([(0, 'n', [2, 3, 0])]))
        (self.dir / 'dump.rdb').write_bytes(data)
        run = self.run_server(SCHEME + ('--save', '', '--label-partitions-max', '1'))
        c = self.up(run)
        self.assertEqual(c.call(*at('S//A/B'), 'GET', 'n'), b'sb')
        self.assertEqual(c.call(*at('S//A'), 'GET', 'n'), b'u')
        self.assertEqual(c.call(*at('U'), 'EXISTS', 'only-expired'), 0)
        self.assertEqual(lf.info(c, *TOP)['rdb_last_load_keys_expired'], '2')

    def test_a_crafted_file_with_its_order_loads_in_that_order(self):
        for order, want in (([2, 3], b'sa'), ([3, 2], b'sb')):
            data = crafted(SEL(0, 2), P(2), K('n', 'sa'), P(3), K('n', 'sb'), lf.order_record([(0, 'n', order)]))
            (self.dir / 'dump.rdb').write_bytes(data)
            run = self.run_server()
            c = self.up(run)
            self.assertEqual(c.call(*at('S//A/B'), 'GET', 'n'), want)
            run.stop(signal.SIGKILL)

    def test_a_plain_reload_of_a_plain_server_still_works(self):
        run = self.run_server(('--save', ''))
        code, text = run.start()
        self.assertIsNone(code, text)
        c = run.client()
        c.call('SET', 'k', 'v')
        self.assertEqual(c.call('DEBUG', 'RELOAD'), 'OK')
        self.assertEqual(c.call('GET', 'k'), b'v')
        data = (self.dir / 'dump.rdb').read_bytes()
        self.assertNotIn(lf.length(lf.ACCESS_ID), data)


class Corruption(Base):
    arguments = SCHEME + ('--save', '', '--rdbcompression', 'no')

    def sample(self):
        run = self.run_server(self.arguments)
        c = self.up(run)
        c.call(*at('S//A'), 'SET', 'n', 'a')
        c.call(*at('S//B'), 'SET', 'n', 'b')
        c.call(*at('U'), 'SET', 'n', 'u')
        c.call(*at('C'), 'RPUSH', 'l', 1, 2)
        c.call(*at('S//A'), 'VADD', 'v', 'VALUES', 2, 1, 0, 'x', 'SETATTR', '{"a":1}')
        c.call(*at('S//A'), 'VADD', 'v', 'VALUES', 2, 0, 1, 'y')
        c.call(*at('U'), 'VADD', 'v', 'VALUES', 2, 1, 1, 'x')
        c.call(*TOP, 'LABEL', 'QUOTA', 'C', 'LIMIT', 1000000)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        return (self.dir / 'dump.rdb').read_bytes()

    def outcome(self, data, index):
        directory = self.dir / ('case-%d' % index)
        directory.mkdir()
        (directory / 'dump.rdb').write_bytes(data)
        run = self.run_server(self.arguments, directory)
        code, text = run.start()
        if code is None:
            c = run.client()
            c.call('ACL', 'SETUSER', 'default', *OPERATOR)
            c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
            for reader in READERS:
                c.call(*at(reader), 'GET', 'n')
                lf.vector_reads(c, at(reader), 'v', 2, ['x', 'y'])
            lf.answers(c, [(*at('S//A'), 'VADD', 'v', 'VALUES', 2, 0.5, 0.5, 'z'), (*at('U'), 'VREM', 'v', 'x'), (*at('S//A/B'), 'VSIM', 'v', 'ELE', 'y'),
                           (*TOP, 'DEBUG', 'DIGEST-SCOPES')])
            self.assertEqual(run.stop(signal.SIGTERM), 0)
            return 'loaded'
        self.assertEqual(code, 1, 'case %d: %s' % (index, text[-2000:]))
        self.assertNotIn('AddressSanitizer', text)
        self.assertNotIn('ThreadSanitizer', text)
        return 'refused'

    def test_every_flipped_byte_is_refused_or_loads_cleanly(self):
        data = self.sample()
        rows = lf.records(data)
        start = next(r[1] for r in rows if r[0] == 'access')
        stop = len(data) - 8
        outcomes = {'loaded': 0, 'refused': 0}
        for i in range(start, stop):
            flipped = bytearray(data)
            flipped[i] ^= 0x5a
            outcomes[self.outcome(lf.reseal(bytes(flipped)), i)] += 1
        self.assertGreater(outcomes['refused'], (stop - start) // 2)

    def test_every_record_boundary_truncation_is_refused(self):
        data = self.sample()
        for i, row in enumerate(lf.records(data)):
            if row[0] == 'eof':
                break
            self.assertEqual(self.outcome(data[:row[2]], 10000 + i), 'refused')


class Access(Base):
    arguments = SCHEME + ('--save', '')

    def test_persistence_commands_need_top(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*at('C'), 'SET', 'k', 'v')
        low = at('C')
        for command in (('SAVE',), ('BGSAVE',), ('BGSAVE', 'SCHEDULE'), ('SHUTDOWN',), ('SHUTDOWN', 'NOSAVE'), ('SHUTDOWN', 'SAVE'),
                        ('SHUTDOWN', 'ABORT'), ('DEBUG', 'RELOAD'), ('CONFIG', 'SET', 'save', '60 1'), ('CONFIG', 'SET', 'dir', '/tmp'),
                        ('CONFIG', 'SET', 'dbfilename', 'x.rdb'), ('CONFIG', 'SET', 'rdbcompression', 'no'), ('CONFIG', 'SET', 'RDB-KEY-SAVE-DELAY', '0'),
                        ('CONFIG', 'SET', 'aof-use-rdb-preamble', 'yes'), ('CONFIG', 'SET', 'shutdown-on-sigterm', 'nosave'),
                        ('CONFIG', 'SET', 'maxmemory', '0', 'stop-writes-on-bgsave-error', 'no'), ('CONFIG', 'SET', 'appendonly', 'yes'),
                        ('CONFIG', 'SET', 'maxmemory', '0'), ('CONFIG', 'SET', 'no-appendfsync-on-rewrite', 'yes'),
                        ('CONFIG', 'SET', 'sanitize-dump-payload', 'no'), ('CONFIG', 'SET', 'loading-process-events-interval-bytes', '1024'),
                        ('CONFIG', 'REWRITE')):
            self.assertEqual(error_of(c, *low, *command), TOP_ERROR, command)
        for command in (('BGREWRITEAOF',), ('DEBUG', 'LOADAOF')):
            self.assertEqual(error_of(c, *low, *command), TOP_ERROR, command)
        for command in (('MIGRATE', '127.0.0.1', 1, 'k', 0, 10),):
            self.assertEqual(error_of(c, *low, *command), MIGRATE_ERROR, command)
            self.assertEqual(error_of(c, *TOP, *command), MIGRATE_ERROR, command)
        self.assertEqual(c.call(*TOP, 'CONFIG', 'SET', 'maxmemory', '0'), 'OK')
        self.assertEqual(c.call(*TOP, 'SAVE'), 'OK')
        self.assertEqual(c.call(*TOP, 'CONFIG', 'SET', 'save', '3600 1'), 'OK')
        self.assertEqual(c.call(*TOP, 'CONFIG', 'SET', 'shutdown-on-sigterm', 'save'), 'OK')
        self.assertIn('always a snapshot', error_of(c, *TOP, 'CONFIG', 'SET', 'aof-use-rdb-preamble', 'no'))
        self.assertEqual(c.call(*TOP, 'BGSAVE'), 'Background saving started')
        lf_wait(lambda: lf.info(c, *TOP)['rdb_bgsave_in_progress'] == '0')
        self.assertEqual(c.call(*TOP, 'DEBUG', 'RELOAD'), 'OK')
        self.assertEqual(c.call(*low, 'GET', 'k'), b'v')
        self.assertEqual(error_of(c, *TOP, 'DEBUG', 'RELOAD', 'MERGE'), 'ERR DEBUG RELOAD MERGE and NOFLUSH are not available with a label scheme or owner mode')
        self.assertEqual(error_of(c, *TOP, 'DEBUG', 'RELOAD', 'NOFLUSH', 'NOSAVE'), 'ERR DEBUG RELOAD MERGE and NOFLUSH are not available with a label scheme or owner mode')

    def test_lastsave_and_info_below_top(self):
        run = self.run_server()
        c = self.up(run)
        started = c.call(*at('C'), 'LASTSAVE')
        time.sleep(1.1)
        c.call(*at('S//A'), 'SET', 'hidden', 1)
        c.call(*TOP, 'SAVE')
        self.assertEqual(c.call(*at('C'), 'LASTSAVE'), started)
        self.assertGreater(c.call(*TOP, 'LASTSAVE'), started)
        low = lf.info(c, *at('C'))
        self.assertEqual(low['rdb_last_save_time'], '0')
        self.assertEqual(low['rdb_saves'], '0')
        self.assertEqual(low['rdb_changes_since_last_save'], '0')
        self.assertNotIn('owners_forget_sequence', low)
        self.assertNotEqual(lf.info(c, *TOP)['rdb_last_save_time'], '0')

    def test_dump_serialises_the_resolved_copy_as_a_plain_payload(self):
        (self.dir / 'plain').mkdir()
        plain = self.run_server(('--save', ''), self.dir / 'plain')
        code, _ = plain.start()
        self.assertIsNone(code)
        p = plain.client()
        run = self.run_server()
        c = self.up(run)
        for label, value in (('S//A', 'high'), ('U', 'low')):
            c.call(*at(label), 'RPUSH', 'l', value, value + '2')
        p.call('RPUSH', 'l', 'high', 'high2')
        p.call('RPUSH', 'm', 'low', 'low2')
        self.assertEqual(c.call(*at('S//A'), 'DUMP', 'l'), p.call('DUMP', 'l'))
        self.assertEqual(c.call(*at('C'), 'DUMP', 'l'), p.call('DUMP', 'm'))
        self.assertIsNone(c.call(*at('C'), 'DUMP', 'nothing'))
        payload = c.call(*at('U'), 'DUMP', 'l')
        self.assertEqual(c.call(*at('C'), 'RESTORE', 'copied', 0, payload), 'OK')
        self.assertEqual(c.call(*at('C'), 'LRANGE', 'copied', 0, -1), [b'low', b'low2'])
        self.assertEqual(c.call(*at('U'), 'EXISTS', 'copied'), 0)
        self.assertEqual(error_of(c, *at('C'), 'RESTORE', 'copied', 0, payload), 'BUSYKEY Target key name already exists.')
        self.assertEqual(c.call(*at('C'), 'RESTORE', 'copied', 0, p.call('DUMP', 'l'), 'REPLACE'), 'OK')
        self.assertEqual(c.call(*at('C'), 'LRANGE', 'copied', 0, -1), [b'high', b'high2'])
        self.assertTrue(error_of(c, *at('C'), 'RESTORE', 'l', 0, payload).startswith('INUSE name in use at U'))
        self.assertTrue(error_of(c, *at('C'), 'RESTORE', 'l', 0, payload, 'REPLACE').startswith('INUSE name in use at U'))
        self.assertEqual(c.call(*at('U;VETTED'), 'RESTORE', 'l', 0, payload), 'OK')
        self.assertEqual(c.call(*at('U;VETTED'), 'LRANGE', 'l', 0, -1), [b'low', b'low2'])
        self.assertEqual(c.call(*at('S//A'), 'LRANGE', 'l', 0, -1), [b'high', b'high2'])
        c.call(*at('C'), 'VADD', 'vs', 'VALUES', 2, 1, 0, 'e')
        p.call('VADD', 'pvs', 'VALUES', 2, 1, 0, 'e')
        self.assertTrue(c.call(*at('C'), 'DUMP', 'vs').startswith(b'\x07'))
        self.assertEqual(c.call(*at('C'), 'RESTORE', 'vs2', 0, p.call('DUMP', 'pvs')), 'OK')
        self.assertEqual(c.call(*at('C'), 'VEMB', 'vs2', 'e'), c.call(*at('C'), 'VEMB', 'vs', 'e'))
        bogus = b'\x07\x01\x0c\x00'
        bogus += lf.rdbcmp.crc64(bogus).to_bytes(8, 'little')
        self.assertEqual(error_of(c, *at('C'), 'RESTORE', 'bogus', 0, bogus), 'ERR Bad data format')
        self.assertEqual(error_of(p, 'RESTORE', 'bogus', 0, bogus), 'ERR Bad data format')
        self.assertEqual(c.call(*TOP, 'SAVE'), 'OK')
        self.assertNotIn('Refusing to save', run.log())

    def test_scripts_may_dump(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*at('C'), 'SET', 'k', 'v')
        self.assertTrue(c.call(*at('C'), 'EVAL', "return redis.call('DUMP', 'k')", 0).startswith(b'\x00'))


class Runtime(Base):
    arguments = ('--save', '3600 1')

    def test_turning_a_scheme_on_writes_an_empty_labelled_snapshot(self):
        run = self.run_server()
        code, text = run.start()
        self.assertIsNone(code, text)
        c = run.client()
        c.call('SET', 'k', 'v')
        c.call('SAVE')
        self.assertIn('needs a server without keys', error_of(c, 'CONFIG', 'SET', 'label-levels', 'U,S'))
        c.call('FLUSHALL')
        self.assertEqual(c.call('CONFIG', 'SET', 'label-levels', 'U,S'), 'OK')
        data = (self.dir / 'dump.rdb').read_bytes()
        fields = lf.header_fields(data)
        self.assertEqual(fields[2][0], lf.LABELLED)
        c.call('ACL', 'SETUSER', 'default', 'clearance:*')
        c.call('LABEL', 'AS', 'S', 'SET', 'k', 'labelled')
        run.stop(signal.SIGTERM)
        again = self.run_server(('--save', '3600 1', '--label-levels', 'U,S'))
        code, text = again.start()
        self.assertIsNone(code, text)
        c = again.client()
        c.call('ACL', 'SETUSER', 'default', 'clearance:*')
        self.assertEqual(c.call('LABEL', 'AS', 'S', 'GET', 'k'), b'labelled')

    def test_a_command_form_base_stays_refused(self):
        run = self.run_server(('--save', '3600 1', '--appendonly', 'yes'))
        code, text = run.start()
        self.assertIsNone(code, text)
        c = run.client()
        self.assertEqual(c.call('CONFIG', 'SET', 'label-levels', 'U,S'), 'OK')
        run.stop()
        refused = self.run_server(SCHEME + ('--appendonly', 'yes'))
        code, text = refused.start(('--appendonly', 'yes', '--aof-use-rdb-preamble', 'no'))
        self.assertEqual(code, 1)
        self.assertIn('the append-only base of a server with a label scheme or owner mode is always a snapshot', text)

    def test_stale_temporary_files_are_removed_at_startup(self):
        dead = 4000000
        while Path('/proc/%d' % dead).exists():
            dead += 1
        names = ['temp-%d.rdb' % dead, 'temp-rewriteaof-bg-%d.aof' % dead, 'temp-rewriteaof-%d.aof' % dead]
        live = 'temp-%d.rdb' % os.getpid()
        for n in names + [live, 'temp-x.rdb']:
            (self.dir / n).write_bytes(b'stale')
        plain = self.run_server(('--save', ''))
        code, _ = plain.start()
        self.assertIsNone(code)
        plain.stop()
        for n in names:
            self.assertTrue((self.dir / n).exists())
        labelled = self.run_server(SCHEME + ('--save', ''))
        code, text = labelled.start()
        self.assertIsNone(code, text)
        labelled.stop()
        for n in names:
            self.assertFalse((self.dir / n).exists(), n)
        self.assertTrue((self.dir / live).exists())
        self.assertTrue((self.dir / 'temp-x.rdb').exists())


class Golden(Base):
    arguments = SCHEME + SEEDS + ('--save', '', '--rdbcompression', 'no')
    FIXTURE = FIXTURES / 'labelled-snapshot.hex'

    def build(self, c):
        c.call(*at('S//B'), 'SET', 'name', 'right')
        c.call(*at('S//A'), 'SET', 'name', 'left')
        c.call(*at('U'), 'SET', 'name', 'low')
        c.call(*at('C'), 'RPUSH', 'list', 'a', 'b')
        c.call(*at('C;VETTED'), 'SET', 'timed', 'x', 'PXAT', FAR)
        c.call(*TOP, 'LABEL', 'QUOTA', 'C', 'LIMIT', 4096)

    def test_the_labelled_snapshot_has_its_fixed_bytes(self):
        run = self.run_server()
        c = self.up(run)
        self.build(c)
        c.call(*TOP, 'SAVE')
        got = lf.access_bytes(lf.without_seed((self.dir / 'dump.rdb').read_bytes()))
        if WRITE_FIXTURES:
            FIXTURES.mkdir(exist_ok=True)
            self.FIXTURE.write_text(got.hex() + '\n')
        self.assertEqual(got.hex(), self.FIXTURE.read_text().strip())

    def test_the_fixed_bytes_load(self):
        data = lf.seal(lf.aux_head() + bytes.fromhex(self.FIXTURE.read_text().strip()))
        (self.dir / 'dump.rdb').write_bytes(data)
        run = self.run_server()
        c = self.up(run)
        self.assertEqual(c.call(*at('S//A/B'), 'GET', 'name'), b'right')
        self.assertEqual(c.call(*at('C'), 'GET', 'name'), b'low')
        self.assertEqual(c.call(*at('C'), 'LRANGE', 'list', 0, -1), [b'a', b'b'])
        self.assertEqual(c.call(*at('C;VETTED'), 'PEXPIRETIME', 'timed'), FAR)
        self.assertEqual(c.call(*at('U'), 'EXISTS', 'timed'), 0)
        self.assertEqual(c.call(*TOP, 'LABEL', 'QUOTA', 'C')[0], 4096)


class MidLoad(Base):
    arguments = SCHEME + SEEDS + ('--save', '', '--rdbcompression', 'no')
    LABELS = ('U', 'C', 'S//A', 'C;VETTED', 'S//B')

    def saved(self, arguments=None):
        run = self.run_server(arguments)
        c = self.up(run)
        for i in range(1200):
            c.call(*at(self.LABELS[i % len(self.LABELS)]), 'SET', 'k%d' % i, 'v' * 1000)
        c.call(*at('S//A'), 'SET', 'shared-name', 'a')
        c.call(*at('S//B'), 'SET', 'shared-name', 'b')
        c.call(*TOP, 'LABEL', 'QUOTA', 'C', 'LIMIT', 900000)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        return run

    def facts(self, c):
        out = {'scopes': c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), 'digest': c.call(*TOP, 'DEBUG', 'DIGEST'),
               'quota': c.call(*TOP, 'LABEL', 'QUOTA', 'C'), 'loaded': lf.info(c, *TOP)['rdb_last_load_keys_loaded']}
        for reader in ('U', 'C', 'S//A/B'):
            out[reader] = (c.call(*at(reader), 'DBSIZE'), c.call(*at(reader), 'GET', 'shared-name'),
                           [l for l in c.call(*at(reader), 'INFO', 'keyspace').decode().splitlines() if l.startswith('db')])
        return out

    def test_commands_served_during_the_load_change_nothing(self):
        run = self.saved()
        clean = self.facts(self.up(run))
        run.stop(signal.SIGKILL)
        c = run.launch(SLOW)
        c.call('ACL', 'SETUSER', 'default', *OPERATOR)
        self.assertTrue(lf.loading(c, *TOP))
        other = run.client()
        self.assertEqual(other.call('ECHO', 'during the load'), b'during the load')
        self.assertTrue(other.call('HELLO', 2))
        self.assertEqual(other.call('AUTH', 'default', 'any'), 'OK')
        self.assertIn(b'loading:', other.call(*at('C'), 'INFO', 'persistence'))
        self.assertTrue(error_of(c, *TOP, 'DEBUG', 'DIGEST-SCOPES').startswith('LOADING'))
        self.assertTrue(error_of(c, *TOP, 'DEBUG', 'RELOAD').startswith('LOADING'))
        self.assertTrue(error_of(c, *TOP, 'CONFIG', 'SET', 'label-levels', 'U,C,TS').startswith('LOADING'))
        self.assertTrue(lf.loading(c, *TOP))
        lf.wait_loaded(c, *TOP)
        self.assertEqual(self.facts(c), clean)
        self.assertEqual(c.call('CONFIG', 'GET', 'label-levels'), [b'label-levels', b'U,C,S'])

    def test_eviction_waits_for_the_end_of_the_load(self):
        run = self.saved()
        c = run.launch(SLOW + ('--maxmemory', '1', '--maxmemory-policy', 'allkeys-random'))
        c.call('ACL', 'SETUSER', 'default', *OPERATOR)
        samples = 0
        while True:
            fields = lf.info(c, *TOP, section='everything')
            if fields['loading'] != '1':
                break
            samples += 1
            self.assertEqual(fields['evicted_keys'], '0')
            c.call('ECHO', 'x')
        self.assertGreater(samples, 0)
        self.assertEqual(fields['rdb_last_load_keys_loaded'], '1202')
        self.assertNotIn('Sanitizer', run.log())


class HiddenCopies(Base):
    arguments = SCHEME + SEEDS + ('--save', '')
    LOW = 'C//A'
    VISIBLE = ('U', 'C', 'C//A')
    HIDDEN = ('C//B', 'S//B', 'S', 'S//A/B')
    NAMES = ['n%d' % i for i in range(10)]

    def script(self):
        rng = random.Random(23)
        ops = []
        for step in range(220):
            label = rng.choice(self.VISIBLE + self.HIDDEN)
            name = rng.choice(self.NAMES)
            r = rng.random()
            if r < 0.6:
                ops.append((label, ('SET', name, 'v|%s|%d' % (label, step))))
            elif r < 0.7:
                ops.append((label, ('DEL', name)))
            elif r < 0.85:
                ops.append((label, ('RPUSH', 'l' + name, step)))
            else:
                ops.append((label, ('HSET', 'h' + name, 'f%d' % (step % 4), step)))
        return ops

    def ages(self, c):
        before = after = 0
        for name in self.NAMES:
            seen = c.call(*at(self.LOW), 'GET', name)
            if seen is None:
                continue
            step = int(seen.split(b'|')[2])
            for label in self.HIDDEN:
                own = c.call(*at(label), 'GET', name)
                if own is not None and own.split(b'|')[1] == label.encode():
                    if int(own.split(b'|')[2]) < step:
                        before += 1
                    else:
                        after += 1
        return before, after

    def corpus(self, c):
        low = at(self.LOW)
        keys, cursors = full_scan(c, low)
        out = [keys, cursors, c.call(*low, 'DBSIZE'), sorted(c.call(*low, 'KEYS', '*'))]
        for pre in ('', 'l', 'h'):
            for name in self.NAMES:
                k = pre + name
                kind = c.call(*low, 'TYPE', k)
                out.append((k, kind, c.call(*low, 'EXISTS', k), c.call(*low, 'PEXPIRETIME', k), c.call(*low, 'LABEL', 'OF', k),
                            c.call(*low, 'DUMP', k), read_value(c, low, k, kind) if kind != 'none' else None))
        out.append([c.call(*low, 'RANDOMKEY') for _ in range(6)])
        out.append([l for l in c.call(*low, 'INFO', 'keyspace').decode().splitlines() if l.startswith('db')])
        out.append(sorted(lf.info(c, *low).items()))
        return out

    def world(self, hidden, expire=False):
        directory = self.dir / ('copies-%d-%d' % (hidden, expire))
        directory.mkdir()
        run = self.run_server(directory=directory)
        c = self.up(run)
        for label, op in self.script():
            if label in self.HIDDEN:
                if not hidden or (expire and op[0] != 'SET'):
                    continue
                if expire:
                    op = op + ('PX', 1200)
            try:
                c.call(*at(label), *op)
            except ServerError:
                pass
        ages = self.ages(c)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        if expire:
            time.sleep(1.5)
        c = self.up(run)
        out = self.corpus(c)
        run.stop(signal.SIGKILL)
        return ages, out

    def test_hidden_copies_of_visible_names_change_nothing_after_a_restart(self):
        _, quiet = self.world(False)
        (before, after), noisy = self.world(True)
        self.assertGreater(before, 0)
        self.assertGreater(after, 0)
        self.assertEqual(quiet, noisy)

    def test_hidden_copies_that_expired_during_downtime_leave_nothing(self):
        _, quiet = self.world(False)
        _, gone = self.world(True, expire=True)
        self.assertEqual(quiet, gone)


class Fixes(Base):
    arguments = SCHEME + ('--save', '')

    def test_a_low_reader_cannot_tell_a_failed_save(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*at('C'), 'SET', 'k', 'v')
        self.assertEqual(c.call(*TOP, 'BGSAVE'), 'Background saving started')
        lf_wait(lambda: lf.info(c, *TOP)['rdb_bgsave_in_progress'] == '0')
        good = (lf.info(c, *at('C')), lf.info(c, *at('C'), section='stats'))
        os.chmod(self.dir, 0o500)
        try:
            self.assertEqual(c.call(*TOP, 'BGSAVE'), 'Background saving started')
            lf_wait(lambda: lf.info(c, *TOP)['rdb_bgsave_in_progress'] == '0')
            self.assertEqual(lf.info(c, *TOP)['rdb_last_bgsave_status'], 'err')
            failed = (lf.info(c, *at('C')), lf.info(c, *at('C'), section='stats'))
        finally:
            os.chmod(self.dir, 0o700)
        self.assertEqual(good[0], failed[0])
        self.assertEqual(good[0]['rdb_last_bgsave_status'], 'ok')
        self.assertEqual(good[1], failed[1])

    def test_a_labelled_snapshot_is_private_to_the_server_user(self):
        mask = os.umask(0)
        os.umask(mask)
        plain = self.dir / 'plain'
        plain.mkdir()
        run = self.run_server(('--save', ''), plain)
        code, text = run.start()
        self.assertIsNone(code, text)
        c = run.client()
        c.call('SET', 'k', 'v')
        c.call('SAVE')
        self.assertEqual((plain / 'dump.rdb').stat().st_mode & 0o777, 0o644 & ~mask)
        run.stop(signal.SIGKILL)
        run = self.run_server()
        c = self.up(run)
        c.call(*at('C'), 'SET', 'k', 'v')
        stale = self.dir / ('temp-%d.rdb' % run.process.pid)
        stale.write_bytes(b'old')
        os.chmod(stale, 0o644)
        c.call(*TOP, 'SAVE')
        self.assertEqual((self.dir / 'dump.rdb').stat().st_mode & 0o777, 0o600)
        (self.dir / 'dump.rdb').unlink()
        c.call(*TOP, 'BGSAVE')
        lf_wait(lambda: lf.info(c, *TOP)['rdb_bgsave_in_progress'] == '0')
        self.assertEqual((self.dir / 'dump.rdb').stat().st_mode & 0o777, 0o600)

    def test_the_startup_cleanup_keeps_the_configured_files(self):
        dead = 4000000
        while Path('/proc/%d' % dead).exists():
            dead += 1
        names = ('temp-%d.rdb' % dead, 'temp-rewriteaof-%d.aof' % dead, 'temp-rewriteaof-bg-%d.aof' % dead)
        arguments = SCHEME + ('--save', '', '--dbfilename', names[0], '--appendfilename', names[1], '--appenddirname', names[2])
        run = self.run_server(arguments)
        c = self.up(run)
        c.call(*at('C'), 'SET', 'k', 'kept')
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        for n in names[1:]:
            (self.dir / n).write_bytes(b'operator file')
        c = self.up(run)
        self.assertEqual(c.call(*at('C'), 'GET', 'k'), b'kept')
        for n in names:
            self.assertTrue((self.dir / n).exists(), n)
        self.assertNotIn('Removed the stale temporary file', run.log())

    def test_restore_checks_every_payload_in_depth(self):
        (self.dir / 'plain').mkdir()
        plain = self.run_server(('--save', ''), self.dir / 'plain')
        code, _ = plain.start()
        self.assertIsNone(code)
        p = plain.client()
        self.assertEqual(p.call('CONFIG', 'GET', 'sanitize-dump-payload'), [b'sanitize-dump-payload', b'no'])
        self.assertEqual(p.call('RESTORE', 'shallow', 0, DEEP_PAYLOAD), 'OK')
        plain.kill()
        c = self.up(self.run_server())
        self.assertEqual(c.call('CONFIG', 'GET', 'sanitize-dump-payload'), [b'sanitize-dump-payload', b'no'])
        self.assertEqual(error_of(c, *at('C'), 'RESTORE', 'deep', 0, DEEP_PAYLOAD), 'ERR Bad data format')
        self.assertEqual(c.call(*at('C'), 'EXISTS', 'deep'), 0)
        good = c.call(*at('C'), 'DUMP', 'nothing')
        self.assertIsNone(good)
        c.call(*at('C'), 'HSET', 'h', 'f', 'v')
        self.assertEqual(c.call(*at('C'), 'RESTORE', 'h2', 0, c.call(*at('C'), 'DUMP', 'h')), 'OK')


class SchemeChanges(Base):
    arguments = SCHEME + ('--save', '3600 100000')

    def test_a_runtime_rename_saves_a_snapshot_with_the_new_names(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*at('S'), 'SET', 'k', 'secret')
        c.call(*TOP, 'SAVE')
        self.assertEqual(c.call(*TOP, 'CONFIG', 'SET', 'label-levels', 'U,C,TS'), 'OK')
        run.stop(signal.SIGKILL)
        again = self.run_server(('--label-levels', 'U,C,TS', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED', '--save', ''))
        c = self.up(again)
        self.assertEqual(c.call(*at('TS'), 'GET', 'k'), b'secret')

    def test_a_runtime_extension_saves_a_snapshot(self):
        run = self.run_server(SCHEME + ('--save', ''))
        c = self.up(run)
        c.call(*at('C'), 'SET', 'k', 'v')
        c.call(*TOP, 'SAVE')
        self.assertEqual(c.call(*TOP, 'CONFIG', 'SET', 'label-compartments', 'A,B,X'), 'OK')
        run.stop(signal.SIGKILL)
        c = self.up(self.run_server(SCHEME + ('--save', '')))
        self.assertEqual(c.call('CONFIG', 'GET', 'label-compartments'), [b'label-compartments', b'A,B,X'])
        self.assertEqual(c.call(*at('C'), 'GET', 'k'), b'v')

    def test_a_failed_save_refuses_the_rename(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*at('C'), 'SET', 'k', 'v')
        os.chmod(self.dir, 0o500)
        try:
            text = error_of(c, *TOP, 'CONFIG', 'SET', 'label-levels', 'U,C,TS')
        finally:
            os.chmod(self.dir, 0o700)
        self.assertIn('the snapshot with the changed label scheme could not be written', text)
        self.assertEqual(c.call('CONFIG', 'GET', 'label-levels'), [b'label-levels', b'U,C,S'])
        self.assertEqual(c.call(*at('C'), 'GET', 'k'), b'v')

    def test_adopting_a_longer_scheme_writes_an_audit_record(self):
        run = self.run_server(('--label-levels', 'U,C,S,TS', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED', '--save', ''))
        c = self.up(run)
        c.call(*at('C'), 'SET', 'k', 'v')
        c.call(*at('TS//A/B'), 'SAVE')
        run.stop(signal.SIGKILL)
        audit = self.dir / 'audit.jsonl'
        c = self.up(self.run_server(SCHEME + ('--save', '', '--label-audit-file', str(audit))))
        self.assertEqual(c.call(*at('C'), 'GET', 'k'), b'v')
        text = audit.read_text()
        self.assertIn('"event":"scheme-adopt"', text)
        self.assertIn('"before":"U,C,S","after":"U,C,S,TS"', text)


class RefusedLoads(Base):
    arguments = SCHEME + ('--save', '')

    def test_a_refusal_after_keys_were_read_stops_the_server(self):
        run = self.run_server(('--save', ''))
        code, text = run.start()
        self.assertIsNone(code, text)
        c = run.client()
        c.call('SET', 'mine', 'kept')
        late = lf.seal(lf.aux_head() + SEL(0, 2) + K('from-file-1', 'x') + K('from-file-2', 'y') + lf.header_record(lf.LABELLED, SCHEME_BLOB) + K('never', 'z'))
        (self.dir / 'late.rdb').write_bytes(late)
        c.call('CONFIG', 'SET', 'dbfilename', 'late.rdb')
        c.send('DEBUG', 'RELOAD', 'NOSAVE')
        try:
            c.reply()
            self.fail('the server answered after a refusal past its first keys')
        except (OSError, EOFError):
            pass
        self.assertEqual(run.process.wait(timeout=20), 1)
        run.process = None
        self.assertIn('Part of the data file was already loaded when it was refused, so the server stops', run.log())

    def test_a_scheme_the_server_cannot_adopt_is_refused_before_the_flush(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*at('C'), 'SET', 'mine', 'kept')
        blob = lf.eslt(['U', 'C', 'S', 'TOKEN'], ['A', 'B'], ['WEB', 'VETTED'], [(1, 0, ())])
        (self.dir / 'wide.rdb').write_bytes(lf.seal(lf.aux_head() + lf.header_record(lf.LABELLED, blob) + SEL(0) + P(1) + K('from-file', 'x')))
        c.call(*TOP, 'CONFIG', 'SET', 'dbfilename', 'wide.rdb')
        self.assertEqual(error_of(c, *TOP, 'DEBUG', 'RELOAD', 'NOSAVE'), 'ERR Error trying to load the RDB dump, check server logs.')
        self.assertEqual(c.call(*at('C'), 'GET', 'mine'), b'kept')
        self.assertIn('cannot adopt', run.log())


VFAR = FAR - 3000
VPLAN = (('U', 100, 0), ('C', 520, 0), ('S//A', 300, 0), ('S//B', 520, 220), ('C;VETTED', 520, 400), ('S', 140, 0))
VCHARGED = ('U', 'C', 'S//A', 'S//B', 'C;VETTED', 'S', 'U;VETTED')
VOWN = {'U': 60, 'C': 500, 'S//A': 260, 'S//B': 480, 'C;VETTED': 500, 'S': 140}
VKEYS = (('vs', 4, None), ('two', 4, None), ('vbin', 16, None), ('vproj', 3, 6), ('tv', 4, None), ('gone', 4, None))
VDOOMED = (('tv', 'S//A'), ('gone', 'C;VETTED'))


vadd = lf.vadd
interleave = lf.interleave


def vector_script(seed):
    rng = random.Random(seed)
    chains = []
    for k, (label, n, _) in enumerate(VPLAN):
        own = []
        for i in range(VOWN[label]):
            attr = ('SETATTR', '{"a":%d}' % (i % 7)) if i % 3 == 0 else ()
            own.append((label, vadd('vs', rng, 4, 'p%d-%d' % (k, i), *attr)))
        chains.append(own)
    for i in range(20):
        pair = [('S//A', vadd('vs', rng, 4, 'e%d' % i, 'SETATTR', '{"a":%d}' % i)), ('S//B', vadd('vs', rng, 4, 'e%d' % i))]
        rng.shuffle(pair)
        chains.append(pair)
    for i in range(20, 40):
        later = [('C;VETTED', vadd('vs', rng, 4, 'e%d' % i)), ('U', vadd('vs', rng, 4, 'e%d' % i))]
        rng.shuffle(later)
        chains.append([('C', vadd('vs', rng, 4, 'e%d' % i, 'SETATTR', '{"a":%d}' % (i % 5)))] + later)
    for i in range(40, 60):
        chains.append([('S//A', vadd('vs', rng, 4, 'e%d' % i))])
    for i in range(40, 60):
        chains.append([('S//B', vadd('vs', rng, 4, 'e%d' % i))])
    for i in range(60, 80):
        chains.append([('U', vadd('vs', rng, 4, 'e%d' % i))])
    ops = [('U;VETTED', vadd(key, rng, dim, 'anchor%d' % i, *(('BIN',) if key == 'vbin' else ()), width=width))
           for key, dim, width in VKEYS if key not in ('two', 'gone') for i in range(2)]
    ops += interleave(rng, chains)
    for k, (label, n, gone) in enumerate(VPLAN):
        names = ['p%d-%d' % (k, i) for i in range(VOWN[label])]
        rng.shuffle(names)
        ops += [(label, ('VREM', 'vs', x)) for x in names[:gone]]
    twins = [op for op in ops if op[0] == 'C' and op[1][0] == 'VADD' and op[1][8].startswith('p1-')]
    for j, (label, cmd) in enumerate(twins[:14]):
        ops.append(('C', ('VADD', 'vs', 'VALUES', 4, *cmd[4:8], 'twin%d' % j)))
    for i in range(40):
        ops.append(('S//A', vadd('two', rng, 4, 'w%d' % i)))
    for i in range(30):
        ops.append(('C', vadd('two', rng, 4, 'w%d' % i, 'SETATTR', '{"a":%d}' % i)))
    for i in range(20):
        ops.append(('S//B', vadd('two', rng, 4, 'w%d' % (i + 50))))
    bits = random.Random(seed + 1)
    for i in range(600):
        ops.append(('C', ('VADD', 'vbin', 'VALUES', 16, *[bits.choice(('1', '-1')) for _ in range(16)], 'b%d' % i, 'BIN')))
    for i in range(60):
        ops.append(('U', ('VADD', 'vbin', 'VALUES', 16, *[bits.choice(('1', '-1')) for _ in range(16)], 'c%d' % i, 'BIN')))
    for i in range(530):
        ops.append(('S//A', vadd('vproj', rng, 3, 'r%d' % i, width=6)))
    for i in range(50):
        ops.append(('U', vadd('vproj', rng, 3, 'q%d' % i, width=6)))
    for i in range(30, 90):
        ops.append(('S//A', vadd('tv', rng, 4, 't%d' % i)))
    for i in range(50):
        ops.append(('U', vadd('tv', rng, 4, 't%d' % i)))
    for i in range(30):
        ops.append(('C;VETTED', vadd('gone', rng, 4, 'g%d' % i)))
    ops.append(('U', ('PEXPIREAT', 'vs', VFAR)))
    return ops


def vector_more(seed):
    rng = random.Random(seed)
    ops = []
    for i in range(30):
        ops.append(('U', vadd('vs', rng, 4, 'late-u%d' % i)))
    for i in range(460):
        ops.append(('C;VETTED', vadd('vs', rng, 4, 'late-cv%d' % i)))
    for i in range(240):
        ops.append(('S//A', vadd('vs', rng, 4, 'late-sa%d' % i)))
    for i in range(0, 280, 2):
        ops.append(('S//B', ('VREM', 'vs', 'p3-%d' % i)))
    for i in range(0, 480, 5):
        ops.append(('C', vadd('vs', rng, 4, 'p1-%d' % i)))
        ops.append(('C', ('VSETATTR', 'vs', 'p1-%d' % (i + 1), '{"a":9}')))
    for j in range(0, 14, 3):
        ops.append(('C', ('VREM', 'vs', 'twin%d' % j)))
    for i in range(25):
        ops.append(('C//A', vadd('vs', rng, 4, 'late-ca%d' % i)))
        ops.append(('S//A', vadd('two', rng, 4, 'late-w%d' % i)))
        ops.append(('C', vadd('tv', rng, 4, 'late-t%d' % i)))
    for i in range(0, 600, 7):
        ops.append(('C', ('VREM', 'vbin', 'b%d' % i)))
    ops.append(('S//A', ('VREM', 'vs', 'e3')))
    return ops


def apply_ops(c, ops):
    commands = [(*at(label), *cmd) for label, cmd in ops]
    return lf.answers(c, commands)


def vector_names(key):
    if key == 'vs':
        return ['e%d' % i for i in range(0, 80, 3)] + ['p%d-%d' % (k, i) for k in range(6) for i in range(0, 520, 41)] + \
            ['twin%d' % i for i in range(0, 14, 2)] + ['late-cv%d' % i for i in range(0, 460, 50)] + ['nope']
    if key == 'two':
        return ['w%d' % i for i in range(0, 70, 4)] + ['late-w3']
    if key == 'vbin':
        return ['b%d' % i for i in range(0, 600, 37)] + ['c%d' % i for i in range(0, 60, 9)]
    if key == 'vproj':
        return ['r%d' % i for i in range(0, 530, 33)] + ['q%d' % i for i in range(0, 50, 7)]
    if key == 'tv':
        return ['t%d' % i for i in range(0, 90, 5)] + ['late-t2']
    return ['g%d' % i for i in range(0, 30, 4)]


def vector_corpus(c, readers=READERS, randoms=True, skip=()):
    out = {}
    for reader in readers:
        for key, dim, width in VKEYS:
            if key in skip:
                continue
            out[(reader, key)] = lf.vector_reads(c, at(reader), key, dim, vector_names(key), randoms, width)
    return out


class VectorRoundTrip(Base):
    arguments = SCHEME + SEEDS + ('--save', '')

    def built(self, name):
        directory = self.dir / name
        directory.mkdir()
        run = self.run_server(directory=directory)
        c = self.up(run)
        for label in VCHARGED:
            c.call(*TOP, 'LABEL', 'QUOTA', label, 'LIMIT', 1 << 40)
        outcome = apply_ops(c, vector_script(41))
        refusals = [x for x in outcome if isinstance(x, tuple)]
        self.assertEqual(refusals, [])
        return run, c

    def doom(self, c):
        for key, label in VDOOMED:
            self.assertEqual(c.call(*at(label), 'PEXPIRE', key, 1000), 1)

    def test_every_partition_kind_reads_the_same_after_a_restart_and_after_further_writes(self):
        a, ca = self.built('restarted')
        b, cb = self.built('running')
        self.assertEqual(ca.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), cb.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'))
        before = vector_corpus(ca, randoms=False, skip=('tv', 'gone'))
        scopes_before = ca.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
        for c in (ca, cb):
            self.doom(c)
        self.assertEqual(ca.call(*TOP, 'SAVE'), 'OK')
        a.stop(signal.SIGKILL)
        time.sleep(1.3)
        ca = self.up(a)
        self.assertEqual(lf.info(ca, *TOP)['rdb_last_load_keys_expired'], '2')
        for key, label in VDOOMED:
            cb.call(*at(label), 'EXISTS', key)
        lf_wait(lambda: cb.call(*TOP, 'DBSIZE') == ca.call(*TOP, 'DBSIZE'))
        self.assertEqual(vector_corpus(ca, randoms=False, skip=('tv', 'gone')), before)
        restarted = vector_corpus(ca)
        self.assertEqual(restarted, vector_corpus(cb))
        self.assertEqual(ca.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), cb.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'))
        self.assertEqual(ca.call(*TOP, 'DEBUG', 'DIGEST'), cb.call(*TOP, 'DEBUG', 'DIGEST'))
        self.assertNotEqual(ca.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), scopes_before)
        for label in VCHARGED:
            used, running = ca.call(*TOP, 'LABEL', 'QUOTA', label)[1], cb.call(*TOP, 'LABEL', 'QUOTA', label)[1]
            self.assertGreater(running, 1000, label)
            self.assertEqual(used, running, label)
        more = vector_more(43)
        self.assertEqual(apply_ops(ca, more), apply_ops(cb, more))
        self.assertEqual(vector_corpus(ca), vector_corpus(cb))
        self.assertEqual(ca.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), cb.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'))

    def test_a_reload_and_a_second_restart_keep_every_partition(self):
        a, c = self.built('reloaded')
        before = vector_corpus(c, randoms=False)
        scopes = c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
        self.assertEqual(c.call(*TOP, 'DEBUG', 'RELOAD'), 'OK')
        self.assertEqual(c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), scopes)
        self.assertEqual(vector_corpus(c, randoms=False), before)
        self.assertEqual(c.call(*TOP, 'BGSAVE'), 'Background saving started')
        lf_wait(lambda: lf.info(c, *TOP)['rdb_bgsave_in_progress'] == '0')
        self.assertEqual(lf.info(c, *TOP)['rdb_last_bgsave_status'], 'ok')
        a.stop(signal.SIGKILL)
        c = self.up(a)
        self.assertEqual(c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), scopes)
        self.assertEqual(vector_corpus(c, randoms=False), before)


class VectorPinned(Base):
    arguments = SCHEME + SEEDS + ('--save', '')

    def scoped_payload(self, dump):
        p = lf.rdbcmp.Parser(dump)
        self.assertEqual(p.u8(), 7)
        p.length()
        p.length()
        evs = lf.plain_string(p.string())
        self.assertEqual(evs[:4], b'EVS\x02')
        q = lf.rdbcmp.Parser(evs)
        q.raw(5)
        q.u8()
        for _ in range(3):
            varint(q)
        flags = evs[4]
        self.assertEqual(flags & 1, 0)
        return evs[:4] + bytes([flags | 1]) + evs[5:q.i] + b'\x00' + evs[q.i:]

    def test_a_pinned_bottom_partition_loads_saves_and_takes_writes_like_a_running_one(self):
        (self.dir / 'plain').mkdir()
        plain = self.run_server(('--save', '', '--label-stream-seed', '5'), self.dir / 'plain')
        code, _ = plain.start()
        self.assertIsNone(code)
        p = plain.client()
        rng = random.Random(12)
        for i in range(260):
            p.call(*vadd('pv', rng, 4, 'k%d' % i, *(('SETATTR', '{"a":%d}' % (i % 6)) if i % 2 else ())))
        payload = self.scoped_payload(p.call('DUMP', 'pv'))
        names = ['k%d' % i for i in range(0, 260, 11)]
        plain_reads = lf.vector_reads(p, (), 'pv', 4, names, randoms=False)
        body = lf.aux_head() + lf.header_record(lf.LABELLED, SCHEME_BLOB) + SEL(0) + P(0) + \
            b'\x07' + lf.string('pv') + lf.length(lf.module_id('eski-vset', 2)) + lf.length(5) + lf.string(payload) + lf.length(0)
        data = lf.seal(body)
        runs = []
        for name in ('first', 'second'):
            (self.dir / name).mkdir()
            (self.dir / name / 'dump.rdb').write_bytes(data)
            run = self.run_server(directory=self.dir / name)
            runs.append((run, self.up(run)))
        (a, ca), (b, cb) = runs
        loaded = lf.vector_reads(ca, at('U'), 'pv', 4, names, randoms=False)
        self.assertEqual([x for i, x in enumerate(loaded) if i not in (3, 5)], [x for i, x in enumerate(plain_reads) if i not in (3, 5)])
        scopes = ca.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
        self.assertEqual(ca.call(*TOP, 'SAVE'), 'OK')
        a.stop(signal.SIGKILL)
        ca = self.up(a)
        self.assertEqual(ca.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), scopes)
        for reader in READERS:
            self.assertEqual(lf.vector_reads(ca, at(reader), 'pv', 4, names), lf.vector_reads(cb, at(reader), 'pv', 4, names), reader)
        more = [('U', vadd('pv', rng, 4, 'n%d' % i)) for i in range(60)] + [('U', ('VREM', 'pv', 'k%d' % i)) for i in range(0, 260, 3)] + \
            [('C', vadd('pv', rng, 4, 'c%d' % i)) for i in range(20)]
        self.assertEqual(apply_ops(ca, more), apply_ops(cb, more))
        for reader in READERS:
            self.assertEqual(lf.vector_reads(ca, at(reader), 'pv', 4, names + ['n3', 'c4']), lf.vector_reads(cb, at(reader), 'pv', 4, names + ['n3', 'c4']), reader)
        self.assertEqual(ca.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), cb.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'))

    def test_a_pinned_partition_is_refused_away_from_the_bottom_label(self):
        (self.dir / 'plain').mkdir()
        plain = self.run_server(('--save', ''), self.dir / 'plain')
        code, _ = plain.start()
        self.assertIsNone(code)
        p = plain.client()
        p.call('VADD', 'pv', 'VALUES', 2, 1, 0, 'k')
        payload = self.scoped_payload(p.call('DUMP', 'pv'))
        body = lf.aux_head() + lf.header_record(lf.LABELLED, SCHEME_BLOB) + SEL(0) + P(1) + \
            b'\x07' + lf.string('pv') + lf.length(lf.module_id('eski-vset', 2)) + lf.length(5) + lf.string(payload) + lf.length(0)
        (self.dir / 'dump.rdb').write_bytes(lf.seal(body))
        self.assertIn('vector set partition that does not fit its scope', self.refused(self.run_server()))

    def test_a_failed_copy_order_check_at_the_end_of_the_load_names_its_reason(self):
        (self.dir / 'source').mkdir()
        source = self.run_server(SCHEME + SEEDS + ('--save', '', '--rdbcompression', 'no'), self.dir / 'source')
        c = self.up(source)
        c.call(*at('U'), 'VADD', 'pv', 'VALUES', 2, 1, 0, 'k')
        c.call(*at('U'), 'VADD', 'pv', 'VALUES', 2, 0, 1, 'j')
        self.assertEqual(c.call(*TOP, 'SAVE'), 'OK')
        data = (self.dir / 'source' / 'dump.rdb').read_bytes()
        row = next(r for r in lf.records(data) if r[0] == 'vset')
        p = lf.rdbcmp.Parser(data)
        p.i = row[1] + 1
        p.string()
        begin = p.i
        lf.module_value(p)
        value = b'\x07' + lf.string('pv') + data[begin:p.i]
        for i, order in enumerate((lf.order_record([(0, 'pv', [0, 1])]), b'')):
            body = lf.aux_head() + lf.header_record(lf.LABELLED, SCHEME_BLOB) + SEL(0, 2) + P(0) + value + P(1) + value + order
            directory = self.dir / ('order-%d' % i)
            directory.mkdir()
            (directory / 'dump.rdb').write_bytes(lf.seal(body))
            text = self.refused(self.run_server(directory=directory))
            self.assertIn('the file holds a vector set with an invalid order of copies', text)
            self.assertNotIn('the file is malformed', text)


def varint(p):
    shift = value = 0
    while True:
        b = p.u8()
        value |= (b & 0x7f) << shift
        shift += 7
        if b < 0x80:
            return value


class VectorTwins(Base):
    arguments = SCHEME + SEEDS + ('--save', '')
    LOW = 'C//A'
    VISIBLE = ('U', 'C', 'C//A')
    HIDDEN = ('C//B', 'S//B', 'S', 'S//A/B', 'S//A')
    KEYS = ('k0', 'k1', 'k2', 'k3')
    NAMES = ['n%d' % i for i in range(30)]

    def script(self):
        rng = random.Random(31)
        ops = []
        for step in range(700):
            label = rng.choice(self.VISIBLE + self.HIDDEN)
            key = rng.choice(self.KEYS)
            name = rng.choice(self.NAMES)
            r = rng.random()
            if r < 0.75:
                attr = ('SETATTR', '{"a":%d}' % (step % 6)) if step % 4 == 0 else ()
                ops.append((label, vadd(key, rng, 3, name, *attr)))
            elif r < 0.87:
                ops.append((label, ('VREM', key, name)))
            else:
                ops.append((label, ('VSETATTR', key, name, '{"a":%d}' % (step % 5))))
        bulk = [('C', vadd('k0', rng, 3, 'big%d' % i)) for i in range(560)] + [('S', vadd('k0', rng, 3, 'big%d' % i)) for i in range(540)] + \
            [('S//B', vadd('k1', rng, 3, 'big%d' % i)) for i in range(530)] + [('C//A', vadd('k1', rng, 3, 'big%d' % i)) for i in range(150)]
        return interleave(rng, [ops, bulk])

    def corpus(self, c):
        low = at(self.LOW)
        keys, cursors = full_scan(c, low)
        out = [keys, cursors, c.call(*low, 'DBSIZE'), sorted(c.call(*low, 'KEYS', '*')), [c.call(*low, 'RANDOMKEY') for _ in range(6)]]
        names = self.NAMES + ['big%d' % i for i in range(0, 560, 23)]
        for key in self.KEYS + ('k9',):
            out.append(lf.vector_reads(c, low, key, 3, names))
            out.append(lf.answers(c, [(*low, 'MEMORY', 'USAGE', key), (*low, 'DUMP', key), (*low, 'OBJECT', 'ENCODING', key),
                                      (*low, 'DEBUG', 'DIGEST-VALUE', key), (*low, 'TTL', key)]))
        out.append([l for l in c.call(*low, 'INFO', 'keyspace').decode().splitlines() if l.startswith('db')])
        out.append(sorted((k, v) for k, v in lf.info(c, *low, section='everything').items() if k not in VARYING))
        out.append(c.call(*low, 'LASTSAVE') == c.call(*at('U'), 'LASTSAVE'))
        out.append(lf.answers(c, [(*low, 'DEBUG', 'DIGEST-SCOPES'), (*low, 'SAVE'), (*low, 'BGSAVE'), (*low, 'DEBUG', 'RELOAD'),
                                  (*low, 'BGREWRITEAOF'), (*low, 'CONFIG', 'SET', 'save', '1 1')]))
        copies = []
        for key in self.KEYS:
            payload = c.call(*low, 'DUMP', key)
            if payload is not None:
                copies += [(*low, 'RESTORE', key + '-copy', 0, payload), (*low, 'VCARD', key + '-copy'), (*low, 'VINFO', key + '-copy'),
                           (*low, 'VEMB', key + '-copy', 'n3'), (*low, 'DEL', key + '-copy')]
        out.append(lf.answers(c, copies))
        return out

    def world(self, hidden, expire=False, sensitive=False, cap=False):
        directory = self.dir / ('v-%d-%d-%d-%d' % (hidden, expire, sensitive, cap))
        directory.mkdir()
        run = self.run_server(directory=directory)
        c = self.up(run)
        visible = []
        ages = {}
        for step, (label, op) in enumerate(self.script()):
            if label in self.HIDDEN and not hidden:
                continue
            reply = lf.answers(c, [(*at(label), *op)])[0]
            if label in self.VISIBLE:
                visible.append(reply)
            if op[0] == 'VADD' and reply in (0, 1):
                ages.setdefault((op[1], op[-1] if op[-2] != 'SETATTR' else op[-3], label in self.HIDDEN), step)
        if sensitive:
            c.call(*at('C'), 'VADD', 'k2', 'VALUES', 3, 1, 2, 3, 'n7')
        if expire:
            for label in self.HIDDEN:
                for key in self.KEYS:
                    if c.call(*at(label), 'LABEL', 'OF', key) == label.encode():
                        self.assertEqual(c.call(*at(label), 'PEXPIRE', key, 1200), 1)
        before = self.corpus(c)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        if expire:
            time.sleep(1.4)
        c = self.up(run, ('--label-partitions-max', '4') if cap else ())
        after = self.corpus(c)
        if cap:
            after.append([str(lf.answers(c, [(*at(label), 'VADD', 'probe', 'VALUES', 3, 1, 1, 1, 'x')])[0]) for label in ('U;VETTED', 'C;VETTED')])
        run.stop(signal.SIGKILL)
        order = [0, 0]
        for (key, name, high), step in ages.items():
            if high and (key, name, False) in ages:
                order[0 if step < ages[(key, name, False)] else 1] += 1
        return visible, before, after, order

    def test_hidden_vector_partitions_change_nothing_before_or_after_a_restart(self):
        quiet = self.world(False)
        noisy = self.world(True)
        self.assertGreater(noisy[3][0], 0)
        self.assertGreater(noisy[3][1], 0)
        self.assertEqual(quiet[0], noisy[0])
        self.assertEqual(quiet[1], noisy[1])
        self.assertEqual(quiet[2], noisy[2])

    def test_hidden_vector_partitions_that_expired_during_downtime_leave_nothing(self):
        quiet = self.world(False, cap=True)
        gone = self.world(True, expire=True, cap=True)
        self.assertEqual(quiet[1], gone[1])
        self.assertEqual(quiet[2], gone[2])

    def test_a_visible_vector_difference_shows(self):
        self.assertNotEqual(self.world(False)[2], self.world(False, sensitive=True)[2])


VARYING = ('run_id', 'tcp_port', 'process_id', 'executable', 'config_file', 'listener0', 'server_time_usec', 'uptime_in_seconds',
           'uptime_in_days', 'lru_clock', 'io_threads_active', 'monotonic_clock')


class VectorRestore(Base):
    arguments = SCHEME + SEEDS + ('--save', '')

    def plain(self):
        (self.dir / 'plain').mkdir()
        run = self.run_server(('--save', '', '--label-stream-seed', '5'), self.dir / 'plain')
        code, _ = run.start()
        self.assertIsNone(code)
        self.plain_run = run
        return run.client()

    def test_restore_lands_at_the_callers_scope_like_any_other_type(self):
        p = self.plain()
        rng = random.Random(8)
        for i in range(200):
            p.call(*vadd('src', rng, 4, 'm%d' % i, 'SETATTR', '{"a":%d}' % (i % 4)))
        payload = p.call('DUMP', 'src')
        names = ['m%d' % i for i in range(0, 200, 9)]
        run = self.run_server()
        c = self.up(run)
        self.assertEqual(c.call(*at('C'), 'RESTORE', 'r', 0, payload), 'OK')
        self.assertEqual(c.call(*at('C'), 'LABEL', 'OF', 'r'), b'C')
        self.assertEqual(c.call(*at('U'), 'EXISTS', 'r'), 0)
        self.assertEqual(c.call(*at('S//A'), 'VCARD', 'r'), 200)
        self.assertEqual([c.call(*at('C'), 'VEMB', 'r', n) for n in names], [p.call('VEMB', 'src', n) for n in names])
        self.assertEqual([c.call(*at('C'), 'VGETATTR', 'r', n) for n in names], [p.call('VGETATTR', 'src', n) for n in names])
        self.assertEqual(error_of(c, *at('C'), 'RESTORE', 'r', 0, payload), 'BUSYKEY Target key name already exists.')
        c.call(*at('U'), 'VADD', 'low', 'VALUES', 4, 1, 1, 1, 1, 'u')
        self.assertTrue(error_of(c, *at('C'), 'RESTORE', 'low', 0, payload).startswith('INUSE name in use at U'))
        self.assertEqual(c.call(*at('S//A'), 'VADD', 'r', 'VALUES', 4, 1, 2, 3, 4, 'high'), 1)
        self.assertEqual(c.call(*at('S//A'), 'VCARD', 'r'), 201)
        self.assertEqual(c.call(*at('C'), 'RESTORE', 'r', 0, p.call('DUMP', 'src'), 'REPLACE'), 'OK')
        self.assertEqual(c.call(*at('C'), 'VCARD', 'r'), 200)
        self.assertEqual(c.call(*at('C'), 'VISMEMBER', 'r', 'high'), 0)
        self.assertEqual(c.call(*at('S//A'), 'VCARD', 'r'), 1)
        self.assertEqual(c.call(*at('S//A'), 'VISMEMBER', 'r', 'high'), 1)
        low_view = c.call(*at('C'), 'DUMP', 'r')
        self.assertEqual(c.call(*at('U;VETTED'), 'RESTORE', 'low2', 0, low_view), 'OK')
        self.assertEqual([c.call(*at('U;VETTED'), 'VEMB', 'low2', n) for n in names], [p.call('VEMB', 'src', n) for n in names])
        self.assertEqual(p.call('RESTORE', 'back', 0, low_view), 'OK')
        self.assertEqual([p.call('VGETATTR', 'back', n) for n in names], [p.call('VGETATTR', 'src', n) for n in names])
        reads = {r: lf.vector_reads(c, at(r), key, 4, names, randoms=False) for r in READERS for key in ('r', 'low2')}
        scopes = c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        c = self.up(run)
        self.assertEqual(c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), scopes)
        self.assertEqual({r: lf.vector_reads(c, at(r), key, 4, names, randoms=False) for r in READERS for key in ('r', 'low2')}, reads)

    def test_a_scoped_payload_is_refused(self):
        run = self.run_server(SCHEME + SEEDS + ('--save', '', '--rdbcompression', 'no'))
        c = self.up(run)
        c.call(*at('C'), 'VADD', 'v', 'VALUES', 2, 1, 0, 'x')
        c.call(*TOP, 'SAVE')
        data = (self.dir / 'dump.rdb').read_bytes()
        row = next(r for r in lf.records(data) if r[0] == 'vset')
        p = lf.rdbcmp.Parser(data)
        p.i = row[1] + 1
        p.string()
        begin = p.i
        lf.module_value(p)
        body = b'\x07' + data[begin:p.i] + bytes([12, 0])
        payload = body + lf.rdbcmp.crc64(body).to_bytes(8, 'little')
        self.assertEqual(error_of(c, *at('C'), 'RESTORE', 'scoped', 0, payload), 'ERR Bad data format')
        self.assertEqual(c.call(*at('C'), 'EXISTS', 'scoped'), 0)
        self.assertEqual(c.call(*at('C'), 'RESTORE', 'flat', 0, c.call(*at('C'), 'DUMP', 'v')), 'OK')

    def test_a_refused_restore_answers_like_a_write_over_the_limit(self):
        p = self.plain()
        rng = random.Random(9)
        p.pipeline([vadd('big', rng, 2, 'e%d' % i, 'M', 64) for i in range(5000)])
        payload = p.call('DUMP', 'big')
        p.call('DEL', 'big')
        p.call('CONFIG', 'SET', 'maxmemory', int(lf.info(p, section='memory')['used_memory']) + len(payload) + 100000)
        self.assertEqual(error_of(p, 'RESTORE', 'big', 0, payload), "OOM command not allowed when used memory > 'maxmemory'.")
        self.assertEqual(error_of(p, 'RESTORE', 'list', 0, lf.MALFORMED_LIST), 'ERR Bad data format')
        self.assertEqual(error_of(p, 'RESTORE', 'big', 0, payload), "OOM command not allowed when used memory > 'maxmemory'.")
        self.assertEqual(error_of(self.plain_run.client(), 'RESTORE', 'list', 0, lf.MALFORMED_LIST), 'ERR Bad data format')
        self.assertEqual(p.call('EXISTS', 'big'), 0)
        p.call('CONFIG', 'SET', 'maxmemory', 0)
        self.assertEqual(error_of(p, 'RESTORE', 'bogus', 0, b'\x07\x01' + payload[2:]), 'ERR DUMP payload version or checksum are wrong')
        self.assertEqual(p.call('RESTORE', 'big', 0, payload), 'OK')
        run = self.run_server()
        c = self.up(run)
        c.call(*TOP, 'CONFIG', 'SET', 'maxmemory', int(lf.info(c, *TOP, section='memory')['used_memory']) + len(payload) + 100000)
        self.assertEqual(error_of(c, *at('C'), 'RESTORE', 'big', 0, payload), "OOM command not allowed when used memory > 'maxmemory'.")
        self.assertEqual(error_of(c, *at('C'), 'RESTORE', 'list', 0, lf.MALFORMED_LIST), 'ERR Bad data format')
        self.assertEqual(error_of(c, *at('U'), 'RESTORE', 'big', 0, payload), "OOM command not allowed when used memory > 'maxmemory'.")
        self.assertEqual(error_of(run.client(), *at('S//A'), 'RESTORE', 'list', 0, lf.MALFORMED_LIST), 'ERR Bad data format')
        c.call(*TOP, 'CONFIG', 'SET', 'maxmemory', 0)
        self.assertEqual(c.call(*at('C'), 'EXISTS', 'big'), 0)
        self.assertEqual(c.call(*at('C'), 'SET', 'big', 'after the refusal'), 'OK')

    def test_a_malformed_payload_answers_the_format_error_whatever_size_its_header_claims(self):
        p = self.plain()
        run = self.run_server()
        c = self.up(run)
        payloads = lf.malformed_vset_dumps()
        for client, prefix in ((p, ()), (c, at('C')), (c, at('U'))):
            used = int(lf.info(client, *TOP if prefix else (), section='memory')['used_memory'])
            for limit in (0, used + (1 << 22), used + (1 << 30)):
                client.call(*TOP if prefix else (), 'CONFIG', 'SET', 'maxmemory', limit)
                for payload in payloads:
                    self.assertEqual(error_of(client, *prefix, 'RESTORE', 'm', 0, payload), 'ERR Bad data format', (prefix, limit, payload[:40]))
                self.assertEqual(client.call(*prefix, 'EXISTS', 'm'), 0)
            client.call(*TOP if prefix else (), 'CONFIG', 'SET', 'maxmemory', 0)


class VectorAccounting(Base):
    arguments = SCHEME + SEEDS + ('--save', '')
    ELEMENTS = 300
    LABELS = ('C', 'U', 'S//A')

    def figures(self, c):
        return tuple(c.call(*TOP, 'LABEL', 'QUOTA', label)[1] for label in self.LABELS) + \
            (int(lf.info(c, *TOP, section='memory')['used_memory_dataset']),)

    def build(self, c, key, label):
        rng = random.Random(15)
        ops = [(*at(label), *vadd(key, rng, 3, 'e%d' % i)) for i in range(self.ELEMENTS)]
        self.assertEqual(lf.answers(c, ops), [1] * self.ELEMENTS)

    def near(self, restored, restored_base, built, built_base, what):
        for k, name in enumerate(self.LABELS + ('used_memory_dataset',)):
            got, want = restored[k] - restored_base[k], built[k] - built_base[k]
            if want == 0:
                self.assertEqual(got, 0, (what, name, restored, built))
            else:
                self.assertGreater(want, 4000, (what, name))
                self.assertLessEqual(got, want * 5 // 4, (what, name, restored, built))
                self.assertGreaterEqual(got, want * 4 // 5, (what, name, restored, built))

    def servers(self):
        out = []
        for name in ('restored', 'built'):
            (self.dir / name).mkdir()
            run = self.run_server(directory=self.dir / name)
            c = self.up(run)
            self.build(c, 'src', 'S//A')
            out.append((run, c, c.call(*at('S//A'), 'DUMP', 'src')))
        self.assertEqual(out[0][2], out[1][2])
        return out

    def test_a_restored_vector_set_is_charged_like_one_built_by_writes_and_released_by_del(self):
        (a, ca, payload), (b, cb, _) = self.servers()
        base_a, base_b = self.figures(ca), self.figures(cb)
        self.assertEqual(ca.call(*at('C'), 'RESTORE', 'r', 0, payload), 'OK')
        self.build(cb, 'r', 'C')
        self.near(self.figures(ca), base_a, self.figures(cb), base_b, 'restore')
        self.assertEqual(ca.call(*at('U'), 'RESTORE', 'low', 0, payload), 'OK')
        self.build(cb, 'low', 'U')
        self.near(self.figures(ca), base_a, self.figures(cb), base_b, 'second restore')
        self.assertEqual(ca.call(*at('C'), 'RESTORE', 'r', 0, payload, 'REPLACE'), 'OK')
        self.assertEqual(ca.call(*at('U'), 'RESTORE', 'low', 0, payload, 'REPLACE'), 'OK')
        self.near(self.figures(ca), base_a, self.figures(cb), base_b, 'restore with replace')
        for c in (ca, cb):
            self.assertEqual(c.call(*at('C'), 'DEL', 'r'), 1)
            self.assertEqual(c.call(*at('U'), 'DEL', 'low'), 1)
        fa, fb = self.figures(ca), self.figures(cb)
        self.assertEqual([x - y for x, y in zip(fa, base_a)], [x - y for x, y in zip(fb, base_b)], (fa, base_a, fb, base_b))

    def test_a_restart_then_removing_everything_leaves_what_a_running_server_leaves(self):
        (a, ca, payload), (b, cb, _) = self.servers()
        base_a, base_b = self.figures(ca), self.figures(cb)
        for c in (ca, cb):
            self.assertEqual(c.call(*at('C'), 'RESTORE', 'r', 0, payload), 'OK')
            self.assertEqual(c.call(*at('U'), 'RESTORE', 'low', 0, payload), 'OK')
        self.assertEqual(ca.call(*TOP, 'SAVE'), 'OK')
        a.stop(signal.SIGKILL)
        ca = self.up(a)
        for k, (restarted, running) in enumerate(zip(self.figures(ca), self.figures(cb))):
            self.assertGreater(running, 30000, k)
            if k < len(self.LABELS):
                self.assertEqual(restarted, running, (k, restarted, running))
            else:
                self.assertLessEqual(restarted, running * 5 // 4, (k, restarted, running))
                self.assertGreaterEqual(restarted, running * 4 // 5, (k, restarted, running))
        for c in (ca, cb):
            self.assertEqual(c.call(*at('C'), 'DEL', 'r'), 1)
            self.assertEqual(c.call(*at('U'), 'DEL', 'low'), 1)
            self.assertEqual(c.call(*at('S//A'), 'DEL', 'src'), 1)
            self.assertEqual(c.call(*TOP, 'DBSIZE'), 0)
        self.assertEqual(self.figures(ca), self.figures(cb))


class VectorSave(Base):
    arguments = SCHEME + SEEDS + ('--save', '3600 1')

    def test_a_vector_set_at_any_label_saves_and_no_write_answers_misconf(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*at('C'), 'SET', 'k', 'v')
        self.assertEqual(c.call(*at('S//A'), 'VADD', 'vs', 'VALUES', 2, 1, 0, 'e'), 1)
        self.assertEqual(c.call(*TOP, 'BGSAVE'), 'Background saving started')
        lf_wait(lambda: lf.info(c, *TOP)['rdb_bgsave_in_progress'] == '0')
        self.assertEqual(lf.info(c, *TOP)['rdb_last_bgsave_status'], 'ok')
        for label in READERS:
            self.assertEqual(c.call(*at(label), 'SET', 'w-' + label, 1), 'OK')
        self.assertEqual(c.call(*at('C'), 'VADD', 'vs', 'VALUES', 2, 0, 1, 'f'), 1)
        self.assertEqual(run.stop(signal.SIGTERM), 0)
        self.assertNotIn('Refusing to save', run.log())
        c = self.up(run)
        self.assertEqual(c.call(*at('S//A'), 'VCARD', 'vs'), 1)
        self.assertEqual(c.call(*at('S//A'), 'VISMEMBER', 'vs', 'e'), 1)
        self.assertEqual(c.call(*at('C'), 'VCARD', 'vs'), 1)
        self.assertEqual(c.call(*at('C'), 'VISMEMBER', 'vs', 'f'), 1)


class VectorSeed(Base):
    arguments = ('--save', '')

    def plain(self, name, seed):
        (self.dir / name).mkdir()
        run = self.run_server(('--save', '', '--label-stream-seed', str(seed)), self.dir / name)
        code, text = run.start()
        self.assertIsNone(code, text)
        return run, run.client()

    def grow(self, c, prefix=()):
        rng = random.Random(4)
        lf.answers(c, [(*prefix, *vadd('later', rng, 4, 'l%d' % i)) for i in range(600)])
        return lf.vector_reads(c, prefix, 'later', 4, ['l%d' % i for i in range(0, 600, 17)], randoms=False)

    def test_a_plain_file_carries_the_seed_only_with_a_vector_set(self):
        run, c = self.plain('plain', 5)
        c.call('SET', 'k', 'v')
        c.call('SAVE')
        self.assertNotIn(b'eski-vset-seed', (self.dir / 'plain' / 'dump.rdb').read_bytes())
        c.call('VADD', 'vs', 'VALUES', 2, 1, 0, 'e')
        c.call('SAVE')
        data = (self.dir / 'plain' / 'dump.rdb').read_bytes()
        self.assertEqual(data.count(b'eski-vset-seed'), 1)
        value = lf.aux_fields(data)[b'eski-vset-seed']
        self.assertTrue(value.isdigit() and int(value) > 0 and not value.startswith(b'0'), value)
        rows = lf.records(data)
        kinds = [r[0] for r in rows]
        self.assertEqual(kinds.index('vset') - 1, [i for i, r in enumerate(rows) if r[0] == 'aux' and data[r[1] + 1:r[1] + 16] == b'\x0eeski-vset-seed'][0])
        self.assertEqual(c.call('DEBUG', 'RELOAD'), 'OK')
        self.assertEqual(c.call('VCARD', 'vs'), 1)

    def test_a_seed_loaded_from_a_file_wins_over_label_stream_seed(self):
        run, c = self.plain('first', 5)
        c.call('VADD', 'k1', 'VALUES', 2, 1, 0, 'e')
        c.call('SAVE')
        run.stop(signal.SIGKILL)
        restarted = lf.Run(BINARY, self.dir / 'first', ('--save', '', '--label-stream-seed', '9'), KEYSPACE_THREADS)
        self.runs.append(restarted)
        code, text = restarted.start()
        self.assertIsNone(code, text)
        loaded = self.grow(restarted.client())
        _, same = self.plain('same', 5)
        same.call('VADD', 'k1', 'VALUES', 2, 1, 0, 'e')
        _, other = self.plain('other', 9)
        other.call('VADD', 'k1', 'VALUES', 2, 1, 0, 'e')
        self.assertEqual(loaded, self.grow(same))
        self.assertNotEqual(loaded, self.grow(other))

    def test_a_labelled_header_carries_the_seed_and_it_wins_after_a_restart(self):
        def labelled(name, seed):
            (self.dir / name).mkdir()
            run = self.run_server(SCHEME + ('--save', '', '--label-stream-seed', str(seed)), self.dir / name)
            return run, self.up(run)
        run, c = labelled('lab', 5)
        c.call(*at('C'), 'SET', 'k', 'v')
        c.call(*TOP, 'SAVE')
        self.assertEqual(lf.header_fields((self.dir / 'lab' / 'dump.rdb').read_bytes())[-1][0], 0)
        c.call(*at('S//A'), 'VADD', 'vs', 'VALUES', 2, 1, 0, 'e')
        c.call(*TOP, 'SAVE')
        self.assertNotEqual(lf.header_fields((self.dir / 'lab' / 'dump.rdb').read_bytes())[-1][0], 0)
        run.stop(signal.SIGKILL)
        again = self.run_server(SCHEME + ('--save', '', '--label-stream-seed', '9'), self.dir / 'lab')
        loaded = self.grow(self.up(again), at('C'))
        _, same = labelled('same', 5)
        same.call(*at('S//A'), 'VADD', 'vs', 'VALUES', 2, 1, 0, 'e')
        _, other = labelled('other', 9)
        other.call(*at('S//A'), 'VADD', 'vs', 'VALUES', 2, 1, 0, 'e')
        self.assertEqual(loaded, self.grow(same, at('C')))
        self.assertNotEqual(loaded, self.grow(other, at('C')))

    def test_an_invalid_seed_field_is_refused(self):
        for i, value in enumerate((b'0', b'abc', b'', b'018446744073709551615', b'18446744073709551616')):
            directory = self.dir / ('bad-%d' % i)
            directory.mkdir()
            body = lf.aux_head() + b'\xfa' + lf.string('eski-vset-seed') + lf.string(value) + SEL(0) + K('k', 'v')
            (directory / 'dump.rdb').write_bytes(lf.seal(body))
            text = self.refused(self.run_server(('--save', ''), directory))
            self.assertIn('invalid vector set seed field', text, value)
        directory = self.dir / 'good'
        directory.mkdir()
        body = lf.aux_head() + b'\xfa' + lf.string('eski-vset-seed') + lf.string('18446744073709551615') + SEL(0) + K('k', 'v')
        (directory / 'dump.rdb').write_bytes(lf.seal(body))
        run = self.run_server(('--save', ''), directory)
        code, text = run.start()
        self.assertIsNone(code, text)
        self.assertEqual(run.client().call('GET', 'k'), b'v')

    def test_a_repeated_seed_field_is_refused(self):
        for i, (first, second) in enumerate(((b'77', b'77'), (b'77', b'78'))):
            directory = self.dir / ('twice-%d' % i)
            directory.mkdir()
            field = b'\xfa' + lf.string('eski-vset-seed')
            body = lf.aux_head() + field + lf.string(first) + field + lf.string(second) + SEL(0) + K('k', 'v')
            (directory / 'dump.rdb').write_bytes(lf.seal(body))
            self.assertIn('invalid vector set seed field', self.refused(self.run_server(('--save', ''), directory)))

    def test_a_load_without_a_seed_forgets_the_seed_it_held(self):
        run, c = self.plain('first', 5)
        c.call('VADD', 'k1', 'VALUES', 2, 1, 0, 'e')
        c.call('SAVE')
        run.stop(signal.SIGKILL)
        restarted = lf.Run(BINARY, self.dir / 'first', ('--save', '', '--label-stream-seed', '9'), KEYSPACE_THREADS)
        self.runs.append(restarted)
        code, text = restarted.start()
        self.assertIsNone(code, text)
        r = restarted.client()
        self.assertEqual(r.call('VCARD', 'k1'), 1)
        self.assertEqual(r.call('DEL', 'k1'), 1)
        self.assertEqual(r.call('DEBUG', 'RELOAD'), 'OK')
        self.assertNotIn(b'eski-vset-seed', (self.dir / 'first' / 'dump.rdb').read_bytes())
        loaded = self.grow(r)
        worlds = []
        for name, seed in (('nine', 9), ('five', 5)):
            _, w = self.plain(name, seed)
            w.call('VADD', 'k1', 'VALUES', 2, 1, 0, 'e')
            w.call('DEL', 'k1')
            worlds.append(self.grow(w))
        self.assertEqual(loaded, worlds[0])
        self.assertNotEqual(loaded, worlds[1])


class DebugHelp(Base):
    def test_the_help_names_digest_scopes_only_with_labels(self):
        (self.dir / 'plain').mkdir()
        plain = self.run_server(('--save', ''), self.dir / 'plain')
        code, _ = plain.start()
        self.assertIsNone(code)
        lines = plain.client().call('DEBUG', 'HELP')
        self.assertNotIn('DIGEST-SCOPES', lines)
        c = self.up(self.run_server(SCHEME + ('--save', '')))
        labelled = c.call(*TOP, 'DEBUG', 'HELP')
        at_scopes = labelled.index('DIGEST-SCOPES')
        self.assertEqual(labelled[:at_scopes] + labelled[at_scopes + 3:], lines)
        self.assertTrue(labelled[at_scopes + 3].startswith('ERROR '))
        self.assertTrue(all(x.startswith('    ') for x in labelled[at_scopes + 1:at_scopes + 3]))


class VectorDigest(Base):
    arguments = SCHEME + SEEDS + ('--save', '')

    def test_digest_scopes_sees_each_vector_partition(self):
        c = self.up(self.run_server())
        c.call(*at('U;VETTED'), 'VADD', 'v', 'VALUES', 2, 0, 1, 'anchor')
        c.call(*at('S//A'), 'VADD', 'v', 'VALUES', 2, 1, 0, 'x', 'SETATTR', '{"a":1}')
        c.call(*at('S//A'), 'VADD', 'v', 'VALUES', 2, 1, 1, 'y')
        c.call(*at('S//B'), 'VADD', 'v', 'VALUES', 2, 2, 1, 'z')
        plain, scopes = c.call(*TOP, 'DEBUG', 'DIGEST'), c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
        c.call(*at('S//A'), 'VREM', 'v', 'x')
        c.call(*at('S//B'), 'VADD', 'v', 'VALUES', 2, 1, 0, 'x', 'SETATTR', '{"a":1}')
        self.assertEqual(c.call(*TOP, 'DEBUG', 'DIGEST'), plain)
        moved = c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
        self.assertNotEqual(moved, scopes)
        c.call(*at('S//A'), 'VREM', 'v', 'y')
        c.call(*at('S//A'), 'VADD', 'v', 'VALUES', 2, 1, 1, 'y')
        self.assertEqual(c.call(*TOP, 'DEBUG', 'DIGEST'), plain)
        self.assertNotEqual(c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), moved)


def main():
    global BINARY, KEYSPACE_THREADS, OLDER, WRITE_FIXTURES
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', default=str(BINARY))
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--older-server')
    parser.add_argument('--write-fixtures', action='store_true')
    args, rest = parser.parse_known_args()
    BINARY = Path(args.server).resolve()
    KEYSPACE_THREADS = args.keyspace_threads
    OLDER = Path(args.older_server).resolve() if args.older_server else None
    WRITE_FIXTURES = args.write_fixtures
    unittest.main(argv=[sys.argv[0]] + rest, verbosity=1)


if __name__ == '__main__':
    main()
