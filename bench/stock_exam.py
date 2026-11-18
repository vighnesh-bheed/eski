import argparse
import copy
import hashlib
import json
import math
import os
import shutil
import signal
import statistics
import subprocess
import sys
import time
import traceback
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / 'testbed'))
import exam_metrics as metrics
import exam_workflow
import plans
from baseline_run import GUARD_DIR, NOT_QUALIFYING, finish_guard, host_record, start_guard

SCHEMA = 'eski-baseline-stock-v1'
RUNNER = ('run.sh', 'spec.py', 'compare.py', 'exam_scheduler.py', 'exam_metrics.py')
TARGETS = ('eski', 'redis', 'valkey', 'dragonfly')
REHEARSAL_WORKLOADS = ('get64-p1', 'zscore16-p1')
PERCENTILES = '50,90,95,99,99.5,99.9,99.95,99.99,100'
SENSORS = (('coretemp', 'Package id 0'), ('k10temp', 'Tctl'), ('zenpower', 'Tdie'), ('k10temp', 'Tdie'))
SPEC_VERSION = 'v0.3.46'
SPEC_SHA256 = '763f7dd9d453050c0cebe174437e244eeaf9a185e64de18f70bad20ed07e0ca0'
SPEC_URL = 'https://github.com/redis/redis-benchmarks-specification/archive/refs/tags/v0.3.46.tar.gz'
ENGINE_SENTENCE = ('Redis, Valkey and Dragonfly each run in a fresh container per measurement with the same CPU set, a {memory} memory and swap cap, '
                   '{maxmemory} bytes of maxmemory, persistence off and host loopback networking; Dragonfly runs one proactor thread on its single core. '
                   'Eski runs natively, as the qualified release binary, pinned to the same server CPU with the same maxmemory and persistence off and '
                   'no container memory cap; its memory is its resident and peak resident size read before it stops, and the competitors\' is the '
                   'kernel memory peak of their container and the peak resident size of the server process.')


class Refused(Exception):
    pass


def sha(path):
    value = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            value.update(block)
    return value.hexdigest()


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_name('.' + path.name + '.part')
    pending.write_text(json.dumps(value, indent=1, sort_keys=True, allow_nan=False) + '\n')
    pending.replace(path)


def load(path):
    return json.loads(Path(path).read_text())


def interrupted(signum, frame):
    raise KeyboardInterrupt


def sensor():
    for chip, label in SENSORS:
        if metrics.Reader(None, chip, label).sensor()['available']:
            return chip, label
    return None


def power_source():
    supplies = metrics.power_supplies()
    if supplies is None:
        return None
    if any(device['type'] == 'Mains' for device in supplies.values()):
        return 'mains'
    return 'no-power-supply-devices' if not supplies else None


def roles(args, threads):
    server = sorted(metrics.cpu_set(args.server_cpus))
    client = sorted(metrics.cpu_set(args.client_cpus))
    if set(server) & set(client):
        raise Refused('server and client CPUs overlap')
    if len(client) < threads:
        raise Refused('the method needs %d client CPUs and %d are given' % (threads, len(client)))
    spare = sorted(os.sched_getaffinity(0) - set(server) - set(client))
    spare = [cpu for cpu in spare if cpu != 0] or spare
    if not spare:
        raise Refused('no CPU outside the server and client roles is available for the controller')
    return dict(server=[server[0]], client=client[:threads], control=[spare[-1]])


def base_design(client_cpus):
    if len(metrics.cpu_set(client_cpus)) >= 4:
        return HERE / 'testbed/designs/cloud-four-client-cores.json'
    return HERE / 'testbed/design.json'


def effective_design(args, role_cpus, chip, label, source):
    design = load(base_design(args.client_cpus))
    resources = design['resources']
    resources.update(server_cpus=','.join(map(str, role_cpus['server'])), client_cpus=','.join(map(str, role_cpus['client'])),
                     control_cpus=','.join(map(str, role_cpus['control'])), server_memory=args.server_memory, client_memory=args.client_memory,
                     maxmemory=args.maxmemory, dragonfly_threads=1)
    gates = design['gates']
    gates.update(sensor_chip=chip, sensor_label=label, power_source=source, idle_watch_seconds=600)
    if args.profile == 'rehearsal':
        design['dataset'].update(keys=2000, sample_keys=[1, 1000, 2000])
        design['client'].update(warmup_seconds=1, test_seconds=2, timeout_seconds=120)
        design['repetitions'] = 1
        design['workloads'] = [w for w in design['workloads'] if w['key'] in REHEARSAL_WORKLOADS]
        design['calibration']['workloads'] = [REHEARSAL_WORKLOADS[0]]
        gates.update(min_rest=0, stable_seconds=0, max_wait=30, sample_seconds=1, min_free_bytes=1 << 30, idle_watch_seconds=3)
    design['methodology']['engines'] = ENGINE_SENTENCE.format(memory=args.server_memory, maxmemory=args.maxmemory)
    design['methodology']['latency'] = (design['methodology']['latency'] + ' Every timed run keeps its raw memtier output with the full histogram '
                                        'and the percentiles ' + PERCENTILES + '.')
    return plans.validate(design)


def full_histogram(plan):
    for item in plan['items']:
        for client in item['clients']:
            client['argv'] = [part for part in client['argv'] if part != '--hide-histogram' and not part.startswith('--print-percentiles')]
            client['argv'].append('--print-percentiles=' + PERCENTILES)
    return plan


def workspace(root, binary):
    base = root / 'workspace'
    (base / 'bench').mkdir(parents=True)
    (base / 'bin').mkdir()
    for name in RUNNER:
        shutil.copy2(HERE / name, base / 'bench' / name)
    shutil.copy2(binary, base / 'bin/eski')
    (base / 'bin/eski').chmod(0o755)
    return base


def profile_for(base, args, ports, digest):
    files = {str(path.relative_to(base)): sha(path) for path in sorted(base.rglob('*')) if path.is_file()}
    images = dict(args.image)
    profile = dict(schema='eski-exam-profile-v1', source_revision='eski-binary-sha256:' + digest, source_sha256=digest, harness='bench/run.sh',
                   dragonfly_threads=1, images=dict(redis=images['redis'], valkey=images['valkey'], dragonfly=images['dragonfly'],
                                                     memtier=images['memtier'], cli=images['redis']),
                   files=files, native=dict(path='bin/eski', files={}), ports=ports)
    write(base / 'profile.json', profile)
    return profile


def scheduler_argv(base, root, phase, design, targets, advisory):
    resources, gates = design['resources'], design['gates']
    repetitions = design['repetitions'] if phase == 'benchmark' else design['calibration']['repetitions']
    pool = ','.join(resources[role + '_cpus'] for role in ('server', 'client', 'control'))
    argv = ['taskset', '--cpu-list', pool, sys.executable, '-B', str(base / 'bench/exam_scheduler.py'), 'run',
            '--plan', str(base / 'plans' / phase / 'plan.json'), '--profile', str(base / 'profile.json'),
            '--output', str(root / phase / 'results'), '--host-lock', str(root / 'control/child-host.lock'), '--targets', ','.join(targets),
            '--repetitions', str(repetitions), '--power-source', gates['power_source']]
    for name in ('server_cpus', 'client_cpus', 'control_cpus', 'server_memory', 'client_memory', 'maxmemory', 'resource_policy'):
        argv += ['--' + name.replace('_', '-'), str(resources[name])]
    for name in plans.GATES:
        argv += ['--' + name.replace('_', '-'), str(gates[name])]
    if advisory:
        argv.append('--advisory-gates')
    return argv


def run_scheduler(argv, root, phase, log):
    entry = Path(os.environ[GUARD_DIR]) / ('exam-' + phase)
    entry.write_text(str(root / phase / 'results') + '\n')
    with open(log, 'ab') as output:
        process = subprocess.Popen(argv, stdout=output, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, cwd=str(root))
        try:
            code = process.wait()
        except KeyboardInterrupt:
            try:
                process.wait(timeout=90)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise
    checkpoint = root / phase / 'results/checkpoint.json'
    state = load(checkpoint) if checkpoint.exists() else None
    if state is not None and not any(row['state'] == 'running' for row in state['cases']):
        entry.unlink()
    return code, state


def owner_memory(directory):
    peaks = []
    path = Path(directory) / 'owners.jsonl'
    if not path.exists():
        return peaks
    for line in path.read_text().splitlines():
        try:
            owner = json.loads(line)
        except ValueError:
            continue
        if owner.get('event') == 'before-stop' and owner.get('role') == 'server':
            peaks.append(dict(container=owner.get('container'), pid=owner.get('pid'), peak_rss_bytes=(owner.get('status') or {}).get('VmHWM'),
                              rss_bytes=(owner.get('status') or {}).get('VmRSS'), cgroup_peak_bytes=(owner.get('cgroup') or {}).get('memory.peak'),
                              attribution=owner.get('cgroup_attribution')))
    return peaks


def engine_memory(directory):
    found = {}
    for path in sorted(Path(directory).glob('run/*/*.info_memory.txt')):
        for line in path.read_text(errors='replace').splitlines():
            name, _, value = line.partition(':')
            if name in ('used_memory', 'used_memory_rss', 'used_memory_peak', 'used_memory_dataset'):
                found[name] = value.strip()
    return found


def phase_summary(root, phase, state):
    if state is None:
        return dict(state='not started')
    measurements = []
    cells = {}
    for row in state['cases']:
        attempt = row['attempts'][-1] if row['attempts'] else {}
        details = attempt.get('details') or {}
        record = details.get('record') or {}
        directory = root / phase / 'results' / attempt['directory'] if attempt.get('directory') else None
        entry = dict(id=row['id'], workload=row['key'], target=row['target'], repetition=row['repetition'], state=row['state'],
                     reasons=details.get('reasons') or [], annotations=details.get('annotations') or [],
                     ops_per_sec=record.get('ops_per_sec'), p50_ms=record.get('p50_ms'), p99_ms=record.get('p99_ms'), p999_ms=record.get('p999_ms'),
                     max_ms=record.get('max_ms'), directory=str(directory.relative_to(root)) if directory else None,
                     memory=owner_memory(directory) if directory else [], engine_memory=engine_memory(directory) if directory else {},
                     client_utilization_pct=details.get('client_utilization_pct'))
        measurements.append(entry)
        cell = cells.setdefault('%s/%s' % (row['key'], row['target']), dict(workload=row['key'], target=row['target'], valid=[], states=[]))
        cell['states'].append(row['state'])
        if row['state'] == 'successful' and isinstance(entry['ops_per_sec'], (int, float)):
            cell['valid'].append(entry['ops_per_sec'])
    for cell in cells.values():
        values = cell.pop('valid')
        cell.update(valid_repetitions=len(values), planned_repetitions=len(cell['states']),
                    ops_per_sec_median=statistics.median(values) if values else None,
                    ops_per_sec_min=min(values) if values else None, ops_per_sec_max=max(values) if values else None)
    counts = {}
    for row in state['cases']:
        counts[row['state']] = counts.get(row['state'], 0) + 1
    return dict(state=state.get('state'), counts=counts, planned=len(state['cases']), measurements=measurements, cells=sorted(cells.values(), key=lambda c: (c['workload'], c['target'])))


def idle(root, design, profile):
    resources, gates = design['resources'], design['gates']
    reader = metrics.Reader(None, gates['sensor_chip'], gates['sensor_label'])
    cpus = metrics.cpu_set(resources['server_cpus']) | metrics.cpu_set(resources['client_cpus'])
    samples = root / 'control/idle-watch.jsonl'
    result = exam_workflow.idle_watch(reader, gates['idle_watch_seconds'], gates['sample_seconds'], cpus, record=lambda row: metrics.append_json(samples, row))
    roles_map = {role: metrics.cpu_set(resources[role + '_cpus']) for role in ('server', 'client', 'control')}
    result['reason'] = None if result['passed'] else exam_workflow.idle_watch_reason(result, roles_map) if result['offenders'] else 'interrupted'
    write(root / 'control/idle-watch.json', result)
    return result


def prepare(args, root):
    chip_label = sensor()
    source = power_source()
    advisory = args.profile == 'rehearsal'
    if chip_label is None and not advisory:
        raise Refused('no package temperature sensor resolves uniquely (coretemp Package id 0, k10temp Tctl or zenpower Tdie); the gates need one')
    if source is None and not advisory:
        raise Refused('the machine lists power supply devices but no Mains device, so neither power gate applies')
    chip, label = chip_label or SENSORS[0]
    threads = load(base_design(args.client_cpus))['client']['threads']
    role_cpus = roles(args, threads)
    os.sched_setaffinity(0, set(role_cpus['control']))
    design = effective_design(args, role_cpus, chip, label, source or 'mains')
    write(root / 'design.json', design)
    first = int(args.ports.split('-')[0])
    ports = dict(redis=first, valkey=first + 1, dragonfly=first + 2, eski=first + 3)
    base = workspace(root, args.eski)
    digest = sha(base / 'bin/eski')
    return dict(design=design, roles=role_cpus, ports=ports, base=base, digest=digest, advisory=advisory, sensor=[chip, label],
                sensor_found=chip_label is not None, power_source=source)


def write_plans(base, design, corrupt=False):
    for phase in plans.PHASES:
        plan = full_histogram(plans.plan(design, phase))
        if corrupt:
            plan['items'][0]['check']['replies'][0]['equals'] += 1
        write(base / 'plans' / phase / 'plan.json', plan)


def exam(args, root, result):
    setup = prepare(args, root)
    design, base = setup['design'], setup['base']
    result.update(design=design, roles=setup['roles'], ports=setup['ports'], eski_sha256=setup['digest'], advisory_gates=setup['advisory'],
                  sensor=setup['sensor'], sensor_found=setup['sensor_found'], power_source=setup['power_source'])
    write_plans(base, design, args.corrupt_check)
    profile_for(base, args, setup['ports'], setup['digest'])
    result['idle_watch'] = idle(root, design, args.profile)
    if not result['idle_watch']['passed'] and not setup['advisory']:
        raise Refused('idle watch held the run: %s' % result['idle_watch']['reason'])
    phases = {}
    result['phases'] = phases
    for phase in plans.PHASES:
        argv = scheduler_argv(base, root, phase, design, list(TARGETS), setup['advisory'])
        code, state = run_scheduler(argv, root, phase, root / ('%s.log' % phase))
        phases[phase] = dict(phase_summary(root, phase, state), scheduler_exit=code, argv=argv)
        if phase == 'calibration':
            valid = state is not None and all(row['state'] == 'successful' for row in state['cases'])
            phases[phase]['all_valid'] = valid
            if not valid and not setup['advisory']:
                raise Refused('calibration did not pass for every engine; the benchmark phase was not started')
    return verdict(phases, setup['advisory'])


def verdict(phases, advisory):
    benchmark = phases['benchmark']
    if not advisory:
        return 0 if benchmark.get('state') == 'finished' else 1
    broken = sum(count for phase in phases.values() for state, count in (phase.get('counts') or {}).items() if state in ('failed', 'skipped'))
    finished = benchmark.get('state') in ('finished', 'finished-with-nonsuccess')
    return 0 if finished and benchmark.get('planned') and not broken else 1


def fits(item, pool):
    needs = [max(1, math.ceil(float(client['requested_cpus']))) if client.get('requested_cpus') else 1 for client in item['clients']]
    return all(need <= pool for need in needs) and (len(needs) == 1 or sum(needs) <= pool)


def spec_select(plan, per_group, rehearsal, max_groups=0, pool=None):
    groups = {}
    for item in plan['items']:
        if pool is not None and not fits(item, pool):
            continue
        for group in item['info'].get('tested_groups') or ['ungrouped']:
            groups.setdefault(group, []).append(item)

    def preload_size(item):
        argv = (item.get('preload') or {}).get('argv') or []
        for index, part in enumerate(argv):
            if part.startswith('--key-maximum='):
                value = part.split('=', 1)[1]
                return int(value) if value.isdigit() else 1 << 40
            if part in ('--key-maximum', '-n') and index + 1 < len(argv) and argv[index + 1].isdigit():
                return int(argv[index + 1])
        return 0

    def rank(item):
        priority = item['info'].get('priority')
        priority = priority if isinstance(priority, int) else 1 << 20
        return (preload_size(item), priority, item['key']) if rehearsal else (priority, preload_size(item), item['key'])
    chosen, keys = [], set()
    names = sorted(groups)
    if max_groups:
        names = sorted(names, key=lambda group: (min(preload_size(item) for item in groups[group]), group))[:max_groups]
    for group in sorted(names):
        for item in sorted(groups[group], key=rank)[:per_group]:
            if item['key'] not in keys:
                keys.add(item['key'])
                chosen.append(item)
    return dict(plan, items=chosen), sorted(names)


def spec(args, root, result):
    setup = prepare(args, root)
    design, base = setup['design'], setup['base']
    result.update(design=design, roles=setup['roles'], ports=setup['ports'], eski_sha256=setup['digest'], advisory_gates=setup['advisory'],
                  sensor=setup['sensor'], power_source=setup['power_source'])
    images = dict(args.image)
    cache = root / 'spec-cache'
    environment = {key: value for key, value in os.environ.items() if not key.startswith('BENCH_') and key != 'ESKI_BIN'}
    environment.update(ESKI_BIN=str(base / 'bin/eski'), BENCH_SPEC_CACHE=str(cache), BENCH_REDIS_IMAGE=images['redis'],
                       BENCH_MEMTIER_IMAGE=images['memtier'], BENCH_PORT_ESKI=str(setup['ports']['eski']), BENCH_PORT_REDIS=str(setup['ports']['redis']),
                       BENCH_RUN_ID='spec-probe-%d' % os.getpid(), PYTHONDONTWRITEBYTECODE='1')
    (Path(os.environ[GUARD_DIR]) / ('label-spec-probe-%d' % os.getpid())).write_text(environment['BENCH_RUN_ID'] + '\n')
    with open(root / 'spec-list.log', 'wb') as log:
        listed = subprocess.run(['bash', str(base / 'bench/run.sh'), '--spec-list'], cwd=str(base), env=environment, stdout=log, stderr=subprocess.STDOUT)
    if listed.returncode:
        raise Refused('bash bench/run.sh --spec-list failed with %d; see spec-list.log' % listed.returncode)
    tree = cache / ('redis-benchmarks-specification-' + SPEC_VERSION.lstrip('v'))
    planned = root / 'spec-plan-all.json'
    clients = design['resources']['client_cpus']
    command = [sys.executable, '-I', str(base / 'bench/spec.py'), 'plan', '--out', str(planned), '--client-cpus', clients,
               '--memtier-image', images['memtier'], '--default-memtier-image', images['memtier'], '--rb-image', images['redis'],
               '--client-timeout', '1800', '--preload-timeout', '3600', '--tree', str(tree), '--release', SPEC_VERSION, '--sha256', SPEC_SHA256,
               '--url', SPEC_URL, '--select', '', '--quick-cap', str(args.spec_test_seconds), '--probe', str(cache / 'eski_commands.json'),
               '--reference', str(cache / 'reference_commands.json')]
    with open(root / 'spec-plan.log', 'wb') as log:
        built = subprocess.run(command, cwd=str(base), env=environment, stdout=log, stderr=subprocess.STDOUT)
    if built.returncode:
        raise Refused('spec.py plan failed with %d; see spec-plan.log' % built.returncode)
    full_plan = load(planned)
    pool = len(metrics.cpu_set(clients))
    chosen, groups = spec_select(full_plan, args.spec_cases_per_group, args.profile == 'rehearsal', args.spec_max_groups, pool)
    every = {group for item in full_plan['items'] for group in item['info'].get('tested_groups') or ['ungrouped']}
    fitting = {group for item in full_plan['items'] if fits(item, pool) for group in item['info'].get('tested_groups') or ['ungrouped']}
    result['spec'] = dict(release=SPEC_VERSION, sha256=SPEC_SHA256, groups=groups, applicable=len(full_plan['items']),
                          chosen=[dict(key=item['key'], name=item['name'], groups=item['info'].get('tested_groups'), test_time_s=item['info'].get('test_time_s'),
                                       declared_test_time_s=item['info'].get('declared_test_time_s')) for item in chosen['items']],
                          skipped=((full_plan.get('suites') or {}).get('spec') or {}).get('skipped'),
                          groups_without_a_case_that_fits_the_client_cpus=sorted(every - fitting), client_cpus=pool)
    if not chosen['items']:
        raise Refused('no applicable specification case')
    spec_design = copy.deepcopy(design)
    spec_design['repetitions'] = args.spec_repetitions
    write(base / 'plans/benchmark/plan.json', dict(schema=plans.PLAN_SCHEMA, items=chosen['items']))
    profile_for(base, args, setup['ports'], setup['digest'])
    result['idle_watch'] = idle(root, design, args.profile)
    if not result['idle_watch']['passed'] and not setup['advisory']:
        raise Refused('idle watch held the run: %s' % result['idle_watch']['reason'])
    argv = scheduler_argv(base, root, 'benchmark', spec_design, list(TARGETS), setup['advisory'])
    code, state = run_scheduler(argv, root, 'benchmark', root / 'benchmark.log')
    result['phases'] = dict(benchmark=dict(phase_summary(root, 'benchmark', state), scheduler_exit=code, argv=argv))
    return verdict(result['phases'], setup['advisory'])


def cooling(chip, label, cool, rest_until, max_wait, advisory):
    deadline = time.monotonic() + max_wait
    reader = metrics.Reader(None, chip, label)
    while True:
        celsius = reader.sensor()['celsius']
        if advisory or (celsius is not None and celsius <= cool and time.monotonic() >= rest_until):
            return 'met' if not advisory else 'advisory (%s C)' % celsius, celsius
        if time.monotonic() >= deadline:
            return 'not met within %d s (package %s C)' % (max_wait, celsius), celsius
        time.sleep(1)


def fill(args, root, result):
    setup = prepare(args, root)
    design, base = setup['design'], setup['base']
    result.update(design=design, roles=setup['roles'], ports=setup['ports'], eski_sha256=setup['digest'], advisory_gates=setup['advisory'],
                  sensor=setup['sensor'], power_source=setup['power_source'], fill_keys=args.fill_keys)
    images = dict(args.image)
    resources, settings = design['resources'], design['fill']
    engines = []
    result['engines'] = engines
    rest_until = 0
    for target in TARGETS:
        directory = root / 'fill' / target
        directory.mkdir(parents=True)
        gate, before = cooling(setup['sensor'][0], setup['sensor'][1], settings['cool_temp_c'], rest_until, settings['max_wait_seconds'], setup['advisory'])
        entry = dict(target=target, gate=gate, package_c_before=before, image_id=images.get(target), started_at=time.time())
        engines.append(entry)
        if not gate.startswith(('met', 'advisory')):
            entry.update(status='skipped', error='cooling gate ' + gate)
            continue
        run_id = 'fill-%d-%s' % (os.getpid(), target)
        environment = {key: value for key, value in os.environ.items() if not key.startswith('BENCH_') and key != 'ESKI_BIN'}
        environment.update(ESKI_BIN=str(base / 'bin/eski'), BENCH_REDIS_IMAGE=images['redis'], BENCH_VALKEY_IMAGE=images['valkey'],
                           BENCH_DRAGONFLY_IMAGE=images['dragonfly'], BENCH_MEMTIER_IMAGE=images['memtier'], BENCH_SERVER_CPUS=resources['server_cpus'],
                           BENCH_CLIENT_CPUS=resources['client_cpus'], BENCH_DRAGONFLY_THREADS='1', BENCH_SERVER_MEMORY=resources['server_memory'],
                           BENCH_CLIENT_MEMORY=resources['client_memory'], BENCH_SERVER_MAXMEMORY=str(resources['maxmemory']),
                           BENCH_OUTPUT_DIR=str(directory / 'run'), BENCH_RUN_ID=run_id, BENCH_OWNER_EVENTS=str(directory / 'owners.jsonl'),
                           BENCH_SPEC_CACHE=str(directory / 'probe-cache'), BENCH_FILL_KEYS=str(args.fill_keys), PYTHONDONTWRITEBYTECODE='1')
        for name, port in setup['ports'].items():
            environment['BENCH_PORT_' + name.upper()] = str(port)
        label = Path(os.environ[GUARD_DIR]) / ('label-' + run_id)
        label.write_text(run_id + '\n')
        started = time.monotonic()
        with (directory / 'harness.log').open('wb') as log:
            code = subprocess.run(['bash', str(base / 'bench/run.sh'), '--targets', target, '--scenarios', 'fill10m'], cwd=str(base), env=environment,
                                  stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL).returncode
        label.unlink()
        rest_until = time.monotonic() + (0 if setup['advisory'] else settings['rest_seconds'])
        records = []
        if (directory / 'run/records.jsonl').exists():
            records = [json.loads(line) for line in (directory / 'run/records.jsonl').read_text().splitlines() if line.strip()]
        record = next((item for item in records if item.get('scenario') == 'fill10m'), {})
        for field in ('keys_requested', 'dbsize', 'used_memory', 'used_memory_rss', 'bytes_per_key_rss', 'bytes_per_key_used', 'ops_per_sec',
                      'p50_ms', 'p99_ms', 'p999_ms', 'max_ms', 'error', 'settled', 'settle_s', 'settle_samples', 'settle_timeout_s'):
            entry[field] = record.get(field)
        memory = owner_memory(directory)
        entry['server_memory_before_stop'] = memory
        peaks = [m['cgroup_peak_bytes'] for m in memory if m.get('container') and isinstance(m.get('cgroup_peak_bytes'), (int, float))]
        rss_peaks = [m['peak_rss_bytes'] for m in memory if isinstance(m.get('peak_rss_bytes'), (int, float))]
        entry['cgroup_peak_bytes'] = max(peaks) if peaks else None
        entry['peak_rss_bytes'] = max(rss_peaks) if rss_peaks else None
        if entry['dbsize']:
            entry['bytes_per_key_cgroup_peak'] = entry['cgroup_peak_bytes'] / entry['dbsize'] if entry['cgroup_peak_bytes'] else None
            entry['bytes_per_key_peak_rss'] = entry['peak_rss_bytes'] / entry['dbsize'] if entry['peak_rss_bytes'] else None
        entry.update(returncode=code, seconds=time.monotonic() - started, finished_at=time.time())
        valid = code == 0 and not record.get('error') and isinstance(record.get('dbsize'), int) and record['dbsize'] >= args.fill_keys and entry['bytes_per_key_rss'] is not None
        entry['status'] = 'valid' if valid else 'failed'
    return 0 if all(engine['status'] == 'valid' for engine in engines) else 1


def image_pair(text):
    key, _, value = text.partition('=')
    if key not in ('redis', 'valkey', 'dragonfly', 'memtier') or not value:
        raise argparse.ArgumentTypeError('expected KEY=IMAGE with a key among redis, valkey, dragonfly, memtier')
    return key, value


def main():
    parser = argparse.ArgumentParser(description='Measure Eski against Redis, Valkey and Dragonfly by the method of bench/testbed/design.json on this host: '
                                     'an idle watch, a calibration that every engine must pass, rotated engine order, repetitions, the cooling, idle '
                                     'and frequency gates and per-second machine telemetry of the exam scheduler, the raw memtier output with the full '
                                     'histogram of every timed run; or the cases of the Redis benchmarks specification, one or more per command group; '
                                     'or the fill that gives memory per key.')
    parser.add_argument('mode', choices=('exam', 'spec', 'fill'))
    parser.add_argument('--out', type=Path, required=True, help='new directory for this measurement')
    parser.add_argument('--profile', choices=('full', 'rehearsal'), required=True)
    parser.add_argument('--eski', type=Path, required=True)
    parser.add_argument('--server-cpus', required=True)
    parser.add_argument('--client-cpus', required=True)
    parser.add_argument('--ports', required=True, help='FIRST-LAST, at least four free loopback ports')
    parser.add_argument('--image', type=image_pair, action='append', required=True)
    parser.add_argument('--server-memory', default='8g')
    parser.add_argument('--client-memory', default='2g')
    parser.add_argument('--maxmemory', type=int, default=6442450944)
    parser.add_argument('--spec-test-seconds', type=int, default=30)
    parser.add_argument('--spec-repetitions', type=int, default=2)
    parser.add_argument('--spec-cases-per-group', type=int, default=1)
    parser.add_argument('--spec-max-groups', type=int, default=0, help='keep only this many command groups, those with the smallest preloads; 0 keeps every group')
    parser.add_argument('--fill-keys', type=int, default=10000000)
    parser.add_argument('--corrupt-check', action='store_true', help='deliberately expect one key too many in the first workload\'s DBSIZE check, to prove the check fails')
    args = parser.parse_args()
    if {key for key, _ in args.image} != {'redis', 'valkey', 'dragonfly', 'memtier'}:
        parser.error('--image is needed for redis, valkey, dragonfly and memtier')
    first, _, last = args.ports.partition('-')
    if not (first.isdigit() and last.isdigit() and int(last) - int(first) >= 3):
        parser.error('--ports needs a range of at least four ports')
    root = args.out.resolve()
    if root.exists():
        parser.error('%s already exists' % root)
    root.mkdir(parents=True)
    (root / 'control').mkdir()
    result = dict(schema=SCHEMA, mode=args.mode, profile=args.profile, qualifying=args.profile == 'full', note=None if args.profile == 'full' else NOT_QUALIFYING,
                  exit_code=1, started_at=time.time(), host_start=host_record(root, args.server_cpus, args.client_cpus))
    guard, watcher, write_end = start_guard(root)
    os.environ[GUARD_DIR] = str(guard)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    message = 'finished'
    code = 1
    try:
        code = dict(exam=exam, spec=spec, fill=fill)[args.mode](args, root, result)
    except Refused as error:
        result['error'] = str(error)
        code = 1
    except Exception as error:
        traceback.print_exc()
        result['error'] = '%s: %s' % (type(error).__name__, error)
        code = 1
    except KeyboardInterrupt:
        result['error'] = 'interrupted by a signal'
        message = 'interrupted'
        code = 130
    finally:
        leaked = finish_guard(guard, watcher, write_end, message)
        if leaked:
            result['leaked_and_cleaned'] = leaked
        result['guard_log'] = [json.loads(line) for line in (root / 'guard.log').read_text().splitlines()] if (root / 'guard.log').exists() else []
        result.update(exit_code=code, finished_at=time.time(), seconds=time.time() - result['started_at'],
                      host_end=host_record(root, args.server_cpus, args.client_cpus))
        write(root / 'result.json', result)
    return code


if __name__ == '__main__':
    sys.exit(main())
