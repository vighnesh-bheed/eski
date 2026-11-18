import argparse
import os
import re
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
import scoped_log as sl
from support import ServerError
sys.path.insert(0, str(ROOT / 'test/vectorset'))
from compare import Conn

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0
MISSING = 'SEARCH_INDEX_NOT_FOUND Index not found: '
EXISTS = 'SEARCH_INDEX_EXISTS Index already exists'
NOPERM = 'NOPERM User does not have the required permissions to query the index'

CREATE_CASES = (
    (('FT.CREATE',), b"-ERR wrong number of arguments for 'FT.CREATE' command\r\n"),
    (('FT.INFO',), b"-ERR wrong number of arguments for 'FT.INFO' command\r\n"),
    (('FT.DROPINDEX',), b"-ERR wrong number of arguments for 'FT.DROPINDEX' command\r\n"),
    (('FT.CREATE', 'e'), b"-ERR wrong number of arguments for 'FT.CREATE' command\r\n"),
    (('FT.CREATE', 'e', 'SCHEMA'), b"-ERR wrong number of arguments for 'FT.CREATE' command\r\n"),
    (('FT.CREATE', 'e', 'SCHEMA', 't', 'TEXT'), b'-SEARCH_INDEX_EXISTS Index already exists\r\n'),
    (('FT.CREATE', 'x1', 'ON', 'HASH'), b"-ERR wrong number of arguments for 'FT.CREATE' command\r\n"),
    (('FT.CREATE', 'x1', 'SCHEMA', 't', 'BLOB'), b'-SEARCH_PARSE_ARGS Invalid field type for field `t`\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 't'), b"-ERR wrong number of arguments for 'FT.CREATE' command\r\n"),
    (('FT.CREATE', 'x1', 'ON', 'STRING', 'SCHEMA', 't', 'TEXT'), b'-SEARCH_ADD_ARGS Invalid rule type: STRING\r\n'),
    (('FT.CREATE', 'x1', 'PREFIX', '2', 'a:', 'SCHEMA', 't', 'TEXT'), b'-SEARCH_ARG_UNRECOGNIZED Unknown argument `t`\r\n'),
    (('FT.CREATE', 'x1', 'PREFIX', 'x', 'SCHEMA', 't', 'TEXT'), b'-SEARCH_PARSE_ARGS Bad arguments for PREFIX: Could not convert argument to expected type\r\n'),
    (('FT.CREATE', 'x1', 'LANGUAGE', 'klingon', 'SCHEMA', 't', 'TEXT'), b'-SEARCH_ADD_ARGS Invalid language\r\n'),
    (('FT.CREATE', 'x1', 'STOPWORDS', '3', 'a', 'SCHEMA', 't', 'TEXT'), b'-SEARCH_ARG_UNRECOGNIZED Unknown argument `TEXT`\r\n'),
    (('FT.CREATE', 'x1', 'SCORE', 'abc', 'SCHEMA', 't', 'TEXT'), b'-SEARCH_ADD_ARGS Invalid score\r\n'),
    (('FT.CREATE', 'x1', 'SCORE', '2', 'SCHEMA', 't', 'TEXT'), b'-SEARCH_ADD_ARGS Invalid score\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 't', 'TEXT', 't', 'TEXT'), b'-SEARCH_QUERY_BAD Duplicate field in schema - t\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 't', 'TEXT', 'WEIGHT', 'abc'), b'-SEARCH_PARSE_ARGS Bad arguments for weight: Could not convert argument to expected type\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'g', 'TAG', 'SEPARATOR', ';;'), b'-SEARCH_PARSE_ARGS Tag separator must be a single character. Got `%s`;;\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'g', 'TAG', 'SEPARATOR'), b'-SEARCH_PARSE_ARGS SEPARATOR requires an argument\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 't', 'TEXT', 'PHONETIC', 'xx:yy'), b'-SEARCH_QUERY_BAD Matcher Format: <2 chars algorithm>:<2 chars language>. Support algorithms: double metaphone (dm). Supported languages: English (en), French (fr), Portuguese (pt) and Spanish (es)\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 't', 'TEXT', 'BOGUS'), b'-SEARCH_PARSE_ARGS Field `BOGUS` does not have a type\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR'), b'-SEARCH_PARSE_ARGS Bad arguments for vector similarity algorithm: Expected an argument, but none provided\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'IVF', '6', 'TYPE', 'FLOAT32', 'DIM', '2', 'DISTANCE_METRIC', 'L2'), b'-SEARCH_PARSE_ARGS Bad arguments for vector similarity algorithm: Unknown argument\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'FLAT', '5', 'TYPE', 'FLOAT32', 'DIM', '2', 'DISTANCE_METRIC', 'L2'), b'-SEARCH_PARSE_ARGS Bad number of arguments for vector similarity index: got 5 but expected even number as algorithm parameters (should be submitted as named arguments)\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'FLAT', '8', 'TYPE', 'FLOAT32', 'DIM', '2', 'DISTANCE_METRIC', 'L2'), b'-SEARCH_PARSE_ARGS Expected 8 parameters but got 6\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'FLAT', '4', 'TYPE', 'FLOAT32', 'DIM', '2'), b'-SEARCH_PARSE_ARGS Missing mandatory parameter: cannot create FLAT index without specifying DISTANCE_METRIC argument\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'FLAT', '4', 'DIM', '2', 'DISTANCE_METRIC', 'L2'), b'-SEARCH_PARSE_ARGS Missing mandatory parameter: cannot create FLAT index without specifying TYPE argument\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'FLAT', '4', 'TYPE', 'FLOAT32', 'DISTANCE_METRIC', 'L2'), b'-SEARCH_PARSE_ARGS Missing mandatory parameter: cannot create FLAT index without specifying DIM argument\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'FLAT', '6', 'TYPE', 'FLOAT32', 'DIM', '0', 'DISTANCE_METRIC', 'L2'), b'-SEARCH_PARSE_ARGS Bad arguments for vector similarity FLAT index `DIM`: Value is outside acceptable bounds\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'FLAT', '6', 'TYPE', 'FLOAT32', 'DIM', 'abc', 'DISTANCE_METRIC', 'L2'), b'-SEARCH_PARSE_ARGS Bad arguments for vector similarity FLAT index `DIM`: Could not convert argument to expected type\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'FLAT', '6', 'TYPE', 'FLOAT128', 'DIM', '2', 'DISTANCE_METRIC', 'L2'), b'-SEARCH_PARSE_ARGS Bad arguments for vector similarity FLAT index `TYPE`: Unknown argument\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'FLAT', '6', 'TYPE', 'FLOAT32', 'DIM', '2', 'DISTANCE_METRIC', 'HAMMING'), b'-SEARCH_PARSE_ARGS Bad arguments for vector similarity FLAT index `DISTANCE_METRIC`: Unknown argument\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'FLAT', '8', 'TYPE', 'FLOAT32', 'DIM', '2', 'DISTANCE_METRIC', 'L2', 'M', '16'), b'-SEARCH_PARSE_ARGS Bad arguments for algorithm FLAT: M\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'HNSW', '8', 'TYPE', 'FLOAT32', 'DIM', '2', 'DISTANCE_METRIC', 'L2', 'M', '0'), b'-SEARCH_PARSE_ARGS Bad arguments for vector similarity HNSW index `M`: Value is outside acceptable bounds\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'HNSW', '8', 'TYPE', 'FLOAT32', 'DIM', '2', 'DISTANCE_METRIC', 'L2', 'EF_CONSTRUCTION', '0'), b'-SEARCH_PARSE_ARGS Bad arguments for vector similarity HNSW index `EF_CONSTRUCTION`: Value is outside acceptable bounds\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'HNSW', '8', 'TYPE', 'FLOAT32', 'DIM', '2', 'DISTANCE_METRIC', 'L2', 'EPSILON', 'abc'), b'-SEARCH_PARSE_ARGS Bad arguments for vector similarity HNSW index `EPSILON`: Could not convert argument to expected type\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'HNSW', '8', 'TYPE', 'FLOAT32', 'DIM', '2', 'DISTANCE_METRIC', 'L2', 'BLOCK_SIZE', '0'), b'-SEARCH_PARSE_ARGS Bad arguments for algorithm HNSW: BLOCK_SIZE\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'SVS-VAMANA', '8', 'TYPE', 'FLOAT32', 'DIM', '2', 'DISTANCE_METRIC', 'L2', 'COMPRESSION', 'LVQ99'), b'-SEARCH_PARSE_ARGS Bad arguments for vector similarity SVS-VAMANA index `COMPRESSION`: Unknown argument\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'SVS-VAMANA', '8', 'TYPE', 'FLOAT32', 'DIM', '2', 'DISTANCE_METRIC', 'L2', 'M', '16'), b'-SEARCH_PARSE_ARGS Bad arguments for algorithm SVS-VAMANA: M\r\n'),
    (('FT.CREATE', 'x1', 'SCHEMA', 'v', 'VECTOR', 'FLAT', '6', 'TYPE', 'FLOAT32', 'DIM', '2', 'DISTANCE_METRIC', 'L2', 'SORTABLE'), b'-SEARCH_PARSE_ARGS Field `SORTABLE` does not have a type\r\n'),
    (('FT.INFO', 'nosuch'), b'-SEARCH_INDEX_NOT_FOUND Index not found: nosuch\r\n'),
    (('FT.DROPINDEX', 'nosuch'), b'-SEARCH_INDEX_NOT_FOUND Index not found: nosuch\r\n'),
    (('FT.INFO', 'e', 'extra'), b"-ERR wrong number of arguments for 'FT.INFO' command\r\n"),
    (('FT.DROPINDEX', 'e', 'XX'), b'-SEARCH_ARG_UNRECOGNIZED Unknown argument\r\n'),
    (('FT._LIST', 'extra'), b'-SEARCH_ARG_UNRECOGNIZED Unknown argument\r\n'),
)
EMPTY_INFO = {
    2: (
        b'*68\r\n+index_name\r\n+c13\r\n+index_options\r\n*0\r\n+index_definition\r\n*8\r\n'
        b'+key_type\r\n+HASH\r\n+prefixes\r\n*1\r\n+\r\n+default_score\r\n$1\r\n1\r\n+indexes_all\r\n'
        b'+false\r\n+attributes\r\n*2\r\n*8\r\n+identifier\r\n+title\r\n+attribute\r\n+t\r\n+type\r\n'
        b'+TEXT\r\n+WEIGHT\r\n$1\r\n1\r\n*6\r\n+identifier\r\n+n\r\n+attribute\r\n+num\r\n+type\r\n'
        b'+NUMERIC\r\n+num_docs\r\n:0\r\n+max_doc_id\r\n:0\r\n+num_terms\r\n:0\r\n+num_records\r\n'
        b':0\r\n+inverted_sz_mb\r\n$1\r\n0\r\n+vector_index_sz_mb\r\n$1\r\n0\r\n'
        b'+total_inverted_index_blocks\r\n:0\r\n+offset_vectors_sz_mb\r\n$1\r\n0\r\n'
        b'+doc_table_size_mb\r\n$1\r\n0\r\n+sortable_values_size_mb\r\n$1\r\n0\r\n'
        b'+key_table_size_mb\r\n$1\r\n0\r\n+tag_overhead_sz_mb\r\n$1\r\n0\r\n'
        b'+text_overhead_sz_mb\r\n$1\r\n0\r\n+total_index_memory_sz_mb\r\n$1\r\n0\r\n'
        b'+geoshapes_sz_mb\r\n$1\r\n0\r\n+records_per_doc_avg\r\n$3\r\nnan\r\n+bytes_per_record_avg\r\n'
        b'$3\r\nnan\r\n+offsets_per_term_avg\r\n$3\r\nnan\r\n+offset_bits_per_record_avg\r\n$3\r\n'
        b'nan\r\n+hash_indexing_failures\r\n:0\r\n+total_indexing_time\r\n$1\r\n0\r\n+indexing\r\n'
        b':0\r\n+percent_indexed\r\n$1\r\n1\r\n+number_of_uses\r\n:1\r\n+cleaning\r\n:0\r\n'
        b'+gc_stats\r\n*14\r\n+bytes_collected\r\n$1\r\n0\r\n+total_ms_run\r\n$1\r\n0\r\n'
        b'+total_cycles\r\n$1\r\n0\r\n+average_cycle_time_ms\r\n$3\r\nnan\r\n+last_run_time_ms\r\n'
        b'$1\r\n0\r\n+gc_numeric_trees_missed\r\n$1\r\n0\r\n+gc_blocks_denied\r\n$1\r\n0\r\n'
        b'+cursor_stats\r\n*8\r\n+global_idle\r\n:0\r\n+global_total\r\n:0\r\n+index_capacity\r\n'
        b':128\r\n+index_total\r\n:0\r\n+dialect_stats\r\n*8\r\n+dialect_1\r\n:0\r\n+dialect_2\r\n'
        b':0\r\n+dialect_3\r\n:0\r\n+dialect_4\r\n:0\r\n+Index Errors\r\n*8\r\n+indexing failures\r\n'
        b':0\r\n+last indexing error\r\n+N/A\r\n+last indexing error key\r\n$3\r\nN/A\r\n'
        b'+background indexing status\r\n+OK\r\n+field statistics\r\n*2\r\n*6\r\n+identifier\r\n'
        b'+title\r\n+attribute\r\n+t\r\n+Index Errors\r\n*6\r\n+indexing failures\r\n:0\r\n'
        b'+last indexing error\r\n+N/A\r\n+last indexing error key\r\n$3\r\nN/A\r\n*6\r\n'
        b'+identifier\r\n+n\r\n+attribute\r\n+num\r\n+Index Errors\r\n*6\r\n+indexing failures\r\n'
        b':0\r\n+last indexing error\r\n+N/A\r\n+last indexing error key\r\n$3\r\nN/A\r\n'
    ),
    3: (
        b'%34\r\n+index_name\r\n+c13\r\n+index_options\r\n*0\r\n+index_definition\r\n%4\r\n'
        b'+key_type\r\n+HASH\r\n+prefixes\r\n*1\r\n+\r\n+default_score\r\n,1\r\n+indexes_all\r\n'
        b'+false\r\n+attributes\r\n*2\r\n%5\r\n+identifier\r\n+title\r\n+attribute\r\n+t\r\n+type\r\n'
        b'+TEXT\r\n+WEIGHT\r\n,1\r\n+flags\r\n*0\r\n%4\r\n+identifier\r\n+n\r\n+attribute\r\n+num\r\n'
        b'+type\r\n+NUMERIC\r\n+flags\r\n*0\r\n+num_docs\r\n:0\r\n+max_doc_id\r\n:0\r\n+num_terms\r\n'
        b':0\r\n+num_records\r\n:0\r\n+inverted_sz_mb\r\n,0\r\n+vector_index_sz_mb\r\n'
        b',0\r\n+total_inverted_index_blocks\r\n:0\r\n+offset_vectors_sz_mb\r\n,0\r\n'
        b'+doc_table_size_mb\r\n,0\r\n+sortable_values_size_mb\r\n,0\r\n'
        b'+key_table_size_mb\r\n,0\r\n+tag_overhead_sz_mb\r\n,0\r\n'
        b'+text_overhead_sz_mb\r\n,0\r\n+total_index_memory_sz_mb\r\n,0\r\n'
        b'+geoshapes_sz_mb\r\n,0\r\n+records_per_doc_avg\r\n,nan\r\n+bytes_per_record_avg\r\n,nan\r\n'
        b'+offsets_per_term_avg\r\n,nan\r\n+offset_bits_per_record_avg\r\n,nan\r\n'
        b'+hash_indexing_failures\r\n:0\r\n+total_indexing_time\r\n,0\r\n+indexing\r\n:0\r\n'
        b'+percent_indexed\r\n,1\r\n+number_of_uses\r\n:1\r\n+cleaning\r\n:0\r\n+gc_stats\r\n%7\r\n'
        b'+bytes_collected\r\n,0\r\n+total_ms_run\r\n,0\r\n+total_cycles\r\n,0\r\n'
        b'+average_cycle_time_ms\r\n,nan\r\n+last_run_time_ms\r\n,0\r\n+gc_numeric_trees_missed\r\n'
        b',0\r\n+gc_blocks_denied\r\n,0\r\n+cursor_stats\r\n%4\r\n+global_idle\r\n:0\r\n'
        b'+global_total\r\n:0\r\n+index_capacity\r\n:128\r\n+index_total\r\n:0\r\n+dialect_stats\r\n'
        b'%4\r\n+dialect_1\r\n:0\r\n+dialect_2\r\n:0\r\n+dialect_3\r\n:0\r\n+dialect_4\r\n:0\r\n'
        b'+Index Errors\r\n%4\r\n+indexing failures\r\n:0\r\n+last indexing error\r\n+N/A\r\n'
        b'+last indexing error key\r\n$3\r\nN/A\r\n+background indexing status\r\n+OK\r\n'
        b'+field statistics\r\n*2\r\n%3\r\n+identifier\r\n+title\r\n+attribute\r\n+t\r\n'
        b'+Index Errors\r\n%3\r\n+indexing failures\r\n:0\r\n+last indexing error\r\n+N/A\r\n'
        b'+last indexing error key\r\n$3\r\nN/A\r\n%3\r\n+identifier\r\n+n\r\n+attribute\r\n+num\r\n'
        b'+Index Errors\r\n%3\r\n+indexing failures\r\n:0\r\n+last indexing error\r\n+N/A\r\n'
        b'+last indexing error key\r\n$3\r\nN/A\r\n'
    ),
}


class SearchDefinitions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='eski-search-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.servers = []

    def server(self, mode='', extra=()):
        directory = self.root / str(len(self.servers))
        directory.mkdir()
        s = sl.Server(BINARY, directory, mode, extra, KEYSPACE_THREADS)
        self.servers.append(s)
        self.addCleanup(s.kill)
        c = s.up()
        self.addCleanup(c.close)
        return s, c

    def raw(self, server, protocol):
        c = Conn(server.run.port, protocol, 15)
        self.addCleanup(c.close)
        return lambda argv: c.call([arg.encode() for arg in argv]).raw

    def create(self, c, name, *scope, field='body', prefix='doc:'):
        return c.call(*scope, 'FT.CREATE', name, 'ON', 'HASH', 'PREFIX', 1, prefix, 'SCHEMA', field, 'TEXT')

    def test_captured_syntax_errors_and_empty_info_in_both_protocols(self):
        s, c = self.server()
        self.assertEqual(c.call('FT.CREATE', 'e', 'SCHEMA', 't', 'TEXT'), 'OK')
        for protocol in (2, 3):
            self.assertEqual(c.call('ft.create', 'c13', 'schema', 'title', 'as', 't', 'text',
                                    'n', 'as', 'num', 'numeric'), 'OK')
            raw = self.raw(s, protocol)
            with self.subTest(protocol=protocol):
                for args, reply in CREATE_CASES:
                    self.assertEqual(raw(args), reply, args)
                reported = raw(('FT.INFO', 'c13'))
                prefix = b'+total_index_memory_sz_mb\r\n'
                encoded = rb'\$[0-9]+\r\n([0-9.e+-]+)\r\n' if protocol == 2 else rb',([0-9.e+-]+)\r\n'
                size = re.search(re.escape(prefix) + encoded, reported)
                self.assertIsNotNone(size)
                self.assertGreater(float(size[1]), 0)
                self.assertLess(float(size[1]), 0.01)
                replacement = b'$1\r\n0\r\n' if protocol == 2 else b',0\r\n'
                reported = reported[:size.start()] + prefix + replacement + reported[size.end():]
                self.assertEqual(reported, EMPTY_INFO[protocol])
                head = b'*' if protocol == 2 else b'~'
                self.assertEqual(raw(('FT._LIST',)), head + b'2\r\n+c13\r\n+e\r\n')
                self.assertEqual(c.call('FT.DROPINDEX', 'c13'), 'OK')

    def test_definition_layout_for_all_supported_field_types(self):
        _, c = self.server()
        self.assertEqual(c.call('FT.CREATE', 'mixed', 'LANGUAGE', 'German',
                                'LANGUAGE_FIELD', 'lang', 'SCORE_FIELD', 'score', 'SCORE', '0.5',
                                'STOPWORDS', 2, 'foo', 'bar', 'SKIPINITIALSCAN', 'SCHEMA',
                                'body', 'TEXT', 'WEIGHT', '2.5', 'NOSTEM', 'SORTABLE', 'UNF',
                                'facet', 'TAG', 'SEPARATOR', ';', 'CASESENSITIVE', 'INDEXMISSING',
                                'price', 'NUMERIC', 'SORTABLE', 'NOINDEX',
                                'v', 'VECTOR', 'HNSW', 16, 'DIM', 4, 'TYPE', 'FLOAT64',
                                'DISTANCE_METRIC', 'IP', 'M', 8, 'EF_CONSTRUCTION', 100,
                                'EF_RUNTIME', 20, 'EPSILON', '0.05', 'INITIAL_CAP', 100), 'OK')
        expected = [
            ['identifier', 'body', 'attribute', 'body', 'type', 'TEXT', 'WEIGHT', b'2.5', 'NOSTEM', 'SORTABLE', 'UNF'],
            ['identifier', 'facet', 'attribute', 'facet', 'type', 'TAG', 'SEPARATOR', ';', 'CASESENSITIVE', 'INDEXMISSING'],
            ['identifier', 'price', 'attribute', 'price', 'type', 'NUMERIC', 'SORTABLE', 'UNF', 'NOINDEX'],
            ['identifier', 'v', 'attribute', 'v', 'type', 'VECTOR', 'algorithm', 'HNSW', 'data_type',
             'FLOAT64', 'dim', 4, 'distance_metric', 'IP', 'M', 8, 'ef_construction', 100, 'ef_runtime', 20],
        ]
        flat = c.call('FT.INFO', 'mixed')
        info = dict(zip(flat[::2], flat[1::2]))
        self.assertEqual(info['attributes'], expected)
        self.assertEqual(info['stopwords_list'], [b'bar', b'foo'])
        self.assertEqual(info['number_of_uses'], 1)
        self.assertEqual(info['index_definition'], ['key_type', 'HASH', 'prefixes', [''], 'default_language',
                                                     'german', 'language_field', 'lang', 'default_score', b'0.5',
                                                     'score_field', 'score', 'indexes_all', 'false'])
        c.call('HELLO', 3)
        info = c.call('FT.INFO', 'mixed')
        self.assertEqual(info['attributes'][3]['algorithm'], 'HNSW')
        self.assertEqual(info['number_of_uses'], 2)
        self.assertEqual(info['attributes'][0]['flags'], ['NOSTEM', 'SORTABLE', 'UNF'])
        self.assertEqual(info['attributes'][1]['flags'], ['CASESENSITIVE', 'INDEXMISSING'])
        self.assertEqual(info['attributes'][2]['flags'], ['SORTABLE', 'UNF', 'NOINDEX'])

    def test_database_lifecycle_and_dd(self):
        _, c = self.server()
        for db, operation, retained in ((0, ('FLUSHDB',), False), (1, ('FLUSHDB',), False),
                                        (0, ('SWAPDB', 0, 1), True), (1, ('FLUSHALL',), False)):
            with self.subTest(db=db, operation=operation):
                c.call('SELECT', 0)
                c.call('FLUSHALL')
                self.assertEqual(self.create(c, 'index'), 'OK')
                c.call('SELECT', db)
                self.assertEqual(c.call(*operation), 'OK')
                self.assertEqual(c.call('FT._LIST'), ['index'] if retained else [])
        c.call('SELECT', 1)
        with self.assertRaisesRegex(ServerError, 'Cannot create index on db != 0'):
            self.create(c, 'elsewhere')
        c.call('SELECT', 0)
        self.assertEqual(self.create(c, 'index'), 'OK')
        c.call('HSET', 'doc:still-a-hash', 'body', 'value')
        c.call('SELECT', 1)
        self.assertEqual(c.call('FT.DROPINDEX', 'index', 'dD'), 'OK')
        c.call('SELECT', 0)
        self.assertIsNone(c.call('HGET', 'doc:still-a-hash', 'body'))

    def test_module_acl_and_command_introspection(self):
        _, c = self.server()
        initial = c.call('COMMAND', 'COUNT')
        module = c.call('MODULE', 'LIST')
        modules = [dict(zip(row[::2], row[1::2])) for row in module]
        self.assertIn({b'name': b'search', b'ver': 81001, b'path': b'', b'args': []}, modules)
        names = [b'FT.AGGREGATE', b'FT.ALIASADD', b'FT.ALIASDEL', b'FT.ALIASUPDATE', b'FT.ALTER',
                 b'FT.CONFIG', b'FT.CREATE', b'FT.CURSOR', b'FT.DROPINDEX', b'FT.EXPLAIN', b'FT.EXPLAINCLI',
                 b'FT.HYBRID', b'FT.INFO', b'FT.PROFILE', b'FT.SEARCH', b'FT.TAGVALS', b'FT._LIST']
        subcommands = [b'FT.CONFIG|GET', b'FT.CONFIG|HELP', b'FT.CONFIG|SET',
                       b'FT.CURSOR|DEL', b'FT.CURSOR|GC', b'FT.CURSOR|READ']
        self.assertEqual(sorted(c.call('COMMAND', 'LIST', 'FILTERBY', 'MODULE', 'search')), sorted(names + subcommands))
        self.assertEqual(sorted(c.call('ACL', 'CAT', 'search')), names)
        self.assertIn('search', [x.decode() if isinstance(x, bytes) else x for x in c.call('ACL', 'CAT')])
        self.assertIn(b'FT.CREATE', c.call('COMMAND', 'DOCS', 'FT.CREATE'))
        create = c.call('COMMAND', 'INFO', 'FT.CREATE')[0]
        self.assertEqual(create, [b'FT.CREATE', -5, ['write', 'denyoom', 'module'], 0, 0, 0,
                                  ['@search'], [b'dont_cache'], [], []])
        self.assertGreater(initial, len(names))
        search = c.call('COMMAND', 'INFO', 'FT.SEARCH')[0]
        self.assertEqual(search, [b'FT.SEARCH', -3, ['readonly', 'module'], 0, 0, 0,
                                  ['@read', '@search'], [b'dont_cache'], [], []])

    def test_acl_prefix_coverage_is_read_only_and_applies_after_resolution(self):
        s, c = self.server()
        c.call('FT.CREATE', 'both', 'PREFIX', 2, 'item:', 'document:', 'SCHEMA', 'body', 'TEXT')
        for pattern in ('~item:one', '~item:', '%W~item:*', r'~item:\*', '~other:*'):
            with self.subTest(pattern=pattern):
                c.call('ACL', 'SETUSER', 'limited', 'reset', 'on', 'nopass', '+@search', pattern, '~document:*')
                user = s.client('limited')
                self.addCleanup(user.close)
                self.assertEqual(user.call('FT._LIST'), ['both'])
                for argv in (('FT.INFO', 'both'), ('FT.DROPINDEX', 'both', 'DD')):
                    with self.assertRaisesRegex(ServerError, NOPERM):
                        user.call(*argv)
                with self.assertRaisesRegex(ServerError, MISSING + 'absent'):
                    user.call('FT.INFO', 'absent')
        c.call('ACL', 'SETUSER', 'limited', 'reset', 'on', 'nopass', '+@search',
               '(%R~[i]tem:*)', '(%R~document:*)')
        user = s.client('limited')
        self.addCleanup(user.close)
        self.assertIsInstance(user.call('FT.INFO', 'both'), list)
        self.assertEqual(user.call('FT.CREATE', 'all-prefixes', 'PREFIX', 0, 'SCHEMA', 'body', 'TEXT'), 'OK')
        with self.assertRaisesRegex(ServerError, NOPERM):
            user.call('FT.INFO', 'all-prefixes')
        self.assertEqual(user.call('FT.CREATE', 'unreadable', 'PREFIX', 1, 'later:', 'SCHEMA', 'body', 'TEXT'), 'OK')
        with self.assertRaisesRegex(ServerError, NOPERM):
            user.call('FT.INFO', 'unreadable')
        c.call('HSET', 'item:a', 'body', 'still present')
        self.assertEqual(user.call('FT.DROPINDEX', 'both', 'DD'), 'OK')
        self.assertEqual(c.call('EXISTS', 'item:a'), 0)

    def test_label_resolution_age_and_scoped_flush(self):
        _, c = self.server('labels')
        older = sl.at('labels', 'S//A')
        newer = sl.at('labels', 'S//B')
        low = sl.at('labels', 'U')
        top = sl.top('labels')
        self.assertEqual(self.create(c, 'same', *older, field='older'), 'OK')
        self.assertEqual(self.create(c, 'same', *newer, field='newer'), 'OK')
        self.assertEqual(c.call(*top, 'FT._LIST'), ['same'])
        self.assertIn('older', str(c.call(*top, 'FT.INFO', 'same')))
        with self.assertRaisesRegex(ServerError, EXISTS):
            self.create(c, 'same', *top)
        with self.assertRaisesRegex(ServerError, 'INUSE index in use at S//A'):
            c.call(*top, 'FT.DROPINDEX', 'same')
        with self.assertRaisesRegex(ServerError, MISSING + 'same'):
            c.call(*low, 'FT.INFO', 'same')
        self.assertEqual(self.create(c, 'same', *low, field='low'), 'OK')
        c.call('SELECT', 1)
        self.assertEqual(c.call(*older, 'FLUSHDB'), 'OK')
        self.assertIn('older', str(c.call(*older, 'FT.INFO', 'same')))
        c.call('SELECT', 0)
        self.assertEqual(c.call(*older, 'FLUSHDB'), 'OK')
        self.assertIn('newer', str(c.call(*top, 'FT.INFO', 'same')))
        self.assertEqual(c.call(*top, 'FLUSHALL'), 'OK')
        self.assertEqual(c.call(*low, 'FT._LIST'), [])

    def test_owner_resolution_metadata_and_forget(self):
        s, c = self.server('both', ('--owner-partitions-max', '1',))
        u1 = sl.at('both', 'C', 'u1')
        u2 = sl.at('both', 'C', 'u2')
        shared = sl.at('both', 'C')
        op = sl.top('both')
        ordinary = sl.at('both', 'C', 'ordinary')
        self.assertEqual(c.call(*ordinary, 'PING'), 'PONG')
        self.assertEqual(c.call(*op, 'OWNERS', 'FORGET', 'ordinary')[1], 0)
        self.assertEqual(c.call(*u2, 'SET', 'holds-one-partition', 'yes'), 'OK')
        self.assertEqual(self.create(c, 'same', *u1, field='own'), 'OK')
        self.assertEqual(self.create(c, 'same', *shared, field='shared'), 'OK')
        self.assertIn('own', str(c.call(*u1, 'FT.INFO', 'same')))
        self.assertIn('shared', str(c.call(*u2, 'FT.INFO', 'same')))
        with self.assertRaisesRegex(ServerError, 'INUSE index in use at C SHARED'):
            c.call(*u2, 'FT.DROPINDEX', 'same')
        self.assertEqual(c.call(*u1, 'DBSIZE'), 0)
        info = c.call(*op, 'OWNERS', 'INFO', 'u1')
        owner_info = dict(zip(info[::2], info[1::2]))
        self.assertEqual(owner_info[b'partitions'], 0)
        self.assertEqual(c.call(*u2, 'FLUSHDB'), 'OK')
        self.assertIn('own', str(c.call(*u1, 'FT.INFO', 'same')))
        self.assertEqual(c.call(*u2, 'SET', 'holds-one-partition', 'yes'), 'OK')
        self.assertEqual(c.call(*op, 'OWNERS', 'LIST', 0)[1], [b'u2', b'u1'])
        c.call(*op, 'ACL', 'SETUSER', 'no-shared', 'on', 'nopass', '+@all', '~*', 'clearance:*',
               'trust:*', 'owners:*')
        restricted = s.client('no-shared')
        self.addCleanup(restricted.close)
        with self.assertRaises(ServerError):
            self.create(restricted, 'refused', *shared)
        self.assertEqual(c.call(*u1, 'FT._LIST'), ['same'])
        self.assertEqual(c.call(*op, 'OWNERS', 'FORGET', 'u1')[1], 0)
        self.assertIn('shared', str(c.call(*u1, 'FT.INFO', 'same')))
        self.assertEqual(c.call(*op, 'OWNERS', 'LIST', 0)[1], [b'u2'])

    def test_labels_and_owners_hide_index_creation_drop_flush_and_forget(self):
        for mode in ('labels', 'owners'):
            with self.subTest(mode=mode):
                _, a = self.server(mode)
                _, b = self.server(mode)
                reader = sl.at(mode, 'C') if mode == 'labels' else sl.at(mode, 'UNCLASSIFIED', 'u1')
                hidden = sl.at(mode, 'S') if mode == 'labels' else sl.at(mode, 'UNCLASSIFIED', 'u2')
                top = sl.top(mode)
                self.assertEqual(self.create(b, 'hidden', *hidden, field='secret'), 'OK')

                def visible(c):
                    rows = [c.call(*reader, 'FT._LIST'), c.call(*reader, 'DBSIZE'),
                            c.call(*reader, 'INFO', 'keyspace')]
                    for argv in (('LABEL', 'COPIES', 'hidden'), ('FT.INFO', 'hidden'), ('FT.DROPINDEX', 'hidden')):
                        try:
                            rows.append(c.call(*reader, *argv))
                        except ServerError as error:
                            rows.append(str(error))
                    return rows

                self.assertEqual(visible(a), visible(b))
                self.assertEqual(b.call(*top, 'LABEL', 'COPIES', 'hidden'), [])
                self.assertEqual(visible(a)[-2:], [MISSING + 'hidden'] * 2)
                for c in (a, b):
                    self.assertEqual(self.create(c, 'hidden', *reader, field='public'), 'OK')
                self.assertEqual(a.call(*reader, 'FT.INFO', 'hidden'), b.call(*reader, 'FT.INFO', 'hidden'))
                self.assertEqual(b.call(*hidden, 'FT.DROPINDEX', 'hidden'), 'OK')
                self.assertEqual(self.create(b, 'different', *hidden), 'OK')
                self.assertEqual(b.call(*hidden, 'FLUSHALL'), 'OK')
                if mode == 'owners':
                    self.assertEqual(self.create(b, 'forgotten', *hidden), 'OK')
                    b.call(*top, 'OWNERS', 'FORGET', 'u2')
                self.assertEqual(visible(a), visible(b))

    def test_transaction_and_script_use_the_enclosing_scope(self):
        _, c = self.server('labels')
        scope = sl.at('labels', 'C')
        low = sl.at('labels', 'U')
        self.assertEqual(c.call(*scope, 'MULTI'), 'OK')
        self.assertEqual(c.call('FT.CREATE', 'from-tx', 'SCHEMA', 'body', 'TEXT'), 'QUEUED')
        self.assertEqual(c.call('EXEC'), ['OK'])
        script = "return redis.call('FT.CREATE', 'from-script', 'SCHEMA', 'body', 'TEXT')"
        self.assertEqual(c.call(*scope, 'EVAL', script, 0), 'OK')
        self.assertEqual(c.call(*scope, 'FT._LIST'), ['from-script', 'from-tx'])
        self.assertEqual(c.call(*low, 'FT._LIST'), [])

    def test_definition_commands_survive_in_all_append_only_modes(self):
        for mode in ('', 'labels', 'owners'):
            with self.subTest(mode=mode):
                s, c = self.server(mode, ('--appendonly', 'yes', '--appendfsync', 'always', '--save', ''))
                scope = (sl.at(mode, 'C') if mode == 'labels' else
                         sl.at(mode, 'UNCLASSIFIED', 'u1') if mode == 'owners' else ())
                self.assertEqual(self.create(c, 'removed', *scope), 'OK')
                self.assertEqual(c.call(*scope, 'FT.DROPINDEX', 'removed'), 'OK')
                self.assertEqual(self.create(c, 'survivor', *scope), 'OK')
                self.assertEqual(c.call(*scope, 'SET', 'persistent', 'v'), 'OK')
                s.stop()
                rows = sl.records(sl.last_incr(s.run.directory).read_bytes())
                self.assertEqual([row[1][:2] for row in map(sl.scoped, rows) if row[1][0].upper().startswith(b'FT.')],
                                 [[b'FT.CREATE', b'removed'], [b'FT.DROPINDEX', b'removed'],
                                  [b'FT.CREATE', b'survivor']])
                restarted = s.up()
                self.addCleanup(restarted.close)
                self.assertEqual(restarted.call(*scope, 'GET', 'persistent'), b'v')
                self.assertEqual(restarted.call(*scope, 'FT._LIST'), ['survivor'])


def main():
    global BINARY, KEYSPACE_THREADS
    args = argparse.ArgumentParser()
    args.add_argument('--server', default=str(BINARY))
    args.add_argument('--keyspace-threads', type=int, default=0)
    args.add_argument('--ports', default=os.getenv('ESKI_SEARCH_PORTS', ''))
    parsed, unittest_args = args.parse_known_args()
    BINARY = Path(parsed.server).resolve()
    KEYSPACE_THREADS = parsed.keyspace_threads
    if parsed.ports:
        sl.use_ports(parsed.ports)
    unittest.main(argv=[sys.argv[0]] + unittest_args, verbosity=1)


if __name__ == '__main__':
    main()
