import argparse
import copy
import csv
import fcntl
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
_metrics_spec = importlib.util.spec_from_file_location('eski_exam_metrics', Path(__file__).with_name('exam_metrics.py'))
metrics = importlib.util.module_from_spec(_metrics_spec)
_metrics_spec.loader.exec_module(metrics)


SCHEMA = 'eski-exam-v1'
TERMINAL = {'successful', 'invalid', 'failed', 'skipped'}
TARGETS = {'redis', 'valkey', 'dragonfly', 'eski', 'eski-docker'}
TARGET_ORDER = ('eski-docker', 'eski', 'redis', 'valkey', 'dragonfly')
POWER_SOURCES = ('mains', 'no-power-supply-devices')
PRESENT_POWER_SUPPLY = {'Battery': 'battery_present', 'Mains': 'mains_present'}


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def atomic(path, value):
    atomic_bytes(path, canonical(value) + b'\n')


def atomic_bytes(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def load(path):
    return json.loads(Path(path).read_text())


def status_view(checkpoint):
    if checkpoint is None:
        return dict(status='NOT STARTED', done=False, passed=False, counts=dict(planned=None, successful=0, valid=0, failed=0, invalid=0, skipped=0, interrupted=0, pending=0, running=0, missing=None), cases=[])
    rows = checkpoint['cases']
    counts = {name: sum(row['state'] == name for row in rows) for name in sorted(TERMINAL | {'interrupted', 'pending', 'running'})}
    counts.update(planned=len(rows), valid=counts['successful'], missing=sum(row['state'] not in TERMINAL for row in rows))
    cleanup_pending = any(row['attempts'] and row['attempts'][-1].get('cleanup', {}).get('ok') is False for row in rows)
    done = bool(rows) and counts['missing'] == 0 and not cleanup_pending
    passed = done and counts['successful'] == len(rows)
    owner = checkpoint.get('controller') or {}
    current = metrics.process(owner.get('pid')) if owner.get('pid') else None
    alive = bool(current and current['start_ticks'] == owner.get('start_ticks') and current['state'] != 'Z' and checkpoint.get('controller_boot_id') == metrics.read('/proc/sys/kernel/random/boot_id'))
    if done:
        status = 'DONE' if passed else 'DONE WITH FAILURES'
    elif checkpoint.get('state') == 'paused':
        status = 'INTERRUPTED' if counts['interrupted'] else 'HELD'
    elif not alive:
        status = 'INTERRUPTED'
    elif checkpoint.get('state') == 'cooling':
        status = 'COOLING'
    else:
        status = 'RUNNING'
    by_target = {}
    for row in rows:
        by_target.setdefault(row['target'], {name: 0 for name in counts if name != 'planned'})
        target = by_target[row['target']]
        target[row['state']] += 1
        target['valid'] += row['state'] == 'successful'
        target['missing'] += row['state'] not in TERMINAL
    return dict(schema=SCHEMA, status=status, done=done, passed=passed, counts=counts, by_target=by_target,
                identity=checkpoint.get('identity'), updated_at=checkpoint.get('updated_at'), pause=checkpoint.get('pause'),
                controller_alive=alive, cleanup_pending=cleanup_pending, cases=[dict(id=row['id'], key=row['key'], target=row['target'], repetition=row['repetition'], state=row['state'], attempts=[dict(directory=a.get('directory'), state=a['state'], artifacts_sha256=a.get('artifacts_sha256')) for a in row['attempts']]) for row in rows])


def finite_measurement(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool) or value < 0:
        return None
    try:
        return value if math.isfinite(value) else None
    except OverflowError:
        return None


def measurement_tables(checkpoint):
    measurements = []
    groups = {}
    targets = [target for target in TARGET_ORDER if any(row['target'] == target for row in checkpoint['cases'])]
    for row in checkpoint['cases']:
        attempt = row['attempts'][-1] if row['attempts'] else {}
        details = attempt.get('details') or {}
        record = details.get('record') or {}
        telemetry = attempt.get('telemetry') or {}
        reasons = list(details.get('reasons') or [])
        reasons += [str(value) for value in (details.get('error'), record.get('error'), record.get('skipped'), (details.get('target') or {}).get('reason'), attempt.get('interruption_reason')) if value]
        result = dict(case=row['key'], name=row['name'], suite=row['suite'], target=row['target'], repetition=row['repetition'], state=row['state'],
                      ops_per_sec=None, p50_ms=None, p99_ms=None, p999_ms=None, max_ms=None, count=None,
                      server_cgroup_peak_bytes=None, server_cgroup_peak_scope='unavailable',
                      owned_process_sampled_max_rss_bytes=None, sampled_rss_scope='unavailable', aggregation=record.get('aggregation', ''), reason='; '.join(dict.fromkeys(reasons)))
        if row['state'] == 'successful':
            for field in ('ops_per_sec', 'p50_ms', 'p99_ms', 'p999_ms', 'max_ms', 'count'):
                result[field] = finite_measurement(record.get(field))
            if result['ops_per_sec'] == 0:
                result['ops_per_sec'] = None
            peaks = [p for p in telemetry.get('server_pre_stop_cgroup_peaks', []) if Path(p.get('artifact_dir') or '').parts[-2:] == ('run', row['target']) and finite_measurement(p.get('memory_peak_bytes')) is not None]
            if peaks:
                result['server_cgroup_peak_bytes'] = peaks[-1]['memory_peak_bytes']
                result['server_cgroup_peak_scope'] = 'kernel memory.peak of the last case-run server instance, the one that served the timed client, read immediately before stop; includes preload and warmup; excludes command-probe instances; not a process RSS measurement'
            rss = [p['sampled_max_rss_bytes'] for p in telemetry.get('process_sampled_maxima', []) if finite_measurement(p.get('sampled_max_rss_bytes')) is not None]
            if rss:
                result['owned_process_sampled_max_rss_bytes'] = max(rss)
                result['sampled_rss_scope'] = 'maximum sampled RSS of any single owned process (server/client/harness); not summed, not a continuous or exclusive-memory peak'
        else:
            result['server_cgroup_peak_scope'] = result['sampled_rss_scope'] = 'numeric measurements withheld for nonsuccess; raw telemetry retained'
            if not result['reason']:
                result['reason'] = row['state']
        measurements.append(result)
        key = (row['index'], row['repetition'])
        comparison = groups.setdefault(key, dict(case=row['key'], name=row['name'], suite=row['suite'], repetition=row['repetition']))
        comparison[row['target'] + '_state'] = row['state']
        comparison[row['target'] + '_ops_per_sec'] = result['ops_per_sec']
    return measurements, list(groups.values()), targets


def csv_bytes(rows, fields):
    text = io.StringIO(newline='')
    writer = csv.DictWriter(text, fieldnames=fields, lineterminator='\n')
    writer.writeheader()
    writer.writerows(rows)
    return text.getvalue().encode()


def markdown_cell(value):
    return str(value).replace('\\', '\\\\').replace('|', '\\|').replace('\r', ' ').replace('\n', ' ')


def publish(output, checkpoint):
    report = status_view(checkpoint)
    measurements, comparisons, targets = measurement_tables(checkpoint)
    measurement_fields = ('case', 'name', 'suite', 'target', 'repetition', 'state', 'ops_per_sec', 'p50_ms', 'p99_ms', 'p999_ms', 'max_ms', 'count', 'server_cgroup_peak_bytes', 'server_cgroup_peak_scope', 'owned_process_sampled_max_rss_bytes', 'sampled_rss_scope', 'aggregation', 'reason')
    comparison_fields = ['case', 'name', 'suite', 'repetition'] + [field for target in targets for field in (target + '_state', target + '_ops_per_sec')]
    atomic_bytes(output / 'measurements.csv', csv_bytes(measurements, measurement_fields))
    atomic_bytes(output / 'comparisons.csv', csv_bytes(comparisons, comparison_fields))
    report.update(measurements='measurements.csv', comparisons='comparisons.csv')
    atomic(output / 'summary.json', report)
    atomic(output / 'index.json', dict(schema=SCHEMA, identity=checkpoint['identity'], summary='summary.json', report='report.md', measurements='measurements.csv', comparisons='comparisons.csv', checkpoint='checkpoint.json', original_plan='original-plan.json', immutable_identity='identity.json', gates='gates.jsonl', events='events.jsonl', cases=report['cases']))
    counts = report['counts']
    lines = ['# Benchmark experiment', '', 'Status at checkpoint publication: ' + report['status'] + '.', '',
             'Use exam.sh status for the current controller liveness. Completion and validity are separate.', '',
             '| Planned | Valid | Failed | Invalid | Skipped | Missing |', '| ---: | ---: | ---: | ---: | ---: | ---: |',
             '| %s | %s | %s | %s | %s | %s |' % tuple(counts[k] for k in ('planned', 'valid', 'failed', 'invalid', 'skipped', 'missing')), '',
             '[Measurements and latency/memory scopes](measurements.csv) · [Per-case engine comparisons](comparisons.csv) · [Machine summary](summary.json) · [Artifact index](index.json) · [Checkpoint](checkpoint.json) · [Immutable identity](identity.json)', '',
             '| Target | Valid | Failed | Invalid | Skipped | Missing |', '| --- | ---: | ---: | ---: | ---: | ---: |']
    for target, values in sorted(report['by_target'].items()):
        lines.append('| %s | %s | %s | %s | %s | %s |' % ((target,) + tuple(values[k] for k in ('valid', 'failed', 'invalid', 'skipped', 'missing'))))
    lines += ['', '## Per-case throughput', '', 'Values are operations per second for the same case and repetition. Only successful finite measurements populate numeric cells. Other outcomes remain labelled; their numeric measurements are blank in the CSV files. No cross-workload average or winner is calculated.', '',
              '| Case | Repetition | ' + ' | '.join(markdown_cell(target) for target in targets) + ' |',
              '| --- | ---: | ' + ' | '.join('---:' for _ in targets) + ' |']
    for comparison in comparisons:
        cells = []
        for target in targets:
            value = comparison.get(target + '_ops_per_sec')
            cells.append(format(value, ',.2f') if value is not None else comparison.get(target + '_state', 'missing') + ' (unavailable)')
        lines.append('| ' + ' | '.join([markdown_cell(comparison['name']), str(comparison['repetition']), *cells]) + ' |')
    lines += ['', 'Every case/engine/repetition retains its own attempts, raw harness logs, original and resolved plans, metrics and ownership observations. Successful cases are not rerun on resume. Failed, invalid and skipped outcomes remain visible. Interrupted cases require explicit retry admission.', '', 'RSS/process maxima are sampled. Kernel cgroup memory peaks carry their actual observation scope; native process cgroups are not exclusive. Missing sensors/measurements stay unavailable. Sampled interference detection cannot prove absence of short activity between samples.', '']
    atomic_bytes(output / 'report.md', '\n'.join(lines).encode())


def contained(root, name):
    path = root / name
    if Path(name).is_absolute() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('profile path escapes workspace: ' + name)
    return path


def durable_artifacts(directory):
    inventory = {}
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():
            raise ValueError('unexpected result symlink: ' + str(path))
        if path.is_file():
            with path.open('rb') as handle:
                os.fsync(handle.fileno())
            inventory[str(path.relative_to(directory))] = dict(sha256=sha(path), bytes=path.stat().st_size)
    atomic(directory / 'artifacts.json', inventory)
    for path in [p for p in directory.rglob('*') if p.is_dir()] + [directory]:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    return sha(directory / 'artifacts.json')


class Lock:
    def __init__(self, path):
        self.path, self.fd = Path(path), None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(self.path, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.fd)
            self.fd = None
            raise ValueError('another runner holds ' + str(self.path))
        return self

    def __exit__(self, *args):
        if self.fd is not None:
            os.close(self.fd)


def validate(args, reader):
    profile = load(args.profile)
    root = Path(args.profile).resolve().parent
    if profile.get('schema') != 'eski-exam-profile-v1' or not profile.get('source_revision'):
        raise ValueError('profile requires schema eski-exam-profile-v1 and source_revision')
    files = dict(profile.get('files') or {})
    for name, digest in ((profile.get('native') or {}).get('files') or {}).items():
        if name in files and files[name] != digest:
            raise ValueError('conflicting file inventories: ' + name)
        files[name] = digest
    if not files:
        raise ValueError('profile has no immutable file inventory')
    for name, digest in files.items():
        if sha(contained(root, name)) != digest:
            raise ValueError('profile file hash mismatch: ' + name)
    selected = args.targets.split(',')
    if len(selected) != len(set(selected)) or not set(selected) <= TARGETS:
        raise ValueError('targets must be a unique supported comma-separated list')
    images = profile.get('images') or {}
    needed = (set(selected) - {'eski'}) | {'cli', 'memtier'}
    for role in set(images) | needed:
        image = images.get(role, '')
        if not isinstance(image, str) or not image.startswith('sha256:') or len(image) != 71 or any(c not in '0123456789abcdef' for c in image[7:]):
            raise ValueError('profile requires an immutable local image ID for ' + role)
    if 'redis' in selected and images['redis'] != images['cli']:
        raise ValueError('run.sh shares its Redis server and CLI image; profile IDs must agree')
    if 'eski' in selected:
        native = profile.get('native') or {}
        if not native.get('path') or native['path'] not in files:
            raise ValueError('native target requires a hashed launcher and runtime file inventory')
    roles = {role: metrics.cpu_set(getattr(args, role + '_cpus')) for role in ('server', 'client', 'control')}
    union = set.union(*roles.values())
    if sum(map(len, roles.values())) != len(union):
        raise ValueError('logical CPU affinity sets overlap')
    if not union <= os.sched_getaffinity(0):
        raise ValueError('requested CPU affinity is outside the current allowed set')
    topology = reader.topology(roles)
    dragonfly_threads = profile.get('dragonfly_threads', 4)
    if 'dragonfly_threads' in profile and (type(dragonfly_threads) is not int or not 1 <= dragonfly_threads <= len(roles['server'])):
        raise ValueError('profile dragonfly_threads must be positive and no larger than the server CPU pool')
    if args.power_source not in POWER_SOURCES:
        raise ValueError('power source must be one of ' + ', '.join(POWER_SOURCES))
    if args.repetitions < 1 or args.maxmemory < 1 or args.min_free_bytes < 0 or not 0 <= args.min_idle <= 100:
        raise ValueError('invalid repetitions, maxmemory or idle threshold')
    if args.max_client_utilization_pct is not None and not (math.isfinite(args.max_client_utilization_pct) and 0 < args.max_client_utilization_pct <= 100):
        raise ValueError('invalid client utilization threshold')
    if args.max_latency_seconds is not None and not (math.isfinite(args.max_latency_seconds) and args.max_latency_seconds > 0):
        raise ValueError('invalid latency sanity bound')
    numbers = (args.cool_temp_c, args.max_temp_c, args.min_rest, args.stable_seconds, args.max_wait, args.sample_seconds)
    if not all(math.isfinite(v) for v in numbers) or min(numbers) < 0 or args.sample_seconds < .2 or args.max_wait <= 0 or args.max_temp_c <= args.cool_temp_c:
        raise ValueError('invalid cooling/sampling thresholds')
    for limit in (args.server_memory, args.client_memory):
        if not re.fullmatch(r'[1-9][0-9]*(?:[bkmgBKMG])?', limit):
            raise ValueError('invalid container memory limit: ' + limit)
    plan = load(args.plan)
    items = plan.get('items') or []
    if not items or len({i.get('key') for i in items}) != len(items):
        raise ValueError('plan must contain nonempty items with unique keys')
    for item in items:
        if not all(item.get(k) for k in ('key', 'name', 'suite', 'clients')):
            raise ValueError('plan item requires key/name/suite/clients')
        if 'warmup' in item:
            warmup = item['warmup']
            if not isinstance(warmup, dict) or warmup.get('tool') not in ('memtier_benchmark', 'redis-benchmark') or not isinstance(warmup.get('argv'), list) or not all(isinstance(value, str) for value in warmup['argv']):
                raise ValueError('warmup requires a supported tool and an argv array of strings')
            if item.get('flush_each_run'):
                raise ValueError('cannot flush the warmed dataset before timed clients')
        phases = item['clients'] + [item[name] for name in ('preload', 'warmup') if item.get(name)]
        for client in phases:
            ref = client.get('image')
            image = images.get(ref, ref if ref in images.values() else None)
            if image not in images.values() or not image.startswith('sha256:'):
                raise ValueError('unresolved plan tool image: ' + str(ref))
        needs = client_needs(item['clients'], sorted(roles['client']))
        oversubscribed = any(n and n > len(roles['client']) for n in needs) or (len(needs) > 1 and all(needs) and sum(needs) > len(roles['client']))
        if oversubscribed and args.resource_policy == 'strict':
            raise ValueError('declared client CPU requests exceed the client pool for %s; regenerate the plan or explicitly admit --resource-policy allow-oversubscription' % item['key'])
        if item.get('warmup') and client_needs([item['warmup']], sorted(roles['client']))[0] > len(roles['client']) and args.resource_policy == 'strict':
            raise ValueError('declared warmup CPU request exceeds the client pool for ' + item['key'])
    harness = contained(root, profile.get('harness', 'bench/run.sh'))
    if str(harness.relative_to(root)) not in files:
        raise ValueError('harness must be in the profile file inventory')
    env = os.environ.copy()
    for name in list(env):
        if name.startswith('BENCH_') or name == 'ESKI_BIN':
            del env[name]
    if profile.get('tool_bin'):
        env['PATH'] = str(contained(root, profile['tool_bin'])) + os.pathsep + env.get('PATH', '')
    tools = {}
    for name in ('bash', 'python3', 'docker', 'jq', 'ss', 'taskset', 'timeout'):
        path = shutil.which(name, path=env.get('PATH'))
        tools[name] = dict(path=path, sha256=sha(path) if path else None)
    auto = {p.name: sha(p) for p in (Path(__file__), Path(metrics.__file__))}
    cpu_model = next((s.split(':', 1)[1].strip() for s in (metrics.read('/proc/cpuinfo') or '').splitlines() if s.startswith('model name')), None)
    host = dict(cpu_model=cpu_model, kernel=platform.release(), machine=platform.machine(),
                machine_id_sha256=hashlib.sha256((metrics.read('/etc/machine-id') or '').encode()).hexdigest(), topology=topology)
    host['hardware'] = {name: metrics.read('/sys/class/dmi/id/' + name) for name in ('sys_vendor', 'product_name', 'board_name', 'bios_version')}
    host['online_cpus'] = metrics.read('/sys/devices/system/cpu/online')
    host['mem_total'] = next((line for line in (metrics.read('/proc/meminfo') or '').splitlines() if line.startswith('MemTotal:')), None)
    host['frequency_policy'] = metrics.frequency_policy(union)
    if any(not policy['scaling_governor'] or not policy['scaling_driver'] or not policy['scaling_min_freq'] or not policy['scaling_max_freq'] for policy in host['frequency_policy'].values()):
        raise ValueError('CPU frequency policy unavailable for an admitted CPU')
    config = {name: getattr(args, name) for name in ('repetitions', 'server_memory', 'client_memory', 'maxmemory', 'cool_temp_c', 'max_temp_c', 'min_idle', 'min_rest', 'stable_seconds', 'max_wait', 'sample_seconds', 'min_free_bytes', 'resource_policy', 'power_source')}
    config.update(cpus={k: sorted(v) for k, v in roles.items()}, sensor=dict(chip=reader.chip, label=reader.label), targets=selected, dragonfly_threads=dragonfly_threads,
                  client_budget_cores=client_budget_cores(topology, roles['client']), max_client_utilization_pct=args.max_client_utilization_pct, max_latency_seconds=args.max_latency_seconds)
    identity = dict(schema=SCHEMA, plan_sha256=sha(args.plan), profile_sha256=sha(args.profile),
                    files=files, scheduler=auto, tools=tools, host=host, config=config)
    identity['sha256'] = hashlib.sha256(canonical(identity)).hexdigest()
    return dict(profile=profile, root=root, plan=plan, targets=selected, roles=roles,
                harness=harness, env=env, identity=identity)


def schedule(plan, targets, repetitions):
    rows = []
    for repetition in range(repetitions):
        for index, item in enumerate(plan['items']):
            offset = (repetition + index) % len(targets)
            for target in targets[offset:] + targets[:offset]:
                rows.append(dict(id='%06d-r%03d-%s' % (index, repetition + 1, target),
                                 index=index, key=item['key'], name=item['name'], suite=item['suite'], target=target, repetition=repetition + 1,
                                 state='pending', attempts=[]))
    return rows


def client_needs(clients, pool):
    return [max(1, math.ceil(float(c['requested_cpus']))) if c.get('requested_cpus') else len(metrics.cpu_set(c['cpus'])) if c.get('cpus') else len(pool) for c in clients]


def resolved_plan(model, row, client_cpus):
    plan = copy.deepcopy(model['plan'])
    item = plan['items'][row['index']]
    images = model['profile']['images']
    clients = item['clients']
    needs = client_needs(clients, client_cpus)
    allocations = [client_cpus] * len(clients)
    if len(clients) == 1:
        allocations = [client_cpus[:min(needs[0], len(client_cpus))]]
    elif sum(needs) <= len(client_cpus):
        allocations, pos = [], 0
        for need in needs:
            allocations.append(client_cpus[pos:pos + need])
            pos += need
    for client, cpus in zip(clients, allocations):
        client['image'] = images.get(client['image'], client['image'])
        client['cpus'] = ','.join(map(str, cpus))
    if item.get('preload'):
        item['preload']['image'] = images.get(item['preload']['image'], item['preload']['image'])
        item['preload']['cpus'] = ','.join(map(str, sorted(set().union(*map(set, allocations)))))
    if item.get('warmup'):
        warmup = item['warmup']
        warmup['image'] = images.get(warmup['image'], warmup['image'])
        warmup['cpus'] = ','.join(map(str, client_cpus[:min(client_needs([warmup], client_cpus)[0], len(client_cpus))]))
    plan['items'] = [item]
    return plan


def power_problems(sample, source):
    if source == 'mains':
        ac = sample.get('ac_online') or {}
        if not ac or any(value is None for value in ac.values()) or sample.get('availability', {}).get('ac') is not True:
            return ['ac_sensor_unavailable']
        return ['ac_not_online'] if any(value != 1 for value in ac.values()) else []
    if source == 'no-power-supply-devices':
        devices = sample.get('power_supply')
        if not isinstance(devices, dict) or sample.get('availability', {}).get('power_supply') is not True:
            return ['power_supply_telemetry_unavailable']
        return sorted({PRESENT_POWER_SUPPLY.get((device or {}).get('type'), 'power_supply_device_present') for device in devices.values()})
    return ['power_source_undeclared']


def sample_problems(sample, args, cooling=False):
    problems = []
    package = sample['package']
    if not package.get('available'):
        problems.append('package_sensor_unavailable')
    elif package['celsius'] > (args.cool_temp_c if cooling else args.max_temp_c):
        problems.append('package_temperature')
    problems += power_problems(sample, getattr(args, 'power_source', 'mains'))
    if sample.get('counter_resets'):
        problems.append('counter_reset')
    if sample.get('availability', {}).get('cpu') is not True or sample.get('availability', {}).get('process_scan') is not True:
        problems.append('telemetry_unavailable')
    throttle = sample.get('throttle') or {}
    deltas = sample.get('throttle_delta') or {}
    if sample.get('availability', {}).get('throttle') is not True or not throttle or any(finite_measurement(value) is None for value in [*throttle.values(), *deltas.values()]) or set(throttle) != set(deltas):
        problems.append('throttle_telemetry_unavailable')
    if any(finite_measurement(value) is not None and value > 0 for value in deltas.values()):
        problems.append('thermal_throttling')
    if cooling:
        cpus = metrics.cpu_set(args.server_cpus) | metrics.cpu_set(args.client_cpus)
        if any(sample.get('idle_pct', {}).get(key) is None or sample['idle_pct'][key] < args.min_idle for key in ['cpu'] + ['cpu%d' % c for c in cpus]):
            problems.append('cpu_not_idle')
        if sample.get('external_cpu'):
            problems.append('external_cpu_activity')
    return problems


def owner_rows(path):
    result = []
    if not path.exists():
        return result
    for line in path.read_text().splitlines():
        try:
            result.append(json.loads(line))
        except ValueError:
            result.append(dict(event='malformed', raw=line))
    return result


def policy_problems(sample, expected):
    observed = sample.get('frequency_policy') or {}
    return ['frequency_policy_changed'] if any(observed.get('cpu' + cpu) != policy for cpu, policy in expected.items()) else []


INFRASTRUCTURE = {'dockerd', 'containerd', 'systemd', 'systemd-journal', 'containerd-shim'}
KERNEL_THREAD_PREFIXES = ('kworker/', 'rcu_', 'rcuc/', 'rcub/', 'jbd2/', 'ksoftirqd/', 'migration/', 'kswapd', 'kcompactd', 'khugepaged')
BOUND_KERNEL_THREAD = re.compile(r'(?:kworker|ksoftirqd|migration|rcuc)/(\d+)(?::|$)')
KERNEL_THREAD_MIN_CORES = .1
NEGLIGIBLE_CORES = .02


def kernel_thread(proc):
    return proc.get('pid') == 2 or proc.get('ppid') == 2 or proc['comm'].startswith(KERNEL_THREAD_PREFIXES)


def bound_kernel_thread_cpu(proc):
    match = BOUND_KERNEL_THREAD.match(proc['comm'])
    if not match:
        return None
    processor = proc.get('processor')
    return processor if isinstance(processor, int) and not isinstance(processor, bool) else int(match.group(1))


def role_cpus(args, role):
    text = getattr(args, role + '_cpus', None)
    return metrics.cpu_set(text) if text else set()


def reserved_kernel_threads(samples, args):
    roles = {role: role_cpus(args, role) for role in ('server', 'client')}
    result = dict(min_cores=KERNEL_THREAD_MIN_CORES, server=[], client=[], reasons=[], annotations=[],
                  method='per-CPU bound kernel threads (kworker/N:, ksoftirqd/N, migration/N, rcuc/N) at or above the share threshold in any sample, placed by the recorded processor when present and by the CPU in the name otherwise; one on a server CPU invalidates, one on a client CPU is annotated')
    for index, sample in enumerate(samples):
        for proc in sample.get('external_cpu', []):
            cpu = bound_kernel_thread_cpu(proc)
            cores = finite_measurement(proc.get('cpu_cores'))
            if cpu is None or cores is None or cores < KERNEL_THREAD_MIN_CORES:
                continue
            for role, cpus in roles.items():
                if cpu in cpus:
                    result[role].append(dict(sample=index, pid=proc['pid'], comm=proc['comm'], cpu=cpu, cpu_cores=cores))
    if result['server']:
        result['reasons'].append('kernel_thread_on_reserved_cpu')
    if result['client']:
        result['annotations'].append('kernel_thread_on_client_cpu')
    return result


def owned_process(proc, keys, groups):
    if (proc['pid'], proc['start_ticks']) in keys:
        return True
    lines = (proc.get('cgroup') or '').splitlines()
    return any(cg and any(line == '0::' + cg or line.startswith('0::' + cg.rstrip('/') + '/') for line in lines) for cg in groups)


def validity(samples, owners, args, expected_policy=None):
    reasons = set() if samples else {'telemetry_unavailable'}
    if any(o.get('event') == 'malformed' for o in owners):
        reasons.add('ownership_log_partial')
    keys = {(o.get('pid'), (o.get('process') or {}).get('start_ticks')) for o in owners}
    groups = {o.get('cgroup', {}).get('path') for o in owners if o.get('container')}
    sightings = {}
    for sample in samples:
        for proc in sample.get('external_cpu', []):
            key = (proc['pid'], proc['start_ticks'])
            sightings[key] = sightings.get(key, 0) + 1
    reasons.update(reserved_kernel_threads(samples, args)['reasons'])
    policy = None
    for sample in samples:
        reasons.update(sample_problems(sample, args))
        if expected_policy is not None:
            reasons.update(policy_problems(sample, expected_policy))
        current_policy = sample.get('frequency_policy')
        if policy is not None and current_policy != policy:
            reasons.add('frequency_policy_changed')
        policy = current_policy
        for proc in sample.get('external_cpu', []):
            if owned_process(proc, keys, groups) or proc['comm'] in INFRASTRUCTURE or kernel_thread(proc):
                continue
            cores = finite_measurement(proc.get('cpu_cores'))
            if cores is not None and cores < NEGLIGIBLE_CORES and sightings[(proc['pid'], proc['start_ticks'])] == 1:
                continue
            reasons.add('external_cpu_activity')
    return sorted(reasons)


def client_budget_cores(topology, client_cpus):
    return len(set(client_cpus))


def timed_client(owners, key):
    return next((o for o in owners if o.get('role') == 'client' and (o.get('artifact_dir') or '').endswith('/' + key) and o.get('process')), None)


def client_headroom(samples, owners, row, budget, max_pct):
    owner = timed_client(owners, row['key'])
    result = dict(budget_cores=budget, max_utilization_pct=max_pct, owner_pid=owner.get('pid') if owner else None,
                  samples=0, median_cores=None, max_cores=None, utilization_pct=None, reasons=[], annotations=[],
                  method='median of the owned timed client process CPU time in logical CPUs over its samples, first and last two omitted, against the logical client CPU budget; above the threshold the measurement is annotated client_limited and stays valid')
    if owner is None:
        result['reasons'].append('client_ownership_unobserved')
        return result
    rows = []
    for sample in samples:
        for proc in sample.get('owned_processes', []):
            if proc.get('pid') == owner['pid'] and proc.get('start_ticks') == owner['process'].get('start_ticks') and finite_measurement(proc.get('cpu_cores')) is not None:
                rows.append(proc['cpu_cores'])
    interior = rows[2:-2] if len(rows) > 4 else rows
    result['samples'] = len(interior)
    if not interior:
        result['reasons'].append('client_headroom_unmeasured')
        return result
    result['median_cores'] = statistics.median(interior)
    result['max_cores'] = max(interior)
    result['utilization_pct'] = 100 * result['median_cores'] / budget if budget else None
    if result['utilization_pct'] is None:
        result['reasons'].append('client_headroom_unmeasured')
    elif result['utilization_pct'] > max_pct:
        result['annotations'].append('client_limited')
    return result


def latency_maxima(node, trail=()):
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == 'Max Latency':
                found.append(('/'.join(trail), finite_measurement(value)))
            else:
                found.extend(latency_maxima(value, trail + (str(key),)))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found.extend(latency_maxima(value, trail + (str(index),)))
    return found


def latency_sanity(run_dir, row, limit_seconds):
    limit_ms = limit_seconds * 1000
    result = dict(limit_ms=limit_ms, files=[], reasons=[], method='every Max Latency field of the raw timed client JSON, in milliseconds, must lie within the declared run lifetime; larger values are histogram range artifacts, not measured requests')
    paths = sorted(Path(run_dir).glob('*/%s.json' % row['key']))
    if not paths:
        result['reasons'].append('latency_sanity_unmeasured')
        return result
    for path in paths:
        entry = dict(path=str(path.relative_to(run_dir)), fields=0, max_ms=None, offending=[])
        try:
            found = latency_maxima(json.loads(path.read_text()))
        except (OSError, ValueError):
            entry['unreadable'] = True
            result['reasons'].append('latency_sanity_unreadable')
            result['files'].append(entry)
            continue
        values = [(name, value) for name, value in found if value is not None]
        entry['fields'] = len(values)
        if not values or len(values) != len(found):
            result['reasons'].append('latency_sanity_unmeasured')
        else:
            entry['max_ms'] = max(value for _, value in values)
            entry['offending'] = [dict(field=name, ms=value) for name, value in values if value > limit_ms][:20]
            if entry['offending']:
                result['reasons'].append('timing_anomaly')
        result['files'].append(entry)
    result['reasons'] = sorted(set(result['reasons']))
    return result


COLLAPSE_FRACTION = .5
TAIL_STALL_MAX_MS = 100
TAIL_STALL_P99_MS = 1


def per_second_counts(totals):
    series = totals.get('Time-Serie')
    if isinstance(series, dict):
        try:
            series = [series[key] for key in sorted(series, key=int)]
        except ValueError:
            return None
    if not isinstance(series, list):
        return None
    counts = [finite_measurement(entry.get('Count')) if isinstance(entry, dict) else None for entry in series]
    if not counts or any(count is None for count in counts):
        return None
    return counts[:-1] if len(counts) > 1 else counts


def throughput_steadiness(run_dir, row):
    result = dict(collapse_fraction=COLLAPSE_FRACTION, tail_stall_max_ms=TAIL_STALL_MAX_MS, tail_stall_p99_ms=TAIL_STALL_P99_MS, files=[], reasons=[], annotations=[],
                  method='per-second request counts of the raw timed client JSON without the trailing partial second; a second below half of the run median is a throughput collapse and invalidates; a maximum latency above 100 ms with p99 under 1 ms is annotated tail_stall')
    for path in sorted(Path(run_dir).glob('*/%s.json' % row['key'])):
        entry = dict(path=str(path.relative_to(run_dir)), seconds=0, median=None, minimum=None, collapsed=[], max_ms=None, p99_ms=None)
        try:
            totals = json.loads(path.read_text())['ALL STATS']['Totals']
            if not isinstance(totals, dict):
                raise ValueError('totals')
        except (OSError, ValueError, KeyError, TypeError):
            entry['unreadable'] = True
            result['reasons'].append('throughput_series_unreadable')
            result['files'].append(entry)
            continue
        counts = per_second_counts(totals)
        if counts is None:
            result['reasons'].append('throughput_series_unmeasured')
        else:
            median = statistics.median(counts)
            entry.update(seconds=len(counts), median=median, minimum=min(counts),
                         collapsed=[dict(second=index, count=count) for index, count in enumerate(counts) if count < COLLAPSE_FRACTION * median][:20])
            if entry['collapsed']:
                result['reasons'].append('throughput_collapse')
        percentiles = totals.get('Percentile Latencies')
        entry['max_ms'] = finite_measurement(totals.get('Max Latency'))
        entry['p99_ms'] = finite_measurement(percentiles.get('p99.00')) if isinstance(percentiles, dict) else None
        if entry['max_ms'] is not None and entry['p99_ms'] is not None and entry['max_ms'] > TAIL_STALL_MAX_MS and entry['p99_ms'] < TAIL_STALL_P99_MS:
            result['annotations'].append('tail_stall')
        result['files'].append(entry)
    result['reasons'] = sorted(set(result['reasons']))
    result['annotations'] = sorted(set(result['annotations']))
    return result


def throughput_series(run_dir, row):
    paths = sorted(Path(run_dir).glob('*/%s.json' % row['key']))
    if not paths:
        return dict(available=False, reason='no raw timed client output')
    try:
        result = metrics.memtier_series(json.loads(paths[-1].read_text()))
    except (OSError, ValueError):
        return dict(available=False, reason='unreadable raw timed client output', path=str(paths[-1].relative_to(run_dir)))
    result['path'] = str(paths[-1].relative_to(run_dir))
    return result


def role_cpu_shares(samples, roles, owners=(), key=None):
    owner = timed_client(owners, key) if key else None
    window = samples
    if owner:
        window = [s for s in samples if any(p.get('pid') == owner['pid'] and p.get('start_ticks') == owner['process'].get('start_ticks') for p in s.get('owned_processes', []))] or samples
    result = dict(window='timed client lifetime' if owner and window is not samples else 'whole case', samples=len(window), roles={})
    for role, cpus in roles.items():
        columns = {name: [] for name in metrics.CPU_FIELDS}
        for sample in window:
            rows = [share for share in ((sample.get('cpu_share_pct') or {}).get('cpu%d' % cpu) for cpu in sorted(cpus)) if share]
            if rows:
                for name in metrics.CPU_FIELDS:
                    columns[name].append(sum(share[name] for share in rows) / len(rows))
        result['roles'][role] = {name: statistics.median(values) if values else None for name, values in columns.items()}
    return result


def result_status(directory, row, returncode, reasons, expected_plan=None):
    try:
        summary = load(directory / 'summary.json')
        lines = (directory / 'records.jsonl').read_text().splitlines()
        records = [json.loads(line) for line in lines]
        if not summary['meta']['complete'] or len(records) != 1:
            raise ValueError('missing completion or unexpected record count')
        target = summary['meta']['targets'][row['target']]
        record = records[0]
        if record.get('target') != row['target']:
            raise ValueError('record target mismatch')
        if record.get('scenario') != row['name'] or record.get('suite') != row['suite']:
            raise ValueError('record case identity mismatch')
        if 'error' in record or returncode:
            return 'failed', dict(record=record, target=target, reasons=reasons)
        if 'skipped' in record or target['status'] == 'skipped':
            return 'skipped', dict(record=record, target=target, reasons=reasons)
        if target['status'] != 'ok':
            return 'failed', dict(record=record, target=target, reasons=reasons)
        if expected_plan is not None:
            observed = load(directory / 'plan.json')['items']
            expected = expected_plan['items'][0]
            if len(observed) != 1 or observed[0] != expected:
                raise ValueError('observed plan workload/resource mismatch')
        if not isinstance(record.get('ops_per_sec'), (int, float)) or not math.isfinite(record['ops_per_sec']) or record['ops_per_sec'] <= 0:
            raise ValueError('no valid completed throughput record')
        return 'invalid' if reasons else 'successful', dict(record=record, target=target, reasons=reasons)
    except (OSError, ValueError, KeyError, TypeError) as error:
        return 'failed' if returncode else 'invalid', dict(error='partial or invalid harness output: ' + str(error), reasons=reasons)


def stop_group(child):
    if child.poll() is not None:
        return
    os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=20)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=10)


def cleanup_containers(run_id, env=None):
    try:
        done = subprocess.run(['docker', 'ps', '-aq', '--filter', 'label=eski-bench=' + run_id], capture_output=True, text=True, timeout=15, env=env)
        if done.returncode:
            return dict(ok=False, stderr=done.stderr)
        ids = done.stdout.split()
        if ids:
            done = subprocess.run(['docker', 'rm', '-f', *ids], capture_output=True, text=True, timeout=30, env=env)
        return dict(ok=done.returncode == 0, containers=ids, stderr=done.stderr)
    except (OSError, subprocess.TimeoutExpired) as error:
        return dict(ok=False, error=str(error))


class Scheduler:
    def __init__(self, args, model, reader, clock=time, cleanup=cleanup_containers):
        self.args, self.model, self.reader, self.clock, self.cleanup = args, model, reader, clock, cleanup
        if cleanup is cleanup_containers:
            self.cleanup = lambda run_id: cleanup_containers(run_id, model['env'])
        self.output = Path(args.output)
        self.state = None
        self.interrupted = False

    def save(self, event):
        self.state['updated_at'] = self.clock.time()
        metrics.append_json(self.output / 'events.jsonl', dict(event=event, at=self.state['updated_at'], state=self.state['state']))
        atomic(self.output / 'checkpoint.json', self.state)
        publish(self.output, self.state)

    def initialize(self, resume):
        path = self.output / 'checkpoint.json'
        identity_path = self.output / 'identity.json'
        if path.exists():
            self.state = load(path)
            if not resume:
                raise ValueError('checkpoint exists; use resume or a fresh output directory')
            if self.state['identity'] != self.model['identity']['sha256'] or load(identity_path) != self.model['identity']:
                raise ValueError('immutable experiment identity mismatch; no cases started')
            expected = schedule(self.model['plan'], self.model['targets'], self.args.repetitions)
            if len(self.state['cases']) != len(expected):
                raise ValueError('checkpoint schedule changed')
            for row, original in zip(self.state['cases'], expected):
                if any(row.get(key) != original[key] for key in ('id', 'index', 'key', 'name', 'suite', 'target', 'repetition')):
                    raise ValueError('checkpoint case order or identity changed')
                if row['state'] not in TERMINAL | {'pending', 'running', 'interrupted'}:
                    raise ValueError('invalid checkpoint case state')
                if row['state'] in TERMINAL and (not row['attempts'] or row['attempts'][-1].get('state') != row['state'] or not row['attempts'][-1].get('artifacts_sha256')):
                    raise ValueError('terminal checkpoint lacks durable result evidence')
            for row in self.state['cases']:
                for old in row['attempts']:
                    if old.get('artifacts_sha256'):
                        directory = self.output / old['directory']
                        if sha(directory / 'artifacts.json') != old['artifacts_sha256']:
                            raise ValueError('case artifact inventory changed: ' + row['id'])
                        for name, info in load(directory / 'artifacts.json').items():
                            if sha(contained(directory, name)) != info['sha256']:
                                raise ValueError('case artifact changed: ' + row['id'] + '/' + name)
                if row['state'] == 'running':
                    attempt = row['attempts'][-1]
                    process = attempt.get('harness_process')
                    current = metrics.process(process['pid']) if process else None
                    same_boot = attempt.get('boot_id') == metrics.read('/proc/sys/kernel/random/boot_id')
                    if same_boot and current and current['state'] != 'Z' and current['start_ticks'] == process['start_ticks']:
                        os.killpg(current['group'], signal.SIGTERM)
                        deadline = self.clock.monotonic() + 25
                        while (metrics.process(current['pid']) or {}).get('state') not in (None, 'Z') and self.clock.monotonic() < deadline:
                            self.clock.sleep(.1)
                        if (metrics.process(current['pid']) or {}).get('state') not in (None, 'Z'):
                            raise ValueError('owned interrupted harness still exists; cleanup required')
                    attempt['cleanup'] = self.cleanup(attempt['run_id'])
                    attempt['state'], row['state'] = 'interrupted', 'interrupted'
                    attempt['finished_at'] = self.clock.time()
                    self.state['last_case_end'] = attempt['finished_at']
                    self.save('recovered-interruption')
                if row['attempts'] and row['state'] != 'running' and not row['attempts'][-1].get('cleanup', {}).get('ok', False):
                    row['attempts'][-1]['cleanup'] = self.cleanup(row['attempts'][-1]['run_id'])
                    if not row['attempts'][-1]['cleanup']['ok']:
                        self.state['state'] = 'paused'
                        self.save('owned-cleanup-blocked')
                        raise ValueError('owned interrupted container cleanup incomplete; no new work admitted')
        else:
            if resume and not identity_path.exists():
                raise ValueError('no checkpoint to resume')
            if identity_path.exists() and load(identity_path) != self.model['identity']:
                raise ValueError('identity exists without checkpoint and differs')
            if any(p.name not in ('identity.json', 'original-plan.json', '.scheduler.lock') for p in self.output.iterdir()):
                raise ValueError('new experiment output must be empty')
            atomic(identity_path, self.model['identity'])
            atomic(self.output / 'original-plan.json', self.model['plan'])
            self.state = dict(schema=SCHEMA, identity=self.model['identity']['sha256'], state='ready',
                              cases=schedule(self.model['plan'], self.model['targets'], self.args.repetitions), last_case_end=None)
            self.save('created')

    def observe(self, *arguments):
        sample = self.reader.sample(*arguments)
        sample['power_source'] = self.args.power_source
        return sample

    def gate(self, row):
        self.state['state'] = 'cooling'
        self.save('cooling-started')
        start = self.clock.monotonic()
        stable = None
        while not self.interrupted:
            sample = self.observe()
            problems = sample_problems(sample, self.args, True)
            problems += policy_problems(sample, self.model['identity']['host']['frequency_policy'])
            free = shutil.disk_usage(self.output).free
            if free < self.args.min_free_bytes:
                problems.append('disk_pressure')
            if self.state['last_case_end'] is not None and self.clock.time() - self.state['last_case_end'] < self.args.min_rest:
                problems.append('minimum_rest')
            metrics.append_json(self.output / 'gates.jsonl', dict(case=row['id'], sample=sample, free_bytes=free, problems=problems))
            now = self.clock.monotonic()
            stable = (stable if stable is not None else now) if not problems else None
            if stable is not None and now - stable >= self.args.stable_seconds:
                return True
            if any(p in problems for p in ('package_sensor_unavailable', 'disk_pressure')) or now - start >= self.args.max_wait:
                self.state['state'] = 'paused'
                self.state['pause'] = dict(case=row['id'], reasons=problems, waited=now - start)
                self.save('cooling-paused')
                return False
            self.clock.sleep(self.args.sample_seconds)
        self.state['state'] = 'paused'
        self.save('interrupted-before-case')
        return False

    def execute(self, row):
        directory = self.output / 'cases' / row['id'] / ('attempt-%03d' % (len(row['attempts']) + 1))
        directory.mkdir(parents=True)
        for parent in [directory, *directory.parents]:
            descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            if parent == self.output:
                break
        subset = resolved_plan(self.model, row, sorted(self.model['roles']['client']))
        atomic(directory / 'plan.json', subset)
        run_id = 'exam-' + uuid.uuid4().hex
        attempt = dict(directory=str(directory.relative_to(self.output)), state='running', started_at=self.clock.time(),
                       run_id=run_id, boot_id=metrics.read('/proc/sys/kernel/random/boot_id'),
                       resolved_plan_sha256=sha(directory / 'plan.json'), resource_policy=self.args.resource_policy,
                       original_resources=[dict(cpus=c.get('cpus'), requested_cpus=c.get('requested_cpus')) for c in self.model['plan']['items'][row['index']]['clients']],
                       resolved_resources=[c.get('cpus') for c in subset['items'][0]['clients']])
        needs = client_needs(self.model['plan']['items'][row['index']]['clients'], sorted(self.model['roles']['client']))
        attempt['resource_admission'] = dict(requested=needs, pool_size=len(self.model['roles']['client']),
                                             oversubscribed=any(n > len(self.model['roles']['client']) for n in needs) or sum(needs) > len(self.model['roles']['client']),
                                             policy=self.args.resource_policy)
        row['attempts'].append(attempt)
        row['state'], self.state['state'] = 'running', 'running'
        self.save('case-starting')
        env = self.model['env'].copy()
        images = self.model['profile']['images']
        for name, value in dict(BENCH_SERVER_CPUS=self.args.server_cpus, BENCH_CLIENT_CPUS=self.args.client_cpus,
                                BENCH_SERVER_MEMORY=self.args.server_memory, BENCH_CLIENT_MEMORY=self.args.client_memory,
                                BENCH_SERVER_MAXMEMORY=str(self.args.maxmemory), BENCH_REDIS_IMAGE=images['cli'],
                                BENCH_DRAGONFLY_THREADS=str(self.model['identity']['config']['dragonfly_threads']),
                                BENCH_MEMTIER_IMAGE=images['memtier'], BENCH_RUN_ID=run_id,
                                BENCH_SPEC_CACHE=str(directory / 'probe-cache'),
                                BENCH_OUTPUT_DIR=str(directory / 'run'), BENCH_OWNER_EVENTS=str(directory / 'owners.jsonl')).items():
            env[name] = value
        for role, name in (('valkey', 'BENCH_VALKEY_IMAGE'), ('dragonfly', 'BENCH_DRAGONFLY_IMAGE'), ('eski-docker', 'BENCH_ESKI_IMAGE')):
            if role in images:
                env[name] = images[role]
        if row['target'] == 'eski':
            env['ESKI_BIN'] = str(contained(self.model['root'], self.model['profile']['native']['path']))
        argv = ['bash', str(self.model['harness']), '--targets', row['target'], '--scenarios', 'none', '--plan', str(directory / 'plan.json')]
        attempt['argv'] = argv
        samples = []
        with (directory / 'harness.log').open('wb') as output:
            gate_read, gate_write = os.pipe()
            launcher = 'import os,sys; token=os.read(int(sys.argv[1]),1); os.close(int(sys.argv[1])); os.execvpe(sys.argv[2],sys.argv[2:],os.environ) if token==b"!" else sys.exit(125)'
            child = subprocess.Popen(['python3', '-c', launcher, str(gate_read), *argv], pass_fds=(gate_read,), cwd=self.model['root'], env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            os.close(gate_read)
            try:
                attempt['harness_process'] = metrics.process(child.pid)
                if not attempt['harness_process']:
                    raise ValueError('cannot record owned launch identity before granting execution')
                self.save('case-launched')
                os.write(gate_write, b'!')
                os.close(gate_write)
                gate_write = None
                while True:
                    owners = owner_rows(directory / 'owners.jsonl')
                    sample = self.observe(child.pid, owners)
                    samples.append(sample)
                    metrics.append_json(directory / 'metrics.jsonl', sample)
                    if shutil.disk_usage(self.output).free < self.args.min_free_bytes:
                        attempt['interruption_reason'] = 'disk_pressure'
                        self.interrupted = True
                    if self.interrupted:
                        stop_group(child)
                    if child.poll() is not None:
                        break
                    self.clock.sleep(self.args.sample_seconds)
            finally:
                if gate_write is not None:
                    os.close(gate_write)
                if child.poll() is None:
                    stop_group(child)
                    attempt['cleanup'] = self.cleanup(run_id)
        owners = owner_rows(directory / 'owners.jsonl')
        reasons = validity(samples, owners, self.args, self.model['identity']['host']['frequency_policy'])
        quality = dict(kernel_threads=reserved_kernel_threads(samples, self.args), throughput_steadiness=throughput_steadiness(directory / 'run', row))
        reasons = sorted(set(reasons) | set(quality['throughput_steadiness']['reasons']))
        if self.args.max_client_utilization_pct is not None:
            quality['client_headroom'] = client_headroom(samples, owners, row, self.model['identity']['config']['client_budget_cores'], self.args.max_client_utilization_pct)
            reasons = sorted(set(reasons) | set(quality['client_headroom']['reasons']))
        if self.args.max_latency_seconds is not None:
            quality['latency_sanity'] = latency_sanity(directory / 'run', row, self.args.max_latency_seconds)
            reasons = sorted(set(reasons) | set(quality['latency_sanity']['reasons']))
        quality['throughput_series'] = throughput_series(directory / 'run', row)
        attempt['cleanup'] = self.cleanup(run_id)
        if self.interrupted or child.returncode in (-signal.SIGTERM, -signal.SIGINT, 130, 143):
            state, details = 'interrupted', dict(reasons=reasons, returncode=child.returncode)
        else:
            state, details = result_status(directory / 'run', row, child.returncode, reasons, subset)
        if not attempt['cleanup']['ok']:
            state = 'invalid'
            details.setdefault('reasons', []).append('owned_cleanup_incomplete')
            self.interrupted = True
        details['annotations'] = sorted(set(sum((entry.get('annotations', []) for entry in quality.values()), [])))
        if 'client_headroom' in quality:
            details['client_utilization_pct'] = quality['client_headroom']['utilization_pct']
        attempt.update(state=state, details=details, returncode=child.returncode, finished_at=self.clock.time(),
                       telemetry=dict(samples=len(samples), ownership_events=len(owners),
                                      maximum_kind='sampled process/RSS maxima; cgroup peaks have per-observation scope',
                                      raw='metrics.jsonl', ownership='owners.jsonl'))
        peaks = {}
        for sample in samples:
            for proc in sample.get('owned_processes', []):
                key = '%s:%s' % (proc['pid'], proc['start_ticks'])
                old = peaks.setdefault(key, dict(pid=proc['pid'], start_ticks=proc['start_ticks'], sampled_max_rss_bytes=None, sampled_max_cpu_cores=None))
                for source, field in (('rss_bytes', 'sampled_max_rss_bytes'), ('cpu_cores', 'sampled_max_cpu_cores')):
                    if proc.get(source) is not None:
                        old[field] = max(old[field] or 0, proc[source])
        attempt['telemetry']['process_sampled_maxima'] = list(peaks.values())
        attempt['telemetry']['measurement_quality'] = quality
        attempt['telemetry']['role_cpu_share_pct'] = role_cpu_shares(samples, self.model['roles'], owners, row['key'])
        attempt['telemetry']['ownership_available'] = {role: any(o.get('role') == role and o.get('process') for o in owners) for role in ('server', 'client')}
        attempt['telemetry']['unavailable'] = [role + ' ownership not observed; no exclusive process/cgroup measurement claimed' for role, available in attempt['telemetry']['ownership_available'].items() if not available]
        attempt['telemetry']['server_pre_stop_cgroup_peaks'] = [dict(pid=o.get('pid'), container=o.get('container'), artifact_dir=o.get('artifact_dir'), memory_peak_bytes=o.get('cgroup', {}).get('memory.peak'), scope=o.get('peak_scope')) for o in owners if o.get('container') and o.get('event') == 'before-stop' and o.get('role') == 'server']
        if state == 'successful':
            target = details['target']
            expected = images.get(row['target'])
            if expected and target.get('image_id') != expected:
                attempt['state'] = state = 'invalid'
                details['reasons'].append('observed_target_image_mismatch')
        atomic(directory / 'result.json', attempt)
        attempt['artifacts_sha256'] = durable_artifacts(directory)
        row['state'] = state
        self.state['last_case_end'] = attempt['finished_at']
        self.state['state'] = 'paused' if self.interrupted or state == 'interrupted' else 'ready'
        self.save('case-' + state)

    def run(self, resume=False):
        self.output.mkdir(parents=True, exist_ok=True)
        with Lock(self.args.host_lock), Lock(self.output / '.scheduler.lock'):
            self.initialize(resume)
            self.state['controller'] = metrics.process(os.getpid())
            self.state['controller_boot_id'] = metrics.read('/proc/sys/kernel/random/boot_id')
            self.save('controller-ready')
            if any(row['state'] == 'interrupted' for row in self.state['cases']) and not self.args.retry_interrupted:
                self.state['state'] = 'paused'
                self.save('explicit-interrupted-retry-required')
                return self.state
            for row in self.state['cases']:
                if row['state'] in TERMINAL:
                    continue
                if not self.gate(row):
                    return self.state
                self.execute(row)
                if self.interrupted or row['state'] == 'interrupted':
                    return self.state
            self.state['state'] = 'finished' if all(r['state'] == 'successful' for r in self.state['cases']) else 'finished-with-nonsuccess'
            self.save('finished')
            return self.state


def parser():
    p = argparse.ArgumentParser(description='Resumable per-case engine scheduler; never changes declared workload argv or durations.')
    p.add_argument('command', choices=('inspect', 'status', 'run', 'resume'))
    p.add_argument('--plan', type=Path)
    p.add_argument('--profile', type=Path)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--targets')
    for role in ('server', 'client', 'control'):
        p.add_argument('--' + role + '-cpus')
    p.add_argument('--server-memory', default='8g')
    p.add_argument('--client-memory', default='2g')
    p.add_argument('--maxmemory', type=int, default=6 * 1024 ** 3)
    p.add_argument('--repetitions', type=int, default=1)
    p.add_argument('--package-sensor')
    p.add_argument('--sensor-chip', default='coretemp')
    p.add_argument('--sensor-label', default='Package id 0')
    p.add_argument('--cool-temp-c', type=float, default=50)
    p.add_argument('--max-temp-c', type=float, default=90)
    p.add_argument('--min-idle', type=float, default=95)
    p.add_argument('--min-rest', type=float, default=10)
    p.add_argument('--stable-seconds', type=float, default=15)
    p.add_argument('--max-wait', type=float, default=1200)
    p.add_argument('--sample-seconds', type=float, default=2)
    p.add_argument('--min-free-bytes', type=int, default=5 * 1024 ** 3)
    p.add_argument('--resource-policy', choices=('strict', 'allow-oversubscription'), default='strict')
    p.add_argument('--power-source', choices=POWER_SOURCES, default='mains', help='mains requires an online Mains power supply device in every sample; no-power-supply-devices requires that the machine exposes no power supply device at all')
    p.add_argument('--max-client-utilization-pct', type=float, default=None, help='annotate a measurement as client_limited when its owned timed client uses more than this share of the logical client CPU budget; unobserved ownership invalidates')
    p.add_argument('--max-latency-seconds', type=float, default=None, help='invalidate a measurement whose raw client JSON reports a maximum latency beyond this run lifetime bound')
    p.add_argument('--host-lock', type=Path, default=Path(tempfile.gettempdir()) / ('eski-exam-%d.lock' % os.getuid()))
    p.add_argument('--retry-interrupted', action='store_true', help='explicitly start a new preserved attempt only for interrupted cases; failed/invalid/skipped are never retried')
    return p


def main():
    p = parser()
    args = p.parse_args()
    try:
        args.output = args.output.resolve()
        if args.command == 'status':
            checkpoint = args.output / 'checkpoint.json'
            print(json.dumps(status_view(load(checkpoint) if checkpoint.exists() else None), indent=2))
            return 0
        if any(getattr(args, name) is None for name in ('plan', 'profile', 'targets', 'server_cpus', 'client_cpus', 'control_cpus')):
            raise ValueError('plan/profile/targets and all three explicit CPU sets are required')
        reader = metrics.Reader(args.package_sensor, args.sensor_chip, args.sensor_label)
        model = validate(args, reader)
        if args.command == 'inspect':
            print(json.dumps(dict(identity=model['identity'], sample=dict(reader.sample(), power_source=args.power_source), planned_cases=len(model['plan']['items']) * len(model['targets']) * args.repetitions), indent=2))
            return 0
        missing = [name for name, data in model['identity']['tools'].items() if data['path'] is None]
        if missing:
            raise ValueError('required tools unavailable: ' + ','.join(missing))
        os.sched_setaffinity(0, model['roles']['control'])
        scheduler = Scheduler(args, model, reader)
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, lambda *_: setattr(scheduler, 'interrupted', True))
        result = scheduler.run(args.command == 'resume')
        print(json.dumps(dict(state=result['state'], identity=result['identity'], counts={s: sum(r['state'] == s for r in result['cases']) for s in sorted(TERMINAL | {'pending', 'interrupted'})}), indent=2))
        return 0 if result['state'] == 'finished' else 2
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps(dict(state='rejected', error=str(error))), flush=True)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
