import argparse
import json
import os
import statistics
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import Server, ServerError, cpu_seconds, encode, sha256

OPERATOR = ['on', 'nopass', '~*', '&*', '+@all', 'owners:*', 'owner-shared', 'owner-operator']
PHASES = ('create', 'hit', 'miss', 'overwrite', 'ladder', 'compact_churn', 'remove')


def phase_frames(phase, users):
    out = []
    for i in range(users):
        h = [b'LABEL', b'AS', b'OWNER', b'b%07d' % i]
        if phase == 'create':
            out.append(encode(h + [b'SET', b'k', b'v']))
        elif phase == 'hit':
            out.append(encode(h + [b'GET', b'k']))
        elif phase == 'miss':
            out.append(encode(h + [b'GET', b'nope']))
        elif phase == 'overwrite':
            out.append(encode(h + [b'SET', b'k', b'w']))
        elif phase == 'ladder':
            out.append(encode(h + [b'MSET', b'a', b'1', b'b', b'2', b'c', b'3', b'd', b'4']))
        elif phase == 'compact_churn':
            out.append(encode(h + [b'DEL', b'b', b'c', b'd']))
            out.append(encode(h + [b'MSET', b'b', b'2', b'c', b'3', b'd', b'4']))
        elif phase == 'remove':
            out.append(encode(h + [b'DEL', b'k', b'a', b'b', b'c', b'd']))
    return out


def run_form(a, compact, workdir):
    server = Server(a.binary, a.port, workdir, ['--owners', 'yes', '--owner-compact', 'yes' if compact else 'no'], cpus=a.cpu)
    out = {}
    try:
        c = server.conn()
        c.call('ACL', 'SETUSER', 'default', *OPERATOR)
        for phase in PHASES:
            frames = phase_frames(phase, a.users)
            cpu0 = cpu_seconds(server.pid)
            t0 = time.perf_counter()
            replies = c.pipeline(frames)
            wall = time.perf_counter() - t0
            cpu = cpu_seconds(server.pid) - cpu0
            errors = sum(1 for r in replies if isinstance(r, ServerError))
            out[phase] = {'server_cpu_s': cpu, 'wall_s': wall, 'commands': len(frames), 'errors': errors}
        c.close()
    finally:
        server.stop()
    out['fatal_log_lines'] = server.fatal_lines()
    return out


def report(path):
    for line in Path(path).read_text().splitlines():
        res = json.loads(line)
        print('# %s users %d rounds %d sha256 %s' % (res['binary'], res['users'], res['rounds'], res['sha256'][:16]))
        print('%-14s %16s %16s %10s' % ('phase', 'compact us/cmd', 'full us/cmd', 'full/compact'))
        for phase in PHASES:
            per = {}
            for form in ('compact', 'full'):
                rows = res[form][phase]
                per[form] = statistics.median(r['server_cpu_s'] * 1e6 / r['commands'] for r in rows)
            ratio = per['full'] / per['compact'] if per['compact'] else float('nan')
            print('%-14s %16.3f %16.3f %10.3f' % (phase, per['compact'], per['full'], ratio))


def main():
    ap = argparse.ArgumentParser(description='The compact owner partition against the fixed form (owner-compact no) in one binary: '
                                 'server CPU and wall time per phase, the forms alternating from round to round.')
    ap.add_argument('--binary', default=str(Path(__file__).resolve().parents[2] / 'bin' / 'eski'))
    ap.add_argument('--port', type=int, default=7652)
    ap.add_argument('--cpu', help='CPU list for the server (taskset)')
    ap.add_argument('--users', type=int, default=300)
    ap.add_argument('--rounds', type=int, default=2)
    ap.add_argument('--workdir')
    ap.add_argument('--out', help='append the JSON result to this file')
    ap.add_argument('--report', metavar='FILE', help='print the median server CPU per command of each phase from FILE and exit')
    a = ap.parse_args()
    if a.report:
        report(a.report)
        return
    if not a.out:
        raise SystemExit('--out is required')
    workdir = Path(a.workdir or Path(os.environ.get('TMPDIR', '/tmp')) / ('eski-owner-forms-%d' % a.port))
    binary = str(Path(a.binary).resolve())
    res = {'binary': binary, 'sha256': sha256(binary), 'users': a.users, 'rounds': a.rounds, 'loadavg_before': open('/proc/loadavg').read().strip()}
    fatal = []
    for r in range(a.rounds):
        for compact in ((True, False) if r % 2 == 0 else (False, True)):
            part = run_form(a, compact, workdir)
            fatal += part.pop('fatal_log_lines')
            form = res.setdefault('compact' if compact else 'full', {})
            for phase, row in part.items():
                form.setdefault(phase, []).append(row)
    res['loadavg_after'] = open('/proc/loadavg').read().strip()
    res['fatal_log_lines'] = fatal
    with open(a.out, 'a') as fh:
        fh.write(json.dumps(res) + '\n')
    errors = sum(row['errors'] for form in ('compact', 'full') for rows in res[form].values() for row in rows)
    print('owner forms: %d users, %d rounds, phases %s, %d errors; results in %s' % (a.users, a.rounds, ' '.join(PHASES), errors, a.out))
    sys.exit(1 if errors or fatal else 0)


main()
