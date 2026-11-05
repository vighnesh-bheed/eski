import argparse
import fnmatch
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Client, info, wait_for

BINARY = ROOT / 'bin/eski'


class RuntimeOperations(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='eski-operations-')
        self.directory = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.processes = []
        self.addCleanup(self.stop_all)

    def stop_all(self):
        for process in self.processes:
            if process.poll() is None:
                process.send_signal(signal.SIGCONT)
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

    def launch(self, arguments=(), environment=None, ready=True):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        directory = self.directory / ('server-%d' % len(self.processes))
        directory.mkdir()
        log = (directory / 'server.log').open('wb')
        self.addCleanup(log.close)
        env = dict(os.environ)
        for name in ('NOTIFY_SOCKET', 'UPSTART_JOB', 'UPSTART_INSTANCE'):
            env.pop(name, None)
        env.update(environment or {})
        command = [str(BINARY), '--bind', '127.0.0.1', '--port', str(port), '--dir', str(directory),
                   '--save', '', '--appendonly', 'no', '--enable-debug-command', 'yes',
                   '--compute-threads', '2', '--keyspace-threads', '2'] + list(arguments)
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=subprocess.STDOUT, env=env, start_new_session=True)
        self.processes.append(process)
        if ready:
            self.ready(process, port)
        return process, port, directory

    def ready(self, process, port):
        def connected():
            self.assertIsNone(process.poll(), 'owned server exited during startup')
            try:
                client = Client(port, .2)
                try:
                    return client.call('PING') == 'PONG'
                finally:
                    client.close()
            except (OSError, EOFError):
                return False
        wait_for(connected, timeout=20, label='runtime operations readiness')

    def client(self, port):
        client = Client(port)
        self.addCleanup(client.close)
        return client

    def supervisor(self, abstract=False):
        channel = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(channel.close)
        channel.settimeout(15)
        channel.setsockopt(socket.SOL_SOCKET, socket.SO_PASSCRED, 1)
        name = str(self.directory / 'notify.sock')
        if abstract:
            name = '@eski-operations-%d-%s' % (os.getpid(), self.directory.name)
        channel.bind('\0' + name[1:] if abstract else name)
        return channel, name

    def notification(self, channel, process):
        payload, controls, _, _ = channel.recvmsg(4096, socket.CMSG_SPACE(12))
        credentials = [struct.unpack('3i', data) for level, kind, data in controls
                       if level == socket.SOL_SOCKET and kind == socket.SCM_CREDENTIALS]
        self.assertEqual(credentials, [(process.pid, os.getuid(), os.getgid())])
        return payload

    def supervision(self, abstract=False, mode='systemd'):
        channel, name = self.supervisor(abstract)
        process, port, _ = self.launch(['--supervised', mode, '--daemonize', 'yes'], {'NOTIFY_SOCKET': name})
        self.assertIn(b'READY=1', self.notification(channel, process))
        self.assertEqual(info(self.client(port))['process_supervised'], 'systemd')
        self.assertEqual(self.client(port).call('SET', 'supervised', 'alive'), 'OK')
        process.terminate()
        self.assertIn(b'STOPPING=1', self.notification(channel, process))
        self.assertEqual(process.wait(timeout=15), 0)

    def test_systemd_filesystem_ready_stop_and_no_daemon_fork(self):
        self.supervision()

    def test_systemd_abstract_socket_ready_and_stop(self):
        self.supervision(abstract=True)

    def test_systemd_abstract_socket_uses_all_108_address_bytes(self):
        channel = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(channel.close)
        channel.settimeout(15)
        name = ('@eski-operations-%d-' % os.getpid()).ljust(108, 'x')
        channel.bind('\0' + name[1:])
        process, port, _ = self.launch(['--supervised', 'systemd'], {'NOTIFY_SOCKET': name})
        self.assertIn(b'READY=1', channel.recv(4096))
        self.assertEqual(info(self.client(port))['process_supervised'], 'systemd')
        process.terminate()
        self.assertIn(b'STOPPING=1', channel.recv(4096))
        self.assertEqual(process.wait(timeout=15), 0)

    def test_auto_detects_owned_systemd_socket(self):
        self.supervision(mode='auto')

    def test_supervised_no_ignores_notification_environment(self):
        channel, name = self.supervisor()
        _, port, _ = self.launch(['--supervised', 'no'], {'NOTIFY_SOCKET': name})
        self.assertEqual(info(self.client(port))['process_supervised'], 'no')
        channel.settimeout(.05)
        with self.assertRaises(socket.timeout):
            channel.recv(4096)

    def test_missing_supervisor_environment_is_reported_unsupervised(self):
        _, port, directory = self.launch(['--supervised', 'systemd'])
        self.assertEqual(info(self.client(port))['process_supervised'], 'no')
        self.assertIn('without a valid supervisor environment', (directory / 'server.log').read_text())

    def test_upstart_stops_owned_process_then_continues_ready(self):
        process, port, _ = self.launch(['--supervised', 'upstart', '--daemonize', 'yes'],
                                       {'UPSTART_JOB': 'eski-owned-fixture'}, ready=False)
        wait_for(lambda: '\nState:\tT' in Path('/proc/%d/status' % process.pid).read_text(),
                 timeout=15, label='owned upstart readiness stop')
        process.send_signal(signal.SIGCONT)
        self.ready(process, port)
        self.assertEqual(info(self.client(port))['process_supervised'], 'upstart')
        process.terminate()
        self.assertEqual(process.wait(timeout=15), 0)

    def test_disable_thp_changes_only_owned_process_policy(self):
        process, _, _ = self.launch(['--disable-thp', 'yes'])
        status = Path('/proc/%d/status' % process.pid).read_text()
        self.assertEqual(next(line.split(':', 1)[1].strip() for line in status.splitlines() if line.startswith('THP_enabled:')), '0')
        process2, _, _ = self.launch(['--disable-thp', 'no'])
        parent_status = Path('/proc/self/status').read_text()
        parent_value = next(line for line in parent_status.splitlines() if line.startswith('THP_enabled:'))
        self.assertIn(parent_value + '\n', Path('/proc/%d/status' % process2.pid).read_text())

    def test_logo_is_eski_and_obeys_configuration(self):
        _, _, enabled = self.launch(['--always-show-logo', 'yes'])
        _, _, disabled = self.launch(['--always-show-logo', 'no'])
        self.assertIn('EEEEE  SSSS  K  K  III', (enabled / 'server.log').read_text())
        self.assertNotIn('EEEEE  SSSS  K  K  III', (disabled / 'server.log').read_text())

    def recording_shim(self):
        shim = self.directory / 'record-operations.so'
        subprocess.run(['clang', '-shared', '-fPIC', '-O1', '-pthread', '-Wall', '-Wextra', '-Werror',
                        str(Path(__file__).with_name('runtime_operations_shim.c')), '-o', str(shim)], check=True)
        return shim

    def test_background_snapshot_honors_native_atfork_callbacks(self):
        shim = self.recording_shim()
        record = self.directory / 'atfork.log'
        _, port, directory = self.launch(environment={'LD_PRELOAD': str(shim), 'ESKI_TEST_ATFORK_RECORD': str(record)})
        client = self.client(port)
        self.assertEqual(client.call('SET', 'fork:snapshot', 'persisted-in-child'), 'OK')
        self.assertIn('Background saving started', client.call('BGSAVE'))
        wait_for(lambda: info(client, 'persistence')['rdb_bgsave_in_progress'] == '0' and (directory / 'dump.rdb').is_file(),
                 timeout=20, label='owned background snapshot')
        self.assertEqual(info(client, 'persistence')['rdb_last_bgsave_status'], 'ok')
        self.assertEqual(client.call('SET', 'fork:snapshot', 'later-mutation'), 'OK')
        self.assertEqual(client.call('DEBUG', 'RELOAD', 'NOSAVE'), 'OK')
        self.assertEqual(client.call('GET', 'fork:snapshot'), b'persisted-in-child')
        self.assertEqual(sorted(record.read_text().splitlines()), ['CHILD', 'PARENT', 'PREPARE'])

    def test_syslog_ident_facility_priority_and_loglevel_on_real_logger(self):
        shim = self.recording_shim()
        record = self.directory / 'syslog.log'
        process, port, _ = self.launch(['--syslog-enabled', 'yes', '--syslog-ident', 'eski-owned-syslog',
                                 '--syslog-facility', 'local3'],
                                {'LD_PRELOAD': str(shim), 'ESKI_TEST_SYSLOG_RECORD': str(record)})
        client = self.client(port)
        self.assertEqual(client.call('DEBUG', 'LOG', 'owned-warning-100%-%s'), 'OK')
        text = record.read_text()
        self.assertIn('OPEN|9|152|eski-owned-syslog', text)
        self.assertIn('LOG|4|152|eski-owned-syslog|', text)
        self.assertIn('DEBUG LOG: owned-warning-100%-%s', text)
        self.assertEqual(client.call('CONFIG', 'SET', 'loglevel', 'nothing'), 'OK')
        before = record.read_bytes()
        self.assertEqual(client.call('DEBUG', 'LOG', 'hidden-by-loglevel'), 'OK')
        self.assertEqual(record.read_bytes(), before)
        self.assertEqual(client.call('CONFIG', 'SET', 'loglevel', 'warning'), 'OK')
        process.terminate()
        self.assertEqual(process.wait(timeout=15), 0)
        self.assertTrue(record.read_text().endswith('CLOSE\n'))
        disabled = self.directory / 'disabled-syslog.log'
        _, port2, _ = self.launch(['--syslog-enabled', 'no'],
                                 {'LD_PRELOAD': str(shim), 'ESKI_TEST_SYSLOG_RECORD': str(disabled)})
        self.assertEqual(self.client(port2).call('DEBUG', 'LOG', 'ordinary-output-only'), 'OK')
        self.assertFalse(disabled.exists())

    def test_replication_source_configuration_preserves_migrate_connection(self):
        listener = socket.socket()
        self.addCleanup(listener.close)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(15)
        target_port = listener.getsockname()[1]
        peers, errors = [], []
        def target():
            try:
                connection, address = listener.accept()
                peers.append(address[0])
                connection.settimeout(15)
                try:
                    client = Client.__new__(Client)
                    client.socket, client.buffer, client.pushes = connection, bytearray(), []
                    self.assertEqual(client.reply()[0].lower(), b'select')
                    connection.sendall(b'+OK\r\n')
                    for _ in range(3):
                        self.assertEqual(client.reply()[0].lower(), b'restore')
                        connection.sendall(b'+OK\r\n')
                    self.assertEqual(connection.recv(1), b'')
                finally:
                    connection.close()
            except BaseException as error:
                errors.append(error)
        worker = threading.Thread(target=target, daemon=True)
        worker.start()
        process, port, _ = self.launch(['--bind-source-addr', '127.0.0.2'])
        client = self.client(port)
        for index, source in enumerate(('127.0.0.2', 'not-an-ip', 'localhost')):
            self.assertEqual(client.call('CONFIG', 'SET', 'bind-source-addr', source), 'OK')
            self.assertEqual(client.call('CONFIG', 'GET', 'bind-source-addr'), [b'bind-source-addr', source.encode()])
            key = 'migration:' + str(index)
            self.assertEqual(client.call('SET', key, 'kept'), 'OK')
            self.assertEqual(client.call('MIGRATE', '127.0.0.1', target_port, key, 0, 5000), 'OK')
        process.terminate()
        self.assertEqual(process.wait(timeout=15), 0)
        worker.join(timeout=15)
        self.assertFalse(worker.is_alive())
        if errors:
            raise errors[0]
        self.assertEqual(peers, ['127.0.0.1'])


def main():
    global BINARY
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--case', action='append', default=[])
    arguments = parser.parse_args()
    BINARY = arguments.server.resolve()
    suite = unittest.TestSuite(test for test in unittest.defaultTestLoader.loadTestsFromTestCase(RuntimeOperations)
                               if not arguments.case or any(fnmatch.fnmatchcase(test._testMethodName, pattern)
                                                           for pattern in arguments.case))
    if not suite.countTestCases():
        raise SystemExit('no runtime operations cases selected')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())


if __name__ == '__main__':
    main()
