import argparse
import os
from pathlib import Path
import struct
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
import scoped_log as sl
from support import ServerError

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0


def info(c, name='items', scope=()):
    row = c.call(*scope, 'FT.INFO', name)
    return dict(zip(row[::2], row[1::2]))


def create(c, name='items', scope=(), options=(), schema=('body', 'TEXT', 'NOSTEM')):
    return c.call(*scope, 'FT.CREATE', name, 'PREFIX', 1, 'item:', *options, 'SCHEMA', *schema)


class SearchMaintenance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='eski-search-index-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.servers = []

    def server(self, mode='', extra=()):
        directory = self.root / str(len(self.servers))
        directory.mkdir()
        server = sl.Server(BINARY, directory, mode, extra, KEYSPACE_THREADS)
        self.servers.append(server)
        self.addCleanup(server.kill)
        client = server.up()
        self.addCleanup(client.close)
        return client

    def counts(self, c, expected, name='items', scope=()):
        row = info(c, name, scope)
        self.assertEqual(tuple(row[name] for name in ('num_docs', 'num_terms', 'num_records')), expected)
        return row

    def wait_for_deadline(self, c, deadline, scope=()):
        end = time.monotonic() + 6
        while time.monotonic() < end:
            seconds, micros = (int(t) for t in c.call(*scope, 'TIME'))
            if seconds * 1000 + micros // 1000 > deadline:
                return
        self.fail('server clock did not pass key or hash-field expiry deadline')

    def test_initial_scan_skip_and_full_document_updates(self):
        c = self.server()
        c.call('HSET', 'item:before', 'body', 'zebra', 'other', 'present')
        c.call('HSET', 'outside', 'body', 'ignore')
        c.call('SET', 'item:string', 'ignore')
        self.assertEqual(create(c), 'OK')
        self.assertEqual(create(c, 'skip', options=('SKIPINITIALSCAN',)), 'OK')
        self.counts(c, (1, 1, 1))
        self.counts(c, (0, 0, 0), 'skip')
        c.call('HMSET', 'item:before', 'body', 'giraffe llama')
        for name in ('items', 'skip'):
            self.counts(c, (1, 2, 2), name)
        c.call('HSETNX', 'item:before', 'body', 'ignored')
        self.counts(c, (1, 2, 2))
        c.call('HDEL', 'item:before', 'body', 'other')
        row = self.counts(c, (0, 0, 0))
        self.assertEqual(row['hash_indexing_failures'], 1)
        self.assertEqual(c.call('EXISTS', 'item:before'), 0)

    def test_numeric_vector_errors_and_recovery(self):
        c = self.server()
        self.assertEqual(create(c, schema=('body', 'TEXT', 'NOSTEM', 'qty', 'NUMERIC',
                                           'v', 'VECTOR', 'FLAT', 6, 'TYPE', 'FLOAT32',
                                           'DIM', 2, 'DISTANCE_METRIC', 'L2')), 'OK')
        c.call('HSET', 'item:n', 'body', 'first', 'qty', 6, 'v', struct.pack('<ff', 1, 2))
        self.assertEqual(info(c)['num_docs'], 1)
        c.call('HINCRBY', 'item:n', 'qty', 2)
        c.call('HINCRBYFLOAT', 'item:n', 'qty', '.5')
        self.assertEqual(c.call('HGET', 'item:n', 'qty'), b'8.5')
        c.call('HSET', 'item:n', 'qty', 'broken')
        c.call('HSET', 'item:v', 'body', 'second', 'v', b'short')
        row = self.counts(c, (0, 0, 0))
        self.assertEqual(row['hash_indexing_failures'], 2)
        field_errors = [dict(zip(f[::2], f[1::2]))['Index Errors'] for f in row['field statistics']]
        self.assertEqual([f[1] for f in field_errors], [0, 1, 1])
        self.assertEqual(dict(zip(row['Index Errors'][::2], row['Index Errors'][1::2]))['last indexing error key'], b'item:v')
        c.call('HSET', 'item:n', 'qty', 7)
        self.assertEqual(info(c)['num_docs'], 1)
        c.call('HSET', 'item:v', 'v', struct.pack('<ff', 2, 3))
        self.assertEqual(info(c)['num_docs'], 2)

    def test_rename_copy_move_swap_restore_overwrite_and_delete(self):
        c = self.server()
        self.assertEqual(create(c), 'OK')
        c.call('HSET', 'item:a', 'body', 'first')
        before = self.counts(c, (1, 1, 1))
        c.call('RENAME', 'item:a', 'item:b')
        self.assertEqual(self.counts(c, (1, 1, 1))['max_doc_id'], before['max_doc_id'])
        c.call('RENAME', 'item:b', 'outside')
        self.counts(c, (0, 0, 0))
        c.call('RENAMENX', 'outside', 'item:c')
        self.assertGreater(self.counts(c, (1, 1, 1))['max_doc_id'], before['max_doc_id'])
        c.call('HSET', 'item:d', 'body', 'second')
        c.call('COPY', 'item:c', 'item:d', 'REPLACE')
        self.counts(c, (2, 1, 2))
        dump = c.call('DUMP', 'item:d')
        c.call('RESTORE', 'item:e', 0, dump)
        self.counts(c, (3, 1, 3))
        c.call('SET', 'item:d', 'replacement')
        c.call('UNLINK', 'item:e')
        self.counts(c, (1, 1, 1))
        c.call('MOVE', 'item:c', 1)
        self.counts(c, (0, 0, 0))
        c.call('SELECT', 1)
        c.call('HSET', 'item:otherdb', 'body', 'third')
        self.counts(c, (0, 0, 0))
        c.call('MOVE', 'item:c', 0)
        self.counts(c, (1, 1, 1))
        c.call('SWAPDB', 0, 1)
        self.counts(c, (1, 1, 1))
        c.call('SELECT', 0)
        c.call('DEL', 'item:otherdb')
        self.counts(c, (0, 0, 0))

    def test_pending_key_and_field_expiry_are_excluded_from_info(self):
        c = self.server()
        c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        self.assertEqual(create(c), 'OK')
        c.call('HSET', 'item:key', 'body', 'expiredkey')
        c.call('HSET', 'item:field', 'body', 'expiredfield', 'other', 'survives')
        c.call('HSET', 'item:allfields', 'body', 'expireallfields')
        c.call('HSET', 'item:live', 'body', 'survives')
        self.counts(c, (4, 4, 4))
        c.call('PEXPIRE', 'item:key', 120)
        c.call('HPEXPIRE', 'item:field', 120, 'FIELDS', 1, 'body')
        c.call('HPEXPIRE', 'item:allfields', 120, 'FIELDS', 1, 'body')
        deadline = c.call('HPEXPIRETIME', 'item:allfields', 'FIELDS', 1, 'body')[0]
        self.wait_for_deadline(c, deadline)
        self.counts(c, (2, 1, 1))
        self.assertEqual(c.call('DBSIZE'), 4)
        self.assertIsNone(c.call('HGET', 'item:field', 'body'))
        self.assertIsNone(c.call('HGET', 'item:key', 'body'))
        self.counts(c, (2, 1, 1))
        c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 1)
        end = time.monotonic() + 6
        while c.call('DBSIZE') != 2 and time.monotonic() < end:
            pass
        self.assertEqual(c.call('DBSIZE'), 2)
        self.counts(c, (2, 1, 1))

    def test_scoped_initial_scan_info_flush_and_dd(self):
        c = self.server('labels')
        low, mid, high = (sl.at('labels', l) for l in ('U', 'C', 'S'))
        top = sl.top('labels')
        c.call(*high, 'HSET', 'item:base', 'body', 'secret')
        for name, scope, value in (('base', low, 'hello'), ('mid', mid, 'raccoon'), ('high', high, 'hidden')):
            c.call(*scope, 'HSET', 'item:' + name, 'body', value)
        c.call(*low, 'HSET', 'keep', 'body', 'unmatched')
        self.assertEqual(create(c, scope=low), 'OK')
        self.counts(c, (1, 1, 1), scope=low)
        self.counts(c, (2, 2, 2), scope=mid)
        self.counts(c, (4, 4, 4), scope=high)
        with self.assertRaisesRegex(ServerError, 'INUSE index in use'):
            c.call(*high, 'FT.DROPINDEX', 'items', 'DD')
        self.assertEqual(c.call(*mid, 'FLUSHDB'), 'OK')
        self.counts(c, (3, 3, 3), scope=high)
        self.assertEqual(c.call(*low, 'FT.DROPINDEX', 'items', 'DD'), 'OK')
        self.assertEqual(c.call(*low, 'EXISTS', 'item:base'), 0)
        self.assertEqual(c.call(*high, 'HGET', 'item:base', 'body'), b'secret')
        self.assertEqual(c.call(*high, 'HGET', 'item:high', 'body'), b'hidden')
        self.assertEqual(c.call(*low, 'EXISTS', 'keep'), 1)
        self.assertEqual(c.call(*top, 'FT._LIST'), [])

    def test_owner_partitions_errors_and_forget_do_not_change_siblings(self):
        c = self.server('both')
        shared, first, second = (sl.at('both', 'C', o) for o in (None, 'alice', 'bob'))
        top = sl.top('both')
        self.assertEqual(create(c, scope=shared, schema=('body', 'TEXT', 'NOSTEM', 'qty', 'NUMERIC')), 'OK')
        c.call(*second, 'HSET', 'item:key', 'body', 'bob')
        c.call(*shared, 'HSET', 'item:key', 'body', 'shared')
        before = info(c, scope=second)
        c.call(*first, 'HSET', 'item:hidden', 'body', 'alice', 'qty', 'bad')
        c.call(*first, 'HSET', 'item:own', 'body', 'alice')
        self.assertEqual(info(c, scope=second), before)
        self.assertEqual(info(c, scope=first)['hash_indexing_failures'], 1)
        self.assertEqual(info(c, scope=top)['hash_indexing_failures'], 0)
        c.call(*first, 'DEL', 'item:own', 'item:hidden')
        self.assertEqual(info(c, scope=first)['hash_indexing_failures'], 1)
        self.assertEqual(c.call(*first, 'FLUSHDB'), 'OK')
        self.assertEqual(info(c, scope=first)['hash_indexing_failures'], 0)
        c.call(*first, 'HSET', 'item:hidden', 'body', 'alice', 'qty', 'bad')
        c.call(*first, 'DEL', 'item:hidden')
        self.assertEqual(c.call(*top, 'OWNERS', 'FORGET', 'alice')[1], 0)
        self.assertEqual(info(c, scope=second), before)
        self.assertEqual(info(c, scope=first)['hash_indexing_failures'], 0)
        self.assertEqual(c.call(*shared, 'FT.DROPINDEX', 'items', 'DD'), 'OK')
        self.assertEqual(c.call(*shared, 'EXISTS', 'item:key'), 0)
        self.assertEqual(c.call(*second, 'HGET', 'item:key', 'body'), b'bob')

    def test_global_eviction_removes_live_index_records(self):
        c = self.server()
        self.assertEqual(create(c), 'OK')
        c.call('CONFIG', 'SET', 'maxmemory-policy', 'volatile-ttl')
        for i in range(16):
            key = f'item:{i}'
            c.call('HSET', key, 'body', 'retained', 'padding', 'p' * 8192)
            c.call('PEXPIREAT', key, 4102444800000 + i)
        self.counts(c, (16, 1, 16))
        memory = dict(line.split(b':', 1) for line in c.call('INFO', 'memory').splitlines() if b':' in line)
        c.call('CONFIG', 'SET', 'maxmemory', int(memory[b'used_memory']) - 24000)
        c.call('SET', 'trigger', 'value')
        c.call('CONFIG', 'SET', 'maxmemory', 0)
        remaining = c.call('DBSIZE') - 1
        self.assertGreater(remaining, 0)
        self.assertLess(remaining, 16)
        self.counts(c, (remaining, 1, remaining))

    def test_pipeline_exec_and_lua_publish_before_reading(self):
        c = self.server()
        rows = c.pipeline([('HSET', 'item:first', 'body', 'first'), ('FT.CREATE', 'items', 'PREFIX', 1, 'item:',
                          'SCHEMA', 'body', 'TEXT', 'NOSTEM'), ('HSET', 'item:second', 'body', 'second'),
                          ('SET', 'elsewhere', 'ordinary'), ('FT.INFO', 'items'),
                          ('COPY', 'item:first', 'item:third'), ('FT.INFO', 'items')])
        self.assertEqual(rows[:4], [1, 'OK', 1, 'OK'])
        self.assertEqual(dict(zip(rows[4][::2], rows[4][1::2]))['num_docs'], 2)
        self.assertEqual(dict(zip(rows[6][::2], rows[6][1::2]))['num_docs'], 3)
        c.call('MULTI')
        c.call('HSET', 'item:tx', 'body', 'transaction')
        c.call('FT.INFO', 'items')
        tx = c.call('EXEC')[1]
        self.assertEqual(dict(zip(tx[::2], tx[1::2]))['num_docs'], 4)
        script = "redis.call('HSET',KEYS[1],'body','script'); local r=redis.call('FT.INFO','items'); for i=1,#r,2 do if (type(r[i])=='table' and r[i].ok or r[i])=='num_docs' then return r[i+1] end end"
        self.assertEqual(c.call('EVAL', script, 1, 'item:lua'), 5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', default=str(BINARY))
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--ports', default=os.getenv('ESKI_SEARCH_PORTS', ''))
    args, names = parser.parse_known_args()
    BINARY = Path(args.server).resolve()
    KEYSPACE_THREADS = args.keyspace_threads
    if args.ports:
        sl.use_ports(args.ports)
    unittest.main(argv=[sys.argv[0]] + names, verbosity=1)
