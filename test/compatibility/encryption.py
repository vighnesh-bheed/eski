import argparse
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
sys.path.insert(0, str(ROOT / 'test/threading'))
import labelled_files as lf
import scoped_log as sl
from support import ServerError

BINARY = ROOT / 'bin/eski'
THREADS = 0
FIXTURES = ROOT / 'test/compatibility/fixtures'

MAGIC = b'ESKIENC1'
HEADER = 58
OVERHEAD = 20
SEGMENT_MAX = 64 * 1024
CONTINUES = 0x80000000

LEVELS = 'PUBLICLEVEL,SECRETLEVEL'
COMPARTMENTS = 'ALPHACOMPART'
TRUSTS = 'WEBTRUST,VETTEDTRUST'
SCHEME = ('--label-levels', LEVELS, '--label-compartments', COMPARTMENTS, '--label-trust-levels', TRUSTS)
OWNERS = ('--owners', 'yes')
MODES = {'off': (), 'labels': SCHEME, 'owners': OWNERS, 'both': SCHEME + OWNERS}
TOP = {'labels': 'SECRETLEVEL//ALPHACOMPART', 'owners': 'UNCLASSIFIED', 'both': 'SECRETLEVEL//ALPHACOMPART'}
LOW = {'labels': 'PUBLICLEVEL', 'owners': 'UNCLASSIFIED', 'both': 'PUBLICLEVEL'}
HIGH = {'labels': 'SECRETLEVEL//ALPHACOMPART;VETTEDTRUST', 'owners': 'UNCLASSIFIED', 'both': 'SECRETLEVEL//ALPHACOMPART;VETTEDTRUST'}
OPERATOR = ('on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*')
OWNER_OPERATOR = OPERATOR + ('owners:*', 'owner-shared', 'owner-operator')
LOG = ('--appendonly', 'yes', '--appendfsync', 'always', '--auto-aof-rewrite-percentage', '0')
QUIET = ('--save', '')

KEY_NAME = 'needlekeyzebra'
VALUE = 'needlevalueokapi'
OWNER_ID = 'ownerquagga7'
NEEDLES = (KEY_NAME, VALUE, OWNER_ID, 'SECRETLEVEL', 'ALPHACOMPART', 'VETTEDTRUST', 'PUBLICLEVEL')

FIXTURE_KEY = '6b1d0c2e9f3a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9011223344'


def openssl(*arguments, data=None):
    return subprocess.run(['openssl', *arguments], input=data, capture_output=True, check=True).stdout


def fresh_key_text():
    return openssl('rand', '-hex', '32').decode().strip()


def key_id(key_text):
    out = openssl('kdf', '-keylen', '16', '-kdfopt', 'digest:SHA256', '-kdfopt', 'hexkey:' + key_text,
                  '-kdfopt', 'hexsalt:' + '00' * 32, '-kdfopt', 'info:eski key id v1', 'HKDF')
    return bytes.fromhex(out.decode().strip().replace(':', ''))


def write_key(path, text=None, mode=0o600):
    text = text if text is not None else fresh_key_text()
    path = Path(path)
    if path.exists():
        path.chmod(0o600)
    path.write_text(text + '\n')
    path.chmod(mode)
    return text


def header_of(data):
    return {'magic': data[:8], 'kind': data[8], 'algorithm': data[9], 'key_id': data[10:26], 'salt': data[26:58]}


def segments(data):
    out = []
    at = HEADER
    while at + 4 <= len(data):
        word = int.from_bytes(data[at:at + 4], 'little')
        n = word & 0x7fffffff
        out.append((at, n, bool(word & CONTINUES)))
        at += 4 + n + 16
    return out, at


def data_files(directory):
    skip = {'server.log', 'key', 'key.old', 'key.new', 'key.other', 'link'}
    return [p for p in sorted(Path(directory).rglob('*')) if p.is_file() and p.name not in skip]


def prefix(mode, label=None, owner=None):
    if mode == 'off':
        return ()
    label = label or TOP[mode]
    if mode == 'labels':
        return ('LABEL', 'AS', label)
    if not owner:
        return ('LABEL', 'AS', label, 'SHARED')
    return ('LABEL', 'AS', label, 'OWNER', owner)


class Node:
    def __init__(self, directory, mode, key=None, extra=()):
        self.mode = mode
        self.directory = Path(directory)
        args = list(MODES[mode])
        if key:
            args += ['--encryption-key-file', str(key)]
        args += list(extra)
        self.run = lf.Run(BINARY, directory, args, THREADS)

    def up(self, extra=()):
        code, text = self.run.start(extra)
        if code is not None:
            raise AssertionError('server exited with %r: %s' % (code, text[-3000:]))
        c = self.run.client()
        if self.mode != 'off':
            c.call('ACL', 'SETUSER', 'default', *(OWNER_OPERATOR if self.mode in ('owners', 'both') else OPERATOR))
        return c

    def refused(self, extra=()):
        code, text = self.run.start(extra)
        if code is None:
            self.run.stop()
            raise AssertionError('the server started where it had to refuse')
        return code, text

    def stop(self):
        return self.run.stop()

    def kill(self):
        self.run.kill()

    def pid(self):
        return self.run.process.pid


def top(mode):
    return prefix(mode, TOP.get(mode))


def workload(c, mode, big=False, tag=''):
    t = top(mode)
    scopes = [t]
    if mode in ('labels', 'both'):
        scopes.append(prefix(mode, HIGH[mode], OWNER_ID if mode == 'both' else None))
        scopes.append(prefix(mode, LOW[mode], '' if mode == 'both' else None))
    if mode == 'owners':
        scopes.append(prefix(mode, 'UNCLASSIFIED', OWNER_ID))
        scopes.append(prefix(mode, 'UNCLASSIFIED', ''))
    for i, p in enumerate(scopes):
        c.call(*p, 'SET', '%s%s%d' % (KEY_NAME, tag, i), '%s%d' % (VALUE, i))
        c.call(*p, 'HSET', 'h%s%d' % (tag, i), 'field', VALUE)
        c.call(*p, 'RPUSH', 'l%s%d' % (tag, i), VALUE, 'x', 'y')
        c.call(*p, 'SADD', 's%s%d' % (tag, i), VALUE, 'z')
        c.call(*p, 'ZADD', 'z%s%d' % (tag, i), 1, VALUE)
        c.call(*p, 'XADD', 'x%s%d' % (tag, i), '*', 'f', VALUE)
        c.call(*p, 'SET', 'e%s%d' % (tag, i), VALUE, 'PX', 100000000)
    if big:
        c.call(*t, 'SET', 'big' + tag, os.urandom(3 * SEGMENT_MAX // 2 + 500).hex())


def digest(c, mode):
    t = top(mode)
    out = [c.call(*t, 'DEBUG', 'DIGEST')]
    if mode != 'off':
        out.append(c.call(*t, 'DEBUG', 'DIGEST-SCOPES'))
    return out


def wait_info(c, mode, field, value, timeout=30):
    t = top(mode)
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if lf.info(c, *t).get(field) == value:
            return
        time.sleep(0.01)
    raise AssertionError('INFO %s did not become %s' % (field, value))


def wait_rewritten(c, mode, before):
    t = top(mode)
    end = time.monotonic() + 60
    while time.monotonic() < end:
        i = lf.info(c, *t)
        if int(i['aof_rewrites']) > before and i['aof_rewrite_in_progress'] == '0' and i['aof_rewrite_scheduled'] == '0':
            return
        time.sleep(0.01)
    raise AssertionError('the rewrite did not finish')


def rewrites(c, mode):
    return int(lf.info(c, *top(mode))['aof_rewrites'])


def manifest_path(directory):
    return Path(directory) / 'appendonlydir' / 'appendonly.aof.manifest'


def log_files(directory, suffix):
    d = Path(directory) / 'appendonlydir'
    end = time.monotonic() + 30
    while len([p for p in d.iterdir() if '.base.' in p.name]) > 1 and time.monotonic() < end:
        time.sleep(0.01)
    return sorted((p for p in d.iterdir() if p.name.endswith(suffix)), key=lambda p: int(p.name.split('.')[2]))


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = lf.workdir('eski-encryption-')
        self.dir = Path(self.tmp.name)
        self.key = self.dir / 'key'
        self.key_text = write_key(self.key)
        self.nodes = []
        self.keys = [self.key_text]

    def tearDown(self):
        for n in self.nodes:
            try:
                n.run.kill()
            except Exception:
                pass
        log = (self.dir / 'server.log').read_bytes() if (self.dir / 'server.log').exists() else b''
        for k in self.keys:
            self.assertNotIn(k.encode(), log)
            self.assertNotIn(k.upper().encode(), log)
            self.assertNotIn(bytes.fromhex(k), log)
        self.tmp.cleanup()

    def node(self, mode='off', key=True, extra=(), directory=None):
        n = Node(directory or self.dir, mode, self.key if key is True else key, extra)
        self.nodes.append(n)
        return n

    def assert_sealed(self, directory=None, key_text=None, kinds=None):
        files = data_files(directory or self.dir)
        self.assertTrue(files)
        want = key_id(key_text or self.key_text)
        for p in files:
            data = p.read_bytes()
            if len(data) == 0:
                continue
            h = header_of(data)
            self.assertEqual(h['magic'], MAGIC, str(p))
            self.assertEqual(h['algorithm'], 1, str(p))
            self.assertEqual(h['key_id'], want, str(p))
            if kinds is not None:
                self.assertEqual(h['kind'], kinds(p), str(p))
        return files

    def assert_no_plaintext(self, directory=None, extra=()):
        for p in data_files(directory or self.dir):
            data = p.read_bytes()
            for needle in NEEDLES + tuple(extra):
                self.assertNotIn(needle.encode(), data, '%s holds %s' % (p, needle))
            for k in self.keys:
                self.assertNotIn(k.encode(), data)
                self.assertNotIn(bytes.fromhex(k), data)


def kind_of(path):
    name = path.name
    if name.endswith('.manifest') or name.startswith('temp-appendonly.aof.manifest'):
        return 4
    if '.base.' in name or name.startswith('temp-rewriteaof'):
        return 2
    if name.endswith('.incr.aof') or name.endswith('.incr'):
        return 3
    return 1


class KeyFile(Case):
    def test_each_key_file_rule_refuses_the_start(self):
        good = self.key_text
        cases = [
            ('missing', None, 0o600, 'cannot be opened'),
            ('group', good + '\n', 0o640, 'can be read or written by its group'),
            ('others', good + '\n', 0o604, 'can be read or written by its group'),
            ('group-write', good + '\n', 0o620, 'can be read or written by its group'),
            ('short', good[:63] + '\n', 0o600, 'must hold exactly 64 hexadecimal characters'),
            ('long', good + '0\n', 0o600, 'must hold exactly 64 hexadecimal characters'),
            ('not-hex', good[:62] + 'zz\n', 0o600, 'must hold exactly 64 hexadecimal characters'),
            ('two-newlines', good + '\n\n', 0o600, 'must hold exactly 64 hexadecimal characters'),
            ('space', good + ' \n', 0o600, 'must hold exactly 64 hexadecimal characters'),
            ('empty', '', 0o600, 'must hold exactly 64 hexadecimal characters'),
        ]
        for name, text, mode, phrase in cases:
            with self.subTest(case=name):
                path = self.dir / ('k-' + name)
                if text is not None:
                    path.write_text(text)
                    path.chmod(mode)
                code, log = self.node(key=path).refused()
                self.assertEqual(code, 1)
                self.assertIn('Refusing to start: the encryption key file ' + str(path), log)
                self.assertIn(phrase, log)
                self.assertNotIn(good, log)
        directory = self.dir / 'k-dir'
        directory.mkdir(mode=0o700)
        code, log = self.node(key=directory).refused()
        self.assertEqual(code, 1)
        self.assertIn('is not a regular file', log)

    def test_the_owner_rule_is_checked(self):
        if os.geteuid() == 0:
            self.skipTest('the owner rule needs a user without root')
        self.assertTrue(any(p.stat().st_uid == 0 for p in [Path('/etc/hostname'), Path('/etc/passwd')] if p.exists()))
        code, log = self.node(key=Path('/etc/passwd')).refused()
        self.assertEqual(code, 1)
        self.assertIn('Refusing to start: the encryption key file /etc/passwd', log)

    def test_good_key_files_start_and_the_path_shows_by_exact_name_only(self):
        for mode in (0o400, 0o600):
            with self.subTest(mode=oct(mode)):
                self.key.chmod(mode)
                n = self.node()
                c = n.up()
                self.assertEqual(c.call('CONFIG', 'GET', 'encryption-key-file'), [b'encryption-key-file', str(self.key).encode()])
                self.assertEqual(c.call('CONFIG', 'GET', 'encryption-adopt-plain'), [b'encryption-adopt-plain', b'no'])
                listed = c.call('CONFIG', 'GET', '*')
                self.assertNotIn(b'encryption-key-file', listed)
                self.assertNotIn(self.key_text.encode(), b''.join(x for x in listed if isinstance(x, bytes)))
                with self.assertRaises(ServerError) as e:
                    c.call('CONFIG', 'SET', 'encryption-key-file', str(self.key))
                self.assertIn("can't set immutable config", str(e.exception))
                n.stop()
        link = self.dir / 'link'
        link.symlink_to(self.key)
        n = self.node(key=link)
        n.up()
        n.stop()

    def test_the_switches_need_a_key_and_a_previous_key_must_differ(self):
        for extra in (('--encryption-adopt-plain', 'yes'), ('--encryption-key-file-previous', str(self.key))):
            with self.subTest(extra=extra[0]):
                code, log = self.node(key=None, extra=extra).refused()
                self.assertEqual(code, 1)
                self.assertIn('encryption-adopt-plain and encryption-key-file-previous need encryption-key-file', log)
        same = self.dir / 'key.old'
        write_key(same, self.key_text)
        code, log = self.node(extra=('--encryption-key-file-previous', str(same))).refused()
        self.assertEqual(code, 1)
        self.assertIn('encryption-key-file-previous holds the same key as encryption-key-file', log)
        bad = self.dir / 'key.other'
        bad.write_text('x\n')
        bad.chmod(0o600)
        code, log = self.node(extra=('--encryption-key-file-previous', str(bad))).refused()
        self.assertIn('Refusing to start: the previous encryption key file ' + str(bad), log)


class Files(Case):
    def test_snapshots_from_save_bgsave_shutdown_and_reload_are_sealed_and_load(self):
        for mode in MODES:
            with self.subTest(mode=mode):
                d = self.dir / mode
                d.mkdir()
                n = self.node(mode, directory=d, extra=('--save', '3600 1'))
                c = n.up()
                workload(c, mode, big=True)
                want = digest(c, mode)
                self.assertEqual(c.call(*top(mode), 'SAVE'), 'OK')
                self.assert_sealed(d, kinds=kind_of)
                before = lf.info(c, *top(mode))['rdb_last_bgsave_status']
                c.call(*top(mode), 'BGSAVE')
                wait_info(c, mode, 'rdb_bgsave_in_progress', '0')
                self.assertEqual(before, 'ok')
                self.assertEqual(lf.info(c, *top(mode))['rdb_last_bgsave_status'], 'ok')
                self.assertEqual(c.call(*top(mode), 'DEBUG', 'RELOAD'), 'OK')
                self.assertEqual(digest(c, mode), want)
                workload(c, mode, tag='later')
                want = digest(c, mode)
                n.stop()
                files = self.assert_sealed(d, kinds=kind_of)
                self.assertEqual([p.name for p in files], ['dump.rdb'])
                self.assert_no_plaintext(d)
                c = n.up()
                self.assertEqual(digest(c, mode), want)
                n.stop()

    def test_the_log_base_increments_manifest_and_temporary_files_are_sealed_and_load(self):
        for mode in MODES:
            with self.subTest(mode=mode):
                d = self.dir / mode
                d.mkdir()
                n = self.node(mode, directory=d, extra=LOG + QUIET)
                c = n.up()
                workload(c, mode, big=True)
                before = rewrites(c, mode)
                c.call(*top(mode), 'BGREWRITEAOF')
                wait_rewritten(c, mode, before)
                workload(c, mode, tag='tail')
                self.assertEqual(c.call(*top(mode), 'DEBUG', 'LOADAOF'), 'OK')
                want = digest(c, mode)
                self.assert_sealed(d, kinds=kind_of)
                incr = log_files(d, '.incr.aof')
                kept = incr[-1].read_bytes()
                n.kill()
                c = n.up()
                self.assertEqual(digest(c, mode), want)
                after = log_files(d, '.incr.aof')
                self.assertEqual(len(after), len(incr) + 1)
                c.call(*top(mode), 'SET', 'one-more', 'x')
                self.assertEqual(after[-2].read_bytes(), kept)
                want = digest(c, mode)
                n.stop()
                self.assert_sealed(d, kinds=kind_of)
                self.assert_no_plaintext(d)
                c = n.up()
                self.assertEqual(digest(c, mode), want)
                n.stop()

    def test_turning_the_log_on_at_runtime_and_a_command_form_base_are_sealed(self):
        for preamble in ('yes', 'no'):
            with self.subTest(preamble=preamble):
                d = self.dir / preamble
                d.mkdir()
                n = self.node('off', directory=d, extra=QUIET + ('--aof-use-rdb-preamble', preamble, '--appendfsync', 'always'))
                c = n.up()
                workload(c, 'off', big=True)
                c.call('CONFIG', 'SET', 'appendonly', 'yes')
                wait_info(c, 'off', 'aof_rewrite_in_progress', '0')
                wait_info(c, 'off', 'aof_rewrites', '1')
                workload(c, 'off', tag='after')
                want = digest(c, 'off')
                n.stop()
                self.assert_sealed(d, kinds=kind_of)
                self.assert_no_plaintext(d)
                c = n.up(('--appendonly', 'yes'))
                self.assertEqual(digest(c, 'off'), want)
                n.stop()

    def test_temporary_files_are_sealed_while_they_are_written(self):
        n = self.node('off', extra=LOG + QUIET)
        c = n.up()
        for i in range(300):
            c.call('SET', '%s%d' % (KEY_NAME, i), os.urandom(6000).hex())
        c.call('CONFIG', 'SET', 'rdb-key-save-delay', '20000')
        for command, field, kind in (('BGSAVE', 'rdb_bgsave_in_progress', 1), ('BGREWRITEAOF', 'aof_rewrite_in_progress', 2)):
            with self.subTest(command=command):
                c.call(command)
                seen = None
                end = time.monotonic() + 60
                while time.monotonic() < end and seen is None:
                    for p in self.dir.iterdir():
                        if p.name.startswith('temp-') and p.stat().st_size > 2 * SEGMENT_MAX:
                            seen = p.read_bytes()
                            break
                    time.sleep(0.01)
                self.assertIsNotNone(seen)
                self.assertEqual(seen[:8], MAGIC)
                self.assertEqual(seen[8], kind)
                self.assertNotIn(KEY_NAME.encode(), seen)
                c.call('CONFIG', 'SET', 'rdb-key-save-delay', '0')
                wait_info(c, 'off', field, '0', timeout=120)
                c.call('CONFIG', 'SET', 'rdb-key-save-delay', '20000')
        c.call('CONFIG', 'SET', 'rdb-key-save-delay', '0')
        n.stop()

    def test_every_file_gets_its_own_salt(self):
        n = self.node('both', extra=LOG + ('--save', '3600 1'))
        c = n.up()
        salts = []
        for round_number in range(3):
            workload(c, 'both', tag=str(round_number))
            c.call(*top('both'), 'SAVE')
            before = rewrites(c, 'both')
            c.call(*top('both'), 'BGREWRITEAOF')
            wait_rewritten(c, 'both', before)
            log_files(self.dir, '.incr.aof')
            for p in data_files(self.dir):
                salts.append(header_of(p.read_bytes())['salt'])
        n.stop()
        self.assertEqual(len(salts), 12)
        self.assertEqual(len(set(salts)), len(salts))

    def test_turning_owner_mode_on_with_the_log_and_the_shutdown_rewrite_are_sealed(self):
        n = self.node('off', extra=LOG + QUIET)
        c = n.up()
        c.call('CONFIG', 'SET', 'owners', 'yes')
        c.call('ACL', 'SETUSER', 'default', *OWNER_OPERATOR)
        self.assert_sealed(kinds=kind_of)
        p = prefix('owners', 'UNCLASSIFIED', OWNER_ID)
        c.call(*p, 'SET', KEY_NAME, VALUE)
        c.call(*prefix('owners', 'UNCLASSIFIED', ''), 'SET', 'kept', 'yes')
        c.call(*top('owners'), 'OWNERS', 'FORGET', OWNER_ID)
        before = rewrites(c, 'owners')
        self.assertGreaterEqual(before, 1)
        n.stop()
        self.assertIn('OWNERS FORGET ran after the last append-only rewrite, so the append-only file is rewritten before exiting', n.run.log())
        self.assert_sealed(kinds=kind_of)
        self.assert_no_plaintext()
        n2 = self.node('owners', extra=LOG + QUIET)
        c = n2.up()
        self.assertEqual(c.call(*prefix('owners', 'UNCLASSIFIED', ''), 'GET', 'kept'), b'yes')
        self.assertIsNone(c.call(*prefix('owners', 'UNCLASSIFIED', OWNER_ID), 'GET', KEY_NAME))
        n2.stop()

    def test_a_frozen_sealed_snapshot_still_loads(self):
        write_key(self.key, FIXTURE_KEY)
        self.keys.append(FIXTURE_KEY)
        data = bytes.fromhex((FIXTURES / 'encrypted-snapshot.hex').read_text().strip())
        self.assertEqual(header_of(data)['key_id'], key_id(FIXTURE_KEY))
        (self.dir / 'dump.rdb').write_bytes(data)
        n = self.node('off', extra=QUIET)
        c = n.up()
        self.assertEqual(c.call('GET', 'frozen'), b'format')
        self.assertEqual(c.call('LRANGE', 'frozen-list', 0, -1), [b'a', b'b', b'c'])
        n.stop()


class Behaviour(Case):
    def sealed_dir(self, mode='off', log=False, big=False):
        n = self.node(mode, extra=(LOG + QUIET) if log else QUIET)
        c = n.up()
        workload(c, mode, big=big)
        want = digest(c, mode)
        if not log:
            c.call(*top(mode), 'SAVE')
        n.stop()
        return want

    def test_no_key_refuses_an_encrypted_snapshot_and_an_encrypted_log(self):
        self.sealed_dir()
        code, log = self.node(key=None, extra=QUIET).refused()
        self.assertEqual(code, 1)
        self.assertIn('Refusing to load the data file dump.rdb: the data file is encrypted; set encryption-key-file', log)
        (self.dir / 'dump.rdb').unlink()
        self.sealed_dir(log=True)
        code, log = self.node(key=None, extra=LOG + QUIET).refused()
        self.assertEqual(code, 1)
        self.assertIn('the data file is encrypted; set encryption-key-file', log)

    def test_another_key_refuses_before_decrypting(self):
        self.sealed_dir('labels')
        other = self.dir / 'key.other'
        self.keys.append(write_key(other))
        code, log = self.node('labels', key=other, extra=QUIET).refused()
        self.assertEqual(code, 1)
        self.assertIn('Refusing to load the data file dump.rdb: the data file was written with another key', log)
        (self.dir / 'dump.rdb').unlink()
        self.sealed_dir('labels', log=True)
        code, log = self.node('labels', key=other, extra=LOG + QUIET).refused()
        self.assertIn('the data file was written with another key', log)

    def test_a_damaged_snapshot_is_refused_naming_the_segment(self):
        want = self.sealed_dir('both', big=True)
        path = self.dir / 'dump.rdb'
        good = path.read_bytes()
        segs, end = segments(good)
        self.assertEqual(end, len(good))
        self.assertGreaterEqual(len(segs), 3)
        for k in (0, 1, len(segs) - 1):
            for where in ('cipher', 'tag', 'length'):
                with self.subTest(segment=k, where=where):
                    at, size, _ = segs[k]
                    spot = {'cipher': at + 4 + min(size // 2, size - 1) if size else at + 4, 'tag': at + 4 + size + 3, 'length': at + 1}[where]
                    bad = bytearray(good)
                    bad[spot] ^= 0x04
                    path.write_bytes(bytes(bad))
                    code, log = self.node('both', extra=QUIET).refused()
                    self.assertEqual(code, 1)
                    if where != 'length':
                        self.assertIn('The encrypted data file dump.rdb is damaged at segment %d' % k, log)
                    else:
                        self.assertIn('The encrypted data file dump.rdb is', log)
        for cut in (segs[1][0], segs[-1][0], len(good) - 1):
            with self.subTest(cut=cut):
                path.write_bytes(good[:cut])
                code, log = self.node('both', extra=QUIET).refused()
                self.assertEqual(code, 1)
                self.assertIn('The encrypted data file dump.rdb is cut short at segment', log)
        path.write_bytes(good)
        c = self.node('both', extra=QUIET).up()
        self.assertEqual(digest(c, 'both'), want)

    def log_with_batches(self, mode='off', extra=(), directory=None):
        n = self.node(mode, extra=LOG + QUIET + tuple(extra), directory=directory)
        c = n.up()
        for i in range(6):
            c.call(*top(mode), 'SET', 'k%d' % i, 'v%d' % i)
        return n, c

    def test_a_damaged_middle_segment_of_the_log_is_refused(self):
        n, c = self.log_with_batches()
        n.kill()
        incr = log_files(self.dir, '.incr.aof')[-1]
        good = incr.read_bytes()
        segs, end = segments(good)
        self.assertEqual(end, len(good))
        self.assertGreaterEqual(len(segs), 6)
        for k in (1, 3):
            for loading in ('yes', 'no'):
                with self.subTest(segment=k, truncated=loading):
                    at, size, _ = segs[k]
                    bad = bytearray(good)
                    bad[at + 4 + size // 2] ^= 0x80
                    incr.write_bytes(bytes(bad))
                    code, log = self.node(extra=LOG + QUIET + ('--aof-load-truncated', loading)).refused()
                    self.assertEqual(code, 1)
                    self.assertIn('The encrypted data file %s is damaged at segment %d' % (incr.name, k), log)
                    self.assertEqual(incr.read_bytes(), bytes(bad))
        incr.write_bytes(good)
        c = self.node(extra=LOG + QUIET).up()
        self.assertEqual(c.call('GET', 'k5'), b'v5')

    def torn_log(self, directory):
        directory.mkdir()
        n, c = self.log_with_batches(directory=directory)
        c.call('SET', 'huge', 'q' * (2 * SEGMENT_MAX + 500))
        n.kill()
        incr = log_files(directory, '.incr.aof')[-1]
        good = incr.read_bytes()
        segs, end = segments(good)
        self.assertEqual(end, len(good))
        self.assertEqual([s[2] for s in segs[-3:]], [True, True, False])
        return incr, good, segs

    def test_a_torn_last_segment_follows_aof_load_truncated(self):
        incr, good, segs = self.torn_log(self.dir / 'probe')
        huge_at = segs[-3][0]
        last_small = segs[-4][0]
        cases = [
            (huge_at + 2, huge_at, True),
            (segs[-2][0] + 9, huge_at, True),
            (segs[-1][0], huge_at, True),
            (len(good) - 1, huge_at, True),
            (last_small + 7, last_small, False),
        ]
        for i, (cut, boundary, k5) in enumerate(cases):
            with self.subTest(cut=cut):
                d = self.dir / ('cut%d' % i)
                incr, good, segs = self.torn_log(d)
                incr.write_bytes(good[:cut])
                code, log = self.node(extra=LOG + QUIET + ('--aof-load-truncated', 'no'), directory=d).refused()
                self.assertEqual(code, 1)
                self.assertEqual(incr.read_bytes(), good[:cut])
                n2 = self.node(extra=LOG + QUIET + ('--aof-load-truncated', 'yes'), directory=d)
                c = n2.up()
                self.assertIn('is incomplete', n2.run.log())
                self.assertEqual(incr.stat().st_size, boundary)
                self.assertEqual(incr.read_bytes(), good[:boundary])
                self.assertIsNone(c.call('GET', 'huge'))
                self.assertEqual(c.call('GET', 'k4'), b'v4')
                self.assertEqual(c.call('GET', 'k5'), b'v5' if k5 else None)
                c.call('SET', 'after', 'cut')
                n2.stop()
                c = self.node(extra=LOG + QUIET, directory=d).up()
                self.assertEqual(c.call('GET', 'after'), b'cut')
                self.assertEqual(c.call('GET', 'k4'), b'v4')
                self.nodes[-1].stop()

    def test_plain_files_under_a_key_are_refused(self):
        n = self.node('owners', key=None, extra=QUIET)
        c = n.up()
        workload(c, 'owners')
        c.call(*top('owners'), 'SAVE')
        n.stop()
        code, log = self.node('owners', extra=QUIET).refused()
        self.assertEqual(code, 1)
        self.assertIn('Refusing to load the data file dump.rdb: the data file is not encrypted although encryption-key-file is set', log)
        (self.dir / 'dump.rdb').unlink()
        n = self.node('owners', key=None, extra=LOG + QUIET)
        c = n.up()
        workload(c, 'owners')
        n.stop()
        code, log = self.node('owners', extra=LOG + QUIET).refused()
        self.assertEqual(code, 1)
        self.assertIn('the data file is not encrypted although encryption-key-file is set', log)

    def test_a_swapped_or_shortened_closed_file_is_refused(self):
        n = self.node('both', extra=LOG + QUIET)
        c = n.up()
        workload(c, 'both', tag='a')
        before = rewrites(c, 'both')
        c.call(*top('both'), 'BGREWRITEAOF')
        wait_rewritten(c, 'both', before)
        old_base = log_files(self.dir, '.base.rdb')[-1].read_bytes()
        old_incr = log_files(self.dir, '.incr.aof')[-1]
        c.call(*top('both'), 'OWNERS', 'FORGET', OWNER_ID)
        workload(c, 'both', tag='b')
        old_incr_bytes = old_incr.read_bytes()
        before = rewrites(c, 'both')
        c.call(*top('both'), 'BGREWRITEAOF')
        wait_rewritten(c, 'both', before)
        workload(c, 'both', tag='c')
        n.stop()
        c = self.node('both', extra=LOG + QUIET).up()
        c.call(*top('both'), 'SET', 'last', 'one')
        want = digest(c, 'both')
        self.nodes[-1].stop()
        base = log_files(self.dir, '.base.rdb')[-1]
        incrs = log_files(self.dir, '.incr.aof')
        self.assertGreaterEqual(len(incrs), 2)
        self.assertEqual(header_of(old_base)['kind'], 2)
        good_base = base.read_bytes()
        base.write_bytes(incrs[-1].read_bytes())
        code, log = self.node('both', extra=LOG + QUIET).refused()
        self.assertEqual(code, 1)
        self.assertIn('the data file is an encrypted file of another kind', log)
        base.write_bytes(old_base)
        code, log = self.node('both', extra=LOG + QUIET).refused()
        self.assertEqual(code, 1)
        self.assertIn('it is not the file the manifest lists, because its salt differs', log)
        base.write_bytes(good_base)
        closed = incrs[-2]
        good_closed = closed.read_bytes()
        closed.write_bytes(old_incr_bytes)
        code, log = self.node('both', extra=LOG + QUIET).refused()
        self.assertIn('salt differs', log)
        segs, _ = segments(good_closed)
        if len(segs) > 1:
            closed.write_bytes(good_closed[:segs[-1][0]])
            code, log = self.node('both', extra=LOG + QUIET).refused()
            self.assertIn('bytes long and the manifest records', log)
        closed.write_bytes(good_closed)
        manifest = manifest_path(self.dir)
        good_manifest = manifest.read_bytes()
        bad = bytearray(good_manifest)
        bad[HEADER + 10] ^= 1
        manifest.write_bytes(bytes(bad))
        code, log = self.node('both', extra=LOG + QUIET).refused()
        self.assertIn('the encrypted manifest cannot be opened: the file fails its authentication check', log)
        manifest.write_bytes(good_manifest)
        c = self.node('both', extra=LOG + QUIET).up()
        self.assertEqual(digest(c, 'both'), want)


class Runtime(Case):
    def test_a_runtime_reload_of_a_file_it_must_refuse_keeps_the_keyspace(self):
        plain_dir = self.dir / 'plain'
        plain_dir.mkdir()
        n = self.node('off', key=None, extra=QUIET, directory=plain_dir)
        c = n.up()
        c.call('SET', 'planted', 'plain')
        c.call('SAVE')
        n.stop()
        other_dir = self.dir / 'other'
        other_dir.mkdir()
        other = self.dir / 'key.other'
        self.keys.append(write_key(other))
        n = self.node('off', key=other, extra=QUIET, directory=other_dir)
        c = n.up()
        c.call('SET', 'planted', 'other')
        c.call('SAVE')
        n.stop()
        n = self.node('off', extra=QUIET)
        c = n.up()
        workload(c, 'off')
        c.call('SAVE')
        want = digest(c, 'off')
        good = (self.dir / 'dump.rdb').read_bytes()
        for source, phrase in ((plain_dir, 'is not encrypted although encryption-key-file is set'), (other_dir, 'was written with another key')):
            with self.subTest(source=source.name):
                (self.dir / 'dump.rdb').write_bytes((source / 'dump.rdb').read_bytes())
                with self.assertRaises(ServerError):
                    c.call('DEBUG', 'RELOAD', 'NOSAVE')
                self.assertIn(phrase, n.run.log())
                self.assertEqual(digest(c, 'off'), want)
        (self.dir / 'dump.rdb').write_bytes(good)
        self.assertEqual(c.call('DEBUG', 'RELOAD', 'NOSAVE'), 'OK')
        self.assertEqual(digest(c, 'off'), want)
        n.stop()
        plain = self.node('off', key=None, extra=QUIET)
        c = plain.up(('--dbfilename', 'none.rdb'))
        c.call('SET', 'x', 'y')
        (self.dir / 'none.rdb').write_bytes(good)
        with self.assertRaises(ServerError):
            c.call('DEBUG', 'RELOAD', 'NOSAVE')
        self.assertIn('is encrypted; set encryption-key-file', plain.run.log())
        self.assertEqual(c.call('GET', 'x'), b'y')
        plain.stop()


class Switches(Case):
    def plain_files(self, mode, log):
        n = self.node(mode, key=None, extra=(LOG + ('--save', '3600 1')) if log else ('--save', '3600 1'))
        c = n.up()
        workload(c, mode, big=True)
        want = digest(c, mode)
        n.stop()
        found = [p for p in data_files(self.dir) if VALUE.encode() in p.read_bytes() or KEY_NAME.encode() in p.read_bytes()]
        self.assertTrue(found)
        return want

    def test_adopting_plain_files_encrypts_them_once(self):
        for mode in ('off', 'both'):
            for log in (False, True):
                with self.subTest(mode=mode, log=log):
                    shutil.rmtree(self.dir / 'appendonlydir', ignore_errors=True)
                    for p in data_files(self.dir):
                        p.unlink()
                    want = self.plain_files(mode, log)
                    extra = (LOG if log else ()) + ('--save', '3600 1')
                    n = self.node(mode, extra=extra + ('--encryption-adopt-plain', 'yes'))
                    c = n.up()
                    self.assertEqual(digest(c, mode), want)
                    text = n.run.log()
                    self.assertIn('Copies and backups of the data files made before this start', text)
                    n.stop()
                    self.assert_sealed(kinds=kind_of)
                    self.assert_no_plaintext()
                    code, log_text = self.node(mode, extra=extra + ('--encryption-adopt-plain', 'yes')).refused()
                    self.assertEqual(code, 1)
                    self.assertIn('encryption-adopt-plain is set but no data file without encryption was found; remove the setting', log_text)
                    c = self.node(mode, extra=extra).up()
                    self.assertEqual(digest(c, mode), want)
                    self.nodes[-1].stop()

    def test_the_previous_key_opens_old_files_once_and_rewrites_them(self):
        for log in (False, True):
            with self.subTest(log=log):
                shutil.rmtree(self.dir / 'appendonlydir', ignore_errors=True)
                for p in data_files(self.dir):
                    p.unlink()
                extra = (LOG if log else ()) + ('--save', '3600 1')
                old = self.dir / 'key.old'
                old_text = write_key(old)
                self.keys.append(old_text)
                n = self.node('both', key=old, extra=extra)
                c = n.up()
                workload(c, 'both', big=True)
                if log:
                    before = rewrites(c, 'both')
                    c.call(*top('both'), 'BGREWRITEAOF')
                    wait_rewritten(c, 'both', before)
                    workload(c, 'both', tag='tail')
                want = digest(c, 'both')
                n.stop()
                self.assert_sealed(key_text=old_text)
                new = self.dir / 'key.new'
                new_text = write_key(new)
                self.keys.append(new_text)
                code, log_text = self.node('both', key=new, extra=extra).refused()
                self.assertIn('the data file was written with another key', log_text)
                n = self.node('both', key=new, extra=extra + ('--encryption-key-file-previous', str(old)))
                c = n.up()
                self.assertEqual(digest(c, 'both'), want)
                n.stop()
                self.assert_sealed(key_text=new_text)
                self.assert_no_plaintext()
                code, log_text = self.node('both', key=new, extra=extra + ('--encryption-key-file-previous', str(old))).refused()
                self.assertIn('encryption-key-file-previous is set but no data file written with the previous key was found; remove the setting', log_text)
                c = self.node('both', key=new, extra=extra).up()
                self.assertEqual(digest(c, 'both'), want)
                self.nodes[-1].stop()
                code, log_text = self.node('both', key=old, extra=extra).refused()
                self.assertIn('the data file was written with another key', log_text)


class Writes(Case):
    def test_a_failed_write_is_retried_and_the_log_still_loads(self):
        previous = signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        popen = lf.subprocess.Popen
        lf.subprocess.Popen = lambda *a, **k: popen(*a, restore_signals=False, **k)
        try:
            n = self.node('off', extra=LOG[:2] + ('--appendfsync', 'everysec', '--auto-aof-rewrite-percentage', '0') + QUIET)
            c = n.up()
        finally:
            lf.subprocess.Popen = popen
            signal.signal(signal.SIGXFSZ, previous)
        for i in range(5):
            c.call('SET', 'a%d' % i, 'v')
        incr = log_files(self.dir, '.incr.aof')[-1]
        size = incr.stat().st_size
        pid = n.pid()
        soft, hard = resource.prlimit(pid, resource.RLIMIT_FSIZE)
        resource.prlimit(pid, resource.RLIMIT_FSIZE, (size + 37, hard))
        acknowledged = []
        try:
            c.call('SET', 'blocked', 'w' * 500)
            acknowledged.append('blocked')
        except ServerError:
            pass
        wait_info(c, 'off', 'aof_last_write_status', 'err')
        refused = 0
        try:
            c.call('SET', 'meanwhile', 'x')
            acknowledged.append('meanwhile')
        except ServerError as e:
            refused += 1
            self.assertIn('MISCONF', str(e))
        resource.prlimit(pid, resource.RLIMIT_FSIZE, (soft, hard))
        wait_info(c, 'off', 'aof_last_write_status', 'ok')
        for i in range(5):
            c.call('SET', 'b%d' % i, 'v')
        want = digest(c, 'off')
        n.kill()
        good = incr.read_bytes()
        segs, end = segments(good)
        self.assertEqual(end, len(good))
        c = self.node('off', extra=LOG + QUIET).up()
        self.assertEqual(digest(c, 'off'), want)
        for k in acknowledged:
            self.assertIsNotNone(c.call('GET', k))
        self.assertEqual(c.call('GET', 'b4'), b'v')


class PendingWrite(Case):
    def limited(self, keyed, directory):
        previous = signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        popen = lf.subprocess.Popen
        lf.subprocess.Popen = lambda *a, **k: popen(*a, restore_signals=False, **k)
        try:
            n = self.node('off', key=True if keyed else None, extra=LOG[:2] + ('--appendfsync', 'everysec', '--auto-aof-rewrite-percentage', '0') + QUIET, directory=directory)
            c = n.up()
        finally:
            lf.subprocess.Popen = popen
            signal.signal(signal.SIGXFSZ, previous)
        return n, c

    def check_refused(self, keyed):
        d = self.dir / ('k' if keyed else 'p')
        d.mkdir()
        n, c = self.limited(keyed, d)
        for i in range(5):
            c.call('SET', 'a%d' % i, 'v')
        incr = log_files(d, '.incr.aof')[-1]
        pid = n.pid()
        soft, hard = resource.prlimit(pid, resource.RLIMIT_FSIZE)
        resource.prlimit(pid, resource.RLIMIT_FSIZE, (incr.stat().st_size + 37, hard))
        acknowledged = []
        try:
            c.call('SET', 'blocked', 'w' * 500)
            acknowledged.append('blocked')
        except ServerError:
            pass
        wait_info(c, 'off', 'aof_last_write_status', 'err')
        want = digest(c, 'off')
        with self.assertRaises(ServerError) as caught:
            c.call('DEBUG', 'LOADAOF')
        self.assertIn('DEBUG LOADAOF is refused', str(caught.exception))
        self.assertEqual(digest(c, 'off'), want)
        resource.prlimit(pid, resource.RLIMIT_FSIZE, (soft, hard))
        wait_info(c, 'off', 'aof_last_write_status', 'ok')
        self.assertEqual(c.call('DEBUG', 'LOADAOF'), 'OK')
        self.assertEqual(digest(c, 'off'), want)
        n.kill()
        c = self.node('off', key=True if keyed else None, extra=LOG + QUIET, directory=d).up()
        self.assertEqual(digest(c, 'off'), want)
        for k in acknowledged + ['a4']:
            self.assertIsNotNone(c.call('GET', k))
        self.nodes[-1].stop()

    def test_debug_loadaof_is_refused_while_a_write_error_is_pending_without_a_key(self):
        self.check_refused(False)

    def test_debug_loadaof_is_refused_while_a_write_error_is_pending_with_a_key(self):
        self.check_refused(True)


class LeftBehind(Case):
    def test_with_a_key_files_the_manifest_does_not_list_are_removed_at_a_start(self):
        n = self.node('off', extra=LOG + QUIET)
        c = n.up()
        workload(c, 'off')
        want = digest(c, 'off')
        n.stop()
        log = self.dir / 'appendonlydir'
        incr = log_files(self.dir, '.incr.aof')[-1]
        (log / 'appendonly.aof.9.incr.aof').write_bytes(incr.read_bytes())
        (log / 'temp-appendonly.aof.incr').write_bytes(incr.read_bytes())
        (log / 'notes.txt').write_bytes(b'kept')
        c = self.node('off', extra=LOG + QUIET).up()
        self.assertEqual(digest(c, 'off'), want)
        self.assertFalse((log / 'appendonly.aof.9.incr.aof').exists())
        self.assertFalse((log / 'temp-appendonly.aof.incr').exists())
        self.assertTrue((log / 'notes.txt').exists())
        self.nodes[-1].stop()

    def test_a_start_refused_for_a_switch_left_set_has_removed_the_history_it_dropped(self):
        n = self.node('off', extra=LOG + QUIET + ('--aof-disable-auto-gc', 'yes'))
        c = n.up()
        workload(c, 'off', big=True)
        before = rewrites(c, 'off')
        c.call('BGREWRITEAOF')
        wait_rewritten(c, 'off', before)
        workload(c, 'off', tag='tail')
        want = digest(c, 'off')
        n.stop()
        old = sorted(p.name for p in (self.dir / 'appendonlydir').iterdir())
        code, text = self.node('off', extra=LOG + QUIET + ('--encryption-adopt-plain', 'yes')).refused()
        self.assertIn('encryption-adopt-plain is set but no data file without encryption was found; remove the setting', text)
        self.assertIn('Removing the history file', text)
        left = sorted(p.name for p in (self.dir / 'appendonlydir').iterdir())
        gone = [x for x in old if x not in left]
        self.assertTrue(gone, (old, left))
        for line in text.splitlines():
            if 'Removing the history file ' in line:
                self.assertNotIn(line.split('Removing the history file ')[1].split()[0], left)
        c = self.node('off', extra=LOG + QUIET).up()
        self.assertEqual(digest(c, 'off'), want)
        self.nodes[-1].stop()


def main():
    global BINARY, THREADS
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', default=str(BINARY))
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--ports')
    parser.add_argument('rest', nargs='*')
    args = parser.parse_args()
    BINARY = Path(args.server)
    THREADS = args.keyspace_threads
    if args.ports:
        sl.use_ports(args.ports)
    unittest.main(argv=[sys.argv[0]] + args.rest, verbosity=2)


if __name__ == '__main__':
    main()
