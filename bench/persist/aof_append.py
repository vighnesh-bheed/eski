import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import Server, ServerError, cpu_seconds, encode

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


def start(binary, port, folder, mode, appendonly, fsync, key, cpu):
    spec = MODES[mode]
    args = list(spec['args']) + ['--appendonly', 'yes' if appendonly else 'no', '--appendfsync', fsync, '--auto-aof-rewrite-percentage', '0']
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
        c.close()
    finally:
        server.stop()
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
    a = parser.parse_args()
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
    with tempfile.TemporaryDirectory(prefix='eski-aof-append.') as work:
        for i, (mode, aof, enc) in enumerate(configs):
            rows.append(measure(a, mode, aof, enc, a.port + i, work))
    text = json.dumps({'rows': rows}, indent=2)
    if a.out:
        Path(a.out).write_text(text + '\n')
    print(text)
    return 0 if all(r['failed_writes'] == 0 and (not r['appendonly'] or r['log_bytes'] > 0) for r in rows) else 1


if __name__ == '__main__':
    sys.exit(main())
