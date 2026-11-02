import argparse
import fnmatch
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Client, Push, Server, ServerError, info, wait_for

BINARY = ROOT / 'bin/eski'
REFERENCE_PORT = None
KEYSPACE_THREADS = 0
NODENAME_ERROR = ("ERR CONFIG SET failed (possibly related to argument 'cluster-announce-human-nodename') - "
                  "Announced human node name contained invalid character")
MANY_SCRIPTS = (" * Many scripts: There seem to be many cached scripts in this instance (more than 1000). This may be "
                "because scripts are generated and `EVAL`ed, instead of being parameterized (with KEYS and ARGV), "
                "`SCRIPT LOAD`ed and `EVALSHA`ed. Unless `SCRIPT FLUSH` is called periodically, the scripts' caches "
                "may end up consuming most of your memory.\n\n")


def error_of(client, *arguments):
    client.send(*arguments)
    value = client.reply()
    if not isinstance(value, ServerError):
        raise AssertionError('expected an error from %r, got %r' % (arguments, value))
    return str(value)


def fields_of(row):
    return dict(part.split('=', 1) for part in row.decode().split() if '=' in part)


def link_local_address():
    try:
        rows = Path('/proc/net/if_inet6').read_text().splitlines()
    except OSError:
        return None
    for row in rows:
        parts = row.split()
        if len(parts) >= 6 and parts[0].startswith('fe80') and parts[5] != 'lo':
            text = ':'.join(parts[0][i:i + 4] for i in range(0, 32, 4))
            return socket.inet_ntop(socket.AF_INET6, socket.inet_pton(socket.AF_INET6, text)), int(parts[1], 16)
    return None


class ServerParity(unittest.TestCase):
    def setUp(self):
        if REFERENCE_PORT is None:
            self.server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS)))
            self.addCleanup(self.server.close)
            self.server.start()
            self.port = self.server.port
        else:
            self.server = None
            self.port = REFERENCE_PORT
        self.client = self.connection()
        self.client.call('FLUSHALL')
        self.client.call('DEBUG', 'SET-ACTIVE-EXPIRE', 1)
        self.addCleanup(self.restore_defaults)

    def restore_defaults(self):
        cleanup = Client(self.port)
        try:
            cleanup.call('CLIENT', 'UNPAUSE')
            cleanup.call('DEBUG', 'SET-ACTIVE-EXPIRE', 1)
            cleanup.call('CONFIG', 'SET', 'rdb-key-save-delay', 0)
            cleanup.call('CONFIG', 'SET', 'maxmemory-policy', 'noeviction')
            cleanup.call('CONFIG', 'SET', 'cluster-announce-human-nodename', '')
            wait_for(lambda: info(cleanup, 'persistence')['rdb_bgsave_in_progress'] == '0', timeout=20,
                     label='background save finished')
            cleanup.call('SCRIPT', 'FLUSH')
            cleanup.call('FLUSHALL')
        finally:
            cleanup.close()

    def connection(self, protocol=2):
        client = Client(self.port)
        self.addCleanup(client.close)
        if protocol == 3:
            client.call('HELLO', 3)
        return client

    def owned(self):
        if REFERENCE_PORT is not None:
            self.skipTest('requires ownership of the server process')

    def test_scan_masks_cursor_beyond_table(self):
        for i in range(5):
            self.client.call('SET', 'k%d' % i, 'v')
        for cursor in (4096, 64):
            nxt, keys = self.client.call('SCAN', cursor, 'COUNT', 100)
            self.assertEqual(nxt, b'0')
            self.assertEqual(sorted(keys), [b'k0', b'k1', b'k2', b'k3', b'k4'])
        nxt, keys = self.client.call('SCAN', '18446744073709551615', 'COUNT', 100)
        self.assertTrue(set(keys) <= {b'k0', b'k1', b'k2', b'k3', b'k4'})
        self.client.call('FLUSHALL')
        self.assertEqual(self.client.call('SCAN', 4096), [b'0', []])

    def test_scan_family_keywords_end_at_nul(self):
        self.client.call('SADD', 's', 'a', 'b', 'c')
        self.client.call('HSET', 'h', 'a', 1)
        self.client.call('ZADD', 'z', 1, 'a')
        self.assertEqual(sorted(self.client.call('SSCAN', 's', 0, b'COUNT\x00xyz', 10)[1]), [b'a', b'b', b'c'])
        self.assertEqual(self.client.call('HSCAN', 'h', 0, b'COUNT\x00xyz', 10), [b'0', [b'a', b'1']])
        self.assertEqual(self.client.call('ZSCAN', 'z', 0, b'COUNT\x00xyz', 10), [b'0', [b'a', b'1']])
        self.assertEqual(sorted(self.client.call('SCAN', 0, b'COUNT\x00xyz', 10)[1]), [b'h', b's', b'z'])
        self.assertEqual(self.client.call('SCAN', 0, b'TYPE\x00x', 'set')[1], [b's'])
        self.assertEqual(self.client.call('HSCAN', 'h', 0, b'NOVALUES\x00x'), [b'0', [b'a']])
        self.assertEqual(self.client.call('HSCAN', 'h', 0, b'MATCH\x00x', '*'), [b'0', [b'a', b'1']])
        for command in (('ZSCAN', 'z', 0), ('SCAN', 0)):
            self.assertEqual(error_of(self.client, *command, b'NOVALUES\x00x'), 'ERR NOVALUES option can only be used in HSCAN')

    def test_quoted_error_arguments_end_at_nul(self):
        cases = [
            (('NOSUCH', b'a\x00b', 'c'), "ERR unknown command 'NOSUCH', with args beginning with: 'a' 'c' "),
            ((b'NO\x00SUCH', 'x'), "ERR unknown command 'NO', with args beginning with: 'x' "),
            (('CLIENT', b'NOSUCH\x00X'), "ERR unknown subcommand 'NOSUCH'. Try CLIENT HELP."),
            (('CONFIG', b'GET\x00X', 'x'), "ERR unknown subcommand 'GET'. Try CONFIG HELP."),
            (('OBJECT', b'NOSUCH\x00Y', 'k'), "ERR unknown subcommand 'NOSUCH'. Try OBJECT HELP."),
            (('XINFO', b'NOSUCH\x00Y', 'k'), "ERR unknown subcommand 'NOSUCH'. Try XINFO HELP."),
            (('DEBUG', b'NOSUCH\x00X'), "ERR unknown subcommand or wrong number of arguments for 'NOSUCH'. Try DEBUG HELP."),
            (('CONFIG', 'SET', b'nosuch\x00x', 1), "ERR Unknown option or number of arguments for CONFIG SET - 'nosuch'"),
            (('CLIENT', 'SETINFO', b'BOGUS\x00y', 'x'), "ERR Unrecognized option 'BOGUS'"),
        ]
        for command, expected in cases:
            self.assertEqual(error_of(self.client, *command), expected)

    def test_randomkey_skips_expired_keys(self):
        self.client.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        self.client.pipeline([('SET', 'x%d' % i, 'v', 'PX', 1) for i in range(3000)])
        self.client.call('SET', 'live', 'v')
        time.sleep(0.1)
        for unused in range(5):
            self.assertEqual(self.client.call('RANDOMKEY'), b'live')
        self.assertLess(self.client.call('DBSIZE'), 3001)
        self.client.call('FLUSHALL')
        self.client.pipeline([('SET', 'x%d' % i, 'v', 'PX', 1) for i in range(500)])
        time.sleep(0.1)
        self.assertIsNone(self.client.call('RANDOMKEY'))
        self.assertEqual(self.client.call('DBSIZE'), 0)

    def test_randomkey_while_expiry_is_paused(self):
        pauser = self.connection()
        self.client.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        for i in range(20):
            self.client.call('SET', 'x%d' % i, 'v', 'PX', 1)
        self.client.call('SET', 'live', 'v')
        time.sleep(0.1)
        pauser.call('CLIENT', 'PAUSE', 5000, 'WRITE')
        self.assertEqual({self.client.call('RANDOMKEY') for unused in range(40)}, {b'live'})
        self.assertEqual(self.client.call('DBSIZE'), 21)
        pauser.call('CLIENT', 'UNPAUSE')
        self.client.call('DEL', 'live')
        pauser.call('CLIENT', 'PAUSE', 5000, 'WRITE')
        for unused in range(5):
            self.assertIn(self.client.call('RANDOMKEY'), {b'x%d' % i for i in range(20)})
        pauser.call('CLIENT', 'UNPAUSE')

    def test_access_time_frozen_while_child_runs(self):
        self.client.call('SET', 'k', 'v')
        self.client.call('SET', 'k2', 'v')
        self.client.call('SET', 't', 'v')
        time.sleep(2.2)
        self.client.call('CONFIG', 'SET', 'rdb-key-save-delay', 1000000)
        self.assertEqual(self.client.call('BGSAVE'), 'Background saving started')
        self.client.call('GET', 'k')
        self.client.call('TOUCH', 't')
        self.client.call('SET', 'k2', 'w')
        self.assertGreaterEqual(self.client.call('OBJECT', 'IDLETIME', 'k'), 2)
        self.assertGreaterEqual(self.client.call('OBJECT', 'IDLETIME', 't'), 2)
        self.assertGreaterEqual(self.client.call('OBJECT', 'IDLETIME', 'k2'), 2)
        self.client.call('CONFIG', 'SET', 'rdb-key-save-delay', 0)
        wait_for(lambda: info(self.client, 'persistence')['rdb_bgsave_in_progress'] == '0', timeout=20,
                 label='background save finished')
        self.client.call('GET', 'k')
        self.assertEqual(self.client.call('OBJECT', 'IDLETIME', 'k'), 0)

    def test_access_frequency_frozen_while_child_runs(self):
        self.client.call('CONFIG', 'SET', 'maxmemory-policy', 'allkeys-lfu')
        self.client.call('CONFIG', 'SET', 'lfu-log-factor', 0)
        self.addCleanup(self.client.call, 'CONFIG', 'SET', 'lfu-log-factor', 10)
        self.client.call('SET', 'k', 'v')
        self.assertEqual(self.client.call('OBJECT', 'FREQ', 'k'), 5)
        self.client.call('CONFIG', 'SET', 'rdb-key-save-delay', 1000000)
        self.client.call('BGSAVE')
        for unused in range(10):
            self.client.call('GET', 'k')
        self.assertEqual(self.client.call('OBJECT', 'FREQ', 'k'), 5)
        self.client.call('CONFIG', 'SET', 'rdb-key-save-delay', 0)
        wait_for(lambda: info(self.client, 'persistence')['rdb_bgsave_in_progress'] == '0', timeout=20,
                 label='background save finished')
        for unused in range(10):
            self.client.call('GET', 'k')
        self.assertEqual(self.client.call('OBJECT', 'FREQ', 'k'), 15)

    def test_noloop_skips_the_last_writer_of_a_paused_batch(self):
        tracker = self.connection(3)
        pauser = self.connection()
        writer = self.connection()
        tracker.call('CLIENT', 'TRACKING', 'on', 'BCAST', 'NOLOOP')
        for first, second, notified in ((writer, tracker, False), (tracker, writer, True)):
            pauser.call('CLIENT', 'PAUSE', 2000, 'WRITE')
            first.send('SET', 'k', 'first')
            time.sleep(0.05)
            second.send('SET', 'k', 'second')
            time.sleep(0.05)
            pauser.call('CLIENT', 'UNPAUSE')
            self.assertEqual(first.reply(), 'OK')
            self.assertEqual(second.reply(), 'OK')
            self.assertEqual(self.client.call('GET', 'k'), b'second')
            time.sleep(0.1)
            pushed = []
            while tracker.available(0.1):
                pushed.append(tracker.read())
            self.assertEqual(pushed, [Push([b'invalidate', [b'k']])] if notified else [])
            tracker.pushes.clear()

    def test_resp2_subscriber_without_redirect_gets_no_invalidation(self):
        writer = self.connection()
        for mode in ((), ('BCAST',)):
            tracker = self.connection()
            self.assertEqual(tracker.call('CLIENT', 'TRACKING', 'on', *mode), 'OK')
            tracker.call('GET', 'k')
            tracker.send('SUBSCRIBE', '__redis__:invalidate')
            self.assertEqual(tracker.read(), [b'subscribe', b'__redis__:invalidate', 1])
            writer.call('SET', 'k', 'v')
            self.assertFalse(tracker.available(0.3))
        looped = self.connection()
        looped.call('CLIENT', 'TRACKING', 'on', 'REDIRECT', looped.call('CLIENT', 'ID'))
        looped.call('GET', 'k')
        looped.send('SUBSCRIBE', '__redis__:invalidate')
        looped.read()
        writer.call('SET', 'k', 'v2')
        self.assertEqual(looped.read(), [b'message', b'__redis__:invalidate', [b'k']])

    def test_tracking_error_order_and_mode_reset(self):
        tracker = self.connection(3)
        self.assertEqual(error_of(tracker, 'CLIENT', 'TRACKING', 'maybe', 'REDIRECT', 999999),
                         'ERR The client ID you want redirect to does not exist')
        for words in (('on', 'BCAST', 'OPTIN', 'OPTOUT'), ('on', 'OPTIN', 'OPTOUT', 'BCAST')):
            self.assertEqual(error_of(tracker, 'CLIENT', 'TRACKING', *words), 'ERR OPTIN and OPTOUT are not compatible with BCAST')
        tracker.call('CLIENT', 'TRACKING', 'on', 'OPTIN')
        tracker.call('CLIENT', 'TRACKING', 'on')
        self.assertEqual(error_of(tracker, 'CLIENT', 'CACHING', 'yes'),
                         'ERR CLIENT CACHING YES is only valid when tracking is enabled in OPTIN mode.')
        self.assertEqual(error_of(tracker, 'CLIENT', 'CACHING', 'no'),
                         'ERR CLIENT CACHING NO is only valid when tracking is enabled in OPTOUT mode.')
        self.assertEqual(error_of(tracker, 'CLIENT', 'CACHING', 'maybe'), 'ERR syntax error')
        self.assertEqual(tracker.call('CLIENT', 'TRACKINGINFO')[b'flags'], [b'on'])
        self.assertEqual(tracker.call('CLIENT', 'TRACKING', 'on', 'OPTOUT'), 'OK')

    def test_client_list_accepts_only_type_or_id(self):
        me = self.client.call('CLIENT', 'ID')
        for words in (('USER', 'default'), ('ADDR', '127.0.0.1:1'), ('LADDR', '127.0.0.1:1'), ('SKIPME', 'yes'),
                      ('MAXAGE', 10), ('TYPE', 'normal', 'ID', me), ('TYPE', 'normal', 'extra')):
            self.assertEqual(error_of(self.client, 'CLIENT', 'LIST', *words), 'ERR syntax error')
        self.assertEqual(len(self.client.call('CLIENT', 'LIST', 'TYPE', 'normal').splitlines()), 1)
        self.assertEqual(len(self.client.call('CLIENT', 'LIST', 'ID', me, me).splitlines()), 2)

    def test_client_setinfo_keyword_ends_at_nul(self):
        self.assertEqual(self.client.call('CLIENT', 'SETINFO', b'LIB-NAME\x00', 'x'), 'OK')
        self.assertEqual(self.client.call('CLIENT', 'SETINFO', b'lib-ver\x00zz', '1.0'), 'OK')
        fields = fields_of(self.client.call('CLIENT', 'INFO'))
        self.assertEqual((fields['lib-name'], fields['lib-ver']), ('x', '1.0'))
        self.assertEqual(error_of(self.client, 'CLIENT', 'SETINFO', b'LIB-NAME\x00', 'a b'),
                         'ERR LIB-NAME cannot contain spaces, newlines or special characters.')

    def test_fresh_connection_reply_buffer_fields(self):
        fields = fields_of(self.connection().call('CLIENT', 'INFO'))
        self.assertEqual((fields['rbs'], fields['rbp']), ('16384', '16384'))

    def test_shutdown_abort_may_repeat(self):
        self.assertEqual(error_of(self.client, 'SHUTDOWN', 'ABORT', 'ABORT'), 'ERR No shutdown in progress.')
        for extra in ('NOSAVE', 'NOW', 'FORCE', 'SAVE'):
            self.assertEqual(error_of(self.client, 'SHUTDOWN', 'ABORT', extra), 'ERR syntax error')

    def test_memory_doctor_reports_many_scripts(self):
        self.client.pipeline([('SET', 'k%d' % i, 'x' * 200) for i in range(60000)])
        for i in range(1000):
            self.client.call('SCRIPT', 'LOAD', 'return %d' % i)
        self.assertNotIn(b'Many scripts', self.client.call('MEMORY', 'DOCTOR'))
        self.client.call('SCRIPT', 'LOAD', 'return 1000')
        report = self.client.call('MEMORY', 'DOCTOR').decode()
        self.assertIn(MANY_SCRIPTS + "I'm here to keep you safe, Sam. I want to help you.\n", report)

    def test_human_nodename_character_set(self):
        rejected = set(range(0, 45)) | set(range(58, 65)) | set(range(91, 95)) | set(range(123, 128))
        for code in range(256):
            value = b'a' + bytes([code]) + b'b'
            self.client.send('CONFIG', 'SET', 'cluster-announce-human-nodename', value)
            reply = self.client.reply()
            if code in rejected:
                self.assertEqual(str(reply), NODENAME_ERROR, code)
            else:
                self.assertEqual(reply, 'OK', code)

    def test_help_goes_to_standard_error_with_status_one(self):
        self.owned()
        for flag in ('--help', '-h'):
            done = subprocess.run([str(BINARY), flag], capture_output=True, timeout=10)
            self.assertEqual(done.returncode, 1)
            self.assertEqual(done.stdout, b'')
            self.assertTrue(done.stderr.startswith(b'Usage: '))

    def started(self, arguments, cwd=None, configuration=None):
        directory = Path(tempfile.mkdtemp(prefix='eski-parity-'))
        self.addCleanup(subprocess.run, ['rm', '-rf', str(directory)])
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        log = (directory / 'server.log').open('ab')
        self.addCleanup(log.close)
        command = [str(BINARY)] + ([configuration] if configuration else []) + [
            '--bind', '127.0.0.1', '--port', str(port), '--dir', str(directory), '--save', '']
        process = subprocess.Popen(command + list(arguments), cwd=cwd or directory, stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        def stop():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)
        self.addCleanup(stop)
        def ready():
            if process.poll() is not None:
                raise AssertionError('server exited: ' + (directory / 'server.log').read_text(errors='replace'))
            try:
                client = Client(port, timeout=0.3)
            except OSError:
                return False
            try:
                return client.call('PING') == 'PONG'
            except (OSError, EOFError):
                return False
            finally:
                client.close()
        wait_for(ready, timeout=15, label='parity server readiness')
        client = Client(port)
        self.addCleanup(client.close)
        return client, directory

    def test_empty_cluster_config_file_starts(self):
        self.owned()
        workspace = Path(tempfile.mkdtemp(prefix='eski-parity-conf-'))
        self.addCleanup(subprocess.run, ['rm', '-rf', str(workspace)])
        (workspace / 'empty.conf').write_text('cluster-config-file ""\n')
        client, unused = self.started((), configuration=str(workspace / 'empty.conf'))
        self.assertEqual(client.call('CONFIG', 'GET', 'cluster-config-file'), [b'cluster-config-file', b''])

    def test_config_file_folds_leading_parent_components(self):
        self.owned()
        workspace = Path(tempfile.mkdtemp(prefix='eski-parity-path-')).resolve()
        self.addCleanup(subprocess.run, ['rm', '-rf', str(workspace)])
        (workspace / 'conf').mkdir()
        (workspace / 'sub' / 'deeper').mkdir(parents=True)
        (workspace / 'conf' / 'e.conf').write_text('save ""\n')
        deeper = workspace / 'sub' / 'deeper'
        for given, expected in (('../../conf/e.conf', workspace / 'conf/e.conf'),
                                ('./../.././conf/e.conf', str(deeper) + '/./../.././conf/e.conf'),
                                ('../deeper/../../conf/e.conf', str(workspace / 'sub') + '/deeper/../../conf/e.conf')):
            client, unused = self.started((), cwd=deeper, configuration=given)
            self.assertEqual(info(client)['config_file'], str(expected))

    def test_invalid_server_cpulist_is_silent(self):
        self.owned()
        for text in ('0:2', '3-1', 'x'):
            client, directory = self.started(('--server-cpulist', text))
            self.assertEqual(client.call('PING'), 'PONG')
            self.assertNotIn('server-cpulist', (directory / 'server.log').read_text(errors='replace'))

    def test_query_buffer_limit_log_line_carries_client_info(self):
        self.owned()
        client, directory = self.started(('--client-query-buffer-limit', '1mb'))
        victim = Client(client.socket.getpeername()[1])
        self.addCleanup(victim.close)
        victim.call('CLIENT', 'SETNAME', 'big')
        try:
            victim.socket.sendall(b'*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3000000\r\n' + b'a' * 2000000)
        except OSError:
            pass
        wait_for(lambda: info(client, 'stats')['client_query_buffer_limit_disconnections'] == '1', timeout=5,
                 label='query buffer limit disconnect')
        lines = [line for line in (directory / 'server.log').read_text(errors='replace').splitlines()
                 if 'Closing client that reached max query buffer length' in line]
        self.assertEqual(len(lines), 1)
        tail = lines[0].split('Closing client that reached max query buffer length: ', 1)[1]
        head, qbuf = tail.split(' (qbuf initial bytes: ', 1)
        names = [part.split('=', 1)[0] for part in head.split(' ')]
        self.assertEqual(names, ['id', 'addr', 'laddr', 'fd', 'name', 'age', 'idle', 'flags', 'db', 'sub', 'psub', 'ssub',
                                 'multi', 'watch', 'qbuf', 'qbuf-free', 'argv-mem', 'multi-mem', 'rbs', 'rbp', 'obl', 'oll',
                                 'omem', 'tot-mem', 'events', 'cmd', 'user', 'redir', 'resp', 'lib-name', 'lib-ver'])
        self.assertIn(' name=big ', ' ' + head + ' ')
        self.assertEqual(qbuf, '"' + 'a' * 64 + '")')

    def test_link_local_peer_has_no_scope_suffix(self):
        self.owned()
        found = link_local_address()
        if found is None:
            self.skipTest('no link-local IPv6 address on this machine')
        address, scope = found
        directory = Path(tempfile.mkdtemp(prefix='eski-parity-v6-'))
        self.addCleanup(subprocess.run, ['rm', '-rf', str(directory)])
        with socket.socket(socket.AF_INET6) as probe:
            probe.bind(('::1', 0))
            port = probe.getsockname()[1]
        process = subprocess.Popen([str(BINARY), '--bind', '::', '--port', str(port), '--dir', str(directory),
                                    '--save', '', '--protected-mode', 'no'], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        def stop():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)
        self.addCleanup(stop)
        def connect():
            sock = socket.socket(socket.AF_INET6)
            try:
                sock.connect((address, port, 0, scope))
            except OSError:
                sock.close()
                return None
            return sock
        sock = None
        end = time.monotonic() + 10
        while sock is None and time.monotonic() < end:
            sock = connect()
            if sock is None:
                time.sleep(0.05)
        if sock is None:
            self.skipTest('link-local listener not reachable')
        self.addCleanup(sock.close)
        sock.sendall(b'*2\r\n$6\r\nCLIENT\r\n$4\r\nINFO\r\n')
        data = b''
        while not data.endswith(b'\n\r\n'):
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        fields = fields_of(data.split(b'\r\n', 1)[1])
        self.assertTrue(fields['addr'].startswith('[' + address + ']:'), fields['addr'])
        self.assertEqual(fields['laddr'], '[' + address + ']:' + str(port))


def main():
    global BINARY, REFERENCE_PORT, KEYSPACE_THREADS
    parser = argparse.ArgumentParser(description='Server, connection and key space replies that follow the reference.')
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--reference-port', type=int, help='explicitly isolated localhost reference fixture')
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--case', default='*')
    parser.add_argument('--timeout', type=int, default=300)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    REFERENCE_PORT = args.reference_port
    KEYSPACE_THREADS = args.keyspace_threads
    if args.timeout <= 0 or (REFERENCE_PORT is None and not BINARY.is_file()):
        parser.error('existing binary and positive timeout required')
    names = [name for name in unittest.defaultTestLoader.getTestCaseNames(ServerParity)
             if fnmatch.fnmatchcase(name, args.case)]
    if not names:
        parser.error('no tests selected')
    def expired(unused_signal, unused_frame):
        raise SystemExit(124)
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(args.timeout)
    try:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(ServerParity(name) for name in names))
        return 0 if result.wasSuccessful() else 1
    finally:
        signal.alarm(0)


if __name__ == '__main__':
    raise SystemExit(main())
