import argparse
import hashlib
import json
import os
import platform
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import exam_metrics as metrics
from harness import GUARD_DIR, MEMORY_LOG, Server

SCHEMA = 'eski-baseline-step-v1'
NOT_QUALIFYING = 'rehearsal size on a machine that is not the measurement host; the figures prove the code path and are not read'


def sha(path):
    value = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            value.update(block)
    return value.hexdigest()


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def filesystem(path):
    best, kind = '', None
    target = str(Path(path).resolve())
    for line in (read('/proc/self/mountinfo') or '').splitlines():
        left, _, right = line.partition(' - ')
        fields = left.split()
        if len(fields) > 4 and (target == fields[4] or target.startswith(fields[4].rstrip('/') + '/')) and len(fields[4]) >= len(best):
            best, kind = fields[4], right.split()[0] if right.split() else None
    return dict(mount=best, type=kind)


def host_record(out, server_cpus, client_cpus):
    cpus = sorted(metrics.cpu_set(server_cpus) | metrics.cpu_set(client_cpus)) if server_cpus and client_cpus else []
    policy = metrics.frequency_policy(cpus) if cpus else {}
    microcode = sorted({line.split(':', 1)[1].strip() for line in (read('/proc/cpuinfo') or '').splitlines() if line.startswith('microcode')})
    model = next((line.split(':', 1)[1].strip() for line in (read('/proc/cpuinfo') or '').splitlines() if line.startswith('model name')), None)
    memory = {line.split(':')[0]: line.split(':')[1].strip() for line in (read('/proc/meminfo') or '').splitlines()[:3] if ':' in line}
    try:
        stat = os.statvfs(out)
        free = stat.f_bavail * stat.f_frsize
    except OSError:
        free = None
    return dict(time=time.time(), kernel=platform.release(), cpu_model=model, microcode=microcode, cmdline=read('/proc/cmdline'),
                smt=read('/sys/devices/system/cpu/smt/control'), thp=read('/sys/kernel/mm/transparent_hugepage/enabled'),
                thp_defrag=read('/sys/kernel/mm/transparent_hugepage/defrag'), no_turbo=read('/sys/devices/system/cpu/intel_pstate/no_turbo'),
                loadavg=read('/proc/loadavg'), memory=memory, output_filesystem=filesystem(out), output_free_bytes=free,
                server_cpus=server_cpus, client_cpus=client_cpus, frequency_policy=policy, affinity=sorted(os.sched_getaffinity(0)))


class Sampler(threading.Thread):
    def __init__(self, path, seconds, roles):
        super().__init__(daemon=True)
        self.path, self.seconds, self.roles = path, seconds, roles
        self.stop_event = threading.Event()
        self.summary = dict(samples=0, max_package_c=None, throttle_events=0, external_on_role_cpus=[], min_idle_pct={})

    def run(self):
        reader = metrics.Reader()
        while True:
            try:
                sample = reader.sample()
            except OSError:
                sample = None
            if sample is not None:
                self.note(sample)
                metrics.append_json(self.path, dict(wall_time=sample['wall_time'], idle_pct=sample['idle_pct'], package=sample['package'],
                                                    throttle_delta=sample['throttle_delta'], frequency_khz=sample['frequency_khz'],
                                                    external_cpu=[dict(pid=p['pid'], comm=p['comm'], processor=p.get('processor'), cpu_cores=p.get('cpu_cores'),
                                                                       kthread=p.get('kthread')) for p in sample['external_cpu']],
                                                    loadavg=sample['loadavg'], cpu_share_pct={k: v for k, v in sample['cpu_share_pct'].items() if k in self.role_keys()}))
            if self.stop_event.wait(self.seconds):
                break

    def role_keys(self):
        return {'cpu%d' % c for cpus in self.roles.values() for c in cpus}

    def note(self, sample):
        summary = self.summary
        summary['samples'] += 1
        celsius = (sample.get('package') or {}).get('celsius')
        if celsius is not None:
            summary['max_package_c'] = max(summary['max_package_c'] or celsius, celsius)
        summary['throttle_events'] += sum(v for v in (sample.get('throttle_delta') or {}).values() if isinstance(v, (int, float)))
        for role, cpus in self.roles.items():
            for cpu in cpus:
                value = (sample.get('idle_pct') or {}).get('cpu%d' % cpu)
                if value is not None:
                    key = '%s:cpu%d' % (role, cpu)
                    summary['min_idle_pct'][key] = min(summary['min_idle_pct'].get(key, 100.0), round(value, 1))
        all_cpus = {c for cpus in self.roles.values() for c in cpus}
        for proc in sample.get('external_cpu') or []:
            if proc.get('processor') in all_cpus and (proc.get('cpu_cores') or 0) >= .1 and len(summary['external_on_role_cpus']) < 200:
                summary['external_on_role_cpus'].append(dict(comm=proc['comm'], pid=proc['pid'], cpu=proc.get('processor'), cores=round(proc['cpu_cores'], 3)))

    def finish(self):
        self.stop_event.set()
        self.join(timeout=30)
        return self.summary


def inventory(folder):
    files = {}
    for path in sorted(Path(folder).rglob('*')):
        if path.is_file() and not path.is_symlink():
            files[str(path.relative_to(folder))] = dict(bytes=path.stat().st_size, sha256=sha(path))
    return files


def substitute(argv, values):
    return [part.format(**values) if '{' in part else part for part in argv]


def memory_rows(path):
    rows = []
    if Path(path).is_file():
        for line in Path(path).read_text().splitlines():
            try:
                rows.append(json.loads(line))
            except ValueError:
                rows.append(dict(malformed=line[:200]))
    return rows


def collected(folder, patterns):
    found = {}
    for pattern in patterns:
        for path in sorted(Path(folder).glob(pattern)):
            name = str(path.relative_to(folder))
            try:
                text = path.read_text()
            except OSError as error:
                found[name] = dict(unreadable=str(error)[:200])
                continue
            try:
                found[name] = json.loads(text)
            except ValueError:
                try:
                    found[name] = dict(json_lines=[json.loads(line) for line in text.splitlines() if line.strip()])
                except ValueError as error:
                    found[name] = dict(unreadable=str(error)[:200])
    return found


def interrupted(signum, frame):
    raise KeyboardInterrupt


def start_guard(folder):
    guard = folder / 'guard'
    guard.mkdir()
    read_end, write_end = os.pipe()
    watcher = subprocess.Popen([sys.executable, '-IB', str(HERE / 'guard.py'), str(guard), str(folder / 'guard.log')], stdin=read_end,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, cwd='/')
    os.close(read_end)
    return guard, watcher, write_end


def finish_guard(guard, watcher, write_end, message):
    leaked = sorted(path.name for path in guard.iterdir() if not path.name.startswith('.'))
    os.write(write_end, message.encode())
    os.close(write_end)
    try:
        watcher.wait(timeout=300)
    except subprocess.TimeoutExpired:
        leaked.append('guard watcher still running')
    return leaked


def run(args, folder):
    roles = {'server': metrics.cpu_set(args.server_cpus) if args.server_cpus else set(),
             'client': metrics.cpu_set(args.client_cpus) if args.client_cpus else set()}
    result = dict(schema=SCHEMA, name=args.name, area=args.area, profile=args.profile, qualifying=args.profile == 'full',
                  note=None if args.profile == 'full' else NOT_QUALIFYING, argv=args.command, repetitions=[], exit_code=1,
                  host_start=host_record(folder, args.server_cpus, args.client_cpus), started_at=time.time())
    artifact = Path(args.out) / args.artifact
    guard, watcher, write_end = start_guard(folder)
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    environment[GUARD_DIR] = str(guard)
    code = 1
    message = 'finished'
    try:
        for rep in range(1, args.repeat + 1):
            directory = folder / ('rep-%02d' % rep)
            directory.mkdir()
            (directory / 'tmp').mkdir()
            values = dict(dir=str(directory), new=str(directory / 'data'), rep=rep, json=str(directory / 'result.json'),
                          port=args.eski_port or 0, odd=rep % 2)
            argv = substitute(args.command, values)
            env = dict(environment, TMPDIR=str(directory / 'tmp'))
            env[MEMORY_LOG] = str(directory / 'memory.jsonl')
            row = dict(rep=rep, argv=argv, started_at=time.time())
            result['repetitions'].append(row)
            server = None
            sampler = Sampler(directory / 'telemetry.jsonl', args.sample_seconds, roles) if args.sample_seconds > 0 else None
            if sampler:
                sampler.start()
            started = time.monotonic()
            named = []
            try:
                if args.eski_port:
                    os.environ[MEMORY_LOG] = env[MEMORY_LOG]
                    os.environ[GUARD_DIR] = str(guard)
                    server = Server(args.eski, args.eski_port, directory / 'server', args.eski_arg, cpus=args.server_cpus)
                with (directory / 'driver.log').open('wb') as log:
                    process = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env, cwd=str(HERE.parent))
                    named = [pattern.replace('{pid}', str(process.pid)) for pattern in args.guard_container]
                    for name in named:
                        (guard / ('container-' + name)).write_text(name + '\n')
                    try:
                        row['exit_code'] = process.wait(timeout=args.rep_timeout)
                    except subprocess.TimeoutExpired:
                        process.send_signal(signal.SIGINT)
                        try:
                            process.wait(timeout=60)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                        row['exit_code'] = 124
                        row['error'] = 'repetition exceeded %d s' % args.rep_timeout
                    except KeyboardInterrupt:
                        try:
                            process.wait(timeout=60)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                        raise
            finally:
                for name in named:
                    gone = subprocess.run(['docker', 'container', 'inspect', name], capture_output=True).returncode != 0
                    if gone and (guard / ('container-' + name)).exists():
                        (guard / ('container-' + name)).unlink()
                if server is not None:
                    row['server_exit'] = server.stop()
                row['seconds'] = time.monotonic() - started
                if sampler:
                    row['telemetry'] = sampler.finish()
                row['memory'] = memory_rows(directory / 'memory.jsonl')
                row['outputs'] = collected(directory, args.collect)
                failing = [name for name, value in row['outputs'].items() if isinstance(value, dict) and value.get('exit_code', 0) not in (0, None)]
                if failing:
                    row['failing_outputs'] = failing
                row['files'] = inventory(directory)
            if row['exit_code'] != 0 or row.get('failing_outputs') or (args.collect and not row['outputs']):
                row.setdefault('error', 'driver exit %s; see %s' % (row['exit_code'], (directory / 'driver.log').relative_to(args.out)))
                if not args.keep_going:
                    break
        code = 0 if len(result['repetitions']) == args.repeat and all(not r.get('error') for r in result['repetitions']) else 1
    except KeyboardInterrupt:
        message = 'interrupted'
        code = 130
        result['error'] = 'interrupted by a signal'
    finally:
        leaked = finish_guard(guard, watcher, write_end, message)
        if leaked:
            result['leaked_and_cleaned'] = leaked
            code = code or 1
        result['guard_log'] = memory_rows(folder / 'guard.log')
        result['exit_code'] = code
        result['finished_at'] = time.time()
        result['seconds'] = result['finished_at'] - result['started_at']
        result['host_end'] = host_record(folder, args.server_cpus, args.client_cpus)
        artifact.parent.mkdir(parents=True, exist_ok=True)
        pending = artifact.with_name('.' + artifact.name + '.part')
        pending.write_text(json.dumps(result, indent=1, sort_keys=True) + '\n')
        pending.replace(artifact)
    return code


def main():
    parser = argparse.ArgumentParser(description='Run one baseline step: repeat a driver, keep every raw output with its sha256, '
                                     'the memory the servers reported before they stopped, machine telemetry and a host record, '
                                     'and clean up every server and container the driver left, even after a kill.')
    parser.add_argument('--name', required=True)
    parser.add_argument('--area', required=True)
    parser.add_argument('--profile', choices=('full', 'rehearsal'), required=True)
    parser.add_argument('--out', type=Path, required=True, help='run directory; the step writes only under OUT/NAME and the artifact')
    parser.add_argument('--artifact', required=True, help='path of the result JSON relative to OUT')
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--keep-going', action='store_true', help='run every repetition even after one fails')
    parser.add_argument('--collect', action='append', default=[], help='glob of JSON outputs in a repetition directory to embed')
    parser.add_argument('--server-cpus')
    parser.add_argument('--client-cpus')
    parser.add_argument('--sample-seconds', type=float, default=2)
    parser.add_argument('--rep-timeout', type=int, default=86400)
    parser.add_argument('--eski', type=Path, help='start this Eski binary for every repetition')
    parser.add_argument('--eski-port', type=int)
    parser.add_argument('--eski-arg', action='append', default=[])
    parser.add_argument('--guard-container', action='append', default=[], help='name of a container the driver starts itself, {pid} being the driver process; removed if the driver leaves it')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ['--']:
        args.command = args.command[1:]
    if not args.command or args.repeat < 1 or (args.eski_port and not args.eski):
        parser.error('a driver command after --, a positive --repeat and --eski with --eski-port are required')
    args.out = args.out.resolve()
    folder = args.out / args.name
    if folder.exists() and any(folder.iterdir()):
        parser.error('step directory %s already exists and is not empty' % folder)
    folder.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    return run(args, folder)


if __name__ == '__main__':
    sys.exit(main())
