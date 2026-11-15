import argparse
import hashlib
import json
import random
import struct
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import Conn, Server, ServerError, cpu_seconds, encode, parse_info

SCHEME = ['--label-levels', 'UNCLASSIFIED,CONFIDENTIAL,SECRET', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED']
RULES = ['on', 'nopass', '~*', '&*', '+@all']
MODES = {
    'off': {'args': [], 'login': None, 'build': [], 'reader': lambda i: []},
    'owners': {'args': ['--owners', 'yes'] + SCHEME, 'login': ['clearance:*', 'trust:*', 'owners:*', 'owner-shared', 'owner-operator'],
               'build': ['LABEL', 'AS', 'SHARED'], 'reader': lambda i: ['LABEL', 'AS', 'OWNER', 'u%d' % i]},
}
SIZES = {'smoke': (300, 16, 2, 40), 'full': (100000, 128, 16, 5000)}
KEY = 'set'


def blob(vector):
    return struct.pack('<%df' % len(vector), *vector)


def percentile(values, share):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * share))]


def compute_jobs(c, mode):
    info = parse_info(c.call(*MODES[mode]['build'], 'INFO', 'server'))
    return int(info.get('compute_jobs_submitted', 0))


def client_run(port, mode, index, frames, pipeline, result):
    c = Conn(port)
    digest = hashlib.sha256()
    latencies = []
    failed = 0
    for start in range(0, len(frames), pipeline):
        batch = frames[start:start + pipeline]
        t0 = time.perf_counter()
        c.s.sendall(b''.join(batch))
        replies = [c.reply() for _ in batch]
        latencies.append(time.perf_counter() - t0)
        for r in replies:
            if isinstance(r, ServerError):
                failed += 1
            digest.update(repr(r).encode())
    c.close()
    result[index] = (latencies, failed, digest.hexdigest())


def run_variant(port, mode, clients, queries, pipeline, variant, count, dim, seed):
    rng = random.Random(seed)
    per_client = []
    for i in range(clients):
        prefix = MODES[mode]['reader'](i)
        extra = ['NOTHREAD'] if variant == 'inline' else []
        per_client.append([encode(prefix + ['VSIM', KEY, 'FP32', blob([rng.uniform(-1, 1) for _ in range(dim)]), 'COUNT', count, 'WITHSCORES'] + extra)
                           for _ in range(queries)])
    results = [None] * clients
    workers = [threading.Thread(target=client_run, args=(port, mode, i, per_client[i], pipeline, results)) for i in range(clients)]
    t0 = time.perf_counter()
    for w in workers:
        w.start()
    for w in workers:
        w.join()
    wall = time.perf_counter() - t0
    latencies = [x for r in results for x in r[0]]
    return {'wall_s': wall, 'queries_per_s': clients * queries / wall, 'latency_median_s': percentile(latencies, 0.5), 'latency_p99_s': percentile(latencies, 0.99),
            'failed': sum(r[1] for r in results), 'reply_digest': hashlib.sha256(''.join(r[2] for r in results).encode()).hexdigest()}


def measure(a, mode, threads, port, work, shape):
    elements, dim, clients, queries = shape
    spec = MODES[mode]
    args = ['--compute-threads', str(threads), '--compute-max-memory', a.compute_memory] + spec['args']
    if spec['login'] is not None:
        args += ['--user', 'default'] + RULES + spec['login']
    server = Server(a.server, port, Path(work) / ('%s-%d' % (mode, threads)), args, cpus=a.cpu)
    rows = []
    try:
        c = server.conn()
        rng = random.Random(elements + dim)
        frames = [encode(spec['build'] + ['VADD', KEY, 'FP32', blob([rng.uniform(-1, 1) for _ in range(dim)]), 'e%d' % i, 'Q8']) for i in range(elements)]
        for r in c.pipeline(frames, window=500):
            if isinstance(r, ServerError):
                raise SystemExit('building the set failed: %s' % r)
        for variant in a.variants.split(','):
            jobs0 = compute_jobs(c, mode)
            cpu0 = cpu_seconds(server.pid)
            row = run_variant(port, mode, clients, queries, a.pipeline, variant, a.count, dim, 99)
            row.update({'mode': mode, 'compute_threads': threads, 'variant': variant, 'clients': clients, 'queries_per_client': queries, 'pipeline': a.pipeline,
                        'elements': elements, 'dim': dim, 'server_cpu_s': cpu_seconds(server.pid) - cpu0, 'jobs_submitted': compute_jobs(c, mode) - jobs0})
            rows.append(row)
        c.close()
    finally:
        server.stop()
    return rows


def main():
    parser = argparse.ArgumentParser(
        description="Measures vector similarity search under load at several numbers of compute threads: many clients each send VSIM commands, in the default form, which a compute worker runs when the server has any, and with NOTHREAD, which keeps the search on the coordinator, so inline and threaded runs of the same queries are measured on the same server. Each client reads the same set (labels off), or reads a shared set as its own user (owner mode). Per run it records the throughput, the median and 99th percentile round trip of a command or batch, the server's CPU time and the compute jobs submitted, and every run's replies are hashed: the hashes of one mode must be identical for every thread count and variant, which the exit status checks. Informs: the threshold below which a search stays inline, and whether replies are built on the worker. The timing fields are for a quiet machine and are read in a speed pass.")
    parser.add_argument('--server', default='bin/eski', help='the server binary (default bin/eski)')
    parser.add_argument('--port', type=int, default=7680, help='first port; each thread count uses the next one in turn')
    parser.add_argument('--size', choices=('smoke', 'full', 'custom'), default='smoke', help='smoke: 300 elements of 16 dimensions, 2 clients of 40 queries; full: 100,000 elements of 128 dimensions, 16 clients of 5,000 queries; custom: the numbers below')
    parser.add_argument('--elements', type=int, default=300)
    parser.add_argument('--dim', type=int, default=16)
    parser.add_argument('--clients', type=int, default=2)
    parser.add_argument('--queries', type=int, default=40, help='queries per client')
    parser.add_argument('--count', type=int, default=10, help='the COUNT of each search')
    parser.add_argument('--pipeline', type=int, default=1, help='commands in flight per client; 1 measures each command alone')
    parser.add_argument('--threads', default='0,1,2,4', help='comma separated compute thread counts')
    parser.add_argument('--modes', default='off,owners', help='comma separated: off, owners')
    parser.add_argument('--variants', default='threaded,inline', help='comma separated: threaded (the default form), inline (NOTHREAD)')
    parser.add_argument('--compute-memory', default='128mb', help='the compute-max-memory of the server')
    parser.add_argument('--cpu', help='CPU list for the server, as taskset -c takes it')
    parser.add_argument('--out', help='write the JSON here as well')
    a = parser.parse_args()
    shape = (a.elements, a.dim, a.clients, a.queries) if a.size == 'custom' else SIZES[a.size]
    for m in a.modes.split(','):
        if m not in MODES:
            raise SystemExit('unknown mode %s' % m)
    rows = []
    with tempfile.TemporaryDirectory(prefix='eski-vsim-threads.') as work:
        port = a.port
        for mode in a.modes.split(','):
            for threads in [int(t) for t in a.threads.split(',')]:
                rows += measure(a, mode, threads, port, work, shape)
                port += 1
    text = json.dumps({'rows': rows}, indent=2)
    if a.out:
        Path(a.out).write_text(text + '\n')
    print(text)
    identical = all(len({r['reply_digest'] for r in rows if r['mode'] == m}) == 1 for m in a.modes.split(','))
    threaded_ran = all(r['jobs_submitted'] == 0 for r in rows if r['compute_threads'] == 0 or r['variant'] == 'inline')
    return 0 if identical and threaded_ran and all(r['failed'] == 0 for r in rows) else 1


if __name__ == '__main__':
    sys.exit(main())
