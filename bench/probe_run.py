import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


def interrupted(signum, frame):
    raise KeyboardInterrupt


def odin():
    return os.environ.get('ODIN') or shutil.which('odin') or str(Path.home() / 'odin' / 'current' / 'odin')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def lines(text):
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('{'):
            try:
                rows.append(json.loads(line))
            except ValueError:
                rows.append(dict(unparsed=line[:500]))
    return rows


def owners_vset(args, result):
    work = Path(args.work).resolve()
    work.mkdir(parents=True)
    binary = work / 'vset-owners'
    started = time.monotonic()
    with open(work / 'build.log', 'wb') as log:
        for step in (['bash', 'tools/build_lua.sh', 'release'], ['bash', 'tools/build_diagnostics.sh', 'release'],
                     [odin(), 'build', 'bench/owners/vset', '-o:speed', '-out:' + str(binary)]):
            if subprocess.run(step, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT).returncode:
                raise SystemExit('build step %s failed; see %s' % (step[:3], work / 'build.log'))
    result.update(build_seconds=time.monotonic() - started, binary_sha256=sha(binary))
    command = [str(binary), 'all', str(args.owners), str(args.graph), str(args.rounds)]
    if args.cpu:
        command = ['taskset', '-c', args.cpu] + command
    done = subprocess.run(command, capture_output=True, text=True, timeout=args.timeout)
    (work / 'probe.out').write_text(done.stdout)
    (work / 'probe.err').write_text(done.stderr)
    result.update(command=command, returncode=done.returncode, probes=lines(done.stdout))
    return done.returncode == 0 and bool(result['probes'])


def store(args, result):
    work = Path(args.work).resolve()
    tool = [sys.executable, '-IB', str(HERE / 'micro/store.py')]
    started = time.monotonic()
    with open(Path(args.out).with_suffix('.build.log'), 'wb') as log:
        built = subprocess.run(tool + ['build', '--tree', 'A=' + str(ROOT), '--control', 'A', '--work', str(work)], stdout=log, stderr=subprocess.STDOUT)
    result['build_seconds'] = time.monotonic() - started
    if built.returncode:
        raise SystemExit('store.py build failed')
    rows = work / 'rows.jsonl'
    command = tool + ['run', '--work', str(work), '--keys', str(args.keys), '--reps', str(args.reps), '--rounds', str(args.rounds), '--out', str(rows)]
    if args.cpu:
        command += ['--cpu', args.cpu]
    done = subprocess.run(command, capture_output=True, text=True, timeout=args.timeout)
    result.update(command=command, returncode=done.returncode, builds=json.loads((work / 'builds.json').read_text()),
                  rows=lines(rows.read_text()) if rows.exists() else [], stderr=done.stderr[-2000:])
    report = subprocess.run(tool + ['report', str(rows), '--base', 'A'], capture_output=True, text=True, timeout=300) if rows.exists() else None
    result['report'] = report.stdout if report else None
    return done.returncode == 0 and bool(result['rows'])


def main():
    parser = argparse.ArgumentParser(description='Build one of the in-process Odin probes from this checkout and run it unattended, writing its '
                                     'JSON lines into one JSON result: owners-vset is bench/owners/vset (view open, merged VSIM and '
                                     'compact-block graduation with many owners), store is bench/micro/store.py with its layout control.')
    parser.add_argument('probe', choices=('owners-vset', 'store'))
    parser.add_argument('--work', required=True, help='new directory for the build and the raw output')
    parser.add_argument('--out', required=True)
    parser.add_argument('--cpu')
    parser.add_argument('--owners', type=int, default=300000)
    parser.add_argument('--graph', type=int, default=50000)
    parser.add_argument('--rounds', type=int, default=4000)
    parser.add_argument('--keys', type=int, default=20000)
    parser.add_argument('--reps', type=int, default=5)
    parser.add_argument('--timeout', type=int, default=86400)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, interrupted)
    result = dict(schema='eski-baseline-probe-v1', probe=args.probe, exit_code=1, started_at=time.time())
    try:
        ok = (owners_vset if args.probe == 'owners-vset' else store)(args, result)
        result['exit_code'] = 0 if ok else 1
    finally:
        result['finished_at'] = time.time()
        Path(args.out).write_text(json.dumps(result, indent=1) + '\n')
    return result['exit_code']


if __name__ == '__main__':
    sys.exit(main())
