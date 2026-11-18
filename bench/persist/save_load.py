import argparse
from contextlib import nullcontext
import json
import os
import re
import struct
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
    'off': {'args': [], 'login': None, 'top': []},
    'labels': {'args': SCHEME, 'login': ['clearance:*', 'trust:*'], 'top': []},
    'owners': {'args': ['--owners', 'yes'] + SCHEME, 'login': ['clearance:*', 'trust:*', 'owners:*', 'owner-shared', 'owner-operator'],
               'top': ['LABEL', 'AS', 'SHARED']},
}
SIZES = {'smoke': (3, 40, 12), 'full': (2000, 40, 20)}
DIM = 16
LOADED = re.compile(r'DB loaded from disk: ([0-9.]+) seconds')


def head(mode, partition):
    if mode == 'off':
        return []
    if mode == 'labels':
        return ['LABEL', 'AS', MARKINGS[partition % len(MARKINGS)]]
    return ['LABEL', 'AS', 'OWNER', 'u%d' % partition]


def digest_of(c, mode):
    value = c.call(*MODES[mode]['top'], 'DEBUG', 'DIGEST' if mode == 'off' else 'DIGEST-SCOPES')
    return value.decode() if isinstance(value, bytes) else str(value)


def persistence_info(c, mode):
    return parse_info(c.call(*MODES[mode]['top'], 'INFO', 'persistence'))


def populate(c, mode, partitions, keys, elements):
    state = 12345
    frames = []
    for p in range(partitions):
        prefix = head(mode, p)
        for j in range(keys):
            frames.append(encode(prefix + ['SET', 'p%d:k%d' % (p, j), 'value-%d-%d' % (p, j) + 'x' * 48]))
        for j in range(elements):
            vec = []
            for _ in range(DIM):
                state = (state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
                vec.append(((state >> 40) % 2001 - 1000) / 1000.0)
            frames.append(encode(prefix + ['VADD', 'p%d:vs' % p, 'FP32', struct.pack('<%df' % DIM, *vec), 'e%d' % j]))
    for r in c.pipeline(frames, window=500):
        if isinstance(r, ServerError):
            raise SystemExit('loading the dataset failed: %s' % r)
    return len(frames)


def start(binary, port, folder, mode, key, cpu):
    spec = MODES[mode]
    args = ['--enable-debug-command', 'yes'] + spec['args']
    if key is not None:
        args += ['--encryption-key-file', str(key)]
    if spec['login'] is not None:
        args += ['--user', 'default'] + RULES + spec['login']
    return Server(binary, port, folder, args, cpus=cpu)


def load_seconds(path, offset):
    found = LOADED.findall(Path(path).read_text(errors='replace')[offset:])
    return float(found[-1]) if found else None


def measure(a, mode, encryption, port, work):
    folder = Path(work) / ('%s-%s' % (mode, 'sealed' if encryption else 'plain'))
    key = None
    if encryption:
        key = Path(work) / 'key'
        if not key.exists():
            key.write_text(os.urandom(32).hex() + '\n')
            key.chmod(0o600)
    partitions, keys, elements = (a.partitions, a.keys, a.elements) if a.size == 'custom' else SIZES[a.size]
    top = MODES[mode]['top']
    row = {'mode': mode, 'encryption': encryption, 'partitions': partitions, 'keys_per_partition': keys, 'elements_per_partition': elements}
    server = start(a.server, port, folder, mode, key, a.cpu)
    try:
        c = server.conn()
        row['commands'] = populate(c, mode, partitions, keys, elements)
        row['digest'] = digest_of(c, mode)
        t0 = time.perf_counter()
        cpu0 = cpu_seconds(server.pid)
        if c.call(*top, 'SAVE') != 'OK':
            raise SystemExit('SAVE failed')
        row['save_wall_s'] = time.perf_counter() - t0
        row['save_cpu_s'] = cpu_seconds(server.pid) - cpu0
        row['file_bytes'] = (folder / 'dump.rdb').stat().st_size
        t0 = time.perf_counter()
        cpu0 = cpu_seconds(server.pid)
        if not str(c.call(*top, 'BGSAVE')).startswith('Background saving started'):
            raise SystemExit('BGSAVE failed')
        while persistence_info(c, mode).get('rdb_bgsave_in_progress') != '0':
            time.sleep(0.001)
        row['bgsave_wall_s'] = time.perf_counter() - t0
        row['bgsave_parent_cpu_s'] = cpu_seconds(server.pid) - cpu0
        row['bgsave_status'] = persistence_info(c, mode).get('rdb_last_bgsave_status')
        c.close()
    finally:
        server.stop()
    mark = server.log_path.stat().st_size
    t0 = time.perf_counter()
    server = start(a.server, port, folder, mode, key, a.cpu)
    try:
        row['startup_wall_s'] = time.perf_counter() - t0
        row['startup_cpu_s'] = cpu_seconds(server.pid)
        c = server.conn()
        row['load_log_s'] = load_seconds(server.log_path, mark)
        row['keys_loaded'] = int(persistence_info(c, mode).get('rdb_last_load_keys_loaded', -1))
        row['digest_after_restart_equal'] = digest_of(c, mode) == row['digest']
        c.close()
    finally:
        server.stop()
    return row


def main():
    parser = argparse.ArgumentParser(
        description="Measures SAVE, BGSAVE and the startup load of a generated dataset in each chosen mode (labels off, a label scheme, owner mode), with the data files plain or encrypted, from the server's own INFO fields and log. Every partition (a label in label mode, a user in owner mode, the single one with labels off) gets the same number of strings and vector set elements, so a size with many partitions measures the cost of the partition records. Each configuration saves, saves in the background, stops, restarts from the file and checks that the digest of the whole dataset (DEBUG DIGEST, or DEBUG DIGEST-SCOPES with labels or owners) is the same after the restart. Informs: the form of the partition record, the cost of encryption, the cost of validation at load. Prints JSON with one row per configuration; the timing fields are for a quiet machine and are read in a speed pass.")
    parser.add_argument('--server', default='bin/eski', help='the server binary (default bin/eski)')
    parser.add_argument('--port', type=int, default=7650, help='first port; each configuration uses the next one in turn')
    parser.add_argument('--size', choices=('smoke', 'full', 'custom'), default='smoke', help='smoke: 3 partitions of 40 strings and 12 elements; full: 2,000 partitions of 40 strings and 20 elements; custom: the three numbers below')
    parser.add_argument('--partitions', type=int, default=3)
    parser.add_argument('--keys', type=int, default=40, help='strings per partition')
    parser.add_argument('--elements', type=int, default=12, help='vector set elements per partition')
    parser.add_argument('--modes', default='off,labels,owners', help='comma separated: off, labels, owners')
    parser.add_argument('--encryption', default='off,on', help='comma separated: off, on')
    parser.add_argument('--cpu', help='CPU list for the server, as taskset -c takes it')
    parser.add_argument('--out', help='write the JSON here as well')
    parser.add_argument('--work-dir', type=Path, help='new directory to retain logs and data')
    a = parser.parse_args()
    modes = a.modes.split(',')
    for m in modes:
        if m not in MODES:
            raise SystemExit('unknown mode %s' % m)
    rows = []
    if a.work_dir is not None:
        a.work_dir = a.work_dir.resolve()
        a.work_dir.mkdir(parents=True, exist_ok=False)
    working = nullcontext(a.work_dir) if a.work_dir else tempfile.TemporaryDirectory(prefix='eski-save-load.')
    with working as work:
        port = a.port
        for mode in modes:
            for flag in a.encryption.split(','):
                rows.append(measure(a, mode, flag == 'on', port, work))
                port += 1
    text = json.dumps({'rows': rows}, indent=2)
    if a.out:
        Path(a.out).write_text(text + '\n')
    print(text)
    return 0 if all(r['digest_after_restart_equal'] and r['bgsave_status'] == 'ok' for r in rows) else 1


if __name__ == '__main__':
    sys.exit(main())
