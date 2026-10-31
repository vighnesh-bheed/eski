import argparse
from pathlib import Path
import signal
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Server, info

BINARY = ROOT / 'bin/eski'
WORKERS = 2


class HfeWorkers(unittest.TestCase):
    def setUp(self):
        self.server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(WORKERS)))
        self.addCleanup(self.server.close)
        self.server.start()
        self.client = self.server.client()
        self.client.socket.settimeout(1)
        self.client.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        self.before = int(info(self.client, 'server')['keyspace_jobs_submitted'])

    def tearDown(self):
        if WORKERS:
            observer = self.server.client(timeout=1)
            self.assertGreater(int(info(observer, 'server')['keyspace_jobs_submitted']), self.before)

    def variants(self):
        for threshold in (512, 0):
            self.client.call('CONFIG', 'SET', 'hash-max-listpack-entries', threshold)
            for protocol in (2, 3):
                self.client.call('HELLO', protocol)
                yield str(threshold) + ':' + str(protocol), protocol

    def seed(self, key, only_expired=False):
        fields = ('dead1', '1', 'dead2', '2') if only_expired else ('dead1', '1', 'dead2', '2', 'keep', 'value')
        self.client.call('HSET', key, *fields)
        self.assertEqual(self.client.call('HPEXPIRE', key, 1, 'FIELDS', 2, 'dead1', 'dead2'), [1, 1])
        time.sleep(0.01)

    def test_live_collection_frames_match_filtered_elements_and_pipeline_boundary(self):
        for variant, protocol in self.variants():
            for command in ('HGETALL', 'HKEYS', 'HVALS'):
                for empty in (False, True):
                    key = variant + ':' + command + ':' + str(empty)
                    self.seed(key, empty)
                    before = int(info(self.client, 'server')['keyspace_jobs_submitted'])
                    result, pong = self.client.pipeline([(command, key), ('PING',)])
                    after = int(info(self.client, 'server')['keyspace_jobs_submitted'])
                    self.assertEqual(after - before, 1 if WORKERS else 0)
                    self.assertEqual(pong, 'PONG')
                    expected = [] if empty else [b'keep', b'value'] if command == 'HGETALL' else [b'keep'] if command == 'HKEYS' else [b'value']
                    if protocol == 3 and command == 'HGETALL':
                        expected = {} if empty else {b'keep': b'value'}
                    self.assertEqual(result, expected)

    def test_field_reads_expiry_queries_and_writes_keep_private_registry_consistent(self):
        for variant, protocol in self.variants():
            key = variant + ':writes'
            self.seed(key)
            self.assertEqual(self.client.call('HLEN', key), 3)
            self.assertEqual(self.client.call('HSCAN', key, 0, 'COUNT', 100), [b'0', [b'keep', b'value']])
            self.assertEqual(self.client.call('HPTTL', key, 'FIELDS', 3, 'dead1', 'dead2', 'keep'), [-2, -2, -1])
            self.assertEqual(self.client.call('HLEN', key), 3)
            self.assertEqual(self.client.call('HMGET', key, 'dead1', 'keep'), [None, b'value'])
            self.assertEqual(self.client.call('HSET', key, 'new', 'fresh'), 1)
            self.assertEqual(self.client.call('HDEL', key, 'dead2'), 1)
            self.assertEqual(self.client.call('HPEXPIRE', key, 60000, 'FIELDS', 1, 'new'), [1])
            self.assertEqual(self.client.call('HPERSIST', key, 'FIELDS', 1, 'new'), [1])
            result = self.client.call('HGETALL', key)
            actual = result if protocol == 3 else dict(zip(result[::2], result[1::2]))
            self.assertEqual(actual, {b'keep': b'value', b'new': b'fresh'})

    def test_random_field_cleanup_drops_expired_fields_and_preserves_reply_frame(self):
        for variant, protocol in self.variants():
            key = variant + ':random'
            self.seed(key)
            self.assertEqual(self.client.call('HRANDFIELD', key, 10), [b'keep'])
            self.assertEqual(self.client.pipeline([('HGETALL', key), ('PING',)])[1], 'PONG')

    def test_dump_and_copy_preserve_future_field_expiry_without_canonical_key_bindings(self):
        for variant, protocol in self.variants():
            key = variant + ':dump'
            self.seed(key)
            self.assertEqual(self.client.call('HPEXPIRE', key, 60000, 'FIELDS', 1, 'keep'), [1])
            payload = self.client.call('DUMP', key)
            self.client.call('RESTORE', key + ':restore', 0, payload)
            self.assertEqual(self.client.call('COPY', key, key + ':copy'), 1)
            for destination in (key + ':restore', key + ':copy'):
                ttl = self.client.call('HPTTL', destination, 'FIELDS', 1, 'keep')[0]
                self.assertGreater(ttl, 50000)
                result = self.client.call('HGETALL', destination)
                actual = result if protocol == 3 else dict(zip(result[::2], result[1::2]))
                self.assertEqual(actual, {b'keep': b'value'})


def main():
    global BINARY, WORKERS
    parser = argparse.ArgumentParser(description='Private worker hash-field expiry ownership and RESP framing regressions.')
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--keyspace-threads', type=int, choices=(0, 2), default=2)
    args = parser.parse_args()
    BINARY, WORKERS = args.server.resolve(), args.keyspace_threads
    signal.alarm(120)
    return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(HfeWorkers)).wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
