import argparse
from contextlib import closing, contextmanager
import json
import math
import os
from pathlib import Path
import random
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from harness import Conn, ROOT, Server, ServerError, encode, parse_info

sys.path.insert(0, str(ROOT / 'test/search'))
import compare
from compare import IMAGE, reference_server

TOPICS = ('alpha', 'bravo', 'cedar', 'denim', 'ember', 'frost', 'grove', 'haven')
PREFIX = 'baseline:document:'
INDEX = 'baseline-index'


def corpus(size, seed):
    topics = [TOPICS[i % len(TOPICS)] for i in range(size)]
    random.Random(seed).shuffle(topics)
    return topics


def search_cases(topics):
    cases = []
    for topic in TOPICS:
        keys = [f'{PREFIX}{i}'.encode() for i, word in enumerate(topics) if word == topic]
        args = ('FT.SEARCH', INDEX, f'@body:{topic}', 'SORTBY', 'rank', 'ASC', 'NOCONTENT',
                'LIMIT', '0', '5', 'DIALECT', '2')
        cases.append(('search', args, [len(keys), *keys[:5]]))
    return cases


def json_case(rank):
    return 'json-get', ('JSON.GET', f'{PREFIX}{rank}', '$.rank'), f'[{rank}]'.encode()


def planned_requests(topics, seed, count):
    rng = random.Random(seed)
    searches = search_cases(topics)
    return [rng.choice(searches) if rng.randrange(2) else json_case(rng.randrange(len(topics)))
            for _ in range(count)]


def validate(client, item):
    _, args, expected = item
    result = client.call(*args)
    if result != expected:
        raise ValueError(f'{args!r}: expected {expected!r}, got {result!r}')


def prepare(client, topics, requests):
    response = client.call('FT.CREATE', INDEX, 'ON', 'JSON', 'PREFIX', '1', PREFIX, 'SCHEMA',
                           '$.body', 'AS', 'body', 'TEXT', '$.rank', 'AS', 'rank', 'NUMERIC', 'SORTABLE')
    if response != 'OK':
        raise ValueError(f'FT.CREATE returned {response!r}')
    for start in range(0, len(topics), 256):
        end = min(start + 256, len(topics))
        frames = [encode(('JSON.SET', f'{PREFIX}{i}', '$',
                         json.dumps({'rank': i, 'body': f'{topics[i]} sample document'}, separators=(',', ':'))))
                  for i in range(start, end)]
        for rank, response in enumerate(client.pipeline(frames, window=256), start):
            if response != 'OK':
                raise ValueError(f'JSON.SET document {rank} returned {response!r}')
    deadline = time.monotonic() + 30
    while client.call('FT.SEARCH', INDEX, '*', 'NOCONTENT', 'LIMIT', '0', '0', 'DIALECT', '2') != [len(topics)]:
        if time.monotonic() >= deadline:
            raise ValueError('indexed document count did not reach corpus size')
        time.sleep(0.05)
    checks = {item[1]: item for item in (*search_cases(topics), json_case(0), json_case(len(topics)-1), *requests)}
    for item in checks.values():
        validate(client, item)
    return len(checks)


def percentiles(values):
    ordered = sorted(values)
    return {f'p{percent}': ordered[math.ceil(len(ordered)*percent/100)-1]
            for percent in (50, 95, 99)} if ordered else {}


def measure(client, requests, raw):
    samples = {'search': [], 'json-get': []}
    errors = []
    started = time.perf_counter_ns()
    for number, (kind, args, expected) in enumerate(requests):
        tick = time.perf_counter_ns()
        try:
            reply = client.call(*args)
        except ServerError as error:
            reply = error
        elapsed = time.perf_counter_ns() - tick
        samples[kind].append(elapsed / 1000)
        if reply != expected:
            errors.append({'request': number, 'kind': kind, 'reply': repr(reply)[:4000]})
    seconds = (time.perf_counter_ns() - started) / 1e9
    raw.write_text(json.dumps({'latency_us': samples, 'errors': errors}) + '\n')
    return {'seconds': seconds, 'requests': len(requests), 'errors': len(errors),
            'successful_requests_per_s': (len(requests)-len(errors))/seconds,
            'by_command': {kind: {'requests': len(values), 'latency_us': percentiles(values)}
                           for kind, values in samples.items()}}


@contextmanager
def eski_server(binary, port, directory, cpus):
    server = Server(binary, port, directory, ('--maxmemory', '1gb'), cpus=cpus)
    try:
        yield
    finally:
        code = server.stop()
    if code != 0:
        raise RuntimeError(f'Eski exit status {code}')


def bench(args, target, directory, topics, warmup, requests):
    port = args.port
    server = (eski_server(args.server, port, directory, args.server_cpus) if target == 'eski'
              else reference_server(port, directory, cpus=args.server_cpus, cleanup_timeout=30))
    with server, closing(Conn(port, timeout=10)) as client:
        checked = prepare(client, topics, warmup + requests)
        for item in warmup:
            validate(client, item)
        memory = parse_info(client.call('INFO', 'memory'))
        row = {'target': target, 'checked_requests': checked, 'warmup': len(warmup),
               'used_memory': int(memory['used_memory']), 'used_memory_rss': int(memory['used_memory_rss'])}
        if not args.verify_only:
            row.update(measure(client, requests, directory / 'samples.json'))
    return row


def main():
    parser = argparse.ArgumentParser(description='Compare Search over JSON and JSON.GET on the same seeded corpus')
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--server-cpus', required=True)
    parser.add_argument('--documents', type=int, default=16000)
    parser.add_argument('--seed', type=int, default=8042)
    parser.add_argument('--warmup', type=int, default=500)
    parser.add_argument('--requests', type=int, default=10000)
    parser.add_argument('--rounds', type=int, default=2, help='alternate engine order by round')
    parser.add_argument('--verify-only', action='store_true', help='verify a corpus without timing')
    parser.add_argument('--image', help='local image ID of the reference to start instead of the pinned reference by digest')
    args = parser.parse_args()
    if args.image:
        compare.IMAGE = args.image
    if not 1024 <= args.port <= 65535 or not len(TOPICS) <= args.documents <= 1000000:
        parser.error('invalid TCP port or corpus size')
    if not 0 <= args.warmup <= 1000000 or not 1 <= args.requests <= 1000000 or not 1 <= args.rounds <= 100:
        parser.error('invalid warmup, request count or rounds')
    args.out = args.out.resolve()
    args.out.mkdir(mode=0o700, parents=True, exist_ok=False)
    topics = corpus(args.documents, args.seed)
    requests = planned_requests(topics, args.seed ^ 0x1234, args.requests)
    warmup = planned_requests(topics, args.seed ^ 0x3210, args.warmup)
    rows = []
    summary = {'documents': args.documents, 'seed': args.seed, 'reference': compare.IMAGE,
               'server_cpus': args.server_cpus, 'client_cpus': sorted(os.sched_getaffinity(0)),
               'timed': not args.verify_only, 'rows': rows, 'exit_code': 1}
    report = args.out / 'summary.json'
    try:
        for r in range(1 if args.verify_only else args.rounds):
            targets = ('redis-search', 'eski') if r % 2 == 0 else ('eski', 'redis-search')
            for target in targets:
                directory = args.out / f'round-{r}-{target}'
                rows.append({'round': r, **bench(args, target, directory, topics, warmup, requests)})
                report.write_text(json.dumps(summary, indent=2) + '\n')
        summary['exit_code'] = int(any(row.get('errors', 0) for row in rows))
    finally:
        report.write_text(json.dumps(summary, indent=2) + '\n')
    return summary['exit_code']


if __name__ == '__main__':
    sys.exit(main())
