import argparse
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
import scoped_log as sl
from support import ServerError

BINARY = ROOT / 'bin/eski'
THREADS = 0
VECTOR = ('VECTOR', 'FLAT', 6, 'TYPE', 'FLOAT32', 'DIM', 2, 'DISTANCE_METRIC', 'L2')
SCHEMA = ('$.nested.text', 'AS', 'text', 'TEXT', 'SORTABLE', '$.numbers[*]', 'AS', 'n', 'NUMERIC', 'SORTABLE',
          '$.tags', 'AS', 'tags', 'TAG', '$.geo[*]', 'AS', 'point', 'GEO', '$.vectors[*]', 'AS', 'v', *VECTOR)
DOC = '{"nested":{"text":["first","second"]},"numbers":[2,4],"tags":["a,b","xyz"],"geo":["0,0","2,2"],"vectors":[[0,0],[10,10]],"explicit":null}'
POINT = struct.pack('<ff', 10, 10)


def create(c, scope=(), name='idx', schema=SCHEMA, prefix='item:', options=()):
    return c.call(*scope, 'FT.CREATE', name, 'ON', 'JSON', 'PREFIX', 1, prefix, 'STOPWORDS', 0, *options, 'SCHEMA', *schema)


def mapping(value):
    return value if isinstance(value, dict) else dict(zip(value[::2], value[1::2]))


def matches(c, query='*', scope=(), index='idx'):
    response = c.call(*scope, 'FT.SEARCH', index, query, 'NOCONTENT', 'LIMIT', 0, 50)
    if isinstance(response, list):
        return response[0], set(response[1:])
    return response['total_results'], {row['id'] for row in response['results']}


class JsonSearch(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix='eski-json-search-')
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name)
        self.number = 0

    def server(self, scope='', options=()):
        directory = self.root / str(self.number)
        directory.mkdir()
        self.number += 1
        server = sl.Server(BINARY, directory, scope, ('--save', '', '--shutdown-on-sigterm', 'nosave') + options, THREADS)
        self.addCleanup(self.stop, server)
        return server, self.start(server)

    def start(self, server):
        c = server.up()
        print('Eski PID', server.run.process.pid, 'port', server.run.port, flush=True)
        return c

    def stop(self, server):
        status = server.stop()
        log = server.run.log()
        self.assertIn(status, (None, 0), log)
        self.assertNotIn('AddressSanitizer', log)

    def test_search_multivalue_projections_and_dialects(self):
        _, c = self.server()
        c.call('JSON.SET', 'item:a', '$', DOC)
        c.call('HSET', 'item:hash', 'text', 'first')
        self.assertEqual(create(c), 'OK')
        c.call('JSON.SET', 'item:b', '$', '{"nested":{"text":"first second"},"numbers":[3,1],"tags":false,"vectors":[[5,5]]}')
        c.call('JSON.SET', 'item:bad', '$', '{"numbers":[1,true]}')
        self.assertEqual(matches(c), (2, {b'item:a', b'item:b'}))
        self.assertEqual(matches(c, '@text:"first second"'), (1, {b'item:b'}))
        self.assertEqual(matches(c, '@n:[1 2]'), (2, {b'item:a', b'item:b'}))
        self.assertEqual(matches(c, '@n:[4 4]'), (1, {b'item:a'}))
        self.assertEqual(matches(c, '@point:[2 2 1 km]'), (1, {b'item:a'}))
        self.assertEqual(matches(c, '@tags:{a}'), (0, set()))
        self.assertEqual(matches(c, r'@tags:{a\,b}'), (1, {b'item:a'}))
        self.assertEqual(matches(c, '@tags:{false}'), (1, {b'item:b'}))
        fields = ('RETURN', 9, 'text', 'n', 'v', '$.explicit', '$.missing', '$.nested.text[1]', 'AS', 'leaf', '$.nested')
        base = ('FT.SEARCH', 'idx', '*', 'INKEYS', 1, 'item:a')
        replies = [
            {b'text': b'["first","second"]', b'n': b'2', b'v': b'[0,0]', b'$.explicit': None,
             b'leaf': b'second', b'$.nested': b'{"text":["first","second"]}'},
            {b'text': b'[["first","second"]]', b'n': b'[2,4]', b'v': b'[[0,0],[10,10]]', b'$.explicit': b'[null]',
             b'leaf': b'["second"]', b'$.nested': b'[{"text":["first","second"]}]'},
        ]
        for proto in (2, 3):
            c.call('HELLO', proto)
            for dialect in (1, 2, 3, 4):
                result = c.call(*base, *fields, 'DIALECT', dialect, 'FORMAT', 'STRING')
                row = mapping(result[2]) if proto == 2 else result['results'][0]['extra_attributes']
                self.assertEqual(row, replies[dialect >= 3])
                result = c.call(*base, 'DIALECT', dialect)
                row = mapping(result[2]) if proto == 2 else result['results'][0]['extra_attributes']
                self.assertEqual(json.loads(row[b'$']), [json.loads(DOC)] if dialect >= 3 else json.loads(DOC))
        expanded = c.call(*base, *fields, 'DIALECT', 3, 'FORMAT', 'EXPAND')
        self.assertEqual(expanded['format'], 'EXPAND')
        self.assertEqual(expanded['results'][0]['extra_attributes'], {
            b'text': [[b'first', b'second']], b'n': [2, 4], b'v': [[0, 0], [10, 10]],
            b'$.explicit': [None], b'leaf': [b'second'], b'$.nested': [{b'text': [b'first', b'second']}],
        })
        response = c.call('FT.INFO', 'idx')
        self.assertEqual(response['index_definition']['key_type'], 'JSON')
        self.assertEqual(response['attributes'][2]['SEPARATOR'], '')
        self.assertEqual(response['attributes'][1]['flags'], ['SORTABLE', 'UNF'])
        self.assertEqual(response['Index Errors']['last indexing error'], 'SEARCH_VALUE_BAD NUMERIC fields can only contain numeric or nulls')
        highlights = c.call('FT.SEARCH', 'idx', 'first', 'RETURN', 1, 'text', 'DIALECT', 3, 'HIGHLIGHT')
        fields = {row['id']: row['extra_attributes'][b'text'] for row in highlights['results']}
        self.assertEqual(fields, {b'item:a': b'[["first","second"]]', b'item:b': b'<b>first</b> second'})
        with self.assertRaisesRegex(ServerError, 'requires RETURN'):
            c.call('FT.SEARCH', 'idx', 'first', 'HIGHLIGHT')
        with self.assertRaisesRegex(ServerError, 'SEARCH_PATH_BAD'):
            create(c, name='bad', schema=('$.unclosed[', 'AS', 'broken', 'TEXT'))

    def test_vector_knn_range_aggregation_hybrid_and_cursors(self):
        for algorithm in ('FLAT', 'HNSW'):
            _, c = self.server()
            vector = (*VECTOR[:1], algorithm, *VECTOR[2:])
            schema = (*SCHEMA[:-len(VECTOR)], *vector)
            self.assertEqual(create(c, schema=schema), 'OK')
            c.call('JSON.SET', 'item:a', '$', DOC)
            c.call('JSON.SET', 'item:b', '$', '{"nested":{"text":"first chosen"},"numbers":[3],"vectors":[[9,9]]}')
            c.call('JSON.SET', 'item:c', '$', '{"nested":{"text":"last"},"numbers":[7],"vectors":[[2,2]]}')
            c.call('JSON.ARRAPPEND', 'item:a', '$.vectors', '[10,9]', '[10,11]')
            query = '*=>[KNN 2 @v $q AS d]'
            options = ('PARAMS', 2, 'q', POINT, 'DIALECT', 2)
            hits = c.call('FT.SEARCH', 'idx', query, 'RETURN', 1, 'd', 'SORTBY', 'd', *options)
            self.assertEqual(hits, [2, b'item:a', [b'd', b'0'], b'item:b', [b'd', b'2']])
            self.assertEqual(c.call('FT.SEARCH', 'idx', '@v:[VECTOR_RANGE 2 $q]=>{$YIELD_DISTANCE_AS:d}', 'RETURN', 1, 'd', 'SORTBY', 'd', *options), hits)
            self.assertEqual(c.call('FT.SEARCH', 'idx', '(@n:[3 3])=>[KNN 1 @v $q AS d]', 'RETURN', 1, 'd', *options),
                             [1, b'item:b', [b'd', b'2']])
            a = c.call('FT.AGGREGATE', 'idx', query, 'LOAD', 2, 'n', '$.nested', 'APPLY', '@n + @d', 'AS', 'value',
                       'SORTBY', 2, '@value', 'ASC', *options)
            self.assertEqual(a, [2, [b'd', b'0', b'n', b'2', b'$.nested', b'{"text":["first","second"]}', b'value', b'2'],
                                   [b'd', b'2', b'n', b'3', b'$.nested', b'{"text":"first chosen"}', b'value', b'5']])
            h = mapping(c.call('FT.HYBRID', 'idx', 'SEARCH', '@text:first', 'VSIM', '@v', '$q', 'LOAD', 2, '@text', '@$.nested', 'PARAMS', 2, 'q', POINT))
            self.assertEqual(h['total_results'], 3)
            self.assertIn(b'["first","second"]', {mapping(row)[b'text'] for row in h['results']})
            c.call('HELLO', 3)
            result, cursor = c.call('FT.AGGREGATE', 'idx', '*', 'LOAD', 2, '__key', '$.nested', 'SORTBY', 1, '@__key',
                                    'DIALECT', 3, 'FORMAT', 'EXPAND', 'WITHCURSOR', 'COUNT', 1)
            self.assertEqual(result['format'], 'EXPAND')
            self.assertEqual(result['results'][0]['extra_attributes'][b'$.nested'], [{b'text': [b'first', b'second']}])
            self.assertGreater(cursor, 0)
            more, next_id = c.call('FT.CURSOR', 'READ', 'idx', cursor, 'COUNT', 5)
            self.assertEqual(more['format'], 'EXPAND')
            self.assertEqual({row['extra_attributes'][b'__key'] for row in more['results']}, {b'item:b', b'item:c'})
            self.assertEqual(next_id, 0)

    def test_rebuild_and_maintain_all_generic_key_lifecycle_paths(self):
        server, c = self.server(options=sl.LOG + ('--aof-use-rdb-preamble', 'no'))
        schema = ('$.text', 'AS', 'text', 'TEXT', '$.n[*]', 'AS', 'n', 'NUMERIC')
        self.assertEqual(create(c, schema=schema), 'OK')
        c.call('JSON.SET', 'item:in', '$', '{"text":"old","n":[1,9223372036854775807]}')
        c.call('JSON.SET', 'other', '$', '{"text":"bright","n":[42]}')
        with self.assertRaisesRegex(ServerError, 'numeric overflow'):
            c.call('JSON.NUMINCRBY', 'item:in', '$.n[*]', 1)
        self.assertEqual(matches(c, '@n:[2 2]'), (1, {b'item:in'}))
        c.call('JSON.MSET', 'item:in', '$.text', '"new"', 'item:dup', '$', '{"text":"copy"}')
        self.assertEqual(matches(c, '@text:old'), (0, set()))
        self.assertEqual(c.call('COPY', 'item:in', 'item:copy'), 1)
        self.assertEqual(c.call('COPY', 'item:in', 'item:db1', 'DB', 1), 1)
        self.assertEqual(c.call('RENAME', 'other', 'item:renamed'), 'OK')
        self.assertEqual(c.call('RENAME', 'item:dup', 'outside'), 'OK')
        self.assertEqual(matches(c), (3, {b'item:in', b'item:copy', b'item:renamed'}))
        self.assertEqual(c.call('MOVE', 'item:copy', 1), 1)
        self.assertEqual(c.call('SELECT', 1), 'OK')
        self.assertEqual(c.call('MOVE', 'item:copy', 0), 1)
        c.call('SELECT', 0)
        self.assertEqual(c.call('FT.ALTER', 'idx', 'SCHEMA', 'ADD', '$.text', 'AS', 'tag', 'TAG'), 'OK')
        self.assertEqual(matches(c, '@tag:{bright}'), (1, {b'item:renamed'}))
        payload = c.call('DUMP', 'item:renamed')
        self.assertEqual(c.call('RESTORE', 'item:restored', 0, payload), 'OK')
        self.assertEqual(c.call('JSON.DEL', 'item:renamed', '$'), 1)
        self.assertEqual(matches(c, '@tag:{bright}'), (1, {b'item:restored'}))
        self.assertEqual(c.call('UNLINK', 'item:restored'), 1)
        self.assertEqual(c.call('SET', 'item:copy', 'other type'), 'OK')
        self.assertEqual(matches(c), (1, {b'item:in'}))
        self.assertEqual(c.call('SWAPDB', 0, 1), 'OK')
        self.assertEqual(matches(c, '@tag:{new}'), (1, {b'item:db1'}))
        self.assertEqual(c.call('SWAPDB', 0, 1), 'OK')
        c.call('PEXPIREAT', 'item:in', sl.FAR)
        self.assertEqual(c.call('BGREWRITEAOF'), 'Background append only file rewriting started')
        sl.wait_for(lambda: b'aof_rewrite_in_progress:0' in c.call('INFO', 'persistence'))
        self.assertIn(b'aof_last_bgrewrite_status:ok', c.call('INFO', 'persistence'))
        self.stop(server)
        c = self.start(server)
        self.assertEqual(matches(c, '@n:[2 2] @tag:{new}'), (1, {b'item:in'}))
        self.assertEqual(c.call('PEXPIRETIME', 'item:in'), sl.FAR)
        c.call('HSET', 'item:hash', 'text', 'stay')
        self.assertEqual(c.call('FT.DROPINDEX', 'idx', 'DD'), 'OK')
        self.assertEqual(c.call('EXISTS', 'item:in'), 0)
        self.assertEqual(c.call('EXISTS', 'item:hash', 'item:copy', 'outside'), 3)
        self.assertEqual(create(c, schema=schema), 'OK')
        c.call('JSON.SET', 'item:live', '$', '{"text":"flush"}')
        self.assertEqual(c.call('FLUSHDB', 'ASYNC'), 'OK')
        self.assertEqual(c.call('FT._LIST'), [])
        self.assertEqual(create(c, schema=schema), 'OK')
        self.assertEqual(matches(c), (0, set()))

    def test_scoped_index_acl_expiry_and_hidden_twin(self):
        _, c = self.server('both')
        _, absent = self.server('both')
        top = sl.top('both')
        reader = sl.at('both', 'U', 'reader')
        shared = sl.at('both', 'U')
        hidden = sl.at('both', 'C//A', 'other')
        schema = ('$.text', 'AS', 'text', 'TEXT', '$.price', 'AS', 'price', 'NUMERIC')
        for client in (c, absent):
            self.assertEqual(create(client, scope=shared, schema=schema), 'OK')
            client.call(*reader, 'JSON.SET', 'item:1', '$', '{"text":"token","price":1}')
            client.call(*reader, 'JSON.SET', 'item:2', '$', '{"text":"later","price":2}')
        c.call(*hidden, 'JSON.SET', 'item:1', '$', '{"text":"secret","price":3}')
        c.call(*hidden, 'JSON.SET', 'item:3', '$', '{"text":"secret","price":"invalid"}')
        pair = sl.Pair(c, absent)
        pair.call(*reader, 'FT.INFO', 'idx')
        pair.call(*reader, 'FT.SEARCH', 'idx', '*', 'RETURN', 2, '$', 'price', 'SORTBY', 'price')
        self.assertEqual(pair.call(*reader, 'FT.SEARCH', 'idx', '@text:secret', 'NOCONTENT'), [0])
        c.call(*top, 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        _, cursor = c.call(*reader, 'FT.AGGREGATE', 'idx', '*', 'LOAD', 1, 'text', 'WITHCURSOR', 'COUNT', 1)
        self.assertGreater(cursor, 0)

        def clock_ms():
            seconds, micros = map(int, c.call(*reader, 'TIME'))
            return seconds * 1000 + micros // 1000

        deadline = clock_ms() + 25
        c.call(*reader, 'PEXPIREAT', 'item:2', deadline)
        sl.wait_for(lambda: clock_ms() > deadline)
        self.assertEqual(matches(c, scope=reader), (1, {b'item:1'}))
        with self.assertRaises(ServerError):
            c.call(*reader, 'FT.CURSOR', 'READ', 'idx', cursor)
        self.assertEqual(c.call(*shared, 'FT.DROPINDEX', 'idx', 'DD'), 'OK')
        self.assertEqual(c.call(*reader, 'JSON.GET', 'item:1'), b'{"text":"token","price":1}')
        self.assertEqual(c.call(*hidden, 'JSON.GET', 'item:1'), b'{"text":"secret","price":3}')

        server, plain = self.server()
        create(plain, schema=schema)
        plain.call('ACL', 'SETUSER', 'limited', 'on', 'nopass', '+@search', '%R~item:allowed:*')
        limited = server.client('limited')
        for command in (('FT.SEARCH', 'idx', '*'), ('FT.AGGREGATE', 'idx', '*'), ('FT.INFO', 'idx')):
            with self.assertRaisesRegex(ServerError, 'NOPERM'):
                limited.call(*command)

    def test_content_quota_twins_and_eviction(self):
        for mode in ('labels', 'owners'):
            with self.subTest(mode=mode):
                scope = sl.at(mode, 'C') if mode == 'labels' else sl.at(mode, 'UNCLASSIFIED', 'reader')
                top = sl.top(mode)
                peers = [self.server(mode)[1] for _ in range(2)]
                quota = (*top, 'LABEL', 'QUOTA', 'C') if mode == 'labels' else (*top, 'OWNERS', 'QUOTA', 'reader')
                for client in peers:
                    self.assertEqual(create(client, scope=scope, schema=('$.text', 'AS', 'text', 'TEXT')), 'OK')
                    client.call(*scope, 'JSON.SET', 'item:key', '$', '{"array":[1,2],"text":"term"}')
                peers[1].call(*scope, 'JSON.ARRAPPEND', 'item:key', '$.array', *(['0'] * 2048))
                peers[1].call(*scope, 'JSON.ARRTRIM', 'item:key', '$.array', 0, 1)
                self.assertEqual(peers[0].call(*scope, 'JSON.GET', 'item:key'), peers[1].call(*scope, 'JSON.GET', 'item:key'))
                pair = sl.Pair(*peers)
                self.assertEqual(pair.call(*scope, 'JSON.DEBUG', 'MEMORY', 'item:key'), 69)
                pair.call(*scope, 'MEMORY', 'USAGE', 'item:key')
                used = pair.call(*quota)[1]
                self.assertEqual(pair.call(*top, 'DEBUG', 'CHARGE-CHECK'), 1)
                self.assertEqual(pair.call(*quota, 'LIMIT', used), 'OK')
                self.assertEqual(pair.call(*scope, 'JSON.SET', 'item:key', '$.added', '"grown"'), 'OK')
                self.assertTrue(pair.error(*scope, 'JSON.SET', 'item:other', '$', '{}').startswith('OOM'))
                pair.call(*top, 'CONFIG', 'SET', 'maxmemory-policy', 'allkeys-random')
                self.assertEqual(pair.call(*scope, 'SET', 'trigger', 'evict'), 'OK')
                self.assertIsNone(pair.call(*scope, 'JSON.GET', 'item:key'))
                self.assertEqual(matches(peers[0], scope=scope), (0, set()))
                self.assertEqual(matches(peers[1], scope=scope), (0, set()))
                self.assertEqual(pair.call(*top, 'DEBUG', 'CHARGE-CHECK'), 0)


def main():
    global BINARY, THREADS
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--ports')
    args = parser.parse_args()
    BINARY, THREADS = args.server.resolve(), args.keyspace_threads
    if args.ports:
        sl.use_ports(args.ports)
    unittest.main(argv=[__file__])


if __name__ == '__main__':
    main()
