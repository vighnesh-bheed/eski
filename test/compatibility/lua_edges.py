import argparse
from pathlib import Path
import signal
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Server, ServerError

BINARY = ROOT / 'bin/eski'


class LuaEdges(unittest.TestCase):
    def setUp(self):
        self.server = Server(BINARY, workers=0, arguments=('--keyspace-threads', '2'))
        self.server.start()
        self.addCleanup(self.server.close)
        self.client = self.server.client()

    def test_time_is_frozen_to_microseconds_inside_script(self):
        self.client.call('DEBUG', 'SET-DISABLE-DENY-SCRIPTS', 1)
        source = 'local first=redis.call("TIME");redis.call("DEBUG","SLEEP",0.02);return {first,redis.call("TIME")}'
        result = self.client.call('EVAL', source, 0)
        self.assertEqual(result[0], result[1])
        self.assertEqual(len(result[0]), 2)
        self.assertTrue(0 <= int(result[0][1]) < 1000000)

    def test_debug_object_preserves_expired_physical_key(self):
        self.client.call('DEBUG', 'SET-ACTIVE-EXPIRE', 0)
        self.client.call('SET', 'expired', 'kept-physically', 'PX', 1)
        self.client.call('DEBUG', 'SLEEP', 0.01)
        self.assertIn('encoding:', self.client.call('DEBUG', 'OBJECT', 'expired'))
        self.assertEqual(self.client.call('EVAL', 'return redis.call("EXISTS",KEYS[1])', 1, 'expired'), 0)
        result = self.client.pipeline([('DEBUG', 'OBJECT', 'expired'), ('PING',)])
        self.assertIsInstance(result[0], ServerError)
        self.assertEqual(result[1], 'PONG')

    def test_sort_constant_orders_set_before_projection_and_limit(self):
        self.client.call('SADD', 'unordered', 'z', 'a', 'aaa', 'aa', 'b')
        self.client.call('MSET', 'value:a', 'A', 'value:aa', 'AA')
        source = 'return redis.call("SORT",KEYS[1],unpack(ARGV))'
        self.assertEqual(self.client.call('EVAL', source, 1, 'unordered', 'BY', '_'), [b'a', b'aa', b'aaa', b'b', b'z'])
        self.assertEqual(self.client.call('EVAL', source, 1, 'unordered', 'BY', '_', 'DESC', 'LIMIT', 1, 2), [b'b', b'aaa'])
        self.assertEqual(self.client.call('EVAL', source, 1, 'unordered', 'BY', '_', 'LIMIT', 0, 2, 'GET', '#', 'GET', 'value:*'), [b'a', b'A', b'aa', b'AA'])
        self.client.call('RPUSH', 'ordered-list', 'z', 'a', 'b')
        self.client.call('ZADD', 'ordered-zset', 1, 'z', 2, 'a', 3, 'b')
        for key in ('ordered-list', 'ordered-zset'):
            self.assertEqual(self.client.call('EVAL', source, 1, key, 'BY', '_'), [b'z', b'a', b'b'])

    def test_dynamic_configuration_errors_preserve_protocol_framing(self):
        result = self.client.pipeline([('CONFIG', 'SET', 'unknown\r\n+injected', 'x'), ('PING', 'following')])
        self.assertIsInstance(result[0], ServerError)
        self.assertNotIn('\r', str(result[0]))
        self.assertNotIn('\n', str(result[0]))
        self.assertIn('unknown  +injected', str(result[0]))
        self.assertEqual(result[1], b'following')
        self.assertFalse(self.client.available(0.01))


def main():
    global BINARY
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', type=Path, default=BINARY)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    signal.alarm(90)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(LuaEdges))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
