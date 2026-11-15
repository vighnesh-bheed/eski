import argparse
import fnmatch
import hashlib
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
OOM = "OOM command not allowed when used memory > 'maxmemory'."
ABORTED = 'EXECABORT Transaction discarded because of previous errors.'
ABORTED_OOM = 'EXECABORT Transaction discarded because of: ' + OOM
LARGE = 8000
TIGHT = 2000
ROOMY = 64000
MANY = 1500
MANY_TIGHT = 36000
MANY_ROOMY = 80000
OVER = -50000
LIBRARY = '''#!lua name=memlimit
redis.register_function('ml_plain', function(keys, args) return redis.call('set', 'f', '1') end)
redis.register_function{function_name='ml_stale', callback=function(keys, args) return redis.call('set', 'f', '1') end, flags={'allow-stale'}}
redis.register_function{function_name='ml_oom', callback=function(keys, args) return redis.call('set', 'g', '1') end, flags={'allow-oom'}}
redis.register_function{function_name='ml_read', callback=function(keys, args) return redis.call('get', 'g') end, flags={'no-writes'}}
'''


def text(length, salt=0):
    parts = []
    index = 0
    while sum(len(part) for part in parts) < length:
        parts.append(hashlib.sha256(b'%d:%d' % (salt, index)).hexdigest())
        index += 1
    return ''.join(parts)[:length]


class MemoryLimit(unittest.TestCase):
    def setUp(self):
        if REFERENCE_PORT is None:
            self.server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS)))
            self.addCleanup(self.server.close)
            self.server.start()
            self.port = self.server.port
        else:
            self.server = None
            self.port = REFERENCE_PORT
        self.control = self.connection()
        self.addCleanup(self.restore)
        self.probe = self.connection()
        self.reset()

    def connection(self):
        client = Client(self.port)
        self.addCleanup(client.close)
        return client

    def restore(self):
        try:
            self.control.call('CONFIG', 'SET', 'maxmemory', 0)
            self.control.call('CONFIG', 'SET', 'maxmemory-policy', 'noeviction')
            self.control.call('CONFIG', 'SET', 'notify-keyspace-events', '')
            self.control.call('FLUSHALL')
        except (OSError, EOFError, ServerError):
            pass

    def reset(self, policy='noeviction'):
        self.control.call('CONFIG', 'SET', 'maxmemory', 0)
        self.control.call('CONFIG', 'SET', 'maxmemory-policy', policy)
        self.control.call('FLUSHALL')
        self.control.call('SCRIPT', 'FLUSH')

    def used(self):
        return int(info(self.control, 'memory')['used_memory'])

    def headroom(self, amount):
        self.used()
        limit = self.used() + amount
        self.control.call('CONFIG', 'SET', 'maxmemory', limit)
        return limit

    def unlimited(self):
        self.control.call('CONFIG', 'SET', 'maxmemory', 0)

    def ask(self, *command):
        self.probe.send(*command)
        return self.probe.reply()

    def evicted(self):
        return int(info(self.control, 'stats')['evicted_keys'])

    def fill(self, count):
        replies = self.control.pipeline([('SET', 'fill:%04d' % index, text(1000, index)) for index in range(count)])
        self.assertEqual(replies, ['OK'] * count)

    def refused(self, reply, label):
        self.assertIsInstance(reply, ServerError, label)
        self.assertEqual(str(reply), OOM, label)

    def served(self, reply, label):
        self.assertNotIsInstance(reply, ServerError, label)

    def growing_commands(self):
        large = text(LARGE)
        halves = (text(LARGE // 2, 1), text(LARGE // 2, 2))
        members = tuple(text(100, index) for index in range(LARGE // 100))
        return (
            ('SET', (), lambda v: ('SET', 'k', v), large),
            ('SETEX', (), lambda v: ('SETEX', 'k', 100, v), large),
            ('SETNX over a key that exists', (('SET', 'k', 'a'),), lambda v: ('SETNX', 'k', v), large),
            ('APPEND', (('SET', 'k', 'a'),), lambda v: ('APPEND', 'k', v), large),
            ('SETRANGE', (('SET', 'k', 'a'),), lambda v: ('SETRANGE', 'k', 0, v), large),
            ('MSET', (), lambda v: ('MSET', 'k', v[0], 'k2', v[1]), halves),
            ('LPUSH', (), lambda v: ('LPUSH', 'k', v), large),
            ('RPUSH of many members', (), lambda v: ('RPUSH', 'k') + tuple(v), members),
            ('HSET', (), lambda v: ('HSET', 'k', 'f', v), large),
            ('SADD', (), lambda v: ('SADD', 'k', v), large),
            ('ZADD', (), lambda v: ('ZADD', 'k', 1, v), large),
            ('XADD', (), lambda v: ('XADD', 'k', '*', 'f', v), large),
        )

    def test_write_is_refused_when_its_own_arguments_exceed_the_headroom(self):
        for label, setup, build, payload in self.growing_commands():
            with self.subTest(command=label):
                self.reset()
                small = ('a', 'b') if isinstance(payload, tuple) else 'a'
                for command in setup:
                    self.control.call(*command)
                self.served(self.ask(*build(small)), label + ' warm')
                self.control.call('FLUSHALL')
                for command in setup:
                    self.control.call(*command)
                before = self.control.call('DEBUG', 'DIGEST') if REFERENCE_PORT is None else None
                size = self.control.call('DBSIZE')
                evicted = self.evicted()
                self.headroom(TIGHT)
                self.refused(self.ask(*build(payload)), label)
                self.assertEqual(self.control.call('DBSIZE'), size, label)
                if before is not None:
                    self.assertEqual(self.control.call('DEBUG', 'DIGEST'), before, label)
                self.assertEqual(self.evicted(), evicted, label)
                self.unlimited()
                self.headroom(ROOMY)
                self.served(self.ask(*build(payload)), label + ' with room')

    def test_restore_is_refused_when_its_payload_exceeds_the_headroom(self):
        self.control.call('SET', 'source', text(LARGE))
        self.control.call('SET', 'tiny', 'a')
        payload = self.control.call('DUMP', 'source')
        tiny = self.control.call('DUMP', 'tiny')
        self.assertGreater(len(payload), 2 * TIGHT)
        self.control.call('DEL', 'source', 'tiny')
        self.assertEqual(self.ask('RESTORE', 'warm', 0, tiny), 'OK')
        self.control.call('DEL', 'warm')
        self.headroom(TIGHT)
        self.refused(self.ask('RESTORE', 'k', 0, payload), 'RESTORE')
        self.assertEqual(self.control.call('EXISTS', 'k'), 0)
        self.unlimited()
        self.headroom(ROOMY)
        self.assertEqual(self.ask('RESTORE', 'k', 0, payload), 'OK')
        self.assertEqual(self.control.call('STRLEN', 'k'), LARGE)

    def test_commands_that_cannot_grow_memory_are_served_with_large_arguments(self):
        large = text(LARGE)
        self.control.call('SET', 'k', 'a')
        commands = (('GET', large), ('PING', large), ('EXISTS', large), ('DEL', large), ('PUBLISH', 'channel', large))
        for command in commands:
            self.served(self.ask(command[0], *('a' for _ in command[1:])), command[0] + ' warm')
        self.headroom(TIGHT)
        for command in commands:
            with self.subTest(command=command[0]):
                self.served(self.ask(*command), command[0])
        self.assertEqual(self.control.call('GET', 'k'), b'a')

    def test_queued_write_is_refused_when_it_is_queued(self):
        large = text(LARGE)
        self.assertEqual(self.probe.pipeline([('MULTI',), ('SET', 'k', 'a'), ('EXEC',)]), ['OK', 'QUEUED', ['OK']])
        self.control.call('FLUSHALL')
        self.headroom(TIGHT)
        self.assertEqual(self.ask('MULTI'), 'OK')
        self.refused(self.ask('SET', 'k', large), 'queued SET')
        reply = self.ask('EXEC')
        self.assertIsInstance(reply, ServerError)
        self.assertEqual(str(reply), ABORTED)
        self.assertEqual(self.control.call('DBSIZE'), 0)
        self.unlimited()
        self.headroom(ROOMY)
        self.assertEqual(self.ask('MULTI'), 'OK')
        self.assertEqual(self.ask('SET', 'k', large), 'QUEUED')
        self.assertEqual(self.ask('EXEC'), ['OK'])
        self.assertEqual(self.control.call('STRLEN', 'k'), LARGE)

    def test_eviction_makes_room_for_the_arguments_before_the_command_runs(self):
        self.reset('allkeys-lru')
        self.fill(300)
        self.assertEqual(self.ask('SET', 'warm', 'a'), 'OK')
        self.control.call('CONFIG', 'SET', 'notify-keyspace-events', 'E$e')
        listener = self.connection()
        listener.send('PSUBSCRIBE', '__keyevent@0__:*')
        self.assertEqual(listener.reply(), [b'psubscribe', b'__keyevent@0__:*', 1])
        before = self.evicted()
        self.headroom(0)
        self.assertEqual(self.ask('SET', 'incoming', text(LARGE)), 'OK')
        ahead = 0
        while True:
            message = listener.reply()
            self.assertEqual(message[0], b'pmessage')
            if message[2].endswith(b':set') and message[3] == b'incoming':
                break
            if message[2].endswith(b':evicted'):
                ahead += 1
        self.assertGreaterEqual(ahead, 4)
        self.assertGreaterEqual(self.evicted() - before, ahead)
        self.assertEqual(self.control.call('STRLEN', 'incoming'), LARGE)

    def test_script_write_runs_at_the_limit_under_an_evicting_policy(self):
        script = "return redis.call('set', KEYS[1], ARGV[1])"
        self.reset('allkeys-lru')
        self.fill(300)
        self.assertEqual(self.ask('EVAL', script, 1, 'warm', 'a'), 'OK')
        before = self.evicted()
        self.headroom(0)
        self.assertEqual(self.ask('EVAL', script, 1, 'small', 'a'), 'OK')
        self.assertEqual(self.ask('EVAL', script, 1, 'large', text(LARGE)), 'OK')
        self.assertGreaterEqual(self.evicted() - before, 4)
        self.assertEqual(self.control.call('STRLEN', 'large'), LARGE)

    def test_script_is_judged_once_when_it_arrives(self):
        write = "redis.call('set', 'b', '1') return 'done'"
        grow = "redis.call('set', 'a', string.rep('x', 100000)) " + write
        self.assertEqual(self.ask('EVAL', 'return 1', 0), 1)
        self.headroom(30000)
        self.assertEqual(self.ask('EVAL', grow, 0), b'done')
        self.assertEqual(self.control.call('STRLEN', 'a'), 100000)
        self.assertEqual(self.control.call('GET', 'b'), b'1')
        self.reset()
        self.control.call('SET', 'big', text(100000))
        self.headroom(-50000)
        reply = self.ask('EVAL', write, 0)
        self.assertIsInstance(reply, ServerError)
        self.assertTrue(str(reply).startswith(OOM + ' script:'), str(reply))
        self.assertEqual(self.control.call('EXISTS', 'b'), 0)
        self.assertEqual(self.ask('EVAL', "redis.call('del', 'big') " + write, 0), b'done')
        self.assertEqual(self.control.call('GET', 'b'), b'1')

    def test_flagged_script_is_refused_before_it_runs(self):
        large = text(LARGE)
        body = "return redis.call('set', KEYS[1], ARGV[1])"
        self.assertEqual(self.ask('EVAL', '#!lua\n' + body, 1, 'warm', 'a'), 'OK')
        self.control.call('FLUSHALL')
        self.headroom(TIGHT)
        self.refused(self.ask('EVAL', '#!lua\n' + body, 1, 'k', large), 'flagged script')
        self.assertEqual(self.control.call('DBSIZE'), 0)
        self.assertIsNone(self.ask('EVAL', "#!lua flags=no-writes\nreturn redis.call('get', KEYS[1])", 1, 'k', large))
        self.assertEqual(self.ask('EVAL', '#!lua flags=allow-oom\n' + body, 1, 'k', large), 'OK')
        self.assertEqual(self.control.call('STRLEN', 'k'), LARGE)

    def test_script_inside_a_transaction_uses_the_decision_made_at_exec(self):
        script = "return redis.call('set', 'b', '1')"
        self.assertEqual(self.probe.pipeline([('MULTI',), ('SETRANGE', 'warm', 10, 'x'), ('EVAL', script, 0), ('EXEC',)]),
                         ['OK', 'QUEUED', 'QUEUED', [11, 'OK']])
        self.control.call('FLUSHALL')
        self.assertEqual(self.probe.pipeline([('MULTI',), ('SETRANGE', 'grown', 150000, 'x'), ('EVAL', script, 0)]),
                         ['OK', 'QUEUED', 'QUEUED'])
        self.headroom(30000)
        self.assertEqual(self.ask('EXEC'), [150001, 'OK'])
        self.assertEqual(self.control.call('GET', 'b'), b'1')

    def test_many_small_arguments_count_beyond_their_lengths(self):
        members = tuple('m%05d' % index for index in range(MANY))
        pairs = tuple(part for index in range(MANY // 2) for part in ('k%05d' % index, 'v'))
        cases = (
            ('SADD', ('SADD', 'k', 'a'), ('SADD', 'k') + members),
            ('RPUSH', ('RPUSH', 'k', 'a'), ('RPUSH', 'k') + members),
            ('ZADD', ('ZADD', 'k', 1, 'a'), ('ZADD', 'k') + tuple(part for index in range(MANY // 2) for part in (index, 'm%05d' % index))),
            ('HSET', ('HSET', 'k', 'f', 'v'), ('HSET', 'k') + pairs),
            ('MSET', ('MSET', 'k', 'a'), ('MSET',) + pairs),
        )
        for label, warm, command in cases:
            with self.subTest(command=label):
                self.assertLess(sum(len(str(part)) for part in command), MANY_TIGHT // 3, label)
                self.reset()
                self.served(self.ask(*warm), label + ' warm')
                self.control.call('FLUSHALL')
                self.served(self.ask(*warm), label + ' warm')
                size = self.control.call('DBSIZE')
                self.headroom(MANY_TIGHT)
                self.refused(self.ask(*command), label)
                self.assertEqual(self.control.call('DBSIZE'), size, label)
                self.unlimited()
                self.headroom(MANY_ROOMY)
                self.served(self.ask(*command), label + ' with room')

    def test_many_small_queued_commands_count_beyond_their_lengths(self):
        cases = (
            ('200 SET of one-byte values', [('SET', 'k%03d' % index, 'v') for index in range(200)], 16000, 40000),
            ('20 SADD of 48 members', [('SADD', 'k%d' % (index % 7)) + tuple('m%05d' % (index * 100 + member) for member in range(48)) for index in range(20)], 28000, 60000),
        )
        for label, commands, tight, roomy in cases:
            with self.subTest(case=label):
                self.assertLess(sum(len(str(part)) for command in commands for part in command), tight // 2, label)
                self.reset()
                warm = [('MULTI',), commands[0][:3], ('EXEC',)]
                for _ in range(2):
                    self.assertEqual(self.probe.pipeline(warm)[:2], ['OK', 'QUEUED'], label)
                    self.control.call('FLUSHALL')
                self.headroom(tight)
                replies = self.probe.pipeline([('MULTI',)] + commands + [('EXEC',)])
                self.assertEqual(replies[0], 'OK', label)
                refused = [reply for reply in replies[1:-1] if isinstance(reply, ServerError)]
                self.assertTrue(refused, label)
                self.assertEqual({str(reply) for reply in refused}, {OOM}, label)
                self.assertIsInstance(replies[-1], ServerError, label)
                self.assertIn(str(replies[-1]), (ABORTED, ABORTED_OOM), label)
                self.assertEqual(self.control.call('DBSIZE'), 0, label)
                self.unlimited()
                self.headroom(roomy)
                replies = self.probe.pipeline([('MULTI',)] + commands + [('EXEC',)])
                self.assertEqual(replies[:-1], ['OK'] + ['QUEUED'] * len(commands), label)
                self.assertEqual(len(replies[-1]), len(commands), label)

    def test_eviction_makes_room_for_many_small_arguments(self):
        names = tuple('m%05d' % index for index in range(MANY))
        self.reset('allkeys-lru')
        self.assertEqual(self.ask('DEL', 'a'), 0)
        self.fill(300)
        before = self.evicted()
        self.headroom(0)
        self.assertEqual(self.ask('DEL', *names), 0)
        count = self.evicted() - before
        self.assertTrue(45 <= count <= 110, 'evicted %d keys of about 1000 bytes for %d small arguments' % (count, MANY))

    def library(self):
        self.control.call('FUNCTION', 'FLUSH')
        self.addCleanup(self.control.call, 'FUNCTION', 'FLUSH')
        self.assertEqual(self.control.call('FUNCTION', 'LOAD', LIBRARY), b'memlimit')

    def test_exec_holding_a_declared_script_is_refused_as_a_whole(self):
        write = "return redis.call('set', 'b', '1')"
        read = "return redis.call('get', 'g')"
        header = hashlib.sha1(('#!lua\n' + write).encode()).hexdigest()
        cases = (
            ('script with a header', ('EVAL', '#!lua\n' + write, 0), None),
            ('script with a header that only allows stale reads', ('EVAL', '#!lua flags=allow-stale\n' + write, 0), None),
            ('script with a header, by digest', ('EVALSHA', header, 0), None),
            ('script with a header, read-only command', ('EVAL_RO', '#!lua\n' + read, 0), None),
            ('function without flags', ('FCALL', 'ml_plain', 0), None),
            ('function that only allows stale reads', ('FCALL', 'ml_stale', 0), None),
            ('function without flags, wrong key count', ('FCALL', 'ml_plain', 'x'), None),
            ('script with a header that allows memory', ('EVAL', '#!lua flags=allow-oom\n' + write, 0), 'OK'),
            ('script with a header that does not write', ('EVAL', '#!lua flags=no-writes\n' + read, 0), b'1'),
            ('function that allows memory', ('FCALL', 'ml_oom', 0), 'OK'),
            ('function that does not write', ('FCALL', 'ml_read', 0), b'1'),
            ('function that does not write, read-only command', ('FCALL_RO', 'ml_read', 0), b'1'),
            ('read-only script without a header', ('EVAL_RO', read, 0), b'1'),
        )
        for label, command, expected in cases:
            with self.subTest(script=label):
                self.reset()
                self.library()
                self.control.call('SCRIPT', 'LOAD', '#!lua\n' + write)
                self.control.call('SET', 'big', text(100000))
                self.control.call('SET', 'g', '1')
                self.control.call('SET', 'victim', 'kept')
                self.assertEqual(self.probe.pipeline([('MULTI',), ('DEL', 'victim'), command]), ['OK', 'QUEUED', 'QUEUED'], label)
                self.headroom(OVER)
                reply = self.ask('EXEC')
                self.unlimited()
                if expected is None:
                    self.assertIsInstance(reply, ServerError, label)
                    self.assertEqual(str(reply), ABORTED_OOM, label)
                    self.assertEqual(self.control.call('GET', 'victim'), b'kept', label)
                    self.assertEqual(self.control.call('EXISTS', 'b', 'f'), 0, label)
                else:
                    self.assertEqual(reply, [1, expected], label)
                    self.assertEqual(self.control.call('EXISTS', 'victim'), 0, label)

    def test_declared_script_is_refused_when_it_is_queued_or_sent_over_the_limit(self):
        write = "return redis.call('set', 'b', '1')"
        read = "return redis.call('get', 'g')"
        refused = (
            ('EVAL', '#!lua\n' + write, 0),
            ('EVAL_RO', '#!lua\n' + read, 0),
            ('EVAL', '#!lua\n' + write, 'x'),
            ('FCALL', 'ml_plain', 0),
            ('FCALL_RO', 'ml_plain', 0),
        )
        self.library()
        self.control.call('SET', 'big', text(100000))
        self.control.call('SET', 'g', '1')
        for command in refused:
            with self.subTest(command=command[:2]):
                self.unlimited()
                self.headroom(OVER)
                self.refused(self.ask(*command), 'sent')
                self.assertEqual(self.ask('MULTI'), 'OK')
                self.refused(self.ask(*command), 'queued')
                reply = self.ask('EXEC')
                self.assertIsInstance(reply, ServerError)
                self.assertEqual(str(reply), ABORTED)
                self.assertEqual(self.control.call('EXISTS', 'b', 'f'), 0)
        self.unlimited()
        self.headroom(OVER)
        self.assertEqual(self.ask('MULTI'), 'OK')
        self.assertEqual(self.ask('EVAL', write, 0), 'QUEUED')
        self.assertEqual(self.ask('FCALL', 'ml_oom', 0), 'QUEUED')
        self.assertEqual(self.ask('EVAL', '#!lua flags=no-writes\n' + read, 0), 'QUEUED')
        reply = self.ask('EXEC')
        self.assertIsInstance(reply[0], ServerError)
        self.assertTrue(str(reply[0]).startswith(OOM + ' script:'), str(reply[0]))
        self.assertEqual(reply[1:], ['OK', b'1'])

    def test_snapshot_load_is_not_evicted_until_it_has_finished(self):
        if REFERENCE_PORT is not None:
            self.skipTest('the load is restarted on a local server only')
        count = 600
        empty = self.used()
        self.fill(count)
        self.assertEqual(self.control.call('SAVE'), 'OK')
        limit = empty + count * 1000 // 3
        directory = self.server.directory
        self.server.stop()
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        log = (directory / 'reload.log').open('ab')
        self.addCleanup(log.close)
        process = subprocess.Popen(
            [str(BINARY), '--bind', '127.0.0.1', '--port', str(port), '--dir', str(directory), '--save', '',
             '--appendonly', 'no', '--compute-threads', '0', '--keyspace-threads', str(KEYSPACE_THREADS),
             '--maxmemory', str(limit), '--maxmemory-policy', 'allkeys-lru', '--key-load-delay', '2000',
             '--loading-process-events-interval-bytes', '1024'],
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)

        def reap():
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
        self.addCleanup(reap)

        def connect():
            self.assertIsNone(process.poll(), 'the reloading server exited')
            try:
                return Client(port)
            except OSError:
                return None
        client = wait_for(connect, timeout=15, label='the reloading server to accept a connection')
        self.addCleanup(client.close)
        samples = []
        while True:
            if info(client, 'persistence')['loading'] != '1':
                break
            evicted = int(info(client, 'stats')['evicted_keys'])
            used = int(info(client, 'memory')['used_memory'])
            if info(client, 'persistence')['loading'] != '1':
                break
            samples.append((evicted, used))
            time.sleep(0.01)
        self.assertTrue(any(used > limit for _, used in samples),
                        'no sample was taken over the limit while the snapshot loaded: limit %d, last samples %r'
                        % (limit, samples[-3:]))
        self.assertEqual({evicted for evicted, _ in samples}, {0})
        self.assertGreater(int(info(client, 'stats')['evicted_keys']), 0)
        size = client.call('DBSIZE')
        self.assertGreater(size, 0)
        self.assertLess(size, count)
        wait_for(lambda: int(info(client, 'memory')['used_memory']) <= limit, timeout=15,
                 label='eviction to bring the loaded data under the limit')


def main():
    global BINARY, REFERENCE_PORT, KEYSPACE_THREADS
    parser = argparse.ArgumentParser(description='Memory limit admission and eviction checks; replies only, no timing.')
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--reference-port', type=int, help='explicitly isolated localhost reference fixture')
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--case', default='*')
    parser.add_argument('--timeout', type=int, default=240)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    REFERENCE_PORT = args.reference_port
    KEYSPACE_THREADS = args.keyspace_threads
    if args.timeout <= 0 or (REFERENCE_PORT is None and not BINARY.is_file()):
        parser.error('existing binary and positive timeout required')
    names = [name for name in unittest.defaultTestLoader.getTestCaseNames(MemoryLimit)
             if fnmatch.fnmatchcase(name, args.case)]
    if not names:
        parser.error('no tests selected')

    def expired(unused_signal, unused_frame):
        raise SystemExit(124)
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(args.timeout)
    try:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(MemoryLimit(name) for name in names))
        return 0 if result.wasSuccessful() else 1
    finally:
        signal.alarm(0)


if __name__ == '__main__':
    raise SystemExit(main())
