import argparse
from pathlib import Path
import signal
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Server, ServerError, info, wait_for

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0


def read_commands(directory):
    result = []
    for path in sorted(directory.rglob('*.incr.aof')):
        data = path.read_bytes()
        position = 0
        while position < len(data):
            if data[position:position + 1] == b'#':
                position = data.index(b'\r\n', position) + 2
                continue
            end = data.index(b'\r\n', position)
            if data[position:position + 1] != b'*':
                raise AssertionError('AOF command array required')
            count = int(data[position + 1:end])
            position = end + 2
            command = []
            for unused in range(count):
                end = data.index(b'\r\n', position)
                if data[position:position + 1] != b'$':
                    raise AssertionError('AOF argument bulk required')
                length = int(data[position + 1:end])
                position = end + 2
                command.append(data[position:position + length])
                position += length
                if data[position:position + 2] != b'\r\n':
                    raise AssertionError('AOF argument terminator required')
                position += 2
            result.append(command)
    return result


class HashExpiryAof(unittest.TestCase):
    def setUp(self):
        self.server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS), '--appendonly', 'yes',
                                                         '--appendfsync', 'always', '--aof-use-rdb-preamble', 'no'))
        self.addCleanup(self.server.close)
        self.server.start()
        self.client = self.server.client()

    def commands(self):
        return read_commands(self.server.directory)

    def field_deletions(self):
        return [command for command in self.commands() if command[0].upper() == b'HDEL']

    def restart(self):
        self.server.stop()
        self.server.start()
        self.client = self.server.client()

    def test_immediate_field_deletions_are_atomic_individual_effects(self):
        self.client.call('HSET', 'immediate', 'first', 'a', 'second', 'b')
        self.assertEqual(self.client.call('HEXPIREAT', 'immediate', 1, 'FIELDS', 3,
                                          'first', 'second', 'missing'), [2, 2, -2])
        expected = [[b'MULTI'], [b'HDEL', b'immediate', b'first'],
                    [b'HDEL', b'immediate', b'second'], [b'EXEC']]
        commands = self.commands()
        index = commands.index([b'MULTI'])
        self.assertEqual(commands[index:index + 4], expected)
        self.restart()
        self.assertEqual(self.client.call('EXISTS', 'immediate'), 0)

    def test_lazy_field_reads_log_actual_hdel_and_replay_without_resurrection(self):
        self.client.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        self.client.call('HSET', 'lazy', 'a', 1, 'b', 2, 'c', 3)
        self.client.call('HPEXPIRE', 'lazy', 1, 'FIELDS', 3, 'a', 'b', 'c')
        time.sleep(.01)
        self.assertEqual(self.client.call('HEXISTS', 'lazy', 'a'), 0)
        self.assertIsNone(self.client.call('HGET', 'lazy', 'b'))
        self.assertEqual(self.client.call('HSTRLEN', 'lazy', 'c'), 0)
        self.assertEqual(self.field_deletions(), [[b'HDEL', b'lazy', field] for field in (b'a', b'b', b'c')])
        self.restart()
        self.assertEqual(self.client.call('EXISTS', 'lazy'), 0)

    def test_active_expiry_after_move_copy_swap_uses_current_database(self):
        self.client.call('HSET', 'moved', 'expires', 'value', 'retained', 'value')
        self.client.call('HPEXPIRE', 'moved', 150, 'FIELDS', 1, 'expires')
        self.client.call('MOVE', 'moved', 1)
        self.client.call('SELECT', 1)
        self.client.call('COPY', 'moved', 'copied')
        self.client.call('SWAPDB', 1, 2)
        self.client.call('SELECT', 2)
        wait_for(lambda: self.client.call('HLEN', 'moved') == 1 and self.client.call('HLEN', 'copied') == 1,
                 timeout=3, label='active field expiry after database ownership changes')
        deletes = self.field_deletions()
        self.assertCountEqual(deletes, [[b'HDEL', b'moved', b'expires'], [b'HDEL', b'copied', b'expires']])
        selected = 0
        for command in self.commands():
            if command[0].upper() == b'SELECT':
                selected = int(command[1])
            if command[0].upper() == b'HDEL':
                self.assertEqual(selected, 2)
        self.restart()
        self.client.call('SELECT', 2)
        self.assertEqual(self.client.call('HGETALL', 'moved'), [b'retained', b'value'])
        self.assertEqual(self.client.call('HGETALL', 'copied'), [b'retained', b'value'])

    def test_increment_and_setnx_prechecks_do_not_duplicate_expiry_effects(self):
        self.client.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        for key in ('increment', 'setnx'):
            self.client.call('HSET', key, 'field', 4, 'retained', 8)
            self.client.call('HPEXPIRE', key, 1, 'FIELDS', 1, 'field')
        time.sleep(.01)
        self.assertEqual(self.client.call('HINCRBY', 'increment', 'field', 3), 3)
        self.assertEqual(self.client.call('HSETNX', 'setnx', 'field', 9), 1)
        self.assertCountEqual(self.field_deletions(), [[b'HDEL', b'increment', b'field'], [b'HDEL', b'setnx', b'field']])
        self.restart()
        self.assertEqual(self.client.call('HGET', 'increment', 'field'), b'3')
        self.assertEqual(self.client.call('HGET', 'setnx', 'field'), b'9')


    def test_suppressed_binary_field_expiry_and_disconnected_order_remain_exact(self):
        c = self.client
        c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        field = b'field\r\n\x00'
        c.call('HSET', 'suppressed', field, 'value', 'keep', 'stable')
        c.send_many([('CLIENT', 'REPLY', 'OFF'), ('HPEXPIRE', 'suppressed', 60000, 'FIELDS', 1, field),
                     ('CLIENT', 'REPLY', 'ON'), ('PING', 'after-off')])
        self.assertEqual(c.reply(), 'OK')
        self.assertEqual(c.reply(), b'after-off')
        c.send_many([('CLIENT', 'REPLY', 'SKIP'), ('HPERSIST', 'suppressed', 'FIELDS', 1, field), ('PING', 'after-skip')])
        self.assertEqual(c.reply(), b'after-skip')
        c.call('HPEXPIRE', 'suppressed', 1, 'FIELDS', 1, field)
        time.sleep(.01)
        c.send_many([('CLIENT', 'REPLY', 'OFF'), ('HGET', 'suppressed', field),
                     ('CLIENT', 'REPLY', 'ON'), ('PING', 'after-lazy')])
        self.assertEqual(c.reply(), 'OK')
        self.assertEqual(c.reply(), b'after-lazy')
        writer = self.server.client()
        writer.send_many([('HSET', 'disconnected', 'n', 1), ('HINCRBY', 'disconnected', 'n', 2),
                          ('HPEXPIRE', 'disconnected', 100000, 'FIELDS', 1, 'n')])
        writer.socket.shutdown(1)
        wait_for(lambda: c.call('HGET', 'disconnected', 'n') == b'3', label='ordered disconnected hash writes')
        self.assertEqual([command for command in self.field_deletions() if command[1] == b'suppressed'],
                         [[b'HDEL', b'suppressed', field]])
        self.assertIn([b'HPERSIST', b'suppressed', b'FIELDS', b'1', field], self.commands())
        self.assertFalse(any(command[0].upper() == b'RESTORE' for command in self.commands()))
        self.restart()
        self.assertEqual(self.client.call('HGETALL', 'suppressed'), [b'keep', b'stable'])
        self.assertEqual(self.client.call('HGET', 'disconnected', 'n'), b'3')
        self.assertGreater(self.client.call('HPTTL', 'disconnected', 'FIELDS', 1, 'n')[0], 50000)

    def test_float_increment_keeps_future_field_deadline_across_replay(self):
        for threshold in (512, 0):
            for execution in ('direct', 'transaction', 'lua'):
                self.client.call('CONFIG', 'SET', 'hash-max-listpack-entries', threshold)
                key = 'float-expiry-' + str(threshold) + '-' + execution
                self.client.call('HSET', key, 'field', 1)
                self.client.call('HPEXPIRE', key, 60000, 'FIELDS', 1, 'field')
                deadline = self.client.call('HPEXPIRETIME', key, 'FIELDS', 1, 'field')
                if execution == 'transaction':
                    self.client.call('MULTI')
                    self.client.call('HINCRBYFLOAT', key, 'field', '.5')
                    self.assertEqual(self.client.call('EXEC'), [b'1.5'])
                elif execution == 'lua':
                    self.assertEqual(self.client.call('EVAL', "return redis.call('HINCRBYFLOAT',KEYS[1],ARGV[1],ARGV[2])", 1, key, 'field', '.5'), b'1.5')
                else:
                    self.assertEqual(self.client.call('HINCRBYFLOAT', key, 'field', '.5'), b'1.5')
                self.assertEqual(self.client.call('HPEXPIRETIME', key, 'FIELDS', 1, 'field'), deadline)
                self.client.call('SAVE')
                self.client.call('DEBUG', 'RELOAD', 'NOSAVE')
                self.assertEqual(self.client.call('HPEXPIRETIME', key, 'FIELDS', 1, 'field'), deadline)
                self.client.call('DEBUG', 'LOADAOF')
                self.assertEqual(self.client.call('HPEXPIRETIME', key, 'FIELDS', 1, 'field'), deadline)
                self.restart()
                self.assertEqual(self.client.call('HGET', key, 'field'), b'1.5')
                self.assertEqual(self.client.call('HPEXPIRETIME', key, 'FIELDS', 1, 'field'), deadline)

    def test_empty_expired_field_is_a_real_owned_deletion_event(self):
        self.client.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        for threshold in (512, 0):
            self.client.call('CONFIG', 'SET', 'hash-max-listpack-entries', threshold)
            key = 'empty-field-' + str(threshold)
            self.client.call('HSET', key, b'', 'value', 'keep', 'stable')
            self.client.call('HPEXPIRE', key, 1, 'FIELDS', 1, b'')
            time.sleep(.01)
            self.assertEqual(self.client.pipeline([('HEXISTS', key, b''), ('HGET', key, b''), ('PING',)]),
                             [0, None, 'PONG'])
            self.assertEqual([command for command in self.field_deletions() if command[1] == key.encode()],
                             [[b'HDEL', key.encode(), b'']])
        self.restart()
        for threshold in (512, 0):
            self.assertEqual(self.client.call('HGETALL', 'empty-field-' + str(threshold)), [b'keep', b'stable'])

    def test_bounded_hash_retry_and_disjoint_error_do_not_duplicate_trace(self):
        for budget in (16 << 20, (42 << 20) + (256 << 10)):
            with Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS),
                        '--keyspace-max-memory', str(budget), '--appendonly', 'yes', '--appendfsync', 'always',
                        '--aof-use-rdb-preamble', 'no')) as server:
                c = server.client()
                c.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
                c.call('CONFIG', 'SET', 'rdbcompression', 'no')
                before = info(c, 'server')
                self.assertEqual(c.call('HSET', 'large-hash', 'large', b'x' * (6 << 20)), 1)
                after = info(c, 'server')
                if KEYSPACE_THREADS:
                    self.assertGreater(int(after['keyspace_jobs_submitted']), int(before['keyspace_jobs_submitted']))
                    self.assertGreater(int(after['keyspace_sync_fallbacks']), int(before['keyspace_sync_fallbacks']))
                c.call('HSET', 'small', 'dead', 'gone', 'bad', 'text')
                c.call('HPEXPIRE', 'small', 1, 'FIELDS', 1, 'dead')
                time.sleep(.01)
                results = c.pipeline([('HMGET', 'small', 'dead', 'bad'), ('HINCRBY', 'small', 'bad', 1),
                                      ('HSET', 'peer', 'value', 'retained'), ('HPEXPIRE', 'peer', 100000, 'FIELDS', 1, 'value')])
                self.assertEqual(results[0], [None, b'text'])
                self.assertIsInstance(results[1], ServerError)
                self.assertEqual(results[2:], [1, [1]])
                commands = read_commands(server.directory)
                self.assertEqual(sum(command[0].upper() == b'HSET' and command[1] == b'large-hash' for command in commands), 1)
                self.assertFalse(any(command[0].upper() == b'RESTORE' for command in commands))
                self.assertEqual([command for command in commands if command[0].upper() == b'HDEL'],
                                 [[b'HDEL', b'small', b'dead']])
                server.stop()
                server.start()
                restored = server.client()
                self.assertEqual(restored.call('HSTRLEN', 'large-hash', 'large'), 6 << 20)
                self.assertEqual(restored.call('HGETALL', 'small'), [b'bad', b'text'])
                self.assertEqual(restored.call('HGET', 'peer', 'value'), b'retained')
                self.assertGreater(restored.call('HPTTL', 'peer', 'FIELDS', 1, 'value')[0], 50000)


def main():
    global BINARY, KEYSPACE_THREADS
    parser = argparse.ArgumentParser(description='Original canonical hash-field expiry AOF encoding and durability regressions.')
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--keyspace-threads', type=int, choices=(0, 2), default=0)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    KEYSPACE_THREADS = args.keyspace_threads
    if not BINARY.is_file():
        parser.error('existing server binary required')
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(124))
    signal.alarm(60)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(HashExpiryAof))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
