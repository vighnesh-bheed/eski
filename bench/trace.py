import argparse
import hashlib
import json
import os
import random
import shutil
import signal
import struct
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from harness import Conn, ServerError, encode, guard_add, guard_remove, port_free
import search_bench

TARGETS = ('stock', 'search', 'json', 'vector-sets', 'persistence', 'change-log', 'access')
SCHEME = ['--label-levels', 'UNCLASSIFIED,CONFIDENTIAL,SECRET', '--label-compartments', 'A,B', '--label-trust-levels', 'WEB,VETTED']
OWNER_LOGIN = ['--user', 'default', 'on', 'nopass', '~*', '&*', '+@all', 'clearance:*', 'trust:*', 'owners:*', 'owner-shared', 'owner-operator']


def interrupted(signum, frame):
    raise KeyboardInterrupt


def sha(path):
    value = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            value.update(block)
    return value.hexdigest()


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def perf_ready(folder, stack_bytes):
    perf = shutil.which('perf')
    if not perf:
        return None, None, None, 'perf is not installed on this host; install the linux-perf package that matches the running kernel'
    version = subprocess.run([perf, '--version'], capture_output=True, text=True)
    if version.returncode:
        return None, None, None, 'perf does not run: %s' % (version.stderr.strip() or version.stdout.strip())[-300:]
    paranoid = read('/proc/sys/kernel/perf_event_paranoid')
    event = 'cycles' if paranoid is not None and paranoid.lstrip('-').isdigit() and int(paranoid) <= 1 else 'cycles:u'
    refused = []
    for graph in (['--call-graph', 'dwarf,%d' % stack_bytes], ['--call-graph', 'fp'], []):
        for candidate in (event, 'cpu-clock:u' if event.endswith(':u') else 'cpu-clock'):
            probe = subprocess.run([perf, 'record', '-q', '-e', candidate, *graph, '-o', str(folder / 'probe.data'), '--', 'true'], capture_output=True, text=True)
            try:
                (folder / 'probe.data').unlink()
            except FileNotFoundError:
                pass
            if probe.returncode == 0:
                note = None if graph else ('call graphs are not permitted here (kernel.perf_event_paranoid=%s): %s' % (
                    paranoid, refused[-1] if refused else 'no detail'))
                return perf, candidate, graph, note
            refused.append(' '.join([candidate, *graph]) + ': ' + (probe.stderr.strip().splitlines() or ['no detail'])[-1][:200])
    return None, None, None, 'perf_event_open is not permitted (kernel.perf_event_paranoid=%s): %s' % (paranoid, '; '.join(refused)[-600:])


def children(pid):
    found = []
    for task in Path('/proc/%d/task' % pid).glob('*'):
        found += [int(value) for value in (read(task / 'children') or '').split()]
    return found


def wait_server(recorder, port):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline and recorder.poll() is None:
        try:
            conn = Conn(port, timeout=5)
            conn.call('PING')
            conn.close()
            kids = children(recorder.pid)
            return kids[0] if kids else None
        except (OSError, EOFError, ServerError):
            time.sleep(0.05)
    return None


def server_args(target, folder):
    if target == 'persistence':
        return ['--appendonly', 'yes', '--appendfsync', 'everysec', '--auto-aof-rewrite-percentage', '0', '--dir', str(folder)]
    if target == 'change-log':
        mirror = folder / 'mirror'
        mirror.mkdir(mode=0o700, parents=True)
        return ['--appendonly', 'yes', '--appendfsync', 'always', '--auto-aof-rewrite-percentage', '0', '--dir', str(folder), '--change-log-dir', str(mirror)]
    if target == 'access':
        return ['--owners', 'yes'] + SCHEME + OWNER_LOGIN
    return ['--maxmemory', '4gb']


def memtier(args, folder, seconds, pipeline):
    name = 'eski-baseline-trace-%d-%d' % (os.getpid(), pipeline)
    guard_add('container', name, name + '\n')
    command = ['docker', 'run', '--pull=never', '--rm', '--name', name, '--network', 'host', '--cpuset-cpus', args.client_cpus,
               '--memory', '2g', '--memory-swap', '2g', args.memtier_image, '--server=127.0.0.1', '--port=%d' % args.port, '--protocol=redis',
               '--ratio=1:1', '--key-maximum=100000', '--key-pattern=R:R', '--data-size=64', '--threads=2', '--clients=16',
               '--pipeline=%d' % pipeline, '--test-time=%d' % max(1, seconds), '--hide-histogram']
    with open(folder / ('memtier-p%d.log' % pipeline), 'wb') as log:
        done = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=seconds + 300)
    guard_remove('container', name)
    return done.returncode


def loop(conn, requests, seconds):
    deadline = time.monotonic() + seconds
    done = failed = 0
    while time.monotonic() < deadline:
        for request in requests:
            try:
                search_bench.execute(conn, request)
            except (ServerError, OSError, EOFError):
                failed += 1
            done += 1
            if time.monotonic() >= deadline:
                break
    return dict(requests=done, failed=failed)


def drive(target, args, folder):
    seconds = args.seconds
    scale = args.scale
    conn = Conn(args.port, timeout=600)
    try:
        if target == 'stock':
            frames = [encode(('SET', 'memtier-%d' % i, 'x' * 64)) for i in range(1, 100001 if scale else 5001)]
            conn.pipeline(frames, window=256)
            return dict(p1=memtier(args, folder, seconds // 2, 1), p16=memtier(args, folder, seconds - seconds // 2, 16))
        if target in ('search', 'json'):
            corpus = search_bench.Corpus(20000 if scale else 400, 9137)
            areas = ('search-hash', 'full-text', 'vector-search', 'aggregate') if target == 'search' else ('json',)
            loaded = set()
            requests = []
            for area in areas:
                for storage in search_bench.storages(area):
                    if storage not in loaded:
                        loaded.add(storage)
                        conn.pipeline(corpus.hash_frames() if storage == 'hash' else corpus.json_frames(area != 'json'), window=256)
                for name, spec in search_bench.index_specs(area).items():
                    try:
                        conn.call('FT.CREATE', name, *spec)
                    except ServerError:
                        pass
                shapes = search_bench.shapes(area, corpus)
                plan = search_bench.plan_requests(area, corpus, shapes, 200, 1, 5)
                requests += [item['request'] for item in plan]
            return loop(conn, requests, seconds)
        if target == 'vector-sets':
            rng = random.Random(3)
            count, dim = (20000, 64) if scale else (500, 16)
            frames = [encode(('VADD', 'trace:vset', 'FP32', struct.pack('<%df' % dim, *[rng.uniform(-1, 1) for _ in range(dim)]), 'e%d' % i)) for i in range(count)]
            conn.pipeline(frames, window=256)
            requests = [(('VSIM', 'trace:vset', 'FP32', struct.pack('<%df' % dim, *[rng.uniform(-1, 1) for _ in range(dim)]), 'COUNT', '10', 'WITHSCORES'),)
                        for _ in range(64)]
            return loop(conn, requests, seconds)
        if target in ('persistence', 'change-log'):
            deadline = time.monotonic() + seconds
            writes = 0
            while time.monotonic() < deadline:
                conn.pipeline([encode(('SET', 'p:%d' % (writes + i), 'v' * 64)) for i in range(1000)], window=100)
                writes += 1000
                if target == 'persistence' and writes % 20000 == 0:
                    try:
                        conn.call('BGSAVE')
                    except ServerError:
                        pass
            return dict(writes=writes)
        if target == 'access':
            deadline = time.monotonic() + seconds
            done = 0
            while time.monotonic() < deadline:
                frames = []
                for i in range(500):
                    owner = 'u%d' % ((done + i) % 1000)
                    frames.append(encode(('LABEL', 'AS', 'OWNER', owner, 'SET', 'k:%d' % ((done + i) % 5000), 'v' * 32)))
                    frames.append(encode(('LABEL', 'AS', 'OWNER', owner, 'GET', 'k:%d' % ((done + i) % 5000))))
                conn.pipeline(frames, window=200)
                done += 500
            return dict(requests=done * 2)
    finally:
        conn.close()
    raise ValueError(target)


def main():
    parser = argparse.ArgumentParser(description='Record where Eski spends its time in one workload area: the debug-information build of the '
                                     'qualified source serves the area\'s requests while perf samples it with call graphs; the step is untimed and '
                                     'separate from every timed pass. It keeps perf.data, text reports, the build ids, a perf archive of the '
                                     'objects needed to resolve symbols elsewhere, and the binary\'s sha256.')
    parser.add_argument('--target', choices=TARGETS, required=True)
    parser.add_argument('--server', type=Path, required=True, help='the eski-debug binary')
    parser.add_argument('--server-cpus', required=True)
    parser.add_argument('--client-cpus', required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--seconds', type=int, default=30)
    parser.add_argument('--scale', type=int, choices=(0, 1), default=1)
    parser.add_argument('--frequency', type=int, default=499)
    parser.add_argument('--stack-bytes', type=int, default=8192)
    parser.add_argument('--memtier-image', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--result', type=Path, required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, interrupted)
    folder = args.out.resolve()
    folder.mkdir(parents=True)
    result = dict(schema='eski-baseline-trace-v1', target=args.target, binary=str(args.server), seconds=args.seconds, scale=args.scale, exit_code=1)
    try:
        if not args.server.is_file():
            result['error'] = 'the debug build is missing at %s: its build failed or did not run, so this profile is owed' % args.server
            return 1
        result['binary_sha256'] = sha(args.server)
        perf, event, graph, reason = perf_ready(folder, args.stack_bytes)
        result.update(event=event, call_graph=' '.join(graph or []) or None)
        if perf is None:
            result['error'] = reason
            return 1
        result['call_graph_note'] = reason
        data = folder / 'perf.data'
        directory = folder / 'server'
        directory.mkdir()
        argv = [str(args.server.resolve()), '--bind', '127.0.0.1', '--port', str(args.port), '--dir', str(directory), '--save', '',
                '--appendonly', 'no', '--memcached-port', '0'] + server_args(args.target, directory)
        command = [perf, 'record', '-q', '-e', event, '-F', str(args.frequency), *graph, '-o', str(data),
                   '--', 'taskset', '-c', args.server_cpus] + argv
        result['perf_command'] = command
        if not port_free(args.port):
            result['error'] = 'port %d is in use' % args.port
            return 1
        recorder = subprocess.Popen(command, stdout=open(directory / 'server.log', 'wb'), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        server = None
        try:
            server = wait_server(recorder, args.port)
            if server is None:
                result['error'] = 'the server did not start under perf record: ' + (directory / 'server.log').read_text(errors='replace')[-800:]
                return 1
            result['workload'] = drive(args.target, args, folder)
        finally:
            if server is not None:
                try:
                    os.kill(server, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            try:
                recorder.wait(timeout=300)
            except subprocess.TimeoutExpired:
                recorder.send_signal(signal.SIGINT)
                try:
                    recorder.wait(timeout=60)
                except subprocess.TimeoutExpired:
                    recorder.kill()
                    recorder.wait()
            result['perf_exit'] = recorder.returncode
        outputs = {}
        for name, extra in (('report.txt', ['report', '--stdio', '--no-children', '--sort', 'comm,dso,symbol', '--percent-limit', '0.2']),
                            ('report-children.txt', ['report', '--stdio', '--children', '--sort', 'symbol', '--percent-limit', '1']),
                            ('buildids.txt', ['buildid-list'])):
            done = subprocess.run([perf, *extra, '-i', str(data)], capture_output=True, text=True, timeout=1800)
            (folder / name).write_text(done.stdout + done.stderr)
            outputs[name] = done.returncode
        archive = subprocess.run([perf, 'archive', str(data)], capture_output=True, text=True, cwd=str(folder), timeout=1800)
        outputs['perf archive'] = archive.returncode
        (folder / 'archive.log').write_text(archive.stdout + archive.stderr)
        shutil.copy2(args.server, folder / 'eski-debug')
        result['outputs'] = outputs
        result['perf_data_bytes'] = data.stat().st_size if data.exists() else 0
        samples = 'Samples' in (folder / 'report.txt').read_text(errors='replace') or 'Event count' in (folder / 'report.txt').read_text(errors='replace')
        result['has_samples'] = samples
        result['exit_code'] = 0 if result['perf_data_bytes'] > 0 and samples and outputs['report.txt'] == 0 and graph else 1
        if not (result['perf_data_bytes'] > 0 and samples):
            result['error'] = 'perf recorded no usable samples; see server/server.log and report.txt'
        elif not graph:
            result['error'] = 'a flat profile was recorded, but ' + reason
        return result['exit_code']
    finally:
        args.result.write_text(json.dumps(result, indent=1) + '\n')


if __name__ == '__main__':
    sys.exit(main())
