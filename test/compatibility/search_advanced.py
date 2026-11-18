import argparse
import json
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
MISSING = 'SEARCH_INDEX_NOT_FOUND Index not found: '
DENIED = 'NOPERM User does not have the required permissions to query the index'
QUERY_VECTOR = struct.pack('<ff', 0, 0)
SCORERS = ('BM25STD', 'BM25', 'BM25STD.NORM', 'BM25STD.TANH', 'TFIDF', 'TFIDF.DOCNORM',
           'DISMAX', 'DOCSCORE', 'HAMMING')


def pairs(value):
    return value if isinstance(value, dict) else dict(zip(value[::2], value[1::2]))


def profile(value):
    return pairs(value['Profile'] if isinstance(value, dict) else value[1])


def sample(c, scope=(), name='catalog', prefix='doc:'):
    return c.call(*scope, 'FT.CREATE', name, 'PREFIX', 1, prefix, 'SCORE_FIELD', 'rank',
                  'PAYLOAD_FIELD', 'payload', 'STOPWORDS', 0, 'SCHEMA',
                  'body', 'AS', 'text', 'TEXT', 'NOSTEM', 'WITHSUFFIXTRIE',
                  'other', 'TEXT', 'NOSTEM', 'tag', 'TAG', 'WITHSUFFIXTRIE',
                  'loc', 'GEO', 'price', 'NUMERIC',
                  'vec', 'VECTOR', 'FLAT', 6, 'TYPE', 'FLOAT32', 'DIM', 2, 'DISTANCE_METRIC', 'L2')


def docs(c, scope=(), prefix='doc:', hidden=False):
    rows = [('a', 'fox fox dog', ' Farm, BLUE ', '0,0', 1, 0.8, b'\x00'),
            ('b', 'wolf bear fox', 'wild, BLUE', '0 1', 2, 0.4, b'\x01'),
            ('c', 'wolf bear', ' wilderness ', '0,30', 3, 0.6, b'\x03')]
    for key, text, tag, point, n, rank, payload in rows:
        c.call(*scope, 'HSET', prefix + key, 'body', text, 'other', 'fox',
               'tag', tag if not hidden else 'classified', 'loc', point, 'price', n,
               'rank', rank, 'payload', payload, 'vec', struct.pack('<ff', n-1, 0))


def hybrid(c, scorer, *extra):
    return c.call('FT.HYBRID', 'catalog', 'SEARCH', '@text:fox', 'SCORER', scorer,
                  'YIELD_SCORE_AS', 'lexical', 'VSIM', '@vec', '$v', 'YIELD_SCORE_AS', 'vector',
                  'COMBINE', 'LINEAR', 4, 'ALPHA', '0.4', 'BETA', '0.6', *extra,
                  'PARAMS', 2, 'v', QUERY_VECTOR)


class SearchAdvanced(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='eski-search-advanced-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.n = 0

    def server(self, mode='', extra=()):
        directory = self.root / str(self.n)
        self.n += 1
        directory.mkdir()
        server = sl.Server(BINARY, directory, mode, extra, THREADS)
        self.addCleanup(self.stop, server)
        return server, self.up(server)

    def up(self, server):
        c = server.up()
        self.addCleanup(c.close)
        print('Eski PID', server.run.process.pid, 'port', server.run.port, flush=True)
        return c

    def stop(self, server):
        if server.run.process is not None:
            code = server.stop()
            out = server.run.log()
            self.assertEqual(code, 0, out)
            self.assertNotIn('AddressSanitizer', out)

    def reference(self):
        if REFERENCE is None:
            self.skipTest('reference port was not supplied')
        c = Client(REFERENCE)
        self.addCleanup(c.close)
        c.call('FLUSHALL')
        self.addCleanup(c.call, 'FLUSHALL')
        return c

    def test_scorers_explanations_and_payloads(self):
        _, c = self.server()
        self.assertEqual(sample(c), 'OK')
        docs(c)
        summaries = {}
        for scorer in SCORERS:
            with self.subTest(scorer=scorer):
                result = c.call('FT.SEARCH', 'catalog', '@text:fox', 'WITHSCORES', 'EXPLAINSCORE',
                                'SCORER', scorer, 'PAYLOAD', b'\x00', 'WITHPAYLOADS', 'NOCONTENT')
                self.assertEqual(result[0], 2)
                self.assertEqual(result[1], b'doc:a')
                self.assertEqual(result[3], b'\x00')
                summaries[scorer] = float(result[2][0])
                self.assertTrue(result[2][1])
        self.assertAlmostEqual(summaries['DOCSCORE'], 0.8, places=6)
        self.assertEqual(summaries['DISMAX'], 3)
        self.assertEqual(summaries['BM25STD.NORM'], 1)
        self.assertEqual(summaries['HAMMING'], 1)
        self.assertNotEqual(summaries['BM25STD'], summaries['TFIDF'])
        self.assertNotEqual(summaries['TFIDF'], summaries['TFIDF.DOCNORM'])
        c.call('HELLO', 3)
        response = c.call('FT.SEARCH', 'catalog', '@text:fox', 'WITHSCORES', 'EXPLAINSCORE',
                          'WITHPAYLOADS', 'SCORER', 'TFIDF', 'RETURN', 1, 'text')['results'][0]
        self.assertIsInstance(response['score'][0], float)
        self.assertTrue(response['score'][1][1][0].startswith('(TFIDF '))
        self.assertEqual(response['payload'], b'\x00')
        agg = c.call('FT.AGGREGATE', 'catalog', '@text:fox', 'SCORER', 'TFIDF', 'ADDSCORES',
                     'LOAD', 1, '@__key', 'SORTBY', 2, '@__score', 'DESC')
        rows = agg['results']
        self.assertEqual(rows[0]['extra_attributes'][b'__key'], b'doc:a')
        self.assertAlmostEqual(float(rows[0]['extra_attributes'][b'__score']), summaries['TFIDF'])
        result = hybrid(c, 'TFIDF', 'EXPLAINSCORE')
        first = result['results'][0]
        self.assertAlmostEqual(float(first[b'lexical']), summaries['TFIDF'])
        self.assertAlmostEqual(float(first[b'__score']), 0.4 * summaries['TFIDF'] + 0.6)
        self.assertIn('Final TFIDF', str(first['score']))
        self.assertIn('LINEAR', str(first['score']).upper())

    def test_legacy_scorer_groups_positions_in_filtered_unions(self):
        _, c = self.server()
        clients = (('Eski', c), ('Redis', self.reference())) if REFERENCE else (('Eski', c),)
        for engine, c in clients:
            for storage in ('HASH', 'JSON'):
                with self.subTest(engine=engine, storage=storage):
                    prefix = storage.lower() + ':'
                    fields = ('body', 'TEXT', 'NOSTEM', 'tag', 'TAG') if storage == 'HASH' else (
                        '$.body', 'AS', 'body', 'TEXT', 'NOSTEM', '$.tag', 'AS', 'tag', 'TAG')
                    self.assertEqual(c.call('FT.CREATE', prefix, 'ON', storage, 'PREFIX', 1, prefix,
                                            'SCHEMA', *fields), 'OK')
                    for name, body, tag in [('a', 'alpha filler spacer beta', 'news'), ('b', 'alpha beta', 'news'),
                                            ('c', 'beta', 'news'), ('d', 'fox', 'other')]:
                        if storage == 'HASH':
                            c.call('HSET', prefix + name, 'body', body, 'tag', tag)
                        else:
                            c.call('JSON.SET', prefix + name, '$', json.dumps({'body': body, 'tag': tag}))
                    for protocol in (2, 3):
                        c.call('HELLO', protocol)
                        for query, expected in (
                                ('@body:(alpha|beta) @tag:{news}', [('a', 3), ('b', 3), ('c', 2)]),
                                ('@body:(alpha|beta) -@tag:{other}', [('a', 2), ('b', 2), ('c', 1)]),
                                ('@body:alpha @body:beta @tag:{news}', [('b', 3), ('a', 1)])):
                            for explain in ((), ('EXPLAINSCORE',)):
                                result = c.call('FT.SEARCH', prefix, query, 'SCORER', 'TFIDF', 'DIALECT', 2,
                                                'WITHSCORES', 'NOCONTENT', *explain)
                                if protocol == 2:
                                    rows = zip(result[1::2], result[2::2], strict=True)
                                else:
                                    rows = ((row['id'], row['score']) for row in result['results'])
                                observed = [(key.decode().removeprefix(prefix), float(score[0] if explain else score))
                                            for key, score in rows]
                                self.assertEqual(observed, expected)

    def test_fuzzy_suffix_infix_geo_and_snippets(self):
        _, c = self.server()
        sample(c)
        docs(c)
        checks = (
            ('@text:%foz%', {b'doc:a', b'doc:b'}), ('@text:%%fx%%', {b'doc:a', b'doc:b'}),
            ('@text:%%%xof%%%', {b'doc:a', b'doc:b', b'doc:c'}), ('@text:*ox', {b'doc:a', b'doc:b'}),
            ('@text:*o*l*', set()), ('@text:*ol*', {b'doc:b', b'doc:c'}),
            ("@text:w'f?x'", {b'doc:a', b'doc:b'}), ('@tag:{*rness}', {b'doc:c'}),
            ('@tag:{*ild*}', {b'doc:b', b'doc:c'}), ('@tag:{bl*}', {b'doc:a', b'doc:b'}),
            ('@loc:[0 0 150 km]', {b'doc:a', b'doc:b'}), ('@loc:[0 0 20 mi]', {b'doc:a'}),
        )
        for query, expected in checks:
            with self.subTest(query=query):
                r = c.call('FT.SEARCH', 'catalog', query, 'DIALECT', 2, 'NOCONTENT')
                self.assertEqual(set(r[1:]), expected)
                self.assertEqual(r[0], len(expected))
        with self.assertRaisesRegex(ServerError, 'WITHSUFFIXTRIE'):
            c.call('FT.SEARCH', 'catalog', '@other:*ox', 'DIALECT', 2)
        self.assertEqual(c.call('FT.SEARCH', 'catalog', '*', 'NOCONTENT',
                                'GEOFILTER', 'loc', 0, 0, 10, 'km'), [1, b'doc:a'])
        self.assertEqual(c.call('FT.SEARCH', 'catalog', '*', 'NOCONTENT',
                                'FILTER', 'price', 2, '(3'), [1, b'doc:b'])
        c.call('HSET', 'doc:fragment', 'body', 'zero one two fox four five six seven fox ten eleven')
        start = ('FT.SEARCH', 'catalog', '@text:fox', 'INKEYS', 1, 'doc:fragment')
        r = c.call(*start, 'RETURN', 3, 'text', 'AS', 'article', 'HIGHLIGHT', 'FIELDS', 1, 'text', 'TAGS', '[', ']')
        self.assertEqual(r[-1], [b'article', b'zero one two fox four five six seven fox ten eleven'])
        r = c.call(*start, 'RETURN', 1, 'text', 'HIGHLIGHT', 'FIELDS', 1, 'text', 'TAGS', '[', ']')
        self.assertEqual(r[-1], [b'text', b'zero one two [fox] four five six seven [fox] ten eleven'])
        r = c.call(*start, 'RETURN', 1, 'text', 'SUMMARIZE', 'FIELDS', 1, 'text', 'LEN', 3)
        self.assertEqual(r[-1], [b'text', b'fox four five six seven fox... '])
        c.call('HDEL', 'doc:a', 'loc')
        self.assertEqual(c.call('FT.SEARCH', 'catalog', '@loc:[0 0 10 km]', 'NOCONTENT'), [0])

    def test_alter_atomic_scan_and_alias_lifecycle(self):
        _, c = self.server()
        self.assertEqual(c.call('FT.CREATE', 'one', 'PREFIX', 1, 'one:', 'SCHEMA', 'text', 'TEXT'), 'OK')
        self.assertEqual(c.call('FT.CREATE', 'two', 'PREFIX', 1, 'two:', 'SCHEMA', 'text', 'TEXT'), 'OK')
        c.call('HSET', 'one:a', 'text', 'fox', 'label', 'blue', 'place', '0,0')
        c.call('HSET', 'two:a', 'text', 'fox')
        self.assertEqual(c.call('FT.ALIASUPDATE', 'view', 'one'), 'OK')
        self.assertEqual(c.call('FT.SEARCH', 'view', '*', 'NOCONTENT'), [1, b'one:a'])
        with self.assertRaisesRegex(ServerError, 'Duplicate field'):
            c.call('FT.ALTER', 'view', 'SCHEMA', 'ADD', 'label', 'TAG', 'text', 'NUMERIC')
        with self.assertRaisesRegex(ServerError, 'No such field'):
            c.call('FT.TAGVALS', 'one', 'label')
        self.assertEqual(c.call('FT.ALTER', 'view', 'SCHEMA', 'ADD', 'label', 'TAG'), 'OK')
        self.assertEqual(c.call('FT.TAGVALS', 'view', 'label'), [b'blue'])
        self.assertEqual(c.call('FT.ALTER', 'one', 'SKIPINITIALSCAN', 'SCHEMA', 'ADD', 'place', 'GEO'), 'OK')
        self.assertEqual(c.call('FT.SEARCH', 'view', '@place:[0 0 5 km]', 'NOCONTENT'), [0])
        c.call('HSET', 'one:a', 'place', '0,0', 'changed', 'yes')
        self.assertEqual(c.call('FT.SEARCH', 'view', '@place:[0 0 5 km]', 'NOCONTENT'), [1, b'one:a'])
        with self.assertRaisesRegex(ServerError, 'Alias already exists'):
            c.call('FT.ALIASADD', 'view', 'two')
        self.assertEqual(c.call('FT.ALIASUPDATE', 'view', 'two'), 'OK')
        self.assertEqual(c.call('FT.SEARCH', 'view', '*', 'NOCONTENT'), [1, b'two:a'])
        self.assertEqual(c.call('FT._LIST'), ['one', 'two'])
        self.assertEqual(c.call('FT.DROPINDEX', 'one'), 'OK')
        self.assertEqual(c.call('FT.DROPINDEX', 'view'), 'OK')
        with self.assertRaisesRegex(ServerError, '^Alias does not exist$'):
            c.call('FT.ALIASDEL', 'view')

    def test_explain_profile_and_config_protocols(self):
        _, c = self.server()
        sample(c)
        docs(c)
        for proto in (2, 3):
            c.call('HELLO', proto)
            with self.subTest(protocol=proto):
                self.assertEqual(c.call('FT.EXPLAIN', 'catalog', '@text:fox'), b'@text:fox\n')
                self.assertEqual(c.call('FT.EXPLAINCLI', 'catalog', '@text:fox'), ['@text:fox', ''])
                original = c.call('FT.SEARCH', 'catalog', '@text:fox', 'NOCONTENT')
                profiled = c.call('FT.PROFILE', 'catalog', 'SEARCH', 'LIMITED', 'QUERY', '@text:fox', 'NOCONTENT')
                self.assertEqual(profiled['Results'] if proto == 3 else profiled[0], original)
                data = pairs(profile(profiled)['Shards'][0])
                self.assertEqual(pairs(data['Iterators profile'])['Term'], b'fox')
                self.assertEqual([pairs(x)['Type'] for x in data['Result processors profile']],
                                 ['Index', 'Scorer', 'Sorter'])
                profiled = c.call('FT.PROFILE', 'catalog', 'AGGREGATE', 'QUERY', '*', 'LOAD', 1, '@tag')
                self.assertIn('Threadsafe-Loader', str(profile(profiled)))
                hybrid_profile = c.call('FT.PROFILE', 'catalog', 'HYBRID', 'QUERY', 'SEARCH', 'fox',
                                        'VSIM', '@vec', '$v', 'PARAMS', 2, 'v', QUERY_VECTOR)
                inner = pairs(hybrid_profile['Profile'] if proto == 3 else hybrid_profile[-1])
                self.assertEqual(set(pairs(inner['Shards'][0])), {'SEARCH', 'VSIM'})
                self.assertEqual(c.call('FT.CONFIG', 'GET', 'default_dialect'),
                                 {'DEFAULT_DIALECT': b'1'} if proto == 3 else [['DEFAULT_DIALECT', b'1']])
                self.assertEqual(c.call('FT.CONFIG', 'GET', 'unknown'), {} if proto == 3 else [])
        c.call('HELLO', 2)
        self.assertEqual(c.call('FT.CONFIG', 'SET', 'DEFAULT_SCORER', 'DISMAX'), 'OK')
        self.assertEqual(c.call('FT.SEARCH', 'catalog', '@text:fox', 'WITHSCORES', 'NOCONTENT')[2], b'3')
        self.assertEqual(c.call('FT.CONFIG', 'SET', 'MINPREFIX', 4), 'OK')
        self.assertEqual(c.call('FT.SEARCH', 'catalog', '@text:fo*', 'NOCONTENT'), [0])
        self.assertEqual(c.call('FT.CONFIG', 'SET', 'MAXSEARCHRESULTS', 1), 'OK')
        with self.assertRaisesRegex(ServerError, 'LIMIT exceeds maximum of 1'):
            c.call('FT.SEARCH', 'catalog', '*', 'LIMIT', 0, 2)
        with self.assertRaisesRegex(ServerError, 'higher than 4'):
            c.call('FT.CONFIG', 'SET', 'DEFAULT_DIALECT', 9)

    def test_scoped_aliases_shadows_acl_tag_values_and_profiles(self):
        _, a = self.server('both')
        server, b = self.server('both')
        shared = sl.at('both', 'U')
        alice = sl.at('both', 'C', 'alice')
        bob = sl.at('both', 'S', 'bob')
        top = sl.top('both')
        sample(b, bob, 'private', 'sec:')
        docs(b, bob, 'sec:', hidden=True)
        b.call(*bob, 'FT.ALIASADD', 'view', 'private')
        b.call(*bob, 'FT.ALIASADD', 'secret', 'private')
        for c in (a, b):
            sample(c, shared, 'public')
            c.call(*alice, 'HSET', 'doc:b', 'body', 'shadow', 'tag', 'local', 'loc', '20,20')
            docs(c, shared)
            c.call(*shared, 'FT.ALIASADD', 'view', 'public')
            with self.assertRaisesRegex(ServerError, 'Alias already exists'):
                c.call(*alice, 'FT.ALIASADD', 'view', 'public')
        for cmd in (('FT.SEARCH', 'secret', '*'), ('FT.EXPLAIN', 'secret', '*'),
                    ('FT.TAGVALS', 'secret', 'tag'), ('FT.PROFILE', 'secret', 'SEARCH', 'QUERY', '*'),
                    ('FT.ALTER', 'secret', 'SCHEMA', 'ADD', 'x', 'TAG')):
            for c in (a, b):
                with self.assertRaisesRegex(ServerError, '^' + MISSING + 'secret$'):
                    c.call(*alice, *cmd)
        for cmd in (('FT.TAGVALS', 'view', 'tag'), ('FT.SEARCH', 'view', '*', 'NOCONTENT'),
                    ('FT.PROFILE', 'view', 'SEARCH', 'QUERY', 'fox', 'NOCONTENT')):
            self.assertEqual(a.call(*alice, *cmd), b.call(*alice, *cmd))
        self.assertEqual(b.call(*alice, 'FT.TAGVALS', 'view', 'tag'), [b'blue', b'farm', b'local', b'wilderness'])
        self.assertEqual(b.call(*bob, 'FT.TAGVALS', 'view', 'tag'), [b'classified'])
        with self.assertRaisesRegex(ServerError, 'requires the top scope'):
            b.call(*alice, 'FT.CONFIG', 'SET', 'TIMEOUT', 1)
        b.call(*top, 'ACL', 'SETUSER', 'blind', 'on', 'nopass', '+@all', '~sec:*',
               'clearance:*', 'trust:*', 'owners:*', 'owner-shared')
        blind = server.client('blind')
        self.addCleanup(blind.close)
        for cmd in (('FT.SEARCH', 'view', '*'), ('FT.EXPLAIN', 'view', '*'),
                    ('FT.TAGVALS', 'view', 'tag'), ('FT.PROFILE', 'view', 'AGGREGATE', 'QUERY', '*')):
            with self.assertRaisesRegex(ServerError, '^' + DENIED + '$'):
                blind.call(*alice, *cmd)
        self.assertEqual(b.call(*bob, 'FLUSHDB'), 'OK')
        with self.assertRaisesRegex(ServerError, '^' + MISSING + 'secret$'):
            b.call(*bob, 'FT.INFO', 'secret')
        self.assertEqual(b.call(*alice, 'FT.TAGVALS', 'view', 'tag'), a.call(*alice, 'FT.TAGVALS', 'view', 'tag'))
        sample(b, bob, 'private', 'sec:')
        b.call(*bob, 'FT.ALIASADD', 'secret', 'private')
        b.call(*top, 'OWNERS', 'FORGET', 'bob')
        with self.assertRaisesRegex(ServerError, '^' + MISSING + 'secret$'):
            b.call(*bob, 'FT.INFO', 'secret')

    def test_definitions_and_aliases_survive_restart_and_rewrite(self):
        for mode, extra in (('', ('--appendonly', 'no', '--save', '')),
                            ('', sl.LOG + ('--aof-use-rdb-preamble', 'no')),
                            ('both', ('--enable-debug-command', 'yes'))):
            with self.subTest(mode=mode, flags=extra):
                server, c = self.server(mode, extra)
                scope = sl.at(mode, 'C', 'alice') if mode else ()
                admin = sl.top(mode) if mode else ()
                self.assertEqual(sample(c, scope, 'one', 'do:'), 'OK')
                self.assertEqual(sample(c, scope, 'two', 'doc:'), 'OK')
                if mode:
                    shared = sl.at(mode, 'U')
                    self.assertEqual(sample(c, shared, 'two', 'shared:'), 'OK')
                    c.call(*shared, 'HSET', 'shared:a', 'body', 'fox', 'tag', 'public')
                    self.assertEqual(c.call(*shared, 'FT.ALIASADD', 'shared-view', 'two'), 'OK')
                self.assertEqual(c.call(*scope, 'FT.ALIASADD', 'view', 'one'), 'OK')
                docs(c, scope)
                self.assertEqual(c.call(*scope, 'HSET', 'doc:a', 'status', 'READY'), 1)
                self.assertEqual(c.call(*scope, 'FT.ALTER', 'two', 'SCHEMA', 'ADD', 'status', 'TAG'), 'OK')
                self.assertEqual(c.call(*scope, 'FT.ALIASUPDATE', 'view', 'two'), 'OK')
                if extra[:2] == ('--appendonly', 'no'):
                    self.assertEqual(c.call('SAVE'), 'OK')
                else:
                    self.stop(server)
                    c = self.up(server)
                    self.assertEqual(c.call(*scope, 'FT.TAGVALS', 'view', 'status'), [b'ready'])
                    before = sl.rewrites(c, mode)
                    self.assertIn('rewrit', c.call(*admin, 'BGREWRITEAOF'))
                    sl.wait_rewritten(c, mode, before)
                self.stop(server)
                c = self.up(server)
                self.assertEqual(c.call(*scope, 'FT.TAGVALS', 'view', 'status'), [b'ready'])
                self.assertEqual(c.call(*scope, 'FT.SEARCH', 'view', '@loc:[0 0 20 mi]', 'NOCONTENT'), [1, b'doc:a'])
                self.assertEqual(c.call(*scope, 'FT.SEARCH', 'view', '@text:*ox', 'NOCONTENT')[0], 2)
                if mode:
                    self.assertEqual(c.call(*scope, 'FT.SEARCH', 'shared-view', '*', 'NOCONTENT'), [1, b'shared:a'])
                self.assertEqual(c.call(*scope, 'FT.DROPINDEX', 'two'), 'OK')
                if mode:
                    self.assertEqual(c.call(*scope, 'FT.SEARCH', 'shared-view', '*', 'NOCONTENT'), [1, b'shared:a'])
                with self.assertRaisesRegex(ServerError, '^' + MISSING + 'view$'):
                    c.call(*scope, 'FT.INFO', 'view')

    def test_pinned_reference_replies_and_errors(self):
        ref = self.reference()
        _, eski = self.server()
        for c in (ref, eski):
            c.call('FT.CONFIG', 'SET', 'DEFAULT_DIALECT', 1)
            sample(c)
            docs(c)
        for proto in (2, 3):
            for c in (ref, eski):
                c.call('HELLO', proto)
            examples = [
                ('FT.SEARCH', 'catalog', '@text:%foz%', 'DIALECT', 2, 'NOCONTENT'),
                ('FT.SEARCH', 'catalog', '@text:*ox', 'DIALECT', 2, 'NOCONTENT'),
                ('FT.SEARCH', 'catalog', '@loc:[0 0 150 km]', 'NOCONTENT'),
                ('FT.SEARCH', 'catalog', '@text:fox', 'INKEYS', 1, 'doc:a', 'RETURN', 1, 'text',
                 'HIGHLIGHT', 'FIELDS', 1, 'text'),
                ('FT.EXPLAIN', 'catalog', '@text:fox'),
                ('FT.EXPLAINCLI', 'catalog', '@loc:[0 0 150 km]'),
                ('FT.TAGVALS', 'catalog', 'tag'),
                ('FT.CONFIG', 'HELP', 'TIMEOUT'),
            ]
            examples.extend(('FT.SEARCH', 'catalog', '@text:fox', 'NOCONTENT', 'LIMIT', 0, 1,
                             'SCORER', scorer, 'WITHSCORES', 'EXPLAINSCORE', 'PAYLOAD', b'\x00')
                            for scorer in SCORERS)
            for cmd in examples:
                with self.subTest(protocol=proto, command=cmd):
                    self.assertEqual(eski.call(*cmd), ref.call(*cmd))
            for method in ('RRF', 'LINEAR'):
                combine = (2, 'WINDOW', 2) if method == 'RRF' else (4, 'ALPHA', 0.4, 'BETA', 0.6)
                cmd = ('FT.HYBRID', 'catalog', 'SEARCH', '@text:fox', 'SCORER', 'TFIDF',
                       'VSIM', '@vec', '$v', 'COMBINE', method, *combine, 'EXPLAINSCORE',
                       'PARAMS', 2, 'v', QUERY_VECTOR, 'LIMIT', 0, 1)
                reference, actual = (pairs(c.call(*cmd)) for c in (ref, eski))
                del reference['execution_time'], actual['execution_time']
                self.assertEqual(actual, reference)
            for cmd in (('FT.TAGVALS', 'catalog', 'text'), ('FT.TAGVALS', 'catalog', 'bad'),
                        ('FT.CONFIG', 'SET', 'UNKNOWN', 'x'), ('FT.ALTER', 'catalog', 'SCHEMA', 'ADD', 'text', 'TAG'),
                        ('FT.SEARCH', 'catalog', '@text|other:*ox', 'DIALECT', 2),
                        ('FT.SEARCH', 'catalog', 'fox', 'HIGHLIGHT', 'FIELDS', 1, 'invalid'),
                        ('FT.ALIASDEL', 'unknown'), ('FT.PROFILE', 'catalog', 'BOGUS', 'QUERY', '*')):
                with self.subTest(protocol=proto, command=cmd):
                    with self.assertRaises(ServerError) as e:
                        ref.call(*cmd)
                    with self.assertRaisesRegex(ServerError, '^' + re.escape(str(e.exception)) + '$'):
                        eski.call(*cmd)


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
