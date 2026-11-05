import argparse
import os
from pathlib import Path
import signal
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Server, ServerError, encode, info, wait_for

BINARY = ROOT / 'bin/eski'


class AofManifest(unittest.TestCase):
    def server(self, enabled=True):
        server = Server(BINARY, workers=0, arguments=('--appendonly', 'yes' if enabled else 'no',
                        '--appendfsync', 'always', '--auto-aof-rewrite-percentage', '0'))
        self.addCleanup(server.close)
        return server

    def fatal_manifest(self, text, expected, files=()):
        server = self.server()
        directory = server.directory / 'appendonlydir'
        directory.mkdir()
        (directory / 'appendonly.aof.manifest').write_text(text)
        for name, data in files:
            (directory / name).write_bytes(data)
        try:
            try:
                server.start()
            except (AssertionError, ServerError):
                pass
            else:
                self.fail('invalid manifest unexpectedly started a serving process')
            self.assertEqual(server.process.wait(timeout=5), 1)
            log = (server.directory / 'server.log').read_text(errors='replace')
            for phrase in expected:
                self.assertIn(phrase, log)
        finally:
            if server.process is not None and server.process.poll() == 1:
                server.stop(expected_exit=1)
            server.close()

    def test_blank_and_whitespace_manifest_lines_are_rejected(self):
        for blank in ('\n', ' \t\n'):
            with self.subTest(blank=blank):
                self.fatal_manifest('file appendonly.aof.1.incr.aof seq 1 type i\n' + blank,
                                    ['Invalid AOF manifest file format'],
                                    [('appendonly.aof.1.incr.aof', encode(('SET', 'k', 'v')))])

    def test_missing_referenced_files_report_actual_path_and_errno(self):
        self.fatal_manifest('file missing.incr.aof seq 1 type i\n',
                            ['missing.incr.aof', 'No such file or directory'])

    def test_backoff_is_reported_only_when_an_eligible_automatic_retry_is_blocked(self):
        server = self.server()
        server.start()
        c = server.client()
        c.call('SET', 'slow', 'value')
        c.call('CONFIG', 'SET', 'rdb-key-save-delay', 500000)
        children = Path('/proc/%s/task/%s/children' % (server.process.pid, server.process.pid))
        for _ in range(3):
            c.call('BGREWRITEAOF')
            child = wait_for(lambda: children.read_text().split(), label='manual rewrite child')
            self.assertEqual(len(child), 1)
            os.kill(int(child[0]), signal.SIGKILL)
            wait_for(lambda: info(c, 'persistence')['aof_rewrite_in_progress'] == '0', label='failed rewrite reaped')
        log = server.directory / 'server.log'
        self.assertNotIn('triggered the limit', log.read_text(errors='replace'))
        before = int(info(c, 'stats')['total_forks'])
        c.call('CONFIG', 'SET', 'auto-aof-rewrite-percentage', 1)
        c.call('CONFIG', 'SET', 'auto-aof-rewrite-min-size', 1)
        c.call('SET', 'growth', 'x' * 4096)
        wait_for(lambda: 'triggered the limit' in log.read_text(errors='replace'), label='actual retry refusal')
        self.assertEqual(log.read_text(errors='replace').count('triggered the limit'), 1)
        self.assertEqual(int(info(c, 'stats')['total_forks']), before)
        self.assertEqual(info(c, 'persistence')['aof_rewrite_in_progress'], '0')
        c.call('CONFIG', 'SET', 'auto-aof-rewrite-percentage', 0)
        c.call('CONFIG', 'SET', 'rdb-key-save-delay', 0)
        c.call('BGREWRITEAOF')
        wait_for(lambda: info(c, 'persistence')['aof_rewrite_in_progress'] == '0', label='explicit retry bypasses automatic backoff')
        self.assertEqual(info(c, 'persistence')['aof_last_bgrewrite_status'], 'ok')

    def test_debug_reload_resets_changes_only_after_loading_persisted_generation(self):
        server = self.server()
        server.start()
        c = server.client()
        c.call('SET', 'generation', 'persisted')
        self.assertGreater(int(info(c, 'persistence')['rdb_changes_since_last_save']), 0)
        c.call('DEBUG', 'LOADAOF')
        self.assertEqual(info(c, 'persistence')['rdb_changes_since_last_save'], '0')
        c.call('CONFIG', 'SET', 'appendonly', 'no')
        c.call('SET', 'generation', 'unsaved')
        self.assertGreater(int(info(c, 'persistence')['rdb_changes_since_last_save']), 0)
        c.call('DEBUG', 'LOADAOF')
        self.assertEqual(c.call('GET', 'generation'), b'persisted')
        self.assertEqual(info(c, 'persistence')['rdb_changes_since_last_save'], '0')

    def test_interrupted_old_file_migration_resumes_without_overwriting_destination(self):
        for destination_present in (False, True):
            with self.subTest(destination_present=destination_present):
                server = self.server()
                directory = server.directory / 'appendonlydir'
                directory.mkdir()
                (directory / 'appendonly.aof.manifest').write_text('file appendonly.aof seq 1 type b\n')
                source = server.directory / 'appendonly.aof'
                source.write_bytes(encode(('SET', 'origin', 'source')))
                destination = directory / 'appendonly.aof'
                if destination_present:
                    destination.write_bytes(encode(('SET', 'origin', 'destination')))
                try:
                    server.start()
                    c = server.client()
                    self.assertEqual(c.call('GET', 'origin'), b'destination' if destination_present else b'source')
                    self.assertEqual(source.exists(), destination_present)
                    self.assertTrue(destination.is_file())
                finally:
                    server.close()

    def test_history_retirement_is_latest_first_and_gc_preserves_active_files(self):
        server = self.server()
        server.start()
        c = server.client()
        c.call('CONFIG', 'SET', 'aof-disable-auto-gc', 'yes')
        c.call('SET', 'durable', 'value')
        directory = server.directory / c.call('CONFIG', 'GET', 'appenddirname')[1].decode()
        path = directory / 'appendonly.aof.manifest'
        def rows():
            return [line.split() for line in path.read_text().splitlines()]
        retired = []
        for _ in range(2):
            old = rows()
            base = next(row[1] for row in old if row[5] == 'b')
            incr = [row[1] for row in old if row[5] == 'i']
            c.call('BGREWRITEAOF')
            wait_for(lambda: info(c, 'persistence')['aof_rewrite_in_progress'] == '0', label='history rewrite')
            retired = list(reversed(incr)) + [base] + retired
            self.assertEqual([row[1] for row in rows() if row[5] == 'h'], retired)
        active = [row[1] for row in rows() if row[5] in ('b', 'i')]
        c.call('CONFIG', 'SET', 'aof-disable-auto-gc', 'no')
        self.assertEqual([row[1] for row in rows() if row[5] == 'h'], [])
        self.assertEqual([row[1] for row in rows() if row[5] in ('b', 'i')], active)
        wait_for(lambda: all(not (directory / name).exists() for name in retired), label='history deletion')
        self.assertTrue(all((directory / name).is_file() for name in active))
        c.call('DEBUG', 'LOADAOF')
        self.assertEqual(c.call('GET', 'durable'), b'value')

    def test_failed_initial_rewrite_retires_temp_journal_without_duplicate_replay(self):
        server = self.server(False)
        server.start()
        c = server.client()
        c.call('SET', 'counter', 0)
        c.call('MSET', *[item for i in range(50) for item in ('fill-' + str(i), 'value')])
        c.call('CONFIG', 'SET', 'rdb-key-save-delay', 50000)
        c.call('CONFIG', 'SET', 'appendonly', 'yes')
        children = Path('/proc/%s/task/%s/children' % (server.process.pid, server.process.pid))
        child = wait_for(lambda: children.read_text().split(), label='owned rewrite child')
        self.assertEqual(len(child), 1)
        os.kill(int(child[0]), signal.SIGKILL)
        self.assertEqual(c.pipeline([('INCR', 'counter')] * 10), list(range(1, 11)))
        c.call('CONFIG', 'SET', 'rdb-key-save-delay', 0)
        log = server.directory / 'server.log'
        wait_for(lambda: 'Removing the temp incr aof file' in log.read_text(errors='replace'), label='abandoned journal removal')
        wait_for(lambda: (row := info(c, 'persistence'))['aof_rewrite_in_progress'] == '0' and row['aof_last_bgrewrite_status'] == 'ok',
                 timeout=15, label='successful rewrite retry')
        self.assertEqual(c.call('GET', 'counter'), b'10')
        c.call('DEBUG', 'LOADAOF')
        self.assertEqual(c.call('GET', 'counter'), b'10')


def main():
    global BINARY
    parser = argparse.ArgumentParser(description='Owned multipart AOF manifest, retirement and retry correctness regressions.')
    parser.add_argument('--server', type=Path, default=BINARY)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    if not BINARY.is_file():
        parser.error('existing server binary required')
    signal.alarm(90)
    return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(AofManifest)).wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
