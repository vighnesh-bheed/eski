import argparse
import json
from pathlib import Path
import random
import socket
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Client, Push, Server, ServerError, info

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0
SCHEME = ('--label-levels', 'U,C,S', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED')
LABELS_OFF = 'ERR labels are not configured on this server'
INVALID = 'ERR invalid label'
TOP_ERROR = 'ERR this command needs a label that dominates the whole label scheme'


def AS(label):
    return ('LABEL', 'AS', label)


def error_of(client, *arguments):
    client.send(*arguments)
    value = client.reply()
    if not isinstance(value, ServerError):
        raise AssertionError('expected an error from %r, got %r' % (arguments, value))
    return str(value)


def call(client, *arguments):
    client.send(*arguments)
    return client.reply()


def as_map(value):
    if isinstance(value, dict):
        return value
    return dict(zip(value[0::2], value[1::2]))


def scan_all(client, label, *options):
    names = []
    cursor = 0
    rounds = 0
    while True:
        cursor, batch = client.call(*AS(label), 'SCAN', cursor, *options)
        names += batch
        cursor = int(cursor)
        rounds += 1
        if cursor == 0 or rounds > 100000:
            return names


def start_server(extra=(), threads=None):
    arguments = ('--keyspace-threads', str(KEYSPACE_THREADS if threads is None else threads)) + SCHEME + tuple(extra)
    server = Server(BINARY, workers=0, arguments=arguments)
    server.start()
    return server


class LabelsOff(unittest.TestCase):
    def setUp(self):
        self.server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS)))
        self.addCleanup(self.server.close)
        self.server.start()
        self.client = self.server.client()

    def test_key_subcommands_answer_labels_off(self):
        for command in (('LABEL', 'OF', 'k'), ('LABEL', 'DECLASSIFY', 'k', 'U'), ('LABEL', 'RAISE', 'k', 'U'),
                        ('LABEL', 'COPIES'), ('LABEL', 'QUOTA', 'U')):
            self.assertEqual(error_of(self.client, *command), LABELS_OFF)

    def test_listings_and_counts_keep_their_shape(self):
        c = self.client
        for i in range(300):
            c.call('SET', 'k%d' % i, i)
        self.assertEqual(c.call('DBSIZE'), 300)
        self.assertEqual(len(c.call('KEYS', '*')), 300)
        names = []
        cursor = 0
        while True:
            cursor, batch = c.call('SCAN', cursor, 'COUNT', 7)
            names += batch
            if int(cursor) == 0:
                break
        self.assertEqual(len(set(names)), 300)
        self.assertIn(b'db0:keys=300,expires=0', c.call('INFO', 'keyspace'))
        self.assertTrue(c.call('RANDOMKEY').startswith(b'k'))


class Labelled(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='eski-keyspace-labels-')
        self.addCleanup(self.directory.cleanup)
        self.audit = Path(self.directory.name) / 'audit.log'
        self.server = start_server(('--label-audit-file', str(self.audit), '--label-stream-seed', '77'))
        self.addCleanup(self.server.close)
        self.c = self.connect()
        self.c.call('ACL', 'SETUSER', 'default', 'clearance:*', 'trust:*')

    def connect(self, protocol=2):
        client = Client(self.server.port)
        self.addCleanup(client.close)
        if protocol == 3:
            client.call('HELLO', 3)
        return client

    def at(self, label, *arguments):
        return self.c.call(*AS(label), *arguments)

    def refused(self, label, *arguments):
        return error_of(self.c, *AS(label), *arguments)

    def test_reads_resolve_one_copy_in_the_owner_order(self):
        self.at('U', 'SET', 'k', 'u')
        self.assertEqual(self.at('S', 'GET', 'k'), b'u')
        self.at('S//A', 'SET', 'k2', 'a')
        self.at('S//B', 'SET', 'k2', 'b')
        self.assertEqual(self.at('S//A/B', 'GET', 'k2'), b'a')
        self.at('S//A', 'DEL', 'k2')
        self.at('S//A', 'SET', 'k2', 'a2')
        self.assertEqual(self.at('S//A/B', 'GET', 'k2'), b'b')
        self.at('C//A', 'SET', 'k3', 'ca')
        self.at('C', 'SET', 'k3', 'c')
        self.assertEqual(self.at('S//A', 'GET', 'k3'), b'ca')
        self.assertEqual(self.at('S', 'GET', 'k3'), b'c')
        self.at('C', 'SET', 'k4', 'web')
        self.at('C;VETTED', 'SET', 'k4', 'vetted')
        self.assertEqual(self.at('S', 'GET', 'k4'), b'vetted')
        self.assertEqual(self.at('C', 'GET', 'k4'), b'web')
        self.assertEqual(self.at('S;VETTED', 'GET', 'k4'), b'vetted')

    def test_hidden_copies_behave_as_missing(self):
        self.at('S', 'SET', 'h', 'secret')
        self.at('S', 'RPUSH', 'hl', 'x')
        self.at('S', 'EXPIRE', 'h', 100)
        self.assertIsNone(self.at('U', 'GET', 'h'))
        self.assertEqual(self.at('U', 'TYPE', 'h'), 'none')
        self.assertEqual(self.at('U', 'EXISTS', 'h', 'hl'), 0)
        self.assertEqual(self.at('U', 'TTL', 'h'), -2)
        self.assertIsNone(self.at('U', 'OBJECT', 'ENCODING', 'h'))
        self.assertIsNone(self.at('U', 'MEMORY', 'USAGE', 'h'))
        self.assertIsNone(self.at('U', 'LABEL', 'OF', 'h'))
        self.assertIsNone(self.at('U', 'LINDEX', 'h', 0))
        self.assertEqual(self.at('U', 'LPUSH', 'h', 'mine'), 1)
        self.assertEqual(self.at('U', 'TYPE', 'h'), 'list')
        self.assertEqual(self.at('S', 'TYPE', 'h'), 'string')
        self.assertEqual(self.at('U', 'SET', 'hl', 'forced'), 'OK')
        self.assertEqual(self.at('S', 'LRANGE', 'hl', 0, -1), [b'x'])

    def test_writes_land_exactly_at_the_command_label(self):
        self.at('U', 'SET', 'k', 'u')
        self.at('U', 'RPUSH', 'l', 'a')
        expected = 'INUSE name in use at U'
        for command in (('SET', 'k', 'v'), ('APPEND', 'k', 'v'), ('INCR', 'k'), ('DEL', 'k'), ('UNLINK', 'k'),
                        ('EXPIRE', 'k', 10), ('PERSIST', 'k'), ('RENAME', 'k', 'z'), ('SETNX', 'k', 'v'),
                        ('SET', 'k', 'v', 'NX'), ('GETDEL', 'k'), ('LPUSH', 'l', 'b'), ('RPOP', 'l'),
                        ('MSET', 'fresh', 1, 'k', 2), ('MSETNX', 'fresh', 1, 'k', 2), ('MOVE', 'k', 1),
                        ('SORT', 'l', 'STORE', 'k'), ('LMOVE', 'l', 'dst', 'LEFT', 'LEFT')):
            self.assertEqual(self.refused('S', *command), expected, command)
        self.assertIsNone(self.at('S', 'GET', 'fresh'))
        self.assertEqual(self.at('U', 'GET', 'k'), b'u')
        self.assertEqual(self.at('S', 'SET', 'mine', 'm'), 'OK')
        self.assertEqual(self.at('S', 'APPEND', 'mine', 'x'), 2)
        self.assertEqual(self.at('S', 'SUNIONSTORE', 'su', 'missing'), 0)
        self.at('U', 'SADD', 'us', 'a', 'b')
        self.assertEqual(self.at('S', 'SUNIONSTORE', 'su', 'us'), 2)
        self.assertEqual(self.at('S', 'LABEL', 'OF', 'su'), b'S')
        self.assertEqual(self.refused('S', 'SUNIONSTORE', 'us', 'us'), 'INUSE name in use at U')
        self.assertEqual(self.refused('S', 'RENAME', 'mine', 'k'), expected)
        self.assertEqual(self.refused('S', 'COPY', 'mine', 'k'), expected)
        self.assertEqual(self.at('S', 'COPY', 'mine', 'mine2'), 1)
        self.assertEqual(self.at('S', 'DEL', 'missing', 'mine2'), 1)
        self.assertEqual(self.at('S//A', 'SET', 'deep', 1), 'OK')
        self.assertEqual(self.refused('S//A/B', 'INCR', 'deep'), 'INUSE name in use at S//A')

    def test_sort_by_and_get_read_hidden_keys_as_missing(self):
        self.at('U', 'RPUSH', 'ids', 1, 2, 3)
        self.at('U', 'SET', 'w_1', 30)
        self.at('S', 'SET', 'w_2', 10)
        self.at('U', 'SET', 'n_1', 'one')
        self.at('S', 'SET', 'n_3', 'three')
        self.assertEqual(self.at('U', 'SORT', 'ids', 'BY', 'w_*', 'GET', 'n_*'), [None, None, b'one'])
        self.assertEqual(self.at('S', 'SORT', 'ids', 'BY', 'w_*', 'GET', 'n_*'), [b'three', None, b'one'])
        self.assertEqual(self.at('S', 'SORT', 'ids', 'BY', 'w_*', 'GET', '#'), [b'3', b'2', b'1'])

    def test_listings_and_counts_show_each_name_once(self):
        for i in range(10):
            self.at('S', 'SET', 'u%d' % i, 'shadow')
        for i in range(120):
            self.at('U', 'SET', 'u%d' % i, i)
        for i in range(80):
            self.at('S', 'SET', 's%d' % i, i)
        self.at('S', 'SET', 'timed', 1, 'EX', 100)
        self.assertEqual(self.at('U', 'DBSIZE'), 120)
        self.assertEqual(self.at('S', 'DBSIZE'), 201)
        self.assertEqual(self.at('C', 'DBSIZE'), 120)
        self.assertEqual(len(self.at('S', 'KEYS', '*')), 201)
        self.assertEqual(sorted(self.at('S', 'KEYS', 'u1?')), sorted(b'u1%d' % i for i in range(10)))
        names = scan_all(self.c, 'S', 'COUNT', 9)
        self.assertEqual(len(set(names)), 201)
        self.assertEqual(set(scan_all(self.c, 'U', 'COUNT', 5)), set(b'u%d' % i for i in range(120)))
        self.assertEqual(set(scan_all(self.c, 'S', 'MATCH', 's*', 'TYPE', 'string')), set(b's%d' % i for i in range(80)))
        self.assertIn(b'db0:keys=201,expires=1', self.at('S', 'INFO', 'keyspace'))
        self.assertIn(b'db0:keys=120,expires=0', self.at('U', 'INFO', 'keyspace'))
        visible = set(b'u%d' % i for i in range(120))
        for _ in range(60):
            self.assertIn(self.at('U', 'RANDOMKEY'), visible)
        self.assertEqual(self.at('U;VETTED', 'DBSIZE'), 0)
        self.assertIsNone(self.at('U;VETTED', 'RANDOMKEY'))

    def test_scan_survives_new_labels_and_resizes(self):
        for i in range(400):
            self.at('U', 'SET', 'base%d' % i, i)
        names = []
        cursor = 0
        grow = 0
        while True:
            cursor, batch = self.c.call(*AS('S//A/B'), 'SCAN', cursor, 'COUNT', 11)
            names += batch
            for label in ('C', 'S//A', 'C//B', 'S'):
                self.at(label, 'SET', 'new%d' % grow, grow)
                grow += 1
            cursor = int(cursor)
            if cursor == 0:
                break
        self.assertTrue(set(b'base%d' % i for i in range(400)) <= set(names))

    def test_randomkey_finds_a_visible_name_when_most_are_shadowed_or_expired(self):
        for i in range(300):
            self.at('S', 'SET', 'x%d' % i, 'shadow')
            self.at('U', 'SET', 'x%d' % i, i)
        self.at('S', 'SET', 'only', 1)
        for i in range(300):
            self.at('S', 'PEXPIRE', 'x%d' % i, 1)
        time.sleep(0.05)
        self.c.call('CONFIG', 'SET', 'hz', 1)
        seen = set(self.at('S', 'RANDOMKEY') for _ in range(20))
        self.assertTrue(seen <= set(b'x%d' % i for i in range(300)) | {b'only'})
        self.assertNotIn(None, seen)

    def test_flush_deletes_only_the_command_label_unless_top(self):
        self.at('U', 'SET', 'a', 1)
        self.at('S', 'SET', 'b', 1)
        self.c.call('SELECT', 2)
        self.at('U', 'SET', 'a2', 1)
        self.c.call('SELECT', 0)
        self.assertEqual(self.at('U', 'FLUSHDB'), 'OK')
        self.assertEqual(self.at('S', 'KEYS', '*'), [b'b'])
        self.c.call('SELECT', 2)
        self.assertEqual(self.at('S', 'DBSIZE'), 1)
        self.assertEqual(self.at('U', 'FLUSHALL'), 'OK')
        self.assertEqual(self.at('S', 'DBSIZE'), 0)
        self.c.call('SELECT', 0)
        self.assertEqual(self.at('S', 'DBSIZE'), 1)
        self.assertEqual(self.c.call('FLUSHALL'), 'OK')
        self.assertEqual(self.c.call('DBSIZE'), 0)

    def test_swapdb_at_top_moves_every_label(self):
        self.at('U', 'SET', 'a', 1)
        self.at('S', 'SET', 'b', 1)
        self.assertEqual(self.refused('S', 'SWAPDB', 0, 1), TOP_ERROR)
        self.assertEqual(self.c.call('SWAPDB', 0, 1), 'OK')
        self.c.call('SELECT', 1)
        self.assertEqual(self.at('S', 'DBSIZE'), 2)
        self.assertEqual(self.at('U', 'GET', 'a'), b'1')
        self.assertEqual(self.at('S', 'LABEL', 'OF', 'b'), b'S')

    def test_watch_aborts_only_on_dominated_writes(self):
        low = self.connect()
        high = self.connect()
        for label, other, writer, aborted in (('U', 'S', 'S', False), ('U', 'U', 'U', True), ('S', 'U', 'U', True)):
            low.call(*AS(label), 'WATCH', 'w')
            low.call(*AS(label), 'MULTI')
            low.call(*AS(label), 'SET', 'probe', 1)
            high.call(*AS(writer), 'SET', 'w', 'x')
            result = low.call(*AS(label), 'EXEC')
            self.assertEqual(result is None, aborted, (label, writer))
            high.call(*AS(writer), 'DEL', 'w')

    def test_blocking_pops_wake_only_on_their_label(self):
        waiter = self.connect()
        waiter.socket.settimeout(5)
        waiter.send(*AS('S'), 'BLPOP', 'q', 2)
        time.sleep(0.1)
        self.at('U', 'RPUSH', 'q', 'low')
        time.sleep(0.2)
        self.at('S', 'RPUSH', 'q2', 'unrelated')
        self.assertIsNone(waiter.reply())
        self.assertEqual(self.refused('S', 'BLPOP', 'q', 1), 'INUSE name in use at U')
        waiter.send(*AS('S'), 'BLPOP', 'qq', 5)
        time.sleep(0.1)
        self.at('S', 'RPUSH', 'qq', 'high')
        self.assertEqual(waiter.reply(), [b'qq', b'high'])
        reader = self.connect()
        reader.send(*AS('S'), 'XREAD', 'BLOCK', 3000, 'STREAMS', 'st', '$')
        time.sleep(0.1)
        self.at('S//A', 'XADD', 'st', '*', 'f', 'hidden')
        time.sleep(0.1)
        self.at('U', 'XADD', 'st2', '*', 'f', 'other')
        self.at('U', 'XADD', 'st', '*', 'f', 'visible')
        value = reader.reply()
        self.assertEqual(value[0][0], b'st')
        self.assertEqual(value[0][1][0][1], [b'f', b'visible'])

    def test_keyspace_notifications_reach_dominating_sessions(self):
        self.c.call('CONFIG', 'SET', 'notify-keyspace-events', 'KEA')
        low = self.connect()
        low.call('LABEL', 'SESSION', 'U')
        low.call('SUBSCRIBE', '__keyevent@0__:set', '__keyevent@0__:expired')
        low.reply()
        high = self.connect()
        high.call('LABEL', 'SESSION', 'S')
        high.call('SUBSCRIBE', '__keyevent@0__:set', '__keyevent@0__:expired')
        high.reply()
        self.at('S', 'SET', 'hs', 1)
        self.at('U', 'SET', 'us', 1)
        self.at('S', 'SET', 'gone', 1, 'PX', 30)
        time.sleep(0.3)
        self.at('U', 'SET', 'fence', 1)
        low.socket.settimeout(2)
        self.assertEqual(low.reply(), [b'message', b'__keyevent@0__:set', b'us'])
        self.assertEqual(low.reply(), [b'message', b'__keyevent@0__:set', b'fence'])
        got = [high.reply() for _ in range(5)]
        payloads = [m[2] for m in got]
        self.assertEqual(sorted(payloads), sorted([b'hs', b'us', b'gone', b'gone', b'fence']))

    def test_tracking_invalidates_only_dominating_sessions(self):
        tracker = self.connect(3)
        tracker.call('LABEL', 'SESSION', 'U')
        tracker.call('CLIENT', 'TRACKING', 'ON')
        self.at('S//A', 'SET', 't', 'hidden')
        self.at('U', 'SET', 't', 1)
        tracker.call('GET', 't')
        self.at('S//A', 'SET', 't', 'hidden again')
        self.at('S', 'SET', 'other', 1)
        tracker.call('PING')
        self.assertEqual(tracker.pushes, [])
        self.at('U', 'SET', 't', 2)
        tracker.call('PING')
        self.assertEqual(tracker.pushes, [Push([b'invalidate', [b't']])])
        bcast = self.connect(3)
        bcast.call('LABEL', 'SESSION', 'U')
        bcast.call('CLIENT', 'TRACKING', 'ON', 'BCAST', 'PREFIX', 'p:')
        self.at('S', 'SET', 'p:hidden', 1)
        self.at('U', 'SET', 'p:seen', 1)
        time.sleep(0.1)
        bcast.call('PING')
        self.assertEqual(bcast.pushes, [Push([b'invalidate', [b'p:seen']])])

    def test_reads_at_another_label_never_change_the_copy(self):
        self.c.call('CONFIG', 'SET', 'notify-keyspace-events', 'Kh')
        self.at('U', 'HSET', 'hx', 'f', 'v', 'g', 'w')
        self.at('U', 'HPEXPIRE', 'hx', 1, 'FIELDS', 1, 'f')
        self.c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        time.sleep(0.05)
        low = self.connect()
        low.call('LABEL', 'SESSION', 'U')
        low.call('SUBSCRIBE', '__keyspace@0__:hx')
        self.assertIsNone(self.at('S', 'HGET', 'hx', 'f'))
        self.assertEqual(self.at('S', 'HGETALL', 'hx'), [b'g', b'w'])
        self.assertEqual(self.at('S', 'HRANDFIELD', 'hx'), b'g')
        self.assertEqual(self.at('S', 'HRANDFIELD', 'hx', 5), [b'g'])
        self.at('U', 'SET', 'fence', 1)
        low.socket.settimeout(1)
        try:
            message = low.reply()
        except (TimeoutError, socket.timeout):
            message = None
        self.assertIsNone(message)
        self.assertIsNone(self.at('U', 'HGET', 'hx', 'f'))
        self.assertEqual(low.reply(), [b'message', b'__keyspace@0__:hx', b'hexpired'])
        self.c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 1)
        self.at('U', 'PFADD', 'hll', 'a', 'b', 'c')
        self.at('U', 'PFADD', 'hll', 'd')
        before = self.at('U', 'GET', 'hll')
        self.assertEqual(self.at('S', 'PFCOUNT', 'hll'), 4)
        self.assertEqual(self.at('U', 'GET', 'hll'), before)
        self.c.call('CONFIG', 'SET', 'maxmemory-policy', 'allkeys-lru')
        self.at('U', 'SET', 'idle', 1)
        time.sleep(2.1)
        self.at('S', 'GET', 'idle')
        self.assertGreaterEqual(self.at('U', 'OBJECT', 'IDLETIME', 'idle'), 2)
        self.at('U', 'GET', 'idle')
        self.assertLess(self.at('U', 'OBJECT', 'IDLETIME', 'idle'), 2)

    def test_random_draws_come_from_the_command_label_stream(self):
        other = start_server(('--label-stream-seed', '77'))
        self.addCleanup(other.close)
        b = Client(other.port)
        self.addCleanup(b.close)
        b.call('ACL', 'SETUSER', 'default', 'clearance:*', 'trust:*')
        for client in (self.c, b):
            client.call(*AS('U'), 'SADD', 'pool', *range(50))
            client.call(*AS('S'), 'SADD', 'spool', *range(50))
        draws_a = []
        draws_b = []
        for i in range(30):
            self.c.call(*AS('S'), 'SRANDMEMBER', 'spool', 3)
            self.c.call(*AS('S'), 'SPOP', 'spool')
            draws_a.append(self.c.call(*AS('U'), 'SRANDMEMBER', 'pool', 2))
            draws_b.append(b.call(*AS('U'), 'SRANDMEMBER', 'pool', 2))
        self.assertEqual(draws_a, draws_b)

    def test_scripts_and_transactions_run_each_command_at_the_bound_label(self):
        self.at('U', 'SET', 'k', 'u')
        text = error_of(self.c, *AS('S'), 'EVAL', "return redis.call('SET', KEYS[1], 'x')", 1, 'k')
        self.assertIn('INUSE name in use at U', text)
        self.assertEqual(self.at('S', 'EVAL', "return redis.call('GET', KEYS[1])", 1, 'k'), b'u')
        self.assertEqual(self.at('S', 'EVAL', "redis.call('SET', KEYS[1], 'x') return redis.call('GET', KEYS[1])", 1, 'own'), b'x')
        self.c.call(*AS('S'), 'MULTI')
        self.c.call('SET', 'k', 'x')
        self.c.call('SET', 'n', 'y')
        result = self.c.call(*AS('S'), 'EXEC')
        self.assertIsInstance(result[0], ServerError)
        self.assertEqual(str(result[0]), 'INUSE name in use at U')
        self.assertEqual(result[1], 'OK')
        self.assertEqual(self.at('S', 'LABEL', 'OF', 'n'), b'S')

    def test_vector_sets_are_present_at_each_label_holding_elements(self):
        self.at('U', 'VADD', 'v', 'VALUES', 2, 1, 0, 'a')
        self.at('U', 'VADD', 'v', 'VALUES', 2, 0, 1, 'b')
        self.at('S', 'VADD', 'v', 'VALUES', 2, 1, 1, 'c')
        self.assertEqual([self.at(l, 'VCARD', 'v') for l in ('U', 'C', 'S')], [2, 2, 3])
        self.assertEqual(self.at('S', 'VSIM', 'v', 'VALUES', 2, 1, 1, 'COUNT', 1), [b'c'])
        self.assertEqual(self.at('U', 'VSIM', 'v', 'VALUES', 2, 1, 1, 'COUNT', 1)[0] in (b'a', b'b'), True)
        self.assertEqual(self.at('S', 'DBSIZE'), 1)
        self.assertEqual(self.refused('S', 'VREM', 'v', 'a'), 'INUSE element in use at U')
        self.assertEqual(self.refused('S', 'VADD', 'v', 'VALUES', 2, 0, 0, 'a'), 'INUSE element in use at U')
        self.assertEqual(self.at('S//A', 'VADD', 'v', 'VALUES', 2, 0.5, 0.5, 'd'), 1)
        self.assertEqual(self.at('S', 'VCARD', 'v'), 3)
        self.assertEqual(self.at('S//A', 'VCARD', 'v'), 4)
        self.assertEqual(self.at('U', 'DEL', 'v'), 1)
        self.assertEqual(self.at('U', 'EXISTS', 'v'), 0)
        self.assertEqual(self.at('S', 'TYPE', 'v'), 'vectorset')
        self.assertEqual(self.at('S', 'VCARD', 'v'), 1)
        self.assertEqual(self.at('U', 'SET', 'v', 'string at U'), 'OK')
        self.assertEqual(self.at('U', 'TYPE', 'v'), 'string')
        self.assertEqual(self.at('C', 'GET', 'v'), b'string at U')
        self.assertEqual(self.refused('S', 'GET', 'v'), 'WRONGTYPE Operation against a key holding the wrong kind of value')
        self.assertEqual(self.at('S//A', 'EXPIRE', 'v', 100), 1)
        self.assertEqual(self.at('S//A', 'TTL', 'v'), 100)
        self.assertEqual(self.at('S', 'TTL', 'v'), -1)
        self.assertEqual(self.at('S//A', 'RENAME', 'v', 'w'), 'OK')
        self.assertEqual(self.at('S//A', 'VCARD', 'w'), 1)
        self.assertEqual(self.at('S//A', 'VCARD', 'v'), 1)
        self.assertEqual(self.refused('S', 'COPY', 'v', 'vv'), 'ERR not supported for this module key')
        self.assertEqual(self.at('S', 'MOVE', 'v', 3), 1)
        self.c.call('SELECT', 3)
        self.assertEqual(self.at('S', 'VCARD', 'v'), 1)
        self.c.call('SELECT', 0)
        self.assertEqual(self.at('S//A', 'TYPE', 'v'), 'string')

    def test_vector_set_memory_returns_to_the_baseline(self):
        def round_trip(round):
            for label in ('U', 'C', 'S', 'S//A'):
                for i in range(40):
                    self.at(label, 'VADD', 'm%d' % (i % 5), 'VALUES', 4, i, label.count('/'), round, 1, '%s-%d' % (label, i))
            self.assertEqual(self.at('S//A', 'VCARD', 'm0'), 32)
            for i in range(5):
                self.at('S//A', 'UNLINK', 'm%d' % i)
                self.at('U', 'DEL', 'm%d' % i)
            self.c.call(*AS('S'), 'FLUSHDB')
            self.c.call(*AS('C'), 'FLUSHDB', 'ASYNC')
            time.sleep(0.2)
            self.assertEqual(self.c.call('DBSIZE'), 0)
            stats = as_map(self.c.call('MEMORY', 'STATS'))
            self.assertEqual(stats[b'dataset.bytes'], 0)
            return int(info(self.c, 'memory')['used_memory'])
        settled = round_trip(0)
        for round in range(1, 4):
            self.assertEqual(round_trip(round), settled)

    def test_relabel_moves_one_copy_with_rights_and_audit(self):
        self.at('S', 'SET', 'k', 'secret', 'EX', 1000)
        self.assertEqual(self.at('S', 'LABEL', 'DECLASSIFY', 'k', 'U'), 'OK')
        self.assertEqual(self.at('U', 'GET', 'k'), b'secret')
        self.assertGreater(self.at('U', 'TTL', 'k'), 900)
        self.assertEqual(self.refused('U', 'LABEL', 'DECLASSIFY', 'k', 'S'), "ERR the target label must be below the copy's label")
        self.assertEqual(self.refused('U', 'LABEL', 'RAISE', 'k', 'NOPE'), INVALID)
        self.assertEqual(self.refused('S', 'LABEL', 'RAISE', 'k', 'S//A'), 'INUSE name in use at U')
        self.assertEqual(self.at('U', 'LABEL', 'RAISE', 'k', 'C'), 'OK')
        self.at('U', 'SET', 'k', 'again')
        self.assertEqual(self.refused('U', 'LABEL', 'RAISE', 'k', 'C'), 'INUSE name in use at C')
        self.c.call('ACL', 'SETUSER', 'agent', 'on', 'nopass', '+@all', '-label|declassify', '~*', 'clearance:S')
        agent = self.connect()
        agent.call('AUTH', 'agent', 'x')
        agent.call(*AS('S'), 'SET', 'mine', 1)
        self.assertTrue(error_of(agent, *AS('S'), 'LABEL', 'DECLASSIFY', 'mine', 'U').startswith('NOPERM'))
        self.at('U', 'VADD', 'v', 'VALUES', 2, 1, 0, 'a')
        self.at('S', 'VADD', 'v', 'VALUES', 2, 0, 1, 'b')
        self.assertEqual(self.refused('S', 'LABEL', 'DECLASSIFY', 'v', 'U'), 'ERR name an element to relabel a vector set')
        self.assertEqual(self.at('S', 'LABEL', 'DECLASSIFY', 'v', 'C', 'ELEMENT', 'b'), 'OK')
        self.assertEqual(self.at('S', 'LABEL', 'OF', 'v', 'b'), b'C')
        self.assertEqual(self.at('C', 'VEMB', 'v', 'b'), [b'0', b'1'])
        self.assertEqual(self.at('C', 'VCARD', 'v'), 2)
        records = [json.loads(line) for line in self.audit.read_text().splitlines()]
        events = [r['event'] for r in records]
        self.assertGreaterEqual(events.count('declassify'), 2)
        self.assertIn('raise', events)

    def test_label_of_and_copies(self):
        self.at('S//A', 'SET', 'n', 1)
        self.at('S//B', 'SET', 'n', 2)
        self.assertEqual(self.at('S//A/B', 'LABEL', 'OF', 'n'), b'S//A')
        self.assertEqual(self.refused('S', 'LABEL', 'COPIES'), TOP_ERROR)
        self.assertEqual(self.c.call('LABEL', 'COPIES'), [b'n'])
        self.assertEqual(sorted(self.c.call('LABEL', 'COPIES', 'n')), [[b'S//A', 'string'], [b'S//B', 'string']])

    def test_quota_confines_eviction_to_the_label(self):
        self.c.call('CONFIG', 'SET', 'maxmemory-policy', 'allkeys-random')
        for i in range(200):
            self.at('S', 'SET', 'keep%d' % i, 'x' * 100)
        self.assertEqual(self.c.call('LABEL', 'QUOTA', 'U', 'LIMIT', 200000), 'OK')
        for i in range(3000):
            self.at('U', 'SET', 'fill%d' % i, 'y' * 100)
        limit, used = self.c.call('LABEL', 'QUOTA', 'U')
        self.assertEqual(limit, 200000)
        self.assertLess(used, 200000 + 64 * 1024)
        self.assertEqual(self.at('S', 'DBSIZE') - self.at('U', 'DBSIZE'), 200)
        self.c.call('CONFIG', 'SET', 'maxmemory-policy', 'noeviction')
        text = error_of(self.c, *AS('U'), 'SET', 'more', 'z' * 300000)
        self.assertTrue(text.startswith('OOM'), text)
        self.assertEqual(self.at('S', 'SET', 'fine', 1), 'OK')

    def test_workers_stay_idle_while_labelled(self):
        before = info(self.c, 'keyspace')
        for i in range(50):
            self.at('U', 'SET', 'w%d' % i, i)
            self.at('U', 'GET', 'w%d' % i)
        after = info(self.c, 'keyspace')
        for name in ('keyspace_jobs_submitted', 'keyspace_jobs_completed'):
            if name in before:
                self.assertEqual(before[name], after[name])


class PartitionLimit(unittest.TestCase):
    def test_readers_do_not_allocate_and_writers_are_capped(self):
        server = start_server(('--label-partitions-max', '2'))
        self.addCleanup(server.close)
        c = Client(server.port)
        self.addCleanup(c.close)
        c.call('ACL', 'SETUSER', 'default', 'clearance:*', 'trust:*')
        for label in ('C', 'C//A', 'C//B', 'S', 'S//A', 'S//B', 'S//A/B', 'C;VETTED', 'S;VETTED'):
            for db in range(4):
                c.call('SELECT', db)
                self.assertIsNone(c.call(*AS(label), 'GET', 'k'))
        c.call('SELECT', 0)
        self.assertEqual(c.call(*AS('U'), 'SET', 'k', 1), 'OK')
        self.assertEqual(c.call(*AS('C'), 'SET', 'k2', 1), 'OK')
        self.assertEqual(c.call(*AS('S'), 'SET', 'k3', 1), 'OK')
        self.assertEqual(error_of(c, *AS('S//A'), 'SET', 'k4', 1), 'ERR label partition limit reached')
        self.assertEqual(c.call(*AS('S//A'), 'GET', 'k3'), b'1')
        self.assertEqual(c.call(*AS('S'), 'SET', 'k5', 1), 'OK')


class RuntimeScheme(unittest.TestCase):
    def test_existing_data_becomes_bottom_data(self):
        server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS)))
        self.addCleanup(server.close)
        server.start()
        c = Client(server.port)
        self.addCleanup(c.close)
        c.call('SET', 'old', 'value')
        c.call('VADD', 'vs', 'VALUES', 2, 1, 0, 'e')
        c.call('CONFIG', 'SET', 'label-levels', 'U,S')
        c.call('ACL', 'SETUSER', 'default', 'clearance:*')
        self.assertEqual(c.call(*AS('S'), 'GET', 'old'), b'value')
        self.assertEqual(c.call(*AS('U'), 'LABEL', 'OF', 'old'), b'U')
        self.assertEqual(c.call(*AS('S'), 'VCARD', 'vs'), 1)
        self.assertEqual(c.call(*AS('S'), 'VADD', 'vs', 'VALUES', 2, 0, 1, 'f'), 1)
        self.assertEqual(c.call(*AS('U'), 'VCARD', 'vs'), 1)
        self.assertEqual(c.call(*AS('S'), 'VCARD', 'vs'), 2)
        self.assertEqual(error_of(c, *AS('S'), 'SET', 'old', 'x'), 'INUSE name in use at U')


def normalise(command, value):
    name = command[0].upper()
    if isinstance(value, ServerError):
        return 'ERR:' + str(value)
    if name in ('SMEMBERS', 'KEYS', 'HGETALL', 'HKEYS', 'HVALS', 'SINTER', 'SUNION', 'SDIFF') and isinstance(value, list):
        return sorted(repr(v) for v in value)
    if name == 'SCAN':
        return None
    return repr(value)


class NonInterference(unittest.TestCase):
    LOW = 'C;VETTED'
    HIGH = ('S', 'S//A', 'C//B', 'C', 'U')
    NAMES = ['n%d' % i for i in range(8)]

    def low_command(self, rng):
        k = rng.choice(self.NAMES)
        choice = rng.randrange(20)
        return [
            ('SET', k, rng.randrange(100)), ('GET', k), ('DEL', k), ('INCR', k), ('EXISTS', k, rng.choice(self.NAMES)),
            ('TYPE', k), ('TTL', k), ('EXPIRE', k, 1000), ('RPUSH', k, 'x'), ('LRANGE', k, 0, -1), ('SADD', k, rng.randrange(5)),
            ('SMEMBERS', k), ('SRANDMEMBER', k, 2), ('HSET', k, 'f', 1), ('HGETALL', k), ('DBSIZE',), ('KEYS', '*'),
            ('APPEND', k, 'z'), ('PFADD', k, rng.randrange(9)), ('PFCOUNT', k)][choice]

    def high_command(self, rng):
        k = rng.choice(self.NAMES)
        label = rng.choice(self.HIGH)
        choice = rng.randrange(12)
        return label, [
            ('SET', k, 'h'), ('DEL', k), ('GET', k), ('RPUSH', k, 'y'), ('SADD', k, 'm'), ('HSET', k, 'g', 2),
            ('PFCOUNT', k), ('SRANDMEMBER', k, 3), ('SPOP', k), ('RANDOMKEY',), ('EXPIRE', k, 50), ('FLUSHDB',)][choice]

    def run_world(self, seed, interleave):
        server = start_server(('--label-stream-seed', '5'))
        try:
            low = Client(server.port)
            admin = Client(server.port)
            admin.call('ACL', 'SETUSER', 'default', 'clearance:*', 'trust:*')
            admin.call('CONFIG', 'SET', 'notify-keyspace-events', 'KEA')
            watcher = Client(server.port)
            watcher.call('LABEL', 'SESSION', self.LOW)
            watcher.send('PSUBSCRIBE', '__key*@0__:*')
            watcher.read()
            tracker = Client(server.port)
            tracker.call('HELLO', 3)
            tracker.call('LABEL', 'SESSION', self.LOW)
            tracker.call('CLIENT', 'TRACKING', 'ON')
            rng = random.Random(seed)
            noise = random.Random(seed * 31 + 7)
            replies = []
            for step in range(250):
                command = self.low_command(rng)
                low.send(*AS(self.LOW), *command)
                replies.append(normalise(command, low.reply()))
                if command[0] == 'GET':
                    tracker.send('GET', command[1])
                    tracker.reply()
                if interleave:
                    for _ in range(noise.randrange(3)):
                        label, high = self.high_command(noise)
                        admin.send(*AS(label), *high)
                        admin.reply()
            low.call(*AS(self.LOW), 'SET', 'fence', 1)
            tracker.call('PING')
            time.sleep(0.2)
            watcher.socket.settimeout(0.5)
            messages = []
            while True:
                try:
                    messages.append(repr(watcher.read()))
                except (TimeoutError, socket.timeout, OSError):
                    break
            result = replies, messages, [repr(p) for p in tracker.pushes]
            for client in (low, admin, watcher, tracker):
                client.close()
            return result
        finally:
            server.close()

    def test_hidden_activity_changes_nothing_a_low_reader_observes(self):
        for seed in range(4):
            quiet = self.run_world(seed, False)
            noisy = self.run_world(seed, True)
            self.assertEqual(quiet[0], noisy[0], 'replies, seed %d' % seed)
            self.assertEqual(quiet[1], noisy[1], 'notifications, seed %d' % seed)
            self.assertEqual(quiet[2], noisy[2], 'tracking, seed %d' % seed)


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
