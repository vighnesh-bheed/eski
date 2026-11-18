import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import exam_metrics as metrics


def interrupted(signum, frame):
    raise KeyboardInterrupt


def measurement_roles(server_cpus, client_cpus, control_cpus):
    server = sorted(metrics.cpu_set(server_cpus))
    client = sorted(metrics.cpu_set(client_cpus))
    control = sorted(metrics.cpu_set(control_cpus))
    if len(client) < 2:
        raise SystemExit('the noise floor needs at least two client CPUs')
    if set(control) & (set(server) | set(client)):
        raise SystemExit('the controller CPUs %s overlap the server or client role' % control_cpus)
    if not set(control) <= os.sched_getaffinity(0):
        raise SystemExit('the controller CPUs %s are not all permitted by this process\'s affinity' % control_cpus)
    control = ','.join(map(str, control))
    if len(server) >= 2 and len(client) >= 4:
        return dict(mode='concurrent', server=str(server[0]), server_b=str(server[1]), client='%d,%d' % tuple(client[:2]),
                    client_b='%d,%d' % tuple(client[2:4]), cluster='%d,%d' % (server[0], server[1]), control=control)
    return dict(mode='sequential', server=str(server[0]), server_b=str(server[0]), client='%d,%d' % tuple(client[:2]),
                client_b='%d,%d' % tuple(client[:2]), cluster=str(server[0]), control=control)


def main():
    parser = argparse.ArgumentParser(description='Measure the noise floor of bench/ab.py on this host: an A/A session of one binary against itself, '
                                     'run concurrently with the two servers swapped every round when the roles give two server CPUs and four client CPUs, sequential otherwise, '
                                     'and the floor record bench/ab_report.py derives from it, so a later A/B session knows the smallest difference '
                                     'it can believe on this hardware.')
    parser.add_argument('--binary', required=True)
    parser.add_argument('--server-cpus', required=True)
    parser.add_argument('--client-cpus', required=True)
    parser.add_argument('--control-cpus', required=True, help='CPUs outside both roles for the session controller')
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--memtier-image', required=True)
    parser.add_argument('--rounds', type=int, default=8)
    parser.add_argument('--seconds', type=int, default=20)
    parser.add_argument('--warmup', type=int, default=5)
    parser.add_argument('--workloads', help='comma separated workloads of bench/ab.py; its default set when omitted')
    parser.add_argument('--out', required=True, help='new directory for the session')
    parser.add_argument('--result', required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, interrupted)
    roles = measurement_roles(args.server_cpus, args.client_cpus, args.control_cpus)
    out = Path(args.out).resolve()
    result = dict(schema='eski-baseline-noise-floor-v1', roles=roles, rounds=args.rounds, seconds=args.seconds, warmup=args.warmup, exit_code=1)
    try:
        command = [sys.executable, '-IB', str(HERE / 'ab.py'), '--a', args.binary, '--b', args.binary, '--label', 'aa-host', '--out', str(out),
                   '--rounds', str(args.rounds), '--seconds', str(args.seconds), '--warmup', str(args.warmup), '--mode', roles['mode'],
                   '--server-cpus', roles['server'], '--server-cpus-b', roles['server_b'], '--client-cpus', roles['client'],
                   '--client-cpus-b', roles['client_b'], '--cluster-cpus', roles['cluster'], '--control-cpu', roles['control'],
                   '--port', str(args.port), '--memtier-image', args.memtier_image] + (['--workloads', args.workloads] if args.workloads else [])
        result['command'] = command
        started = time.monotonic()
        done = subprocess.run(command, capture_output=True, text=True)
        result.update(session_seconds=time.monotonic() - started, session_exit=done.returncode, session_stderr=done.stderr[-2000:])
        session = out / 'aa-host'
        floor = out / 'floor.json'
        report = subprocess.run([sys.executable, '-IB', str(HERE / 'ab_report.py'), str(session), '--no-floor', '--write-floor', str(floor)],
                                capture_output=True, text=True)
        (out / 'report.txt').write_text(report.stdout + report.stderr)
        result['report_exit'] = report.returncode
        if (session / 'summary.json').exists():
            result['summary'] = json.loads((session / 'summary.json').read_text()).get('summary')
        if floor.exists():
            result['floor'] = json.loads(floor.read_text())
        result['exit_code'] = 0 if done.returncode == 0 and report.returncode == 0 and floor.exists() else 1
    finally:
        Path(args.result).write_text(json.dumps(result, indent=1) + '\n')
    return result['exit_code']


if __name__ == '__main__':
    sys.exit(main())
