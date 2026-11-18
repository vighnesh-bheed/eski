import argparse
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
import scoped_log as sl
from support import ServerError

SERVER = ROOT / 'bin/eski'
BASELINE = None
QUIET = ('--save', '', '--shutdown-on-sigterm', 'nosave')
LOG = ('--appendonly', 'yes', '--appendfsync', 'always', '--auto-aof-rewrite-percentage', '0')
MARKER = bytes.fromhex('f7 81 12 c9 22 4a b7 21 d4 01')
SCOPE = sl.at('both', 'C//A', 'u1')
TOP = sl.top('both')


def info(reply):
    return dict(zip(reply[::2], reply[1::2]))


def definition(client, name, scope=()):
    return client.call(*scope, 'FT.CREATE', name, 'ON', 'HASH', 'PREFIX', 2, 'doc:', b'bin:\x00',
                       'LANGUAGE', 'Dutch', 'LANGUAGE_FIELD', 'lang', 'SCORE', '0.12345678912345678',
                       'SCORE_FIELD', 'rank', 'STOPWORDS', 2, 'fiets', 'boot', 'MAXTEXTFIELDS',
                       'INDEXALL', 'ENABLE', 'SKIPINITIALSCAN', 'SCHEMA',
                       'body', 'AS', 'text', 'TEXT', 'WEIGHT', '1.2345678912345678', 'SORTABLE', 'UNF',
                       'NOSTEM', 'INDEXMISSING', 'category', 'TAG', 'SEPARATOR', b'\x00', 'CASESENSITIVE',
                       'INDEXEMPTY', 'price', 'NUMERIC', 'SORTABLE', 'NOINDEX',
                       'a', 'VECTOR', 'FLAT', 10, 'TYPE', 'FLOAT32', 'DIM', 4, 'DISTANCE_METRIC', 'COSINE',
                       'INITIAL_CAP', 10, 'BLOCK_SIZE', 4,
                       'b', 'VECTOR', 'HNSW', 16, 'TYPE', 'FLOAT64', 'DIM', 4, 'DISTANCE_METRIC', 'IP',
                       'M', 8, 'EF_CONSTRUCTION', 100, 'EF_RUNTIME', 20, 'EPSILON', '0.012345678912345678',
                       'INITIAL_CAP', 100, 'INDEXMISSING')


def simple(client, name, scope=(), field='body'):
    return client.call(*scope, 'FT.CREATE', name, 'SCHEMA', field, 'TEXT')


def definition_info(client, name, scope=()):
    values = info(client.call(*scope, 'FT.INFO', name))
    return tuple(values[key] for key in ('index_name', 'index_options', 'index_definition', 'attributes'))


def base_file(directory, sealed_extension=None):
    folder = sl.log_dir(directory)
    if sealed_extension:
        return max(folder.glob('*.base.' + sealed_extension), key=lambda path: int(path.name.split('.')[2]))
    for row in (folder / 'appendonly.aof.manifest').read_text().splitlines():
        words = row.split()
        if words[words.index('type') + 1] == 'b':
            return folder / words[words.index('file') + 1]
    raise AssertionError('no AOF base in manifest')


def rewrite(client, scope=()):
    self_reply = client.call(*scope, 'BGREWRITEAOF')
    if self_reply != 'Background append only file rewriting started':
        raise AssertionError(self_reply)
    sl.wait_for(lambda: b'aof_rewrite_in_progress:0' in client.call(*scope, 'INFO', 'persistence'))
    if b'aof_last_bgrewrite_status:ok' not in client.call(*scope, 'INFO', 'persistence'):
        raise AssertionError('AOF rewrite failed')


def rdb_len(data, offset):
    b = data[offset]
    if b < 0x40:
        return b, offset + 1
    if b < 0x80:
        return (b & 63) * 256 + data[offset + 1], offset + 2
    width = {0x80: 4, 0x81: 8}[b]
    return int.from_bytes(data[offset + 1:offset + 1 + width], 'big'), offset + 1 + width


def first_record(data):
    start = data.index(MARKER)
    offset = start + len(MARKER)
    fields = []
    while data[offset]:
        op = data[offset]
        field = offset + 1
        value, offset = rdb_len(data, field)
        if op == 5:
            offset += value
        elif op != 2:
            raise AssertionError(op)
        fields.append((field, offset))
    return start, offset + 1, fields


def rdb_stable(data):
    data = re.sub(rb'\xfa\x05ctime\xc2.{4}', b'', data, count=1, flags=re.S)
    data = re.sub(rb'\xfa\x08used-mem\xc2.{4}', b'', data, count=1, flags=re.S)
    return data


class SearchPersistence(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='eski-search-persist-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.nodes = []

    def node(self, mode='', extra=(), binary=None):
        directory = self.root / str(len(self.nodes))
        directory.mkdir()
        server = sl.Server(binary or SERVER, directory, mode, ('--appendonly', 'no') + QUIET + extra)
        self.nodes.append(server)
        self.addCleanup(server.kill)
        return server

    def up(self, server):
        connection = server.up()
        self.addCleanup(connection.close)
        return connection

    def key(self):
        path = self.root / 'key'
        path.write_text(bytes(range(32)).hex() + '\n')
        path.chmod(0o600)
        return '--encryption-key-file', str(path)

    def test_plain_snapshot_restart_and_reload(self):
        server = self.node()
        c = self.up(server)
        self.assertEqual(definition(c, b'schema\x00name'), 'OK')
        expected = definition_info(c, b'schema\x00name')
        self.assertEqual(c.call('HSET', 'doc:1', 'body', 'fiets'), 1)
        self.assertEqual(c.call('SAVE'), 'OK')
        self.assertEqual(c.call('FT.DROPINDEX', b'schema\x00name'), 'OK')
        self.assertEqual(simple(c, 'after-save'), 'OK')
        self.assertEqual(c.call('DEBUG', 'RELOAD', 'NOSAVE'), 'OK')
        self.assertEqual(c.call('FT._LIST'), [b'schema\x00name'])
        self.assertEqual(definition_info(c, b'schema\x00name'), expected)
        self.assertEqual(c.call('HGET', 'doc:1', 'body'), b'fiets')
        server.stop()
        c = self.up(server)
        self.assertEqual(definition_info(c, b'schema\x00name'), expected)
        self.assertNotIn('after-save', c.call('FT._LIST'))

    def test_plain_snapshot_noflush_and_merge(self):
        server = self.node()
        c = self.up(server)
        self.assertEqual(simple(c, 'overlap', field='saved'), 'OK')
        self.assertEqual(c.call('SET', 'merge-key', 'saved'), 'OK')
        self.assertEqual(c.call('SAVE'), 'OK')
        self.assertEqual(c.call('SET', 'merge-key', 'live'), 'OK')
        self.assertEqual(c.call('FT.DROPINDEX', 'overlap'), 'OK')
        self.assertEqual(simple(c, 'overlap', field='live'), 'OK')
        self.assertEqual(simple(c, 'keep'), 'OK')
        with self.assertRaises(ServerError):
            c.call('DEBUG', 'RELOAD', 'NOSAVE', 'NOFLUSH')
        self.assertIn('live', str(definition_info(c, 'overlap')))
        self.assertEqual(c.call('GET', 'merge-key'), b'live')
        self.assertEqual(c.call('DEBUG', 'RELOAD', 'NOSAVE', 'NOFLUSH', 'MERGE'), 'OK')
        self.assertEqual(c.call('FT._LIST'), ['keep', 'overlap'])
        self.assertIn('saved', str(definition_info(c, 'overlap')))
        self.assertEqual(c.call('GET', 'merge-key'), b'saved')

    def test_plain_sealed_snapshot_and_command_aof(self):
        key = self.key()
        for extra, command in (((), ('DEBUG', 'RELOAD', 'NOSAVE')),
                               (LOG + ('--aof-use-rdb-preamble', 'no'), ('DEBUG', 'LOADAOF'))):
            with self.subTest(command=command):
                server = self.node(extra=key + extra)
                c = self.up(server)
                self.assertEqual(definition(c, 'private-index'), 'OK')
                expected = definition_info(c, 'private-index')
                self.assertEqual(c.call('HSET', 'doc:1', 'body', 'protected'), 1)
                if extra:
                    rewrite(c)
                    payload = base_file(server.run.directory, 'aof').read_bytes()
                    self.assertEqual(simple(c, 'post-rewrite-index'), 'OK')
                else:
                    self.assertEqual(c.call('SAVE'), 'OK')
                    payload = (server.run.directory / 'dump.rdb').read_bytes()
                self.assertTrue(payload.startswith(b'ESKI'))
                self.assertNotIn(b'private-index', payload)
                self.assertEqual(c.call(*command), 'OK')
                server.stop()
                c = self.up(server)
                self.assertEqual(definition_info(c, 'private-index'), expected)
                self.assertEqual(c.call('HGET', 'doc:1', 'body'), b'protected')
                if extra:
                    self.assertIn('post-rewrite-index', c.call('FT._LIST'))

    def test_definition_dirty_and_metadata_only_flushes(self):
        server = self.node(extra=LOG)
        c = self.up(server)

        def dirty():
            return int(re.search(rb'rdb_changes_since_last_save:(\d+)', c.call('INFO', 'persistence'))[1])

        start = dirty()
        self.assertEqual(simple(c, 'one'), 'OK')
        self.assertEqual(dirty(), start + 1)
        with self.assertRaises(ServerError):
            simple(c, 'one')
        with self.assertRaises(ServerError):
            c.call('FT.DROPINDEX', 'missing')
        self.assertEqual(dirty(), start + 1)
        self.assertEqual(c.call('FT.DROPINDEX', 'one'), 'OK')
        self.assertEqual(dirty(), start + 2)
        for command in ('FLUSHDB', 'FLUSHALL'):
            self.assertEqual(simple(c, 'only-metadata'), 'OK')
            self.assertEqual(c.call('DBSIZE'), 0)
            self.assertEqual(c.call(command), 'OK')
            self.assertEqual(c.call('FT._LIST'), [])
        self.assertEqual(c.call('DEBUG', 'LOADAOF'), 'OK')
        self.assertEqual(c.call('FT._LIST'), [])
        server.stop()
        c = self.up(server)
        self.assertEqual(c.call('FT._LIST'), [])

    def test_scoped_snapshot_restart_reload_and_digest(self):
        for encrypted in (False, True):
            with self.subTest(encrypted=encrypted):
                server = self.node('both', self.key() if encrypted else ())
                c = self.up(server)
                before = c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
                self.assertEqual(simple(c, 'same', SCOPE, 'secret'), 'OK')
                low = sl.at('both', 'U', 'u1')
                two = sl.at('both', 'C//A', 'u2')
                own_only = sl.at('both', 'S//B', 'metadata-only')
                self.assertEqual(simple(c, 'same', low, 'public'), 'OK')
                self.assertEqual(simple(c, 'same', two, 'other'), 'OK')
                self.assertEqual(simple(c, 'metadata', own_only), 'OK')
                with_definitions = c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
                self.assertNotEqual(with_definitions, before)
                self.assertEqual(c.call(*SCOPE, 'HSET', 'doc:1', 'secret', 'hidden'), 1)
                dig = c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
                self.assertEqual(c.call(*TOP, 'SAVE'), 'OK')
                keys = (server.run.directory / 'dump.rdb').read_bytes()
                self.assertEqual(MARKER in keys, not encrypted)
                self.assertEqual(c.call(*SCOPE, 'FT.DROPINDEX', 'same'), 'OK')
                self.assertEqual(c.call(*TOP, 'DEBUG', 'RELOAD', 'NOSAVE'), 'OK')
                self.assertEqual(c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), dig)
                self.assertIn('secret', str(definition_info(c, 'same', SCOPE)))
                server.stop()
                c = self.up(server)
                self.assertEqual(c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), dig)
                for scope, field in ((SCOPE, 'secret'), (low, 'public'), (two, 'other')):
                    self.assertIn(field, str(definition_info(c, 'same', scope)))
                self.assertEqual(c.call(*own_only, 'FT._LIST'), ['metadata'])
                self.assertEqual(c.call(*own_only, 'DBSIZE'), 0)

    def test_plain_command_aof_rewrite_keeps_canonical_definitions(self):
        server = self.node(extra=LOG + ('--aof-use-rdb-preamble', 'no'))
        c = self.up(server)
        self.assertEqual(definition(c, 'first'), 'OK')
        expected = definition_info(c, 'first')
        self.assertEqual(simple(c, 'second'), 'OK')
        self.assertEqual(c.call('HSET', 'doc:1', 'body', 'text'), 1)
        rewrite(c)
        rows = sl.records(base_file(server.run.directory).read_bytes())
        self.assertEqual([row[:2] for row in rows[:2]], [[b'FT.CREATE', b'first'], [b'FT.CREATE', b'second']])
        self.assertTrue(any(row[0].upper() in (b'HSET', b'HMSET') for row in rows[2:]), rows)
        self.assertEqual(c.call('FT.DROPINDEX', 'second', 'DD'), 'OK')
        self.assertEqual(simple(c, 'after'), 'OK')
        with self.assertRaises(ServerError):
            simple(c, 'first')
        with self.assertRaises(ServerError):
            c.call('FT.DROPINDEX', 'absent')
        replay = sl.records(sl.last_incr(server.run.directory).read_bytes())
        effect = [row for row in replay if row[0].upper().startswith(b'FT.')]
        self.assertEqual(effect, [[b'FT.DROPINDEX', b'second', b'DD'], [b'FT.CREATE', b'after', b'SCHEMA', b'body', b'TEXT']])
        self.assertEqual(c.call('DEBUG', 'LOADAOF'), 'OK')
        self.assertEqual(c.call('FT._LIST'), ['after', 'first'])
        self.assertEqual(definition_info(c, 'first'), expected)
        server.stop()
        c = self.up(server)
        self.assertEqual(c.call('FT._LIST'), ['after', 'first'])
        self.assertEqual(definition_info(c, 'first'), expected)

    def test_scoped_aof_restart_rewrite_reload_flush(self):
        for encrypted in (False, True):
            with self.subTest(encrypted=encrypted):
                server = self.node('both', LOG + (self.key() if encrypted else ()) +
                                   ('--label-partitions-max', '2', '--owner-partitions-max', '2'))
                c = self.up(server)
                self.assertEqual(simple(c, 'first', SCOPE, 'secret'), 'OK')
                self.assertEqual(c.call(*SCOPE, 'HSET', 'doc:1', 'secret', 'text'), 1)
                other = sl.at('both', 'S//B', 'u1')
                self.assertEqual(simple(c, 'meta-only', other), 'OK')
                self.assertEqual(simple(c, 'flushed', sl.at('both', 'S//A', 'u2')), 'OK')
                rewrite(c, TOP)
                base = base_file(server.run.directory, 'rdb' if encrypted else None).read_bytes()
                self.assertEqual(MARKER in base, not encrypted)
                self.assertEqual(simple(c, 'from-incr', other), 'OK')
                another = sl.at('both', 'S//A', 'u1')
                self.assertEqual(simple(c, 'from-other-label', another), 'OK')
                self.assertEqual(c.call(*sl.at('both', 'S//A', 'u2'), 'FLUSHDB', 'SYNC'), 'OK')
                if not encrypted:
                    rows = sl.records(sl.last_incr(server.run.directory).read_bytes())
                    self.assertIn(((b'S//B', b'u1'), [b'FT.CREATE', b'from-incr', b'SCHEMA', b'body', b'TEXT']),
                                  [sl.scoped(row) for row in rows])
                dig = c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES')
                self.assertEqual(c.call(*TOP, 'DEBUG', 'LOADAOF'), 'OK')
                self.assertEqual(c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), dig)
                self.assertEqual(c.call(*other, 'FT._LIST'), ['from-incr', 'meta-only'])
                self.assertEqual(c.call(*sl.at('both', 'S//A', 'u2'), 'FT._LIST'), [])
                server.stop()
                c = self.up(server)
                self.assertEqual(c.call(*TOP, 'DEBUG', 'DIGEST-SCOPES'), dig)
                self.assertEqual(c.call(*another, 'FT._LIST'), ['first', 'from-other-label'])
                self.assertEqual(c.call(*other, 'DBSIZE'), 0)
                self.assertEqual(c.call(*SCOPE, 'HGET', 'doc:1', 'secret'), b'text')

    def test_scoped_incremental_at_partition_limit_and_wrong_scope(self):
        server = self.node('both', LOG + ('--owner-partitions-max', '1'))
        c = self.up(server)
        self.assertEqual(c.call(*SCOPE, 'HSET', 'doc:1', 'body', 'value'), 1)
        reader = sl.at('both', 'U', 'u1')
        before = c.call(*reader, 'INFO', 'persistence')
        side = sl.at('both', 'S//B', 'u1')
        self.assertEqual(c.call(*side, 'MULTI'), 'OK')
        self.assertEqual(simple(c, 'one'), 'QUEUED')
        self.assertEqual(simple(c, 'two'), 'QUEUED')
        self.assertEqual(c.call('EXEC'), ['OK', 'OK'])
        self.assertEqual(c.call(*side, 'FT.DROPINDEX', 'one', 'DD'), 'OK')
        self.assertEqual(c.call(*reader, 'INFO', 'persistence'), before)
        self.assertEqual(c.call(*TOP, 'DEBUG', 'LOADAOF'), 'OK')
        self.assertEqual(c.call(*side, 'FT._LIST'), ['two'])
        self.assertEqual(c.call(*SCOPE, 'HGET', 'doc:1', 'body'), b'value')
        server.stop()
        c = self.up(server)
        self.assertEqual(c.call(*side, 'FT._LIST'), ['two'])
        server.stop()
        incr = sl.last_incr(server.run.directory)
        rows = sl.records(incr.read_bytes())
        record = next(row for row in rows if sl.scoped(row)[1][0] == b'FT.DROPINDEX')
        self.assertEqual(record[4], b'u1')
        record[4] = b'u2'
        incr.write_bytes(sl.encode_records(rows))
        code, log = server.refused()
        self.assertEqual(code, 1, log)
        self.assertIn('the file and the data disagree about a scope', log)

    def test_malformed_rdb_and_wrong_access_mode(self):
        source = self.node(extra=('--rdbchecksum', 'no'))
        c = self.up(source)
        self.assertEqual(simple(c, 'alpha'), 'OK')
        self.assertEqual(c.call('SET', 'key', 'data'), 'OK')
        self.assertEqual(c.call('SAVE'), 'OK')
        raw = (source.run.directory / 'dump.rdb').read_bytes()
        start, end, fields = first_record(raw)
        copy_record = bytearray(raw[start:end])
        copy_record[fields[3][0] - start] = 2
        bad_values = [(0, b'\x01', 'placement or version'), (1, b'\x03', 'placement or version'),
                      (2, b'\x01', 'another access mode'), (3, b'\x00', 'invalid creation order'),
                      (6, b'\x81' + b'\xff' * 8, 'invalid argument count'),
                      (7, b'\x81' + b'\xff' * 8, 'invalid argument length')]
        cases = [(raw[:fields[i][0]] + value + raw[fields[i][0] + 1:], reason) for i, value, reason in bad_values]
        cases.extend([(raw[:end] + copy_record + raw[end:], 'duplicate search index'),
                      (raw[:start] + raw[end:-9] + raw[start:end] + raw[-9:], 'after the data records begin')])
        for malformed, reason in cases:
            with self.subTest(reason=reason):
                target = self.node()
                (target.run.directory / 'dump.rdb').write_bytes(malformed)
                code, log = target.refused()
                self.assertEqual(code, 1, log)
                self.assertIn(reason, log)
        scoped = self.node('both')
        c = self.up(scoped)
        self.assertEqual(simple(c, 'owner', SCOPE), 'OK')
        self.assertEqual(c.call(*TOP, 'SAVE'), 'OK')
        plain = self.node()
        shutil.copyfile(scoped.run.directory / 'dump.rdb', plain.run.directory / 'dump.rdb')
        code, log = plain.refused()
        self.assertEqual(code, 1, log)
        self.assertIn('holds data with labels or owners', log)
        self.assertEqual(c.call(*SCOPE, 'SET', 'scoped-key', 'keepers'), 'OK')
        (scoped.run.directory / 'dump.rdb').write_bytes(raw)
        with self.assertRaises(ServerError):
            c.call(*TOP, 'DEBUG', 'RELOAD', 'NOSAVE')
        self.assertEqual(c.call(*SCOPE, 'GET', 'scoped-key'), b'keepers')
        self.assertEqual(c.call(*SCOPE, 'FT._LIST'), ['owner'])
        if BASELINE:
            older = self.node(binary=BASELINE)
            (older.run.directory / 'dump.rdb').write_bytes(raw)
            code, log = older.refused()
            self.assertEqual(code, 1, log)
            self.assertIn('unknown module type', log)

    def test_malformed_search_alias_target_is_refused(self):
        source = self.node(extra=('--rdbchecksum', 'no'))
        c = self.up(source)
        self.assertEqual(simple(c, 'alpha'), 'OK')
        self.assertEqual(c.call('FT.ALIASADD', 'view', 'alpha'), 'OK')
        self.assertEqual(c.call('SAVE'), 'OK')
        raw = (source.run.directory / 'dump.rdb').read_bytes()
        _, definition_end, _ = first_record(raw)
        _, _, fields = first_record(raw[definition_end:])
        index = definition_end + fields[-1][1] - 1
        self.assertEqual(raw[index:index + 1], b'1')
        malformed = raw[:index] + b'9' + raw[index + 1:]
        target = self.node()
        (target.run.directory / 'dump.rdb').write_bytes(malformed)
        code, log = target.refused()
        self.assertEqual(code, 1, log)
        self.assertIn('search alias with an invalid target', log)

    def test_no_definitions_baseline_files_match(self):
        if not BASELINE:
            self.skipTest('pass --baseline to compare persisted files')
        snapshots = []
        logs = []
        for binary in (BASELINE, SERVER):
            ordinary = self.node(extra=('--rdbchecksum', 'no'), binary=binary)
            c = self.up(ordinary)
            self.assertEqual(c.call('HSET', 'key', 'field', 'value'), 1)
            self.assertEqual(c.call('SAVE'), 'OK')
            snapshots.append((ordinary.run.directory / 'dump.rdb').read_bytes())
            older = self.node(extra=LOG + ('--aof-use-rdb-preamble', 'no'), binary=binary)
            c = self.up(older)
            self.assertEqual(c.call('HSET', 'key', 'field', 'value'), 1)
            rewrite(c)
            logs.append(base_file(older.run.directory).read_bytes())
        self.assertNotIn(MARKER, snapshots[1])
        self.assertEqual(rdb_stable(snapshots[0]), rdb_stable(snapshots[1]))
        self.assertEqual(logs[0], logs[1])


def main():
    global SERVER, BASELINE
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', type=Path, default=SERVER)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--ports', default=os.getenv('ESKI_SEARCH_PORTS', ''))
    args, tests = parser.parse_known_args()
    SERVER = args.server.resolve()
    BASELINE = args.baseline.resolve() if args.baseline else None
    if args.ports:
        sl.use_ports(args.ports)
    unittest.main(argv=[sys.argv[0]] + tests)


if __name__ == '__main__':
    main()
