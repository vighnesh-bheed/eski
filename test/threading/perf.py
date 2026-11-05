import argparse
from collections import defaultdict
import hashlib
import json
import math
import multiprocessing
import os
from pathlib import Path
import random
from queue import Empty
import resource
import signal
import statistics
import sys
import time


sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from support import Client, Server, ServerError, compute_info, cpu_delta


SCHEMA = 'eski-lcs-scaling-v1'


def worker_counts(value):
    try:
        result = [int(part) for part in value.split(',')]
    except ValueError as error:
        raise argparse.ArgumentTypeError('worker counts must be comma-separated integers') from error
    if not result or len(set(result)) != len(result) or any(not 0 <= count <= 64 for count in result):
        raise argparse.ArgumentTypeError('worker counts must be unique and between 0 and 64')
    return result


def experiment_configurations(server, baseline, workers):
    return [('baseline', baseline, None)] + [('workers-%d' % count, server, count) for count in workers]


def ordered_cpus(value):
    try:
        result = [int(part) for part in value.split(',')]
    except ValueError as error:
        raise argparse.ArgumentTypeError('worker CPUs must be comma-separated CPU IDs') from error
    if not result or min(result) < 0 or len(set(result)) != len(result):
        raise argparse.ArgumentTypeError('worker CPUs must be unique nonnegative CPU IDs in assignment order')
    return result


def read_topology(cpu_ids, sysfs_root=Path('/sys')):
    siblings, missing = {}, []
    for cpu in sorted(cpu_ids):
        try:
            path = sysfs_root/'devices/system/cpu'/('cpu%d' % cpu)/'topology/thread_siblings_list'
            siblings[cpu] = cpuset(path.read_text().strip())
        except (OSError, ValueError, argparse.ArgumentTypeError):
            siblings[cpu] = {cpu}
            missing.append(cpu)
    return siblings, missing


def validate_roles(server_cpus, client_cpus, worker_cpus, coordinator_cpu, controller_cpus, topology):
    if server_cpus & client_cpus:
        raise ValueError('server and client CPU sets must not overlap')
    if controller_cpus & (server_cpus | client_cpus):
        raise ValueError('controller affinity overlaps server/client CPUs; launch the tool with taskset -c on separate controller CPUs')
    if not worker_cpus or min(worker_cpus) < 0 or len(set(worker_cpus)) != len(worker_cpus):
        raise ValueError('ordered worker CPUs must be unique and nonnegative')
    if coordinator_cpu < 0 or not set(worker_cpus) <= server_cpus or coordinator_cpu not in server_cpus:
        raise ValueError('worker and coordinator CPUs must be contained in --server-cpus')
    if coordinator_cpu in worker_cpus:
        raise ValueError('coordinator CPU must be distinct from every worker CPU')
    def overlap(left, right):
        return next(((cpu, other) for cpu in sorted(left) for other in sorted(right)
                     if other in topology.get(cpu, {cpu}) or cpu in topology.get(other, {other})), None)
    for name, left, right in (('server/client', server_cpus, client_cpus), ('server/controller', server_cpus, controller_cpus),
                              ('client/controller', client_cpus, controller_cpus)):
        pair = overlap(left, right)
        if pair:
            raise ValueError('%s roles share SMT siblings %d and %d; select separate physical cores' % (name, *pair))
    for index, cpu in enumerate(worker_cpus):
        pair = overlap({cpu}, set(worker_cpus[index+1:]) | {coordinator_cpu})
        if pair:
            raise ValueError('workers/coordinator share SMT siblings %d and %d; select distinct physical cores' % pair)


def thread_role_plan(pid, threads, workers, workload, worker_cpus, coordinator_cpu):
    main_cpu = worker_cpus[0] if workload == 'get-control' or workers in (None, 0) else coordinator_cpu
    result = {tid: {'role': 'coordinator' if tid == pid else 'background',
                    'cpu': main_cpu if tid == pid else coordinator_cpu} for tid in threads}
    compute_tids = sorted(tid for tid, value in threads.items() if tid != pid and value['name'] == 'eski-compute')
    for index, tid in enumerate(compute_tids):
        result[tid] = {'role': 'compute', 'cpu': worker_cpus[index % len(worker_cpus)]}
    return result


def parse_thread_stat(text):
    close = text.rindex(')')
    fields = text[close+2:].split()
    utime, stime = int(fields[11]), int(fields[12])
    return {'name': text[text.index('(')+1:close], 'ticks': utime+stime, 'utime': utime, 'stime': stime,
            'minflt': int(fields[7]), 'majflt': int(fields[9]), 'last_cpu': int(fields[36])}


def observe_threads(pid, proc_root=Path('/proc')):
    result = {}
    for directory in sorted((proc_root/str(pid)/'task').glob('*')):
        try:
            tid = int(directory.name)
            result[tid] = dict(parse_thread_stat((directory/'stat').read_text()), affinity=sorted(os.sched_getaffinity(tid)))
        except (OSError, ValueError, IndexError):
            pass
    return result


def process_memory(pid, proc_root=Path('/proc')):
    result = dict.fromkeys(('VmRSS', 'VmHWM', 'VmSize'))
    try:
        for line in (proc_root/str(pid)/'status').read_text().splitlines():
            name, separator, value = line.partition(':')
            if separator and name in result:
                fields = value.split()
                if len(fields) == 2 and fields[1] == 'kB':
                    result[name] = int(fields[0])*1024
    except (OSError, ValueError):
        pass
    return result


def placement_rows(threads, plan):
    return [dict(value, tid=tid, role=plan.get(tid, {}).get('role', 'unassigned'),
                 requested_cpu=plan.get(tid, {}).get('cpu')) for tid, value in sorted(threads.items())]


def placement_errors(threads, plan):
    errors = []
    if set(threads) != set(plan):
        errors.append('server thread identities changed during timing')
    for tid, requested in plan.items():
        if tid in threads and threads[tid]['affinity'] != [requested['cpu']]:
            errors.append('TID %d affinity differs from its assigned %s CPU %d' % (tid, requested['role'], requested['cpu']))
    return errors


def assign_roles(server, args, workload, require_workers=False):
    threads = observe_threads(server.process.pid)
    if server.process.pid not in threads:
        raise RuntimeError('cannot observe server coordinator thread')
    plan = thread_role_plan(server.process.pid, threads, server.workers, workload, args.worker_cpus, args.coordinator_cpu)
    count = sum(value['role'] == 'compute' for value in plan.values())
    if require_workers and count != server.workers:
        raise RuntimeError('expected %d compute TIDs after bootstrap, observed %d' % (server.workers, count))
    for tid, role in plan.items():
        os.sched_setaffinity(tid, {role['cpu']})
    observed = observe_threads(server.process.pid)
    errors = placement_errors(observed, plan)
    if errors:
        raise RuntimeError('; '.join(errors))
    return plan, observed


def cpuset(value):
    result = set()
    try:
        for part in value.split(','):
            bounds = part.split('-')
            if len(bounds) == 1:
                result.add(int(bounds[0]))
            elif len(bounds) == 2:
                first, last = map(int, bounds)
                if first > last:
                    raise ValueError()
                result.update(range(first, last+1))
            else:
                raise ValueError()
    except ValueError as error:
        raise argparse.ArgumentTypeError('CPU sets use nonnegative numbers or inclusive ranges') from error
    if not result or min(result) < 0:
        raise argparse.ArgumentTypeError('a nonempty nonnegative CPU set is required')
    return result


def percentile(values, fraction):
    if not values:
        return None
    return sorted(values)[max(0, math.ceil(len(values)*fraction)-1)]


def cpu_temperatures():
    result = []
    for directory in sorted(Path('/sys/class/hwmon').glob('hwmon*')):
        try:
            name = (directory/'name').read_text().strip()
            if name not in ('coretemp', 'k10temp', 'zenpower'):
                continue
            for path in sorted(directory.glob('temp*_input')):
                label = path.with_name(path.name.replace('_input', '_label'))
                result.append({'chip': name, 'label': label.read_text().strip() if label.exists() else path.stem,
                               'celsius': int(path.read_text())/1000})
        except (OSError, ValueError):
            pass
    return result


def power_policy(cpu_ids, sysfs_root=Path('/sys')):
    policy = {}
    for cpu in sorted(cpu_ids):
        directory = sysfs_root/'devices/system/cpu'/('cpu%d' % cpu)/'cpufreq'
        for name in ('cpuinfo_min_freq', 'cpuinfo_max_freq', 'scaling_min_freq', 'scaling_max_freq',
                     'scaling_governor', 'energy_performance_preference'):
            path = directory/name
            try:
                value = path.read_text().strip()
                policy['cpu%d/%s' % (cpu, name)] = int(value) if name.endswith('_freq') else value
            except (OSError, ValueError):
                policy['cpu%d/%s' % (cpu, name)] = None
    for directory in sorted((sysfs_root/'class/power_supply').glob('*')):
        online = directory/'online'
        if online.exists():
            policy['power/'+directory.name] = online.read_text().strip()
    return policy


def actor(port, command, expected, pipeline, warmup, duration, cpu_ids, start, start_at, finish, ready, output, seed, max_samples):
    client = None
    try:
        os.sched_setaffinity(0, cpu_ids)
        client = Client(port, timeout=30)
        commands = [command]*pipeline
        until = time.monotonic()+warmup
        while time.monotonic() < until:
            for reply in client.pipeline(commands):
                if reply != expected or isinstance(reply, ServerError):
                    raise ValueError('warmup returned an unexpected reply')
        ready.put({'ready': True})
        if not start.wait(timeout=60):
            raise TimeoutError('timed client start was not signalled')
        placement_before = observe_threads(os.getpid())
        before = resource.getrusage(resource.RUSAGE_SELF)
        stop_at = start_at.value+duration
        rng = random.Random(seed)
        samples = []
        count = 0
        while time.monotonic() < stop_at:
            sent = time.perf_counter_ns()
            client.send_many(commands)
            for _ in commands:
                reply = client.reply()
                if reply != expected or isinstance(reply, ServerError):
                    raise ValueError('timed request returned an unexpected reply')
                latency = time.perf_counter_ns()-sent
                count += 1
                if len(samples) < max_samples:
                    samples.append(latency)
                else:
                    chosen = rng.randrange(count)
                    if chosen < max_samples:
                        samples[chosen] = latency
        after = resource.getrusage(resource.RUSAGE_SELF)
        placement_after = observe_threads(os.getpid())
        output.put({'requests': count, 'latency_samples_ns': samples,
                    'cpu_seconds': after.ru_utime+after.ru_stime-before.ru_utime-before.ru_stime,
                    'affinity_requested': sorted(cpu_ids),
                    'placements_before': [dict(value, tid=tid, role='client') for tid, value in sorted(placement_before.items())],
                    'placements_after': [dict(value, tid=tid, role='client') for tid, value in sorted(placement_after.items())]})
        finish.wait(timeout=15)
    except BaseException as error:
        output.put({'error': type(error).__name__+': '+str(error)})
        ready.put({'ready': False})
    finally:
        if client is not None:
            client.close()


def load(server, command, expected, connections, pipeline, args, seed, workload=None):
    workload = workload or ('get-control' if str(command[0]).upper() == 'GET' else 'lcs')
    context = multiprocessing.get_context('spawn')
    start, finish = context.Event(), context.Event()
    start_at = context.Value('d', 0)
    ready, output = context.Queue(), context.Queue()
    processes = [context.Process(target=actor, args=(server.port, command, expected, pipeline, args.warmup, args.duration,
                 args.client_cpus, start, start_at, finish, ready, output, seed+at, args.max_samples)) for at in range(connections)]
    try:
        for process in processes:
            process.start()
        for _ in processes:
            if not ready.get(timeout=args.warmup+30)['ready']:
                raise RuntimeError('a client failed before timing: '+str(output.get(timeout=1)))
        plan, before = assign_roles(server, args, workload, require_workers=bool(server.workers) and workload != 'get-control')
        memory_before = process_memory(server.process.pid)
        controller_before = observe_threads(os.getpid())
        admin = server.client()
        counters_before = compute_info(admin) if server.workers is not None else None
        start_at.value = time.monotonic()
        start.set()
        rows, temperatures, placements, memory_samples, affinity_errors = [], [], [], [], []
        deadline = start_at.value+args.duration+30
        while len(rows) < len(processes):
            remaining = deadline-time.monotonic()
            if remaining <= 0:
                raise TimeoutError('timed clients did not finish')
            try:
                rows.append(output.get(timeout=min(.25, remaining)))
            except Empty:
                pass
            readings = cpu_temperatures()
            at = time.monotonic()-start_at.value
            temperatures.append({'seconds': at, 'readings': readings})
            observed = observe_threads(server.process.pid)
            placements.append({'seconds': at, 'threads': placement_rows(observed, plan)})
            memory_samples.append({'seconds': at, 'memory': process_memory(server.process.pid)})
            affinity_errors.extend(placement_errors(observed, plan))
            if not readings or any(value['celsius'] > args.max_temperature for value in readings):
                raise RuntimeError('CPU temperature telemetry disappeared or exceeded its limit during timing')
        elapsed = time.monotonic()-start_at.value
        after = observe_threads(server.process.pid)
        memory_after = process_memory(server.process.pid)
        affinity_errors.extend(placement_errors(after, plan))
        controller_after = observe_threads(os.getpid())
        counters_after = compute_info(admin) if server.workers is not None else None
        errors = [row['error'] for row in rows if 'error' in row]
        if errors:
            raise RuntimeError('; '.join(errors))
        samples = [value for row in rows for value in row['latency_samples_ns']]
        if not samples:
            raise RuntimeError('timed clients completed no requests')
        cpu_rows = cpu_delta(before, after, elapsed)
        for row in cpu_rows:
            row['role'] = plan.get(row['tid'], {}).get('role', 'unassigned')
            row['requested_cpu'] = plan.get(row['tid'], {}).get('cpu')
        compute_rows = [row for row in cpu_rows if row['role'] == 'compute']
        client_cpu = sum(row['cpu_seconds'] for row in rows)
        return {'elapsed_seconds': elapsed, 'requests': sum(row['requests'] for row in rows),
                'ops_per_second': sum(row['requests'] for row in rows)/elapsed,
                'latency_ms': {label: percentile(samples, fraction)/1e6 for label, fraction in (('p50', .5), ('p99', .99), ('p99.9', .999))},
                'latency_sampling': 'uniform reservoir per client; pipelined requests measured from their batch send',
                'clients': rows, 'thread_cpu': cpu_rows, 'compute_cpu_cores': sum(row['cpu_cores'] for row in compute_rows),
                'compute_tids_with_cpu': [row['tid'] for row in compute_rows if row['cpu_seconds'] > 0],
                'client_cpu_seconds': client_cpu, 'client_utilization': client_cpu/(elapsed*len(args.client_cpus)),
                'client_limited': client_cpu/(elapsed*len(args.client_cpus)) >= .85,
                'compute_before': counters_before, 'compute_after': counters_after, 'temperature_samples': temperatures,
                'placements_before': placement_rows(before, plan), 'placements_after': placement_rows(after, plan),
                'placement_samples': placements, 'placement_errors': sorted(set(affinity_errors)),
                'memory_before': memory_before, 'memory_after': memory_after, 'memory_samples': memory_samples, 'memory_units': 'bytes',
                'controller_placements_before': [dict(value, tid=tid, role='controller') for tid, value in sorted(controller_before.items())],
                'controller_placements_after': [dict(value, tid=tid, role='controller') for tid, value in sorted(controller_after.items())]}
    finally:
        finish.set()
        start.set()
        for process in processes:
            if process.pid is None:
                continue
            process.join(timeout=2)
            if process.is_alive():
                process.terminate()
                process.join(timeout=2)
            if process.is_alive():
                process.kill()
                process.join(timeout=2)
        for queue in (ready, output):
            queue.close()
            queue.cancel_join_thread()


def summaries(cases):
    groups = defaultdict(list)
    for case in cases:
        if case['valid']:
            groups[(case['configuration'], case['workload'])].append(case)
    result = []
    baselines = {workload: statistics.median(row['ops_per_second'] for row in rows)
                 for (configuration, workload), rows in groups.items() if configuration == 'baseline'}
    for (configuration, workload), rows in sorted(groups.items()):
        values = [row['ops_per_second'] for row in rows]
        median = statistics.median(values)
        result.append({'configuration': configuration, 'workload': workload, 'valid_repetitions': len(rows),
                       'ops_median': median, 'ops_min': min(values), 'ops_max': max(values),
                       'observed_ratio_to_baseline': median/baselines[workload] if baselines.get(workload) else None,
                       'client_limited_repetitions': sum(row['client_limited'] for row in rows),
                       'p99_median_ms': statistics.median(row['latency_ms']['p99'] for row in rows),
                       'max_observed_compute_cpu_cores': max(row['compute_cpu_cores'] for row in rows),
                       'max_distinct_compute_tids_with_cpu': max(len(row['compute_tids_with_cpu']) for row in rows)})
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description='Explicit, bounded local LCS worker-scaling experiment; writes fresh local receipts.')
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--server-cpus', type=cpuset, required=True)
    parser.add_argument('--client-cpus', type=cpuset, required=True)
    parser.add_argument('--worker-cpus', type=ordered_cpus, required=True, help='ordered CPU IDs for individually pinned compute workers')
    parser.add_argument('--coordinator-cpu', type=int, required=True, help='server coordinator/background CPU for asynchronous LCS cases')
    parser.add_argument('--workers', type=worker_counts, default=[1, 2, 4], help='unique counts 0..64; 0 tests candidate offloading disabled (default: 1,2,4)')
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--duration', type=float, default=15)
    parser.add_argument('--warmup', type=float, default=5)
    parser.add_argument('--rest', type=float, default=10)
    parser.add_argument('--max-seconds', type=int, default=1800)
    parser.add_argument('--size', type=int, default=2048)
    parser.add_argument('--memory', type=int, default=256 << 20)
    parser.add_argument('--max-temperature', type=float, default=85)
    parser.add_argument('--max-samples', type=int, default=10000)
    parser.add_argument('--require-parallel', action='store_true')
    args = parser.parse_args(argv)
    args.controller_cpus = set(os.sched_getaffinity(0))
    selected_cpus = args.server_cpus | args.client_cpus | args.controller_cpus
    topology, topology_missing = read_topology(selected_cpus)
    try:
        validate_roles(args.server_cpus, args.client_cpus, args.worker_cpus, args.coordinator_cpu, args.controller_cpus, topology)
    except ValueError as error:
        parser.error(str(error))
    if not args.server.is_file() or not args.baseline.is_file():
        parser.error('both server binaries must already exist')
    if not (1 <= args.repetitions <= 5 and 0 < args.duration <= 30 and 0 <= args.warmup <= 15 and 0 <= args.rest <= 30
            and 1 <= args.max_seconds <= 1800 and 1024 <= args.size <= 4096 and 1 <= args.max_samples <= 50000 and args.memory > 0):
        parser.error('requested experiment exceeds the bounded parameter ranges')
    if args.output.exists() and (not args.output.is_dir() or any(args.output.iterdir())):
        parser.error('--output must be absent or empty')
    args.output.mkdir(parents=True, exist_ok=True)
    configurations = experiment_configurations(args.server, args.baseline, args.workers)
    workloads = [('lcs-many', 8, 1), ('lcs-one', 1, 1), ('get-control', 8, 16)]
    data = {'schema': SCHEMA, 'settings': {key: sorted(value) if isinstance(value, set) else str(value) if isinstance(value, Path) else value
            for key, value in vars(args).items()}, 'cases': [], 'complete': False,
            'method': 'Fresh server per case; fixed preload; rotated configurations; explicit coordinator/ordered-worker/client/controller roles; no cross-workload score.'}
    data['binaries'] = {name: {'path': str(path.resolve()), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                        for name, path in (('baseline', args.baseline), ('candidate', args.server))}
    data['machine'] = {'kernel': os.uname().release, 'cpu_count': os.cpu_count(), 'clock_ticks_per_second': os.sysconf('SC_CLK_TCK'),
                       'cpu_model': next((line.split(':', 1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines()
                                          if line.startswith('model name')), 'not recorded'),
                       'thread_siblings': {str(cpu): sorted(siblings) for cpu, siblings in topology.items()},
                       'topology_missing_cpus': topology_missing, 'frequency_units': 'kHz'}
    data['placement_method'] = 'ordered-compute-role-affinity-v1'
    data['planned_cases'] = len(configurations)*len(workloads)*args.repetitions
    receipt = args.output/'results.json'
    def save():
        data['summary'] = summaries(data['cases'])
        receipt.write_text(json.dumps(data, indent=2, sort_keys=True)+'\n')
    def expired(unused_signal, unused_frame):
        raise TimeoutError('experiment reached its whole-run wall-clock limit')
    old = signal.signal(signal.SIGALRM, expired)
    signal.alarm(args.max_seconds)
    try:
        for repetition in range(args.repetitions):
            ordered = configurations[repetition % len(configurations):]+configurations[:repetition % len(configurations)]
            for workload, connections, pipeline in workloads:
                for label, binary, worker_count in ordered:
                    data['active_case'] = {'configuration': label, 'workers': worker_count, 'workload': workload, 'repetition': repetition+1}
                    temperatures = cpu_temperatures()
                    if not temperatures:
                        raise RuntimeError('CPU temperature telemetry is unavailable; no experiment was started')
                    if any(row['celsius'] > args.max_temperature for row in temperatures):
                        raise RuntimeError('CPU temperature exceeds the experiment limit; stopping without a hidden retry')
                    policy_before = power_policy(selected_cpus)
                    with Server(binary, workers=worker_count, memory=args.memory) as server:
                        assign_roles(server, args, workload)
                        client = server.client()
                        if workload.startswith('lcs'):
                            value = (b'abcd\x00efg'*(args.size//8+1))[:args.size]
                            client.call('MSET', 'mt:lcs:a', value, 'mt:lcs:b', value)
                            command, expected = ('LCS', 'mt:lcs:a', 'mt:lcs:b', 'LEN'), args.size
                            if worker_count:
                                if client.call(*command) != expected:
                                    raise RuntimeError('LCS worker bootstrap returned an unexpected result')
                                assign_roles(server, args, workload, require_workers=True)
                        else:
                            value = b'g'*64
                            for at in range(1, 257):
                                client.call('SET', 'mt:get:%d' % at, value)
                            command, expected = ('GET', 'mt:get:1'), value
                        row = load(server, command, expected, connections, pipeline, args, 4100+repetition, workload)
                        temperatures_after = cpu_temperatures()
                        reasons = []
                        if not temperatures_after or any(value['celsius'] > args.max_temperature for value in temperatures_after):
                            reasons.append('CPU temperature missing or above limit after timing')
                        policy_after = power_policy(selected_cpus)
                        if policy_before != policy_after:
                            reasons.append('power source or CPU policy changed')
                        reasons.extend(row['placement_errors'])
                        if any(value is None for snapshot in (row['memory_before'], row['memory_after']) for value in snapshot.values()):
                            reasons.append('server process-memory metadata unavailable')
                        if set(os.sched_getaffinity(0)) != args.controller_cpus:
                            reasons.append('controller affinity changed')
                        row.update(configuration=label, workers=worker_count, workload=workload, repetition=repetition+1,
                                   connections=connections, pipeline=pipeline, temperatures_before=temperatures,
                                   temperatures_after=temperatures_after, policy_before=policy_before, policy_after=policy_after,
                                   valid=not reasons, exclusions=reasons)
                        if worker_count and workload == 'lcs-many':
                            before, after = row['compute_before'], row['compute_after']
                            if after['compute_jobs_submitted'] <= before['compute_jobs_submitted']:
                                row['valid'] = False
                                row['exclusions'].append('timed workload submitted no asynchronous jobs')
                            if after['compute_sync_fallbacks'] != before['compute_sync_fallbacks']:
                                row['valid'] = False
                                row['exclusions'].append('timed workload used synchronous fallback')
                        data['cases'].append(row)
                        data.pop('active_case', None)
                        save()
                        print('%s %s repetition %d: %.1f ops/s; compute %.2f cores; client-limited=%s; valid=%s' %
                              (label, workload, repetition+1, row['ops_per_second'], row['compute_cpu_cores'], row['client_limited'], row['valid']), flush=True)
                        if not row['valid']:
                            raise RuntimeError('invalid case retained; stopping instead of retrying or continuing')
                    time.sleep(args.rest)
        if args.require_parallel:
            proof = [row for row in data['cases'] if row['valid'] and row['workload'] == 'lcs-many' and (row['workers'] or 0) >= 2
                     and len(row['compute_tids_with_cpu']) >= 2 and row['compute_cpu_cores'] > 1.05]
            if not proof:
                raise RuntimeError('no valid sample demonstrated CPU work above one core in multiple compute threads')
        data['complete'] = True
        save()
        return 0 if all(row['valid'] for row in data['cases']) else 1
    except (OSError, ValueError, RuntimeError, TimeoutError, Empty, AssertionError) as error:
        data['error'] = type(error).__name__+': '+str(error)
        active = data.pop('active_case', None)
        if active:
            data['cases'].append(dict(active, valid=False, aborted=True, exclusions=[data['error']]))
        save()
        print('threading perf: '+str(error), file=sys.stderr)
        return 1
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


if __name__ == '__main__':
    raise SystemExit(main())
