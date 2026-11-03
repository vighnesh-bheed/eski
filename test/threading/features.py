import argparse
from concurrent.futures import ThreadPoolExecutor
import threading
import fnmatch
from pathlib import Path
import signal
import sys
import time
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from support import ROOT, Client, Server, ServerError, info, wait_for

BINARY = ROOT / 'bin/eski'
REFERENCE_PORT = None


class Features(unittest.TestCase):
    def setUp(self):
        self.server = Server(BINARY, workers=0, arguments=(
            '--keyspace-threads', '4', '--keyspace-max-memory', str(128 << 20)), queue_ping=True)
        self.server.start()
        self.addCleanup(self.server.close)
        self.client = self.server.client()

    def submitted(self, client=None):
        return int(info(client or self.client)['keyspace_jobs_submitted'])

    def worker_call(self, *args, client=None):
        c = client or self.client
        before = self.submitted(c)
        result = c.call_before_ping(*args)
        self.assertEqual(self.submitted(c), before + 1, args[:2])
        return result

    def test_watch_and_unrelated_idle_multi_keep_workers(self):
        watcher = self.server.client()
        idle = self.server.client()
        watcher.call('WATCH', 'watched')
        idle.call('MULTI')
        self.assertEqual(self.worker_call('SET', 'unrelated', 'v'), 'OK')
        self.assertEqual(self.worker_call('SET', 'watched', 'v'), 'OK')
        watcher.call('MULTI')
        watcher.call('GET', 'watched')
        self.assertIsNone(watcher.call('EXEC'))
        idle.call('DISCARD')
        watcher.call('WATCH', 'stable')
        self.worker_call('SET', 'unrelated', 'v2')
        watcher.call('MULTI')
        watcher.call('GET', 'stable')
        self.assertEqual(watcher.call('EXEC'), [None])

    def test_tracking_and_noloop_publish_after_reply(self):
        tracker = self.server.client()
        tracker.call('HELLO', 3)
        tracker.call('CLIENT', 'TRACKING', 'ON', 'NOLOOP')
        self.assertIsNone(self.worker_call('GET', 'tracked', client=tracker))
        self.worker_call('SET', 'tracked', 'other')
        tracker.call('PING')
        self.assertIn([b'invalidate', [b'tracked']], tracker.pushes)
        tracker.pushes.clear()
        self.worker_call('GET', 'self', client=tracker)
        self.worker_call('SET', 'self', 'mine', client=tracker)
        tracker.call('PING')
        self.assertEqual(tracker.pushes, [])
        tracker.call('CLIENT', 'TRACKING', 'OFF')

    def test_notifications_preserve_duplicate_write_event_order(self):
        self.client.call('CONFIG', 'SET', 'notify-keyspace-events', 'E$gn')
        subscriber = self.server.client()
        subscriber.call('PSUBSCRIBE', '__keyevent@0__:*')
        self.worker_call('MSET', 'events', 'first', 'events', 'second')
        observed = [subscriber.read() for _ in range(3)]
        self.assertEqual([(row[2], row[3]) for row in observed], [
            (b'__keyevent@0__:new', b'events'),
            (b'__keyevent@0__:set', b'events'),
            (b'__keyevent@0__:set', b'events')])
        self.assertEqual(self.client.call('GET', 'events'), b'second')

    def test_lone_commands_on_owned_records_publish_effects_once(self):
        actor = Client(self.server.port)
        self.addCleanup(actor.close)
        self.client.call('CONFIG', 'SET', 'notify-keyspace-events', 'E$g')
        subscriber = self.server.client()
        subscriber.call('PSUBSCRIBE', '__keyevent@0__:*')
        monitor = self.server.client()
        monitor.call('MONITOR')
        watcher = self.server.client()
        watcher.call('WATCH', 'inline')
        before = info(self.client)
        self.assertEqual(actor.pipeline([('SET', 'inline', 'worker'), ('GET', 'inline')]), ['OK', b'worker'])
        self.assertEqual(actor.call('APPEND', 'inline', '+coordinator'), 18)
        self.assertEqual(actor.call('GET', 'inline'), b'worker+coordinator')
        with self.assertRaises(ServerError):
            actor.call('INCR', 'inline')
        self.assertEqual(actor.call('DEL', 'inline'), 1)
        actor.send('CLIENT', 'REPLY', 'OFF')
        actor.send_many([('SET', 'quiet', 'worker'), ('GET', 'quiet')])
        lines = []
        while not lines or '"GET" "quiet"' not in lines[-1]:
            lines.append(str(monitor.read()))
        actor.send('SET', 'quiet', 'coordinator')
        while '"SET" "quiet" "coordinator"' not in lines[-1]:
            lines.append(str(monitor.read()))
        self.assertEqual(actor.pipeline([('CLIENT', 'REPLY', 'ON'), ('GET', 'quiet')]), ['OK', b'coordinator'])
        after = info(self.client)
        deltas = {name: int(after[name]) - int(before[name]) for name in ('keyspace_inline', 'keyspace_jobs_submitted', 'keyspace_sync_fallbacks', 'keyspace_barriers')}
        self.assertEqual(deltas, {'keyspace_inline': 6, 'keyspace_jobs_submitted': 4, 'keyspace_sync_fallbacks': 1, 'keyspace_barriers': 2})
        events = []
        while subscriber.available(0.05):
            frame = subscriber.read()
            events.append((frame[2], frame[3]))
        self.assertEqual(events, [(b'__keyevent@0__:set', b'inline'), (b'__keyevent@0__:append', b'inline'),
                                  (b'__keyevent@0__:del', b'inline'), (b'__keyevent@0__:set', b'quiet'),
                                  (b'__keyevent@0__:set', b'quiet')])
        watcher.call('MULTI')
        watcher.call('GET', 'inline')
        self.assertIsNone(watcher.call('EXEC'))
        actor.call('PING', 'inline-end')
        while '"inline-end"' not in lines[-1]:
            lines.append(str(monitor.read()))
        for command in ('"SET" "inline" "worker"', '"APPEND" "inline" "+coordinator"', '"INCR" "inline"',
                        '"DEL" "inline"', '"SET" "quiet" "coordinator"'):
            self.assertEqual(sum(command in line for line in lines), 1, command)
        self.assertEqual(sum('"GET" "inline"' in line for line in lines), 2)

    def test_monitor_sees_original_command_and_live_source(self):
        monitor = self.server.client()
        monitor.call('MONITOR')
        self.worker_call('HSET', 'monitored', 'field', 'value')
        deadline = time.monotonic() + 5
        lines = []
        while time.monotonic() < deadline:
            if monitor.available(0.1):
                line = monitor.read()
                lines.append(line)
                if '"HSET" "monitored" "field" "value"' in str(line):
                    break
        self.assertTrue(any('"HSET" "monitored" "field" "value"' in str(line) for line in lines), lines)
        self.assertFalse(any('"RESTORE" "monitored"' in str(line) for line in lines), lines)

    def test_blocked_key_falls_back_but_unrelated_keys_use_workers(self):
        waiter = self.server.client()
        waiter.send('BLPOP', 'waiting', 0)
        wait_for(lambda: int(info(self.client, 'clients')['blocked_clients']) == 1, label='blocked list waiter')
        self.worker_call('SET', 'unrelated', 'value')
        before = self.submitted()
        self.assertEqual(self.client.pipeline([('LPUSH', 'waiting', 'payload'), ('DEL', 'waiting'), ('PING',)]), [1, 0, 'PONG'])
        self.assertEqual(waiter.reply(), [b'waiting', b'payload'])
        self.assertEqual(self.submitted(), before + 1)
        self.worker_call('RPUSH', 'waiting', 'later')
        self.assertEqual(self.client.call('LPOP', 'waiting'), b'later')

    def test_aof_restart_replays_all_datatypes_and_cross_db(self):
        with Server(BINARY, workers=0, arguments=(
                '--keyspace-threads', '4', '--keyspace-max-memory', str(256 << 20),
                '--appendonly', 'yes', '--appendfsync', 'always'), queue_ping=True) as server:
            c = server.client()
            wait_for(lambda: info(c, 'persistence').get('aof_rewrite_in_progress') == '0', label='initial AOF rewrite')
            for command in [('SET', 'string', 'value', 'PX', 120000),
                            ('RPUSH', 'list', 'a', 'b'), ('SADD', 'set', 'a', 'b'),
                            ('HSET', 'hash', 'field', 'value'), ('ZADD', 'zset', 2, 'b', 1, 'a'),
                            ('XADD', 'stream', '1-0', 'field', 'value'),
                            ('COPY', 'hash', 'hash-copy', 'DB', 1)]:
                self.worker_call(*command, client=c)
            c.call('XGROUP', 'CREATE', 'stream', 'group', '0')
            c.call('XREADGROUP', 'GROUP', 'group', 'consumer', 'STREAMS', 'stream', '>')
            deadline = c.call('PEXPIRETIME', 'string')
            server.stop()
            server.start()
            c = server.client()
            self.assertEqual(c.call('GET', 'string'), b'value')
            self.assertEqual(c.call('PEXPIRETIME', 'string'), deadline)
            self.assertEqual(c.call('LRANGE', 'list', 0, -1), [b'a', b'b'])
            self.assertEqual(sorted(c.call('SMEMBERS', 'set')), [b'a', b'b'])
            self.assertEqual(c.call('HGETALL', 'hash'), [b'field', b'value'])
            self.assertEqual(c.call('ZRANGE', 'zset', 0, -1), [b'a', b'b'])
            self.assertEqual(c.call('XPENDING', 'stream', 'group')[0], 1)
            c.call('SELECT', 1)
            self.assertEqual(c.call('HGET', 'hash-copy', 'field'), b'value')

    def test_postimage_budget_failure_retries_once_without_duplicate_events(self):
        with Server(BINARY, workers=0, arguments=(
                '--keyspace-threads', '2', '--keyspace-max-memory', str(2 << 20),
                '--appendonly', 'yes', '--appendfsync', 'always'), queue_ping=True) as server:
            c = server.client()
            c.call('CONFIG', 'SET', 'notify-keyspace-events', 'E$')
            subscriber = server.client()
            subscriber.call('SUBSCRIBE', '__keyevent@0__:set')
            c.call('SET', 'rollback', 'old')
            subscriber.read()
            before = info(c)
            value = b'z' * (512 << 10)
            self.assertEqual(c.call_before_ping('SET', 'rollback', value), 'OK')
            self.assertEqual(subscriber.read(), [b'message', b'__keyevent@0__:set', b'rollback'])
            after = info(c)
            self.assertEqual(int(after['keyspace_jobs_submitted']), int(before['keyspace_jobs_submitted']) + 1)
            self.assertEqual(int(after['keyspace_sync_fallbacks']), int(before['keyspace_sync_fallbacks']) + 1)
            self.assertFalse(subscriber.available(0.05))
            self.assertEqual(c.call('STRLEN', 'rollback'), len(value))
            server.stop()
            server.start()
            self.assertEqual(server.client().call('GET', 'rollback'), value)






    def test_retry_tracking_and_suppressed_reply_transitions(self):
        with Server(BINARY, workers=0, arguments=(
                '--keyspace-threads', '2', '--keyspace-max-memory', str(2 << 20),
                '--appendonly', 'yes', '--appendfsync', 'always'), queue_ping=True) as server:
            admin, tracker = server.client(), server.client()
            tracker.call('HELLO', 3)
            tracker.call('CLIENT', 'TRACKING', 'ON', 'NOLOOP')
            self.assertIsNone(tracker.call('GET', 'suppressed'))
            before = info(admin)
            value = b's' * (512 << 10)
            tracker.send_many([('CLIENT', 'REPLY', 'SKIP'), ('SET', 'suppressed', value), ('PING', 'after-skip')])
            self.assertEqual(tracker.reply(), b'after-skip')
            self.assertEqual(tracker.pushes, [])
            self.assertEqual(admin.call('STRLEN', 'suppressed'), len(value))
            tracker.call('CLIENT', 'TRACKING', 'ON')
            tracker.call('GET', 'suppressed')
            tracker.send_many([('CLIENT', 'REPLY', 'OFF'), ('SET', 'suppressed', value),
                               ('CLIENT', 'REPLY', 'ON'), ('PING', 'after-off')])
            self.assertEqual(tracker.reply(), 'OK')
            self.assertEqual(tracker.reply(), b'after-off')
            self.assertIn([b'invalidate', [b'suppressed']], tracker.pushes)
            after = info(admin)
            self.assertGreaterEqual(int(after['keyspace_sync_fallbacks']), int(before['keyspace_sync_fallbacks']) + 2)

    def test_pressure_error_and_disjoint_accepted_retries_preserve_aof(self):
        for policy in ('noeviction', 'allkeys-lru'):
            with Server(BINARY, workers=0, arguments=(
                    '--keyspace-threads', '4', '--keyspace-max-memory', str(16 << 20),
                    '--appendonly', 'yes', '--appendfsync', 'always'), queue_ping=True) as server:
                c = server.client()
                c.call('SET', 'wrongtype', 'string')
                baseline = int(info(c, 'memory')['used_memory'])
                c.call('CONFIG', 'SET', 'maxmemory-policy', policy)
                c.call('CONFIG', 'SET', 'maxmemory', baseline + (12 << 20))
                before = info(c)
                commands = [('SET', 'retry-large', b'L' * (4 << 20)), ('SET', 'wrongtype', 'invalid', 'BADOPTION')]
                commands += [('SET', 'disjoint-' + str(i), bytes([65 + i]) * (256 << 10)) for i in range(12)]
                clients = [server.client() for _ in commands]
                barrier = threading.Barrier(len(commands))
                def perform(item):
                    actor, command = item
                    barrier.wait()
                    reply, pong = actor.pipeline([command, ('PING',)])
                    self.assertEqual(pong, 'PONG')
                    return reply
                with ThreadPoolExecutor(max_workers=len(commands)) as pool:
                    results = list(pool.map(perform, zip(clients, commands)))
                self.assertIsInstance(results[1], ServerError)
                self.assertTrue(all(result == 'OK' or isinstance(result, ServerError) for i, result in enumerate(results) if i != 1))
                c.call('CONFIG', 'SET', 'maxmemory', 0)
                after = info(c)
                self.assertGreater(int(after['keyspace_jobs_submitted']), int(before['keyspace_jobs_submitted']) + 1)
                self.assertGreater(int(after['keyspace_sync_fallbacks']), int(before['keyspace_sync_fallbacks']))
                keys = ['retry-large', 'wrongtype'] + ['disjoint-' + str(i) for i in range(12)]
                expected = c.call('MGET', *keys)
                for i, result in enumerate(results):
                    if i == 1:
                        continue
                    key = commands[i][1]
                    if policy == 'noeviction':
                        self.assertEqual(expected[keys.index(key)], commands[i][2] if result == 'OK' else None)
                server.stop()
                server.start()
                self.assertEqual(server.client().call('MGET', *keys), expected)

    def test_external_redis_replays_canonical_aof(self):
        if REFERENCE_PORT is None:
            self.skipTest('requires --reference-port for an explicitly disposable local Redis instance')
        reference = Client(REFERENCE_PORT)
        self.addCleanup(reference.close)
        for db in range(16):
            reference.call('SELECT', db)
            self.assertEqual(reference.call('DBSIZE'), 0, 'reference must be disposable and empty')
        reference.call('SELECT', 0)
        with Server(BINARY, workers=0, arguments=(
                '--keyspace-threads', '4', '--keyspace-max-memory', str(256 << 20),
                '--appendonly', 'yes', '--appendfsync', 'always',
                '--aof-use-rdb-preamble', 'no'), queue_ping=True) as server:
            c = server.client()
            c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
            deadline = 1893456000000
            commands = [
                ('SET', 'string', 'first'), ('APPEND', 'string', '-second'),
                ('SET', 'ttl', 'value', 'PXAT', deadline),
                ('RPUSH', 'list', 'a', 'b'), ('LSET', 'list', 0, 'A'),
                ('SADD', 'set', 'a', 'b'), ('SMOVE', 'set', 'set', 'a'),
                ('HSET', 'hash', 'f', 'v', 'g', 'w'),
                ('HPEXPIREAT', 'hash', deadline, 'FIELDS', 1, 'f'),
                ('HSET', 'hash', 'g', 'updated'),
                ('HSET', 'hash-float', 'f', 1),
                ('HPEXPIREAT', 'hash-float', deadline, 'FIELDS', 1, 'f'),
                ('HINCRBYFLOAT', 'hash-float', 'f', '.5'),
                ('ZADD', 'zset', 1, 'a', 2, 'b'), ('ZINCRBY', 'zset', 3, 'a'),
                ('XADD', 'stream', '1-0', 'f', 'v'), ('XADD', 'stream', '2-0', 'f', 'w'),
                ('XGROUP', 'CREATE', 'stream', 'group', '0'),
                ('XREADGROUP', 'GROUP', 'group', 'consumer', 'COUNT', 1, 'STREAMS', 'stream', '>'),
                ('SET', 'bitmap-noop', b''),
                ('BITFIELD', 'bitmap-noop', 'OVERFLOW', 'FAIL', 'INCRBY', 'u8', 800, 256),
                ('COPY', 'hash', 'hash-copy', 'DB', 1),
                ('COPY', 'list', 'list-copy'), ('RENAME', 'list-copy', 'renamed'),
                ('RENAME', 'renamed', 'renamed'), ('MOVE', 'renamed', 2),
                ('HSET', 'hash', 'g', 'final'), ('LPUSH', 'hash', 'wrongtype'),
                ('MSET', 'alias', 'before', 'alias', 'after', 'tail', 'accepted')]
            replies = c.pipeline(commands)
            self.assertEqual(sum(isinstance(value, ServerError) for value in replies), 1)
            self.assertIsInstance(replies[-2], ServerError)
            c.call('SET', 'passive-expiry', 'old', 'PX', 30)
            time.sleep(0.06)
            self.assertIsNone(c.call('GET', 'passive-expiry'))
            checks = [(0, ('MGET', 'string', 'ttl', 'alias', 'tail', 'passive-expiry')),
                      (0, ('PEXPIRETIME', 'ttl')), (0, ('LRANGE', 'list', 0, -1)),
                      (0, ('SMEMBERS', 'set')), (0, ('HGETALL', 'hash')),
                      (0, ('HPEXPIRETIME', 'hash', 'FIELDS', 1, 'f')),
                      (0, ('HGET', 'hash-float', 'f')),
                      (0, ('HPEXPIRETIME', 'hash-float', 'FIELDS', 1, 'f')),
                      (0, ('ZRANGE', 'zset', 0, -1, 'WITHSCORES')),
                      (0, ('XRANGE', 'stream', '-', '+')), (0, ('XPENDING', 'stream', 'group')),
                      (1, ('HGETALL', 'hash-copy')), (2, ('LRANGE', 'renamed', 0, -1))]
            expected = []
            for db, command in checks:
                c.call('SELECT', db)
                value = c.call(*command)
                expected.append(sorted(value) if command[0] == 'SMEMBERS' else value)
            c.call('SELECT', 0)
            self.assertGreater(c.call('STRLEN', 'bitmap-noop'), 0)
            dirname = c.call('CONFIG', 'GET', 'appenddirname')[1].decode()
            server.stop()
            directory = server.directory / dirname
            manifest = next(directory.glob('*.manifest'))
            files = []
            for line in manifest.read_text().splitlines():
                words = line.split()
                if len(words) >= 6 and words[0] == 'file' and words[4] == 'type' and words[5] in ('b', 'i'):
                    files.append(directory / words[1])
            self.assertTrue(files)
            replayed = []
            for path in files:
                for args in aof_commands(path.read_bytes()):
                    reply = reference.call(*args)
                    assert_no_errors(self, reply)
                    replayed.append(args)
            self.assertTrue(any(args[0].upper() == b'RESTORE' for args in replayed))
            self.assertTrue(any(args[0].upper() == b'DEL' and args[1] == b'passive-expiry' for args in replayed))
            for (db, command), value in zip(checks, expected):
                reference.call('SELECT', db)
                actual = reference.call(*command)
                self.assertEqual(sorted(actual) if command[0] == 'SMEMBERS' else actual, value, (db, command))
            reference.call('SELECT', 0)
            self.assertEqual(reference.call('GET', 'bitmap-noop'), b'')

    def test_pause_write_preserves_passive_expiry_and_unrelated_workers(self):
        c = self.client
        c.call('SET', 'live', 'value')
        c.call('SET', 'expired', 'old', 'PX', 50)
        c.call('HSET', 'hash', 'field', 'old')
        c.call('HPEXPIRE', 'hash', 50, 'FIELDS', 1, 'field')
        c.call('CLIENT', 'PAUSE', 2000, 'WRITE')
        time.sleep(0.08)
        before = info(c, 'stats')
        self.assertEqual(self.worker_call('GET', 'live'), b'value')
        submitted = self.submitted()
        self.assertIsNone(c.call_before_ping('GET', 'expired'))
        self.assertIsNone(c.call_before_ping('HGET', 'hash', 'field'))
        self.assertEqual(self.submitted(), submitted)
        self.assertEqual(c.call('DBSIZE'), 3)
        after = info(c, 'stats')
        self.assertEqual(after['expired_keys'], before['expired_keys'])
        c.call('CLIENT', 'UNPAUSE')
        self.assertIsNone(c.call('GET', 'expired'))
        self.assertIsNone(c.call('HGET', 'hash', 'field'))

    def test_aggregated_hash_expiry_notifies_once_and_invalidates_watch(self):
        c = self.client
        c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        fields = ['field-' + str(i) for i in range(1000)]
        args = [item for field in fields for item in (field, 'value')]
        c.call('HSET', 'expiring-hash', *args)
        c.call('HPEXPIRE', 'expiring-hash', 30, 'FIELDS', len(fields), *fields)
        watcher, subscriber = self.server.client(), self.server.client()
        watcher.call('WATCH', 'expiring-hash')
        c.call('CONFIG', 'SET', 'notify-keyspace-events', 'Ehg')
        subscriber.call('PSUBSCRIBE', '__keyevent@0__:*')
        time.sleep(0.06)
        self.assertIsNone(self.worker_call('HRANDFIELD', 'expiring-hash'))
        events = [subscriber.read(), subscriber.read()]
        self.assertEqual([(row[2], row[3]) for row in events], [
            (b'__keyevent@0__:hexpired', b'expiring-hash'),
            (b'__keyevent@0__:del', b'expiring-hash')])
        self.assertFalse(subscriber.available(0.02))
        watcher.call('MULTI')
        watcher.call('EXISTS', 'expiring-hash')
        self.assertIsNone(watcher.call('EXEC'))

    def test_typed_notification_sequences_match_coordinator(self):
        commands = [
            ('SET', 'string', 'value'), ('APPEND', 'string', '!'),
            ('SETBIT', 'bits', 3, 1), ('BITFIELD', 'bits', 'SET', 'u4', 0, 3),
            ('PFADD', 'hll', 'a'), ('PFMERGE', 'hll-copy', 'hll'),
            ('RPUSH', 'list', 'a', 'b', 'c'), ('LSET', 'list', 1, 'B'),
            ('LINSERT', 'list', 'AFTER', 'B', 'x'), ('LMOVE', 'list', 'list2', 'LEFT', 'RIGHT'),
            ('LTRIM', 'list', 0, 0), ('LREM', 'list', 0, 'B'), ('RPOP', 'list2'),
            ('SADD', 'set', 'a', 'b'), ('SMOVE', 'set', 'set2', 'a'),
            ('SREM', 'set', 'b'), ('SUNIONSTORE', 'set3', 'set2'), ('SPOP', 'set3'),
            ('HSET', 'hash', 'a', 1, 'b', 2), ('HINCRBY', 'hash', 'a', 1),
            ('HINCRBYFLOAT', 'hash', 'b', '0.5'),
            ('HPEXPIRE', 'hash', 60000, 'FIELDS', 1, 'a'),
            ('HPERSIST', 'hash', 'FIELDS', 1, 'a'), ('HDEL', 'hash', 'a', 'b'),
            ('ZADD', 'zset', 1, 'a', 2, 'b'), ('ZADD', 'zset', 'INCR', 1, 'a'),
            ('ZRANGESTORE', 'zset2', 'zset', 0, -1), ('ZREM', 'zset', 'a'),
            ('ZPOPMAX', 'zset'), ('ZREMRANGEBYRANK', 'zset2', 0, -1),
            ('GEOADD', 'geo', 13.361389, 38.115556, 'Palermo'),
            ('GEOSEARCHSTORE', 'geo2', 'geo', 'FROMMEMBER', 'Palermo', 'BYRADIUS', 100, 'km'),
            ('XADD', 'stream', '1-0', 'f', 'v'), ('XADD', 'stream', '2-0', 'f', 'w'),
            ('XTRIM', 'stream', 'MAXLEN', 1), ('XGROUP', 'CREATE', 'stream', 'g', '0'),
            ('XGROUP', 'CREATECONSUMER', 'stream', 'g', 'c'),
            ('XREADGROUP', 'GROUP', 'g', 'c', 'STREAMS', 'stream', '>'),
            ('XACK', 'stream', 'g', '2-0'), ('XGROUP', 'DELCONSUMER', 'stream', 'g', 'c'),
            ('XDEL', 'stream', '2-0'), ('XGROUP', 'DESTROY', 'stream', 'g'),
            ('COPY', 'string', 'copied'), ('RENAME', 'copied', 'renamed'),
            ('DEL', 'renamed'), ('GET', 'absent')]
        transcripts = []
        for workers in (0, 4):
            with Server(BINARY, workers=0, arguments=(
                    '--keyspace-threads', str(workers), '--keyspace-max-memory', str(128 << 20)), queue_ping=workers > 0) as server:
                actor, subscriber = server.client(), server.client()
                actor.call('CONFIG', 'SET', 'notify-keyspace-events', 'AEnm')
                subscriber.call('PSUBSCRIBE', '__keyevent@0__:*')
                rows = []
                for command in commands:
                    result, pong = actor.pipeline([command, ('PING',)])
                    self.assertEqual(pong, 'PONG')
                    events = []
                    while subscriber.available(0.01):
                        frame = subscriber.read()
                        events.append((frame[2], frame[3]))
                    rows.append((result, events))
                transcripts.append(rows)
        for command, reference, threaded in zip(commands, *transcripts):
            with self.subTest(command=command):
                self.assertEqual(threaded, reference)

    def test_pipelined_retries_and_suppression_keep_order_and_aof(self):
        with Server(BINARY, workers=0, arguments=(
                '--keyspace-threads', '2', '--keyspace-max-memory', str(16 << 20),
                '--appendonly', 'yes', '--appendfsync', 'always'), queue_ping=True) as server:
            c = server.client()
            wait_for(lambda: info(c, 'persistence').get('aof_rewrite_in_progress') == '0', label='initial AOF rewrite')
            before = info(c)
            large = b'p' * (4 << 20)
            c.send_many([('SET', 'pipe:n', 1), ('INCR', 'pipe:n'), ('SET', 'pipe:large', large), ('INCR', 'pipe:n'),
                         ('LPUSH', 'pipe:n', 'x'), ('GET', 'pipe:n'), ('CLIENT', 'REPLY', 'SKIP'),
                         ('SET', 'pipe:skipped', large), ('INCR', 'pipe:n'), ('APPEND', 'pipe:tail', 'z'),
                         ('STRLEN', 'pipe:large')])
            replies = [c.reply() for _ in range(9)]
            self.assertEqual(replies[:4], ['OK', 2, 'OK', 3])
            self.assertIsInstance(replies[4], ServerError)
            self.assertTrue(str(replies[4]).startswith('WRONGTYPE'), replies[4])
            self.assertEqual(replies[5:], [b'3', 4, 1, len(large)])
            self.assertFalse(c.available(0.05))
            after = info(c)
            self.assertGreaterEqual(int(after['keyspace_jobs_submitted']), int(before['keyspace_jobs_submitted']) + 8)
            self.assertGreaterEqual(int(after['keyspace_sync_fallbacks']), int(before['keyspace_sync_fallbacks']) + 2)
            expected = c.pipeline([('GET', 'pipe:n'), ('STRLEN', 'pipe:large'), ('STRLEN', 'pipe:skipped'), ('GET', 'pipe:tail')])
            self.assertEqual(expected, [b'4', len(large), len(large), b'z'])
            server.stop()
            server.start()
            restored = server.client()
            self.assertEqual(restored.pipeline([('GET', 'pipe:n'), ('STRLEN', 'pipe:large'), ('STRLEN', 'pipe:skipped'),
                                                ('GET', 'pipe:tail')]), expected)

    def test_disconnected_accepted_mutation_remains_durable(self):
        with Server(BINARY, workers=0, arguments=(
                '--keyspace-threads', '4', '--keyspace-max-memory', str(128 << 20),
                '--appendonly', 'yes', '--appendfsync', 'always'), queue_ping=True) as server:
            c = server.client()
            writer = server.client()
            writer.send('MSET', 'disconnect', 'first-second', 'disconnect-peer', 'accepted')
            writer.socket.shutdown(1)
            wait_for(lambda: c.call('GET', 'disconnect') == b'first-second', label='accepted disconnected writes')
            server.stop()
            server.start()
            restored = server.client()
            self.assertEqual(restored.call('MGET', 'disconnect', 'disconnect-peer'), [b'first-second', b'accepted'])



def aof_commands(data):
    at = 0
    def line():
        nonlocal at
        end = data.index(b'\r\n', at)
        value = data[at:end]
        at = end + 2
        return value
    while at < len(data):
        header = line()
        if header.startswith(b'#'):
            continue
        if not header.startswith(b'*'):
            raise AssertionError('canonical AOF must contain RESP commands')
        args = []
        for _ in range(int(header[1:])):
            size = line()
            if not size.startswith(b'$'):
                raise AssertionError('canonical AOF arguments must be bulk strings')
            length = int(size[1:])
            args.append(data[at:at + length])
            at += length
            if data[at:at + 2] != b'\r\n':
                raise AssertionError('truncated canonical AOF argument')
            at += 2
        yield args


def assert_no_errors(test, value):
    test.assertNotIsInstance(value, ServerError)
    if isinstance(value, list):
        for item in value:
            assert_no_errors(test, item)


def main(argv=None):
    global BINARY, REFERENCE_PORT
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--case', default='*')
    parser.add_argument('--reference-port', type=int, help='explicitly disposable empty local Redis instance')
    parser.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args(argv)
    BINARY = args.server.resolve()
    REFERENCE_PORT = args.reference_port
    if args.timeout <= 0 or not BINARY.is_file():
        parser.error('positive timeout and existing server binary required')
    names = [name for name in unittest.defaultTestLoader.getTestCaseNames(Features)
             if fnmatch.fnmatchcase(name, args.case)]
    if not names:
        parser.error('case selected no tests')
    signal.alarm(args.timeout)
    try:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(Features(name) for name in names))
        return 0 if result.wasSuccessful() else 1
    finally:
        signal.alarm(0)


if __name__ == '__main__':
    raise SystemExit(main())
