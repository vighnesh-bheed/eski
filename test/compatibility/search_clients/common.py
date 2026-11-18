import argparse
from importlib.metadata import version
from pathlib import Path
import re
import socket
import struct
import sys
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / 'test/threading'))
from support import Client, ServerError

POINT = [1.0, 0.0, 0.0]
OTHER = [0.0, 1.0, 0.0]
THIRD = [-1.0, 0.0, 0.0]
INVALID_VECTOR_OPTION = 'SEARCH_OPTION_INVALID Invalid option'
MISSING = 'SEARCH_INDEX_NOT_FOUND Index not found: '
DENIED = 'NOPERM User does not have the required permissions to query the index'


def point(vector=POINT):
    return struct.pack('<3f', *vector)


def pairs(reply):
    return reply if isinstance(reply, dict) else dict(zip(reply[::2], reply[1::2]))


def setup(expected):
    parser = argparse.ArgumentParser()
    parser.add_argument('port', type=int)
    parser.add_argument('protocol', type=int, choices=(2, 3))
    parser.add_argument('--scoped', action='store_true')
    args = parser.parse_args()
    for package, pin in expected.items():
        actual = version(package)
        if actual != pin:
            parser.error(f'{package} is {actual}, expected {pin}')
    print('Python', '.'.join(map(str, sys.version_info[:3])),
          ' '.join(f'{package}=={pin}' for package, pin in expected.items()), flush=True)
    return args


class Guard:
    def __init__(self, port):
        self.port = port
        self.commands = []

    def install(self):
        connect = socket.socket.connect

        def local_only(sock, address):
            if sock.family != socket.AF_INET or address != ('127.0.0.1', self.port):
                raise OSError(f'fixture blocked connection to {address!r}')
            return connect(sock, address)

        socket.socket.connect = local_only

    def pack(self, original):
        def record(serializer, *args):
            name, *options = args
            if isinstance(name, bytes):
                name = name.decode()
            name = name.upper()
            command = (*name.split(), *options)
            self.check(command)
            self.commands.append(command)
            return original(serializer, *args)
        return record

    def check(self, argv):
        command = argv[0]
        if command in {'FLUSHALL', 'FLUSHDB', 'SHUTDOWN', 'DEBUG', 'CONFIG'}:
            raise AssertionError(f'unexpected administrative command {command}')
        if command in {'FT.SEARCH', 'FT.AGGREGATE', 'FT.HYBRID', 'SCAN'}:
            tokens = [x.decode(errors='replace') if isinstance(x, bytes) else str(x) for x in argv]
            for i, token in enumerate(tokens[:-1]):
                width = {'LIMIT': 2, 'COUNT': 1, 'MAX': 1, 'K': 1, 'WINDOW': 1,
                         'TOPK': 1, 'EF_RUNTIME': 1, 'BATCH_SIZE': 1}.get(token.upper(), 0)
                for value in tokens[i + 1:i + 1 + width]:
                    if re.fullmatch(r'-?\d+', value) and not 0 <= int(value) <= 1000:
                        if (command == 'FT.SEARCH' and tokens[1:3] == ['client-chat', '@session_id:{first}']
                                and tokens[i:i + 3] == ['LIMIT', '0', '10000']):
                            continue
                        raise AssertionError(f'out of bounds {command} {token} {value}')
            for query in tokens[2:3]:
                for value in re.findall(r'\bKNN\s+(\d+)', query, re.I):
                    if int(value) > 1000:
                        raise AssertionError(f'out of bounds KNN {value}')

    def record_redis(self):
        from redis.connection import HiredisRespSerializer, PythonRespSerializer
        for serializer in (HiredisRespSerializer, PythonRespSerializer):
            serializer.pack = self.pack(serializer.pack)


class ClientCase(unittest.TestCase):
    def raw(self, protocol, user=None):
        client = Client(self.args.port)
        self.addCleanup(client.close)
        if user:
            client.call('AUTH', user, 'fixture')
        if protocol == 3:
            self.assertEqual(client.call('HELLO', 3)[b'proto'], 3)
        return client

    def redis(self, protocol=None, user=None):
        from redis import Redis

        client = Redis(host='127.0.0.1', port=self.args.port, protocol=self.redis_protocol(protocol),
                       username=user, password='fixture' if user else None, socket_timeout=5,
                       socket_connect_timeout=3)
        self.addCleanup(client.close)
        return client

    def redis_protocol(self, protocol):
        return protocol or self.args.protocol

    def name(self, base):
        return f'{base}-{self.args.protocol}'

    def expect_wire(self, start, *prefix):
        self.assertTrue(any(cmd[:len(prefix)] == prefix for cmd in self.guard.commands[start:]), prefix)

    def assert_distance(self, value, expected=0):
        self.assertAlmostEqual(float(value), expected, places=6)

    def assert_missing_twin(self, c, visible, hidden, data_cmd, prefix):
        for command, suffix in [('FT.INFO', ()), ('FT.SEARCH', ('*', 'NOCONTENT'))]:
            errors = []
            for name in (hidden, 'never-created'):
                with self.assertRaises(ServerError) as exc:
                    c.call(command, name, *suffix)
                errors.append(str(exc.exception).replace(name, '<name>'))
            self.assertEqual(errors, [MISSING + '<name>'] * 2)
        self.assertNotIn(hidden, c.call('FT._LIST'))
        self.assertIn(visible, c.call('FT._LIST'))
        missing = {} if self.args.protocol == 3 else []
        if data_cmd == 'JSON.GET':
            missing = None
        for key in ('hidden', 'high', 'never-created'):
            self.assertEqual(c.call(data_cmd, f'{prefix}:{key}'), missing)

    def scoped_users(self):
        admin = self.raw(self.args.protocol)
        for user, owner, label, keys, modules in (
                ('client-alice', 'alice', 'U', '~*', '+module|list'),
                ('client-bob', 'bob', 'U', '~*', '+module|list'),
                ('client-limited', 'alice', 'U', '%R~allowed:*', '+module|list')):
            self.assertEqual(admin.call('LABEL', 'AS', 'S//A/B', 'SHARED', 'ACL', 'SETUSER',
                                        user, 'reset', 'on', '>fixture',
                                        f'owner:{owner}', f'clearance:{label}', keys,
                                        '+@search', '+@json', '+@connection', '+@hash',
                                        '+del', '+expire', '+ttl', '+multi', '+exec', modules), 'OK')
        return admin

    def assert_scope(self, client, visible, prefix):
        info = pairs(client.call('FT.INFO', visible))
        self.assertEqual(info['num_docs'], 2)
        hits = client.call('FT.SEARCH', visible, '*=>[KNN 2 @embedding $v AS distance]',
                           'SORTBY', 'distance', 'RETURN', 2, 'content', 'distance',
                           'PARAMS', 2, 'v', point(), 'DIALECT', 2)
        if self.args.protocol == 2:
            keys = hits[1::2]
            fields = [pairs(row) for row in hits[2::2]]
        else:
            keys = [row['id'] for row in hits['results']]
            fields = [row['extra_attributes'] for row in hits['results']]
        self.assertEqual(keys, [f'{prefix}:one'.encode(), f'{prefix}:two'.encode()])
        self.assertEqual([row[b'content'] for row in fields], [b'alpha cat', b'beta dog'])
        self.assert_distance(fields[0][b'distance'])
        self.assert_distance(fields[1][b'distance'], 1)
        with self.assertRaisesRegex(ServerError, DENIED):
            self.raw(self.args.protocol, 'client-limited').call('FT.SEARCH', visible, '*')


def execute(args, guard, *classes):
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(cls) for cls in classes)
    for group in suite:
        for case in group:
            case.args = args
            case.guard = guard
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
