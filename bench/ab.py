import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.dont_write_bytecode = True

SCHEMA = 'eski-local-ab-v2'
MEMTIER = 'sha256:389090e9ef13701f36f5ac97485742618e648adbf76c008418383594a05c1659'
LABEL = 'eski-perf-ab=1'
MAXMEMORY = '6442450944'
DATASET = ['--key-minimum=1', '--key-maximum=100000', '--key-prefix=testbed:', '--data-size=64']
PRELOAD = DATASET + ['--ratio=1:0', '--key-pattern=P:P', '--threads=1', '--clients=1', '--requests=100000', '--pipeline=32']
COMMON = DATASET + ['--print-percentiles=50,99,99.9', '--threads=2', '--clients=16', '--distinct-client-seed', '--run-count=1']
WORKLOADS = {
    'get64-p1-r3k': (['--ratio=0:1', '--key-pattern=R:R', '--pipeline=1', '--rate-limiting=3000'], 96000),
    'set64-p1-r3k': (['--ratio=1:0', '--key-pattern=R:R', '--pipeline=1', '--rate-limiting=3000'], 96000),
    'get64-p16-r20k': (['--ratio=0:1', '--key-pattern=R:R', '--pipeline=16', '--rate-limiting=20000'], 640000),
    'set64-p16-r20k': (['--ratio=1:0', '--key-pattern=R:R', '--pipeline=16', '--rate-limiting=20000'], 640000),
    'ping-p16-r20k': (['--command=PING', '--pipeline=16', '--rate-limiting=20000'], 640000),
    'get64-p1-r1k': (['--ratio=0:1', '--key-pattern=R:R', '--pipeline=1', '--rate-limiting=1000'], 32000),
    'get64-p16-max': (['--ratio=0:1', '--key-pattern=R:R', '--pipeline=16'], None),
    'get64-p1-max': (['--ratio=0:1', '--key-pattern=R:R', '--pipeline=1'], None),
}
DEFAULT = 'get64-p1-r3k,set64-p1-r3k,get64-p16-r20k,set64-p16-r20k,ping-p16-r20k,get64-p1-r1k,get64-p16-max'
SYS = Path('/sys')
THROTTLE_FIELDS = ('core_throttle_count', 'core_throttle_total_time_ms', 'package_throttle_count', 'package_throttle_total_time_ms')
LIMITS = {
    'concurrent': dict(asym_foreign_pct=5.0, server_foreign_pct=30.0, client_foreign_pct=None, rate_fraction=0.98, freq_deviation=0.10,
                       freq_pair_tolerance=0.20, core_throttle_per_s=100.0, min_pairs=3),
    'sequential': dict(asym_foreign_pct=5.0, server_foreign_pct=10.0, client_foreign_pct=15.0, rate_fraction=0.98, freq_deviation=0.10,
                       freq_pair_tolerance=0.20, core_throttle_per_s=100.0, min_pairs=4),
}
ACTIVE_CONTAINERS = set()


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def cpu_list(text):
    out = []
    for part in str(text).split(','):
        a, _, b = part.partition('-')
        out += list(range(int(a), int(b or a) + 1))
    return out


def resp(port, *args, timeout=60):
    s = socket.create_connection(('127.0.0.1', port), timeout=timeout)
    try:
        out = b'*%d\r\n' % len(args)
        for a in args:
            a = a if isinstance(a, bytes) else str(a).encode()
            out += b'$%d\r\n%s\r\n' % (len(a), a)
        s.sendall(out)
        buf = b''
        while True:
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
            if buf[:1] in (b'+', b'-', b':') and buf.endswith(b'\r\n'):
                break
            if buf[:1] == b'$':
                head, _, rest = buf.partition(b'\r\n')
                n = int(head[1:])
                if n < 0 or len(rest) >= n + 2:
                    break
        return buf
    finally:
        s.close()


def info(port):
    fields = {}
    for line in resp(port, 'INFO', 'everything').decode(errors='replace').splitlines():
        if ':' in line and not line.startswith(('#', '$')):
            k, v = line.split(':', 1)
            fields[k.strip()] = v.strip()
    return fields


def cpu_times(text=None):
    out = {}
    for line in (read('/proc/stat') if text is None else text or '').splitlines():
        if re.match(r'cpu\d+ ', line):
            w = line.split()
            out[int(w[0][3:])] = list(map(int, w[1:9]))
    return out


def cpu_delta(before, after, cpus, tick):
    names = ('user', 'nice', 'system', 'idle', 'iowait', 'irq', 'softirq', 'steal')
    total = {n: 0.0 for n in names}
    for c in cpus:
        for i, n in enumerate(names):
            total[n] += (after[c][i] - before[c][i]) / tick
    return total


def threads(pid):
    total = {}
    for d in Path('/proc/%d/task' % pid).iterdir():
        sched = read(d / 'schedstat')
        stat = read(d / 'stat')
        status = read(d / 'status') or ''
        if not sched or not stat:
            continue
        comm = stat[stat.index('(') + 1:stat.rindex(')')]
        rest = stat[stat.rindex(')') + 2:].split()
        a = total.setdefault(comm, dict(run_ns=0, utime=0, stime=0, vol=0, nonvol=0, n=0))
        a['run_ns'] += int(sched.split()[0])
        a['utime'] += int(rest[11])
        a['stime'] += int(rest[12])
        a['vol'] += int(re.search(r'voluntary_ctxt_switches:\s+(\d+)', status).group(1))
        a['nonvol'] += int(re.search(r'nonvoluntary_ctxt_switches:\s+(\d+)', status).group(1))
        a['n'] += 1
    return total


def io(pid):
    out = {}
    for line in (read('/proc/%d/io' % pid) or '').splitlines():
        k, v = line.split(':')
        out[k.strip()] = int(v)
    return out


def throttle(cpu, sys_root=SYS):
    base = Path(sys_root) / ('devices/system/cpu/cpu%d/thermal_throttle' % cpu)
    return {name: int(read(base / name) or 0) for name in THROTTLE_FIELDS}


def throttle_delta(before, after):
    total = {name: 0 for name in THROTTLE_FIELDS}
    for c in after:
        for name in THROTTLE_FIELDS:
            total[name] += after[c].get(name, 0) - before.get(c, {}).get(name, 0)
    return total


def package_sensor(sys_root=SYS):
    for d in (Path(sys_root) / 'class/hwmon').glob('hwmon*'):
        if read(d / 'name') == 'coretemp':
            for label in d.glob('temp*_label'):
                if read(label) == 'Package id 0':
                    return label.with_name(label.name.replace('_label', '_input'))
    return None


def ac_online(sys_root=SYS):
    values = {}
    for d in (Path(sys_root) / 'class/power_supply').glob('*'):
        if read(d / 'type') == 'Mains':
            values[d.name] = read(d / 'online')
    return values


class Sampler(threading.Thread):
    def __init__(self, server_cpu, sensor, interval=0.5, sys_root=SYS):
        super().__init__(daemon=True)
        self.server_cpu, self.sensor, self.interval, self.sys_root = server_cpu, sensor, interval, Path(sys_root)
        self.freq, self.temp, self.stop_flag = [], [], False
        self.cgroup, self.cg_usage = None, []

    def run(self):
        path = self.sys_root / ('devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq' % self.server_cpu)
        while not self.stop_flag:
            f = read(path)
            if f:
                self.freq.append(int(f))
            if self.sensor:
                t = read(self.sensor)
                if t:
                    self.temp.append(int(t) / 1000)
            if self.cgroup:
                stat = read(self.cgroup / 'cpu.stat')
                if stat:
                    m = re.search(r'usage_usec (\d+)', stat)
                    if m:
                        self.cg_usage.append((time.monotonic(), int(m.group(1))))
            time.sleep(self.interval)


def memtier_start(out_dir, name, port, cpus, args, sampler=None):
    cname = 'eskiab-%d-%d-%s' % (os.getpid(), port, name)
    argv = ['docker', 'run', '--rm', '--pull=never', '--name', cname, '--label', LABEL, '--network=host', '--cpuset-cpus=' + cpus,
            '--user', '%d:%d' % (os.getuid(), os.getgid()), '-v', '%s:/out' % out_dir, '--entrypoint', 'nice', MEMTIER, '-n', '10',
            'memtier_benchmark', '--server=127.0.0.1', '--port=%d' % port, '--protocol=redis', '--hide-histogram',
            '--json-out-file=/out/%s.json' % name] + args
    ACTIVE_CONTAINERS.add(cname)
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if sampler is not None:
        for _ in range(50):
            done = subprocess.run(['docker', 'inspect', '-f', '{{.State.Pid}}', cname], capture_output=True, text=True)
            pid = done.stdout.strip()
            if done.returncode == 0 and pid not in ('', '0'):
                cg = read('/proc/%s/cgroup' % pid)
                if cg:
                    sampler.cgroup = SYS / 'fs/cgroup' / cg.split('::', 1)[1].lstrip('/')
                break
            time.sleep(0.1)
    return dict(proc=proc, cname=cname, out_dir=out_dir, name=name)


def memtier_finish(handle, timeout=900):
    proc, cname, out_dir, name = handle['proc'], handle['cname'], handle['out_dir'], handle['name']
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        remove_container(cname)
        raise
    ACTIVE_CONTAINERS.discard(cname)
    (out_dir / (name + '.log')).write_text(stdout + '\n----\n' + stderr)
    if proc.returncode:
        raise RuntimeError('memtier %s rc=%d %s' % (name, proc.returncode, stderr[-500:]))
    totals = json.loads((out_dir / (name + '.json')).read_text())['ALL STATS']['Totals']
    lat = totals.get('Percentile Latencies', {})
    return dict(ops=totals.get('Ops/sec'), p50=lat.get('p50.00'), p99=lat.get('p99.00'), p999=lat.get('p99.90'))


def memtier(out_dir, name, port, cpus, args, sampler=None, timeout=900):
    return memtier_finish(memtier_start(out_dir, name, port, cpus, args, sampler), timeout)


def remove_container(cname):
    subprocess.run(['docker', 'rm', '-f', cname], capture_output=True)
    ACTIVE_CONTAINERS.discard(cname)


def wait_ready(port, deadline=30):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            if resp(port, 'PING', timeout=2).startswith(b'+PONG'):
                return True
        except OSError:
            pass
        time.sleep(0.2)
    return False


def start_server(binary, extra, cpus, port, out_dir):
    data = out_dir / 'data'
    data.mkdir(parents=True, exist_ok=True)
    argv = ['taskset', '-c', cpus, 'nice', '-n', '10', binary, '--bind', '127.0.0.1', '--port', str(port), '--save', '',
            '--appendonly', 'no', '--maxmemory', MAXMEMORY, '--dir', str(data)] + extra
    log = open(out_dir / 'server.log', 'w')
    proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
    (out_dir / 'server.pid').write_text('%d\n' % proc.pid)
    server = dict(proc=proc, log=log, data=data, port=port)
    if not wait_ready(port):
        stop_server(server)
        raise RuntimeError('server not ready on port %d' % port)
    return server


def stop_server(server):
    if server['proc'].poll() is None:
        try:
            resp(server['port'], 'SHUTDOWN', 'NOSAVE', timeout=10)
        except OSError:
            pass
    try:
        server['proc'].wait(timeout=20)
    except subprocess.TimeoutExpired:
        server['proc'].kill()
        server['proc'].wait()
    server['log'].close()
    shutil.rmtree(server['data'], ignore_errors=True)


def snapshot(port, pid, server_list):
    return dict(info=info(port), threads=threads(pid), io=io(pid), throttle={c: throttle(c) for c in server_list})


def make_row(rnd, variant, key, target, mt, before, after, cb, ca, t0, t1, sampler, server_list, client_list, slot, cluster_list=None, ac=None, loadavg=None, tick=None):
    ib, ia, tb, ta, ob, oa = before['info'], after['info'], before['threads'], after['threads'], before['io'], after['io']
    n = max(1, int(ia['total_commands_processed']) - int(ib['total_commands_processed']) - 1)
    wall = t1 - t0
    run_ns = sum(ta[k]['run_ns'] - tb.get(k, {}).get('run_ns', 0) for k in ta)
    per_thread = {k: round((ta[k]['run_ns'] - tb.get(k, {}).get('run_ns', 0)) / n, 1) for k in ta}
    ut = sum(ta[k]['utime'] - tb.get(k, {}).get('utime', 0) for k in ta)
    st = sum(ta[k]['stime'] - tb.get(k, {}).get('stime', 0) for k in ta)
    vol = sum(ta[k]['vol'] - tb.get(k, {}).get('vol', 0) for k in ta)
    tick = tick or os.sysconf('SC_CLK_TCK')
    sd = cpu_delta(cb, ca, server_list, tick)
    cd = cpu_delta(cb, ca, client_list, tick)
    cluster = [c for c in (cluster_list or []) if c not in server_list]
    kd = cpu_delta(cb, ca, cluster, tick) if cluster else None
    own_s = run_ns / 1e9
    task_s = sd['user'] + sd['nice'] + sd['system']
    irq_s = sd['irq'] + sd['softirq']
    client_usage = None
    if len(sampler.cg_usage) >= 2:
        (a_t, a_u), (b_t, b_u) = sampler.cg_usage[0], sampler.cg_usage[-1]
        client_usage = (b_u - a_u) / 1e6 / max(1e-6, b_t - a_t)
    client_task = (cd['user'] + cd['nice'] + cd['system']) / wall
    freq = statistics.mean(sampler.freq) if sampler.freq else None
    th = throttle_delta(before['throttle'], after['throttle'])
    return dict(round=rnd, variant=variant, workload=key, slot=slot, commands=n, wall_s=round(wall, 3), server_ops=round(n / wall), memtier=mt,
                target_ops=target, cpu_ns_per_cmd=round((run_ns + irq_s * 1e9) / n, 1), task_ns_per_cmd=round(run_ns / n, 1),
                server_irq_ns_per_cmd=round(irq_s * 1e9 / n, 1), per_thread_ns=per_thread, user_share=round(ut / max(1, ut + st), 3),
                vol_per_cmd=round(vol / n, 4), syscr_per_cmd=round((oa.get('syscr', 0) - ob.get('syscr', 0)) / n, 4) if oa else None,
                syscw_per_cmd=round((oa.get('syscw', 0) - ob.get('syscw', 0)) / n, 4) if oa else None,
                el_cycles_per_cmd=round((int(ia['eventloop_cycles']) - int(ib['eventloop_cycles'])) / n, 4),
                server_cpu_columns_s={k: round(v, 3) for k, v in sd.items()}, server_own_s=round(own_s, 3),
                server_foreign_pct=round(100 * max(0.0, task_s - own_s) / wall / len(server_list), 2),
                cluster_busy_pct=round(100 * (kd['user'] + kd['nice'] + kd['system'] + kd['irq'] + kd['softirq']) / wall / len(cluster), 1) if kd else None,
                client_task_cores=round(client_task, 3), client_own=round(client_usage, 3) if client_usage is not None else None,
                client_foreign_pct=round(100 * max(0.0, client_task - client_usage) / len(client_list), 2) if client_usage is not None else None,
                freq_mean_khz=round(freq) if freq else None, freq_min_khz=min(sampler.freq) if sampler.freq else None,
                temp_max_c=max(sampler.temp) if sampler.temp else None,
                throttle_delta=th['core_throttle_count'], package_throttle_delta=th['package_throttle_count'],
                core_throttle_ms=th['core_throttle_total_time_ms'], package_throttle_ms=th['package_throttle_total_time_ms'],
                ac=ac_online() if ac is None else ac, loadavg=read('/proc/loadavg') if loadavg is None else loadavg,
                client_limited=bool(client_usage is not None and client_usage / len(client_list) > 0.85))


def measure_sequential(args, rnd, variant, binary, extra, out_dir, sensor):
    slot = dict(server_cpus=args.server_cpus, client_cpus=args.client_cpus, port=args.port)
    server = start_server(binary, extra, args.server_cpus, args.port, out_dir)
    rows = []
    try:
        memtier(out_dir, 'preload', args.port, args.client_cpus, PRELOAD)
        for key in args.workloads.split(','):
            extra_args, target = WORKLOADS[key]
            memtier(out_dir, key + '-warmup', args.port, args.client_cpus, COMMON + extra_args + ['--test-time=%d' % args.warmup])
            before = snapshot(args.port, server['proc'].pid, args.server_list)
            cb = cpu_times()
            sampler = Sampler(args.server_list[0], sensor)
            sampler.start()
            t0 = time.monotonic()
            mt = memtier(out_dir, key, args.port, args.client_cpus, COMMON + extra_args + ['--test-time=%d' % args.seconds], sampler)
            t1 = time.monotonic()
            ca = cpu_times()
            sampler.stop_flag = True
            sampler.join()
            after = snapshot(args.port, server['proc'].pid, args.server_list)
            rows.append(make_row(rnd, variant, key, target, mt, before, after, cb, ca, t0, t1, sampler, args.server_list, args.client_list, slot, args.cluster_list))
            report_row(rows[-1], args.server_cpus)
    finally:
        stop_server(server)
    return rows


def measure_concurrent(args, rnd, variants, out, sensor):
    slots = [dict(server_cpus=args.server_cpus, client_cpus=args.client_cpus, port=args.port),
             dict(server_cpus=args.server_cpus_b, client_cpus=args.client_cpus_b, port=args.port + 1)]
    order = ('B', 'A') if rnd % 2 == 0 else ('A', 'B')
    lanes = []
    rows = []
    try:
        for slot, v in zip(slots, order):
            d = out / ('r%02d-%s' % (rnd, v))
            d.mkdir()
            lane = dict(variant=v, slot=slot, dir=d, server_list=cpu_list(slot['server_cpus']), client_list=cpu_list(slot['client_cpus']))
            lane['server'] = start_server(variants[v][0], variants[v][1], slot['server_cpus'], slot['port'], d)
            lanes.append(lane)
        handles = [memtier_start(l['dir'], 'preload', l['slot']['port'], l['slot']['client_cpus'], PRELOAD) for l in lanes]
        for h in handles:
            memtier_finish(h)
        for key in args.workloads.split(','):
            extra_args, target = WORKLOADS[key]
            handles = [memtier_start(l['dir'], key + '-warmup', l['slot']['port'], l['slot']['client_cpus'], COMMON + extra_args + ['--test-time=%d' % args.warmup]) for l in lanes]
            for h in handles:
                memtier_finish(h)
            for l in lanes:
                l['before'] = snapshot(l['slot']['port'], l['server']['proc'].pid, l['server_list'])
            cb = cpu_times()
            t0 = time.monotonic()
            for l in lanes:
                l['sampler'] = Sampler(l['server_list'][0], sensor)
                l['sampler'].start()
            handles = [memtier_start(l['dir'], key, l['slot']['port'], l['slot']['client_cpus'], COMMON + extra_args + ['--test-time=%d' % args.seconds], l['sampler']) for l in lanes]
            results = [memtier_finish(h) for h in handles]
            t1 = time.monotonic()
            ca = cpu_times()
            for l, mt in zip(lanes, results):
                l['sampler'].stop_flag = True
                l['sampler'].join()
                after = snapshot(l['slot']['port'], l['server']['proc'].pid, l['server_list'])
                rows.append(make_row(rnd, l['variant'], key, target, mt, l['before'], after, cb, ca, t0, t1, l['sampler'], l['server_list'], l['client_list'], l['slot']))
                report_row(rows[-1], l['slot']['server_cpus'])
    finally:
        for l in lanes:
            stop_server(l['server'])
    return rows


def report_row(r, cpus):
    print(json.dumps(dict(r=r['round'], v=r['variant'], cpu=cpus, w=r['workload'], cpu_ns=r['cpu_ns_per_cmd'], task_ns=r['task_ns_per_cmd'],
                          ops=r['memtier']['ops'], foreign=r['server_foreign_pct'], cfor=r['client_foreign_pct'], freq=r['freq_mean_khz'],
                          thr=r['throttle_delta'], pkg=r.get('package_throttle_delta'))), flush=True)


def limits_for(mode, overrides=None):
    out = dict(LIMITS[mode])
    out.update({k: v for k, v in (overrides or {}).items() if v is not None or k == 'client_foreign_pct'})
    return out


def core_throttle_rate(row):
    return row.get('throttle_delta', 0) / max(1e-6, row.get('wall_s') or 0)


def flags(row, limits):
    reasons = []
    if limits.get('server_foreign_pct') is not None and row['server_foreign_pct'] > limits['server_foreign_pct']:
        reasons.append('server_cpu_foreign_load')
    if limits.get('client_foreign_pct') is not None and row['client_foreign_pct'] is not None and row['client_foreign_pct'] > limits['client_foreign_pct']:
        reasons.append('client_cpu_foreign_load')
    if row['target_ops'] and row['memtier']['ops'] < limits['rate_fraction'] * row['target_ops']:
        reasons.append('offered_rate_not_met')
    if core_throttle_rate(row) > limits['core_throttle_per_s']:
        reasons.append('thermal_throttle')
    if any(v != '1' for v in (row.get('ac') or {}).values()):
        reasons.append('ac_offline')
    return reasons


def geometric(a, b):
    return math.sqrt(a * b)


def swap_pairs(by, rounds):
    out = []
    for k in (range(1, max(rounds) + 1, 2) if rounds else ()):
        keys = [(k, 'A'), (k, 'B'), (k + 1, 'A'), (k + 1, 'B')]
        if not all(x in by for x in keys):
            continue
        a1, b1, a2, b2 = (by[x] for x in keys)
        r1, r2 = b1['cpu_ns_per_cmd'] / a1['cpu_ns_per_cmd'], b2['cpu_ns_per_cmd'] / a2['cpu_ns_per_cmd']
        freqs = [x['freq_mean_khz'] for x in (a1, b1, a2, b2)]
        q = geometric(freqs[1] / freqs[0], freqs[3] / freqs[2]) if all(freqs) else None
        out.append(dict(rounds=[k, k + 1], cpu_ratio=geometric(r1, r2), task_ratio=geometric(b1['task_ns_per_cmd'] / a1['task_ns_per_cmd'], b2['task_ns_per_cmd'] / a2['task_ns_per_cmd']),
                        lane_bias=math.sqrt(r1 / r2), freq_ratio=q))
    return out


def summarize_concurrent(rows, limits):
    limits = limits_for('concurrent', limits)
    out = {}
    for key in dict.fromkeys(r['workload'] for r in rows):
        sel = [r for r in rows if r['workload'] == key]
        by = {(r['round'], r['variant']): r for r in sel}
        rounds = sorted({r['round'] for r in sel})
        for r in sel:
            r['noise'] = flags(r, limits)
        round_reasons = {}
        for n in rounds:
            a, b = by.get((n, 'A')), by.get((n, 'B'))
            if not a or not b:
                continue
            reasons = sorted(set(a['noise']) | set(b['noise']))
            if abs(a['server_foreign_pct'] - b['server_foreign_pct']) > limits['asym_foreign_pct']:
                reasons.append('asymmetric_server_foreign_load')
            if a['client_foreign_pct'] is not None and b['client_foreign_pct'] is not None and abs(a['client_foreign_pct'] - b['client_foreign_pct']) > 2 * limits['asym_foreign_pct']:
                reasons.append('asymmetric_client_foreign_load')
            round_reasons[n] = reasons
        pairs = swap_pairs(by, rounds)
        freq_values = [p['freq_ratio'] for p in pairs if p['freq_ratio']]
        center = statistics.median(freq_values) if freq_values else None
        freq_pairs = []
        for p in pairs:
            p['freq_deviation'] = round(p['freq_ratio'] / center - 1, 4) if p['freq_ratio'] and center else None
            if p['freq_deviation'] is not None and abs(p['freq_deviation']) > limits['freq_pair_tolerance']:
                freq_pairs.append(p['rounds'][0])
                for n in p['rounds']:
                    round_reasons[n].append('frequency_difference')
            p['reasons'] = sorted(set(round_reasons[p['rounds'][0]]) | set(round_reasons[p['rounds'][1]]))
            p['clean'] = not p['reasons']
        excluded = [dict(round=n, reasons=reasons) for n, reasons in round_reasons.items() if reasons]
        clean_rounds = [n for n, reasons in round_reasons.items() if not reasons]
        ratio = {n: by[(n, 'B')]['cpu_ns_per_cmd'] / by[(n, 'A')]['cpu_ns_per_cmd'] for n in clean_rounds}
        clean = [p for p in pairs if p['clean']]
        swaps = [p['cpu_ratio'] for p in clean]
        task_swaps = [p['task_ratio'] for p in clean]
        slot_bias = [p['lane_bias'] for p in clean]

        def med(v, field):
            vals = [by[(n, v)][field] for n in clean_rounds]
            return dict(median=statistics.median(vals), min=min(vals), max=max(vals), n=len(vals)) if vals else None

        def ops(v):
            return statistics.median([by[(n, v)]['memtier']['ops'] for n in clean_rounds]) if clean_rounds else None

        out[key] = dict(A=med('A', 'cpu_ns_per_cmd'), B=med('B', 'cpu_ns_per_cmd'), clean_pairs=len(swaps), clean_rounds=clean_rounds, excluded=excluded,
                        pairs_excluded_frequency=freq_pairs, round_ratios={str(n): round(v, 4) for n, v in ratio.items()},
                        cpu_ratio_median=round(statistics.median(swaps), 4) if swaps else None,
                        cpu_ratio_min=round(min(swaps), 4) if swaps else None, cpu_ratio_max=round(max(swaps), 4) if swaps else None,
                        task_ratio_median=round(statistics.median(task_swaps), 4) if task_swaps else None,
                        slot_bias_median=round(statistics.median(slot_bias), 4) if slot_bias else None,
                        ops_ratio_median=round(statistics.median([by[(n, 'B')]['memtier']['ops'] / by[(n, 'A')]['memtier']['ops'] for n in clean_rounds]), 4) if clean_rounds else None,
                        A_ops_median=ops('A'), B_ops_median=ops('B'),
                        client_limited_runs=sum(1 for r in sel if r.get('client_limited')),
                        freq_ratio_median=round(center, 4) if center else None,
                        pairs=[dict(p, cpu_ratio=round(p['cpu_ratio'], 4), task_ratio=round(p['task_ratio'], 4), lane_bias=round(p['lane_bias'], 4),
                                    freq_ratio=round(p['freq_ratio'], 4) if p['freq_ratio'] else None) for p in pairs],
                        core_throttle_per_s_max=round(max(core_throttle_rate(r) for r in sel), 2),
                        package_throttle_runs=sum(1 for r in sel if r.get('package_throttle_delta', 0) > 0),
                        verdict='insufficient' if len(swaps) < limits['min_pairs'] else 'ok')
    return out


def summarize(rows, limits):
    limits = limits_for('sequential', limits)
    out = {}
    for key in dict.fromkeys(r['workload'] for r in rows):
        sel = [r for r in rows if r['workload'] == key]
        for r in sel:
            r['noise'] = flags(r, limits)
        clean = {v: {r['round']: r for r in sel if r['variant'] == v and not r['noise']} for v in ('A', 'B')}
        pairs, freq_pairs = [], []
        for p in sorted(set(clean['A']) & set(clean['B'])):
            fa, fb = clean['A'][p]['freq_mean_khz'], clean['B'][p]['freq_mean_khz']
            if fa and fb and abs(fa - fb) / ((fa + fb) / 2) > limits['freq_deviation']:
                freq_pairs.append(p)
            else:
                pairs.append(p)
        ratios = [clean['B'][p]['cpu_ns_per_cmd'] / clean['A'][p]['cpu_ns_per_cmd'] for p in pairs]
        ops_ratios = [clean['B'][p]['memtier']['ops'] / clean['A'][p]['memtier']['ops'] for p in pairs]

        def med(v, field):
            vals = [r[field] for r in clean[v].values()]
            return dict(median=statistics.median(vals), min=min(vals), max=max(vals), n=len(vals)) if vals else None

        out[key] = dict(A=med('A', 'cpu_ns_per_cmd'), B=med('B', 'cpu_ns_per_cmd'), clean_pairs=len(pairs),
                        excluded=[dict(round=r['round'], variant=r['variant'], reasons=r['noise']) for r in sel if r['noise']],
                        pairs_excluded_frequency=freq_pairs,
                        cpu_ratio_median=round(statistics.median(ratios), 4) if ratios else None,
                        cpu_ratio_min=round(min(ratios), 4) if ratios else None, cpu_ratio_max=round(max(ratios), 4) if ratios else None,
                        ops_ratio_median=round(statistics.median(ops_ratios), 4) if ops_ratios else None,
                        client_limited_runs=sum(1 for r in sel if r.get('client_limited')),
                        task_ratio_median=round(statistics.median([clean['B'][p]['task_ns_per_cmd'] / clean['A'][p]['task_ns_per_cmd'] for p in pairs]), 4) if pairs else None,
                        A_ops_median=statistics.median([r['memtier']['ops'] for r in clean['A'].values()]) if clean['A'] else None,
                        B_ops_median=statistics.median([r['memtier']['ops'] for r in clean['B'].values()]) if clean['B'] else None,
                        core_throttle_per_s_max=round(max(core_throttle_rate(r) for r in sel), 2),
                        package_throttle_runs=sum(1 for r in sel if r.get('package_throttle_delta', 0) > 0),
                        verdict='insufficient' if len(pairs) < limits['min_pairs'] else 'ok')
    return out


def summarize_session(rows, meta, limits=None):
    if not rows:
        return {}
    mode = meta.get('mode', 'sequential')
    chosen = meta.get('limits', {}) if limits is None else limits
    return summarize_concurrent(rows, chosen) if mode == 'concurrent' else summarize(rows, chosen)


def precheck():
    top = subprocess.run(['ps', '-eo', 'pcpu,psr,comm', '--sort=-pcpu'], capture_output=True, text=True).stdout.splitlines()[:8]
    return dict(time=time.strftime('%Y-%m-%dT%H:%M:%S%z'), loadavg=read('/proc/loadavg'), top=top)


def interrupt(signum, frame):
    raise KeyboardInterrupt('signal %d' % signum)


def parser():
    p = argparse.ArgumentParser(description='Concurrent, lane-swapped A/B measurement of two Eski binaries on a shared machine.')
    p.add_argument('--a', required=True)
    p.add_argument('--b', required=True)
    p.add_argument('--extra-a', default='')
    p.add_argument('--extra-b', default='')
    p.add_argument('--label', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--rounds', type=int, default=8)
    p.add_argument('--seconds', type=int, default=20)
    p.add_argument('--warmup', type=int, default=5)
    p.add_argument('--workloads', default=DEFAULT)
    p.add_argument('--mode', choices=('sequential', 'concurrent'), default='concurrent')
    p.add_argument('--server-cpus', default='1')
    p.add_argument('--client-cpus', default='10,11')
    p.add_argument('--server-cpus-b', default='2')
    p.add_argument('--client-cpus-b', default='12,13')
    p.add_argument('--cluster-cpus', default='1-2')
    p.add_argument('--control-cpu', default='14')
    p.add_argument('--port', type=int, default=39400)
    p.add_argument('--max-load', type=float, default=None)
    p.add_argument('--server-foreign-pct', type=float, default=None)
    p.add_argument('--client-foreign-pct', type=float, default=None)
    p.add_argument('--asym-foreign-pct', type=float, default=None)
    p.add_argument('--rate-fraction', type=float, default=None)
    p.add_argument('--freq-deviation', type=float, default=None)
    p.add_argument('--freq-pair-tolerance', type=float, default=None)
    p.add_argument('--core-throttle-per-s', type=float, default=None)
    p.add_argument('--min-pairs', type=int, default=None)
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    unknown = [k for k in args.workloads.split(',') if k not in WORKLOADS]
    if unknown:
        raise SystemExit('unknown workloads: %s' % ', '.join(unknown))
    args.server_list, args.client_list, args.cluster_list = cpu_list(args.server_cpus), cpu_list(args.client_cpus), cpu_list(args.cluster_cpus)
    check = precheck()
    if args.max_load is not None and float(check['loadavg'].split()[0]) >= args.max_load:
        raise SystemExit('1-minute load %s is not below %s' % (check['loadavg'].split()[0], args.max_load))
    limits = dict(LIMITS[args.mode])
    for k in ('server_foreign_pct', 'client_foreign_pct', 'asym_foreign_pct', 'rate_fraction', 'freq_deviation', 'freq_pair_tolerance', 'core_throttle_per_s', 'min_pairs'):
        if getattr(args, k) is not None:
            limits[k] = getattr(args, k)
    os.sched_setaffinity(0, set(cpu_list(args.control_cpu)))
    out = Path(args.out) / args.label
    if out.exists():
        raise SystemExit('output exists: %s' % out)
    out.mkdir(parents=True)
    (out / 'precheck.txt').write_text('%s\n%s\n%s\n' % (check['time'], check['loadavg'], '\n'.join(check['top'])))
    sensor = package_sensor()
    variants = dict(A=(str(Path(args.a).resolve()), args.extra_a.split()), B=(str(Path(args.b).resolve()), args.extra_b.split()))
    first = args.server_list[0]
    second = cpu_list(args.server_cpus_b)[0]
    meta = dict(schema=SCHEMA, label=args.label, started=time.time(), host=platform.node(), kernel=platform.release(),
                cpu_model=next((l.split(':', 1)[1].strip() for l in (read('/proc/cpuinfo') or '').splitlines() if l.startswith('model name')), None),
                binaries={k: dict(path=v[0], sha256=sha(v[0]), extra=v[1]) for k, v in variants.items()},
                cpus=dict(server=args.server_cpus, cluster=args.cluster_cpus, client=args.client_cpus, control=args.control_cpu,
                          server_b=args.server_cpus_b, client_b=args.client_cpus_b), mode=args.mode,
                governor=read(SYS / ('devices/system/cpu/cpu%d/cpufreq/scaling_governor' % first)),
                governor_b=read(SYS / ('devices/system/cpu/cpu%d/cpufreq/scaling_governor' % second)),
                epp=read(SYS / ('devices/system/cpu/cpu%d/cpufreq/energy_performance_preference' % first)),
                max_freq=read(SYS / ('devices/system/cpu/cpu%d/cpufreq/scaling_max_freq' % first)),
                no_turbo=read(SYS / 'devices/system/cpu/intel_pstate/no_turbo'), rounds=args.rounds, seconds=args.seconds, warmup=args.warmup,
                workloads=args.workloads.split(','), limits=limits, memtier_image=MEMTIER, argv=sys.argv if argv is None else ['bench/ab.py'] + list(argv),
                precheck=check, tool_sha256=sha(__file__))
    previous = signal.signal(signal.SIGTERM, interrupt)
    rows = []
    try:
        for rnd in range(1, args.rounds + 1):
            if args.mode == 'concurrent':
                rows += measure_concurrent(args, rnd, variants, out, sensor)
            else:
                for v in (('A', 'B') if rnd % 2 else ('B', 'A')):
                    d = out / ('r%02d-%s' % (rnd, v))
                    d.mkdir()
                    rows += measure_sequential(args, rnd, v, variants[v][0], variants[v][1], d, sensor)
            (out / 'rows.json').write_text(json.dumps(rows, indent=1))
    finally:
        for cname in sorted(ACTIVE_CONTAINERS):
            remove_container(cname)
        signal.signal(signal.SIGTERM, previous)
        meta['finished'] = time.time()
        summary = summarize_session(rows, meta)
        (out / 'rows.json').write_text(json.dumps(rows, indent=1))
        (out / 'summary.json').write_text(json.dumps(dict(meta=meta, summary=summary), indent=1))
        for key, s in summary.items():
            print('%-16s A %s B %s pairs %d ratio %s [%s, %s] ops %s %s' % (key, s['A'] and round(s['A']['median']), s['B'] and round(s['B']['median']),
                                                                          s['clean_pairs'], s['cpu_ratio_median'], s['cpu_ratio_min'], s['cpu_ratio_max'],
                                                                          s['ops_ratio_median'], s['verdict']))


if __name__ == '__main__':
    main()
