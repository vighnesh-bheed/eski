import argparse
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
import scoped_log as sl
from support import ServerError

BINARY = ROOT / 'bin/eski'
KEYSPACE_THREADS = 0
MODES = ('labels', 'owners', 'both')
GENERIC = 'Bad file format reading the append only file'
SECRET_OWNER = b'SECRETOWNER9'
SECRET_VALUE = b'SECRETVALUE9'

MARKING = {'labels': b'S//A', 'owners': b'UNCLASSIFIED', 'both': b'S//A'}
LOW = {'labels': b'U', 'owners': b'UNCLASSIFIED', 'both': b'U'}
OTHER_MARKING = {'labels': b'C', 'owners': b'UNCLASSIFIED', 'both': b'C'}
HOLDER = {'labels': (b'U', None), 'owners': (b'UNCLASSIFIED', b''), 'both': (b'U', b'')}
WRITER = {'labels': (b'C', None), 'owners': (b'UNCLASSIFIED', b'u1'), 'both': (b'C', b'u1')}


def marker(mode, labelled=None, owners=None, version=b'1'):
    lab = (b'1' if sl.MODES[mode]['labelled'] else b'0') if labelled is None else labelled
    own = (b'1' if sl.MODES[mode]['owners'] else b'0') if owners is None else owners
    return [sl.MARKER, version, lab, own]


def head(mode, marking=None, owner=None):
    marking = MARKING[mode] if marking is None else marking
    row = [b'LABEL', b'AS', marking]
    if sl.MODES[mode]['owners'] and owner is not None:
        row += [b'SHARED'] if owner == b'' else [b'OWNER', owner]
    return row


def user(mode):
    return SECRET_OWNER if sl.MODES[mode]['owners'] else None


def scoped(mode, *inner, marking=None, owner=None):
    if owner is None:
        owner = user(mode)
    return head(mode, marking, owner) + list(inner)


def good(mode):
    return [marker(mode), [b'SELECT', b'0']]


def held(mode, *inner):
    marking, owner = HOLDER[mode]
    return scoped(mode, *inner, marking=marking, owner=owner)


def written(mode, *inner):
    marking, owner = WRITER[mode]
    return scoped(mode, *inner, marking=marking, owner=owner)


def holdings(mode):
    return good(mode) + [held(mode, b'SET', b'k', SECRET_VALUE), held(mode, b'SET', b'n', b'5'), held(mode, b'HSET', b'h', b'a', b'1'),
                         held(mode, b'RPUSH', b'l', b'x'), held(mode, b'SADD', b's', b'x'), held(mode, b'ZADD', b'z', b'1', b'x')]


class Case:
    def __init__(self, name, rows, reason, modes=MODES, extra=(), raw=None):
        self.name = name
        self.rows = rows
        self.reason = reason
        self.modes = modes
        self.extra = extra
        self.raw = raw

    def content(self, mode):
        if self.raw is not None:
            return self.raw(mode) if callable(self.raw) else self.raw
        rows = self.rows(mode) if callable(self.rows) else self.rows
        return sl.encode_records(rows)


def cases():
    out = []

    def add(name, rows, reason, modes=MODES, extra=(), raw=None):
        out.append(Case(name, rows, reason, modes, extra, raw))

    def after_good(*tail):
        return lambda mode: good(mode) + [list(t(mode)) if callable(t) else list(t) for t in tail]

    add('no marker, a select first', lambda m: [[b'SELECT', b'0'], scoped(m, b'SET', b'k', SECRET_VALUE)], 'does not start with the access marker')
    add('no marker, a scoped record first', lambda m: [scoped(m, b'SET', b'k', SECRET_VALUE)], 'does not start with the access marker')
    add('no marker, a transaction first', lambda m: [[b'MULTI'], scoped(m, b'SET', b'k', b'v'), [b'EXEC']], 'does not start with the access marker')
    add('no marker, an operator record first', lambda m: [[b'FUNCTION', b'FLUSH']], 'does not start with the access marker')
    add('no marker, the seed first', lambda m: [[sl.SEED, b'7']], 'does not start with the access marker')
    add('a marker of three words', lambda m: [marker(m)[:3]], 'form or version')
    add('a marker of five words', lambda m: [marker(m) + [b'x']], 'form or version')
    for version in (b'0', b'2', b'', b'01', b'1 ', b'one'):
        add('a marker of version %r' % version, lambda m, v=version: [marker(m, version=v)], 'form or version')
    for lab, own in ((b'0', b'0'), (b'1', b'0'), (b'0', b'1'), (b'1', b'1'), (b'2', b'0'), (b'0', b'x'), (b'', b'')):
        def rows(m, lab=lab, own=own):
            return [marker(m, lab, own)]

        def applies(m, lab=lab, own=own):
            return marker(m, lab, own) != marker(m)
        for m in MODES:
            if marker(m, lab, own) != marker(m):
                add('a marker of mode %r %r' % (lab, own), rows, 'names another mode', modes=(m,))
    add('a marker after a select', lambda m: [marker(m), [b'SELECT', b'0'], marker(m)], 'not the first record')
    add('a marker twice in a row', lambda m: [marker(m), marker(m)], 'not the first record')
    add('a marker after a scoped record', lambda m: good(m) + [scoped(m, b'SET', b'k', b'v'), marker(m)], 'not the first record')
    add('a marker inside a transaction', lambda m: good(m) + [[b'MULTI'], marker(m), [b'EXEC']], 'not the first record')
    add('a marker of another mode later in the file', lambda m: good(m) + [marker(m, b'0', b'0')], 'not the first record')

    for marking in (b'', b'NOPE', b'U//Q', b'S//A/B;BOGUS', b'U;', b'//', b'   ', b'x' * 300, b'S//', b'S//A,B', b'U;WEB;VETTED', b'C//A//B', b'U\x00'):
        add('a marking that does not parse: %r' % marking[:24], lambda m, k=marking: good(m) + [scoped(m, b'SET', b'k', SECRET_VALUE, marking=k)], 'marking does not parse', modes=('labels', 'both'))
    for marking in (b'', b'NOPE', b'U', b'UNCLASSIFIED;BOGUS', b'UNCLASSIFIED//A', b'OWNER', b'SHARED'):
        add('an owner-only marking that does not parse: %r' % marking, lambda m, k=marking: good(m) + [scoped(m, b'SET', b'k', SECRET_VALUE, marking=k)], 'marking does not parse', modes=('owners',))

    add('an owner word in label-only mode', lambda m: good(m) + [[b'LABEL', b'AS', b'U', b'OWNER', b'u1', b'SET', b'k', b'v']], 'owner mode is off', modes=('labels',))
    add('a shared word in label-only mode', lambda m: good(m) + [[b'LABEL', b'AS', b'U', b'SHARED', b'SET', b'k', b'v']], 'owner mode is off', modes=('labels',))
    add('an owner word with a secret id in label-only mode', lambda m: good(m) + [[b'LABEL', b'AS', b'U', b'OWNER', SECRET_OWNER, b'SET', b'k', SECRET_VALUE]], 'owner mode is off', modes=('labels',))
    add('an owner word inside a transaction in label-only mode', lambda m: good(m) + [[b'MULTI'], [b'LABEL', b'AS', b'U', b'OWNER', b'u1', b'SET', b'k', b'v'], [b'EXEC']], 'owner mode is off', modes=('labels',))

    for bad in (b'*', b'has space', b'x' * 129, b'', b'\x01', b'a\tb', b'\x7f', b'\x80', b'a\nb', b'\xff\xfe', b' ', b'x' * 1000):
        add('a malformed owner id: %r' % bad[:20], lambda m, k=bad: good(m) + [[b'LABEL', b'AS', LOW[m], b'OWNER', k, b'SET', b'key', SECRET_VALUE]], 'malformed owner id', modes=('owners', 'both'))
    add('an owner word without an id', lambda m: good(m) + [[b'LABEL', b'AS', LOW[m], b'OWNER']], 'no command|malformed owner id', modes=('owners', 'both'))
    add('an owner and an id and no command', lambda m: good(m) + [[b'LABEL', b'AS', LOW[m], b'OWNER', b'u1']], 'names no command', modes=('owners', 'both'))
    add('a shared word and no command', lambda m: good(m) + [[b'LABEL', b'AS', LOW[m], b'SHARED']], 'names no command', modes=('owners', 'both'))
    add('a marking and no command', lambda m: good(m) + [[b'LABEL', b'AS', LOW[m]]], 'names no command')
    add('a prefix of two words', lambda m: good(m) + [[b'LABEL', b'AS']], 'names no command')

    add('a nested prefix', lambda m: good(m) + [head(m) + [b'LABEL', b'AS', LOW[m], b'SET', b'k', b'v']], 'wraps another scope prefix')
    add('a nested prefix with owners', lambda m: good(m) + [head(m, owner=b'u1') + head(m, LOW[m], b'u2') + [b'SET', b'k', b'v']], 'wraps another scope prefix', modes=('owners', 'both'))
    add('a session prefix inside a prefix', lambda m: good(m) + [head(m) + [b'LABEL', b'SESSION', LOW[m]]], 'wraps another scope prefix')
    add('a nested prefix inside a transaction', lambda m: good(m) + [[b'MULTI'], head(m) + head(m) + [b'SET', b'k', b'v'], [b'EXEC']], 'wraps another scope prefix')

    two = {
        'labels': (b'U', b'C', None, None),
        'both': (b'U', b'U', b'u1', b'u2'),
    }
    add('a transaction with two labels', lambda m: good(m) + [[b'MULTI'], scoped(m, b'SET', b'a', b'1', marking=b'U'), scoped(m, b'SET', b'b', b'1', marking=b'C'), [b'EXEC']], 'name two scopes', modes=('labels', 'both'))
    add('a transaction with two labels that differ in trust', lambda m: good(m) + [[b'MULTI'], scoped(m, b'SET', b'a', b'1', marking=b'C'), scoped(m, b'SET', b'b', b'1', marking=b'C;VETTED'), [b'EXEC']], 'name two scopes', modes=('labels', 'both'))
    add('a transaction with two owners', lambda m: good(m) + [[b'MULTI'], scoped(m, b'SET', b'a', b'1', owner=b'u1'), scoped(m, b'SET', b'b', b'1', owner=b'u2'), [b'EXEC']], 'name two scopes', modes=('owners', 'both'))
    add('a transaction with an owner and shared', lambda m: good(m) + [[b'MULTI'], scoped(m, b'SET', b'a', b'1', owner=b'u1'), scoped(m, b'SET', b'b', b'1', owner=b''), [b'EXEC']], 'name two scopes', modes=('owners', 'both'))
    add('a transaction with a named and an unnamed record', lambda m: good(m) + [[b'MULTI'], scoped(m, b'SET', b'a', b'1', owner=b'u1'), head(m) + [b'SET', b'b', b'1'], [b'EXEC']], 'name two scopes', modes=('owners', 'both'))
    add('a transaction with two scopes after maintenance records', lambda m: good(m) + [[b'MULTI'], scoped(m, b'DEL', b'x', owner=b'u9'), scoped(m, b'SET', b'a', b'1', owner=b'u1'), scoped(m, b'DEL', b'y', owner=b'u8'), scoped(m, b'SET', b'b', b'1', owner=b'u2'), [b'EXEC']], 'name two scopes', modes=('owners', 'both'))

    for inner in ([b'MULTI'], [b'EXEC'], [b'SELECT', b'1'], [b'DISCARD'], [sl.SEED, b'7'], [sl.MARKER, b'1', b'1', b'0'], [b'multi'], [b'Select', b'0']):
        add('a prefix around %r' % inner[0], lambda m, i=inner: good(m) + [head(m) + i], 'only the loader reads')

    for row in ([b'SET', b'k', SECRET_VALUE], [b'FLUSHALL'], [b'FLUSHDB'], [b'CONFIG', b'SET', b'maxmemory', b'1'], [b'CONFIG', b'SET', b'appendonly', b'no'],
                [b'CONFIG', b'SET', b'label-levels', b'U,C,S', b'label-compartments', b'A,B'], [b'CONFIG', b'GET', b'label-levels'], [b'CONFIG', b'SET', b'owners', b'yes'],
                [b'CONFIG', b'REWRITE'], [b'CONFIG', b'SET', b'label-levels'], [b'CONFIG', b'SET', b'dir', b'/tmp'], [b'DEBUG', b'RELOAD'], [b'DEL', b'k'],
                [b'NOSUCHCOMMAND', b'x'], [b'LABEL', b'DECLASSIFY', b'k', b'U'], [b'LABEL', b'QUOTA', b'U', b'LIMIT'], [b'LABEL', b'QUOTA', b'U', b'LIMIT', b'1', b'2'],
                [b'FUNCTION', b'LIST'], [b'FUNCTION'], [b'SWAPDB', b'0'], [b'SWAPDB', b'0', b'1', b'2'], [b'SELECT'], [b'SELECT', b'0', b'1']):
        modes = MODES
        if row[0] == b'SELECT':
            add('an unprefixed %s record of the wrong shape' % row[0].decode(), lambda m, r=row: good(m) + [r], 'Wrong number of arguments for .select.', modes=MODES)
            continue
        add('an unprefixed record %r' % row[:3], lambda m, r=row: good(m) + [r], 'carries no scope and is not an operator record' if row[:1] != [b'FUNCTION'] or len(row) > 1 else 'carries no scope and is not an operator record', modes=modes)
    for row in ([b'OWNERS', b'FORGET', b'u1'], [b'OWNERS', b'QUOTA', b'u1', b'LIMIT', b'5'], [b'OWNERS', b'FORGET'], [b'OWNERS', b'FORGET', b'u1', b'x'], [b'OWNERS', b'QUOTA', b'u1', b'LIMIT'],
                [b'OWNERS', b'LIST', b'0'], [b'OWNERS', b'INFO', b'u1']):
        add('an owners record in label-only mode %r' % row[:3], lambda m, r=row: good(m) + [r], 'not an operator record', modes=('labels',))
    for row in ([b'OWNERS', b'FORGET'], [b'OWNERS', b'FORGET', b'u1', b'x'], [b'OWNERS', b'QUOTA', b'u1', b'LIMIT'], [b'OWNERS', b'QUOTA', b'u1', b'MAX', b'4'], [b'OWNERS', b'LIST', b'0'], [b'OWNERS', b'INFO', b'u1']):
        add('a malformed owners record %r' % row[:3], lambda m, r=row: good(m) + [r], 'not an operator record', modes=('owners', 'both'))

    for row in ([b'SWAPDB', b'0', b'1'], [b'FUNCTION', b'FLUSH'], [b'CONFIG', b'SET', b'label-levels', b'U'], [b'LABEL', b'QUOTA', b'U', b'LIMIT', b'5']):
        add('an operator record %r inside a prefix' % row[:2], lambda m, r=row: good(m) + [head(m) + r], 'wraps an operator record')
    for row in ([b'OWNERS', b'FORGET', b'u1'], [b'OWNERS', b'QUOTA', b'u1', b'LIMIT', b'5']):
        add('an owners record %r inside a prefix' % row[:2], lambda m, r=row: good(m) + [head(m, owner=b'u1') + r], 'wraps an operator record', modes=('owners', 'both'))

    for row in ([b'GET', b'k'], [b'LRANGE', b'k', b'0', b'-1'], [b'EXISTS', b'k'], [b'KEYS', b'*'], [b'SCAN', b'0'], [b'INFO'], [b'PING'], [b'DBSIZE'], [b'TTL', b'k'], [b'TYPE', b'k']):
        add('a scoped read %r' % row[:1], lambda m, r=row: good(m) + [scoped(m, *r)], 'changes no data')
    for row in ([b'EVAL', b'return 1', b'0'], [b'EVALSHA', b'0' * 40, b'0'], [b'FCALL', b'f', b'0'], [b'EVAL_RO', b'return 1', b'0'], [b'MIGRATE', b'127.0.0.1', b'1', b'k', b'0', b'10']):
        add('a scoped %r' % row[:1], lambda m, r=row: good(m) + [scoped(m, *r)], 'never holds|changes no data|unknown command')
    add('a scoped unknown command', lambda m: good(m) + [scoped(m, b'NOSUCHCOMMAND', b'k')], 'unknown command')
    add('a scoped command with the wrong arity', lambda m: good(m) + [scoped(m, b'SET', b'k')], 'wrong number of arguments')
    add('a scoped command with too many arguments for its arity', lambda m: good(m) + [scoped(m, b'GETSET', b'k', b'v', b'extra')], 'wrong number of arguments')

    add('a record that fails at replay: INCR on text', lambda m: good(m) + [scoped(m, b'SET', b'k', b'text'), scoped(m, b'INCR', b'k')], 'failed at replay')
    add('a record that fails at replay: wrong type', lambda m: good(m) + [scoped(m, b'SET', b'k', b'text'), scoped(m, b'LPUSH', b'k', b'a')], 'failed at replay')
    add('a record that fails at replay: bad integer', lambda m: good(m) + [scoped(m, b'SET', b'k', b'1', b'EX', b'abc')], 'failed at replay')
    add('a record that fails at replay inside a transaction', lambda m: good(m) + [[b'MULTI'], scoped(m, b'SET', b'k', b'text'), scoped(m, b'INCR', b'k'), [b'EXEC']], 'failed at replay')
    add('a record that fails at replay: syntax', lambda m: good(m) + [scoped(m, b'SET', b'k', b'v', b'NOSUCHOPTION')], 'failed at replay')
    add('a select of a database that does not exist', lambda m: [marker(m), [b'SELECT', b'99']], "Invalid DB index '99'")
    add('a select that is not a number', lambda m: [marker(m), [b'SELECT', b'abc']], "Invalid DB index 'abc'")
    add('a select of a negative database', lambda m: [marker(m), [b'SELECT', b'-1']], "Invalid DB index '-1'")
    add('an operator record that fails at replay: an unknown function library', lambda m: good(m) + [[b'FUNCTION', b'DELETE', b'nosuchlib']], 'failed at replay')
    add('an operator record that fails at replay: a bad function load', lambda m: good(m) + [[b'FUNCTION', b'LOAD', b'not a library']], 'failed at replay')
    add('an operator record that fails at replay: a swap of a missing database', lambda m: good(m) + [[b'SWAPDB', b'0', b'99']], 'failed at replay')
    add('a quota record that fails at replay', lambda m: good(m) + [[b'LABEL', b'QUOTA', b'NOPE', b'LIMIT', b'5']], 'failed at replay', modes=('labels', 'both'))
    add('an owner quota record that fails at replay', lambda m: good(m) + [[b'OWNERS', b'QUOTA', b'bad id', b'LIMIT', b'5']], 'failed at replay', modes=('owners', 'both'))
    add('a declassify that fails at replay', lambda m: good(m) + [scoped(m, b'LABEL', b'DECLASSIFY', b'missing', b'U')], 'failed at replay', modes=('labels', 'both'))

    add('a prefixed record that needs a partition beyond the label cap', lambda m: good(m) + [scoped(m, b'SET', b'k', b'v', marking=b'C', owner=b'u1' if m != 'labels' else None),
                                                                             scoped(m, b'SET', b'k2', b'v', marking=b'S', owner=b'u1' if m != 'labels' else None)],
        'beyond label-partitions-max', modes=('labels',), extra=('--label-partitions-max', '1'))
    add('a prefixed record that needs a partition beyond the owner cap', lambda m: good(m) + [scoped(m, b'SET', b'k', b'v', owner=b'u1'), scoped(m, b'SET', b'k', b'v', marking=OTHER_MARKING[m], owner=b'u1') if m == 'both' else scoped(m, b'SET', b'k2', b'v', owner=b'u2')],
        'beyond owner-partitions-max|beyond label-partitions-max', modes=('owners', 'both'), extra=('--owner-partitions-max', '1', '--label-partitions-max', '1' ))

    for row in ([b'INCR', b'n'], [b'APPEND', b'k', b'x'], [b'SETRANGE', b'k', b'0', b'x'], [b'PEXPIREAT', b'k', b'1'], [b'EXPIRE', b'k', b'100'], [b'PERSIST', b'k'],
                [b'GETSET', b'k', b'v'], [b'SET', b'k', b'v'], [b'HSET', b'h', b'b', b'2'], [b'HDEL', b'h', b'a', b'b'], [b'LPUSH', b'l', b'y'], [b'SADD', b's', b'y'],
                [b'ZADD', b'z', b'2', b'y'], [b'RENAME', b'k', b'k9'], [b'DEL', b'k', b'n'], [b'UNLINK', b'k', b'other'], [b'LMOVE', b'l', b'dst', b'LEFT', b'LEFT']):
        add('a record that writes a name held only at another scope: %r' % row[0], lambda m, r=row: holdings(m) + [written(m, *r)], 'another scope holds')
    add('a write to a name held only at another scope inside a transaction', lambda m: holdings(m) + [[b'MULTI'], written(m, b'SET', b'mine', b'1'), written(m, b'INCR', b'n'), [b'EXEC']], 'another scope holds')
    for row in ([sl.SEED], [sl.SEED, b'0'], [sl.SEED, b'018'], [sl.SEED, b'18446744073709551616'], [sl.SEED, b'12', b'13'], [sl.SEED, b'-5'], [sl.SEED, b'1e3'], [sl.SEED, b' 5'], [sl.SEED, b''], [sl.SEED, b'+5']):
        add('a seed record %r' % row[1:], lambda m, r=row: good(m) + [r], 'seed record')
    add('two different seeds', lambda m: good(m) + [[sl.SEED, b'5'], [sl.SEED, b'6']], 'disagrees')

    schemes = {
        'labels': (b'label-levels', [b'U,C', b'U', b'S,C,U', b'U,S,C', b'C,U,S', b'U,C,U', b'U,C,S,C', b'U,C,S,A', b'', b'U,,S', b'U,C,S,', b',U,C,S', b'U,C,S,bad!name', b'U,C,S,' + b'x' * 65, b'U,C,S,context', b'U,C,S,TOKEN']),
        'compartments': (b'label-compartments', [b'A', b'', b'B,A', b'A,A', b'B,B', b'A,U', b'A,B,A', b'A,B,S']),
        'trusts': (b'label-trust-levels', [b'WEB', b'', b'VETTED,WEB', b'WEB,WEB', b'WEB,VETTED,WEB']),
    }
    for kind, (name, values) in schemes.items():
        for value in values:
            add('a scheme change the runtime rules refuse: %s %r' % (name.decode(), value), lambda m, n=name, v=value: good(m) + [[b'CONFIG', b'SET', n, v]], 'failed at replay', modes=('labels', 'both'))
    add('a scheme change that turns labels on in owner-only mode', lambda m: good(m) + [[b'CONFIG', b'SET', b'label-levels', b'UNCLASSIFIED,C']], 'failed at replay', modes=('owners',))
    add('a scheme change that names a level OWNER', lambda m: good(m) + [[b'CONFIG', b'SET', b'label-levels', b'UNCLASSIFIED,OWNER']], 'failed at replay', modes=('owners', 'both'))
    add('a scheme change that names a level SHARED', lambda m: good(m) + [[b'CONFIG', b'SET', b'label-levels', b'U,C,S,shared']], 'failed at replay', modes=('both',))
    add('a scheme change with a missing value', lambda m: good(m) + [[b'CONFIG', b'SET', b'label-levels']], 'not an operator record')
    add('a scheme change of two settings', lambda m: good(m) + [[b'CONFIG', b'SET', b'label-levels', b'U,C,S,TS', b'label-compartments', b'A,B,C']], 'not an operator record')

    add('garbage instead of a record', None, GENERIC, raw=lambda m: sl.encode_records([marker(m)]) + b'hello\r\n')
    add('a record with a negative count', None, GENERIC, raw=lambda m: sl.encode_records([marker(m)]) + b'*-1\r\n')
    add('a record with a zero count', None, GENERIC, raw=lambda m: sl.encode_records([marker(m)]) + b'*0\r\n')
    add('a bulk with a bad length', None, GENERIC, raw=lambda m: sl.encode_records([marker(m)]) + b'*1\r\n$x\r\nabc\r\n')
    add('a bulk without its terminator', None, GENERIC, raw=lambda m: sl.encode_records([marker(m)]) + b'*1\r\n$3\r\nabcXY')
    add('a record whose first word is not a bulk', None, GENERIC, raw=lambda m: sl.encode_records([marker(m)]) + b'*1\r\n:5\r\n')
    add('a bare line feed', None, GENERIC, raw=lambda m: sl.encode_records([marker(m)]) + b'*1\n$3\nSET\n')
    return out


CASES = cases()


def accepted_cases():
    out = []

    def add(name, rows, modes=MODES, check=None):
        out.append((name, rows, modes, check))
    add('a maintenance deletion inside a transaction keeps its own scope',
        lambda m: good(m) + [scoped(m, b'SET', b'a', b'old', marking=b'U', owner=b''), [b'MULTI'], scoped(m, b'DEL', b'a', marking=b'U', owner=b''), scoped(m, b'SET', b'a', b'new', owner=b'u1'), [b'EXEC']],
        modes=('both',))
    add('a transaction of one scope', lambda m: good(m) + [[b'MULTI'], scoped(m, b'SET', b'a', b'1'), scoped(m, b'INCR', b'n'), [b'EXEC']])
    add('two transactions of two scopes in a row',
        lambda m: good(m) + [[b'MULTI'], scoped(m, b'SET', b'a', b'1', owner=b'u1'), [b'EXEC'], [b'MULTI'], scoped(m, b'SET', b'b', b'1', owner=b'u2'), [b'EXEC']], modes=('owners', 'both'))
    add('a scheme rename and an extension', lambda m: good(m) + [[b'CONFIG', b'SET', b'label-compartments', b'A,Z'], [b'CONFIG', b'SET', b'label-levels', b'U,C,S,TS'], [b'CONFIG', b'SET', b'label-trust-levels', b'WEB,VETTED,GOLD']], modes=('labels', 'both'))
    add('a level rename in owner-only mode', lambda m: good(m) + [[b'CONFIG', b'SET', b'label-levels', b'PUBLIC']], modes=('owners',))
    add('a scheme record that changes nothing', lambda m: good(m) + [[b'CONFIG', b'SET', b'label-levels', b'U,C,S']], modes=('labels', 'both'))
    add('operator records', lambda m: good(m) + [[b'FUNCTION', b'FLUSH'], [b'SWAPDB', b'0', b'1'], [b'LABEL', b'QUOTA', b'C', b'LIMIT', b'900000']], modes=('labels', 'both'))
    add('owner operator records', lambda m: good(m) + [[b'OWNERS', b'QUOTA', b'u1', b'LIMIT', b'900000'], [b'OWNERS', b'FORGET', b'u1'], [b'OWNERS', b'FORGET', b'never-seen']], modes=('owners', 'both'))
    add('a seed record', lambda m: good(m) + [[sl.SEED, b'987654321']])
    add('a lower-case marker and prefix', lambda m: [[w.lower() if w in (sl.MARKER,) else w for w in marker(m)], [b'select', b'0'], [w.lower() if w in (b'LABEL', b'AS') else w for w in scoped(m, b'set', b'k', b'v')]])
    return out


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='eski-rejects-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.servers = []

    def tearDown(self):
        for s in self.servers:
            s.kill()

    def prepared(self, name, mode, extra=()):
        d = self.root / name
        d.mkdir(exist_ok=True)
        s = sl.Server(BINARY, d, mode, extra, KEYSPACE_THREADS)
        self.servers.append(s)
        return s


class Startup(Base):
    def check_mode(self, mode):
        failures = []
        total = 0
        groups = {}
        for case in CASES:
            if mode in case.modes:
                groups.setdefault(case.extra, []).append(case)
        for n, (extra, group) in enumerate(groups.items()):
            s = self.prepared('s%d' % n, mode, extra)
            s.up()
            s.kill()
            incr = sl.last_incr(s.run.directory)
            for case in group:
                total += 1
                incr.write_bytes(case.content(mode))
                code, text = s.run.start()
                if code is None:
                    s.run.stop()
                    failures.append((case.name, 'the server started on a log it must refuse'))
                    continue
                reasons = case.reason.split('|')
                if code != 1 or sl.REFUSED not in text and GENERIC not in text and "reading the append only file" not in text or not any(self.matches(r, text) for r in reasons):
                    failures.append((case.name, code, text[-500:]))
                    continue
                for secret in (SECRET_OWNER, SECRET_VALUE):
                    if secret.decode() in text:
                        failures.append((case.name, 'the log names a secret', text[-500:]))
                if incr.read_bytes() != case.content(mode):
                    failures.append((case.name, 'the refused file was changed'))
        self.assertGreater(total, 100)
        self.assertEqual(failures, [], '%d of %d rejections failed in %s mode' % (len(failures), total, mode))

    def matches(self, reason, text):
        import re
        return re.search(reason, text) is not None

    def test_label_only_every_rejection_is_a_clean_refusal_at_startup(self):
        self.check_mode('labels')

    def test_owner_only_every_rejection_is_a_clean_refusal_at_startup(self):
        self.check_mode('owners')

    def test_both_every_rejection_is_a_clean_refusal_at_startup(self):
        self.check_mode('both')

    def test_a_server_without_labels_refuses_a_scoped_log_and_a_marker(self):
        s = sl.plain_server(BINARY, self.root / 'plain', (), KEYSPACE_THREADS) if (self.root / 'plain').mkdir() is None else None
        self.servers.append(s)
        s.up()
        s.kill()
        incr = sl.last_incr(s.run.directory)
        for rows in ([[b'SELECT', b'0'], [b'LABEL', b'AS', b'U', b'SET', b'k', SECRET_VALUE]], [marker('labels')], [marker('both')], [marker('owners'), [b'SELECT', b'0']],
                     [[b'SELECT', b'0'], [b'LABEL', b'AS', b'U', b'OWNER', SECRET_OWNER, b'SET', b'k', b'v']], [[b'SELECT', b'0'], [b'LABEL', b'AS', b'U', b'SHARED', b'SET', b'k', b'v']],
                     [[b'MULTI'], [b'LABEL', b'AS', b'U', b'SET', b'k', b'v'], [b'EXEC']], [[b'SELECT', b'0'], marker('labels')]):
            incr.write_bytes(sl.encode_records(rows))
            code, text = s.refused()
            self.assertEqual(code, 1, text[-500:])
            self.assertIn('written by a server with a label scheme or owner mode, and this server has neither', text)
            self.assertNotIn(SECRET_OWNER.decode(), text)
            self.assertNotIn(SECRET_VALUE.decode(), text)


class Positive(Base):
    def test_the_harness_accepts_the_valid_forms(self):
        for name, rows, modes, check in accepted_cases():
            for mode in modes:
                s = self.prepared('p-%s-%d' % (mode, abs(hash(name)) % 100000), mode)
                s.up()
                s.kill()
                sl.last_incr(s.run.directory).write_bytes(sl.encode_records(rows(mode)))
                c = s.up()
                self.assertEqual(c.call('PING'), 'PONG', '%s in %s mode' % (name, mode))
                s.kill()

    def test_a_valid_transaction_is_applied_whole(self):
        for mode in ('both',):
            s = self.prepared('tx', mode)
            s.up()
            s.kill()
            rows = good(mode) + [scoped(mode, b'SET', b'a', b'old', marking=b'U', owner=b''), [b'MULTI'], scoped(mode, b'DEL', b'a', marking=b'U', owner=b''), scoped(mode, b'SET', b'a', b'new', owner=b'u1'), [b'EXEC']]
            sl.last_incr(s.run.directory).write_bytes(sl.encode_records(rows))
            c = s.up()
            self.assertEqual(c.call('LABEL', 'AS', 'S//A', 'OWNER', 'u1', 'GET', 'a'), b'new')
            self.assertIsNone(c.call('LABEL', 'AS', 'U', 'SHARED', 'GET', 'a'))


    def test_a_maintenance_deletion_never_reaches_another_scope(self):
        for mode in MODES:
            s = self.prepared('m-%s' % mode, mode)
            s.up()
            s.kill()
            rows = holdings(mode) + [written(mode, b'DEL', b'k'), written(mode, b'UNLINK', b'n'), written(mode, b'HDEL', b'h', b'a'),
                                     held(mode, b'SET', b'gone', b'1'), held(mode, b'DEL', b'gone'), held(mode, b'DEL', b'gone'), held(mode, b'HDEL', b'h', b'zz')]
            sl.last_incr(s.run.directory).write_bytes(sl.encode_records(rows))
            c = s.up()
            low = sl.at(mode, *[x.decode() if x is not None else None for x in HOLDER[mode]])
            high = sl.at(mode, *[x.decode() if x is not None else None for x in WRITER[mode]])
            self.assertEqual(c.call(*low, 'GET', 'k'), SECRET_VALUE, mode)
            self.assertEqual(c.call(*low, 'GET', 'n'), b'5', mode)
            self.assertEqual(c.call(*low, 'HGETALL', 'h'), [b'a', b'1'], mode)
            self.assertEqual(c.call(*high, 'GET', 'k'), SECRET_VALUE, mode)
            self.assertEqual(c.call(*low, 'EXISTS', 'gone'), 0, mode)
            s.kill()


class Runtime(Base):
    def check_mode(self, mode):
        s = self.prepared('rt', mode)
        c = s.up()
        t = sl.top(mode)
        base_rows = good(mode)
        incr = sl.last_incr(s.run.directory)
        failures = []
        total = 0
        for case in CASES:
            if mode not in case.modes or case.extra:
                continue
            total += 1
            mark = len(s.run.log())
            incr.write_bytes(case.content(mode))
            try:
                reply = c.call(*t, 'DEBUG', 'LOADAOF')
                failures.append((case.name, 'the load was accepted', reply))
                continue
            except ServerError as e:
                if 'Error trying to load the AOF files' not in str(e):
                    failures.append((case.name, str(e)))
                    continue
            text = s.run.log()[mark:]
            reasons = case.reason.split('|')
            import re
            if not any(re.search(r, text) for r in reasons):
                failures.append((case.name, 'reason missing', text[-400:]))
            for db in range(4):
                c.call('SELECT', db)
                if c.call(*t, 'DBSIZE') != 0:
                    failures.append((case.name, 'the keyspace is not empty after the refused load (db %d)' % db))
                    break
            c.call('SELECT', 0)
            if c.call('PING') != 'PONG' or s.run.process.poll() is not None:
                failures.append((case.name, 'the server is not serving'))
                break
            for secret in (SECRET_OWNER, SECRET_VALUE):
                if secret.decode() in text:
                    failures.append((case.name, 'the log names a secret'))
        self.assertGreater(total, 100)
        self.assertEqual(failures, [], '%d of %d runtime rejections failed in %s mode' % (len(failures), total, mode))

    def test_label_only_every_rejection_leaves_an_empty_keyspace_at_runtime(self):
        self.check_mode('labels')

    def test_owner_only_every_rejection_leaves_an_empty_keyspace_at_runtime(self):
        self.check_mode('owners')

    def test_both_every_rejection_leaves_an_empty_keyspace_at_runtime(self):
        self.check_mode('both')


def main():
    global BINARY, KEYSPACE_THREADS
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', default=str(BINARY))
    parser.add_argument('--keyspace-threads', type=int, default=0)
    parser.add_argument('--ports', default='')
    args, rest = parser.parse_known_args()
    BINARY = Path(args.server).resolve()
    KEYSPACE_THREADS = args.keyspace_threads
    if args.ports:
        sl.use_ports(args.ports)
    unittest.main(argv=[sys.argv[0]] + rest, verbosity=1)


if __name__ == '__main__':
    main()
