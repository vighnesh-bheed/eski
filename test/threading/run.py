import argparse
from concurrent.futures import ThreadPoolExecutor
import ctypes
import fnmatch
import os
from pathlib import Path
import random
import signal
import socket
import sys
import time
import unittest


sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from support import Client, Push, ROOT, Server, ServerError, compute_info, encode, info, is_subsequence, lcs_length, thread_cpu, wait_for


BINARY = ROOT/'bin/eski'


class Threading(unittest.TestCase):
    def setUp(self):
        self.server = Server(BINARY)
        self.addCleanup(self.server.close)
        self.server.start()
        self.admin = self.server.client()

    def pair(self, length=4096, prefix='work', client=None):
        client = client or self.admin
        value = (b'abcd\x00efg'*(length//8+1))[:length]
        left, right = prefix+':a', prefix+':b'
        self.assertEqual(client.call('MSET', left, value, right, value), 'OK')
        return left, right, value

    def idle(self, client=None):
        client = client or self.admin
        return wait_for(lambda: (value if value['compute_jobs_pending'] == 0 and value['compute_memory_reserved'] == 0 else None)
                        if (value := compute_info(client)) else None, label='compute reclamation')

    def pending(self, minimum=1, client=None):
        client = client or self.admin
        return wait_for(lambda: value if (value := compute_info(client))['compute_jobs_pending'] >= minimum else None,
                        timeout=5, label='accepted asynchronous work')

    def test_default_and_startup_only_configuration(self):
        def inspect(client, expected):
            for name, value in expected.items():
                self.assertEqual(client.call('CONFIG', 'GET', name), [name.encode(), value])
                self.assertEqual(client.call('CONFIG', 'GET', name.upper()), [name.upper().encode(), value])
            for pattern in ('*', 'compute-*', 'COMPUTE-*'):
                reply = client.call('CONFIG', 'GET', pattern)
                names = {value.decode() for value in reply[::2]}
                self.assertTrue(names.isdisjoint(expected), (pattern, names & expected.keys()))
            for name, current in expected.items():
                for value in (current, b'1'):
                    client.send('CONFIG', 'SET', name, value)
                    error = client.reply()
                    self.assertIsInstance(error, ServerError)
                    self.assertIn('immutable', str(error).lower())
                    self.assertEqual(client.call('CONFIG', 'GET', name), [name.encode(), current])
        with Server(BINARY, workers=None) as default:
            client = default.client()
            values = compute_info(client)
            self.assertEqual(values['compute_threads_configured'], 0)
            self.assertEqual(values['compute_threads_active'], 0)
            inspect(client, {'compute-threads': b'0', 'compute-max-memory': b'134217728'})
        values = compute_info(self.admin)
        self.assertEqual(values['compute_threads_configured'], 2)
        inspect(self.admin, {'compute-threads': b'2', 'compute-max-memory': str(self.server.memory).encode()})

    def test_lcs_matches_independent_model_and_disabled_replies(self):
        rng = random.Random(719)
        with Server(BINARY, workers=0) as reference:
            plain = reference.client()
            enabled = self.server.client()
            pairs = [(b'', b''), (b'\x00a\xffb', b'\xff\x00b'), (b'ababa', b'babab')]
            pairs += [(bytes(rng.randrange(5) for _ in range(rng.randrange(1, 35))),
                       bytes(rng.randrange(5) for _ in range(rng.randrange(1, 35)))) for _ in range(35)]
            pairs += [(b'abcd'*270, b'bcad'*270)]
            for left, right in pairs:
                expected = lcs_length(left, right)
                for client in (plain, enabled):
                    client.call('MSET', 'model:a', left, 'model:b', right)
                for options in ((), ('LEN',), ('IDX',), ('IDX', 'WITHMATCHLEN'), ('IDX', 'MINMATCHLEN', 3, 'WITHMATCHLEN')):
                    first = plain.call('LCS', 'model:a', 'model:b', *options)
                    second = enabled.call('LCS', 'model:a', 'model:b', *options)
                    self.assertEqual(second, first, (len(left), len(right), options))
                    if not options:
                        self.assertEqual(len(second), expected)
                        self.assertTrue(is_subsequence(second, left) and is_subsequence(second, right))
                    elif options == ('LEN',):
                        self.assertEqual(second, expected)
                    else:
                        fields = dict(zip(second[::2], second[1::2]))
                        self.assertEqual(fields[b'len'], expected)
                        previous_a, previous_b = len(left), len(right)
                        for match in fields[b'matches']:
                            (a0, a1), (b0, b1) = match[:2]
                            self.assertLess(a1, previous_a)
                            self.assertLess(b1, previous_b)
                            self.assertEqual(left[a0:a1+1], right[b0:b1+1])
                            self.assertEqual(a1-a0, b1-b0)
                            if len(match) == 3:
                                self.assertEqual(match[2], a1-a0+1)
                            previous_a, previous_b = a0, b0
            self.assertGreater(self.idle()['compute_jobs_submitted'], 0)
            self.assertEqual(compute_info(plain)['compute_jobs_submitted'], 0)

    def test_error_precedence_two_key_acl_and_getkeys(self):
        self.admin.call('LPUSH', 'wrong', 'v')
        self.admin.send('LCS', 'wrong', 'missing', 'BOGUS')
        self.assertIn('must contain string values', str(self.admin.reply()))
        self.admin.send('LCS', 'missing', 'missing2', 'BOGUS')
        self.assertIn('syntax error', str(self.admin.reply()))
        self.assertEqual(self.admin.call('COMMAND', 'GETKEYS', 'LCS', 'allowed:a', 'outside:b', 'LEN'), [b'allowed:a', b'outside:b'])
        a, b, value = self.pair(1100, 'allowed')
        self.admin.call('SET', 'outside:b', value)
        self.admin.call('ACL', 'SETUSER', 'limited', 'on', '>secret', '+lcs', '~allowed:*')
        client = self.server.client()
        self.assertEqual(client.call('AUTH', 'limited', 'secret'), 'OK')
        self.assertEqual(client.call('LCS', a, b, 'LEN'), len(value))
        for keys in ((a, 'outside:b'), ('outside:b', a)):
            client.send('LCS', *keys, 'LEN')
            error = client.reply()
            self.assertIsInstance(error, ServerError)
            self.assertIn('NOPERM', str(error))

    def test_async_pipeline_preserves_effects_protocol_and_database(self):
        a, b, value = self.pair()
        client = self.server.client()
        commands = [('LCS', a, b, 'LEN'), ('SET', a, 'changed'), ('STRLEN', a), ('ECHO', 'after-lcs'),
                    ('SELECT', 1), ('SET', a, 'other-db'), ('SELECT', 0), ('GET', a)]
        encoded = b''.join(encode(command) for command in commands)
        client.socket.sendall(encoded[:17])
        client.socket.sendall(encoded[17:])
        self.assertEqual([client.reply() for _ in commands], [len(value), 'OK', 7, b'after-lcs', 'OK', 'OK', 'OK', b'changed'])
        self.pair(1100, 'protocol')
        client.send_many([('LCS', 'protocol:a', 'protocol:b', 'LEN'), ('HELLO', 3),
                          ('LCS', 'protocol:a', 'protocol:b', 'IDX', 'WITHMATCHLEN'), ('ECHO', 'done')])
        self.assertEqual(client.reply(), 1100)
        self.assertIsInstance(client.reply(), dict)
        result = client.reply()
        self.assertEqual(result[b'len'], 1100)
        self.assertEqual(client.reply(), b'done')
        self.assertGreater(self.idle()['compute_jobs_completed'], 0)

    def test_reply_suppression_and_exec_stay_ordered(self):
        a, b, value = self.pair(1100)
        client = self.server.client()
        client.send_many([('CLIENT', 'REPLY', 'OFF'), ('LCS', a, b, 'LEN'), ('CLIENT', 'REPLY', 'ON'), ('PING', 'on'),
                          ('CLIENT', 'REPLY', 'SKIP'), ('LCS', a, b, 'LEN'), ('PING', 'after-skip')])
        self.assertEqual([client.reply() for _ in range(3)], ['OK', b'on', b'after-skip'])
        self.idle()
        before = compute_info(self.admin)
        replies = client.pipeline([('MULTI',), ('SET', 'tx:a', value), ('SET', 'tx:b', value),
                                   ('LCS', 'tx:a', 'tx:b', 'LEN'), ('GET', 'tx:a'), ('EXEC',), ('PING',)])
        self.assertEqual(replies[:5], ['OK', 'QUEUED', 'QUEUED', 'QUEUED', 'QUEUED'])
        self.assertEqual(replies[5], ['OK', 'OK', len(value), value])
        self.assertEqual(replies[6], 'PONG')
        after = self.idle()
        self.assertEqual(after['compute_jobs_submitted'], before['compute_jobs_submitted'])

    def test_snapshot_owns_values_during_mutation_deletion_and_expiry(self):
        for mutation in ('SET', 'UNLINK', 'FLUSHDB', 'PEXPIRE'):
            a, b, value = self.pair(6144, 'snapshot')
            client = self.server.client()
            client.send('LCS', a, b, 'LEN')
            self.pending()
            if mutation == 'SET':
                self.admin.call('MSET', a, b'x'*len(value), b, b'y'*len(value))
            elif mutation == 'PEXPIRE':
                self.admin.call('PEXPIRE', a, 1)
                self.admin.call('PEXPIRE', b, 1)
            elif mutation == 'UNLINK':
                self.admin.call('UNLINK', a, b)
            else:
                self.admin.call('FLUSHDB', 'ASYNC')
            self.assertEqual(client.reply(), len(value), mutation)
            self.idle()
            client.close()
        self.admin.call('MSET', 'epoch:a', b'a'*1100, 'epoch:b', b'a'*1100)
        def write_epochs():
            writer = self.server.client()
            try:
                for at in range(25):
                    value = bytes([97+at%2])*1100
                    writer.call('MSET', 'epoch:a', value, 'epoch:b', value)
            finally:
                writer.close()
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(write_epochs)
            reader = self.server.client()
            for _ in range(25):
                self.assertEqual(reader.call('LCS', 'epoch:a', 'epoch:b', 'LEN'), 1100)
            future.result(timeout=10)
        self.idle()

    def test_disconnect_cancel_and_reused_connections_reclaim_once(self):
        a, b, value = self.pair(6144)
        before = self.idle()
        first, second = self.server.client(), self.server.client()
        old_fds = {int(dict(value.split(b'=', 1) for value in client.call('CLIENT', 'INFO').split())[b'fd']) for client in (first, second)}
        second_id = second.call('CLIENT', 'ID')
        first.send('LCS', a, b, 'LEN')
        second.send('LCS', a, b, 'LEN')
        self.pending(2)
        first.close()
        self.assertEqual(self.admin.call('CLIENT', 'KILL', 'ID', second_id), 1)
        second.close()
        reused = False
        replacements = []
        for at in range(35):
            replacement = self.server.client()
            replacements.append(replacement)
            new_fd = int(dict(value.split(b'=', 1) for value in replacement.call('CLIENT', 'INFO').split())[b'fd'])
            reused |= new_fd in old_fds
            self.assertEqual(replacement.call('ECHO', 'replacement-%d' % at), ('replacement-%d' % at).encode())
        after = self.idle()
        self.assertEqual(after['compute_jobs_submitted']-before['compute_jobs_submitted'], 2)
        self.assertGreaterEqual(after['compute_jobs_cancelled']-before['compute_jobs_cancelled'], 1)
        self.assertEqual(after['compute_jobs_pending'], 0)
        self.assertEqual(after['compute_memory_reserved'], 0)
        self.assertTrue(reused, 'the replacement loop did not exercise server FD reuse')
        for replacement in replacements:
            replacement.close()

    def test_memory_pressure_falls_back_without_changing_replies(self):
        with Server(BINARY, workers=1, memory=1 << 20) as limited:
            client = limited.client()
            a, b, value = self.pair(1100, 'limited', client)
            before = compute_info(client)
            self.assertEqual(client.call('LCS', a, b, 'LEN'), len(value))
            after = compute_info(client)
            self.assertEqual(after['compute_jobs_submitted'], before['compute_jobs_submitted'])
            self.assertGreater(after['compute_sync_fallbacks'], before['compute_sync_fallbacks'])
            self.assertEqual(after['compute_memory_reserved'], 0)
        with Server(BINARY, workers=1, memory=80 << 20) as limited:
            admin = limited.client()
            a, b, value = self.pair(4096, 'pressure', admin)
            clients = [limited.client() for _ in range(5)]
            for client in clients:
                client.send('LCS', a, b, 'LEN')
            peak = compute_info(admin)
            self.assertLessEqual(peak['compute_jobs_pending'], 64)
            self.assertLessEqual(peak['compute_memory_reserved'], 80 << 20)
            for client in clients:
                self.assertEqual(client.reply(), len(value))
            values = wait_for(lambda: row if (row := compute_info(admin))['compute_jobs_pending'] == 0 else None,
                              label='limited pool drain')
            self.assertEqual(values['compute_memory_reserved'], 0)
            self.assertGreater(values['compute_sync_fallbacks'], 0)

    def test_monitor_and_accounting_complete_once_in_admission_order(self):
        a, b, value = self.pair(6144, 'tracked')
        tracker, monitor = self.server.client(), self.server.client()
        tracker.call('HELLO', 3)
        monitor.call('MONITOR')
        self.admin.call('CONFIG', 'SET', 'slowlog-log-slower-than', 0)
        before = info(self.admin, 'commandstats').get('cmdstat_lcs', 'calls=0')
        calls_before = int(before.split('calls=', 1)[1].split(',', 1)[0])
        tracker.send('LCS', a, b, 'LEN')
        self.pending()
        self.admin.call('MSET', a, 'changed', b, 'changed')
        self.assertEqual(tracker.reply(), len(value))
        self.idle()
        after = info(self.admin, 'commandstats')['cmdstat_lcs']
        self.assertEqual(int(after.split('calls=', 1)[1].split(',', 1)[0])-calls_before, 1)
        slow = self.admin.call('SLOWLOG', 'GET', 128)
        self.assertEqual(sum(row[3][0].lower() == b'lcs' for row in slow), 1)
        lines = []
        while monitor.available(0.05):
            lines.append(monitor.read())
        self.assertEqual(sum('"lcs"' in str(line).lower() for line in lines), 1)
        command_at = next(at for at, line in enumerate(lines) if '"lcs"' in str(line).lower())
        mutation_at = next(at for at, line in enumerate(lines) if '"mset"' in str(line).lower())
        self.assertLess(command_at, mutation_at)

    def test_tracked_source_falls_back_and_replies_before_invalidation(self):
        a, b, value = self.pair(4096, 'tracking')
        tracker = self.server.client()
        tracker.call('HELLO', 3)
        tracker.call('CLIENT', 'TRACKING', 'ON')
        monitor = self.server.client()
        monitor.call('MONITOR')
        before = compute_info(self.admin)
        tracker.send('LCS', a, b, 'LEN')
        while '"lcs"' not in str(monitor.read()).lower():
            pass
        self.admin.call('MSET', a, 'new', b, 'new')
        self.assertEqual(tracker.read(), len(value))
        invalidated = set()
        while not {a.encode(), b.encode()} <= invalidated:
            frame = tracker.read()
            self.assertIsInstance(frame, Push)
            self.assertEqual(frame[0], b'invalidate')
            invalidated.update(frame[1])
        after = self.idle()
        self.assertEqual(after['compute_jobs_submitted'], before['compute_jobs_submitted'])
        self.assertGreater(after['compute_sync_fallbacks'], before['compute_sync_fallbacks'])

    def test_other_clients_keep_atomic_counters_watch_and_transfers(self):
        a, b, value = self.pair(4096, 'watch')
        watcher = self.server.client()
        watcher.call('WATCH', a, b)
        watcher.send('LCS', a, b, 'LEN')
        self.pending()
        self.admin.call('SET', a, 'changed')
        self.assertEqual(watcher.reply(), len(value))
        self.assertEqual(watcher.pipeline([('MULTI',), ('SET', 'watch:result', 'bad'), ('EXEC',)]), ['OK', 'QUEUED', None])
        self.admin.call('SET', 'counter', 0)
        def increments():
            client = self.server.client()
            try:
                return [client.call('INCR', 'counter') for _ in range(150)]
            finally:
                client.close()
        with ThreadPoolExecutor(max_workers=6) as pool:
            values = [value for result in pool.map(lambda unused: increments(), range(6)) for value in result]
        self.assertEqual(sorted(values), list(range(1, 901)))
        self.assertEqual(self.admin.call('GET', 'counter'), b'900')
        self.admin.call('MSET', 'balance:a', 500, 'balance:b', 500)
        def transfers():
            client = self.server.client()
            try:
                for _ in range(80):
                    self.assertEqual(client.pipeline([('MULTI',), ('DECR', 'balance:a'), ('INCR', 'balance:b'), ('EXEC',)])[:3],
                                     ['OK', 'QUEUED', 'QUEUED'])
            finally:
                client.close()
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(transfers)
            for _ in range(100):
                self.assertEqual(sum(map(int, self.admin.call('MGET', 'balance:a', 'balance:b'))), 1000)
            future.result(timeout=10)

    def test_keyspace_blocking_and_pause_preserve_connection_order(self):
        a, b, value = self.pair(4096)
        waiters = [self.server.client() for _ in range(5)]
        for client in waiters:
            client.send_many([('BLPOP', 'waiting', 0), ('PING', 'after-block')])
        wait_for(lambda: info(self.admin, 'clients').get('blocked_clients') == '5', label='five keyspace waiters')
        worker = self.server.client()
        worker.send('LCS', a, b, 'LEN')
        self.pending()
        self.assertEqual(self.admin.call('PING'), 'PONG')
        self.assertEqual(worker.reply(), len(value))
        self.admin.call('RPUSH', 'waiting', *range(5))
        for at, client in enumerate(waiters):
            self.assertEqual(client.reply(), [b'waiting', str(at).encode()])
            self.assertEqual(client.reply(), b'after-block')
        self.admin.call('CLIENT', 'PAUSE', 5000, 'WRITE')
        worker.send_many([('LCS', a, b, 'LEN'), ('SET', 'paused-write', 'done'), ('PING', 'resumed')])
        self.pending()
        self.assertEqual(worker.reply(), len(value))
        self.assertEqual(self.admin.call('GET', 'paused-write'), None)
        self.admin.call('CLIENT', 'UNPAUSE')
        self.assertEqual(worker.reply(), 'OK')
        self.assertEqual(worker.reply(), b'resumed')

    def test_forks_finish_work_and_restart_workers_and_persistence(self):
        with Server(BINARY, arguments=('--appendonly', 'yes', '--appendfsync', 'always')) as persistent:
            admin = persistent.client()
            wait_for(lambda: info(admin, 'persistence').get('aof_rewrite_in_progress') == '0', label='startup AOF rewrite')
            a, b, value = self.pair(4096, 'persisted', admin)
            admin.call('SET', 'durable', 'saved')
            for command, flag in (('BGSAVE', 'rdb_bgsave_in_progress'), ('BGREWRITEAOF', 'aof_rewrite_in_progress')):
                client = persistent.client()
                client.send('LCS', a, b, 'LEN')
                self.pending(client=admin)
                admin.call(command)
                self.assertEqual(client.reply(), len(value))
                wait_for(lambda: info(admin, 'persistence').get(flag) == '0', label=command+' completion')
                before = compute_info(admin)['compute_jobs_submitted']
                self.assertEqual(admin.call('LCS', a, b, 'LEN'), len(value))
                self.assertGreater(compute_info(admin)['compute_jobs_submitted'], before)
                self.idle(admin)
            admin.send('SHUTDOWN', 'NOSAVE')
            persistent.process.wait(timeout=10)
            persistent.stop()
            persistent.start()
            reader = persistent.client()
            self.assertEqual(reader.call('GET', 'durable'), b'saved')
            self.assertEqual(reader.call('LCS', a, b, 'LEN'), len(value))
            self.idle(reader)

    def test_shutdown_with_pending_work_exits_and_can_restart(self):
        a, b, value = self.pair(6144)
        client = self.server.client()
        client.send('LCS', a, b, 'LEN')
        self.pending()
        self.admin.send('SHUTDOWN', 'NOSAVE')
        self.server.process.wait(timeout=10)
        self.server.stop()
        self.server.start()
        admin = self.server.client()
        self.assertEqual(admin.call('PING'), 'PONG')
        a, b, value = self.pair(1100, 'restart', admin)
        self.assertEqual(admin.call('LCS', a, b, 'LEN'), len(value))
        self.idle(admin)

    def test_sigterm_and_sigint_exit_cleanly_disabled_and_pending(self):
        for number in (signal.SIGTERM, signal.SIGINT):
            for workers in (None, 0, 2):
                with self.subTest(signal=number.name, workers=workers):
                    with Server(BINARY, workers=workers) as server:
                        if workers:
                            admin = server.client()
                            a, b, unused = self.pair(6144, 'signal', admin)
                            clients = [server.client(), server.client()]
                            for client in clients:
                                client.send('LCS', a, b, 'LEN')
                            self.pending(client=admin)
                        server.process.send_signal(number)
                        self.assertEqual(server.process.wait(timeout=10), 0,
                                         'signal %s must cause a clean coordinator shutdown' % number.name)

    def test_signals_delivered_to_an_actual_compute_tid_exit_cleanly(self):
        library = ctypes.CDLL(None, use_errno=True)
        if not hasattr(library, 'tgkill'):
            self.skipTest('this libc does not expose tgkill for directed Linux-thread delivery')
        send = library.tgkill
        send.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_int)
        send.restype = ctypes.c_int
        for number in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=number.name):
                with Server(BINARY, workers=1) as server:
                    admin = server.client()
                    a, b, unused = self.pair(6144, 'worker-signal', admin)
                    clients = [server.client(), server.client()]
                    for client in clients:
                        client.send('LCS', a, b, 'LEN')
                    self.pending(2, admin)
                    tids = [tid for tid, data in thread_cpu(server.process.pid).items() if data['name'] == 'eski-compute']
                    self.assertEqual(len(tids), 1)
                    self.assertNotEqual(tids[0], server.process.pid)
                    if send(server.process.pid, tids[0], int(number)) != 0:
                        code = ctypes.get_errno()
                        raise OSError(code, os.strerror(code))
                    self.assertEqual(server.process.wait(timeout=10), 0,
                                     'signal %s delivered to compute TID %d must exit cleanly' % (number.name, tids[0]))

    def test_second_sigint_forces_prompt_exact_exit_one_during_coordinator_sleep(self):
        library = ctypes.CDLL(None, use_errno=True)
        self.assertTrue(hasattr(library, 'tgkill'), 'libc tgkill is required to target the coordinator deterministically')
        send = library.tgkill
        send.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_int)
        send.restype = ctypes.c_int
        with Server(BINARY, workers=2) as server:
            admin = server.client()
            a, b, value = self.pair(1100, 'force-signal', admin)
            self.assertEqual(admin.call('LCS', a, b, 'LEN'), len(value))
            self.assertEqual(compute_info(admin)['compute_threads_active'], 2)
            sleeper = server.client()
            sleeper.send('DEBUG', 'SLEEP', 5)
            task = Path('/proc', str(server.process.pid), 'task', str(server.process.pid))
            def sleeping_without_pending_interrupt():
                status = dict(line.split(':', 1) for line in (task/'status').read_text().splitlines() if ':' in line)
                pending = int(status['SigPnd'], 16) | int(status['ShdPnd'], 16)
                return 'nanosleep' in (task/'wchan').read_text() and not pending & (1 << (int(signal.SIGINT)-1))
            wait_for(sleeping_without_pending_interrupt, timeout=3, label='coordinator DEBUG SLEEP')
            self.assertEqual(send(server.process.pid, server.process.pid, int(signal.SIGINT)), 0)
            wait_for(sleeping_without_pending_interrupt, timeout=3, label='first SIGINT handled before returning to sleep')
            started = time.monotonic()
            self.assertEqual(send(server.process.pid, server.process.pid, int(signal.SIGINT)), 0)
            self.assertEqual(server.process.wait(timeout=2), 1, 'second SIGINT must force exact exit 1')
            self.assertLess(time.monotonic()-started, 2)
            server.stop(expected_exit=1)

    def test_half_close_has_the_same_reply_boundary_as_disabled(self):
        captured = []
        for workers in (0, 2):
            with Server(BINARY, workers=workers) as server:
                admin = server.client()
                a, b, value = self.pair(1100, 'half', admin)
                client = server.client()
                client.send_many([('LCS', a, b, 'LEN'), ('ECHO', 'last')])
                client.socket.shutdown(socket.SHUT_WR)
                replies = []
                try:
                    while True:
                        replies.append(client.read())
                except (EOFError, ConnectionResetError):
                    pass
                captured.append(replies)
        self.assertEqual(captured[0], captured[1])


def main(argv=None):
    global BINARY
    parser = argparse.ArgumentParser(description='Run isolated black-box regressions for LCS compute workers; never runs performance collection.')
    parser.add_argument('--server', type=Path, default=Path(os.environ.get('ESKI_THREADING_BIN', ROOT/'bin/eski')))
    parser.add_argument('--case', default='*', help='unittest method glob')
    parser.add_argument('--timeout', type=int, default=180, help='whole-run wall-clock limit in seconds')
    args = parser.parse_args(argv)
    BINARY = args.server.resolve()
    if args.timeout <= 0 or not BINARY.is_file():
        parser.error('positive timeout and an existing --server binary are required')
    selected = [name for name in unittest.defaultTestLoader.getTestCaseNames(Threading) if fnmatch.fnmatchcase(name, args.case)]
    if not selected:
        parser.error('--case selected no tests')
    def expired(unused_signal, unused_frame):
        print('threading correctness exceeded its wall-clock limit', file=sys.stderr)
        raise SystemExit(124)
    old = signal.signal(signal.SIGALRM, expired)
    signal.alarm(args.timeout)
    try:
        suite = unittest.TestSuite(Threading(name) for name in selected)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


if __name__ == '__main__':
    raise SystemExit(main())
