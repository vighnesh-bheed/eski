import argparse
import json
import math
import os
import random
import statistics
import struct
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import operator_rules, Server, ServerError, cpu_seconds, encode, pairs, parse_info, rss_bytes, sha256

SIZES = {'smoke': (2000, 1000), 'full': (300000, 50000)}
POOL = 4096
OPERATOR = ['on', 'nopass', '~*', '&*', '+@all', 'owners:*', 'owner-shared', 'owner-operator']


def vector(rng, dim):
    return [(b - 127.5) / 127.5 for b in rng.randbytes(dim)]


def blob(v):
    return struct.pack('<%df' % len(v), *v)


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    return dot / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b)) or 1.0)


def user(i):
    return 'u%d' % i


def value(i):
    return 'v%x' % i


class Run:
    def __init__(self, args):
        self.a = args
        self.failures = []
        self.checks = 0
        self.rng = random.Random(args.seed)
        self.shared = [vector(self.rng, args.dim) for _ in range(args.graph)]
        self.pool = [vector(self.rng, args.dim) for _ in range(POOL)]
        self.load_wall = 0.0
        self.load_cpu = 0.0

    def fail(self, what, got):
        if len(self.failures) < 50:
            self.failures.append('%s: %r' % (what, got))
        else:
            self.failures.append(None)

    def expect(self, what, got, want):
        self.checks += 1
        if got != want:
            self.fail('%s, wanted %r' % (what, want), got)

    def own(self, i, *cmd):
        return encode(['LABEL', 'AS', 'OWNER', user(i)] + list(cmd))

    def shared_call(self, c, *cmd):
        return c.call('LABEL', 'AS', 'SHARED', *cmd)

    def snapshot(self, c, pid):
        time.sleep(0.3)
        m = parse_info(self.shared_call(c, 'INFO', 'memory'))
        o = parse_info(self.shared_call(c, 'INFO', 'owners'))
        return {
            'used_memory': int(m['used_memory']),
            'allocator_allocated': int(m['allocator_allocated']),
            'rss': rss_bytes(pid),
            'owner_bytes': int(o.get('owner_bytes', 0)),
            'owner_partitions': int(o.get('owner_partitions', 0)),
            'owners_known': int(o.get('owners_known', 0)),
            'owners_holding_data': int(o.get('owners_holding_data', 0)),
        }

    def build_graph(self, c):
        frames = [encode(['LABEL', 'AS', 'SHARED', 'VADD', 'vs', 'FP32', blob(v), 's%d' % j]) for j, v in enumerate(self.shared)]
        frames.append(encode(['LABEL', 'AS', 'SHARED', 'SET', 'sk', 'shared']))
        for j, r in enumerate(c.pipeline(frames, window=500)):
            self.expect('shared write %d' % j, r if not isinstance(r, ServerError) else str(r), 1 if j < len(self.shared) else 'OK')

    def load(self, c, pid, lo, hi):
        frames = []
        for i in range(lo, hi):
            frames.append(self.own(i, 'SET', 'k', value(i)))
            frames.append(self.own(i, 'VADD', 'vs', 'FP32', blob(self.pool[i % POOL]), 'e%d' % i))
        cpu0 = cpu_seconds(pid)
        t0 = time.perf_counter()
        replies = c.pipeline(frames)
        self.load_wall += time.perf_counter() - t0
        self.load_cpu += cpu_seconds(pid) - cpu0
        for n, r in enumerate(replies):
            i = lo + n // 2
            want = 'OK' if n % 2 == 0 else 1
            self.expect('write of %s' % user(i), r if not isinstance(r, ServerError) else str(r), want)

    def neighbour(self, i):
        return i - 1 if i > 0 else 1

    def check(self, c, lo, hi):
        g = self.a.graph
        frames = []
        wants = []
        for i in range(lo, hi):
            j = self.neighbour(i)
            frames += [self.own(i, 'GET', 'k'), self.own(i, 'VISMEMBER', 'vs', 'e%d' % i), self.own(i, 'VCARD', 'vs'),
                       self.own(i, 'VISMEMBER', 'vs', 's%d' % (i % g)), self.own(i, 'VISMEMBER', 'vs', 'e%d' % j),
                       self.own(i, 'DBSIZE')]
            wants += [('%s reads its key' % user(i), value(i).encode()), ('%s holds its element' % user(i), 1),
                      ('%s counts the shared graph and its element' % user(i), g + 1),
                      ('%s sees shared element s%d' % (user(i), i % g), 1),
                      ('%s does not see the element of %s' % (user(i), user(j)), 0),
                      ('%s sees its key and the two shared keys' % user(i), 3)]
        for (what, want), r in zip(wants, c.pipeline(frames)):
            self.expect(what, r if not isinstance(r, ServerError) else str(r), want)
        for i in range(lo, hi):
            if i % self.a.sample_every and i != hi - 1:
                continue
            self.sampled(c, i)

    def sampled(self, c, i):
        j = self.neighbour(i)
        s = i % self.a.graph
        emb = c.call('LABEL', 'AS', 'OWNER', user(i), 'VEMB', 'vs', 'e%d' % i)
        sim = cosine([float(x) for x in emb], self.pool[i % POOL])
        self.checks += 1
        if sim < 0.98:
            self.fail('%s reads back its vector' % user(i), sim)
        own = c.call('LABEL', 'AS', 'OWNER', user(i), 'VSIM', 'vs', 'ELE', 'e%d' % i, 'COUNT', '1', 'TRUTH')
        self.expect('%s finds its element first' % user(i), own, [b'e%d' % i])
        shared = c.call('LABEL', 'AS', 'OWNER', user(i), 'VSIM', 'vs', 'ELE', 's%d' % s, 'COUNT', '1', 'TRUTH')
        self.expect('%s finds shared element s%d first' % (user(i), s), shared, [b's%d' % s])
        near = c.call('LABEL', 'AS', 'OWNER', user(i), 'VSIM', 'vs', 'FP32', blob(self.pool[j % POOL]), 'COUNT', '1', 'TRUTH')
        self.checks += 1
        if near == [b'e%d' % j] or len(near) != 1:
            self.fail('%s searching with the vector of %s' % (user(i), user(j)), near)
        try:
            r = c.call('LABEL', 'AS', 'OWNER', user(i), 'VSIM', 'vs', 'ELE', 'e%d' % j)
        except ServerError as e:
            r = str(e)
        self.checks += 1
        if not isinstance(r, str) or 'element' not in r.lower():
            self.fail('%s searching from the element of %s' % (user(i), user(j)), r)

    def finish_checks(self, c):
        n = self.a.users
        g = self.a.graph
        self.expect('the shared reader counts the graph', self.shared_call(c, 'VCARD', 'vs'), g)
        self.expect('the shared reader sees two keys', self.shared_call(c, 'DBSIZE'), 2)
        self.expect('the shared reader sees no user key', self.shared_call(c, 'GET', 'k'), None)
        self.expect('the shared reader sees no user element', self.shared_call(c, 'VISMEMBER', 'vs', 'e0'), 0)
        o = parse_info(self.shared_call(c, 'INFO', 'owners'))
        self.expect('owners holding data', int(o.get('owners_holding_data', -1)), n)
        mid = n // 2
        info = pairs(self.shared_call(c, 'OWNERS', 'INFO', user(mid)))
        self.expect('OWNERS INFO keys of %s, its string and its vector set' % user(mid), info.get('keys'), 2)
        self.expect('OWNERS INFO elements of %s' % user(mid), info.get('elements'), 1)
        return info

    def idle(self, pid, seconds):
        cpu0 = cpu_seconds(pid)
        t0 = time.perf_counter()
        time.sleep(seconds)
        return {'server_cpu_s': cpu_seconds(pid) - cpu0, 'wall_s': time.perf_counter() - t0}

    def latency(self, c):
        rng = random.Random(self.a.seed + 1)
        series = {'user_get': [], 'shared_get': [], 'user_vsim': [], 'shared_vsim': []}
        for k in range(self.a.samples):
            i = rng.randrange(self.a.users)
            q = blob(vector(rng, self.a.dim))
            order = (('user', 'shared') if k % 2 == 0 else ('shared', 'user'))
            for who in order:
                head = ['LABEL', 'AS', 'OWNER', user(i)] if who == 'user' else ['LABEL', 'AS', 'SHARED']
                key = 'k' if who == 'user' else 'sk'
                t0 = time.perf_counter_ns()
                c.call(*head, 'GET', key)
                series[who + '_get'].append(time.perf_counter_ns() - t0)
                t0 = time.perf_counter_ns()
                c.call(*head, 'VSIM', 'vs', 'FP32', q, 'COUNT', '10')
                series[who + '_vsim'].append(time.perf_counter_ns() - t0)
        out = {}
        for name, xs in series.items():
            xs.sort()
            out[name] = {'samples': len(xs), 'median_us': statistics.median(xs) / 1000, 'p90_us': xs[int(len(xs) * 0.9)] / 1000,
                         'p99_us': xs[int(len(xs) * 0.99)] / 1000}
        return out


def main():
    ap = argparse.ArgumentParser(description='Owner scale run: many users, each with one small key and one vector set element, '
                                 'beside a shared graph. Checks isolation while it loads and reports bytes per user.')
    ap.add_argument('--binary', default=str(Path(__file__).resolve().parents[2] / 'bin' / 'eski'))
    ap.add_argument('--port', type=int, default=7650)
    ap.add_argument('--size', choices=sorted(SIZES), default='smoke')
    ap.add_argument('--users', type=int)
    ap.add_argument('--graph', type=int)
    ap.add_argument('--dim', type=int, default=128)
    ap.add_argument('--batch', type=int, default=5000)
    ap.add_argument('--sample-every', type=int, default=1000)
    ap.add_argument('--seed', type=int, default=7)
    ap.add_argument('--extra', default='', help='more server options, split on spaces')
    ap.add_argument('--cpu', help='CPU list for the server (taskset)')
    ap.add_argument('--probes', action='store_true', help='also record the timing probes')
    ap.add_argument('--idle-seconds', type=float, default=2.0)
    ap.add_argument('--samples', type=int, default=200)
    ap.add_argument('--print-timing', action='store_true', help='print the timing probes as well as recording them')
    ap.add_argument('--workdir')
    ap.add_argument('--out', help='append the JSON result to this file')
    a = ap.parse_args()
    users, graph = SIZES[a.size]
    a.users = a.users or users
    a.graph = a.graph or graph
    if a.users < 2 or a.graph < 1:
        raise SystemExit('need at least two users and one shared element')
    workdir = Path(a.workdir or Path(os.environ.get('TMPDIR', '/tmp')) / ('eski-owner-scale-%d' % a.port))
    run = Run(a)
    server = Server(a.binary, a.port, workdir, ['--owners', 'yes'] + a.extra.split(), cpus=a.cpu)
    result = {'binary': server.binary, 'sha256': sha256(server.binary), 'users': a.users, 'graph': a.graph, 'dim': a.dim,
              'extra': a.extra, 'shape': 'SET k v<hex id> and VADD vs FP32 <%d floats> e<id> (Q8) per user' % a.dim}
    timing = {}
    try:
        c = server.conn()
        c.call('ACL', 'SETUSER', 'default', *operator_rules(a.extra.split(), OPERATOR))
        run.build_graph(c)
        if a.probes:
            timing['idle_without_owners'] = run.idle(server.pid, a.idle_seconds)
        before = run.snapshot(c, server.pid)
        for lo in range(0, a.users, a.batch):
            hi = min(a.users, lo + a.batch)
            run.load(c, server.pid, lo, hi)
            run.check(c, lo, hi)
        after = run.snapshot(c, server.pid)
        result['sample_owner_info'] = {k: v for k, v in run.finish_checks(c).items()}
        if a.probes:
            timing['creation'] = {'users': a.users, 'wall_s': run.load_wall, 'server_cpu_s': run.load_cpu,
                                  'users_per_s': a.users / run.load_wall if run.load_wall else None,
                                  'server_cpu_us_per_user': run.load_cpu * 1e6 / a.users}
            timing['idle_with_owners'] = run.idle(server.pid, a.idle_seconds)
            timing['latency'] = run.latency(c)
        c.close()
        result['before'] = before
        result['after'] = after
        result['bytes_per_user'] = {k: (after[k] - before[k]) / a.users for k in ('used_memory', 'allocator_allocated', 'rss', 'owner_bytes')}
        result['owner_partitions_per_user'] = (after['owner_partitions'] - before['owner_partitions']) / a.users
    finally:
        code = server.stop()
    result['fatal_log_lines'] = server.fatal_lines()
    result['exit_code'] = code
    result['checks'] = run.checks
    result['failures'] = len(run.failures)
    result['failure_samples'] = [f for f in run.failures if f]
    if a.probes:
        result['timing'] = timing
    if a.out:
        with open(a.out, 'a') as fh:
            fh.write(json.dumps(result, default=lambda v: v.decode(errors='replace') if isinstance(v, bytes) else str(v)) + '\n')
    print('owner scale: %d users, %d shared elements, %d checks, %d failures' % (a.users, a.graph, run.checks, len(run.failures)))
    for f in result['failure_samples'][:10]:
        print('  failure: %s' % f)
    print('bytes per user: used_memory %.0f, allocator_allocated %.0f, rss %.0f, owner_bytes %.0f; owner partitions per user %.2f' % (
        result['bytes_per_user']['used_memory'], result['bytes_per_user']['allocator_allocated'], result['bytes_per_user']['rss'],
        result['bytes_per_user']['owner_bytes'], result['owner_partitions_per_user']))
    if a.probes:
        if a.print_timing:
            print(json.dumps(timing, indent=1))
        else:
            print('timing probes recorded%s' % (' in ' + a.out if a.out else ''))
    bad = run.failures or result['fatal_log_lines'] or code not in (0, None)
    sys.exit(1 if bad else 0)


main()
