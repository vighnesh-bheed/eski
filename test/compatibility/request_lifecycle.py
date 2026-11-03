import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import signal
import socket
import struct
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Server, ServerError, encode, info, wait_for
sys.path.insert(0, str(ROOT / 'test/compatibility'))
import transport

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0


class RequestLifecycle(unittest.TestCase):
    def setUp(self):
        self.server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS)))
        self.addCleanup(self.server.close)
        self.server.start()
        self.control = self.server.client()

    def fields(self, name):
        for row in self.control.call('CLIENT', 'LIST').decode().splitlines():
            values = dict(field.split('=', 1) for field in row.split())
            if values.get('name') == name:
                return values
        return None

    def named(self, name):
        client = self.server.client()
        client.call('CLIENT', 'SETNAME', name)
        return client

    def test_bulk_arrival_fragmentation_preserves_capacity_and_bucket_eviction_order(self):
        control = self.control
        control.call('CLIENT', 'SETNAME', 'control')
        control.call('CLIENT', 'NO-EVICT', 'ON')
        control.call('DEBUG', 'REPLYBUFFER', 'RESIZING', 0)

        def rows():
            return [dict(field.split('=', 1) for field in row.split())
                    for row in control.call('CLIENT', 'LIST').decode().splitlines()]

        sizes = (128 << 10, 1 << 20)
        for name, size in zip(('bucket-small', 'bucket-large'), sizes):
            header = b'*2\r\n$' + str(size).encode() + b'\r\n'
            for index in range(3):
                client = self.named(name)
                if index == 0:
                    client.socket.sendall(header)
                    wait_for(lambda: any(row.get('name') == name and int(row['qbuf-free']) >= size
                                         for row in rows()), timeout=2, label='validated fragmented bulk header')
                    client.socket.sendall(b'v' * size)
                else:
                    client.socket.sendall(header + b'v' * size)
            wait_for(lambda: len([row for row in rows() if row.get('name') == name and int(row['qbuf']) == size]) == 3,
                     timeout=2, label='all equal incomplete bulk bodies received')
            group = [row for row in rows() if row.get('name') == name]
            self.assertEqual(len({row['tot-mem'] for row in group}), 1)
            self.assertEqual(len({int(row['qbuf']) + int(row['qbuf-free']) for row in group}), 1)

        current = rows()
        small = next(int(row['tot-mem']) for row in current if row.get('name') == 'bucket-small')
        controller = next(int(row['tot-mem']) for row in current if row.get('name') == 'control')
        control.call('CONFIG', 'SET', 'maxmemory-clients', small * 3 + controller)
        remaining = rows()
        self.assertEqual(len([row for row in remaining if row.get('name') == 'bucket-small']), 3)
        self.assertEqual(len([row for row in remaining if row.get('name') == 'bucket-large']), 0)

    def test_idle_reply_buffer_regrowth_preserves_real_maxmemory_headroom(self):
        client = self.control
        client.call('CONFIG', 'SET', 'latency-tracking', 'no')
        client.call('CONFIG', 'SET', 'maxmemory-policy', 'allkeys-random')
        for start in range(0, 4095, 16):
            commands = [('SET', str(index), 'A') for index in range(start, min(start + 16, 4095))]
            client.send_many(commands)
            for _ in commands:
                self.assertEqual(client.reply(), 'OK')
        time.sleep(1.2)
        used = int(info(client, 'memory')['used_memory'])
        client.call('CONFIG', 'SET', 'maxmemory', used + 10240)
        for index in range(3):
            self.assertEqual(client.call('SET', 'after-idle-' + str(index), 'A'), 'OK')
        self.assertEqual(client.call('DBSIZE'), 4098)
        self.assertEqual(int(info(client, 'stats')['evicted_keys']), 0)

    def test_partial_payload_consumes_headers_and_restores_binary_pipeline(self):
        client = self.named('partial-payload')
        value = bytes(range(256)) * 4096
        wire = encode(('SET', 'fragmented', value))
        payload = wire.index(value[:256])
        client.socket.sendall(wire[:payload])
        wait_for(lambda: int(self.fields('partial-payload')['qbuf']) == 0 and int(self.fields('partial-payload')['qbuf-free']) >= len(value),
                 timeout=2, label='parsed headers moved out of actual query buffer')
        self.assertGreaterEqual(int(self.fields('partial-payload')['qbuf-free']), len(value))
        client.socket.sendall(value[:900000])
        wait_for(lambda: int(self.fields('partial-payload')['qbuf']) == 900000,
                 timeout=2, label='actual incomplete body bytes')
        client.socket.sendall(value[900000:] + b'\r\n' + encode(('GET', 'fragmented')))
        self.assertEqual(client.reply(), 'OK')
        self.assertEqual(client.reply(), value)
        self.assertEqual(client.call('PING'), 'PONG')

    def test_earlier_large_bulk_and_leading_command_survive_final_bulk_fragment(self):
        client = self.named('leading-pipeline')
        first = b'a\x00\xff\r\n' * 50000
        second = bytes(range(256)) * 2048
        wire = encode(('MSET', 'first', first, 'second', second))
        split = len(wire) - len(second) - 2 + 12345
        client.socket.sendall(encode(('PING',)) + wire[:split])
        self.assertEqual(client.reply(), 'PONG')
        wait_for(lambda: int(self.fields('leading-pipeline')['qbuf']) == 12345,
                 timeout=2, label='completed leading frame compacted without losing earlier bulk')
        client.socket.sendall(wire[split:] + encode(('MGET', 'first', 'second')))
        self.assertEqual(client.reply(), 'OK')
        self.assertEqual(client.reply(), [first, second])

    def test_fragmented_blocked_replay_and_paused_pipeline_keep_argument_ownership(self):
        client = self.named('replayed')
        wire = encode(('BLMOVE', 'source', 'destination', 'LEFT', 'RIGHT', 0))
        split = wire.index(b'BLMOVE') + 3
        client.socket.sendall(wire[:split])
        wait_for(lambda: int(self.fields('replayed')['qbuf']) == 3, timeout=2, label='partial blocking command body')
        client.socket.sendall(wire[split:] + encode(('PING',)))
        wait_for(lambda: int(info(self.control, 'clients')['blocked_clients']) == 1,
                 timeout=2, label='fragmented command parked with complete replay frame')
        self.control.call('LPUSH', 'source', 'value')
        self.assertEqual(client.reply(), b'value')
        self.assertEqual(client.reply(), 'PONG')
        self.assertEqual(self.control.call('LRANGE', 'destination', 0, -1), [b'value'])
        self.control.call('CLIENT', 'PAUSE', 10000, 'WRITE')
        try:
            wire = encode(('SET', 'paused-fragment', 'retained'))
            split = wire.index(b'retained') + 2
            client.socket.sendall(wire[:split])
            wait_for(lambda: int(self.fields('replayed')['qbuf']) == 2, timeout=2, label='paused command fragment')
            client.socket.sendall(wire[split:] + encode(('GET', 'paused-fragment')))
            wait_for(lambda: self.fields('replayed')['cmd'] == 'set', timeout=2, label='restored command held by pause')
            self.assertFalse(client.available(.02))
        finally:
            self.control.call('CLIENT', 'UNPAUSE')
        self.assertEqual(client.reply(), 'OK')
        self.assertEqual(client.reply(), b'retained')

    def test_partial_eof_and_following_protocol_error_release_owned_prefix(self):
        baseline = int(info(self.control, 'clients')['connected_clients'])
        client = self.named('eof-prefix')
        client.socket.sendall(b'*2\r\n$3\r\nGET\r\n$2097152\r\n')
        wait_for(lambda: int(self.fields('eof-prefix')['qbuf-free']) >= 2097152,
                 timeout=2, label='actual large body reservation')
        client.close()
        wait_for(lambda: int(info(self.control, 'clients')['connected_clients']) == baseline,
                 timeout=2, label='partial EOF closes owner')
        self.assertEqual(self.control.call('PING'), 'PONG')
        malformed = self.named('error-prefix')
        malformed.socket.sendall(b'*2\r\n$3\r\nGET\r\n$100\r\nx')
        wait_for(lambda: int(self.fields('error-prefix')['qbuf']) == 1, timeout=2, label='error fixture prefix consumed')
        malformed.socket.sendall(b'x' * 99 + b'\r\n*1\r\n$xx\r\n')
        self.assertIsNone(malformed.reply())
        self.assertIn('invalid bulk length', str(malformed.reply()))
        self.assertEqual(self.control.call('PING'), 'PONG')

    def worker_counters(self):
        values = info(self.control)
        return int(values['keyspace_jobs_submitted']), int(values['keyspace_sync_fallbacks'])

    def assert_error(self, value, prefix):
        self.assertIsInstance(value, ServerError)
        self.assertTrue(str(value).startswith(prefix), value)

    def test_mixed_pipeline_replies_follow_request_order(self):
        client = self.named('mixed-order')
        submitted, _ = self.worker_counters()
        commands = [('SET', 'order:a', 'one'), ('GET', 'order:a'), ('INCR', 'order:n'), ('GET', 'order:a', 'extra'),
                    ('INCR', 'order:n'), ('PING',), ('NOSUCHCOMMAND', 'x'), ('GET', 'order:n'),
                    ('SELECT', 1), ('SET', 'order:a', 'db1'), ('GET', 'order:a'), ('SELECT', 0), ('GET', 'order:a'),
                    ('MULTI',), ('SET', 'order:a', 'tx'), ('GET', 'order:a'), ('EXEC',),
                    ('APPEND', 'order:a', '!'), ('CLIENT', 'REPLY', 'SKIP'), ('SET', 'order:b', 'skipped'),
                    ('GET', 'order:b'), ('CLIENT', 'REPLY', 'OFF'), ('INCR', 'order:n'), ('GET', 'order:n'),
                    ('CLIENT', 'REPLY', 'ON'), ('HSET', 'order:h', 'f', 'v'), ('HGET', 'order:h', 'f'),
                    ('INFO', 'keyspace'), ('LPUSH', 'order:a', 'x'), ('MGET', 'order:a', 'order:b', 'order:n'),
                    ('ECHO', 'end')]
        client.send_many(commands)
        replies = [client.reply() for _ in range(len(commands) - 5)]
        self.assertEqual(replies[:3], ['OK', b'one', 1])
        self.assert_error(replies[3], 'ERR wrong number of arguments')
        self.assertEqual(replies[4:6], [2, 'PONG'])
        self.assert_error(replies[6], 'ERR unknown command')
        self.assertEqual(replies[7:19], [b'2', 'OK', 'OK', b'db1', 'OK', b'one', 'OK', 'QUEUED', 'QUEUED',
                                         ['OK', b'tx'], 3, b'skipped'])
        self.assertEqual(replies[19:22], ['OK', 1, b'v'])
        self.assertIn(b'db0:keys=', replies[22])
        self.assert_error(replies[23], 'WRONGTYPE')
        self.assertEqual(replies[24:], [[b'tx!', b'skipped', b'3'], b'end'])
        self.assertFalse(client.available(.05))
        if KEYSPACE_THREADS:
            self.assertGreaterEqual(self.worker_counters()[0] - submitted, 12)

    def test_acl_rejection_after_accepted_pipeline_commands_keeps_order(self):
        self.control.call('ACL', 'SETUSER', 'pipeline-reader', 'on', 'nopass', '~*', '+get', '+incr', '+ping', '+auth')
        self.control.call('SET', 'reject:key', 'kept')
        reader = self.server.client()
        reader.call('AUTH', 'pipeline-reader', 'unused')
        replies = reader.pipeline([('INCR', 'reject:n'), ('GET', 'reject:key'), ('SET', 'reject:key', 'denied'),
                                   ('GET', 'reject:key'), ('INCR', 'reject:n'), ('PING',)])
        self.assertEqual(replies[:2], [1, b'kept'])
        self.assert_error(replies[2], 'NOPERM')
        self.assertEqual(replies[3:], [b'kept', 2, 'PONG'])

    def test_oom_rejection_after_accepted_pipeline_commands_keeps_order(self):
        self.control.call('SET', 'reject:key', 'kept')
        self.control.call('SET', 'reject:n', 2)
        self.control.call('CONFIG', 'SET', 'maxmemory-policy', 'noeviction')
        self.control.call('CONFIG', 'SET', 'maxmemory', 1)
        try:
            replies = self.control.pipeline([('GET', 'reject:key'), ('SET', 'reject:other', 'v'), ('GET', 'reject:key'),
                                             ('INCR', 'reject:n'), ('GET', 'reject:n')])
        finally:
            self.control.call('CONFIG', 'SET', 'maxmemory', 0)
        self.assertEqual(replies[0], b'kept')
        self.assert_error(replies[1], 'OOM')
        self.assertEqual(replies[2], b'kept')
        self.assert_error(replies[3], 'OOM')
        self.assertEqual(replies[4], b'2')

    def test_protocol_error_after_accepted_pipeline_commands_keeps_order(self):
        client = self.named('protocol-after-accepted')
        client.socket.sendall(encode(('SET', 'proto:a', 1)) + encode(('INCR', 'proto:a')) + encode(('GET', 'proto:a'))
                              + b'*1\r\n$xx\r\n')
        self.assertEqual([client.reply() for _ in range(3)], ['OK', 2, b'2'])
        self.assert_error(client.reply(), 'ERR Protocol error')
        with self.assertRaises((EOFError, ConnectionResetError)):
            client.reply()
        self.assertEqual(self.control.call('GET', 'proto:a'), b'2')

    def test_disconnect_mid_pipeline_keeps_an_accepted_prefix(self):
        count = 300
        keys = ['cut:%03d' % index for index in range(count)]
        wire = b''.join(encode(('SET', key, index)) for index, key in enumerate(keys))
        baseline = int(info(self.control, 'clients')['connected_clients'])
        raw = socket.create_connection(('127.0.0.1', self.server.port), timeout=3)
        raw.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
        raw.sendall(wire)
        raw.close()
        wait_for(lambda: int(info(self.control, 'clients')['connected_clients']) == baseline,
                 timeout=5, label='reset connection closed')
        values = self.control.call('MGET', *keys)
        accepted = next((index for index, value in enumerate(values) if value is None), count)
        self.assertEqual(values[:accepted], [str(index).encode() for index in range(accepted)])
        self.assertEqual(values[accepted:], [None] * (count - accepted))
        half = self.server.client()
        half.socket.sendall(b''.join(encode(('INCR', 'half:' + key)) for key in keys))
        half.socket.shutdown(socket.SHUT_WR)
        self.assertEqual([half.reply() for _ in keys], [1] * count)
        with self.assertRaises((EOFError, ConnectionResetError)):
            half.reply()
        self.assertEqual(self.control.call('MGET', *['half:' + key for key in keys]), [b'1'] * count)

    def test_concurrent_deep_pipelines_keep_per_connection_order(self):
        connections, depth = 6, 120
        clients = [self.server.client() for _ in range(connections)]
        submitted, fallbacks = self.worker_counters()
        def run(index):
            commands = []
            for _ in range(depth):
                commands += [('INCR', 'deep:%d' % index), ('INCR', 'deep:shared'), ('GET', 'deep:%d' % index)]
            return clients[index].pipeline(commands)
        with ThreadPoolExecutor(max_workers=connections) as pool:
            results = list(pool.map(run, range(connections)))
        shared = []
        for replies in results:
            self.assertEqual(replies[0::3], list(range(1, depth + 1)))
            self.assertEqual(replies[2::3], [str(value).encode() for value in range(1, depth + 1)])
            self.assertEqual(replies[1::3], sorted(replies[1::3]))
            shared += replies[1::3]
        self.assertEqual(sorted(shared), list(range(1, connections * depth + 1)))
        if KEYSPACE_THREADS:
            after_submitted, after_fallbacks = self.worker_counters()
            self.assertEqual(after_submitted - submitted, connections * depth * 3)
            self.assertEqual(after_fallbacks, fallbacks)

    def test_fragmented_tls_and_unix_requests_use_same_owned_lifecycle(self):
        transport.BINARY = BINARY
        transport.Transport.setUpClass()
        self.addCleanup(transport.Transport.tearDownClass)
        pki = transport.Transport.pki
        tls_port = transport.free_port()
        server = transport.TransportServer(('--tls-port', str(tls_port), '--tls-cert-file', str(pki / 'server.crt'),
                    '--tls-key-file', str(pki / 'server.key'), '--tls-ca-cert-file', str(pki / 'ca.crt'), '--tls-auth-clients', 'no'))
        self.addCleanup(server.close)
        server.start()
        import ssl
        context = ssl.create_default_context(cafile=str(pki / 'ca.crt'))
        raw = socket.create_connection(('127.0.0.1', tls_port), timeout=3)
        tls = transport.NetworkClient(context.wrap_socket(raw, server_hostname='localhost'))
        self.addCleanup(tls.close)
        unix_server = transport.TransportServer(unix=True)
        self.addCleanup(unix_server.close)
        unix_server.start()
        unix = unix_server.connection()
        for client in (tls, unix):
            value = b'\x00\xffwire' * 20000
            wire = encode(('SET', 'transport-fragment', value))
            split = len(wire) - len(value) - 2 + 17
            client.socket.sendall(wire[:split])
            time.sleep(.01)
            client.socket.sendall(wire[split:] + encode(('GET', 'transport-fragment')))
            self.assertEqual(client.reply(), 'OK')
            self.assertEqual(client.reply(), value)


def main():
    global BINARY, KEYSPACE_THREADS
    parser = argparse.ArgumentParser(description='Original fragmented protocol ownership and query-buffer lifecycle regressions.')
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--keyspace-threads', type=int, choices=(0, 2), default=0)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    KEYSPACE_THREADS = args.keyspace_threads
    if not BINARY.is_file():
        parser.error('existing server binary required')
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(124))
    signal.alarm(90)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(RequestLifecycle))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
