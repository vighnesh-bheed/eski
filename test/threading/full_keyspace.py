import argparse
from concurrent.futures import ThreadPoolExecutor
import fnmatch
import os
from pathlib import Path
import signal
import sys
import time
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from support import ROOT, Server, ServerError, encode, info

BINARY = ROOT / 'bin/eski'


class FullKeyspace(unittest.TestCase):
    def setUp(self):
        self.server = Server(BINARY, workers=0, arguments=(
            '--keyspace-threads', '4', '--keyspace-max-memory', str(16 << 20)), queue_ping=True)
        self.server.start()
        self.addCleanup(self.server.close)
        self.client = self.server.client()

    def assert_pipeline(self, commands, expected, client=None):
        self.assertEqual((client or self.client).pipeline(commands), expected)

    def test_conditional_options_and_ttl_preservation(self):
        c = self.client
        self.assert_pipeline([
            ('SET', 'k', 'one', 'NX'), ('SET', 'k', 'two', 'NX', 'GET'),
            ('SET', 'k', 'three', 'XX', 'GET'), ('GET', 'k'),
            ('SET', 'missing', 'x', 'XX'), ('SETNX', 'k', 'x'),
            ('SETNX', 'other', 'v'), ('GETSET', 'k', 'four'),
        ], ['OK', b'one', b'one', b'three', None, 0, 1, b'three'])
        self.assertEqual(c.call('SET', 'k', 'ttl', 'PX', 30000), 'OK')
        self.assertEqual(c.call('SET', 'k', 'kept', 'KEEPTTL', 'GET'), b'ttl')
        ttl = c.call('PTTL', 'k')
        self.assertGreater(ttl, 25000)
        self.assertLessEqual(ttl, 30000)
        self.assertEqual(c.call('GETEX', 'k', 'PERSIST'), b'kept')
        self.assertEqual(c.call('PTTL', 'k'), -1)
        self.assert_pipeline([('SETEX', 'seconds', 30, 's'),
                              ('PSETEX', 'milliseconds', 30000, 'm'),
                              ('GETDEL', 'k'), ('GETDEL', 'k')], ['OK', 'OK', b'kept', None])
        self.assertGreater(c.call('TTL', 'seconds'), 25)
        self.assertGreater(c.call('PTTL', 'milliseconds'), 25000)

    def test_ranges_increments_and_binary_values(self):
        self.assert_pipeline([
            ('APPEND', 's', b'a\x00b'), ('APPEND', 's', b'\xff'), ('STRLEN', 's'),
            ('GETRANGE', 's', -3, -1), ('SETRANGE', 's', 6, b'z'),
            ('GET', 's'), ('SETRANGE', 'absent', 100, b''), ('EXISTS', 'absent'),
            ('INCR', 'n'), ('INCRBY', 'n', 40), ('DECR', 'n'),
            ('DECRBY', 'n', -2), ('INCRBYFLOAT', 'n', '.5'), ('GET', 'n'),
        ], [3, 4, 4, b'\x00b\xff', 7, b'a\x00b\xff\x00\x00z', 0, 0,
            1, 41, 40, 42, b'42.5', b'42.5'])

    def test_atomic_multi_key_duplicates_and_noop_conditions(self):
        self.assert_pipeline([
            ('MSET', 'a', '1', 'b', '2', 'a', '3'),
            ('MGET', 'a', 'b', 'a', 'absent'),
            ('MSETNX', 'a', 'changed', 'c', 'no'), ('GET', 'c'),
            ('MSETNX', 'x', '1', 'x', '2', 'y', '3'),
            ('MGET', 'x', 'y'), ('EXISTS', 'a', 'a', 'missing'),
            ('TOUCH', 'a', 'a', 'missing'), ('DEL', 'a', 'a', 'missing'),
            ('MGET', 'a', 'b'), ('TYPE', 'b'), ('TYPE', 'a'),
        ], ['OK', [b'3', b'2', b'3', None], 0, None, 1, [b'2', b'3'],
            2, 2, 1, [None, b'2'], 'string', 'none'])

    def test_concurrent_atomic_multi_key_visibility(self):
        c = self.client
        keys = [f'atomic:{i}' for i in range(12)]
        c.call('MSET', *sum(([key, '0'] for key in keys), []))

        def write():
            client = self.server.client()
            try:
                for value in range(1, 45):
                    client.call('MSET', *sum(([key, str(value)] for key in reversed(keys)), []))
            finally:
                client.close()

        def read():
            client = self.server.client()
            try:
                for _ in range(60):
                    values = client.call('MGET', *keys)
                    self.assertEqual(len(set(values)), 1, values)
            finally:
                client.close()

        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(write), *(pool.submit(read) for _ in range(3))]
            for future in futures:
                future.result(timeout=30)
        self.assertEqual(c.call('MGET', *keys), [b'44'] * len(keys))

    def test_expiry_flags_absolute_deadlines_and_lazy_expiry(self):
        c = self.client
        self.assert_pipeline([
            ('SET', 'k', 'v'), ('PEXPIRE', 'k', 30000, 'NX'),
            ('PEXPIRE', 'k', 1000, 'NX'), ('PEXPIRE', 'k', 40000, 'GT'),
            ('PEXPIRE', 'k', 50000, 'LT'), ('PERSIST', 'k'),
            ('PEXPIRE', 'k', 30000, 'XX'), ('PERSIST', 'k'),
        ], ['OK', 1, 0, 1, 0, 1, 0, 0])
        at = int(time.time() * 1000) + 30000
        self.assertEqual(c.call('PEXPIREAT', 'k', at), 1)
        self.assertEqual(c.call('PEXPIRETIME', 'k'), at)
        self.assertEqual(c.call('GETEX', 'k', 'PXAT', 1), b'v')
        self.assert_pipeline([('GET', 'k'), ('PTTL', 'k')], [None, -2])
        c.call('SET', 'short', 'v', 'PX', 20)
        time.sleep(.04)
        self.assert_pipeline([('GET', 'short'), ('EXISTS', 'short')], [None, 0])

    def test_error_replay_keeps_same_owner_fifo_and_exact_errors(self):
        c = self.client
        commands = [('SET', 'n', '1'), ('INCRBY', 'n', 'bad'), ('INCR', 'n'),
                    ('SET', 'n', '9223372036854775807'), ('INCR', 'n'),
                    ('GET', 'n'), ('SET', 'n', 'after'), ('GET', 'n')]
        result = c.pipeline(commands)
        self.assertEqual(result[0], 'OK')
        self.assertIsInstance(result[1], ServerError)
        self.assertIn('not an integer', str(result[1]))
        self.assertEqual(result[2:4], [2, 'OK'])
        self.assertIsInstance(result[4], ServerError)
        self.assertIn('overflow', str(result[4]))
        self.assertEqual(result[5:], [b'9223372036854775807', 'OK', b'after'])
        c.call('HSET', 'hash', 'f', 'v')
        result = c.pipeline([('MGET', 'hash', 'n'), ('GET', 'hash'),
                             ('SET', 'hash', 'string'), ('GET', 'hash')])
        self.assertEqual(result[0], [None, b'after'])
        self.assertIsInstance(result[1], ServerError)
        self.assertEqual(result[2:], ['OK', b'string'])

    def test_budget_fallback_preserves_accepted_mutations_after_disconnect(self):
        with Server(BINARY, workers=0, arguments=('--keyspace-threads', '2',
                    '--keyspace-max-memory', str(16 << 10)), queue_ping=True) as server:
            client = server.client()
            payload = b'x' * (32 << 10)
            client.send_many([('SET', 'k', 'start'), ('APPEND', 'k', payload),
                              ('MSET', 'a', 'left', 'b', 'right')])
            client.socket.shutdown(1)
            self.assertEqual(client.reply(), 'OK')
            self.assertEqual(client.reply(), len(payload) + 5)
            self.assertEqual(client.reply(), 'OK')
            client.close()
            observer = server.client()
            self.assertEqual(observer.call('GET', 'k'), b'start' + payload)
            self.assertEqual(observer.call('MGET', 'a', 'b'), [b'left', b'right'])

    def test_new_commands_really_enter_worker_path(self):
        c = self.client
        before = int(info(c, 'server')['keyspace_jobs_submitted'])
        self.assert_pipeline([('MSET', 'a', '1', 'b', '2'), ('MGET', 'a', 'b'),
                              ('APPEND', 'a', 'x'), ('GETRANGE', 'a', 0, -1),
                              ('SET', 'a', 'v', 'XX', 'GET'), ('INCR', 'counter')],
                             ['OK', [b'1', b'2'], 2, b'1x', b'1x', 1])
        after = int(info(c, 'server')['keyspace_jobs_submitted'])
        self.assertGreaterEqual(after - before, 6)


    def test_list_commands_mutate_clones_and_keep_replies(self):
        self.assert_pipeline([
            ('LPUSH', 'l', '1', '2', '3'), ('RPUSH', 'l', '4'),
            ('LRANGE', 'l', 0, -1), ('LLEN', 'l'), ('LINDEX', 'l', -1),
            ('LPOS', 'l', '2'), ('LPOS', 'l', '1', 'COUNT', 0),
            ('LSET', 'l', 1, 'middle'), ('LINSERT', 'l', 'BEFORE', '1', 'before'),
            ('LREM', 'l', 0, 'middle'), ('LPOP', 'l', 2), ('RPOP', 'l'),
            ('LRANGE', 'l', 0, -1), ('LTRIM', 'l', 10, -1), ('TYPE', 'l'),
            ('LPUSHX', 'l', 'absent'), ('LPOS', 'l', 'x'),
            ('LPOS', 'l', 'x', 'COUNT', 0), ('LPOP', 'l', 0),
        ], [3, 4, [b'3', b'2', b'1', b'4'], 4, b'4', 1, [2], 'OK', 5,
            1, [b'3', b'before'], b'4', [b'1'], 'OK', 'none', 0, None, [], None])

    def test_list_multi_key_moves_and_pop_are_atomic(self):
        self.assert_pipeline([
            ('RPUSH', 'a', '1', '2', '3'), ('RPUSH', 'b', 'x'),
            ('LMOVE', 'a', 'b', 'RIGHT', 'LEFT'),
            ('LRANGE', 'a', 0, -1), ('LRANGE', 'b', 0, -1),
            ('RPOPLPUSH', 'a', 'a'), ('LRANGE', 'a', 0, -1),
            ('LMPOP', 3, 'missing', 'b', 'a', 'LEFT', 'COUNT', 2),
            ('LMPOP', 2, 'b', 'a', 'RIGHT', 'COUNT', 10),
            ('LMPOP', 2, 'a', 'b', 'LEFT'), ('MGET', 'a', 'b'),
        ], [3, 1, b'3', [b'1', b'2'], [b'3', b'x'], b'2', [b'2', b'1'],
            [b'b', [b'3', b'x']], [b'a', [b'1', b'2']], None, [None, None]])

    def test_list_type_replacements_and_ttl_metadata(self):
        c = self.client
        self.assertEqual(c.call('RPUSH', 'l', 'a', 'b'), 2)
        self.assertEqual(c.call('MGET', 'l'), [None])
        c.call('SET', 's', 'string')
        result = c.pipeline([('GET', 'l'), ('SET', 'l', 'string', 'GET'),
                             ('LPUSH', 's', 'c'), ('LLEN', 's')])
        self.assertTrue(all(isinstance(value, ServerError) for value in result))
        self.assertEqual(c.call('PEXPIRE', 'l', 30000), 1)
        self.assertEqual(c.call('LPOP', 'l'), b'a')
        self.assertGreater(c.call('PTTL', 'l'), 25000)
        self.assertEqual(c.call('SET', 'l', 'string'), 'OK')
        self.assertEqual(c.call('GET', 'l'), b'string')
        self.assertEqual(c.call('PTTL', 'l'), -1)
        self.assertEqual(c.call('DEL', 'l'), 1)
        self.assertEqual(c.call('RPUSH', 'l', 'new'), 1)
        self.assertEqual(c.call('LRANGE', 'l', 0, -1), [b'new'])

    def test_list_noops_and_element_dirty_accounting(self):
        c = self.client
        def dirty():
            return int(info(c, 'persistence')['rdb_changes_since_last_save'])
        before = dirty()
        self.assertEqual(c.call('RPUSH', 'l', 'a', 'b', 'a', 'c'), 4)
        self.assertEqual(dirty() - before, 4)
        before = dirty()
        self.assert_pipeline([('LPOP', 'l', 0), ('LINSERT', 'l', 'AFTER', 'missing', 'x'),
                              ('LREM', 'l', 0, 'missing'), ('LTRIM', 'l', 0, -1),
                              ('LPUSHX', 'missing', 'x'), ('DEL', 'missing'),
                              ('PERSIST', 'missing'), ('PEXPIRE', 'missing', 1000)],
                             [[], -1, 0, 'OK', 0, 0, 0, 0])
        self.assertEqual(dirty(), before)
        self.assertEqual(c.call('LREM', 'l', 0, 'a'), 2)
        self.assertEqual(dirty() - before, 2)
        before = dirty()
        self.assertEqual(c.call('LTRIM', 'l', 0, 0), 'OK')
        self.assertEqual(dirty() - before, 1)

    def test_list_quicklist_and_encoding_after_string_mutations(self):
        c = self.client
        c.call('CONFIG', 'SET', 'list-max-listpack-size', 2)
        self.assertEqual(c.call('RPUSH', 'l', *range(20)), 20)
        self.assertEqual(c.call('LRANGE', 'l', -4, -1), [b'16', b'17', b'18', b'19'])
        self.assertEqual(c.call('LPOP', 'l', 3), [b'0', b'1', b'2'])
        self.assertEqual(c.call('LSET', 'l', -1, 'last'), 'OK')
        self.assertEqual(c.call('LINDEX', 'l', -1), b'last')
        self.assertEqual(c.call('SET', 's', '1'), 'OK')
        self.assertEqual(c.call('APPEND', 's', ''), 1)
        self.assertEqual(c.call('OBJECT', 'ENCODING', 's'), b'raw')
        self.assertEqual(c.call('INCRBYFLOAT', 'f', 1), b'1')
        self.assertEqual(c.call('OBJECT', 'ENCODING', 'f'), b'embstr')


    def test_bitmap_options_and_atomic_bitop(self):
        self.assert_pipeline([
            ('SETBIT', 'bits', 7, 1), ('SETBIT', 'bits', 8, 1),
            ('GETBIT', 'bits', 7), ('BITCOUNT', 'bits'),
            ('BITCOUNT', 'bits', 0, 7, 'BIT'), ('BITPOS', 'bits', 1),
            ('BITFIELD', 'bf', 'SET', 'u8', 0, 250, 'OVERFLOW', 'SAT',
             'INCRBY', 'u8', 0, 10, 'OVERFLOW', 'FAIL', 'INCRBY', 'u8', 0, 1),
            ('BITFIELD_RO', 'bf', 'GET', 'u8', 0),
            ('SET', 'a', b'\x0f'), ('SET', 'b', b'\xf0'),
            ('BITOP', 'OR', 'out', 'a', 'b'), ('GET', 'out'),
            ('BITOP', 'XOR', 'b', 'a', 'b'), ('GET', 'b'),
        ], [0, 0, 1, 2, 1, 7, [0, 255, None], [255], 'OK', 'OK', 1, b'\xff', 1, b'\xff'])

    def test_hll_cache_merge_and_debug_options(self):
        c = self.client
        self.assert_pipeline([
            ('PFADD', 'h1', 'a', 'b'), ('PFADD', 'h1', 'a'),
            ('PFADD', 'h2', 'b', 'c'), ('PFCOUNT', 'h1'), ('PFCOUNT', 'h1'),
            ('PFCOUNT', 'h1', 'h2'), ('PFMERGE', 'merged', 'h1', 'h2'),
            ('PFCOUNT', 'merged'), ('PFDEBUG', 'ENCODING', 'merged'),
            ('PFDEBUG', 'TODENSE', 'merged'), ('PFDEBUG', 'TODENSE', 'merged'),
            ('PFCOUNT', 'merged'),
        ], [1, 0, 1, 2, 2, 3, 'OK', 3, 'sparse', 1, 0, 3])
        registers = c.call('PFDEBUG', 'GETREG', 'merged')
        self.assertEqual(len(registers), 16384)
        self.assertTrue(all(isinstance(value, int) and 0 <= value <= 63 for value in registers))

    def test_set_mutation_algebra_and_scan(self):
        c = self.client
        self.assert_pipeline([
            ('SADD', 'a', '1', '2', '3', '3'), ('SADD', 'b', '3', '4'),
            ('SCARD', 'a'), ('SMISMEMBER', 'a', '2', 'missing', '3'),
            ('SMOVE', 'a', 'b', '2'), ('SMOVE', 'b', 'b', '2'),
            ('SINTERCARD', 2, 'a', 'b'), ('SINTERCARD', 2, 'a', 'b', 'LIMIT', 1),
            ('SUNIONSTORE', 'u', 'a', 'b'), ('SDIFFSTORE', 'd', 'a', 'b'),
            ('SINTERSTORE', 'i', 'a', 'b'),
        ], [3, 2, 3, [1, 0, 1], 1, 1, 1, 1, 4, 1, 1])
        self.assertEqual(sorted(c.call('SMEMBERS', 'u')), [b'1', b'2', b'3', b'4'])
        self.assertEqual(c.call('SMEMBERS', 'd'), [b'1'])
        cursor, members = c.call('SSCAN', 'u', 0, 'MATCH', '[13]', 'COUNT', 100)
        self.assertEqual(cursor, b'0')
        self.assertEqual(sorted(members), [b'1', b'3'])
        self.assertEqual(len(c.call('SRANDMEMBER', 'u', -7)), 7)
        popped = c.call('SPOP', 'u', 3)
        self.assertEqual(len(set(popped)), 3)
        self.assertEqual(c.call('SCARD', 'u'), 1)

    def test_hash_commands_field_expiry_and_options(self):
        c = self.client
        self.assert_pipeline([
            ('HSET', 'h', 'a', '1', 'b', '2', 'c', '3'),
            ('HSETNX', 'h', 'a', 'no'), ('HSETNX', 'h', 'd', '4'),
            ('HINCRBY', 'h', 'a', 4), ('HINCRBYFLOAT', 'h', 'a', '.5'),
            ('HMGET', 'h', 'a', 'missing', 'a'), ('HSTRLEN', 'h', 'a'),
            ('HEXISTS', 'h', 'b'), ('HLEN', 'h'),
            ('HPEXPIRE', 'h', 30000, 'NX', 'FIELDS', 2, 'a', 'b'),
            ('HPEXPIRE', 'h', 10000, 'NX', 'FIELDS', 2, 'a', 'b'),
            ('HPERSIST', 'h', 'FIELDS', 1, 'a'),
        ], [3, 0, 1, 5, b'5.5', [b'5.5', None, b'5.5'], 3, 1, 4, [1, 1], [0, 0], [1]])
        ttls = c.call('HPTTL', 'h', 'FIELDS', 3, 'a', 'b', 'missing')
        self.assertEqual(ttls[0], -1)
        self.assertGreater(ttls[1], 25000)
        self.assertEqual(ttls[2], -2)
        self.assertEqual(c.call('HPEXPIRE', 'h', 0, 'FIELDS', 1, 'b'), [2])
        self.assertEqual(c.call('HGET', 'h', 'b'), None)
        values = c.call('HGETALL', 'h')
        self.assertEqual(dict(zip(values[::2], values[1::2])), {b'a': b'5.5', b'c': b'3', b'd': b'4'})
        cursor, values = c.call('HSCAN', 'h', 0, 'MATCH', 'a', 'NOVALUES')
        self.assertEqual((cursor, values), (b'0', [b'a']))
        fields = c.call('HRANDFIELD', 'h', 20, 'WITHVALUES')
        self.assertEqual(len(fields), 6)
        self.assertEqual(c.call('HDEL', 'h', 'a', 'c', 'd'), 3)
        self.assertEqual(c.call('TYPE', 'h'), 'none')


    def test_sorted_set_options_ranges_algebra_and_pop(self):
        c = self.client
        self.assert_pipeline([
            ('ZADD', 'z', 'NX', 1, 'a', 2, 'b', 3, 'c'),
            ('ZADD', 'z', 'XX', 'CH', 5, 'a'), ('ZINCRBY', 'z', 1, 'a'),
            ('ZSCORE', 'z', 'a'), ('ZMSCORE', 'z', 'missing', 'c'),
            ('ZRANGE', 'z', 0, -1, 'WITHSCORES'), ('ZRANK', 'z', 'a', 'WITHSCORE'),
            ('ZREVRANK', 'z', 'a'), ('ZCOUNT', 'z', '(2', '+inf'),
            ('ZRANGEBYSCORE', 'z', 2, 6, 'LIMIT', 1, 1),
            ('ZREMRANGEBYRANK', 'z', 0, 0), ('ZRANGESTORE', 'ranged', 'z', 0, 0, 'REV'),
            ('SADD', 'members', 'a', 'c'),
            ('ZUNIONSTORE', 'out', 2, 'z', 'members', 'WEIGHTS', 2, 3, 'AGGREGATE', 'MAX'),
            ('ZRANGE', 'out', 0, -1, 'WITHSCORES'),
            ('ZINTERCARD', 2, 'z', 'members', 'LIMIT', 1),
            ('ZDIFF', 2, 'out', 'members'),
            ('ZMPOP', 2, 'missing', 'out', 'MAX', 'COUNT', 1), ('ZPOPMIN', 'out'),
        ], [3, 1, b'6', b'6', [None, b'3'], [b'b', b'2', b'c', b'3', b'a', b'6'],
            [2, b'6'], 0, 2, [b'c'], 1, 1, 2, 2, [b'c', b'6', b'a', b'12'],
            1, [], [b'out', [[b'a', b'12']]], [b'c', b'6']])
        values = c.call('ZRANDMEMBER', 'z', 10, 'WITHSCORES')
        self.assertEqual(len(values), 4)
        cursor, values = c.call('ZSCAN', 'z', 0, 'MATCH', 'a', 'COUNT', 100)
        self.assertEqual((cursor, values), (b'0', [b'a', b'6']))

    def test_geo_queries_options_and_store(self):
        c = self.client
        self.assertEqual(c.call('GEOADD', 'geo', 13.361389, 38.115556, 'Palermo',
                                15.087269, 37.502669, 'Catania'), 2)
        self.assertEqual(c.call('GEOADD', 'geo', 'NX', 14, 38, 'Palermo'), 0)
        self.assertEqual(c.call('GEOSEARCH', 'geo', 'FROMMEMBER', 'Palermo',
                                'BYRADIUS', 200, 'km', 'ASC'), [b'Palermo', b'Catania'])
        self.assertTrue(160 < float(c.call('GEODIST', 'geo', 'Palermo', 'Catania', 'km')) < 170)
        hashes = c.call('GEOHASH', 'geo', 'Palermo', 'Catania', 'missing')
        self.assertEqual([len(value) if value else None for value in hashes], [11, 11, None])
        positions = c.call('GEOPOS', 'geo', 'Palermo', 'missing')
        self.assertAlmostEqual(float(positions[0][0]), 13.361389, places=4)
        self.assertEqual(positions[1], None)
        self.assertEqual(c.call('GEOSEARCHSTORE', 'distances', 'geo', 'FROMMEMBER',
                                'Palermo', 'BYRADIUS', 200, 'km', 'STOREDIST'), 2)
        self.assertEqual(float(c.call('ZSCORE', 'distances', 'Palermo')), 0)
        self.assertTrue(160 < float(c.call('ZSCORE', 'distances', 'Catania')) < 170)
        self.assertEqual(c.call('GEORADIUS', 'geo', 13.361389, 38.115556, 200, 'km',
                                'STORE', 'radius'), 2)
        self.assertEqual(c.call('ZCARD', 'radius'), 2)

    def test_stream_entries_trim_metadata_and_multi_read(self):
        c = self.client
        self.assert_pipeline([
            ('XADD', 's', '1-0', 'f', 'one'), ('XADD', 's', '2-0', 'f', 'two'),
            ('XLEN', 's'), ('XRANGE', 's', '-', '+', 'COUNT', 1),
            ('XREVRANGE', 's', '+', '-', 'COUNT', 1),
            ('XDEL', 's', '1-0'), ('XTRIM', 's', 'MAXLEN', 0), ('TYPE', 's'),
            ('XSETID', 's', '5-0', 'ENTRIESADDED', 3, 'MAXDELETEDID', '2-0'),
            ('XADD', 'absent', 'NOMKSTREAM', '*', 'f', 'v'),
        ], [b'1-0', b'2-0', 2, [[b'1-0', [b'f', b'one']]],
            [[b'2-0', [b'f', b'two']]], 1, 1, 'stream', 'OK', None])
        row = c.call('XINFO', 'STREAM', 's')
        row = dict(zip(row[::2], row[1::2]))
        self.assertEqual((row[b'length'], row[b'last-generated-id'], row[b'entries-added']), (0, b'5-0', 3))
        c.call('XADD', 'left', '1-0', 'f', 'a')
        c.call('XADD', 'right', '2-0', 'f', 'b')
        expected = [[b'left', [[b'1-0', [b'f', b'a']]]], [b'right', [[b'2-0', [b'f', b'b']]]]]
        self.assertEqual(c.call('XREAD', 'COUNT', 1, 'STREAMS', 'left', 'right', 0, 0), expected)
        self.assertEqual(c.call('XREAD', 'STREAMS', 'left', 'left', 0, 0), [expected[0], expected[0]])

    def test_stream_groups_pending_claim_and_duplicate_keys(self):
        c = self.client
        self.assertEqual(c.call('XGROUP', 'CREATE', 's', 'g', 0, 'MKSTREAM'), 'OK')
        self.assertEqual(c.call('XGROUP', 'CREATECONSUMER', 's', 'g', 'c'), 1)
        c.call('XADD', 's', '1-0', 'f', 'one')
        c.call('XADD', 's', '2-0', 'f', 'two')
        self.assertEqual(c.call('XREADGROUP', 'GROUP', 'g', 'c', 'COUNT', 1,
                                'STREAMS', 's', '>'), [[b's', [[b'1-0', [b'f', b'one']]]]])
        self.assertEqual(c.call('XPENDING', 's', 'g'), [1, b'1-0', b'1-0', [[b'c', b'1']]])
        self.assertEqual(c.call('XACK', 's', 'g', '1-0'), 1)
        self.assertEqual(c.call('XREADGROUP', 'GROUP', 'g', 'c', 'STREAMS', 's', 's', '>', '>'),
                         [[b's', [[b'2-0', [b'f', b'two']]]]])
        self.assertEqual(c.call('XCLAIM', 's', 'g', 'other', 0, '2-0', 'JUSTID'), [b'2-0'])
        pending = c.call('XPENDING', 's', 'g', '-', '+', 10)
        self.assertEqual((pending[0][0], pending[0][1]), (b'2-0', b'other'))
        self.assertEqual(c.call('XAUTOCLAIM', 's', 'g', 'final', 0, '0-0', 'COUNT', 10, 'JUSTID'),
                         [b'0-0', [b'2-0'], []])
        self.assertEqual(c.call('XACK', 's', 'g', '2-0'), 1)
        row = c.call('XINFO', 'STREAM', 's', 'FULL', 'COUNT', 10)
        row = dict(zip(row[::2], row[1::2]))
        self.assertEqual((row[b'length'], len(row[b'groups'])), (2, 1))
        self.assertEqual(c.call('XGROUP', 'DESTROY', 's', 'g'), 1)
        self.assertEqual(c.call('TYPE', 's'), 'stream')

    def test_resp3_typed_worker_reply_shapes(self):
        c = self.client
        c.call('HELLO', 3)
        c.call('HSET', 'h', 'f', 'v')
        self.assertEqual(c.call('HGETALL', 'h'), {b'f': b'v'})
        c.call('ZADD', 'z', 1, 'a', 2, 'b')
        self.assertEqual(c.call('ZRANGE', 'z', 0, -1, 'WITHSCORES'), [[b'a', 1.0], [b'b', 2.0]])
        self.assertEqual(c.call('ZPOPMIN', 'z'), [b'a', 1.0])
        c.call('XADD', 's', '1-0', 'f', 'v')
        self.assertEqual(c.call('XREAD', 'STREAMS', 's', 0), {b's': [[b'1-0', [b'f', b'v']]]})
        self.assertEqual(c.call('XINFO', 'STREAM', 's')[b'length'], 1)

    def test_all_typed_groups_submit_real_worker_jobs(self):
        c = self.client
        before = int(info(c, 'server')['keyspace_jobs_submitted'])
        commands = [('HSET', 'h', 'f', 'v'), ('SADD', 'set', 'a'),
                    ('ZADD', 'z', 1, 'a'), ('GEOADD', 'geo', 0, 0, 'origin'),
                    ('XADD', 'stream', '1-0', 'f', 'v'), ('PFADD', 'hll', 'value'),
                    ('SETBIT', 'bits', 0, 1)]
        c.pipeline(commands)
        after = int(info(c, 'server')['keyspace_jobs_submitted'])
        self.assertGreaterEqual(after - before, len(commands))
        result = c.pipeline([('SINTERCARD', '1junk', 'set'), ('SCARD', 'set')])
        self.assertIsInstance(result[0], ServerError)
        self.assertEqual(result[1], 1)


    def test_atomic_key_copy_rename_move_and_cross_db_identity(self):
        c = self.client
        self.assertEqual(c.call('SET', 'number', 12, 'PX', 30000), 'OK')
        self.assertEqual(c.call('COPY', 'number', 'copy'), 1)
        self.assertEqual(c.call('OBJECT', 'REFCOUNT', 'copy'), 1)
        self.assertEqual(c.call('GETEX', 'copy', 'PERSIST'), b'12')
        self.assertEqual(c.call('OBJECT', 'REFCOUNT', 'copy'), 1)
        self.assertEqual(c.call('RENAME', 'copy', 'renamed'), 'OK')
        self.assertEqual(c.call('OBJECT', 'REFCOUNT', 'renamed'), 1)
        self.assertEqual(c.call('RENAMENX', 'renamed', 'number'), 0)
        self.assertEqual(c.call('COPY', 'number', 'number', 'DB', 1), 1)
        c.call('SELECT', 1)
        self.assertEqual(c.call('GET', 'number'), b'12')
        self.assertGreater(c.call('PTTL', 'number'), 25000)
        c.call('SELECT', 0)
        self.assertEqual(c.call('MOVE', 'renamed', 1), 1)
        self.assertEqual(c.call('GET', 'renamed'), None)
        c.call('SELECT', 1)
        self.assertEqual(c.call('GET', 'renamed'), b'12')
        self.assertEqual(c.call('OBJECT', 'REFCOUNT', 'renamed'), 1)
        c.call('SELECT', 0)
        c.call('RPUSH', 'list', 'a', 'b')
        self.assertEqual(c.call('COPY', 'list', 'list-copy'), 1)
        c.call('LPOP', 'list')
        self.assertEqual(c.call('LRANGE', 'list-copy', 0, -1), [b'a', b'b'])
        self.assertEqual(c.call('RENAME', 'list-copy', 'list-copy'), 'OK')
        self.assertEqual(c.call('RENAMENX', 'list-copy', 'list-copy'), 0)

    def test_dump_restore_all_types_and_absolute_field_expiry(self):
        with Server(BINARY, workers=0, arguments=('--keyspace-threads', '4',
                    '--keyspace-max-memory', str(128 << 20)), queue_ping=True) as server:
            c = server.client()
            c.call('SET', 'string', b'\x00value\xff' * 100)
            c.call('RPUSH', 'list', 'a', 'b')
            c.call('SADD', 'set', 'a', 'b')
            c.call('ZADD', 'zset', 1, 'a', 2, 'b')
            c.call('HSET', 'hash', 'f', 'v', 'g', 'w')
            deadline = 1893456000000
            c.call('HPEXPIREAT', 'hash', deadline, 'FIELDS', 1, 'f')
            c.call('XADD', 'stream', '1-0', 'f', 'v')
            before = int(info(c, 'server')['keyspace_jobs_submitted'])
            for name in ('string', 'list', 'set', 'zset', 'hash', 'stream'):
                submitted = int(info(c, 'server')['keyspace_jobs_submitted'])
                payload = c.call('DUMP', name)
                self.assertEqual(int(info(c, 'server')['keyspace_jobs_submitted']), submitted + 1)
                self.assertIsInstance(payload, bytes)
                submitted = int(info(c, 'server')['keyspace_jobs_submitted'])
                self.assertEqual(c.call('RESTORE', name + '-restored', 30000, payload), 'OK')
                self.assertEqual(int(info(c, 'server')['keyspace_jobs_submitted']), submitted + 1)
                self.assertEqual(c.call('TYPE', name + '-restored'), c.call('TYPE', name))
            after = int(info(c, 'server')['keyspace_jobs_submitted'])
            self.assertGreaterEqual(after - before, 12)
            self.assertEqual(c.call('GET', 'string-restored'), b'\x00value\xff' * 100)
            self.assertEqual(c.call('LRANGE', 'list-restored', 0, -1), [b'a', b'b'])
            self.assertEqual(sorted(c.call('SMEMBERS', 'set-restored')), [b'a', b'b'])
            self.assertEqual(c.call('ZRANGE', 'zset-restored', 0, -1, 'WITHSCORES'), [b'a', b'1', b'b', b'2'])
            self.assertEqual(c.call('HPEXPIRETIME', 'hash-restored', 'FIELDS', 1, 'f'), [deadline])
            self.assertEqual(c.call('XRANGE', 'stream-restored', '-', '+'), [[b'1-0', [b'f', b'v']]])
            payload = c.call('DUMP', 'string')
            self.assertEqual(c.call('RESTORE', 'idle', 0, payload, 'IDLETIME', 30), 'OK')
            self.assertTrue(29 <= c.call('OBJECT', 'IDLETIME', 'idle') <= 31)
            self.assertEqual(c.call('RESTORE', 'idle', 1, payload, 'REPLACE', 'ABSTTL'), 'OK')
            self.assertEqual(c.call('GET', 'idle'), None)
            result = c.pipeline([('RESTORE', 'string', 'bad', b'bad'),
                                 ('RESTORE', 'string', -1, payload, 'REPLACE'),
                                 ('RESTORE', 'invalid', 0, payload[:-1] + bytes([payload[-1] ^ 1]))])
            self.assertTrue(all(isinstance(value, ServerError) for value in result))
            self.assertIn('BUSYKEY', str(result[0]))
            self.assertIn('TTL', str(result[1]))
            self.assertIn('checksum', str(result[2]))

    def test_restore_adversarial_counts_and_lzf_leave_previous_value(self):
        sys.path.insert(0, str(ROOT / 'test' / 'rdb'))
        from rdbcmp import crc64
        with Server(BINARY, workers=0, arguments=('--keyspace-threads', '2',
                    '--keyspace-max-memory', str(128 << 20)), queue_ping=True) as server:
            c = server.client()
            c.call('SET', 'target', 'old')
            version = c.call('DUMP', 'target')[-10:-8]
            def payload(body):
                encoded = body + version
                return encoded + crc64(encoded).to_bytes(8, 'little')
            malformed = [
                payload(bytes([5, 0x81]) + (1 << 40).to_bytes(8, 'big')),
                payload(bytes([0, 0xc3, 1, 0x40, 165, 0])),
                payload(bytes([0, 0xc3, 1, 0x40, 164, 0])),
            ]
            for value in malformed:
                result = c.pipeline([('RESTORE', 'target', 0, value, 'REPLACE'), ('GET', 'target')])
                self.assertIsInstance(result[0], ServerError)
                self.assertEqual(result[1], b'old')
            literal = payload(bytes([0, 0xc3, 2, 1, 0, ord('a')]))
            self.assertEqual(c.call('RESTORE', 'literal', 0, literal), 'OK')
            self.assertEqual(c.call('GET', 'literal'), b'a')


def main(argv=None):
    global BINARY
    parser = argparse.ArgumentParser(description='Broad string and atomic multi-key worker correctness; no benchmarks.')
    parser.add_argument('--server', type=Path, default=Path(os.environ.get('ESKI_THREADING_BIN', BINARY)))
    parser.add_argument('--case', default='*')
    parser.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args(argv)
    BINARY = args.server.resolve()
    if args.timeout <= 0 or not BINARY.is_file():
        parser.error('positive timeout and existing server binary required')
    names = [name for name in unittest.defaultTestLoader.getTestCaseNames(FullKeyspace)
             if fnmatch.fnmatchcase(name, args.case)]
    if not names:
        parser.error('case selected no tests')
    signal.alarm(args.timeout)
    try:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(FullKeyspace(name) for name in names))
        return 0 if result.wasSuccessful() else 1
    finally:
        signal.alarm(0)


if __name__ == '__main__':
    raise SystemExit(main())
