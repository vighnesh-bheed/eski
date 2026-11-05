import argparse
from pathlib import Path
import signal
import socket
import ssl
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Client, Server, ServerError, info, wait_for
sys.path.insert(0, str(ROOT / 'test/compatibility'))
from run import ConfiguredServer
import transport

BINARY = ROOT / 'bin/eski'


def nonloopback():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
        route.connect(('192.0.2.1', 9))
        address = route.getsockname()[0]
    if address.startswith('127.'):
        raise unittest.SkipTest('non-loopback interface unavailable')
    return address


class ServerDefaults(unittest.TestCase):
    def server(self, *arguments):
        server = Server(BINARY, workers=0, arguments=arguments)
        self.addCleanup(server.close)
        server.start()
        return server

    def test_default_save_schedule_and_explicit_empty_survive_rewrite(self):
        server = ConfiguredServer(BINARY, workers=0)
        self.addCleanup(server.close)
        (server.directory / 'server.conf').write_text('')
        server.start()
        client = server.client()
        self.assertEqual(client.call('CONFIG', 'GET', 'save'), [b'save', b'3600 1 300 100 60 10000'])
        self.assertEqual(client.call('CONFIG', 'GET', 'protected-mode'), [b'protected-mode', b'yes'])
        client.call('CONFIG', 'SET', 'save', '')
        client.call('CONFIG', 'REWRITE')
        server.stop()
        server.start()
        self.assertEqual(server.client().call('CONFIG', 'GET', 'save'), [b'save', b''])

    def test_allocator_relocation_cannot_be_enabled_without_a_supported_allocator(self):
        server = self.server()
        client = server.client()
        self.assertEqual(client.call('CONFIG', 'GET', 'activedefrag'), [b'activedefrag', b'no'])
        with self.assertRaisesRegex(ServerError, 'libc without allocator relocation support'):
            client.call('CONFIG', 'SET', 'activedefrag', 'yes')
        self.assertEqual(client.call('CONFIG', 'GET', 'activedefrag'), [b'activedefrag', b'no'])
        self.assertEqual(client.call('CONFIG', 'SET', 'activedefrag', 'no'), 'OK')
        self.assertEqual(client.call('PING'), 'PONG')

    def test_errorstats_overflow_is_bounded_real_async_cleanup_and_reset(self):
        server = self.server()
        client = server.client()
        client.call('CONFIG', 'RESETSTAT')
        for index in range(140):
            with self.assertRaises(ServerError):
                client.call('EVAL', 'return {err=ARGV[1].." fixture error"}', 0, 'FIXTURE' + str(index))
        self.assertEqual(info(client, 'errorstats'), {'errorstat_ERRORSTATS_DISABLED': 'count=1'})
        self.assertEqual(int(info(client, 'stats')['total_error_replies']), 140)
        wait_for(lambda: int(info(client, 'memory')['lazyfreed_objects']) == 128,
                 timeout=3, label='actual detached error map cleanup')
        logs = (server.directory / 'server.log').read_text()
        self.assertEqual(logs.count('Errorstats stopped adding new errors'), 1)
        self.assertEqual(logs.count('Error codes recorded before errorstats stopped'), 1)
        client.call('CONFIG', 'RESETSTAT')
        self.assertEqual(info(client, 'errorstats'), {})
        with self.assertRaises(ServerError):
            client.call('EVAL', 'return {err="AFTERRESET fixture error"}', 0)
        self.assertEqual(info(client, 'errorstats'), {'errorstat_AFTERRESET': 'count=1'})

    def test_oom_score_disabled_changes_and_background_child_class(self):
        server = self.server()
        client = server.client()
        pid = int(info(client, 'server')['process_id'])
        score = Path('/proc') / str(pid) / 'oom_score_adj'
        base = int(score.read_text())
        if base > 970:
            self.skipTest('owned process OOM adjustment has insufficient positive headroom')
        custom = base + 1
        score.write_text(str(custom))
        client.call('CONFIG', 'SET', 'oom-score-adj-values', '7 8 19')
        self.assertEqual(int(score.read_text()), custom)
        client.call('CONFIG', 'SET', 'oom-score-adj', 'yes')
        self.assertEqual(int(score.read_text()), custom + 7)
        client.call('SET', 'child-class', 'value')
        client.call('CONFIG', 'SET', 'rdb-key-save-delay', 1000000)
        client.call('BGSAVE')
        child_path = Path('/proc') / str(pid) / 'task' / str(pid) / 'children'
        children = wait_for(lambda: child_path.read_text().split(), timeout=3, label='owned RDB child')
        child_score = Path('/proc') / children[0] / 'oom_score_adj'
        wait_for(lambda: child_score.exists() and int(child_score.read_text()) == custom + 19,
                 timeout=2, label='actual configured background child OOM class')
        client.call('CONFIG', 'SET', 'oom-score-adj', 'no')
        self.assertEqual(int(score.read_text()), custom)

    def test_protected_mode_checks_default_user_and_counts_rejected_connections(self):
        remote = nonloopback()
        server = self.server('--bind', '0.0.0.0')
        client = server.client()
        before = info(client, 'stats')
        with socket.create_connection((remote, server.port), timeout=3) as connection:
            result = transport.NetworkClient(connection).read()
            self.assertIsInstance(result, ServerError)
            self.assertTrue(str(result).startswith('DENIED '))
            self.assertEqual(connection.recv(1), b'')
        after = info(client, 'stats')
        self.assertEqual(int(after['rejected_connections']) - int(before['rejected_connections']), 1)
        self.assertEqual(int(after['total_connections_received']) - int(before['total_connections_received']), 0)
        self.assertEqual(int(after['total_error_replies']) - int(before['total_error_replies']), 0)
        client.call('CONFIG', 'SET', 'bind', '*')
        with socket.create_connection((remote, server.port), timeout=3) as connection:
            self.assertTrue(str(transport.NetworkClient(connection).read()).startswith('DENIED '))
        client.call('CONFIG', 'SET', 'requirepass', 'secret')
        connection = Client.__new__(Client)
        connection.socket = socket.create_connection((remote, server.port), timeout=3)
        connection.buffer = bytearray()
        connection.pushes = []
        self.addCleanup(connection.close)
        self.assertEqual(connection.call('AUTH', 'secret'), 'OK')
        self.assertEqual(connection.call('PING'), 'PONG')
        client.call('CONFIG', 'SET', 'requirepass', '')
        client.call('CONFIG', 'SET', 'protected-mode', 'no')
        with socket.create_connection((remote, server.port), timeout=3) as accepted:
            self.assertEqual(transport.NetworkClient(accepted).call('PING'), 'PONG')

    def test_protected_tls_denial_is_encrypted_and_unix_remains_local(self):
        remote = nonloopback()
        transport.BINARY = BINARY
        transport.Transport.setUpClass()
        self.addCleanup(transport.Transport.tearDownClass)
        port = transport.free_port()
        pki = transport.Transport.pki
        server = transport.TransportServer(('--bind', '0.0.0.0', '--tls-port', str(port),
                    '--tls-cert-file', str(pki / 'server.crt'), '--tls-key-file', str(pki / 'server.key'),
                    '--tls-ca-cert-file', str(pki / 'ca.crt'), '--tls-auth-clients', 'no'))
        server.arguments += ['--unixsocket', str(server.socket_path)]
        self.addCleanup(server.close)
        server.start()
        context = ssl.create_default_context(cafile=str(pki / 'ca.crt'))
        raw = socket.create_connection((remote, port), timeout=3)
        with context.wrap_socket(raw, server_hostname='localhost') as encrypted:
            error = transport.NetworkClient(encrypted).read()
            self.assertIsInstance(error, ServerError)
            self.assertTrue(str(error).startswith('DENIED '))
        admin = server.connection()
        admin.call('CONFIG', 'SET', 'protected-mode', 'no')
        pending = socket.create_connection((remote, port), timeout=3)
        pending_address = ('addr=' + remote + ':' + str(pending.getsockname()[1]) + ' ').encode()
        wait_for(lambda: pending_address in admin.call('CLIENT', 'LIST'), timeout=2,
                 label='owned remote TLS socket accepted before handshake')
        admin.call('CONFIG', 'SET', 'protected-mode', 'yes')
        with context.wrap_socket(pending, server_hostname='localhost') as encrypted:
            self.assertTrue(str(transport.NetworkClient(encrypted).read()).startswith('DENIED '))
        unix = socket.socket(socket.AF_UNIX)
        self.addCleanup(unix.close)
        unix.settimeout(3)
        unix.connect(str(server.socket_path))
        self.assertEqual(transport.NetworkClient(unix).call('PING'), 'PONG')


def main():
    global BINARY
    parser = argparse.ArgumentParser(description='Original server default, bounded error statistics and protected transport regressions.')
    parser.add_argument('--server', type=Path, default=BINARY)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    if not BINARY.is_file():
        parser.error('existing server binary required')
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(124))
    signal.alarm(90)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ServerDefaults))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
