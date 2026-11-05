import argparse
import fnmatch
import os
from pathlib import Path
import struct
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'test/threading'))
from support import Client, Server, ServerError, info, wait_for

BINARY = ROOT/'bin/eski'
REFERENCE_PORT = None
WORKERS = 0


def crc64(data):
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ 0x95AC9329AC4BC9B5 if value & 1 else value >> 1
    return value


def mapping(value):
    return value if isinstance(value, dict) else dict(zip(value[::2], value[1::2]))


def code(name, body):
    return ('#!lua name='+name+'\n'+body).encode()


class Functions(unittest.TestCase):
    portable = True

    def setUp(self):
        self.server = None
        if REFERENCE_PORT is None:
            self.server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(WORKERS)))
            self.addCleanup(self.server.close)
            self.server.start()
            self.port = self.server.port
        else:
            self.port = REFERENCE_PORT
        self.client = self.connection()
        self.client.call('FLUSHALL')
        self.client.call('FUNCTION', 'FLUSH', 'SYNC')
        self.client.call('SCRIPT', 'FLUSH', 'SYNC')

    def connection(self):
        client = Client(self.port)
        self.addCleanup(client.close)
        return client

    def load(self, name, body, replace=False):
        args = ['FUNCTION', 'LOAD'] + (['REPLACE'] if replace else [])
        self.assertEqual(self.client.call(*args, code(name, body)), name.encode())

    def error(self, *args, contains=None):
        self.client.send(*args)
        reply = self.client.reply()
        self.assertIsInstance(reply, ServerError)
        if contains is not None:
            self.assertIn(contains.lower(), str(reply).lower())
        return reply

    def test_registered_closure_and_binary_keys_arguments(self):
        self.load('closure', 'local n=0; redis.register_function("sequence",function(k,a) n=n+1; return {n,k[1],a[1]} end)')
        self.assertEqual(self.client.call('FCALL', 'sequence', 1, b'k\x00x', b'a\x00y'), [1, b'k\x00x', b'a\x00y'])
        self.assertEqual(self.client.call('FCALL', 'sequence', 1, 'next', 'last'), [2, b'next', b'last'])
        self.error('EVAL', 'return redis.register_function("illegal",function() end)', 0)

    def test_metadata_and_subcommand_errors_preserve_live_functions(self):
        self.load('stable', 'redis.register_function("stable_fn",function()return 17 end)')
        cases = (
            (('FUNCTION', 'LOAD', code('invalid foo=bar', 'return 1')), 'ERR Invalid metadata value given: foo=bar'),
            (('FUNCTION', 'LOAD', code('invalid name=other', 'return 1')), 'ERR Invalid metadata value, name argument was given multiple times'),
            (('FUNCTION', 'LIST', 'LIBRARYNAME'), 'ERR library name argument was not given'),
            (('FUNCTION', 'FLUSH', 'bad'), 'ERR FUNCTION FLUSH only supports SYNC|ASYNC option'),
            (('FUNCTION', 'FLUSH', 'sync', 'extra'), "ERR unknown subcommand or wrong number of arguments for 'FLUSH'. Try FUNCTION HELP."),
        )
        for arguments, expected in cases:
            with self.subTest(arguments=arguments):
                self.assertEqual(str(self.error(*arguments)), expected)
                self.assertEqual(self.client.call('FCALL', 'stable_fn', 0), 17)

    def test_function_errors_sanitize_user_arguments_without_extra_frames(self):
        for arguments, expected in (
            (('FUNCTION', 'LIST', b'X\r\n+INJECTED'), 'ERR Unknown argument X  +INJECTED'),
            (('FUNCTION', 'LIST', b'X\x00tail'), 'ERR Unknown argument X'),
            (('FUNCTION', 'LOAD', b'X\r\n+INJECTED', code('absent', 'return 1')), 'ERR Unknown option given: X  +INJECTED'),
        ):
            with self.subTest(arguments=arguments):
                error, following = self.client.pipeline([arguments, ('PING', 'after-function-error')])
                self.assertIsInstance(error, ServerError)
                self.assertEqual(str(error), expected)
                self.assertEqual(following, b'after-function-error')
                self.assertFalse(self.client.available(.01))
        self.assertEqual(self.client.call('FUNCTION', 'LIST'), [])

    def test_function_lookup_and_list_patterns_ignore_case(self):
        self.load('MixedCase', 'redis.register_function("MiXeD_Fn",function()return 19 end)')
        self.assertEqual(self.client.call('FCALL', 'MIXED_FN', 0), 19)
        self.assertEqual(self.client.call('FCALL', 'mixed_fn', 0), 19)
        libraries = self.client.call('FUNCTION', 'LIST', 'LIBRARYNAME', 'mIxEd*')
        self.assertEqual(mapping(libraries[0])[b'library_name'], b'MixedCase')
        self.error('FUNCTION', 'LOAD', code('different', 'redis.register_function("mixed_fn",function()return 23 end)'), contains='already exists')
        self.assertEqual(self.client.call('FCALL', 'mixed_fn', 0), 19)

    def test_version_fields_are_available_during_load_and_calls(self):
        self.load('versions', 'local version=redis.REDIS_VERSION_NUM;local text=redis.REDIS_VERSION;redis.register_function("versions",function()return {version,text,redis.REDIS_VERSION_NUM,redis.REDIS_VERSION}end)')
        version = info(self.client)['redis_version']
        major, minor, patch = (int(part) for part in version.split('.'))
        number = (major << 16)+(minor << 8)+patch
        self.assertEqual(self.client.call('FCALL', 'versions', 0), [number, version.encode(), number, version.encode()])

    def test_async_flush_detaches_vm_and_counts_actual_deferred_frees(self):
        count = 128
        for index in range(count):
            self.load('retired_'+str(index), 'redis.register_function("retired_'+str(index)+'",function()return 1 end)')
        before = int(info(self.client, 'memory')['used_memory_vm_functions'])
        self.client.call('CONFIG', 'RESETSTAT')
        self.client.call('FUNCTION', 'FLUSH', 'ASYNC')
        after = info(self.client, 'memory')
        self.assertEqual(int(after['number_of_libraries']), 0)
        self.assertEqual(int(after['number_of_functions']), 0)
        self.assertLess(int(after['used_memory_vm_functions']), before)
        self.load('live', 'redis.register_function("live",function()return 31 end)')
        wait_for(lambda: int(info(self.client, 'memory')['lazyfreed_objects']) == count+1, label='deferred function libraries and engine release')
        self.assertEqual(self.client.call('FCALL', 'live', 0), 31)

    def test_registration_errors_leave_no_library_or_function(self):
        cases = (
            ('redis.register_function("same",function()end);redis.register_function("same",function()end)', 'Function already exists in the library'),
            ('redis.register_function("",function()end)', 'Library names can only contain letters, numbers, or underscores(_) and must be at least one character long'),
            ('redis.register_function("bad-name",function()end)', 'Library names can only contain letters, numbers, or underscores(_) and must be at least one character long'),
            ('redis.register_function{function_name="bad",callback=function()end,flags="bad"}', 'flags argument to redis.register_function must be a table representing function flags'),
            ('redis.register_function{function_name="bad",callback=function()end,flags={function()end}}', 'unknown flag given'),
        )
        for body, expected in cases:
            with self.subTest(body=body):
                self.error('FUNCTION', 'LOAD', code('invalid', body), contains=expected)
                self.assertEqual(self.client.call('FUNCTION', 'LIST'), [])
                stats = mapping(self.client.call('FUNCTION', 'STATS'))
                engine = mapping(mapping(stats[b'engines'])[b'LUA'])
                self.assertEqual(engine[b'libraries_count'], 0)
                self.assertEqual(engine[b'functions_count'], 0)
        self.load('recovered', 'redis.register_function("good",function()return 29 end)')
        self.assertEqual(self.client.call('FCALL', 'good', 0), 29)

    def test_list_metadata_description_flags_and_code(self):
        source = code('metadata', 'redis.register_function{function_name="view",callback=function() return 7 end,description="visible",flags={"no-writes","allow-oom"}}')
        self.assertEqual(self.client.call('FUNCTION', 'LOAD', source), b'metadata')
        self.assertEqual(self.client.call('FUNCTION', 'LIST', 'LIBRARYNAME', 'none*'), [])
        library = mapping(self.client.call('FUNCTION', 'LIST', 'LIBRARYNAME', 'meta*', 'WITHCODE')[0])
        self.assertEqual(library[b'library_name'], b'metadata')
        self.assertEqual(library[b'engine'], b'LUA')
        self.assertEqual(library[b'library_code'], source)
        function = mapping(library[b'functions'][0])
        self.assertEqual(function[b'name'], b'view')
        self.assertEqual(function[b'description'], b'visible')
        self.assertEqual(set(function[b'flags']), {'no-writes', 'allow-oom'})
        stats = mapping(self.client.call('FUNCTION', 'STATS'))
        self.assertIsNone(stats[b'running_script'])
        engine = mapping(mapping(stats[b'engines'])[b'LUA'])
        self.assertEqual(engine[b'libraries_count'], 1)
        self.assertEqual(engine[b'functions_count'], 1)

    def test_failed_replacement_preserves_registered_closure(self):
        self.load('replaceable', 'local n=0;redis.register_function("keep",function() n=n+1 return n end)')
        self.assertEqual(self.client.call('FCALL', 'keep', 0), 1)
        self.error('FUNCTION', 'LOAD', 'REPLACE', code('replaceable', 'this is not valid lua'))
        self.error('FUNCTION', 'LOAD', 'REPLACE', code('replaceable', 'return 1'), contains='No functions registered')
        self.assertEqual(self.client.call('FCALL', 'keep', 0), 2)
        self.load('replaceable', 'redis.register_function("replacement",function()return 23 end)', replace=True)
        self.error('FCALL', 'keep', 0, contains='Function not found')
        self.assertEqual(self.client.call('FCALL', 'replacement', 0), 23)

    def test_cross_library_collision_is_atomic(self):
        self.load('first', 'redis.register_function("taken",function()return 1 end)')
        self.load('second', 'redis.register_function("safe",function()return 2 end)')
        self.error('FUNCTION', 'LOAD', 'REPLACE', code('second', 'redis.register_function("taken",function()return 9 end)'), contains='already exists')
        self.assertEqual(self.client.call('FCALL', 'taken', 0), 1)
        self.assertEqual(self.client.call('FCALL', 'safe', 0), 2)
        self.error('FUNCTION', 'LOAD', code('duplicate', 'redis.register_function("d",function()end);redis.register_function("d",function()end)'))
        self.assertEqual(self.client.call('FUNCTION', 'LIST', 'LIBRARYNAME', 'duplicate'), [])

    def test_readonly_call_checks_declared_policy_and_inner_writes(self):
        self.load('policies', 'redis.register_function("default_read",function()return 3 end);redis.register_function{function_name="readonly",callback=function()return 4 end,flags={"no-writes"}};redis.register_function{function_name="badwrite",callback=function(k) return redis.call("SET",k[1],"bad") end,flags={"no-writes"}}')
        self.error('FCALL_RO', 'default_read', 0, contains='Can not execute a script with write flag using *_ro command')
        self.assertEqual(self.client.call('FCALL_RO', 'readonly', 0), 4)
        self.error('FCALL', 'badwrite', 1, 'untouched', contains='read-only')
        self.assertEqual(self.client.call('EXISTS', 'untouched'), 0)

    def test_key_count_validation_and_missing_function(self):
        self.load('arguments', 'redis.register_function("args",function(k,a)return {#k,#a}end)')
        self.assertEqual(self.client.call('FCALL', 'args', 2, 'a', 'b', 'c'), [2, 1])
        self.error('FCALL', 'args', -1)
        self.error('FCALL', 'args', 'bad')
        self.error('FCALL', 'args', 2, 'a')
        self.error('FCALL', 'missing', 0, contains='Function not found')
        self.error('FUNCTION', 'LOAD')

    def test_loading_cannot_execute_database_commands(self):
        self.error('FUNCTION', 'LOAD', code('forbidden', 'redis.call("SET","load-effect","bad");redis.register_function("never",function()end)'))
        self.assertEqual(self.client.call('EXISTS', 'load-effect'), 0)
        self.assertEqual(self.client.call('FUNCTION', 'LIST'), [])

    def test_flush_delete_and_script_cache_are_independent(self):
        digest = self.client.call('SCRIPT', 'LOAD', 'return 19')
        self.load('independent', 'redis.register_function("available",function()return 29 end)')
        self.client.call('SCRIPT', 'FLUSH', 'ASYNC')
        self.assertEqual(self.client.call('FCALL', 'available', 0), 29)
        self.error('EVALSHA', digest, 0, contains='NOSCRIPT')
        self.client.call('FUNCTION', 'DELETE', 'independent')
        self.error('FUNCTION', 'DELETE', 'independent', contains='not found')
        self.load('fresh', 'redis.register_function("available",function()return 31 end)')
        self.client.call('FUNCTION', 'FLUSH', 'ASYNC')
        self.error('FCALL', 'available', 0, contains='not found')

    def test_dump_restore_modes_validate_before_publishing(self):
        self.load('stored', 'redis.register_function("stored_fn",function()return 11 end)')
        payload = self.client.call('FUNCTION', 'DUMP')
        self.assertEqual(str(self.error('FUNCTION', 'RESTORE', payload, 'APPEND')), 'ERR Library stored already exists')
        self.assertEqual(self.client.call('FCALL', 'stored_fn', 0), 11)
        self.client.call('FUNCTION', 'FLUSH', 'SYNC')
        self.client.call('FUNCTION', 'RESTORE', payload)
        self.assertEqual(self.client.call('FCALL', 'stored_fn', 0), 11)
        corrupt = payload[:-1]+bytes([payload[-1]^1])
        self.error('FUNCTION', 'RESTORE', corrupt, 'FLUSH', contains='checksum')
        self.assertEqual(self.client.call('FCALL', 'stored_fn', 0), 11)
        self.load('other', 'redis.register_function("other_fn",function()return 13 end)')
        self.client.call('FUNCTION', 'RESTORE', payload, 'FLUSH')
        self.error('FCALL', 'other_fn', 0, contains='not found')
        self.assertEqual(self.client.call('FCALL', 'stored_fn', 0), 11)

    def test_select_inside_function_does_not_change_callers_database(self):
        self.load('database', 'redis.register_function("select_write",function(k,a) redis.call("SELECT",5);return redis.call("SET",k[1],a[1]) end)')
        self.assertEqual(self.client.call('FCALL', 'select_write', 1, 'selected', 'value'), 'OK')
        self.assertIsNone(self.client.call('GET', 'selected'))
        self.client.call('SELECT', 5)
        self.assertEqual(self.client.call('GET', 'selected'), b'value')

    def test_failed_function_retains_earlier_effects(self):
        self.load('effects', 'redis.register_function("partial",function(k)redis.call("INCR",k[1]);error("planned")end)')
        self.error('FCALL', 'partial', 1, 'counter', contains='planned')
        self.assertEqual(self.client.call('GET', 'counter'), b'1')

    def test_libraries_share_configuration_separately_from_eval(self):
        self.load('settings_a', 'redis.register_function("precision_set",function(k,a)return cjson.encode_number_precision(tonumber(a[1]))end)')
        self.load('settings_b', 'redis.register_function("precision_get",function()return {cjson.encode_number_precision(),cjson.encode(1/3)}end)')
        self.client.call('FCALL', 'precision_set', 0, 3)
        self.assertEqual(self.client.call('FCALL', 'precision_get', 0), [3, b'0.333'])
        self.assertEqual(self.client.call('EVAL', 'return cjson.encode_number_precision()', 0), 14)
        payload = self.client.call('FUNCTION', 'DUMP')
        self.client.call('FUNCTION', 'RESTORE', payload, 'FLUSH')
        self.assertEqual(self.client.call('FCALL', 'precision_get', 0), [3, b'0.333'])
        self.client.call('FUNCTION', 'FLUSH', 'ASYNC')
        self.load('settings_c', 'redis.register_function("precision_get",function()return cjson.encode_number_precision()end)')
        self.assertEqual(self.client.call('FCALL', 'precision_get', 0), 14)

    def test_random_stream_continues_across_engines_and_flushes(self):
        expected = self.client.call('EVAL', 'math.randomseed(123);return {math.random(1,1000000000),math.random(1,1000000000),math.random(1,1000000000)}', 0)
        self.load('random_a', 'redis.register_function("random_draw",function()return math.random(1,1000000000)end)')
        self.assertEqual(self.client.call('EVAL', 'math.randomseed(123);return math.random(1,1000000000)', 0), expected[0])
        self.client.call('SCRIPT', 'FLUSH', 'SYNC')
        self.assertEqual(self.client.call('FCALL', 'random_draw', 0), expected[1])
        self.client.call('FUNCTION', 'FLUSH', 'SYNC')
        self.load('random_b', 'redis.register_function("random_draw",function()return math.random(1,1000000000)end)')
        self.assertEqual(self.client.call('FCALL', 'random_draw', 0), expected[2])

    def test_registration_keys_and_flags_ignore_case(self):
        self.load('upper', 'redis.register_function{FUNCTION_NAME="upper_fn", CALLBACK=function() return 1 end}')
        self.load('mixed', 'redis.register_function{Function_Name="mixed_fn", Callback=function() return 2 end, Description="d", Flags={"No-Writes","ALLOW-OOM"}}')
        self.assertEqual(self.client.call('FCALL', 'UPPER_FN', 0), 1)
        self.assertEqual(self.client.call('FCALL_RO', 'mixed_fn', 0), 2)
        function = mapping(mapping(self.client.call('FUNCTION', 'LIST', 'LIBRARYNAME', 'mixed')[0])[b'functions'][0])
        self.assertEqual((function[b'description'], set(function[b'flags'])), (b'd', {'no-writes', 'allow-oom'}))
        self.load('numeric', 'redis.register_function(1, function() return 3 end)\nredis.register_function{function_name=2, callback=function() return 4 end, description=5}')
        self.assertEqual([self.client.call('FCALL', 1, 0), self.client.call('FCALL', 2, 0)], [3, 4])
        functions = [mapping(item) for item in mapping(self.client.call('FUNCTION', 'LIST', 'LIBRARYNAME', 'numeric')[0])[b'functions']]
        self.assertEqual(sorted((item[b'name'], item[b'description']) for item in functions), [(b'1', None), (b'2', b'5')])

    def test_registration_errors_are_wrapped_with_reference_texts(self):
        prefix = 'ERR Error registering functions: '
        cases = (("redis.register_function('f')", 'ERR calling redis.register_function with a single argument is only applicable to Lua table (representing named arguments).'),
                 ("redis.register_function{function_name='f', callback=function() end, flags={'bogus'}}", 'ERR unknown flag given'),
                 ("redis.register_function{function_name='f', callback=function() end, flags={1}}", 'ERR unknown flag given'),
                 ("redis.register_function{[1]='x'}", 'ERR unknown argument given to redis.register_function'),
                 ("redis.register_function({}, function() end)", 'ERR first argument to redis.register_function must be a string'),
                 ("redis.register_function{function_name={}, callback=function() end}", 'ERR function_name argument given to redis.register_function must be a string'),
                 ("redis.register_function{function_name='f', callback=function() end, description=true}", 'ERR description argument given to redis.register_function must be a string'),
                 ("redis.register_function('same', function() end)\nredis.register_function('same', function() end)", 'ERR Function already exists in the library'),
                 ("redis.register_function('bad name', function() end)", 'ERR Library names can only contain letters, numbers, or underscores(_) and must be at least one character long'),
                 ("redis.register_function()", 'ERR wrong number of arguments to redis.register_function'),
                 ("error('boom')", "ERR user_function:2: Script attempted to access nonexistent global variable 'error'"),
                 ("redis.call('ping')", "ERR user_function:2: Script attempted to access nonexistent global variable 'call'"))
        for body, expected in cases:
            with self.subTest(body=body):
                self.assertEqual(str(self.error('FUNCTION', 'LOAD', code('wrapped', body))), prefix+expected)
        self.assertEqual(str(self.error('FUNCTION', 'LOAD', code('compile', 'foo('))), "ERR Error compiling function: user_function:2: unexpected symbol near '<eof>'")
        self.assertEqual(str(self.error('FUNCTION', 'LOAD', code('empty', 'return 1'))), 'ERR No functions registered')
        self.assertEqual(self.client.call('FUNCTION', 'LIST'), [])

    def test_load_environment_offers_logging_and_runtime_omits_replicate_commands(self):
        self.load('logging', "redis.log(redis.LOG_WARNING, 'parity load log')\nlocal level = redis.LOG_NOTICE\nredis.register_function('logging', function() return {level, redis.LOG_DEBUG, redis.LOG_VERBOSE, redis.LOG_WARNING} end)")
        self.assertEqual(self.client.call('FCALL', 'logging', 0), [2, 0, 1, 3])
        self.load('replicating', "redis.register_function('replicating', function() return redis.replicate_commands() end)")
        self.assertEqual(str(self.error('FCALL', 'replicating', 0)), "ERR user_function:2: attempt to call field 'replicate_commands' (a nil value) script: replicating, on @user_function:2.")
        self.assertEqual(self.client.call('EVAL', 'return redis.replicate_commands()', 0), 1)

    def test_library_shebang_metadata_is_parsed_before_engine_lookup(self):
        body = "\nredis.register_function('f_%s', function() return 1 end)"
        for header, expected in (('#!lua NAME=upper_name', b'upper_name'), ('#!lua Name=mixed_name', b'mixed_name'), ('#!Lua name=engine_case', b'engine_case')):
            with self.subTest(header=header):
                self.assertEqual(self.client.call('FUNCTION', 'LOAD', (header+body % expected.decode()).encode()), expected)
        for source, expected in ((b'#!lua name=bare', 'ERR Invalid library metadata'), (b'#!foo', 'ERR Invalid library metadata'),
                                 (b'#!foo badarg\nreturn 1', 'ERR Invalid metadata value given: badarg'),
                                 (b'#!foo\nreturn 1', 'ERR Library name was not given'),
                                 (b'#!foo name=a name=b\nreturn 1', 'ERR Invalid metadata value, name argument was given multiple times'),
                                 (b'#!foo name=bad-name\nreturn 1', 'ERR Library names can only contain letters, numbers, or underscores(_) and must be at least one character long'),
                                 (b'#! lua name=spaced\nreturn 1', 'ERR Invalid metadata value given: lua'),
                                 (b'#!lua NAME=\nreturn 1', 'ERR Library names can only contain letters, numbers, or underscores(_) and must be at least one character long'),
                                 (b'#!foo name=z\nreturn 1', "ERR Engine 'foo' not found")):
            with self.subTest(source=source):
                self.assertEqual(str(self.error('FUNCTION', 'LOAD', source)), expected)

    def test_fcall_looks_up_the_function_before_key_count(self):
        for arguments in (('FCALL', 'missing', 'abc'), ('FCALL', 'missing', '-1'), ('FCALL', 'missing', '5'), ('FCALL_RO', 'missing', 'abc')):
            with self.subTest(arguments=arguments):
                self.assertEqual(str(self.error(*arguments)), 'ERR Function not found')
        self.load('present', 'redis.register_function("present",function(k,a)return {#k,#a}end)')
        self.assertEqual(str(self.error('FCALL', 'present', 'abc')), 'ERR Bad number of keys provided')
        self.assertEqual(str(self.error('FCALL_RO', 'present', 5)), "ERR Number of keys can't be greater than number of args")

    def dumped(self, name, function):
        self.client.call('FUNCTION', 'FLUSH', 'SYNC')
        self.load(name, 'redis.register_function("%s",function() return 1 end)' % function)
        payload = self.client.call('FUNCTION', 'DUMP')
        self.client.call('FUNCTION', 'FLUSH', 'SYNC')
        return payload[:-10], payload[-10:-8]

    def test_restore_reports_reference_texts_in_payload_order(self):
        first, version = self.dumped('L1', 'f1')
        other, _ = self.dumped('LX', 'f1')
        changed, _ = self.dumped('L1', 'h1')
        upper, _ = self.dumped('L2', 'F1')
        seal = lambda body: body+version+struct.pack('<Q', crc64(body+version))
        for payload, expected in ((seal(bytes([0])+first[1:]), 'ERR given type is not a function'),
                                  (seal(bytes([2])+first[1:]), 'ERR given type is not a function'),
                                  (seal(bytes([246])+first[1:]), 'ERR Pre-GA function format not supported'),
                                  (seal(first+first), "ERR Library 'L1' already exists"),
                                  (seal(first+changed), "ERR Library 'L1' already exists"),
                                  (seal(other+first), 'ERR Function f1 already exists'),
                                  (seal(first+upper), 'ERR Function F1 already exists')):
            with self.subTest(payload=payload[:1]):
                self.assertEqual(str(self.error('FUNCTION', 'RESTORE', payload)), expected)
        self.assertEqual(self.client.call('FUNCTION', 'LIST'), [])
        self.load('L1', 'redis.register_function("g1",function() return 1 end)')
        self.assertEqual(str(self.error('FUNCTION', 'RESTORE', seal(other+first))), 'ERR Function f1 already exists')
        self.assertEqual(str(self.error('FUNCTION', 'RESTORE', seal(changed))), 'ERR Library L1 already exists')
        self.assertEqual(self.client.call('FUNCTION', 'RESTORE', seal(changed), 'REPLACE'), 'OK')

    def test_async_flush_defers_only_more_than_64_functions(self):
        def freed():
            return int(info(self.client, 'memory')['lazyfreed_objects'])
        def populate(libraries, functions):
            self.client.call('FUNCTION', 'FLUSH', 'SYNC')
            for index in range(libraries):
                body = '\n'.join('redis.register_function("f%d_%d",function() return 1 end)' % (index, item) for item in range(functions))
                self.load('lazy%d' % index, body)
        for libraries, functions, expected in ((3, 2, 0), (32, 2, 0), (1, 64, 0), (33, 2, 67), (1, 65, 66), (10, 7, 71)):
            with self.subTest(libraries=libraries, functions=functions):
                populate(libraries, functions)
                before = freed()
                self.assertEqual(self.client.call('FUNCTION', 'FLUSH', 'ASYNC'), 'OK')
                if expected:
                    wait_for(lambda: freed()-before == expected, label='deferred function release')
                else:
                    time.sleep(0.05)
                    self.assertEqual(freed()-before, 0)

    def test_load_timeout_is_fixed_and_wrapped(self):
        self.addCleanup(self.client.call, 'CONFIG', 'SET', 'busy-reply-threshold', '5000')
        for threshold in ('5000', '200'):
            with self.subTest(threshold=threshold):
                self.client.call('CONFIG', 'SET', 'busy-reply-threshold', threshold)
                start = time.monotonic()
                self.assertEqual(str(self.error('FUNCTION', 'LOAD', code('endless', 'local i = 0 while true do i = i + 1 end'))), 'ERR Error registering functions: ERR FUNCTION LOAD timeout')
                self.assertTrue(0.4 <= time.monotonic()-start < 2.5)


class Persistence(Functions):
    portable = False

    def restart(self):
        self.server.stop()
        self.server.start()
        self.client = self.server.client()

    def test_rdb_preserves_libraries_and_resets_nonpersistent_closure_state(self):
        self.load('saved', 'local n=0;redis.register_function("saved_fn",function(k,a)n=n+1;redis.call("SET",k[1],a[1]);return n end)')
        self.assertEqual(self.client.call('FCALL', 'saved_fn', 1, 'before', 'snapshot'), 1)
        self.assertEqual(self.client.call('SAVE'), 'OK')
        self.restart()
        self.assertEqual(self.client.call('GET', 'before'), b'snapshot')
        self.assertEqual(self.client.call('FCALL', 'saved_fn', 1, 'after', 'restart'), 1)

    def test_aof_preserves_library_load_and_effects_after_errors(self):
        self.client.call('CONFIG', 'SET', 'appendonly', 'yes')
        self.client.call('CONFIG', 'SET', 'appendfsync', 'always')
        wait_for(lambda: info(self.client, 'persistence').get('aof_rewrite_in_progress') == '0', label='initial AOF rewrite')
        self.load('journal', 'redis.register_function("journal_fn",function(k)redis.call("INCR",k[1]);error("afterwrite")end)')
        self.error('FCALL', 'journal_fn', 1, 'journal-counter', contains='afterwrite')
        self.server.arguments += ['--appendonly', 'yes', '--appendfsync', 'always']
        self.restart()
        self.assertEqual(self.client.call('GET', 'journal-counter'), b'1')
        self.error('FCALL', 'journal_fn', 1, 'journal-counter', contains='afterwrite')
        self.assertEqual(self.client.call('GET', 'journal-counter'), b'2')

    def test_command_aof_rewrite_includes_functions(self):
        self.client.call('CONFIG', 'SET', 'appendonly', 'yes')
        self.client.call('CONFIG', 'SET', 'aof-use-rdb-preamble', 'no')
        wait_for(lambda: info(self.client, 'persistence').get('aof_rewrite_in_progress') == '0', label='initial AOF rewrite')
        self.load('rewrite', 'redis.register_function("rewritten",function()return 43 end)')
        self.client.call('BGREWRITEAOF')
        wait_for(lambda: info(self.client, 'persistence').get('aof_rewrite_in_progress') == '0', label='command AOF rewrite')
        self.server.arguments += ['--appendonly', 'yes', '--aof-use-rdb-preamble', 'no']
        self.restart()
        self.assertEqual(self.client.call('FCALL', 'rewritten', 0), 43)


def main():
    global BINARY, REFERENCE_PORT, WORKERS
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', type=Path, default=Path(os.environ.get('ESKI_SCRIPTING_BIN', BINARY)))
    parser.add_argument('--reference-port', type=int)
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--case', action='append', default=[])
    args = parser.parse_args()
    BINARY, REFERENCE_PORT, WORKERS = args.server.resolve(), args.reference_port, args.keyspace_threads
    suite = unittest.TestSuite()
    for kind in [Functions, Persistence]:
        if REFERENCE_PORT is not None and not kind.portable:
            continue
        for test in unittest.defaultTestLoader.loadTestsFromTestCase(kind):
            if kind is Persistence and test._testMethodName in Functions.__dict__:
                continue
            name = kind.__name__+'.'+test._testMethodName
            if not args.case or any(fnmatch.fnmatchcase(name, pattern) for pattern in args.case):
                suite.addTest(test)
    if not suite.countTestCases():
        raise SystemExit('no function cases selected')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())


if __name__ == '__main__':
    main()
