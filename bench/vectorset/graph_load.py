import argparse
from contextlib import nullcontext
import json
import random
import re
import struct
import sys
import tempfile
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import Server, ServerError, cpu_seconds, encode, parse_info

SIZES = {'smoke': 600, 'full': 100000}
LOADED = re.compile(r'DB loaded from disk: ([0-9.]+) seconds')
QUERIES = 8


def command_usec(c, name):
    for line in c.call('INFO', 'commandstats').decode().splitlines():
        if line.startswith('cmdstat_%s:' % name):
            fields = dict(kv.split('=') for kv in line.split(':', 1)[1].split(','))
            return int(fields['calls']), int(fields['usec'])
    return 0, 0


def blob(vector):
    return struct.pack('<%df' % len(vector), *vector)


def check(replies, what):
    for r in replies:
        if isinstance(r, ServerError):
            raise SystemExit('%s failed: %s' % (what, r))


def main():
    parser = argparse.ArgumentParser(
        description="Measures how long a large vector set takes to load from its version 2 payload, which carries the graph, against rebuilding the same set by inserting its elements, which is the work the load of a version 1 payload does because that payload carries no graph (the server no longer writes version 1, so the rebuild is timed as VADD over the same elements). The set is built with VADD and its insertion time is read from the server's own command statistics; its DUMP payload is restored --rounds times, timed the same way, and compared with the original by cardinality and by the replies to a few searches, which a version 2 restore must give exactly. The set is then saved to a snapshot and the server restarted from it, and the load time is read from the server's log. Informs: whether to copy link rows directly or decode each link, and whether to validate the partitions on compute workers. Prints JSON; the timing fields are for a quiet machine and are read in a speed pass.")
    parser.add_argument('--server', default='bin/eski', help='the server binary (default bin/eski)')
    parser.add_argument('--port', type=int, default=7670, help='first port; the restart uses the next one')
    parser.add_argument('--size', choices=('smoke', 'full', 'custom'), default='smoke', help='smoke: 600 elements; full: 100,000 elements; custom: --elements')
    parser.add_argument('--elements', type=int, default=600)
    parser.add_argument('--dim', type=int, default=32)
    parser.add_argument('--quant', choices=('Q8', 'NOQUANT', 'BIN'), default='Q8')
    parser.add_argument('--m', type=int, default=16, help='links per node (the M option)')
    parser.add_argument('--rounds', type=int, default=2, help='restores of the payload')
    parser.add_argument('--cpu', help='CPU list for the server, as taskset -c takes it')
    parser.add_argument('--out', help='write the JSON here as well')
    parser.add_argument('--work-dir', type=Path, help='new directory to retain logs and data')
    a = parser.parse_args()
    if a.work_dir is not None:
        a.work_dir = a.work_dir.resolve()
        a.work_dir.mkdir(parents=True, exist_ok=False)
    working = nullcontext(a.work_dir) if a.work_dir else tempfile.TemporaryDirectory(prefix='eski-graph-load.')
    n = a.elements if a.size == 'custom' else SIZES[a.size]
    rng = random.Random(n * 7 + a.dim)
    vectors = [[rng.uniform(-1, 1) for _ in range(a.dim)] for _ in range(n)]
    probes = [[rng.uniform(-1, 1) for _ in range(a.dim)] for _ in range(QUERIES)]
    result = {'elements': n, 'dim': a.dim, 'quant': a.quant, 'm': a.m, 'rounds': []}
    with working as work:
        server = Server(a.server, a.port, work, ['--enable-debug-command', 'yes'], cpus=a.cpu)
        try:
            c = server.conn()
            frames = [encode(['VADD', 'set:origin', 'FP32', blob(v), 'e%d' % i, a.quant, 'M', a.m]) for i, v in enumerate(vectors)]
            cpu0 = cpu_seconds(server.pid)
            t0 = time.perf_counter()
            check(c.pipeline(frames, window=500), 'building the set')
            result['rebuild_wall_s'] = time.perf_counter() - t0
            result['rebuild_cpu_s'] = cpu_seconds(server.pid) - cpu0
            result['rebuild_vadd_calls'], result['rebuild_vadd_usec'] = command_usec(c, 'vadd')
            payload = c.call('DUMP', 'set:origin')
            result['payload_bytes'] = len(payload)
            searches = [['VSIM', 'set:origin', 'FP32', blob(p), 'COUNT', 10, 'WITHSCORES', 'TRUTH'] for p in probes]
            want = [c.call(*s) for s in searches]
            for r in range(a.rounds):
                c.call('CONFIG', 'RESETSTAT')
                key = 'set:restored:%d' % r
                t0 = time.perf_counter()
                reply = c.call('RESTORE', key, 0, payload)
                wall = time.perf_counter() - t0
                if reply != 'OK':
                    raise SystemExit('RESTORE failed: %r' % reply)
                calls, usec = command_usec(c, 'restore')
                got = [c.call(*(s[:1] + [key] + s[2:])) for s in searches]
                result['rounds'].append({'round': r, 'restore_wall_s': wall, 'restore_calls': calls, 'restore_usec': usec,
                                         'same_cardinality': c.call('VCARD', key) == c.call('VCARD', 'set:origin'), 'same_search_replies': got == want})
                c.call('DEL', key)
            digest = c.call('DEBUG', 'DIGEST')
            if c.call('SAVE') != 'OK':
                raise SystemExit('SAVE failed')
            result['snapshot_bytes'] = (Path(work) / 'dump.rdb').stat().st_size
            c.close()
        finally:
            server.stop()
        mark = server.log_path.stat().st_size
        t0 = time.perf_counter()
        server = Server(a.server, a.port + 1, work, ['--enable-debug-command', 'yes'], cpus=a.cpu)
        try:
            result['startup_wall_s'] = time.perf_counter() - t0
            c = server.conn()
            found = LOADED.findall(server.log_path.read_text(errors='replace')[mark:])
            result['snapshot_load_log_s'] = float(found[-1]) if found else None
            result['digest_after_restart_equal'] = c.call('DEBUG', 'DIGEST') == digest
            result['same_search_replies_after_restart'] = [c.call(*s) for s in searches] == want
            c.close()
        finally:
            server.stop()
    text = json.dumps(result, indent=2)
    if a.out:
        Path(a.out).write_text(text + '\n')
    print(text)
    ok = result['digest_after_restart_equal'] and result['same_search_replies_after_restart'] and all(r['same_cardinality'] and r['same_search_replies'] for r in result['rounds'])
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
