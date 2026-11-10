import argparse
import hashlib
import json
import os
import shutil
import statistics
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PROBE = HERE / 'store'
COPIED = ('src', 'third_party', 'tools', '.build')


def odin():
    return os.environ.get('ODIN') or shutil.which('odin') or str(Path.home() / 'odin' / 'current' / 'odin')


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def relayout(src):
    files = sorted(p for p in src.glob('*.odin') if not p.name.endswith('_test.odin'))
    for k, p in enumerate(reversed(files)):
        p.rename(p.with_name('%s%03d_%s' % (chr(ord('z') - k % 26), k, p.name)))


def build(args):
    work = Path(args.work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    trees = []
    for spec in args.tree:
        name, _, path = spec.partition('=')
        if not name or not path:
            raise SystemExit('--tree takes NAME=PATH')
        trees.append((name, Path(path).resolve(), False))
        if name in args.control:
            trees.append((name + '-layout', Path(path).resolve(), True))
    builds = []
    for index, (name, path, layout) in enumerate(trees):
        if not (path / 'src').is_dir():
            raise SystemExit('%s has no src directory' % path)
        dest = work / ('t%d' % index)
        if dest.exists():
            shutil.rmtree(dest)
        dest.mkdir()
        for part in COPIED:
            if (path / part).exists():
                shutil.copytree(path / part, dest / part, symlinks=True)
        if layout:
            relayout(dest / 'src')
        shutil.copytree(PROBE, dest / 'bench' / 'micro' / 'store')
        log = open(dest / 'build.log', 'w')
        for step in (['bash', 'tools/build_lua.sh', 'release'], ['bash', 'tools/build_diagnostics.sh', 'release'],
                     [odin(), 'build', 'bench/micro/store', '-o:speed', '-out:store-micro']):
            if subprocess.run(step, cwd=dest, stdout=log, stderr=subprocess.STDOUT).returncode != 0:
                raise SystemExit('build of %s failed, see %s' % (name, dest / 'build.log'))
        log.close()
        binary = dest / 'store-micro'
        builds.append({'name': name, 'tree': str(path), 'layout_control': layout, 'binary': str(binary), 'sha256': sha256(binary)})
        print('built %s from %s%s: %s' % (name, path, ' (layout control)' if layout else '', binary))
    (work / 'builds.json').write_text(json.dumps(builds, indent=1) + '\n')


def run(args):
    work = Path(args.work).resolve()
    builds = json.loads((work / 'builds.json').read_text())
    with open(args.out, 'a') as out:
        out.write(json.dumps({'meta': 'start', 'builds': builds, 'keys': args.keys, 'reps': args.reps, 'rounds': args.rounds,
                              'cpu': args.cpu, 'loadavg': open('/proc/loadavg').read().strip()}) + '\n')
        for r in range(args.rounds):
            for j in range(len(builds)):
                b = builds[(r + j) % len(builds)]
                cmd = [b['binary'], str(args.keys), str(args.reps), args.families]
                if args.cpu:
                    cmd = ['taskset', '-c', args.cpu] + cmd
                done = subprocess.run(cmd, capture_output=True, text=True)
                if done.returncode != 0:
                    raise SystemExit('%s failed: %s' % (b['name'], done.stderr.strip()))
                for line in done.stdout.splitlines():
                    out.write(json.dumps({'round': r, 'build': b['name'], 'loadavg': open('/proc/loadavg').read().split()[0],
                                          'data': json.loads(line)}) + '\n')
        out.write(json.dumps({'meta': 'end', 'loadavg': open('/proc/loadavg').read().strip()}) + '\n')
    print('store micro: %d rounds of %d builds at %d keys written to %s' % (args.rounds, len(builds), args.keys, args.out))


def quantile(xs, p):
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def report(args):
    rows = [json.loads(line) for line in Path(args.file).read_text().splitlines()]
    data = [r for r in rows if 'data' in r]
    per = {}
    for r in data:
        d = r['data']
        for phase, xs in d.items():
            if phase in ('family', 'keys'):
                continue
            per.setdefault((d['family'], d['keys'], phase), {}).setdefault(r['round'], {})[r['build']] = statistics.median(xs[args.drop:] or xs)
    names = sorted({r['build'] for r in data})
    base = args.base or names[0]
    others = [n for n in names if n != base]
    print('%-6s %-8s %-10s %10s  %s' % ('family', 'keys', 'phase', base + ' ns', '  '.join('%-24s' % (n + '/' + base) for n in others)))
    for (fam, keys, phase), rounds in sorted(per.items()):
        b = [v[base] for v in rounds.values() if base in v]
        cells = []
        for n in others:
            ratio = [v[n] / v[base] for v in rounds.values() if n in v and base in v and v[base]]
            cells.append('%.3f [%.3f..%.3f]' % (statistics.median(ratio), quantile(ratio, 0.1), quantile(ratio, 0.9)) if ratio else '-')
        print('%-6s %-8d %-10s %10.2f  %s' % (fam, keys, phase, statistics.median(b) if b else float('nan'), '  '.join('%-24s' % c for c in cells)))


def main():
    ap = argparse.ArgumentParser(description='In-process store microbenchmark: the real store and table code of one or more source '
                                 'trees, driven without the network, in interleaved rounds with an identical-code layout control.')
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('build', help='copy each tree, add the probe and build it')
    p.add_argument('--tree', action='append', required=True, help='NAME=PATH of a source tree (a checkout with src, third_party and tools)')
    p.add_argument('--control', action='append', default=[], help='NAME of a tree to build a second time with its files laid out differently')
    p.add_argument('--work', required=True)
    p = sub.add_parser('run', help='run every build in interleaved rounds')
    p.add_argument('--work', required=True)
    p.add_argument('--keys', type=int, default=20000)
    p.add_argument('--reps', type=int, default=5)
    p.add_argument('--rounds', type=int, default=8)
    p.add_argument('--families', default='short,long')
    p.add_argument('--cpu', help='CPU for every run (taskset)')
    p.add_argument('--out', required=True)
    p = sub.add_parser('report', help='per phase, the base build in nanoseconds per operation and every other build as a ratio')
    p.add_argument('file')
    p.add_argument('--base')
    p.add_argument('--drop', type=int, default=1, help='repetitions to drop at the start of each run')
    args = ap.parse_args()
    {'build': build, 'run': run, 'report': report}[args.cmd](args)


if __name__ == '__main__':
    main()
