import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import time
import unittest


sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'test/threading'))
from support import Client, Push, Server, ServerError, info, wait_for


BINARY = ROOT/'bin/eski'
REFERENCE_PORT = None


def unpack_message(data):
    offset = 0

    def take(length):
        nonlocal offset
        if length < 0 or length > len(data)-offset:
            raise ValueError('truncated MessagePack value')
        value = data[offset:offset+length]
        offset += length
        return value

    def read(depth=0):
        if depth > 64:
            raise ValueError('MessagePack nesting exceeds the test limit')
        tag = take(1)[0]
        if tag < 0x80:
            return tag
        if tag >= 0xe0:
            return tag-256
        if 0xa0 <= tag <= 0xbf:
            return take(tag & 31)
        if 0x90 <= tag <= 0x9f:
            return [read(depth+1) for _ in range(tag & 15)]
        if 0x80 <= tag <= 0x8f:
            return {read(depth+1): read(depth+1) for _ in range(tag & 15)}
        if tag in (0xc0, 0xc2, 0xc3):
            return {0xc0: None, 0xc2: False, 0xc3: True}[tag]
        numbers = {0xca: '>f', 0xcb: '>d', 0xcc: '>B', 0xcd: '>H', 0xce: '>I',
                   0xcf: '>Q', 0xd0: '>b', 0xd1: '>h', 0xd2: '>i', 0xd3: '>q'}
        if tag in numbers:
            fmt = numbers[tag]
            return struct.unpack(fmt, take(struct.calcsize(fmt)))[0]
        lengths = {0xc4: 1, 0xc5: 2, 0xc6: 4, 0xd9: 1, 0xda: 2, 0xdb: 4,
                   0xdc: 2, 0xdd: 4, 0xde: 2, 0xdf: 4}
        if tag not in lengths:
            raise ValueError('unsupported MessagePack tag %02x' % tag)
        count = int.from_bytes(take(lengths[tag]), 'big')
        if tag in (0xc4, 0xc5, 0xc6, 0xd9, 0xda, 0xdb):
            return take(count)
        if count > 100000:
            raise ValueError('MessagePack collection exceeds the test limit')
        if tag in (0xdc, 0xdd):
            return [read(depth+1) for _ in range(count)]
        return {read(depth+1): read(depth+1) for _ in range(count)}

    result = read()
    if offset != len(data):
        raise ValueError('trailing MessagePack bytes')
    return result


class Fixture(unittest.TestCase):
    portable = False

    def setUp(self):
        self.server = None
        if self.portable and REFERENCE_PORT is not None:
            self.client = Client(REFERENCE_PORT)
            self.addCleanup(self.client.close)
            self.client.call('FLUSHDB')
            self.client.call('SCRIPT', 'FLUSH', 'SYNC')
        else:
            self.server = Server(BINARY, workers=0)
            self.addCleanup(self.server.close)
            self.server.start()
            self.client = self.server.client()

    def error(self, arguments, contains=None, client=None):
        client = client or self.client
        client.send(*arguments)
        value = client.reply()
        self.assertIsInstance(value, ServerError)
        if contains is not None:
            self.assertIn(contains.casefold(), str(value).casefold())
        return value

    def healthy(self, client=None):
        client = client or self.client
        self.assertEqual(client.call('PING'), 'PONG')
        self.assertEqual(client.call('EVAL', 'return 17', 0), 17)

    def limit(self, name, value):
        old = self.client.call('CONFIG', 'GET', name)[1]
        self.client.call('CONFIG', 'SET', name, value)
        self.addCleanup(self.client.call, 'CONFIG', 'SET', name, old)

    def new_server(self, arguments=(), workers=0):
        instance = Server(BINARY, workers=workers, arguments=arguments)
        self.addCleanup(instance.close)
        return instance.start()

    def connection(self):
        if self.server is not None:
            return self.server.client()
        client = Client(REFERENCE_PORT)
        self.addCleanup(client.close)
        return client

    def typed(self, actual, expected):
        self.assertEqual(actual, expected)
        self.assertIs(type(actual), type(expected))
        if isinstance(expected, list):
            for left, right in zip(actual, expected):
                self.typed(left, right)


class Compatibility(Fixture):
    portable = True

    def test_bignum_text_sanitizes_line_breaks_in_both_client_protocols(self):
        for protocol in (2, 3):
            self.client.call('HELLO', protocol)
            for payload in (b'123\r\n123', b'', b'word'):
                with self.subTest(protocol=protocol, payload=payload):
                    self.client.send('EVAL', 'return {big_number=ARGV[1]}', 0, payload)
                    self.assertEqual(self.client.take(1), b'$' if protocol == 2 else b'(')
                    text = payload.replace(b'\r', b' ').replace(b'\n', b' ')
                    if protocol == 2:
                        self.assertEqual(int(self.client.line()), len(text))
                        self.assertEqual(self.client.take(len(text)+2), text+b'\r\n')
                    else:
                        self.assertEqual(self.client.line(), text)
                    self.assertEqual(self.client.call('PING'), 'PONG')

    def test_forwarded_error_stats_use_the_public_boolean_marker(self):
        source = "local e=redis.pcall('GET');return {type(e.ignore_error_stats_update),e.ignore_error_stats_update}"
        self.assertEqual(self.client.call('EVAL', source, 0), [b'boolean', 1])
        cases = (
            ("return redis.call('GET')", 1),
            ("return redis.pcall('GET')", 1),
            ("redis.pcall('GET');return redis.error_reply('ERR independent')", 2),
            ("return {err='ERR manual',ignore_error_stats_update=true}", 0),
            ("return {err='ERR manual',ignore_error_stats_update=false}", 1),
            ("return {err='ERR manual',ignore_error_stats_update=1}", 1),
        )
        for source, expected in cases:
            with self.subTest(source=source):
                self.client.call('CONFIG', 'RESETSTAT')
                self.error(('EVAL', source, 0))
                self.assertEqual(int(info(self.client, 'stats')['total_error_replies']), expected)

    def test_nested_error_stats_count_new_errors_and_preserve_array_framing(self):
        for source, count in (
            ("return {redis.error_reply('ERR nested')}", 1),
            ("return {redis.pcall('GET')}", 1),
            ("return {{err='ERR manual',ignore_error_stats_update=true}}", 0),
            ("return {{err='ERR manual',ignore_error_stats_update=1}}", 1),
            ("return {{err='CUSTOM first'},{{err='OTHER second'},{err='ERR ignored',ignore_error_stats_update=true}},redis.pcall('GET')}", 3),
        ):
            with self.subTest(source=source):
                self.client.call('CONFIG', 'RESETSTAT')
                result, following = self.client.pipeline([('EVAL', source, 0), ('PING', 'after-nested-errors')])
                self.assertIsInstance(result, list)
                self.assertIsInstance(result[0], ServerError)
                self.assertEqual(following, b'after-nested-errors')
                self.assertFalse(self.client.available(.01))
                self.assertEqual(int(info(self.client, 'stats')['total_error_replies']), count)
        errors = info(self.client, 'errorstats')
        self.assertEqual(errors['errorstat_CUSTOM'], 'count=1')
        self.assertEqual(errors['errorstat_OTHER'], 'count=1')
        self.assertEqual(errors['errorstat_ERR'], 'count=1')

    def test_acl_check_distinguishes_wrong_arity_and_unknown_commands(self):
        for arguments, expected in (("'eval','script'", 'Wrong number of args'), ("'get'", 'Wrong number of args'),
                                    ("'unknown-command'", 'Invalid command passed')):
            with self.subTest(arguments=arguments):
                error = self.error(('EVAL', 'return redis.acl_check_cmd('+arguments+')', 0), expected)
                self.assertFalse(str(error).startswith('ERR ERR '))
        self.healthy()

    def test_random_defaults_vary_and_explicit_seed_repeats(self):
        source = 'return {math.random(1,1000000000),math.random(1,1000000000),math.random(1,1000000000)}'
        rows = self.client.pipeline([('EVAL', source, 0)]*8)
        self.assertTrue(all(len(row) == 3 and all(type(value) is int and 1 <= value <= 1000000000 for value in row) for row in rows))
        self.assertGreater(len(set(tuple(row) for row in rows)), 1)
        seeded = 'math.randomseed(317); '+source
        repeated = self.client.pipeline([('EVAL', seeded, 0)]*8)
        self.assertEqual(repeated, [repeated[0]]*8)

    def test_returned_and_thrown_error_tables_preserve_content_and_frames(self):
        cases = ((b'', 'ERR '), (b'CUSTOM tagged', 'CUSTOM tagged'), (b'OOM tagged', 'OOM tagged'),
                 (b'ERR first\r\n+second', 'ERR first  +second'), (b'ERR left\x00right', 'ERR left'))
        for body in ('return redis.error_reply(ARGV[1])', 'error(redis.error_reply(ARGV[1]),0)'):
            for message, expected in cases:
                with self.subTest(body=body, message=message):
                    result, following = self.client.pipeline([('EVAL', body, 0, message), ('PING', 'following-error')])
                    self.assertIsInstance(result, ServerError)
                    self.assertTrue(str(result).startswith(expected), repr(result))
                    self.assertNotIn('\r', str(result))
                    self.assertNotIn('\n', str(result))
                    self.assertEqual(following, b'following-error')
                    self.assertFalse(self.client.available(.01))
        self.assertEqual(str(self.error(('EVAL', 'return {err=""}', 0))), '')
        self.error(('EVAL', 'error({},0)', 0), 'ERR ')
        self.assertEqual(self.client.call('EVAL', 'return {}', 0), [])
        self.healthy()

    def test_host_error_classes_and_global_pcall_string_origins_are_preserved(self):
        self.client.call('SET', 'error:typed', 'string')
        result = self.error(('EVAL', "return redis.call('LPUSH','error:typed','x')", 0))
        self.assertTrue(str(result).startswith('WRONGTYPE '), repr(result))
        result = self.error(('EVAL', "return redis.call('GET')", 0))
        self.assertTrue(str(result).startswith('ERR '), repr(result))
        self.assertFalse(str(result).startswith('ERR ERR '), repr(result))
        source = "local ok,x=pcall(function() return redis.call('LPUSH','error:typed','x') end); return {ok,type(x),x}"
        result = self.client.call('EVAL', source, 0)
        self.assertEqual(result[:2], [None, b'string'])
        self.assertTrue(result[2].startswith(b'WRONGTYPE '))
        result = self.client.call('EVAL', "local x=redis.pcall('LPUSH','error:typed','x'); return {type(x),x.err}", 0)
        self.assertEqual(result[0], b'table')
        self.assertTrue(result[1].startswith(b'WRONGTYPE '))
        for source, expected in (("error('ERR plain',0)", 'ERR ERR plain'),
                                 ("local _,x=pcall(function() redis.call('GET') end); error(x,0)", 'ERR ERR '),
                                 ("xpcall(function() redis.call('GET') end,function(x) return x end); error('ERR after',0)", 'ERR ERR after')):
            with self.subTest(source=source):
                self.assertTrue(str(self.error(('EVAL', source, 0))).startswith(expected))
        self.assertEqual(self.client.call('GET', 'error:typed'), b'string')

    def test_numeric_arguments_canonicalize_floats_without_changing_strings(self):
        source = "local negativezero=tonumber(ARGV[1])/tonumber(ARGV[2]); redis.call('SET','number:float',2.0); redis.call('SET','number:negative',negativezero); redis.call('SET','number:zero',0.0); redis.call('SET','number:string','2.0'); redis.call('SET','number:negative-string','-0.0'); return redis.call('MGET','number:float','number:negative','number:zero','number:string','number:negative-string')"
        self.assertEqual(self.client.call('EVAL', source, 0, '0', '-1'), [b'2', b'0', b'0', b'2.0', b'-0.0'])
        self.assertEqual(self.client.call('EVAL', "return redis.call('INCRBY','number:counter',2.0)", 0), 2)
        self.error(('EVAL', "return redis.call('INCRBY','number:counter','2.0')", 0), 'integer')
        self.assertEqual(self.client.call('GET', 'number:counter'), b'2')

    def test_binary_source_keys_arguments_and_nil_array_boundary(self):
        key, value, literal = b'key\x00\xff', b'arg\x00\r\n\xff', b'literal\x00\xfe'
        source = b'return {KEYS[1],ARGV[1],[=['+literal+b']=],false,19,nil,"lost"}'
        self.assertEqual(self.client.call('EVAL', source, 1, key, value), [key, value, literal, None, 19])
        self.assertEqual(self.client.call('EVAL', 'return {#KEYS,#ARGV}', 0), [0, 0])

    def test_key_count_and_arity_reject_before_effects(self):
        source = "return redis.call('SET','unexpected','written')"
        for command in ('EVAL', 'EVAL_RO', 'EVALSHA', 'EVALSHA_RO'):
            for count in ('-1', 'not-a-number', '9223372036854775808', '2'):
                with self.subTest(command=command, count=count):
                    self.error((command, source, count, 'one'))
            self.error((command,), 'wrong number')
        self.assertIsNone(self.client.call('GET', 'unexpected'))
        self.healthy()

    def test_load_is_compile_only_and_digest_execution_is_binary_safe(self):
        source = b"return redis.call('SET',KEYS[1],ARGV[1])"
        digest = hashlib.sha1(source).hexdigest().encode()
        self.assertEqual(self.client.call('SCRIPT', 'LOAD', source), digest)
        self.assertIsNone(self.client.call('GET', 'loaded'))
        self.assertEqual(self.client.call('SCRIPT', 'LOAD', source), digest)
        self.assertEqual(self.client.call('SCRIPT', 'EXISTS', digest, b'0'*40, digest), [1, 0, 1])
        self.assertEqual(self.client.call('EVALSHA', digest, 1, 'loaded', b'\x00\xff'), 'OK')
        self.assertEqual(self.client.call('GET', 'loaded'), b'\x00\xff')

    def test_invalid_source_missing_sha_and_both_flush_modes(self):
        bad = b'return function('
        self.error(('SCRIPT', 'LOAD', bad))
        self.assertEqual(self.client.call('SCRIPT', 'EXISTS', hashlib.sha1(bad).hexdigest()), [0])
        for digest in (b'0'*40, b'123', b'g'*40):
            self.error(('EVALSHA', digest, 0), 'NOSCRIPT')
        for mode in ('SYNC', 'ASYNC'):
            source = b'return 29'
            digest = self.client.call('SCRIPT', 'LOAD', source)
            self.assertEqual(self.client.call('EVALSHA_RO', digest, 0), 29)
            self.assertEqual(self.client.call('SCRIPT', 'FLUSH', mode), 'OK')
            self.assertEqual(self.client.call('SCRIPT', 'EXISTS', digest), [0])
            self.error(('EVALSHA', digest, 0), 'NOSCRIPT')
        self.error(('SCRIPT', 'FLUSH', 'INVALID'))
        self.error(('SCRIPT', 'KILL'), 'NOTBUSY')
        self.assertIsInstance(self.client.call('SCRIPT', 'HELP'), list)

    def test_call_pcall_and_partial_error_effects(self):
        self.client.call('SET', 'typed', 'string')
        result = self.client.call('EVAL', "local e=redis.pcall('LPUSH','typed','x'); return {e.err,redis.call('GET','typed')}", 0)
        self.assertIn(b'WRONGTYPE', result[0])
        self.assertEqual(result[1], b'string')
        self.error(('EVAL', "redis.call('SET','before-error','kept'); redis.call('LPUSH','typed','bad'); redis.call('SET','after-error','bad')", 0), 'WRONGTYPE')
        self.assertEqual(self.client.call('MGET', 'before-error', 'after-error'), [b'kept', None])
        result = self.client.call('EVAL', "return {redis.status_reply('ready'),redis.error_reply('ERR deliberate'),redis.call('INCR','counter')}", 0)
        self.assertEqual(result[0], 'ready')
        self.assertIsInstance(result[1], ServerError)
        self.assertEqual(str(result[1]), 'ERR deliberate')
        self.assertEqual(result[2], 1)
        self.assertEqual(self.client.call('GET', 'counter'), b'1')

    def test_script_response_protocol_is_independent_of_client_protocol(self):
        self.client.call('HSET', 'protocol:hash', 'field', 'value')
        source = "redis.setresp(3); return redis.call('HGETALL',KEYS[1])"
        self.assertEqual(self.client.call('EVAL', source, 1, 'protocol:hash'), [b'field', b'value'])
        self.assertEqual(self.client.call('EVAL', 'return {double=1.25}', 0), b'1.25')
        self.client.call('HELLO', 3)
        self.assertEqual(self.client.call('EVAL', source, 1, 'protocol:hash'), {b'field': b'value'})
        self.assertEqual(self.client.call('EVAL', "return redis.call('HGETALL',KEYS[1])", 1, 'protocol:hash'), [b'field', b'value'])
        self.assertEqual(self.client.call('EVAL', 'redis.setresp(3); return {true,false}', 0), [True, False])
        self.assertEqual(self.client.call('EVAL', 'return {double=1.25}', 0), 1.25)
        for client_resp in (2, 3):
            self.client.call('HELLO', client_resp)
            for script_resp in (2, 3):
                prefix = '' if script_resp == 2 else 'redis.setresp(3); '
                false = None if script_resp == 2 else False if client_resp == 3 else 0
                true = True if script_resp == 3 and client_resp == 3 else 1
                for body, expected in (('return false', false), ('return true', true),
                                       ('return {false,true}', [false, true]), ('return nil', None)):
                    with self.subTest(client_resp=client_resp, script_resp=script_resp, body=body):
                        self.typed(self.client.call('EVAL', prefix+body, 0), expected)

    def test_read_only_script_variants_reject_mutations_and_special_effects(self):
        self.client.call('SET', 'ro:key', 'old')
        self.assertEqual(self.client.call('EVAL_RO', "return redis.call('GET',KEYS[1])", 1, 'ro:key'), b'old')
        for inner in ("redis.call('SET','ro:key','bad')", "redis.call('PUBLISH','channel','bad')",
                      "redis.call('SPUBLISH','channel','bad')", "redis.call('PFCOUNT','missing-hll')"):
            source = 'return '+inner
            digest = self.client.call('SCRIPT', 'LOAD', source)
            with self.subTest(inner=inner):
                self.error(('EVAL_RO', source, 0), 'read-only')
                self.error(('EVALSHA_RO', digest, 0), 'read-only')
        self.assertEqual(self.client.call('GET', 'ro:key'), b'old')

    def test_inner_acl_checks_actual_undeclared_keys_and_commands(self):
        self.client.call('SET', 'allow:key', 'yes')
        self.client.call('SET', 'deny:key', 'hidden')
        self.client.call('ACL', 'SETUSER', 'scripter', 'on', '>secret', '+eval', '+eval_ro', '+get', '+set', '~allow:*')
        client = Client(REFERENCE_PORT) if self.server is None else self.server.client()
        if self.server is None:
            self.addCleanup(client.close)
        client.call('AUTH', 'scripter', 'secret')
        self.assertEqual(client.call('EVAL', "return redis.call('GET','allow:key')", 0), b'yes')
        for inner in ("'GET','deny:key'", "'DEL','allow:key'"):
            for wrapper in ('call', 'pcall'):
                result = self.error(('EVAL', 'return redis.'+wrapper+'('+inner+')', 0), client=client)
                self.assertTrue(str(result).startswith('ERR ACL failure in script:'), repr(result))
        self.assertTrue(str(self.error(('GET', 'deny:key'), client=client)).startswith('NOPERM '))
        self.assertTrue(str(self.error(('EVAL', 'return 1', 1, 'deny:key'), client=client)).startswith('NOPERM '))
        self.assertEqual(self.client.call('GET', 'allow:key'), b'yes')

    def test_multi_keeps_script_error_prior_writes_and_following_commands(self):
        self.client.send_many([('MULTI',), ('EVAL', "redis.call('SET','tx:before','kept'); error('deliberate')", 0),
                               ('SET', 'tx:after', 'kept-too'), ('EXEC',)])
        self.assertEqual([self.client.reply() for _ in range(3)], ['OK', 'QUEUED', 'QUEUED'])
        result = self.client.reply()
        self.assertEqual(len(result), 2)
        self.assertIsInstance(result[0], ServerError)
        self.assertIn('deliberate', str(result[0]))
        self.assertEqual(result[1], 'OK')
        self.assertEqual(self.client.call('MGET', 'tx:before', 'tx:after'), [b'kept', b'kept-too'])

    def test_expiry_clock_is_frozen_inside_script(self):
        source = "redis.call('SET','script:expiry','v','PX',1000); local a=redis.call('PTTL','script:expiry'); for i=1,2500 do if redis.call('PTTL','script:expiry')~=a then error('expiry moved') end end; return {a,redis.call('GET','script:expiry')}"
        self.assertEqual(self.client.call('EVAL', source, 0), [1000, b'v'])
        self.client.call('PEXPIRE', 'script:expiry', 1)
        time.sleep(.02)
        self.assertIsNone(self.client.call('GET', 'script:expiry'))

    def test_sha1_and_signed_32_bit_helpers_match_independent_values(self):
        for length in (0, 1, 2, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 1024):
            payload = bytes((at*73+19) & 255 for at in range(length))
            with self.subTest(length=length):
                self.assertEqual(self.client.call('EVAL', 'return redis.sha1hex(ARGV[1])', 0, payload), hashlib.sha1(payload).hexdigest().encode())
        source = 'return {bit.band(0xf0,0x3c),bit.bor(0xf0,0x0f),bit.bxor(0xaa,0xff),bit.bnot(0),bit.lshift(1,31),bit.rshift(-1,31),bit.arshift(-1,7),bit.rol(1,31),bit.ror(1,1),bit.tohex(-1)}'
        self.assertEqual(self.client.call('EVAL', source, 0), [0x30, 255, 0x55, -1, -(1 << 31), 1, -1, -(1 << 31), -(1 << 31), b'ffffffff'])

    def test_json_unicode_null_and_collection_mapping(self):
        document = b'{"text":"\\uD83D\\uDE80","nil":null,"list":[true,false,1.5],"quoted":"a\\n\\\"b"}'
        source = "local t=cjson.decode(ARGV[1]); return {t.text,t['nil']==cjson.null and 1 or 0,cjson.encode(t)}"
        result = self.client.call('EVAL', source, 0, document)
        self.assertEqual(result[:2], ['🚀'.encode(), 1])
        self.assertEqual(json.loads(result[2]), json.loads(document))
        for bad in (b'{"x":}', b'[1,]', b'"\\uD800"', b'{"x":1} trailing'):
            self.error(('EVAL', 'return cjson.decode(ARGV[1])', 0, bad))
        self.healthy()

    def test_messagepack_golden_values_and_binary_numeric_roundtrip(self):
        golden = b'\x96\xa3a\x00\xff\xcd\x01\x00\xff\xc3\xc2\xcb'+struct.pack('>d', 1.25)
        source = 'local t=cmsgpack.unpack(ARGV[1]); return {t[1],t[2],t[3],t[4] and 1 or 0,t[5] and 1 or 0,tostring(t[6])}'
        self.assertEqual(self.client.call('EVAL', source, 0, golden), [b'a\x00\xff', 256, -1, 1, 0, b'1.25'])
        source = 'return cmsgpack.pack({ARGV[1],-33,65536,1.25,true,false,9007199254740991})'
        payload = b'\x00\xff\r\n'
        result = self.client.call('EVAL', source, 0, payload)
        self.assertEqual(unpack_message(result), [payload, -33, 65536, 1.25, True, False, 9007199254740991])
        self.assertIsNone(self.client.call('EVAL', 'return cmsgpack.unpack(ARGV[1])', 0, b''))
        for bad in (b'\xda\x00', b'\x91', b'\xc1'):
            with self.subTest(invalid_frame=bad):
                self.error(('EVAL', 'return cmsgpack.unpack(ARGV[1])', 0, bad))
        self.healthy()

    def actual_inner_tracking(self, command):
        writer, tracker = self.connection(), self.connection()
        tracker.call('HELLO', 3)
        tracker.call('CLIENT', 'TRACKING', 'ON', 'NOLOOP')
        writer.call('MSET', 'tracked:declared', 'a', 'tracked:actual', 'b')
        source = "return redis.call('GET','tracked:actual')"
        self.assertEqual(tracker.call(command, source, 1, 'tracked:declared'), b'b')
        writer.call('SET', 'tracked:declared', 'changed')
        self.assertFalse(tracker.available(.03))
        writer.call('SET', 'tracked:actual', 'changed')
        frame = tracker.read()
        self.assertIsInstance(frame, Push)
        self.assertEqual(frame, [b'invalidate', [b'tracked:actual']])
        tracker.call('EVAL', "redis.call('GET','tracked:actual'); return redis.call('SET','tracked:actual','own')", 0)
        self.assertEqual(tracker.pushes, [])
        self.assertFalse(tracker.available(.03))
        tracker.call('CLIENT', 'TRACKING', 'OFF')
        tracker.call('CLIENT', 'TRACKING', 'ON', 'OPTIN')
        tracker.call('CLIENT', 'CACHING', 'YES')
        self.assertEqual(tracker.call(command, source, 0), b'own')
        writer.call('SET', 'tracked:actual', 'optin-change')
        frame = tracker.read()
        self.assertIsInstance(frame, Push)
        self.assertEqual(frame, [b'invalidate', [b'tracked:actual']])
        self.assertEqual(tracker.call(command, source, 0), b'optin-change')
        writer.call('SET', 'tracked:actual', 'not-opted-in')
        self.assertEqual(tracker.pushes, [])
        self.assertFalse(tracker.available(.03))

    def test_eval_tracks_actual_inner_reads_and_respects_noloop_optin(self):
        self.actual_inner_tracking('EVAL')

    def test_eval_ro_tracks_actual_inner_reads_and_respects_noloop_optin(self):
        self.actual_inner_tracking('EVAL_RO')


class Integration(Fixture):
    def test_attributes_are_ignored_by_the_inner_resp3_parser(self):
        self.client.call('DEBUG', 'SET-DISABLE-DENY-SCRIPTS', 1)
        source = "redis.setresp(3);return redis.call('DEBUG','PROTOCOL','attrib')"
        self.assertEqual(self.client.call('EVAL', source, 0), b'Some real reply following the attribute')
        self.client.call('DEBUG', 'SET-DISABLE-DENY-SCRIPTS', 0)
        self.error(('EVAL', source, 0), 'not allowed')
        self.healthy()

    def test_explicit_deprecated_apis_preserve_environment_and_gc_lifetimes(self):
        server = self.new_server(('--lua-enable-deprecated-api', 'yes'))
        client = server.client()
        source = "local f=function()return value end;local e={value=7};setfenv(f,e);return {f(),getfenv(f)==e,type(newproxy(true))}"
        self.assertEqual(client.call('EVAL', source, 0), [7, 1, b'userdata'])
        source = "local n=0;do local p=newproxy(true);getmetatable(p).__gc=function()n=n+1 end end;collectgarbage('collect');return n"
        self.assertEqual(client.call('EVAL', source, 0), 1)
        self.error(('CONFIG', 'SET', 'lua-enable-deprecated-api', 'no'), 'immutable', client)
        self.healthy(client)

    def test_large_argument_vectors_and_invalid_inner_values_are_atomic(self):
        values = [b'absent-boundary']*4097
        self.assertEqual(self.client.call('EVAL', 'return {#KEYS,#ARGV,KEYS[4097]}', len(values), *values), [len(values), 0, values[-1]])
        self.assertEqual(self.client.call('EVAL', 'return {#KEYS,#ARGV,ARGV[4097]}', 0, *values), [0, len(values), values[-1]])
        source = "return redis.call('EXISTS',unpack(ARGV))"
        self.assertEqual(self.client.call('EVAL', source, 0, *values), 0)
        for value in ('{}', 'true', 'function() end'):
            with self.subTest(value=value):
                self.error(('EVAL', "return redis.call('SET','boundary:unexpected',"+value+")", 0), 'arguments')
        self.assertIsNone(self.client.call('GET', 'boundary:unexpected'))
        self.healthy()

    def test_first_inner_oom_keeps_class_and_later_effect_sequence_can_finish(self):
        self.client.call('SET', 'oom:existing', 'kept')
        self.limit('maxmemory', 1)
        self.client.call('CONFIG', 'SET', 'maxmemory-policy', 'noeviction')
        self.assertGreater(int(info(self.client, 'memory')['used_memory']), 1)
        result = self.error(('EVAL', "return redis.call('SET','oom:rejected','bad')", 0))
        self.assertTrue(str(result).startswith('OOM '), repr(result))
        self.assertIsNone(self.client.call('GET', 'oom:rejected'))
        source = "local ok,x=pcall(function() return redis.call('SET','oom:rejected','bad') end); return {ok,type(x),x}"
        result = self.client.call('EVAL', source, 0)
        self.assertEqual(result[:2], [None, b'string'])
        self.assertTrue(result[2].startswith(b'OOM '))
        self.assertEqual(self.client.call('EVAL', "redis.call('DEL','oom:existing'); return redis.call('SET','oom:after','kept')", 0), 'OK')
        self.client.call('CONFIG', 'SET', 'maxmemory', 0)
        self.assertEqual(self.client.call('MGET', 'oom:existing', 'oom:rejected', 'oom:after'), [None, None, b'kept'])
        self.healthy()

    def test_supported_no_write_header_preserves_source_digest_and_policy(self):
        source = b'#!lua flags=no-writes\nreturn redis.call("GET",KEYS[1])'
        self.client.call('SET', 'header:key', 'v')
        digest = self.client.call('SCRIPT', 'LOAD', source)
        self.assertEqual(digest, hashlib.sha1(source).hexdigest().encode())
        self.assertEqual(self.client.call('EVALSHA', digest, 1, 'header:key'), b'v')
        self.error(('EVAL', b'#!lua flags=no-writes\nreturn redis.call("SET","header:key","bad")', 0), 'read-only')
        for flag in (b'no-writes', b'allow-oom', b'allow-stale', b'no-cluster', b'allow-cross-slot-keys',
                     b'no-writes,allow-oom,allow-stale,no-cluster,allow-cross-slot-keys'):
            with self.subTest(flag=flag):
                flagged = b'#!lua flags='+flag+b'\nreturn 31'
                digest = self.client.call('SCRIPT', 'LOAD', flagged)
                self.assertEqual(digest, hashlib.sha1(flagged).hexdigest().encode())
                self.assertEqual(self.client.call('EVALSHA_RO', digest, 0), 31)
        for header in (b'#!python', b'#!lua flags=unknown', b'#!lua unknown=value'):
            self.error(('SCRIPT', 'LOAD', header+b'\nreturn 1'))
        self.assertEqual(self.client.call('GET', 'header:key'), b'v')

    def test_sandbox_denies_process_files_globals_and_binary_loaders(self):
        blocked = ('loadfile', 'dofile', 'require', 'package', 'io', 'debug', 'getfenv', 'setfenv', 'newproxy')
        source = 'local names={'+','.join(json.dumps(name) for name in blocked)+'}; for _,name in ipairs(names) do local ok,v=pcall(function() return _G[name] end); if ok and v~=nil then return name end end; return "blocked"'
        self.assertEqual(self.client.call('EVAL', source, 0), b'blocked')
        self.assertEqual(self.client.call('EVAL', 'return {type(os.clock),type(os.execute),type(os.exit),type(os.time),type(os.date)}', 0),
                         [b'function', b'nil', b'nil', b'nil', b'nil'])
        self.error(('EVAL', 'forbidden_new_global=1; return 1', 0), 'readonly')
        self.error(('EVAL', 'return forbidden_new_global', 0), 'global')
        for source in (b'\x1bLua\x55\x00invalid', b'\x1bLJ\x02invalid'):
            self.error(('EVAL', source, 0))
            self.error(('SCRIPT', 'LOAD', source))
        source = "return string.dump(function() return 7 end)"
        dumped = self.client.call('EVAL', source, 0)
        self.assertTrue(dumped.startswith(b'\x1bLua\x51'))
        self.error(('EVAL', dumped, 0))
        self.error(('SCRIPT', 'LOAD', dumped))
        source = "local f,e=loadstring(ARGV[1]); return {type(f),type(e)}"
        self.assertEqual(self.client.call('EVAL', source, 0, dumped), [b'nil', b'string'])
        source = "local sent=false; local f,e=load(function() if not sent then sent=true; return ARGV[1] end end); return {type(f),type(e)}"
        self.assertEqual(self.client.call('EVAL', source, 0, dumped), [b'nil', b'string'])
        self.assertEqual(self.client.call('EVAL', "local t=setmetatable({}, {__gc=function() redis.call('SET','finalized','bad') end}); t=nil; collectgarbage('collect'); return 1", 0), 1)
        self.assertIsNone(self.client.call('GET', 'finalized'))
        self.healthy()

    def test_builtin_tables_are_readonly_across_invocations(self):
        for library in ('math', 'redis', 'cjson', 'cmsgpack', 'struct', 'bit', 'table', 'string', 'coroutine', 'os', '_G'):
            for operation in (library+'.saved=19', "rawset("+library+",'saved',19)", 'setmetatable('+library+',{})'):
                with self.subTest(operation=operation):
                    self.error(('EVAL', operation+'; return 1', 0), 'readonly')
        self.error(('EVAL', 'table.insert=nil; return 1', 0), 'readonly')
        self.assertEqual(self.client.call('EVAL', 'local t={}; table.insert(t,7); return t', 0), [7])
        self.assertEqual(self.client.call('EVAL', 'return {math.saved==nil and 1 or 0,redis.saved==nil and 1 or 0,cjson.saved==nil and 1 or 0}', 0), [1, 1, 1])

    def test_library_configuration_persists_until_script_flush(self):
        self.assertEqual(self.client.call('EVAL', 'return cjson.encode_number_precision(5)', 0), 5)
        self.assertEqual(self.client.call('EVAL', 'return cjson.encode_number_precision()', 0), 5)
        self.assertEqual(self.client.call('EVAL', 'return cjson.encode(1.23456789)', 0), b'1.2346')
        self.client.call('SCRIPT', 'FLUSH', 'SYNC')
        self.assertEqual(self.client.call('EVAL', 'return cjson.encode_number_precision()', 0), 14)

    def test_text_loaders_coroutines_and_mutable_local_metatables(self):
        self.assertEqual(self.client.call('EVAL', "return loadstring('return 9')()", 0), 9)
        source = "local chunks={'return ', '11'}; return load(function() return table.remove(chunks,1) end)()"
        self.assertEqual(self.client.call('EVAL', source, 0), 11)
        source = "local co=coroutine.create(function() coroutine.yield('paused'); return 'done' end); local a,b=coroutine.resume(co); local s=coroutine.status(co); local c,d=coroutine.resume(co); return {a,b,s,c,d,coroutine.status(co)}"
        self.assertEqual(self.client.call('EVAL', source, 0), [1, b'paused', b'suspended', 1, b'done', b'dead'])
        source = "local mt={__index=function(t,k) return 'fallback:'..k end}; local t=setmetatable({},mt); rawset(t,'value',7); return {rawget(t,'value'),t.missing,getmetatable(t)==mt and 1 or 0,type(collectgarbage('count')),os.clock()>=0 and 1 or 0}"
        self.assertEqual(self.client.call('EVAL', source, 0), [7, b'fallback:missing', 1, b'number', 1])

    def test_unsafe_and_reentrant_inner_commands_reject_without_context_damage(self):
        commands = (('EVAL', 'return 1', 0), ('SCRIPT', 'FLUSH'), ('MULTI',), ('EXEC',),
                    ('CLIENT', 'RESET'), ('CONFIG', 'GET', '*'), ('SAVE',))
        self.client.call('SET', 'retained', 'yes')
        for arguments in commands:
            with self.subTest(command=arguments):
                source = "return redis.call(unpack(ARGV))"
                self.error(('EVAL', source, 0, *arguments), 'not allowed')
        self.assertEqual(self.client.call('GET', 'retained'), b'yes')
        self.healthy()

    def test_script_safe_keyspace_commands_keep_client_database_and_never_block(self):
        self.client.call('SET', 'retained', 'yes')
        source = "redis.call('SELECT',1); redis.call('SET','selected:key','db1'); return redis.call('KEYS','selected:*')"
        self.assertEqual(self.client.call('EVAL', source, 0), [b'selected:key'])
        self.assertEqual(self.client.call('GET', 'retained'), b'yes')
        self.assertIsNone(self.client.call('GET', 'selected:key'))
        self.assertIsNone(self.client.call('EVAL', "return redis.call('GET','selected:key')", 0))
        self.client.call('SELECT', 1)
        self.assertEqual(self.client.call('GET', 'selected:key'), b'db1')
        self.client.call('SELECT', 0)
        self.assertIsNone(self.client.call('EVAL', "return redis.call('BLPOP','blocked',0)", 0))
        self.client.call('LPUSH', 'blocked', 'ready')
        self.assertEqual(self.client.call('EVAL', "return redis.call('BLPOP','blocked',0)", 0), [b'blocked', b'ready'])
        self.assertEqual(self.client.call('EVAL', "return redis.call('MIGRATE','127.0.0.1',1,'missing-key',0,1)", 0), 'NOKEY')
        self.assertEqual(self.client.call('EVAL', "return redis.call('FLUSHDB')", 0), 'OK')
        self.assertIsNone(self.client.call('GET', 'retained'))
        self.client.call('SELECT', 1)
        self.assertEqual(self.client.call('GET', 'selected:key'), b'db1')
        self.client.call('SELECT', 0)
        self.healthy()

    def test_output_memory_depth_and_cycle_failures_cleanup(self):
        self.limit('lua-max-output', 4096)
        self.error(('EVAL', 'return string.rep("x",8192)', 0))
        self.healthy()
        self.client.call('CONFIG', 'SET', 'lua-max-output', 1 << 20)
        self.limit('lua-max-memory', 128 << 10)
        self.error(('EVAL', 'local t={}; for i=1,20000 do t[i]=string.rep("x",100) end; return #t', 0))
        self.healthy()
        for source in ('local t={}; t[1]=t; return t', 'local t={}; t.t=t; return cjson.encode(t)'):
            self.error(('EVAL', source, 0))
            self.healthy()
        nested = self.client.call('EVAL', 'local t={}; for i=1,80 do t={t} end; return t', 0)
        for unused in range(80):
            self.assertIsInstance(nested, list)
            self.assertEqual(len(nested), 1)
            nested = nested[0]
        self.assertEqual(nested, [])
        self.assertEqual(self.client.call('EVAL', 'local t={}; t[1]=t; return cmsgpack.pack(t)', 0), b'\x91'*16+b'\xc0')
        self.healthy()
        self.client.call('CONFIG', 'SET', 'lua-max-memory', 4096)
        self.error(('EVAL', 'return 1', 0))
        self.client.call('CONFIG', 'SET', 'lua-max-memory', 128 << 10)
        self.healthy()

    def test_bridge_limit_is_sticky_and_prevents_later_mutation(self):
        self.client.call('SET', 'large-response', b'z'*(32 << 10))
        self.limit('lua-max-bridge-memory', 4096)
        source = "pcall(function() redis.call('GET','large-response') end); redis.call('SET','after-overflow','bad'); return 1"
        self.error(('EVAL', source, 0))
        self.assertIsNone(self.client.call('GET', 'after-overflow'))
        self.healthy()
        self.client.call('SET', 'repeated-response', b'z'*1024)
        source = "local n=0; for i=1,20 do n=n+#redis.call('GET','repeated-response') end; return n"
        self.assertEqual(self.client.call('EVAL', source, 0), 20*1024)
        self.assertIsNone(self.client.call('GET', 'after-overflow'))
        self.healthy()

    def test_cache_budget_rejects_growth_without_losing_loaded_source(self):
        self.limit('lua-max-cache-memory', 8192)
        digest = self.client.call('SCRIPT', 'LOAD', b'return 41')
        self.error(('SCRIPT', 'LOAD', b'return 1'+b' '*(16 << 10)))
        self.assertEqual(self.client.call('EVALSHA', digest, 0), 41)
        self.client.call('SCRIPT', 'FLUSH', 'ASYNC')
        self.assertEqual(self.client.call('SCRIPT', 'EXISTS', digest), [0])
        self.healthy()

    def test_eval_source_lru_is_bounded_and_loaded_source_stays_pinned(self):
        pinned = self.client.call('SCRIPT', 'LOAD', 'return 9001')
        sources = [b'return '+str(value).encode() for value in range(510)]
        self.assertEqual(self.client.pipeline([('EVAL', source, 0) for source in sources]), list(range(510)))
        digests = [hashlib.sha1(source).hexdigest() for source in (sources[0], sources[-1])]
        self.assertEqual(self.client.call('SCRIPT', 'EXISTS', pinned, *digests), [1, 0, 1])
        self.assertEqual(int(info(self.client, 'stats')['evicted_scripts']), 10)
        self.client.call('CONFIG', 'RESETSTAT')
        self.assertEqual(int(info(self.client, 'stats')['evicted_scripts']), 0)
        self.assertEqual(self.client.call('SCRIPT', 'EXISTS', pinned, *digests), [1, 0, 1])
        self.assertEqual(self.client.call('EVALSHA', pinned, 0), 9001)

    def test_cache_memory_accounting_follows_real_source_ownership(self):
        before = info(self.client, 'memory')
        self.assertEqual(int(before['number_of_cached_scripts']), 0)
        source = b'return 53'+b' '*2048
        digest = self.client.call('SCRIPT', 'LOAD', source)
        retained = info(self.client, 'memory')
        self.assertEqual(int(retained['number_of_cached_scripts']), 1)
        self.assertGreaterEqual(int(retained['used_memory_scripts_eval'])-int(before['used_memory_scripts_eval']), len(source))
        self.assertEqual(self.client.call('EVALSHA', digest, 0), 53)
        self.assertEqual(int(info(self.client, 'memory')['number_of_cached_scripts']), 1)
        self.client.call('SCRIPT', 'FLUSH', 'SYNC')
        after = info(self.client, 'memory')
        self.assertEqual(int(after['number_of_cached_scripts']), 0)
        self.assertEqual(int(after['used_memory_scripts']), 0)

    def test_reply_line_content_cannot_inject_following_protocol_frames(self):
        for function in ('status_reply', 'error_reply'):
            source = 'return redis.'+function+'(ARGV[1])'
            replies = self.client.pipeline([('EVAL', source, 0, b'line\r\n:999\r\n'), ('PING',)])
            self.assertEqual(replies[1], 'PONG')
            self.assertEqual(len(replies), 2)
            self.assertFalse(self.client.available(.01))

        for source in ('return redis.error_reply(ARGV[1])', 'error(redis.error_reply(ARGV[1]),0)'):
            with self.subTest(binary_error_source=source):
                result, following = self.client.pipeline([('EVAL', source, 0, b'ERR left\x00right'), ('PING', 'after-binary-error')])
                self.assertIsInstance(result, ServerError)
                expected = 'ERR left'
                if source.startswith('error('):
                    expected += ' script: '+hashlib.sha1(source.encode()).hexdigest()+', on @user_script:1.'
                self.assertEqual(str(result), expected)
                self.assertEqual(following, b'after-binary-error')
                self.assertFalse(self.client.available(.01))

    def test_aof_replays_actual_partial_effects_and_nested_multi(self):
        instance = self.new_server(('--appendonly', 'yes', '--appendfsync', 'always'))
        client = instance.client()
        digest = client.call('SCRIPT', 'LOAD', 'return 91')
        self.error(('EVAL', "redis.call('SET','aof:partial','yes'); redis.call('PEXPIRE','aof:partial',60000); error('stop')", 0), 'stop', client)
        client.send_many([('MULTI',), ('EVAL', "redis.call('SET','aof:inside','kept'); error('tx-stop')", 0),
                          ('SET', 'aof:after', 'kept-too'), ('EXEC',)])
        self.assertEqual([client.reply() for _ in range(3)], ['OK', 'QUEUED', 'QUEUED'])
        result = client.reply()
        self.assertIsInstance(result[0], ServerError)
        self.assertEqual(result[1], 'OK')
        self.assertGreater(client.call('PTTL', 'aof:partial'), 0)
        expiry = client.call('PEXPIRETIME', 'aof:partial')
        client.send('SHUTDOWN', 'NOSAVE')
        self.assertEqual(instance.process.wait(timeout=15), 0)
        instance.stop()
        instance.start()
        client = instance.client()
        self.assertEqual(client.call('MGET', 'aof:partial', 'aof:inside', 'aof:after'), [b'yes', b'kept', b'kept-too'])
        self.assertGreater(client.call('PTTL', 'aof:partial'), 0)
        self.assertEqual(client.call('PEXPIRETIME', 'aof:partial'), expiry)
        self.error(('EVALSHA', digest, 0), 'NOSCRIPT', client)

    def test_worker_fence_and_inner_lcs_remain_synchronous(self):
        instance = self.new_server(('--keyspace-threads', '2'), workers=2)
        client = instance.client()
        payload = b'a'*1024
        before = info(client)
        self.assertEqual(client.pipeline([('SET', 'worker:a', payload), ('SET', 'worker:b', payload),
                                          ('EVAL', "return {redis.call('GET',KEYS[1]),redis.call('LCS',KEYS[1],KEYS[2],'LEN'),redis.call('SET','worker:out','done')}", 2, 'worker:a', 'worker:b')]),
                         ['OK', 'OK', [payload, 1024, 'OK']])
        after = info(client)
        self.assertEqual(int(after['keyspace_jobs_submitted'])-int(before['keyspace_jobs_submitted']), 2)
        self.assertEqual(after['keyspace_jobs_pending'], '0')
        self.assertEqual(after['compute_jobs_submitted'], before['compute_jobs_submitted'])
        self.assertEqual(client.call('GET', 'worker:out'), b'done')

    def test_same_client_invalidation_follows_outer_reply_and_is_not_inner_result(self):
        client = self.server.client()
        client.call('HELLO', 3)
        client.call('CLIENT', 'TRACKING', 'ON')
        self.client.call('SET', 'self-tracked', 'old')
        client.call('GET', 'self-tracked')
        client.send('EVAL', "local r=redis.call('SET','self-tracked','new'); return {r,redis.call('GET','self-tracked')}", 0)
        self.assertEqual(client.read(), ['OK', b'new'])
        self.assertEqual(client.read(), Push([b'invalidate', [b'self-tracked']]))
        self.assertEqual(client.call('PING'), 'PONG')

    def test_notifications_and_blocked_pop_observe_completed_script(self):
        subscriber, waiter = self.server.client(), self.server.client()
        self.client.call('CONFIG', 'SET', 'notify-keyspace-events', 'E$')
        subscriber.call('SUBSCRIBE', '__keyevent@0__:set')
        waiter.send_many([('BLPOP', 'script:waiting', 0), ('GET', 'script:marker')])
        wait_for(lambda: info(self.client, 'clients').get('blocked_clients') == '1', label='script observer blocked')
        source = "redis.call('RPUSH','script:waiting','first'); local n=redis.call('LLEN','script:waiting'); redis.call('SET','script:marker','finished'); return n"
        self.assertEqual(self.client.call('EVAL', source, 0), 1)
        self.assertEqual(waiter.reply(), [b'script:waiting', b'first'])
        self.assertEqual(waiter.reply(), b'finished')
        self.assertEqual(subscriber.read(), [b'message', b'__keyevent@0__:set', b'script:marker'])
        self.healthy()


class Busy(Fixture):
    def setUp(self):
        super().setUp()
        self.client.call('CONFIG', 'SET', 'busy-reply-threshold', 1)
        self.busy_password = None
        self.addCleanup(self.unstick)

    def unstick(self):
        if self.server.process is None or self.server.process.poll() is not None:
            return
        client = None
        try:
            client = Client(self.server.port, timeout=1)
            if self.busy_password is not None:
                client.call('AUTH', self.busy_password)
            client.send('SHUTDOWN', 'NOSAVE')
            self.server.process.wait(timeout=2)
        except (OSError, EOFError, ServerError, TimeoutError, subprocess.TimeoutExpired):
            pass
        finally:
            if client is not None:
                client.close()

    def busy_client(self):
        client = self.server.client(timeout=5)
        wait_for(lambda: self.is_busy(client), timeout=5, label='script BUSY threshold')
        return client

    def is_busy(self, client):
        client.send('PING')
        result = client.reply()
        return isinstance(result, ServerError) and str(result).startswith('BUSY ')

    def kill(self, client):
        self.assertEqual(client.call('SCRIPT', 'KILL'), 'OK')
        result = self.client.reply()
        self.assertIsInstance(result, ServerError)
        self.assertIn('kill', str(result).casefold())
        self.healthy()

    def test_transaction_started_while_busy_discards_rejected_commands(self):
        self.client.call('SET', 'busy:transaction', 1)
        self.client.send('EVAL', 'while true do end', 0)
        control = self.busy_client()
        actor = self.server.client()
        self.assertEqual(actor.call('MULTI'), 'OK')
        self.error(('INCR', 'busy:transaction'), 'BUSY', actor)
        self.kill(control)
        self.assertEqual(actor.call('INCR', 'busy:transaction'), 'QUEUED')
        self.error(('EXEC',), 'previous errors', actor)
        self.assertEqual(self.client.call('GET', 'busy:transaction'), b'1')
        self.assertEqual(actor.call('PING', 'after-abort'), b'after-abort')

    def test_exec_while_busy_aborts_and_leaves_transaction_state(self):
        self.client.call('SET', 'busy:transaction', 1)
        actor = self.server.client()
        self.assertEqual(actor.call('MULTI'), 'OK')
        self.assertEqual(actor.call('INCR', 'busy:transaction'), 'QUEUED')
        self.client.send('EVAL', 'while true do end', 0)
        control = self.busy_client()
        self.error(('EXEC',), 'EXECABORT Transaction discarded because of: BUSY', actor)
        self.assertEqual(actor.call('MULTI'), 'OK')
        self.assertEqual(actor.call('DISCARD'), 'OK')
        self.assertEqual(actor.call('UNWATCH'), 'OK')
        self.kill(control)
        self.assertEqual(self.client.call('GET', 'busy:transaction'), b'1')
        self.assertEqual(actor.call('PING', 'after-abort'), b'after-abort')

    def suppressed_control(self, mode):
        client = self.server.client(timeout=5)
        marker = 'suppression:'+mode+':'+str(id(client))
        prefix = marker.encode()
        if mode == 'OFF':
            commands = [('PING', prefix), ('CLIENT', 'REPLY', 'OFF'), ('SET', marker, 'ready')]
        else:
            commands = [('CLIENT', 'REPLY', 'SKIP'), ('SET', marker, 'ready'),
                        ('PING', prefix), ('CLIENT', 'REPLY', 'SKIP')]
        client.send_many(commands)
        wait_for(lambda: self.client.call('GET', marker) == b'ready', label='reply suppression prepared')
        return client, prefix

    def source_suppressed_while_busy(self, mode):
        source = self.server.client(timeout=5)
        commands = [('PING', 'source-prefix'), ('CLIENT', 'REPLY', mode),
                    ('EVAL', "local v=redis.call('ECHO','captured'); while true do end", 0)]
        if mode == 'OFF':
            commands.append(('CLIENT', 'REPLY', 'ON'))
        commands.append(('PING', 'source-after'))
        source.send_many(commands)
        observer = self.busy_client()
        self.assertEqual(observer.call('SCRIPT', 'KILL'), 'OK')
        self.assertEqual(source.reply(), b'source-prefix')
        if mode == 'OFF':
            self.assertEqual(source.reply(), 'OK')
        self.assertEqual(source.reply(), b'source-after')
        self.assertFalse(source.available(.02))
        self.healthy()

    def signal_readonly(self, sig):
        self.client.send('EVAL', 'while true do end', 0)
        self.busy_client()
        os.kill(self.server.process.pid, sig)
        self.assertEqual(self.server.process.wait(timeout=5), 0)
        logs = (self.server.directory/'server.log').read_text(errors='replace')
        self.assertIn('User requested shutdown...', logs)
        self.assertIn('Eski is now ready to exit, bye bye...', logs)
        self.server.stop()

    def test_source_reply_off_and_skip_preserve_finite_script_effects(self):
        client = self.server.client()
        client.send_many([('CLIENT', 'REPLY', 'OFF'),
                          ('EVAL', "return redis.call('SET','script:off','kept')", 0),
                          ('CLIENT', 'REPLY', 'ON'), ('PING', 'after-off'),
                          ('CLIENT', 'REPLY', 'SKIP'),
                          ('EVAL', "return redis.call('SET','script:skip','kept')", 0), ('PING', 'after-skip')])
        self.assertEqual([client.reply() for _ in range(3)], ['OK', b'after-off', b'after-skip'])
        self.assertEqual(self.client.call('MGET', 'script:off', 'script:skip'), [b'kept', b'kept'])
        self.assertFalse(client.available(.02))

    def test_source_reply_off_suppresses_killed_script_and_preserves_prefix(self):
        self.source_suppressed_while_busy('OFF')

    def test_source_reply_skip_suppresses_killed_script_and_preserves_prefix(self):
        self.source_suppressed_while_busy('SKIP')

    def test_other_client_skip_consumes_one_busy_response_and_preserves_prefix(self):
        control, prefix = self.suppressed_control('SKIP')
        self.client.send('EVAL', 'while true do end', 0)
        observer = self.busy_client()
        control.send_many([('PING', 'suppressed'), ('PING', 'visible')])
        self.assertEqual(control.reply(), prefix)
        result = control.reply()
        self.assertIsInstance(result, ServerError)
        self.assertTrue(str(result).startswith('BUSY '))
        self.assertFalse(control.available(.02))
        self.kill(observer)
        self.assertEqual(control.call('PING', 'after-skip'), b'after-skip')

    def test_other_client_reply_off_auth_and_kill_change_state_without_leaks(self):
        self.client.call('ACL', 'SETUSER', 'quiet', 'on', '>secret', '+ping', '+script|kill', '+client|reply')
        control, prefix = self.suppressed_control('OFF')
        self.client.send('EVAL', 'while true do end', 0)
        self.busy_client()
        control.send_many([('PING', 'suppressed'), ('AUTH', 'quiet', 'secret'), ('SCRIPT', 'KILL')])
        result = self.client.reply()
        self.assertIsInstance(result, ServerError)
        self.assertIn('kill', str(result).casefold())
        control.send_many([('CLIENT', 'REPLY', 'ON'), ('PING', 'after-off')])
        self.assertEqual([control.reply() for _ in range(3)], [prefix, 'OK', b'after-off'])
        self.assertFalse(control.available(.02))
        self.healthy()

    def test_other_client_skip_auth_or_kill_runs_once_without_reply(self):
        self.client.call('ACL', 'SETUSER', 'skipauth', 'on', '>secret', '+ping', '+script|kill')
        for skipped in ('AUTH', 'KILL'):
            with self.subTest(skipped=skipped):
                control, prefix = self.suppressed_control('SKIP')
                self.client.send('EVAL', 'while true do end', 0)
                self.busy_client()
                if skipped == 'AUTH':
                    control.send_many([('AUTH', 'skipauth', 'secret'), ('PING', 'visible')])
                    self.assertEqual(control.reply(), prefix)
                    result = control.reply()
                    self.assertIsInstance(result, ServerError)
                    self.assertTrue(str(result).startswith('BUSY '))
                    self.assertFalse(control.available(.02))
                    self.kill(control)
                else:
                    control.send('SCRIPT', 'KILL')
                    result = self.client.reply()
                    self.assertIsInstance(result, ServerError)
                    self.assertIn('kill', str(result).casefold())
                    self.assertEqual(control.reply(), prefix)
                self.assertEqual(control.call('PING', 'after-control'), b'after-control')
                self.assertFalse(control.available(.02))

    def test_pending_sigterm_cancels_readonly_script_then_shuts_down_normally(self):
        self.signal_readonly(signal.SIGTERM)

    def test_pending_sigint_cancels_readonly_script_then_shuts_down_normally(self):
        self.signal_readonly(signal.SIGINT)

    def test_first_signal_after_write_waits_for_authorized_nosave_escape(self):
        self.client.send('EVAL', "redis.call('SET','signal:write','kept'); while true do end", 0)
        control = self.busy_client()
        os.kill(self.server.process.pid, signal.SIGTERM)
        self.error(('SCRIPT', 'KILL'), 'UNKILLABLE', control)
        self.error(('PING',), 'BUSY', control)
        self.assertIsNone(self.server.process.poll())
        control.send('SHUTDOWN', 'NOSAVE')
        self.assertEqual(self.server.process.wait(timeout=5), 0)
        self.server.stop()

    def test_second_sigint_forces_exit_one_after_write(self):
        self.client.send('EVAL', "redis.call('SET','signal:write','kept'); while true do end", 0)
        control = self.busy_client()
        os.kill(self.server.process.pid, signal.SIGINT)
        self.error(('SCRIPT', 'KILL'), 'UNKILLABLE', control)
        self.assertIsNone(self.server.process.poll())
        os.kill(self.server.process.pid, signal.SIGINT)
        self.assertEqual(self.server.process.wait(timeout=5), 1)
        self.server.stop(expected_exit=1)

    def test_read_only_busy_loop_can_be_killed_from_new_authenticated_client(self):
        self.client.call('ACL', 'SETUSER', 'killer', 'on', '>secret', '+ping', '+script|kill')
        self.client.send('EVAL', 'while true do end', 0)
        client = self.busy_client()
        self.assertEqual(client.call('AUTH', 'killer', 'secret'), 'OK')
        self.kill(client)

    def test_busy_service_authenticates_new_clients_before_control(self):
        self.client.call('ACL', 'SETUSER', 'default', '>busy-secret')
        self.busy_password = 'busy-secret'
        self.client.send('EVAL', 'while true do end', 0)
        client = self.server.client(timeout=5)
        self.error(('SCRIPT', 'KILL'), 'NOAUTH', client)
        self.error(('AUTH', 'wrong-secret'), 'WRONGPASS', client)
        self.assertEqual(client.call('AUTH', 'busy-secret'), 'OK')
        self.kill(client)

    def test_pcall_and_xpcall_cannot_swallow_kill(self):
        for source in ('while true do pcall(function() while true do end end) end',
                       'while true do xpcall(function() while true do end end,function(e) return e end) end'):
            with self.subTest(source=source):
                self.client.send('EVAL', source, 0)
                self.kill(self.busy_client())

    def test_source_disconnect_does_not_lose_busy_lifetime(self):
        source = self.server.client()
        source.send('EVAL', 'while true do end', 0)
        observer = self.busy_client()
        source.close()
        replacement = self.server.client()
        self.error(('PING',), 'BUSY', replacement)
        self.assertEqual(observer.call('SCRIPT', 'KILL'), 'OK')
        def ready():
            replacement.send('PING')
            return replacement.reply() == 'PONG'
        wait_for(ready, label='dead-source kill cleanup')
        self.healthy(replacement)

    def test_busy_activity_and_source_completion_refresh_idle_timeout(self):
        self.client.call('CONFIG', 'SET', 'timeout', 1)
        old = self.server.client(timeout=5)
        self.assertEqual(old.call('PING'), 'PONG')
        self.client.send('EVAL', 'while true do end', 0)
        active = self.busy_client()
        started = time.monotonic()
        recent = None
        for phase in range(2):
            deadline = started+(phase+1)*1.15
            while time.monotonic() < deadline:
                self.error(('PING',), 'BUSY', active)
                if recent is not None:
                    self.error(('PING',), 'BUSY', recent)
                time.sleep(.03)
            if phase == 0:
                recent = self.server.client(timeout=5)
                self.error(('PING',), 'BUSY', recent)
        self.assertEqual(recent.call('SCRIPT', 'KILL'), 'OK')
        result = self.client.reply()
        self.assertIsInstance(result, ServerError)
        self.assertIn('kill', str(result).casefold())
        wait_for(lambda: old.available(.05), timeout=3, label='older idle connection timeout after script')
        with self.assertRaises((EOFError, ConnectionResetError)):
            old.read()
        for client in (self.client, active, recent):
            self.assertEqual(client.call('PING'), 'PONG')

    def test_after_write_script_refuses_kill_and_auth_abort_reaps_process(self):
        self.client.send('EVAL', "redis.call('SET','before-endless','preserved'); while true do end", 0)
        client = self.busy_client()
        self.error(('SCRIPT', 'KILL'), 'UNKILLABLE', client)
        self.error(('GET', 'before-endless'), 'BUSY', client)
        client.send('SHUTDOWN', 'NOSAVE')
        code = self.server.process.wait(timeout=5)
        self.assertEqual(code, 0)
        self.server.stop()


def main(argv=None):
    global BINARY, REFERENCE_PORT
    parser = argparse.ArgumentParser(description='Original Lua correctness checks; no benchmarks or automatic compilation.')
    fallback = os.environ.get('ESKI_SCRIPTING_BIN', os.environ.get('ESKI_THREADING_BIN', ROOT/'bin/eski'))
    parser.add_argument('--server', type=Path, default=Path(fallback))
    parser.add_argument('--case', default='*', help='Class.method glob')
    parser.add_argument('--reference-port', type=int, help='run portable cases against an explicitly isolated localhost reference server')
    parser.add_argument('--timeout', type=int, default=240)
    args = parser.parse_args(argv)
    BINARY = args.server.resolve()
    REFERENCE_PORT = args.reference_port
    if args.timeout <= 0 or (REFERENCE_PORT is None and not BINARY.is_file()):
        parser.error('positive timeout and an existing --server binary are required')
    if REFERENCE_PORT is not None and not 1 <= REFERENCE_PORT <= 65535:
        parser.error('--reference-port must be in 1..65535')
    classes = (Compatibility,) if REFERENCE_PORT is not None else (Compatibility, Integration, Busy)
    selected = [(cls, name) for cls in classes for name in unittest.defaultTestLoader.getTestCaseNames(cls)
                if fnmatch.fnmatchcase(cls.__name__+'.'+name, args.case)]
    if not selected:
        parser.error('--case selected no tests')

    def expired(unused_signal, unused_frame):
        print('scripting correctness exceeded its wall-clock limit', file=sys.stderr)
        raise SystemExit(124)

    old = signal.signal(signal.SIGALRM, expired)
    signal.alarm(args.timeout)
    try:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(cls(name) for cls, name in selected))
        return 0 if result.wasSuccessful() else 1
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


if __name__ == '__main__':
    raise SystemExit(main())
