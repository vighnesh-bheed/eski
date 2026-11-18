import argparse
import json
import os
import random
import signal
import struct
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import Conn, Container, Server, encode
from search_bench import execute, key_of, memory, timed

SCHEMA = 'eski-baseline-vector-sets-v1'
TARGETS = ('eski', 'redis-search')
KEY = 'bench:vset'
DIFFERENCES = {
    'hnsw': 'VSIM without TRUTH walks each engine\'s own HNSW graph, which the two engines build differently, so the neighbours of one query '
            'may differ; the replies are compared and the request is timed with the difference counted',
}


def interrupted(signum, frame):
    raise KeyboardInterrupt


def blob(values):
    return struct.pack('<%df' % len(values), *values)


def corpus(count, dim, seed):
    rng = random.Random(seed)
    vectors = [[round(rng.uniform(-1, 1) * 256) / 256 for _ in range(dim)] for _ in range(count)]
    attributes = [json.dumps(dict(group=i % 8, rank=i), separators=(',', ':')) for i in range(count)]
    probes = [[round(rng.uniform(-1, 1) * 256) / 256 for _ in range(dim)] for _ in range(64)]
    return vectors, attributes, probes


def shapes(count, probes):
    out = []

    def add(name, make, difference=None):
        out.append(dict(name=name, make=make, difference=difference))
    add('vsim-graph', lambda r: (('VSIM', KEY, 'FP32', blob(r.choice(probes)), 'COUNT', '10', 'WITHSCORES'),), 'hnsw')
    add('vsim-truth', lambda r: (('VSIM', KEY, 'FP32', blob(r.choice(probes)), 'COUNT', '10', 'WITHSCORES', 'TRUTH'),))
    add('vsim-element', lambda r: (('VSIM', KEY, 'ELE', 'e%d' % r.randrange(count), 'COUNT', '10', 'WITHSCORES', 'TRUTH'),))
    add('vsim-filter', lambda r: (('VSIM', KEY, 'FP32', blob(r.choice(probes)), 'COUNT', '10', 'WITHSCORES', 'TRUTH', 'FILTER', '.group == %d' % r.randrange(8)),))
    add('vemb', lambda r: (('VEMB', KEY, 'e%d' % r.randrange(count)),))
    add('vgetattr', lambda r: (('VGETATTR', KEY, 'e%d' % r.randrange(count)),))
    add('vcard-vdim', lambda r: (('VCARD', KEY), ('VDIM', KEY)))
    add('vismember', lambda r: (('VISMEMBER', KEY, 'e%d' % r.randrange(count * 2)),))
    return out


def plan_requests(shape_list, count, connections, seed):
    rng = random.Random(seed)
    plan = []
    for i in range(count):
        shape = shape_list[i % len(shape_list)] if i < len(shape_list) else rng.choice(shape_list)
        plan.append(dict(shape=shape['name'], owner=i % connections, request=tuple(tuple(part) for part in shape['make'](rng))))
    return plan


def build(conn, vectors, attributes, quant):
    frames = []
    for i, vector in enumerate(vectors):
        frames.append(encode(('VADD', KEY, 'FP32', blob(vector), 'e%d' % i, quant, 'SETATTR', attributes[i])))
    started = time.perf_counter()
    replies = conn.pipeline(frames, window=256)
    seconds = time.perf_counter() - started
    bad = [r for r in replies if r != 1]
    if bad:
        raise RuntimeError('VADD failed: %r' % bad[:3])
    usage = conn.call('MEMORY', 'USAGE', KEY)
    return dict(seconds=seconds, elements=len(frames), memory_usage=usage)


def start(target, args, port, folder):
    if target == 'eski':
        server = Server(args.server, port, folder, ('--maxmemory', '4gb'), cpus=args.server_cpus)
        return server, server.pid, None
    container = Container('eski-baseline-vset-%d-%d' % (port, os.getpid()), args.image,
                          ['redis-server', '--bind', '127.0.0.1', '--port', port, '--protected-mode', 'yes', '--save', '', '--appendonly', 'no',
                           '--maxmemory', '4gb'], port, folder, cpus=args.server_cpus, memory=args.server_memory, tmpfs='/data:rw,size=64m')
    return container, container.pid, container


def verify(args, data, shape_list, plans, folder):
    ports = {'eski': args.port, 'redis-search': args.port + 1}
    engines, replies = {}, {}
    distinct = {}
    for plan in plans.values():
        for item in plan:
            distinct.setdefault(key_of(item['request']), item)
    try:
        for target in TARGETS:
            engines[target] = start(target, args, ports[target], folder / ('verify-' + target))
            conn = Conn(ports[target], timeout=120)
            try:
                build(conn, data[0], data[1], args.quant)
                replies[target] = {key: execute(conn, item['request']) for key, item in distinct.items()}
            finally:
                conn.close()
    finally:
        for handle, _, _ in engines.values():
            handle.stop()
    by_shape = {s['name']: dict(checked=0, equal=0, differences=[], difference=s['difference']) for s in shape_list}
    for key, item in distinct.items():
        row = by_shape[item['shape']]
        row['checked'] += 1
        reference = replies['redis-search'][key]
        if args.corrupt_check == item['shape'] and row['checked'] == 1:
            reference = reference + ['deliberately wrong expectation']
        if replies['eski'][key] == reference:
            row['equal'] += 1
        elif len(row['differences']) < 5:
            row['differences'].append(dict(request=[[p if isinstance(p, str) else repr(p) for p in argv] for argv in item['request']],
                                           eski=replies['eski'][key], reference=reference))
    (folder / 'verification.json').write_text(json.dumps(by_shape, indent=1, default=repr) + '\n')
    return by_shape, {target: {key: replies[target][key] for key in distinct} for target in TARGETS}


def main():
    parser = argparse.ArgumentParser(description='Vector sets on Eski and on the pinned Redis 8.10.3 image: the same seeded elements and attributes are '
                                     'added to both, every distinct query is sent to both and its replies compared before anything is timed, the '
                                     'engine order alternates by repetition, and every repetition keeps the build time, raw per-request latencies, '
                                     'error counts and memory.')
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--image', required=True)
    parser.add_argument('--server-cpus', required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--elements', type=int, default=50000)
    parser.add_argument('--dim', type=int, default=128)
    parser.add_argument('--quant', choices=('Q8', 'NOQUANT', 'BIN'), default='Q8')
    parser.add_argument('--queries', type=int, default=4000)
    parser.add_argument('--warmup', type=int, default=200)
    parser.add_argument('--repetitions', type=int, default=4)
    parser.add_argument('--connections', default='1,8')
    parser.add_argument('--seed', type=int, default=4421)
    parser.add_argument('--server-memory', default='8g')
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--corrupt-check')
    args = parser.parse_args()
    args.connections = [int(v) for v in args.connections.split(',')]
    args.out = args.out.resolve()
    args.out.mkdir(parents=True)
    signal.signal(signal.SIGTERM, interrupted)
    data = corpus(args.elements, args.dim, args.seed)
    shape_list = shapes(args.elements, data[2])
    plans = {level: plan_requests(shape_list, args.queries, level, args.seed + level) for level in args.connections}
    plans['warmup'] = plan_requests(shape_list, args.warmup, 1, args.seed - 1)
    summary = dict(schema=SCHEMA, elements=args.elements, dim=args.dim, quant=args.quant, queries=args.queries, repetitions=args.repetitions,
                   connections=args.connections, reference_image=args.image, seed=args.seed, server_cpus=args.server_cpus,
                   client_cpus=sorted(os.sched_getaffinity(0)), shapes=[dict(name=s['name'], difference=s['difference'], documented=DIFFERENCES.get(s['difference']))
                                                                        for s in shape_list],
                   timed=not args.verify_only, rows=[], exit_code=1)
    report = args.out / 'summary.json'
    try:
        verification, verified = verify(args, data, shape_list, plans, args.out)
        summary['verification'] = verification
        unexpected = [n for n, row in verification.items() if row['equal'] != row['checked'] and not row['difference']]
        timed_shapes = {n for n, row in verification.items() if row['equal'] == row['checked'] or row['difference']}
        summary.update(unexpected_differences=unexpected, timed_shapes=sorted(timed_shapes))
        if not args.verify_only and timed_shapes:
            for rep in range(1, args.repetitions + 1):
                order = TARGETS if rep % 2 else tuple(reversed(TARGETS))
                for target in order:
                    directory = args.out / ('rep-%d-%s' % (rep, target))
                    directory.mkdir()
                    handle, pid, container = start(target, args, args.port, directory / 'server')
                    row = dict(rep=rep, target=target, order=list(order))
                    expected = verified[target]
                    summary['rows'].append(row)
                    try:
                        conn = Conn(args.port, timeout=120)
                        row['memory_empty'] = memory(conn, pid, container)
                        row['build'] = build(conn, data[0], data[1], args.quant)
                        row['memory_built'] = memory(conn, pid, container)
                        if 'used_memory' in row['memory_built'] and 'used_memory' in row['memory_empty']:
                            row['bytes_per_element'] = (row['memory_built']['used_memory'] - row['memory_empty']['used_memory']) / args.elements
                        warm = [(p['shape'], p['request']) for p in plans['warmup'] if p['shape'] in timed_shapes]
                        failed = {}
                        for shape, request in warm:
                            if execute(conn, request) != expected[key_of(request)]:
                                failed[shape] = failed.get(shape, 0) + 1
                        row['warmup'] = dict(requests=len(warm), errors=sum(failed.values()), errors_by_shape=failed)
                        conn.close()
                        row['levels'] = []
                        for level in args.connections:
                            level_dir = directory / ('connections-%d' % level)
                            level_dir.mkdir()
                            row['levels'].append(timed(args.port, [p for p in plans[level] if p['shape'] in timed_shapes], expected, level, level_dir))
                        conn = Conn(args.port, timeout=120)
                        row['memory_after'] = memory(conn, pid, container)
                        conn.close()
                    finally:
                        handle.stop()
        errors = sum(entry['errors'] for row in summary['rows'] for level in row.get('levels', [])
                     for name, entry in level['by_shape'].items() if not verification[name]['difference'])
        errors += sum(count for row in summary['rows'] for name, count in row.get('warmup', {}).get('errors_by_shape', {}).items()
                      if not verification[name]['difference'])
        summary['timed_errors'] = errors
        summary['exit_code'] = int(bool(unexpected) or not timed_shapes or bool(errors))
    except KeyboardInterrupt:
        summary.update(error='interrupted', exit_code=130)
        raise
    finally:
        report.write_text(json.dumps(summary, indent=1, default=repr) + '\n')
    return summary['exit_code']


if __name__ == '__main__':
    sys.exit(main())
