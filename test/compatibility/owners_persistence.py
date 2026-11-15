import argparse
from pathlib import Path
import random
import signal
import subprocess
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
FIXTURES = ROOT / 'test/compatibility/fixtures'
WRITE_FIXTURES = False
SCHEME = ('--label-levels', 'U,C,S', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED')
OWNERS = ('--owners', 'yes')
SEEDS = ('--debug-hash-seed', '11', '--label-stream-seed', '5')
OPERATOR = ('on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*', 'owners:*', 'owner-shared', 'owner-operator')
TOP = ('LABEL', 'AS', 'S//A/B', 'SHARED')
TOP_ERROR = 'ERR this command needs a label that dominates the whole label scheme'
OPERATOR_ERROR = 'ERR this command needs a login with the owner-operator right'
FAR = 4102444800000
READERS = (('U', ''), ('C', ''), ('S//A/B', ''), ('C', 'u1'), ('S//A/B', 'u1'), ('S//A', 'u1'), ('S//B', 'u2'), ('U', 'u3'), ('C;VETTED', 'u1'))
SCHEME_BLOB = lf.eslt(['U', 'C', 'S'], ['A', 'B'], ['WEB', 'VETTED'], [(1, 0, ()), (2, 0, (0,)), (2, 0, (1,))])
SLOW = ('--key-load-delay', '2000', '--loading-process-events-interval-bytes', '1024')


def at(label, owner=''):
    if owner == '':
        return ('LABEL', 'AS', label, 'SHARED')
    return ('LABEL', 'AS', label, 'OWNER', owner)


def error_of(client, *arguments):
    try:
        value = client.call(*arguments)
    except ServerError as error:
        return str(error)
    raise AssertionError('expected an error from %r, got %r' % (arguments, value))


def as_map(value):
    if isinstance(value, dict):
        return value
    return dict(zip(value[0::2], value[1::2]))


def full_scan(c, p):
    seen = []
    cursors = []
    cursor = b'0'
    while True:
        cursor, batch = c.call(*p, 'SCAN', cursor, 'COUNT', 5)
        cursors.append(cursor)
        seen.extend(batch)
        if cursor == b'0':
            return sorted(set(seen)), cursors


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
        return sorted(zip(flat[0::2], flat[1::2])), c.call(*p, 'HPEXPIRETIME', key, 'FIELDS', len(fields), *fields)
    if kind == 'stream':
        return c.call(*p, 'XRANGE', key, '-', '+')
    return kind


def view(c, label, owner):
    p = at(label, owner)
    keys, _ = full_scan(c, p)
    out = {'scan': keys, 'dbsize': c.call(*p, 'DBSIZE'), 'keys': sorted(c.call(*p, 'KEYS', '*'))}
    for k in keys:
        kind = c.call(*p, 'TYPE', k)
        out[(k, 'value')] = (kind, read_value(c, p, k, kind), c.call(*p, 'PEXPIRETIME', k), c.call(*p, 'LABEL', 'OF', k))
    out['keyspace'] = [','.join(x for x in l.split(',') if not x.startswith('avg_ttl='))
                       for l in c.call(*p, 'INFO', 'keyspace').decode().splitlines() if l.startswith('db')]
    return out


def owners_listed(c):
    out = []
    cursor = 0
    while True:
        cursor, batch = c.call(*TOP, 'OWNERS', 'LIST', cursor, 'COUNT', 2)
        out.extend(batch)
        if cursor == b'0':
            return out


def owner_facts(c, name):
    info = as_map(c.call(*TOP, 'OWNERS', 'INFO', name))
    return {k: v for k, v in info.items() if k != b'bytes'}, c.call(*TOP, 'OWNERS', 'QUOTA', name)[0]


def state(c):
    return {
        'scopes': c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'),
        'digest': c.call(*TOP, 'DEBUG', 'DIGEST'),
        'listed': owners_listed(c),
        'owners': {n: owner_facts(c, n) for n in ('u1', 'u2', 'u3', 'u9')},
        'views': {r: view(c, *r) for r in READERS},
    }


def populate(c, rng):
    for label, owner in (('S//A', 'u1'), ('S//B', 'u1'), ('C', 'u1'), ('U', 'u2'), ('S//B', 'u2'), ('C', ''), ('U', ''), ('S//A', ''), ('U', 'u3')):
        p = at(label, owner)
        tag = (label + '-' + (owner or 'shared')).replace('/', '').replace(';', '-')
        c.call(*p, 'SET', 's-' + tag, 'value')
        c.call(*p, 'RPUSH', 'l-' + tag, *range(6))
        c.call(*p, 'SADD', 'set-' + tag, *['m%d' % i for i in range(rng.randrange(3, 200))])
        c.call(*p, 'ZADD', 'z-' + tag, *[x for i in range(rng.randrange(3, 150)) for x in (i, 'z%d' % i)])
        c.call(*p, 'HSET', 'h-' + tag, *[x for i in range(rng.randrange(2, 200)) for x in ('f%d' % i, 'v')])
        c.call(*p, 'HPEXPIREAT', 'h-' + tag, FAR, 'FIELDS', 1, 'f1')
        c.call(*p, 'XADD', 'x-' + tag, '1-1', 'a', 1)
        c.call(*p, 'SET', 't-' + tag, 'timed', 'PXAT', FAR - 7)
    for label, owner, value in (('S//A', 'u1', 'u1-a'), ('S//B', 'u1', 'u1-b'), ('S//B', '', 'shared-b'), ('C', 'u1', 'u1-c'), ('U', 'u2', 'u2-u'), ('U', '', 'shared-u')):
        c.call(*at(label, owner), 'SET', 'dup', value)
    for label in ('S//B', 'S//A'):
        c.call(*at(label, 'u1'), 'SET', 'age', label)
    c.call('SELECT', 2)
    c.call(*at('C', 'u1'), 'SET', 'db2', 'one')
    c.call(*at('C'), 'SET', 'db2', 'shared')
    c.call('SELECT', 0)
    c.call(*TOP, 'OWNERS', 'QUOTA', 'u1', 'LIMIT', 50000000)
    c.call(*TOP, 'OWNERS', 'QUOTA', 'u9', 'LIMIT', 70000)
    c.call(*TOP, 'LABEL', 'QUOTA', 'C', 'LIMIT', 40000000)
    c.call(*at('U', 'u8'), 'GET', 'nothing')


def wait(predicate, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError('condition not reached')


class Base(unittest.TestCase):
    arguments = SCHEME + OWNERS + SEEDS + ('--save', '3600 1')

    def setUp(self):
        self.temp = lf.workdir('eski-owners-persist-')
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.runs = []

    def tearDown(self):
        for run in self.runs:
            run.kill()

    def run_server(self, arguments=None, directory=None):
        run = lf.Run(BINARY, directory or self.dir, self.arguments if arguments is None else arguments, KEYSPACE_THREADS)
        self.runs.append(run)
        return run

    def up(self, run, extra=()):
        code, text = run.start(extra)
        self.assertIsNone(code, 'server exited with %r: %s' % (code, text[-3000:]))
        c = run.client()
        c.call('ACL', 'SETUSER', 'default', *OPERATOR)
        return c

    def refused(self, run):
        code, text = run.start()
        if code is None:
            run.stop()
            self.fail('server started on a file it must refuse')
        self.assertEqual(code, 1, text[-3000:])
        return text


class RoundTrip(Base):
    def check(self, how):
        run = self.run_server()
        c = self.up(run)
        populate(c, random.Random(5))
        known = lf.info(c, *TOP, section='owners')['owners_known']
        before = state(c)
        self.assertEqual(c.call(*at('S//A/B', 'u1'), 'GET', 'age'), b'S//B')
        if how == 'save':
            c.call(*TOP, 'SAVE')
            run.stop(signal.SIGKILL)
        elif how == 'bgsave':
            c.call(*TOP, 'BGSAVE')
            wait(lambda: lf.info(c, *TOP)['rdb_bgsave_in_progress'] == '0')
            run.stop(signal.SIGKILL)
        elif how == 'shutdown':
            self.assertEqual(run.stop(signal.SIGTERM), 0)
        if how == 'reload':
            self.assertEqual(c.call(*TOP, 'DEBUG', 'RELOAD'), 'OK')
            self.assertEqual(lf.info(c, *TOP, section='owners')['owners_known'], known)
        else:
            c = self.up(run)
            self.assertEqual(int(lf.info(c, *TOP, section='owners')['owners_known']), int(known) - 1)
        after = state(c)
        self.assertEqual(before['scopes'], after['scopes'])
        self.assertEqual(before['digest'], after['digest'])
        self.assertEqual(before['listed'], after['listed'])
        self.assertEqual(before['owners'], after['owners'])
        for reader in READERS:
            self.assertEqual(before['views'][reader], after['views'][reader], 'reader %r after %s' % (reader, how))
        self.assertEqual(c.call(*at('S//A/B', 'u1'), 'GET', 'age'), b'S//B')
        self.assertEqual(c.call(*TOP, 'OWNERS', 'QUOTA', 'u9')[0], 70000)

    def test_save_and_restart(self):
        self.check('save')

    def test_bgsave_and_restart(self):
        self.check('bgsave')

    def test_shutdown_and_restart(self):
        self.check('shutdown')

    def test_debug_reload(self):
        self.check('reload')

    def test_owner_mode_without_a_scheme(self):
        run = self.run_server(OWNERS + SEEDS + ('--save', ''))
        c = self.up(run)
        top = ('LABEL', 'AS', 'UNCLASSIFIED', 'SHARED')
        c.call('LABEL', 'AS', 'UNCLASSIFIED', 'OWNER', 'u1', 'SET', 'k', 'mine')
        c.call(*top, 'SET', 'k', 'shared')
        c.call(*top, 'OWNERS', 'QUOTA', 'u1', 'LIMIT', 123456)
        before = c.call(*top, 'DEBUG', 'DIGEST-SCOPES')
        c.call(*top, 'SAVE')
        run.stop(signal.SIGKILL)
        c = self.up(run)
        self.assertEqual(c.call(*top, 'DEBUG', 'DIGEST-SCOPES'), before)
        self.assertEqual(c.call('LABEL', 'AS', 'UNCLASSIFIED', 'OWNER', 'u1', 'GET', 'k'), b'mine')
        self.assertEqual(c.call('LABEL', 'AS', 'UNCLASSIFIED', 'OWNER', 'u2', 'GET', 'k'), b'shared')
        self.assertEqual(c.call(*top, 'OWNERS', 'QUOTA', 'u1')[0], 123456)


class Reload(Base):
    def test_reload_keeps_owner_numbers_for_live_connections(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*TOP, 'ACL', 'SETUSER', 'alice', 'on', 'nopass', '~*', '&*', '+@all', 'clearance:C', 'owner:u1')
        for name in ('u5', 'u1', 'u7'):
            c.call(*at('U', name), 'SET', 'k', name)
        before = owners_listed(c)
        alice = run.client()
        alice.call('AUTH', 'alice', 'x')
        self.assertEqual(alice.call('MULTI'), 'OK')
        self.assertEqual(alice.call('SET', 'queued', 'from-alice'), 'QUEUED')
        self.assertEqual(c.call(*TOP, 'DEBUG', 'RELOAD'), 'OK')
        self.assertEqual(alice.call('EXEC'), ['OK'])
        self.assertEqual(c.call(*at('C', 'u1'), 'GET', 'queued'), b'from-alice')
        self.assertIsNone(c.call(*at('C', 'u5'), 'GET', 'queued'))
        self.assertEqual(owners_listed(c), before)
        self.assertEqual(alice.call('GET', 'k'), b'u1')


class Twins(Base):
    arguments = SCHEME + OWNERS + SEEDS + ('--save', '', '--owner-partitions-max', '6')

    def world(self, hidden, expire=False, sensitive=False):
        directory = self.dir / ('w-%d-%d-%d' % (hidden, expire, sensitive))
        directory.mkdir()
        run = self.run_server(directory=directory)
        c = self.up(run)
        rng = random.Random(4)
        for i in range(10):
            label = rng.choice(('U', 'C'))
            owner = rng.choice(('u1', ''))
            c.call(*at(label, owner), 'SET', 'n%d' % i, 'v%d' % i, 'NX')
        if sensitive:
            c.call(*at('C', 'u1'), 'SET', 'extra', 'other')
        if hidden:
            noise = random.Random(8)
            ttl = ('PX', 1200) if expire else ()
            for step in range(50):
                label = noise.choice(('U', 'C', 'S//A'))
                name = noise.choice(['n%d' % i for i in range(10)] + ['own%d' % i for i in range(5)])
                c.send(*at(label, noise.choice(('u2', 'u3'))), 'SET', name, 'secret', 'NX', *ttl)
                c.reply()
            if not expire:
                c.call(*TOP, 'OWNERS', 'QUOTA', 'u2', 'LIMIT', 900000)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        if expire:
            time.sleep(1.5)
        c = self.up(run)
        me = at('C', 'u1')
        corpus = list(full_scan(c, me))
        corpus += [c.call(*me, 'DBSIZE'), sorted(c.call(*me, 'KEYS', '*')), [c.call(*me, 'RANDOMKEY') for _ in range(5)]]
        for name in ['n%d' % i for i in range(10)] + ['own%d' % i for i in range(5)]:
            corpus.append((c.call(*me, 'EXISTS', name), c.call(*me, 'TYPE', name), c.call(*me, 'GET', name), c.call(*me, 'LABEL', 'OF', name)))
        corpus.append([l for l in c.call(*me, 'INFO', 'keyspace').decode().splitlines() if l.startswith('db')])
        corpus.append(sorted(lf.info(c, *me).items()))
        if expire or not hidden:
            corpus.append(sorted(lf.info(c, *TOP, section='owners').items()))
            outcome = []
            for label in ('U', 'C', 'U;VETTED', 'C;VETTED', 'U'):
                try:
                    outcome.append(c.call(*at(label, 'u1'), 'SET', 'probe', 1))
                except ServerError as error:
                    outcome.append(str(error))
            corpus.append(outcome)
        run.stop(signal.SIGKILL)
        return corpus

    def test_another_users_data_changes_nothing_after_a_restart(self):
        quiet = self.world(False)
        noisy = self.world(True)
        self.assertEqual(quiet[:-2], noisy)

    def test_another_users_expired_data_leaves_nothing(self):
        self.assertEqual(self.world(False), self.world(True, expire=True))

    def test_a_visible_difference_shows(self):
        self.assertNotEqual(self.world(False), self.world(False, sensitive=True))


class Forget(Base):
    def test_the_sequence_fields_and_the_coalesced_snapshot(self):
        run = self.run_server(SCHEME + OWNERS + ('--save', '3600 100000', '--rdbcompression', 'no', '--owners-forget-snapshot-delay', '1'))
        c = self.up(run)
        c.call(*at('C', 'forgotten-user-77'), 'SET', 'k', 'marker-value-31337')
        c.call(*at('C', 'kept-user'), 'SET', 'k', 'kept-value')
        c.call(*TOP, 'SAVE')
        data = (self.dir / 'dump.rdb').read_bytes()
        self.assertIn(b'forgotten-user-77', data)
        self.assertIn(b'marker-value-31337', data)
        saves = int(lf.info(c, *TOP)['rdb_saves'])
        first = as_map(c.call(*TOP, 'OWNERS', 'FORGET', 'forgotten-user-77'))
        self.assertEqual(first[b'sequence'], 1)
        self.assertEqual(first[b'keys'], 1)
        second = as_map(c.call(*TOP, 'OWNERS', 'FORGET', 'never-seen'))
        self.assertEqual(second, {b'keys': 0, b'elements': 0, b'bytes': 0, b'sequence': 2})
        fields = lf.info(c, *TOP)
        self.assertEqual((fields['owners_forget_sequence'], fields['owners_forget_in_snapshot'], fields['owners_forget_in_aof']), ('2', '0', '2'))
        wait(lambda: lf.info(c, *TOP)['owners_forget_in_snapshot'] == '2', 20)
        wait(lambda: lf.info(c, *TOP)['rdb_bgsave_in_progress'] == '0')
        self.assertEqual(int(lf.info(c, *TOP)['rdb_saves']), saves + 1)
        data = (self.dir / 'dump.rdb').read_bytes()
        self.assertNotIn(b'forgotten-user-77', data)
        self.assertNotIn(b'marker-value-31337', data)
        self.assertIn(b'kept-value', data)
        self.assertEqual(lf.header_fields(data)[-2][0], 2)
        time.sleep(1.5)
        self.assertEqual(int(lf.info(c, *TOP)['rdb_saves']), saves + 1)
        low = lf.info(c, *at('C', 'kept-user'))
        self.assertNotIn('owners_forget_sequence', low)
        run.stop(signal.SIGKILL)
        c = self.up(run)
        fields = lf.info(c, *TOP)
        self.assertEqual((fields['owners_forget_sequence'], fields['owners_forget_in_snapshot']), ('2', '2'))

    def test_a_zero_delay_leaves_the_snapshot_to_the_operator(self):
        run = self.run_server(SCHEME + OWNERS + ('--save', '3600 100000', '--owners-forget-snapshot-delay', '0'))
        c = self.up(run)
        c.call(*at('C', 'u1'), 'SET', 'k', 'v')
        c.call(*TOP, 'SAVE')
        saves = int(lf.info(c, *TOP)['rdb_saves'])
        c.call(*TOP, 'OWNERS', 'FORGET', 'u1')
        time.sleep(2.2)
        fields = lf.info(c, *TOP)
        self.assertEqual((int(fields['rdb_saves']), fields['owners_forget_in_snapshot']), (saves, '0'))
        c.call(*TOP, 'BGSAVE')
        wait(lambda: lf.info(c, *TOP)['owners_forget_in_snapshot'] == '1')

    def test_without_snapshots_the_field_reads_the_sequence(self):
        run = self.run_server(SCHEME + OWNERS + ('--save', ''))
        c = self.up(run)
        c.call(*TOP, 'OWNERS', 'FORGET', 'u1')
        fields = lf.info(c, *TOP)
        self.assertEqual((fields['owners_forget_sequence'], fields['owners_forget_in_snapshot'], fields['owners_forget_in_aof']), ('1', '1', '1'))


class Access(Base):
    arguments = SCHEME + OWNERS + ('--save', '3600 100000')

    def test_only_the_flush_of_everything_saves_or_stops_a_snapshot(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*TOP, 'ACL', 'SETUSER', 'bob', 'on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'owner:u1')
        for owner in ('u1', 'u2', ''):
            c.call(*at('C', owner), 'SET', 'k', owner or 'shared')
        saves = int(lf.info(c, *TOP)['rdb_saves'])
        bob = run.client()
        bob.call('AUTH', 'bob', 'x')
        self.assertEqual(bob.call('FLUSHALL'), 'OK')
        self.assertEqual(c.call(*at('S//A/B', 'u1'), 'FLUSHALL'), 'OK')
        self.assertEqual(int(lf.info(c, *TOP)['rdb_saves']), saves)
        self.assertEqual(c.call(*at('C', 'u2'), 'GET', 'k'), b'u2')
        c.call(*TOP, 'CONFIG', 'SET', 'rdb-key-save-delay', 200000)
        c.call(*TOP, 'BGSAVE')
        self.assertEqual(bob.call('FLUSHALL'), 'OK')
        self.assertEqual(lf.info(c, *TOP)['rdb_bgsave_in_progress'], '1')
        c.call(*TOP, 'CONFIG', 'SET', 'rdb-key-save-delay', 0)
        self.assertEqual(c.call(*TOP, 'FLUSHALL'), 'OK')
        self.assertEqual(lf.info(c, *TOP)['rdb_bgsave_in_progress'], '1')
        c.call(*TOP, 'ACL', 'SETUSER', 'ops', 'on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*', 'owner-operator')
        ops = run.client()
        ops.call('AUTH', 'ops', 'x')
        self.assertEqual(ops.call('LABEL', 'AS', 'S//A/B', 'FLUSHALL'), 'OK')
        self.assertEqual(lf.info(c, *TOP)['rdb_bgsave_in_progress'], '0')
        self.assertEqual(int(lf.info(c, *TOP)['rdb_saves']), saves + 2)

    def test_users_and_non_operators_are_below_top(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*TOP, 'ACL', 'SETUSER', 'bob', 'on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'owner:u1')
        bob = run.client()
        bob.call('AUTH', 'bob', 'x')
        for command in (('SAVE',), ('BGSAVE',), ('SHUTDOWN', 'NOSAVE'), ('DEBUG', 'RELOAD'), ('CONFIG', 'SET', 'save', '')):
            self.assertEqual(error_of(bob, *command), OPERATOR_ERROR, command)
        self.assertEqual(bob.call('LASTSAVE'), c.call(*at('U', 'u1'), 'LASTSAVE'))
        self.assertEqual(lf.info(bob)['rdb_last_save_time'], '0')
        bob.call('SET', 'k', 'v')
        self.assertTrue(bob.call('DUMP', 'k').startswith(b'\x00'))
        self.assertEqual(bob.call('RESTORE', 'k2', 0, bob.call('DUMP', 'k')), 'OK')
        self.assertEqual(c.call(*at('S//A/B', 'u1'), 'GET', 'k2'), b'v')
        self.assertIsNone(c.call(*at('S//A/B', 'u2'), 'GET', 'k2'))


class Caps(Base):
    def test_owner_partition_cap_is_enforced_at_load(self):
        run = self.run_server()
        c = self.up(run)
        for owner in ('u1', 'u2', 'u3'):
            c.call(*at('C', owner), 'SET', 'k', owner)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        self.assertIn('owner-partitions-max', self.refused(self.run_server(SCHEME + OWNERS + ('--save', '', '--owner-partitions-max', '2'))))
        c = self.up(self.run_server(SCHEME + OWNERS + ('--save', '', '--owner-partitions-max', '3')))
        self.assertEqual(c.call(*at('C', 'u3'), 'GET', 'k'), b'u3')


def crafted(*parts, owners=(('u1', 0), ('u2', 0)), scheme=SCHEME_BLOB, flags=lf.LABELLED | lf.OWNERS):
    return lf.seal(lf.aux_head() + lf.header_record(flags, scheme, (), owners) + b''.join(parts))


P = lf.partition_record
K = lf.string_key
SEL = lf.select

CASES = [
    ('owner text', crafted(owners=[('a b', 0)]), 'owner 1 has an invalid id'),
    ('owner star', crafted(owners=[('*', 0)]), 'owner 1 has an invalid id'),
    ('owner repeat', crafted(owners=[('u1', 0), ('u1', 5)]), 'owner 2 repeats an earlier owner'),
    ('owner beyond', crafted(SEL(0), P(0, 3), K('k', 'v')), 'names owner 3 beyond its owner table'),
    ('owner order missing', crafted(SEL(0, 2), P(2, 1), K('n', 'a'), P(3, 1), K('n', 'b')), "holds key 'n' in two or more partitions"),
    ('owner order wrong owner', crafted(SEL(0, 2), P(2, 1), K('n', 'a'), P(3, 1), K('n', 'b'), lf.order_record([(2, 'n', [2, 3])])), 'names a partition the file does not hold'),
    ('reserved level', crafted(scheme=lf.eslt(['U', 'C', 'S', 'SHARED'], ['A', 'B'], ['WEB', 'VETTED'])), 'which owner mode reserves'),
    ('owner quota', crafted(owners=[('u1', 1 << 63)]), 'invalid owner quota'),
    ('owner count', lf.seal(lf.aux_head() + lf.record(lf.uint(1), lf.uint(1), lf.uint(3), lf.text(SCHEME_BLOB), lf.uint(0), lf.uint(1 << 40))), 'more owners than owner ids exist'),
]


class Validation(Base):
    arguments = SCHEME + OWNERS + ('--save', '')

    def test_every_crafted_owner_failure_is_refused(self):
        for name, data, words in CASES:
            directory = self.dir / name.replace(' ', '-')
            directory.mkdir()
            (directory / 'dump.rdb').write_bytes(data)
            text = self.refused(self.run_server(directory=directory))
            self.assertIn(words, text, name)
            self.assertNotIn("'u1'", text)

    def test_owner_copies_follow_their_order_and_unused_owners_are_dropped(self):
        for order, want in (([2, 3], b'a'), ([3, 2], b'b')):
            data = crafted(SEL(0, 3), P(2, 1), K('n', 'a'), P(3, 1), K('n', 'b'), P(0, 2), K('gone', 'x', 1000), lf.order_record([(1, 'n', order)]))
            (self.dir / 'dump.rdb').write_bytes(data)
            run = self.run_server()
            c = self.up(run)
            self.assertEqual(c.call(*at('S//A/B', 'u1'), 'GET', 'n'), want)
            owners = lf.info(c, *TOP, section='owners')
            self.assertEqual((owners['owners_known'], owners['owners_holding_data'], owners['owner_partitions']), ('1', '1', '2'))
            run.stop(signal.SIGKILL)


class Runtime(Base):
    def test_turning_owner_mode_on_writes_an_empty_owner_snapshot(self):
        run = self.run_server(SCHEME + ('--save', '3600 1'))
        code, text = run.start()
        self.assertIsNone(code, text)
        c = run.client()
        c.call('ACL', 'SETUSER', 'default', 'clearance:*', 'trust:*')
        c.call('LABEL', 'AS', 'C', 'SET', 'k', 'v')
        c.call('LABEL', 'AS', 'S//A/B', 'SAVE')
        self.assertEqual(lf.header_fields((self.dir / 'dump.rdb').read_bytes())[2][0], lf.LABELLED)
        c.call('LABEL', 'AS', 'S//A/B', 'FLUSHALL')
        self.assertEqual(c.call('LABEL', 'AS', 'S//A/B', 'CONFIG', 'SET', 'owners', 'yes'), 'OK')
        self.assertEqual(lf.header_fields((self.dir / 'dump.rdb').read_bytes())[2][0], lf.LABELLED | lf.OWNERS)
        run.stop()
        c = self.up(self.run_server(SCHEME + OWNERS + ('--save', '3600 1')))
        self.assertEqual(c.call(*TOP, 'DBSIZE'), 0)


class Golden(Base):
    arguments = SCHEME + OWNERS + SEEDS + ('--save', '', '--rdbcompression', 'no')
    FIXTURE = FIXTURES / 'owner-snapshot.hex'

    def build(self, c):
        c.call(*at('S//B', 'u1'), 'SET', 'name', 'right')
        c.call(*at('S//A', 'u1'), 'SET', 'name', 'left')
        c.call(*at('U'), 'SET', 'name', 'shared')
        c.call(*at('C', 'u2'), 'RPUSH', 'list', 'a', 'b')
        c.call(*TOP, 'OWNERS', 'QUOTA', 'u3', 'LIMIT', 5000)

    def test_the_owner_snapshot_has_its_fixed_bytes(self):
        run = self.run_server()
        c = self.up(run)
        self.build(c)
        c.call(*TOP, 'SAVE')
        got = lf.access_bytes(lf.without_seed((self.dir / 'dump.rdb').read_bytes()))
        if WRITE_FIXTURES:
            FIXTURES.mkdir(exist_ok=True)
            self.FIXTURE.write_text(got.hex() + '\n')
        self.assertEqual(got.hex(), self.FIXTURE.read_text().strip())

    def test_the_fixed_owner_bytes_load(self):
        (self.dir / 'dump.rdb').write_bytes(lf.seal(lf.aux_head() + bytes.fromhex(self.FIXTURE.read_text().strip())))
        c = self.up(self.run_server())
        self.assertEqual(c.call(*at('S//A/B', 'u1'), 'GET', 'name'), b'right')
        self.assertEqual(c.call(*at('S//A/B', 'u2'), 'GET', 'name'), b'shared')
        self.assertEqual(c.call(*at('C', 'u2'), 'LRANGE', 'list', 0, -1), [b'a', b'b'])
        self.assertEqual(c.call(*TOP, 'OWNERS', 'QUOTA', 'u3')[0], 5000)


class MidLoad(Base):
    arguments = SCHEME + OWNERS + SEEDS + ('--save', '', '--rdbcompression', 'no')

    def saved(self):
        run = self.run_server()
        c = self.up(run)
        for i in range(1200):
            c.call(*at('C', 'u1'), 'SET', 'k%d' % i, 'v' * 1000)
        for i in range(20):
            c.call(*at('U', 'u2'), 'SET', 'k%d' % i, 'w' * 1000)
            c.call(*at('C'), 'SET', 's%d' % i, 'x' * 1000)
        used = as_map(c.call(*TOP, 'OWNERS', 'INFO', 'u1'))[b'bytes']
        c.call(*TOP, 'OWNERS', 'QUOTA', 'u1', 'LIMIT', used + 40000)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        return run

    def facts(self, c):
        out = {'scopes': c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), 'owners': lf.info(c, *TOP, section='owners'),
               'u1': c.call(*TOP, 'OWNERS', 'INFO', 'u1'), 'u2': c.call(*TOP, 'OWNERS', 'INFO', 'u2'),
               'quota': c.call(*TOP, 'OWNERS', 'QUOTA', 'u1')}
        admitted = 0
        while admitted < 200:
            try:
                c.call(*at('C', 'u1'), 'SET', 'more%d' % admitted, 'm' * 1000)
            except ServerError as error:
                self.assertIn('OOM', str(error))
                break
            admitted += 1
        out['admitted'] = admitted
        c.call(*at('C', 'u1'), 'FLUSHALL')
        out['flushed'] = c.call(*TOP, 'OWNERS', 'INFO', 'u1')
        out['after flush'] = lf.info(c, *TOP, section='owners')
        return out

    def probe(self, run, c):
        c.call('ACL', 'SETUSER', 'default', *OPERATOR)
        c.call(*TOP, 'ACL', 'SETUSER', 'alice', 'on', 'nopass', '~*', '&*', '+@all', 'clearance:C', 'owner:u1')
        self.assertTrue(lf.loading(c, *TOP))
        self.assertEqual(c.call(*TOP, 'ECHO', 'during the load'), b'during the load')
        other = run.client()
        self.assertEqual(other.call('AUTH', 'alice', 'x'), 'OK')
        self.assertTrue(other.call('HELLO', 2))
        self.assertEqual(other.call('ECHO', 'as a user'), b'as a user')
        self.assertIn(b'loading:', other.call('INFO', 'persistence'))
        self.assertTrue(error_of(c, *TOP, 'DEBUG', 'DIGEST-SCOPES').startswith('LOADING'))
        self.assertTrue(error_of(c, *TOP, 'CONFIG', 'SET', 'owners', 'no').startswith('LOADING'))
        self.assertTrue(lf.loading(c, *TOP))
        lf.wait_loaded(c, *TOP)

    def test_commands_served_during_the_load_change_no_accounting(self):
        run = self.saved()
        clean = self.facts(self.up(run))
        run.stop(signal.SIGKILL)
        run = self.saved()
        c = run.launch(SLOW)
        self.probe(run, c)
        self.assertEqual(self.facts(c), clean)
        self.assertGreater(clean['admitted'], 0)
        self.assertLess(clean['admitted'], 200)

    def test_a_key_loaded_after_a_served_command_still_expires(self):
        run = self.run_server()
        c = self.up(run)
        for i in range(1200):
            c.call(*at('C', 'u1'), 'SET', 'k%d' % i, 'v' * 1000)
        c.call(*TOP, 'SAVE')
        rows = [r for r in lf.records((self.dir / 'dump.rdb').read_bytes()) if r[0] == 'key']
        data = (self.dir / 'dump.rdb').read_bytes()
        last = data[rows[-1][1]:rows[-1][2]]
        name = last[2:2 + last[1]].decode()
        c.call(*at('C', 'u1'), 'PEXPIREAT', name, int(time.time() * 1000) + 9000)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        c = run.launch(SLOW)
        self.probe(run, c)
        fields = lf.info(c, *TOP)
        self.assertEqual(fields['rdb_last_load_keys_expired'], '0')
        wait(lambda: lf.info(c, *TOP, section='stats')['expired_keys'] == '1', 40)
        self.assertEqual(as_map(c.call(*TOP, 'OWNERS', 'INFO', 'u1'))[b'keys'], 1199)

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
            c.call(*at('C', 'u1'), 'ECHO', 'x')
        self.assertGreater(samples, 0)
        self.assertEqual(fields['rdb_last_load_keys_loaded'], '1240')
        self.assertNotIn('Sanitizer', run.log())

    def test_an_owner_a_connection_used_during_the_load_is_kept(self):
        keys = [K('k%d' % i, 'v' * 1000) for i in range(1200)]
        data = crafted(SEL(0, 1201), P(1, 1), *keys, P(1, 2), K('gone', 'x', 1000), owners=(('u1', 0), ('u5', 0)))
        (self.dir / 'dump.rdb').write_bytes(data)
        run = self.run_server()
        c = run.launch(SLOW)
        c.call('ACL', 'SETUSER', 'default', *OPERATOR)
        c.call(*TOP, 'ACL', 'SETUSER', 'alice', 'on', 'nopass', '~*', '&*', '+@all', 'clearance:C', 'owner:u5')
        alice = run.client()
        self.assertEqual(alice.call('AUTH', 'alice', 'x'), 'OK')
        self.assertEqual(alice.call('MULTI'), 'OK')
        self.assertTrue(lf.loading(c, *TOP))
        lf.wait_loaded(c, *TOP)
        self.assertEqual(alice.call('SET', 'q', 'from-alice'), 'QUEUED')
        self.assertEqual(alice.call('EXEC'), ['OK'])
        self.assertEqual(c.call(*at('C', 'u5'), 'GET', 'q'), b'from-alice')
        self.assertIsNone(c.call(*at('C', 'u1'), 'GET', 'q'))

    def test_without_served_commands_unused_owners_are_dropped(self):
        keys = [K('k%d' % i, 'v') for i in range(20)]
        data = crafted(SEL(0, 21), P(1, 1), *keys, P(1, 2), K('gone', 'x', 1000), owners=(('u1', 0), ('u5', 0)))
        (self.dir / 'dump.rdb').write_bytes(data)
        c = self.up(self.run_server())
        self.assertEqual(lf.info(c, *TOP, section='owners')['owners_known'], '1')


class ForgetShutdown(Base):
    arguments = SCHEME + OWNERS + ('--save', '', '--rdbcompression', 'no')

    def forgotten(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*at('C', 'forgotten-user-77'), 'SET', 'k', 'marker-value-31337')
        c.call(*at('C', 'kept-user'), 'SET', 'k', 'kept-value')
        c.call(*TOP, 'SAVE')
        self.assertEqual(as_map(c.call(*TOP, 'OWNERS', 'FORGET', 'forgotten-user-77'))[b'sequence'], 1)
        return run, c

    def test_a_clean_shutdown_saves_a_forget_the_snapshot_lacks(self):
        run, c = self.forgotten()
        self.assertEqual(run.stop(signal.SIGTERM), 0)
        data = (self.dir / 'dump.rdb').read_bytes()
        self.assertNotIn(b'forgotten-user-77', data)
        self.assertNotIn(b'marker-value-31337', data)
        self.assertIn(b'kept-value', data)
        self.assertEqual(lf.header_fields(data)[-2][0], 1)
        c = self.up(run)
        fields = lf.info(c, *TOP)
        self.assertEqual((fields['owners_forget_sequence'], fields['owners_forget_in_snapshot']), ('1', '1'))
        self.assertIsNone(c.call(*at('C', 'forgotten-user-77'), 'GET', 'k'))
        self.assertEqual(c.call(*at('C', 'kept-user'), 'GET', 'k'), b'kept-value')

    def test_shutdown_nosave_leaves_the_file_and_warns(self):
        run, c = self.forgotten()
        c.send(*TOP, 'SHUTDOWN', 'NOSAVE')
        self.assertEqual(run.process.wait(timeout=20), 0)
        run.process = None
        self.assertIn(b'marker-value-31337', (self.dir / 'dump.rdb').read_bytes())
        self.assertIn('Exiting without a save although OWNERS FORGET ran after the last snapshot', run.log())


class OwnerCorruption(Base):
    arguments = SCHEME + OWNERS + ('--save', '', '--rdbcompression', 'no')

    def sample(self):
        run = self.run_server()
        c = self.up(run)
        c.call(*at('S//A', 'u1'), 'SET', 'n', 'a')
        c.call(*at('S//B', 'u1'), 'SET', 'n', 'b')
        c.call(*at('U'), 'SET', 'n', 'u')
        c.call(*at('C', 'u2'), 'RPUSH', 'l', 1, 2)
        c.call(*at('U'), 'VADD', 'v', 'VALUES', 2, 1, 0, 'x', 'SETATTR', '{"a":1}')
        c.call(*at('C', 'u2'), 'VADD', 'v', 'VALUES', 2, 0, 1, 'y')
        c.call(*at('S//A', 'u1'), 'VADD', 'w', 'VALUES', 2, 1, 1, 'x')
        c.call(*TOP, 'OWNERS', 'QUOTA', 'u3', 'LIMIT', 5000)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        return (self.dir / 'dump.rdb').read_bytes()

    def outcome(self, data, index):
        directory = self.dir / ('case-%d' % index)
        directory.mkdir()
        (directory / 'dump.rdb').write_bytes(data)
        run = self.run_server(directory=directory)
        code, text = run.start()
        if code is None:
            c = run.client()
            c.call('ACL', 'SETUSER', 'default', *OPERATOR)
            c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
            for reader in READERS:
                c.call(*at(*reader), 'GET', 'n')
                for key in ('v', 'w'):
                    lf.vector_reads(c, at(*reader), key, 2, ['x', 'y'])
            lf.answers(c, [(*at('C', 'u2'), 'VADD', 'v', 'VALUES', 2, 0.5, 0.5, 'z'), (*at('U'), 'VREM', 'v', 'x'),
                           (*at('S//A', 'u1'), 'VADD', 'w', 'VALUES', 2, 0, 1, 'q'), (*TOP, 'DEBUG', 'DIGEST-SCOPES')])
            self.assertEqual(run.stop(signal.SIGTERM), 0)
            return 'loaded'
        self.assertEqual(code, 1, 'case %d: %s' % (index, text[-2000:]))
        self.assertNotIn('Sanitizer', text)
        self.assertNotIn("'u1'", text)
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

    def test_flags_that_disagree_with_the_scheme_are_refused(self):
        blob = lf.eslt(['UNCLASSIFIED', 'C', 'S'], ['A', 'B'], [], [(2, 0, (0, 1))])
        data = lf.seal(lf.aux_head() + lf.header_record(lf.OWNERS, blob, (), [('u1', 0)]) + SEL(0, 1) + P(1, 1) + K('k', 'top-secret'))
        (self.dir / 'dump.rdb').write_bytes(data)
        text = self.refused(self.run_server(OWNERS + ('--save', '')))
        self.assertIn('mode flags do not match its label scheme', text)


class OwnerHiddenCopies(Base):
    arguments = SCHEME + OWNERS + SEEDS + ('--save', '')
    READER = ('C', 'u1')
    VISIBLE = (('U', 'u1'), ('C', 'u1'), ('U', ''), ('C', ''))
    HIDDEN = (('S//A', 'u1'), ('C', 'u2'), ('U', 'u3'), ('S//B', ''), ('C//A', ''), ('C//B', 'u1'))
    NAMES = ['n%d' % i for i in range(10)]

    def script(self):
        rng = random.Random(31)
        ops = []
        for step in range(220):
            scope = rng.choice(self.VISIBLE + self.HIDDEN)
            name = rng.choice(self.NAMES)
            r = rng.random()
            if r < 0.6:
                ops.append((scope, ('SET', name, 'v|%s:%s|%d' % (scope[0], scope[1], step))))
            elif r < 0.7:
                ops.append((scope, ('DEL', name)))
            elif r < 0.85:
                ops.append((scope, ('RPUSH', 'l' + name, step)))
            else:
                ops.append((scope, ('HSET', 'h' + name, 'f%d' % (step % 4), step)))
        return ops

    def ages(self, c):
        before = after = 0
        for name in self.NAMES:
            seen = c.call(*at(*self.READER), 'GET', name)
            if seen is None:
                continue
            step = int(seen.split(b'|')[2])
            for scope in self.HIDDEN:
                own = c.call(*at(*scope), 'GET', name)
                if own is not None and own.split(b'|')[1] == ('%s:%s' % scope).encode():
                    if int(own.split(b'|')[2]) < step:
                        before += 1
                    else:
                        after += 1
        return before, after

    def corpus(self, c):
        me = at(*self.READER)
        keys, cursors = full_scan(c, me)
        out = [keys, cursors, c.call(*me, 'DBSIZE'), sorted(c.call(*me, 'KEYS', '*'))]
        for pre in ('', 'l', 'h'):
            for name in self.NAMES:
                k = pre + name
                kind = c.call(*me, 'TYPE', k)
                out.append((k, kind, c.call(*me, 'EXISTS', k), c.call(*me, 'PEXPIRETIME', k), c.call(*me, 'LABEL', 'OF', k),
                            c.call(*me, 'DUMP', k), read_value(c, me, k, kind)))
        out.append([c.call(*me, 'RANDOMKEY') for _ in range(6)])
        out.append([l for l in c.call(*me, 'INFO', 'keyspace').decode().splitlines() if l.startswith('db')])
        out.append(sorted(lf.info(c, *me).items()))
        return out

    def world(self, hidden, expire=False):
        directory = self.dir / ('copies-%d-%d' % (hidden, expire))
        directory.mkdir()
        run = self.run_server(directory=directory)
        c = self.up(run)
        for scope, op in self.script():
            if scope in self.HIDDEN:
                if not hidden or (expire and op[0] != 'SET'):
                    continue
                if expire:
                    op = op + ('PX', 1200)
            try:
                c.call(*at(*scope), *op)
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


vadd = lf.vadd
OVFAR = FAR - 4000
OVKEYS = (('vs', 4), ('two', 4), ('vbin', 16), ('tv', 4), ('gone', 4))
OVDOOMED = (('tv', 'S//A', 'u1'), ('gone', 'C;VETTED', 'u3'))
OVREADERS = READERS + (('U', 'u2'), ('C;VETTED', 'u3'), ('U;VETTED', ''), ('S//A/B', 'u2'))
OVPLAN = ((('U', ''), 100, 0, 40), (('C', ''), 520, 0, 20), (('C', 'u1'), 100, 0, 20), (('S//A', 'u1'), 520, 0, 20),
          (('U', 'u1'), 520, 220, 0), (('U', 'u2'), 300, 0, 20), (('S//B', 'u2'), 520, 400, 20), (('C;VETTED', 'u3'), 140, 0, 0))


def ov_script(seed):
    rng = random.Random(seed)
    ops = [(('U;VETTED', ''), vadd(key, rng, dim, 'anchor%d' % i, *(('BIN',) if key == 'vbin' else ()))) for key, dim in OVKEYS if key not in ('two', 'gone') for i in range(2)]
    chains = []
    for k, (scope, n, _, shared) in enumerate(OVPLAN):
        chains.append([(scope, vadd('vs', rng, 4, 'p%d-%d' % (k, i), *(('SETATTR', '{"a":%d}' % (i % 7)) if i % 3 == 0 else ()))) for i in range(n - shared)])
    for i in range(20):
        first = [(('C', 'u1'), vadd('vs', rng, 4, 'e%d' % i)), (('U', 'u2'), vadd('vs', rng, 4, 'e%d' % i, 'SETATTR', '{"a":%d}' % i))]
        rng.shuffle(first)
        chains.append(first + [(('U', ''), vadd('vs', rng, 4, 'e%d' % i))])
    for i in range(20, 40):
        pair = [(('S//A', 'u1'), vadd('vs', rng, 4, 'e%d' % i)), (('S//B', 'u2'), vadd('vs', rng, 4, 'e%d' % i))]
        rng.shuffle(pair)
        chains.append(pair + [(('C', ''), vadd('vs', rng, 4, 'e%d' % i))])
    for i in range(40, 60):
        chains.append([(('U', ''), vadd('vs', rng, 4, 'e%d' % i))])
    for i in range(16):
        pair = [(('S//A', 'u1'), vadd('vs', rng, 4, 'h%d' % i, 'SETATTR', '{"a":%d}' % i)), (('S//B', 'u1'), vadd('vs', rng, 4, 'h%d' % i))]
        rng.shuffle(pair)
        chains.append(pair)
    ops += lf.interleave(rng, chains)
    for k, (scope, n, gone, shared) in enumerate(OVPLAN):
        names = ['p%d-%d' % (k, i) for i in range(n - shared)]
        rng.shuffle(names)
        ops += [(scope, ('VREM', 'vs', x)) for x in names[:gone]]
    twins = [op for op in ops if op[0] == ('C', '') and op[1][0] == 'VADD' and op[1][8].startswith('p1-')]
    for j, (scope, cmd) in enumerate(twins[:14]):
        ops.append((('C', ''), ('VADD', 'vs', 'VALUES', 4, *cmd[4:8], 'twin%d' % j)))
    twins = [op for op in ops if op[0] == ('S//A', 'u1') and op[1][0] == 'VADD' and op[1][8].startswith('p3-')]
    for j, (scope, cmd) in enumerate(twins[:10]):
        ops.append((('S//A', 'u1'), ('VADD', 'vs', 'VALUES', 4, *cmd[4:8], 'utwin%d' % j)))
    for owner, n in (('u1', 30), ('u2', 25), ('', 20)):
        ops += [(('C', owner), vadd('two', rng, 4, 'w%d' % i, 'SETATTR', '{"a":%d}' % i)) for i in range(n)]
    ops += [(('U', 'u3'), vadd('two', rng, 4, 'x%d' % i)) for i in range(10)]
    bits = random.Random(seed + 1)
    ops += [(('C', 'u1'), ('VADD', 'vbin', 'VALUES', 16, *[bits.choice(('1', '-1')) for _ in range(16)], 'b%d' % i, 'BIN')) for i in range(600)]
    ops += [(('U', ''), ('VADD', 'vbin', 'VALUES', 16, *[bits.choice(('1', '-1')) for _ in range(16)], 'c%d' % i, 'BIN')) for i in range(60)]
    ops += [(('S//A', 'u1'), vadd('tv', rng, 4, 't%d' % i)) for i in range(30, 90)]
    ops += [(('U', ''), vadd('tv', rng, 4, 't%d' % i)) for i in range(50)]
    ops += [(('C', 'u2'), vadd('tv', rng, 4, 'v%d' % i)) for i in range(40)]
    ops += [(('C;VETTED', 'u3'), vadd('gone', rng, 4, 'g%d' % i)) for i in range(30)]
    ops.append((('U', 'u1'), ('PEXPIREAT', 'vs', OVFAR)))
    return ops


def ov_more(seed):
    rng = random.Random(seed)
    ops = [(('U', 'u1'), ('VREM', 'vs', 'p4-%d' % i)) for i in range(0, 520, 3)]
    ops += [(('U', 'u2'), vadd('vs', rng, 4, 'late-u2-%d' % i)) for i in range(250)]
    ops += [(('S//B', 'u2'), vadd('vs', rng, 4, 'late-sb-%d' % i)) for i in range(420)]
    ops += [(('C', 'u1'), vadd('vs', rng, 4, 'p2-%d' % i)) for i in range(0, 80, 4)]
    ops += [(('C', 'u1'), ('VSETATTR', 'vs', 'p2-%d' % i, '{"a":8}')) for i in range(1, 80, 4)]
    ops += [(('C', ''), ('VREM', 'vs', 'twin%d' % j)) for j in range(0, 14, 3)]
    ops += [(('S//A', 'u1'), ('VREM', 'vs', 'utwin%d' % j)) for j in range(0, 10, 2)]
    ops += [(('C', 'u4'), vadd('vs', rng, 4, 'late-u4-%d' % i)) for i in range(20)]
    ops += [(('C', 'u2'), vadd('two', rng, 4, 'late-w%d' % i)) for i in range(15)]
    ops += [(('U', ''), vadd('tv', rng, 4, 'late-t%d' % i)) for i in range(15)]
    ops += [(('C', 'u1'), ('VREM', 'vbin', 'b%d' % i)) for i in range(0, 600, 7)]
    return ops


def ov_apply(c, ops):
    return lf.answers(c, [(*at(*scope), *cmd) for scope, cmd in ops])


def ov_names(key):
    if key == 'vs':
        return ['e%d' % i for i in range(0, 60, 3)] + ['h%d' % i for i in range(16)] + ['p%d-%d' % (k, i) for k in range(8) for i in range(0, 520, 43)] + \
            ['twin%d' % i for i in range(0, 14, 2)] + ['utwin%d' % i for i in range(0, 10, 3)] + ['late-sb-%d' % i for i in range(0, 420, 60)] + ['nope']
    if key == 'two':
        return ['w%d' % i for i in range(0, 30, 3)] + ['x%d' % i for i in range(0, 10, 3)] + ['late-w2']
    if key == 'vbin':
        return ['b%d' % i for i in range(0, 600, 37)] + ['c%d' % i for i in range(0, 60, 9)]
    if key == 'tv':
        return ['t%d' % i for i in range(0, 90, 5)] + ['v%d' % i for i in range(0, 40, 7)] + ['late-t3']
    return ['g%d' % i for i in range(0, 30, 4)]


def ov_corpus(c, readers=OVREADERS, randoms=True, skip=()):
    return {(r, key): lf.vector_reads(c, at(*r), key, dim, ov_names(key), randoms) for r in readers for key, dim in OVKEYS if key not in skip}


def ov_wait(predicate, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError('condition not reached')


class OwnerVectorRoundTrip(Base):
    arguments = SCHEME + OWNERS + SEEDS + ('--save', '')

    def built(self, name):
        (self.dir / name).mkdir()
        run = self.run_server(directory=self.dir / name)
        c = self.up(run)
        for label in ('U', 'C'):
            c.call(*TOP, 'LABEL', 'QUOTA', label, 'LIMIT', 1 << 40)
        self.assertEqual([x for x in ov_apply(c, ov_script(51)) if isinstance(x, tuple)], [])
        return run, c

    def test_every_owner_partition_kind_reads_the_same_after_a_restart_and_after_further_writes(self):
        a, ca = self.built('restarted')
        b, cb = self.built('running')
        before = ov_corpus(ca, randoms=False, skip=('tv', 'gone'))
        owners = {n: owner_facts(ca, n) for n in ('u1', 'u2', 'u3')}
        for c in (ca, cb):
            for key, label, owner in OVDOOMED:
                self.assertEqual(c.call(*at(label, owner), 'PEXPIRE', key, 1000), 1)
        self.assertEqual(ca.call(*TOP, 'SAVE'), 'OK')
        a.stop(signal.SIGKILL)
        time.sleep(1.3)
        ca = self.up(a)
        self.assertEqual(lf.info(ca, *TOP)['rdb_last_load_keys_expired'], '2')
        for key, label, owner in OVDOOMED:
            cb.call(*at(label, owner), 'EXISTS', key)
        ov_wait(lambda: cb.call(*TOP, 'DEBUG', 'DIGEST-SCOPES') == ca.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'))
        self.assertEqual(ov_corpus(ca, randoms=False, skip=('tv', 'gone')), before)
        self.assertEqual(owner_facts(ca, 'u2'), owners['u2'])
        for n in ('u1', 'u2', 'u3'):
            self.assertEqual(owner_facts(ca, n), owner_facts(cb, n), n)
        self.assertEqual(ov_corpus(ca), ov_corpus(cb))
        self.assertEqual(ca.call(*TOP, 'DEBUG', 'DIGEST'), cb.call(*TOP, 'DEBUG', 'DIGEST'))
        more = ov_more(53)
        self.assertEqual(ov_apply(ca, more), ov_apply(cb, more))
        self.assertEqual(ov_corpus(ca), ov_corpus(cb))
        self.assertEqual(ca.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), cb.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'))
        for n in ('u1', 'u2', 'u3', 'u4'):
            self.assertEqual(owner_facts(ca, n), owner_facts(cb, n), n)
            used, running = as_map(ca.call(*TOP, 'OWNERS', 'INFO', n))[b'bytes'], as_map(cb.call(*TOP, 'OWNERS', 'INFO', n))[b'bytes']
            self.assertGreater(running, 1000, n)
            if n in [owner for _, _, owner in OVDOOMED]:
                self.assertLessEqual(abs(used - running), 1024, (n, used, running))
            else:
                self.assertEqual(used, running, n)
        for label in ('U', 'C'):
            used, running = ca.call(*TOP, 'LABEL', 'QUOTA', label)[1], cb.call(*TOP, 'LABEL', 'QUOTA', label)[1]
            self.assertGreater(running, 1000, label)
            self.assertEqual(used, running, label)

    def test_a_reload_keeps_every_owner_partition(self):
        a, c = self.built('reloaded')
        before = ov_corpus(c, randoms=False)
        scopes = c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
        self.assertEqual(c.call(*TOP, 'DEBUG', 'RELOAD'), 'OK')
        self.assertEqual(c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), scopes)
        self.assertEqual(ov_corpus(c, randoms=False), before)
        c.call(*TOP, 'BGSAVE')
        ov_wait(lambda: lf.info(c, *TOP)['rdb_bgsave_in_progress'] == '0')
        self.assertEqual(lf.info(c, *TOP)['rdb_last_bgsave_status'], 'ok')
        a.stop(signal.SIGKILL)
        c = self.up(a)
        self.assertEqual(c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), scopes)
        self.assertEqual(ov_corpus(c, randoms=False), before)


OV_VARYING = ('run_id', 'tcp_port', 'process_id', 'executable', 'config_file', 'listener0', 'server_time_usec', 'uptime_in_seconds',
              'uptime_in_days', 'lru_clock', 'io_threads_active', 'monotonic_clock')


class OwnerVectorTwins(Base):
    arguments = SCHEME + OWNERS + SEEDS + ('--save', '')
    READER = ('C', 'u1')
    VISIBLE = (('U', 'u1'), ('C', 'u1'), ('U', ''), ('C', ''))
    HIDDEN = (('C', 'u2'), ('U', 'u3'), ('S//A', 'u2'), ('C;VETTED', 'u3'))
    KEYS = ('k0', 'k1', 'k2', 'k3')
    NAMES = ['n%d' % i for i in range(30)]

    def script(self):
        rng = random.Random(37)
        ops = []
        for step in range(700):
            scope = rng.choice(self.VISIBLE + self.HIDDEN)
            key = rng.choice(self.KEYS)
            name = rng.choice(self.NAMES)
            r = rng.random()
            if r < 0.75:
                ops.append((scope, vadd(key, rng, 3, name, *(('SETATTR', '{"a":%d}' % (step % 6)) if step % 4 == 0 else ()))))
            elif r < 0.87:
                ops.append((scope, ('VREM', key, name)))
            else:
                ops.append((scope, ('VSETATTR', key, name, '{"a":%d}' % (step % 5))))
        bulk = [(('C', 'u1'), vadd('k0', rng, 3, 'big%d' % i)) for i in range(560)] + [(('C', 'u2'), vadd('k0', rng, 3, 'big%d' % i)) for i in range(540)] + \
            [(('U', 'u3'), vadd('k1', rng, 3, 'big%d' % i)) for i in range(530)] + [(('U', ''), vadd('k1', rng, 3, 'big%d' % i)) for i in range(150)]
        return lf.interleave(rng, [ops, bulk])

    def corpus(self, c):
        me = at(*self.READER)
        out = list(full_scan(c, me))
        out += [c.call(*me, 'DBSIZE'), sorted(c.call(*me, 'KEYS', '*')), [c.call(*me, 'RANDOMKEY') for _ in range(5)]]
        names = self.NAMES + ['big%d' % i for i in range(0, 560, 23)]
        for key in self.KEYS + ('k9',):
            out.append(lf.vector_reads(c, me, key, 3, names))
            out.append(lf.answers(c, [(*me, 'MEMORY', 'USAGE', key), (*me, 'DUMP', key), (*me, 'OBJECT', 'ENCODING', key), (*me, 'TTL', key)]))
        out.append([l for l in c.call(*me, 'INFO', 'keyspace').decode().splitlines() if l.startswith('db')])
        out.append(sorted((k, v) for k, v in lf.info(c, *me, section='everything').items() if k not in OV_VARYING))
        out.append(lf.answers(c, [(*me, 'DEBUG', 'DIGEST-SCOPES'), (*me, 'SAVE'), (*me, 'BGSAVE'), (*me, 'OWNERS', 'INFO', 'u1'),
                                  (*me, 'CONFIG', 'SET', 'save', '1 1')]))
        copies = []
        for key in self.KEYS:
            payload = c.call(*me, 'DUMP', key)
            if payload is not None:
                copies += [(*me, 'RESTORE', key + '-copy', 0, payload), (*me, 'VCARD', key + '-copy'), (*me, 'VEMB', key + '-copy', 'n3'), (*me, 'DEL', key + '-copy')]
        out.append(lf.answers(c, copies))
        return out

    def world(self, hidden, expire=False, sensitive=False):
        directory = self.dir / ('ov-%d-%d-%d' % (hidden, expire, sensitive))
        directory.mkdir()
        run = self.run_server(directory=directory)
        c = self.up(run)
        visible = []
        for scope, op in self.script():
            if scope in self.HIDDEN and not hidden:
                continue
            reply = lf.answers(c, [(*at(*scope), *op)])[0]
            if scope in self.VISIBLE:
                visible.append(reply)
        if sensitive:
            c.call(*at('C', 'u1'), 'VADD', 'k2', 'VALUES', 3, 1, 2, 3, 'extra')
        if expire:
            for scope in self.HIDDEN:
                for key in self.KEYS:
                    mine = c.call(*at(*scope), 'LABEL', 'OF', key)
                    if mine is not None and c.call(*at(*scope), 'PEXPIRE', key, 1200) != 1:
                        raise AssertionError('no own presence')
        before = self.corpus(c)
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        if expire:
            time.sleep(1.4)
        c = self.up(run)
        after = self.corpus(c)
        if expire or not hidden:
            after.append(sorted((k, v) for k, v in lf.info(c, *TOP, section='owners').items() if not k.endswith('_bytes')))
        run.stop(signal.SIGKILL)
        return visible, before, after

    def test_another_users_vector_partitions_change_nothing_before_or_after_a_restart(self):
        quiet = self.world(False)
        noisy = self.world(True)
        self.assertEqual(quiet[0], noisy[0])
        self.assertEqual(quiet[1], noisy[1])
        self.assertEqual(quiet[2][:-1], noisy[2])

    def test_another_users_expired_vector_partitions_leave_nothing(self):
        self.assertEqual(self.world(False)[2], self.world(True, expire=True)[2])

    def test_a_visible_vector_difference_shows(self):
        self.assertNotEqual(self.world(False)[2], self.world(False, sensitive=True)[2])


class OwnerVectorRestore(Base):
    arguments = SCHEME + OWNERS + SEEDS + ('--save', '')

    def test_restore_lands_in_the_callers_own_scope_and_meets_the_owner_quota(self):
        run = self.run_server()
        c = self.up(run)
        rng = random.Random(6)
        c.pipeline([(*at('C', 'u2'), *vadd('big', rng, 8, 'e%d' % i)) for i in range(3000)])
        payload = c.call(*at('C', 'u2'), 'DUMP', 'big')
        small = c.call(*at('C', 'u2'), 'VADD', 'small', 'VALUES', 2, 1, 0, 'only')
        small = c.call(*at('C', 'u2'), 'DUMP', 'small')
        c.call(*TOP, 'OWNERS', 'QUOTA', 'u1', 'LIMIT', 100000)
        self.assertEqual(error_of(c, *at('C', 'u1'), 'RESTORE', 'big', 0, payload), "OOM command not allowed when used memory > 'owner-quota'.")
        self.assertEqual(error_of(c, *at('C', 'u1'), 'RESTORE', 'list', 0, lf.MALFORMED_LIST), 'ERR Bad data format')
        self.assertEqual(error_of(c, *at('C', 'u1'), 'RESTORE', 'big', 0, payload), "OOM command not allowed when used memory > 'owner-quota'.")
        self.assertEqual(error_of(run.client(), *at('C', 'u2'), 'RESTORE', 'list', 0, lf.MALFORMED_LIST), 'ERR Bad data format')
        self.assertEqual(c.call(*at('C', 'u1'), 'EXISTS', 'big'), 0)
        self.assertEqual(c.call(*at('C', 'u1'), 'RESTORE', 'mine', 0, small), 'OK')
        self.assertEqual(c.call(*at('C', 'u1'), 'VEMB', 'mine', 'only'), c.call(*at('C', 'u2'), 'VEMB', 'small', 'only'))
        self.assertEqual(c.call(*at('C', 'u3'), 'EXISTS', 'mine'), 0)
        self.assertEqual(c.call(*at('C'), 'EXISTS', 'mine'), 0)
        self.assertEqual(c.call(*at('S//A', 'u1'), 'VCARD', 'mine'), 1)
        self.assertEqual(c.call(*at('U', 'u1'), 'EXISTS', 'mine'), 0)
        self.assertEqual(c.call(*at('C', 'u3'), 'RESTORE', 'big', 0, payload), 'OK')
        self.assertEqual(c.call(*at('C', 'u3'), 'VCARD', 'big'), 3000)
        facts = {n: owner_facts(c, n) for n in ('u1', 'u2', 'u3')}
        reads = {r: lf.vector_reads(c, at(*r), key, 8 if key == 'big' else 2, ['e1', 'e9', 'only'], randoms=False) for r in OVREADERS for key in ('big', 'mine', 'small')}
        c.call(*TOP, 'SAVE')
        run.stop(signal.SIGKILL)
        c = self.up(run)
        self.assertEqual({n: owner_facts(c, n) for n in ('u1', 'u2', 'u3')}, facts)
        self.assertEqual({r: lf.vector_reads(c, at(*r), key, 8 if key == 'big' else 2, ['e1', 'e9', 'only'], randoms=False) for r in OVREADERS for key in ('big', 'mine', 'small')}, reads)
        self.assertEqual(error_of(c, *at('C', 'u1'), 'RESTORE', 'big', 0, payload), "OOM command not allowed when used memory > 'owner-quota'.")

    def test_a_malformed_payload_answers_the_format_error_whatever_size_its_header_claims(self):
        c = self.up(self.run_server())
        payloads = lf.malformed_vset_dumps()
        for limit in (1 << 40, 100000, 1000):
            c.call(*TOP, 'OWNERS', 'QUOTA', 'u1', 'LIMIT', limit)
            for payload in payloads:
                self.assertEqual(error_of(c, *at('C', 'u1'), 'RESTORE', 'm', 0, payload), 'ERR Bad data format', (limit, payload[:40]))
            self.assertEqual(c.call(*at('C', 'u1'), 'EXISTS', 'm'), 0)


class OwnerVectorAccounting(Base):
    arguments = SCHEME + OWNERS + SEEDS + ('--save', '')
    ELEMENTS = 300

    def figures(self, c):
        return (c.call(*TOP, 'LABEL', 'QUOTA', 'C')[1], as_map(c.call(*TOP, 'OWNERS', 'INFO', 'u1'))[b'bytes'],
                int(lf.info(c, *TOP, section='memory')['used_memory_dataset']))

    def build(self, c, key, scope):
        rng = random.Random(14)
        ops = [(*at(*scope), *vadd(key, rng, 3, 'e%d' % i)) for i in range(self.ELEMENTS)]
        self.assertEqual(lf.answers(c, ops), [1] * self.ELEMENTS)

    def near(self, restored, restored_base, built, built_base, what):
        for k, name in enumerate(('label C use', 'u1 bytes', 'used_memory_dataset')):
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
            self.build(c, 'src', ('C', 'u2'))
            out.append((run, c, c.call(*at('C', 'u2'), 'DUMP', 'src')))
        self.assertEqual(out[0][2], out[1][2])
        return out

    def test_a_restored_vector_set_is_charged_like_one_built_by_writes_and_released_by_del(self):
        (a, ca, payload), (b, cb, _) = self.servers()
        base_a, base_b = self.figures(ca), self.figures(cb)
        self.assertEqual(ca.call(*at('C', 'u1'), 'RESTORE', 'mine', 0, payload), 'OK')
        self.build(cb, 'mine', ('C', 'u1'))
        self.near(self.figures(ca), base_a, self.figures(cb), base_b, 'restore at an owner')
        self.assertEqual(ca.call(*at('C'), 'RESTORE', 'shared', 0, payload), 'OK')
        self.build(cb, 'shared', ('C', ''))
        self.near(self.figures(ca), base_a, self.figures(cb), base_b, 'restore shared')
        self.assertEqual(ca.call(*at('C', 'u1'), 'RESTORE', 'mine', 0, payload, 'REPLACE'), 'OK')
        self.assertEqual(ca.call(*at('C'), 'RESTORE', 'shared', 0, payload, 'REPLACE'), 'OK')
        self.near(self.figures(ca), base_a, self.figures(cb), base_b, 'restore with replace')
        for c, base in ((ca, base_a), (cb, base_b)):
            self.assertEqual(c.call(*at('C', 'u1'), 'DEL', 'mine'), 1)
            self.assertEqual(c.call(*at('C'), 'DEL', 'shared'), 1)
        self.assertEqual(self.figures(ca)[2], base_a[2])
        self.assertEqual(self.figures(cb)[2], base_b[2])
        self.assertEqual(self.figures(ca)[:2], self.figures(cb)[:2])

    def test_a_restart_then_removing_everything_leaves_what_a_running_server_leaves(self):
        (a, ca, payload), (b, cb, _) = self.servers()
        base_a, base_b = self.figures(ca), self.figures(cb)
        for c in (ca, cb):
            self.assertEqual(c.call(*at('C', 'u1'), 'RESTORE', 'mine', 0, payload), 'OK')
            self.assertEqual(c.call(*at('C'), 'RESTORE', 'shared', 0, payload), 'OK')
            self.assertEqual(c.call(*at('U', 'u1'), 'RESTORE', 'low', 0, payload), 'OK')
        self.assertEqual(ca.call(*TOP, 'SAVE'), 'OK')
        a.stop(signal.SIGKILL)
        ca = self.up(a)
        self.near(self.figures(ca), base_a, self.figures(cb), base_b, 'after the restart')
        self.assertEqual(self.figures(ca)[:2], self.figures(cb)[:2])
        self.assertEqual(as_map(ca.call(*TOP, 'OWNERS', 'INFO', 'u2'))[b'bytes'], as_map(cb.call(*TOP, 'OWNERS', 'INFO', 'u2'))[b'bytes'])
        for c in (ca, cb):
            self.assertEqual(c.call(*at('C', 'u1'), 'DEL', 'mine'), 1)
            self.assertEqual(c.call(*at('C'), 'DEL', 'shared'), 1)
            self.assertEqual(c.call(*at('U', 'u1'), 'DEL', 'low'), 1)
            self.assertEqual(c.call(*at('C', 'u2'), 'DEL', 'src'), 1)
            self.assertEqual(c.call(*TOP, 'DBSIZE'), 0)
        self.assertEqual(self.figures(ca), self.figures(cb))
        self.assertEqual(as_map(ca.call(*TOP, 'OWNERS', 'INFO', 'u2'))[b'bytes'], as_map(cb.call(*TOP, 'OWNERS', 'INFO', 'u2'))[b'bytes'])


SEAL_INFO = {1: 'eski snapshot v1', 2: 'eski append v1', 3: 'eski append v1', 4: 'eski manifest v1'}


def openssl(*arguments, data=None):
    return subprocess.run(['openssl', *arguments], input=data, capture_output=True, check=True).stdout


def opened(path, key_text):
    data = path.read_bytes()
    if data[:8] != b'ESKIENC1':
        return data
    kind = data[8]
    salt = data[26:58]
    derived = openssl('kdf', '-keylen', '32', '-kdfopt', 'digest:SHA256', '-kdfopt', 'hexkey:' + key_text, '-kdfopt', 'hexsalt:' + salt.hex(),
                      '-kdfopt', 'info:' + SEAL_INFO[kind], 'HKDF').decode().strip().replace(':', '')
    spans = []
    at = 58
    while at + 4 <= len(data):
        n = int.from_bytes(data[at:at + 4], 'little') & 0x7fffffff
        spans.append((at + 4, min(n, len(data) - at - 4)))
        at += 4 + n + 16
    out = b''
    for index, (start, n) in enumerate(spans):
        closing = 1 if kind != 3 and index == len(spans) - 1 else 0
        iv = index.to_bytes(8, 'little') + bytes([closing, 0, 0, 0]) + b'\x00\x00\x00\x02'
        out += openssl('enc', '-d', '-aes-256-ctr', '-K', derived, '-iv', iv.hex(), '-nopad', data=data[start:start + n])
    return out


class ForgetCoverage(Base):
    ID = 'forgotten-owner-58'
    DATA = 'FORGOTTENVALUE58'
    LOG = ('--appendonly', 'yes', '--appendfsync', 'always', '--auto-aof-rewrite-percentage', '0')

    def data_dir(self, name):
        d = self.dir / name
        d.mkdir()
        return d

    def key(self):
        path = self.dir / 'key'
        if not path.exists():
            path.write_text(openssl('rand', '-hex', '32').decode().strip() + '\n')
            path.chmod(0o600)
        return path

    def holders(self, directory, key_text=None):
        found = []
        for p in sorted(directory.rglob('*')):
            if not p.is_file() or p.name == 'server.log':
                continue
            try:
                data = opened(p, key_text) if key_text else p.read_bytes()
            except (FileNotFoundError, subprocess.CalledProcessError):
                continue
            if self.ID.encode() in data or self.DATA.encode() in data:
                found.append(p.name)
        return found

    def fill(self, c):
        for label in ('U', 'C', 'S//A'):
            c.call(*at(label, self.ID), 'SET', 'k-' + label, self.DATA)
            c.call(*at(label, self.ID), 'RPUSH', 'l-' + label, self.DATA, 'two')
            c.call(*at(label, 'stays-owner-3'), 'SET', 'k-' + label, 'kept')
        c.call(*TOP, 'OWNERS', 'QUOTA', self.ID, 'LIMIT', 9000000)

    def check_covered_means_gone(self, gc, keyed):
        d = self.data_dir('gc-%s-key-%s' % (gc, keyed))
        extra = self.LOG + ('--save', '', '--aof-disable-auto-gc', gc, '--owners-forget-aof-delay', '1')
        key_text = None
        if keyed:
            extra += ('--encryption-key-file', str(self.key()))
            key_text = self.key().read_text().strip()
        run = self.run_server(SCHEME + OWNERS + SEEDS + extra, directory=d)
        c = self.up(run)
        self.fill(c)
        self.assertEqual(c.call(*TOP, 'BGREWRITEAOF'), 'Background append only file rewriting started')
        wait(lambda: lf.info(c, *TOP)['aof_rewrite_in_progress'] == '0' and lf.info(c, *TOP)['aof_rewrites'] == '1')
        c.call(*at('C', self.ID), 'SET', 'after-rewrite', self.DATA)
        self.assertTrue(self.holders(d, key_text), 'the forgotten owner was never in a file, so the test shows nothing')
        c.call(*TOP, 'OWNERS', 'FORGET', self.ID)
        seen = []

        def covered():
            i = lf.info(c, *TOP)
            if i['owners_forget_in_aof'] != i['owners_forget_sequence']:
                return False
            seen.append(self.holders(d, key_text))
            return True
        wait(covered, 40)
        self.assertEqual(seen[0], [], 'the field reported the forget covered while these files held the owner')
        self.assertEqual(c.call(*at('C', 'stays-owner-3'), 'GET', 'k-C'), b'kept')
        run.stop()
        self.assertEqual(self.holders(d, key_text), [])

    def test_once_the_forget_counts_as_covered_no_file_holds_the_owner_with_history_kept_or_not_and_with_a_key_or_not(self):
        for gc in ('yes', 'no'):
            for keyed in (False, True):
                with self.subTest(disable_auto_gc=gc, key=keyed):
                    self.check_covered_means_gone(gc, keyed)

    def test_with_the_log_off_the_field_keeps_its_value_while_an_earlier_log_is_in_the_directory(self):
        d = self.data_dir('off')
        run = self.run_server(SCHEME + OWNERS + SEEDS + self.LOG + ('--save', ''), directory=d)
        c = self.up(run)
        self.fill(c)
        run.stop()
        run = self.run_server(SCHEME + OWNERS + SEEDS + ('--appendonly', 'no', '--save', '', '--owners-forget-aof-delay', '1'), directory=d)
        c = self.up(run)
        c.call(*TOP, 'OWNERS', 'FORGET', self.ID)
        i = lf.info(c, *TOP)
        self.assertEqual((i['owners_forget_sequence'], i['owners_forget_in_aof']), ('1', '0'))
        self.assertIn('OWNERS FORGET ran while the append-only file is off, and appendonlydir still holds files', run.log())
        wait(lambda: run.log().count('appendonlydir still holds files') >= 2, 20)
        self.assertNotIn(self.ID, run.log())
        self.assertNotIn('owners_forget_in_aof', lf.info(c, *at('C', 'u1')))
        for p in (d / 'appendonlydir').iterdir():
            p.unlink()
        i = lf.info(c, *TOP)
        self.assertEqual(i['owners_forget_in_aof'], i['owners_forget_sequence'])

    def test_a_snapshot_file_this_server_does_not_use_keeps_the_snapshot_field_and_is_named_in_a_warning(self):
        d = self.data_dir('snap')
        run = self.run_server(SCHEME + OWNERS + SEEDS + ('--appendonly', 'no', '--save', ''), directory=d)
        c = self.up(run)
        self.fill(c)
        self.assertEqual(c.call(*TOP, 'SAVE'), 'OK')
        run.stop()
        run = self.run_server(SCHEME + OWNERS + SEEDS + self.LOG + ('--save', '', '--owners-forget-snapshot-delay', '1'), directory=d)
        c = self.up(run)
        c.call(*TOP, 'OWNERS', 'FORGET', self.ID)
        i = lf.info(c, *TOP)
        self.assertEqual((i['owners_forget_sequence'], i['owners_forget_in_snapshot']), ('1', '0'))
        self.assertIn('OWNERS FORGET ran while snapshots are not in use, and the data file dump.rdb', run.log())
        wait(lambda: run.log().count('the data file dump.rdb was neither read nor written') >= 2, 20)
        self.assertTrue(self.holders(d))
        (d / 'dump.rdb').unlink()
        i = lf.info(c, *TOP)
        self.assertEqual(i['owners_forget_in_snapshot'], i['owners_forget_sequence'])


class OwnerBytesAcrossLoads(Base):
    LOG = ('--appendonly', 'yes', '--appendfsync', 'always', '--auto-aof-rewrite-percentage', '0', '--save', '')
    SNAPSHOT = ('--appendonly', 'no', '--save', '3600 1')

    def workload(self, c):
        rng = random.Random(12)
        self.assertEqual(c.call(*at('C'), 'VADD', 'k', 'VALUES', 3, '0', '1', '0', 'shared'), 1)
        for i in range(30):
            c.call(*at('C', 'u1'), 'VADD', 'k', 'VALUES', 3, *['%.3f' % rng.uniform(-1, 1) for _ in range(3)], 'x%d' % i)
        self.assertEqual(c.call(*at('C', 'u1'), 'SET', 'plain', 'v'), 'OK')
        self.assertEqual(c.call(*at('C', 'u1'), 'HSET', 'h', 'f', 'v'), 1)
        held = self.bytes_of(c)
        self.assertIn('INUSE', error_of(c, *at('S', 'u1'), 'VADD', 'k', 'VALUES', 3, '1', '0', '0', 'x3'))
        self.assertEqual(c.call(*at('S//A', 'u1'), 'DEL', 'missing'), 0)
        self.assertIsNone(c.call(*at('S//B', 'u1'), 'SPOP', 'missing'))
        self.assertEqual(c.call('SELECT', 3), 'OK')
        self.assertEqual(c.call(*at('C', 'u1'), 'DEL', 'missing'), 0)
        self.assertEqual(c.call('SELECT', 0), 'OK')
        self.assertEqual(self.bytes_of(c), held, 'writes that left nothing at a new label or database must leave no record')

    def bytes_of(self, c):
        return as_map(c.call(*TOP, 'OWNERS', 'INFO', 'u1'))[b'bytes']

    def rewrite(self, c):
        before = int(lf.info(c, *TOP, section='persistence')['aof_rewrites'])
        self.assertIn('rewriting', str(c.call(*TOP, 'BGREWRITEAOF')))
        wait(lambda: int(lf.info(c, *TOP, section='persistence')['aof_rewrites']) > before and lf.info(c, *TOP, section='persistence')['aof_rewrite_in_progress'] == '0')

    def test_a_users_bytes_survive_every_load_of_the_log(self):
        run = self.run_server(SCHEME + OWNERS + SEEDS + self.LOG)
        c = self.up(run)
        self.workload(c)
        want = self.bytes_of(c)
        self.assertEqual(c.call(*TOP, 'DEBUG', 'LOADAOF'), 'OK')
        self.assertEqual(self.bytes_of(c), want, 'after DEBUG LOADAOF')
        c.close()
        self.assertEqual(run.stop(signal.SIGTERM), 0)
        c = self.up(run)
        self.assertEqual(self.bytes_of(c), want, 'after a restart from the log')
        self.rewrite(c)
        self.assertEqual(self.bytes_of(c), want, 'after a rewrite')
        c.close()
        run.stop(signal.SIGKILL)
        c = self.up(run)
        self.assertEqual(self.bytes_of(c), want, 'after a rewrite and a restart')
        c.close()

    def test_a_users_bytes_survive_every_load_of_a_snapshot(self):
        run = self.run_server(SCHEME + OWNERS + SEEDS + self.SNAPSHOT)
        c = self.up(run)
        self.workload(c)
        want = self.bytes_of(c)
        self.assertEqual(c.call(*TOP, 'DEBUG', 'RELOAD'), 'OK')
        self.assertEqual(self.bytes_of(c), want, 'after DEBUG RELOAD')
        self.assertEqual(c.call(*TOP, 'SAVE'), 'OK')
        c.close()
        run.stop(signal.SIGKILL)
        c = self.up(run)
        self.assertEqual(self.bytes_of(c), want, 'after a restart from a snapshot')
        c.close()


def main():
    global BINARY, KEYSPACE_THREADS, WRITE_FIXTURES
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', default=str(BINARY))
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--write-fixtures', action='store_true')
    args, rest = parser.parse_known_args()
    BINARY = Path(args.server).resolve()
    KEYSPACE_THREADS = args.keyspace_threads
    WRITE_FIXTURES = args.write_fixtures
    unittest.main(argv=[sys.argv[0]] + rest, verbosity=1)


if __name__ == '__main__':
    main()
