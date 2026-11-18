import argparse
import json
import os
from pathlib import Path
import socket
import struct
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
import scoped_log as sl
from support import Client, ServerError, encode

BINARY = ROOT / 'bin/eski'
THREADS = 0
REFERENCE = None
QUERY = struct.pack('<ff', 1, 1)
KNN = '*=>[KNN 2 @v $q AS d]'
UNKNOWN_FIELD = 'SEARCH_SYNTAX Unknown field at offset 0 near zz'
MISSING_VALUE = 'SEARCH_VALUE_NOT_FOUND Could not find the value for a parameter name, consider using EXISTS if applicable for '


class Incomplete(Exception):
    pass


def frame(data, at=0):
    if at >= len(data):
        raise Incomplete
    end = data.find(b'\r\n', at)
    if end < 0:
        raise Incomplete
    kind, head, after = data[at:at + 1], data[at + 1:end], end + 2
    if kind in b'+-:,_#(':
        return after
    if kind in b'$=!':
        size = int(head)
        if size < 0:
            return after
        if len(data) < after + size + 2:
            raise Incomplete
        return after + size + 2
    if kind in b'*~%>':
        count = int(head)
        for _ in range(max(0, count) * (2 if kind == b'%' else 1)):
            after = frame(data, after)
        return after
    raise AssertionError('unknown reply kind %r' % kind)


def framed(port, protocol, command):
    with socket.create_connection(('127.0.0.1', port), timeout=30) as s:
        data = b''
        if protocol == 3:
            s.sendall(encode(('HELLO', 3, 'SETNAME', 'framing')))
            while True:
                try:
                    hello = frame(data)
                    break
                except Incomplete:
                    data += s.recv(65536)
            data = data[hello:]
        s.sendall(encode(command) + encode(('PING',)))
        while not data.endswith(b'+PONG\r\n'):
            chunk = s.recv(65536)
            if not chunk:
                raise AssertionError('server closed the connection')
            data += chunk
    end = frame(data)
    return data[:end], data[end:]


def build(c, prefix='d:', name='e', scope=()):
    assert c.call(*scope, 'FT.CREATE', name, 'ON', 'HASH', 'PREFIX', 1, prefix, 'SCHEMA', 't', 'TEXT', 'g', 'TAG',
                  'n', 'NUMERIC', 'SORTABLE', 'v', 'VECTOR', 'FLAT', 6, 'TYPE', 'FLOAT32', 'DIM', 2,
                  'DISTANCE_METRIC', 'L2') == 'OK'
    rows = [('1', 'red fox', 'a', 1, (1, 0)), ('2', 'red dog', 'b', 2, (0, 1)), ('3', 'blue fox runs', None, 3, (1, 1)),
            ('4', 'green fox', 'a', 4, (2, 0)), ('5', 'grey wolf', 'c', 5, (3, 3))]
    for key, text, tag, n, vec in rows:
        fields = ['t', text, 'n', n, 'v', struct.pack('<ff', *vec)]
        if tag is not None:
            fields += ['g', tag]
        c.call(*scope, 'HSET', prefix + key, *fields)


def pairs(value):
    return value if isinstance(value, dict) else dict(zip(value[::2], value[1::2]))


def info(c, name, scope=()):
    return pairs(c.call(*scope, 'FT.INFO', name))


def total(reply):
    return reply['total_results'] if isinstance(reply, dict) else reply[0]


def keys(reply):
    if isinstance(reply, dict):
        return [row['id'] for row in reply['results']]
    return [item for item in reply[1:] if isinstance(item, bytes)]


def hybrid_keys(reply):
    rows = pairs(reply)['results']
    return [pairs(row)[b'__key'] for row in rows]


class SearchEdges(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='eski-search-edges-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.n = 0

    def server(self, mode='', extra=()):
        directory = self.root / str(self.n)
        self.n += 1
        directory.mkdir()
        server = sl.Server(BINARY, directory, mode, extra, THREADS)
        self.addCleanup(self.stop, server)
        c = server.up()
        self.addCleanup(c.close)
        print('Eski PID', server.run.process.pid, 'port', server.run.port, flush=True)
        return server, c

    def stop(self, server):
        if server.run.process is not None:
            code = server.stop()
            out = server.run.log()
            self.assertEqual(code, 0, out)
            self.assertNotIn('AddressSanitizer', out)

    def test_profile_replies_frame_exactly(self):
        server, c = self.server()
        build(c)
        params = ('PARAMS', 2, 'q', QUERY, 'DIALECT', 2)
        requests = [
            ('SEARCH', 'QUERY', KNN) + params,
            ('SEARCH', 'QUERY', '@g:{a}=>[KNN 2 @v $q AS d]') + params,
            ('SEARCH', 'QUERY', KNN, 'NOCONTENT') + params,
            ('SEARCH', 'QUERY', KNN, 'RETURN', 1, 'd') + params,
            ('SEARCH', 'LIMITED', 'QUERY', KNN) + params,
            ('SEARCH', 'QUERY', '@v:[VECTOR_RANGE 5 $q]=>{$YIELD_DISTANCE_AS: d}') + params,
            ('SEARCH', 'QUERY', 'fox'),
            ('SEARCH', 'QUERY', 'fox', 'NOCONTENT'),
            ('AGGREGATE', 'QUERY', KNN, 'LOAD', 1, '@d') + params,
            ('AGGREGATE', 'QUERY', '*', 'GROUPBY', 1, '@g'),
            ('HYBRID', 'QUERY', 'SEARCH', 'fox', 'VSIM', '@v', '$q', 'PARAMS', 2, 'q', QUERY),
        ]
        for protocol in (2, 3):
            for request in requests:
                with self.subTest(protocol=protocol, request=request[:4]):
                    reply, rest = framed(server.run.port, protocol, ('FT.PROFILE', 'e') + request)
                    self.assertEqual(rest, b'+PONG\r\n')
                    self.assertNotEqual(reply[:1], b'-', reply)
            with self.subTest(protocol=protocol, request='transaction'):
                with socket.create_connection(('127.0.0.1', server.run.port), timeout=30) as s:
                    s.sendall(encode(('MULTI',)) + encode(('FT.PROFILE', 'e') + requests[0]) + encode(('EXEC',)) + encode(('PING',)))
                    data = b''
                    while not data.endswith(b'+PONG\r\n'):
                        chunk = s.recv(65536)
                        self.assertTrue(chunk)
                        data += chunk
                at = frame(data)
                at = frame(data, at)
                at = frame(data, at)
                self.assertEqual(data[at:], b'+PONG\r\n')

    def test_hybrid_queries_parse_with_dialect_two(self):
        _, c = self.server()
        build(c)
        self.assertEqual(c.call('FT.CONFIG', 'GET', 'DEFAULT_DIALECT'), [['DEFAULT_DIALECT', b'1']])
        for search, vector_filter in (('fox', '@zz:{a}'), ('@zz:fox', None)):
            extra = ('FILTER', vector_filter) if vector_filter else ()
            with self.assertRaisesRegex(ServerError, '^' + UNKNOWN_FIELD + '$'):
                c.call('FT.HYBRID', 'e', 'SEARCH', search, 'VSIM', '@v', '$q', *extra, 'PARAMS', 2, 'q', QUERY)
        empty_filter = ('FILTER', '@g:{none}')
        reply = c.call('FT.HYBRID', 'e', 'SEARCH', '-red fox', 'VSIM', '@v', '$q', *empty_filter, 'PARAMS', 2, 'q', QUERY)
        self.assertEqual(sorted(hybrid_keys(reply)), [b'd:3', b'd:4'])
        reply = c.call('FT.HYBRID', 'e', 'SEARCH', '@n>=4', 'VSIM', '@v', '$q', *empty_filter, 'PARAMS', 2, 'q', QUERY)
        self.assertEqual(sorted(hybrid_keys(reply)), [b'd:4', b'd:5'])
        self.assertEqual(c.call('FT.CREATE', 'j', 'ON', 'JSON', 'PREFIX', 1, 'j:', 'SCHEMA', '$.t', 'AS', 't', 'TEXT',
                                '$.v', 'AS', 'v', 'VECTOR', 'FLAT', 6, 'TYPE', 'FLOAT32', 'DIM', 2, 'DISTANCE_METRIC', 'L2'), 'OK')
        c.call('JSON.SET', 'j:1', '$', json.dumps({'t': 'red fox', 'v': [1, 0]}))
        self.assertEqual(c.call('FT.CONFIG', 'SET', 'DEFAULT_DIALECT', 3), 'OK')
        reply = c.call('FT.HYBRID', 'j', 'SEARCH', 'fox', 'VSIM', '@v', '$q', 'LOAD', 1, '@t', 'PARAMS', 2, 'q', QUERY)
        self.assertEqual(pairs(pairs(reply)['results'][0])[b't'], b'red fox')
        self.assertEqual(c.call('FT.AGGREGATE', 'j', 'fox', 'LOAD', 1, '@t')[1], [b't', b'["red fox"]'])

    def test_null_group_keys_evaluate_as_null(self):
        _, c = self.server()
        build(c)
        base = ('FT.AGGREGATE', 'e', '*', 'GROUPBY', 1, '@g', 'REDUCE', 'COUNT', 0, 'AS', 'k')
        reply = c.call(*base, 'FILTER', "(@g == 'a' && @k > 0) || (@g == 'b' && @k > 0)", 'SORTBY', 2, '@g', 'ASC')
        self.assertEqual(reply, [2, [b'g', b'a', b'k', b'2'], [b'g', b'b', b'k', b'1']])
        reply = c.call(*base, 'FILTER', "@g != 'a'", 'SORTBY', 2, '@g', 'ASC')
        self.assertEqual(reply[1:], [[b'g', None, b'k', b'1'], [b'g', b'b', b'k', b'1'], [b'g', b'c', b'k', b'1']])
        for expression, value in (('exists(@g)', b'1'), ('!@g', b'1'), ('@g == NULL', b'1'), ("@g < 'b'", b'1'),
                                  ('case(@g, 1, 2)', b'2'), ('upper(@g)', None), ("format('%s', @g)", b'(null)'),
                                  ('@g', None)):
            with self.subTest(expression=expression):
                reply = c.call(*base, 'APPLY', expression, 'AS', 'x', 'SORTBY', 2, '@g', 'ASC')
                self.assertEqual(reply[1], [b'g', None, b'k', b'1', b'x', value])
        for expression, error in (('@g < 1', 'Error converting string'), ('@g + 1', 'SEARCH_NUMERIC_VALUE_INVALID Invalid numeric value'),
                                  ('strlen(@g)', MISSING_VALUE + 'g')):
            with self.subTest(expression=expression):
                with self.assertRaisesRegex(ServerError, '^' + error + '$'):
                    c.call(*base, 'APPLY', expression, 'AS', 'x', 'SORTBY', 2, '@g', 'ASC')
        reply = c.call('FT.AGGREGATE', 'e', '*', 'LOAD', 1, '@g', 'APPLY', 'exists(@g)', 'AS', 'x', 'SORTBY', 2, '@x', 'ASC')
        self.assertEqual(reply[1], [b'x', b'0'])

    def test_expression_errors_point_at_the_last_token(self):
        _, c = self.server()
        build(c)
        cases = (('@n +', 3, 'n'), ('@n  +', 4, 'n'), ('1 +', 2, '1'), ('(@n +', 4, 'n'), ('@n + (', 5, 'n'),
                 ('abs(', 3, 'abs'), ('abs(@n', 4, 'n'), ("'x' +", 4, "'x'"), ('@n +)', 4, 'n'), ('@n ++', 4, 'n'),
                 ('!', 0, ''), ('@', 0, ''), ('@n @n', 3, 'n'), ('1 2', 2, '2'), (')', 0, ''), ('', 0, ''), ('  ', 0, ''),
                 ('@n<=', 2, 'n'), ('case(@n,', 7, 'n'), ('@n , 2', 3, 'n'), ('@n+1', 2, '+1'), ('upper(@t) +', 10, 't'))
        for expression, offset, near in cases:
            with self.subTest(expression=expression):
                expected = "SEARCH_EXPR Syntax error at offset %d near '%s'" % (offset, near)
                with self.assertRaises(ServerError) as error:
                    c.call('FT.AGGREGATE', 'e', '*', 'LOAD', 2, '@n', '@t', 'APPLY', expression, 'AS', 'x')
                self.assertEqual(str(error.exception), expected)

    def test_wildcard_with_inkeys_is_unscored(self):
        _, c = self.server()
        build(c)
        reply = c.call('FT.SEARCH', 'e', '*', 'NOCONTENT', 'WITHSCORES', 'INKEYS', 3, 'd:4', 'd:2', 'd:1', 'DIALECT', 2)
        self.assertEqual(reply, [3, b'd:1', b'0', b'd:2', b'0', b'd:4', b'0'])
        reply = c.call('FT.SEARCH', 'e', '*', 'NOCONTENT', 'WITHSCORES', 'SCORER', 'DOCSCORE', 'INKEYS', 2, 'd:2', 'd:1')
        self.assertEqual(reply, [2, b'd:1', b'1', b'd:2', b'1'])
        reply = c.call('FT.SEARCH', 'e', '*', 'NOCONTENT', 'WITHSCORES', 'EXPLAINSCORE', 'INKEYS', 1, 'd:2')
        self.assertEqual(reply[2], [b'0', ['Final BM25 : words BM25 0.00 * document score 1.00', ['Irrelevant token -> score is 0']]])
        reply = c.call('FT.SEARCH', 'e', 'fox', 'NOCONTENT', 'WITHSCORES', 'INKEYS', 2, 'd:3', 'd:1')
        self.assertTrue(all(float(score) > 0 for score in reply[2::2]))
        self.assertNotEqual(c.call('FT.SEARCH', 'e', '*', 'NOCONTENT', 'WITHSCORES')[2], b'0')

    def test_aggregate_counts_and_sort_window(self):
        _, c = self.server()
        build(c)
        for i in range(6, 13):
            c.call('HSET', 'd:%d' % i, 't', 'fox', 'g', 'z%d' % i, 'n', i)
        knn = ('FT.AGGREGATE', 'e', KNN)
        params = ('PARAMS', 2, 'q', QUERY, 'DIALECT', 2)
        for steps, resp2, resp3 in ((('LOAD', 1, '@d'), 1, 2), ((), 1, 2), (('LOAD', 3, '@d', 'AS', 'x'), 2, 2),
                                    (('LOAD', 1, '@__key'), 2, 2), (('LOAD', 1, '@t'), 2, 2)):
            with self.subTest(steps=steps):
                c.call('HELLO', 2)
                self.assertEqual(c.call(*knn, *steps, *params)[0], resp2)
                c.call('HELLO', 3)
                self.assertEqual(c.call(*knn, *steps, *params)['total_results'], resp3)
        c.call('HELLO', 2)
        self.assertEqual(c.call('FT.AGGREGATE', 'e', 'fox', 'ADDSCORES', 'LOAD', 1, '@__score')[0], 1)
        self.assertEqual(c.call('FT.AGGREGATE', 'e', '*', 'LIMIT', 2, 3)[0], 3)
        c.call('HELLO', 3)
        self.assertEqual(c.call('FT.AGGREGATE', 'e', '*', 'LIMIT', 2, 3)['total_results'], 5)
        c.call('HELLO', 2)
        grouped = ('FT.AGGREGATE', 'e', '*', 'GROUPBY', 1, '@g', 'REDUCE', 'COUNT', 0, 'AS', 'k', 'SORTBY', 2, '@g', 'ASC')
        reply = c.call(*grouped)
        self.assertEqual((reply[0], len(reply) - 1), (11, 10))
        self.assertEqual(len(c.call(*grouped, 'LIMIT', 0, 20)) - 1, 11)
        self.assertEqual(len(c.call(*grouped, 'MAX', 3)) - 1, 3)
        reply = c.call(*grouped, 'APPLY', '@k * 2', 'AS', 'twice')
        self.assertEqual((reply[0], len(reply) - 1), (11, 10))

    def test_hybrid_nosort_follows_limit(self):
        _, c = self.server()
        build(c)
        for i in range(6, 30):
            c.call('HSET', 'd:%d' % i, 't', 'fox ' * (i % 4 + 1), 'v', struct.pack('<ff', i, i % 7))
        base = ('FT.HYBRID', 'e', 'SEARCH', 'fox', 'VSIM', '@v', '$q')
        tail = ('PARAMS', 2, 'q', QUERY)
        sorted_page = pairs(c.call(*base, 'LIMIT', 0, 5, *tail))
        self.assertEqual(pairs(c.call(*base, 'NOSORT', 'LIMIT', 0, 5, *tail))['results'], sorted_page['results'])
        everything = c.call(*base, 'NOSORT', *tail)
        fused = pairs(everything)['total_results']
        self.assertGreater(fused, 10)
        self.assertEqual(len(pairs(everything)['results']), fused)
        self.assertEqual(sorted(hybrid_keys(everything)), sorted(hybrid_keys(c.call(*base, 'LIMIT', 0, 100, *tail))))
        self.assertEqual(len(pairs(c.call(*base, *tail))['results']), 10)

    def test_dialect_four_counts_and_order(self):
        _, c = self.server()
        build(c)
        for query, extra, expected in (
                ('@g:{a|b}', ('NOCONTENT',), (1, [b'd:1', b'd:2', b'd:4'])),
                ('@g:{a|b}', ('NOCONTENT', 'LIMIT', 0, 0), (0, [])),
                ('@g:{a|b}', ('RETURN', 1, 't', 'LIMIT', 0, 2), (2, [b'd:1', b'd:2'])),
                ('@g:{a|b}', ('RETURN', 1, 'n', 'LIMIT', 0, 2), (1, [b'd:1', b'd:2'])),
                ('*', ('NOCONTENT', 'LIMIT', 1, 2), (1, [b'd:2', b'd:3'])),
                ('@n:[2 5]', ('RETURN', 1, 't'), (4, [b'd:2', b'd:3', b'd:4', b'd:5'])),
                ('@n:[2 5]', ('RETURN', 1, 'n'), (1, [b'd:2', b'd:3', b'd:4', b'd:5'])),
                ('fox', ('NOCONTENT', 'LIMIT', 0, 2), (2, None)),
                ('@g:{a|b}', ('NOCONTENT', 'WITHCOUNT'), (3, None)),
                ('*', ('NOCONTENT', 'SORTBY', 'n', 'DESC', 'LIMIT', 0, 2), (2, [b'd:5', b'd:4'])),
                (KNN, ('NOCONTENT', 'LIMIT', 0, 1, 'PARAMS', 2, 'q', QUERY), (1, None))):
            with self.subTest(query=query, extra=extra):
                reply = c.call('FT.SEARCH', 'e', query, *extra, 'DIALECT', 4)
                self.assertEqual(total(reply), expected[0])
                if expected[1] is not None:
                    self.assertEqual(keys(reply), expected[1])
        self.assertEqual(c.call('FT.SEARCH', 'e', '@g:{a|b}', 'NOCONTENT', 'DIALECT', 2)[0], 3)
        c.call('HELLO', 3)
        self.assertEqual(c.call('FT.SEARCH', 'e', '@g:{a|b}', 'NOCONTENT', 'LIMIT', 0, 2, 'DIALECT', 4)['total_results'], 2)
        c.call('HELLO', 2)
        reply = c.call('FT.SEARCH', 'e', 'fox', 'NOCONTENT', 'WITHSCORES', 'LIMIT', 0, 3, 'DIALECT', 4)
        self.assertEqual(reply[1::2], c.call('FT.SEARCH', 'e', 'fox', 'NOCONTENT', 'WITHSCORES', 'LIMIT', 0, 3, 'DIALECT', 2)[1::2])

    def test_info_statistics(self):
        _, c = self.server()
        self.assertEqual(c.call('FT.CREATE', 't1', 'PREFIX', 1, 'a:', 'SCHEMA', 't', 'TEXT'), 'OK')
        self.assertEqual(c.call('FT.CREATE', 't2', 'PREFIX', 1, 'b:', 'SCHEMA', 'g', 'TAG'), 'OK')
        c.call('HSET', 'a:1', 't', 'hello world hello')
        c.call('HSET', 'a:2', 't', 'one two three four')
        c.call('HSET', 'a:3', 't', 'five')
        c.call('HSET', 'b:1', 'g', 'x,y')
        figures = info(c, 't1')
        self.assertEqual(figures['records_per_doc_avg'], b'2.3333332538604736')
        self.assertEqual(figures['offsets_per_term_avg'], b'1.1428571939468384')
        self.assertNotEqual(figures['offset_bits_per_record_avg'], b'nan')
        tags = info(c, 't2')
        self.assertEqual((tags['offsets_per_term_avg'], tags['offset_bits_per_record_avg']), (b'0', b'nan'))
        self.assertEqual(pairs(info(c, 't1')['dialect_stats']), {'dialect_1': 0, 'dialect_2': 0, 'dialect_3': 0, 'dialect_4': 0})
        c.call('FT.SEARCH', 't1', 'hello')
        c.call('FT.SEARCH', 't1', 'hello', 'DIALECT', 2)
        c.call('FT.SEARCH', 't1', 'hello', 'DIALECT', 2)
        c.call('FT.EXPLAIN', 't1', 'hello', 'DIALECT', 4)
        with self.assertRaises(ServerError):
            c.call('FT.SEARCH', 't1', '(', 'DIALECT', 4)
        c.call('FT.PROFILE', 't1', 'AGGREGATE', 'QUERY', 'hello', 'DIALECT', 3)
        self.assertEqual(pairs(info(c, 't1')['dialect_stats']), {'dialect_1': 1, 'dialect_2': 1, 'dialect_3': 1, 'dialect_4': 0})
        self.assertEqual(pairs(info(c, 't2')['dialect_stats'])['dialect_1'], 0)

    def test_command_docs_place_the_module_after_complexity(self):
        _, c = self.server()
        for name in ('FT.SEARCH', 'FT.CREATE', 'FT.INFO'):
            with self.subTest(name=name):
                fields = list(pairs(c.call('COMMAND', 'DOCS', name)[1]))
                self.assertEqual(fields[fields.index(b'complexity') + 1], b'module')
        fields = list(pairs(c.call('COMMAND', 'DOCS', 'JSON.GET')[1]))
        self.assertEqual(fields[fields.index(b'complexity') + 1], b'module')

    def test_scoped_counts_and_statistics_hide_other_scopes(self):
        for mode in ('labels', 'owners'):
            with self.subTest(mode=mode):
                _, a = self.server(mode)
                server, b = self.server(mode)
                low = sl.at(mode, sl.MODES[mode]['low'], 'u1' if sl.MODES[mode]['owners'] else None)
                other = sl.at(mode, sl.MODES[mode]['top'], 'u2' if sl.MODES[mode]['owners'] else None)
                shared = sl.at(mode, sl.MODES[mode]['low']) if sl.MODES[mode]['owners'] else low
                for c in (a, b):
                    build(c, scope=shared)
                for i in range(6, 9):
                    b.call(*other, 'HSET', 'd:%d' % i, 't', 'fox', 'g', 'a', 'n', i, 'v', struct.pack('<ff', i, 0))
                b.call(*other, 'FT.SEARCH', 'e', 'fox', 'DIALECT', 4)
                requests = (
                    ('FT.SEARCH', 'e', '@g:{a}', 'NOCONTENT', 'DIALECT', 4),
                    ('FT.SEARCH', 'e', 'fox', 'NOCONTENT', 'LIMIT', 0, 2, 'DIALECT', 4),
                    ('FT.SEARCH', 'e', '*', 'NOCONTENT', 'WITHSCORES', 'INKEYS', 2, 'd:1', 'd:7'),
                    ('FT.AGGREGATE', 'e', '*', 'LIMIT', 1, 2),
                    ('FT.AGGREGATE', 'e', KNN, 'LOAD', 1, '@d', 'PARAMS', 2, 'q', QUERY, 'DIALECT', 2),
                    ('FT.AGGREGATE', 'e', '*', 'GROUPBY', 1, '@g', 'SORTBY', 2, '@g', 'ASC'),
                    ('FT.HYBRID', 'e', 'SEARCH', 'fox', 'VSIM', '@v', '$q', 'NOSORT', 'PARAMS', 2, 'q', QUERY),
                )
                for request in requests:
                    for protocol in (2, 3):
                        a.call('HELLO', protocol)
                        b.call('HELLO', protocol)
                        reply_a, reply_b = a.call(*low, *request), b.call(*low, *request)
                        if request[0] == 'FT.HYBRID':
                            reply_a, reply_b = pairs(reply_a), pairs(reply_b)
                            del reply_a['execution_time'], reply_b['execution_time']
                        self.assertEqual(reply_a, reply_b, request)
                a.call('HELLO', 2)
                b.call('HELLO', 2)
                rights = ['on', 'nopass', '~*', '&*', '+@all']
                rights += ['owners:*', 'owner-shared'] if sl.MODES[mode]['owners'] else []
                rights += ['clearance:*', 'trust:*'] if sl.MODES[mode]['labelled'] else []
                b.call(*sl.top(mode), 'ACL', 'SETUSER', 'app', *rights)
                app = server.client('app')
                self.addCleanup(app.close)
                self.assertEqual(pairs(info(app, 'e', low)['dialect_stats']), {'dialect_1': 0, 'dialect_2': 0, 'dialect_3': 0, 'dialect_4': 0})
                self.assertEqual(pairs(info(b, 'e', sl.top(mode))['dialect_stats'])['dialect_4'], 1)

    def test_pinned_reference_replies(self):
        if REFERENCE is None:
            self.skipTest('reference port was not supplied')
        ref = Client(REFERENCE)
        self.addCleanup(ref.close)
        ref.call('FLUSHALL')
        self.addCleanup(ref.call, 'FLUSHALL')
        _, eski = self.server()
        for c in (ref, eski):
            try:
                c.call('FT.DROPINDEX', 'e')
            except ServerError:
                pass
            build(c)
        params = ('PARAMS', 2, 'q', QUERY, 'DIALECT', 2)
        requests = [
            ('FT.HYBRID', 'e', 'SEARCH', 'fox', 'VSIM', '@v', '$q', 'FILTER', '@zz:{a}', 'PARAMS', 2, 'q', QUERY),
            ('FT.AGGREGATE', 'e', '*', 'GROUPBY', 1, '@g', 'REDUCE', 'COUNT', 0, 'AS', 'k',
             'FILTER', "(@g == 'a' && @k > 0) || (@g == 'b' && @k > 0)", 'SORTBY', 2, '@g', 'ASC'),
            ('FT.AGGREGATE', 'e', KNN, 'LOAD', 1, '@d') + params,
            ('FT.AGGREGATE', 'e', '*', 'LOAD', 1, '@n', 'SORTBY', 2, '@n', 'ASC', 'LIMIT', 0, 3),
            ('FT.AGGREGATE', 'e', '*', 'LOAD', 2, '@n', '@t', 'APPLY', '@n +', 'AS', 'x'),
            ('FT.SEARCH', 'e', '*', 'NOCONTENT', 'WITHSCORES', 'INKEYS', 3, 'd:4', 'd:2', 'd:1', 'DIALECT', 2),
            ('FT.SEARCH', 'e', '@g:{a|b}', 'NOCONTENT', 'DIALECT', 4),
            ('FT.SEARCH', 'e', '@g:{a|b}', 'RETURN', 1, 'n', 'LIMIT', 0, 2, 'DIALECT', 4),
            ('FT.SEARCH', 'e', '@g:{a|b}', 'RETURN', 1, 't', 'LIMIT', 0, 2, 'DIALECT', 4),
            ('FT.SEARCH', 'e', '@n:[2 5]', 'NOCONTENT', 'DIALECT', 4),
            ('FT.AGGREGATE', 'e', '*', 'LIMIT', 2, 2),
            ('FT.AGGREGATE', 'e', '*', 'GROUPBY', 1, '@g', 'REDUCE', 'COUNT', 0, 'AS', 'k', 'FILTER', "@g != 'a'",
             'SORTBY', 2, '@g', 'ASC'),
            ('FT.SEARCH', 'e', 'fox', 'NOCONTENT', 'LIMIT', 0, 2, 'DIALECT', 4),
        ]
        for protocol in (2, 3):
            for c in (ref, eski):
                c.call('HELLO', protocol)
            for request in requests:
                with self.subTest(protocol=protocol, request=request[:3]):
                    try:
                        expected = ref.call(*request)
                    except ServerError as error:
                        expected = error
                    try:
                        actual = eski.call(*request)
                    except ServerError as error:
                        actual = error
                    if isinstance(expected, ServerError):
                        self.assertEqual(str(actual), str(expected))
                        continue
                    if request[0] == 'FT.HYBRID':
                        expected, actual = pairs(expected), pairs(actual)
                        del expected['execution_time'], actual['execution_time']
                    self.assertEqual(actual, expected)


def main():
    global BINARY, THREADS, REFERENCE
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--ports', default=os.getenv('ESKI_SEARCH_PORTS', ''))
    parser.add_argument('--reference-port', type=int)
    args, tests = parser.parse_known_args()
    BINARY, THREADS, REFERENCE = args.server.resolve(), args.keyspace_threads, args.reference_port
    if args.ports:
        sl.use_ports(args.ports)
    unittest.main(argv=[sys.argv[0]] + tests, verbosity=2)


if __name__ == '__main__':
    main()
