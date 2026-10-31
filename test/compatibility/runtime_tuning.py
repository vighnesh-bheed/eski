import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import threading
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Server, info, wait_for

BINARY = ROOT / 'bin/eski'


def cpu_list(text):
    result = set()
    for part in text.strip().split(','):
        if not part:
            continue
        ends = part.split('-')
        result.update(range(int(ends[0]), int(ends[-1]) + 1))
    return result


def affinity(tid):
    for row in Path(f'/proc/{tid}/status').read_text().splitlines():
        if row.startswith('Cpus_allowed_list:'):
            return cpu_list(row.split(':', 1)[1])
    raise AssertionError('missing actual thread affinity')


def tasks(pid):
    return {int(path.name) for path in Path(f'/proc/{pid}/task').iterdir()}


def background_tasks(pid):
    return {tid for tid in tasks(pid) if tid != pid and not
            Path(f'/proc/{tid}/comm').read_text().strip().startswith(('eski-keyspace', 'eski-compute'))}


class RuntimeTuning(unittest.TestCase):
    def server(self, *arguments, workers=0, keyspace=2):
        server = Server(BINARY, workers=workers, arguments=('--keyspace-threads', str(keyspace),) + arguments)
        self.addCleanup(server.close)
        return server.start()

    def test_empty_invalid_and_strided_server_cpu_lists(self):
        allowed = sorted(os.sched_getaffinity(0))
        inherited = set(allowed)
        for text in ('', 'bad', '0-1:0'):
            with self.subTest(cpu_list=text):
                server = self.server('--server-cpulist', text)
                self.assertEqual(affinity(server.process.pid), inherited)
                self.assertEqual(server.client().call('PING'), 'PONG')
                server.close()
        if len(allowed) < 2:
            self.skipTest('two allowed CPUs required for a strided affinity witness')
        first, last = allowed[0], allowed[-1]
        server = self.server('--server-cpulist', f'{first}-{last}:{last-first}')
        self.assertEqual(affinity(server.process.pid), {first, last})

    def test_main_background_workers_and_persistence_children_have_actual_affinity(self):
        allowed = sorted(os.sched_getaffinity(0))
        if len(allowed) < 2:
            self.skipTest('two allowed CPUs required to distinguish worker and child roles')
        main, background = allowed[:2]
        server = self.server('--server-cpulist', str(main), '--bio-cpulist', str(background),
                             '--bgsave-cpulist', str(background),
                             '--aof-rewrite-cpulist', f'{main},{background}',
                             '--rdb-key-save-delay', '50000', workers=2)
        client = server.client()
        pid = server.process.pid
        self.assertEqual(affinity(pid), {main})
        client.call('SET', 'lcs:a', 'a' * 1100)
        client.call('SET', 'lcs:b', 'a' * 1100)
        self.assertEqual(client.call('LCS', 'lcs:a', 'lcs:b', 'LEN'), 1100)
        original = tasks(pid)
        for tid in original:
            self.assertEqual(affinity(tid), {main})
        client.call('SADD', 'large-set', *range(4096))
        client.call('MULTI')
        client.call('UNLINK', 'large-set')
        self.assertEqual(client.call('EXEC'), [1])
        lazy = wait_for(lambda: background_tasks(pid) - original, label='actual lazyfree worker TID')
        for tid in lazy:
            wait_for(lambda: affinity(tid) == {background}, label='lazyfree worker startup affinity')
            self.assertEqual(affinity(tid), {background})
        client.call('CONFIG', 'SET', 'appendonly', 'yes')
        wait_for(lambda: info(client, 'persistence')['aof_rewrite_in_progress'] == '0', label='initial AOF rewrite')
        client.call('SET', 'aof-worker', 'value')
        bio = wait_for(lambda: background_tasks(pid) - original - lazy, timeout=5, label='actual AOF bio worker TID')
        for tid in bio:
            wait_for(lambda: affinity(tid) == {background}, label='AOF bio worker startup affinity')
            self.assertEqual(affinity(tid), {background})
        for index in range(8):
            client.call('SET', f'child:{index}', index)
        child_path = Path(f'/proc/{pid}/task/{pid}/children')
        for command, expected, field in [('BGSAVE', {background}, 'rdb_bgsave_in_progress'),
                                         ('BGREWRITEAOF', {main, background}, 'aof_rewrite_in_progress')]:
            with self.subTest(command=command):
                client.call(command)
                child = wait_for(lambda: [int(value) for value in child_path.read_text().split()], label=command+' child')
                self.assertEqual(len(child), 1)
                wait_for(lambda: affinity(child[0]) == expected, label=command+' applied child CPU list')
                self.assertEqual(affinity(child[0]), expected)
                wait_for(lambda: info(client, 'persistence')[field] == '0', label=command+' completion')
        self.assertEqual(client.call('PING'), 'PONG')

    def test_activerehashing_controls_idle_migration_but_not_requests(self):
        server = self.server('--activerehashing', 'no', keyspace=0)
        client = server.client()
        def rehashing():
            return int(info(client, 'memory')['mem_overhead_db_hashtable_rehashing'])
        count = 0
        while count < 20000 and not rehashing():
            client.call('SET', f'rehash:{count}', count)
            count += 1
        self.assertGreater(rehashing(), 0, 'fixture must create a real database migration')
        before = rehashing()
        time.sleep(0.25)
        self.assertEqual(rehashing(), before)
        for index in range(count * 2):
            client.call('SET', f'rehash:{index % count}', index % count)
        self.assertEqual(rehashing(), 0, 'request-driven migration must continue when idle migration is disabled')
        while count < 40000 and not rehashing():
            client.call('SET', f'rehash:{count}', count)
            count += 1
        self.assertGreater(rehashing(), 0)
        client.call('CONFIG', 'SET', 'activerehashing', 'yes')
        wait_for(lambda: rehashing() == 0, label='enabled idle database migration')
        self.assertEqual(client.call('DBSIZE'), count)



    def test_log_level_changes_during_actual_background_affinity_warning(self):
        server = self.server('--bio-cpulist', 'bad', keyspace=0)
        client = server.client()
        self.assertEqual(client.call('SADD', 'background-warning', *range(4096)), 4096)
        commands = [('UNLINK', 'background-warning')]
        commands += [('CONFIG', 'SET', 'loglevel', 'debug' if index % 2 == 0 else 'notice')
                     for index in range(10000)]
        replies = client.pipeline(commands)
        self.assertEqual(replies[0], 1)
        self.assertTrue(all(reply == 'OK' for reply in replies[1:]))
        wait_for(lambda: int(info(client, 'memory')['lazyfree_pending_objects']) == 0,
                 label='background warning and lazyfree completion')
        self.assertIn('Ignoring invalid bio-cpulist CPU list',
                      (server.directory / 'server.log').read_text(errors='replace'))
        self.assertEqual(client.call('CONFIG', 'GET', 'loglevel'), [b'loglevel', b'notice'])
        self.assertEqual(client.call('PING'), 'PONG')


    def test_forked_debugger_and_persistence_drain_real_background_work(self):
        server = self.server('--appendonly', 'yes', '--appendfsync', 'everysec',
                             '--lazyfree-lazy-user-flush', 'yes', workers=2)
        control = server.client()
        wait_for(lambda: info(control, 'persistence')['aof_rewrite_in_progress'] == '0', label='initial rewrite')
        for index in range(24):
            control.call('SADD', f'large:{index}', *range(1024))
        source = server.client()
        self.assertEqual(source.call('SCRIPT', 'DEBUG', 'YES'), 'OK')
        source.send('EVAL', 'redis.call("FLUSHDB", "ASYNC")\nredis.call("SET", "child-only", "value")\nreturn redis.call("GET", "child-only")', 0)
        stopped = source.reply()
        self.assertIsInstance(stopped, list)
        self.assertIn('stopped', '\n'.join(stopped).lower())
        self.assertEqual(control.call('DBSIZE'), 24)
        source.send('continue')
        ended = source.reply()
        self.assertIsInstance(ended, list)
        self.assertIn('<endsession>', '\n'.join(ended).lower())
        self.assertEqual(source.reply(), b'value')
        self.assertIsNone(control.call('GET', 'child-only'))
        self.assertEqual(control.call('SCARD', 'large:0'), 1024)
        failures = []
        started = threading.Event()
        def writer():
            client = server.client()
            try:
                for index in range(80):
                    client.call('MULTI')
                    client.call('SADD', 'recycled', *range(1024))
                    client.call('UNLINK', 'recycled')
                    client.call('SET', 'writer-final', index)
                    self.assertEqual(client.call('EXEC'), [1024, 1, 'OK'])
                    started.set()
            except BaseException as error:
                failures.append(error)
            finally:
                started.set()
        worker = threading.Thread(target=writer)
        worker.start()
        self.addCleanup(lambda: worker.join(20))
        self.assertTrue(started.wait(10))
        for command, field in [('BGSAVE', 'rdb_bgsave_in_progress'), ('BGREWRITEAOF', 'aof_rewrite_in_progress')]:
            control.call(command)
            wait_for(lambda: info(control, 'persistence')[field] == '0', label=command+' concurrent worker completion')
        worker.join(20)
        self.assertFalse(worker.is_alive())
        self.assertFalse(failures, failures)
        self.assertEqual(control.call('GET', 'writer-final'), b'79')
        wait_for(lambda: int(info(control, 'memory')['lazyfree_pending_objects']) == 0, label='parent lazyfree completion')
        digest = control.call('DEBUG', 'DIGEST')
        control.call('DEBUG', 'LOADAOF')
        self.assertEqual(control.call('DEBUG', 'DIGEST'), digest)
        self.assertEqual(control.call('PING'), 'PONG')


    def test_shutdown_drains_background_syslog_before_closing_owned_logger(self):
        server = Server(BINARY, workers=0, arguments=(
            '--keyspace-threads', '0', '--bio-cpulist', 'bad', '--syslog-enabled', 'yes',
            '--syslog-ident', 'eski-owned-background-shutdown'))
        self.addCleanup(server.close)
        shim = server.directory / 'record-operations.so'
        record = server.directory / 'syslog.log'
        subprocess.run(['clang', '-shared', '-fPIC', '-O1', '-pthread',
                        str(Path(__file__).with_name('runtime_operations_shim.c')), '-o', str(shim)],
                       check=True)
        with mock.patch.dict(os.environ, {'LD_PRELOAD': str(shim), 'ESKI_TEST_SYSLOG_RECORD': str(record)}):
            server.start()
        client = server.client()
        self.assertEqual(client.call('SADD', 'background-at-exit', *range(4096)), 4096)
        client.send_many([('UNLINK', 'background-at-exit'), ('SHUTDOWN', 'NOSAVE')])
        reply = bytearray()
        while True:
            chunk = client.socket.recv(16)
            if not chunk:
                break
            reply.extend(chunk)
            self.assertLessEqual(len(reply), 4)
        self.assertIn(bytes(reply), (b'', b':1\r\n'))
        self.assertEqual(server.process.wait(timeout=10), 0)
        text = record.read_text(errors='replace')
        self.assertIn('Ignoring invalid bio-cpulist CPU list', text)
        self.assertEqual(text.count('CLOSE\n'), 1)
        self.assertTrue(text.rstrip().endswith('CLOSE'), text)
        self.assertLess(text.index('Ignoring invalid bio-cpulist CPU list'), text.index('CLOSE\n'))


def main():
    global BINARY
    parser = argparse.ArgumentParser(description='Owned-process CPU affinity and idle rehash correctness checks.')
    parser.add_argument('--server', type=Path, default=BINARY)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    if not BINARY.is_file():
        parser.error('existing server binary required')
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(124))
    signal.alarm(120)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(RuntimeTuning))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
