import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/threading'))
from support import Client, Push, Server, ServerError, info

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0
AUDIENCE = 'owners-test-node'
SCHEME = ('--label-levels', 'U,C,S', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED')
INVALID_OWNER = 'ERR invalid owner'
OWNERS_OFF = 'ERR owners are not enabled on this server'
REQUIRED = 'ERR this login must name an owner with every command'
CONTEXT_OWNER = "ERR the owner differs from the context's owner"
BOUND = 'ERR this connection is bound to another owner'
TRANSACTION = "ERR the command's label differs from the transaction's label"
WATCH_REFUSED = "EXECABORT Transaction discarded because of: the command's label differs from the transaction's label"
TOP_ERROR = 'ERR this command needs a label that dominates the whole label scheme'
SCRIPT_ERROR = "ERR this command needs a label that dominates the running script's label"
SESSION_NEEDED = 'ERR this command needs a session label set with LABEL SESSION'
PER_COMMAND = 'ERR this login must send every command through LABEL AS'
TOKEN_ERROR = 'ERR invalid label token'
CONTEXT_ERROR = 'ERR invalid context'
PERSIST_ERROR = 'ERR persistence is off while a label scheme is configured'
OWNER_PERSIST_ERROR = 'ERR persistence is off while owner mode is on'
OPERATOR_ERROR = 'ERR this command needs a login with the owner-operator right'
OWNER_TRANSACTION = "ERR the command's owner differs from the transaction's owner"
OWNER_WATCH_REFUSED = "EXECABORT Transaction discarded because of: the command's owner differs from the transaction's owner"

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


SECRET = bytes(range(1, 33))
KEY = token_key(SECRET).hex()


def token(marking, *lines, handle=None):
    body = ['eski-label-token 1', 'marking ' + marking, 'expires %d' % (int(time.time() * 1000) + 600000), 'audience ' + AUDIENCE]
    if handle is not None:
        body.append('context ' + (handle.decode() if isinstance(handle, bytes) else handle))
    body.extend(lines)
    statement = '\n'.join(body).encode()
    return (statement.hex() + '.' + token_signature(SECRET, statement).hex()).encode()


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


def drained(client):
    try:
        client.socket.settimeout(2)
        client.send('PING')
        while True:
            client.read()
    except (OSError, EOFError):
        return True
    return False


def push_of(client, *arguments):
    client.send(*arguments)
    value = client.read()
    if isinstance(value, ServerError):
        raise value
    return value


def messages(client):
    seen = []
    while client.available(0.3):
        value = client.read()
        if isinstance(value, Push) and value[0] in (b'message', b'pmessage', b'smessage'):
            seen.append(value[-1])
    return sorted(seen)


def client_ids(text):
    return sorted(int(f.split('=', 1)[1]) for line in text.decode().splitlines() for f in line.split() if f.startswith('id='))


class OwnersOff(unittest.TestCase):
    scheme = ()

    def setUp(self):
        arguments = ('--keyspace-threads', str(KEYSPACE_THREADS), '--memcached-port', '0') + self.scheme
        self.server = Server(BINARY, workers=0, arguments=arguments)
        self.addCleanup(self.server.close)
        self.server.start()
        self.client = self.server.client()
        if self.scheme:
            self.client.call('ACL', 'SETUSER', 'default', 'clearance:*')

    def test_owners_answers_its_off_error_except_help(self):
        c = self.client
        self.assertTrue(c.call('OWNERS', 'HELP')[0].startswith('OWNERS <subcommand>'))
        for command in (('OWNERS', 'FORGET', 'u1'), ('OWNERS', 'INFO', 'u1'), ('OWNERS', 'LIST', '0'), ('OWNERS', 'QUOTA', 'u1'),
                        ('OWNERS', 'QUOTA', 'u1', 'LIMIT', '10')):
            self.assertEqual(error_of(c, *command), OWNERS_OFF)
        self.assertTrue(error_of(c, 'OWNERS', 'NOPE').startswith("ERR unknown subcommand 'NOPE'. Try OWNERS HELP."))
        self.assertEqual(error_of(c, 'OWNERS', 'FORGET'), "ERR wrong number of arguments for 'owners|forget' command")
        self.assertEqual(error_of(c, 'OWNERS', 'HELP', 'x'), "ERR wrong number of arguments for 'owners|help' command")
        self.assertEqual(error_of(c, 'OWNERS'), "ERR wrong number of arguments for 'owners' command")

    def test_owner_rules_answer_the_owners_off_error(self):
        for rule in ('owners:*', 'owner:u1', 'owner-shared', 'owner-operator', 'owner:', 'owners:x'):
            text = error_of(self.client, 'ACL', 'SETUSER', 'x', rule)
            self.assertEqual(text, "ERR Error in ACL SETUSER modifier '%s': Owners are not enabled on this server" % rule)

    def test_settings_are_hidden(self):
        c = self.client
        names = c.call('CONFIG', 'GET', '*')[0::2]
        self.assertFalse([n for n in names if n.startswith(b'owner')])
        self.assertEqual(c.call('CONFIG', 'GET', 'owners'), [b'owners', b'no'])
        self.assertEqual(c.call('CONFIG', 'GET', 'owner-quota-default'), [b'owner-quota-default', b'0'])
        self.assertEqual(c.call('CONFIG', 'GET', 'owner-partitions-max'), [b'owner-partitions-max', b'0'])
        self.assertEqual(c.call('INFO', 'owners'), b'')

    def test_owner_mode_is_refused_while_the_server_holds_keys(self):
        c = self.client
        c.call('CONFIG', 'SET', 'save', '')
        if self.scheme:
            c.call('LABEL', 'AS', 'C', 'SET', 'k', 'v')
        else:
            c.call('VADD', 'vs', 'VALUES', 2, 1, 0, 'e')
        self.assertEqual(error_of(c, 'CONFIG', 'SET', 'owners', 'yes'),
                         "ERR CONFIG SET failed (possibly related to argument 'owners') - owner mode needs a server without keys, because existing keys carry no owner")
        self.assertEqual(c.call('CONFIG', 'GET', 'owners'), [b'owners', b'no'])
        self.assertEqual(c.call('FLUSHALL'), 'OK')
        self.assertEqual(c.call('CONFIG', 'SET', 'owners', 'yes'), 'OK')
        self.assertEqual(c.call('CONFIG', 'GET', 'owners'), [b'owners', b'yes'])



class LabelsOff(OwnersOff):
    def test_turning_owners_on_needs_persistence_off(self):
        c = self.client
        c.call('CONFIG', 'SET', 'save', '900 1')
        self.assertIn('needs persistence off', error_of(c, 'CONFIG', 'SET', 'owners', 'yes'))
        self.assertEqual(c.call('CONFIG', 'GET', 'owners'), [b'owners', b'no'])
        c.call('CONFIG', 'SET', 'save', '')
        self.assertEqual(c.call('CONFIG', 'SET', 'owners', 'yes'), 'OK')
        self.assertEqual(as_map(c.call('LABEL', 'WHOAMI'))[b'owners'], b'none')
        self.assertEqual(error_of(c, 'CONFIG', 'SET', 'owners', 'no'),
                         "ERR CONFIG SET failed (possibly related to argument 'owners') - owner mode cannot be turned off")
        self.assertEqual(error_of(c, 'CONFIG', 'SET', 'save', '60 10'),
                         "ERR CONFIG SET failed (possibly related to argument 'save') - persistence stays off while owner mode is on")
        self.assertEqual(error_of(c, 'SAVE'), OWNER_PERSIST_ERROR)
        self.assertEqual(c.call('CONFIG', 'GET', 'owners'), [b'owners', b'yes'])


class LabelOnly(OwnersOff):
    scheme = SCHEME

    def test_owner_words_fail_exactly_as_before(self):
        c = self.client
        self.assertTrue(error_of(c, 'LABEL', 'AS', 'U', 'OWNER', 'u1', 'GET', 'k').startswith("ERR unknown command 'OWNER'"))
        self.assertTrue(error_of(c, 'LABEL', 'AS', 'U', 'SHARED', 'GET', 'k').startswith("ERR unknown command 'SHARED'"))
        self.assertEqual(error_of(c, 'LABEL', 'AS', 'OWNER', 'u1', 'GET', 'k'), 'ERR invalid label')
        self.assertEqual(error_of(c, 'LABEL', 'AS', 'SHARED', 'GET', 'k'), 'ERR invalid label')
        self.assertEqual(error_of(c, 'CONTEXT', 'CREATE', 'OWNER', 'u1'), 'ERR syntax error')
        self.assertEqual(error_of(c, 'CONTEXT', 'CREATE', 'SHARED'), 'ERR syntax error')
        self.assertEqual(error_of(c, 'LABEL', 'SESSION', 'U', 'OWNER', 'u1'), 'ERR syntax error')
        self.assertEqual(len(as_map(c.call('LABEL', 'WHOAMI'))), 10)
        self.assertEqual(len(as_map(c.call('ACL', 'GETUSER', 'default'))), 9)
        self.assertEqual(len(as_map(c.call('CONTEXT', 'INFO', c.call('CONTEXT', 'CREATE')))), 2)
        c.call('CONFIG', 'SET', 'label-token-audience', AUDIENCE)
        c.call('ACL', 'SETUSER', 'default', 'token-key:' + KEY)
        self.assertEqual(as_map(c.call('LABEL', 'AS', 'TOKEN', token('U'), 'LABEL', 'WHOAMI'))[b'label'], b'U')
        self.assertEqual(error_of(c, 'LABEL', 'AS', 'TOKEN', token('U', 'owner u1'), 'GET', 'k'), TOKEN_ERROR)
        self.assertEqual(error_of(c, 'LABEL', 'AS', 'TOKEN', token('U', 'shared'), 'GET', 'k'), TOKEN_ERROR)

    def test_turning_owners_on_pins_subscribers_and_reserves_two_level_names(self):
        c = self.client
        sub = self.server.client()
        sub.call('HELLO', 3)
        push_of(sub, 'SUBSCRIBE', 'news')
        self.assertEqual(c.call('CONFIG', 'SET', 'label-levels', 'U,C,S,SHARED'), 'OK')
        self.assertEqual(error_of(c, 'CONFIG', 'SET', 'owners', 'yes'),
                         "ERR CONFIG SET failed (possibly related to argument 'owners') - owner mode needs a label scheme without a level named OWNER or SHARED")
        self.assertEqual(c.call('CONFIG', 'SET', 'label-levels', 'U,C,S,TOP'), 'OK')
        self.assertEqual(c.call('CONFIG', 'SET', 'owners', 'yes'), 'OK')
        self.assertEqual(error_of(c, 'CONFIG', 'SET', 'label-levels', 'U,C,S,TOP,OWNER'),
                         "ERR CONFIG SET failed (possibly related to argument 'label-levels') - OWNER and SHARED are reserved and cannot name a level while owner mode is on")
        self.assertEqual(error_of(c, 'CONFIG', 'SET', 'label-levels', 'U,C,S,owner'),
                         "ERR CONFIG SET failed (possibly related to argument 'label-levels') - OWNER and SHARED are reserved and cannot name a level while owner mode is on")
        self.assertEqual(c.call('CONFIG', 'GET', 'label-levels'), [b'label-levels', b'U,C,S,TOP'])
        who = as_map(sub.call('LABEL', 'WHOAMI'))
        self.assertEqual((who[b'pinned-owner'], who[b'label']), (b'SHARED', b'S//A/B'))
        self.assertEqual(c.call('LABEL', 'AS', 'U', 'PUBLISH', 'news', 'm'), 0)
        self.assertEqual(c.call('LABEL', 'AS', 'S//A/B', 'PUBLISH', 'news', 'm'), 1)
        self.assertEqual(messages(sub), [b'm', b'm'])
        self.assertEqual(len(as_map(c.call('LABEL', 'WHOAMI'))), 15)


class OwnerMode(unittest.TestCase):
    extra = SCHEME

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='eski-owners-')
        self.addCleanup(self.directory.cleanup)
        self.audit = Path(self.directory.name) / 'audit.log'
        self.aclfile = Path(self.directory.name) / 'users.acl'
        self.aclfile.write_text('')
        arguments = ('--keyspace-threads', str(KEYSPACE_THREADS), '--memcached-port', '0', '--owners', 'yes') + self.extra + (
            '--label-audit-file', str(self.audit), '--label-token-audience', AUDIENCE, '--aclfile', str(self.aclfile))
        self.server = Server(BINARY, workers=0, arguments=arguments)
        self.addCleanup(self.server.close)
        self.server.start()
        self.admin = self.connect()
        self.admin.call('ACL', 'SETUSER', 'default', 'clearance:*', 'owner-operator', 'token-key:' + KEY)
        self.setup_logins()

    def setup_logins(self):
        base = ('on', 'nopass', '+@all', '~*', '&*', 'token-key:' + KEY)
        self.admin.call('ACL', 'SETUSER', 'app', *base, 'clearance:S//A', 'trust:VETTED', 'owners:*')
        self.admin.call('ACL', 'SETUSER', 'fixed', *base, 'clearance:S', 'owner:u42')
        self.admin.call('ACL', 'SETUSER', 'shared', *base, 'clearance:S', 'owners:*', 'owner-shared')
        self.admin.call('ACL', 'SETUSER', 'plain', *base, 'clearance:C')
        self.admin.call('ACL', 'SETUSER', 'op', *base, 'clearance:*', 'owners:*', 'owner-operator')
        self.admin.call('ACL', 'SETUSER', 'top', *base, 'clearance:*', 'owners:*')

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

    def records(self):
        return [json.loads(line) for line in self.audit.read_text().splitlines()]


class Owners(OwnerMode):
    def test_the_owner_id_star_is_reserved(self):
        c, app = self.admin, self.connect('app')
        self.assertEqual(error_of(c, 'ACL', 'SETUSER', 'x', 'owner:*'), "ERR Error in ACL SETUSER modifier 'owner:*': Invalid owner rule")
        self.assertEqual(c.call('ACL', 'SETUSER', 'x', 'owners:*'), 'OK')
        self.assertEqual(as_map(c.call('ACL', 'GETUSER', 'x'))[b'owners'], b'*')
        for command in (('LABEL', 'AS', 'OWNER', '*', 'GET', 'k'), ('LABEL', 'AS', 'S//A', 'OWNER', '*', 'GET', 'k'),
                        ('LABEL', 'AS', 'OWNER', '*', 'CONTEXT', 'CREATE'), ('LABEL', 'AS', 'OWNER', 'u1', 'CONTEXT', 'CREATE', 'OWNER', '*')):
            self.assertEqual(error_of(app, *command), INVALID_OWNER)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'TOKEN', token('S//A', 'owner *'), 'GET', 'k'), TOKEN_ERROR)
        for command in (('OWNERS', 'FORGET', '*'), ('OWNERS', 'INFO', '*'), ('OWNERS', 'QUOTA', '*')):
            self.assertEqual(error_of(c, *command), INVALID_OWNER)
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', '**', 'PING'), 'PONG')

    def test_owner_rules_round_trip_and_reset(self):
        c = self.admin
        c.call('ACL', 'SETUSER', 'x', 'on', 'nopass', '+@all', '~*', 'owners:*', 'owner-shared', 'owner-operator')
        user = as_map(c.call('ACL', 'GETUSER', 'x'))
        self.assertEqual(user[b'owners'], b'*')
        self.assertIn(b'owner-shared', user[b'flags'])
        self.assertIn(b'owner-operator', user[b'flags'])
        line = [x for x in c.call('ACL', 'LIST') if x.startswith(b'user x ')][0].decode()
        self.assertIn('owners:* owner-shared owner-operator', line)
        c.call('ACL', 'SETUSER', 'x', 'owner:auth0|5f3c~!')
        self.assertEqual(as_map(c.call('ACL', 'GETUSER', 'x'))[b'owners'], b'auth0|5f3c~!')
        self.assertEqual(c.call('ACL', 'SAVE'), 'OK')
        self.assertIn('owner:auth0|5f3c~! owner-shared owner-operator', self.aclfile.read_text())
        c.call('ACL', 'SETUSER', 'x', 'reset')
        user = as_map(c.call('ACL', 'GETUSER', 'x'))
        self.assertEqual(user[b'owners'], b'')
        self.assertNotIn(b'owner-operator', user[b'flags'])
        self.assertEqual(c.call('ACL', 'LOAD'), 'OK')
        self.assertEqual(as_map(c.call('ACL', 'GETUSER', 'x'))[b'owners'], b'auth0|5f3c~!')
        for rule in ('owners:x', 'owners:', 'owner:', 'owner:' + 'x' * 129, 'owner:a b', 'owner:a\tb'):
            self.assertEqual(error_of(c, 'ACL', 'SETUSER', 'x', rule), "ERR Error in ACL SETUSER modifier '%s': Invalid owner rule" % rule)
        self.assertEqual(len(as_map(c.call('ACL', 'GETUSER', 'default'))), 10)
        setuser = [r for r in self.records() if r['event'] == 'acl-setuser' and r['details']['user'] == 'x'][0]
        self.assertIn('owners:*', setuser['details']['rules'])

    def test_whoami_shows_the_owner_fields(self):
        who = self.whoami(self.admin)
        self.assertEqual((who[b'owner'], who[b'owners'], who[b'owner-shared'], who[b'owner-operator'], who[b'pinned-owner'], who[b'top']),
                         (None, b'none', 0, 1, None, 1))
        app = self.connect('app')
        who = self.whoami(app, 'LABEL', 'AS', 'OWNER', 'u1')
        self.assertEqual((who[b'owner'], who[b'owners'], who[b'owner-operator'], who[b'label'], who[b'top']), (b'u1', b'any', 0, b'S//A', 0))
        self.assertIsNone(self.whoami(app)[b'owner'])
        fixed = self.connect('fixed')
        self.assertEqual((self.whoami(fixed)[b'owner'], self.whoami(fixed)[b'owners']), (b'u42', b'fixed'))
        self.assertEqual(self.whoami(self.connect('shared'))[b'owner-shared'], 1)
        self.assertEqual(len(self.whoami(app)), 15)

    def test_arrival_forms_and_their_refusals(self):
        app = self.connect('app')
        self.assertEqual(error_of(app, 'GET', 'k'), REQUIRED)
        for command in (('PING',), ('ECHO', 'x'), ('LABEL', 'HELP'), ('CONTEXT', 'HELP'), ('OWNERS', 'HELP'), ('CLIENT', 'ID'),
                        ('CLIENT', 'SETNAME', 'n'), ('SELECT', 0), ('AUTH', 'app', 'x'), ('LABEL', 'WHOAMI')):
            self.assertNotIsInstance(app.call(*command), ServerError)
        self.assertEqual(app.call('LABEL', 'AS', 'S//A', 'OWNER', 'u1', 'SET', 'k', 'v'), 'OK')
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u1', 'GET', 'k'), b'v')
        self.assertEqual(app.call('LABEL', 'AS', 'C', 'TRUST', 'VETTED', 'OWNER', 'u1', 'LABEL', 'WHOAMI')[1::2][:2], [b'app', b'C;VETTED'])
        for command in (('LABEL', 'AS', 'SHARED', 'GET', 'k'), ('LABEL', 'AS', 'S//A', 'SHARED', 'GET', 'k'),
                        ('LABEL', 'AS', 'OWNER', 'x' * 129, 'GET', 'k'), ('LABEL', 'AS', 'OWNER', 'a b', 'GET', 'k'),
                        ('LABEL', 'AS', 'OWNER', 'caf\xe9', 'GET', 'k')):
            self.assertEqual(error_of(app, *command), INVALID_OWNER)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'OWNER', 'u1'), 'ERR invalid label')
        self.assertTrue(error_of(app, 'LABEL', 'AS', 'S//A', 'OWNER', 'u1').startswith("ERR unknown command 'OWNER'"))
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'OWNER', 'u1', 'LABEL', 'AS', 'C', 'GET', 'k'), 'ERR LABEL AS cannot wrap LABEL AS or LABEL SESSION')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'SHARED', 'LABEL', 'SESSION', 'C'), 'ERR LABEL AS cannot wrap LABEL AS or LABEL SESSION')
        self.assertEqual(error_of(app, 'LABEL', 'SESSION', 'C', 'OWNER', 'u1'), 'ERR syntax error')
        fixed = self.connect('fixed')
        self.assertIsNone(fixed.call('GET', 'k'))
        self.assertIsNone(fixed.call('LABEL', 'AS', 'OWNER', 'u42', 'GET', 'k'))
        for command in (('LABEL', 'AS', 'OWNER', 'u43', 'GET', 'k'), ('LABEL', 'AS', 'SHARED', 'GET', 'k'), ('LABEL', 'AS', 'S', 'OWNER', 'u4', 'GET', 'k')):
            self.assertEqual(error_of(fixed, *command), INVALID_OWNER)
        plain = self.connect('plain')
        self.assertIsNone(plain.call('GET', 'k'))
        self.assertIsNone(plain.call('LABEL', 'AS', 'SHARED', 'GET', 'k'))
        self.assertEqual(error_of(plain, 'LABEL', 'AS', 'OWNER', 'u1', 'GET', 'k'), INVALID_OWNER)
        shared = self.connect('shared')
        self.assertEqual(shared.call('LABEL', 'AS', 'SHARED', 'SET', 's', '1'), 'OK')
        self.assertEqual(shared.call('LABEL', 'AS', 'S', 'OWNER', 'u5', 'GET', 's'), b'1')

    def test_the_acl_check_runs_before_the_owner_refusals(self):
        self.admin.call('ACL', 'SETUSER', 'noget', 'on', 'nopass', '+@all', '-get', '-debug', '~*', '&*', 'clearance:S', 'owners:*')
        noget = self.connect('noget')
        self.assertEqual(error_of(noget, 'GET', 'k'), "NOPERM User noget has no permissions to run the 'get' command")
        self.assertEqual(error_of(noget, 'LABEL', 'AS', 'OWNER', 'a b', 'GET', 'k'), "NOPERM User noget has no permissions to run the 'get' command")
        self.assertEqual(error_of(noget, 'LABEL', 'AS', 'OWNER', 'u1', 'DEBUG', 'SLEEP', 0), "NOPERM User noget has no permissions to run the 'debug' command")
        self.assertEqual(error_of(noget, 'LABEL', 'AS', 'OWNER', 'u1', 'SET', 'k'), "ERR wrong number of arguments for 'set' command")
        self.assertEqual(error_of(noget, 'SET', 'k', 'v'), REQUIRED)
        log = self.admin.call('ACL', 'LOG')
        self.assertTrue([e for e in log if as_map(e)[b'username'] == b'noget' and as_map(e)[b'object'] == b'debug'])
        self.assertEqual(error_of(noget, 'LABEL', 'AS', 'NOPE', 'GET', 'k'), 'ERR invalid label')

    def test_per_command_logins_treat_the_owner_only_form_as_unprefixed(self):
        self.admin.call('ACL', 'SETUSER', 'pool', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:S', 'owners:*', 'label-per-command')
        pool = self.connect('pool')
        self.assertEqual(error_of(pool, 'LABEL', 'AS', 'OWNER', 'u1', 'GET', 'k'), PER_COMMAND)
        self.assertEqual(pool.call('LABEL', 'AS', 'OWNER', 'u1', 'PING'), 'PONG')
        self.assertIsNone(pool.call('LABEL', 'AS', 'S', 'OWNER', 'u1', 'GET', 'k'))
        self.assertEqual(error_of(pool, 'LABEL', 'AS', 'S', 'GET', 'k'), REQUIRED)
        self.assertEqual(pool.call('LABEL', 'AS', 'S', 'OWNER', 'u1', 'MULTI'), 'OK')
        self.assertEqual(pool.call('GET', 'k'), 'QUEUED')
        self.assertEqual(pool.call('LABEL', 'AS', 'OWNER', 'u1', 'GET', 'k'), 'QUEUED')
        self.assertEqual(pool.call('EXEC'), [None, None])

    def test_contexts_carry_their_owner(self):
        app = self.connect('app')
        handle = app.call('LABEL', 'AS', 'OWNER', 'u1', 'CONTEXT', 'CREATE')
        self.assertEqual(as_map(app.call('LABEL', 'AS', 'OWNER', 'u1', 'CONTEXT', 'INFO', handle)),
                         {b'marking': b'S//A', b'trust': b'WEB', b'owner': b'u1'})
        self.assertEqual(self.whoami(app, 'LABEL', 'AS', 'CONTEXT', handle)[b'owner'], b'u1')
        self.assertEqual(self.whoami(app, 'LABEL', 'AS', 'S//A', 'OWNER', 'u1', 'CONTEXT', handle)[b'owner'], b'u1')
        self.assertEqual(self.whoami(app, 'LABEL', 'AS', 'OWNER', 'u1', 'CONTEXT', handle)[b'owner'], b'u1')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'S//A', 'OWNER', 'u2', 'CONTEXT', handle, 'GET', 'k'), CONTEXT_OWNER)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'OWNER', 'u2', 'CONTEXT', handle, 'GET', 'k'), CONTEXT_OWNER)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'S//A', 'SHARED', 'CONTEXT', handle, 'GET', 'k'), CONTEXT_OWNER)
        app.call('LABEL', 'SESSION', 'C')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'OWNER', 'u1', 'CONTEXT', handle, 'GET', 'k'), "ERR the label differs from the context's label")
        other = app.call('LABEL', 'AS', 'OWNER', 'u1', 'CONTEXT', 'CREATE', 'OWNER', 'u2', 'LEVEL', 'S//A')
        self.assertEqual(as_map(app.call('LABEL', 'AS', 'OWNER', 'u1', 'CONTEXT', 'INFO', other))[b'owner'], b'u2')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'OWNER', 'u1', 'CONTEXT', 'CREATE', 'SHARED'), INVALID_OWNER)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'OWNER', 'u1', 'CONTEXT', 'CREATE', 'OWNER', 'a b'), INVALID_OWNER)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'OWNER', 'u1', 'CONTEXT', 'CREATE', 'OWNER', 'u2', 'OWNER', 'u3'), 'ERR syntax error')
        self.assertEqual(error_of(app, 'CONTEXT', 'CREATE', 'OWNER', 'u2'), REQUIRED)
        plain = self.connect('plain')
        self.assertIsNone(as_map(plain.call('CONTEXT', 'INFO', plain.call('CONTEXT', 'CREATE')))[b'owner'])
        self.assertEqual(error_of(plain, 'CONTEXT', 'CREATE', 'OWNER', 'u1'), INVALID_OWNER)
        self.assertIsNone(as_map(plain.call('CONTEXT', 'INFO', plain.call('CONTEXT', 'CREATE', 'SHARED')))[b'owner'])
        fixed = self.connect('fixed')
        fixed_handle = fixed.call('CONTEXT', 'CREATE')
        self.assertEqual(as_map(fixed.call('CONTEXT', 'INFO', fixed_handle))[b'owner'], b'u42')
        self.admin.call('ACL', 'SETUSER', 'fixed', 'owner:u43')
        self.assertEqual(error_of(self.connect('fixed'), 'LABEL', 'AS', 'CONTEXT', fixed_handle, 'GET', 'k'), CONTEXT_ERROR)

    def test_tokens_carry_their_owner(self):
        app = self.connect('app')
        self.assertEqual(self.whoami(app, 'LABEL', 'AS', 'TOKEN', token('S//A', 'owner u1'))[b'owner'], b'u1')
        for t in (token('S//A'), token('S//A', 'shared'), token('S//A', 'owner u1', 'shared'), token('S//A', 'owner u1', 'owner u2'),
                  token('S//A', 'shared', 'shared'), token('S//A', 'owner a b'), token('S//A', 'owner ' + 'x' * 129), token('S//A', 'owner ')):
            self.assertEqual(error_of(app, 'LABEL', 'AS', 'TOKEN', t, 'GET', 'k'), TOKEN_ERROR)
        handle = app.call('LABEL', 'AS', 'OWNER', 'u1', 'CONTEXT', 'CREATE')
        self.assertEqual(self.whoami(app, 'LABEL', 'AS', 'TOKEN', token('S//A', 'owner u1', handle=handle))[b'owner'], b'u1')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'TOKEN', token('S//A', 'owner u2', handle=handle), 'GET', 'k'), TOKEN_ERROR)
        fixed = self.connect('fixed')
        self.assertEqual(self.whoami(fixed, 'LABEL', 'AS', 'TOKEN', token('S'))[b'owner'], b'u42')
        self.assertEqual(self.whoami(fixed, 'LABEL', 'AS', 'TOKEN', token('S', 'owner u42'))[b'owner'], b'u42')
        self.assertEqual(error_of(fixed, 'LABEL', 'AS', 'TOKEN', token('S', 'owner u43'), 'GET', 'k'), TOKEN_ERROR)
        plain = self.connect('plain')
        self.assertIsNone(self.whoami(plain, 'LABEL', 'AS', 'TOKEN', token('C', 'shared'))[b'owner'])
        self.assertEqual(error_of(plain, 'LABEL', 'AS', 'TOKEN', token('C', 'owner u1'), 'GET', 'k'), TOKEN_ERROR)
        shared = self.connect('shared')
        self.assertIsNone(self.whoami(shared, 'LABEL', 'AS', 'TOKEN', token('S', 'shared'))[b'owner'])

    def test_transactions_bind_the_owner(self):
        app = self.connect('app')
        self.assertEqual(error_of(app, 'MULTI'), REQUIRED)
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u1', 'MULTI'), 'OK')
        self.assertEqual(app.call('LABEL', 'WHOAMI'), 'QUEUED')
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u1', 'GET', 'k'), 'QUEUED')
        replies = app.call('EXEC')
        self.assertEqual(as_map(replies[0])[b'owner'], b'u1')
        app.call('LABEL', 'AS', 'OWNER', 'u1', 'MULTI')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'OWNER', 'u2', 'GET', 'k'), OWNER_TRANSACTION)
        self.assertEqual(error_of(app, 'EXEC'), 'EXECABORT Transaction discarded because of previous errors.')
        app.call('LABEL', 'AS', 'OWNER', 'u1', 'MULTI')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'C', 'OWNER', 'u1', 'GET', 'k'), TRANSACTION)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'OWNER', 'u2', 'EXEC'), OWNER_WATCH_REFUSED)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'OWNER', 'u1', 'EXEC'), 'ERR EXEC without MULTI')
        app.call('LABEL', 'AS', 'OWNER', 'u1', 'WATCH', 'k')
        app.call('LABEL', 'AS', 'OWNER', 'u2', 'MULTI')
        self.assertEqual(app.call('GET', 'k'), 'QUEUED')
        self.assertEqual(error_of(app, 'EXEC'), OWNER_WATCH_REFUSED)
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u1', 'CLIENT', 'INFO').decode().split(' watch=')[1].split()[0], '0')
        app.call('LABEL', 'AS', 'OWNER', 'u1', 'WATCH', 'k')
        app.call('LABEL', 'AS', 'OWNER', 'u1', 'MULTI')
        app.call('GET', 'k')
        self.assertEqual(app.call('EXEC'), [None])
        app.call('LABEL', 'AS', 'OWNER', 'u1', 'WATCH', 'k')
        app.call('LABEL', 'AS', 'OWNER', 'u2', 'WATCH', 'j')
        app.call('LABEL', 'AS', 'OWNER', 'u1', 'MULTI')
        self.assertEqual(error_of(app, 'EXEC'), OWNER_WATCH_REFUSED)
        app.call('LABEL', 'AS', 'C', 'OWNER', 'u1', 'WATCH', 'k')
        app.call('LABEL', 'AS', 'OWNER', 'u2', 'WATCH', 'j')
        app.call('LABEL', 'AS', 'OWNER', 'u1', 'MULTI')
        self.assertEqual(error_of(app, 'EXEC'), WATCH_REFUSED)
        fixed = self.connect('fixed')
        fixed.call('WATCH', 'k')
        fixed.call('MULTI')
        fixed.call('GET', 'k')
        self.assertEqual(fixed.call('EXEC'), [None])

    def test_scripts_inherit_the_owner(self):
        app = self.connect('app')
        reply = app.call('LABEL', 'AS', 'OWNER', 'u1', 'EVAL', "return redis.call('LABEL', 'WHOAMI')", 0)
        self.assertEqual(as_map(reply)[b'owner'], b'u1')
        text = error_of(app, 'LABEL', 'AS', 'OWNER', 'u1', 'EVAL', "return redis.call('LABEL', 'AS', 'S', 'OWNER', 'u2', 'GET', 'k')", 0)
        self.assertIn('not allowed', text.lower())
        text = error_of(self.admin, 'EVAL', "return redis.call('OWNERS', 'INFO', 'u1')", 0)
        self.assertIn('not allowed from script', text)

    def test_busy_script_commands_need_a_dominating_scope(self):
        self.admin.call('CONFIG', 'SET', 'busy-reply-threshold', 50)
        script = self.connect('app')
        script.send('LABEL', 'AS', 'S//A', 'OWNER', 'u1', 'EVAL', 'while true do end', 0)
        time.sleep(0.3)
        other = self.connect('app')
        self.assertEqual(error_of(other, 'LABEL', 'AS', 'S//A', 'OWNER', 'u2', 'SCRIPT', 'KILL'), SCRIPT_ERROR)
        self.assertEqual(error_of(other, 'SCRIPT', 'KILL'), REQUIRED)
        self.assertEqual(other.call('LABEL', 'AS', 'S//A', 'OWNER', 'u1', 'SCRIPT', 'KILL'), 'OK')
        self.assertIn('killed', str(script.reply()).lower())
        self.admin.call('FUNCTION', 'LOAD', "#!lua name=spin\nredis.register_function('spin', function() while true do end end)")
        script.send('LABEL', 'AS', 'S//A', 'OWNER', 'u1', 'FCALL', 'spin', 0)
        time.sleep(0.3)
        self.assertIsNone(as_map(other.call('LABEL', 'AS', 'S//A', 'OWNER', 'u2', 'FUNCTION', 'STATS'))[b'running_script'])
        self.assertEqual(error_of(other, 'LABEL', 'AS', 'S//A', 'OWNER', 'u2', 'FUNCTION', 'KILL'), SCRIPT_ERROR)
        self.assertEqual(as_map(as_map(other.call('LABEL', 'AS', 'S//A', 'OWNER', 'u1', 'FUNCTION', 'STATS'))[b'running_script'])[b'name'], b'spin')
        self.assertEqual(as_map(as_map(self.admin.call('FUNCTION', 'STATS'))[b'running_script'])[b'name'], b'spin')
        self.assertEqual(self.admin.call('FUNCTION', 'KILL'), 'OK')
        self.assertIn('killed', str(script.reply()).lower())
        plain = self.connect('plain')
        plain.send('FCALL', 'spin', 0)
        time.sleep(0.3)
        self.assertIsNone(as_map(other.call('LABEL', 'AS', 'S//A', 'OWNER', 'u2', 'FUNCTION', 'STATS'))[b'running_script'])
        self.assertEqual(error_of(other, 'LABEL', 'AS', 'S//A', 'OWNER', 'u2', 'FUNCTION', 'KILL'), SCRIPT_ERROR)
        peer = self.connect('plain')
        self.assertEqual(as_map(as_map(peer.call('FUNCTION', 'STATS'))[b'running_script'])[b'name'], b'spin')
        self.assertEqual(peer.call('FUNCTION', 'KILL'), 'OK')
        self.assertIn('killed', str(plain.reply()).lower())
        self.admin.call('FUNCTION', 'FLUSH')

    def test_script_kill_needs_the_script_owner_or_the_operator(self):
        self.admin.call('CONFIG', 'SET', 'busy-reply-threshold', 50)
        self.admin.call('ACL', 'SETUSER', 'sharer', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:*', 'owners:*', 'owner-shared')
        self.admin.call('FUNCTION', 'LOAD', "#!lua name=spin\nredis.register_function('spin', function() while true do end end)")
        user, fixed, sharer, op = self.connect('app'), self.connect('fixed'), self.connect('sharer'), self.connect('op')
        plain = self.connect('plain')
        plain.send('FCALL', 'spin', 0)
        time.sleep(0.3)
        for client, prefix in ((user, ('LABEL', 'AS', 'S//A', 'OWNER', 'u1')), (fixed, ()), (sharer, ('LABEL', 'AS', 'OWNER', 'u1'))):
            self.assertIsNone(as_map(client.call(*prefix, 'FUNCTION', 'STATS'))[b'running_script'])
            self.assertEqual(error_of(client, *prefix, 'FUNCTION', 'KILL'), SCRIPT_ERROR)
            self.assertEqual(error_of(client, *prefix, 'SCRIPT', 'KILL'), SCRIPT_ERROR)
        self.assertEqual(error_of(sharer, 'LABEL', 'AS', 'U', 'SHARED', 'FUNCTION', 'KILL'), SCRIPT_ERROR)
        self.assertEqual(as_map(as_map(sharer.call('LABEL', 'AS', 'SHARED', 'FUNCTION', 'STATS'))[b'running_script'])[b'name'], b'spin')
        self.assertEqual(sharer.call('LABEL', 'AS', 'SHARED', 'FUNCTION', 'KILL'), 'OK')
        self.assertIn('killed', str(plain.reply()).lower())
        script = self.connect('app')
        script.send('LABEL', 'AS', 'S//A', 'OWNER', 'u1', 'EVAL', 'while true do end', 0)
        time.sleep(0.3)
        for client, prefix in ((user, ('LABEL', 'AS', 'S//A', 'OWNER', 'u2')), (fixed, ()), (sharer, ('LABEL', 'AS', 'SHARED')),
                               (user, ('LABEL', 'AS', 'C', 'OWNER', 'u1')), (op, ('LABEL', 'AS', 'C', 'OWNER', 'u2'))):
            self.assertEqual(error_of(client, *prefix, 'SCRIPT', 'KILL'), SCRIPT_ERROR)
        self.assertEqual(op.call('LABEL', 'AS', 'S//A', 'OWNER', 'u2', 'SCRIPT', 'KILL'), 'OK')
        self.assertIn('killed', str(script.reply()).lower())
        script.send('LABEL', 'AS', 'S//A', 'OWNER', 'u1', 'FCALL', 'spin', 0)
        time.sleep(0.3)
        self.assertIsNone(as_map(sharer.call('LABEL', 'AS', 'SHARED', 'FUNCTION', 'STATS'))[b'running_script'])
        self.assertEqual(as_map(as_map(op.call('LABEL', 'AS', 'S//A', 'OWNER', 'u2', 'FUNCTION', 'STATS'))[b'running_script'])[b'name'], b'spin')
        self.assertEqual(as_map(as_map(sharer.call('LABEL', 'AS', 'OWNER', 'u1', 'FUNCTION', 'STATS'))[b'running_script'])[b'name'], b'spin')
        self.assertEqual(sharer.call('LABEL', 'AS', 'OWNER', 'u1', 'FUNCTION', 'KILL'), 'OK')
        self.assertIn('killed', str(script.reply()).lower())
        self.admin.call('FUNCTION', 'FLUSH')

    def subscribers(self):
        shared = self.connect('plain', protocol=3)
        push_of(shared, 'SUBSCRIBE', 'news')
        u1 = self.connect('app', protocol=3)
        push_of(u1, 'LABEL', 'AS', 'OWNER', 'u1', 'SUBSCRIBE', 'news')
        u2 = self.connect('app', protocol=3)
        push_of(u2, 'LABEL', 'AS', 'OWNER', 'u2', 'SUBSCRIBE', 'news')
        every = self.connect('op', protocol=3)
        push_of(every, 'SUBSCRIBE', 'news')
        fixed = self.connect('fixed', protocol=3)
        push_of(fixed, 'SUBSCRIBE', 'news')
        return shared, u1, u2, every, fixed

    def test_the_push_pin_fixes_the_owner(self):
        shared, u1, u2, every, fixed = self.subscribers()
        pins = [self.whoami(c)[b'pinned-owner'] for c in (shared, u1, u2, every, fixed)]
        self.assertEqual(pins, [b'SHARED', b'OWNER u1', b'OWNER u2', b'EVERY', b'OWNER u42'])
        self.assertEqual(self.whoami(u1)[b'label'], b'S//A')
        app = self.connect('app', protocol=3)
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'S//A', 'OWNER', 'u1', 'SUBSCRIBE', 'news'), SESSION_NEEDED)
        self.assertEqual(error_of(app, 'SUBSCRIBE', 'news'), REQUIRED)
        self.assertIsNone(self.whoami(app)[b'pinned-owner'])
        self.assertEqual(error_of(app, 'CLIENT', 'TRACKING', 'ON'), REQUIRED)
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u3', 'CLIENT', 'TRACKING', 'ON'), 'OK')
        self.assertEqual(self.whoami(app)[b'pinned-owner'], b'OWNER u3')
        self.assertEqual(error_of(u1, 'LABEL', 'AS', 'OWNER', 'u2', 'PING'), BOUND)
        self.assertEqual(error_of(u1, 'LABEL', 'AS', 'S//A', 'SHARED', 'PING'), INVALID_OWNER)
        self.assertEqual(u1.call('LABEL', 'AS', 'OWNER', 'u1', 'PING'), 'PONG')
        self.assertEqual(u1.call('PING'), 'PONG')
        self.assertEqual(error_of(every, 'LABEL', 'AS', 'OWNER', 'u1', 'GET', 'k'), BOUND)
        app.call('LABEL', 'SESSION', 'C')
        push_of(app, 'LABEL', 'AS', 'C', 'OWNER', 'u3', 'SUBSCRIBE', 'more')
        self.assertEqual(self.whoami(app)[b'pinned-owner'], b'OWNER u3')
        push_of(u1, 'LABEL', 'AS', 'OWNER', 'u1', 'UNSUBSCRIBE', 'news')
        self.assertEqual(self.whoami(u1)[b'pinned-owner'], b'OWNER u1')
        self.assertEqual(u1.call('RESET'), 'RESET')
        self.assertIsNone(self.whoami(u1)[b'pinned-owner'])

    def test_a_push_command_refused_on_arrival_pins_nothing(self):
        base = ('on', 'nopass', '+@all', '-subscribe', '-client|tracking', '~*', '&*', 'clearance:S')
        self.admin.call('ACL', 'SETUSER', 'nosub', *base, 'owner:u5')
        self.admin.call('ACL', 'SETUSER', 'anysub', *base, 'owners:*')
        nosub, anysub, app = self.connect('nosub'), self.connect('anysub'), self.connect('app')
        for client, prefix in ((nosub, ()), (anysub, ('LABEL', 'AS', 'OWNER', 'u1'))):
            for command, name in ((('SUBSCRIBE', 'news'), 'subscribe'), (('CLIENT', 'TRACKING', 'ON'), 'client|tracking')):
                text = "NOPERM User %s has no permissions to run the '%s' command" % (self.whoami(client)[b'login'].decode(), name)
                self.assertEqual(error_of(client, *prefix, *command), text)
                who = self.whoami(client)
                self.assertEqual((who[b'session'], who[b'pinned-owner']), (0, None))
        for command, text in ((('SUBSCRIBE', 'news'), REQUIRED), (('LABEL', 'AS', 'OWNER', 'a b', 'SUBSCRIBE', 'news'), INVALID_OWNER),
                              (('CLIENT', 'TRACKING', 'ON'), REQUIRED)):
            self.assertEqual(error_of(app, *command), text)
            who = self.whoami(app)
            self.assertEqual((who[b'session'], who[b'pinned-owner']), (0, None))
        self.assertEqual(self.whoami(anysub, 'LABEL', 'AS', 'OWNER', 'u1')[b'owner'], b'u1')
        fixed = self.connect('fixed', protocol=3)
        push_of(fixed, 'SUBSCRIBE', 'news')
        who = self.whoami(fixed)
        self.assertEqual((who[b'session'], who[b'label'], who[b'pinned-owner']), (1, b'S', b'OWNER u42'))
        listener = self.connect('app', protocol=3)
        push_of(listener, 'LABEL', 'AS', 'OWNER', 'u1', 'SUBSCRIBE', 'news')
        who = self.whoami(listener)
        self.assertEqual((who[b'session'], who[b'label'], who[b'pinned-owner']), (1, b'S//A', b'OWNER u1'))
        self.connect('plain').call('PUBLISH', 'news', 'm')
        self.assertEqual((messages(fixed), messages(listener)), ([b'm'], [b'm']))

    def test_a_push_command_refused_after_admission_pins_no_owner(self):
        app = self.connect('app', protocol=3)
        def unpinned():
            who = self.whoami(app)
            self.assertEqual((who[b'session'], who[b'pinned-owner']), (0, None))
            self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u2', 'PING'), 'PONG')
        self.admin.call('CONFIG', 'SET', 'busy-reply-threshold', 50)
        script = self.connect('plain')
        script.send('EVAL', 'while true do end', 0)
        time.sleep(0.3)
        for command in (('SUBSCRIBE', 'ch'), ('CLIENT', 'TRACKING', 'ON')):
            self.assertTrue(error_of(app, 'LABEL', 'AS', 'OWNER', 'u1', *command).startswith('BUSY'))
        self.assertEqual(self.admin.call('SCRIPT', 'KILL'), 'OK')
        self.assertIn('killed', str(script.reply()).lower())
        unpinned()
        self.admin.call('CONFIG', 'SET', 'maxmemory', 1)
        self.assertTrue(error_of(app, 'LABEL', 'AS', 'OWNER', 'u1', 'SUBSCRIBE', 'ch').startswith('OOM'))
        self.admin.call('CONFIG', 'SET', 'maxmemory', 0)
        unpinned()
        self.assertTrue(error_of(app, 'LABEL', 'AS', 'OWNER', 'u1', 'CLIENT', 'TRACKING', 'ON', 'REDIRECT', 999999).startswith('ERR'))
        unpinned()
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u1', 'CLIENT', 'TRACKING', 'ON'), 'OK')
        self.assertEqual(self.whoami(app)[b'pinned-owner'], b'OWNER u1')
        self.assertEqual(error_of(app, 'LABEL', 'AS', 'OWNER', 'u2', 'PING'), BOUND)

    def test_messages_reach_the_pins_that_dominate_their_scope(self):
        shared, u1, u2, every, fixed = self.subscribers()
        app = self.connect('app')
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u1', 'PUBLISH', 'news', 'at-u1'), 1)
        plain = self.connect('plain')
        self.assertEqual(plain.call('PUBLISH', 'news', 'at-shared'), 1)
        writer = self.connect('shared')
        self.assertEqual(writer.call('LABEL', 'AS', 'S', 'SHARED', 'PUBLISH', 'news', 'at-s'), 0)
        self.assertEqual(writer.call('LABEL', 'AS', 'S', 'OWNER', 'u42', 'PUBLISH', 'news', 'at-u42'), 1)
        self.assertEqual(messages(shared), [b'at-shared'])
        self.assertEqual(messages(u1), [b'at-s', b'at-shared', b'at-u1'])
        self.assertEqual(messages(u2), [b'at-s', b'at-shared'])
        self.assertEqual(messages(every), [b'at-s', b'at-shared', b'at-u1', b'at-u42'])
        self.assertEqual(messages(fixed), [b'at-s', b'at-shared', b'at-u42'])
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u1', 'PUBSUB', 'NUMSUB', 'news'), [b'news', 2])
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u9', 'PUBSUB', 'NUMSUB', 'news'), [b'news', 1])
        self.assertEqual(self.connect('top').call('LABEL', 'AS', 'OWNER', 'u9', 'PUBSUB', 'NUMSUB', 'news'), [b'news', 1])
        self.assertEqual(self.admin.call('PUBSUB', 'NUMSUB', 'news'), [b'news', 5])
        self.assertEqual(self.admin.call('LABEL', 'AS', 'S//A', 'PUBSUB', 'NUMSUB', 'news'), [b'news', 4])
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u9', 'PUBSUB', 'CHANNELS'), [b'news'])

    def test_keyspace_notifications_reach_every_pin_for_shared_data(self):
        self.admin.call('CONFIG', 'SET', 'notify-keyspace-events', 'KEA')
        u1 = self.connect('app', protocol=3)
        u1.call('LABEL', 'SESSION', 'C')
        push_of(u1, 'LABEL', 'AS', 'OWNER', 'u1', 'PSUBSCRIBE', '__keyevent@0__:*')
        plain = self.connect('plain')
        plain.call('SET', 'shared-key', 'v')
        seen = []
        while u1.available(0.3):
            value = u1.read()
            if isinstance(value, Push) and value[0] == b'pmessage':
                seen.append(value[-1])
        self.assertIn(b'shared-key', seen)

    def test_introspection_follows_the_scope(self):
        shared, u1, u2, every, fixed = self.subscribers()
        ids = {name: c.call('CLIENT', 'ID') for name, c in (('shared', shared), ('u1', u1), ('u2', u2), ('every', every), ('fixed', fixed))}
        unpinned = self.connect('app')
        ids['unpinned'] = unpinned.call('CLIENT', 'ID')
        viewer = self.connect('app')
        own = viewer.call('CLIENT', 'ID')
        seen = client_ids(viewer.call('LABEL', 'AS', 'OWNER', 'u1', 'CLIENT', 'LIST'))
        self.assertIn(own, seen)
        self.assertIn(ids['u1'], seen)
        self.assertIn(ids['shared'], seen)
        for name in ('u2', 'every', 'fixed', 'unpinned'):
            self.assertNotIn(ids[name], seen)
        everyone = client_ids(self.admin.call('CLIENT', 'LIST'))
        for name in ids:
            self.assertIn(ids[name], everyone)
        self.assertEqual(viewer.call('LABEL', 'AS', 'OWNER', 'u1', 'CLIENT', 'LIST', 'ID', ids['u2']), b'')
        self.assertEqual(viewer.call('LABEL', 'AS', 'OWNER', 'u1', 'CLIENT', 'KILL', 'ID', ids['u2']), 0)
        self.assertFalse(closed(u2))
        self.assertEqual(self.admin.call('CLIENT', 'KILL', 'ID', ids['u2']), 1)
        blocked = self.connect('fixed')
        blocked_id = blocked.call('CLIENT', 'ID')
        blocked.send('BLPOP', 'queue', 0)
        time.sleep(0.2)
        self.assertEqual(viewer.call('LABEL', 'AS', 'OWNER', 'u1', 'CLIENT', 'UNBLOCK', blocked_id), 0)
        self.assertEqual(self.connect('fixed').call('CLIENT', 'UNBLOCK', blocked_id), 1)
        self.assertIsNone(blocked.reply())
        self.admin.call('CONFIG', 'SET', 'slowlog-log-slower-than', 0)
        self.admin.call('SLOWLOG', 'RESET')
        app = self.connect('app')
        app.call('LABEL', 'AS', 'OWNER', 'u1', 'ECHO', 'slow-u1')
        app.call('LABEL', 'AS', 'OWNER', 'u2', 'ECHO', 'slow-u2')
        self.connect('plain').call('ECHO', 'slow-shared')
        mine = [e[3] for e in viewer.call('LABEL', 'AS', 'OWNER', 'u1', 'SLOWLOG', 'GET', -1)]
        self.assertIn([b'ECHO', b'slow-u1'], mine)
        self.assertIn([b'ECHO', b'slow-shared'], mine)
        self.assertNotIn([b'ECHO', b'slow-u2'], mine)
        everything = [e[3] for e in self.admin.call('SLOWLOG', 'GET', -1)]
        self.assertIn([b'ECHO', b'slow-u2'], everything)
        self.assertEqual(viewer.call('LABEL', 'AS', 'OWNER', 'u1', 'SLOWLOG', 'LEN'), len(mine) + 1)
        top = self.connect('top')
        redacted = top.call('LABEL', 'AS', 'OWNER', 'u1', 'INFO', 'stats').decode()
        self.assertIn('total_commands_processed:0', redacted)
        self.assertEqual(top.call('LABEL', 'AS', 'OWNER', 'u1', 'INFO', 'owners'), b'')
        owners = self.admin.call('INFO', 'owners').decode()
        self.assertTrue(owners.startswith('# Owners\r\n'))
        self.assertIn('owners_known:', owners)
        self.assertIn('# Owners', self.admin.call('INFO').decode())
        self.assertNotIn('# Owners', top.call('LABEL', 'AS', 'OWNER', 'u1', 'INFO').decode())

    def test_top_needs_the_operator_in_owner_mode(self):
        top = self.connect('top')
        self.assertEqual(self.whoami(top, 'LABEL', 'AS', 'OWNER', 'u1')[b'top'], 0)
        for command in (('MONITOR',), ('DEBUG', 'SLEEP', 0), ('CONFIG', 'RESETSTAT'), ('SLOWLOG', 'RESET'), ('MEMORY', 'STATS'),
                        ('OWNERS', 'INFO', 'u1'), ('OWNERS', 'FORGET', 'u1'), ('OWNERS', 'LIST', 0), ('OWNERS', 'QUOTA', 'u1'),
                        ('LABEL', 'COPIES')):
            self.assertEqual(error_of(top, 'LABEL', 'AS', 'OWNER', 'u1', *command), OPERATOR_ERROR)
        self.assertEqual(error_of(self.connect('app'), 'LABEL', 'AS', 'OWNER', 'u1', 'DEBUG', 'SLEEP', 0), TOP_ERROR)
        self.assertTrue(top.call('LABEL', 'AS', 'OWNER', 'u1', 'OWNERS', 'HELP'))
        op = self.connect('op')
        self.assertEqual(self.whoami(op, 'LABEL', 'AS', 'OWNER', 'u1')[b'top'], 1)
        self.assertEqual(op.call('LABEL', 'AS', 'OWNER', 'u1', 'DEBUG', 'SLEEP', 0), 'OK')
        monitor = self.connect('op')
        self.assertEqual(monitor.call('LABEL', 'AS', 'OWNER', 'u1', 'MONITOR'), 'OK')
        self.connect('app').call('LABEL', 'AS', 'OWNER', 'u7', 'ECHO', 'seen-by-monitor')
        time.sleep(0.2)
        seen = b''
        while monitor.available(0.2):
            seen += monitor.socket.recv(65536)
        self.assertIn(b'seen-by-monitor', seen)

    def test_forget_removes_the_owner_from_the_subject_side(self):
        self.admin.call('CONFIG', 'SET', 'slowlog-log-slower-than', 0)
        pinned = self.connect('app', protocol=3)
        push_of(pinned, 'LABEL', 'AS', 'OWNER', 'u7', 'SUBSCRIBE', 'ch')
        bound = self.connect('app')
        bound.call('LABEL', 'AS', 'OWNER', 'u7', 'MULTI')
        watching = self.connect('app')
        watching.call('LABEL', 'AS', 'OWNER', 'u7', 'WATCH', 'k')
        blocked = self.connect('app')
        blocked.send('LABEL', 'AS', 'OWNER', 'u7', 'BLPOP', 'queue', 0)
        other_pin = self.connect('app', protocol=3)
        push_of(other_pin, 'LABEL', 'AS', 'OWNER', 'u8', 'SUBSCRIBE', 'ch')
        idle = self.connect('app')
        idle.call('LABEL', 'AS', 'OWNER', 'u7', 'ECHO', 'secret-u7')
        handle = idle.call('LABEL', 'AS', 'OWNER', 'u7', 'CONTEXT', 'CREATE')
        kept = idle.call('LABEL', 'AS', 'OWNER', 'u8', 'CONTEXT', 'CREATE')
        idle.call('LABEL', 'AS', 'TOKEN', token('S//A', 'owner u7'), 'PING')
        time.sleep(0.2)
        entry = as_map(self.admin.call('OWNERS', 'INFO', 'u7'))[b'bytes']
        self.assertGreater(entry, 0)
        self.assertEqual(as_map(self.admin.call('OWNERS', 'FORGET', 'u7')), {b'keys': 0, b'elements': 0, b'bytes': entry})
        for client in (pinned, bound, watching, blocked):
            self.assertTrue(closed(client))
        self.assertFalse(closed(other_pin))
        self.assertFalse(closed(idle))
        self.assertEqual(error_of(idle, 'LABEL', 'AS', 'OWNER', 'u8', 'CONTEXT', 'INFO', handle), CONTEXT_ERROR)
        self.assertEqual(as_map(idle.call('LABEL', 'AS', 'OWNER', 'u8', 'CONTEXT', 'INFO', kept))[b'owner'], b'u8')
        logged = [e[3] for e in self.admin.call('SLOWLOG', 'GET', -1)]
        self.assertNotIn([b'ECHO', b'secret-u7'], logged)
        self.assertEqual(self.whoami(idle, 'LABEL', 'AS', 'OWNER', 'u7')[b'owner'], b'u7')
        record = [r for r in self.records() if r['event'] == 'owner-forget'][-1]
        self.assertEqual(record['details']['owner'], 'u7')
        self.assertEqual((record['details']['connections'], record['details']['contexts']), ('4', '1'))
        self.assertGreaterEqual(int(record['details']['slowlog']), 1)
        self.assertEqual(record['details']['tokens'], '1')
        self.assertEqual(as_map(self.admin.call('OWNERS', 'FORGET', 'never-seen')), {b'keys': 0, b'elements': 0, b'bytes': 0})
        self.assertEqual(error_of(self.admin, 'OWNERS', 'FORGET', 'a b'), INVALID_OWNER)

    def test_owner_quota_info_and_list(self):
        c = self.admin
        self.assertEqual(c.call('OWNERS', 'QUOTA', 'u1'), [0, 0])
        self.assertEqual(c.call('OWNERS', 'QUOTA', 'u1', 'LIMIT', 1000), 'OK')
        entry = as_map(c.call('OWNERS', 'INFO', 'u1'))[b'bytes']
        self.assertGreater(entry, 0)
        self.assertEqual(c.call('OWNERS', 'QUOTA', 'u1'), [1000, entry])
        c.call('CONFIG', 'SET', 'owner-quota-default', '500')
        self.assertEqual(c.call('OWNERS', 'QUOTA', 'u2'), [500, 0])
        self.assertEqual(c.call('OWNERS', 'QUOTA', 'u1', 'LIMIT', 0), 'OK')
        self.assertEqual(c.call('OWNERS', 'QUOTA', 'u1'), [500, entry])
        self.assertEqual(as_map(c.call('OWNERS', 'INFO', 'u1')),
                         {b'keys': 0, b'elements': 0, b'bytes': entry, b'partitions': 0, b'labels': 0, b'quota': 500})
        self.assertEqual(error_of(c, 'OWNERS', 'QUOTA', 'u1', 'LIMIT', -1), 'ERR value is not an integer or out of range')
        self.assertEqual(error_of(c, 'OWNERS', 'QUOTA', 'u1', 'MAX', 1), 'ERR syntax error')
        self.assertEqual(c.call('OWNERS', 'LIST', 0), [b'0', []])
        self.assertEqual(c.call('OWNERS', 'LIST', 0, 'COUNT', 5), [b'0', []])
        self.assertEqual(error_of(c, 'OWNERS', 'LIST', 0, 'COUNT', 0), 'ERR syntax error')
        self.assertEqual(error_of(c, 'OWNERS', 'LIST', 'x'), 'ERR invalid cursor')
        records = [r for r in self.records() if r['event'] == 'owner-quota']
        self.assertEqual([(r['details']['owner'], r['details']['limit']) for r in records], [('u1', '1000'), ('u1', '0')])
        events = [r['event'] for r in self.records()]
        self.assertEqual(events[:2], ['scheme-load', 'owners-on'])

    def test_acl_changes_close_connections_beyond_the_new_owner_rules(self):
        self.admin.call('ACL', 'SETUSER', 'mover', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:S', 'owners:*')
        sub = self.connect('mover', protocol=3)
        push_of(sub, 'LABEL', 'AS', 'OWNER', 'u1', 'SUBSCRIBE', 'ch')
        tx = self.connect('mover')
        tx.call('LABEL', 'AS', 'OWNER', 'u1', 'MULTI')
        watcher = self.connect('mover')
        watcher.call('LABEL', 'AS', 'OWNER', 'u1', 'WATCH', 'k')
        idle = self.connect('mover')
        self.admin.call('ACL', 'SETUSER', 'mover', 'owner:u2')
        for client in (sub, tx, watcher):
            self.assertTrue(closed(client))
        self.assertFalse(closed(idle))
        self.admin.call('ACL', 'SETUSER', 'boss', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:*', 'owners:*', 'owner-operator')
        monitor = self.connect('boss')
        monitor.call('LABEL', 'AS', 'OWNER', 'u1', 'MONITOR')
        every = self.connect('boss', protocol=3)
        push_of(every, 'SUBSCRIBE', 'ch')
        self.assertEqual(self.whoami(every)[b'pinned-owner'], b'EVERY')
        self.admin.call('ACL', 'SETUSER', 'boss', 'reset', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:*', 'owners:*')
        self.assertTrue(drained(monitor))
        self.assertTrue(drained(every))

    def test_auth_repins_or_closes_and_reset_clears_the_pin(self):
        sub = self.connect('plain', protocol=3)
        push_of(sub, 'SUBSCRIBE', 'news')
        sub.call('AUTH', 'fixed', 'x')
        who = self.whoami(sub)
        self.assertEqual((who[b'pinned-owner'], who[b'label']), (b'OWNER u42', b'S'))
        operator = self.connect('plain', protocol=3)
        push_of(operator, 'SUBSCRIBE', 'news')
        operator.call('AUTH', 'op', 'x')
        self.assertEqual(self.whoami(operator)[b'pinned-owner'], b'EVERY')
        gone = self.connect('plain', protocol=3)
        push_of(gone, 'SUBSCRIBE', 'news')
        gone.send('AUTH', 'app', 'x')
        self.assertEqual(gone.reply(), 'OK')
        self.assertTrue(closed(gone))

    def test_a_write_pause_sees_through_owner_prefixes(self):
        admin = self.admin
        app = [self.connect('app') for _ in range(6)]
        fixed = self.connect('fixed')
        ro = "#!lua flags=no-writes\nreturn 'ro'"
        sha = app[0].call('LABEL', 'AS', 'OWNER', 'u1', 'SCRIPT', 'LOAD', ro)
        known = int(info(admin, 'owners')['owners_known'])
        self.assertEqual(app[5].call('LABEL', 'AS', 'OWNER', 'u1', 'MULTI'), 'OK')
        self.assertEqual(app[5].call('LABEL', 'AS', 'OWNER', 'u1', 'SET', 'k2', 'v'), 'QUEUED')
        self.assertEqual(admin.call('CLIENT', 'PAUSE', 5000, 'WRITE'), 'OK')
        held = [(app[0], ('LABEL', 'AS', 'OWNER', 'fresh7', 'SET', 'k', 'v')), (app[1], ('LABEL', 'AS', 'S//A', 'OWNER', 'u2', 'SET', 'k', 'v')),
                (app[2], ('LABEL', 'AS', 'OWNER', 'u1', 'EVALSHA', sha, 0)), (app[5], ('LABEL', 'AS', 'OWNER', 'u1', 'EXEC')),
                (fixed, ('SET', 'k', 'v')), (app[4], ('LABEL', 'AS', 'SHARED', 'SET', 'k', 'v'))]
        for client, command in held:
            client.send(*command)
        self.assertIsNone(app[3].call('LABEL', 'AS', 'OWNER', 'u1', 'GET', 'k'))
        self.assertEqual(app[3].call('LABEL', 'AS', 'OWNER', 'u1', 'EVAL', ro, 0), b'ro')
        self.assertEqual(error_of(app[3], 'LABEL', 'AS', 'S//A'), "ERR wrong number of arguments for 'label|as' command")
        self.assertEqual(error_of(app[3], 'LABEL', 'AS', 'NOPE', 'OWNER', 'u1', 'SET', 'k', 'v'), 'ERR invalid label')
        for client, command in held:
            self.assertFalse(client.available(0.3), command)
        self.assertEqual(int(info(admin, 'owners')['owners_known']), known)
        self.assertEqual(as_map(admin.call('OWNERS', 'INFO', 'fresh7'))[b'keys'], 0)
        self.assertEqual(admin.call('CLIENT', 'UNPAUSE'), 'OK')
        replies = [client.reply() for client, _ in held]
        self.assertEqual(replies[:5] + [str(replies[5])], ['OK', 'OK', b'ro', ['OK'], 'OK', INVALID_OWNER])
        self.assertEqual(int(info(admin, 'owners')['owners_known']), known + 3)
        self.assertEqual(as_map(admin.call('OWNERS', 'INFO', 'fresh7'))[b'keys'], 1)
        self.assertEqual(app[3].call('LABEL', 'AS', 'OWNER', 'fresh7', 'GET', 'k'), b'v')
        for client in app:
            who = self.whoami(client)
            self.assertEqual((who[b'session'], who[b'pinned-owner']), (0, None))

    def owner_bytes(self, owner):
        return as_map(self.admin.call('OWNERS', 'INFO', owner))[b'bytes']

    def test_a_users_scripts_count_toward_its_quota(self):
        admin, app, shared = self.admin, self.connect('app'), self.connect('shared')
        u1, u2 = ('LABEL', 'AS', 'OWNER', 'u1'), ('LABEL', 'AS', 'OWNER', 'u2')
        quota_oom = "OOM command not allowed when used memory > 'owner-quota'."
        app.call(*u1, 'PING')
        base = self.owner_bytes('u1')
        pinned, evaled, common = 'return "%s"' % ('a' * 200), 'return "%s"' % ('b' * 300), 'return "%s"' % ('c' * 50)
        held = app.call(*u1, 'SCRIPT', 'LOAD', pinned)
        step_pinned = self.owner_bytes('u1') - base
        self.assertEqual(app.call(*u1, 'EVAL', evaled, 0), b'b' * 300)
        step_evaled = self.owner_bytes('u1') - base - step_pinned
        charge = step_pinned - len(pinned)
        self.assertGreater(charge, 0)
        self.assertEqual(step_evaled - len(evaled), charge)
        before = self.owner_bytes('u1')
        self.assertEqual(shared.call('LABEL', 'AS', 'SHARED', 'SCRIPT', 'LOAD', common), hashlib.sha1(common.encode()).hexdigest().encode())
        self.assertEqual(self.owner_bytes('u1'), before)
        app.call(*u1, 'SCRIPT', 'LOAD', common)
        self.assertEqual(self.owner_bytes('u1') - before, charge + len(common))
        self.assertEqual(app.call(*u1, 'EVAL', pinned, 0), b'a' * 200)
        self.assertEqual(app.call(*u1, 'SCRIPT', 'LOAD', pinned), held)
        self.assertEqual(self.owner_bytes('u1') - before, charge + len(common))
        used = self.owner_bytes('u1')
        self.assertEqual(admin.call('OWNERS', 'QUOTA', 'u1', 'LIMIT', used + charge + 100), 'OK')
        cached = int(info(admin, 'memory')['number_of_cached_scripts'])
        big = 'return "%s"' % ('d' * 600)
        self.assertEqual(error_of(app, *u1, 'SCRIPT', 'LOAD', big), quota_oom)
        self.assertEqual(error_of(app, *u1, 'EVAL', big, 0), quota_oom)
        self.assertEqual(admin.call('SCRIPT', 'EXISTS', hashlib.sha1(big.encode()).hexdigest()), [0])
        self.assertEqual(app.call(*u1, 'SCRIPT', 'EXISTS', held, hashlib.sha1(evaled.encode()).hexdigest()), [1, 1])
        self.assertEqual(int(info(admin, 'memory')['number_of_cached_scripts']), cached)
        self.assertEqual(self.owner_bytes('u1'), used)
        room = 'return "%s"' % ('e' * 300)
        self.assertEqual(app.call(*u1, 'EVAL', room, 0), b'e' * 300)
        self.assertEqual(app.call(*u1, 'SCRIPT', 'EXISTS', held, hashlib.sha1(evaled.encode()).hexdigest()), [1, 0])
        self.assertEqual(self.owner_bytes('u1'), used - len(evaled) + len(room))
        later = 'return "%s"' % ('f' * 300)
        self.assertEqual(app.call(*u1, 'EVAL', later, 0), b'f' * 300)
        self.assertEqual(app.call(*u1, 'SCRIPT', 'EXISTS', hashlib.sha1(room.encode()).hexdigest(), hashlib.sha1(later.encode()).hexdigest(), held), [0, 1, 1])
        self.assertEqual(admin.call('OWNERS', 'QUOTA', 'u1', 'LIMIT', 1), 'OK')
        self.assertEqual(app.call(*u1, 'EVALSHA', held, 0), b'a' * 200)
        self.assertEqual(app.call(*u1, 'EVAL', pinned, 0), b'a' * 200)
        self.assertEqual(app.call(*u1, 'SCRIPT', 'LOAD', common), hashlib.sha1(common.encode()).hexdigest().encode())
        self.assertEqual(shared.call('LABEL', 'AS', 'SHARED', 'SCRIPT', 'LOAD', big), hashlib.sha1(big.encode()).hexdigest().encode())
        self.assertEqual(app.call(*u2, 'SCRIPT', 'LOAD', big), hashlib.sha1(big.encode()).hexdigest().encode())
        self.assertEqual(error_of(app, *u1, 'SCRIPT', 'LOAD', big), quota_oom)
        total = self.owner_bytes('u1')
        cached = int(info(admin, 'memory')['number_of_cached_scripts'])
        self.assertEqual(as_map(admin.call('OWNERS', 'FORGET', 'u1'))[b'bytes'], total)
        self.assertEqual(int(info(admin, 'memory')['number_of_cached_scripts']), cached - 2)
        self.assertEqual(app.call(*u1, 'SCRIPT', 'EXISTS', held), [0])
        self.assertEqual(app.call(*u2, 'SCRIPT', 'EXISTS', hashlib.sha1(big.encode()).hexdigest()), [1])

    def test_script_bytes_count_once_in_used_memory(self):
        admin, app = self.admin, self.connect('app')
        u3 = ('LABEL', 'AS', 'OWNER', 'u3')
        shared = self.connect('shared')
        app.call(*u3, 'PING')
        shared.call('LABEL', 'AS', 'SHARED', 'PING')
        grown = []
        for client, prefix, letter in ((shared, ('LABEL', 'AS', 'SHARED'), 'h'), (app, u3, 'g')):
            body = 'return "%s"' % (letter * 20000)
            memory, owned = int(info(admin, 'memory')['used_memory']), self.owner_bytes('u3')
            client.call(*prefix, 'SCRIPT', 'LOAD', body)
            grown.append(int(info(admin, 'memory')['used_memory']) - memory)
            charged = self.owner_bytes('u3') - owned
        self.assertGreater(charged, len(body))
        self.assertGreaterEqual(grown[1], len(body))
        self.assertLess(abs(grown[1] - grown[0]), len(body) // 2)

    def test_function_changes_need_the_operator_at_top(self):
        library = "#!lua name=lib\nredis.register_function('f', function() return 'one' end)"
        top, app, fixed, op = self.connect('top'), self.connect('app'), self.connect('fixed'), self.connect('op')
        for client, prefix, text in ((top, ('LABEL', 'AS', 'OWNER', 'u1'), OPERATOR_ERROR), (app, ('LABEL', 'AS', 'OWNER', 'u1'), TOP_ERROR),
                                     (fixed, (), TOP_ERROR)):
            for command in (('FUNCTION', 'LOAD', library), ('FUNCTION', 'DELETE', 'lib'), ('FUNCTION', 'FLUSH'),
                            ('FUNCTION', 'RESTORE', b'\x00'), ('SCRIPT', 'FLUSH')):
                self.assertEqual(error_of(client, *prefix, *command), text)
        self.assertEqual(op.call('LABEL', 'AS', 'OWNER', 'u1', 'FUNCTION', 'LOAD', library), b'lib')
        self.assertEqual(app.call('LABEL', 'AS', 'OWNER', 'u2', 'FCALL', 'f', 0), b'one')
        self.assertEqual(fixed.call('FCALL', 'f', 0), b'one')
        self.assertEqual(len(fixed.call('FUNCTION', 'LIST')), 1)
        self.assertEqual(self.admin.call('FUNCTION', 'DELETE', 'lib'), 'OK')
        self.assertEqual(op.call('LABEL', 'AS', 'OWNER', 'u1', 'SCRIPT', 'FLUSH'), 'OK')

    def test_scripts_are_cached_per_user(self):
        app, shared, plain, op = self.connect('app'), self.connect('shared'), self.connect('plain'), self.connect('op')
        u1 = ('LABEL', 'AS', 'S//A', 'OWNER', 'u1')
        u2 = ('LABEL', 'AS', 'S//A', 'OWNER', 'u2')
        mine = app.call(*u1, 'SCRIPT', 'LOAD', "return 'mine'")
        self.assertEqual(app.call(*u1, 'SCRIPT', 'EXISTS', mine), [1])
        self.assertEqual(app.call(*u2, 'SCRIPT', 'EXISTS', mine), [0])
        self.assertEqual(error_of(app, *u2, 'EVALSHA', mine, 0), 'NOSCRIPT No matching script. Please use EVAL.')
        self.assertEqual(plain.call('SCRIPT', 'EXISTS', mine), [0])
        self.assertEqual(shared.call('LABEL', 'AS', 'SHARED', 'SCRIPT', 'EXISTS', mine), [0])
        common = shared.call('LABEL', 'AS', 'SHARED', 'SCRIPT', 'LOAD', "return 'common'")
        seen = plain.call('SCRIPT', 'LOAD', "return 'seen'")
        for prefix in (u1, u2):
            self.assertEqual(app.call(*prefix, 'SCRIPT', 'EXISTS', common, seen), [1, 1])
            self.assertEqual(app.call(*prefix, 'EVALSHA', common, 0), b'common')
        self.assertEqual(app.call('LABEL', 'AS', 'C', 'OWNER', 'u1', 'SCRIPT', 'EXISTS', common, seen), [0, 1])
        self.assertEqual(self.admin.call('SCRIPT', 'EXISTS', mine, common, seen), [1, 1, 1])
        self.assertEqual(op.call('LABEL', 'AS', 'OWNER', 'u2', 'SCRIPT', 'EXISTS', mine), [1])
        self.assertEqual(op.call('LABEL', 'AS', 'C', 'OWNER', 'u2', 'SCRIPT', 'EXISTS', mine, seen), [0, 1])
        self.assertEqual(app.call(*u2, 'EVAL', "return 'mine'", 0), b'mine')
        self.assertEqual(app.call(*u2, 'EVALSHA', mine, 0), b'mine')
        self.assertEqual(int(info(self.admin, 'memory')['number_of_cached_scripts']), 3)
        text = app.call(*u1, 'INFO', 'memory').decode()
        self.assertIn('\r\nnumber_of_cached_scripts:0\r\n', text)

    def test_forget_drops_the_users_scripts_and_random_stream(self):
        app = self.connect('app')
        u1 = ('LABEL', 'AS', 'S//A', 'OWNER', 'u1')
        u2 = ('LABEL', 'AS', 'S//A', 'OWNER', 'u2')
        draws = 'return {math.random(1000000), math.random(1000000)}'
        first = app.call(*u1, 'EVAL', draws, 0)
        both = app.call(*u1, 'SCRIPT', 'LOAD', "return 'both'")
        alone = app.call(*u1, 'SCRIPT', 'LOAD', "return 'alone'")
        self.assertEqual(app.call(*u2, 'EVAL', "return 'both'", 0), b'both')
        self.assertNotEqual(app.call(*u1, 'EVAL', draws, 0), first)
        self.assertEqual(int(info(self.admin, 'memory')['number_of_cached_scripts']), 3)
        self.admin.call('OWNERS', 'FORGET', 'u1')
        self.assertEqual(app.call(*u1, 'SCRIPT', 'EXISTS', both, alone), [0, 0])
        self.assertEqual(app.call(*u2, 'SCRIPT', 'EXISTS', both, alone), [1, 0])
        self.assertEqual(int(info(self.admin, 'memory')['number_of_cached_scripts']), 1)
        self.assertEqual(app.call(*u1, 'EVAL', draws, 0), first)

    def scripted_world(self, hidden):
        server = Server(BINARY, workers=0, arguments=('--keyspace-threads', str(KEYSPACE_THREADS), '--memcached-port', '0', '--owners', 'yes',
                                                      '--label-stream-seed', '5') + SCHEME)
        self.addCleanup(server.close)
        server.start()
        admin = Client(server.port)
        self.addCleanup(admin.close)
        admin.call('ACL', 'SETUSER', 'default', 'clearance:*', 'owner-operator')
        admin.call('ACL', 'SETUSER', 'app', 'on', 'nopass', '+@all', '~*', '&*', 'clearance:S//A', 'owners:*')
        app = Client(server.port)
        self.addCleanup(app.close)
        app.call('AUTH', 'app', 'x')
        observed = []
        settings = "return {math.random(1000000), cjson.encode_max_depth(), cjson.encode_number_precision(), cjson.encode({0.123456789012})}"
        for step in range(5):
            if hidden:
                app.call('LABEL', 'AS', 'OWNER', 'u2', 'EVAL', 'math.randomseed(1); cjson.encode_max_depth(4); cjson.encode_number_precision(1); return math.random(9)', 0)
                app.call('LABEL', 'AS', 'C', 'OWNER', 'u1', 'EVAL', 'return math.random(9)', 0)
                app.call('LABEL', 'AS', 'S//A', 'OWNER', 'u1', 'EVAL', 'return math.random(9)', 0)
            observed.append(app.call('LABEL', 'AS', 'C', 'OWNER', 'u2', 'EVAL', settings, 0))
        return observed

    def test_script_randomness_and_json_settings_stay_within_a_user(self):
        quiet = self.scripted_world(False)
        noisy = self.scripted_world(True)
        self.assertEqual(quiet, noisy)
        self.assertEqual([row[1:] for row in quiet], [[1000, 14, b'[0.123456789012]']] * 5)


class OwnersWithoutLabels(OwnerMode):
    extra = ()

    def setup_logins(self):
        self.admin.call('ACL', 'SETUSER', 'user', 'on', 'nopass', '+@all', '~*', '&*', 'owner:u1')

    def test_one_level_with_owners_is_protected_and_top_needs_the_operator(self):
        user = self.connect('user')
        who = self.whoami(user)
        self.assertEqual((who[b'label'], who[b'owner'], who[b'top']), (b'UNCLASSIFIED', b'u1', 0))
        self.assertEqual(error_of(user, 'DEBUG', 'SLEEP', 0), OPERATOR_ERROR)
        self.assertEqual(error_of(user, 'SAVE'), OWNER_PERSIST_ERROR)
        self.assertEqual(error_of(self.admin, 'CONFIG', 'SET', 'save', '60 1'),
                         "ERR CONFIG SET failed (possibly related to argument 'save') - persistence stays off while owner mode is on")
        self.assertEqual(self.admin.call('DEBUG', 'SLEEP', 0), 'OK')
        self.assertEqual(self.whoami(self.admin)[b'top'], 1)
        self.assertEqual(user.call('SET', 'k', 'v'), 'OK')
        self.assertEqual(user.call('LABEL', 'AS', 'UNCLASSIFIED', 'OWNER', 'u1', 'GET', 'k'), b'v')
        events = [r['event'] for r in self.records()]
        self.assertEqual(events[0], 'owners-on')
        self.assertNotIn('scheme-load', events)

    def test_a_scheme_is_refused_while_owner_mode_holds_keys(self):
        user = self.connect('user')
        self.assertEqual(user.call('SET', 'k', 'v'), 'OK')
        self.assertEqual(error_of(self.admin, 'CONFIG', 'SET', 'label-levels', 'U,S'),
                         "ERR CONFIG SET failed (possibly related to argument 'label-levels') - a label scheme needs a server without keys, because existing keys carry no label")
        self.assertEqual(self.admin.call('CONFIG', 'GET', 'label-levels'), [b'label-levels', b'UNCLASSIFIED'])
        self.assertEqual(user.call('DEL', 'k'), 1)
        self.assertEqual(self.admin.call('CONFIG', 'SET', 'label-levels', 'U,S'), 'OK')


class Startup(unittest.TestCase):
    def refused(self, *arguments):
        with tempfile.TemporaryDirectory(prefix='eski-owners-start-') as directory:
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            process = subprocess.run([str(BINARY), '--bind', '127.0.0.1', '--port', str(port), '--dir', directory, '--owners', 'yes',
                                      '--appendonly', 'no', *arguments], stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
            self.assertNotEqual(process.returncode, 0)
            return (process.stdout + process.stderr).decode(errors='replace')

    def test_owner_mode_never_loads_a_data_file(self):
        with tempfile.TemporaryDirectory(prefix='eski-owners-file-') as directory:
            plain = Server(BINARY, workers=0)
            plain.start()
            try:
                writer = plain.client()
                writer.call('SET', 'old', 'value')
                writer.call('CONFIG', 'SET', 'dir', directory)
                self.assertEqual(writer.call('SAVE'), 'OK')
            finally:
                plain.close()
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            process = subprocess.run([str(BINARY), '--bind', '127.0.0.1', '--port', str(port), '--dir', directory, '--owners', 'yes',
                                      '--appendonly', 'no', '--save', '', '--memcached-port', '0'], stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
            self.assertEqual(process.returncode, 1)
            text = (process.stdout + process.stderr).decode(errors='replace')
            self.assertIn('Refusing to start: the data file dump.rdb in ', text)
            self.assertIn('a server with a label scheme or owner mode never loads it', text)

    def test_owner_mode_refuses_persistence_memcached_and_reserved_levels(self):
        self.assertIn('needs persistence off', self.refused('--save', '900 1'))
        self.assertIn('memcached endpoint off', self.refused('--save', '', '--memcached-port', '11421'))
        self.assertIn('without a level named OWNER or SHARED', self.refused('--save', '', '--label-levels', 'U,SHARED'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', default=str(BINARY))
    parser.add_argument('--keyspace-threads', type=int, default=0)
    known, rest = parser.parse_known_args()
    BINARY = Path(known.server).resolve()
    KEYSPACE_THREADS = known.keyspace_threads
    unittest.main(argv=[sys.argv[0]] + rest, verbosity=2)
