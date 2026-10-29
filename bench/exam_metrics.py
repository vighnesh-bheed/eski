import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time


POLICY_FIELDS = ('scaling_governor', 'scaling_driver', 'energy_performance_preference', 'scaling_min_freq', 'scaling_max_freq')


def frequency_policy(cpus, sys=Path('/sys')):
    return {str(cpu): {name: read(sys / f'devices/system/cpu/cpu{cpu}/cpufreq' / name) for name in POLICY_FIELDS} for cpu in sorted(cpus)}


def read(path):
    try:
        return Path(path).read_text().strip()
    except (OSError, ValueError):
        return None


def number(path, scale=1):
    try:
        value = float(read(path)) / scale
        return value if math.isfinite(value) else None
    except (TypeError, ValueError):
        return None


def cpu_set(text):
    result = set()
    for part in text.split(','):
        ends = part.split('-')
        if len(ends) > 2 or not all(x.isdigit() for x in ends):
            raise ValueError('invalid CPU list: ' + text)
        low, high = int(ends[0]), int(ends[-1])
        if high < low or high > 65535:
            raise ValueError('invalid CPU range: ' + part)
        result.update(range(low, high + 1))
    if not result:
        raise ValueError('empty CPU list')
    return result


def append_json(path, value):
    fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_EX)
        length = os.fstat(fd).st_size
        if length and os.pread(fd, 1, length - 1) != b'\n':
            os.write(fd, b'\n')
            value = dict(value, recovered_partial_tail=True)
        data = (json.dumps(value, sort_keys=True, allow_nan=False) + '\n').encode()
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    finally:
        os.close(fd)


def process(pid, proc=Path('/proc')):
    raw = read(proc / str(pid) / 'stat')
    if not raw or ')' not in raw:
        return None
    try:
        tail = raw[raw.rindex(')') + 2:].split()
        return dict(pid=int(pid), comm=raw[raw.index('(') + 1:raw.rindex(')')],
                    state=tail[0], ppid=int(tail[1]), group=int(tail[2]),
                    ticks=int(tail[11]) + int(tail[12]), start_ticks=int(tail[19]),
                    rss_bytes=int(tail[21]) * os.sysconf('SC_PAGE_SIZE'),
                    cgroup=read(proc / str(pid) / 'cgroup'))
    except (ValueError, IndexError):
        return None


def cgroup_snapshot(pid, proc=Path('/proc'), sys=Path('/sys')):
    membership = read(proc / str(pid) / 'cgroup')
    relative = next((line[3:] for line in (membership or '').splitlines() if line.startswith('0::')), None)
    if relative is None or '..' in Path(relative).parts:
        return dict(available=False, reason='unavailable cgroup v2 membership')
    directory = sys / 'fs/cgroup' / relative.lstrip('/')
    data = dict(available=directory.is_dir(), path=relative)
    for name in ('memory.current', 'memory.peak', 'memory.swap.current', 'pids.current'):
        data[name] = number(directory / name)
    for name in ('cpu.stat', 'memory.events', 'io.stat', 'cpu.pressure', 'memory.pressure', 'io.pressure'):
        data[name] = read(directory / name)
    return data


def container_pid(name):
    try:
        done = subprocess.run(['docker', 'inspect', '--format', '{{.State.Pid}}', name],
                              capture_output=True, text=True, timeout=5)
        return int(done.stdout) if done.returncode == 0 and done.stdout.strip().isdigit() else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def owner_event(events, kind, role, pid=None, container=None, artifact_dir=None):
    pid = container_pid(container) if container else pid
    item = dict(event=kind, role=role, container=container, pid=pid,
                artifact_dir=artifact_dir, wall_time=time.time(), monotonic=time.monotonic(), process=process(pid) if pid else None)
    item['cgroup'] = cgroup_snapshot(pid) if pid else dict(available=False, reason='owned PID unavailable')
    item['cgroup_attribution'] = 'owned-container' if container else 'shared-process-cgroup-not-exclusive'
    item['peak_scope'] = 'kernel cgroup lifetime peak sampled immediately before stop' if container and kind == 'before-stop' else 'observed-so-far; may miss final lifetime peak'
    append_json(events, item)


class Reader:
    def __init__(self, sensor=None, chip='coretemp', label='Package id 0', root=Path('/')):
        self.root = Path(root)
        self.proc = self.root / 'proc'
        self.sys = self.root / 'sys'
        self.preferred = sensor
        self.chip, self.label = chip, label
        self.previous_cpu = None
        self.previous_processes = {}
        self.previous_time = None
        self.previous_throttle = None

    def sensor(self):
        candidates = list((self.sys / 'class/hwmon').glob('hwmon*/temp*_input'))
        matched = []
        for path in candidates:
            driver = read(path.parent / 'name')
            label = read(path.with_name(path.name.replace('_input', '_label')))
            if driver == self.chip and label == self.label:
                matched.append(path)
        valid_chip = self.chip in ('coretemp', 'k10temp', 'zenpower')
        valid_label = bool(re.fullmatch(r'Package id \d+|Tctl|Tdie', self.label))
        path = matched[0] if valid_chip and valid_label and len(matched) == 1 else None
        if self.preferred:
            preferred = Path(self.preferred)
            if preferred.exists() and (read(preferred.parent / 'name') != self.chip or read(preferred.with_name(preferred.name.replace('_input', '_label'))) != self.label):
                path = None
        value = number(path, 1000) if path else None
        return dict(available=value is not None and 0 < value < 130,
                    chip=self.chip, label=self.label, path=str(path) if path else None,
                    preferred_path=self.preferred, celsius=value,
                    reason=None if value is not None else 'CPU-package chip/label must resolve uniquely and expose a valid reading')

    def topology(self, roles):
        topology, used = {}, {}
        for role, cpus in roles.items():
            for cpu in sorted(cpus):
                path = self.sys / f'devices/system/cpu/cpu{cpu}/topology'
                siblings = read(path / 'thread_siblings_list')
                if siblings is None:
                    raise ValueError('physical CPU topology unavailable for CPU%d' % cpu)
                siblings = cpu_set(siblings)
                for sibling in siblings:
                    if sibling in used and used[sibling] != role:
                        raise ValueError('CPU physical siblings overlap between ' + role + ' and ' + used[sibling])
                    used[sibling] = role
                topology[str(cpu)] = dict(role=role, siblings=sorted(siblings),
                                         package=read(path / 'physical_package_id'), core=read(path / 'core_id'))
        return topology

    def sample(self, group=None, owners=()):
        at = time.monotonic()
        cpu = {}
        for line in (read(self.proc / 'stat') or '').splitlines():
            if re.match(r'^cpu(?:\d+)? ', line):
                words = line.split()
                values = list(map(int, words[1:9]))
                cpu[words[0]] = (sum(values), values[3])
        idle = {}
        resets = []
        if self.previous_cpu:
            resets.extend('cpu_disappeared:' + key for key in self.previous_cpu if key not in cpu)
            for key, (total, rest) in cpu.items():
                before = self.previous_cpu.get(key)
                if before:
                    delta, quiet = total - before[0], rest - before[1]
                    if delta < 0 or quiet < 0:
                        resets.append('cpu:' + key)
                    idle[key] = 100 * quiet / delta if delta > 0 and quiet >= 0 else None
        self.previous_cpu = cpu
        ac = {}
        for directory in (self.sys / 'class/power_supply').glob('*'):
            if read(directory / 'type') == 'Mains':
                ac[directory.name] = number(directory / 'online')
        throttle = {}
        frequencies = {}
        policies = {}
        for directory in (self.sys / 'devices/system/cpu').glob('cpu[0-9]*'):
            for path in (directory / 'thermal_throttle').glob('*throttle_count'):
                throttle[str(path.relative_to(self.sys))] = number(path)
            frequencies[directory.name] = number(directory / 'cpufreq/scaling_cur_freq')
            policies[directory.name] = {name: read(directory / 'cpufreq' / name) for name in POLICY_FIELDS}
        throttle_delta = {}
        if self.previous_throttle is not None:
            resets.extend('throttle_disappeared:' + key for key in self.previous_throttle if key not in throttle)
            for key, value in throttle.items():
                old = self.previous_throttle.get(key)
                if value is not None and old is not None:
                    if value < old:
                        resets.append('throttle:' + key)
                    else:
                        throttle_delta[key] = value - old
        self.previous_throttle = throttle
        processes = {}
        for path in self.proc.glob('[0-9]*'):
            entry = process(path.name, self.proc)
            if entry:
                processes[(entry['pid'], entry['start_ticks'])] = entry
        owner_keys = {(o.get('pid'), (o.get('process') or {}).get('start_ticks')) for o in owners}
        cgroups = {o.get('cgroup', {}).get('path') for o in owners if o.get('container')}
        observed, external = [], []
        dt = at - self.previous_time if self.previous_time else None
        ticks = os.sysconf('SC_CLK_TCK')
        for key, entry in processes.items():
            old = self.previous_processes.get(key)
            delta = entry['ticks'] - old['ticks'] if old else None
            if delta is not None and delta < 0:
                resets.append('process:%d' % entry['pid'])
            entry['cpu_cores'] = delta / ticks / dt if delta is not None and delta >= 0 and dt else None
            owned = key in owner_keys or (group is not None and entry['group'] == group)
            if not owned and entry['cgroup']:
                owned = any(cg and any(line == '0::' + cg or line.startswith('0::' + cg.rstrip('/') + '/') for line in entry['cgroup'].splitlines()) for cg in cgroups)
            if owned:
                entry['role'] = next((o.get('role') for o in owners if o.get('pid') == entry['pid'] and (o.get('process') or {}).get('start_ticks') == entry['start_ticks']), 'harness-descendant')
                observed.append(entry)
            elif entry['cpu_cores'] is not None and entry['pid'] != os.getpid():
                known_load = entry['comm'] in {'rustc', 'cargo', 'odin', 'clang', 'clang++', 'cc1', 'cc1plus', 'gcc', 'g++', 'ld', 'ld.lld', 'make', 'ninja', 'memtier_benchma', 'redis-benchmark', 'stress', 'stress-ng', 'sysbench', 'fio'}
                if entry['cpu_cores'] >= .1 or (known_load and entry['cpu_cores'] > 0):
                    entry['known_build_or_load'] = known_load
                    external.append(entry)
        gone = [dict(pid=k[0], start_ticks=k[1], status='disappeared') for k in self.previous_processes if k not in processes and k in owner_keys]
        self.previous_processes, self.previous_time = processes, at
        snapshots = []
        for owner in owners:
            item = dict(role=owner.get('role'), pid=owner.get('pid'), container=owner.get('container'))
            current = process(owner.get('pid'), self.proc) if owner.get('pid') else None
            same = current and current['start_ticks'] == (owner.get('process') or {}).get('start_ticks')
            item['status'] = 'running' if same else 'disappeared-or-reused'
            item['cgroup'] = cgroup_snapshot(current['pid'], self.proc, self.sys) if same else None
            snapshots.append(item)
        return dict(wall_time=time.time(), monotonic=at, idle_pct=idle, ac_online=ac,
                    package=self.sensor(), throttle=throttle, throttle_delta=throttle_delta,
                    frequency_khz=frequencies, frequency_policy=policies, cpu_ticks=cpu, loadavg=read(self.proc / 'loadavg'),
                    memory=read(self.proc / 'meminfo'), pressure={k: read(self.proc / 'pressure' / k) for k in ('cpu', 'memory', 'io')},
                    owned_processes=observed, owned_cgroups=snapshots, disappeared=gone,
                    external_cpu=external, counter_resets=resets,
                    availability=dict(cpu=bool(cpu), process_scan=bool(processes), throttle=bool(throttle), frequency=any(v is not None for v in frequencies.values()),
                                      ac=bool(ac) and all(value is not None for value in ac.values()), cgroup_version=2 if (self.sys / 'fs/cgroup/cgroup.controllers').exists() else None))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=('hook', 'watch'))
    parser.add_argument('--events', required=True)
    parser.add_argument('--kind', default='start')
    parser.add_argument('--role', required=True)
    parser.add_argument('--pid', type=int)
    parser.add_argument('--container')
    parser.add_argument('--artifact-dir')
    args = parser.parse_args()
    if args.command == 'watch':
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            pid = container_pid(args.container)
            if pid:
                owner_event(args.events, 'start', args.role, container=args.container, artifact_dir=args.artifact_dir)
                return
            time.sleep(.5)
        owner_event(args.events, 'unavailable', args.role, container=args.container, artifact_dir=args.artifact_dir)
    else:
        owner_event(args.events, args.kind, args.role, args.pid, args.container, args.artifact_dir)


if __name__ == '__main__':
    main()
