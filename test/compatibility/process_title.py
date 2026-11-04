import argparse
import fnmatch
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Client, Server, ServerError, info, wait_for

BINARY = ROOT / 'bin/eski'


def read_title(pid):
    return Path('/proc/%s/cmdline' % pid).read_bytes().split(b'\0', 1)[0].decode()


def free_port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


class ProcessTitle(unittest.TestCase):
    def start(self, arguments=()):
        server = Server(BINARY, workers=2, arguments=['--keyspace-threads', '2'] + list(arguments), queue_ping=True)
        self.addCleanup(server.close)
        server.start()
        return server, server.client()

    def test_default_initial_title_and_original_executable_survive_refreshes(self):
        server, client = self.start()
        expected = str(BINARY) + ' 127.0.0.1:' + str(server.port)
        self.assertEqual(read_title(server.process.pid), expected)
        self.assertEqual(info(client)['executable'], str(BINARY))
        for index in range(30):
            template = 'generation-%d {title} {listen-addr}' % index
            self.assertEqual(client.call('CONFIG', 'SET', 'proc-title-template', template), 'OK')
            self.assertEqual(read_title(server.process.pid), 'generation-%d %s' % (index, expected))
        self.assertEqual(info(client)['executable'], str(BINARY))
        self.assertEqual(client.call('SET', 'title:workers', 'alive'), 'OK')
        self.assertEqual(client.call('EVAL', 'return redis.call("GET",KEYS[1])', 1, 'title:workers'), b'alive')
        self.assertGreater(int(info(client)['keyspace_jobs_submitted']), 0)

    def test_disabled_configuration_preserves_real_original_command_line(self):
        server, client = self.start(['--set-proc-title', 'no'])
        before = Path('/proc/%s/cmdline' % server.process.pid).read_bytes()
        self.assertIn(b'--set-proc-title\0no\0', before)
        self.assertEqual(client.call('CONFIG', 'SET', 'proc-title-template', 'changed {listen-addr}'), 'OK')
        self.assertEqual(Path('/proc/%s/cmdline' % server.process.pid).read_bytes(), before)
        self.assertEqual(info(client)['executable'], str(BINARY))

    def test_expansion_with_config_file_unixsocket_and_real_ps_arguments(self):
        with tempfile.TemporaryDirectory(prefix='eski-title-') as directory:
            directory = Path(directory)
            port = free_port()
            config = directory / 'server.conf'
            unix = directory / 'server.sock'
            config.write_text('bind 127.0.0.1\nport %d\nsave ""\nappendonly no\ndir "%s"\nunixsocket "%s"\n' % (port, directory, unix))
            with (directory / 'server.log').open('w') as log:
                process = subprocess.Popen([str(BINARY), str(config)], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    def ready():
                        if process.poll() is not None:
                            raise AssertionError('process-title fixture exited during startup')
                        try:
                            client = Client(port, .2)
                            client.close()
                            return True
                        except OSError:
                            return False
                    wait_for(ready, timeout=15, label='process-title fixture')
                    client = Client(port)
                    try:
                        template = 'TEST {title} {listen-addr} {port} {tls-port} {unixsocket} {config-file}'
                        self.assertEqual(client.call('CONFIG', 'SET', 'proc-title-template', template), 'OK')
                        expected = 'TEST %s 127.0.0.1:%d %d 0 %s %s' % (BINARY, port, port, unix, config)
                        self.assertEqual(read_title(process.pid), expected)
                        args = subprocess.run(['ps', '-p', str(process.pid), '-o', 'args='], check=True, capture_output=True, text=True).stdout.strip()
                        self.assertEqual(args, expected)
                    finally:
                        client.close()
                finally:
                    process.terminate()
                    self.assertEqual(process.wait(timeout=10), 0)

    def unix_connection(self, path):
        connection = socket.socket(socket.AF_UNIX)
        connection.settimeout(10)
        connection.connect(str(path))
        client = Client.__new__(Client)
        client.socket, client.buffer, client.pushes = connection, bytearray(), []
        self.addCleanup(client.close)
        return client

    def test_unix_only_title_uses_socket_path(self):
        server, client = self.start()
        unix = server.directory / 'title.sock'
        server.stop()
        server.arguments += ['--unixsocket', str(unix), '--port', '0']
        with (server.directory / 'unix.log').open('ab') as log:
            server.process = subprocess.Popen([str(BINARY), '--bind', '127.0.0.1', '--port', '0', '--save', '', '--dir', str(server.directory), '--unixsocket', str(unix)], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        wait_for(unix.exists, timeout=15, label='Unix-only process-title listener')
        client = self.unix_connection(unix)
        self.assertEqual(client.call('PING'), 'PONG')
        expected = 'unixsocket:' + str(unix)
        self.assertEqual(read_title(server.process.pid), str(BINARY) + ' ' + expected)
        self.assertEqual(client.call('CONFIG', 'SET', 'proc-title-template', '{listen-addr} plain={port} tls={tls-port}'), 'OK')
        self.assertEqual(read_title(server.process.pid), expected + ' plain=0 tls=0')

    def test_tls_only_title_uses_tls_port_and_refreshes_runtime_change(self):
        server, client = self.start()
        server.stop()
        key, cert = server.directory / 'key.pem', server.directory / 'cert.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
        unix, tls_port = server.directory / 'title.sock', free_port()
        command = [str(BINARY), '--bind', '127.0.0.1', '--port', '0', '--save', '', '--dir', str(server.directory), '--unixsocket', str(unix), '--tls-port', str(tls_port), '--tls-cert-file', str(cert), '--tls-key-file', str(key), '--tls-ca-cert-file', str(cert), '--tls-auth-clients', 'no']
        with (server.directory / 'tls.log').open('ab') as log:
            server.process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        wait_for(unix.exists, timeout=15, label='TLS-only process-title listener')
        client = self.unix_connection(unix)
        self.assertEqual(client.call('PING'), 'PONG')
        self.assertEqual(read_title(server.process.pid), str(BINARY) + ' 127.0.0.1:%d' % tls_port)
        replacement = free_port()
        self.assertEqual(client.call('CONFIG', 'SET', 'tls-port', replacement), 'OK')
        self.assertEqual(read_title(server.process.pid), str(BINARY) + ' 127.0.0.1:%d' % replacement)
        self.assertEqual(client.call('CONFIG', 'SET', 'proc-title-template', '{listen-addr} plain={port} tls={tls-port}'), 'OK')
        self.assertEqual(read_title(server.process.pid), '127.0.0.1:%d plain=0 tls=%d' % (replacement, replacement))

    def test_growing_and_shortening_titles_clear_old_bytes(self):
        key = 'ESKI_PROCESS_TITLE_SPACE_PAD'
        old = os.environ.get(key)
        os.environ[key] = 'X' * 8192
        try:
            server, client = self.start()
        finally:
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old
        for template in ['L' * 1000, 'short title', '{{title}', ' {listen-addr} ']:
            self.assertEqual(client.call('CONFIG', 'SET', 'proc-title-template', template), 'OK')
            expected = template
            if template == '{{title}':
                expected = '{title}'
            elif template == ' {listen-addr} ':
                expected = '127.0.0.1:%d' % server.port
            self.assertEqual(read_title(server.process.pid), expected)
            self.assertEqual(info(client)['executable'], str(BINARY))
        raw = Path('/proc/%s/cmdline' % server.process.pid).read_bytes()
        self.assertTrue(all(byte == 0 for byte in raw[len(expected):]))
        self.assertNotIn(b'--appendonly', raw)

    def test_invalid_templates_and_later_apply_failure_preserve_previous_title(self):
        server, client = self.start()
        self.assertEqual(client.call('CONFIG', 'SET', 'proc-title-template', 'stable {listen-addr}'), 'OK')
        previous = read_title(server.process.pid)
        for template in ['{invalid-var}', '{title}', '{server-mode}', ' ', '{unterminated']:
            with self.assertRaisesRegex(ServerError, 'template format is invalid'):
                client.call('CONFIG', 'SET', 'proc-title-template', template)
            self.assertEqual(read_title(server.process.pid), previous)
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1', 0))
            occupied.listen()
            with self.assertRaisesRegex(ServerError, 'Unable to listen'):
                client.call('CONFIG', 'SET', 'proc-title-template', 'must rollback {listen-addr}', 'port', occupied.getsockname()[1])
        self.assertEqual(read_title(server.process.pid), previous)
        self.assertEqual(client.call('CONFIG', 'GET', 'port', 'proc-title-template'), [b'port', str(server.port).encode(), b'proc-title-template', b'stable {listen-addr}'])
        self.assertEqual(client.call('PING'), 'PONG')

    def test_successful_port_and_bind_changes_refresh_title(self):
        server, client = self.start()
        new_port = free_port()
        self.assertEqual(client.call('CONFIG', 'SET', 'port', new_port), 'OK')
        self.assertEqual(read_title(server.process.pid), str(BINARY) + ' 127.0.0.1:%d' % new_port)
        with_client = Client(new_port)
        self.addCleanup(with_client.close)
        self.assertEqual(with_client.call('PING'), 'PONG')
        self.assertEqual(client.call('CONFIG', 'SET', 'bind', '0.0.0.0'), 'OK')
        self.assertEqual(read_title(server.process.pid), str(BINARY) + ' 0.0.0.0:%d' % new_port)
        self.assertEqual(client.call('PING'), 'PONG')

    def test_background_fork_keeps_parent_title_and_live_helpers(self):
        server, client = self.start()
        self.assertEqual(client.call('CONFIG', 'SET', 'proc-title-template', 'parent {title} {listen-addr}'), 'OK')
        before = read_title(server.process.pid)
        self.assertEqual(client.call('SET', 'title:snapshot', 'kept'), 'OK')
        client.call('BGSAVE')
        wait_for(lambda: info(client, 'persistence').get('rdb_bgsave_in_progress') == '0', label='title background snapshot')
        self.assertEqual(read_title(server.process.pid), before)
        self.assertEqual(client.call('GET', 'title:snapshot'), b'kept')
        self.assertEqual(info(client)['executable'], str(BINARY))


def main():
    global BINARY
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--case', action='append', default=[])
    args = parser.parse_args()
    BINARY = args.server.resolve()
    suite = unittest.TestSuite()
    for test in unittest.defaultTestLoader.loadTestsFromTestCase(ProcessTitle):
        if not args.case or any(fnmatch.fnmatchcase(test._testMethodName, pattern) for pattern in args.case):
            suite.addTest(test)
    if not suite.countTestCases():
        raise SystemExit('no process-title cases selected')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())


if __name__ == '__main__':
    main()
