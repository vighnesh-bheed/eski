import argparse
import fnmatch
import hashlib
from pathlib import Path
import socket
import ssl
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'test/threading'))
sys.path.insert(0, str(ROOT/'test/compatibility'))
from support import Client, Server, ServerError, wait_for
import transport

REFERENCE_PORT = None


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


    def test_session_lifecycle_is_logged(self):
        server = self.server(['--compute-threads', '2', '--keyspace-threads', '2'])
        source = server.connection()
        self.begin(source, 'SYNC', 'return 3')
        source.send('continue')
        self.finish(source, 3)
        source = server.connection()
        self.begin(source, 'YES', 'return 4')
        source.send('continue')
        self.finish(source, 4)
        source = server.connection()
        self.begin(source, 'YES', 'return 5')
        log = server.directory / 'server.log'
        wait_for(lambda: log.read_text().count('Eski forked for debugging eval') == 2, label='forked session log')
        control = server.connection()
        control.send('SHUTDOWN', 'NOSAVE')
        self.assertEqual(server.process.wait(timeout=10), 0)
        text = log.read_text()
        for line in ('* Eski synchronous debugging eval session started', '* Eski synchronous debugging eval session ended',
                     ':C ', '* Lua debugging session child exiting', '* Killing debugging session '):
            self.assertIn(line, text)
        self.assertEqual(text.count('Lua debugging session child exiting'), 1)


class Replies(unittest.TestCase):
    SCRIPT = '\n'.join(["local a = 1", "local b = {1,2,3}", "redis.call('set', 'dbg:k1', 'v')", "local c = redis.call('get', 'dbg:k1')",
                        "redis.setresp(3)", "local d = redis.call('get', 'dbg:nokey')", "local e = redis.call('hgetall', 'dbg:nohash')",
                        "redis.call('mset', 'dbg:a1','1','dbg:a2','2','dbg:a3','3','dbg:a4','4','dbg:a5','5','dbg:a6','6')",
                        "local f = redis.call('hset', 'dbg:hh', 'x', '1')", "local g = redis.call('hgetall', 'dbg:hh')", "local h = 12", "return a"])

    def setUp(self):
        self.instance = None
        if REFERENCE_PORT is None:
            self.instance = Server(transport.BINARY, workers=0)
            self.addCleanup(self.instance.close)
            self.instance.start()
        self.admin = self.connect()
        for key in ('dbg:k1', 'dbg:hh', 'dbg:h3', 'dbg:s3', 'dbg:z3', 'dbg:long', 'dbg:str') + tuple('dbg:a%d' % i for i in range(1, 7)):
            self.admin.call('DEL', key)
        self.admin.call('HSET', 'dbg:h3', 'a', '1')
        self.admin.call('SADD', 'dbg:s3', 'x')
        self.admin.call('ZADD', 'dbg:z3', '1.5', 'm')
        self.admin.call('SET', 'dbg:long', 'x'*300)
        self.admin.call('SET', 'dbg:str', 'text')

    def connect(self):
        client = Client(REFERENCE_PORT if REFERENCE_PORT is not None else self.instance.port)
        self.addCleanup(client.close)
        return client

    def session(self, script):
        source = self.connect()
        self.assertEqual(source.call('SCRIPT', 'DEBUG', 'SYNC'), 'OK')
        source.send('EVAL', script, 0)
        self.assertTrue(source.reply()[0].startswith('* Stopped at '))
        return source

    def step(self, source, *command):
        source.send(*command)
        value = source.reply()
        self.assertIsInstance(value, list)
        return value

    def finish(self, source, expected):
        source.send('continue')
        self.assertEqual(source.reply(), ['<endsession>'])
        self.assertEqual(source.reply(), expected)

    def test_breakpoint_listing_and_maxlen_replies(self):
        source = self.session(self.SCRIPT)
        for command, expected in (
                (('foo',), ['<error> Unknown Redis Lua debugger command or wrong number of arguments.']),
                (('r',), ['<error> Unknown Redis Lua debugger command or wrong number of arguments.']),
                (('b',), ["No breakpoints set. Use 'b <line>' to add one."]),
                (('b', '3'), ['   2   local b = {1,2,3}', "  #3   redis.call('set', 'dbg:k1', 'v')", "   4   local c = redis.call('get', 'dbg:k1')"]),
                (('b', '3'), ['Wrong line number.']), (('b', '99'), ['Wrong line number.']),
                (('b', '-3'), ['Breakpoint removed.']), (('b', '-7'), ['No breakpoint in the specified line.']),
                (('b', 'x'), ["Invalid argument:'x'"]), (('b', '02'), ["Invalid argument:'02'"]), (('b', '-0'), ["Invalid argument:'-0'"]),
                (('b', '0'), ['All breakpoints removed.']),
                (('b', '11'), ["   10  local g = redis.call('hgetall', 'dbg:hh')", '  #11  local h = 12', '   12  return a']),
                (('B',), ['1 breakpoints set:', '  #11  local h = 12']),
                (('l', '11', 'x'), ['  #11  local h = 12']),
                (('maxlen',), ['<value> replies are truncated at 256 bytes.']),
                (('maxlen', '10'), ['<value> replies are truncated at 60 bytes.']),
                (('maxlen', '-5'), ['<value> replies are truncated at 60 bytes.']),
                (('maxlen', '61'), ['<value> replies are truncated at 61 bytes.']),
                (('maxlen', '0'), ['<value> replies are unlimited.']),
                (('MAXLEN', 'abc'), ['<value> replies are unlimited.']),
                (('p',), ['No local variables in the current context.']),
                (('Print', 'nosuch'), ['No such variable.']),
                (('e',), ['<retval> nil']),
                (('eval', "redis.call('ping')"), ['<retval> {["ok"]="PONG"}'])):
            with self.subTest(command=command):
                self.assertEqual(self.step(source, *command), expected)
        self.assertEqual(self.step(source, 'STEP'), ['* Stopped at 2, stop reason = step over', '-> 2   local b = {1,2,3}'])
        self.step(source, 'b', '0')
        self.finish(source, 1)

    def test_traced_commands_and_replies_render_like_the_reference(self):
        source = self.session(self.SCRIPT)
        for command, expected in (
                (('r', 'hgetall', 'dbg:h3'), ['<redis> hgetall dbg:h3', '<reply> ["a","1"]']),
                (('r', 'get', 'dbg:nokey'), ['<redis> get dbg:nokey', '<reply> NULL']),
                (('r', 'nosuchcmd'), ['<redis> nosuchcmd', '<error> Unknown Redis command called from script']),
                (('r', 'get'), ['<redis> get', '<error> Wrong number of args calling Redis command from script']),
                (('r', 'hello'), ['<redis> hello', '<error> This command is not allowed from script']),
                (('r', 'incr', 'dbg:str'), ['<redis> incr dbg:str', '<error> -ERR value is not an integer or out of range', '<reply> "-ERR value is not an integer or out of range"']),
                (('r', 'mset', 'a', '1', 'b', '2', 'c', '3', 'd', '4', 'e', '5', 'f'),
                 ['<redis> mset a 1 b 2 c 3 d 4 e ... (1 more)', "<error> -ERR wrong number of arguments for 'mset' command", "<reply> \"-ERR wrong number of arguments for 'mset' command\""]),
                (('e', 'redis.setresp(3)'), ['<retval> nil']),
                (('r', 'hgetall', 'dbg:h3'), ['<redis> hgetall dbg:h3', '<reply> {"a" => "1"}']),
                (('r', 'smembers', 'dbg:s3'), ['<redis> smembers dbg:s3', '<reply> ~("x")']),
                (('r', 'zscore', 'dbg:z3', 'm'), ['<redis> zscore dbg:z3 m', '<reply> (double) 1.5']),
                (('r', 'get', 'dbg:nokey'), ['<redis> get dbg:nokey', '<reply> (null)']),
                (('r', 'get', 'dbg:long'), ['<redis> get dbg:long', '<reply> "' + 'x'*247 + ' ...', "<hint> The above reply was trimmed. Use 'maxlen 0' to disable trimming."]),
                (('r', 'get', 'dbg:long'), ['<redis> get dbg:long', '<reply> "' + 'x'*247 + ' ...'])):
            with self.subTest(command=command):
                self.assertEqual(self.step(source, *command), expected)
        self.finish(source, 1)

    def test_stepping_logs_and_stop_reasons(self):
        source = self.session(self.SCRIPT)
        self.step(source, 'b', '4')
        self.assertEqual(self.step(source, 's'), ['* Stopped at 2, stop reason = step over', '-> 2   local b = {1,2,3}'])
        self.assertEqual(self.step(source, 's'), ['* Stopped at 3, stop reason = step over', "-> 3   redis.call('set', 'dbg:k1', 'v')"])
        self.assertEqual(self.step(source, 's'), ['<redis> set dbg:k1 v', '<reply> "+OK"', '* Stopped at 4, stop reason = break point', "->#4   local c = redis.call('get', 'dbg:k1')"])
        self.step(source, 'b', '0')
        for line in range(5, 8):
            self.step(source, 's')
        self.assertEqual(self.step(source, 's'), ['<redis> hgetall dbg:nohash', '<reply> {}', '* Stopped at 8, stop reason = step over',
                                                  "-> 8   redis.call('mset', 'dbg:a1','1','dbg:a2','2','dbg:a3','3','dbg:a4','4','dbg:a5','5','dbg:a6','6')"])
        self.assertEqual(self.step(source, 's')[0], '<redis> mset dbg:a1 1 dbg:a2 2 dbg:a3 3 dbg:a4 4 dbg:a5 ... (2 more)')
        self.assertEqual(self.step(source, 's'), ['<redis> hset dbg:hh x 1', '<reply> 1', '* Stopped at 10, stop reason = step over', "-> 10  local g = redis.call('hgetall', 'dbg:hh')"])
        self.finish(source, 1)

    def test_trace_skips_tail_calls_and_names_callers(self):
        source = self.session('\n'.join(["local function inner(x)", "  local y = x + 1", "  redis.breakpoint()", "  return y", "end",
                                         "local function outer()", "  return inner(5)", "end", "return outer()"]))
        self.assertEqual(self.step(source, 'c'), ['* Stopped at 4, stop reason = redis.breakpoint() called', '-> 4     return y'])
        self.assertEqual(self.step(source, 't'), ['In top level:', '-> 4     return y'])
        self.finish(source, 6)
        source = self.session('\n'.join(["local function f(x)", "  redis.breakpoint()", "  return x + 1", "end", "local y = f(1)", "return y"]))
        self.step(source, 'c')
        self.assertEqual(self.step(source, 't'), ['In f:', '-> 3     return x + 1', 'From top level:', '   5   local y = f(1)'])
        self.finish(source, 2)

    def test_more_than_1024_arguments_end_the_session_with_protocol_error(self):
        script = 'return 1'
        source = self.session(script)
        self.assertEqual(self.step(source, 'r', *['x']*1023), ['<redis> x x x x x x x x x x ... (1012 more)', '<error> Unknown Redis command called from script'])
        source.send('r', *['x']*1024)
        self.assertEqual(source.reply(), ['<endsession>'])
        error = source.reply()
        self.assertIsInstance(error, ServerError)
        self.assertEqual(str(error), 'ERR protocol error script: %s, on @user_script:1.' % hashlib.sha1(script.encode()).hexdigest())
        with self.assertRaises((EOFError, OSError)):
            source.send('PING')
            source.reply()


def main():
    global REFERENCE_PORT
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', type=Path, default=ROOT/'bin/eski')
    parser.add_argument('--reference-port', type=int)
    parser.add_argument('--case', action='append', default=[])
    args = parser.parse_args()
    transport.BINARY = args.server.resolve()
    REFERENCE_PORT = args.reference_port
    suite = unittest.TestSuite()
    for kind in (Replies,) if REFERENCE_PORT is not None else (Debugger, Replies):
        for name in sorted(kind.__dict__):
            if name.startswith('test_') and (not args.case or any(fnmatch.fnmatchcase(name, pattern) for pattern in args.case)):
                suite.addTest(kind(name))
    if not suite.countTestCases():
        raise SystemExit('no debugger cases selected')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())


if __name__ == '__main__':
    main()
