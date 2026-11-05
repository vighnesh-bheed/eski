import argparse
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import time


POLICY_FIELDS = ('scaling_governor', 'scaling_driver', 'energy_performance_preference', 'scaling_min_freq', 'scaling_max_freq')
CPU_FIELDS = ('user', 'nice', 'system', 'idle', 'iowait', 'irq', 'softirq', 'steal')
PF_KTHREAD = 0x00200000
DISPLAY_DRIVERS = ('i915', 'xe', 'amdgpu', 'radeon', 'nouveau', 'ast', 'mgag200', 'simpledrm', 'virtio_gpu', 'vmwgfx', 'bochs', 'cirrus', 'qxl', 'gma500_gfx')


def frequency_policy(cpus, sys=Path('/sys')):
    return {str(cpu): {name: read(sys / f'devices/system/cpu/cpu{cpu}/cpufreq' / name) for name in POLICY_FIELDS} for cpu in sorted(cpus)}


def power_supplies(sys=Path('/sys')):
    directory = Path(sys) / 'class/power_supply'
    try:
        names = sorted(path.name for path in directory.iterdir())
    except OSError:
        return None
    return {name: dict(type=read(directory / name / 'type'), online=number(directory / name / 'online')) for name in names}


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


def softirqs(proc=Path('/proc')):
    lines = (read(proc / 'softirqs') or '').splitlines()
    if not lines:
        return None
    cpus = [cpu.lower() for cpu in lines[0].split()]
    result = {}
    for line in lines[1:]:
        name, separator, rest = line.partition(':')
        values = rest.split()
        if separator and name.strip() and len(values) == len(cpus) and all(value.isdigit() for value in values):
            result[name.strip()] = dict(zip(cpus, map(int, values)))
    return result


def interrupts(proc=Path('/proc')):
    lines = (read(proc / 'interrupts') or '').splitlines()
    if not lines:
        return None
    cpus = [cpu.lower() for cpu in lines[0].split()]
    totals = dict.fromkeys(cpus, 0)
    for line in lines[1:]:
        values = line.partition(':')[2].split()[:len(cpus)]
        if len(values) == len(cpus) and all(value.isdigit() for value in values):
            for cpu, value in zip(cpus, values):
                totals[cpu] += int(value)
    return totals


def counter_deltas(current, previous):
    if current is None or previous is None:
        return None
    result = {}
    for key, value in current.items():
        before = previous.get(key)
        if isinstance(value, dict):
            result[key] = counter_deltas(value, before if isinstance(before, dict) else None)
        else:
            result[key] = value - before if before is not None and value >= before else None
    return result


def machine_inventory(root=Path('/')):
    root = Path(root)
    modules = sorted(line.split()[0] for line in (read(root / 'proc/modules') or '').splitlines() if line.split())
    directory = root / 'sys/class/drm'
    try:
        entries = sorted(path.name for path in directory.iterdir())
    except OSError:
        entries = None
    cards = {}
    for name in entries or []:
        if re.fullmatch(r'card\d+', name):
            driver = directory / name / 'device/driver'
            cards[name] = driver.resolve().name if driver.exists() else None
    migration = read(root / 'proc/sys/kernel/timer_migration')
    return dict(cmdline=read(root / 'proc/cmdline'), modules=modules, drm=dict(available=entries is not None, entries=entries, cards=cards),
                timer_migration=int(migration) if migration and migration.isdigit() else None)


def display_drivers(inventory):
    found = set(inventory.get('modules') or []) & set(DISPLAY_DRIVERS)
    for card, driver in ((inventory.get('drm') or {}).get('cards') or {}).items():
        found.add(driver or card)
    return sorted(found)


def memtier_series(data):
    stats = data.get('ALL STATS') if isinstance(data, dict) else None
    if stats is None and isinstance(data, dict):
        merged = [key for key in data if key.startswith('AGGREGATED AVERAGE RESULTS')]
        stats = data[merged[0]] if merged else None
    series = ((stats or {}).get('Totals') or {}).get('Time-Serie') if isinstance(stats, dict) else None
    result = dict(available=False, seconds=0, per_second_ops=None, steady_ops_per_sec=None, stall_seconds=None, stall_windows=None, min_second_ratio=None,
                  method='memtier per-second request counts of the timed client; the trailing partial second is dropped; steady rate is the median full second; a stall second delivers under half the steady rate; windows are runs of consecutive stall seconds')
    if not isinstance(series, dict) or not series:
        result['reason'] = 'no per-second series in the raw client output'
        return result
    try:
        counts = [int(series[key]['Count']) for key in sorted(series, key=int)]
    except (KeyError, TypeError, ValueError):
        result['reason'] = 'unreadable per-second series'
        return result
    if len(counts) > 1 and counts[-1] < .5 * statistics.median(counts[:-1]):
        counts = counts[:-1]
    steady = statistics.median(counts)
    stalls = [count < .5 * steady for count in counts] if steady > 0 else [False] * len(counts)
    result.update(available=True, seconds=len(counts), per_second_ops=counts, steady_ops_per_sec=steady, stall_seconds=sum(stalls),
                  stall_windows=sum(1 for index, stalled in enumerate(stalls) if stalled and (index == 0 or not stalls[index - 1])),
                  min_second_ratio=min(counts) / steady if steady > 0 else None)
    return result


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
                    processor=int(tail[36]) if len(tail) > 36 else None, kthread=bool(int(tail[6]) & PF_KTHREAD),
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
        self.previous_fields = None
        self.previous_softirqs = None
        self.previous_interrupts = None
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
        cpu, fields = {}, {}
        for line in (read(self.proc / 'stat') or '').splitlines():
            if re.match(r'^cpu(?:\d+)? ', line):
                words = line.split()
                values = list(map(int, words[1:9]))
                cpu[words[0]] = (sum(values), values[3])
                fields[words[0]] = values
        shares = {}
        if self.previous_fields:
            for key, values in fields.items():
                before = self.previous_fields.get(key)
                deltas = [now - old for now, old in zip(values, before)] if before else []
                shares[key] = {name: round(100 * delta / sum(deltas), 2) for name, delta in zip(CPU_FIELDS, deltas)} if deltas and sum(deltas) > 0 and min(deltas) >= 0 else None
        self.previous_fields = fields
        soft = softirqs(self.proc)
        soft_delta = counter_deltas(soft, self.previous_softirqs)
        self.previous_softirqs = soft
        irq = interrupts(self.proc)
        irq_delta = counter_deltas(irq, self.previous_interrupts)
        self.previous_interrupts = irq
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
        supplies = power_supplies(self.sys)
        ac = {name: device['online'] for name, device in (supplies or {}).items() if device['type'] == 'Mains'}
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
        return dict(wall_time=time.time(), monotonic=at, idle_pct=idle, ac_online=ac, power_supply=supplies,
                    package=self.sensor(), throttle=throttle, throttle_delta=throttle_delta,
                    frequency_khz=frequencies, frequency_policy=policies, cpu_ticks=cpu, cpu_fields=fields, cpu_share_pct=shares,
                    softirqs=soft, softirq_delta=soft_delta, interrupts=irq, interrupt_delta=irq_delta, loadavg=read(self.proc / 'loadavg'),
                    memory=read(self.proc / 'meminfo'), pressure={k: read(self.proc / 'pressure' / k) for k in ('cpu', 'memory', 'io')},
                    owned_processes=observed, owned_cgroups=snapshots, disappeared=gone,
                    external_cpu=external, counter_resets=resets,
                    availability=dict(cpu=bool(cpu), process_scan=bool(processes), throttle=bool(throttle), frequency=any(v is not None for v in frequencies.values()),
                                      ac=bool(ac) and all(value is not None for value in ac.values()), power_supply=supplies is not None,
                                      softirqs=bool(soft), interrupts=bool(irq),
                                      cgroup_version=2 if (self.sys / 'fs/cgroup/cgroup.controllers').exists() else None))


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
