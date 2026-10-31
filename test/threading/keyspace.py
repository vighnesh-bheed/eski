import argparse
from concurrent.futures import ThreadPoolExecutor
import fnmatch
import os
from pathlib import Path
import signal
import socket
import sys
import time
import unittest


sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from support import Push, ROOT, Server, ServerError, encode, info, wait_for


BINARY = ROOT/'bin/eski'
FIELDS = ('keyspace_threads_configured', 'keyspace_threads_active', 'keyspace_jobs_pending',
          'keyspace_memory_used', 'keyspace_records', 'keyspace_jobs_submitted',
          'keyspace_jobs_completed', 'keyspace_gets', 'keyspace_sets',
          'keyspace_sync_fallbacks', 'keyspace_barriers', 'keyspace_worker_nanoseconds')


def server(workers=2, memory=8 << 20, arguments=()):
    return Server(BINARY, workers=0, arguments=('--keyspace-threads', str(workers),
                  '--keyspace-max-memory', str(memory), *arguments))


class Keyspace(unittest.TestCase):
    def setUp(self):
        self.server = server()
        self.addCleanup(self.server.close)
        self.server.start()
        self.admin = self.server.client()

    def snapshot(self, client=None):
        client = client or self.admin
        rows = [line.split(b':', 1) for line in client.call('INFO', 'server').splitlines() if b':' in line]
        result = {}
        for name in FIELDS:
            values = [value for key, value in rows if key == name.encode()]
            self.assertEqual(len(values), 1, name)
            self.assertTrue(values[0].isdigit(), (name, values))
            result[name] = int(values[0])
        self.assertEqual(result['keyspace_jobs_pending'], 0)
        self.assertEqual(result['keyspace_records'], 0)
        self.assertEqual(result['keyspace_memory_used'], 0)
        self.assertEqual(result['keyspace_jobs_submitted'], result['keyspace_jobs_completed'])
        self.assertLessEqual(result['keyspace_threads_active'], result['keyspace_threads_configured'])
        return result

    def error(self, client, arguments, contains):
        client.send(*arguments)
        result = client.reply()
        self.assertIsInstance(result, ServerError)
        self.assertIn(contains.lower(), str(result).lower())
        return result

    def dirty(self, client=None):
        return int(info(client or self.admin, 'persistence')['rdb_changes_since_last_save'])

    def calls(self, name, client=None):
        row = info(client or self.admin, 'commandstats').get('cmdstat_'+name, 'calls=0')
        return int(row.split('calls=', 1)[1].split(',', 1)[0])

    def test_default_named_hidden_and_immutable_configuration(self):
        def inspect(client, expected):
            for name, value in expected.items():
                for spelling in (name, name.upper()):
                    self.assertEqual(client.call('CONFIG', 'GET', spelling), [spelling.encode(), value])
            for pattern in ('*', 'keyspace-*', 'KEYSPACE-*'):
                reply = client.call('CONFIG', 'GET', pattern)
                self.assertTrue(set(reply[::2]).isdisjoint(name.encode() for name in expected), pattern)
            for name, current in expected.items():
                for value in (current, b'1'):
                    self.error(client, ('CONFIG', 'SET', name, value), 'immutable')
                    self.assertEqual(client.call('CONFIG', 'GET', name), [name.encode(), current])
        with Server(BINARY, workers=None) as default:
            client = default.client()
            values = self.snapshot(client)
            self.assertEqual(values['keyspace_threads_configured'], 0)
            self.assertEqual(values['keyspace_threads_active'], 0)
            inspect(client, {'keyspace-threads': b'0', 'keyspace-max-memory': b'134217728'})
        inspect(self.admin, {'keyspace-threads': b'2', 'keyspace-max-memory': b'8388608'})
        self.assertEqual(self.admin.call('SET', 'config:enabled', 'v'), 'OK')
        self.assertEqual(self.snapshot()['keyspace_threads_active'], 2)

    def test_binary_empty_and_storage_boundaries_match_an_independent_model(self):
        client = self.server.client()
        commands, expected, model = [], [], {}
        for at, length in enumerate((0, 1, 15, 16, 17, 43, 44, 45, 255, 4095, 4096, 4097, 65537)):
            key = b'' if at == 0 else b'key\x00\xff\r\n'+bytes([at])
            value = (b'\x00a\xff\r\n'*(length//5+1))[:length]
            model[key] = value
            commands += [('SET', key, value), ('GET', key)]
            expected += ['OK', value]
        commands += [('GET', b'absent\x00\xff'), ('MGET', *model)]
        expected += [None, list(model.values())]
        wire = b''.join(encode(command) for command in commands)
        client.socket.sendall(wire[:23])
        client.socket.sendall(wire[23:])
        self.assertEqual([client.reply() for _ in commands], expected)
        values = self.snapshot()
        self.assertEqual(values['keyspace_sets'], len(model))
        self.assertEqual(values['keyspace_gets'], len(model)+1)

    def test_pipeline_protocol_database_and_ready_barriers_preserve_order(self):
        client = self.server.client()
        commands = [('SET', 'same', 'db0'), ('GET', 'same'), ('SELECT', 1), ('GET', 'same'),
                    ('SET', 'same', 'db1'), ('HELLO', 3), ('GET', 'same'), ('GET', 'absent'),
                    ('SELECT', 0), ('MGET', 'same'), ('HELLO', 2), ('GET', 'same'), ('ECHO', 'end')]
        replies = client.pipeline(commands)
        self.assertEqual(replies[:5], ['OK', b'db0', 'OK', None, 'OK'])
        self.assertIsInstance(replies[5], dict)
        self.assertEqual(replies[6:10], [b'db1', None, 'OK', [b'db0']])
        self.assertIsInstance(replies[10], list)
        self.assertEqual(replies[11:], [b'db0', b'end'])
        self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], 8)

    def test_reply_off_and_skip_preserve_mutations_and_order(self):
        client = self.server.client()
        client.send_many([('CLIENT', 'REPLY', 'OFF'), ('SET', 'silent', 'stored'), ('GET', 'silent'),
                          ('CLIENT', 'REPLY', 'ON'), ('PING', 'on'), ('CLIENT', 'REPLY', 'SKIP'),
                          ('SET', 'skipped', 'kept'), ('GET', 'skipped'), ('PING', 'end')])
        self.assertEqual([client.reply() for _ in range(4)], ['OK', b'on', b'kept', b'end'])
        self.assertEqual(self.admin.call('MGET', 'silent', 'skipped'), [b'stored', b'kept'])
        self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], 5)

    def test_half_close_delivers_all_accepted_replies(self):
        for protocol in (2, 3):
            with self.subTest(protocol=protocol):
                client = self.server.client()
                client.call('HELLO', protocol)
                commands = [('SET', 'half', b'value\x00'), ('GET', 'half'), ('GET', 'missing'), ('ECHO', 'last')]
                client.send_many(commands)
                client.socket.shutdown(socket.SHUT_WR)
                self.assertEqual([client.reply() for _ in commands], ['OK', b'value\x00', None, b'last'])
                with self.assertRaises((EOFError, ConnectionResetError)):
                    client.read()
        self.assertGreater(self.snapshot()['keyspace_jobs_completed'], 0)

    def test_mutable_reads_are_whole_immutable_values_during_replacements(self):
        reader, writer = self.server.client(), self.server.client()
        before = self.snapshot()
        for at in range(12):
            old = bytes([at])*131073+b'old'
            new = bytes([255-at])*131073+b'new'
            self.assertEqual(writer.call('SET', 'retained', old), 'OK')
            reader.send('GET', 'retained')
            self.assertEqual(reader.take(1), b'$')
            length = int(reader.line())
            self.assertEqual(length, len(old))
            self.assertEqual(writer.call('SET', 'retained', new), 'OK')
            self.assertEqual(reader.take(length+2), old+b'\r\n')
            self.assertEqual(reader.call('GET', 'retained'), new)
        after = self.snapshot()
        self.assertEqual(after['keyspace_sets']-before['keyspace_sets'], 24)
        self.assertEqual(after['keyspace_gets']-before['keyspace_gets'], 24)

    def test_disconnected_admitted_set_commits_and_owns_slowlog_identity(self):
        self.admin.call('SET', 'large-output', b'x'*131072)
        source = self.server.client()
        source.call('CLIENT', 'SETNAME', 'closed-worker-source')
        source_addr = ('127.0.0.1:%d' % source.socket.getsockname()[1]).encode()
        self.admin.call('CONFIG', 'SET', 'slowlog-log-slower-than', 0)
        self.admin.call('SLOWLOG', 'RESET')
        before, dirty, calls = self.snapshot(), self.dirty(), self.calls('set')
        self.admin.call('CONFIG', 'SET', 'client-output-buffer-limit', 'normal 1024 0 0')
        source.send_many([('MGET', 'large-output'), ('SET', 'orphan', 'committed')])
        with self.assertRaises((EOFError, ConnectionResetError)):
            source.read()
        self.admin.call('CONFIG', 'SET', 'client-output-buffer-limit', 'normal 0 0 0')
        after = self.snapshot()
        self.assertEqual(after['keyspace_jobs_submitted']-before['keyspace_jobs_submitted'], 2)
        self.assertEqual(after['keyspace_sets']-before['keyspace_sets'], 1)
        self.assertEqual(self.dirty()-dirty, 1)
        self.assertEqual(self.calls('set')-calls, 1)
        self.assertEqual(self.admin.call('MGET', 'orphan'), [b'committed'])
        entries = [row for row in self.admin.call('SLOWLOG', 'GET', 128) if row[3] == [b'SET', b'orphan', b'committed']]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0][4:], [source_addr, b'closed-worker-source'])
        replacement = self.server.client()
        self.assertEqual(replacement.pipeline([('SET', 'replacement', 'fresh'), ('GET', 'replacement'), ('PING',)]),
                         ['OK', b'fresh', 'PONG'])

    def test_dirty_hit_miss_and_command_counts_are_charged_once(self):
        before = self.snapshot()
        dirty, hits, misses = self.dirty(), int(info(self.admin, 'stats')['keyspace_hits']), int(info(self.admin, 'stats')['keyspace_misses'])
        sets, gets = self.calls('set'), self.calls('get')
        commands = [('SET', 'count', 'a'), ('SET', 'count', 'a'), ('GET', 'count'),
                    ('GET', 'not-present'), ('SET', 'count', 'b'), ('GET', 'count')]
        self.assertEqual(self.admin.pipeline(commands), ['OK', 'OK', b'a', None, 'OK', b'b'])
        after = self.snapshot()
        observed = info(self.admin, 'stats')
        self.assertEqual(after['keyspace_sets']-before['keyspace_sets'], 3)
        self.assertEqual(after['keyspace_gets']-before['keyspace_gets'], 3)
        self.assertEqual(self.dirty()-dirty, 3)
        self.assertEqual(int(observed['keyspace_hits'])-hits, 2)
        self.assertEqual(int(observed['keyspace_misses'])-misses, 1)
        self.assertEqual(self.calls('set')-sets, 3)
        self.assertEqual(self.calls('get')-gets, 3)

    def test_type_errors_retry_and_expiry_and_set_options_use_workers(self):
        self.admin.call('LPUSH', 'typed', 'item')
        before = self.snapshot()
        self.error(self.admin, ('GET', 'typed'), 'WRONGTYPE')
        self.assertEqual(self.admin.call('SET', 'typed', 'string'), 'OK')
        after = self.snapshot()
        self.assertEqual(after['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'] + 2)
        self.assertEqual(self.admin.call('GET', 'typed'), b'string')
        self.admin.call('SET', 'ttl', 'old', 'PX', 60000)
        before = self.snapshot()
        self.assertEqual(self.admin.pipeline([('GET', 'ttl'), ('SET', 'ttl', 'persistent'), ('PTTL', 'ttl')]),
                         [b'old', 'OK', -1])
        self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'] + 3)
        self.admin.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        self.admin.call('SET', 'expired', 'old', 'PX', 1)
        time.sleep(.02)
        before = self.snapshot()
        self.assertIsNone(self.admin.call('GET', 'expired'))
        after = self.snapshot()
        self.assertEqual(after['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'] + 1)
        self.assertEqual(after['keyspace_sync_fallbacks'], before['keyspace_sync_fallbacks'])
        self.assertEqual(self.admin.pipeline([('SET', 'option', 'v', 'NX'), ('SET', 'option', 'bad', 'NX'),
                                             ('SET', 'option', 'new', 'GET'), ('MGET', 'option', 'typed')]),
                         ['OK', None, b'v', [b'new', b'string']])

    def test_read_only_import_preserves_encoding_allocation_and_no_touch(self):
        self.admin.call('SETRANGE', 'raw-number', 0, '123')
        encoding = self.admin.call('OBJECT', 'ENCODING', 'raw-number')
        memory = self.admin.call('MEMORY', 'USAGE', 'raw-number')
        before = self.snapshot()
        self.assertEqual(self.admin.pipeline([('GET', 'raw-number')]*8), [b'123']*8)
        self.assertEqual(self.admin.call('OBJECT', 'ENCODING', 'raw-number'), encoding)
        self.assertEqual(self.admin.call('MEMORY', 'USAGE', 'raw-number'), memory)
        self.assertEqual(self.snapshot()['keyspace_gets']-before['keyspace_gets'], 8)
        self.admin.call('SET', 'untouched', 'same')
        original = self.admin.call('DEBUG', 'OBJECT', 'untouched').split(' lru:', 1)[1].split()[0]
        time.sleep(1.1)
        self.admin.call('CLIENT', 'NO-TOUCH', 'ON')
        self.assertEqual(self.admin.pipeline([('GET', 'untouched'), ('SET', 'untouched', 'same'),
                                             ('SET', 'new-untouched', 'created')]), [b'same', 'OK', 'OK'])
        self.assertEqual(self.admin.call('DEBUG', 'OBJECT', 'untouched').split(' lru:', 1)[1].split()[0], original)
        new_clock = int(self.admin.call('DEBUG', 'OBJECT', 'new-untouched').split(' lru:', 1)[1].split()[0])
        self.assertLessEqual((int(info(self.admin)['lru_clock'])-new_clock) & ((1 << 24)-1), 1)
        self.admin.call('CLIENT', 'NO-TOUCH', 'OFF')
        self.admin.call('GET', 'untouched')
        self.assertNotEqual(self.admin.call('DEBUG', 'OBJECT', 'untouched').split(' lru:', 1)[1].split()[0], original)

    def test_budget_rejection_reconciles_existing_and_new_records_without_double_dirty(self):
        with server(memory=2048) as bounded:
            client = bounded.client()
            before, dirty = self.snapshot(client), self.dirty(client)
            value = b'z'*32769
            self.assertEqual(client.pipeline([('SET', 'budget', 'small'), ('SET', 'budget', value),
                                              ('MGET', 'budget'), ('SET', 'new-budget', value)]),
                             ['OK', 'OK', [value], 'OK'])
            after = self.snapshot(client)
            self.assertGreater(after['keyspace_sync_fallbacks'], before['keyspace_sync_fallbacks'])
            self.assertGreater(after['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'])
            self.assertEqual(self.dirty(client)-dirty, 3)
            self.assertEqual(client.call('SET', 'after-rejection', 'ok'), 'OK')
            self.assertEqual(client.call('GET', 'after-rejection'), b'ok')
            self.snapshot(client)
        with server(memory=0) as disabled:
            client = disabled.client()
            self.assertEqual(client.pipeline([('SET', 'zero', 'v'), ('GET', 'zero')]), ['OK', b'v'])
            self.assertEqual(self.snapshot(client)['keyspace_jobs_submitted'], 0)

    def test_acl_arity_and_renamed_handlers_keep_eligibility(self):
        self.admin.call('ACL', 'SETUSER', 'limited', 'on', '>secret', '+get', '+set', '~allowed:*')
        client = self.server.client()
        client.call('AUTH', 'limited', 'secret')
        self.assertEqual(client.pipeline([('SET', 'allowed:key', 'v'), ('GET', 'allowed:key')]), ['OK', b'v'])
        before = self.snapshot()
        self.error(client, ('SET', 'forbidden', 'v'), 'NOPERM')
        self.error(client, ('GET', 'forbidden'), 'NOPERM')
        self.error(client, ('GET',), 'wrong number')
        self.error(client, ('SET', 'allowed:key'), 'wrong number')
        self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'])
        with server(arguments=('--rename-command', 'get', 'readget', '--rename-command', 'set', 'writeset')) as renamed:
            client = renamed.client()
            self.assertEqual(client.pipeline([('writeset', 'renamed', 'v'), ('readget', 'renamed')]), ['OK', b'v'])
            self.assertEqual(self.snapshot(client)['keyspace_jobs_submitted'], 2)
            self.error(client, ('GET', 'renamed'), 'unknown command')

    def test_transaction_execution_is_a_barrier_while_watched_and_idle_multi_clients_allow_workers(self):
        writer, watcher = self.server.client(), self.server.client()
        writer.call('SET', 'watched', 'old')
        watcher.call('WATCH', 'watched')
        before = self.snapshot()
        writer.call('SET', 'watched', 'new')
        self.assertEqual(watcher.pipeline([('MULTI',), ('GET', 'watched'), ('EXEC',)]), ['OK', 'QUEUED', None])
        self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'] + 1)
        watcher.call('MULTI')
        before = self.snapshot()
        self.assertEqual(writer.pipeline([('SET', 'other', 'v'), ('GET', 'other')]), ['OK', b'v'])
        watcher.call('SET', 'tx:a', 'left')
        watcher.call('SET', 'tx:b', 'right')
        watcher.call('MGET', 'tx:a', 'tx:b')
        self.assertEqual(watcher.call('EXEC'), ['OK', 'OK', [b'left', b'right']])
        self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'] + 2)
        self.assertEqual(writer.call('GET', 'watched'), b'new')
        self.assertGreater(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'])

    def test_tracking_notifications_and_monitor_preserve_worker_effect_order(self):
        writer, tracker = self.server.client(), self.server.client()
        writer.call('SET', 'tracked', 'old')
        tracker.call('HELLO', 3)
        tracker.call('CLIENT', 'TRACKING', 'ON')
        before = self.snapshot()
        self.assertEqual(tracker.call('GET', 'tracked'), b'old')
        writer.call('SET', 'tracked', 'new')
        frame = tracker.read()
        self.assertIsInstance(frame, Push)
        self.assertEqual(frame, [b'invalidate', [b'tracked']])
        self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'] + 2)
        tracker.call('CLIENT', 'TRACKING', 'OFF')
        self.admin.call('CONFIG', 'SET', 'notify-keyspace-events', 'KE$')
        subscriber = self.server.client()
        self.assertEqual(subscriber.call('SUBSCRIBE', '__keyevent@0__:set'),
                         [b'subscribe', b'__keyevent@0__:set', 1])
        before = self.snapshot()
        writer.call('SET', 'notified', 'value')
        self.assertEqual(subscriber.read(), [b'message', b'__keyevent@0__:set', b'notified'])
        self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'] + 1)
        subscriber.call('UNSUBSCRIBE')
        self.admin.call('CONFIG', 'SET', 'notify-keyspace-events', '')
        monitor = self.server.client()
        monitor.call('MONITOR')
        before = self.snapshot()
        writer.call('SET', 'monitored', 'value')
        writer.call('GET', 'monitored')
        self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'] + 2)
        writer.call('PING', 'monitor-end')
        lines = []
        while not lines or '"monitor-end"' not in lines[-1]:
            lines.append(str(monitor.read()).lower())
        self.assertEqual(sum('"set" "monitored" "value"' in line for line in lines), 1)
        self.assertEqual(sum('"get" "monitored"' in line for line in lines), 1)

    def test_blocking_pause_and_memory_policies_preserve_admission_boundaries(self):
        waiter, writer = self.server.client(), self.server.client()
        waiter.send('BLPOP', 'waiting', 0)
        wait_for(lambda: info(self.admin, 'clients').get('blocked_clients') == '1', label='blocked client')
        before = self.snapshot()
        self.assertEqual(writer.pipeline([('SET', 'blocked:other', 'v'), ('GET', 'blocked:other')]), ['OK', b'v'])
        self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'] + 2)
        blocked_before = self.snapshot()['keyspace_jobs_submitted']
        self.admin.call('RPUSH', 'waiting', 'awake')
        self.assertEqual(waiter.reply(), [b'waiting', b'awake'])
        self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], blocked_before)
        self.admin.call('CLIENT', 'PAUSE', 5000, 'WRITE')
        writer.send_many([('SET', 'paused', 'after'), ('GET', 'paused'), ('ECHO', 'done')])
        self.assertIsNone(self.admin.call('GET', 'paused'))
        self.admin.call('CLIENT', 'UNPAUSE')
        self.assertEqual([writer.reply() for _ in range(3)], ['OK', b'after', b'done'])
        for name, enabled, disabled in (('maxmemory', '64mb', '0'), ('maxmemory-clients', '64mb', '0'),
                                        ('maxmemory-policy', 'allkeys-lfu', 'noeviction')):
            with self.subTest(policy=name):
                self.admin.call('CONFIG', 'SET', name, enabled)
                before = self.snapshot()
                self.assertEqual(writer.pipeline([('SET', 'policy', 'value'), ('GET', 'policy')]), ['OK', b'value'])
                self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'] + 2)
                self.admin.call('CONFIG', 'SET', name, disabled)

    def test_multiple_connections_fifo_and_legacy_argv_survive_completion_fences(self):
        clients = [self.server.client() for _ in range(8)]
        before = self.snapshot()
        def sequence(item):
            index, client = item
            for at in range(12):
                value = ('client:%d value:%d' % (index, at)).encode()
                self.assertEqual(client.pipeline([('SET', 'fifo:%d' % index, value), ('GET', 'fifo:%d' % index)]),
                                 ['OK', value])
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(sequence, enumerate(clients)))
        for at, client in enumerate(clients):
            client.send_many([('SET', 'queued:%d' % at, 'owned'), ('ECHO', 'ticket:%d' % at)])
        values = {b'legacy\x00a': b'first\xff', b'legacy\x00b': b'second\r\n'}
        self.assertEqual(self.admin.call('MSET', *[part for pair in values.items() for part in pair]), 'OK')
        for at, client in enumerate(clients):
            self.assertEqual([client.reply(), client.reply()], ['OK', ('ticket:%d' % at).encode()])
        self.assertEqual(self.admin.call('MGET', *values), list(values.values()))
        after = self.snapshot()
        self.assertEqual(after['keyspace_sets']-before['keyspace_sets'], 8*12+8)
        self.assertEqual(after['keyspace_gets']-before['keyspace_gets'], 8*12)
        self.assertGreater(after['keyspace_barriers'], before['keyspace_barriers'])

    def test_snapshot_fork_reload_and_shutdown_save_import_latest_values(self):
        client = self.server.client()
        replies = client.pipeline([('SET', 'saved:a', 'one'), ('SET', 'saved:b', b'two\x00'), ('BGSAVE',)])
        self.assertEqual(replies, ['OK', 'OK', 'Background saving started'])
        wait_for(lambda: info(self.admin, 'persistence').get('rdb_bgsave_in_progress') == '0', label='BGSAVE completion')
        self.assertEqual(info(self.admin, 'persistence')['rdb_last_bgsave_status'], 'ok')
        self.admin.call('MSET', 'saved:a', 'changed', 'saved:b', 'changed')
        self.admin.call('DEBUG', 'RELOAD', 'NOSAVE')
        self.assertEqual(self.admin.call('MGET', 'saved:a', 'saved:b'), [b'one', b'two\x00'])
        before = self.snapshot()
        self.assertEqual(self.admin.call('SET', 'post-fork', 'joined-and-resumed'), 'OK')
        self.assertGreater(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'])
        self.admin.send_many([('SET', 'shutdown:saved', 'latest'), ('SHUTDOWN', 'SAVE')])
        self.assertEqual(self.server.process.wait(timeout=10), 0)
        self.server.stop()
        self.server.start()
        client = self.server.client()
        self.assertEqual(client.call('MGET', 'saved:a', 'saved:b', 'post-fork', 'shutdown:saved'),
                         [b'one', b'two\x00', b'joined-and-resumed', b'latest'])

    def test_automatic_snapshot_threshold_sees_deferred_dirty(self):
        self.admin.call('CONFIG', 'SET', 'save', '1 1')
        self.admin.call('SAVE')
        before = self.snapshot()
        self.assertEqual(self.admin.call('SET', 'autosaved', 'worker-write'), 'OK')
        self.assertGreater(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'])
        wait_for(lambda: (row if row.get('rdb_changes_since_last_save') == '0'
                         and row.get('rdb_bgsave_in_progress') == '0' else None)
                 if (row := info(self.admin, 'persistence')) else None, timeout=6, label='automatic snapshot')
        self.admin.call('CONFIG', 'SET', 'save', '')
        self.admin.call('SET', 'autosaved', 'changed')
        self.admin.call('DEBUG', 'RELOAD', 'NOSAVE')
        self.assertEqual(self.admin.call('GET', 'autosaved'), b'worker-write')

    def test_memcached_metadata_uses_coordinator_while_plain_keys_use_workers(self):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        with server(arguments=('--memcached-port', str(port))) as shared:
            client = shared.client()
            self.assertEqual(client.pipeline([('SET', 'shared', 'redis-write'), ('GET', 'shared')]), ['OK', b'redis-write'])
            self.assertEqual(self.snapshot(client)['keyspace_jobs_submitted'], 2)
            with socket.create_connection(('127.0.0.1', port), timeout=10) as connection:
                stream = connection.makefile('rb')
                try:
                    connection.sendall(b'get shared\r\n')
                    self.assertEqual(stream.readline(), b'VALUE shared 0 11\r\n')
                    self.assertEqual(stream.readline(), b'redis-write\r\n')
                    self.assertEqual(stream.readline(), b'END\r\n')
                    connection.sendall(b'set shared 9 0 8\r\nmc-write\r\n')
                    self.assertEqual(stream.readline(), b'STORED\r\n')
                    self.assertEqual(client.call('GET', 'shared'), b'mc-write')
                    self.assertEqual(self.snapshot(client)['keyspace_jobs_submitted'], 2)
                finally:
                    stream.close()

    def test_aof_enable_rewrite_restart_and_disable_fence_actor_values(self):
        self.admin.call('SET', 'aof:before', 'actor-value')
        before = self.snapshot()
        self.admin.call('CONFIG', 'SET', 'appendonly', 'yes')
        self.admin.call('CONFIG', 'SET', 'appendfsync', 'always')
        wait_for(lambda: info(self.admin, 'persistence').get('aof_rewrite_in_progress') == '0'
                 and info(self.admin, 'persistence').get('aof_rewrite_scheduled') == '0', label='AOF enable rewrite')
        self.assertEqual(self.admin.pipeline([('SET', 'aof:after', 'logged-value'), ('GET', 'aof:before')]), ['OK', b'actor-value'])
        self.assertEqual(self.snapshot()['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'] + 2)
        self.admin.call('BGREWRITEAOF')
        wait_for(lambda: info(self.admin, 'persistence').get('aof_rewrite_in_progress') == '0', label='AOF explicit rewrite')
        self.admin.send('SHUTDOWN', 'NOSAVE')
        self.assertEqual(self.server.process.wait(timeout=10), 0)
        self.server.stop()
        self.server.arguments += ['--appendonly', 'yes', '--appendfsync', 'always']
        self.server.start()
        client = self.server.client()
        self.assertEqual(client.call('MGET', 'aof:before', 'aof:after'), [b'actor-value', b'logged-value'])
        before = self.snapshot(client)
        self.assertEqual(client.call('GET', 'aof:before'), b'actor-value')
        self.assertEqual(self.snapshot(client)['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'] + 1)
        client.call('CONFIG', 'SET', 'appendonly', 'no')
        self.assertEqual(client.call('SET', 'aof:disabled', 'worker-again'), 'OK')
        self.assertGreater(self.snapshot(client)['keyspace_jobs_submitted'], before['keyspace_jobs_submitted'])


def main(argv=None):
    global BINARY
    parser = argparse.ArgumentParser(description='Run isolated GET/plain SET worker correctness regressions; no benchmark collection.')
    parser.add_argument('--server', type=Path, default=Path(os.environ.get('ESKI_THREADING_BIN', ROOT/'bin/eski')))
    parser.add_argument('--case', default='*', help='unittest method glob')
    parser.add_argument('--timeout', type=int, default=180, help='whole-run wall-clock limit in seconds')
    args = parser.parse_args(argv)
    BINARY = args.server.resolve()
    if args.timeout <= 0 or not BINARY.is_file():
        parser.error('positive timeout and an existing --server binary are required')
    selected = [name for name in unittest.defaultTestLoader.getTestCaseNames(Keyspace) if fnmatch.fnmatchcase(name, args.case)]
    if not selected:
        parser.error('--case selected no tests')
    def expired(unused_signal, unused_frame):
        print('keyspace correctness exceeded its wall-clock limit', file=sys.stderr)
        raise SystemExit(124)
    old = signal.signal(signal.SIGALRM, expired)
    signal.alarm(args.timeout)
    try:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(Keyspace(name) for name in selected))
        return 0 if result.wasSuccessful() else 1
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


if __name__ == '__main__':
    raise SystemExit(main())
