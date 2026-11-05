import argparse
import fnmatch
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Client, Server, ServerError, info, wait_for

BINARY = ROOT / 'bin/eski'
REFERENCE_PORT = None
KEYSPACE_THREADS = 0


class ConfiguredServer(Server):
    def start(self):
        self.configuration = self.directory / 'server.conf'
        if not self.configuration.exists():
            self.configuration.write_text('save ""\nappendonly no\n')
        self.log = (self.directory / 'server.log').open('ab')
        command = [str(self.binary), str(self.configuration), '--bind', '127.0.0.1',
                   '--port', str(self.port), '--dir', str(self.directory),
                   '--enable-debug-command', 'yes', '--enable-protected-configs', 'yes',
                   '--compute-threads', '0', '--keyspace-threads', str(KEYSPACE_THREADS)]
        self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=self.log,
                                        stderr=subprocess.STDOUT, start_new_session=True)
        def ready():
            if self.process.poll() is not None:
                raise AssertionError('configured server exited: ' + (self.directory / 'server.log').read_text())
            try:
                client = Client(self.port, timeout=.2)
                try:
                    return client.call('PING') == 'PONG'
                finally:
                    client.close()
            except (OSError, EOFError):
                return False
        wait_for(ready, timeout=15, label='configured server readiness')
        return self


class Compatibility(unittest.TestCase):
    def setUp(self):
        if REFERENCE_PORT is None:
            self.server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS)))
            self.addCleanup(self.server.close)
            self.server.start()
            self.port = self.server.port
        else:
            self.port = REFERENCE_PORT
        self.client = self.connection()
        self.client.call('FLUSHALL')

    def connection(self):
        client = Client(self.port)
        self.addCleanup(client.close)
        return client

    def dirty(self):
        return int(info(self.client, 'persistence')['rdb_changes_since_last_save'])

    def blocked(self):
        return int(info(self.client, 'clients')['blocked_clients'])

    def fields(self, name):
        rows = self.client.call('CLIENT', 'LIST').decode().splitlines()
        for row in rows:
            fields = dict(item.split('=', 1) for item in row.split())
            if fields.get('name') == name:
                return fields
        self.fail('named client disappeared: ' + name)

    def qcapacity(self, name):
        fields = self.fields(name)
        return int(fields['qbuf']) + int(fields['qbuf-free'])

    def test_restore_huge_sorted_set_count_rejects_without_allocating_count(self):
        sys.path.insert(0, str(ROOT / 'test/rdb'))
        from rdbcmp import crc64
        self.client.call('SET', 'restore-target', 'retained')
        version = self.client.call('DUMP', 'restore-target')[-10:-8]
        before = self.dirty()
        for kind in (3, 5):
            for count in (1 << 40, (1 << 64) - 2):
                body = bytes((kind, 0x81)) + count.to_bytes(8, 'big') + version
                payload = body + crc64(body).to_bytes(8, 'little')
                with self.assertRaises(ServerError):
                    self.client.call('RESTORE', 'restore-target', 0, payload, 'REPLACE')
                self.assertEqual(self.client.call('GET', 'restore-target'), b'retained')
                self.assertEqual(self.client.call('PING'), 'PONG')
                self.assertEqual(self.dirty(), before)

    def test_zadd_incr_and_zincrby_publish_increment_events(self):
        self.client.call('CONFIG', 'SET', 'notify-keyspace-events', 'Ez')
        listener = self.connection()
        self.assertEqual(listener.call('PSUBSCRIBE', '__keyevent@0__:*')[0], b'psubscribe')
        for command, event in ((('ZADD', 'event-zset', 1, 'member'), b'zadd'),
                               (('ZADD', 'event-zset', 'INCR', 2, 'member'), b'zincr'),
                               (('ZINCRBY', 'event-zset', 2, 'member'), b'zincr')):
            self.client.call(*command)
            self.assertEqual(listener.read(), [b'pmessage', b'__keyevent@0__:*',
                                             b'__keyevent@0__:' + event, b'event-zset'])

    def test_config_rewrite_survives_restart(self):
        server = ConfiguredServer(BINARY, workers=0)
        self.addCleanup(server.close)
        server.start()
        client = server.client()
        client.call('CONFIG', 'SET', 'save', '120 3')
        client.call('CONFIG', 'SET', 'maxmemory', 8000000)
        client.call('CONFIG', 'SET', 'hz', 20)
        self.assertEqual(client.call('CONFIG', 'REWRITE'), 'OK')
        server.stop()
        server.start()
        client = server.client()
        self.assertEqual(client.call('CONFIG', 'GET', 'save')[1], b'120 3')
        self.assertEqual(client.call('CONFIG', 'GET', 'maxmemory')[1], b'8000000')
        self.assertEqual(client.call('CONFIG', 'GET', 'hz')[1], b'20')

    def test_maxclients_refusal_and_recovery(self):
        server = Server(BINARY, workers=0, arguments=('--maxclients', '3'))
        self.addCleanup(server.close)
        server.start()
        clients = [server.client() for unused in range(3)]
        for client in clients:
            self.assertEqual(client.call('PING'), 'PONG')
        rejected = server.client()
        try:
            rejected.send('PING')
            reply = rejected.reply()
        except (EOFError, OSError):
            reply = None
        self.assertTrue(reply is None or isinstance(reply, ServerError))
        clients[0].close()
        wait_for(lambda: int(info(clients[1], 'clients')['connected_clients']) == 2,
                 label='closed client releases connection limit')
        replacement = server.client()
        self.assertEqual(replacement.call('PING'), 'PONG')

    def test_migrate_copy_replace_auth_and_ttl(self):
        destination = Server(BINARY, workers=0)
        self.addCleanup(destination.close)
        destination.start()
        target = Client(destination.port)
        self.addCleanup(target.close)
        target.call('CONFIG', 'SET', 'requirepass', 'migration-secret')
        target.call('AUTH', 'migration-secret')
        target.call('SELECT', 5)
        self.client.call('SET', 'migration-key', 'original', 'PX', 10000)
        arguments = ('MIGRATE', '127.0.0.1', destination.port, 'migration-key', 5, 1000)
        self.assertEqual(self.client.call(*arguments, 'COPY', 'AUTH', 'migration-secret'), 'OK')
        self.assertEqual(self.client.call('GET', 'migration-key'), b'original')
        self.assertEqual(target.call('GET', 'migration-key'), b'original')
        self.assertGreater(target.call('PTTL', 'migration-key'), 0)
        self.client.call('SET', 'migration-key', 'replacement')
        self.client.send(*arguments, 'AUTH', 'migration-secret')
        self.assertIsInstance(self.client.reply(), ServerError)
        self.assertEqual(self.client.call('GET', 'migration-key'), b'replacement')
        self.assertEqual(self.client.call(*arguments, 'REPLACE', 'AUTH', 'migration-secret'), 'OK')
        self.assertIsNone(self.client.call('GET', 'migration-key'))
        self.assertEqual(target.call('GET', 'migration-key'), b'replacement')
        self.assertEqual(target.call('PTTL', 'migration-key'), -1)

    def test_migrate_multiple_keys_preserves_types_and_missing_keys(self):
        destination = Server(BINARY, workers=0)
        self.addCleanup(destination.close)
        destination.start()
        target = destination.client()
        self.client.call('HSET', 'migrate-hash', 'field', 'value')
        self.client.call('LPUSH', 'migrate-list', 'a', 'b')
        self.assertEqual(self.client.call('MIGRATE', '127.0.0.1', destination.port, '', 0, 1000,
                                         'KEYS', 'migrate-hash', 'absent-key', 'migrate-list'), 'OK')
        self.assertEqual(target.call('HGET', 'migrate-hash', 'field'), b'value')
        self.assertEqual(target.call('LRANGE', 'migrate-list', 0, -1), [b'b', b'a'])
        self.assertEqual(self.client.call('EXISTS', 'migrate-hash', 'migrate-list'), 0)
        self.assertEqual(self.client.call('MIGRATE', '127.0.0.1', destination.port, '', 0, 1000,
                                         'KEYS', 'absent-key'), 'NOKEY')

    def test_runtime_network_rebind_and_failed_change_rollback(self):
        if REFERENCE_PORT is not None:
            self.skipTest('requires ownership of listener lifecycle')
        with socket.socket() as reserved:
            reserved.bind(('127.0.0.1', 0))
            occupied_port = reserved.getsockname()[1]
            self.client.send('CONFIG', 'SET', 'port', occupied_port)
            self.assertIsInstance(self.client.reply(), ServerError)
            original = self.connection()
            self.assertEqual(original.call('PING'), 'PONG')
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            new_port = probe.getsockname()[1]
        self.assertEqual(self.client.call('CONFIG', 'SET', 'port', new_port), 'OK')
        moved = Client(new_port)
        self.addCleanup(moved.close)
        self.assertEqual(moved.call('PING'), 'PONG')
        moved.send('CONFIG', 'SET', 'bind', '999.999.999.999')
        self.assertIsInstance(moved.reply(), ServerError)
        reconnected = Client(new_port)
        self.addCleanup(reconnected.close)
        self.assertEqual(reconnected.call('PING'), 'PONG')

    def test_rdb_save_restart_preserves_types_expiry_and_databases(self):
        if REFERENCE_PORT is not None:
            self.skipTest('requires ownership of process lifecycle')
        self.client.call('SET', 'durable', 'string')
        self.client.call('HSET', 'durable-hash', 'field', 'value')
        self.client.call('SET', 'durable-ttl', 'value', 'PX', 60000)
        self.client.call('SELECT', 5)
        self.client.call('RPUSH', 'durable-list', 'one', 'two')
        self.assertEqual(self.client.call('SAVE'), 'OK')
        self.server.stop()
        self.server.start()
        restarted = self.server.client()
        self.assertEqual(restarted.call('GET', 'durable'), b'string')
        self.assertEqual(restarted.call('HGET', 'durable-hash', 'field'), b'value')
        self.assertGreater(restarted.call('PTTL', 'durable-ttl'), 0)
        restarted.call('SELECT', 5)
        self.assertEqual(restarted.call('LRANGE', 'durable-list', 0, -1), [b'one', b'two'])

    def test_acl_subcommand_denials_log_context(self):
        self.client.call('ACL', 'SETUSER', 'compat-user', 'reset', 'on', '>secret', '~*', '+ping')
        self.addCleanup(self.client.call, 'ACL', 'DELUSER', 'compat-user')
        self.client.call('ACL', 'LOG', 'RESET')
        restricted = self.connection()
        restricted.call('AUTH', 'compat-user', 'secret')
        restricted.send('SCRIPT', 'HELP')
        self.assertIsInstance(restricted.reply(), ServerError)
        entries = self.client.call('ACL', 'LOG')
        entry = dict(zip(entries[0][::2], entries[0][1::2]))
        self.assertEqual(entry[b'username'], b'compat-user')
        self.assertEqual(entry[b'context'], b'toplevel')
        self.assertEqual(entry[b'reason'], b'command')
        self.assertEqual(entry[b'object'], b'script|help')

    def test_lolwut_versions_and_protocol(self):
        client = self.client
        version = info(client, 'server')['redis_version'].encode()
        self.assertEqual(client.call('LOLWUT'), b'Redis ver. ' + version + b'\n')
        self.assertEqual(client.call('LOLWUT', 'VERSION', 100), b'Redis ver. ' + version + b'\n')
        skyline = client.call('LOLWUT', 'VERSION', 6, 7, 3)
        self.assertEqual(skyline.count(b' \x1b[0m'), 21)
        schotter = client.call('LOLWUT', 'VERSION', 5, 8, 1, 1).decode()
        art = schotter.split('Georg Nees')[0]
        self.assertTrue(all(char == '\n' or 0x2800 <= ord(char) <= 0x28ff for char in art))
        for arguments in [('VERSION', 'bad'), ('VERSION', 5, 'bad'), ('VERSION', 6, 2, 'bad')]:
            client.send('LOLWUT', *arguments)
            self.assertIsInstance(client.reply(), ServerError)
        client.call('HELLO', 3)
        self.assertEqual(client.call('LOLWUT'), b'Redis ver. ' + version + b'\n')

    def test_pause_retains_expired_key_without_side_effects(self):
        client = self.client
        client.call('CONFIG', 'SET', 'hz', 100)
        before = int(info(client, 'stats')['expired_keys'])
        client.call('MULTI')
        client.call('SET', 'retained', 'payload', 'PX', 40)
        client.call('CLIENT', 'PAUSE', 10000, 'WRITE')
        client.call('EXEC')
        self.addCleanup(client.call, 'CLIENT', 'UNPAUSE')
        time.sleep(.15)
        self.assertIsNone(client.call('GET', 'retained'))
        self.assertEqual(client.call('EXISTS', 'retained'), 0)
        self.assertEqual(client.call('DBSIZE'), 1)
        self.assertEqual(int(info(client, 'stats')['expired_keys']), before)
        self.assertEqual(client.call('RANDOMKEY'), b'retained')
        client.call('CLIENT', 'UNPAUSE')
        self.assertIsNone(client.call('GET', 'retained'))
        self.assertEqual(int(info(client, 'stats')['expired_keys']), before + 1)

    def test_pause_hash_fields_remain_physical_but_reads_hide_expiry(self):
        client = self.client
        client.call('HSET', 'hash-pause', 'due', 'old', 'live', 'value')
        before = int(info(client, 'stats')['expired_subkeys'])
        client.call('MULTI')
        client.call('HPEXPIRE', 'hash-pause', 30, 'FIELDS', 1, 'due')
        client.call('CLIENT', 'PAUSE', 10000, 'WRITE')
        client.call('EXEC')
        self.addCleanup(client.call, 'CLIENT', 'UNPAUSE')
        time.sleep(.15)
        self.assertIsNone(client.call('HGET', 'hash-pause', 'due'))
        self.assertEqual(client.call('HMGET', 'hash-pause', 'due', 'live'), [None, b'value'])
        self.assertEqual(client.call('HEXISTS', 'hash-pause', 'due'), 0)
        self.assertEqual(client.call('HSTRLEN', 'hash-pause', 'due'), 0)
        self.assertEqual(client.call('HLEN', 'hash-pause'), 2)
        self.assertCountEqual(client.call('HRANDFIELD', 'hash-pause', 10), [b'due', b'live'])
        self.assertEqual(client.call('HGETALL', 'hash-pause'), [b'live', b'value'])
        self.assertEqual(int(info(client, 'stats')['expired_subkeys']), before)
        client.call('CLIENT', 'UNPAUSE')
        self.assertIsNone(client.call('HGET', 'hash-pause', 'due'))
        self.assertEqual(int(info(client, 'stats')['expired_subkeys']), before + 1)

    def test_pause_timeout_releases_expiry(self):
        client = self.client
        client.call('MULTI')
        client.call('SET', 'timeout-key', 'value', 'PX', 20)
        client.call('CLIENT', 'PAUSE', 150, 'WRITE')
        client.call('EXEC')
        time.sleep(.05)
        self.assertIsNone(client.call('GET', 'timeout-key'))
        self.assertEqual(client.call('DBSIZE'), 1)
        wait_for(lambda: client.call('DBSIZE') == 0, timeout=2, label='expiry after pause timeout')

    def test_hash_field_mutation_dirty_counts(self):
        client = self.client
        def delta(expected, *command):
            before = self.dirty()
            reply = client.call(*command)
            self.assertEqual(self.dirty() - before, expected, command)
            return reply
        delta(2, 'HSET', 'hash-dirty', 'a', '1', 'b', '2')
        delta(2, 'HSET', 'hash-dirty', 'a', '1', 'b', '3')
        delta(0, 'HSETNX', 'hash-dirty', 'a', 'different')
        delta(2, 'HPEXPIRE', 'hash-dirty', 60000, 'FIELDS', 2, 'a', 'b')
        delta(1, 'HPERSIST', 'hash-dirty', 'FIELDS', 2, 'a', 'b')
        delta(0, 'HPERSIST', 'hash-dirty', 'FIELDS', 2, 'a', 'b')
        delta(2, 'HDEL', 'hash-dirty', 'a', 'b', 'missing')

    def test_set_and_sorted_set_mutation_dirty_counts(self):
        client = self.client
        def delta(expected, *command):
            before = self.dirty()
            reply = client.call(*command)
            self.assertEqual(self.dirty() - before, expected, command)
            return reply
        delta(3, 'SADD', 'set-dirty', 'a', 'b', 'c')
        delta(0, 'SADD', 'set-dirty', 'a', 'c')
        delta(0, 'SMOVE', 'set-dirty', 'set-dirty', 'b')
        delta(2, 'ZADD', 'zset-dirty', 1, 'a', 2, 'b')
        delta(1, 'ZADD', 'zset-dirty', 1, 'a', 3, 'b')
        delta(0, 'ZADD', 'zset-dirty', 'NX', 9, 'a')
        delta(0, 'ZADD', 'zset-dirty', 'INCR', 0, 'a')

    def test_stream_delivery_ack_and_delete_dirty_counts(self):
        client = self.client
        def delta(expected, *command):
            before = self.dirty()
            reply = client.call(*command)
            self.assertEqual(self.dirty() - before, expected, command)
            return reply
        for number in range(1, 4):
            delta(1, 'XADD', 'stream-dirty', '%d-0' % number, 'field', str(number))
        delta(1, 'XGROUP', 'CREATE', 'stream-dirty', 'g', 0)
        delta(2, 'XREADGROUP', 'GROUP', 'g', 'consumer', 'COUNT', 3, 'STREAMS', 'stream-dirty', '>')
        delta(0, 'XREADGROUP', 'GROUP', 'g', 'consumer', 'COUNT', 3, 'STREAMS', 'stream-dirty', 0)
        delta(2, 'XACK', 'stream-dirty', 'g', '1-0', '2-0')
        delta(0, 'XACK', 'stream-dirty', 'g', '1-0', '2-0')
        delta(2, 'XDEL', 'stream-dirty', '1-0', '2-0')
        delta(1, 'XTRIM', 'stream-dirty', 'MAXLEN', 0)
        delta(1, 'XREADGROUP', 'GROUP', 'g', 'new-consumer', 'STREAMS', 'stream-dirty', '>')

    def test_keyspace_expiry_delete_and_store_dirty_noops(self):
        client = self.client
        def delta(expected, *command):
            before = self.dirty()
            reply = client.call(*command)
            self.assertEqual(self.dirty() - before, expected, command)
            return reply
        delta(1, 'SET', 'generic-dirty', 'value')
        delta(0, 'RENAME', 'generic-dirty', 'generic-dirty')
        delta(0, 'PERSIST', 'generic-dirty')
        delta(1, 'PEXPIRE', 'generic-dirty', 60000, 'NX')
        delta(0, 'PEXPIRE', 'generic-dirty', 60000, 'NX')
        delta(1, 'PERSIST', 'generic-dirty')
        delta(0, 'EXPIRE', 'absent-dirty', 10)
        delta(1, 'SET', 'second-dirty', 'value')
        delta(2, 'DEL', 'generic-dirty', 'second-dirty', 'absent-dirty')
        delta(0, 'DEL', 'generic-dirty', 'second-dirty')
        delta(0, 'SUNIONSTORE', 'dest-dirty', 'absent-dirty')
        delta(3, 'SADD', 'source-dirty', 'a', 'b', 'c')
        delta(1, 'SUNIONSTORE', 'dest-dirty', 'source-dirty')
        delta(1, 'SUNIONSTORE', 'dest-dirty', 'absent-dirty')
        delta(3, 'ZADD', 'zsource-dirty', 1, 'a', 2, 'b', 3, 'c')
        delta(1, 'ZRANGESTORE', 'zdest-dirty', 'zsource-dirty', 0, -1)
        delta(1, 'ZRANGESTORE', 'zdest-dirty', 'absent-dirty', 0, -1)
        delta(0, 'ZRANGESTORE', 'zdest-dirty', 'absent-dirty', 0, -1)

    def test_geo_store_and_bitfield_dirty_counts(self):
        client = self.client
        def delta(expected, *command):
            before = self.dirty()
            reply = client.call(*command)
            self.assertEqual(self.dirty() - before, expected, command)
            return reply
        delta(2, 'BITFIELD', 'field-dirty', 'SET', 'u8', 0, 1, 'SET', 'u8', 8, 2)
        delta(0, 'BITFIELD', 'field-dirty', 'INCRBY', 'u8', 0, 0)
        delta(0, 'BITFIELD', 'field-dirty', 'INCRBY', 'u8', 0, 256)
        delta(2, 'GEOADD', 'geo-dirty', 10, 20, 'a', 11, 21, 'b')
        delta(0, 'GEORADIUS', 'geo-dirty', 10, 20, 10000, 'km')
        delta(2, 'GEORADIUS', 'geo-dirty', 10, 20, 10000, 'km', 'STORE', 'geo-dest-dirty')
        delta(2, 'GEORADIUS', 'geo-dirty', 10, 20, 10000, 'km', 'STORE', 'geo-dest-dirty')
        delta(1, 'GEORADIUS', 'absent-geo', 10, 20, 10000, 'km', 'STORE', 'geo-dest-dirty')
        delta(0, 'GEORADIUS', 'absent-geo', 10, 20, 10000, 'km', 'STORE', 'geo-dest-dirty')

    def test_list_dirty_counts_elements_and_noops(self):
        client = self.client
        def delta(expected, *command):
            before = self.dirty()
            value = client.call(*command)
            self.assertEqual(self.dirty() - before, expected, command)
            return value
        delta(3, 'LPUSH', 'list-dirty', 'a', 'a', 'b')
        delta(0, 'LTRIM', 'list-dirty', 0, -1)
        delta(0, 'LREM', 'list-dirty', 0, 'missing')
        delta(0, 'LPOP', 'list-dirty', 0)
        delta(2, 'LREM', 'list-dirty', 0, 'a')
        delta(1, 'LMOVE', 'list-dirty', 'list-dirty', 'LEFT', 'LEFT')
        delta(1, 'LPOP', 'list-dirty', 5)
        delta(0, 'LPOP', 'list-dirty')
        delta(0, 'LPUSHX', 'missing-list', 'x')
        delta(0, 'LINSERT', 'missing-list', 'BEFORE', 'x', 'y')
        delta(0, 'LTRIM', 'missing-list', 0, 1)
        before = self.dirty()
        client.call('MULTI')
        client.call('BLPOP', 'missing-list', 0)
        client.call('BLMOVE', 'missing-list', 'dest-list', 'LEFT', 'RIGHT', 0)
        self.assertEqual(client.call('EXEC'), [None, None])
        self.assertEqual(self.dirty(), before)

    def test_parked_pop_counts_only_mutations(self):
        blocked = self.connection()
        baseline = self.dirty()
        blocked.send('BLPOP', 'pending', 0)
        wait_for(lambda: self.blocked() == 1, label='list wait')
        self.assertEqual(self.dirty(), baseline)
        self.client.call('LPUSH', 'pending', 'item')
        self.assertEqual(blocked.reply(), [b'pending', b'item'])
        self.assertEqual(self.dirty(), baseline + 2)

    def test_parked_move_counts_once(self):
        blocked = self.connection()
        baseline = self.dirty()
        blocked.send('BLMOVE', 'source', 'destination', 'LEFT', 'RIGHT', 0)
        wait_for(lambda: self.blocked() == 1, label='move wait')
        self.assertEqual(self.dirty(), baseline)
        self.client.call('LPUSH', 'source', 'item')
        self.assertEqual(blocked.reply(), b'item')
        self.assertEqual(self.client.call('LRANGE', 'destination', 0, -1), [b'item'])
        self.assertEqual(self.dirty(), baseline + 2)

    def test_block_timeout_and_wrongtype_are_not_dirty(self):
        blocked = self.connection()
        baseline = self.dirty()
        self.assertIsNone(blocked.call('BLPOP', 'absent', .03))
        self.assertEqual(self.dirty(), baseline)
        self.client.call('SET', 'wrong', 'string')
        baseline = self.dirty()
        blocked.send('BLPOP', 'wrong', .03)
        self.assertIsInstance(blocked.reply(), ServerError)
        self.assertEqual(self.dirty(), baseline)

    def test_idle_query_buffer_frees_and_recovers(self):
        client = self.connection()
        client.call('CLIENT', 'SETNAME', 'idle-buffer')
        self.assertGreaterEqual(self.qcapacity('idle-buffer'), 16384)
        wait_for(lambda: self.qcapacity('idle-buffer') == 0, timeout=5, label='idle query buffer release')
        self.assertEqual(client.call('PING'), 'PONG')
        self.assertGreaterEqual(self.qcapacity('idle-buffer'), 16384)

    def test_active_query_buffer_releases_old_peak(self):
        client = self.connection()
        self.client.call('CONFIG', 'SET', 'hz', 100)
        self.client.call('DEBUG', 'PAUSE-CRON', 1)
        self.addCleanup(self.client.call, 'DEBUG', 'PAUSE-CRON', 0)
        client.call('CLIENT', 'SETNAME', 'active-buffer')
        client.call('SET', 'large', b'x' * 400000)
        capacity = self.qcapacity('active-buffer')
        self.assertGreater(capacity, 32768)
        self.client.call('DEBUG', 'PAUSE-CRON', 0)
        def shrunk():
            client.call('PING')
            return 0 < self.qcapacity('active-buffer') < capacity
        wait_for(shrunk, timeout=2, label='query peak release while active')
        self.assertEqual(client.call('STRLEN', 'large'), 400000)

    def test_client_memory_limit_evicts_partial_request(self):
        client = self.connection()
        self.client.call('CLIENT', 'NO-EVICT', 'ON')
        self.client.call('CONFIG', 'SET', 'maxmemory-clients', 400000)
        self.addCleanup(self.client.call, 'CONFIG', 'SET', 'maxmemory-clients', 0)
        client.call('CLIENT', 'SETNAME', 'evict-partial')
        client.socket.sendall(b'*3\r\n$3\r\nSET\r\n$4\r\nhuge\r\n$700000\r\n' + b'a' * 200000)
        wait_for(lambda: b'name=evict-partial ' not in self.client.call('CLIENT', 'LIST'),
                 timeout=3, label='oversized client eviction')
        self.assertIsNone(self.client.call('GET', 'huge'))

    def test_hard_output_limit_closes_before_partial_reply(self):
        client = self.connection()
        client.call('CLIENT', 'SETNAME', 'output-limit')
        self.client.call('SET', 'large-output', b'o' * 400000)
        previous = self.client.call('CONFIG', 'GET', 'client-output-buffer-limit')[1]
        self.addCleanup(self.client.call, 'CONFIG', 'SET', 'client-output-buffer-limit', previous)
        self.client.call('CONFIG', 'SET', 'client-output-buffer-limit', 'normal 100000 0 0')
        client.send('GET', 'large-output')
        wait_for(lambda: b'name=output-limit ' not in self.client.call('CLIENT', 'LIST'),
                 timeout=3, label='hard output limit disconnect')
        self.assertEqual(client.socket.recv(1), b'')
        self.assertEqual(self.client.call('STRLEN', 'large-output'), 400000)

    def test_reply_buffer_shrinks_idle_and_recovers_for_large_output(self):
        client = self.connection()
        client.call('CLIENT', 'SETNAME', 'reply-buffer')
        self.client.call('DEBUG', 'REPLYBUFFER', 'PEAK-RESET-TIME', 100)
        self.addCleanup(self.client.call, 'DEBUG', 'REPLYBUFFER', 'PEAK-RESET-TIME', 'reset')
        wait_for(lambda: 1024 <= int(self.fields('reply-buffer')['rbs']) < 2048,
                 timeout=3, label='idle reusable reply buffer release')
        self.client.call('SET', 'output', b'y' * 400000)
        self.client.call('DEBUG', 'REPLYBUFFER', 'PEAK-RESET-TIME', 'never')
        for unused in range(3):
            self.assertEqual(client.call('GET', 'output'), b'y' * 400000)
            self.assertEqual(int(self.fields('reply-buffer')['rbs']), 16384)
        self.assertEqual(client.call('PING'), 'PONG')

    def test_partial_bulk_reserves_then_shrinks_without_losing_input(self):
        client = self.connection()
        client.call('CLIENT', 'SETNAME', 'partial-buffer')
        client.socket.sendall(b'*3\r\n$3\r\nSET\r\n$7\r\npartial\r\n$1000000\r\n')
        wait_for(lambda: self.qcapacity('partial-buffer') >= 1000000, timeout=1, label='bulk reservation')
        time.sleep(.2)
        self.assertGreaterEqual(self.qcapacity('partial-buffer'), 1000000)
        wait_for(lambda: self.qcapacity('partial-buffer') < 1000000, timeout=5, label='idle partial bulk release')
        client.socket.sendall(b'z' * 1000000 + b'\r\n')
        self.assertEqual(client.reply(), 'OK')
        self.assertEqual(self.client.call('STRLEN', 'partial'), 1000000)


def main():
    global BINARY, REFERENCE_PORT, KEYSPACE_THREADS
    parser = argparse.ArgumentParser(description='Original single-node compatibility regressions; no compilation or benchmarks.')
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--reference-port', type=int, help='explicitly isolated localhost reference fixture')
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--case', default='*')
    parser.add_argument('--timeout', type=int, default=120)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    REFERENCE_PORT = args.reference_port
    KEYSPACE_THREADS = args.keyspace_threads
    if args.timeout <= 0 or (REFERENCE_PORT is None and not BINARY.is_file()):
        parser.error('existing binary and positive timeout required')
    names = [name for name in unittest.defaultTestLoader.getTestCaseNames(Compatibility)
             if fnmatch.fnmatchcase(name, args.case)]
    if not names:
        parser.error('no tests selected')
    def expired(unused_signal, unused_frame):
        raise SystemExit(124)
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(args.timeout)
    try:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(Compatibility(name) for name in names))
        return 0 if result.wasSuccessful() else 1
    finally:
        signal.alarm(0)


if __name__ == '__main__':
    raise SystemExit(main())
