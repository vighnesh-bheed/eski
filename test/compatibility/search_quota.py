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
from search_maintenance import create, info
from support import ServerError

SERVER = ROOT / 'bin/eski'
BASELINE = None
QUIET = ('--appendonly', 'no', '--save', '', '--shutdown-on-sigterm', 'nosave')
ALLOC = 'total_index_memory_sz_mb'
LABEL = sl.at('labels', 'C')
LABEL_TOP = sl.top('labels')
OWNER_TOP = sl.top('both')


def mapping(row):
    return dict(zip(row[::2], row[1::2]))


def section(c, name, scope=()):
    return dict(line.split(b':', 1) for line in c.call(*scope, 'INFO', name).splitlines() if b':' in line)


def byte_total(c, scope=(), name='items'):
    return round(float(info(c, name, scope)[ALLOC]) * (1 << 20))


class SearchQuota(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='eski-search-quota-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.servers = []

    def server(self, mode='', extra=(), binary=None):
        directory = self.root / str(len(self.servers))
        directory.mkdir()
        server = sl.Server(binary or SERVER, directory, mode, QUIET + extra)
        self.servers.append(server)
        self.addCleanup(server.kill)
        return server, self.up(server)

    def up(self, server):
        client = server.up()
        self.addCleanup(client.close)
        return client

    def test_definition_admission_uses_exact_creator_quota_and_cleans_up(self):
        for mode in ('labels', 'both'):
            with self.subTest(mode=mode):
                _, c = self.server(mode)
                scope = LABEL if mode == 'labels' else sl.at('both', 'C', 'one')
                top = sl.top(mode)
                if mode == 'labels':
                    quota = (*top, 'LABEL', 'QUOTA', 'C')
                    self.assertEqual(c.call(*quota, 'LIMIT', 0), 'OK')
                    used = lambda: c.call(*quota)[1]
                else:
                    quota = (*top, 'OWNERS', 'QUOTA', 'one')
                    self.assertEqual(c.call(*quota, 'LIMIT', 0), 'OK')
                    used = lambda: mapping(c.call(*top, 'OWNERS', 'INFO', 'one'))[b'bytes']
                idle = used()
                self.assertEqual(create(c, scope=scope), 'OK')
                created = used()
                self.assertGreater(created, idle)
                self.assertEqual(c.call(*scope, 'DBSIZE'), 0)
                self.assertEqual(c.call(*scope, 'FT.DROPINDEX', 'items'), 'OK')
                self.assertEqual(used(), idle)
                c.call(*quota, 'LIMIT', created - 1)
                with self.assertRaisesRegex(ServerError, 'quota'):
                    create(c, scope=scope)
                self.assertEqual(c.call(*scope, 'FT._LIST'), [])
                self.assertEqual(used(), idle)
                c.call(*quota, 'LIMIT', created)
                self.assertEqual(create(c, scope=scope), 'OK')
                self.assertEqual(used(), created)
                if mode == 'both':
                    owner = mapping(c.call(*top, 'OWNERS', 'INFO', 'one'))
                    self.assertEqual((owner[b'keys'], owner[b'partitions'], owner[b'labels']), (0, 0, 1))
                    self.assertEqual(section(c, 'owners', top)[b'owners_holding_data'], b'1')
                    self.assertIn(b'one', c.call(*top, 'OWNERS', 'LIST', 0)[1])
                    forgotten = mapping(c.call(*top, 'OWNERS', 'FORGET', 'one'))
                    self.assertEqual(forgotten[b'bytes'], created)
                    self.assertEqual(forgotten[b'keys'], 0)
                    self.assertEqual(section(c, 'owners', top)[b'owners_holding_data'], b'0')
                else:
                    self.assertEqual(c.call(*scope, 'FLUSHDB'), 'OK')
                    self.assertEqual(used(), idle)
                self.assertEqual(c.call(*scope, 'FT._LIST'), [])

    def test_hidden_owner_content_and_activity_do_not_move_reader_figures(self):
        shared = sl.at('both', 'C')
        reader = sl.at('both', 'C', 'reader')
        hidden = sl.at('both', 'C', 'hidden')
        controls = [self.server('both')[1], self.server('both')[1]]
        for c in controls:
            self.assertEqual(create(c, scope=shared, schema=('body', 'TEXT', 'NOSTEM', 'qty', 'NUMERIC')), 'OK')
            self.assertEqual(c.call(*reader, 'HSET', 'item:1', 'body', 'same', 'qty', '3'), 2)
        before = info(controls[0], scope=reader)
        self.assertGreater(float(before[ALLOC]), 0)
        c = controls[1]
        c.call(*hidden, 'HSET', 'item:1', 'body', 'first', 'qty', '100')
        c.call(*hidden, 'HSET', 'item:1', 'body', 'replaced', 'qty', '101')
        c.call(*hidden, 'HSET', 'item:2', 'body', 'error', 'qty', 'broken')
        self.assertEqual(info(c, scope=reader), before)
        self.assertEqual(float(before['total_indexing_time']), 0)
        self.assertTrue(all(float(v) == 0 for v in before['gc_stats'][1::2]))
        usage = [mapping(node.call(*OWNER_TOP, 'OWNERS', 'INFO', 'reader')) for node in controls]
        self.assertEqual(usage[0], usage[1])
        hidden_used = mapping(c.call(*OWNER_TOP, 'OWNERS', 'INFO', 'hidden'))[b'bytes']
        self.assertGreater(hidden_used, usage[0][b'bytes'])
        self.assertEqual(mapping(c.call(*OWNER_TOP, 'OWNERS', 'FORGET', 'hidden'))[b'bytes'], hidden_used)
        self.assertEqual(info(c, scope=reader), before)

    def test_initial_scan_can_charge_another_owner_and_enforces_next_write(self):
        _, c = self.server('both')
        creator = sl.at('both', 'C')
        owner = sl.at('both', 'C', 'member')
        c.call(*owner, 'HSET', 'item:1', 'body', 'original token')
        baseline = mapping(c.call(*OWNER_TOP, 'OWNERS', 'INFO', 'member'))[b'bytes']
        c.call(*OWNER_TOP, 'OWNERS', 'QUOTA', 'member', 'LIMIT', baseline)
        self.assertEqual(create(c, scope=creator), 'OK')
        self.assertEqual(info(c, scope=owner)['num_docs'], 1)
        used = mapping(c.call(*OWNER_TOP, 'OWNERS', 'INFO', 'member'))[b'bytes']
        self.assertGreater(used, baseline)
        with self.assertRaisesRegex(ServerError, 'owner-quota'):
            c.call(*owner, 'HSET', 'item:2', 'body', 'refused')
        self.assertEqual(c.call(*owner, 'HGET', 'item:1', 'body'), b'original token')
        c.call(*OWNER_TOP, 'CONFIG', 'SET', 'maxmemory-policy', 'allkeys-random')
        c.call(*OWNER_TOP, 'OWNERS', 'QUOTA', 'member', 'LIMIT', used - 1)
        self.assertEqual(c.call(*owner, 'SET', 'trigger', 'ok'), 'OK')
        self.assertEqual(c.call(*owner, 'EXISTS', 'item:1'), 0)
        self.assertEqual(info(c, scope=owner)['num_docs'], 0)
        self.assertLess(mapping(c.call(*OWNER_TOP, 'OWNERS', 'INFO', 'member'))[b'bytes'], used)
        self.assertEqual(c.call(*creator, 'FT.DROPINDEX', 'items'), 'OK')
        self.assertEqual(c.call(*owner, 'GET', 'trigger'), b'ok')

    def test_overwrite_compacts_history_without_changing_live_charge(self):
        server, c = self.server('labels')
        self.assertEqual(create(c, scope=LABEL), 'OK')
        c.call(*LABEL, 'HSET', 'item:key', 'body', 'stable')
        logical = byte_total(c, LABEL)
        self.assertLessEqual(byte_total(c, LABEL_TOP), logical)
        long_text = ' '.join(f'token{i:04d}' for i in range(2800))
        c.call(*LABEL, 'HSET', 'item:key', 'body', long_text)
        self.assertGreater(byte_total(c, LABEL), logical)
        self.assertLessEqual(byte_total(c, LABEL_TOP), byte_total(c, LABEL))
        for i in range(1320):
            c.call(*LABEL, 'HSET', 'item:key', 'body', ('change', 'stable')[i % 2])
        row = info(c, scope=LABEL)
        self.assertEqual((row['num_docs'], row['num_terms'], row['num_records']), (1, 1, 1))
        self.assertGreater(row['max_doc_id'], 1024)
        self.assertEqual(byte_total(c, LABEL), logical)
        self.assertLessEqual(byte_total(c, LABEL_TOP), logical)
        self.assertGreater(float(info(c, scope=LABEL_TOP)['total_indexing_time']), 0)
        self.assertEqual(c.call(*LABEL_TOP, 'SAVE'), 'OK')
        self.assertEqual(c.call(*LABEL_TOP, 'DEBUG', 'RELOAD', 'NOSAVE'), 'OK')
        self.assertEqual(byte_total(c, LABEL), logical)
        server.stop()
        c = self.up(server)
        self.assertEqual(byte_total(c, LABEL), logical)
        self.assertLessEqual(byte_total(c, LABEL_TOP), logical)

    def test_large_vectors_and_removal_stay_within_content_bound(self):
        for engine, dim in (('FLAT', 1 << 16), ('HNSW', 1 << 14)):
            with self.subTest(engine=engine):
                _, c = self.server('labels')
                schema = ('v', 'VECTOR', engine, 6, 'TYPE', 'FLOAT32', 'DIM', dim, 'DISTANCE_METRIC', 'L2')
                self.assertEqual(create(c, scope=LABEL, schema=schema), 'OK')
                blob = struct.pack('<f', 1.0) * dim
                c.call(*LABEL, 'HSET', 'item:one', 'v', blob)
                single = byte_total(c, LABEL)
                self.assertGreaterEqual(single, len(blob))
                self.assertLessEqual(byte_total(c, LABEL_TOP), single)
                for i in range(9):
                    c.call(*LABEL, 'HSET', f'item:{i}', 'v', blob)
                self.assertGreater(byte_total(c, LABEL), single)
                self.assertLessEqual(byte_total(c, LABEL_TOP), byte_total(c, LABEL))
                self.assertEqual(c.call(*LABEL, 'DEL', *(f'item:{i}' for i in range(9))), 9)
                self.assertEqual(byte_total(c, LABEL), single)
                self.assertLessEqual(byte_total(c, LABEL_TOP), single)
                self.assertEqual(c.call(*LABEL, 'UNLINK', 'item:one'), 1)
                self.assertLess(byte_total(c, LABEL), single)
                self.assertEqual(info(c, scope=LABEL)['num_docs'], 0)
                self.assertEqual(c.call(*LABEL, 'FT.DROPINDEX', 'items'), 'OK')
                self.assertEqual(c.call(*LABEL_TOP, 'LABEL', 'QUOTA', 'C')[1], 0)

    def test_quota_admission_reaps_expired_hash_and_releases_index_charge(self):
        _, c = self.server('labels')
        self.assertEqual(create(c, scope=LABEL), 'OK')
        c.call(*LABEL_TOP, 'DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        c.call(*LABEL, 'HSET', 'item:timed', 'body', 'expired words')

        def clock_ms():
            seconds, micros = map(int, c.call(*LABEL, 'TIME'))
            return seconds * 1000 + micros // 1000

        deadline = clock_ms() + 650
        self.assertEqual(c.call(*LABEL, 'PEXPIREAT', 'item:timed', deadline), 1)
        held = c.call(*LABEL_TOP, 'LABEL', 'QUOTA', 'C')[1]
        sl.wait_for(lambda: clock_ms() > deadline, timeout=10)
        self.assertEqual(info(c, scope=LABEL)['num_docs'], 0)
        self.assertEqual(c.call(*LABEL_TOP, 'LABEL', 'QUOTA', 'C')[1], held)
        c.call(*LABEL_TOP, 'LABEL', 'QUOTA', 'C', 'LIMIT', byte_total(c, LABEL))
        self.assertEqual(c.call(*LABEL, 'SET', 'key', 'new'), 'OK')
        self.assertEqual(c.call(*LABEL, 'EXISTS', 'item:timed'), 0)
        self.assertEqual(c.call(*LABEL, 'GET', 'key'), b'new')
        self.assertLess(c.call(*LABEL_TOP, 'LABEL', 'QUOTA', 'C')[1], held)

    def test_plain_maxmemory_uses_real_allocations_and_leaves_no_definition(self):
        _, c = self.server()
        dim = 1 << 16
        schema = ('v', 'VECTOR', 'FLAT', 6, 'TYPE', 'FLOAT32', 'DIM', dim, 'DISTANCE_METRIC', 'L2')
        blob = struct.pack('<f', 2.0) * dim
        self.assertEqual(c.call('HSET', 'item:existing', 'v', blob), 1)
        bare = int(section(c, 'memory')[b'used_memory'])
        self.assertEqual(create(c, 'existing', schema=schema), 'OK')
        indexed = int(section(c, 'memory')[b'used_memory'])
        self.assertGreater(indexed - bare, len(blob))
        self.assertEqual(c.call('CONFIG', 'SET', 'maxmemory', (indexed + bare) // 2), 'OK')
        with self.assertRaisesRegex(ServerError, 'maxmemory'):
            create(c, 'refused')
        self.assertEqual(c.call('FT._LIST'), ['existing'])
        self.assertEqual(c.call('FT.DROPINDEX', 'existing'), 'OK')
        self.assertEqual(c.call('FT._LIST'), [])
        self.assertEqual(c.call('SET', 'trigger', 'ok'), 'OK')
        self.assertEqual(c.call('CONFIG', 'SET', 'maxmemory', 0), 'OK')
        self.assertEqual(create(c, 'refused'), 'OK')

    def test_ordinary_commands_without_search_match_baseline(self):
        if not BASELINE:
            self.skipTest('pass --baseline to compare ordinary behavior')
        calls = [('SET', 'key', 'value'), ('HSET', 'hash', 'first', 'here', 'number', '17'),
                 ('HINCRBY', 'hash', 'number', 3), ('HGETALL', 'hash'), ('RENAME', 'hash', 'other'),
                 ('COPY', 'key', 'copy'), ('MEMORY', 'USAGE', 'key'), ('INFO', 'keyspace'),
                 ('DEBUG', 'DIGEST'), ('FT._LIST',), ('DEL', 'other', 'key'), ('DBSIZE',)]
        replies = []
        for binary in (BASELINE, SERVER):
            _, c = self.server(binary=binary)
            replies.append([c.call(*command) for command in calls])
        self.assertEqual(replies[0], replies[1])


def main():
    global SERVER, BASELINE
    args = argparse.ArgumentParser()
    args.add_argument('--server', type=Path, default=SERVER)
    args.add_argument('--baseline', type=Path)
    args.add_argument('--ports', default=os.getenv('ESKI_SEARCH_PORTS', ''))
    options, tests = args.parse_known_args()
    SERVER = options.server.resolve()
    BASELINE = options.baseline.resolve() if options.baseline else None
    if options.ports:
        sl.use_ports(options.ports)
    unittest.main(argv=[sys.argv[0]] + tests)


if __name__ == '__main__':
    main()
