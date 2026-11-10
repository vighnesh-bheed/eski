import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Client, Push, Server, ServerError, info, wait_for

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0
AUDIENCE = 'labels-test-node'
SCHEME = ('--label-levels', 'U,C,S,TOP SECRET', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED')
INVALID = 'ERR invalid label'
CONTEXT_ERROR = 'ERR invalid context'
TOKEN_ERROR = 'ERR invalid label token'
TOP_ERROR = 'ERR this command needs a label that dominates the whole label scheme'
PERSIST_ERROR = 'ERR persistence is off while a label scheme is configured'
LABELS_OFF = 'ERR labels are not configured on this server'
KEYS_REFUSED = "ERR CONFIG SET failed (possibly related to argument 'label-levels') - a label scheme needs a server without keys, because existing keys carry no label"
STARTUP_REFUSED = 'holds data that carries no labels or owners, and a server with a label scheme or owner mode never loads it'
WATCH_REFUSED = "EXECABORT Transaction discarded because of: the command's label differs from the transaction's label"

ED25519_SEED_PREFIX = bytes.fromhex('302e020100300506032b657004220420')
ED25519_PUBLIC_PREFIX = bytes.fromhex('302a300506032b6570032100')
OPENSSL_MISSING = 'signing label tokens needs the openssl command line of OpenSSL 3 on PATH'


def openssl(*arguments):
    try:
        done = subprocess.run(('openssl',) + arguments, stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
    except FileNotFoundError:
        raise RuntimeError(OPENSSL_MISSING) from None
    if done.returncode != 0:
        raise RuntimeError('openssl %s failed: %s' % (arguments[0], done.stderr.decode(errors='replace').strip()))
    return done.stdout


OPENSSL_VERSION = openssl('version').decode(errors='replace').strip()


def seed_file(directory, secret):
    if len(secret) != 32:
        raise ValueError('an Ed25519 seed has 32 bytes')
    path = os.path.join(directory, 'seed.der')
    with open(path, 'wb') as handle:
        handle.write(ED25519_SEED_PREFIX + secret)
    return path


def token_key(secret):
    with tempfile.TemporaryDirectory(prefix='eski-token-') as directory:
        public = openssl('pkey', '-inform', 'DER', '-in', seed_file(directory, secret), '-pubout', '-outform', 'DER')
    if len(public) != len(ED25519_PUBLIC_PREFIX) + 32 or not public.startswith(ED25519_PUBLIC_PREFIX):
        raise RuntimeError('%s returned no Ed25519 public key' % OPENSSL_VERSION)
    return public[len(ED25519_PUBLIC_PREFIX):]


def token_signature(secret, message):
    with tempfile.TemporaryDirectory(prefix='eski-token-') as directory:
        statement = os.path.join(directory, 'statement')
        with open(statement, 'wb') as handle:
            handle.write(message)
        signature = openssl('pkeyutl', '-sign', '-rawin', '-keyform', 'DER', '-inkey', seed_file(directory, secret), '-in', statement)
    if len(signature) != 64:
        raise RuntimeError('%s returned no Ed25519 signature' % OPENSSL_VERSION)
    return signature


TEST_SECRET = bytes(range(1, 33))
OTHER_SECRET = bytes(range(101, 133))


def token(secret, marking, expires_ms=None, audience=AUDIENCE, trust=None, handle=None, extra=None):
    lines = ['eski-label-token 1', 'marking ' + marking]
    if trust is not None:
        lines.append('trust ' + trust)
    lines.append('expires %d' % (expires_ms if expires_ms is not None else int(time.time() * 1000) + 600000))
    lines.append('audience ' + audience)
    if handle is not None:
        lines.append('context ' + handle)
    if extra is not None:
        lines.append(extra)
    statement = '\n'.join(lines).encode()
    return (statement.hex() + '.' + token_signature(secret, statement).hex()).encode()


def error_of(client, *arguments):
    client.send(*arguments)
    value = client.reply()
    if not isinstance(value, ServerError):
        raise AssertionError('expected an error from %r, got %r' % (arguments, value))
    return str(value)


def as_map(value):
    if isinstance(value, dict):
        return value
    return dict(zip(value[0::2], value[1::2]))


def closed(client):
    try:
        client.socket.settimeout(2)
        client.send('PING')
        client.reply()
    except (OSError, EOFError):
        return True
    return False


def push_of(client, *arguments):
    client.send(*arguments)
    value = client.read()
    if isinstance(value, ServerError):
        raise value
    return value


class LabelsOff(unittest.TestCase):
    def setUp(self):
        self.server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS)))
        self.addCleanup(self.server.close)
        self.server.start()
        self.client = self.server.client()

    def test_label_and_context_commands_answer_an_error(self):
        for command in (('LABEL', 'WHOAMI'), ('LABEL', 'SESSION', 'U'), ('LABEL', 'AS', 'U', 'GET', 'k'),
                        ('CONTEXT', 'CREATE'), ('CONTEXT', 'INFO', '00' * 16), ('CONTEXT', 'DROP', '00' * 16)):
            self.assertEqual(error_of(self.client, *command), LABELS_OFF)
        self.assertTrue(self.client.call('LABEL', 'HELP')[0].startswith('LABEL <subcommand>'))
        self.assertTrue(self.client.call('CONTEXT', 'HELP')[0].startswith('CONTEXT <subcommand>'))
        self.assertTrue(error_of(self.client, 'LABEL', 'NOPE').startswith("ERR unknown subcommand 'NOPE'"))
        self.assertEqual(error_of(self.client, 'LABEL', 'AS', 'U'), "ERR wrong number of arguments for 'label|as' command")

    def test_reply_shapes_stay_those_of_the_reference(self):
        self.assertEqual(self.client.call('PUBLISH', 'ch', 'm'), 0)
        user = as_map(self.client.call('ACL', 'GETUSER', 'default'))
        self.assertEqual(sorted(user), [b'channels', b'commands', b'flags', b'keys', b'passwords', b'selectors'])
        self.assertEqual(self.client.call('ACL', 'LIST'), [b'user default on nopass sanitize-payload ~* &* +@all'])
        names = self.client.call('CONFIG', 'GET', '*')[0::2]
        self.assertFalse([n for n in names if n.startswith(b'label-')])
        self.assertEqual(self.client.call('CONFIG', 'GET', 'label-levels'), [b'label-levels', b'UNCLASSIFIED'])
        self.assertEqual(self.client.call('CONFIG', 'GET', 'label-trust-levels'), [b'label-trust-levels', b''])
        self.assertTrue(self.client.call('INFO', 'stats').find(b'total_commands_processed:0') < 0)
        self.client.call('SET', 'k', 'v')
        self.assertTrue(self.client.call('DUMP', 'k').startswith(b'\x00'))

    def test_label_rules_need_a_scheme(self):
        for rule in ('clearance:*', 'trust:*', 'label-per-command', 'require-token', 'token-key:' + '00' * 32):
            text = error_of(self.client, 'ACL', 'SETUSER', 'x', rule)
            self.assertEqual(text, "ERR Error in ACL SETUSER modifier '%s': Labels are not configured on this server" % rule)

    def test_scheme_needs_persistence_off(self):
        self.client.call('CONFIG', 'SET', 'save', '900 1')
        text = error_of(self.client, 'CONFIG', 'SET', 'label-levels', 'U,S')
        self.assertIn('a label scheme needs persistence off', text)
        self.assertEqual(self.client.call('CONFIG', 'GET', 'label-levels'), [b'label-levels', b'UNCLASSIFIED'])
        self.client.call('CONFIG', 'SET', 'save', '')
        self.assertEqual(self.client.call('CONFIG', 'SET', 'label-levels', 'U,S'), 'OK')
        self.assertTrue(as_map(self.client.call('LABEL', 'WHOAMI'))[b'label'] == b'U')
        self.assertIn('persistence stays off', error_of(self.client, 'CONFIG', 'SET', 'appendonly', 'yes'))
        self.assertIn('persistence stays off', error_of(self.client, 'CONFIG', 'SET', 'save', '60 10'))
        self.assertEqual(error_of(self.client, 'SAVE'), PERSIST_ERROR)

    def test_a_read_only_evalsha_passes_a_write_pause(self):
        c, other = self.client, self.server.client()
        sha = c.call('SCRIPT', 'LOAD', "#!lua flags=no-writes\nreturn 'ro'")
        self.assertEqual(c.call('CLIENT', 'PAUSE', 5000, 'WRITE'), 'OK')
        other.send('EVALSHA', sha, 0)
        self.assertTrue(other.available(2))
        self.assertEqual(other.reply(), b'ro')
        other.send('SET', 'k', 'v')
        self.assertFalse(other.available(0.3))
        self.assertEqual(c.call('CLIENT', 'UNPAUSE'), 'OK')
        self.assertEqual(other.reply(), 'OK')

    def test_a_scheme_is_refused_while_the_server_holds_keys(self):
        c = self.client
        c.call('CONFIG', 'SET', 'save', '')
        for writes in ((('SET', 'k', 'v'),), (('SELECT', 5), ('HSET', 'h', 'f', 'v'), ('SELECT', 0)),
                       (('VADD', 'vs', 'VALUES', 2, 1, 0, 'e'),), (('SET', 'gone', 'v', 'PX', 1),)):
            for command in writes:
                c.call(*command)
            time.sleep(0.01)
            self.assertEqual(error_of(c, 'CONFIG', 'SET', 'label-levels', 'U,S'), KEYS_REFUSED)
            self.assertIn('without keys', error_of(c, 'CONFIG', 'SET', 'label-compartments', 'A'))
            self.assertIn('without keys', error_of(c, 'CONFIG', 'SET', 'label-trust-levels', 'WEB,VETTED'))
            self.assertEqual(c.call('CONFIG', 'GET', 'label-levels'), [b'label-levels', b'UNCLASSIFIED'])
            self.assertEqual(error_of(c, 'LABEL', 'WHOAMI'), LABELS_OFF)
            self.assertEqual(c.call('FLUSHALL'), 'OK')
        self.assertEqual(c.call('CONFIG', 'SET', 'label-levels', 'U,S'), 'OK')
        c.call('ACL', 'SETUSER', 'default', 'clearance:*')
        self.assertEqual(c.call('LABEL', 'AS', 'S', 'SET', 'k', 'v'), 'OK')
        self.assertEqual(c.call('CONFIG', 'SET', 'label-levels', 'U,S,T', 'label-compartments', 'A'), 'OK')
        self.assertEqual(c.call('LABEL', 'AS', 'S', 'GET', 'k'), b'v')


class Labelled(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='eski-labels-')
        self.addCleanup(self.directory.cleanup)
        self.audit = Path(self.directory.name) / 'audit.log'
        self.aclfile = Path(self.directory.name) / 'users.acl'
        self.aclfile.write_text('')
        arguments = ('--keyspace-threads', str(KEYSPACE_THREADS)) + SCHEME + (
            '--label-audit-file', str(self.audit), '--label-token-audience', AUDIENCE, '--aclfile', str(self.aclfile))
        self.server = Server(BINARY, workers=0, arguments=arguments)
        self.addCleanup(self.server.close)
        self.server.start()
        self.admin = self.connect()
        self.admin.call('ACL', 'SETUSER', 'default', 'clearance:*')
        self.admin.call('ACL', 'SETUSER', 'app', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:S//A', 'trust:VETTED')
        self.admin.call('ACL', 'SETUSER', 'peer', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:S//A/B', 'trust:*')
        self.admin.call('ACL', 'SETUSER', 'low', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:C')

    def connect(self, user=None, protocol=2):
        client = Client(self.server.port)
        self.addCleanup(client.close)
        if protocol == 3:
            client.call('HELLO', 3)
        if user is not None:
            client.call('AUTH', user, 'x')
        return client

    def whoami(self, client, *prefix):
        return as_map(client.call(*prefix, 'LABEL', 'WHOAMI'))

    def test_scheme_is_configured_and_grows_by_add_and_rename_only(self):
        c = self.admin
        self.assertEqual(c.call('CONFIG', 'GET', 'label-levels'), [b'label-levels', b'U,C,S,TOP SECRET'])
        self.assertEqual(c.call('CONFIG', 'GET', 'label-compartments'), [b'label-compartments', b'A,B'])
        self.assertEqual(c.call('CONFIG', 'GET', 'label-trust-levels'), [b'label-trust-levels', b'WEB,VETTED'])
        self.assertEqual(c.call('CONFIG', 'SET', 'label-compartments', 'A,B,X'), 'OK')
        self.assertEqual(c.call('CONFIG', 'SET', 'label-levels', 'U,CONFIDENTIAL,S,TOP SECRET'), 'OK')
        for value, words in (('U,S,TOP SECRET', 'never removed'), ('U,S,CONFIDENTIAL,TOP SECRET', 'new to the scheme'),
                             ('U,CONFIDENTIAL,S,A', 'new to the scheme'), ('U,CONFIDENTIAL,S,TOP SECRET,U', 'new to the scheme'),
                             ('U,CONFIDENTIAL,S,TOP SECRET,TOKEN', 'reserved'), ('U,CONFIDENTIAL,S,TOP SECRET,a/b', 'letters, digits')):
            self.assertIn(words, error_of(c, 'CONFIG', 'SET', 'label-levels', value))
        self.assertIn('never removed', error_of(c, 'CONFIG', 'SET', 'label-trust-levels', 'WEB'))
        self.assertEqual(c.call('CONFIG', 'SET', 'label-trust-levels', 'OPEN WEB,VETTED,AUDITED'), 'OK')
        self.assertEqual(c.call('CONFIG', 'GET', 'label-levels'), [b'label-levels', b'U,CONFIDENTIAL,S,TOP SECRET'])
        self.assertEqual(self.whoami(self.connect('app'))[b'trust-clearance'], b'VETTED')
        self.assertEqual(self.whoami(self.connect('low'))[b'clearance'], b'CONFIDENTIAL')
        self.assertIn('persistence stays off', error_of(c, 'CONFIG', 'SET', 'appendonly', 'yes'))
        self.assertIn('persistence stays off', error_of(c, 'CONFIG', 'SET', 'save', '900 1'))
        self.assertEqual(c.call('CONFIG', 'SET', 'save', ''), 'OK')
        self.assertIn('never removed', error_of(c, 'CONFIG', 'SET', 'label-compartments', 'A,B,X,Y', 'label-levels', 'U'))
        self.assertEqual(c.call('CONFIG', 'GET', 'label-compartments'), [b'label-compartments', b'A,B,X'])
        self.assertEqual(error_of(c, 'CONFIG', 'SET', 'label-audit-file', '/x'), "ERR CONFIG SET failed (possibly related to argument 'label-audit-file') - can't set immutable config")

    def test_acl_rules_carry_clearance_trust_flags_and_keys(self):
        c = self.admin
        key = token_key(TEST_SECRET).hex()
        c.call('ACL', 'SETUSER', 'agent', 'on', '>secret', '+@all', '-context|create', '~*', 'clearance:TOP+SECRET//B',
               'trust:VETTED', 'label-per-command', 'require-token', 'token-key:' + key)
        user = as_map(c.call('ACL', 'GETUSER', 'agent'))
        self.assertEqual(user[b'clearance'], b'TOP SECRET//B')
        self.assertEqual(user[b'trust'], b'VETTED')
        self.assertEqual(user[b'token-keys'], [key.encode()])
        self.assertIn(b'label-per-command', user[b'flags'])
        self.assertIn(b'require-token', user[b'flags'])
        line = [x for x in c.call('ACL', 'LIST') if x.startswith(b'user agent ')][0].decode()
        self.assertIn('clearance:TOP+SECRET//B trust:VETTED label-per-command require-token token-key:' + key, line)
        self.assertEqual(c.call('ACL', 'SAVE'), 'OK')
        self.assertIn('clearance:TOP+SECRET//B', self.aclfile.read_text())
        c.call('ACL', 'SETUSER', 'agent', 'label-per-session', 'token-optional', 'reset-token-keys', 'clearance:U', 'trust:WEB')
        self.assertEqual(as_map(c.call('ACL', 'GETUSER', 'agent'))[b'clearance'], b'U')
        self.assertEqual(c.call('ACL', 'LOAD'), 'OK')
        restored = as_map(c.call('ACL', 'GETUSER', 'agent'))
        self.assertEqual((restored[b'clearance'], restored[b'trust'], restored[b'token-keys']), (b'TOP SECRET//B', b'VETTED', [key.encode()]))
        c.call('ACL', 'SETUSER', 'agent', 'reset')
        restored = as_map(c.call('ACL', 'GETUSER', 'agent'))
        self.assertEqual((restored[b'clearance'], restored[b'trust'], restored[b'token-keys']), (b'', b'', []))
        for rule in ('clearance:NOPE', 'clearance:S//Z', 'clearance:S;VETTED', 'trust:NOPE', 'token-key:00', 'token-key:' + 'zz' * 32):
            self.assertEqual(error_of(c, 'ACL', 'SETUSER', 'agent', rule), "ERR Error in ACL SETUSER modifier '%s': Invalid label rule" % rule)
        c.call('ACL', 'SETUSER', 'agent', 'clearance:*', 'trust:*')
        self.assertEqual(as_map(c.call('ACL', 'GETUSER', 'agent'))[b'clearance'], b'*')

    def test_label_as_runs_one_command_and_fails_closed(self):
        app = self.connect('app')
        self.assertEqual(app.call('LABEL', 'AS', 'S//A', 'SET', 'k', 'v'), 'OK')
        self.assertEqual(app.call('LABEL', 'AS', 's // a', 'GET', 'k'), b'v')
        who = self.whoami(app, 'LABEL', 'AS', 'C', 'TRUST', 'VETTED')
        self.assertEqual((who[b'label'], who[b'marking'], who[b'trust']), (b'C;VETTED', b'C', b'VETTED'))
        self.assertEqual(self.whoami(app, 'LABEL', 'AS', 'C;vetted')[b'label'], b'C;VETTED')
        self.assertEqual(self.whoami(app)[b'label'], b'S//A')
        for marking in ('S//B', 'TOP SECRET', 'NOPE', 'S//A/A', '', 'S//A;AUDITED'):
            self.assertEqual(error_of(app, 'LABEL', 'AS', marking, 'GET', 'k'), INVALID)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'C;VETTED', 'TRUST', 'VETTED', 'GET', 'k'), INVALID)
        self.assertEqual(error_of(self.connect('low'), 'LABEL', 'AS', 'U', 'TRUST', 'VETTED', 'GET', 'k'), INVALID)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'S//A', 'LABEL', 'AS', 'C', 'GET', 'k'), 'ERR LABEL AS cannot wrap LABEL AS or LABEL SESSION')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'S//A', 'LABEL', 'SESSION', 'C'), 'ERR LABEL AS cannot wrap LABEL AS or LABEL SESSION')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'S//A'), "ERR wrong number of arguments for 'label|as' command")
        self.assertTrue(error_of(app, 'LABEL', 'AS', 'S//A', 'NOSUCH', 'x').startswith("ERR unknown command 'NOSUCH'"))
        self.admin.call('ACL', 'SETUSER', 'reader', 'on', 'nopass', '+label', '+get', '~public:*', 'clearance:S')
        reader = self.connect('reader')
        self.assertIsNone(reader.call('LABEL', 'AS', 'S', 'GET', 'public:x'))
        self.assertEqual(error_of(reader, 'LABEL', 'AS', 'S', 'SET', 'public:x', '1'), "NOPERM User reader has no permissions to run the 'set' command")
        self.assertEqual(error_of(reader, 'LABEL', 'AS', 'S', 'GET', 'secret'), "NOPERM No permissions to access a key")
        replies = app.pipeline([('LABEL', 'AS', 'U', 'LABEL', 'WHOAMI'), ('LABEL', 'WHOAMI'), ('LABEL', 'AS', 'C', 'LABEL', 'WHOAMI')])
        self.assertEqual([as_map(r)[b'label'] for r in replies], [b'U', b'S//A', b'C'])

    def test_session_whoami_reset_and_auth(self):
        app = self.connect('app')
        who = self.whoami(app)
        self.assertEqual((who[b'login'], who[b'clearance'], who[b'session'], who[b'top']), (b'app', b'S//A', 0, 0))
        self.assertEqual(app.call('LABEL', 'SESSION', 'C', 'TRUST', 'VETTED'), 'OK')
        self.assertEqual(self.whoami(app)[b'label'], b'C;VETTED')
        self.assertEqual(self.whoami(app)[b'session'], 1)
        self.assertEqual(error_of(app, 'LABEL', 'SESSION', 'S//B'), INVALID)
        self.assertEqual(error_of(app, 'LABEL', 'SESSION', 'C', 'TRUSTED', 'VETTED'), 'ERR syntax error')
        self.assertEqual(self.whoami(app)[b'label'], b'C;VETTED')
        app.call('MULTI')
        self.assertEqual(error_of(app, 'LABEL', 'SESSION', 'U'), 'ERR Command not allowed inside a transaction')
        app.call('DISCARD')
        self.assertEqual(app.call('RESET'), 'RESET')
        self.assertEqual(self.whoami(app)[b'login'], b'default')
        app.call('AUTH', 'app', 'x')
        app.call('LABEL', 'SESSION', 'U')
        app.call('AUTH', 'low', 'x')
        self.assertEqual((self.whoami(app)[b'label'], self.whoami(app)[b'session']), (b'C', 0))
        top = self.whoami(self.admin)
        self.assertEqual((top[b'clearance'], top[b'top']), (b'TOP SECRET//A/B', 1))

    def test_contexts_are_bound_to_their_login_and_expire(self):
        app = self.connect('app')
        handle = app.call('CONTEXT', 'CREATE')
        self.assertEqual(len(handle), 32)
        self.assertEqual(as_map(app.call('CONTEXT', 'INFO', handle)), {b'marking': b'S//A', b'trust': b'WEB'})
        task = app.call('LABEL', 'AS', 'C', 'CONTEXT', 'CREATE', 'TRUST', 'VETTED')
        self.assertEqual(as_map(app.call('CONTEXT', 'INFO', task)), {b'marking': b'C', b'trust': b'VETTED'})
        self.assertEqual(self.whoami(app, 'LABEL', 'AS', 'CONTEXT', task)[b'label'], b'C;VETTED')
        self.assertEqual(self.whoami(app, 'LABEL', 'AS', 'C', 'TRUST', 'VETTED', 'CONTEXT', task)[b'label'], b'C;VETTED')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'C', 'CONTEXT', task, 'GET', 'k'), 'ERR the label differs from the context\'s label')
        level = app.call('CONTEXT', 'CREATE', 'LEVEL', 'U//A')
        self.assertEqual(as_map(app.call('CONTEXT', 'INFO', level))[b'marking'], b'U//A')
        for options in (('LEVEL', 'S//B'), ('TRUST', 'AUDITED'), ('LEVEL', 'NOPE'), ('LEVEL', 'C;VETTED', 'TRUST', 'WEB')):
            self.assertEqual(error_of(app, 'CONTEXT', 'CREATE', *options), INVALID)
        self.assertEqual(error_of(app, 'CONTEXT', 'CREATE', 'LEVEL'), 'ERR syntax error')
        self.assertEqual(error_of(app, 'CONTEXT', 'CREATE', 'LEVEL', 'C', 'LEVEL', 'U'), 'ERR syntax error')
        peer = self.connect('peer')
        for client, value in ((peer, handle), (app, b'00' * 16), (app, b'zz'), (app, handle.upper()[:-1])):
            self.assertEqual(error_of(client, 'CONTEXT', 'INFO', value), CONTEXT_ERROR)
        self.assertEqual(error_of(peer, 'LABEL', 'AS', 'CONTEXT', handle, 'GET', 'k'), CONTEXT_ERROR)
        self.assertEqual(error_of(peer, 'CONTEXT', 'DROP', handle), CONTEXT_ERROR)
        self.assertEqual(as_map(app.call('CONTEXT', 'INFO', handle.upper()))[b'marking'], b'S//A')
        self.assertEqual(app.call('CONTEXT', 'DROP', handle), 'OK')
        self.assertEqual(error_of(app, 'CONTEXT', 'INFO', handle), CONTEXT_ERROR)
        self.admin.call('CONFIG', 'SET', 'label-context-max-per-login', 3)
        app.call('CONTEXT', 'CREATE')
        self.assertEqual(error_of(app, 'CONTEXT', 'CREATE'), 'ERR this login already holds the maximum number of contexts')
        self.admin.call('CONFIG', 'SET', 'label-context-idle-timeout', 1)
        time.sleep(2.2)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'CONTEXT', task, 'GET', 'k'), CONTEXT_ERROR)
        self.assertEqual(len(app.call('CONTEXT', 'CREATE')), 32)
        self.admin.call('ACL', 'SETUSER', 'agent', 'on', 'nopass', '+@all', '-context|create', '~*', 'clearance:S')
        agent = self.connect('agent')
        self.assertEqual(error_of(agent, 'CONTEXT', 'CREATE'), "NOPERM User agent has no permissions to run the 'context|create' command")
        self.admin.call('CONFIG', 'SET', 'label-context-idle-timeout', 3600)
        kept = app.call('CONTEXT', 'CREATE')
        self.admin.call('ACL', 'DELUSER', 'app')
        self.admin.call('ACL', 'SETUSER', 'app', 'on', 'nopass', '+@all', '~*', 'clearance:S//A')
        self.assertEqual(error_of(self.connect('app'), 'CONTEXT', 'INFO', kept), CONTEXT_ERROR)

    def test_signed_tokens_are_verified_per_login(self):
        c = self.admin
        c.call('ACL', 'SETUSER', 'svc', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:S//A', 'trust:VETTED',
               'token-key:' + token_key(TEST_SECRET).hex())
        svc = self.connect('svc')
        good = token(TEST_SECRET, 'S//A', trust='VETTED')
        self.assertEqual(self.whoami(svc, 'LABEL', 'AS', 'TOKEN', good)[b'label'], b'S//A;VETTED')
        self.assertEqual(self.whoami(svc, 'LABEL', 'AS', 'TOKEN', good)[b'label'], b'S//A;VETTED')
        self.assertEqual(self.whoami(svc, 'LABEL', 'AS', 'TOKEN', token(TEST_SECRET, 'C;VETTED'))[b'label'], b'C;VETTED')
        statement_bad = good[:-2] + (b'00' if good[-2:] != b'00' else b'11')
        bad = [token(OTHER_SECRET, 'S//A'), token(TEST_SECRET, 'S//A', audience='elsewhere'),
               token(TEST_SECRET, 'S//A', expires_ms=int(time.time() * 1000) - 1), token(TEST_SECRET, 'S//B'),
               token(TEST_SECRET, 'NOPE'), token(TEST_SECRET, 'S//A', trust='AUDITED'), token(TEST_SECRET, 'S//A', extra='owner 7'),
               token(TEST_SECRET, 'C;VETTED', trust='VETTED'), statement_bad, b'not-a-token', b'00.00',
               token(TEST_SECRET, 'S//A', handle='00' * 16)]
        for value in bad:
            self.assertEqual(error_of(svc, 'LABEL', 'AS', 'TOKEN', value, 'GET', 'k'), TOKEN_ERROR)
        self.assertEqual(error_of(self.connect('app'), 'LABEL', 'AS', 'TOKEN', good, 'GET', 'k'), TOKEN_ERROR)
        handle = svc.call('LABEL', 'AS', 'C', 'CONTEXT', 'CREATE')
        bound = token(TEST_SECRET, 'C', handle=handle.decode())
        self.assertEqual(self.whoami(svc, 'LABEL', 'AS', 'TOKEN', bound)[b'label'], b'C')
        self.assertEqual(error_of(svc, 'LABEL', 'AS', 'TOKEN', token(TEST_SECRET, 'U', handle=handle.decode()), 'GET', 'k'), TOKEN_ERROR)
        svc.call('CONTEXT', 'DROP', handle)
        self.assertEqual(error_of(svc, 'LABEL', 'AS', 'TOKEN', bound, 'GET', 'k'), TOKEN_ERROR)
        c.call('ACL', 'SETUSER', 'svc', 'require-token')
        svc = self.connect('svc')
        self.assertEqual(self.whoami(svc, 'LABEL', 'AS', 'TOKEN', good)[b'require-token'], 1)
        for command in (('GET', 'k'), ('LABEL', 'AS', 'S//A', 'GET', 'k'), ('LABEL', 'AS', 'CONTEXT', '00' * 16, 'GET', 'k')):
            self.assertEqual(error_of(svc, *command), 'ERR this login must send every command through LABEL AS TOKEN')
        self.assertEqual(error_of(svc, 'LABEL', 'SESSION', 'C'), 'ERR LABEL SESSION is not available to this login')
        self.assertEqual(svc.call('PING'), 'PONG')
        c.call('ACL', 'SETUSER', 'svc', 'reset-token-keys', 'token-key:' + token_key(OTHER_SECRET).hex())
        self.assertEqual(error_of(svc, 'LABEL', 'AS', 'TOKEN', good, 'GET', 'k'), TOKEN_ERROR)
        self.assertEqual(self.whoami(svc, 'LABEL', 'AS', 'TOKEN', token(OTHER_SECRET, 'U'))[b'label'], b'U')

    def test_label_per_command_logins(self):
        self.admin.call('ACL', 'SETUSER', 'pool', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:S//A', 'label-per-command')
        pool = self.connect('pool')
        refused = 'ERR this login must send every command through LABEL AS'
        for command in (('GET', 'k'), ('SET', 'k', 'v'), ('MULTI',), ('SUBSCRIBE', 'ch'), ('INFO',), ('CLIENT', 'LIST')):
            self.assertEqual(error_of(pool, *command), refused)
        for command in (('PING',), ('ECHO', 'x'), ('SELECT', 0), ('CLIENT', 'SETNAME', 'p'), ('CLIENT', 'ID'), ('LABEL', 'WHOAMI'), ('HELLO', 2)):
            pool.call(*command)
        self.assertEqual(error_of(pool, 'LABEL', 'SESSION', 'C'), 'ERR LABEL SESSION is not available to this login')
        self.assertEqual(pool.call('LABEL', 'AS', 'C', 'SET', 'k', 'v'), 'OK')
        self.assertEqual(pool.call('LABEL', 'AS', 'C', 'MULTI'), 'OK')
        self.assertEqual(pool.call('GET', 'k'), 'QUEUED')
        self.assertEqual(pool.call('LABEL', 'WHOAMI'), 'QUEUED')
        replies = pool.call('EXEC')
        self.assertEqual(replies[0], b'v')
        self.assertEqual(as_map(replies[1])[b'label'], b'C')
        self.assertEqual(error_of(pool, 'LABEL', 'AS', 'C', 'SUBSCRIBE', 'ch'), 'ERR this command needs a session label set with LABEL SESSION')

    def test_multi_binds_the_transaction_label(self):
        app = self.connect('app')
        self.assertEqual(app.call('LABEL', 'AS', 'C', 'MULTI'), 'OK')
        self.assertEqual(app.call('LABEL', 'WHOAMI'), 'QUEUED')
        self.assertEqual(app.call('LABEL', 'AS', 'C', 'LABEL', 'WHOAMI'), 'QUEUED')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'U', 'GET', 'k'), "ERR the command's label differs from the transaction's label")
        self.assertTrue(error_of(app, 'EXEC').startswith('EXECABORT'))
        app.call('MULTI')
        app.call('LABEL', 'AS', 'S//A', 'LABEL', 'WHOAMI')
        app.call('LABEL', 'WHOAMI')
        self.assertEqual([as_map(r)[b'label'] for r in app.call('EXEC')], [b'S//A', b'S//A'])
        app.call('LABEL', 'AS', 'C', 'MULTI')
        app.call('LABEL', 'WHOAMI')
        text = error_of(app, 'LABEL', 'AS', 'U', 'EXEC')
        self.assertEqual(text, "EXECABORT Transaction discarded because of: the command's label differs from the transaction's label")
        app.call('LABEL', 'AS', 'C', 'MULTI')
        app.call('LABEL', 'WHOAMI')
        self.assertEqual(as_map(app.call('LABEL', 'AS', 'C', 'EXEC')[0])[b'label'], b'C')
        app.call('LABEL', 'AS', 'U', 'MULTI')
        self.assertEqual(error_of(app, 'SAVE'), PERSIST_ERROR)
        self.assertEqual(error_of(app, 'DEBUG', 'SLEEP', 0), TOP_ERROR)
        self.assertTrue(error_of(app, 'EXEC').startswith('EXECABORT'))

    def test_a_watch_made_under_another_login_refuses_exec(self):
        self.admin.call('ACL', 'SETUSER', 'twin', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:S//A')
        outcomes = []
        for hidden in (False, True):
            c = self.connect('app')
            self.admin.call('LABEL', 'AS', 'S//A', 'SET', 'w', 'before')
            self.assertEqual(c.call('WATCH', 'w'), 'OK')
            if hidden:
                self.admin.call('LABEL', 'AS', 'S//A', 'SET', 'w', 'after')
            self.assertEqual(c.call('AUTH', 'low', 'x'), 'OK')
            self.assertEqual(self.whoami(c)[b'label'], b'C')
            self.assertEqual(c.call('MULTI'), 'OK')
            self.assertEqual(c.call('SET', 'probe', 1), 'QUEUED')
            c.send('EXEC')
            outcomes.append(str(c.reply()))
            self.assertIsNone(self.admin.call('LABEL', 'AS', 'C', 'GET', 'probe'))
            self.admin.call('LABEL', 'AS', 'S//A', 'DEL', 'w')
        self.assertEqual(outcomes, [WATCH_REFUSED, WATCH_REFUSED])
        c = self.connect('app')
        self.assertEqual(c.call('WATCH', 'w'), 'OK')
        self.assertEqual(c.call('AUTH', 'twin', 'x'), 'OK')
        self.assertEqual(c.call('MULTI'), 'OK')
        self.assertEqual(c.call('SET', 'probe', 2), 'QUEUED')
        self.assertEqual(c.call('EXEC'), ['OK'])
        self.assertEqual(self.admin.call('LABEL', 'AS', 'S//A', 'GET', 'probe'), b'2')

    def test_scripts_run_at_the_caller_label(self):
        app = self.connect('app')
        script = "return redis.call('LABEL', 'WHOAMI')"
        self.assertEqual(as_map(app.call('LABEL', 'AS', 'C', 'EVAL', script, 0))[b'label'], b'C')
        self.assertEqual(as_map(app.call('EVAL', script, 0))[b'label'], b'S//A')
        for body in ("return redis.call('LABEL', 'AS', 'U', 'GET', 'k')", "return redis.call('LABEL', 'SESSION', 'U')",
                     "return redis.call('CONTEXT', 'CREATE')"):
            self.assertIn('This command is not allowed from script', error_of(app, 'EVAL', body, 0))
        app.call('LABEL', 'AS', 'S//A', 'SET', 'k', 'v')
        self.assertIn('persistence is off', error_of(app, 'EVAL', "return redis.call('DUMP', 'k')", 0))
        self.assertIn('dominates the whole label scheme', error_of(app, 'EVAL', "return redis.call('SWAPDB', 0, 1)", 0))
        self.assertEqual(self.admin.call('EVAL', "return redis.call('SWAPDB', 0, 1)", 0), 'OK')
        self.assertEqual(as_map(app.call('LABEL', 'AS', 'U', 'EVAL_RO', script, 0))[b'label'], b'U')

    def test_pubsub_delivers_only_to_dominating_subscribers(self):
        low = self.connect('peer', protocol=3)
        low.call('LABEL', 'SESSION', 'C')
        push_of(low, 'SUBSCRIBE', 'news')
        push_of(low, 'PSUBSCRIBE', 'n*')
        push_of(low, 'SSUBSCRIBE', 'shard')
        high = self.connect('peer', protocol=3)
        high.call('LABEL', 'SESSION', 'S//A/B')
        push_of(high, 'SUBSCRIBE', 'news')
        trusted = self.connect('peer', protocol=3)
        trusted.call('LABEL', 'SESSION', 'S//A/B', 'TRUST', 'VETTED')
        push_of(trusted, 'SUBSCRIBE', 'news')
        pub = self.connect('peer')
        self.assertEqual(pub.call('LABEL', 'AS', 'C', 'PUBLISH', 'news', 'c-msg'), 2)
        self.assertEqual(pub.call('LABEL', 'AS', 'S//A', 'PUBLISH', 'news', 's-msg'), 0)
        self.assertEqual(pub.call('LABEL', 'AS', 'S//A/B', 'PUBLISH', 'news', 'sab-msg'), 1)
        self.assertEqual(pub.call('LABEL', 'AS', 'U', 'TRUST', 'VETTED', 'PUBLISH', 'news', 'vetted-msg'), 0)
        self.assertEqual(pub.call('LABEL', 'AS', 'C', 'SPUBLISH', 'shard', 'c-shard'), 1)
        self.assertEqual(pub.call('LABEL', 'AS', 'S//A', 'SPUBLISH', 'shard', 's-shard'), 0)
        time.sleep(0.3)

        def messages(client):
            seen = []
            while client.available(0.2):
                value = client.read()
                if isinstance(value, Push) and value[0] in (b'message', b'pmessage', b'smessage'):
                    seen.append((value[0], value[-1]))
            return sorted(seen)
        self.assertEqual(messages(low), [(b'message', b'c-msg'), (b'message', b'vetted-msg'), (b'pmessage', b'c-msg'),
                                         (b'pmessage', b'vetted-msg'), (b'smessage', b'c-shard')])
        self.assertEqual(messages(high), [(b'message', b'c-msg'), (b'message', b's-msg'), (b'message', b'sab-msg'), (b'message', b'vetted-msg')])
        self.assertEqual(messages(trusted), [(b'message', b'vetted-msg')])
        u = self.connect('peer')
        self.assertEqual(u.call('LABEL', 'AS', 'U', 'PUBSUB', 'NUMSUB', 'news'), [b'news', 0])
        self.assertEqual(u.call('LABEL', 'AS', 'U', 'PUBSUB', 'CHANNELS'), [])
        self.assertEqual(u.call('LABEL', 'AS', 'U', 'PUBSUB', 'NUMPAT'), 0)
        self.assertEqual(u.call('LABEL', 'AS', 'U', 'PUBSUB', 'SHARDCHANNELS'), [])
        self.assertEqual(u.call('LABEL', 'AS', 'C', 'PUBSUB', 'NUMSUB', 'news'), [b'news', 1])
        self.assertEqual(u.call('LABEL', 'AS', 'C', 'PUBSUB', 'NUMPAT'), 1)
        self.assertEqual(u.call('LABEL', 'AS', 'C', 'PUBSUB', 'SHARDNUMSUB', 'shard'), [b'shard', 1])
        self.assertEqual(u.call('LABEL', 'AS', 'S//A/B', 'PUBSUB', 'NUMSUB', 'news'), [b'news', 3])
        self.assertEqual(u.call('LABEL', 'AS', 'S//A/B', 'TRUST', 'VETTED', 'PUBSUB', 'NUMSUB', 'news'), [b'news', 1])
        self.assertEqual(u.call('LABEL', 'AS', 'C', 'PUBSUB', 'CHANNELS'), [b'news'])
        self.assertEqual(self.admin.call('PUBSUB', 'NUMSUB', 'news'), [b'news', 3])
        self.assertEqual(self.admin.call('LABEL', 'AS', 'U', 'PUBSUB', 'NUMSUB', 'news'), [b'news', 0])

    def pushed(self, client):
        seen = []
        while client.available(0.3):
            value = client.read()
            if isinstance(value, Push) and value[0] in (b'message', b'pmessage', b'smessage', b'invalidate'):
                seen.append((value[0], value[-1]))
        return sorted(seen)

    def test_an_implicit_subscribe_pins_the_login_label(self):
        sub = self.connect('peer', protocol=3)
        self.assertEqual(self.whoami(sub)[b'session'], 0)
        push_of(sub, 'SUBSCRIBE', 'news')
        who = self.whoami(sub)
        self.assertEqual((who[b'label'], who[b'session']), (b'S//A/B', 1))
        pattern = self.connect('peer', protocol=3)
        push_of(pattern, 'PSUBSCRIBE', 'n*')
        shard = self.connect('peer', protocol=3)
        push_of(shard, 'SSUBSCRIBE', 'news')
        for client in (pattern, shard):
            self.assertEqual(self.whoami(client)[b'session'], 1)
        self.assertEqual(self.admin.call('LABEL', 'AS', 'C', 'PUBLISH', 'news', 'low'), 0)
        self.assertEqual(self.admin.call('LABEL', 'AS', 'S//A/B', 'PUBLISH', 'news', 'same'), 2)
        self.assertEqual(self.admin.call('LABEL', 'AS', 'TOP SECRET', 'PUBLISH', 'news', 'high'), 0)
        self.assertEqual(self.admin.call('LABEL', 'AS', 'C', 'SPUBLISH', 'news', 'shard-low'), 0)
        self.assertEqual(self.admin.call('LABEL', 'AS', 'S//A/B', 'SPUBLISH', 'news', 'shard-same'), 1)
        self.assertEqual(self.admin.call('LABEL', 'AS', 'TOP SECRET', 'SPUBLISH', 'news', 'shard-high'), 0)
        self.assertEqual(self.pushed(sub), [(b'message', b'low'), (b'message', b'same')])
        self.assertEqual(self.pushed(pattern), [(b'pmessage', b'low'), (b'pmessage', b'same')])
        self.assertEqual(self.pushed(shard), [(b'smessage', b'shard-low'), (b'smessage', b'shard-same')])
        self.assertEqual(self.admin.call('LABEL', 'AS', 'C', 'PUBSUB', 'NUMSUB', 'news'), [b'news', 0])
        self.assertEqual(self.admin.call('LABEL', 'AS', 'S//A/B', 'PUBSUB', 'NUMSUB', 'news'), [b'news', 1])
        sub_id = sub.call('CLIENT', 'ID')
        self.assertNotIn(b'id=%d ' % sub_id, self.admin.call('LABEL', 'AS', 'C', 'CLIENT', 'LIST'))
        self.assertIn(b'id=%d ' % sub_id, self.admin.call('LABEL', 'AS', 'S//A/B', 'CLIENT', 'LIST'))
        push_of(sub, 'UNSUBSCRIBE', 'news')
        self.assertEqual(self.whoami(sub)[b'session'], 1)
        self.admin.call('ACL', 'SETUSER', 'peer', 'clearance:S//A')
        self.assertTrue(closed(sub))
        self.assertTrue(closed(pattern))

    def test_a_prefix_or_a_per_command_login_keeps_the_session_error(self):
        needed = 'ERR this command needs a session label set with LABEL SESSION'
        app = self.connect('peer')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'C', 'SUBSCRIBE', 'ch'), needed)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'C', 'CLIENT', 'TRACKING', 'ON'), needed)
        self.assertEqual(self.whoami(app)[b'session'], 0)
        app.call('LABEL', 'AS', 'C', 'MULTI')
        self.assertEqual(error_of(app, 'SUBSCRIBE', 'ch'), needed)
        self.assertTrue(error_of(app, 'EXEC').startswith('EXECABORT'))
        self.assertEqual(self.whoami(app)[b'session'], 0)
        app.call('MULTI')
        self.assertEqual(app.call('SUBSCRIBE', 'ch'), 'QUEUED')
        self.assertEqual(app.call('EXEC'), [[b'subscribe', b'ch', 1]])
        self.assertEqual(app.call('PING'), [b'pong', b''])
        app.call('RESET')
        self.assertEqual(self.whoami(app)[b'session'], 0)
        self.admin.call('ACL', 'SETUSER', 'pool', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:S//A', 'label-per-command')
        pool = self.connect('pool')
        self.assertEqual(error_of(pool, 'SUBSCRIBE', 'ch'), 'ERR this login must send every command through LABEL AS')
        self.assertEqual(error_of(pool, 'LABEL', 'AS', 'C', 'SUBSCRIBE', 'ch'), needed)
        pool.call('LABEL', 'AS', 'C', 'MULTI')
        self.assertEqual(error_of(pool, 'SUBSCRIBE', 'ch'), needed)

    def test_a_push_command_the_acl_refuses_pins_nothing(self):
        self.admin.call('ACL', 'SETUSER', 'nosub', 'on', 'nopass', '+@all', '-subscribe', '-psubscribe', '-ssubscribe',
                        '-client|tracking', '~*', '&*', 'clearance:S//A')
        sub = self.connect('nosub')
        for command, name in ((('SUBSCRIBE', 'news'), 'subscribe'), (('PSUBSCRIBE', 'n*'), 'psubscribe'),
                              (('SSUBSCRIBE', 'news'), 'ssubscribe'), (('CLIENT', 'TRACKING', 'ON'), 'client|tracking')):
            self.assertEqual(error_of(sub, *command), "NOPERM User nosub has no permissions to run the '%s' command" % name)
            self.assertEqual(self.whoami(sub)[b'session'], 0)
        self.assertEqual(error_of(sub, 'SUBSCRIBE'), "ERR wrong number of arguments for 'subscribe' command")
        self.assertEqual(self.whoami(sub)[b'session'], 0)
        objects = [as_map(e)[b'object'] for e in self.admin.call('ACL', 'LOG') if as_map(e)[b'username'] == b'nosub']
        self.assertEqual(sorted(objects), [b'client|tracking', b'psubscribe', b'ssubscribe', b'subscribe'])
        self.admin.call('ACL', 'SETUSER', 'nochan', 'on', 'nopass', '+@all', '~*', 'resetchannels', '&other', 'clearance:S//A')
        channel = self.connect('nochan')
        self.assertEqual(error_of(channel, 'SUBSCRIBE', 'news'), 'NOPERM No permissions to access a channel')
        self.assertEqual(self.whoami(channel)[b'session'], 0)
        self.assertEqual(self.admin.call('ACL', 'SETUSER', 'nosub', '+subscribe'), 'OK')
        self.assertFalse(closed(sub))
        self.assertEqual(self.whoami(sub)[b'session'], 0)
        listener = self.connect('nosub', protocol=3)
        push_of(listener, 'SUBSCRIBE', 'news')
        who = self.whoami(listener)
        self.assertEqual((who[b'label'], who[b'session']), (b'S//A', 1))
        self.assertEqual(self.admin.call('LABEL', 'AS', 'S//A', 'PUBLISH', 'news', 'at'), 1)
        self.assertEqual(self.pushed(listener), [(b'message', b'at')])
        queued = self.connect('nosub')
        self.assertEqual(queued.call('MULTI'), 'OK')
        self.assertEqual(queued.call('SUBSCRIBE', 'more'), 'QUEUED')
        self.assertEqual(queued.call('EXEC'), [[b'subscribe', b'more', 1]])
        push_of(queued, 'UNSUBSCRIBE', 'more')
        self.assertEqual(self.whoami(queued)[b'session'], 1)

    def test_a_push_command_refused_after_admission_pins_nothing(self):
        low = self.connect('low')
        def unpinned():
            who = self.whoami(low)
            self.assertEqual((who[b'session'], who[b'label']), (0, b'C'))
        self.admin.call('CONFIG', 'SET', 'busy-reply-threshold', 50)
        script = self.connect('app')
        script.send('EVAL', 'while true do end', 0)
        time.sleep(0.3)
        for command in (('SUBSCRIBE', 'ch'), ('PSUBSCRIBE', 'c*'), ('SSUBSCRIBE', 'sh'), ('CLIENT', 'TRACKING', 'ON')):
            self.assertTrue(error_of(low, *command).startswith('BUSY'))
        self.assertEqual(self.admin.call('SCRIPT', 'KILL'), 'OK')
        self.assertIn('killed', str(script.reply()).lower())
        unpinned()
        self.admin.call('CONFIG', 'SET', 'maxmemory', 1)
        for command in (('SUBSCRIBE', 'ch'), ('PSUBSCRIBE', 'c*'), ('SSUBSCRIBE', 'sh')):
            self.assertTrue(error_of(low, *command).startswith('OOM'))
        self.admin.call('CONFIG', 'SET', 'maxmemory', 0)
        unpinned()
        self.assertTrue(error_of(low, 'CLIENT', 'TRACKING', 'ON', 'REDIRECT', 999999).startswith('ERR'))
        self.assertTrue(error_of(low, 'CLIENT', 'TRACKING', 'ON', 'BCAST', 'PREFIX', 'a', 'PREFIX', 'ab').startswith('ERR'))
        unpinned()
        self.assertEqual(low.call('MULTI'), 'OK')
        self.assertEqual(low.call('CLIENT', 'TRACKING', 'ON', 'REDIRECT', 999999), 'QUEUED')
        self.assertTrue(str(low.call('EXEC')[0]).startswith('ERR'))
        unpinned()
        self.assertEqual(low.call('MULTI'), 'OK')
        self.assertEqual(low.call('CLIENT', 'TRACKING', 'ON'), 'QUEUED')
        self.assertEqual(low.call('EXEC'), ['OK'])
        who = self.whoami(low)
        self.assertEqual((who[b'session'], who[b'label']), (1, b'C'))
        other = self.connect('low', protocol=3)
        push_of(other, 'SUBSCRIBE', 'ch')
        self.assertEqual(self.whoami(other)[b'session'], 1)

    def test_client_tracking_pins_the_login_label(self):
        tracker = self.connect('peer', protocol=3)
        self.assertEqual(tracker.call('CLIENT', 'TRACKING', 'ON'), 'OK')
        self.assertEqual((self.whoami(tracker)[b'label'], self.whoami(tracker)[b'session']), (b'S//A/B', 1))
        self.assertIsNone(tracker.call('GET', 'seen'))
        self.assertIsNone(tracker.call('GET', 'hidden'))
        self.admin.call('LABEL', 'AS', 'TOP SECRET', 'SET', 'hidden', 1)
        self.admin.call('LABEL', 'AS', 'C', 'SET', 'seen', 1)
        self.assertEqual(self.pushed(tracker), [(b'invalidate', [b'seen'])])
        self.assertEqual(tracker.call('CLIENT', 'TRACKING', 'OFF'), 'OK')
        self.assertEqual(self.whoami(tracker)[b'session'], 1)

    def test_auth_repins_or_closes_a_connection_that_holds_push_state(self):
        sub = self.connect('peer', protocol=3)
        push_of(sub, 'SUBSCRIBE', 'news')
        self.assertEqual(sub.call('AUTH', 'low', 'x'), 'OK')
        who = self.whoami(sub)
        self.assertEqual((who[b'login'], who[b'label'], who[b'session']), (b'low', b'C', 1))
        self.assertEqual(self.admin.call('LABEL', 'AS', 'S//A', 'PUBLISH', 'news', 'above'), 0)
        self.assertEqual(self.admin.call('LABEL', 'AS', 'C', 'PUBLISH', 'news', 'at'), 1)
        self.assertEqual(self.pushed(sub), [(b'message', b'at')])
        quiet = self.connect('peer', protocol=3)
        quiet.call('AUTH', 'low', 'x')
        self.assertEqual(self.whoami(quiet)[b'session'], 0)
        self.admin.call('ACL', 'SETUSER', 'pool', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:S//A', 'label-per-command')
        tracker = self.connect('peer', protocol=3)
        self.assertEqual(tracker.call('CLIENT', 'TRACKING', 'ON'), 'OK')
        tracker.send('AUTH', 'pool', 'x')
        self.assertEqual(tracker.reply(), 'OK')
        self.assertTrue(closed(tracker))

    def test_server_wide_introspection_is_top_only_or_filtered(self):
        app = self.connect('app')
        for command in (('MONITOR',), ('LATENCY', 'LATEST'), ('SWAPDB', 0, 1), ('DEBUG', 'SLEEP', 0), ('CLIENT', 'PAUSE', 10),
                        ('CLIENT', 'UNPAUSE'), ('MEMORY', 'STATS'), ('SLOWLOG', 'RESET'), ('CONFIG', 'RESETSTAT')):
            self.assertEqual(error_of(app, *command), TOP_ERROR)
        self.assertEqual(self.admin.call('LATENCY', 'LATEST'), [])
        self.assertEqual(self.admin.call('SWAPDB', 0, 1), 'OK')
        secret = self.connect('peer')
        secret.call('LABEL', 'SESSION', 'S//A/B')
        secret.call('CLIENT', 'SETNAME', 'secret-one')
        low = self.connect('low')
        low.call('CLIENT', 'SETNAME', 'low-one')
        names = lambda text: sorted(f.split('=', 1)[1] for f in text.decode().split() if f.startswith('name=') and f != 'name=')
        self.assertEqual(names(low.call('CLIENT', 'LIST')), ['low-one'])
        self.assertIn('secret-one', names(self.admin.call('CLIENT', 'LIST')))
        secret_id = secret.call('CLIENT', 'ID')
        self.assertEqual(low.call('CLIENT', 'LIST', 'ID', secret_id), b'')
        self.assertEqual(low.call('CLIENT', 'KILL', 'ID', secret_id), 0)
        self.assertEqual(low.call('CLIENT', 'UNBLOCK', secret_id), 0)
        self.assertFalse(closed(secret))
        self.assertEqual(self.admin.call('CLIENT', 'KILL', 'ID', secret_id), 1)
        stats = info(low, 'stats')
        self.assertEqual((stats['total_commands_processed'], stats['instantaneous_input_kbps']), ('0', '0.00'))
        self.assertEqual(info(low, 'memory')['used_memory_human'], '0B')
        self.assertEqual(info(low, 'clients')['connected_clients'], '1')
        self.assertEqual(int(info(self.admin, 'clients')['connected_clients']), 3)
        self.assertEqual(low.call('INFO', 'commandstats'), b'# Commandstats\r\n')
        self.assertNotEqual(info(self.admin, 'stats')['total_commands_processed'], '0')
        self.assertEqual(info(low, 'server')['redis_version'], info(self.admin, 'server')['redis_version'])
        self.assertTrue(isinstance(self.admin.call('ACL', 'LOG'), list))

    def test_monitor_and_slowlog_carry_labels(self):
        monitor = Client(self.server.port)
        self.addCleanup(monitor.close)
        self.assertEqual(monitor.call('MONITOR'), 'OK')
        app = self.connect('app')
        app.call('LABEL', 'AS', 'U', 'ECHO', 'visible-to-top')
        self.admin.call('CONFIG', 'SET', 'label-compartments', 'A,B,NEW')
        self.admin.call('ACL', 'SETUSER', 'app', 'clearance:S//A/NEW')
        app = self.connect('app')
        app.call('LABEL', 'AS', 'S//NEW', 'ECHO', 'hidden-from-monitor')
        app.call('LABEL', 'AS', 'U', 'ECHO', 'second-visible')
        time.sleep(0.3)
        seen = b''
        while monitor.available(0.2):
            seen += monitor.socket.recv(65536)
        self.assertIn(b'visible-to-top', seen)
        self.assertIn(b'second-visible', seen)
        self.assertNotIn(b'hidden-from-monitor', seen)
        self.admin.call('CONFIG', 'SET', 'slowlog-log-slower-than', 0)
        self.admin.call('SLOWLOG', 'RESET')
        app.call('LABEL', 'AS', 'S//A', 'ECHO', 'slow-secret')
        app.call('LABEL', 'AS', 'U', 'ECHO', 'slow-public')
        public = [entry[3] for entry in app.call('LABEL', 'AS', 'U', 'SLOWLOG', 'GET', -1)]
        self.assertIn([b'ECHO', b'slow-public'], public)
        self.assertNotIn([b'ECHO', b'slow-secret'], public)
        secret = [entry[3] for entry in app.call('LABEL', 'AS', 'S//A', 'SLOWLOG', 'GET', -1)]
        self.assertIn([b'ECHO', b'slow-secret'], secret)
        self.assertEqual(app.call('LABEL', 'AS', 'U', 'SLOWLOG', 'LEN'), len(public) + 1)
        self.assertGreater(self.admin.call('SLOWLOG', 'LEN'), len(public))
        self.assertEqual(len(app.call('LABEL', 'AS', 'U', 'SLOWLOG', 'GET', 1)), 1)

    def test_persistence_is_refused_in_one_place(self):
        c = self.admin
        c.call('SET', 'k', 'v')
        for command in (('SAVE',), ('BGSAVE',), ('BGSAVE', 'SCHEDULE'), ('BGREWRITEAOF',), ('DUMP', 'k'),
                        ('RESTORE', 'x', 0, 'payload'), ('MIGRATE', '127.0.0.1', 1, 'k', 0, 10), ('DEBUG', 'RELOAD'),
                        ('DEBUG', 'LOADAOF'), ('SHUTDOWN', 'SAVE')):
            self.assertEqual(error_of(c, *command), PERSIST_ERROR)
        self.assertEqual(c.call('PING'), 'PONG')
        self.assertEqual(info(c, 'persistence')['rdb_bgsave_in_progress'], '0')
        self.assertFalse(list(Path(self.server.directory).glob('*.rdb')))

    def test_acl_changes_evict_connections_beyond_the_new_clearance(self):
        app = self.connect('app')
        app.call('LABEL', 'SESSION', 'S//A')
        kept = self.connect('app')
        kept.call('LABEL', 'SESSION', 'C')
        self.admin.call('ACL', 'SETUSER', 'app', 'clearance:S')
        self.assertTrue(closed(app))
        self.assertFalse(closed(kept))
        self.assertEqual(self.whoami(self.connect('app'))[b'clearance'], b'S')

    def test_audit_records_scheme_and_acl_changes(self):
        self.admin.call('ACL', 'SETUSER', 'audited', 'on', '>hunter2', '+get', 'clearance:C')
        self.admin.call('CONFIG', 'SET', 'label-compartments', 'A,B,X')
        self.admin.call('ACL', 'DELUSER', 'audited')
        mode = stat.S_IMODE(os.stat(self.audit).st_mode)
        self.assertEqual(mode, 0o600)
        text = self.audit.read_text()
        self.assertNotIn('hunter2', text)
        records = [json.loads(line) for line in text.splitlines()]
        events = [r['event'] for r in records]
        self.assertEqual(events[0], 'scheme-load')
        self.assertIn('acl-setuser', events)
        self.assertIn('acl-deluser', events)
        change = [r for r in records if r['event'] == 'scheme-change'][-1]
        self.assertEqual(change['details'], {'kind': 'compartments', 'before': 'A,B', 'after': 'A,B,X'})
        setuser = [r for r in records if r['event'] == 'acl-setuser' and r['details']['user'] == 'audited'][0]
        self.assertEqual(setuser['details']['rules'], 'on >(redacted) +get clearance:C')
        self.assertEqual(setuser['login'], 'default')
        self.assertTrue(all(isinstance(r['time'], int) for r in records))


    def test_busy_script_commands_run_at_their_own_label(self):
        self.admin.call('CONFIG', 'SET', 'busy-reply-threshold', 50)
        script = self.connect('app')
        script.send('LABEL', 'AS', 'S//A', 'EVAL', 'while true do end', 0)
        time.sleep(0.3)
        low = self.connect('low')
        self.assertEqual(error_of(low, 'SCRIPT', 'KILL'), "ERR this command needs a label that dominates the running script's label")
        self.assertTrue(error_of(low, 'PING').startswith('BUSY'))
        peer = self.connect('peer')
        self.assertEqual(error_of(peer, 'LABEL', 'AS', 'S//B', 'SCRIPT', 'KILL'), "ERR this command needs a label that dominates the running script's label")
        self.assertEqual(peer.call('LABEL', 'AS', 'S//A/B', 'SCRIPT', 'KILL'), 'OK')
        self.assertIn('killed', str(script.reply()).lower())
        self.assertEqual(script.call('PING'), 'PONG')
        self.admin.call('FUNCTION', 'LOAD', "#!lua name=spin\nredis.register_function('spin', function() while true do end end)")
        script.send('LABEL', 'AS', 'C', 'FCALL', 'spin', 0)
        time.sleep(0.3)
        self.assertEqual(as_map(as_map(low.call('FUNCTION', 'STATS'))[b'running_script'])[b'name'], b'spin')
        vetted = self.connect('app')
        self.assertIsNone(as_map(vetted.call('LABEL', 'AS', 'S//A', 'TRUST', 'VETTED', 'FUNCTION', 'STATS'))[b'running_script'])
        self.assertEqual(error_of(vetted, 'LABEL', 'AS', 'S//A', 'TRUST', 'VETTED', 'FUNCTION', 'KILL'),
                         "ERR this command needs a label that dominates the running script's label")
        self.assertEqual(low.call('FUNCTION', 'KILL'), 'OK')
        self.assertIn('killed', str(script.reply()).lower())
        script.send('LABEL', 'AS', 'S//A', 'FCALL', 'spin', 0)
        time.sleep(0.3)
        self.assertIsNone(as_map(low.call('FUNCTION', 'STATS'))[b'running_script'])
        self.assertEqual(error_of(low, 'FUNCTION', 'KILL'), "ERR this command needs a label that dominates the running script's label")
        self.assertEqual(as_map(as_map(self.admin.call('FUNCTION', 'STATS'))[b'running_script'])[b'name'], b'spin')
        self.assertEqual(self.admin.call('FUNCTION', 'KILL'), 'OK')
        self.assertIn('killed', str(script.reply()).lower())
        self.assertEqual(as_map(script.call('LABEL', 'WHOAMI'))[b'label'], b'S//A')
        self.admin.call('FUNCTION', 'FLUSH')

    def test_context_create_needs_admin_or_dangerous_rights(self):
        c = self.admin
        for name, rules, allowed in (('all-but-dangerous', ('+@all', '-@dangerous'), False), ('all-but-admin', ('+@all', '-@admin'), False),
                                     ('slow-only', ('+@slow',), False), ('connection-only', ('+@connection',), False),
                                     ('everything', ('+@all',), True), ('explicit', ('+context|create',), True),
                                     ('dangerous', ('+@dangerous',), True)):
            c.call('ACL', 'SETUSER', name, 'on', 'nopass', *rules, '~*', 'clearance:S')
            reply = c.call('ACL', 'DRYRUN', name, 'CONTEXT', 'CREATE')
            self.assertEqual(reply == 'OK', allowed, (name, reply))
        self.assertEqual(c.call('ACL', 'DRYRUN', 'all-but-dangerous', 'CONTEXT', 'INFO', '00' * 16), 'OK')
        self.assertIn(b'context|create', c.call('ACL', 'CAT', 'dangerous'))
        self.assertIn(b'context|create', c.call('ACL', 'CAT', 'admin'))
        self.assertNotIn(b'context|create', c.call('ACL', 'CAT', 'slow'))
        info = c.call('COMMAND', 'INFO', 'context|create')[0]
        self.assertEqual(sorted(str(x) for x in info[6]), ['@admin', '@dangerous'])
        agent = self.connect('all-but-dangerous')
        self.assertEqual(error_of(agent, 'CONTEXT', 'CREATE'), "NOPERM User all-but-dangerous has no permissions to run the 'context|create' command")
        self.assertEqual(len(self.connect('explicit').call('CONTEXT', 'CREATE')), 32)

    def test_shutdown_options_cannot_save(self):
        for option in ('shutdown-on-sigterm', 'shutdown-on-sigint'):
            self.assertIn('persistence stays off', error_of(self.admin, 'CONFIG', 'SET', option, 'save'))
            self.assertIn('persistence stays off', error_of(self.admin, 'CONFIG', 'SET', option, 'save now'))
            self.assertEqual(self.admin.call('CONFIG', 'SET', option, 'nosave now'), 'OK')
            self.assertEqual(self.admin.call('CONFIG', 'SET', option, 'default'), 'OK')
        self.assertEqual(error_of(self.admin, 'SHUTDOWN', 'SAVE'), PERSIST_ERROR)
        self.assertEqual(error_of(self.admin, 'SHUTDOWN', 'NOW', 'SAVE'), PERSIST_ERROR)

    def test_label_state_counts_in_client_memory(self):
        def tot_mem(port):
            client = Client(port)
            try:
                text = client.call('CLIENT', 'INFO')
            finally:
                client.close()
            return int(dict(f.split('=', 1) for f in text.decode().split() if '=' in f)['tot-mem'])
        plain = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS)))
        self.addCleanup(plain.close)
        plain.start()
        labelled, unlabelled = tot_mem(self.server.port), tot_mem(plain.port)
        self.assertGreater(labelled, unlabelled)
        self.assertLess(labelled - unlabelled, 512)
        self.assertEqual(tot_mem(plain.port), unlabelled)
        before = int(info(self.admin, 'memory')['mem_clients_normal'])
        extra = [self.connect() for _ in range(8)]
        for x in extra:
            x.call('PING')
        self.assertGreaterEqual(int(info(self.admin, 'memory')['mem_clients_normal']) - before, 8 * (labelled - unlabelled))
        for x in extra:
            x.close()

    def test_a_read_only_evalsha_waits_out_a_write_pause(self):
        app, other, admin = self.connect('app'), self.connect('app'), self.admin
        held = app.call('SCRIPT', 'LOAD', "#!lua flags=no-writes\nreturn 'ro'")
        hidden = self.connect('peer').call('LABEL', 'AS', 'S//B', 'SCRIPT', 'LOAD', "#!lua flags=no-writes\nreturn 'hidden'")
        self.assertEqual(app.call('SCRIPT', 'EXISTS', held, hidden), [1, 0])
        low = self.connect('low')
        for last in (admin, low):
            self.assertEqual(admin.call('CLIENT', 'PAUSE', 5000, 'WRITE'), 'OK')
            self.assertEqual(last.call('PING'), 'PONG')
            app.send('EVALSHA', held, 0)
            other.send('EVALSHA', hidden, 0)
            self.assertFalse(app.available(0.5))
            self.assertFalse(other.available(0.1))
            self.assertEqual(admin.call('CLIENT', 'UNPAUSE'), 'OK')
            self.assertEqual(app.reply(), b'ro')
            self.assertEqual(str(other.reply()), 'NOSCRIPT No matching script. Please use EVAL.')
        self.assertEqual(app.call('EVALSHA_RO', held, 0), b'ro')

    def test_a_write_pause_sees_through_the_label_prefix(self):
        admin = self.admin
        clients = [self.connect('app') for _ in range(8)]
        ro = "#!lua flags=no-writes\nreturn 'ro'"
        sha = clients[0].call('LABEL', 'AS', 'U', 'SCRIPT', 'LOAD', ro)
        writer_tx, reader_tx, wrapped_tx = clients[5], clients[6], clients[7]
        for tx, body in ((writer_tx, ('SET', 'k3', 'v')), (reader_tx, ('GET', 'k')), (wrapped_tx, ('SET', 'k4', 'v'))):
            self.assertEqual(tx.call('MULTI'), 'OK')
            self.assertEqual(tx.call('LABEL', 'AS', 'S//A', *body), 'QUEUED')
        self.assertEqual(admin.call('CLIENT', 'PAUSE', 5000, 'WRITE'), 'OK')
        held = [(clients[0], ('LABEL', 'AS', 'S//A', 'SET', 'k', 'v')), (clients[1], ('LABEL', 'AS', 'U', 'EVALSHA', sha, 0)),
                (writer_tx, ('EXEC',)), (wrapped_tx, ('LABEL', 'AS', 'S//A', 'EXEC'))]
        free = [(clients[2], ('LABEL', 'AS', 'U', 'GET', 'k'), None), (clients[3], ('LABEL', 'AS', 'C', 'EVAL', ro, 0), b'ro'),
                (reader_tx, ('EXEC',), [None]), (clients[4], ('LABEL', 'AS', 'C', 'EVAL_RO', "return 'ro'", 0), b'ro')]
        for client, command in held:
            client.send(*command)
        for client, command, reply in free:
            self.assertEqual(client.call(*command), reply)
        self.assertEqual(error_of(clients[4], 'LABEL', 'AS', 'NOPE', 'SET', 'k', 'v'), INVALID)
        self.assertEqual(error_of(clients[4], 'LABEL', 'AS', 'S//A'), "ERR wrong number of arguments for 'label|as' command")
        self.assertEqual(error_of(clients[4], 'LABEL', 'AS', 'S//A', 'LABEL', 'AS', 'U', 'SET', 'k', 'v'), 'ERR LABEL AS cannot wrap LABEL AS or LABEL SESSION')
        for client, _ in held:
            self.assertFalse(client.available(0.3))
        self.assertIsNone(admin.call('LABEL', 'AS', 'S//A', 'GET', 'k'))
        self.assertEqual(admin.call('CLIENT', 'UNPAUSE'), 'OK')
        self.assertEqual([client.reply() for client, _ in held], ['OK', b'ro', ['OK'], ['OK']])
        self.assertEqual(admin.call('LABEL', 'AS', 'S//A', 'GET', 'k'), b'v')
        for client in clients:
            self.assertEqual(self.whoami(client)[b'session'], 0)

    def test_function_changes_need_top(self):
        app, admin = self.connect('app'), self.admin
        library = "#!lua name=lib\nredis.register_function('f', function() return 'one' end)"
        replaced = "#!lua name=lib\nredis.register_function('f', function() return 'two' end)"
        for command in (('FUNCTION', 'LOAD', library), ('FUNCTION', 'LOAD', 'REPLACE', library), ('FUNCTION', 'DELETE', 'lib'),
                        ('FUNCTION', 'FLUSH'), ('FUNCTION', 'FLUSH', 'ASYNC'), ('FUNCTION', 'RESTORE', b'\x00'), ('SCRIPT', 'FLUSH')):
            self.assertEqual(error_of(app, *command), TOP_ERROR)
            self.assertEqual(error_of(app, 'LABEL', 'AS', 'U', *command), TOP_ERROR)
        self.assertEqual(app.call('MULTI'), 'OK')
        self.assertEqual(error_of(app, 'FUNCTION', 'LOAD', library), TOP_ERROR)
        self.assertTrue(error_of(app, 'EXEC').startswith('EXECABORT'))
        admin.call('ACL', 'SETUSER', 'nofunction', 'on', 'nopass', '+@all', '-function', '~*', 'clearance:*')
        self.assertEqual(error_of(self.connect('nofunction'), 'FUNCTION', 'LOAD', library),
                         "NOPERM User nofunction has no permissions to run the 'function|load' command")
        self.assertEqual(admin.call('FUNCTION', 'LOAD', library), b'lib')
        self.assertEqual(app.call('LABEL', 'AS', 'U', 'FCALL', 'f', 0), b'one')
        self.assertEqual(app.call('FCALL', 'f', 0), b'one')
        self.assertEqual(as_map(app.call('FUNCTION', 'LIST', 'WITHCODE')[0])[b'library_code'], library.encode())
        engines = as_map(as_map(app.call('FUNCTION', 'STATS'))[b'engines'])
        self.assertEqual(as_map(engines[b'LUA'])[b'functions_count'], 1)
        dump = app.call('FUNCTION', 'DUMP')
        self.assertEqual(admin.call('FUNCTION', 'LOAD', 'REPLACE', replaced), b'lib')
        self.assertEqual(app.call('FCALL', 'f', 0), b'two')
        self.assertEqual(error_of(app, 'FUNCTION', 'RESTORE', dump, 'REPLACE'), TOP_ERROR)
        self.assertEqual(app.call('FCALL', 'f', 0), b'two')
        self.assertEqual(admin.call('FUNCTION', 'RESTORE', dump, 'REPLACE'), 'OK')
        self.assertEqual(app.call('FCALL', 'f', 0), b'one')
        self.assertEqual(admin.call('FUNCTION', 'DELETE', 'lib'), 'OK')
        self.assertEqual(error_of(app, 'FCALL', 'f', 0), 'ERR Function not found')
        self.assertEqual(admin.call('FUNCTION', 'FLUSH'), 'OK')
        self.assertEqual(admin.call('SCRIPT', 'FLUSH'), 'OK')

    def test_scripts_are_cached_per_label(self):
        app, peer, admin = self.connect('app'), self.connect('peer'), self.admin
        high = app.call('LABEL', 'AS', 'S//A', 'SCRIPT', 'LOAD', "return 'high'")
        self.assertEqual(high, hashlib.sha1(b"return 'high'").hexdigest().encode())
        self.assertEqual(app.call('LABEL', 'AS', 'S//A', 'SCRIPT', 'EXISTS', high), [1])
        for prefix in (('LABEL', 'AS', 'U'), ('LABEL', 'AS', 'C'), ('LABEL', 'AS', 'S')):
            self.assertEqual(app.call(*prefix, 'SCRIPT', 'EXISTS', high, high.upper()), [0, 0])
            self.assertEqual(error_of(app, *prefix, 'EVALSHA', high, 0), 'NOSCRIPT No matching script. Please use EVAL.')
            self.assertEqual(error_of(app, *prefix, 'EVALSHA_RO', high, 0), 'NOSCRIPT No matching script. Please use EVAL.')
        self.assertEqual(error_of(peer, 'LABEL', 'AS', 'S//B', 'EVALSHA', high, 0), 'NOSCRIPT No matching script. Please use EVAL.')
        self.assertEqual(peer.call('LABEL', 'AS', 'S//A/B', 'EVALSHA', high, 0), b'high')
        self.assertEqual(app.call('LABEL', 'AS', 'C', 'EVAL', "return 'high'", 0), b'high')
        self.assertEqual(app.call('LABEL', 'AS', 'C', 'EVALSHA', high, 0), b'high')
        self.assertEqual(app.call('LABEL', 'AS', 'C', 'SCRIPT', 'EXISTS', high), [1])
        self.assertEqual(app.call('LABEL', 'AS', 'U', 'SCRIPT', 'EXISTS', high), [0])
        self.assertEqual(app.call('LABEL', 'AS', 'U', 'SCRIPT', 'LOAD', "return 'high'"), high)
        self.assertEqual(app.call('LABEL', 'AS', 'U', 'EVALSHA_RO', high, 0), b'high')
        low = app.call('LABEL', 'AS', 'U', 'SCRIPT', 'LOAD', "return 'low'")
        for prefix in (('LABEL', 'AS', 'C'), ('LABEL', 'AS', 'S//A'), ()):
            self.assertEqual(app.call(*prefix, 'SCRIPT', 'EXISTS', low), [1])
            self.assertEqual(app.call(*prefix, 'EVALSHA', low, 0), b'low')
        web = app.call('LABEL', 'AS', 'U', 'TRUST', 'WEB', 'SCRIPT', 'LOAD', "return 'web'")
        self.assertEqual(app.call('LABEL', 'AS', 'S//A', 'TRUST', 'VETTED', 'SCRIPT', 'EXISTS', web), [0])
        self.assertEqual(app.call('LABEL', 'AS', 'S//A', 'TRUST', 'WEB', 'SCRIPT', 'EXISTS', web), [1])
        side = peer.call('LABEL', 'AS', 'C//B', 'SCRIPT', 'LOAD', "return 'side'")
        self.assertEqual(app.call('LABEL', 'AS', 'S//A', 'SCRIPT', 'EXISTS', side), [0])
        self.assertEqual(admin.call('SCRIPT', 'EXISTS', high, low, web, side), [1, 1, 1, 1])
        self.assertEqual(admin.call('EVALSHA', side, 0), b'side')
        self.assertEqual(int(info(admin, 'memory')['number_of_cached_scripts']), 4)
        for field in ('number_of_cached_scripts', 'used_memory_scripts_eval', 'used_memory_scripts'):
            self.assertEqual(info(app, 'memory')[field], '0')
        self.assertEqual(info(app, 'stats')['evicted_scripts'], '0')
        self.assertEqual(app.call('MULTI'), 'OK')
        self.assertEqual(app.call('EVALSHA', side, 0), 'QUEUED')
        self.assertEqual(app.call('EVALSHA', low, 0), 'QUEUED')
        replies = app.call('EXEC')
        self.assertEqual((str(replies[0]), replies[1]), ('NOSCRIPT No matching script. Please use EVAL.', b'low'))

    def test_the_eval_cache_evicts_per_label(self):
        app, admin = self.connect('app'), self.admin
        kept = app.call('LABEL', 'AS', 'S//A', 'SCRIPT', 'LOAD', "return 'kept'")
        app.call('LABEL', 'AS', 'S//A', 'EVAL', "return 'oldest'", 0)
        app.call('LABEL', 'AS', 'U', 'EVAL', "return 'oldest'", 0)
        oldest = hashlib.sha1(b"return 'oldest'").hexdigest()
        app.pipeline([('LABEL', 'AS', 'U', 'EVAL', 'return %d' % i, 0) for i in range(500)])
        self.assertEqual(app.call('LABEL', 'AS', 'U', 'SCRIPT', 'EXISTS', oldest), [0])
        self.assertEqual(app.call('LABEL', 'AS', 'U', 'SCRIPT', 'EXISTS', hashlib.sha1(b'return 0').hexdigest()), [1])
        self.assertEqual(app.call('LABEL', 'AS', 'S//A', 'SCRIPT', 'EXISTS', oldest, kept), [1, 1])
        self.assertEqual(app.call('LABEL', 'AS', 'S//A', 'EVALSHA', oldest, 0), b'oldest')
        self.assertEqual(int(info(admin, 'stats')['evicted_scripts']), 1)
        self.assertEqual(int(info(admin, 'memory')['number_of_cached_scripts']), 502)
        app.pipeline([('LABEL', 'AS', 'S//A', 'EVAL', 'return %d' % i, 0) for i in range(1000, 1500)])
        self.assertEqual(app.call('LABEL', 'AS', 'S//A', 'SCRIPT', 'EXISTS', oldest, kept), [0, 1])
        self.assertEqual(app.call('LABEL', 'AS', 'U', 'SCRIPT', 'EXISTS', hashlib.sha1(b'return 0').hexdigest()), [1])
        self.assertEqual(int(info(admin, 'memory')['number_of_cached_scripts']), 1001)

    def scripted_world(self, hidden):
        server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS), '--label-stream-seed', '5') + SCHEME)
        self.addCleanup(server.close)
        server.start()
        admin = Client(server.port)
        self.addCleanup(admin.close)
        admin.call('ACL', 'SETUSER', 'default', 'clearance:*')
        admin.call('FUNCTION', 'LOAD', "#!lua name=lib\n"
                   "redis.register_function('draw', function() return {math.random(1000000), cjson.encode_max_depth(), cjson.encode({0.123456789012})} end)\n"
                   "redis.register_function('tune', function() math.randomseed(7); cjson.encode_max_depth(3); cjson.encode_number_precision(2) return 1 end)")
        observed = []
        settings = ("return {math.random(1000000), math.random(), cjson.encode_max_depth(), cjson.decode_max_depth(), "
                    "cjson.encode_number_precision(), tostring(cjson.encode_keep_buffer()), tostring(cjson.encode_invalid_numbers()), "
                    "tostring(cjson.decode_invalid_numbers()), {cjson.encode_sparse_array()}, cjson.encode({0.123456789012}), "
                    "collectgarbage('setpause', 120), collectgarbage('setstepmul', 300)}")
        tune = ("math.randomseed(3); cjson.encode_max_depth(2); cjson.decode_max_depth(2); cjson.encode_number_precision(3); "
                "cjson.encode_keep_buffer(false); cjson.encode_invalid_numbers(true); cjson.decode_invalid_numbers(false); "
                "cjson.encode_sparse_array(true, 1, 1); collectgarbage('setpause', 111); collectgarbage('setstepmul', 333); return math.random(10)")
        for step in range(6):
            if hidden:
                admin.call('LABEL', 'AS', 'S//A', 'EVAL', tune, 0)
                admin.call('LABEL', 'AS', 'S//A', 'FCALL', 'tune', 0)
                admin.call('LABEL', 'AS', 'S//A', 'EVAL', 'return math.random(100)', 0)
            observed.append(('settings', admin.call('LABEL', 'AS', 'C', 'EVAL', settings, 0)))
            observed.append(('function', admin.call('LABEL', 'AS', 'C', 'FCALL', 'draw', 0)))
            if step == 2:
                observed.append(('seeded', admin.call('LABEL', 'AS', 'C', 'EVAL', 'math.randomseed(11); return math.random(1000)', 0)))
        return observed

    def test_script_randomness_and_json_settings_stay_within_a_label(self):
        quiet = self.scripted_world(False)
        noisy = self.scripted_world(True)
        self.assertEqual(quiet, noisy)
        rows = [reply for kind, reply in quiet if kind == 'settings']
        self.assertEqual([(row[2], row[3], row[4], row[5], row[9], row[10], row[11]) for row in rows],
                         [(1000, 1000, 14, b'true', b'[0.123456789012]', 200, 200)] * 6)
        self.assertEqual(len({row[0] for row in rows}), 6)
        self.assertEqual([reply[1:] for kind, reply in quiet if kind == 'function'], [[1000, b'[0.123456789012]']] * 6)


class Startup(unittest.TestCase):
    def run_server(self, *arguments):
        directory = tempfile.TemporaryDirectory(prefix='eski-labels-start-')
        self.addCleanup(directory.cleanup)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        command = [str(BINARY)] + list(arguments) + ['--bind', '127.0.0.1', '--port', str(port), '--dir', directory.name]
        return subprocess.run(command, capture_output=True, timeout=20, text=True), directory.name, port

    def test_default_save_points_refuse_a_scheme(self):
        result, _, _ = self.run_server('--label-levels', 'U,S')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('a label scheme needs persistence off', result.stdout + result.stderr)
        result, _, _ = self.run_server('--label-levels', 'U,S', '--save', '', '--appendonly', 'yes')
        self.assertNotEqual(result.returncode, 0)
        for option in ('--shutdown-on-sigterm', '--shutdown-on-sigint'):
            result, _, _ = self.run_server('--label-levels', 'U,S', '--save', '', option, 'save')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('no save in shutdown-on-sigterm or shutdown-on-sigint', result.stdout + result.stderr)
        result, _, _ = self.run_server('--label-levels', 'U,CONTEXT', '--save', '')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('reserved', result.stdout + result.stderr)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            free = probe.getsockname()[1]
        result, _, _ = self.run_server('--label-levels', 'U,S', '--save', '', '--memcached-port', str(free))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('memcached endpoint off', result.stdout + result.stderr)

    def test_config_rewrite_keeps_the_scheme(self):
        directory = tempfile.TemporaryDirectory(prefix='eski-labels-rewrite-')
        self.addCleanup(directory.cleanup)
        conf = Path(directory.name) / 'eski.conf'
        conf.write_text('save ""\nappendonly no\nlabel-levels "U,TOP SECRET"\nlabel-compartments "A"\n')
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        process = subprocess.Popen([str(BINARY), str(conf), '--bind', '127.0.0.1', '--port', str(port), '--dir', directory.name],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            wait_for(lambda: self.ping(port), timeout=15, label='server started')
            client = Client(port)
            client.call('CONFIG', 'SET', 'label-trust-levels', 'WEB,VETTED')
            self.assertEqual(client.call('CONFIG', 'REWRITE'), 'OK')
            client.close()
            text = conf.read_text()
            self.assertIn('label-levels "U,TOP SECRET"', text)
            self.assertIn('label-compartments "A"', text)
            self.assertIn('label-trust-levels "WEB,VETTED"', text)
        finally:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=10)

    def test_a_labelled_server_never_loads_a_data_file(self):
        directory = tempfile.TemporaryDirectory(prefix='eski-labels-file-')
        self.addCleanup(directory.cleanup)
        plain = Server(BINARY, workers=0)
        self.addCleanup(plain.close)
        plain.start()
        writer = plain.client()
        writer.call('SET', 'old', 'value')
        writer.call('CONFIG', 'SET', 'dir', directory.name)
        writer.call('CONFIG', 'SET', 'dbfilename', 'old.rdb')
        self.assertEqual(writer.call('SAVE'), 'OK')
        writer.call('CONFIG', 'SET', 'dbfilename', 'dump.rdb')
        self.assertEqual(writer.call('SAVE'), 'OK')
        plain.close()
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        for arguments in (('--label-levels', 'U,S'), ('--owners', 'yes', '--memcached-port', '0'), ('--label-compartments', 'A', '--dbfilename', 'old.rdb')):
            result = subprocess.run([str(BINARY), '--bind', '127.0.0.1', '--port', str(port), '--dir', directory.name, '--save', '',
                                     '--appendonly', 'no', *arguments], capture_output=True, timeout=20, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Refusing to start: the data file ', result.stdout + result.stderr)
            self.assertIn(STARTUP_REFUSED, result.stdout + result.stderr)
            self.assertIn('Start once without the label scheme and owner mode to move the data out, or move the file away', result.stdout + result.stderr)
        os.rename(os.path.join(directory.name, 'dump.rdb'), os.path.join(directory.name, 'moved.rdb'))
        server = subprocess.Popen([str(BINARY), '--bind', '127.0.0.1', '--port', str(port), '--dir', directory.name, '--save', '',
                                   '--appendonly', 'no', '--label-levels', 'U,S', '--enable-debug-command', 'yes', '--enable-protected-configs', 'yes'],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            wait_for(lambda: self.ping(port), timeout=15, label='server started')
            client = Client(port)
            self.addCleanup(client.close)
            self.assertEqual(client.call('DBSIZE'), 0)
            client.call('ACL', 'SETUSER', 'default', 'clearance:*')
            for command in (('DEBUG', 'RELOAD'), ('DEBUG', 'RELOAD', 'NOSAVE'), ('DEBUG', 'RELOAD', 'MERGE', 'NOSAVE'), ('DEBUG', 'LOADAOF')):
                self.assertEqual(error_of(client, *command), PERSIST_ERROR)
            client.call('CONFIG', 'SET', 'dbfilename', 'old.rdb')
            self.assertEqual(error_of(client, 'DEBUG', 'RELOAD', 'NOSAVE'), PERSIST_ERROR)
            self.assertIn('persistence stays off', error_of(client, 'CONFIG', 'SET', 'appendonly', 'yes'))
            self.assertEqual(client.call('DBSIZE'), 0)
        finally:
            os.killpg(server.pid, signal.SIGTERM)
            server.wait(timeout=10)

    def test_signals_and_shutdown_stop_a_labelled_server(self):
        for how in ('sigterm', 'sigint', 'shutdown'):
            directory = tempfile.TemporaryDirectory(prefix='eski-labels-stop-')
            self.addCleanup(directory.cleanup)
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            process = subprocess.Popen([str(BINARY), '--bind', '127.0.0.1', '--port', str(port), '--dir', directory.name, '--save', '',
                                        '--label-levels', 'U,S'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                wait_for(lambda: self.ping(port), timeout=15, label='server started')
                client = Client(port)
                client.call('SET', 'k', 'v')
                self.assertEqual(error_of(client, 'SHUTDOWN', 'SAVE'), PERSIST_ERROR)
                if how == 'shutdown':
                    client.send('SHUTDOWN')
                    try:
                        client.reply()
                    except (EOFError, OSError):
                        pass
                else:
                    os.kill(process.pid, signal.SIGTERM if how == 'sigterm' else signal.SIGINT)
                client.close()
                self.assertEqual(process.wait(timeout=10), 0)
                self.assertFalse(list(Path(directory.name).glob('*.rdb')))
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)

    def ping(self, port):
        try:
            client = Client(port, timeout=0.5)
            ok = client.call('PING') == 'PONG'
            client.close()
            return ok
        except (OSError, EOFError, ServerError):
            return False


def main():
    global BINARY, KEYSPACE_THREADS
    parser = argparse.ArgumentParser(description='Label scheme, subjects, contexts, tokens and server-wide channels.')
    parser.add_argument('--server', type=Path, default=BINARY)
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--case', default='*')
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    BINARY = args.server.resolve()
    KEYSPACE_THREADS = args.keyspace_threads
    if args.timeout <= 0 or not BINARY.is_file():
        parser.error('existing binary and positive timeout required')
    suite = unittest.TestSuite()
    for case in (LabelsOff, Labelled, Startup):
        for name in unittest.defaultTestLoader.getTestCaseNames(case):
            if fnmatch.fnmatchcase(name, args.case):
                suite.addTest(case(name))
    if suite.countTestCases() == 0:
        parser.error('no tests selected')

    def expired(unused_signal, unused_frame):
        raise SystemExit(124)
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(args.timeout)
    try:
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1
    finally:
        signal.alarm(0)


if __name__ == '__main__':
    raise SystemExit(main())
