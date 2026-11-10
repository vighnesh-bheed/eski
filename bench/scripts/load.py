import argparse
import hashlib
import json
import os
import statistics
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import Server, ServerError, cpu_seconds, encode, sha256

LOGIN = ['on', 'nopass', '~*', '&*', '+@all']
MODES = {
    'off': [],
    'labelled': ['--label-levels', 'UNCLASSIFIED,CONFIDENTIAL,SECRET', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED',
                 '--user', 'default'] + LOGIN + ['clearance:*'],
    'owners': ['--owners', 'yes', '--user', 'default'] + LOGIN + ['owner:load-user', 'owner-operator'],
}
BODY = "return redis.call('GET', KEYS[1])"
LIBRARY = "#!lua name=loadlib\nredis.register_function('get', function(keys, args) return redis.call('GET', keys[1]) end)"
WORKLOADS = ('eval', 'evalsha', 'fcall', 'eval_ro', 'get')


def frames(workload, n, keys):
    sha = hashlib.sha1(BODY.encode()).hexdigest()
    out = []
    for i in range(n):
        k = 'key:%d' % (i % keys)
        if workload == 'eval':
            out.append(encode(['EVAL', BODY, '1', k]))
        elif workload == 'evalsha':
            out.append(encode(['EVALSHA', sha, '1', k]))
        elif workload == 'eval_ro':
            out.append(encode(['EVAL_RO', BODY, '1', k]))
        elif workload == 'fcall':
            out.append(encode(['FCALL', 'get', '1', k]))
        else:
            out.append(encode(['GET', k]))
    return out


def run_one(a, name, binary, workdir):
    server = Server(binary, a.port, workdir, MODES[a.mode] + a.extra.split(), cpus=a.cpu)
    out = {}
    try:
        c = server.conn()
        setup = [encode(['SET', 'key:%d' % i, 'value:%d' % i]) for i in range(a.keys)]
        setup += [encode(['SCRIPT', 'LOAD', BODY]), encode(['FUNCTION', 'LOAD', 'REPLACE', LIBRARY])]
        bad = [r for r in c.pipeline(setup) if isinstance(r, ServerError)]
        if bad:
            raise SystemExit('%s setup failed: %s' % (name, bad[0]))
        for w in a.workloads.split(','):
            batch = frames(w, a.commands, a.keys)
            c.pipeline(batch[:min(len(batch), 1000)])
            cpu0 = cpu_seconds(server.pid)
            t0 = time.perf_counter()
            replies = c.pipeline(batch, window=a.pipeline)
            wall = time.perf_counter() - t0
            cpu = cpu_seconds(server.pid) - cpu0
            errors = [r for r in replies if isinstance(r, ServerError)]
            wrong = sum(1 for i, r in enumerate(replies) if not isinstance(r, ServerError) and r != b'value:%d' % (i % a.keys))
            out[w] = {'commands': len(batch), 'server_cpu_s': cpu, 'wall_s': wall, 'errors': len(errors), 'wrong_replies': wrong,
                      'error_sample': str(errors[0]) if errors else None}
        c.close()
    finally:
        server.stop()
    out['fatal_log_lines'] = server.fatal_lines()
    return out


def report(path):
    for line in Path(path).read_text().splitlines():
        res = json.loads(line)
        names = [b['name'] for b in res['binaries']]
        base = names[0]
        print('# mode %s, %d commands per workload, rounds %d' % (res['mode'], res['commands'], res['rounds']))
        print('%-10s %18s  %s' % ('workload', base + ' us/cmd', '  '.join('%-18s' % (n + '/' + base) for n in names[1:])))
        for w in res['workloads']:
            med = {n: statistics.median(r['server_cpu_s'] * 1e6 / r['commands'] for r in res['runs'][n][w]) for n in names}
            cells = ['%.3f' % (med[n] / med[base]) if med[base] else '-' for n in names[1:]]
            print('%-10s %18.3f  %s' % (w, med[base], '  '.join('%-18s' % x for x in cells)))


def main():
    ap = argparse.ArgumentParser(description='Script load generator: EVAL, EVALSHA, EVAL_RO and FCALL of a one-key read, with GET as '
                                 'the control, pipelined against one or more binaries in alternating rounds; records server CPU '
                                 'and wall time per workload.')
    ap.add_argument('--binary', action='append', help='NAME=PATH or PATH; repeat to compare binaries (default: bin/eski)')
    ap.add_argument('--mode', choices=sorted(MODES), default='off')
    ap.add_argument('--extra', default='', help='more server options, split on spaces')
    ap.add_argument('--port', type=int, default=7653)
    ap.add_argument('--cpu', help='CPU list for the server (taskset)')
    ap.add_argument('--keys', type=int, default=1000)
    ap.add_argument('--commands', type=int, default=2000)
    ap.add_argument('--pipeline', type=int, default=64)
    ap.add_argument('--rounds', type=int, default=1)
    ap.add_argument('--workloads', default=','.join(WORKLOADS))
    ap.add_argument('--workdir')
    ap.add_argument('--out')
    ap.add_argument('--report', metavar='FILE', help='print the median server CPU per command from FILE and exit')
    a = ap.parse_args()
    if a.report:
        report(a.report)
        return
    if not a.out:
        raise SystemExit('--out is required')
    for w in a.workloads.split(','):
        if w not in WORKLOADS:
            raise SystemExit('unknown workload %s' % w)
    specs = a.binary or [str(Path(__file__).resolve().parents[2] / 'bin' / 'eski')]
    binaries = []
    for k, spec in enumerate(specs):
        name, sep, path = spec.partition('=')
        if not sep:
            name, path = ('A', 'B', 'C', 'D')[k] if k < 4 else 'bin%d' % k, spec
        binaries.append({'name': name, 'path': str(Path(path).resolve()), 'sha256': sha256(path)})
    workdir = Path(a.workdir or Path(os.environ.get('TMPDIR', '/tmp')) / ('eski-script-load-%d' % a.port))
    res = {'mode': a.mode, 'extra': a.extra, 'binaries': binaries, 'commands': a.commands, 'pipeline': a.pipeline, 'rounds': a.rounds,
           'workloads': a.workloads.split(','), 'runs': {b['name']: {} for b in binaries}, 'loadavg_before': open('/proc/loadavg').read().strip()}
    fatal = []
    problems = 0
    for r in range(a.rounds):
        for j in range(len(binaries)):
            b = binaries[(r + j) % len(binaries)]
            part = run_one(a, b['name'], b['path'], workdir)
            fatal += part.pop('fatal_log_lines')
            for w, row in part.items():
                res['runs'][b['name']].setdefault(w, []).append(row)
                problems += row['errors'] + row['wrong_replies']
    res['loadavg_after'] = open('/proc/loadavg').read().strip()
    res['fatal_log_lines'] = fatal
    with open(a.out, 'a') as fh:
        fh.write(json.dumps(res) + '\n')
    print('script load: mode %s, %d binaries, %d rounds, workloads %s, %d errors or wrong replies; results in %s' % (
        a.mode, len(binaries), a.rounds, a.workloads, problems, a.out))
    sys.exit(1 if problems or fatal else 0)


main()
