import argparse
from contextlib import closing, nullcontext
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import Server, ServerError, cpu_seconds, encode, parse_info

SCHEME = ['--label-levels', 'UNCLASSIFIED,CONFIDENTIAL,SECRET', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED']
MARKINGS = ['UNCLASSIFIED', 'CONFIDENTIAL', 'SECRET', 'UNCLASSIFIED//A', 'CONFIDENTIAL//A', 'SECRET//A', 'SECRET//A/B', 'CONFIDENTIAL//B']
RULES = ['on', 'nopass', '~*', '&*', '+@all']
MODES = {
    'off': {'args': [], 'login': None},
    'labels': {'args': SCHEME, 'login': ['clearance:*', 'trust:*']},
    'owners': {'args': ['--owners', 'yes'] + SCHEME, 'login': ['clearance:*', 'trust:*', 'owners:*', 'owner-shared', 'owner-operator']},
}
SIZES = {'smoke': (400, 4), 'full': (200000, 1000)}
VALUE = 'v' * 64


def head(mode, partition):
    if mode == 'off':
        return []
    if mode == 'labels':
        return ['LABEL', 'AS', MARKINGS[partition % len(MARKINGS)]]
    return ['LABEL', 'AS', 'OWNER', 'u%d' % partition]


def start(binary, port, folder, mode, appendonly, fsync, key, cpu, mirror=None):
    spec = MODES[mode]
    args = list(spec['args']) + ['--appendonly', 'yes' if appendonly else 'no', '--appendfsync', fsync, '--auto-aof-rewrite-percentage', '0']
    if mirror is not None:
        args += ['--change-log-dir', str(mirror)]
    if key is not None:
        args += ['--encryption-key-file', str(key)]
    if spec['login'] is not None:
        args += ['--user', 'default'] + RULES + spec['login']
    return Server(binary, port, folder, args, cpus=cpu)


def log_bytes(folder):
    total = 0
    files = 0
    for path in (Path(folder) / 'appendonlydir').glob('*.incr.aof'):
        total += path.stat().st_size
        files += 1
    return total, files


def latency_samples(c, prefix, count, folder, head_args=()):
    if count <= 0:
        return None
    samples = []
    failed = 0
    for i in range(count):
        frame = encode(list(head_args) + ['SET', '%s:%d' % (prefix, i), VALUE])
        tick = time.perf_counter_ns()
        c.s.sendall(frame)
        reply = c.reply()
        samples.append(time.perf_counter_ns() - tick)
        failed += reply != 'OK'
    (Path(folder) / 'latency-samples.json').write_text(json.dumps(dict(unit='ns', samples=samples)) + '\n')
    ordered = sorted(samples)
    pick = lambda q: ordered[min(len(ordered) - 1, int(len(ordered) * q))] / 1000
    return dict(writes=count, failed=failed, pipeline=1, us=dict(p50=pick(.5), p90=pick(.9), p99=pick(.99), p999=pick(.999), max=ordered[-1] / 1000),
                raw='latency-samples.json')


def measure(a, mode, appendonly, encryption, port, work):
    name = '%s-%s-%s' % (mode, 'aof' if appendonly else 'noaof', 'sealed' if encryption else 'plain')
    folder = Path(work) / name
    key = None
    if encryption:
        key = Path(work) / 'key'
        if not key.exists():
            key.write_text(os.urandom(32).hex() + '\n')
            key.chmod(0o600)
    writes, partitions = (a.writes, a.partitions) if a.size == 'custom' else SIZES[a.size]
    server = start(a.server, port, folder, mode, appendonly, a.fsync, key, a.cpu)
    row = {'mode': mode, 'appendonly': appendonly, 'encryption': encryption, 'fsync': a.fsync, 'writes': writes, 'partitions': partitions}
    try:
        c = server.conn()
        before_bytes, _ = log_bytes(folder)
        frames = [encode(head(mode, i % partitions) + ['SET', 'key:%d' % i, VALUE]) for i in range(writes)]
        cpu0 = cpu_seconds(server.pid)
        t0 = time.perf_counter()
        replies = c.pipeline(frames, window=a.pipeline)
        row['wall_s'] = time.perf_counter() - t0
        row['server_cpu_s'] = cpu_seconds(server.pid) - cpu0
        row['server_cpu_us_per_write'] = row['server_cpu_s'] * 1e6 / writes
        failed = [r for r in replies if isinstance(r, ServerError) or r != 'OK']
        row['failed_writes'] = len(failed)
        after_bytes, files = log_bytes(folder)
        row['incremental_files'] = files
        row['log_bytes'] = after_bytes - before_bytes
        row['log_bytes_per_write'] = (after_bytes - before_bytes) / writes
        row['latency'] = latency_samples(c, 'latency', a.latency_samples, folder, head(mode, 0))
        c.close()
    finally:
        server.stop()
    return row


def verify_mirror(reader, mirror, folder, key):
    first = subprocess.run([reader, mirror, 'first'], capture_output=True, timeout=10)
    (folder / 'mirror-first.out').write_bytes(first.stdout)
    (folder / 'mirror-first.err').write_bytes(first.stderr)
    first.check_returncode()
    epoch, position = first.stdout.decode().split()
    record = subprocess.run([reader, mirror, 'read', epoch, position], capture_output=True, timeout=10)
    (folder / 'mirror-first.aof').write_bytes(record.stdout)
    (folder / 'mirror-read.err').write_bytes(record.stderr)
    record.check_returncode()
    if encode(['SET', key, VALUE]) not in record.stdout:
        raise ValueError('verified change-log record does not contain the committed SET')


def mirror_records(reader, mirror, folder, limit):
    first = subprocess.run([reader, mirror, 'first'], capture_output=True, timeout=60)
    first.check_returncode()
    epoch, position = first.stdout.decode().split()
    payloads = []
    while len(payloads) < limit:
        record = subprocess.run([reader, mirror, 'read', epoch, position], capture_output=True, timeout=60)
        if record.returncode in (3, 4):
            break
        if record.returncode:
            (folder / 'mirror-walk.err').write_bytes(record.stderr)
            raise ValueError('change-log read at position %s failed with %d' % (position, record.returncode))
        payloads.append(record.stdout)
        position = record.stderr.decode().split('next=')[-1].strip()
    return payloads


def verify_all_writes(reader, mirror, folder, frames):
    payloads = mirror_records(reader, mirror, folder, len(frames) + 2)
    combined = b''.join(payloads)
    found = 0
    offset = 0
    for frame in frames:
        offset = combined.find(frame, offset)
        if offset < 0:
            break
        offset += len(frame)
        found += 1
    sets = combined.count(b'*3\r\n$3\r\nSET\r\n')
    return dict(mirror_records=len(payloads), mirror_bytes_read=len(combined), writes_found_in_order=found, set_commands_in_mirror=sets)


def mirror_sample(a, enabled, round_number, work):
    folder = Path(work) / f'round-{round_number}-mirror-{int(enabled)}'
    folder.mkdir()
    mirror = folder / 'mirror' if enabled else None
    if mirror is not None:
        mirror.mkdir(mode=0o700)
    row = {'round': round_number, 'change_log': enabled, 'fsync': a.fsync, 'timed': not a.verify_only}
    writes, _ = (a.writes, a.partitions) if a.size == 'custom' else SIZES[a.size]
    walk = None
    server = start(a.server, a.port, folder, 'off', True, a.fsync, None, a.cpu, mirror)
    try:
        with closing(server.conn()) as c:
            key = 'mirror-check'
            if c.call('SET', key, VALUE) != 'OK' or c.call('GET', key) != VALUE.encode():
                raise ValueError('plain append check did not round-trip')
            if mirror is not None:
                verify_mirror(a.change_log_reader, mirror, folder, key)
            if a.verify_only:
                frames = [encode(['SET', f'key:{i}', VALUE]) for i in range(writes)]
                replies = c.pipeline(frames, a.pipeline)
                row.update(writes=writes, failed_writes=sum(reply != 'OK' for reply in replies), dbsize=c.call('DBSIZE'))
                walk = frames if mirror is not None else None
            if not a.verify_only:
                frames = [encode(['SET', f'key:{i}', VALUE]) for i in range(writes)]
                warmup = min(a.warmup, writes)
                if any(reply != 'OK' for reply in c.pipeline(frames[:warmup], a.pipeline)):
                    raise ValueError('append warmup failed')
                before_aof, _ = log_bytes(folder)
                before_mirror = sum(path.stat().st_size for path in mirror.iterdir()) if mirror else 0
                cpu = cpu_seconds(server.pid)
                started = time.perf_counter()
                replies = c.pipeline(frames, a.pipeline)
                elapsed = time.perf_counter() - started
                after_aof, _ = log_bytes(folder)
                after_mirror = sum(path.stat().st_size for path in mirror.iterdir()) if mirror else 0
                memory = parse_info(c.call('INFO', 'memory'))
                failed = sum(reply != 'OK' for reply in replies)
                row.update(warmup=warmup, writes=writes, pipeline=a.pipeline, wall_s=elapsed,
                           server_cpu_s=cpu_seconds(server.pid)-cpu, failed_writes=failed,
                           successful_writes_per_s=(writes-failed)/elapsed, aof_bytes=after_aof-before_aof,
                           mirror_bytes=after_mirror-before_mirror, used_memory=int(memory['used_memory']),
                           used_memory_rss=int(memory['used_memory_rss']))
                row['latency'] = latency_samples(c, 'latency', a.latency_samples, folder)
    finally:
        code = server.stop()
    if code != 0:
        raise RuntimeError(f'server exited with {code}')
    if walk is not None:
        row.update(verify_all_writes(a.change_log_reader, mirror, folder, walk))
        row['all_writes_mirrored'] = row['writes_found_in_order'] == writes and row['set_commands_in_mirror'] == writes + 1
    return row


def main():
    parser = argparse.ArgumentParser(
        description="Measures what a write costs the server with the append-only file on against off, with labels off against a label scheme against owner mode, and with the log plain or encrypted: the server's CPU time per write over a pipelined run of SET commands whose keys are spread over the partitions (labels in label mode, users in owner mode), and the bytes the incremental log file holds per write, which are exact and reportable. Informs: the size of the scope prefix on a record, aliasing of owners in the log, the cost of sealing the log. Prints JSON with one row per configuration; the timing fields are for a quiet machine and are read in a speed pass.")
    parser.add_argument('--server', default='bin/eski', help='the server binary (default bin/eski)')
    parser.add_argument('--port', type=int, default=7660, help='first port; each configuration uses the next one in turn')
    parser.add_argument('--size', choices=('smoke', 'full', 'custom'), default='smoke', help='smoke: 400 writes over 4 partitions; full: 200,000 writes over 1,000 partitions; custom: the two numbers below')
    parser.add_argument('--writes', type=int, default=400)
    parser.add_argument('--partitions', type=int, default=4)
    parser.add_argument('--pipeline', type=int, default=100, help='commands in flight')
    parser.add_argument('--fsync', choices=('always', 'everysec', 'no'), default='everysec', help='the appendfsync policy of every run')
    parser.add_argument('--modes', default='off,labels,owners', help='comma separated: off, labels, owners')
    parser.add_argument('--aof', default='no,yes', help='comma separated: no, yes')
    parser.add_argument('--encryption', default='off,on', help='comma separated: off, on; only runs with the log on are encrypted')
    parser.add_argument('--cpu', help='CPU list for the server, as taskset -c takes it')
    parser.add_argument('--out', help='write the JSON here as well')
    parser.add_argument('--work-dir', type=Path, help='new directory to retain logs and data')
    parser.add_argument('--change-log-reader', type=lambda name: Path(name).resolve(),
                        help='compare plaintext AOF with the change log off and on using this reader')
    parser.add_argument('--mirror-rounds', type=int, default=2, help='alternate off/on order by round')
    parser.add_argument('--warmup', type=int, default=500, help='warmup writes per mirror measurement')
    parser.add_argument('--verify-only', action='store_true', help='check mirror capture with no timing: one write read back, then every one of '
                        'the writes found in the mirror in order, with the dataset size')
    parser.add_argument('--latency-samples', type=int, default=0, help='after the timed run, this many single writes at pipeline 1 with each round trip kept')
    a = parser.parse_args()
    if a.pipeline < 2 or a.writes < 1 or a.partitions < 1 or a.mirror_rounds < 1 or a.warmup < 0:
        parser.error('invalid workload size, pipeline, rounds or warmup')
    if a.verify_only and a.change_log_reader is None:
        parser.error('--verify-only needs --change-log-reader')
    if a.work_dir is not None:
        a.work_dir = a.work_dir.resolve()
        a.work_dir.mkdir(parents=True, exist_ok=False)
    working = nullcontext(a.work_dir) if a.work_dir else tempfile.TemporaryDirectory(prefix='eski-aof-append.')
    if a.change_log_reader is not None:
        count = 1 if a.verify_only else a.mirror_rounds
        with working as work:
            rows = [mirror_sample(a, enabled, r, work) for r in range(count)
                    for enabled in ((False, True) if r % 2 == 0 else (True, False))]
        print_result(a, rows)
        return int(any(r.get('failed_writes', 0) or (r['timed'] and r['aof_bytes'] <= 0) or
                       (r['timed'] and r['change_log'] and r['mirror_bytes'] <= 0) or
                       (not r['timed'] and (r['dbsize'] != r['writes'] + 1 or (r['change_log'] and not r['all_writes_mirrored'])))
                       for r in rows))
    modes = a.modes.split(',')
    for m in modes:
        if m not in MODES:
            raise SystemExit('unknown mode %s' % m)
    configs = []
    for mode in modes:
        for aof in a.aof.split(','):
            for enc in a.encryption.split(','):
                if aof == 'no' and enc == 'on':
                    continue
                configs.append((mode, aof == 'yes', enc == 'on'))
    rows = []
    with working as work:
        for i, (mode, aof, enc) in enumerate(configs):
            rows.append(measure(a, mode, aof, enc, a.port + i, work))
    print_result(a, rows)
    return 0 if all(r['failed_writes'] == 0 and (not r['appendonly'] or r['log_bytes'] > 0) for r in rows) else 1


def print_result(a, rows):
    text = json.dumps({'rows': rows}, indent=2)
    if a.out:
        Path(a.out).write_text(text + '\n')
    print(text)


if __name__ == '__main__':
    sys.exit(main())
