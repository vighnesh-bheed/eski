import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import signal
import sys
import threading
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Server, ServerError, encode, info, wait_for
from features import aof_commands

BINARY = ROOT / 'bin/eski'


class PersistenceBoundaries(unittest.TestCase):
    def server(self, preamble='no', workers=0):
        server = Server(BINARY, workers=0, arguments=(
            '--keyspace-threads', str(workers), '--appendonly', 'yes',
            '--appendfsync', 'always', '--aof-use-rdb-preamble', preamble,
            '--auto-aof-rewrite-percentage', '0'))
        self.addCleanup(server.close)
        server.start()
        c = server.client()
        wait_for(lambda: info(c, 'persistence')['aof_rewrite_in_progress'] == '0', label='initial rewrite')
        return server, c

    def test_multi_flushall_wraps_initial_select_inside_transaction(self):
        server, c = self.server()
        c.call('SELECT', 9)
        self.assertEqual(c.pipeline([('MULTI',), ('SET', 'foo', 'bar'), ('FLUSHALL',), ('EXEC',)]),
                         ['OK', 'QUEUED', 'QUEUED', ['OK', 'OK']])
        dirname = c.call('CONFIG', 'GET', 'appenddirname')[1].decode()
        files = list((server.directory / dirname).glob('*.incr.aof'))
        self.assertEqual(len(files), 1)
        rows = list(aof_commands(files[0].read_bytes()))
        self.assertEqual([args[0].lower() for args in rows], [b'multi', b'select', b'set', b'flushall', b'exec'])
        self.assertEqual(rows[1], [b'SELECT', b'9'])
        c.call('DEBUG', 'LOADAOF')
        self.assertIsNone(c.call('GET', 'foo'))

    def test_legacy_eval_aof_restores_writes_on_reload_and_restart(self):
        for workers in (0, 2):
            with self.subTest(workers=workers):
                server, c = self.server(workers=workers)
                path = next((server.directory / 'appendonlydir').glob('*.incr.aof'))
                source = 'redis.call("SET",KEYS[1],"100");redis.call("INCR",KEYS[1]);return redis.call("INCR",KEYS[1])'
                path.write_bytes(encode(('SELECT', 9)) + encode(('EVAL', source, 1, 'legacy')))
                self.assertEqual(c.call('DEBUG', 'LOADAOF'), 'OK')
                c.call('SELECT', 9)
                self.assertEqual(c.call('GET', 'legacy'), b'102')
                server.stop()
                server.start()
                c = server.client()
                c.call('SELECT', 9)
                self.assertEqual(c.call('GET', 'legacy'), b'102')
                server.stop()

    def test_slow_legacy_eval_aof_serves_loading_and_preserves_effects(self):
        server, c = self.server(workers=2)
        c.call('CONFIG', 'SET', 'lua-time-limit', 1)
        observer = server.client()
        path = next((server.directory / 'appendonlydir').glob('*.incr.aof'))
        source = 'redis.call("SET",KEYS[1],"loaded");for i=1,250000 do redis.call("PING") end;return 1'
        path.write_bytes(encode(('SELECT', 9)) + encode(('EVAL', source, 1, 'legacy-slow')))
        c.send('DEBUG', 'LOADAOF')
        def loading():
            try:
                observer.call('PING')
            except ServerError as error:
                self.assertTrue(str(error).startswith('LOADING '), str(error))
                return True
            if c.available():
                self.fail('legacy reload completed without its observable loading phase')
            return False
        wait_for(loading, timeout=10, label='legacy Lua loading service')
        self.assertEqual(c.reply(), 'OK')
        c.call('SELECT', 9)
        self.assertEqual(c.call('GET', 'legacy-slow'), b'loaded')
        self.assertEqual(observer.call('PING'), 'PONG')
        self.assertIn('Slow script detected', (server.directory / 'server.log').read_text())

    def test_cross_database_transaction_and_partial_error_replay(self):
        _, c = self.server()
        replies = c.pipeline([('MULTI',), ('SELECT', 2), ('SET', 'slot', 'two'),
                              ('LPOP', 'slot'), ('SELECT', 3), ('SET', 'slot', 'three'), ('EXEC',)])
        self.assertEqual(replies[:6], ['OK', 'QUEUED', 'QUEUED', 'QUEUED', 'QUEUED', 'QUEUED'])
        self.assertIsInstance(replies[-1][2], ServerError)
        self.assertEqual(replies[-1][:2] + replies[-1][3:], ['OK', 'OK', 'OK', 'OK'])
        c.call('DEBUG', 'LOADAOF')
        c.call('SELECT', 2)
        self.assertEqual(c.call('GET', 'slot'), b'two')
        c.call('SELECT', 3)
        self.assertEqual(c.call('GET', 'slot'), b'three')

    def test_failed_bgsave_preserves_legacy_script_reads_and_declared_write_policy(self):
        for workers in (0, 2):
            with self.subTest(workers=workers):
                server, c = self.server(workers=workers)
                read = 'return redis.call("GET",KEYS[1])'
                write = 'return redis.call("SET",KEYS[1],"bad")'
                c.call('SET', 'x', 'x')
                digest = c.call('SCRIPT', 'LOAD', read)
                c.call('FUNCTION', 'LOAD', '#!lua name=misconf\n'
                       'redis.register_function("declared_write",function(k,a)return redis.call("GET",k[1])end)\n'
                       'redis.register_function{function_name="declared_read",callback=function(k,a)return redis.call("GET",k[1])end,flags={"no-writes"}}')
                c.call('CONFIG', 'SET', 'save', '900 1', 'rdb-key-save-delay', '1000000')
                c.call('BGSAVE')
                children = Path('/proc/%d/task/%d/children' % (server.process.pid, server.process.pid))
                def saving_child():
                    values = [int(value) for value in children.read_text().split()]
                    self.assertLessEqual(len(values), 1)
                    return values[0] if values else None
                child = wait_for(saving_child, label='owned background save child')
                state = Path('/proc/%d/stat' % child).read_text().rsplit(')', 1)[1].split()
                self.assertEqual(int(state[1]), server.process.pid)
                os.kill(child, signal.SIGKILL)
                wait_for(lambda: info(c, 'persistence')['rdb_bgsave_in_progress'] == '0'
                         and info(c, 'persistence')['rdb_last_bgsave_status'] == 'err', label='failed background save')
                c.call('CONFIG', 'SET', 'rdb-key-save-delay', '0')
                allowed = [('EVAL', read, 1, 'x'), ('EVALSHA', digest, 1, 'x'),
                           ('EVAL', '#!lua flags=no-writes\n' + read, 1, 'x'),
                           ('FCALL', 'declared_read', 1, 'x')]
                for command in allowed:
                    self.assertEqual(c.call(*command), b'x')
                rejected = [('EVAL', write, 1, 'x'), ('EVAL', '#!lua\n' + read, 1, 'x'),
                            ('FCALL', 'declared_write', 1, 'x')]
                for command in rejected:
                    with self.assertRaisesRegex(ServerError, '^MISCONF '):
                        c.call(*command)
                for command, error in [(('EVALSHA', '0' * 40, 1, 'x'), '^NOSCRIPT '),
                                       (('FCALL', 'missing', 1, 'x'), '^ERR Function not found'),
                                       (('EVAL', '#!python\nreturn 1', 0), '^ERR Unexpected engine')]:
                    with self.assertRaisesRegex(ServerError, error):
                        c.call(*command)
                self.assertEqual(c.pipeline([('MULTI',), ('EVAL', read, 1, 'x'), ('EXEC',)]), ['OK', 'QUEUED', [b'x']])
                result = c.pipeline([('MULTI',), ('EVAL', '#!lua\n' + read, 1, 'x'), ('EXEC',)])
                self.assertEqual(result[0], 'OK')
                self.assertRegex(str(result[1]), '^MISCONF ')
                self.assertRegex(str(result[2]), '^EXECABORT ')
                self.assertEqual(c.call('GET', 'x'), b'x')
                c.call('CONFIG', 'SET', 'save', '')
                server.stop()

    def test_rewrite_with_bounded_concurrent_writes_preserves_digest(self):
        for preamble in ('yes', 'no'):
            for workers in (0, 2):
                with self.subTest(preamble=preamble, workers=workers):
                    server, c = self.server(preamble, workers)
                    c.call('SELECT', 9)
                    c.call('HSET', 'hash', 'f', 'v')
                    c.call('RPUSH', 'list', 'a', 'b')
                    c.call('SADD', 'set', 'a', 'b')
                    c.call('ZADD', 'zset', 1, 'a')
                    c.call('XADD', 'stream', '1-0', 'f', 'v')
                    c.call('CONFIG', 'SET', 'rdb-key-save-delay', 10000)
                    ready = threading.Barrier(5)
                    release = threading.Event()
                    clients = [server.client() for _ in range(4)]
                    def write(item):
                        index, actor = item
                        actor.call('SELECT', 9)
                        actor.call('SET', 'ready-' + str(index), 'yes')
                        ready.wait(timeout=15)
                        if not release.wait(15):
                            raise AssertionError('rewrite release timeout')
                        for batch in range(12):
                            commands = []
                            for offset in range(10):
                                key = 'writer-%d-%d' % (index, batch * 10 + offset)
                                commands += [('SET', key, str(index) * 64), ('APPEND', key, '-tail')]
                            results = actor.pipeline(commands)
                            self.assertFalse(any(isinstance(value, ServerError) for value in results))
                    with ThreadPoolExecutor(max_workers=4) as pool:
                        futures = [pool.submit(write, item) for item in enumerate(clients)]
                        try:
                            ready.wait(timeout=15)
                            self.assertEqual(c.call('BGREWRITEAOF'), 'Background append only file rewriting started')
                        finally:
                            release.set()
                        for future in futures:
                            future.result(timeout=30)
                    wait_for(lambda: info(c, 'persistence')['aof_rewrite_in_progress'] == '0', label='rewrite with writes')
                    self.assertEqual(c.call('DBSIZE'), 489)
                    before = c.call('DEBUG', 'DIGEST')
                    self.assertEqual(c.call('DEBUG', 'LOADAOF'), 'OK')
                    self.assertEqual(c.call('DEBUG', 'DIGEST'), before)
                    self.assertEqual(c.call('GET', 'writer-3-119'), b'3' * 64 + b'-tail')
                    server.stop()


def main():
    global BINARY
    parser = argparse.ArgumentParser(description='Bounded AOF transaction and rewrite correctness checks; no throughput measurement.')
    parser.add_argument('--server', type=Path, default=BINARY)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    if not BINARY.is_file():
        parser.error('existing server binary required')
    signal.alarm(180)
    return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(PersistenceBoundaries)).wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
