import argparse
from pathlib import Path
import signal
import struct
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Server, info

BINARY = ROOT / 'bin/eski'
WORKERS = 2
DEADLINE = 4102444800043


class WorkerMetadata(unittest.TestCase):
    def setUp(self):
        self.server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(WORKERS)))
        self.addCleanup(self.server.close)
        self.server.start()

    def client(self, resp=2):
        client = self.server.client(timeout=2)
        client.call('HELLO', resp)
        return client

    def minimum(self, payload):
        self.assertEqual(payload[0], 25)
        return struct.unpack('<Q', payload[1:9])[0]

    def stale_hash(self, client, key):
        client.call('HSET', key, 'a', '1', 'b', '2')
        client.call('HPEXPIREAT', key, DEADLINE, 'FIELDS', 1, 'a')
        client.call('HPERSIST', key, 'FIELDS', 1, 'a')
        payload = client.call('DUMP', key)
        self.assertEqual(self.minimum(payload), DEADLINE)
        return payload

    def test_registered_minimum_survives_reads_copy_move_rename_and_fence(self):
        for resp in (2, 3):
            client = self.client(resp)
            key = 'metadata-' + str(resp)
            before = int(info(client, 'server')['keyspace_jobs_submitted'])
            payload = self.stale_hash(client, key)
            self.assertEqual(client.call('DUMP', key), payload)
            self.assertEqual(client.call('HMGET', key, 'a', 'b'), [b'1', b'2'])
            client.call('COPY', key, key + '-copy')
            self.assertEqual(client.call('DUMP', key + '-copy'), payload)
            client.call('MOVE', key + '-copy', 1)
            client.call('SELECT', 1)
            self.assertEqual(client.call('DUMP', key + '-copy'), payload)
            client.call('SELECT', 0)
            client.call('RENAME', key, key + '-renamed')
            client.call('INFO', 'server')
            self.assertEqual(client.call('DUMP', key + '-renamed'), payload)
            if WORKERS:
                self.assertGreater(int(info(client, 'server')['keyspace_jobs_submitted']), before)

    def test_pipeline_keeps_registered_hint_before_and_after_coordinator_fence(self):
        for resp in (2, 3):
            client = self.client(resp)
            key = 'pipeline-metadata-' + str(resp)
            client.send_many([('HSET', key, 'a', 1, 'b', 2),
                              ('HPEXPIREAT', key, DEADLINE, 'FIELDS', 1, 'a'),
                              ('HPERSIST', key, 'FIELDS', 1, 'a'), ('DUMP', key),
                              ('COPY', key, key + '-copy'), ('DUMP', key + '-copy'),
                              ('INFO', 'server'), ('DUMP', key)])
            self.assertEqual(client.reply(), 2)
            self.assertEqual(client.reply(), [1])
            self.assertEqual(client.reply(), [1])
            original = client.reply()
            self.assertEqual(self.minimum(original), DEADLINE)
            self.assertEqual(client.reply(), 1)
            self.assertEqual(client.reply(), original)
            self.assertIn(b'redis_version:', client.reply())
            self.assertEqual(client.reply(), original)

    def test_restore_recomputes_hint_and_reused_string_clears_hash_metadata(self):
        for resp in (2, 3):
            client = self.client(resp)
            key = 'restore-metadata-' + str(resp)
            payload = self.stale_hash(client, key)
            client.call('RESTORE', key + '-restored', 0, payload)
            self.assertEqual(self.minimum(client.call('DUMP', key + '-restored')), 0)
            client.call('DEL', key)
            client.call('SET', key, 'plain')
            client.call('DEL', key)
            client.call('HSET', key, 'a', 1)
            self.assertEqual(client.call('DUMP', key)[0], 16)
            client.call('HPEXPIREAT', key, DEADLINE + 99, 'FIELDS', 1, 'a')
            client.call('HPERSIST', key, 'FIELDS', 1, 'a')
            self.assertEqual(self.minimum(client.call('DUMP', key)), DEADLINE + 99)

    def test_rename_overwrite_notifications_and_noop_rejections_match_reference(self):
        for resp in (2, 3):
            client = self.client(resp)
            client.call('CONFIG', 'SET', 'notify-keyspace-events', 'KEgn')
            for operation in ('overwrite', 'nx-reject', 'same-key', 'nx-create'):
                source = 'rename-' + str(resp) + '-' + operation
                destination = source + '-destination'
                client.call('SET', source, 1)
                if operation != 'nx-create':
                    client.call('SET', destination, 2)
                subscriber = self.client(resp)
                subscriber.send('PSUBSCRIBE', '*')
                self.assertEqual(subscriber.read()[0], b'psubscribe')
                if operation == 'nx-reject':
                    self.assertEqual(client.call('RENAMENX', source, destination), 0)
                elif operation == 'same-key':
                    self.assertEqual(client.call('RENAME', source, source), 'OK')
                elif operation == 'nx-create':
                    self.assertEqual(client.call('RENAMENX', source, destination), 1)
                else:
                    self.assertEqual(client.call('RENAME', source, destination), 'OK')
                client.call('PUBLISH', '__metadata_barrier__', 'done')
                events = []
                while True:
                    frame = subscriber.read()
                    if frame[2] == b'__metadata_barrier__':
                        break
                    events.append((frame[2].decode(), frame[3].decode()))
                expected = []
                if operation in ('overwrite', 'nx-create'):
                    expected = [('__keyspace@0__:' + destination, 'new'),
                                ('__keyevent@0__:new', destination),
                                ('__keyspace@0__:' + source, 'rename_from'),
                                ('__keyevent@0__:rename_from', source),
                                ('__keyspace@0__:' + destination, 'rename_to'),
                                ('__keyevent@0__:rename_to', destination)]
                self.assertEqual(events, expected)
                subscriber.close()


def main():
    global BINARY, WORKERS
    parser = argparse.ArgumentParser(description='Original private-object metadata and exact notification regressions.')
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--keyspace-threads', type=int, choices=(0, 2), default=2)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    WORKERS = args.keyspace_threads
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(124))
    signal.alarm(90)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(WorkerMetadata))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
