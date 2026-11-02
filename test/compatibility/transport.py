import argparse
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Client, ServerError, wait_for

BINARY = ROOT / 'bin/eski'


def free_port(family=socket.AF_INET):
    with socket.socket(family) as listener:
        listener.bind(('::1' if family == socket.AF_INET6 else '127.0.0.1', 0))
        return listener.getsockname()[1]


class NetworkClient(Client):
    def __init__(self, connection):
        self.socket = connection
        self.buffer = bytearray()
        self.pushes = []


class TransportServer:
    def __init__(self, arguments=(), ipv6=False, unix=False):
        self.temporary = tempfile.TemporaryDirectory(prefix='eski-transport-')
        self.directory = Path(self.temporary.name)
        self.ipv6 = ipv6
        self.unix = unix
        self.port = 0 if unix else free_port(socket.AF_INET6 if ipv6 else socket.AF_INET)
        self.socket_path = self.directory / 'server.sock'
        self.arguments = list(arguments)
        self.process = None
        self.clients = []
        self.log = None

    def start(self):
        arguments = [str(BINARY), '--bind', '::1' if self.ipv6 else '127.0.0.1',
                     '--port', str(self.port), '--dir', str(self.directory), '--save', '',
                     '--appendonly', 'no', '--compute-threads', '0', '--keyspace-threads', '0',
                     '--enable-debug-command', 'local', '--enable-protected-configs', 'local']
        if self.unix:
            arguments += ['--unixsocket', str(self.socket_path), '--unixsocketperm', '700']
        self.log = (self.directory / 'server.log').open('ab')
        self.process = subprocess.Popen(arguments + self.arguments, stdout=self.log, stderr=subprocess.STDOUT,
                                        stdin=subprocess.DEVNULL, start_new_session=True)
        def ready():
            if self.process.poll() is not None:
                raise AssertionError('transport server exited: ' + (self.directory / 'server.log').read_text())
            try:
                connection = self.connection()
                try:
                    return connection.call('PING') == 'PONG'
                finally:
                    connection.close()
            except (OSError, EOFError):
                return False
        wait_for(ready, timeout=15, label='transport server readiness')
        return self

    def connection(self):
        if self.unix:
            connection = socket.socket(socket.AF_UNIX)
            connection.settimeout(10)
            connection.connect(str(self.socket_path))
        else:
            connection = socket.create_connection(('::1' if self.ipv6 else '127.0.0.1', self.port), timeout=10)
        client = NetworkClient(connection)
        self.clients.append(client)
        return client

    def close(self):
        try:
            for client in self.clients:
                client.close()
            if self.process is not None:
                if self.process.poll() is None:
                    self.process.send_signal(signal.SIGTERM)
                try:
                    code = self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
                    raise AssertionError('transport server required SIGKILL')
                if code != 0:
                    raise AssertionError('transport server exit: %s\n%s' % (code, (self.directory / 'server.log').read_text()))
        finally:
            if self.log is not None:
                self.log.close()
            self.temporary.cleanup()


class Transport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.certificates = tempfile.TemporaryDirectory(prefix='eski-transport-pki-')
        cls.pki = Path(cls.certificates.name)
        def run(*arguments):
            subprocess.run(['openssl', *arguments], cwd=cls.pki, check=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, timeout=20)
        run('req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
            '-keyout', 'ca.key', '-out', 'ca.crt', '-subj', '/CN=Eski transport test CA', '-days', '1',
            '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
            '-addext', 'subjectKeyIdentifier=hash')
        for name, purpose in [('server', 'serverAuth'), ('client', 'clientAuth')]:
            run('req', '-new', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
                '-keyout', name + '.key', '-out', name + '.csr', '-subj', '/CN=localhost')
            (cls.pki / (name + '.ext')).write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nextendedKeyUsage=' + purpose + '\nsubjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1\n')
            run('x509', '-req', '-in', name + '.csr', '-CA', 'ca.crt', '-CAkey', 'ca.key', '-CAcreateserial',
                '-out', name + '.crt', '-days', '1', '-extfile', name + '.ext')

    @classmethod
    def tearDownClass(cls):
        cls.certificates.cleanup()

    def server(self, arguments=(), **options):
        server = TransportServer(arguments, **options)
        self.addCleanup(server.close)
        return server.start()

    def tls_server(self, auth='no', extra=()):
        port = free_port()
        arguments = ['--tls-port', str(port), '--tls-cert-file', str(self.pki / 'server.crt'),
                     '--tls-key-file', str(self.pki / 'server.key'), '--tls-ca-cert-file', str(self.pki / 'ca.crt'),
                     '--tls-auth-clients', auth]
        server = self.server(arguments + list(extra))
        server.tls_port = port
        return server

    def tls_client(self, server, certificate=False, version=None):
        context = ssl.create_default_context(cafile=str(self.pki / 'ca.crt'))
        if certificate:
            context.load_cert_chain(str(self.pki / 'client.crt'), str(self.pki / 'client.key'))
        if version is not None:
            context.minimum_version = version
            context.maximum_version = version
        raw = socket.create_connection(('::1' if server.ipv6 else '127.0.0.1', server.tls_port), timeout=10)
        try:
            encrypted = context.wrap_socket(raw, server_hostname='localhost')
        except BaseException:
            raw.close()
            raise
        client = NetworkClient(encrypted)
        server.clients.append(client)
        return client

    def test_ipv6_addresses_and_local_permissions(self):
        if not socket.has_ipv6:
            self.skipTest('host lacks IPv6')
        server = self.server(ipv6=True)
        client = server.connection()
        self.assertEqual(client.call('PING'), 'PONG')
        client.call('CLIENT', 'SETNAME', 'ipv6-client')
        row = next(row for row in client.call('CLIENT', 'LIST').decode().splitlines() if 'name=ipv6-client ' in row)
        self.assertIn('addr=[::1]:', row)
        self.assertIn('laddr=[::1]:', row)
        self.assertEqual(client.call('DEBUG', 'SLEEP', 0), 'OK')

    def test_dual_ipv4_ipv6_listeners_share_data(self):
        if not socket.has_ipv6:
            self.skipTest('host lacks IPv6')
        server = self.server(('--bind', '127.0.0.1', '::1'))
        ipv4 = server.connection()
        ipv6 = NetworkClient(socket.create_connection(('::1', server.port), timeout=5))
        server.clients.append(ipv6)
        self.assertEqual(ipv4.call('SET', 'dual-family', 'shared'), 'OK')
        self.assertEqual(ipv6.call('GET', 'dual-family'), b'shared')

    def test_migrate_between_ipv6_listeners(self):
        if not socket.has_ipv6:
            self.skipTest('host lacks IPv6')
        source = self.server(ipv6=True)
        target = self.server(ipv6=True)
        sender = source.connection()
        receiver = target.connection()
        sender.call('SET', 'ipv6-migrate', 'retained')
        self.assertEqual(sender.call('MIGRATE', '::1', target.port, 'ipv6-migrate', 0, 1000), 'OK')
        self.assertIsNone(sender.call('GET', 'ipv6-migrate'))
        self.assertEqual(receiver.call('GET', 'ipv6-migrate'), b'retained')

    def test_unix_socket_permissions_and_local_commands(self):
        server = self.server(unix=True)
        client = server.connection()
        self.assertEqual(server.socket_path.stat().st_mode & 0o777, 0o700)
        self.assertEqual(client.call('SET', 'unix-key', 'unix-value'), 'OK')
        self.assertEqual(client.call('GET', 'unix-key'), b'unix-value')
        self.assertEqual(client.call('DEBUG', 'SLEEP', 0), 'OK')
        self.assertIn(str(server.socket_path).encode() + b':0', client.call('CLIENT', 'LIST'))
        client.send('SHUTDOWN', 'NOSAVE')
        self.assertEqual(server.process.wait(timeout=5), 0)
        self.assertFalse(server.socket_path.exists())

    def test_tls_and_plain_share_keyspace_and_large_payloads(self):
        server = self.tls_server()
        encrypted = self.tls_client(server)
        plain = server.connection()
        payload = b'encrypted\x00' * 50000
        self.assertEqual(encrypted.call('SET', 'tls-key', payload), 'OK')
        self.assertEqual(plain.call('GET', 'tls-key'), payload)
        self.assertEqual(encrypted.call('GET', 'tls-key'), payload)
        encrypted.call('HELLO', 3)
        self.assertEqual(encrypted.call('PING'), 'PONG')

    def test_tls_over_ipv6(self):
        if not socket.has_ipv6:
            self.skipTest('host lacks IPv6')
        port = free_port(socket.AF_INET6)
        server = self.server(['--tls-port', str(port), '--tls-cert-file', str(self.pki / 'server.crt'),
                              '--tls-key-file', str(self.pki / 'server.key'), '--tls-auth-clients', 'no'], ipv6=True)
        server.tls_port = port
        encrypted = self.tls_client(server)
        self.assertEqual(encrypted.call('PING'), 'PONG')
        self.assertEqual(encrypted.call('SET', 'ipv6-encrypted', 'value'), 'OK')
        self.assertEqual(server.connection().call('GET', 'ipv6-encrypted'), b'value')

    def test_tls_required_client_certificate(self):
        server = self.tls_server(auth='yes')
        with self.assertRaises((ssl.SSLError, EOFError, OSError)):
            rejected = self.tls_client(server)
            rejected.call('PING')
        accepted = self.tls_client(server, certificate=True)
        self.assertEqual(accepted.call('PING'), 'PONG')

    def test_tls_optional_client_certificate(self):
        server = self.tls_server(auth='optional')
        for certificate in (False, True):
            self.assertEqual(self.tls_client(server, certificate).call('PING'), 'PONG')

    def test_tls_protocol_update_and_invalid_certificate_rollback(self):
        server = self.tls_server()
        plain = server.connection()
        existing = self.tls_client(server)
        plain.send('CONFIG', 'SET', 'tls-cert-file', str(self.pki / 'missing.crt'))
        self.assertIsInstance(plain.reply(), ServerError)
        self.assertEqual(existing.call('PING'), 'PONG')
        self.assertEqual(self.tls_client(server).call('PING'), 'PONG')
        self.assertEqual(plain.call('CONFIG', 'SET', 'tls-protocols', 'TLSv1.2'), 'OK')
        with self.assertRaises(ssl.SSLError):
            self.tls_client(server, version=ssl.TLSVersion.TLSv1_3)
        self.assertEqual(self.tls_client(server, version=ssl.TLSVersion.TLSv1_2).call('PING'), 'PONG')

    def test_tls_protocol_names_ignore_case(self):
        server = self.tls_server()
        plain = server.connection()
        for value in ('tlsv1.2', 'TLSV1.3', 'tlsv1.2 tlsv1.3', 'tLsV1.1', 'tlsv1'):
            self.assertEqual(plain.call('CONFIG', 'SET', 'tls-protocols', value), 'OK')
        self.assertEqual(plain.call('CONFIG', 'GET', 'tls-protocols'), [b'tls-protocols', b'tlsv1'])
        for value in ('bogus', 'TLSv1.2 bogus', 'TLSv1.2  TLSv1.3', '   '):
            plain.send('CONFIG', 'SET', 'tls-protocols', value)
            self.assertEqual(str(plain.reply()), "ERR CONFIG SET failed (possibly related to argument 'tls-protocols') - "
                                                 "Unable to update TLS configuration. Check server logs.")
        self.assertEqual(plain.call('CONFIG', 'SET', 'tls-protocols', 'tlsv1.2'), 'OK')
        with self.assertRaises(ssl.SSLError):
            self.tls_client(server, version=ssl.TLSVersion.TLSv1_3)
        self.assertEqual(self.tls_client(server, version=ssl.TLSVersion.TLSv1_2).call('PING'), 'PONG')
        text = (server.directory / 'server.log').read_text(errors='replace')
        self.assertEqual(text.count("Invalid tls-protocols specified. Use a combination of 'TLSv1', 'TLSv1.1', 'TLSv1.2' and 'TLSv1.3'."), 4)
        self.assertNotIn('Invalid TLS protocol', text)

    def test_tls_incomplete_handshake_does_not_block_clients(self):
        server = self.tls_server()
        incomplete = socket.create_connection(('127.0.0.1', server.tls_port), timeout=5)
        self.addCleanup(incomplete.close)
        incomplete.sendall(b'\x16')
        self.assertEqual(self.tls_client(server).call('PING'), 'PONG')
        self.assertEqual(server.connection().call('PING'), 'PONG')

    def test_tls_backpressure_preserves_replies_and_pipeline_mutations(self):
        server = self.tls_server()
        slow = self.tls_client(server)
        control = server.connection()
        payload = b'p' * 400000
        control.call('SET', 'large-reply', payload)
        slow.send_many([('GET', 'large-reply')] * 20 + [('SET', 'pipeline-after-output', 'kept'), ('PING',)])
        self.assertEqual(control.call('SET', 'independent', 'alive'), 'OK')
        for unused in range(20):
            self.assertEqual(slow.reply(), payload)
        self.assertEqual(slow.reply(), 'OK')
        self.assertEqual(slow.reply(), 'PONG')
        self.assertEqual(control.call('GET', 'pipeline-after-output'), b'kept')

    def test_tls_buffered_input_after_large_requests_is_served(self):
        server = self.tls_server()
        clients = [self.tls_client(server) for unused in range(72)]
        sizes = [1100000 + 977 * index for index in range(len(clients))]
        for index, client in enumerate(clients):
            client.send_many([('SET', 'buffered-%d' % index, b'b' * sizes[index])] +
                             [('INCR', 'buffered-count-%d' % index)] * 50 + [('STRLEN', 'buffered-%d' % index), ('PING',)])
        for index, client in enumerate(clients):
            self.assertEqual(client.reply(), 'OK')
            self.assertEqual([client.reply() for unused in range(50)], list(range(1, 51)))
            self.assertEqual(client.reply(), sizes[index])
            self.assertEqual(client.reply(), 'PONG')

    def test_tls_encrypted_key_and_atomic_password_change(self):
        encrypted = self.pki / 'encrypted-server.key'
        subprocess.run(['openssl', 'pkey', '-in', str(self.pki / 'server.key'), '-aes-256-cbc',
                        '-passout', 'pass:transport-secret', '-out', str(encrypted)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
        server = self.tls_server()
        control = server.connection()
        self.assertEqual(control.call('CONFIG', 'SET', 'tls-key-file', str(encrypted),
                                      'tls-key-file-pass', 'transport-secret'), 'OK')
        self.assertEqual(self.tls_client(server).call('PING'), 'PONG')
        control.send('CONFIG', 'SET', 'tls-key-file-pass', 'wrong-password')
        self.assertIsInstance(control.reply(), ServerError)
        self.assertEqual(self.tls_client(server).call('PING'), 'PONG')

    def test_tls_cipher_preference_uses_requested_order(self):
        server = self.tls_server(extra=('--tls-protocols', 'TLSv1.2', '--tls-ciphers',
                                      'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384'))
        control = server.connection()
        def selected():
            context = ssl.create_default_context(cafile=str(self.pki / 'ca.crt'))
            context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_2
            context.set_ciphers('ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256')
            with socket.create_connection(('127.0.0.1', server.tls_port), timeout=5) as raw:
                with context.wrap_socket(raw, server_hostname='localhost') as encrypted:
                    client = NetworkClient(encrypted)
                    self.assertEqual(client.call('PING'), 'PONG')
                    return encrypted.cipher()[0]
        self.assertEqual(selected(), 'ECDHE-ECDSA-AES256-GCM-SHA384')
        self.assertEqual(control.call('CONFIG', 'SET', 'tls-prefer-server-ciphers', 'yes'), 'OK')
        self.assertEqual(selected(), 'ECDHE-ECDSA-AES128-GCM-SHA256')

    def test_runtime_tls_port_move_preserves_existing_connections(self):
        server = self.tls_server()
        existing = self.tls_client(server)
        control = server.connection()
        new_port = free_port()
        self.assertEqual(control.call('CONFIG', 'SET', 'tls-port', new_port), 'OK')
        server.tls_port = new_port
        self.assertEqual(self.tls_client(server).call('PING'), 'PONG')
        self.assertEqual(existing.call('PING'), 'PONG')
        self.assertEqual(control.call('CONFIG', 'SET', 'port', 0), 'OK')
        self.assertEqual(self.tls_client(server).call('PING'), 'PONG')
        fields = dict(line.split(':', 1) for line in existing.call('INFO', 'server').decode().splitlines()
                      if ':' in line and not line.startswith('#'))
        self.assertEqual(int(fields['tcp_port']), new_port)
        self.assertEqual(control.call('CONFIG', 'SET', 'tls-port', 0), 'OK')
        self.assertEqual(existing.call('PING'), 'PONG')
        with self.assertRaises(OSError):
            socket.create_connection(('127.0.0.1', new_port), timeout=1)

    def test_disabled_tls_stateful_cache_preserves_ticket_resumption(self):
        server = self.tls_server(extra=('--tls-protocols', 'TLSv1.2', '--tls-session-caching', 'no'))
        context = ssl.create_default_context(cafile=str(self.pki / 'ca.crt'))
        context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_2
        session = None
        for attempt in range(2):
            with socket.create_connection(('127.0.0.1', server.tls_port), timeout=5) as raw:
                with context.wrap_socket(raw, server_hostname='localhost', session=session) as encrypted:
                    self.assertEqual(encrypted.session_reused, attempt != 0)
                    client = NetworkClient(encrypted)
                    self.assertEqual(client.call('PING'), 'PONG')
                    session = encrypted.session

    def test_tls_busy_script_can_be_killed(self):
        server = self.tls_server()
        script = self.tls_client(server)
        control = self.tls_client(server)
        server.connection().call('CONFIG', 'SET', 'busy-reply-threshold', 1)
        script.send('EVAL', 'while true do end', 0)
        def busy():
            control.send('PING')
            value = control.reply()
            return isinstance(value, ServerError) and str(value).startswith('BUSY')
        wait_for(busy, timeout=5, label='TLS BUSY response')
        self.assertEqual(control.call('SCRIPT', 'KILL'), 'OK')
        self.assertIsInstance(script.reply(), ServerError)
        self.assertEqual(control.call('PING'), 'PONG')


def main():
    global BINARY
    parser = argparse.ArgumentParser(description='Original owned IPv6, Unix and OpenSSL TLS transport regressions.')
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--timeout', type=int, default=120)
    parser.add_argument('--case', default='*')
    args = parser.parse_args()
    BINARY = args.server.resolve()
    import fnmatch
    names = [name for name in unittest.defaultTestLoader.getTestCaseNames(Transport) if fnmatch.fnmatchcase(name, args.case)]
    if not names or not BINARY.is_file() or args.timeout <= 0:
        parser.error('existing binary, selected cases and positive timeout required')
    def expired(unused_signal, unused_frame):
        raise SystemExit(124)
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(args.timeout)
    try:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(Transport(name) for name in names))
        return 0 if result.wasSuccessful() else 1
    finally:
        signal.alarm(0)


if __name__ == '__main__':
    raise SystemExit(main())
