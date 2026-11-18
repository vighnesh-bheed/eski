import argparse
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
import scoped_log as sl
from support import Client, ServerError

BINARY = ROOT / 'bin/eski'
THREADS = 0
REFERENCE = None
BASE = None
ACL_DENIED = 'NOPERM User does not have the required permissions to query the index'
MISSING = 'SEARCH_INDEX_NOT_FOUND Index not found: '


def point(x, y=0):
    return struct.pack('<ff', x, y)


def create(c, scope=(), index='catalog'):
    schema = ['body', 'AS', 'text', 'TEXT', 'NOSTEM', 'price', 'NUMERIC', 'SORTABLE', 'kind', 'TAG']
    for name, method in [('vec', 'FLAT'), ('graph', 'HNSW')]:
        schema.extend((name, 'VECTOR', method, 6, 'TYPE', 'FLOAT32', 'DIM', 2, 'DISTANCE_METRIC', 'L2'))
    return c.call(*scope, 'FT.CREATE', index, 'ON', 'HASH', 'PREFIX', 1, 'doc:', 'STOPWORDS', 0, 'SCHEMA', *schema)


def add(c, name, price, x, text='fox', kind='one', scope=()):
    return c.call(*scope, 'HSET', 'doc:' + name, 'body', text, 'price', price, 'kind', kind,
                  'vec', point(x), 'graph', point(x), 'binary', b'\x00\xff')


def corpus(c):
    create(c)
    for name, price, x, text, kind in [('a', 1, 2, 'fox', 'one'), ('b', 3, 0, 'wolf', 'two'),
                                        ('c', 2, 1, 'fox', 'one'), ('d', 8, 4, 'fox', 'two')]:
        add(c, name, price, x, text, kind)


def agg(c, *args, query='*', index='catalog', scope=()):
    return c.call(*scope, 'FT.AGGREGATE', index, query, *args)


def hybrid(c, *args, query='fox', field='vec', index='catalog', scope=(), text_alias=''):
    scoring = ('YIELD_SCORE_AS', text_alias) if text_alias else ()
    return c.call(*scope, 'FT.HYBRID', index, 'SEARCH', query, *scoring, 'VSIM', '@' + field, '$q', *args,
                  'PARAMS', 2, 'q', point(0))


def pairs(reply):
    return reply if isinstance(reply, dict) else dict(zip(reply[::2], reply[1::2]))


def normalized_hybrid(reply):
    out = pairs(reply)
    value = out.pop('execution_time')
    if not isinstance(value, (bytes, float)) or float(value) < 0:
        raise AssertionError('invalid execution_time')
    return out['total_results'], [pairs(row) for row in out['results']], out['warnings']


def stats(c, scope=(), index='catalog'):
    return pairs(pairs(c.call(*scope, 'FT.INFO', index))['cursor_stats'])


def cursor(c, *options, index='catalog', scope=(), count=1, idle=300000):
    return agg(c, 'LOAD', 2, '@__key', '@binary', 'SORTBY', 1, '@__key', 'WITHCURSOR', 'COUNT', count,
               'MAXIDLE', idle, *options, index=index, scope=scope)


class SearchPipeline(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='eski-search-pipeline-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.servers = 0

    def server(self, mode='', binary=None):
        path = self.root / str(self.servers)
        self.servers += 1
        path.mkdir()
        server = sl.Server(binary or BINARY, path, mode, (), THREADS)
        self.addCleanup(self.stop, server)
        c = server.up()
        self.addCleanup(c.close)
        print('Eski PID', server.run.process.pid, 'port', server.run.port, flush=True)
        return server, c

    def stop(self, server):
        if server.run.process is None:
            return
        code = server.stop()
        output = server.run.log()
        self.assertEqual(code, 0, output)
        self.assertNotIn('AddressSanitizer', output)

    def test_aggregate_pipeline_resp2_and_resp3(self):
        _, c = self.server()
        corpus(c)
        query = ('LOAD', 5, '@__key', '@kind', '@price', 'AS', 'n',
                 'APPLY', 'sqrt(@n) + 1', 'AS', 's', 'FILTER', '@s >= 2 && @kind == "one"',
                 'SORTBY', 2, '@s', 'DESC', 'MAX', 1)
        expected = {b'__key': b'doc:c', b'kind': b'one', b'n': b'2', b's': b'2.41421356237'}
        self.assertEqual(agg(c, *query), [2, [item for pair in expected.items() for item in pair]])
        self.assertEqual(agg(c, 'SORTBY', 1, '@price', 'MAX', 2, 'LIMIT', 1, 1), [4, [b'price', b'2']])
        option = ('ADDSCORES', 'LOAD', 1, '@__key', 'SORTBY', 2, '@__score', 'DESC')
        score_result = agg(c, *option, query='fox')
        score = float(score_result[1][1])
        self.assertGreater(score, 0)
        self.assertEqual([row[1] for row in score_result[1:]], [score_result[1][1]] * 3)
        c.call('HELLO', 3)
        reply = agg(c, *query)
        self.assertEqual(list(reply), ['attributes', 'format', 'results', 'total_results', 'warning'])
        self.assertEqual(reply, {'attributes': [], 'format': 'STRING',
                                 'results': [{'extra_attributes': expected, 'values': []}],
                                 'total_results': 2, 'warning': []})

    def test_group_reducers_and_ranges(self):
        _, c = self.server()
        corpus(c)
        group = ('GROUPBY', 1, '@kind', 'REDUCE', 'COUNT', 0, 'AS', 'n',
                 'REDUCE', 'SUM', 1, '@price', 'AS', 'sum', 'REDUCE', 'AVG', 1, 'price', 'AS', 'mean',
                 'REDUCE', 'MIN', 1, '@price', 'AS', 'min', 'REDUCE', 'MAX', 1, '@price', 'AS', 'max',
                 'REDUCE', 'COUNT_DISTINCT', 1, '@price', 'AS', 'distinct',
                 'REDUCE', 'TOLIST', 1, '@price', 'AS', 'list',
                 'REDUCE', 'FIRST_VALUE', 4, '@price', 'BY', '@price', 'DESC', 'AS', 'high',
                 'REDUCE', 'STDDEV', 1, '@price', 'AS', 'std', 'REDUCE', 'QUANTILE', 2, '@price', '.5', 'AS', 'mid',
                 'SORTBY', 1, '@kind')
        result = agg(c, *group)
        self.assertEqual(result[0], 2)
        self.assertEqual(pairs(result[1]), {b'kind': b'one', b'n': b'2', b'sum': b'3', b'mean': b'1.5',
                                           b'min': b'1', b'max': b'2', b'distinct': b'2', b'list': [b'1', b'2'],
                                           b'high': b'2', b'std': b'0.707106781187', b'mid': b'1'})
        self.assertEqual(pairs(result[2])[b'sum'], b'11')
        result = agg(c, 'DIALECT', 2, 'PARAMS', 2, 'q', point(0), 'LOAD', 1, '@__key',
                     'APPLY', '(2 - (@dist + abs(@dist))/2)/2', 'AS', 'similarity', 'SORTBY', 2, '@similarity', 'DESC',
                     query='@vec:[VECTOR_RANGE 1 $q]=>{$YIELD_DISTANCE_AS: dist}')
        self.assertEqual(result, [2, [b'dist', b'0', b'__key', b'doc:b', b'similarity', b'1'],
                                  [b'dist', b'1', b'__key', b'doc:c', b'similarity', b'0.5']])
        result = agg(c, 'PARAMS', 2, 'q', point(0), 'DIALECT', 2, 'LOAD', 1, '@__key',
                     query='*=>[KNN 2 @vec $q AS d]')
        self.assertEqual(result, [2, [b'd', b'0', b'__key', b'doc:b'],
                                  [b'd', b'1', b'__key', b'doc:c']])

    def test_additional_expressions_and_collect(self):
        _, c = self.server()
        corpus(c)
        opts = ('DIALECT', 2, 'LOAD', 1, '@__key', 'APPLY', 'matched_terms(1)', 'AS', 'words',
                'APPLY', 'contains("aaa", "aa")', 'AS', 'count',
                'APPLY', 'geodistance("0,0", "1,1")', 'AS', 'metres',
                'APPLY', 'timefmt(0)', 'AS', 'epoch', 'SORTBY', 1, '@__key')
        result = agg(c, *opts, query='(@kind:{one}) | wolf')
        self.assertEqual(result[0], 3)
        fields = [pairs(row) for row in result[1:]]
        self.assertEqual([row[b'words'] for row in fields], [[b'one'], [b'wolf'], [b'one']])
        self.assertEqual(fields[0][b'count'], b'2')
        self.assertEqual(fields[0][b'metres'], b'157293.75')
        self.assertEqual(fields[0][b'epoch'], b'1970-01-01T00:00:00Z')
        query = ('LOAD', 2, '@__key', '@price', 'GROUPBY', 1, '@kind',
                 'REDUCE', 'COLLECT', 7, 'FIELDS', 2, '@__key', '@price', 'SORTBY', 1, '@price', 'AS', 'rows',
                 'SORTBY', 1, '@kind')
        self.assertEqual(pairs(agg(c, *query)[1])[b'rows'], [[b'__key', b'doc:a', b'price', b'1'],
                                                           [b'__key', b'doc:c', b'price', b'2']])
        c.call('HELLO', 3)
        collected = agg(c, *query)['results'][0]['extra_attributes'][b'rows']
        self.assertEqual(collected, [{b'__key': b'doc:a', b'price': b'1'}, {b'__key': b'doc:c', b'price': b'2'}])

    def test_hybrid_rank_window_and_vector_filter(self):
        _, c = self.server()
        corpus(c)
        for field in ('vec', 'graph'):
            r = hybrid(c, 'KNN', 2, 'K', 2, 'YIELD_SCORE_AS', 'vs', 'COMBINE', 'RRF', 6,
                       'WINDOW', 2, 'CONSTANT', 10, 'YIELD_SCORE_AS', 'score',
                       'LOAD', 1, '@__key', field=field, text_alias='ts')
            total, rows, warns = normalized_hybrid(r)
            self.assertEqual(total, 3)
            self.assertEqual(warns, [])
            self.assertEqual([row[b'__key'] for row in rows], [b'doc:c', b'doc:a', b'doc:b'])
            self.assertAlmostEqual(float(rows[0][b'score']), 2 / 12)
            self.assertEqual(rows[0][b'vs'], b'0.5')
            self.assertNotIn(b'vs', rows[1])
            self.assertNotIn(b'ts', rows[2])
        c.call('HELLO', 3)
        r = hybrid(c, 'RANGE', 2, 'RADIUS', 1, 'FILTER', '@kind:{one}', 'YIELD_SCORE_AS', 'vs', 'COMBINE',
                   'LINEAR', 6, 'ALPHA', '0.3', 'BETA', '0.7', 'YIELD_SCORE_AS', 'h',
                   'LOAD', 2, '@__key', '@text', 'APPLY', '@h*2', 'AS', 'doubled', 'LIMIT', 0, 1, text_alias='ts')
        total, rows, warns = normalized_hybrid(r)
        self.assertEqual((total, warns), (3, []))
        self.assertEqual(rows[0][b'__key'], b'doc:c')
        self.assertEqual(rows[0][b'text'], b'fox')
        self.assertAlmostEqual(float(rows[0][b'h']), .3 * float(rows[0][b'ts']) + .7 * .5)
        self.assertAlmostEqual(float(rows[0][b'doubled']), 2 * float(rows[0][b'h']))

    def test_parser_errors_before_execution(self):
        _, c = self.server()
        create(c)
        cases = [
            (('FT.AGGREGATE', 'catalog', '*', 'GROUPBY', 5, '@price'),
             'SEARCH_PARSE_ARGS Bad arguments for GROUPBY: Expected an argument, but none provided'),
            (('FT.AGGREGATE', 'catalog', '*', 'GROUPBY', 0, 'REDUCE', 'NOPE', 0),
             'SEARCH_REDUCER_NOT_FOUND No such reducer: NOPE'),
            (('FT.AGGREGATE', 'catalog', '*', 'SORTBY', 1, '@price', 'MAX', 'NaN'),
             'SEARCH_PARSE_ARGS Bad arguments for MAX: Could not convert argument to expected type'),
            (('FT.AGGREGATE', 'catalog', '*', 'APPLY', 'silly(1)', 'AS', 'v'), "SEARCH_EXPR Unknown function name 'silly'"),
            (('FT.AGGREGATE', 'catalog', '*', 'FILTER', '@absent == 0'),
             'SEARCH_PROP_NOT_FOUND Property not loaded nor in pipeline: `absent`'),
            (('FT.HYBRID', 'catalog', 'SEARCH', 'fox', 'VSIM', '@vec', 'inline'),
             'SEARCH_SYNTAX Invalid vector argument, expected a parameter name starting with $'),
            (('FT.HYBRID', 'catalog', 'SEARCH', 'fox', 'VSIM', '@vec', '$q'),
             'SEARCH_PARAM_NOT_FOUND Parameter not found `q`'),
            (('FT.HYBRID', 'catalog', 'SEARCH', 'fox', 'VSIM', '@text', '$q'),
             'SEARCH_SYNTAX Expected a VECTOR field `text`'),
            (('FT.HYBRID', 'catalog', 'SEARCH', 'fox', 'VSIM', '@vec', '$q', 'PARAMS', 2, 'q', b'abc'),
             "SEARCH_QUERY_BAD Error parsing vector similarity query: query vector blob size (3) does not match index's expected size (8)."),
            (('FT.HYBRID', 'catalog', 'SEARCH', 'fox', 'VSIM', '@vec', '$q', 'KNN', 2, 'K', 'abc'),
             'SEARCH_SYNTAX Invalid K value'),
            (('FT.HYBRID', 'catalog', 'SEARCH', 'fox', 'VSIM', '@vec', '$q', 'COMBINE', 'LINEAR', 2, 'ALPHA', .5),
             'SEARCH_SYNTAX Missing value for BETA'),
        ]
        for protocol in (2, 3):
            c.call('HELLO', protocol)
            for command, expected in cases:
                with self.subTest(command=command, protocol=protocol), self.assertRaisesRegex(ServerError, '^' + re.escape(expected) + '$'):
                    c.call(*command)

    def test_cursor_pages_counts_and_release(self):
        s, c = self.server()
        corpus(c)
        response, handle = cursor(c, count=2)
        self.assertEqual(response, [4, [b'__key', b'doc:a', b'binary', b'\x00\xff'],
                                      [b'__key', b'doc:b', b'binary', b'\x00\xff']])
        self.assertGreater(handle, 0)
        self.assertEqual(stats(c)['index_total'], 1)
        d = s.client()
        self.addCleanup(d.close)
        d.call('HELLO', 3)
        response, remaining = d.call('FT.CURSOR', 'READ', 'catalog', handle)
        self.assertEqual(remaining, handle)
        self.assertEqual(response['total_results'], 0)
        self.assertEqual([r['extra_attributes'][b'__key'] for r in response['results']], [b'doc:c', b'doc:d'])
        response, remaining = d.call('FT.CURSOR', 'READ', 'catalog', handle)
        self.assertEqual((response['results'], remaining), ([], 0))
        self.assertEqual(stats(c)['index_total'], 0)
        with self.assertRaisesRegex(ServerError, 'Cursor not found, id: ' + str(handle)):
            c.call('FT.CURSOR', 'READ', 'catalog', handle)
        _, handle = cursor(c)
        self.assertEqual(c.call('FT.CURSOR', 'DEL', 'catalog', handle), 'OK')
        with self.assertRaisesRegex(ServerError, '^Cursor does not exist$'):
            c.call('FT.CURSOR', 'DEL', 'catalog', handle)
        result = pairs(hybrid(c, 'KNN', 2, 'K', 2, 'YIELD_SCORE_AS', 'vs', 'WITHCURSOR', 'COUNT', 1,
                              text_alias='ts'))
        self.assertGreater(result['SEARCH'], 0)
        self.assertGreater(result['VSIM'], 0)
        self.assertNotEqual(result['SEARCH'], result['VSIM'])
        self.assertEqual(c.call('FT.CURSOR', 'READ', 'catalog', result['VSIM'], 'COUNT', 10),
                         [[2, [b'vs', b'1', b'__key', b'doc:b'], [b'vs', b'0.5', b'__key', b'doc:c']], 0])
        self.assertEqual(c.call('FT.CURSOR', 'DEL', 'catalog', result['SEARCH']), 'OK')
        self.assertEqual(stats(c)['index_total'], 0)

    def test_cursor_acl_and_definition_lifecycle(self):
        s, c = self.server()
        corpus(c)
        for user in ('limited', 'other'):
            c.call('ACL', 'SETUSER', user, 'on', '>x', '+@search', '%R~doc:*')
        r = s.client('limited')
        self.addCleanup(r.close)
        _, handle = cursor(r)
        self.assertEqual(r.call('AUTH', 'other', 'x'), 'OK')
        with self.assertRaisesRegex(ServerError, '^Cursor not found, id: ' + str(handle) + '$'):
            r.call('FT.CURSOR', 'READ', 'catalog', handle)
        r.call('AUTH', 'limited', 'x')
        c.call('ACL', 'SETUSER', 'limited', 'resetkeys', '%R~other:*')
        for cmd in [('FT.CURSOR', 'READ', 'catalog', handle), ('FT.AGGREGATE', 'catalog', '*'),
                    ('FT.HYBRID', 'catalog', 'SEARCH', 'fox', 'VSIM', '@vec', '$q')]:
            with self.assertRaisesRegex(ServerError, '^' + ACL_DENIED + '$'):
                r.call(*cmd)
        c.call('ACL', 'SETUSER', 'limited', '%R~doc:*')
        self.assertEqual(r.call('FT.CURSOR', 'DEL', 'catalog', handle), 'OK')
        _, handle = cursor(r)
        c.call('ACL', 'DELUSER', 'limited')
        self.assertEqual(stats(c)['index_total'], 0)
        c.call('ACL', 'SETUSER', 'limited', 'on', '>x', '+@search', '%R~doc:*')
        fresh = s.client('limited')
        self.addCleanup(fresh.close)
        with self.assertRaisesRegex(ServerError, 'Cursor not found, id: ' + str(handle)):
            fresh.call('FT.CURSOR', 'READ', 'catalog', handle)
        for operation in [('FT.DROPINDEX', 'catalog'), ('FLUSHALL',)]:
            _, handle = cursor(c)
            c.call(*operation)
            with self.assertRaisesRegex(ServerError, '^' + MISSING + 'catalog$'):
                c.call('FT.CURSOR', 'READ', 'catalog', handle)
            corpus(c)
            self.assertEqual(stats(c)['index_total'], 0)

    def test_cursor_deadline_recreation_and_owner_forget(self):
        _, c = self.server('both')
        alice, top, shared = sl.at('both', 'C', 'alice'), sl.top('both'), sl.at('both', 'U')
        create(c, shared)
        add(c, 'a', 1, 0, scope=alice)
        add(c, 'b', 2, 1, scope=alice)
        def clock_ms():
            sec, usec = c.call(*top, 'TIME')
            return int(sec) * 1000 + int(usec) // 1000
        deadline = clock_ms() + 200
        self.assertEqual(c.call(*alice, 'PEXPIREAT', 'doc:b', deadline), 1)
        _, handle = cursor(c, scope=alice)
        self.assertGreater(handle, 0)
        c.call(*alice, 'DEL', 'doc:b')
        add(c, 'b', 9, 1, text='wolf', scope=alice)
        sl.wait_for(lambda: clock_ms() >= deadline, what='original hash key deadline')
        with self.assertRaisesRegex(ServerError, 'Cursor not found, id: ' + str(handle)):
            c.call(*alice, 'FT.CURSOR', 'READ', 'catalog', handle)
        _, cursor_id = cursor(c, scope=alice)
        self.assertEqual(stats(c, alice)['index_total'], 0)
        self.assertEqual(stats(c, top)['index_total'], 1)
        c.call(*top, 'OWNERS', 'FORGET', 'alice')
        self.assertEqual(stats(c, top)['index_total'], 0)
        add(c, 'fresh', 1, 0, scope=alice)
        with self.assertRaisesRegex(ServerError, 'Cursor not found, id: ' + str(cursor_id)):
            c.call(*alice, 'FT.CURSOR', 'READ', 'catalog', cursor_id)
        _, cursor_id = cursor(c, scope=alice)
        c.call(*alice, 'FLUSHDB')
        self.assertEqual(stats(c, top)['index_total'], 0)
        with self.assertRaisesRegex(ServerError, 'Cursor not found, id: ' + str(cursor_id)):
            c.call(*alice, 'FT.CURSOR', 'READ', 'catalog', cursor_id)

    def test_flush_releases_cursor_with_nonmatching_partition_dependency(self):
        _, c = self.server('both')
        shared, higher, reader, top = (sl.at('both', 'U'), sl.at('both', 'C'),
                                       sl.at('both', 'S', 'alice'), sl.top('both'))
        create(c, shared)
        add(c, 'shared', 5, 3, text='unique', scope=shared)
        add(c, 'other', 1, 4, text='unmatched', scope=higher)
        _, handle = agg(c, 'ADDSCORES', 'SORTBY', 1, '@__score', 'WITHCURSOR', 'COUNT', 1,
                        query='unique', scope=reader)
        self.assertGreater(handle, 0)
        self.assertEqual(stats(c, top)['index_total'], 1)
        c.call(*higher, 'FLUSHDB')
        self.assertEqual(stats(c, top)['index_total'], 0)
        with self.assertRaisesRegex(ServerError, 'Cursor not found, id: ' + str(handle)):
            c.call(*reader, 'FT.CURSOR', 'READ', 'catalog', handle)
        self.assertEqual(agg(c, 'LOAD', 1, '@__key', scope=reader), [1, [b'__key', b'doc:shared']])

    def test_scope_twins_expiry_shadow_and_global_limits(self):
        _, a = self.server('both')
        _, b = self.server('both')
        pair = sl.Pair(a, b)
        shared, alice, bob, top = sl.at('both', 'U'), sl.at('both', 'C', 'alice'), sl.at('both', 'C', 'bob'), sl.top('both')
        create(pair, shared)
        create(pair, alice, 'private')
        create(b, bob, 'private')
        add(pair, 'm', 5, 0, scope=shared)
        add(pair, 'o', 6, 0, scope=shared)
        add(pair, 'z', 3, 0, scope=alice)
        add(pair, 'a', 4, 0, scope=alice)
        pair.call(*alice, 'SET', 'doc:shadow', 'plain shadow')
        add(pair, 'shadow', 20, 0, scope=shared)
        add(b, '00-hidden', 100, 0, scope=bob)
        add(b, 'a', 100, 0, scope=bob)
        foreign_page, foreign_id = cursor(b, scope=bob, index='private')
        self.assertGreater(foreign_id, 0)
        self.assertTrue(foreign_page)
        with self.assertRaisesRegex(ServerError, 'Cursor not found, id: ' + str(foreign_id)):
            pair.call(*alice, 'FT.CURSOR', 'READ', 'private', foreign_id)
        with self.assertRaisesRegex(ServerError, 'Cursor does not exist'):
            pair.call(*alice, 'FT.CURSOR', 'DEL', 'private', foreign_id)
        with self.assertRaisesRegex(ServerError, '^' + MISSING + 'absent$'):
            pair.call(*alice, 'FT.AGGREGATE', 'absent', '*', 'nonsense')
        self.assertEqual(stats(a, alice), stats(b, alice))
        self.assertEqual(agg(pair, 'GROUPBY', 0, 'REDUCE', 'SUM', 1, '@price', 'AS', 'sum', scope=alice),
                         [1, [b'sum', b'18']])
        for field, neighbors in (('vec', 1), ('graph', 2)):
            result = hybrid(pair, 'KNN', 2, 'K', neighbors, 'COMBINE', 'RRF', 2, 'WINDOW', 1, field=field, scope=alice)
            self.assertEqual(normalized_hybrid(result)[1], [{b'__key': b'doc:a', b'__score': b'0.0327868852459'}])
            result = agg(pair, 'LOAD', 1, '@__key', 'DIALECT', 2, 'PARAMS', 2, 'q', point(0),
                         query=f'*=>[KNN 2 @{field} $q AS d]', scope=alice)
            self.assertEqual([pairs(row)[b'__key'] for row in result[1:]], [b'doc:a', b'doc:m'])
        pair.call(*top, 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        for c in (a, b):
            sec, usec = c.call(*top, 'TIME')
            deadline = int(sec) * 1000 + int(usec) // 1000 + 60
            c.call(*shared, 'HPEXPIREAT', 'doc:m', deadline, 'FIELDS', 1, 'body')
            def past():
                sec, usec = c.call(*top, 'TIME')
                return int(sec) * 1000 + int(usec) // 1000 > deadline
            sl.wait_for(past, what='hash field expiry')
        result = agg(pair, 'LOAD', 1, '@__key', 'SORTBY', 1, '@__key', scope=alice, query='fox')
        self.assertEqual(result, [3, [b'__key', b'doc:a'], [b'__key', b'doc:o'], [b'__key', b'doc:z']])

    def test_idle_cursor_reaping_and_capacity(self):
        _, c = self.server()
        corpus(c)
        handles = [cursor(c)[1] for _ in range(128)]
        self.assertEqual(len(set(handles)), 128)
        with self.assertRaisesRegex(ServerError, 'SEARCH_LIMIT_OVER INDEX_CURSOR_LIMIT of 128'):
            cursor(c)
        self.assertEqual(c.call('FT.CURSOR', 'DEL', 'catalog', handles.pop()), 'OK')
        handles.append(cursor(c)[1])
        for handle in handles:
            c.call('FT.CURSOR', 'DEL', 'catalog', handle)
        expiring = [cursor(c, idle=500)[1] for _ in range(70)]
        self.assertEqual(stats(c)['index_total'], len(expiring))
        sl.wait_for(lambda: stats(c)['index_total'] == 0, what='all idle cursors to be reaped')
        with self.assertRaisesRegex(ServerError, 'Cursor not found, id: ' + str(expiring[0])):
            c.call('FT.CURSOR', 'READ', 'catalog', expiring[0])

    def test_reference_replies(self):
        if REFERENCE is None:
            self.skipTest('reference port was not supplied')
        _, c = self.server()
        ref = Client(REFERENCE)
        self.addCleanup(ref.close)
        sl.Pair(c, ref).call('FLUSHALL')
        corpus(c)
        corpus(ref)
        aggregate_cases = [
            ('LOAD', 4, '@price', 'AS', 'n', '@__key', 'SORTBY', 2, '@n', 'DESC', 'MAX', 3, 'LIMIT', 1, 2),
            ('LOAD', 2, '@price', '@kind', 'APPLY', 'format("%s!", @kind)', 'AS', 'title',
             'FILTER', '@price >= 2', 'SORTBY', 1, '@price'),
            ('GROUPBY', 1, '@kind', 'REDUCE', 'AVG', 1, 'price', 'AS', 'mean', 'SORTBY', 1, '@kind'),
            ('ADDSCORES', 'SORTBY', 2, '@__score', 'DESC'),
        ]
        hybrid_cases = [
            ('COMBINE', 'RRF', 6, 'WINDOW', 2, 'CONSTANT', 10, 'YIELD_SCORE_AS', 'h', 'LOAD', 2, '@__key', '@text'),
            ('KNN', 2, 'K', 2, 'YIELD_SCORE_AS', 'v', 'COMBINE', 'LINEAR', 6, 'ALPHA', .3, 'BETA', .7,
             'YIELD_SCORE_AS', 'h', 'LOAD', 1, '@__key'),
            ('RANGE', 2, 'RADIUS', 1, 'FILTER', '@kind:{one}', 'LOAD', 1, '@__key'),
        ]
        for protocol in (2, 3):
            c.call('HELLO', protocol)
            ref.call('HELLO', protocol)
            for command in aggregate_cases:
                self.assertEqual(agg(c, *command), agg(ref, *command), command)
            for command in hybrid_cases:
                self.assertEqual(normalized_hybrid(hybrid(c, *command, text_alias='ts')),
                                 normalized_hybrid(hybrid(ref, *command, text_alias='ts')), command)
            first = [cursor(client, count=2) for client in (c, ref)]
            self.assertEqual(first[0][0], first[1][0])
            for count in (2, 2):
                same = [client.call('FT.CURSOR', 'READ', 'catalog', saved[1], 'COUNT', count)
                        for client, saved in zip((c, ref), first)]
                self.assertEqual(same[0][0], same[1][0])
                self.assertEqual(same[0][1] == 0, same[1][1] == 0)

    def test_command_metadata_and_subcommand_acl(self):
        server, c = self.server()
        corpus(c)
        info = c.call('COMMAND', 'INFO', 'FT.AGGREGATE', 'FT.HYBRID', 'FT.CURSOR', 'ft.cursor|read')
        for entry, arity in zip(info, (-3, -7, -2, -4)):
            self.assertEqual(entry[1:6], [arity, ['readonly', 'module'], 0, 0, 0])
        self.assertEqual(info[2][6:9], [['@read', '@search'], [], []])
        self.assertEqual({entry[0]: entry[7] for entry in info[2][9]},
                         {b'FT.CURSOR|DEL': [b'request_policy:special', b'dont_cache'],
                          b'FT.CURSOR|READ': [b'request_policy:special', b'dont_cache'],
                          b'FT.CURSOR|GC': [b'dont_cache']})
        c.call('ACL', 'SETUSER', 'restricted', 'on', '>x', '+@search', '%R~doc:*', '-ft.cursor|read')
        u = server.client('restricted')
        self.addCleanup(u.close)
        _, handle = cursor(u)
        with self.assertRaisesRegex(ServerError, 'NOPERM'):
            u.call('FT.CURSOR', 'read', 'catalog', handle)
        self.assertEqual(u.call('FT.CURSOR', 'del', 'catalog', handle), 'OK')

    def test_existing_search_matches_base(self):
        if BASE is None:
            self.skipTest('base binary was not supplied')
        _, c = self.server()
        _, base = self.server(binary=BASE)
        corpus(c)
        corpus(base)
        pair = sl.Pair(c, base)
        for protocol in (2, 3):
            c.call('HELLO', protocol)
            base.call('HELLO', protocol)
            for args in [('fox', 'WITHSCORES', 'NOCONTENT'),
                         ('@kind:{one}', 'RETURN', 3, 'text', 'price', 'binary', 'SORTBY', 'price', 'DESC'),
                         ('*=>[KNN 2 @vec $q AS d]', 'DIALECT', 2, 'PARAMS', 2, 'q', point(0), 'SORTBY', 'd')]:
                pair.call('FT.SEARCH', 'catalog', *args)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', default=str(BINARY))
    parser.add_argument('--keyspace-threads', default=0, type=int)
    parser.add_argument('--ports', default=os.getenv('ESKI_SEARCH_PORTS', ''))
    parser.add_argument('--reference-port', type=int)
    parser.add_argument('--base')
    args, names = parser.parse_known_args()
    BINARY = Path(args.server).resolve()
    THREADS = args.keyspace_threads
    REFERENCE = args.reference_port
    BASE = Path(args.base).resolve() if args.base else None
    if args.ports:
        sl.use_ports(args.ports)
    unittest.main(argv=[sys.argv[0]] + names, verbosity=1)
