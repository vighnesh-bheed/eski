import argparse
import itertools
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
WRONGTYPE = 'WRONGTYPE Operation against a key holding the wrong kind of value'
WATCH_REFUSED = "EXECABORT Transaction discarded because of: the command's label differs from the transaction's label"


def AS(label):
    return ('LABEL', 'AS', label)


def exec_outcome(client, *prefix):
    client.send(*prefix, 'EXEC')
    value = client.reply()
    return str(value) if isinstance(value, ServerError) else value


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
        self.assertEqual(error_of(self.client, 'LABEL', 'RAISE', 'k', 'U'), "ERR unknown subcommand 'RAISE'. Try LABEL HELP.")
        for command in (('LABEL', 'OF', 'k'), ('LABEL', 'DECLASSIFY', 'k', 'U'),
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
                        ('EXPIRE', 'k', 10), ('PERSIST', 'k'), ('RENAME', 'k', 'z'), ('RENAMENX', 'k', 'z'),
                        ('SET', 'k', 'v', 'XX'), ('SET', 'k', 'v', 'GET'), ('SET', 'k', 'v', 'IFEQ', 'NX'),
                        ('GETDEL', 'k'), ('LPUSH', 'l', 'b'), ('RPOP', 'l'), ('HSETNX', 'k', 'f', 'v'),
                        ('MSET', 'fresh', 1, 'k', 2), ('MOVE', 'k', 1),
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
        self.assertEqual(self.refused('S', 'COPY', 'mine', 'k', 'REPLACE'), expected)
        self.assertEqual(self.at('S', 'COPY', 'mine', 'mine2'), 1)
        self.assertEqual(self.at('S', 'DEL', 'missing', 'mine2'), 1)
        self.assertEqual(self.at('S//A', 'SET', 'deep', 1), 'OK')
        self.assertEqual(self.refused('S//A/B', 'INCR', 'deep'), 'INUSE name in use at S//A')

    def test_create_only_writes_answer_as_for_an_existing_name(self):
        self.at('U', 'SET', 'k', 'u')
        self.at('U', 'RPUSH', 'l', 'a')
        self.assertEqual(self.at('S', 'SET', 'mine', 'm'), 'OK')
        self.c.call('SELECT', 1)
        self.at('U', 'SET', 'mine', 'other')
        self.c.call('SELECT', 0)
        self.c.call('CONFIG', 'SET', 'notify-keyspace-events', 'KEA')
        watcher = self.connect()
        watcher.call('LABEL', 'SESSION', 'S//A/B')
        watcher.call('PSUBSCRIBE', '__key*@*__:*')
        self.assertEqual(self.at('S', 'SETNX', 'k', 'v'), 0)
        self.assertIsNone(self.at('S', 'SET', 'k', 'v', 'NX'))
        self.assertIsNone(self.at('S', 'SET', 'k', 'v', 'NX', 'EX', 100))
        self.assertEqual(self.at('S', 'SET', 'k', 'v', 'NX', 'GET'), b'u')
        self.assertEqual(self.at('S', 'SET', 'k', 'v', 'GET', 'NX', 'KEEPTTL'), b'u')
        self.assertEqual(self.refused('S', 'SET', 'l', 'v', 'NX', 'GET'), WRONGTYPE)
        self.assertEqual(self.refused('S', 'SET', 'k', 'v', 'NX', 'EX', 0), "ERR invalid expire time in 'set' command")
        self.assertEqual(self.refused('S', 'SET', 'k', 'v', 'NX', 'XX'), 'INUSE name in use at U')
        self.assertEqual(self.at('S', 'MSETNX', 'fresh', 1, 'k', 2), 0)
        self.assertEqual(self.at('S', 'MSETNX', 'k', 1, 'mine', 2), 0)
        self.assertEqual(self.at('S', 'RENAMENX', 'mine', 'k'), 0)
        self.assertEqual(self.refused('S', 'RENAMENX', 'missing', 'k'), 'ERR no such key')
        self.assertEqual(self.at('S', 'COPY', 'mine', 'k'), 0)
        self.assertEqual(self.at('S', 'COPY', 'missing', 'k'), 0)
        self.assertEqual(self.at('S', 'COPY', 'mine', 'mine', 'DB', 1), 0)
        self.assertEqual(self.refused('S', 'COPY', 'mine', 'mine', 'DB', 1, 'REPLACE'), 'INUSE name in use at U')
        self.assertEqual(self.at('S', 'MOVE', 'mine', 1), 0)
        self.assertEqual(self.refused('S', 'MOVE', 'k', 1), 'INUSE name in use at U')
        self.assertEqual(self.refused('S', 'RENAMENX', 'k', 'z'), 'INUSE name in use at U')
        self.assertEqual(self.refused('S', 'HSETNX', 'k', 'f', 'v'), 'INUSE name in use at U')
        self.c.call(*AS('S'), 'MULTI')
        self.c.call('SETNX', 'k', 'x')
        self.c.call('SET', 'k', 'x', 'NX', 'GET')
        self.c.call('SET', 'k', 'x')
        result = self.c.call(*AS('S'), 'EXEC')
        self.assertEqual(result[:2], [0, b'u'])
        self.assertEqual(str(result[2]), 'INUSE name in use at U')
        self.assertEqual(self.at('S', 'EVAL', "return redis.call('SETNX', KEYS[1], 'x')", 1, 'k'), 0)
        self.assertEqual(self.at('S', 'EVAL', "return redis.call('MSETNX', KEYS[1], 'x', KEYS[2], 'y')", 2, 'k', 'fresh'), 0)
        self.assertEqual(self.at('U', 'GET', 'k'), b'u')
        self.assertEqual(self.at('U', 'TTL', 'k'), -1)
        self.assertEqual(self.at('S', 'LABEL', 'OF', 'k'), b'U')
        self.assertEqual(self.at('S', 'GET', 'mine'), b'm')
        self.assertIsNone(self.at('S', 'GET', 'fresh'))
        self.assertIsNone(self.at('S', 'GET', 'z'))
        self.assertEqual(self.at('S', 'DBSIZE'), 3)
        self.c.call('SELECT', 1)
        self.assertEqual(self.at('S', 'GET', 'mine'), b'other')
        self.assertEqual(self.at('S', 'LABEL', 'OF', 'mine'), b'U')
        self.c.call('SELECT', 0)
        self.at('U', 'SET', 'fence', 1)
        events = []
        while True:
            message = watcher.reply()
            if message[-1] == b'fence':
                break
            events.append(message)
        self.assertEqual(events, [[b'pmessage', b'__key*@*__:*', b'__keyspace@0__:fence', b'set']])
        self.at('S', 'SET', 'h', 'secret')
        self.assertEqual(self.at('U', 'SETNX', 'h', 'low'), 1)
        self.assertEqual(self.at('U', 'SET', 'h2', 'x', 'NX'), 'OK')
        self.assertEqual(self.at('U', 'GET', 'h'), b'low')
        self.assertEqual(self.at('S', 'GET', 'h'), b'secret')
        self.c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        self.at('U', 'SET', 'gone', 'x', 'PX', 1)
        time.sleep(0.05)
        self.assertEqual(self.at('S', 'SETNX', 'gone', 'y'), 1)
        self.assertEqual(self.at('S', 'LABEL', 'OF', 'gone'), b'S')
        self.c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 1)

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

    def test_randomkey_returns_an_expired_name_while_a_write_pause_holds_expiry(self):
        c = self.c
        self.at('S', 'SET', 'hidden', 'h', 'PX', 3)
        c.call('MULTI')
        c.call('SET', 'key', 'value', 'PX', 3)
        c.call('CLIENT', 'PAUSE', 10000, 'WRITE')
        c.call('EXEC')
        time.sleep(0.05)
        self.assertEqual(c.call('RANDOMKEY'), b'key')
        self.assertIsNone(self.at('U', 'RANDOMKEY'))
        c.call('CLIENT', 'UNPAUSE')
        self.assertIsNone(c.call('RANDOMKEY'))

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

    def test_watch_at_another_label_refuses_exec_whatever_hidden_writes_did(self):
        outcomes = []
        for hidden in (False, True):
            low = self.connect()
            low.call('LABEL', 'SESSION', 'U')
            self.at('S', 'SET', 'w', 'before')
            self.assertEqual(low.call(*AS('S'), 'WATCH', 'w'), 'OK')
            if hidden:
                self.at('S', 'SET', 'w', 'after')
            self.assertEqual(low.call('MULTI'), 'OK')
            self.assertEqual(low.call('SET', 'probe', 1), 'QUEUED')
            outcomes.append(exec_outcome(low))
            self.assertIsNone(self.at('U', 'GET', 'probe'))
            self.at('S', 'DEL', 'w')
        for changed in (False, True):
            low = self.connect()
            low.call('LABEL', 'SESSION', 'U')
            self.at('U', 'SET', 'v', 'before')
            low.call('WATCH', 'v')
            if changed:
                self.at('U', 'SET', 'v', 'after')
            low.call(*AS('S'), 'MULTI')
            low.call('SET', 'probe', 1)
            outcomes.append(exec_outcome(low, *AS('S')))
            self.assertIsNone(self.at('S', 'GET', 'probe'))
            self.at('U', 'DEL', 'v')
        self.assertEqual(outcomes, [WATCH_REFUSED] * 4)

    def test_a_refused_exec_clears_the_watches_and_same_label_watch_keeps_its_rule(self):
        low = self.connect()
        low.call('LABEL', 'SESSION', 'U')

        def transaction(label='U'):
            prefix = () if label == 'U' else AS(label)
            low.call(*prefix, 'MULTI')
            low.call('INCR', 'counter:' + label)
            return exec_outcome(low, *prefix)

        low.call(*AS('S'), 'WATCH', 'w')
        self.assertEqual(transaction(), WATCH_REFUSED)
        self.assertIn(b' watch=0 ', low.call('CLIENT', 'INFO'))
        self.at('S', 'SET', 'w', 'hidden')
        self.assertEqual(transaction(), [1])
        low.call('WATCH', 'w')
        self.at('U', 'SET', 'w', 'seen')
        self.assertIsNone(transaction())
        low.call('WATCH', 'w')
        self.assertEqual(transaction(), [2])
        low.call('WATCH', 'w')
        self.at('S', 'SET', 'w', 'hidden again')
        self.assertEqual(transaction(), [3])
        low.call(*AS('S'), 'WATCH', 'x')
        self.at('C', 'SET', 'x', 'seen from S')
        self.assertIsNone(transaction('S'))
        low.call(*AS('S'), 'WATCH', 'x')
        self.assertEqual(transaction('S'), [1])
        self.assertEqual(self.at('U', 'GET', 'counter:U'), b'3')
        self.assertEqual(self.at('S', 'GET', 'counter:S'), b'1')

    def test_every_watch_label_counts_even_after_a_hidden_write(self):
        outcomes = []
        for hidden in (False, True):
            low = self.connect()
            low.call('LABEL', 'SESSION', 'U')
            self.at('S', 'SET', 'first', 'before')
            low.call(*AS('S'), 'WATCH', 'first')
            if hidden:
                self.at('S', 'SET', 'first', 'after')
            low.call('WATCH', 'second')
            for label in ('S', 'U'):
                low.call(*AS(label), 'MULTI')
                low.call('PING')
                outcomes.append(exec_outcome(low, *AS(label)))
                low.call(*AS('S'), 'WATCH', 'first')
                low.call('WATCH', 'second')
            low.call('UNWATCH')
            self.at('S', 'DEL', 'first')
        self.assertEqual(outcomes, [WATCH_REFUSED] * 4)

    def test_debug_digest_covers_every_label(self):
        plain = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS)))
        self.addCleanup(plain.close)
        plain.start()
        off = Client(plain.port)
        self.addCleanup(off.close)
        for client in (off, self.c):
            client.call('SET', 's', 'v')
            client.call('HSET', 'h', 'f', 'g')
            client.call('RPUSH', 'l', 'a', 'b')
            client.call('VADD', 'vs', 'VALUES', 2, 1, 0, 'a', 'SETATTR', '{"c":1}')
            client.call('VADD', 'vs', 'VALUES', 2, 0, 1, 'b')
        off.call('SET', 'u', 'x')
        self.at('U', 'SET', 'u', 'x')
        names = ('s', 'h', 'l', 'vs', 'u', 'missing')
        self.assertEqual(self.c.call('DEBUG', 'DIGEST-VALUE', *names), off.call('DEBUG', 'DIGEST-VALUE', *names))
        self.assertEqual(self.c.call('DEBUG', 'DIGEST'), off.call('DEBUG', 'DIGEST'))
        self.assertNotEqual(self.c.call('DEBUG', 'DIGEST'), '0' * 40)
        before = self.c.call('DEBUG', 'DIGEST-VALUE', 'vs')
        self.assertNotEqual(before, ['0' * 40])
        self.c.call('VSETATTR', 'vs', 'a', '{"c":2}')
        self.assertNotEqual(self.c.call('DEBUG', 'DIGEST-VALUE', 'vs'), before)

    def test_debug_object_shows_an_expired_key_without_removing_it(self):
        plain = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS)))
        self.addCleanup(plain.close)
        plain.start()
        off = Client(plain.port)
        self.addCleanup(off.close)
        for client in (off, self.c):
            client.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
            client.call('SET', 'gone', 'v', 'PX', 1)
        time.sleep(0.05)
        for client in (off, self.c):
            self.assertIn('encoding:embstr', client.call('DEBUG', 'OBJECT', 'gone'))
            self.assertEqual(client.call('DBSIZE'), 1)
            self.assertEqual(client.call('EXISTS', 'gone'), 0)
            self.assertEqual(client.call('DBSIZE'), 0)
            self.assertEqual(error_of(client, 'DEBUG', 'OBJECT', 'gone'), 'ERR no such key')
            client.call('DEBUG', 'SET-ACTIVE-EXPIRE', 1)
        self.at('U', 'SET', 'low', 'v')
        self.assertIn('encoding:embstr', self.c.call('DEBUG', 'OBJECT', 'low'))

    def test_watch_ignores_stale_keys_on_flush_and_swap(self):
        c = self.c

        def clean_exec(client):
            client.call('MULTI')
            client.call('PING')
            return client.call('EXEC')

        c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        self.at('U', 'SET', 'other', 1)
        c.call('SET', 'x', 'foo', 'PX', 1)
        time.sleep(0.01)
        c.call('WATCH', 'x')
        c.call('FLUSHDB')
        self.assertEqual(clean_exec(c), ['PONG'])
        c.call('FLUSHALL')
        c.call('SELECT', 1)
        c.call('SET', 'x', 'foo', 'PX', 1)
        time.sleep(0.01)
        c.call('WATCH', 'x')
        c.call('SWAPDB', 0, 1)
        self.assertEqual(clean_exec(c), ['PONG'])
        c.call('FLUSHALL')
        c.call('SELECT', 0)
        c.call('SET', 'x', 'foo', 'PX', 1)
        time.sleep(0.01)
        c.call('SELECT', 1)
        c.call('WATCH', 'x')
        c.call('SWAPDB', 0, 1)
        self.assertEqual(clean_exec(c), ['PONG'])
        c.call('FLUSHALL')
        c.call('SELECT', 1)
        c.call('SET', 'x', 'foo', 'PX', 1)
        c.call('SELECT', 0)
        c.call('SET', 'x', 'bar', 'PX', 1)
        time.sleep(0.01)
        c.call('SELECT', 1)
        c.call('WATCH', 'x')
        c.call('SWAPDB', 0, 1)
        self.assertEqual(clean_exec(c), ['PONG'])
        c.call('FLUSHALL')
        c.call('SELECT', 0)
        c.call('SET', 'live', 1)
        c.call('WATCH', 'live')
        c.call('SWAPDB', 0, 1)
        self.assertIsNone(clean_exec(c))
        c.call('SWAPDB', 0, 1)
        c.call('FLUSHALL')
        low = self.connect()
        low.call('LABEL', 'SESSION', 'U')
        self.at('S', 'SET', 'hidden', 1)
        low.call('WATCH', 'hidden')
        c.call('SWAPDB', 0, 1)
        self.assertEqual(clean_exec(low), ['PONG'])
        c.call('SWAPDB', 0, 1)
        low.call('SET', 'mine', 1)
        low.call('WATCH', 'mine')
        c.call('SWAPDB', 0, 1)
        self.assertIsNone(clean_exec(low))
        c.call('SWAPDB', 0, 1)
        low.call('WATCH', 'mine')
        self.at('S', 'FLUSHDB')
        self.assertEqual(clean_exec(low), ['PONG'])
        c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 1)

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

    def test_declassify_moves_one_copy_with_rights_and_audit(self):
        self.at('S', 'SET', 'k', 'secret', 'EX', 1000)
        self.assertEqual(self.at('S', 'LABEL', 'DECLASSIFY', 'k', 'U'), 'OK')
        self.assertEqual(self.at('U', 'GET', 'k'), b'secret')
        self.assertGreater(self.at('U', 'TTL', 'k'), 900)
        self.assertEqual(self.refused('U', 'LABEL', 'DECLASSIFY', 'k', 'S'), "ERR the target label must be below the copy's label")
        self.assertEqual(self.refused('U', 'LABEL', 'DECLASSIFY', 'k', 'NOPE'), INVALID)
        unknown = "ERR unknown subcommand 'RAISE'. Try LABEL HELP."
        self.assertEqual(self.refused('U', 'LABEL', 'RAISE', 'k', 'C'), unknown)
        self.assertEqual(self.refused('S', 'LABEL', 'RAISE', 'k', 'S//A', 'ELEMENT', 'e'), unknown)
        self.assertNotIn(b'label|raise', self.c.call('COMMAND', 'LIST'))
        self.assertFalse(any(b'RAISE' in line for line in (x if isinstance(x, bytes) else str(x).encode() for x in self.c.call('LABEL', 'HELP'))))
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
        self.assertEqual(events.count('declassify'), 2)
        self.assertNotIn('raise', events)

    def test_declassify_follows_the_write_rule_at_its_target(self):
        self.at('S', 'SET', 'n', 'top')
        self.at('U', 'SET', 'n', 'low')
        self.assertEqual(self.refused('S', 'LABEL', 'DECLASSIFY', 'n', 'C'), 'INUSE name in use at U')
        self.assertEqual(self.refused('S', 'LABEL', 'DECLASSIFY', 'n', 'U'), 'INUSE name in use at U')
        self.assertEqual(self.at('S', 'GET', 'n'), b'top')
        self.assertEqual(self.at('U', 'GET', 'n'), b'low')
        self.at('S//A/B', 'SET', 'm', 'both')
        self.at('S//B', 'SET', 'm', 'b')
        self.assertEqual(self.at('S//A/B', 'LABEL', 'DECLASSIFY', 'm', 'S//A'), 'OK')
        self.assertEqual(self.at('S//A', 'GET', 'm'), b'both')
        self.assertEqual(self.at('S//B', 'GET', 'm'), b'b')
        self.assertEqual(sorted(self.c.call('LABEL', 'COPIES', 'm')), [[b'S//A', 'string'], [b'S//B', 'string']])
        self.at('S', 'SET', 'free', 'f')
        self.assertEqual(self.at('S', 'LABEL', 'DECLASSIFY', 'free', 'C'), 'OK')
        self.assertEqual(self.at('S', 'LABEL', 'OF', 'free'), b'C')
        self.at('U', 'VADD', 'v', 'VALUES', 2, 1, 0, 'a')
        self.at('S', 'VADD', 'v', 'VALUES', 2, 0, 1, 'x')
        self.at('S', 'VADD', 'v', 'VALUES', 2, 1, 1, 'y')
        self.at('U', 'VADD', 'v', 'VALUES', 2, 1, 2, 'x')
        self.assertEqual(self.refused('S', 'LABEL', 'DECLASSIFY', 'v', 'C', 'ELEMENT', 'x'), 'INUSE element in use at U')
        self.assertEqual(self.refused('S', 'LABEL', 'DECLASSIFY', 'v', 'U', 'ELEMENT', 'x'), 'INUSE element in use at U')
        self.assertEqual(self.refused('S', 'LABEL', 'DECLASSIFY', 'v', 'C', 'ELEMENT', 'a'), 'INUSE element in use at U')
        self.assertEqual(self.at('S', 'LABEL', 'DECLASSIFY', 'v', 'C', 'ELEMENT', 'y'), 'OK')
        self.assertEqual(self.at('S', 'LABEL', 'OF', 'v', 'y'), b'C')
        self.assertEqual(self.at('S', 'LABEL', 'OF', 'v', 'x'), b'S')
        self.assertEqual(self.at('C', 'VCARD', 'v'), 3)
        self.at('S', 'VADD', 'w', 'VALUES', 2, 1, 0, 'e')
        self.at('U', 'SET', 'w', 'string')
        self.assertEqual(self.refused('S', 'LABEL', 'DECLASSIFY', 'w', 'C', 'ELEMENT', 'e'), 'INUSE name in use at U')
        self.at('S//A', 'VADD', 'z', 'VALUES', 2, 0, 1, 'e')
        self.at('S', 'VADD', 'z', 'VALUES', 2, 1, 0, 'e')
        self.assertEqual(self.at('S', 'LABEL', 'DECLASSIFY', 'z', 'C', 'ELEMENT', 'e'), 'OK')
        self.assertEqual(self.at('S', 'LABEL', 'OF', 'z', 'e'), b'C')
        self.assertEqual(self.at('C', 'VCARD', 'z'), 1)
        self.assertEqual(self.at('S//A', 'LABEL', 'OF', 'z', 'e'), b'S//A')

    def test_label_of_and_copies(self):
        self.at('S//A', 'SET', 'n', 1)
        self.at('S//B', 'SET', 'n', 2)
        self.assertEqual(self.at('S//A/B', 'LABEL', 'OF', 'n'), b'S//A')
        self.assertEqual(self.refused('S', 'LABEL', 'COPIES'), TOP_ERROR)
        self.assertEqual(self.c.call('LABEL', 'COPIES'), [b'n'])
        self.assertEqual(sorted(self.c.call('LABEL', 'COPIES', 'n')), [[b'S//A', 'string'], [b'S//B', 'string']])

    def test_relabel_and_cleanup_subcommands_need_admin_or_dangerous_rights(self):
        c = self.c
        commands = {'label|declassify': ('LABEL', 'DECLASSIFY', 'k', 'U'), 'label|copies': ('LABEL', 'COPIES'),
                    'label|quota': ('LABEL', 'QUOTA', 'U')}
        for name, rules, allowed in (('all-but-dangerous', ('+@all', '-@dangerous'), False), ('all-but-admin', ('+@all', '-@admin'), False),
                                     ('slow-only', ('+@slow',), False), ('write-only', ('+@write',), False),
                                     ('keyspace-only', ('+@keyspace',), False), ('connection-only', ('+@connection',), False),
                                     ('everything', ('+@all',), True), ('dangerous', ('+@dangerous',), True), ('admin', ('+@admin',), True)):
            c.call('ACL', 'SETUSER', name, 'on', 'nopass', *rules, '~*', 'clearance:*', 'trust:*')
            for sub, command in commands.items():
                reply = c.call('ACL', 'DRYRUN', name, *command)
                self.assertEqual(reply == 'OK', allowed, (name, sub, reply))
        for sub, command in commands.items():
            name = 'explicit-' + sub.split('|')[1]
            c.call('ACL', 'SETUSER', name, 'on', 'nopass', '+' + sub, '~*', 'clearance:*', 'trust:*')
            for other, other_command in commands.items():
                reply = c.call('ACL', 'DRYRUN', name, *other_command)
                self.assertEqual(reply == 'OK', other == sub, (name, other, reply))
            self.assertIn(sub.encode(), c.call('ACL', 'CAT', 'dangerous'))
            self.assertIn(sub.encode(), c.call('ACL', 'CAT', 'admin'))
            for category in ('slow', 'fast', 'write', 'keyspace', 'connection'):
                self.assertNotIn(sub.encode(), c.call('ACL', 'CAT', category), (sub, category))
            info = c.call('COMMAND', 'INFO', sub)[0]
            self.assertEqual(sorted(str(x) for x in info[6]), ['@admin', '@dangerous'])
        self.assertEqual(c.call('ACL', 'DRYRUN', 'connection-only', 'LABEL', 'OF', 'k'), 'OK')
        self.assertEqual(c.call('ACL', 'DRYRUN', 'all-but-dangerous', 'LABEL', 'OF', 'k'), 'OK')
        self.assertEqual(sorted(str(x) for x in c.call('COMMAND', 'INFO', 'label|of')[0][6]), ['@connection', '@fast'])
        agent = self.connect()
        agent.call('AUTH', 'all-but-dangerous', 'x')
        agent.call(*AS('S'), 'SET', 'mine', 1)
        self.assertEqual(error_of(agent, *AS('S'), 'LABEL', 'DECLASSIFY', 'mine', 'U'),
                         "NOPERM User all-but-dangerous has no permissions to run the 'label|declassify' command")
        explicit = self.connect()
        explicit.call('AUTH', 'explicit-copies', 'x')
        self.assertEqual(explicit.call('LABEL', 'COPIES'), [])

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
        self.assertEqual(self.c.call('LABEL', 'QUOTA', 'U', 'LIMIT', used // 2), 'OK')
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


class DeclassifyLeavesNothing(unittest.TestCase):
    def world(self, hidden):
        server = start_server(('--label-partitions-max', '3'))
        try:
            c = Client(server.port)
            c.call('ACL', 'SETUSER', 'default', 'clearance:*', 'trust:*')
            c.call(*AS('U'), 'VADD', 'vs', 'VALUES', 2, 0.5, 0.5, 's')
            c.call(*AS('S'), 'VADD', 'vs', 'VALUES', 2, 0.9, 0.1, 'h')
            c.call(*AS('U'), 'SET', 'x', 1)
            out = []
            if hidden is not None:
                out.append(error_of(c, *AS('S'), 'LABEL', 'DECLASSIFY', 'vs', 'C', 'ELEMENT', hidden))
            for label in ('C//A', 'C//B', 'C;VETTED', 'C'):
                c.send(*AS(label), 'SET', 'k', label)
                out.append(repr(c.reply()))
            for label in ('C', 'C//A'):
                cursor = 0
                while True:
                    reply = c.call(*AS(label), 'SCAN', cursor, 'COUNT', 1)
                    out.append(repr(reply))
                    cursor = int(reply[0])
                    if cursor == 0:
                        break
                out.append(repr(c.call(*AS(label), 'DBSIZE')))
            c.close()
            return out
        finally:
            server.close()

    def test_refused_element_declassify_creates_no_partition(self):
        plain = self.world(None)
        for hidden, text in (('nosuch', 'ERR element not found in set'), ('s', 'INUSE element in use at U')):
            noisy = self.world(hidden)
            self.assertEqual(noisy[0], text)
            self.assertEqual(noisy[1:], plain, hidden)


class ManyCopies(unittest.TestCase):
    COMPARTMENTS = ('A', 'B', 'D', 'E', 'F', 'G', 'H', 'I')

    def test_reads_find_a_live_copy_among_more_than_64(self):
        arguments = ('--keyspace-threads', str(KEYSPACE_THREADS), '--label-levels', 'U,C,S',
                     '--label-compartments', ','.join(self.COMPARTMENTS))
        server = Server(BINARY, workers=0, arguments=arguments)
        self.addCleanup(server.close)
        server.start()
        c = Client(server.port)
        self.addCleanup(c.close)
        c.call('ACL', 'SETUSER', 'default', 'clearance:*')
        subsets = list(itertools.combinations(self.COMPARTMENTS, 4))
        labels = ['C//' + '/'.join(subset) for subset in subsets[:64]] + ['S//' + '/'.join(subsets[64])]
        reader = 'S//' + '/'.join(self.COMPARTMENTS)
        c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        for i, label in enumerate(labels):
            if i == 40:
                c.call(*AS(label), 'SET', 'n', 'v%d' % i)
            else:
                c.call(*AS(label), 'SET', 'n', 'v%d' % i, 'PX', 1)
            c.call(*AS(label), 'SET', 'live', 'w%d' % i)
        time.sleep(0.05)
        self.assertEqual(len(c.call('LABEL', 'COPIES', 'live')), 65)
        self.assertEqual(c.call('LABEL', 'COPIES', 'n'), [[labels[40].encode(), 'string']])
        self.assertEqual(c.call(*AS(reader), 'GET', 'n'), b'v40')
        self.assertEqual(c.call(*AS(reader), 'LABEL', 'OF', 'n'), labels[40].encode())
        self.assertEqual(c.call(*AS(reader), 'EXISTS', 'n'), 1)
        self.assertEqual(sorted(c.call(*AS(reader), 'KEYS', '*')), [b'live', b'n'])
        self.assertEqual(c.call(*AS(reader), 'GET', 'live'), b'w64')
        self.assertEqual(c.call(*AS(reader), 'DBSIZE'), 2)
        self.assertEqual(c.call(*AS(labels[40]), 'DEL', 'n'), 1)
        self.assertIsNone(c.call(*AS(reader), 'GET', 'n'))
        self.assertEqual(c.call(*AS(reader), 'EXISTS', 'n'), 0)
        self.assertEqual(c.call(*AS(reader), 'KEYS', '*'), [b'live'])
        self.assertEqual(c.call(*AS(labels[64]), 'DEL', 'live'), 1)
        self.assertEqual(c.call(*AS(reader), 'GET', 'live'), b'w0')
        c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 1)


class RuntimeScheme(unittest.TestCase):
    def test_existing_data_refuses_the_scheme(self):
        server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS)))
        self.addCleanup(server.close)
        server.start()
        c = Client(server.port)
        self.addCleanup(c.close)
        refused = "ERR CONFIG SET failed (possibly related to argument 'label-levels') - a label scheme needs a server without keys, because existing keys carry no label"
        c.call('SET', 'old', 'value')
        c.call('VADD', 'vs', 'VALUES', 2, 1, 0, 'e')
        self.assertEqual(error_of(c, 'CONFIG', 'SET', 'label-levels', 'U,S'), refused)
        self.assertEqual(c.call('DEL', 'old'), 1)
        self.assertEqual(error_of(c, 'CONFIG', 'SET', 'label-levels', 'U,S'), refused)
        self.assertEqual(c.call('GET', 'old'), None)
        self.assertEqual(c.call('VCARD', 'vs'), 1)
        self.assertEqual(c.call('DEL', 'vs'), 1)
        self.assertEqual(c.call('CONFIG', 'SET', 'label-levels', 'U,S'), 'OK')
        c.call('ACL', 'SETUSER', 'default', 'clearance:*')
        self.assertEqual(c.call(*AS('U'), 'SET', 'old', 'value'), 'OK')
        self.assertEqual(c.call(*AS('S'), 'VADD', 'vs', 'VALUES', 2, 0, 1, 'f'), 1)
        self.assertEqual(c.call(*AS('S'), 'VCARD', 'vs'), 1)
        self.assertEqual(c.call(*AS('U'), 'EXISTS', 'vs'), 0)
        self.assertEqual(c.call(*AS('S'), 'LABEL', 'OF', 'old'), b'U')
        self.assertEqual(error_of(c, *AS('S'), 'SET', 'old', 'x'), 'INUSE name in use at U')

    def test_a_watch_from_before_the_scheme_is_a_watch_at_the_lowest_label(self):
        outcomes = []
        for raised, dirty in ((False, False), (False, True), (True, False), (True, True)):
            server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS)))
            self.addCleanup(server.close)
            server.start()
            c = Client(server.port)
            admin = Client(server.port)
            self.addCleanup(c.close)
            self.addCleanup(admin.close)
            c.call('WATCH', 'w')
            if dirty:
                admin.call('SET', 'w', 2)
                admin.call('DEL', 'w')
            admin.call('CONFIG', 'SET', 'label-levels', 'U,S')
            if raised:
                admin.call('ACL', 'SETUSER', 'default', 'clearance:*')
            c.call('MULTI')
            c.call('PING')
            outcomes.append(exec_outcome(c))
        self.assertEqual(outcomes, [['PONG'], None, WATCH_REFUSED, WATCH_REFUSED])


CLIENT_FIELDS = ('flags', 'watch', 'multi', 'multi-mem', 'tot-mem')


def client_fields(text):
    fields = dict(part.split('=', 1) for part in text.decode().split() if '=' in part)
    return tuple(fields[name] for name in CLIENT_FIELDS)


def listed_fields(client, ident):
    for line in client.call('CLIENT', 'LIST').splitlines():
        if line.startswith(b'id=%d ' % ident):
            return client_fields(line)
    raise AssertionError('connection %d is not listed' % ident)


class WatchCounts(unittest.TestCase):
    def setUp(self):
        self.server = start_server()
        self.addCleanup(self.server.close)
        self.admin = self.connect()
        self.admin.call('ACL', 'SETUSER', 'default', 'clearance:*', 'trust:*')

    def connect(self, session=None, port=None):
        client = Client(self.server.port if port is None else port)
        self.addCleanup(client.close)
        if session is not None:
            client.call('LABEL', 'SESSION', session)
        return client

    def twin_run(self, hidden):
        server = start_server()
        self.addCleanup(server.close)
        admin = self.connect(port=server.port)
        admin.call('ACL', 'SETUSER', 'default', 'clearance:*', 'trust:*')
        low, other, observer = (self.connect('U', server.port) for _ in range(3))
        ident, other_ident = low.call('CLIENT', 'ID'), other.call('CLIENT', 'ID')

        def hidden_write(value):
            if hidden:
                admin.call(*AS('S'), 'SET', 'w', value)

        def seen():
            clients = info(observer, 'clients')
            return (client_fields(low.call('CLIENT', 'INFO')), listed_fields(observer, ident),
                    listed_fields(observer, other_ident), clients['watching_clients'], clients['total_watched_keys'])

        views = []
        admin.call(*AS('S'), 'SET', 'w', 'before')
        self.assertEqual(low.call(*AS('S'), 'WATCH', 'w'), 'OK')
        self.assertEqual(other.call('WATCH', 'w'), 'OK')
        hidden_write('after')
        views.append(seen())
        self.assertEqual(low.call('WATCH', 'v'), 'OK')
        hidden_write('again')
        views.append(seen())
        self.assertEqual(low.call('MULTI'), 'OK')
        self.assertEqual(low.call('SET', 'probe', 1), 'QUEUED')
        views.append(listed_fields(observer, ident))
        views.append(exec_outcome(low))
        views.append(seen())
        self.assertEqual(low.call(*AS('S'), 'WATCH', 'w'), 'OK')
        hidden_write('later')
        views.append(seen())
        self.assertEqual(low.call('UNWATCH'), 'OK')
        views.append(seen())
        self.assertIsNone(admin.call(*AS('U'), 'GET', 'probe'))
        self.assertEqual(admin.call(*AS('S'), 'GET', 'w'), b'later' if hidden else b'before')
        return views

    def test_watch_count_and_client_memory_are_the_same_with_and_without_a_hidden_write(self):
        quiet = self.twin_run(False)
        noisy = self.twin_run(True)
        self.assertEqual(quiet, noisy)
        first, second, queued, outcome, refused, rewatched, unwatched = noisy
        self.assertEqual(first[0][:2], ('N', '1'))
        self.assertEqual(first[0], first[1])
        self.assertEqual(first[2][:2], ('N', '1'))
        self.assertEqual(first[3:], ('0', '0'))
        self.assertEqual(second[0][:2], ('N', '2'))
        self.assertEqual(queued[:3], ('x', '2', '1'))
        self.assertGreater(int(queued[3]), 0)
        self.assertEqual(outcome, WATCH_REFUSED)
        self.assertEqual((refused[0][1], refused[1][1], refused[2][1]), ('0', '0', '1'))
        self.assertEqual(rewatched[0][:2], ('N', '1'))
        self.assertEqual((unwatched[0][1], unwatched[1][1], unwatched[2][1]), ('0', '0', '1'))

    def test_the_dirty_flag_shows_only_to_labels_that_dominate_every_watch(self):
        low = self.connect('U')
        ident = low.call('CLIENT', 'ID')
        lower, higher = self.connect('U'), self.connect('S')

        def flags():
            return (client_fields(low.call('CLIENT', 'INFO'))[0], client_fields(low.call(*AS('S'), 'CLIENT', 'INFO'))[0],
                    listed_fields(lower, ident)[0], listed_fields(higher, ident)[0], listed_fields(self.admin, ident)[0])

        low.call(*AS('S'), 'WATCH', 'w')
        self.admin.call(*AS('S'), 'SET', 'w', 'hidden')
        self.assertEqual(flags(), ('N', 'd', 'N', 'd', 'd'))
        low.call('WATCH', 'v')
        self.assertEqual(flags(), ('N', 'd', 'N', 'd', 'd'))
        self.assertEqual(client_fields(low.call('CLIENT', 'INFO'))[1], '2')
        low.call('MULTI')
        self.assertEqual(exec_outcome(low), WATCH_REFUSED)
        self.assertEqual(flags(), ('N', 'N', 'N', 'N', 'N'))

    def test_a_visible_write_marks_a_same_label_transaction_and_keeps_its_keys(self):
        low, observer = self.connect('U'), self.connect('U')
        ident = low.call('CLIENT', 'ID')
        self.admin.call(*AS('U'), 'SET', 'w', 'before')
        low.call('WATCH', 'w', 'x')
        self.admin.call(*AS('U'), 'SET', 'w', 'seen')
        self.admin.call(*AS('U'), 'SET', 'w', 'seen again')
        self.assertEqual(client_fields(low.call('CLIENT', 'INFO'))[:2], ('d', '2'))
        self.assertEqual(listed_fields(observer, ident)[:2], ('d', '2'))
        self.assertEqual(info(self.admin, 'clients')['total_watched_keys'], '2')
        self.assertEqual(low.call('MULTI'), 'OK')
        self.assertEqual(low.call('SET', 'probe', 1), 'QUEUED')
        self.assertEqual(listed_fields(observer, ident)[:3], ('xd', '2', '1'))
        self.assertIsNone(exec_outcome(low))
        self.assertIsNone(self.admin.call(*AS('U'), 'GET', 'probe'))
        self.assertEqual(client_fields(low.call('CLIENT', 'INFO'))[:3], ('N', '0', '-1'))
        self.assertEqual(info(self.admin, 'clients')['total_watched_keys'], '0')
        low.call('WATCH', 'w')
        self.admin.call(*AS('U'), 'SET', 'w', 'third')
        self.assertEqual(client_fields(low.call('CLIENT', 'INFO'))[:2], ('d', '1'))
        self.assertEqual(low.call('UNWATCH'), 'OK')
        self.assertEqual(client_fields(low.call('CLIENT', 'INFO'))[:2], ('N', '0'))
        low.call('MULTI')
        low.call('INCR', 'counter')
        self.assertEqual(exec_outcome(low), [1])


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
