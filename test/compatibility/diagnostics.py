import argparse
import os
from pathlib import Path
import re
import signal
import shutil
import shlex
import subprocess
import tempfile
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Server, info, wait_for

BINARY = ROOT / 'bin/eski'
SANITIZER = 'none'


class DiagnosticServer(Server):
    def __init__(self, binary, **options):
        original = Path(binary).resolve()
        super().__init__(original, **options)
        wrapper = self.directory / 'diagnostic-server'
        wrapper.write_text('#!/bin/sh\nulimit -c 0\nexec ' + shlex.quote(str(original)) + ' "$@"\n')
        wrapper.chmod(0o700)
        self.binary = wrapper


class Diagnostics(unittest.TestCase):
    def server(self, *arguments):
        server = DiagnosticServer(BINARY, workers=2, arguments=('--keyspace-threads', '2') + arguments)
        self.addCleanup(server.close)
        server.start()
        return server

    def logs(self, server):
        return (server.directory / 'server.log').read_text(errors='replace')

    def finish(self, server, expected):
        code = server.process.wait(timeout=5)
        self.assertEqual(code, expected, self.logs(server))
        server.process = None
        return self.logs(server)

    def crash_command(self, client, *arguments):
        try:
            client.call(*arguments)
        except (EOFError, OSError):
            return
        self.fail('intentional fatal command returned a normal reply')

    def test_watchdog_is_one_shot_and_idle_waits_do_not_report(self):
        server = self.server()
        client = server.client()
        client.call('CONFIG', 'SET', 'watchdog-period', 50)
        started = time.monotonic()
        self.assertEqual(client.call('DEBUG', 'SLEEP', .2), 'OK')
        self.assertGreaterEqual(time.monotonic() - started, .15)
        log = self.logs(server)
        self.assertEqual(log.count('WATCHDOG TIMER EXPIRED'), 1, log)
        self.assertEqual(log.count('STACK TRACE DONE'), 1, log)
        self.assertRegex(log, r'debug_sleep|cmd_debug')
        self.assertGreater(len(re.findall(r'^#\d+ ', log, re.MULTILINE)), 1)
        client.call('CONFIG', 'SET', 'watchdog-period', 0)
        client.send_many([('CONFIG', 'SET', 'watchdog-period', 50), ('DEBUG', 'SLEEP', .2)])
        self.assertEqual(client.reply(), 'OK')
        self.assertEqual(client.reply(), 'OK')
        self.assertEqual(self.logs(server).count('WATCHDOG TIMER EXPIRED'), 2)
        time.sleep(.2)
        self.assertEqual(self.logs(server).count('WATCHDOG TIMER EXPIRED'), 2)
        self.assertEqual(client.call('PING'), 'PONG')

    def test_manual_alarm_is_nonfatal_with_watchdog_disabled(self):
        server = self.server()
        client = server.client()
        self.assertEqual(client.call('CONFIG', 'GET', 'watchdog-period'), [b'watchdog-period', b'0'])
        client.send('DEBUG', 'SLEEP', .2)
        time.sleep(.04)
        os.kill(server.process.pid, signal.SIGALRM)
        self.assertEqual(client.reply(), 'OK')
        self.assertEqual(client.call('PING'), 'PONG')
        log = self.logs(server)
        self.assertEqual(log.count('SIGALRM DIAGNOSTIC'), 1, log)
        self.assertNotIn('WATCHDOG TIMER EXPIRED', log)
        self.assertIn('STACK TRACE DONE', log)

    def test_assert_exit_status_crash_log_and_owned_scratch_controls(self):
        for enabled, memory in ((True, True), (True, False), (False, True)):
            server = self.server('--use-exit-on-panic', 'yes')
            client = server.client()
            client.call('CONFIG', 'SET', 'crash-log-enabled', 'yes' if enabled else 'no')
            client.call('CONFIG', 'SET', 'crash-memcheck-enabled', 'yes' if memory else 'no')
            self.crash_command(client, 'DEBUG', 'ASSERT')
            log = self.finish(server, 1)
            self.assertEqual('ASSERTION FAILED' in log, enabled, log)
            self.assertEqual('Diagnostic scratch check:' in log, enabled and memory, log)
            if enabled and memory:
                self.assertIn('16384 owned read-only bytes match expected pattern; dataset and heap not scanned', log)

    def test_native_abort_hides_owned_argument_payloads(self):
        if SANITIZER != 'none':
            self.skipTest('native fatal-handler contract is tested on the noninstrumented server')
        secret = 'DIAGNOSTIC_PRIVATE_ARGUMENT_907'
        for hidden in (False, True):
            server = self.server()
            client = server.client()
            client.call('CONFIG', 'SET', 'hide-user-data-from-log', 'yes' if hidden else 'no')
            client.send('DEBUG', 'SLEEP', '.3' + secret)
            time.sleep(.04)
            os.kill(server.process.pid, signal.SIGABRT)
            log = self.finish(server, -signal.SIGABRT)
            self.assertNotIn(secret, log)
            self.assertIn('ESKI FATAL SIGNAL', log)
            self.assertEqual('<redacted>' in log, hidden, log)

    def test_native_debug_segfault_is_a_real_fatal_signal(self):
        if SANITIZER != 'none':
            self.skipTest('instrumented builds retain their sanitizer fatal handlers')
        server = self.server()
        self.crash_command(server.client(), 'DEBUG', 'SEGFAULT')
        log = self.finish(server, -signal.SIGSEGV)
        self.assertIn('ESKI FATAL SIGNAL', log)
        self.assertIn('STACK TRACE DONE', log)
        self.assertRegex(log, r'eski_diag_segfault|diagnostics_debug')

    def test_sanitizer_fatal_handler_is_preserved(self):
        if SANITIZER == 'none':
            self.skipTest('requires an explicitly selected instrumented server')
        server = self.server()
        self.crash_command(server.client(), 'DEBUG', 'SEGFAULT')
        code = server.process.wait(timeout=5)
        self.assertNotEqual(code, 0)
        log = self.logs(server)
        self.assertIn('AddressSanitizer' if SANITIZER == 'address' else 'ThreadSanitizer', log)
        self.assertNotIn('ESKI FATAL SIGNAL', log)
        server.process = None

    def test_stripped_binary_runs_with_real_address_fallback(self):
        strip = shutil.which('strip')
        if strip is None:
            self.skipTest('native strip utility unavailable')
        with tempfile.TemporaryDirectory(prefix='eski-diagnostic-stripped-') as directory:
            copied = Path(directory) / 'eski'
            shutil.copy2(BINARY, copied)
            subprocess.run([strip, str(copied)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            server = DiagnosticServer(copied, workers=0, arguments=('--keyspace-threads', '0'))
            try:
                server.start()
                client = server.client()
                client.send('DEBUG', 'SLEEP', .1)
                time.sleep(.02)
                os.kill(server.process.pid, signal.SIGALRM)
                self.assertEqual(client.reply(), 'OK')
                self.assertEqual(client.call('PING'), 'PONG')
                self.assertIn('SIGALRM DIAGNOSTIC', self.logs(server))
            finally:
                server.close()

    def test_fork_child_alarm_uses_child_identity_and_save_completes(self):
        server = self.server()
        client = server.client()
        client.call('SET', 'child-diagnostic', 'value')
        client.call('CONFIG', 'SET', 'rdb-key-save-delay', 500000)
        client.call('BGSAVE')
        children = Path('/proc') / str(server.process.pid) / 'task' / str(server.process.pid) / 'children'
        wait_for(lambda: children.read_text().strip(), timeout=2, label='owned RDB child')
        child = int(children.read_text().split()[0])
        os.kill(child, signal.SIGALRM)
        wait_for(lambda: info(client, 'persistence')['rdb_bgsave_in_progress'] == '0', timeout=5, label='save after child diagnostic')
        self.assertEqual(info(client, 'persistence')['rdb_last_bgsave_status'], 'ok')
        self.assertIn('pid=' + str(child) + ' tid=' + str(child), self.logs(server))
        self.assertEqual(client.call('GET', 'child-diagnostic'), b'value')


def main():
    global BINARY, SANITIZER
    parser = argparse.ArgumentParser(description='Original native watchdog, crash privacy, signal and fork regressions.')
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--sanitizer', choices=('none', 'address', 'thread'), default='none')
    args = parser.parse_args()
    BINARY = args.server.resolve()
    SANITIZER = args.sanitizer
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(124))
    signal.alarm(90)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Diagnostics))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
