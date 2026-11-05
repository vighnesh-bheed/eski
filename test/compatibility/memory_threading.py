import argparse
from pathlib import Path
import signal
import socket
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Server, ServerError, info, wait_for

BINARY = ROOT / 'bin/eski'


class MemoryThreading(unittest.TestCase):
    def server(self, *arguments):
        server = Server(BINARY, workers=0, arguments=('--keyspace-threads', '2',) + arguments, queue_ping=True)
        self.addCleanup(server.close)
        server.start()
        return server

    def submitted(self, client):
        return int(info(client, 'server')['keyspace_jobs_submitted'])

    def test_eviction_invalidations_deliver_without_draining_healthy_database(self):
        server = self.server('--maxmemory-policy', 'allkeys-lru', '--maxmemory-eviction-tenacity', '100')
        control = server.client()
        targets = [server.client() for _ in range(10)]
        for target in targets:
            target.call('HELLO', 3)
            target.call('CLIENT', 'TRACKING', 'ON')
        keys = [str(index) + 'x' * 1000 for index in range(300)]
        for key in keys:
            control.call('SET', key, 'x')
            for target in targets:
                self.assertEqual(target.call('GET', key), b'x')
        time.sleep(1.1)
        used = int(info(control, 'memory')['used_memory'])
        control.call('CONFIG', 'SET', 'maxmemory', used - 40000)
        evicted = int(info(control, 'stats')['evicted_keys'])
        self.assertGreater(evicted, 0)
        self.assertGreater(control.call('DBSIZE'), len(keys) // 2)
        control.call('CONFIG', 'SET', 'maxmemory', 0)
        remaining = control.call('MGET', *keys)
        missing = {key.encode() for key, value in zip(keys, remaining) if value is None}
        for target in targets:
            self.assertEqual(target.call('PING'), 'PONG')
            received = {key for push in target.pushes for key in push[1]}
            self.assertEqual(received, missing)

    def test_slow_tracking_target_keeps_complete_pending_frames_with_resizing_disabled(self):
        server = self.server('--maxmemory-policy', 'allkeys-lru', '--maxmemory-eviction-tenacity', '100')
        control = server.client()
        target = server.client()
        target.call('HELLO', 3)
        target.call('CLIENT', 'SETNAME', 'slow-invalidation-target')
        target.call('CLIENT', 'TRACKING', 'ON')
        control.call('DEBUG', 'REPLYBUFFER', 'RESIZING', 0)
        keys = [str(index) + 'x' * 65536 for index in range(64)]
        for key in keys:
            control.call('SET', key, 'x')
            self.assertEqual(target.call('GET', key), b'x')
        control.call('CONFIG', 'SET', 'maxmemory', 1)
        self.assertEqual(control.call('DBSIZE'), 0)
        control.call('CONFIG', 'SET', 'maxmemory', 0)
        self.assertEqual(control.call('PING'), 'PONG')
        rows = [dict(field.split('=', 1) for field in row.split())
                for row in control.call('CLIENT', 'LIST').decode().splitlines()]
        pending = next(row for row in rows if row.get('name') == 'slow-invalidation-target')
        self.assertGreater(int(pending['obl']) + int(pending['omem']), 0)
        self.assertEqual(target.call('PING'), 'PONG')
        received = [key for push in target.pushes for key in push[1]]
        self.assertEqual(len(received), len(keys))
        self.assertEqual(set(received), {key.encode() for key in keys})

    def test_configured_limits_and_lfu_keep_unpressured_workers_active(self):
        server = self.server('--maxmemory', str(64 << 20), '--maxmemory-clients', str(8 << 20),
                             '--maxmemory-policy', 'allkeys-lfu', '--lfu-log-factor', '0',
                             '--lfu-decay-time', '0')
        client = server.client()
        before = self.submitted(client)
        self.assertEqual(client.call('SET', 'frequency', 'value'), 'OK')
        self.assertEqual(client.call('OBJECT', 'FREQ', 'frequency'), 5)
        for expected in (6, 7):
            self.assertEqual(client.call('GET', 'frequency'), b'value')
            self.assertEqual(client.call('OBJECT', 'FREQ', 'frequency'), expected)
        client.call('CLIENT', 'NO-TOUCH', 'ON')
        self.assertEqual(client.call('GET', 'frequency'), b'value')
        self.assertEqual(client.call('OBJECT', 'FREQ', 'frequency'), 7)
        self.assertEqual(client.call('TOUCH', 'frequency'), 1)
        self.assertEqual(client.call('OBJECT', 'FREQ', 'frequency'), 8)
        client.call('CLIENT', 'NO-TOUCH', 'OFF')
        self.assertEqual(client.call('HSET', 'frequency-hash', 'field', 'value'), 1)
        self.assertEqual(client.call('OBJECT', 'FREQ', 'frequency-hash'), 5)
        self.assertEqual(client.call('HGET', 'frequency-hash', 'field'), b'value')
        self.assertEqual(client.call('OBJECT', 'FREQ', 'frequency-hash'), 6)
        self.assertGreaterEqual(self.submitted(client) - before, 7)

    def test_noeviction_pressure_rejects_growth_and_recovers_worker_admission(self):
        server = self.server('--maxmemory', str(64 << 20), '--maxmemory-policy', 'noeviction')
        client = server.client()
        client.call('SET', 'retained', 'value')
        client.call('CONFIG', 'SET', 'maxmemory', 1)
        with self.assertRaisesRegex(ServerError, 'OOM'):
            client.call('SET', 'denied', 'value')
        self.assertEqual(client.call('GET', 'retained'), b'value')
        self.assertEqual(client.call('EXISTS', 'denied'), 0)
        client.call('CONFIG', 'SET', 'maxmemory', 64 << 20)
        before = self.submitted(client)
        self.assertEqual(client.call('SET', 'recovered', 'value'), 'OK')
        self.assertEqual(client.call('GET', 'recovered'), b'value')
        self.assertEqual(self.submitted(client) - before, 2)

    def test_actual_eviction_pressure_preserves_liveness_and_resumes_workers(self):
        server = self.server('--maxmemory', str(64 << 20), '--maxmemory-policy', 'allkeys-lfu')
        client = server.client()
        for index in range(12):
            client.call('SET', 'eviction-' + str(index), bytes((index,)) * 65536)
        used = int(info(client, 'memory')['used_memory'])
        client.call('CONFIG', 'SET', 'maxmemory', max(1, used - 300000))
        client.call('GET', 'eviction-0')
        wait_for(lambda: int(info(client, 'stats')['evicted_keys']) > 0,
                 timeout=3, label='actual key eviction')
        self.assertEqual(client.call('PING'), 'PONG')
        client.call('CONFIG', 'SET', 'maxmemory', 64 << 20)
        before = self.submitted(client)
        self.assertEqual(client.call('SET', 'after-eviction', 'value'), 'OK')
        self.assertEqual(client.call('GET', 'after-eviction'), b'value')
        self.assertEqual(self.submitted(client) - before, 2)

    def test_memcached_metadata_fallback_and_delayed_flush_do_not_disable_unrelated_workers(self):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        server = self.server('--memcached-port', str(port))
        client = server.client()
        mc = socket.create_connection(('127.0.0.1', port), timeout=5)
        self.addCleanup(mc.close)
        stream = mc.makefile('rb')
        self.addCleanup(stream.close)
        mc.sendall(b'set mc-record 71 0 3\r\nold\r\n')
        self.assertEqual(stream.readline(), b'STORED\r\n')
        mc.sendall(b'gets mc-record\r\n')
        header = stream.readline().split()
        self.assertEqual(header[:4], [b'VALUE', b'mc-record', b'71', b'3'])
        self.assertEqual(stream.readline(), b'old\r\n')
        self.assertEqual(stream.readline(), b'END\r\n')
        cas = header[4]
        before = self.submitted(client)
        self.assertEqual(client.call('GET', 'mc-record'), b'old')
        self.assertEqual(self.submitted(client), before)
        mc.sendall(b'cas mc-record 71 0 3 ' + cas + b'\r\nnew\r\n')
        self.assertEqual(stream.readline(), b'STORED\r\n')
        self.assertEqual(client.call('GET', 'mc-record'), b'new')
        before = self.submitted(client)
        self.assertEqual(client.call('SET', 'plain-record', 'value'), 'OK')
        self.assertEqual(client.call('GET', 'plain-record'), b'value')
        self.assertEqual(self.submitted(client) - before, 2)
        mc.sendall(b'flush_all 1\r\n')
        self.assertEqual(stream.readline(), b'OK\r\n')
        before = self.submitted(client)
        self.assertEqual(client.call('SET', 'after-flush-schedule', 'survives'), 'OK')
        self.assertEqual(client.call('GET', 'after-flush-schedule'), b'survives')
        self.assertEqual(self.submitted(client) - before, 2)
        time.sleep(1.1)
        self.assertIsNone(client.call('GET', 'mc-record'))
        self.assertIsNone(client.call('GET', 'plain-record'))
        self.assertEqual(client.call('GET', 'after-flush-schedule'), b'survives')


def main():
    global BINARY
    parser = argparse.ArgumentParser(description='Bounded original memory/frontend threading integration regressions.')
    parser.add_argument('--server', type=Path, default=BINARY)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    if not BINARY.is_file():
        parser.error('existing server binary required')
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(124))
    signal.alarm(90)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(MemoryThreading))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
