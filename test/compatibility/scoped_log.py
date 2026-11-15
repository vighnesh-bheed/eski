import os
from pathlib import Path
import socket
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test/compatibility'))
sys.path.insert(0, str(ROOT / 'test/threading'))
import labelled_files as lf
from support import Client, ServerError, encode

SCHEME = ('--label-levels', 'U,C,S', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED')
OWNERS = ('--owners', 'yes')
SEEDS = ('--debug-hash-seed', '11', '--label-stream-seed', '5')
LOG = ('--appendonly', 'yes', '--appendfsync', 'always', '--save', '', '--auto-aof-rewrite-percentage', '0')
OPERATOR = ('on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*')
OWNER_OPERATOR = OPERATOR + ('owners:*', 'owner-shared', 'owner-operator')
KEEPER = OPERATOR + ('owner-operator',)
FAR = 4102444800000
MARKER = b'ESKI-ACCESS'
SEED = b'ESKI-VSET-SEED'
REFUSED = 'Bad file format reading the append only file '

MODES = {
    'labels': {'args': SCHEME, 'owners': False, 'labelled': True, 'top': 'S//A/B', 'low': 'U'},
    'owners': {'args': OWNERS, 'owners': True, 'labelled': False, 'top': 'UNCLASSIFIED', 'low': 'UNCLASSIFIED'},
    'both': {'args': SCHEME + OWNERS, 'owners': True, 'labelled': True, 'top': 'S//A/B', 'low': 'U'},
}

READERS = {
    'labels': [('U', None), ('C', None), ('S', None), ('S//A', None), ('S//B', None), ('S//A/B', None), ('C;VETTED', None), ('S//A/B;VETTED', None)],
    'owners': [('UNCLASSIFIED', ''), ('UNCLASSIFIED', 'u1'), ('UNCLASSIFIED', 'u2'), ('UNCLASSIFIED', 'u3'), ('UNCLASSIFIED', 'u9')],
    'both': [('U', ''), ('C', ''), ('S//A/B', ''), ('C', 'u1'), ('S//A/B', 'u1'), ('S//A', 'u1'), ('S//B', 'u2'), ('U', 'u3'), ('C;VETTED', 'u1'), ('U', 'u9')],
}

_ports = None
_next = 0


def use_ports(text):
    global _ports
    lo, hi = (int(x) for x in text.split('-'))
    _ports = (lo, hi)
    lf.free_port = pick_port


def pick_port():
    global _next
    if _ports is None:
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            return probe.getsockname()[1]
    lo, hi = _ports
    span = hi - lo + 1
    for _ in range(span):
        port = lo + _next % span
        _next += 1
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(('127.0.0.1', port))
            except OSError:
                continue
            return port
    raise AssertionError('no free port in the range')


def at(mode, label, owner=None):
    if not MODES[mode]['owners']:
        return ('LABEL', 'AS', label)
    if not owner:
        return ('LABEL', 'AS', label, 'SHARED')
    return ('LABEL', 'AS', label, 'OWNER', owner)


def top(mode):
    return at(mode, MODES[mode]['top'])


def mode_args(mode, extra=()):
    return MODES[mode]['args'] + SEEDS + LOG + tuple(extra)


def records(data):
    out = []
    i = 0
    n = len(data)
    while i < n:
        if data[i:i + 1] == b'#':
            j = data.index(b'\r\n', i)
            i = j + 2
            continue
        if data[i:i + 1] != b'*':
            raise ValueError('not a record at byte %d' % i)
        j = data.index(b'\r\n', i)
        count = int(data[i + 1:j])
        i = j + 2
        argv = []
        for _ in range(count):
            j = data.index(b'\r\n', i)
            size = int(data[i + 1:j])
            i = j + 2
            argv.append(data[i:i + size])
            i += size + 2
        out.append(argv)
    return out


def encode_records(rows):
    return b''.join(encode(r) for r in rows)


def log_dir(directory):
    return Path(directory) / 'appendonlydir'


def incr_files(directory):
    d = log_dir(directory)
    names = []
    for line in (d / 'appendonly.aof.manifest').read_text().splitlines():
        parts = line.split()
        if 'type' in parts and parts[parts.index('type') + 1] == 'i':
            names.append(d / parts[parts.index('file') + 1])
    return names


def last_incr(directory):
    return incr_files(directory)[-1]


def scoped(row):
    if len(row) >= 3 and row[0].upper() == b'LABEL' and row[1].upper() == b'AS':
        i = 3
        owner = None
        if i < len(row) and row[i].upper() == b'OWNER':
            owner = row[i + 1]
            i += 2
        elif i < len(row) and row[i].upper() == b'SHARED':
            owner = b''
            i += 1
        return (row[2], owner), row[i:]
    return None, row


def error_text(value):
    return ('error', str(value)) if isinstance(value, ServerError) else value


class Pair:
    def __init__(self, *clients):
        self.clients = list(clients)

    def call(self, *arguments):
        out = []
        for c in self.clients:
            try:
                out.append(c.call(*arguments))
            except ServerError as error:
                out.append(ServerError(str(error)))
        first = error_text(out[0])
        for other in out[1:]:
            if error_text(other) != first:
                raise AssertionError('the servers answered %r differently: %r and %r' % (arguments[:6], first, error_text(other)))
        if isinstance(out[0], ServerError):
            raise out[0]
        return out[0]

    def error(self, *arguments):
        try:
            value = self.call(*arguments)
        except ServerError as error:
            return str(error)
        raise AssertionError('expected an error from %r, got %r' % (arguments[:6], value))

    def until(self, predicate, timeout=15):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if all(predicate(c) for c in self.clients):
                return
            time.sleep(0.005)
        raise AssertionError('condition not reached')

    def gone(self, prefix, key):
        self.until(lambda c: c.call(*prefix, 'EXISTS', key) == 0)


def read_value(c, p, key, kind):
    if kind == 'string':
        return c.call(*p, 'GET', key)
    if kind == 'list':
        return c.call(*p, 'LRANGE', key, 0, -1)
    if kind == 'set':
        return sorted(c.call(*p, 'SMEMBERS', key))
    if kind == 'zset':
        return c.call(*p, 'ZRANGE', key, 0, -1, 'WITHSCORES')
    if kind == 'hash':
        flat = c.call(*p, 'HGETALL', key)
        fields = sorted(flat[0::2])
        if not fields:
            return [], []
        return sorted(zip(flat[0::2], flat[1::2])), c.call(*p, 'HPEXPIRETIME', key, 'FIELDS', len(fields), *fields)
    if kind == 'stream':
        groups = c.call(*p, 'XINFO', 'GROUPS', key)
        pending = [c.call(*p, 'XPENDING', key, g[1]) for g in groups]
        return c.call(*p, 'XRANGE', key, '-', '+'), groups, pending
    if kind == 'vectorset':
        names = c.call(*p, 'VRANGE', key, '-', '+', 1000)
        dim = c.call(*p, 'VDIM', key)
        return names, lf.vector_reads(c, p, key, dim, names, randoms=False)
    return kind


def full_scan(c, p):
    seen = []
    cursor = b'0'
    while True:
        cursor, batch = c.call(*p, 'SCAN', cursor, 'COUNT', 7)
        seen.extend(batch)
        if cursor == b'0':
            return sorted(set(seen))


def view(c, mode, label, owner, dbs=(0, 1, 2, 3)):
    p = at(mode, label, owner)
    out = {}
    for db in dbs:
        c.call('SELECT', db)
        keys = full_scan(c, p)
        out[(db, 'scan')] = keys
        out[(db, 'dbsize')] = c.call(*p, 'DBSIZE')
        out[(db, 'keys')] = sorted(c.call(*p, 'KEYS', '*'))
        for k in keys:
            kind = c.call(*p, 'TYPE', k)
            out[(db, k)] = (kind, read_value(c, p, k, kind), c.call(*p, 'PEXPIRETIME', k), c.call(*p, 'LABEL', 'OF', k))
        out[(db, 'keyspace')] = [','.join(x for x in line.split(',') if not x.startswith('avg_ttl='))
                                 for line in c.call(*p, 'INFO', 'keyspace').decode().splitlines() if line.startswith('db')]
    c.call('SELECT', 0)
    return out


def owners_listed(c, mode):
    if not MODES[mode]['owners']:
        return []
    out = []
    cursor = 0
    while True:
        cursor, batch = c.call(*top(mode), 'OWNERS', 'LIST', cursor, 'COUNT', 2)
        out.extend(batch)
        if cursor == b'0':
            return sorted(out)


def quotas(c, mode):
    out = {}
    t = top(mode)
    if MODES[mode]['labelled']:
        for marking in ('C', 'S//A', 'U'):
            out[marking] = c.call(*t, 'LABEL', 'QUOTA', marking)[0]
        out['C;VETTED'] = c.call(*t, 'LABEL', 'QUOTA', 'C', 'TRUST', 'VETTED')[0]
    if MODES[mode]['owners']:
        for name in ('u1', 'u2', 'u3', 'u9'):
            out[name] = c.call(*t, 'OWNERS', 'QUOTA', name)[0]
    return out


def state(c, mode, dbs=(0, 1, 2, 3)):
    t = top(mode)
    return {
        'scopes': c.call(*t, 'DEBUG', 'DIGEST-SCOPES'),
        'digest': c.call(*t, 'DEBUG', 'DIGEST'),
        'quotas': quotas(c, mode),
        'owners': owners_listed(c, mode),
        'views': {r: view(c, mode, *r, dbs=dbs) for r in READERS[mode]},
    }


def differences(a, b, path=()):
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b), key=repr):
            if k not in a or k not in b:
                out.append(path + (k,))
            else:
                out.extend(differences(a[k], b[k], path + (k,)))
        return out
    return [] if a == b else [path]


class Server:
    def __init__(self, binary, directory, mode, extra=(), keyspace_threads=0):
        self.mode = mode
        self.run = lf.Run(binary, directory, mode_args(mode, extra) if mode else tuple(extra), keyspace_threads)

    def up(self):
        code, text = self.run.start()
        if code is not None:
            raise AssertionError('server exited with %r: %s' % (code, text[-3000:]))
        c = self.run.client()
        if self.mode:
            owners = MODES[self.mode]['owners']
            c.call('ACL', 'SETUSER', 'keeper', *(KEEPER if owners else OPERATOR))
            c.call('ACL', 'SETUSER', 'default', *(OWNER_OPERATOR if owners else OPERATOR))
        return c

    def refused(self):
        code, text = self.run.start()
        if code is None:
            self.run.stop()
            raise AssertionError('server started on a log it must refuse')
        return code, text

    def client(self, user=None):
        c = self.run.client()
        if user:
            c.call('AUTH', user, 'x')
        return c

    def kill(self):
        self.run.kill()

    def stop(self):
        return self.run.stop()


def wait_for(predicate, timeout=30, what='the condition'):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError('timed out waiting for ' + what)


def persistence(c, mode, prefix=None):
    if prefix is not None:
        return lf.info(c, *prefix)
    return lf.info(c, *top(mode)) if mode else lf.info(c)


def rewrites(c, mode, prefix=None):
    return int(persistence(c, mode, prefix)['aof_rewrites'])


def wait_rewritten(c, mode, before, timeout=40, prefix=None):
    def done():
        i = persistence(c, mode, prefix)
        return int(i['aof_rewrites']) > before and i['aof_rewrite_in_progress'] == '0' and i['aof_rewrite_scheduled'] == '0'
    wait_for(done, timeout, 'the append-only rewrite to finish')


def manifest_files(directory):
    d = log_dir(directory)
    names = {'appendonly.aof.manifest'}
    for line in (d / 'appendonly.aof.manifest').read_text().splitlines():
        parts = line.split()
        if 'file' in parts:
            names.add(parts[parts.index('file') + 1])
    return names


def manifest_history(directory):
    d = log_dir(directory)
    out = []
    for line in (d / 'appendonly.aof.manifest').read_text().splitlines():
        parts = line.split()
        if 'type' in parts and parts[parts.index('type') + 1] == 'h':
            out.append(parts[parts.index('file') + 1])
    return out


def log_files_match_manifest(directory):
    if directory is None:
        return True
    present = {p.name for p in log_dir(directory).iterdir()}
    return present == manifest_files(directory)


def wait_history_gone(directory, timeout=20):
    wait_for(lambda: log_files_match_manifest(directory), timeout, 'the history files to be removed')


def tree_files(directory):
    return sorted(p for p in Path(directory).rglob('*') if p.is_file())


def holding(directory, needle, skip=()):
    if isinstance(needle, str):
        needle = needle.encode()
    return [str(p.relative_to(directory)) for p in tree_files(directory) if p.name not in skip and needle in p.read_bytes()]


def plain_server(binary, directory, extra=(), keyspace_threads=0):
    s = Server(binary, directory, '', extra, keyspace_threads)
    s.run.arguments += list(SEEDS + LOG)
    return s


MASKED_INFO = ('run_id', 'process_id', 'tcp_port', 'uptime_in_seconds', 'uptime_in_days', 'server_time_usec', 'executable',
               'config_file', 'listener0', 'redis_git_sha1', 'redis_git_dirty', 'arch_bits', 'os', 'monotonic_clock', 'mem_allocator',
               'process_supervised', 'io_threads_active', 'lru_clock', 'master_replid', 'master_replid2', 'hz')


def info_lines(c, p, sections):
    out = {}
    for section in sections:
        value = c.call(*p, 'INFO', section).decode()
        for line in value.splitlines():
            if ':' not in line or line.startswith('#'):
                continue
            k, v = line.split(':', 1)
            if k in MASKED_INFO:
                continue
            if section == 'keyspace':
                v = ','.join(x for x in v.split(',') if not x.startswith('avg_ttl='))
            out[(section, k)] = v
    return out


INFO_SECTIONS = ('server', 'clients', 'memory', 'persistence', 'stats', 'replication', 'cpu', 'keyspace', 'errorstats', 'commandstats')


def corpus(c, mode, label, owner, dbs=(0, 1, 2, 3)):
    p = at(mode, label, owner)
    out = dict(view(c, mode, label, owner, dbs=dbs))
    out['info'] = info_lines(c, p, ('persistence', 'keyspace', 'replication', 'clients', 'memory', 'stats', 'cpu'))
    out['dbsize'] = [(db, c.call('SELECT', db), c.call(*p, 'DBSIZE')) for db in dbs]
    c.call('SELECT', 0)
    out['config'] = [c.call(*p, 'CONFIG', 'GET', name) for name in ('maxmemory', 'appendonly', 'appendfsync', 'save')]
    out['memory'] = []
    for key in sorted(k for k in out.get((0, 'scan'), [])):
        out['memory'].append((key, c.call(*p, 'OBJECT', 'ENCODING', key), c.call(*p, 'MEMORY', 'USAGE', key), c.call(*p, 'MEMORY', 'USAGE', key, 'SAMPLES', 0)))
    return out


def record_spans(data):
    out = []
    i = 0
    n = len(data)
    while i < n:
        start = i
        if data[i:i + 1] == b'#':
            j = data.index(b'\r\n', i)
            i = j + 2
            out.append((start, i, None))
            continue
        if data[i:i + 1] != b'*':
            raise ValueError('not a record at byte %d' % i)
        j = data.index(b'\r\n', i)
        count = int(data[i + 1:j])
        i = j + 2
        argv = []
        for _ in range(count):
            j = data.index(b'\r\n', i)
            size = int(data[i + 1:j])
            i = j + 2
            argv.append(data[i:i + size])
            i += size + 2
        out.append((start, i, argv))
    return out


def copy_tree(source, target):
    import shutil
    shutil.copytree(source, target, ignore=shutil.ignore_patterns('server.log'))
