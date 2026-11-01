import argparse
import fnmatch
from pathlib import Path
import socket
import ssl
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'test/threading'))
sys.path.insert(0, str(ROOT/'test/compatibility'))
from support import ServerError
import transport


class Debugger(transport.Transport):
    def fixture(self):
        server = self.server(['--compute-threads', '2', '--keyspace-threads', '2'])
        source, observer = server.connection(), server.connection()
        return server, source, observer

    def logs(self, source, contains=None):
        value = source.reply()
        self.assertIsInstance(value, list)
        self.assertTrue(all(isinstance(line, str) for line in value), value)
        if contains is not None:
            self.assertIn(contains.lower(), '\n'.join(value).lower())
        return value

    def command(self, source, *args, contains=None):
        source.send(*args)
        return self.logs(source, contains)

    def begin(self, source, mode, script, *arguments):
        self.assertEqual(source.call('SCRIPT', 'DEBUG', mode), 'OK')
        source.send('EVAL', script, 1, 'debug-key', *arguments)
        self.logs(source, 'Stopped')

    def finish(self, source, result=None, error=False):
        self.logs(source, '<endsession>')
        value = source.reply()
        if error:
            self.assertIsInstance(value, ServerError)
        else:
            self.assertEqual(value, result)
        with self.assertRaises((EOFError, OSError)):
            source.reply()

    def test_sync_steps_locals_eval_breakpoint_and_retained_write(self):
        server, source, observer = self.fixture()
        self.begin(source, 'SYNC', 'local x=7\nredis.call("SET",KEYS[1],x)\nreturn x+1')
        self.command(source, 'step', contains='Stopped')
        self.command(source, 'print', 'x', contains='7')
        self.command(source, 'eval', 'return x+2', contains='nonexistent global')
        self.command(source, 'eval', 'return 3+4', contains='7')
        self.command(source, 'redis', 'PING', contains='PONG')
        self.command(source, 'break', '3')
        self.command(source, 'continue', contains='Stopped')
        self.command(source, 'trace', contains='3')
        source.send('continue')
        self.finish(source, 8)
        self.assertEqual(observer.call('GET', 'debug-key'), b'7')
        self.assertEqual(observer.call('PING'), 'PONG')

    def test_forked_session_discards_writes_and_parent_keeps_serving(self):
        server, source, observer = self.fixture()
        observer.call('MSET', 'before:a', 'one', 'before:b', 'two')
        self.begin(source, 'YES', 'redis.call("SET",KEYS[1],"child")\nreturn 9')
        self.assertEqual(observer.call('PING'), 'PONG')
        self.assertEqual(observer.call('MGET', 'before:a', 'before:b'), [b'one', b'two'])
        self.command(source, 'redis', 'SET', 'debug-extra', 'temporary')
        source.send('continue')
        self.finish(source, 9)
        self.assertIsNone(observer.call('GET', 'debug-key'))
        self.assertIsNone(observer.call('GET', 'debug-extra'))

    def test_sync_abort_preserves_debugger_effects(self):
        server, source, observer = self.fixture()
        self.begin(source, 'SYNC', 'return 5')
        self.command(source, 'redis', 'SET', 'debug-kept', 'value')
        source.send('abort')
        self.finish(source, error=True)
        self.assertEqual(observer.call('GET', 'debug-kept'), b'value')

    def test_timeout_prompt_and_bounded_debug_eval(self):
        server, source, observer = self.fixture()
        source.call('CONFIG', 'SET', 'busy-reply-threshold', '10')
        self.begin(source, 'SYNC', 'return 5')
        self.command(source, 'eval', 'local start=os.clock(); while os.clock()-start<0.05 do end; return 7', contains='7')
        self.command(source, 'eval', 'return 7', contains='7')
        source.send('continue')
        self.finish(source, 5)
        source = server.connection()
        self.begin(source, 'SYNC', 'while true do end')
        self.command(source, 'continue', contains='timeout')
        source.send('abort')
        self.finish(source, error=True)
        self.assertEqual(observer.call('PING'), 'PONG')

    def test_malformed_commands_do_not_corrupt_session(self):
        server, source, observer = self.fixture()
        self.begin(source, 'SYNC', 'return 12')
        self.command(source, b'\0unknown', contains='Unknown Redis Lua debugger command')
        self.command(source, 'redis', 'not-a-command', *['x']*100, contains='Unknown')
        self.command(source, 'print', 'KEYS', contains='debug-key')
        source.send('continue')
        self.finish(source, 12)

    def test_pipelined_fork_reply_prefix_is_sent_once(self):
        server, source, observer = self.fixture()
        source.send_many([('SCRIPT', 'DEBUG', 'YES'), ('EVAL', 'return 21', 0)])
        self.assertEqual(source.reply(), 'OK')
        self.logs(source, 'Stopped')
        source.send('continue')
        self.finish(source, 21)
        self.assertEqual(observer.call('PING'), 'PONG')

    def test_unix_debug_child_keeps_parent_socket_path(self):
        server = self.server(['--compute-threads', '2', '--keyspace-threads', '2'], unix=True)
        source = server.connection()
        self.begin(source, 'YES', 'return 27')
        parent = server.connection()
        self.assertEqual(parent.call('PING'), 'PONG')
        self.assertTrue(server.socket_path.exists())
        source.send('continue')
        self.finish(source, 27)
        self.assertEqual(parent.call('PING'), 'PONG')

    def test_tls_fork_does_not_send_parent_close_notify(self):
        server = self.tls_server(extra=['--compute-threads', '2', '--keyspace-threads', '2'])
        source, parent = self.tls_client(server), self.tls_client(server)
        self.begin(source, 'YES', 'redis.call("SET",KEYS[1],"discarded")\nreturn 31')
        self.assertEqual(parent.call('PING'), 'PONG')
        self.command(source, 'eval', 'return 3+4', contains='7')
        source.send('continue')
        self.finish(source, 31)
        self.assertIsNone(parent.call('GET', 'debug-key'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', type=Path, default=ROOT/'bin/eski')
    parser.add_argument('--case', action='append', default=[])
    args = parser.parse_args()
    transport.BINARY = args.server.resolve()
    suite = unittest.TestSuite()
    for name in sorted(Debugger.__dict__):
        if name.startswith('test_') and (not args.case or any(fnmatch.fnmatchcase(name, pattern) for pattern in args.case)):
            suite.addTest(Debugger(name))
    if not suite.countTestCases():
        raise SystemExit('no debugger cases selected')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())


if __name__ == '__main__':
    main()
