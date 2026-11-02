import argparse
from pathlib import Path
import signal
import struct
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
sys.path.insert(0, str(ROOT / 'test/rdb'))
from support import Client, Push, Server, ServerError, info, wait_for
from rdbcmp import crc64

BINARY = ROOT / 'bin/eski'
REFERENCE_PORT = None
WORKERS = 0


class DatatypeParity(unittest.TestCase):
    def setUp(self):
        if REFERENCE_PORT is None:
            self.server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(WORKERS)))
            self.addCleanup(self.server.close)
            self.server.start()
            self.port = self.server.port
        else:
            self.port = REFERENCE_PORT
        self.client = self.connection()
        self.client.call('FLUSHALL')
        self.client.call('CONFIG', 'SET', 'stream-node-max-entries', 100)
        self.client.call('CONFIG', 'SET', 'stream-node-max-bytes', 4096)

    def connection(self, protocol=2):
        client = Client(self.port)
        self.addCleanup(client.close)
        if protocol == 3:
            client.call('HELLO', 3)
        return client

    def dirty(self):
        return int(info(self.client, 'persistence')['rdb_changes_since_last_save'])

    def answer(self, *command):
        self.client.send(*command)
        return self.client.reply()

    def pending(self, client, wait=0.15):
        replies = []
        end = time.monotonic() + wait
        while time.monotonic() < end:
            if client.available(0.01):
                replies.append(client.read())
        return replies

    def stream_with_group(self, key='s'):
        self.client.call('DEL', key, 'n')
        for i in range(1, 6):
            self.client.call('XADD', key, '%d-1' % i, 'f', 'v')
        self.client.call('XGROUP', 'CREATE', key, 'g', '0')
        self.client.call('XGROUP', 'CREATE', key, 'idle', '$')
        self.client.call('XREADGROUP', 'GROUP', 'g', 'c', 'COUNT', 3, 'STREAMS', key, '>')

    def test_stream_group_commands_leave_watchers_and_trackers_alone(self):
        watcher = self.connection()
        tracker = self.connection(3)
        tracker.call('CLIENT', 'TRACKING', 'on')
        cases = [
            (('XSETID', 's', '100-1'), False, 1),
            (('XSETID', 's', '5-1'), False, 1),
            (('XACK', 's', 'g', '1-1'), False, 1),
            (('XACK', 's', 'g', '9-9'), False, 0),
            (('XCLAIM', 's', 'g', 'c2', 0, '2-1'), False, 2),
            (('XCLAIM', 's', 'g', 'c', 99999999, '2-1'), False, 0),
            (('XAUTOCLAIM', 's', 'g', 'c3', 0, 0), False, 4),
            (('XREADGROUP', 'GROUP', 'g', 'c4', 'STREAMS', 's', '>'), False, 2),
            (('XREADGROUP', 'GROUP', 'g', 'c', 'STREAMS', 's', '>'), False, 1),
            (('XREADGROUP', 'GROUP', 'g', 'c', 'NOACK', 'STREAMS', 's', '>'), False, 1),
            (('XREADGROUP', 'GROUP', 'g', 'c5', 'STREAMS', 's', '0'), False, 1),
            (('XREADGROUP', 'GROUP', 'idle', 'c5', 'STREAMS', 's', '>'), False, 1),
            (('XGROUP', 'CREATECONSUMER', 's', 'g', 'c9'), False, 1),
            (('XGROUP', 'SETID', 's', 'g', '0'), False, 1),
            (('XGROUP', 'CREATE', 's', 'g2', '0'), False, 1),
            (('XGROUP', 'DELCONSUMER', 's', 'g', 'c'), False, 1),
            (('XGROUP', 'DESTROY', 's', 'g'), False, 1),
            (('XGROUP', 'CREATE', 'n', 'g2', '0', 'MKSTREAM'), True, 1),
            (('XTRIM', 's', 'MAXLEN', 2), True, 3),
            (('XDEL', 's', '1-1'), True, 1),
            (('XADD', 's', '*', 'f', 'v'), True, 1),
        ]
        for command, signalled, changes in cases:
            with self.subTest(command=command):
                self.stream_with_group()
                tracker.call('XLEN', 's')
                tracker.call('XLEN', 'n')
                tracker.pushes.clear()
                watcher.call('WATCH', 's', 'n')
                before = self.dirty()
                self.client.call(*command)
                self.assertEqual(self.dirty() - before, changes)
                watcher.call('MULTI')
                watcher.call('PING')
                self.assertEqual(watcher.call('EXEC') is None, signalled)
                self.assertEqual(tracker.call('PING'), 'PONG')
                invalidated = [push for push in tracker.pushes if push and push[0] == b'invalidate']
                self.assertEqual(bool(invalidated), signalled)

    def test_xgroup_setid_does_not_wake_blocked_readers_and_destroy_does(self):
        self.client.call('XADD', 's', '1-1', 'f', 'v')
        self.client.call('XGROUP', 'CREATE', 's', 'g', '$')
        reader = self.connection()
        reader.send('XREADGROUP', 'GROUP', 'g', 'c', 'BLOCK', 0, 'STREAMS', 's', '>')
        wait_for(lambda: int(info(self.client, 'clients')['blocked_clients']) == 1, timeout=5, label='blocked reader')
        self.assertEqual(self.client.call('XGROUP', 'SETID', 's', 'g', '0'), 'OK')
        self.assertEqual(self.pending(reader), [])
        self.client.call('XADD', 's', '2-1', 'f', 'v')
        self.assertEqual(reader.reply(), [[b's', [[b'1-1', [b'f', b'v']], [b'2-1', [b'f', b'v']]]]])
        reader.send('XREADGROUP', 'GROUP', 'g', 'c', 'BLOCK', 0, 'STREAMS', 's', '>')
        wait_for(lambda: int(info(self.client, 'clients')['blocked_clients']) == 1, timeout=5, label='blocked reader again')
        self.assertEqual(self.client.call('XGROUP', 'CREATECONSUMER', 's', 'g', 'c2'), 1)
        self.assertEqual(self.client.call('XSETID', 's', '5-0'), 'OK')
        self.assertEqual(self.pending(reader), [])
        self.assertEqual(self.client.call('XGROUP', 'DESTROY', 's', 'g'), 1)
        woken = reader.reply()
        self.assertIsInstance(woken, ServerError)
        self.assertTrue(str(woken).startswith('NOGROUP'))

    def test_xclaim_dirty_counts_a_raised_last_id_only_without_other_changes(self):
        cases = [
            ('c', ['2-1'], 0, ['LASTID', '9-0'], 1),
            ('c', ['1-1'], 0, ['LASTID', '9-0'], 1),
            ('c2', ['1-1'], 0, [], 2),
            ('c2', ['1-1'], 0, ['LASTID', '9-0'], 2),
            ('c', ['2-1'], 99999999, ['LASTID', '9-0'], 1),
            ('c2', ['2-1'], 99999999, ['LASTID', '9-0'], 2),
            ('c', ['1-1'], 0, [], 1),
            ('c', ['1-1'], 0, ['LASTID', '0-1'], 1),
            ('c', ['1-1', '3-1'], 0, ['LASTID', '9-0'], 2),
            ('c', ['1-1', '2-1'], 0, ['LASTID', '9-0'], 2),
            ('c2', ['2-1'], 0, ['LASTID', '9-0'], 2),
            ('c', ['7-7'], 0, ['LASTID', '9-0'], 1),
            ('c', ['7-7'], 0, [], 0),
            ('c', ['2-1'], 0, ['LASTID', '9-0', 'JUSTID'], 1),
            ('c', ['1-1'], 0, ['LASTID', '9-0', 'JUSTID'], 1),
        ]
        for consumer, ids, minidle, options, changes in cases:
            with self.subTest(consumer=consumer, ids=ids, minidle=minidle, options=options):
                self.client.call('DEL', 's')
                for i in range(1, 4):
                    self.client.call('XADD', 's', '%d-1' % i, 'f', 'v')
                self.client.call('XGROUP', 'CREATE', 's', 'g', '0')
                self.client.call('XREADGROUP', 'GROUP', 'g', 'c', 'STREAMS', 's', '>')
                self.client.call('XDEL', 's', '1-1', '3-1')
                before = self.dirty()
                self.client.call('XCLAIM', 's', 'g', consumer, minidle, *ids, *options)
                self.assertEqual(self.dirty() - before, changes)

    def test_xclaim_time_and_idle_outside_the_past_use_the_current_time(self):
        for i in range(1, 7):
            self.client.call('XADD', 's', '%d-1' % i, 'f', 'v')
        self.client.call('XGROUP', 'CREATE', 's', 'g', '0')
        self.client.call('XREADGROUP', 'GROUP', 'g', 'c', 'STREAMS', 's', '>')
        now = int(time.time() * 1000)
        forms = [('TIME', now + 10 ** 7, False), ('TIME', -5, False), ('IDLE', now + 10 ** 7, False),
                 ('IDLE', now + 1000, False), ('TIME', 5, True), ('IDLE', now - 5, True)]
        for i, (option, value, old) in enumerate(forms):
            self.client.call('XCLAIM', 's', 'g', 'c2', 0, '%d-1' % (i + 1), option, value, 'JUSTID')
        rows = self.client.call('XPENDING', 's', 'g', '-', '+', 10)
        for row, (option, value, old) in zip(rows, forms):
            with self.subTest(option=option, value=value):
                if old:
                    self.assertGreater(row[2], 10 ** 12)
                else:
                    self.assertLess(row[2], 5000)
                    self.assertGreaterEqual(row[2], 0)
        self.assertEqual([row[0] for row in self.client.call('XPENDING', 's', 'g', 'IDLE', 1000000, '-', '+', 10)], [b'5-1', b'6-1'])

    def test_restored_future_delivery_times_report_zero_idle(self):
        self.client.call('XADD', 's', '1-1', 'f', 'v')
        self.client.call('XADD', 's', '2-1', 'f', 'v')
        self.client.call('XGROUP', 'CREATE', 's', 'g', '0')
        low = int(time.time() * 1000) - 5
        self.client.call('XREADGROUP', 'GROUP', 'g', 'consumerX', 'STREAMS', 's', '>')
        high = int(time.time() * 1000) + 5
        payload = self.client.call('DUMP', 's')
        body = bytearray(payload[:-8])
        future = int(time.time() * 1000) + 100000000
        hits = 0
        for at in range(len(body) - 8):
            if low <= struct.unpack('<Q', body[at:at + 8])[0] <= high:
                body[at:at + 8] = struct.pack('<Q', future)
                hits += 1
        self.assertEqual(hits, 4)
        self.assertEqual(self.client.call('RESTORE', 'r', 0, bytes(body) + crc64(bytes(body)).to_bytes(8, 'little')), 'OK')
        self.assertEqual([(row[0], row[2]) for row in self.client.call('XPENDING', 'r', 'g', '-', '+', 10)], [(b'1-1', 0), (b'2-1', 0)])
        self.assertEqual(self.client.call('XPENDING', 'r', 'g', 'IDLE', 5, '-', '+', 10), [])
        consumer = self.client.call('XINFO', 'CONSUMERS', 'r', 'g')[0]
        fields = dict(zip(consumer[0::2], consumer[1::2]))
        self.assertEqual(fields[b'idle'], 0)
        self.assertLess(fields[b'inactive'], -99990000)

    def test_pfadd_dirty_counts_every_register_update(self):
        steps = [
            (('PFADD', 'h', 'a', 'b', 'c', 'd', 'e'), 6),
            (('PFADD', 'h', 'f', 'g', 'h'), 3),
            (('PFADD', 'h', 'a', 'b'), 0),
            (('PFADD', 'h2'), 1),
            (('PFADD', 'h2'), 0),
            (('PFADD', 'h', 'x', 'x', 'x'), 1),
            (('PFADD', 'h3', 'a', 'a'), 2),
            (('PFCOUNT', 'h'), 1),
            (('PFCOUNT', 'h'), 0),
            (('PFADD', 'big', *['e%d' % i for i in range(5000)]), 4507),
            (('PFADD', 'big', *['z%d' % i for i in range(300)]), 242),
            (('PFADD', 'sp', *['e%d' % i for i in range(1000)]), 987),
            (('PFADD', 'sp', *['f%d' % i for i in range(3000)]), 2725),
            (('PFMERGE', 'm', 'h', 'big'), 1),
        ]
        for command, changes in steps:
            with self.subTest(command=command[:3]):
                before = self.dirty()
                self.client.call(*command)
                self.assertEqual(self.dirty() - before, changes)
        self.assertEqual(self.client.call('PFDEBUG', 'ENCODING', 'sp'), 'dense')

    def test_pfcount_cache_refresh_signals_watchers_and_trackers(self):
        self.client.call('PFADD', 'h', 'a', 'b', 'c')
        watcher = self.connection()
        tracker = self.connection(3)
        tracker.call('CLIENT', 'TRACKING', 'on')
        for stale in (True, False):
            with self.subTest(stale=stale):
                tracker.call('GET', 'h')
                tracker.pushes.clear()
                watcher.call('WATCH', 'h')
                self.assertEqual(self.client.call('PFCOUNT', 'h'), 3)
                watcher.call('MULTI')
                watcher.call('PING')
                self.assertEqual(watcher.call('EXEC') is None, stale)
                self.assertEqual(tracker.call('PING'), 'PONG')
                self.assertEqual(bool([push for push in tracker.pushes if push and push[0] == b'invalidate']), stale)
        self.client.call('PFADD', 'h', 'zz')
        tracker.call('GET', 'h')
        tracker.pushes.clear()
        self.assertEqual(self.client.call('PFCOUNT', 'h'), 4)
        self.assertEqual(tracker.call('PING'), 'PONG')
        self.assertEqual(tracker.pushes, [Push([b'invalidate', [b'h']])])

    def test_negative_timeouts_above_one_millisecond_block_forever(self):
        commands = [
            lambda t: ('BLPOP', 'nolist', t),
            lambda t: ('BZPOPMIN', 'nozset', t),
            lambda t: ('BLMOVE', 'nolist', 'dst', 'LEFT', 'LEFT', t),
            lambda t: ('BLMPOP', t, 1, 'nolist', 'LEFT'),
            lambda t: ('BZMPOP', t, 1, 'nozset', 'MIN'),
        ]
        for shape in commands:
            for value in ('-0.0001', '-0.001', '-0.0009999', '-1e-300', '-0'):
                with self.subTest(command=shape(value)):
                    blocked = self.connection()
                    blocked.call('CLIENT', 'SETNAME', 'negative-timeout')
                    identity = blocked.call('CLIENT', 'ID')
                    blocked.send(*shape(value))
                    wait_for(lambda: int(info(self.client, 'clients')['blocked_clients']) == 1, timeout=5, label='blocked client')
                    self.assertEqual(self.pending(blocked, 0.1), [])
                    self.assertEqual(self.client.call('CLIENT', 'UNBLOCK', identity), 1)
                    self.assertIsNone(blocked.reply())
            for value in ('-0.0010001', '-0.0015', '-1', '-inf'):
                with self.subTest(command=shape(value)):
                    self.client.send(*shape(value))
                    self.assertEqual(str(self.client.reply()), 'ERR timeout is negative')

    def test_exact_trims_with_limit_from_an_append_only_file_load(self):
        if REFERENCE_PORT is not None:
            self.skipTest('needs a server started from a prepared append only file')
        server = Server(BINARY, workers=0, arguments=('--appendonly', 'yes', '--stream-node-max-entries', '2', '--keyspace-threads', str(WORKERS)))
        self.addCleanup(server.close)
        folder = server.directory / 'appendonlydir'
        folder.mkdir()
        commands = [('XADD', 's', '%d-1' % i, 'f', 'v') for i in range(1, 31)]
        commands += [('XADD', 's', 'MAXLEN', '=', 29, 'LIMIT', 3, '31-1', 'f', 'v'),
                     ('XTRIM', 's', 'MAXLEN', '=', 25, 'LIMIT', 4),
                     ('XTRIM', 's', 'MINID', '=', '25-1', 'LIMIT', 0),
                     ('XADD', 's', 'MINID', '=', '27-1', '32-1', 'f', 'v')]
        body = b''.join(b'*%d\r\n' % len(command) + b''.join(b'$%d\r\n%s\r\n' % (len(str(part)), str(part).encode()) for part in command) for command in commands)
        (folder / 'appendonly.aof.1.incr.aof').write_bytes(b'*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n' + body)
        (folder / 'appendonly.aof.manifest').write_text('file appendonly.aof.1.incr.aof seq 1 type i\n')
        server.start()
        client = server.client()
        self.assertEqual(client.call('XLEN', 's'), 6)
        self.assertEqual(client.call('XRANGE', 's', '-', '+', 'COUNT', 1)[0][0], b'27-1')

    def test_skiplist_zscan_pages_reach_the_count_hint(self):
        arguments = []
        for i in range(1000):
            arguments += [i, 'm%04d' % i]
        self.client.call('ZADD', 'z', *arguments)
        self.assertEqual(self.client.call('OBJECT', 'ENCODING', 'z'), b'skiplist')
        cursor = b'0'
        seen = set()
        pages = []
        while True:
            cursor, page = self.client.call('ZSCAN', 'z', cursor, 'COUNT', 10)
            pages.append(len(page) // 2)
            seen.update(page[0::2])
            if cursor == b'0':
                break
        self.assertEqual(len(seen), 1000)
        self.assertTrue(all(size >= 10 for size in pages[:-1]), pages)


def main():
    global BINARY, REFERENCE_PORT, WORKERS
    parser = argparse.ArgumentParser(description='Data type replies, signalling and change counts that match the reference.')
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--reference-port', type=int, help='explicitly isolated localhost reference fixture')
    parser.add_argument('--keyspace-threads', type=int, choices=(0, 2), default=0)
    args = parser.parse_args()
    BINARY, REFERENCE_PORT, WORKERS = args.server.resolve(), args.reference_port, args.keyspace_threads
    if REFERENCE_PORT is None and not BINARY.is_file():
        parser.error('existing binary required')
    signal.alarm(300)
    return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(DatatypeParity)).wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
