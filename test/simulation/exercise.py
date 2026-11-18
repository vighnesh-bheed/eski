import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
MAX_SEED = (1 << 64) - 1
CASES = ('disk', 'restart', 'network', 'labels', 'owners')


def bounded(low, high):
    def check(text):
        try:
            value = int(text)
        except ValueError as error:
            raise argparse.ArgumentTypeError('expected an integer') from error
        if not low <= value <= high:
            raise argparse.ArgumentTypeError(f'expected a value between {low} and {high}')
        return value
    return check


def port_range(text):
    try:
        first, last = map(int, text.split('-'))
    except ValueError as error:
        raise argparse.ArgumentTypeError('expected FIRST-LAST') from error
    if not 1 <= first <= last <= 65535:
        raise argparse.ArgumentTypeError('expected an ordered range of valid TCP ports')
    return text


def build(output):
    override = os.environ.get('ODIN')
    compiler = shutil.which(override or 'odin')
    if override is None and compiler is None:
        compiler = shutil.which(Path.home() / 'odin/current/odin')
    if compiler is None:
        raise ValueError('Odin compiler unavailable. Set ODIN or put odin on PATH.')
    output.parent.mkdir(parents=True, exist_ok=True)
    for script in ('build_lua.sh', 'build_diagnostics.sh'):
        subprocess.run(['bash', ROOT / 'tools' / script, 'release'], cwd=ROOT, check=True)
    subprocess.run([Path(compiler).absolute(), 'build', 'tools/simulation', '-define:ESKI_SIMULATION=true',
                    '-vet', '-strict-style', '-debug', '-thread-count:2', f'-out:{output}'], cwd=ROOT, check=True)


def binary_metadata(binary):
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f'missing executable {binary}')
    with binary.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    return {'binary': str(binary), 'sha256': digest, 'platform': platform.platform(),
            'python': platform.python_version(), 'available_cpus': sorted(os.sched_getaffinity(0))}


def save(out, summary):
    temporary = out / 'summary.tmp'
    temporary.write_text(json.dumps(summary, indent=2) + '\n')
    temporary.replace(out / 'summary.json')


def virtual_case(args, case, seed, variant):
    trace = args.out / f'{seed}-{case}-{variant}.trace'
    stderr = trace.with_suffix('.stderr')
    command = [args.binary, case, str(seed), str(args.steps), variant]
    try:
        with trace.open('wb') as output, stderr.open('wb') as errors:
            result = subprocess.run(command, stdout=output, stderr=errors, timeout=args.timeout)
        with trace.open('rb') as output:
            observations = []
            last = b''
            for line in output:
                if line.startswith(b'OBS '):
                    observations.append(line)
                last = line
        expected = f'PASS case={case} seed={seed}'.encode()
        if result.returncode or last.rstrip().split(b' ', 1)[-1] != expected:
            raise ValueError(f'worker exit {result.returncode} with final event {last[-1000:]!r}')
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f'{case} seed {seed} variant {variant}, trace {trace.name}: {error}') from error
    return observations


def virtual(args, summary):
    summary.update(first_seed=args.first_seed, seeds=args.seeds, steps=args.steps, worker_timeout=args.timeout,
                   completed_seeds=0)
    if args.first_seed + args.seeds - 1 > MAX_SEED:
        raise ValueError('seed range exceeds the unsigned 64-bit limit')
    save(args.out, summary)
    if args.measure:
        started = time.monotonic()
    for seed in range(args.first_seed, args.first_seed + args.seeds):
        for case in CASES:
            base = virtual_case(args, case, seed, 'base')
            if case in ('labels', 'owners'):
                hidden = virtual_case(args, case, seed, 'hidden')
                if len(base) != args.steps or base != hidden:
                    raise AssertionError(f'{case} seed {seed} visible replies differ across twins or are incomplete')
        summary['completed_seeds'] += 1
        save(args.out, summary)
    if args.measure:
        seconds = time.monotonic() - started
        iterations = args.seeds * args.steps * 5
        summary['measurement'] = {'seconds': seconds, 'model_iterations': iterations,
                                  'model_iterations_per_second': iterations / seconds}


def check_result(client, log, expected, *command):
    print(f'command={command!r} expected={expected!r}', file=log)
    got = client.call(*command)
    if got != expected:
        raise AssertionError(f'{command!r} returned {got!r}, expected {expected!r}')


def native(args, summary):
    sys.path.insert(0, str(ROOT / 'test/compatibility'))
    import scoped_log

    if args.ports:
        scoped_log.use_ports(args.ports)
    directory = args.out / 'data'
    directory.mkdir()
    summary.update(cycles=args.cycles, transactions_per_cycle=args.transactions, ports=args.ports,
                   appendfsync='always', recovered_cycles=0)
    server = scoped_log.lf.Run(args.binary, directory, ('--appendonly', 'yes', '--appendfsync', 'always',
                               '--save', '', '--auto-aof-rewrite-percentage', '0'))
    total = 0
    with (args.out / 'native.trace').open('w', buffering=1) as trace:
        try:
            for generation in range(args.cycles + 1):
                print(f'start generation={generation} committed={total}', file=trace)
                code, startup = server.start(timeout=10)
                if code is not None:
                    raise RuntimeError(f'generation {generation} startup exit {code}: {startup[-1000:]}')
                client = server.client()
                check_result(client, trace, 'OK', 'SELECT', '2')
                check_result(client, trace, None, 'GET', 'uncommitted')
                if generation == 0:
                    check_result(client, trace, 'OK', 'SET', 'status', 'ready')
                check_result(client, trace, b'ready', 'GET', 'status')
                check_result(client, trace, str(total).encode() if total else None, 'GET', 'counter')
                check_result(client, trace, str(total).encode() if total else None, 'GET', 'last-transaction')
                check_result(client, trace, 'OK', 'SELECT', '0')
                check_result(client, trace, None, 'GET', 'status')
                check_result(client, trace, 'OK', 'SELECT', '2')
                if generation > 0:
                    summary['recovered_cycles'] += 1
                    save(args.out, summary)
                if generation == args.cycles:
                    break
                for _ in range(args.transactions):
                    total += 1
                    check_result(client, trace, 'OK', 'MULTI')
                    check_result(client, trace, 'QUEUED', 'INCR', 'counter')
                    check_result(client, trace, 'QUEUED', 'SET', 'last-transaction', str(total))
                    check_result(client, trace, [total, 'OK'], 'EXEC')
                check_result(client, trace, 'OK', 'MULTI')
                check_result(client, trace, 'QUEUED', 'SET', 'uncommitted', 'pending')
                print(f'sigkill generation={generation} committed={total}', file=trace)
                server.process.kill()
                if server.stop(signal.SIGKILL, timeout=5) != -signal.SIGKILL:
                    raise AssertionError(f'generation {generation} did not exit via SIGKILL')
            if server.stop(timeout=10) != 0:
                raise AssertionError('final generation did not shut down cleanly')
        finally:
            if server.process is not None:
                server.stop(signal.SIGKILL, timeout=5)
    summary['acknowledged_transactions'] = total


def parser():
    main = argparse.ArgumentParser(description='Build and run deterministic simulation or native AOF crash checks')
    modes = main.add_subparsers(dest='mode', required=True)
    builder = modes.add_parser('build', help='build the isolated simulation worker')
    builder.add_argument('--output', type=Path, required=True)
    virtual_parser = modes.add_parser('virtual', help='save seed traces and compare visible replies across twins')
    virtual_parser.add_argument('--first-seed', type=bounded(0, MAX_SEED), default=8)
    virtual_parser.add_argument('--seeds', type=bounded(1, 1000000), default=1)
    virtual_parser.add_argument('--steps', type=bounded(1, 4096), default=4)
    virtual_parser.add_argument('--timeout', type=bounded(1, 3600), default=90, help='seconds per worker')
    virtual_parser.add_argument('--measure', action='store_true', help='record end-to-end model iteration rate')
    native_parser = modes.add_parser('native', help='kill and restart a stock Eski build with synthetic data')
    native_parser.add_argument('--cycles', type=bounded(1, 1000), default=1)
    native_parser.add_argument('--transactions', type=bounded(1, 100000), default=3, help='per crash cycle')
    native_parser.add_argument('--ports', type=port_range, help='inclusive loopback port range')
    for mode in (virtual_parser, native_parser):
        mode.add_argument('--binary', type=Path, required=True)
        mode.add_argument('--out', type=Path, required=True, help='new directory for evidence')
    return main


def main():
    args = parser().parse_args()
    if args.mode == 'build':
        build(args.output.resolve())
        return 0
    args.binary = args.binary.resolve()
    args.out = args.out.resolve()
    args.out.mkdir(mode=0o700, parents=True, exist_ok=False)
    summary = {'mode': args.mode, 'exit_code': None}
    try:
        summary.update(binary_metadata(args.binary))
        if args.mode == 'virtual':
            virtual(args, summary)
        else:
            native(args, summary)
        summary['exit_code'] = 0
    except Exception as error:
        summary.update(exit_code=1, error=str(error))
        print(error, file=sys.stderr)
    except KeyboardInterrupt:
        summary.update(exit_code=130, error='interrupted')
    finally:
        save(args.out, summary)
    print(f'{args.mode} exit {summary["exit_code"]}, summary {args.out / "summary.json"}')
    return summary['exit_code']


if __name__ == '__main__':
    sys.exit(main())
