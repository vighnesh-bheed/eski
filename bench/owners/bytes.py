import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import operator_rules, Server, ServerError, encode, pairs, parse_info, rss_bytes, sha256

OPERATOR = ['on', 'nopass', '~*', '&*', '+@all', 'owners:*', 'owner-shared', 'owner-operator']
SHAPES = ('inline', 'small', 'hash', 'timed', 'two', 'five', 'vset')
WARM = 2000


def shape_frames(shape, i):
    head = [b'LABEL', b'AS', b'OWNER', b'u%07d' % i]
    if shape == 'inline':
        return [encode(head + [b'SET', b'k', b'v'])]
    if shape == 'small':
        return [encode(head + [b'SET', b'profile:12345', b'x' * 32])]
    if shape == 'hash':
        return [encode(head + [b'HSET', b'h', b'f', b'v'])]
    if shape == 'timed':
        return [encode(head + [b'SET', b'k', b'v', b'EX', b'86400'])]
    if shape == 'two':
        return [encode(head + [b'MSET', b'k', b'v', b'j', b'w'])]
    if shape == 'five':
        return [encode(head + [b'MSET', b'a', b'1', b'b', b'2', b'c', b'3', b'd', b'4', b'e', b'5'])]
    if shape == 'vset':
        return [encode(head + [b'SET', b'k', b'v']),
                encode(head + [b'VADD', b'vs', b'VALUES', b'2', b'%f' % ((i % 997) / 997.0), b'%f' % ((i % 991) / 991.0), b'e'])]
    raise ValueError(shape)


def snapshot(c, pid):
    time.sleep(0.35)
    m = parse_info(c.call('LABEL', 'AS', 'SHARED', 'INFO', 'memory'))
    o = parse_info(c.call('LABEL', 'AS', 'SHARED', 'INFO', 'owners'))
    st = pairs(c.call('LABEL', 'AS', 'SHARED', 'MEMORY', 'STATS'))
    return {
        'used_memory': int(m['used_memory']),
        'allocator_allocated': int(m['allocator_allocated']),
        'lut': int(st['overhead.db.hashtable.lut']),
        'rss': rss_bytes(pid),
        'owner_bytes': int(o.get('owner_bytes', 0)),
        'owner_partitions': int(o.get('owner_partitions', 0)),
        'owners_known': int(o.get('owners_known', 0)),
    }


def load(c, shape, ids):
    frames = [f for i in ids for f in shape_frames(shape, i)]
    errors = [r for r in c.pipeline(frames) if isinstance(r, ServerError)]
    return errors


def main():
    ap = argparse.ArgumentParser(description='Bytes per user in owner mode for one data shape: the change in used_memory, '
                                 'allocator_allocated, the table lookup bytes of MEMORY STATS, resident memory and INFO owner_bytes.')
    ap.add_argument('--binary', default=str(Path(__file__).resolve().parents[2] / 'bin' / 'eski'))
    ap.add_argument('--port', type=int, default=7651)
    ap.add_argument('--users', type=int, default=2000)
    ap.add_argument('--shape', choices=SHAPES, default='inline')
    ap.add_argument('--extra', default='', help='more server options, split on spaces, for example "--owner-compact no"')
    ap.add_argument('--cpu', help='CPU list for the server (taskset)')
    ap.add_argument('--tag', default='')
    ap.add_argument('--workdir')
    ap.add_argument('--out', help='append the JSON result to this file')
    a = ap.parse_args()
    workdir = Path(a.workdir or Path(os.environ.get('TMPDIR', '/tmp')) / ('eski-owner-bytes-%d' % a.port))
    server = Server(a.binary, a.port, workdir, ['--owners', 'yes'] + a.extra.split(), cpus=a.cpu)
    try:
        c = server.conn()
        c.call('ACL', 'SETUSER', 'default', *operator_rules(a.extra.split(), OPERATOR))
        if a.shape == 'vset':
            c.call('LABEL', 'AS', 'SHARED', 'VADD', 'vs', 'VALUES', '2', '0.5', '0.5', 'shared-anchor')
        errors = load(c, a.shape, range(9_000_000, 9_000_000 + WARM))
        before = snapshot(c, server.pid)
        errors += load(c, a.shape, range(a.users))
        after = snapshot(c, server.pid)
        c.close()
    finally:
        code = server.stop()
    n = a.users
    res = {'tag': a.tag, 'shape': a.shape, 'users': n, 'extra': a.extra, 'binary': server.binary, 'sha256': sha256(server.binary),
           'errors': len(errors), 'error_samples': [str(e) for e in errors[:5]], 'before': before, 'after': after,
           'per_user': {k: (after[k] - before[k]) / n for k in ('used_memory', 'allocator_allocated', 'lut', 'rss', 'owner_bytes')},
           'partitions_per_user': (after['owner_partitions'] - before['owner_partitions']) / n,
           'fatal_log_lines': server.fatal_lines(), 'exit_code': code}
    if a.out:
        with open(a.out, 'a') as fh:
            fh.write(json.dumps(res) + '\n')
    print(json.dumps({'tag': a.tag, 'shape': a.shape, 'users': n, 'per_user': res['per_user'], 'errors': len(errors)}))
    sys.exit(1 if errors or res['fatal_log_lines'] or code not in (0, None) else 0)


main()
