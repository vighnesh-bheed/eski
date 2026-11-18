import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import Conn, Container, Server, ServerError, encode, parse_info, process_status

SCHEMA = 'eski-baseline-persistence-v1'
TARGETS = ('eski', 'redis', 'valkey')
LOADED = re.compile(r'DB loaded from disk: ([0-9.]+) seconds')
VALUE = 'v' * 64


def interrupted(signum, frame):
    raise KeyboardInterrupt


def selinux():
    done = subprocess.run(['docker', 'info', '--format', '{{json .SecurityOptions}}'], capture_output=True, text=True, timeout=60)
    return 'selinux' in done.stdout


def dataset(keys):
    frames = []
    quarter = max(1, keys // 4)
    for i in range(quarter):
        frames.append(encode(('SET', 'k:s:%d' % i, VALUE)))
        frames.append(encode(('HSET', 'k:h:%d' % i, 'f1', VALUE, 'f2', str(i), 'f3', 'x' * 16)))
        frames.append(encode(('SADD', 'k:t:%d' % i, 'a', 'b', 'c', str(i))))
        frames.append(encode(('ZADD', 'k:z:%d' % i, '1', 'a', '2', 'b', str(i), 'c')))
    return frames, quarter * 4


def samples(quarter):
    picks = sorted({0, quarter // 2, max(0, quarter - 1)})
    out = []
    for i in picks:
        out += [('GET', 'k:s:%d' % i), ('HGETALL', 'k:h:%d' % i), ('SMEMBERS', 'k:t:%d' % i), ('ZRANGE', 'k:z:%d' % i, '0', '-1', 'WITHSCORES')]
    return out


def canonical(reply):
    if isinstance(reply, list):
        return sorted(canonical(item) for item in reply) if reply and not isinstance(reply[0], list) else [canonical(item) for item in reply]
    return reply if not isinstance(reply, bytes) else reply.decode('latin-1')


class Engine:
    def __init__(self, target, args, port, data, label):
        self.target, self.args, self.port, self.data = target, args, port, Path(data)
        self.data.mkdir(parents=True, exist_ok=True)
        self.label = label
        self.handle = None

    def start(self, extra, folder):
        persist = ['--dir', '/data' if self.target != 'eski' else str(self.data), '--dbfilename', 'dump.rdb', '--save', '']
        if self.target == 'eski':
            self.handle = Server(self.args.server, self.port, folder, ['--dir', str(self.data), '--dbfilename', 'dump.rdb'] + extra, cpus=self.args.server_cpus)
            self.pid = self.handle.pid
            self.log = self.handle.log_path
        else:
            binary = 'redis-server' if self.target == 'redis' else 'valkey-server'
            option = ':z' if self.args.selinux else ''
            self.handle = Container('eski-baseline-persist-%s-%d-%d' % (self.target, self.port, os.getpid()), self.args.image[self.target],
                                    [binary, '--bind', '127.0.0.1', '--port', self.port, '--protected-mode', 'yes'] + persist + extra,
                                    self.port, folder, cpus=self.args.server_cpus, memory=self.args.server_memory,
                                    volumes=['%s:/data%s' % (self.data, option)], user='%d:%d' % (os.getuid(), os.getgid()))
            self.pid = self.handle.pid
            self.log = folder / 'server.log'
        return Conn(self.port, timeout=600)

    def stop(self):
        handle, self.handle = self.handle, None
        if handle is not None:
            handle.stop()

    def log_text(self):
        if self.target != 'eski' and self.handle is not None:
            self.handle.save_log()
        return Path(self.log).read_text(errors='replace') if Path(self.log).exists() else ''


def memory(conn, pid):
    info = parse_info(conn.call('INFO', 'memory'))
    status = process_status(pid) if pid else {}
    return dict(used_memory=int(info.get('used_memory', '0').strip() or 0), used_memory_rss=int(info.get('used_memory_rss', '0').strip() or 0),
                rss_bytes=status.get('VmRSS'), peak_rss_bytes=status.get('VmHWM'))


def wait_bgsave(conn):
    started = time.perf_counter()
    while True:
        info = parse_info(conn.call('INFO', 'persistence'))
        if info.get('rdb_bgsave_in_progress', '').strip() == '0':
            return time.perf_counter() - started, info.get('rdb_last_bgsave_status', '').strip()
        time.sleep(0.001)


def aof_bytes(folder):
    return sum(path.stat().st_size for path in Path(folder).glob('appendonlydir/*.incr.aof'))


def snapshot(args, target, rep, root, frames, count, checks):
    folder = root / ('rep-%d-%s-snapshot' % (rep, target))
    engine = Engine(target, args, args.port, folder / 'data', 'snapshot')
    row = dict(kind='snapshot', target=target, rep=rep, keys=count)
    conn = engine.start([], folder / 'server-1')
    try:
        row['memory_empty'] = memory(conn, engine.pid)
        started = time.perf_counter()
        replies = conn.pipeline(frames, window=256)
        row['load_seconds'] = time.perf_counter() - started
        row['load_errors'] = sum(isinstance(r, ServerError) for r in replies)
        row['memory_loaded'] = memory(conn, engine.pid)
        row['bytes_per_key'] = (row['memory_loaded']['used_memory'] - row['memory_empty']['used_memory']) / count
        row['dbsize'] = conn.call('DBSIZE')
        row['before'] = [canonical(conn.call(*argv)) for argv in checks]
        if args.corrupt_check and rep == 1 and not getattr(args, 'corrupted', False):
            args.corrupted = True
            row['before'][0] = 'deliberately wrong expectation'
        started = time.perf_counter()
        row['save_reply'] = conn.call('SAVE')
        row['save_seconds'] = time.perf_counter() - started
        row['file_bytes'] = (folder / 'data/dump.rdb').stat().st_size
        started = time.perf_counter()
        row['bgsave_reply'] = str(conn.call('BGSAVE'))
        row['bgsave_seconds'], row['bgsave_status'] = wait_bgsave(conn)
        conn.close()
    finally:
        engine.stop()
    started = time.perf_counter()
    conn = engine.start([], folder / 'server-2')
    try:
        row['restart_seconds'] = time.perf_counter() - started
        found = LOADED.findall(engine.log_text())
        row['load_log_seconds'] = float(found[-1]) if found else None
        row['dbsize_after_restart'] = conn.call('DBSIZE')
        row['after'] = [canonical(conn.call(*argv)) for argv in checks]
        row['memory_restarted'] = memory(conn, engine.pid)
        conn.close()
    finally:
        engine.stop()
    row['restored_equal'] = row['after'] == row['before'] and row['dbsize_after_restart'] == row['dbsize'] == count
    return row


def readback(conn, quarter):
    frames = []
    for i in range(quarter):
        frames += [encode(('GET', 'k:s:%d' % i)), encode(('HGETALL', 'k:h:%d' % i)), encode(('SMEMBERS', 'k:t:%d' % i)),
                   encode(('ZRANGE', 'k:z:%d' % i, '0', '-1', 'WITHSCORES'))]
    value = hashlib.sha256()
    errors = 0
    for reply in conn.pipeline(frames, window=256):
        errors += isinstance(reply, ServerError)
        value.update(json.dumps(canonical(reply) if not isinstance(reply, ServerError) else ['error', str(reply)]).encode() + b'\n')
    return value.hexdigest(), errors


def expected_digest(quarter):
    value = hashlib.sha256()
    for i in range(quarter):
        for reply in (VALUE, ['f1', VALUE, 'f2', str(i), 'f3', 'x' * 16], ['a', 'b', 'c', str(i)], ['a', '1', 'b', '2', 'c', str(i)]):
            value.update(json.dumps(canonical(reply)).encode() + b'\n')
    return value.hexdigest()


def snapshot_check(args, target, root, frames, count, checks, expected):
    folder = root / ('verify-%s-snapshot' % target)
    engine = Engine(target, args, args.port, folder / 'data', 'snapshot')
    row = dict(kind='snapshot', target=target, rep=1, keys=count, timed=False)
    conn = engine.start([], folder / 'server-1')
    try:
        replies = conn.pipeline(frames, window=256)
        row['load_errors'] = sum(isinstance(r, ServerError) for r in replies)
        row['dbsize'] = conn.call('DBSIZE')
        row['before'] = [canonical(conn.call(*argv)) for argv in checks]
        if args.corrupt_check:
            row['before'][0] = 'deliberately wrong expectation'
        row['save_reply'] = conn.call('SAVE')
        row['bgsave_reply'] = str(conn.call('BGSAVE'))
        row['bgsave_status'] = wait_bgsave(conn)[1]
        conn.close()
    finally:
        engine.stop()
    conn = engine.start([], folder / 'server-2')
    try:
        row['dbsize_after_restart'] = conn.call('DBSIZE')
        row['after'] = [canonical(conn.call(*argv)) for argv in checks]
        row['digest_after_restart'], row['readback_errors'] = readback(conn, count // 4)
        conn.close()
    finally:
        engine.stop()
    row['expected_digest'] = expected
    row['restored_equal'] = (row['after'] == row['before'] and row['dbsize_after_restart'] == row['dbsize'] == count
                             and row['digest_after_restart'] == expected and not row['readback_errors'] and row['bgsave_status'] == 'ok')
    return row


def append_check(args, target, root, fsync):
    folder = root / ('verify-%s-aof-%s' % (target, fsync))
    engine = Engine(target, args, args.port, folder / 'data', 'aof')
    extra = ['--appendonly', 'yes', '--appendfsync', fsync, '--auto-aof-rewrite-percentage', '0']
    row = dict(kind='append', target=target, rep=1, fsync=fsync, writes=args.writes, timed=False)
    conn = engine.start(extra, folder / 'server-1')
    try:
        replies = conn.pipeline([encode(('SET', 'a:%d' % i, VALUE)) for i in range(args.writes)], window=args.pipeline)
        row['failed_writes'] = sum(r != 'OK' for r in replies)
        row['aof_bytes'] = aof_bytes(folder / 'data')
        conn.close()
    finally:
        engine.stop()
    conn = engine.start(extra, folder / 'server-2')
    try:
        row['dbsize_after_restart'] = conn.call('DBSIZE')
        replies = conn.pipeline([encode(('GET', 'a:%d' % i)) for i in range(args.writes)], window=256)
        row['replayed_unequal'] = sum(r != VALUE.encode() and r != VALUE for r in replies)
        conn.close()
    finally:
        engine.stop()
    row['replayed_equal'] = row['dbsize_after_restart'] == args.writes and not row['replayed_unequal'] and not row['failed_writes']
    return row


def verify_only(args, frames, count, checks, summary):
    expected = expected_digest(count // 4)
    for target in TARGETS:
        summary['rows'].append(snapshot_check(args, target, args.out, frames, count, checks, expected))
        for fsync in args.fsync.split(','):
            summary['rows'].append(append_check(args, target, args.out, fsync))
    first = next(row for row in summary['rows'] if row['kind'] == 'snapshot')
    for row in summary['rows']:
        if row['kind'] == 'snapshot':
            row['same_data_as_first_engine'] = row['before'] == first['before'] and row['digest_after_restart'] == first['digest_after_restart']
    bad = [row for row in summary['rows'] if (row['kind'] == 'snapshot' and (not row['restored_equal'] or not row['same_data_as_first_engine'] or row['load_errors']))
           or (row['kind'] == 'append' and not row['replayed_equal'])]
    summary['failed_rows'] = [dict(kind=row['kind'], target=row['target'], fsync=row.get('fsync')) for row in bad]
    return int(bool(bad))


def append(args, target, rep, root, fsync):
    folder = root / ('rep-%d-%s-aof-%s' % (rep, target, fsync))
    engine = Engine(target, args, args.port, folder / 'data', 'aof')
    row = dict(kind='append', target=target, rep=rep, fsync=fsync, writes=args.writes)
    conn = engine.start(['--appendonly', 'yes', '--appendfsync', fsync, '--auto-aof-rewrite-percentage', '0'], folder / 'server')
    try:
        warm = [encode(('SET', 'w:%d' % i, VALUE)) for i in range(min(500, args.writes))]
        conn.pipeline(warm, window=100)
        frames = [encode(('SET', 'a:%d' % i, VALUE)) for i in range(args.writes)]
        before = aof_bytes(folder / 'data')
        started = time.perf_counter()
        replies = conn.pipeline(frames, window=args.pipeline)
        row['seconds'] = time.perf_counter() - started
        row['failed_writes'] = sum(r != 'OK' for r in replies)
        row['aof_bytes'] = aof_bytes(folder / 'data') - before
        row['memory'] = memory(conn, engine.pid)
        conn.close()
    finally:
        engine.stop()
    return row


def main():
    parser = argparse.ArgumentParser(description='Snapshot save, background save, restart load and append-only writes on Eski, Redis 7.4.12 and Valkey '
                                     '8.1.11 with the same mixed dataset and the same writes: every engine writes to a directory on the host disk, '
                                     'the restored dataset is compared with the saved one on every engine, the engine order rotates by repetition, '
                                     'and every repetition keeps times, file sizes and memory.')
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--image', action='append', required=True, help='redis=ID and valkey=ID')
    parser.add_argument('--server-cpus', required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--keys', type=int, default=1000000)
    parser.add_argument('--writes', type=int, default=200000)
    parser.add_argument('--pipeline', type=int, default=100)
    parser.add_argument('--repetitions', type=int, default=4)
    parser.add_argument('--fsync', default='always,everysec')
    parser.add_argument('--server-memory', default='8g')
    parser.add_argument('--corrupt-check', action='store_true', help='deliberately corrupt the saved sample of the first snapshot, to prove the check fails')
    parser.add_argument('--verify-only', action='store_true', help='one untimed pass per engine that reads the whole dataset back after the '
                        'snapshot restart and every append-only write back after the log replay, compared with what was written and across engines')
    args = parser.parse_args()
    args.image = dict(item.split('=', 1) for item in args.image)
    if set(args.image) != {'redis', 'valkey'}:
        parser.error('--image redis=ID and --image valkey=ID are required')
    args.out = args.out.resolve()
    args.out.mkdir(parents=True)
    args.selinux = selinux()
    signal.signal(signal.SIGTERM, interrupted)
    frames, count = dataset(args.keys)
    checks = samples(max(1, args.keys // 4))
    summary = dict(schema=SCHEMA, keys=count, writes=args.writes, pipeline=args.pipeline, repetitions=1 if args.verify_only else args.repetitions,
                   fsync=args.fsync.split(','), images=args.image, server=str(args.server), server_cpus=args.server_cpus,
                   client_cpus=sorted(os.sched_getaffinity(0)), timed=not args.verify_only, rows=[], exit_code=1)
    report = args.out / 'summary.json'
    try:
        if args.verify_only:
            summary['exit_code'] = verify_only(args, frames, count, checks, summary)
            return summary['exit_code']
        for rep in range(1, args.repetitions + 1):
            offset = (rep - 1) % len(TARGETS)
            order = TARGETS[offset:] + TARGETS[:offset]
            for target in order:
                summary['rows'].append(dict(snapshot(args, target, rep, args.out, frames, count, checks), order=list(order)))
                for fsync in args.fsync.split(','):
                    summary['rows'].append(dict(append(args, target, rep, args.out, fsync), order=list(order)))
                report.write_text(json.dumps(summary, indent=1, default=repr) + '\n')
        reference = {}
        for row in summary['rows']:
            if row['kind'] == 'snapshot':
                reference.setdefault(row['rep'], row['before'])
                row['same_data_as_first_engine'] = row['before'] == reference[row['rep']]
        bad = [row for row in summary['rows'] if (row['kind'] == 'snapshot' and (not row['restored_equal'] or not row['same_data_as_first_engine'] or row['load_errors']))
               or (row['kind'] == 'append' and (row['failed_writes'] or row['aof_bytes'] <= 0))]
        summary['failed_rows'] = [dict(kind=row['kind'], target=row['target'], rep=row['rep']) for row in bad]
        summary['exit_code'] = int(bool(bad))
    except KeyboardInterrupt:
        summary.update(error='interrupted', exit_code=130)
        raise
    finally:
        report.write_text(json.dumps(summary, indent=1, default=repr) + '\n')
    return summary['exit_code']


if __name__ == '__main__':
    sys.exit(main())
