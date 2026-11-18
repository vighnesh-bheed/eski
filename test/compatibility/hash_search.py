import argparse
import os
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
VECTOR = ('TYPE', 'FLOAT32', 'DIM', 2, 'DISTANCE_METRIC', 'L2')


def point(x, y):
    return struct.pack('<ff', x, y)


def create(c, scope=(), name='catalog', wanted='item:'):
    return c.call(*scope, 'FT.CREATE', name, 'ON', 'HASH', 'PREFIX', 1, wanted, 'STOPWORDS', 0,
                  'SCHEMA', 'body', 'AS', 'description', 'TEXT', 'NOSTEM', 'title', 'TEXT', 'NOSTEM',
                  'kind', 'TAG', 'price', 'NUMERIC', 'SORTABLE', 'point', 'VECTOR', 'FLAT', 6, *VECTOR,
                  'graph', 'VECTOR', 'HNSW', 6, *VECTOR)


def ids(c, query, *options, scope=(), index='catalog'):
    return c.call(*scope, 'FT.SEARCH', index, query, 'NOCONTENT', 'DIALECT', 2, *options)


class HashSearch(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='eski-hash-search-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.servers = 0

    def server(self, mode=''):
        directory = self.root / str(self.servers)
        self.servers += 1
        directory.mkdir()
        server = sl.Server(BINARY, directory, mode, (), THREADS)
        self.addCleanup(server.kill)
        client = server.up()
        self.addCleanup(client.close)
        return server, client

    def test_text_tag_numeric_filters_prefix_and_inkeys(self):
        _, c = self.server()
        self.assertEqual(create(c), 'OK')
        c.call('HSET', 'item:a', 'body', 'total eclipse', 'title', 'comet', 'kind', 'rare', 'price', 4)
        c.call('HSET', 'item:b', 'body', 'red comet', 'title', 'eclipse', 'kind', 'rare', 'price', 8)
        c.call('HSET', 'item:c', 'body', 'comet', 'title', 'eclipse', 'kind', 'common', 'price', 2)
        self.assertEqual(ids(c, '@description:com*'), [2, b'item:c', b'item:b'])
        self.assertEqual(ids(c, 'eclipse', 'INFIELDS', 1, 'description'), [1, b'item:a'])
        self.assertEqual(ids(c, '@kind:{rare} @price:[(4 9]', 'INFIELDS', 1, 'does-not-exist'), [1, b'item:b'])
        self.assertEqual(ids(c, 'eclipse', 'INKEYS', 3, 'item:c', 'absent', 'item:c'), [1, b'item:c'])
        self.assertEqual(ids(c, 'eclipse', 'INKEYS', 0), [0])
        self.assertEqual(ids(c, '@description:"total eclipse"'), [1, b'item:a'])
        self.assertEqual(ids(c, 'eclipse', 'LIMIT', 0, 0), [3])

    def test_resp2_and_resp3_scores_sort_keys_aliases_and_fields(self):
        _, c = self.server()
        self.assertEqual(create(c), 'OK')
        c.call('HSET', 'item:a', 'body', 'comet', 'price', 2, 'title', 'banana', 'opaque', b'\0\xff')
        c.call('HSET', 'item:b', 'body', 'comet', 'price', 9, 'title', 'apple', 'opaque', b'\0\xfe')
        options = ('RETURN', 5, 'description', 'AS', 'label', 'opaque', 'absent',
                   'SORTBY', 'price', 'DESC', 'WITHSORTKEYS', 'LIMIT', 0, 1)
        self.assertEqual(c.call('FT.SEARCH', 'catalog', 'comet', *options),
                         [2, b'item:b', b'#9', [b'label', b'comet', b'opaque', b'\0\xfe']])
        self.assertEqual(ids(c, '*', 'SORTBY', 'title'), [2, b'item:b', b'item:a'])
        result = c.call('FT.SEARCH', 'catalog', '@price:[2 2]')
        self.assertEqual(dict(zip(result[2][::2], result[2][1::2]))[b'opaque'], b'\0\xff')
        self.assertEqual(c.call('FT.SEARCH', 'catalog', 'comet', 'RETURN', 0), [2, b'item:a', b'item:b'])
        scores = c.call('FT.SEARCH', 'catalog', 'comet', 'NOCONTENT', 'WITHSCORES', 'SCORER', 'BM25STD')
        self.assertGreater(float(scores[2]), 0)
        self.assertEqual(scores[2], scores[4])
        c.call('HELLO', 3)
        reply = c.call('FT.SEARCH', 'catalog', 'comet', *options, 'WITHSCORES')
        self.assertEqual(list(reply), ['attributes', 'format', 'results', 'total_results', 'warning'])
        self.assertEqual(reply['total_results'], 2)
        row = reply['results'][0]
        self.assertEqual(list(row), ['id', 'score', 'sortkey', 'extra_attributes', 'values'])
        self.assertEqual(row['extra_attributes'], {b'label': b'comet', b'opaque': b'\0\xfe'})
        self.assertEqual(row['sortkey'], b'#9')
        self.assertGreater(row['score'], 0)

    def test_flat_and_hnsw_use_filters_before_knn_and_return_distances(self):
        _, c = self.server()
        self.assertEqual(create(c), 'OK')
        for name, x, kind in (('c', 4, 'yes'), ('b', 1, 'yes'), ('a', 0, 'no')):
            c.call('HSET', 'item:' + name, 'body', name, 'kind', kind, 'point', point(x, 0), 'graph', point(x, 0))
        params = ('PARAMS', 2, 'q', point(0, 0), 'DIALECT', 2)
        for field in ('point', 'graph'):
            with self.subTest(field=field):
                self.assertEqual(ids(c, f'*=>[KNN 2 @{field} $q]', *params), [2, b'item:b', b'item:a'])
                self.assertEqual(ids(c, f'@kind:{{yes}}=>[KNN 1 @{field} $q AS d]', *params,
                                     'INKEYS', 2, 'item:c', 'item:a'), [1, b'item:c'])
                result = c.call('FT.SEARCH', 'catalog', f'*=>[KNN 2 @{field} $q AS d]', *params,
                                'RETURN', 2, 'body', 'd', 'SORTBY', 'd', 'DESC', 'WITHSORTKEYS', 'LIMIT', 0, 1)
                self.assertEqual(result, [2, b'item:b', b'#1', [b'd', b'1', b'body', b'b']])
                default = f'__{field}_score'
                result = c.call('FT.SEARCH', 'catalog', f'*=>[KNN 1 @{field} $q]', *params, 'RETURN', 1, default)
                self.assertEqual(result, [1, b'item:a', [default.encode(), b'0']])
                radius = c.call('FT.SEARCH', 'catalog', f'@{field}:[VECTOR_RANGE 1 $q]=>{{$YIELD_DISTANCE_AS: d}}',
                                *params, 'RETURN', 1, 'd', 'SORTBY', 'd')
                self.assertEqual(radius, [2, b'item:a', [b'd', b'0'], b'item:b', [b'd', b'1']])

    def test_scoped_flat_ties_and_limit_are_global(self):
        _, c = self.server('labels')
        low, high = sl.at('labels', 'U'), sl.at('labels', 'C')
        self.assertEqual(create(c, low), 'OK')
        for name, scope in (('z', high), ('a', high), ('b', low), ('c', low)):
            c.call(*scope, 'HSET', 'item:' + name, 'body', 'comet', 'point', point(1, 0))
        self.assertEqual(ids(c, 'comet', scope=high), [4, b'item:a', b'item:b', b'item:c', b'item:z'])
        self.assertEqual(ids(c, '*=>[KNN 1 @point $q]', 'PARAMS', 2, 'q', point(0, 0), scope=high), [1, b'item:a'])
        self.assertEqual(ids(c, '*=>[KNN 3 @point $q]', 'PARAMS', 2, 'q', point(0, 0), 'LIMIT', 1, 1,
                             scope=high), [3, b'item:b'])

    def test_owner_and_label_shadows_and_acl_prefix_coverage(self):
        s, c = self.server('both')
        low, alice, bob, hidden = (sl.at('both', 'U'), sl.at('both', 'C', 'alice'),
                                   sl.at('both', 'C', 'bob'), sl.at('both', 'S', 'bob'))
        self.assertEqual(create(c, low), 'OK')
        self.assertEqual(create(c, hidden, 'hidden'), 'OK')
        c.call(*alice, 'SET', 'item:shadow', 'not a hash')
        c.call(*low, 'HSET', 'item:shadow', 'body', 'background')
        c.call(*bob, 'HSET', 'item:bob', 'body', 'background')
        self.assertEqual(ids(c, 'background', scope=alice), [0])
        self.assertEqual(ids(c, 'background', scope=low), [1, b'item:shadow'])
        self.assertEqual(ids(c, 'background', scope=bob), [2, b'item:bob', b'item:shadow'])
        with self.assertRaisesRegex(ServerError, '^SEARCH_INDEX_NOT_FOUND Index not found: hidden$'):
            ids(c, '*', scope=alice, index='hidden')
        c.call(*sl.top('both'), 'ACL', 'SETUSER', 'limited', 'on', '>x', '+ft.search', '%R~item:shadow',
               'clearance:*', 'trust:*', 'owners:*', 'owner-shared')
        limited = s.client('limited')
        self.addCleanup(limited.close)
        with self.assertRaisesRegex(ServerError, '^NOPERM User does not have the required permissions to query the index$'):
            ids(limited, '*', scope=low)
        c.call(*sl.top('both'), 'ACL', 'SETUSER', 'limited', '%R~item:*')
        self.assertEqual(ids(limited, 'background', scope=low), [1, b'item:shadow'])

    def test_held_expiry_is_filtered_without_reaping_foreign_data(self):
        _, c = self.server('labels')
        low, reader, top = sl.at('labels', 'U'), sl.at('labels', 'C'), sl.top('labels')
        c.call(*top, 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        self.assertEqual(create(c, low), 'OK')
        c.call(*low, 'HSET', 'item:key', 'body', 'comet', 'point', point(0, 0))
        c.call(*low, 'HSET', 'item:field', 'body', 'comet', 'point', point(1, 0))
        c.call(*low, 'HSET', 'item:live', 'body', 'safe', 'point', point(2, 0))
        self.assertEqual(ids(c, 'comet', scope=reader), [2, b'item:field', b'item:key'])

        def clock_ms():
            seconds, micros = c.call(*top, 'TIME')
            return int(seconds) * 1000 + int(micros) // 1000

        deadline = clock_ms() + 120
        c.call(*low, 'PEXPIREAT', 'item:key', deadline)
        c.call(*low, 'HPEXPIREAT', 'item:field', deadline, 'FIELDS', 2, 'body', 'point')
        sl.wait_for(lambda: clock_ms() > deadline, what='the key and hash-field deadlines')
        self.assertEqual(ids(c, 'comet', scope=reader), [0])
        self.assertEqual(ids(c, '*=>[KNN 1 @point $q]', 'PARAMS', 2, 'q', point(0, 0), scope=reader),
                         [1, b'item:live'])
        self.assertEqual(c.call(*low, 'DBSIZE'), 3)

    def test_pipeline_exec_and_eval_publish_before_a_query(self):
        _, c = self.server()
        self.assertEqual(create(c), 'OK')
        result = c.pipeline([('HSET', 'item:change', 'body', 'comet'),
                             ('FT.SEARCH', 'catalog', 'comet', 'NOCONTENT'),
                             ('HSET', 'item:change', 'body', 'wolf'),
                             ('FT.SEARCH', 'catalog', 'comet', 'NOCONTENT')])
        self.assertEqual(result, [1, [1, b'item:change'], 0, [0]])
        self.assertEqual(c.call('MULTI'), 'OK')
        c.call('HSET', 'item:second', 'body', 'wolf')
        c.call('FT.SEARCH', 'catalog', 'wolf', 'NOCONTENT')
        self.assertEqual(c.call('EXEC'), [1, [2, b'item:change', b'item:second']])
        script = "redis.call('HSET',KEYS[1],'body','bear'); return redis.call('FT.SEARCH','catalog','bear','NOCONTENT')"
        self.assertEqual(c.call('EVAL', script, 1, 'item:third'), [1, b'item:third'])

    def test_errors_and_empty_index_without_a_storage_partition(self):
        _, c = self.server('labels')
        low = sl.at('labels', 'U')
        self.assertEqual(create(c, low), 'OK')
        self.assertEqual(ids(c, 'comet', scope=low), [0])
        self.assertEqual(ids(c, '*', 'TIMEOUT', 0, scope=low), [0])
        self.assertEqual(ids(c, '*', 'TIMEOUT', 9223372036854775806, scope=low), [0])
        cases = (
            (('catalog', '*', 'SORTBY', 'unknown'), r'^SEARCH_PROP_NOT_FOUND Property `unknown` not loaded nor in schema$'),
            (('catalog', '*', 'DIALECT', 10), '^SEARCH_PARSE_ARGS DIALECT requires a non negative integer >=1 and <= 4$'),
            (('catalog', '*=>[KNN 1 @point $q]', 'DIALECT', 2), r'^SEARCH_PARAM_NOT_FOUND Parameter not found `q`$'),
            (('catalog', '*=>[KNN 1 @point $q]', 'PARAMS', 2, 'q', b'bad', 'DIALECT', 2),
             r"^SEARCH_QUERY_BAD Error parsing vector similarity query: query vector blob size \(3\) does not match index's expected size \(8\)\.$"),
        )
        for argv, expected in cases:
            with self.subTest(argv=argv), self.assertRaisesRegex(ServerError, expected):
                c.call(*low, 'FT.SEARCH', *argv)
        self.assertEqual(c.call(*low, 'DBSIZE'), 0)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', default=str(BINARY))
    parser.add_argument('--keyspace-threads', default=0, type=int)
    parser.add_argument('--ports', default=os.getenv('ESKI_SEARCH_PORTS', ''))
    args, names = parser.parse_known_args()
    BINARY = Path(args.server).resolve()
    THREADS = args.keyspace_threads
    if args.ports:
        sl.use_ports(args.ports)
    unittest.main(argv=[sys.argv[0]] + names, verbosity=1)
