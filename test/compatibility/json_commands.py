import argparse
import itertools
import struct
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
import scoped_log as sl
from support import ServerError
from labelled_files import length, module_id, rdbcmp

BINARY = ROOT / 'bin/eski'
THREADS = 0
JSON_NAMES = {
    'arrappend', 'arrindex', 'arrinsert', 'arrlen', 'arrpop', 'arrtrim',
    'clear', 'debug', 'del', 'forget', 'get', 'merge', 'mget', 'mset',
    'numincrby', 'nummultby', 'numpowby', 'objkeys', 'objlen', 'resp',
    'set', 'strappend', 'strlen', 'toggle', 'type',
}
WRONG_TYPE = 'Existing key has wrong Redis type'


def pairs(value):
    return value if isinstance(value, dict) else dict(zip(value[::2], value[1::2]))


class JsonCommands(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='eski-json-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.next_server = 0

    def start(self, server):
        c = server.up()
        print('Eski PID', server.run.process.pid, 'port', server.run.port, flush=True)
        return c

    def server(self, mode='', extra=()):
        directory = self.root / str(self.next_server)
        self.next_server += 1
        directory.mkdir()
        server = sl.Server(BINARY, directory, mode, ('--save', '') + extra, THREADS)
        self.addCleanup(self.stop, server)
        return server, self.start(server)

    def stop(self, server):
        code = server.stop()
        log = server.run.log()
        self.assertIn(code, (None, 0), log)
        self.assertNotIn('AddressSanitizer', log)

    def error(self, c, prefix, *args):
        with self.assertRaises(ServerError) as result:
            c.call(*args)
        self.assertTrue(str(result.exception).startswith(prefix), str(result.exception))
        return str(result.exception)

    def test_module_metadata_and_acl_cover_every_key(self):
        server, c = self.server()
        expected = {('json.' + name).encode() for name in JSON_NAMES}
        for proto in (2, 3):
            c.call('HELLO', proto)
            self.assertEqual({pairs(entry)[b'name']: pairs(entry)[b'ver'] for entry in c.call('MODULE', 'LIST')}[b'ReJSON'], 81000)
            self.assertEqual(set(c.call('COMMAND', 'LIST', 'FILTERBY', 'MODULE', 'ReJSON')), expected)
            self.assertEqual(set(c.call('ACL', 'CAT', 'json')), expected)
            self.assertEqual(c.call('COMMAND', 'GETKEYS', 'JSON.MGET', 'a', 'b', '$'), [b'a', b'b'])
            self.assertEqual(c.call('COMMAND', 'GETKEYS', 'JSON.MSET', 'a', '$', '1', 'b'), [b'a', b'b'])
            self.assertEqual(c.call('COMMAND', 'GETKEYS', 'JSON.DEBUG', 'MEMORY', 'a', '$'), [b'a'])
            self.assertEqual(c.call('COMMAND', 'GETKEYS', 'JSON.DEBUG', 'HELP', 'MEMORY', 'b'), [b'b'])
            self.error(c, 'ERR Invalid arguments', 'COMMAND', 'GETKEYS', 'JSON.DEBUG', 'HELP')
        c.call('ACL', 'SETUSER', 'json-user', 'on', 'nopass', '+@json', '+multi', '+exec', '+eval', '%R~read:*', '%W~write:*')
        c.call('JSON.SET', 'read:a', '$', '1')
        user = server.client('json-user')
        self.assertEqual(user.call('JSON.MGET', 'read:a', 'read:b', '$'), [b'[1]', None])
        self.error(user, 'NOPERM', 'JSON.MGET', 'read:a', 'write:b', '$')
        self.error(user, 'NOPERM', 'JSON.DEBUG', 'MEMORY', 'write:b')
        self.assertEqual(user.call('JSON.MSET', 'write:a', '$', '2', 'write:b', '$', '3'), 'OK')
        self.error(user, 'NOPERM', 'JSON.MSET', 'write:a', '$', '4', 'read:a', '$', '5')
        self.assertEqual(c.call('JSON.GET', 'write:a'), b'2')
        self.assertEqual(user.call('MULTI'), 'OK')
        self.error(user, 'NOPERM', 'JSON.MGET', 'read:a', 'write:b', '$')
        self.error(user, 'EXECABORT', 'EXEC')
        self.error(user, 'ERR', 'EVAL', "return redis.call('JSON.MGET','read:a','write:b','$')", 0)

    def test_generic_lifecycle_and_expiry(self):
        _, c = self.server()
        replies = c.pipeline([
            ('JSON.SET', 'src', '$', '{"a":[1,2],"b":3}'),
            ('TYPE', 'src'),
            ('OBJECT', 'ENCODING', 'src'),
            ('OBJECT', 'REFCOUNT', 'src'),
            ('GET', 'src'),
            ('COPY', 'src', 'dst'),
            ('JSON.SET', 'dst', '$.a[0]', '5'),
            ('JSON.GET', 'src'),
        ])
        self.assertEqual(replies[:4], ['OK', 'ReJSON-RL', b'raw', 1])
        self.assertIsInstance(replies[4], ServerError)
        self.assertEqual(replies[5:], [1, 'OK', b'{"a":[1,2],"b":3}'])
        self.error(c, 'WRONGTYPE', 'GET', 'src')
        self.assertEqual(c.call('SCAN', 0, 'TYPE', 'rejson-rl'), [b'0', c.call('SCAN', 0, 'TYPE', 'ReJSON-RL')[1]])
        self.assertEqual(set(c.call('SCAN', 0, 'TYPE', 'ReJSON-RL')[1]), {b'src', b'dst'})
        self.assertEqual(c.call('SCAN', 0, 'TYPE', 'json')[1], [])
        at = 4102444800000
        self.assertEqual(c.call('PEXPIREAT', 'dst', at), 1)
        self.assertEqual(c.call('JSON.SET', 'dst', '$', '[5,2]'), 'OK')
        self.assertEqual(c.call('RENAME', 'dst', 'renamed'), 'OK')
        self.assertEqual(c.call('MOVE', 'renamed', 1), 1)
        self.assertEqual(c.call('SWAPDB', 0, 1), 'OK')
        self.assertEqual(c.call('JSON.GET', 'renamed'), b'[5,2]')
        self.assertEqual(c.call('PEXPIRETIME', 'renamed'), at)
        self.assertEqual(c.call('PEXPIREAT', 'renamed', 1), 1)
        self.assertIsNone(c.call('JSON.GET', 'renamed'))
        self.assertEqual(c.call('SELECT', 1), 'OK')
        self.assertEqual(c.call('JSON.GET', 'src'), b'{"a":[1,2],"b":3}')
        self.assertEqual(c.call('UNLINK', 'src'), 1)
        self.assertEqual(c.call('JSON.SET', 'tree', '$', '[' + ','.join('1' for _ in range(2048)) + ']'), 'OK')
        self.assertEqual(c.call('FLUSHALL', 'ASYNC'), 'OK')
        self.assertEqual(c.call('DBSIZE'), 0)

    def test_validation_and_applied_prefix(self):
        _, c = self.server()
        c.call('SET', 'wrong', 'untouched')
        c.call('JSON.SET', 'root', '$', '{"a":1}')
        self.error(c, 'expected value', 'JSON.MSET', 'fresh', '$', '2', 'root', '$', 'bad')
        self.error(c, WRONG_TYPE, 'JSON.MSET', 'fresh', '$', '2', 'wrong', '$', '3')
        self.error(c, 'ERR new objects', 'JSON.MSET', 'fresh', '$', '{}', 'fresh', '$.a', '3')
        self.error(c, 'ERR wrong number', 'JSON.MSET', 'fresh', '$', '2', 'root')
        self.assertEqual(c.call('JSON.GET', 'root'), b'{"a":1}')
        self.assertEqual(c.call('EXISTS', 'fresh'), 0)
        self.assertIsNone(c.call('JSON.MSET', 'root', '$.absent.child', '2', 'fresh', '$', '3'))
        self.assertEqual(c.call('JSON.MGET', 'fresh', 'wrong', 'root', '$'), [b'[3]', None, b'[{"a":1}]'])
        self.assertEqual(c.call('JSON.MSET', '', '$', '4', '', '$', '5'), 'OK')
        self.assertEqual(c.call('JSON.GET', ''), b'5')
        c.call('JSON.SET', 'overflow', '$', '[1,9223372036854775807]')
        self.error(c, 'ERR numeric overflow', 'JSON.NUMINCRBY', 'overflow', '$[*]', '1')
        self.assertEqual(c.call('JSON.GET', 'overflow'), b'[2,9223372036854775807]')
        c.call('JSON.SET', 'clear', '$', '{"a":{"a":[1]}}')
        self.error(c, 'ERR Path does not exist', 'JSON.CLEAR', 'clear', '$..a')
        self.assertEqual(c.call('JSON.GET', 'clear'), b'{"a":{}}')
        self.assertEqual(c.call('JSON.DEL', 'clear', '$.a'), 1)
        self.assertIsNone(c.call('JSON.GET', 'clear'))

    def test_scoped_hidden_twins_and_foreign_writes(self):
        for mode in ('labels', 'owners', 'both'):
            with self.subTest(mode=mode):
                _, hidden = self.server(mode)
                _, absent = self.server(mode)
                low_label = sl.MODES[mode]['low']
                high_label = sl.MODES[mode]['top']
                low = sl.at(mode, low_label, 'reader')
                private = sl.at(mode, high_label, 'private')
                visible = sl.at(mode, high_label, 'reader')
                hidden.call(*private, 'JSON.SET', 'same', '$', '{"secret":[1,2,3]}')
                hidden.call(*private, 'SET', 'wrong', 'secret')
                pair = sl.Pair(hidden, absent)
                self.assertEqual(pair.call(*low, 'JSON.MGET', 'same', 'wrong', '$'), [None, None])
                self.assertEqual(pair.call(*low, 'JSON.DEBUG', 'MEMORY', 'same'), 0)
                self.assertEqual(pair.call(*low, 'JSON.DEL', 'same', '$'), 0)
                self.assertEqual(pair.error(*low, 'JSON.MSET', 'fresh', '$', '1', 'same', '$.secret', '2'), 'ERR new objects must be created at the root')
                self.assertEqual(pair.call(*low, 'JSON.MSET', 'same', '$', '{}', 'wrong', '$', '1'), 'OK')
                self.assertEqual(pair.call(*low, 'JSON.SET', 'same', '$.arr', '[1,2]'), 'OK')
                self.assertEqual(pair.call(*low, 'JSON.GET', 'same'), b'{"arr":[1,2]}')
                self.assertGreater(pair.call(*low, 'MEMORY', 'USAGE', 'same'), 0)
                self.assertEqual(pair.call(*low, 'COPY', 'same', 'copy'), 1)
                self.assertEqual(pair.call(*low, 'JSON.GET', 'copy'), b'{"arr":[1,2]}')
                if mode != 'owners':
                    self.assertEqual(pair.call(*visible, 'JSON.GET', 'copy'), b'{"arr":[1,2]}')
                    self.assertTrue(pair.error(*visible, 'JSON.MSET', 'fresh', '$', '1', 'copy', '$', '0').startswith('INUSE name in use at '))
                    self.assertIsNone(pair.call(*visible, 'JSON.SET', 'copy', '$', '0', 'NX'))
                    self.assertIsNone(pair.call(*visible, 'JSON.GET', 'fresh'))
                self.assertEqual(pair.call(*low, 'FLUSHDB'), 'OK')
                self.assertIsNone(pair.call(*low, 'JSON.GET', 'same'))
                self.assertEqual(hidden.call(*private, 'JSON.GET', 'same'), b'{"secret":[1,2,3]}')

    def test_watches_tracking_and_notification_order(self):
        server, c = self.server()
        c.call('JSON.MSET', 'a', '$', '{"v":1}', 'b', '$', '{}')
        watcher = server.client()
        tracker = server.client()
        tracker.call('HELLO', 3)
        tracker.call('CLIENT', 'TRACKING', 'ON')
        self.assertEqual(tracker.call('JSON.MGET', 'a', 'b', '$'), [b'[{"v":1}]', b'[{}]'])
        watcher.call('WATCH', 'b')
        self.assertIsNone(c.call('JSON.SET', 'b', '$.missing', '1', 'XX'))
        watcher.call('MULTI')
        watcher.call('PING')
        self.assertIsNone(watcher.call('EXEC'))
        self.assertEqual(tracker.call('PING'), 'PONG')
        self.assertEqual(tracker.pushes, [[b'invalidate', [b'b']]])
        c.call('CONFIG', 'SET', 'notify-keyspace-events', 'Edg')
        events = server.client()
        events.call('PSUBSCRIBE', '__keyevent@0__:*')
        watcher.call('WATCH', 'a')
        self.error(c, 'expected value', 'JSON.SET', 'a', '$', 'bad')
        watcher.call('MULTI')
        watcher.call('PING')
        self.assertIsNone(watcher.call('EXEC'))
        tracker.call('PING')
        self.assertEqual(tracker.pushes[-1], [b'invalidate', [b'a']])
        previous = len(tracker.pushes)
        tracker.call('JSON.DEBUG', 'MEMORY', 'a')
        c.call('JSON.SET', 'a', '$.v', '2')
        tracker.call('PING')
        self.assertEqual(len(tracker.pushes), previous)
        self.assertEqual(events.read()[-2:], [b'__keyevent@0__:json.set', b'a'])
        c.call('JSON.MSET', 'a', '$.v', '2', 'b', '$', 'false', 'a', '$.v', '3')
        c.call('DEL', 'a')
        expected = [(b'json.mset', b'a'), (b'json.mset', b'b'), (b'json.mset', b'a'), (b'del', b'a')]
        for event, key in expected:
            self.assertEqual(events.read(), [b'pmessage', b'__keyevent@0__:*', b'__keyevent@0__:' + event, key])

    def test_script_replies_and_memory_admission(self):
        _, c = self.server()
        c.call('JSON.SET', 'doc', '$', '{"a":[1],"n":1}')
        self.assertEqual(c.call('EVAL', "return redis.call('JSON.TYPE',KEYS[1],'$.*')", 1, 'doc'), [b'array', b'integer'])
        self.assertEqual(c.call('EVAL', "redis.setresp(3);return redis.call('JSON.TYPE',KEYS[1],'$.*')", 1, 'doc'), [[b'array', b'integer']])
        self.error(c, 'ERR', 'EVAL_RO', "return redis.call('JSON.SET',KEYS[1],'$','1')", 1, 'doc')
        initial = c.call('MEMORY', 'USAGE', 'doc')
        c.call('JSON.SET', 'doc', '$.payload', '"' + ('a' * 8192) + '"')
        self.assertGreaterEqual(c.call('MEMORY', 'USAGE', 'doc') - initial, 8192)
        c.call('CONFIG', 'SET', 'maxmemory-policy', 'noeviction', 'maxmemory', 1)
        for command in (('JSON.SET', 'doc', '$', '1'), ('JSON.MERGE', 'doc', '$', '{}'), ('JSON.MSET', 'doc', '$', '1'),
                        ('JSON.ARRAPPEND', 'doc', '$.a', 1), ('JSON.ARRINSERT', 'doc', '$.a', 0, 1), ('JSON.STRAPPEND', 'doc', '$.payload', '"x"')):
            self.error(c, 'OOM', *command)
        self.assertEqual(c.call('JSON.NUMINCRBY', 'doc', '.n', 1), b'2')
        self.assertEqual(c.call('JSON.DEL', 'doc', '$.payload'), 1)
        self.assertEqual(c.call('JSON.GET', 'doc'), b'{"a":[1],"n":2}')
        c.call('CONFIG', 'SET', 'maxmemory-policy', 'allkeys-random')
        self.assertEqual(c.call('DBSIZE'), 0)

    def test_global_maxmemory_uses_live_json_allocations(self):
        _, c = self.server()

        def used():
            info = dict(row.split(b':', 1) for row in c.call('INFO', 'memory').splitlines() if b':' in row)
            return int(info[b'used_memory'])

        initial = used()
        c.call('JSON.SET', 'heap', '$', '[' + ','.join(['1'] * 8192) + ']')
        logical = c.call('JSON.DEBUG', 'MEMORY', 'heap')
        real = c.call('MEMORY', 'USAGE', 'heap')
        self.assertGreater(real, logical * 2)
        self.assertGreater(used() - initial, logical * 2)
        budget = initial + logical * 2
        c.call('CONFIG', 'SET', 'maxmemory-policy', 'noeviction', 'maxmemory', budget)
        self.error(c, 'OOM', 'JSON.SET', 'write', '$', '{}')
        self.assertEqual(c.call('JSON.DEL', 'heap'), 1)
        self.assertEqual(c.call('JSON.SET', 'write', '$', '{}'), 'OK')

    def test_incremental_aof_replays_partial_effects(self):
        for mode in ('', 'both'):
            with self.subTest(mode=mode):
                server, c = self.server(mode, sl.LOG)
                prefix = sl.at(mode, 'U', 'writer') if mode else ()
                c.call(*prefix, 'JSON.SET', 'one', '$', '[1, 9223372036854775807]')
                self.error(c, 'ERR numeric overflow', *prefix, 'JSON.NUMINCRBY', 'one', '$[*]', '1')
                self.assertEqual(c.call(*prefix, 'JSON.GET', 'one'), b'[2,9223372036854775807]')
                c.call(*prefix, 'JSON.SET', 'clear', '$', '{"a":{"a":[1]}}')
                self.error(c, 'ERR Path does not exist', *prefix, 'JSON.CLEAR', 'clear', '$..a')
                c.call(*prefix, 'JSON.MSET', 'two', '$', 'false', 'three', '$', '[]')
                self.assertIsNone(c.call(*prefix, 'JSON.SET', 'two', '$', 'null', 'NX'))
                if not mode:
                    c.call('EVAL', "redis.call('JSON.ARRAPPEND', KEYS[1], '$', '3'); return redis.call('JSON.ARRAPPEND', KEYS[1], '$', '4')", 1, 'three')
                rows = [sl.scoped(row)[1] for row in sl.records(sl.last_incr(server.run.directory).read_bytes())]
                self.assertIn([b'JSON.SET', b'one', b'$', b'[1, 9223372036854775807]'], rows)
                self.assertIn([b'JSON.NUMINCRBY', b'one', b'$[*]', b'1'], rows)
                self.assertIn([b'JSON.CLEAR', b'clear', b'$..a'], rows)
                self.assertFalse(any(row[-1] == b'NX' for row in rows))
                self.stop(server)
                c = self.start(server)
                self.assertEqual(c.call(*prefix, 'JSON.MGET', 'one', 'clear', 'two', 'three', '.'),
                                 [b'[2,9223372036854775807]', b'{"a":{}}', b'false', b'[]' if mode else b'[3,4]'])

    def test_native_snapshot_dump_restore_and_migrate(self):
        server, c = self.server()
        target, to = self.server()
        doc = '{"n":[1,18446744073709551615,1.0,-0.0],"esc":"\\u03b1\\u0000","o":{"b":2,"a":1}}'
        self.assertEqual(c.call('JSON.SET', 'doc', '$', doc), 'OK')
        self.assertEqual(c.call('JSON.SET', 'doc', '$.half', '[1.1,2,-0.0]', 'FPHA', 'FP16'), 'OK')
        self.assertEqual(c.call('PEXPIREAT', 'doc', sl.FAR), 1)
        before = c.call('JSON.GET', 'doc')
        kinds = c.call('JSON.TYPE', 'doc', '$.n[*]')
        self.assertEqual(kinds, [b'integer', b'integer', b'number', b'number'])
        digest = c.call('DEBUG', 'DIGEST')
        payload = c.call('DUMP', 'doc')
        marker = b'\x07' + length(module_id('EskiJSON_', 1))
        self.assertTrue(payload.startswith(marker))
        self.assertEqual(c.call('RESTORE', 'doc', sl.FAR, payload, 'REPLACE', 'ABSTTL'), 'OK')
        self.assertEqual(c.call('DEBUG', 'DIGEST'), digest)
        self.assertEqual(c.call('DUMP', 'doc'), payload)
        self.assertEqual(c.call('SAVE'), 'OK')
        self.assertIn(marker[1:], (server.run.directory / 'dump.rdb').read_bytes())
        self.assertEqual(c.call('DEBUG', 'RELOAD', 'NOSAVE'), 'OK')
        self.assertEqual(c.call('DUMP', 'doc'), payload)
        self.assertEqual(c.call('MIGRATE', '127.0.0.1', target.run.port, 'doc', 0, 5000, 'COPY'), 'OK')
        self.assertEqual(to.call('DUMP', 'doc'), payload)
        self.stop(server)
        c = self.start(server)
        self.assertEqual(c.call('JSON.GET', 'doc'), before)
        self.assertEqual(c.call('JSON.TYPE', 'doc', '$.n[*]'), kinds)
        self.assertEqual(c.call('PEXPIRETIME', 'doc'), sl.FAR)
        self.assertEqual(c.call('DEBUG', 'DIGEST'), digest)

    def test_malformed_native_payloads_are_refused_before_replace(self):
        server, c = self.server(extra=('--shutdown-on-sigterm', 'nosave'))
        c.call('JSON.SET', 'keep', '$', '{"value":17}')
        before = c.call('DUMP', 'keep')
        version = before[-10:-8]
        module = module_id('EskiJSON_', 1)

        def size(n):
            return struct.pack('<q', n)

        def native(tree, *, ident=module, opcode=b'\x05', end=b'\0', count=None):
            return b'\x07' + length(ident) + opcode + length(len(tree) if count is None else count) + tree + end

        scalar = native(b'\0')
        name = size(1) + b'x'
        cases = {
            'version': native(b'\0', ident=module + 1),
            'opcode': native(b'\0', opcode=b'\xc5'),
            'read past payload': native(b'\0', count=1000),
            'extra native bytes': native(b'\0\0'),
            'extra module bytes': scalar + b'X',
            'missing terminator': native(b'\0', end=b''),
            'wrong terminator': native(b'\0', end=b'\x01'),
            'empty tree': native(b''),
            'unknown tag': native(b'\x0f'),
            'unknown format': native(b'\xf7' + size(0)),
            'narrow on integer': native(b'\x13' + size(1)),
            'noncanonical unsigned': native(b'\x04' + size(1)),
            'nonfinite double': native(b'\x05' + struct.pack('<d', float('inf'))),
            'nonrepresentable f16': native(b'\x15' + struct.pack('<d', 1.1)),
            'negative string length': native(b'\x06' + size(-1)),
            'invalid text': native(b'\x06' + size(1) + b'\xff'),
            'oversize array': native(b'\x07' + size(1 << 24 | 1) + b'\0'),
            'truncated object': native(b'\x08' + size(1) + size(3) + b'x'),
            'duplicate member': native(b'\x08' + size(2) + name + b'\0' + name + b'\0'),
            'excessive depth': native((b'\x07' + size(1)) * 128 + b'\0'),
        }
        for name, invalid in cases.items():
            with self.subTest(name=name):
                body = invalid + version
                payload = body + rdbcmp.crc64(body).to_bytes(8, 'little')
                self.error(c, 'ERR Bad data format', 'RESTORE', 'keep', 0, payload, 'REPLACE')
                self.assertEqual(c.call('DUMP', 'keep'), before)
        bad_crc = before[:-1] + bytes([before[-1] ^ 1])
        self.error(c, 'ERR DUMP payload', 'RESTORE', 'keep', 0, bad_crc, 'REPLACE')
        self.assertEqual(c.call('PING'), 'PONG')

        self.assertEqual(c.call('SAVE'), 'OK')
        self.stop(server)
        snapshot = server.run.directory / 'dump.rdb'
        original = snapshot.read_bytes()
        module_prefix = length(module)
        position = original.index(module_prefix) + len(module_prefix)
        damaged = original[:position] + b'\x06' + original[position + 1:-8]
        snapshot.write_bytes(damaged + rdbcmp.crc64(damaged).to_bytes(8, 'little'))
        status, log = server.refused()
        self.assertEqual(status, 1)
        self.assertIn('invalid Eski JSON module payload', log)
        snapshot.write_bytes(original)
        c = self.start(server)
        self.assertEqual(c.call('DUMP', 'keep'), before)

    def test_command_and_snapshot_aof_rewrite_preserve_exact_native_values(self):
        key = self.root / 'aof-key'
        key.write_text(bytes(range(32)).hex() + '\n')
        key.chmod(0o600)
        for preamble, sealed in itertools.product(('yes', 'no'), (False, True)):
            with self.subTest(preamble=preamble, sealed=sealed):
                extra = ('--encryption-key-file', str(key)) if sealed else ()
                server, c = self.server(extra=('--aof-use-rdb-preamble', preamble, '--appendfsync', 'always',
                                               '--auto-aof-rewrite-percentage', '0', '--shutdown-on-sigterm', 'nosave') + extra)
                c.call('JSON.SET', 'ordinary', '$', '{"keep":1,"n":[-0.0,1.0,18446744073709551615]}')
                c.call('JSON.SET', 'narrow', '$', '{"v":[1.5,2,0.1],"untouched":[]}', 'FPHA', 'FP32')
                c.call('JSON.SET', 'narrow', '$.v[1]', '3')
                c.call('PEXPIREAT', 'narrow', sl.FAR)
                c.call('JSON.SET', 'partial', '$', '[3,9223372036854775807]')
                narrow = c.call('DUMP', 'narrow')
                ordinary = c.call('DUMP', 'ordinary')
                c.call('CONFIG', 'SET', 'appendonly', 'yes')

                def status():
                    return dict(line.split(':', 1) for line in c.call('INFO', 'persistence').decode().splitlines() if ':' in line)

                sl.wait_for(lambda: status()['aof_rewrite_in_progress'] == '0' and status()['aof_rewrite_scheduled'] == '0',
                            what='initial JSON base')
                self.assertEqual(status()['aof_last_bgrewrite_status'], 'ok')
                self.assertEqual(c.call('BGREWRITEAOF'), 'Background append only file rewriting started')
                self.error(c, 'ERR numeric overflow', 'JSON.NUMINCRBY', 'partial', '$[*]', '1')
                c.call('JSON.SET', 'increment', '$', '{"extra": 1}')
                sl.wait_for(lambda: status()['aof_rewrite_in_progress'] == '0', what='JSON base rewrite')
                self.assertEqual(status()['aof_last_bgrewrite_status'], 'ok')
                folder = sl.log_dir(server.run.directory)
                manifest = folder / 'appendonly.aof.manifest'
                if sealed:
                    extension = 'rdb' if preamble == 'yes' else 'aof'
                    base = max(folder.glob('*.base.' + extension), key=lambda path: int(path.name.split('.')[2]))
                    self.assertTrue(base.read_bytes().startswith(b'ESKIENC1'))
                    self.assertTrue(manifest.read_bytes().startswith(b'ESKIENC1'))
                    self.assertNotIn(b'ordinary', base.read_bytes())
                else:
                    base = next(line.split()[1] for line in manifest.read_text().splitlines() if line.endswith('type b'))
                    if preamble == 'no':
                        rows = sl.records((folder / base).read_bytes())
                        self.assertIn([b'JSON.SET', b'ordinary', b'$', b'{"keep":1,"n":[-0.0,1.0,18446744073709551615]}'], rows)
                        self.assertIn([b'RESTORE', b'narrow', b'0', narrow], rows)
                        self.assertIn([b'PEXPIREAT', b'narrow', str(sl.FAR).encode()], rows)
                    else:
                        self.assertTrue((folder / base).read_bytes().startswith(b'REDIS'))
                self.assertEqual(c.call('DEBUG', 'LOADAOF'), 'OK')
                self.assertEqual(c.call('DUMP', 'ordinary'), ordinary)
                self.assertEqual(c.call('DUMP', 'narrow'), narrow)
                self.assertEqual(c.call('PEXPIRETIME', 'narrow'), sl.FAR)
                self.assertEqual(c.call('JSON.GET', 'partial'), b'[4,9223372036854775807]')
                self.stop(server)
                server.run.arguments += ['--appendonly', 'yes']
                c = self.start(server)
                self.assertEqual(c.call('DUMP', 'narrow'), narrow)
                self.assertEqual(c.call('JSON.GET', 'increment'), b'{"extra":1}')
                self.assertEqual(c.call('JSON.GET', 'partial'), b'[4,9223372036854775807]')

    def test_scoped_sealed_snapshot_and_aof_keep_json_and_digest(self):
        key = self.root / 'key'
        key.write_text(bytes(range(32)).hex() + '\n')
        key.chmod(0o600)
        for encrypted in (False, True):
            with self.subTest(encrypted=encrypted):
                options = ('--encryption-key-file', str(key)) if encrypted else ()
                server, c = self.server('both', options)
                top = sl.top('both')
                public = sl.at('both', 'U', 'member')
                hidden = sl.at('both', 'C//A', 'other')
                c.call(*public, 'JSON.SET', 'same', '$', '{"n":[1.0,-0.0],"text":"visible"}', 'FPHA', 'FP32')
                c.call(*hidden, 'JSON.SET', 'same', '$', '{"text":"private"}')
                c.call(*public, 'PEXPIREAT', 'same', sl.FAR)
                c.call(*public, 'FT.CREATE', 'json', 'ON', 'JSON', 'SCHEMA', '$.text', 'AS', 'text', 'TEXT')
                saved = c.call(*top, 'DEBUG', 'DIGEST-SCOPES')
                self.assertEqual(c.call(*top, 'SAVE'), 'OK')
                file = (server.run.directory / 'dump.rdb').read_bytes()
                self.assertEqual(file.startswith(b'ESKIENC1'), encrypted)
                self.assertEqual(b'private' in file, not encrypted)
                self.assertEqual(c.call(*top, 'DEBUG', 'RELOAD', 'NOSAVE'), 'OK')
                self.assertEqual(c.call(*top, 'DEBUG', 'DIGEST-SCOPES'), saved)
                self.assertEqual(c.call(*top, 'BGREWRITEAOF'), 'Background append only file rewriting started')
                sl.wait_for(lambda: b'aof_rewrite_in_progress:0' in c.call(*top, 'INFO', 'persistence'))
                self.assertIn(b'aof_last_bgrewrite_status:ok', c.call(*top, 'INFO', 'persistence'))
                self.assertEqual(c.call(*top, 'DEBUG', 'LOADAOF'), 'OK')
                self.assertEqual(c.call(*top, 'DEBUG', 'DIGEST-SCOPES'), saved)
                self.stop(server)
                c = self.start(server)
                self.assertEqual(c.call(*top, 'DEBUG', 'DIGEST-SCOPES'), saved)
                self.assertEqual(c.call(*public, 'PEXPIRETIME', 'same'), sl.FAR)
                self.assertEqual(c.call(*public, 'FT.SEARCH', 'json', '@text:visible', 'NOCONTENT'), [1, b'same'])
                self.assertEqual(c.call(*hidden, 'JSON.GET', 'same'), b'{"text":"private"}')


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
