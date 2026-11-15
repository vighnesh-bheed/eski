import os
import random
import re
import socket
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import support
from support import Client, ServerError, encode

SCHEME = ('--label-levels', 'U,C,S', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED')
OWNERS = ('--owners', 'yes')
SEEDS = ('--debug-hash-seed', '11', '--label-stream-seed', '5')
OPERATOR = ('on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*')
OWNER_OPERATOR = OPERATOR + ('owners:*', 'owner-shared', 'owner-operator')
QUANTS = ('Q8', 'NOQUANT', 'BIN')

MODES = {
    'plain': {'args': (), 'owners': False, 'labelled': False},
    'labels': {'args': SCHEME, 'owners': False, 'labelled': True},
    'owners': {'args': OWNERS, 'owners': True, 'labelled': False},
    'both': {'args': SCHEME + OWNERS, 'owners': True, 'labelled': True},
}

_ports = None
_next = 0


def use_ports(text):
    global _ports
    if text:
        lo, hi = (int(x) for x in text.split('-'))
        _ports = (lo, hi)


def free_port():
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


REPORT_MARKS = ('WARNING: ThreadSanitizer', 'ERROR: AddressSanitizer', 'ERROR: LeakSanitizer', 'runtime error:',
                'a vector set changed while a search read it', 'a vector set write ran on a compute worker',
                'a vector set was changed off the coordinator')


class Server(support.Server):
    def __init__(self, binary, workers=2, mode='plain', arguments=(), memory=512 << 20):
        extra = tuple(MODES[mode]['args']) + SEEDS + ('--memcached-port', '0') + tuple(arguments)
        super().__init__(binary, workers=workers, memory=memory, arguments=extra)
        self.port = free_port()
        self.mode = mode

    def client(self, timeout=60):
        return super().client(timeout)

    def start(self):
        super().start()
        c = Client(self.port, timeout=60)
        try:
            if self.mode == 'labels':
                c.call('ACL', 'SETUSER', 'default', *OPERATOR)
            elif self.mode in ('owners', 'both'):
                c.call('ACL', 'SETUSER', 'default', *OWNER_OPERATOR)
        finally:
            c.close()
        return self

    def reports(self):
        try:
            text = (self.directory / 'server.log').read_text(errors='replace')
        except OSError:
            return '', []
        return text, [mark for mark in REPORT_MARKS if mark in text]

    def close(self):
        problem = None
        try:
            self.stop()
        except BaseException as error:
            problem = error
        text, marks = self.reports()
        keep = os.environ.get('ESKI_THREADING_REPORTS')
        if keep and marks:
            Path(keep).mkdir(parents=True, exist_ok=True)
            (Path(keep) / ('%d-%d.log' % (int(time.time() * 1000), os.getpid()))).write_text(text)
        self.temporary.cleanup()
        if problem is not None:
            raise problem
        if marks:
            raise AssertionError('the server reported %s\n%s' % (', '.join(marks), text[-8000:]))


def at(mode, label=None, owner=None):
    if mode == 'plain':
        return ()
    if mode == 'labels':
        return ('LABEL', 'AS', label or 'U')
    if mode == 'both':
        label = label or 'U'
    if not owner:
        return ('LABEL', 'AS', label or 'UNCLASSIFIED', 'SHARED')
    return ('LABEL', 'AS', label or 'UNCLASSIFIED', 'OWNER', owner)


def top(mode):
    if mode == 'labels':
        return at(mode, 'S//A/B')
    if mode == 'owners':
        return at(mode, 'UNCLASSIFIED')
    if mode == 'both':
        return at(mode, 'S//A/B')
    return ()


class Raw:
    def __init__(self, client):
        self.client = client

    def line(self):
        return self.client.line() + b'\r\n'

    def frame(self):
        head = self.line()
        prefix = head[:1]
        if prefix in (b'$', b'='):
            n = int(head[1:-2])
            if n < 0:
                return head
            return head + self.client.take(n + 2)
        if prefix in (b'*', b'~', b'>', b'%', b'|'):
            n = int(head[1:-2])
            if n < 0:
                return head
            count = 2 * n if prefix in (b'%', b'|') else n
            out = head
            for _ in range(count):
                out += self.frame()
            if prefix == b'|':
                out += self.frame()
            return out
        return head

    def pipeline(self, commands):
        self.client.send_many(commands)
        return [self.frame() for _ in commands]


def vector(rng, dim):
    return [round(rng.uniform(-1, 1), 4) for _ in range(dim)]


def vadd(prefix, key, rng, dim, name, *extra, quant='Q8'):
    return (*prefix, 'VADD', key, 'VALUES', dim, *vector(rng, dim), name, quant, *extra)


def fill(client, prefix, key, rng, dim, count, quant='Q8', names=None, attrs=True):
    commands = []
    for i in range(count):
        name = names[i] if names else 'e%d' % i
        extra = ('SETATTR', '{"a":%d,"t":"x%d"}' % (i % 5, i % 3)) if attrs and i % 4 else ()
        commands.append(vadd(prefix, key, rng, dim, name, *extra, quant=quant))
    for value in client.pipeline(commands):
        if isinstance(value, ServerError):
            raise value
    return commands


def queries(rng, dim, names, count=40):
    out = []
    for _ in range(count):
        if rng.random() < 0.3:
            q = ['ELE', rng.choice(names)]
        else:
            q = ['VALUES', dim, *vector(rng, dim)]
        options = []
        if rng.random() < 0.6:
            options.append('WITHSCORES')
        if rng.random() < 0.4:
            options.append('WITHATTRIBS')
        options += ['COUNT', rng.randint(1, 30)]
        if rng.random() < 0.3:
            options += ['FILTER', rng.choice(['.a >= 2', '.a == 1 or .t == "x2"', '.missing == 3'])]
        if rng.random() < 0.2:
            options.append('TRUTH')
        if rng.random() < 0.2:
            options += ['EF', rng.randint(10, 200)]
        if rng.random() < 0.15:
            options += ['EPSILON', 0.5]
        out.append(q + options)
    return out


def pairs(raw, prefix, key, query_list):
    commands = []
    for q in query_list:
        commands.append((*prefix, 'VSIM', key, *q))
        commands.append((*prefix, 'VSIM', key, *q, 'NOTHREAD'))
    replies = raw.pipeline(commands)
    return [(commands[i], replies[i], replies[i + 1]) for i in range(0, len(commands), 2)]


def compute(client, mode='plain', prefix=None):
    value = client.call(*(top(mode) if prefix is None else prefix), 'INFO', 'server')
    values = dict(line.split(':', 1) for line in value.decode().splitlines() if ':' in line and not line.startswith('#'))
    return {name: int(values[name]) for name in support.FIELDS}


def connected(client, mode='plain', prefix=None):
    value = client.call(*(top(mode) if prefix is None else prefix), 'INFO', 'clients')
    for line in value.decode().splitlines():
        if line.startswith('connected_clients:'):
            return int(line.split(':', 1)[1])
    raise AssertionError('INFO clients has no connected_clients')


def threshold():
    text = (support.ROOT / 'src/vset_threads.odin').read_text()
    found = re.search(r'VSET_THREAD_MIN_VISIBLE\s*::\s*(\d+)', text)
    if not found:
        raise AssertionError('the visible size threshold is not named in src/vset_threads.odin')
    return int(found.group(1))


def threaded_count(results, missing=(), visible=None):
    floor = threshold()
    if visible is not None and visible < floor:
        return 0
    return sum(1 for command, reply, unused in results if not reply.startswith(b'-') and not any(m in command for m in missing))


def parse_monitor(line):
    text = line.decode() if isinstance(line, bytes) else line
    at = text.find('] ')
    if at < 0:
        return None
    rest = text[at + 2:]
    out = []
    i = 0
    while i < len(rest):
        if rest[i] != '"':
            i += 1
            continue
        i += 1
        buf = bytearray()
        while rest[i] != '"':
            ch = rest[i]
            if ch == '\\':
                nxt = rest[i + 1]
                if nxt == 'x':
                    buf.append(int(rest[i + 2:i + 4], 16))
                    i += 4
                    continue
                buf += {'n': b'\n', 'r': b'\r', 't': b'\t', 'a': b'\a', 'b': b'\b', '"': b'"', '\\': b'\\'}.get(nxt, nxt.encode())
                i += 2
                continue
            buf += ch.encode()
            i += 1
        out.append(bytes(buf))
        i += 1
    return out


def seeded(seed):
    return random.Random(seed)


def warm(clients):
    for c in clients:
        c.call('PING')


SLEEPING = ('35', '230')


class Hold:
    def __init__(self, server, mode='plain', seconds=1.0):
        self.client = server.client(timeout=120)
        self.client.call('PING')
        self.seconds = seconds
        self.mode = mode
        self.pid = server.process.pid
        self.started = 0.0

    def asleep(self):
        try:
            with open('/proc/%d/task/%d/syscall' % (self.pid, self.pid)) as handle:
                return handle.read().split()[0] in SLEEPING
        except (OSError, IndexError):
            return None

    def __enter__(self):
        self.started = time.monotonic()
        self.client.send(*top(self.mode), 'DEBUG', 'SLEEP', self.seconds)
        if self.asleep() is None:
            time.sleep(0.3)
            return self
        support.wait_for(self.asleep, 30, 'the coordinator to start its sleep')
        return self

    def __exit__(self, kind, value, trace):
        still_asleep = self.asleep()
        reply = self.client.reply()
        if kind is not None:
            return False
        if isinstance(reply, ServerError):
            raise reply
        if still_asleep is False:
            raise AssertionError('the coordinator woke before the commands of the batch were all sent (a %.2f second hold): the machine was too busy for a one-batch test' % self.seconds)
        return False


class Noise:
    def __init__(self, server, mode, keys, seed, writers=2, cas=True):
        self.stop = threading.Event()
        self.errors = []
        self.count = 0
        self.threads = []
        for i in range(writers):
            t = threading.Thread(target=self.run, args=(server.port, mode, keys, seed + 1000 * i, cas), daemon=True)
            self.threads.append(t)

    def run(self, port, mode, keys, seed, cas):
        rng = random.Random(seed)
        try:
            c = Client(port, timeout=60)
            while not self.stop.is_set():
                key, dim, quant, scope = rng.choice(keys)
                prefix = at(mode, *scope) if mode != 'plain' else ()
                name = 'n%d' % rng.randint(0, 150)
                roll = rng.random()
                if roll < 0.35:
                    command = vadd(prefix, key, rng, dim, name, 'CAS' if cas else 'SETATTR', *(() if cas else ('{"a":1}',)), quant=quant)
                elif roll < 0.6:
                    command = vadd(prefix, key, rng, dim, name, quant=quant)
                elif roll < 0.8:
                    command = (*prefix, 'VREM', key, name)
                elif roll < 0.9:
                    command = (*prefix, 'VSETATTR', key, name, '{"a":%d}' % rng.randint(0, 4))
                else:
                    command = (*prefix, 'VSIM', key, 'VALUES', dim, *vector(rng, dim), 'COUNT', 5)
                value = c.call(*command)
                self.count += 1
            c.close()
        except BaseException as error:
            self.errors.append(error)

    def __enter__(self):
        for t in self.threads:
            t.start()
        return self

    def __exit__(self, *unused):
        self.stop.set()
        for t in self.threads:
            t.join(60)
        if self.errors:
            raise self.errors[0]


def twin_vectors(rng, dim, count, quant='Q8', holes=0.1, twins=0.15):
    commands = []
    last = None
    for i in range(count):
        if last is not None and rng.random() < twins:
            v = last
        else:
            v = vector(rng, dim)
        last = v
        extra = ('SETATTR', '{"a":%d,"t":"x%d"}' % (i % 5, i % 3)) if i % 4 else ()
        commands.append(('VALUES', dim, *v, 'e%d' % i, quant, *extra))
    return commands


def build_set(client, prefix, key, rng, dim, count, quant='Q8', holes=0.1, twins=0.15):
    commands = [(*prefix, 'VADD', key, *rest) for rest in twin_vectors(rng, dim, count, quant, holes, twins)]
    for value in client.pipeline(commands):
        if isinstance(value, ServerError):
            raise value
    gone = ['e%d' % i for i in range(count) if rng.random() < holes]
    for value in client.pipeline([(*prefix, 'VREM', key, name) for name in gone]):
        if isinstance(value, ServerError):
            raise value
    return [n for n in ('e%d' % i for i in range(count)) if n not in set(gone)]


def monitor_peer(line):
    text = line.decode() if isinstance(line, bytes) else line
    a = text.find('[')
    b = text.find(']')
    if a < 0 or b < a:
        return None
    parts = text[a + 1:b].split(' ', 1)
    return parts[1] if len(parts) == 2 else None


def monitor_collect(monitor, marker_client):
    marker_client.call('ECHO', 'end-of-stream')
    order = []
    while True:
        line = monitor.read()
        argv = parse_monitor(line)
        if argv is None:
            continue
        if argv[:1] == [b'ECHO']:
            return order
        order.append((monitor_peer(line), argv))
