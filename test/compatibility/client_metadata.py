import argparse
from pathlib import Path
import signal
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Server, info, wait_for

BINARY = ROOT / 'bin/eski'


def footprint(client):
    row = client.call('CLIENT', 'INFO').decode()
    return int(dict(part.split('=', 1) for part in row.split() if '=' in part)['tot-mem'])


def add_metadata(client, kind, name):
    if kind == 'watch':
        return client.call('WATCH', name)
    if kind == 'subscription':
        client.send('SUBSCRIBE', name)
        return client.read()
    return client.call('CLIENT', 'TRACKING', 'ON', 'BCAST', 'PREFIX', name)


class ClientMetadata(unittest.TestCase):
    def server(self):
        server = Server(BINARY, workers=0, arguments=('--keyspace-threads', '2'))
        self.addCleanup(server.close)
        server.start()
        return server

    def shared_transfer(self, kind):
        server = self.server()
        a, b = server.client(), server.client()
        a.call('HELLO', 3)
        b.call('HELLO', 3)
        key = 'shared:' + 'x' * 8192 + ':'
        if kind == 'subscription':
            warm = 'warmup:' + 'w' * 8192 + ':'
            for client in (a, b):
                add_metadata(client, kind, warm)
                client.send('UNSUBSCRIBE', warm)
                client.read()
        before_a, before_b = footprint(a), footprint(b)
        add_metadata(a, kind, key)
        add_metadata(b, kind, key)
        first, second = footprint(a), footprint(b)
        self.assertGreater(first - before_a, len(key))
        self.assertLess(second - before_b, len(key))
        if kind == 'watch':
            a.call('UNWATCH')
        elif kind == 'subscription':
            a.send('UNSUBSCRIBE', key)
            a.read()
        else:
            a.call('CLIENT', 'TRACKING', 'OFF')
        self.assertLess(footprint(a), first - len(key))
        self.assertGreater(footprint(b), second + len(key))
        self.assertIsInstance(b.call('CLIENT', 'ID'), int)

    def test_watched_key_ownership_is_counted_once_and_transferred(self):
        self.shared_transfer('watch')

    def test_subscription_ownership_is_counted_once_and_transferred(self):
        self.shared_transfer('subscription')

    def test_tracking_prefix_ownership_is_counted_once_and_transferred(self):
        self.shared_transfer('prefix')

    def test_metadata_pressure_evicts_and_recovers_without_disabling_workers(self):
        for kind in ('watch', 'subscription', 'prefix'):
            with self.subTest(kind=kind):
                server = self.server()
                admin, actor = server.client(), server.client()
                admin.call('CLIENT', 'NO-EVICT', 'ON')
                actor.call('HELLO', 3)
                baseline = int(info(admin, 'memory')['mem_clients_normal'])
                evicted = int(info(admin, 'stats')['evicted_clients'])
                admin.call('CONFIG', 'SET', 'maxmemory-clients', baseline + (128 << 10))
                closed = False
                for i in range(256):
                    try:
                        add_metadata(actor, kind, str(i).zfill(6) + ':' + 'p' * 2048 + ':')
                    except (EOFError, OSError):
                        closed = True
                        break
                self.assertTrue(closed, 'bounded metadata growth must evict the unprotected owner')
                wait_for(lambda: int(info(admin, 'stats')['evicted_clients']) == evicted + 1, label='metadata eviction')
                self.assertLess(int(info(admin, 'memory')['mem_clients_normal']), baseline + (32 << 10))
                before = int(info(admin)['keyspace_jobs_submitted'])
                self.assertEqual(admin.call('SET', 'recovered', kind), 'OK')
                self.assertEqual(admin.call('GET', 'recovered'), kind.encode())
                self.assertEqual(int(info(admin)['keyspace_jobs_submitted']), before + 2)
                server.stop()

    def test_no_evict_protects_owned_metadata_then_cleanup_recovers(self):
        for kind in ('watch', 'subscription', 'prefix'):
            with self.subTest(kind=kind):
                server = self.server()
                admin, actor = server.client(), server.client()
                admin.call('CLIENT', 'NO-EVICT', 'ON')
                actor.call('CLIENT', 'NO-EVICT', 'ON')
                actor.call('HELLO', 3)
                baseline = int(info(admin, 'memory')['mem_clients_normal'])
                evicted = int(info(admin, 'stats')['evicted_clients'])
                admin.call('CONFIG', 'SET', 'maxmemory-clients', baseline + (64 << 10))
                for i in range(64):
                    add_metadata(actor, kind, str(i).zfill(6) + ':' + 'n' * 2048 + ':')
                self.assertIsInstance(actor.call('CLIENT', 'ID'), int)
                self.assertEqual(int(info(admin, 'stats')['evicted_clients']), evicted)
                self.assertGreater(int(info(admin, 'memory')['mem_clients_normal']), baseline + (64 << 10))
                actor.close()
                wait_for(lambda: int(info(admin, 'memory')['mem_clients_normal']) < baseline + (32 << 10), label='protected metadata cleanup')
                self.assertEqual(admin.call('PING'), 'PONG')
                server.stop()


def main():
    global BINARY
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', type=Path, default=BINARY)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    if not BINARY.is_file():
        parser.error('existing server binary required')
    signal.alarm(120)
    return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ClientMetadata)).wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
