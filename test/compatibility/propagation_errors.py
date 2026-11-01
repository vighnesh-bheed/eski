import argparse
import os
from pathlib import Path
import shlex
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
from support import Client, ServerError, encode

BINARY = ROOT / 'bin/eski'
WORKERS = 0


class ReplayFixture:
    def __init__(self, payload, mode, use_exit=False, base=None):
        self.temporary = tempfile.TemporaryDirectory(prefix='eski-propagation-policy-')
        self.directory = Path(self.temporary.name)
        aof = self.directory / 'appendonlydir'
        aof.mkdir()
        base_name = 'replay.aof.1.base.rdb' if base is not None else 'replay.aof.1.base.aof'
        (aof / base_name).write_bytes(base if base is not None else b'')
        (aof / 'replay.aof.1.incr.aof').write_bytes(payload)
        (aof / 'replay.aof.manifest').write_text('file ' + base_name + ' seq 1 type b\nfile replay.aof.1.incr.aof seq 1 type i\n')
        wrapper = self.directory / 'server-wrapper'
        wrapper.write_text('#!/bin/sh\nulimit -c 0\nexec ' + shlex.quote(str(BINARY)) + ' "$@"\n')
        wrapper.chmod(0o700)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            self.port = probe.getsockname()[1]
        self.log = (self.directory / 'server.log').open('w')
        self.clients = []
        self.process = subprocess.Popen([str(wrapper), '--bind', '127.0.0.1', '--port', str(self.port),
                                         '--dir', str(self.directory), '--save', '', '--appendonly', 'yes',
                                         '--appendfilename', 'replay.aof', '--appendfsync', 'always',
                                         '--auto-aof-rewrite-percentage', '0', '--aof-load-truncated', 'no',
                                         '--compute-threads', '0', '--keyspace-threads', str(WORKERS),
                                         '--crash-memcheck-enabled', 'no', '--use-exit-on-panic', 'yes' if use_exit else 'no',
                                         '--propagation-error-behavior', mode], stdout=self.log,
                                        stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)

    def logs(self):
        return (self.directory / 'server.log').read_text(errors='replace')

    def ready(self):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline and self.process.poll() is None:
            try:
                client = Client(self.port, timeout=.2)
                self.clients.append(client)
                if client.call('PING') == 'PONG':
                    return client
                client.close()
            except (OSError, EOFError, ServerError):
                pass
            time.sleep(.01)
        return None

    def close(self):
        try:
            for client in self.clients:
                client.close()
            if self.process.poll() is None:
                os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
                raise AssertionError('owned AOF fixture required forced cleanup\n' + self.logs())
        finally:
            self.log.close()
            self.temporary.cleanup()


def bad_execution(transaction):
    commands = [('SET', 'wrong-type', 'value')]
    if transaction:
        commands.append(('MULTI',))
    commands.extend([('LPUSH', 'wrong-type', 'x'), ('SET', 'after-error', 'tail')])
    if transaction:
        commands.append(('EXEC',))
    commands.append(('SET', 'after-transaction', 'complete'))
    return b''.join(encode(command) for command in commands)


class PropagationErrors(unittest.TestCase):
    def fixture(self, *arguments, **options):
        fixture = ReplayFixture(*arguments, **options)
        self.addCleanup(fixture.close)
        return fixture

    def test_ignore_and_replica_only_panic_continue_after_execution_error(self):
        for mode in ('ignore', 'panic-on-replicas'):
            for transaction in (False, True):
                fixture = self.fixture(bad_execution(transaction), mode)
                client = fixture.ready()
                self.assertIsNotNone(client, fixture.logs())
                self.assertEqual(client.call('MGET', 'wrong-type', 'after-error', 'after-transaction'),
                                 [b'value', b'tail', b'complete'])
                self.assertIn('WRONGTYPE', fixture.logs())
                self.assertNotIn('propagation-error-behavior is panic', fixture.logs())

    def test_panic_execution_policy_honors_exit_or_native_abort(self):
        for use_exit in (False, True):
            for transaction in (False, True):
                fixture = self.fixture(bad_execution(transaction), 'panic', use_exit=use_exit)
                self.assertIsNone(fixture.ready(), 'panic AOF policy accepted traffic\n' + fixture.logs())
                self.assertEqual(fixture.process.wait(timeout=3), 1 if use_exit else -signal.SIGABRT, fixture.logs())
                self.assertIn('propagation-error-behavior is panic', fixture.logs())
                self.assertIn('WRONGTYPE', fixture.logs())

    def test_parse_unknown_command_and_arity_failures_remain_startup_errors(self):
        for mode in ('ignore', 'panic', 'panic-on-replicas'):
            for payload in (b'!not-an-aof-frame\r\n', encode(('unknown-aof-command',)), encode(('SET',))):
                fixture = self.fixture(payload, mode)
                self.assertIsNone(fixture.ready(), fixture.logs())
                self.assertEqual(fixture.process.wait(timeout=3), 1, fixture.logs())
                self.assertNotIn('propagation-error-behavior is panic', fixture.logs())

    def test_rdb_preamble_checksum_failure_is_not_an_execution_policy(self):
        corrupt = b'REDIS0012\xff' + b'\x01' + b'\x00' * 7
        for mode in ('ignore', 'panic', 'panic-on-replicas'):
            fixture = self.fixture(b'', mode, base=corrupt)
            self.assertIsNone(fixture.ready(), fixture.logs())
            self.assertEqual(fixture.process.wait(timeout=3), 1, fixture.logs())
            self.assertIn('checksum', fixture.logs().lower())
            self.assertNotIn('propagation-error-behavior is panic', fixture.logs())


def main():
    global BINARY, WORKERS
    parser = argparse.ArgumentParser(description='Original AOF execution-policy, transaction and parse/CRC boundary regressions.')
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--keyspace-threads', type=int, choices=(0, 2), default=0)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    WORKERS = args.keyspace_threads
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(124))
    signal.alarm(90)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(PropagationErrors))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
