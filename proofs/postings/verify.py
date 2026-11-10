import argparse
import bisect
import fcntl
import hashlib
import itertools
import json
import math
import os
import random
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from kernel_audit import audit as audit_kernel

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().parent
SEED = 0x9057195
END = (1 << 32) - 1
CHUNK = 65536
ARRAY_MAX = 4096
U32 = 1 << 32
ID_NONE = 65535
U32_MAX = U32 - 1
U64_MAX = (1 << 64) - 1
K1 = struct.unpack('<f', struct.pack('<f', 1.2))[0]
B = 0.75
AREAS = {
    'svbyte': ['Svbyte'],
    'sorted': ['Sorted'],
    'roaring': ['Roaring'],
    'cursors': ['Cursor'],
    'phrases': ['Phrase'],
    'statistics': ['Stats'],
    'scoring': ['Score'],
}
ROW_AREAS = {'SE': 'svbyte', 'SD': 'svbyte', 'SX': 'svbyte', 'SW': 'svbyte', 'QA': 'sorted', 'QB': 'sorted',
             'RX': 'roaring', 'RA': 'roaring', 'RR': 'roaring', 'RC': 'roaring', 'RF': 'roaring', 'RO': 'roaring',
             'RN': 'roaring', 'RP': 'roaring', 'RS': 'roaring', 'RD': 'roaring', 'RL': 'roaring', 'RE': 'roaring',
             'RT': 'roaring', 'AR': 'cursors', 'DL': 'cursors', 'RQ': 'cursors', 'WT': 'scoring', 'PL': 'cursors',
             'PA': 'cursors', 'PC': 'cursors', 'PV': 'cursors', 'PK': 'cursors', 'T': 'cursors', 'TA': 'cursors',
             'PW': 'phrases', 'TP': 'phrases', 'TS': 'scoring', 'LB': 'statistics', 'LV': 'statistics',
             'SA': 'statistics', 'SR': 'statistics', 'SF': 'statistics', 'DA': 'statistics', 'DX': 'statistics',
             'SV': 'statistics', 'ST': 'statistics', 'BI': 'scoring', 'BM': 'scoring', 'FU': 'scoring', 'TK': 'scoring'}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hexs(data):
    return bytes(data).hex() if data else '-'


def nats(xs):
    return ','.join(map(str, xs)) if xs else '-'


def fbits(x):
    return struct.pack('>d', x).hex()


def unbits(h):
    return struct.unpack('>d', bytes.fromhex(h))[0]


def value_length(v):
    return 1 if v < 1 << 8 else 2 if v < 1 << 16 else 3 if v < 1 << 24 else 4


def sv_encode(values):
    n = len(values)
    control = bytearray((n + 3) // 4)
    data = bytearray()
    for i, v in enumerate(values):
        length = value_length(v)
        control[i // 4] |= (length - 1) << (2 * (i % 4))
        data += v.to_bytes(4, 'little')[:length]
    return bytes(control) + bytes(data)


def sv_decode(data, n):
    pos = (n + 3) // 4
    out = []
    for i in range(n):
        length = ((data[i // 4] >> (2 * (i % 4))) & 3) + 1
        out.append(int.from_bytes(bytes(data[pos:pos + length]).ljust(length, b'\0'), 'little'))
        pos += length
    return out, pos


def sv_encoded_length(data, n):
    cb = (n + 3) // 4
    if len(data) < cb:
        return -1
    return sv_decode(bytes(data) + bytes(4 * n), n)[1]


def sv_delta(values, prev):
    out = []
    for v in values:
        out.append((v - prev) % U32)
        prev = v
    return out


def sv_undelta(ds, prev):
    out = []
    for d in ds:
        prev = (prev + d) % U32
        out.append(prev)
    return out


def elems(c):
    if c[0] == 'r':
        return [s + i for s, l in c[1] for i in range(l + 1)]
    return list(c[1])


def from_set(vs):
    return ('b', list(vs)) if len(vs) > ARRAY_MAX else ('a', list(vs))


def flatten(c):
    return from_set(elems(c)) if c[0] == 'r' else c


def max_runs(vs):
    runs = []
    for v in vs:
        if runs and runs[-1][0] + runs[-1][1] + 1 == v:
            runs[-1] = (runs[-1][0], runs[-1][1] + 1)
        else:
            runs.append((v, 0))
    return runs


class RBitmap:
    def __init__(self, items=None):
        self.items = list(items or [])

    def _slot(self, key):
        for i, (k, _) in enumerate(self.items):
            if k == key:
                return i
        return -1

    def find(self, key):
        for i, (k, _) in enumerate(self.items):
            if k == key:
                return i
        return -1

    def contents(self):
        return [k * CHUNK + v for k, c in self.items for v in elems(c)]

    def add(self, x):
        key, low = divmod(x, CHUNK)
        i = self.find(key)
        if i < 0:
            self.items.append((key, ('a', [low])))
            self.items.sort(key=lambda p: p[0])
            return True
        c = flatten(self.items[i][1])
        vs = list(c[1])
        j = bisect.bisect_left(vs, low)
        if j < len(vs) and vs[j] == low:
            self.items[i] = (key, (c[0], vs))
            return False
        full = c[0] == 'a' and len(vs) >= ARRAY_MAX
        vs.insert(j, low)
        self.items[i] = (key, ('b', vs) if full else (c[0], vs))
        return True

    def remove(self, x):
        key, low = divmod(x, CHUNK)
        i = self.find(key)
        if i < 0:
            return False
        c = self.items[i][1]
        ev = elems(c)
        j = bisect.bisect_left(ev, low)
        if j >= len(ev) or ev[j] != low:
            return False
        c = flatten(c)
        nv = list(c[1])
        del nv[bisect.bisect_left(nv, low)]
        if not nv:
            del self.items[i]
        elif c[0] == 'b' and len(nv) <= ARRAY_MAX:
            self.items[i] = (key, ('a', nv))
        else:
            self.items[i] = (key, (c[0], nv))
        return True

    def contains(self, x):
        key, low = divmod(x, CHUNK)
        i = self.find(key)
        if i < 0:
            return False
        ev = elems(self.items[i][1])
        j = bisect.bisect_left(ev, low)
        return j < len(ev) and ev[j] == low


def set_op(op, x, y):
    sy = set(y)
    if op == 'and':
        return [v for v in x if v in sy]
    if op == 'andnot':
        return [v for v in x if v not in sy]
    return sorted(set(x) | sy)


def con_op(op, a, b):
    if a[0] == 'a' and b[0] == 'a':
        r = set_op(op, a[1], b[1])
        return ('b', r) if len(r) > ARRAY_MAX else ('a', r)
    ea, eb = elems(a), elems(b)
    if op == 'and':
        if a[0] == 'a':
            return ('a', set_op('and', a[1], eb))
        if b[0] == 'a':
            return ('a', set_op('and', b[1], ea))
        return from_set(set_op('and', ea, eb))
    if op == 'or':
        return from_set(set_op('or', ea, eb))
    if a[0] == 'a':
        return ('a', set_op('andnot', a[1], eb))
    return from_set(set_op('andnot', ea, eb))


def combine(op, A, B):
    da, db = dict(A.items), dict(B.items)
    out = []
    for k in sorted(set(da) | set(db)):
        if k in da and k in db:
            c = con_op(op, da[k], db[k])
            if elems(c):
                out.append((k, c))
        elif k in da and op != 'and':
            out.append((k, da[k]))
        elif k in db and op == 'or':
            out.append((k, db[k]))
    return RBitmap(out)


def run_optimize(bm):
    changed = False
    out = []
    for k, c in bm.items:
        e = elems(c)
        runs = len(c[1]) if c[0] == 'r' else len(max_runs(e))
        card = len(e)
        now = 2 * card if c[0] == 'a' else 8192 if c[0] == 'b' else 2 + 4 * runs
        as_runs = 2 + 4 * runs
        flat = 2 * card if card <= ARRAY_MAX else 8192
        if c[0] != 'r' and as_runs < now:
            c, changed = ('r', max_runs(e)), True
        elif c[0] == 'r' and flat <= as_runs:
            c, changed = from_set(e), True
        out.append((k, c))
    return RBitmap(out), changed


def payload(c):
    if c[0] == 'r':
        return struct.pack('<H', len(c[1])) + b''.join(struct.pack('<HH', s, l) for s, l in c[1])
    e = elems(c)
    if len(e) > ARRAY_MAX:
        words = bytearray(8192)
        for v in e:
            words[v >> 3] |= 1 << (v & 7)
        return bytes(words)
    return b''.join(struct.pack('<H', v) for v in e)


def serialize(bm):
    n = len(bm.items)
    runs = any(c[0] == 'r' for _, c in bm.items)
    if runs:
        head = struct.pack('<I', 12347 | (n - 1) << 16)
        flags = bytearray((n + 7) // 8)
        for i, (_, c) in enumerate(bm.items):
            if c[0] == 'r':
                flags[i // 8] |= 1 << (i % 8)
        head += bytes(flags)
    else:
        head = struct.pack('<II', 12346, n)
    head += b''.join(struct.pack('<HH', k, len(elems(c)) - 1) for k, c in bm.items)
    bodies = [payload(c) for _, c in bm.items]
    if not runs or n >= 4:
        at = len(head) + 4 * n
        offs = []
        for body in bodies:
            offs.append(struct.pack('<I', at))
            at += len(body)
        head += b''.join(offs)
    return head + b''.join(bodies)


def deserialize(data):
    data = bytes(data)
    if len(data) < 4:
        return None
    cookie = struct.unpack_from('<I', data, 0)[0]
    if cookie & 0xFFFF == 12347:
        runs, n = True, (cookie >> 16) + 1
        at = 4 + (n + 7) // 8
    elif cookie == 12346:
        if len(data) < 8:
            return None
        runs, n, at = False, struct.unpack_from('<I', data, 4)[0], 8
    else:
        return None
    if n > 65536 or len(data) < at + 4 * n:
        return None
    header = at
    at += 4 * n
    if not runs or n >= 4:
        if len(data) < at + 4 * n:
            return None
        at += 4 * n
    items, prev = [], -1
    for i in range(n):
        key, card = struct.unpack_from('<HH', data, header + 4 * i)
        card += 1
        if key <= prev:
            return None
        prev = key
        is_run = runs and (data[4 + i // 8] >> (i % 8)) & 1
        if is_run:
            if len(data) - at < 2:
                return None
            count = struct.unpack_from('<H', data, at)[0]
            if count == 0 or len(data) - at < 2 + 4 * count:
                return None
            rs, free, total = [], 0, 0
            for r in range(count):
                s, l = struct.unpack_from('<HH', data, at + 2 + 4 * r)
                if s < free or s + l > 0xFFFF:
                    return None
                rs.append((s, l))
                total += l + 1
                free = s + l + 1
            if total != card:
                return None
            items.append((key, ('r', rs)))
            at += 2 + 4 * count
        elif card > ARRAY_MAX:
            if len(data) - at < 8192:
                return None
            vs = [8 * j + k for j in range(8192) for k in range(8) if (data[at + j] >> k) & 1]
            if len(vs) != card:
                return None
            items.append((key, ('b', vs)))
            at += 8192
        else:
            if len(data) - at < 2 * card:
                return None
            vs = list(struct.unpack_from('<%dH' % card, data, at))
            if any(b <= a for a, b in zip(vs, vs[1:])):
                return None
            items.append((key, ('a', vs)))
            at += 2 * card
    return RBitmap(items), at


def checksum(xs):
    p = (1 << 61) - 1
    acc = 0
    for i, x in enumerate(xs):
        acc = (acc + (i + 1) * x % p) % p
    return acc


def layout(bm):
    if not bm.items:
        return '-'
    parts = []
    for k, c in bm.items:
        if c[0] == 'r':
            parts.append(f'{k}:r{len(c[1])}:{len(elems(c))}')
        else:
            parts.append(f'{k}:{c[0]}:{len(c[1])}')
    return ','.join(parts)


def describe(bm):
    c = bm.contents()
    lo = str(c[0]) if c else '-'
    hi = str(c[-1]) if c else '-'
    return f'{layout(bm)}|{len(c)}|{lo}|{hi}|{checksum(c)}'


def first_at_least(xs, t):
    i = bisect.bisect_left(xs, t)
    return xs[i] if i < len(xs) else END


def protocol(docs, targets):
    cur, out = 0, []
    for t in targets:
        if not (cur != 0 and cur >= t):
            cur = first_at_least(docs, t)
        out.append('-' if cur == END else str(cur))
    return ','.join(out) if out else '-'


def ordered_def(lists, slop):
    k = len(lists)
    if k == 0 or any(not l for l in lists):
        return False
    best = None
    for first in lists[0]:
        prev, ok = first, True
        for l in lists[1:]:
            cands = [p for p in l if p >= prev]
            if not cands:
                ok = False
                break
            prev = min(cands)
        if ok and (slop < 0 or prev - first - (k - 1) <= slop):
            return True
    return False


def ordered_brute(lists, slop):
    k = len(lists)
    if k == 0 or any(not l for l in lists):
        return False
    for choice in itertools.product(*lists):
        if all(a <= b for a, b in zip(choice, choice[1:])) and (slop < 0 or choice[-1] - choice[0] - (k - 1) <= slop):
            return True
    return False


def sweep(lists, slop):
    k = len(lists)
    if k == 0:
        return False
    if k == 1:
        return len(lists[0]) > 0
    if any(not l for l in lists):
        return False
    heads = [0] * k
    while True:
        vals = [lists[i][heads[i]] for i in range(k)]
        lo, hi = min(vals), max(vals)
        at = vals.index(lo)
        if hi > lo and (slop < 0 or hi - lo - (k - 1) <= slop):
            return True
        heads[at] += 1
        if heads[at] == len(lists[at]):
            return False


def unordered_brute(lists, slop):
    k = len(lists)
    for choice in itertools.product(*lists):
        if max(choice) > min(choice) and (slop < 0 or max(choice) - min(choice) - (k - 1) <= slop):
            return True
    return False


def idf(documents, containing):
    n = float(containing)
    total = float(max(documents, containing))
    return math.log(1 + (total - n + 0.5) / (n + 0.5))


def contribution(avg, w, prepared, f, dl):
    f = float(f)
    dl = float(dl)
    return w * prepared * f * (K1 + 1) / (f + K1 * (1 - B + B * dl / avg))


def doc_length(d):
    return d * 7 % 13 + 1


def doc_score(d):
    return [1.0, 0.5, 0.75, 2.0][d % 4]


def fold(values):
    if not values:
        return 0.0
    total = values[0]
    for v in values[1:]:
        total = total + v
    return total


class Model:
    def __init__(self):
        self.bitmaps = [RBitmap() for _ in range(4)]
        self.lists = [{'words': 1, 'pos': True, 'items': []} for _ in range(16)]
        self.arrays = [[] for _ in range(16)]
        self.deleted = set()
        self.required = 0
        self.weights = [1.0]
        self.table = [(0, frozenset())]
        self.reader = (0, frozenset())
        self.built = 1
        self.docs, self.lens = {}, {}
        self.terms = {}

    def leaf_docs(self, node):
        if node[0] == 'a':
            return [d for d in self.arrays[node[1]] if d != 0 and d not in self.deleted]
        return [p['doc'] for p in self.lists[node[1]]['items']
                if p['doc'] not in self.deleted and (self.required == 0 or p['mask'] & self.required)]

    def posting(self, k, d):
        for p in self.lists[k]['items']:
            if p['doc'] == d:
                return p
        return None

    def eval_set(self, node):
        kind = node[0]
        if kind in 'at':
            return self.leaf_docs(node)
        kids = node[-1]
        sets = [set(self.eval_set(c)) for c in kids]
        if kind in 'ilk':
            return sorted(set.intersection(*sets)) if sets else []
        if kind in 'uf':
            return sorted(set.union(*sets)) if sets else []
        if kind == 'd':
            return sorted(sets[0] - sets[1])
        base = sorted(set.intersection(*sets)) if sets else []
        return [d for d in base if self.phrase_ok(node, d)]

    def positions(self, node, d):
        kind = node[0]
        if kind == 't':
            if d not in set(self.eval_set(node)):
                return None
            return list(self.posting(node[1], d)['positions'])
        if kind in 'uf':
            got = [self.positions(c, d) for c in node[-1] if d in set(self.eval_set(c))]
            got = [g for g in got if g is not None]
            if not got:
                return None
            return sorted(set(itertools.chain(*got)))
        if kind == 'd':
            return self.positions(node[-1][0], d)
        return None

    def phrase_ok(self, node, d):
        slop, in_order, kids = node[1], node[2], node[3]
        if len(kids) == 1 or (slop < 0 and not in_order):
            return True
        lists = [self.positions(c, d) or [] for c in kids]
        if any(not l for l in lists):
            return False
        return ordered_def(lists, slop) if in_order else sweep(lists, slop)

    def cost(self, node):
        kind = node[0]
        if kind == 'a':
            return len(self.arrays[node[1]])
        if kind == 't':
            return len(self.lists[node[1]]['items'])
        kids = node[-1]
        if kind in 'uf':
            return sum(self.cost(c) for c in kids)
        if kind == 'd':
            return self.cost(kids[0])
        return min(self.cost(c) for c in kids)

    def score(self, node, N, avg, d):
        kind = node[0]
        if kind in 'at':
            f = 1 if kind == 'a' else self.posting(node[1], d)['frequency']
            return contribution(avg, self.weights[node[2]], idf(N, self.cost(node)), f, doc_length(d))
        kids = node[-1]
        if kind in 'ilk':
            order = sorted(range(len(kids)), key=lambda i: (self.cost(kids[i]), i))
            return 1.0 * fold([self.score(kids[i], N, avg, d) for i in order])
        if kind in 'uf':
            matched = [c for c in kids if d in set(self.eval_set(c))]
            if kind == 'f':
                return 1.0 * self.score(matched[0], N, avg, d)
            return 1.0 * fold([self.score(c, N, avg, d) for c in matched])
        if kind == 'd':
            return self.score(kids[0], N, avg, d)
        return 1.0 * fold([self.score(c, N, avg, d) for c in kids])

    def visible(self, i):
        if i >= self.built or i >= len(self.table):
            return False
        lv, cs = self.table[i]
        return lv <= self.reader[0] and cs <= self.reader[1]


def tree_text(node):
    kind = node[0]
    if kind in 'at':
        return f'{kind}{node[1]}.{node[2]}'
    inner = ','.join(tree_text(c) for c in node[-1])
    if kind == 'p':
        return f'p{node[1]}o{1 if node[2] else 0}[{inner}]'
    return f'{kind}[{inner}]'


def popcount(x):
    return bin(x).count('1')


def validate(lst, p):
    if p['doc'] == 0 or p['doc'] > U32 - 2:
        return 'invalid'
    if lst['items'] and p['doc'] <= lst['items'][-1]['doc']:
        return 'order'
    if lst['words'] < 4 and p['mask'] >> (32 * lst['words']):
        return 'invalid'
    if not lst['pos']:
        return 'invalid' if p['positions'] or p['counts'] else 'ok'
    if len(p['counts']) != popcount(p['mask']):
        return 'invalid'
    if sum(p['counts']) != len(p['positions']):
        return 'invalid'
    if any(b <= a for a, b in zip(p['positions'], p['positions'][1:])):
        return 'invalid'
    return 'ok'


def corpus():
    rng = random.Random(SEED)
    lines, expected = [], []
    stats = {kind: 0 for kind in ROW_AREAS}
    extra = {'svbyte_values': 0, 'roaring_bitsets': 0, 'roaring_runs': 0, 'roaring_decodes_accepted': 0,
             'roaring_decodes_rejected': 0, 'postings': 0, 'posting_errors': {}, 'trees': 0, 'phrase_lists': 0,
             'phrase_disjoint_checked': 0, 'stat_errors': {}, 'hidden_ops': 0, 'ordered_true': 0, 'unordered_true': 0}
    m = Model()

    def emit(line, row):
        lines.append(line)
        expected.append(row)
        stats[line.split(' ')[0]] += 1

    def random_values(n):
        out = []
        for _ in range(n):
            bits = rng.choice([0, 1, 7, 8, 9, 15, 16, 17, 23, 24, 25, 31, 32])
            out.append(rng.randrange(1 << bits) if bits else 0)
        return out

    for _ in range(900):
        vals = random_values(rng.randrange(0, 41))
        enc = sv_encode(vals)
        extra['svbyte_values'] += len(vals)
        dec = sv_decode(enc + bytes(16), len(vals))
        assert dec[0] == vals
        emit(f'SE {nats(vals)}', f'SE|{hexs(enc)}|{len(enc)}|{sv_encoded_length(enc, len(vals))}|{nats(vals)}|{nats(vals)}|{dec[1]}|{dec[1]}')
    for _ in range(500):
        prev = rng.randrange(U32) if rng.randrange(3) == 0 else rng.randrange(1000)
        vals = sorted(rng.randrange(prev, min(U32, prev + 1 + rng.choice([10, 1000, 1 << 20, 1 << 31]))) for _ in range(rng.randrange(0, 30)))
        if rng.randrange(4) == 0:
            vals = random_values(len(vals))
        enc = sv_encode(sv_delta(vals, prev))
        emit(f'SD {prev} {nats(vals)}', f'SD|{hexs(enc)}|{len(enc)}|{nats(vals)}|{nats(vals)}|{len(enc)}|{len(enc)}')
    for _ in range(700):
        n = rng.randrange(0, 33)
        control = bytes(rng.randrange(256) for _ in range((n + 3) // 4))
        need = sum(((control[i // 4] >> (2 * (i % 4))) & 3) + 1 for i in range(n))
        data = control + bytes(rng.randrange(256) for _ in range(need + rng.randrange(0, 20)))
        dec = sv_decode(data, n)
        emit(f'SX {n} {hexs(data)}', f'SX|{sv_encoded_length(data, n)}|{nats(dec[0])}|{nats(dec[0])}|{dec[1]}|{dec[1]}')
    for _ in range(200):
        vals = random_values(rng.randrange(0, 30))
        enc = sv_encode(vals)
        emit(f'SW {nats(vals)}', f'SW|{hexs(enc)}|{len(enc)}')

    def sorted_list(n, hi):
        return sorted(rng.sample(range(hi), min(n, hi)))

    for _ in range(1500):
        hi = rng.choice([20, 100, 1000, 100000, U32 - 1])
        x = sorted_list(rng.choice([0, 1, 2, 5, 9, 16, 40, 100]), hi)
        y = sorted_list(rng.choice([0, 1, 3, 8, 17, 64, 300, 3000]), hi)
        if rng.randrange(3) == 0:
            x, y = y, x
        inter = [v for v in x if v in set(y)]
        uni = sorted(set(x) | set(y))
        diff = [v for v in x if v not in set(y)]
        emit(f'QA {nats(x)} {nats(y)}', f'QA|{nats(inter)}|{nats(inter)}|{nats(inter)}|{nats(inter)}|{nats(inter)}|{nats(inter)}|'
             f'{len(inter)}|{nats(uni)}|{nats(diff)}|1')
    for _ in range(1200):
        x = sorted(rng.randrange(60) for _ in range(rng.randrange(0, 30)))
        t = rng.randrange(65)
        fr = rng.randrange(len(x) + 3)
        lb = bisect.bisect_left(x, t)
        ub = bisect.bisect_right(x, t)
        emit(f'QB {nats(x)} {t} {fr}', f'QB|{lb}|{ub}|{max(fr, lb)}')

    def emit_describe(kind, line, bm, prefix=''):
        emit(line, f'{kind}|{prefix}{describe(bm)}')

    def roaring_session(size_scale):
        regs = m.bitmaps
        for r in range(4):
            regs[r] = RBitmap()
            emit(f'RX {r}', 'RX')
        for _ in range(rng.randrange(60, 140)):
            choice = rng.randrange(14)
            r = rng.randrange(4)
            if choice < 4:
                x = rng.randrange(3 * CHUNK) if rng.randrange(4) else rng.randrange(U32)
                emit(f'RA {r} {x}', f'RA|{int(regs[r].add(x))}')
            elif choice < 6:
                c = regs[r].contents()
                x = rng.choice(c) if c and rng.randrange(3) else rng.randrange(3 * CHUNK)
                emit(f'RR {r} {x}', f'RR|{int(regs[r].remove(x))}')
            elif choice == 6:
                c = regs[r].contents()
                x = rng.choice(c) if c and rng.randrange(2) else rng.randrange(3 * CHUNK)
                emit(f'RC {r} {x}', f'RC|{int(regs[r].contains(x))}')
            elif choice == 7:
                start = rng.randrange(3) * CHUNK + rng.randrange(1000)
                count = rng.choice([10, 100, 1000, 4096, 4097, 4200]) if size_scale else rng.randrange(1, 60)
                count = min(count, 5000)
                step = rng.choice([1, 1, 2, 3, 7])
                for i in range(count):
                    regs[r].add(start + i * step)
                emit(f'RF {r} {start} {count} {step}', f'RF|{len(regs[r].contents())}')
            elif choice == 8:
                op = rng.choice(['and', 'or', 'andnot'])
                a, b, out = rng.randrange(4), rng.randrange(4), rng.randrange(4)
                regs[out] = combine(op, regs[a], regs[b])
                emit_describe('RO', f'RO {op} {a} {b} {out}', regs[out])
            elif choice == 9:
                a, b = rng.randrange(4), rng.randrange(4)
                sb = set(regs[b].contents())
                emit(f'RN {a} {b}', f'RN|{sum(1 for v in regs[a].contents() if v in sb)}')
            elif choice == 10:
                regs[r], changed = run_optimize(regs[r])
                emit_describe('RP', f'RP {r}', regs[r], f'{int(changed)}|')
            elif choice == 11:
                emit_describe('RL', f'RL {r}', regs[r])
                a, b = rng.randrange(4), rng.randrange(4)
                same = ([k for k, _ in regs[a].items] == [k for k, _ in regs[b].items] and
                        [len(elems(c)) for _, c in regs[a].items] == [len(elems(c)) for _, c in regs[b].items] and
                        regs[a].contents() == regs[b].contents())
                emit(f'RE {a} {b}', f'RE|{int(same)}')
            elif choice == 12:
                vals = regs[r].contents()
                ops = []
                for _ in range(rng.randrange(1, 12)):
                    if rng.randrange(2):
                        ops.append('n')
                    else:
                        ops.append(str(rng.choice(vals) + rng.choice([-1, 0, 1]) if vals and rng.randrange(2) else rng.randrange(4 * CHUNK)))
                pos, started, done, outs = 0, False, False, []
                for o in ops:
                    if done:
                        outs.append('-')
                    elif o == 'n':
                        if not started:
                            started = True
                            if not vals:
                                done = True
                                outs.append('-')
                            else:
                                pos = 0
                                outs.append(str(vals[0]))
                        elif pos + 1 < len(vals):
                            pos += 1
                            outs.append(str(vals[pos]))
                        else:
                            done = True
                            outs.append('-')
                    else:
                        t = max(int(o), 0)
                        if started and vals[pos] >= t:
                            outs.append(str(vals[pos]))
                        else:
                            started = True
                            i = bisect.bisect_left(vals, t)
                            if i < len(vals):
                                pos = i
                                outs.append(str(vals[i]))
                            else:
                                done = True
                                outs.append('-')
                ops = [o if o == 'n' else str(max(int(o), 0)) for o in ops]
                emit(f'RT {r} {",".join(ops)}', f'RT|{",".join(outs)}')
            else:
                data = serialize(regs[r])
                if len(data) < 40000:
                    emit(f'RS {r}', f'RS|{hexs(data)}')
                    back = deserialize(data)
                    assert back is not None and back[0].items == regs[r].items, 'serialization model round trip'
                    emit(f'RD {hexs(data)}', f'RD|{back[1]}|{describe(back[0])}')
                    extra['roaring_decodes_accepted'] += 1
                    for _ in range(3 if len(data) < 2000 else 1):
                        mutated = bytearray(data)
                        how = rng.randrange(4)
                        if how == 0 and mutated:
                            mutated = mutated[:rng.randrange(len(mutated))]
                        elif how == 1 and mutated:
                            mutated[rng.randrange(len(mutated))] ^= 1 << rng.randrange(8)
                        elif how == 2 and len(mutated) > 8:
                            mutated[rng.randrange(min(len(mutated), 64))] = rng.randrange(256)
                        else:
                            mutated += bytes(rng.randrange(256) for _ in range(rng.randrange(1, 5)))
                        res = deserialize(mutated)
                        if res is None:
                            extra['roaring_decodes_rejected'] += 1
                            emit(f'RD {hexs(mutated)}', 'RD|invalid')
                        else:
                            extra['roaring_decodes_accepted'] += 1
                            emit(f'RD {hexs(mutated)}', f'RD|{res[1]}|{describe(res[0])}')
            for _, c in regs[r].items:
                if c[0] == 'b':
                    extra['roaring_bitsets'] += 1
                if c[0] == 'r':
                    extra['roaring_runs'] += 1

    for s in range(28):
        roaring_session(s % 2 == 0)
    crafted = [b'', b'\x3a\x30', b'\x3a\x30\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x05\x00',
               b'\x3a\x30\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x05\x00',
               b'\x3b\x30\x00\x00\x01\x00\x00\x01\x00\x01\x00\x00\x00\x01\x00',
               b'\x3b\x30\x00\x00\x01\x00\x00\x00\x00\x01\x00\x05\x00\x00\x00',
               b'\x3b\x30\x00\x00\x01\x00\x00\x01\x00\x02\x00\x00\x00\x00\x00\x01\x00\x00\x00',
               b'\x3a\x30\x00\x00\x02\x00\x00\x00\x05\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x01\x00',
               b'\x3a\x30\x00\x00\x01\x00\x00\x00\x00\x00\x01\x00\x10\x00\x00\x00\x07\x00\x05\x00']
    for data in crafted:
        res = deserialize(data)
        emit(f'RD {hexs(data)}', 'RD|invalid' if res is None else f'RD|{res[1]}|{describe(res[0])}')

    def make_list(k, text_fields, with_pos, ndocs):
        words = min(4, max(1, (text_fields + 31) // 32))
        m.lists[k] = {'words': words, 'pos': with_pos, 'items': []}
        emit(f'PL {k} {text_fields} {int(with_pos)}', f'PL|{words}')
        doc = 0
        for _ in range(ndocs):
            doc += rng.choice([1, 1, 2, 3, 10, 100])
            if rng.randrange(30) == 0:
                d = rng.choice([0, doc - 1 if doc > 1 else 0, U32 - 1, doc])
            else:
                d = doc
            freq = rng.randrange(1, 9)
            nf = rng.randrange(1, min(4, 32 * words) + 1)
            fields = sorted(rng.sample(range(min(32 * words, 40)), nf))
            mask = sum(1 << f for f in fields)
            if rng.randrange(40) == 0:
                mask |= 1 << (32 * words) if words < 4 else 0
            counts = [rng.randrange(1, 4) for _ in fields] if with_pos else []
            positions = sorted(rng.sample(range(1, 200), sum(counts))) if with_pos else []
            if with_pos and rng.randrange(40) == 0 and positions:
                positions[0] = positions[-1]
            if with_pos and rng.randrange(50) == 0:
                counts = counts[:-1]
            if not with_pos and rng.randrange(50) == 0:
                counts = [1]
            p = {'doc': d, 'frequency': freq, 'mask': mask, 'counts': counts, 'positions': positions}
            e = validate(m.lists[k], p)
            extra['posting_errors'][e] = extra['posting_errors'].get(e, 0) + 1
            if e == 'ok':
                m.lists[k]['items'].append(p)
                extra['postings'] += 1
            else:
                doc = m.lists[k]['items'][-1]['doc'] if m.lists[k]['items'] else 0
            n = len(m.lists[k]['items'])
            emit(f'PA {k} {d} {freq} {mask:x} {nats(counts)} {nats(positions)}', f'PA|{e}|{n}|{n // 128}|{n % 128}')

    def drain_row(k):
        lst = m.lists[k]
        rows = []
        for p in lst['items']:
            if p['doc'] in m.deleted or (m.required and not p['mask'] & m.required):
                continue
            rows.append(f"{p['doc']}:{p['frequency']}:{p['mask']:x}:{nats(p['positions'] if lst['pos'] else [])}")
        emit(f'PC {k}', 'PC|' + (';'.join(rows) if rows else '-'))

    def set_deleted(ds):
        m.deleted = set(ds)
        emit(f'DL {nats(sorted(set(ds)))}', 'DL')

    def set_required(r):
        m.required = r
        emit(f'RQ {r:x}', 'RQ')

    for k in range(10):
        make_list(k, rng.choice([1, 5, 31, 32, 33, 70, 128]), k % 4 != 3, rng.choice([5, 40, 127, 128, 129, 300]))
    for _ in range(40):
        k = rng.randrange(10)
        docs = [p['doc'] for p in m.lists[k]['items']]
        set_deleted(rng.sample(docs, min(len(docs), rng.randrange(0, 12))) + [rng.randrange(1, 500) for _ in range(rng.randrange(3))])
        set_required(rng.choice([0, 0, 1, 2, 3, 1 << 33, (1 << 40) - 1]))
        drain_row(k)
        accepted = [p['doc'] for p in m.lists[k]['items'] if p['doc'] not in m.deleted and (m.required == 0 or p['mask'] & m.required)]
        targets = sorted(rng.randrange(1, (docs[-1] if docs else 10) + 50) for _ in range(rng.randrange(1, 15)))
        if rng.randrange(3) == 0:
            targets = [rng.randrange(1, (docs[-1] if docs else 10) + 50) for _ in range(rng.randrange(1, 15))]
        emit(f'PV {k} {nats(targets)}', f'PV|{protocol(accepted, targets)}')
    for k in range(10):
        docs = [p['doc'] for p in m.lists[k]['items']]
        set_deleted(rng.sample(docs, min(len(docs), rng.randrange(0, 30))))
        gone = [d for d in docs if d in m.deleted]
        m.lists[k]['items'] = [p for p in m.lists[k]['items'] if p['doc'] not in m.deleted]
        emit(f'PK {k}', f'PK|{len(gone)}|{nats(gone)}|{len(m.lists[k]["items"])}')
        set_deleted([])
        drain_row(k)
    set_required(0)
    for k in range(10, 16):
        make_list(k, 2, True, rng.choice([20, 60, 140]))

    for k in range(12):
        n = rng.choice([0, 3, 10, 40, 100, 160])
        docs = sorted(rng.sample(range(1, 220), n))
        if rng.randrange(4) == 0:
            docs = [0] + docs
        m.arrays[k] = docs
        emit(f'AR {k} {nats(docs)}', 'AR')
    weights = [1.0, 0.1, 0.2, 0.3, 1.5, 2.0 / 3.0, 1e-3]
    m.weights = weights
    emit(f'WT {",".join(fbits(w) for w in weights)}', 'WT')

    def leaf(allow_terms=True):
        if allow_terms and rng.randrange(2):
            return ('t', rng.randrange(16), rng.randrange(len(weights)))
        return ('a', rng.randrange(12), rng.randrange(len(weights)))

    def tree(depth):
        if depth == 0 or rng.randrange(4) == 0:
            return leaf()
        kind = rng.choice('iilkuufd')
        if kind == 'd':
            return ('d', [tree(depth - 1), tree(depth - 1)])
        return (kind, [tree(depth - 1) for _ in range(rng.randrange(1, 4))])

    def phrase_tree():
        kids = []
        for _ in range(rng.randrange(1, 4)):
            if rng.randrange(4) == 0:
                kids.append(('u', [('t', rng.randrange(10, 16), rng.randrange(len(weights))) for _ in range(2)]))
            else:
                kids.append(('t', rng.randrange(10, 16), rng.randrange(len(weights))))
        return ('p', rng.choice([-1, 0, 1, 2, 5, 50]), rng.randrange(2) == 1, kids)

    for _ in range(700):
        if rng.randrange(6) == 0:
            set_deleted([rng.randrange(1, 220) for _ in range(rng.randrange(0, 15))])
        node = tree(3)
        docs = m.eval_set(node)
        extra['trees'] += 1
        emit(f'T {tree_text(node)}', f'T|{nats(docs)}')
        targets = sorted(rng.randrange(1, 260) for _ in range(rng.randrange(1, 10)))
        emit(f'TA {tree_text(node)} {nats(targets)}', f'TA|{protocol(docs, targets)}')
        N = rng.choice([1, 10, 200, 5000])
        tl = N * rng.randrange(1, 20)
        avg = tl / N
        rows = [f'{d}:{fbits(m.score(node, N, avg, d) * doc_score(d))}' for d in docs]
        emit(f'TS {N} {tl} {tree_text(node)}', 'TS|' + (','.join(rows) if rows else '-'))
    set_deleted([])
    for _ in range(500):
        node = phrase_tree()
        docs = m.eval_set(node)
        emit(f'TP {tree_text(node)}', f'TP|{nats(docs)}')
        N = rng.choice([10, 300])
        tl = N * 9
        rows = [f'{d}:{fbits(m.score(node, N, tl / N, d) * doc_score(d))}' for d in docs]
        emit(f'TS {N} {tl} {tree_text(node)}', 'TS|' + (','.join(rows) if rows else '-'))
    for _ in range(2500):
        k = rng.randrange(1, 5)
        lists = []
        disjoint = rng.randrange(2) == 0
        pool = list(range(1, 40))
        rng.shuffle(pool)
        for i in range(k):
            n = rng.randrange(0, 6) if rng.randrange(10) else 0
            if disjoint:
                l = sorted(pool[:n])
                pool = pool[n:]
            else:
                l = sorted(rng.sample(range(1, 30), n))
            lists.append(l)
        slop = rng.choice([-1, 0, 0, 1, 2, 3, 10])
        o = ordered_def(lists, slop)
        assert o == ordered_brute(lists, slop), 'greedy ordered window equals the chain definition'
        u = sweep(lists, slop)
        if u and k >= 2:
            assert unordered_brute(lists, slop), 'sweep soundness'
        if disjoint and k >= 2 and all(lists):
            extra['phrase_disjoint_checked'] += 1
            assert u == unordered_brute(lists, slop), 'sweep completeness on disjoint lists'
        extra['phrase_lists'] += 1
        extra['ordered_true'] += int(o)
        extra['unordered_true'] += int(u)
        emit(f'PW {rng.randrange(2)} {slop} {";".join(nats(l) for l in lists)}', f'PW|{int(o)}|{int(u)}')
    emit('PW 0 0 5;5,6', 'PW|1|0')

    labels = [(0, []), (1, []), (1, [0]), (2, [0, 1]), (2, [1]), (3, [0, 1, 2]), (1, [2]), (3, [])]
    for lv, cs in labels:
        lab = (lv, frozenset(cs))
        if lab in m.table:
            idx = m.table.index(lab)
        else:
            idx = len(m.table)
            m.table.append(lab)
        emit(f'LB {lv} {nats(sorted(cs))}', f'LB|{idx}')

    def set_reader(lv, cs):
        m.reader = (lv, frozenset(cs))
        m.built = len(m.table)
        emit(f'LV {lv} {nats(sorted(cs))}', f'LV|{m.built}')

    def stat_err(e):
        extra['stat_errors'][e] = extra['stat_errors'].get(e, 0) + 1
        return e

    def term_add(term, lab, delta):
        if lab == ID_NONE:
            return stat_err('invalid')
        t = m.terms.setdefault(term, {})
        if lab in t and delta > U32_MAX - t[lab]:
            return stat_err('overflow')
        t[lab] = t.get(lab, 0) + delta
        return stat_err('ok')

    def term_remove(term, lab, delta):
        t = m.terms.get(term, {})
        if lab not in t:
            return stat_err('ok' if delta == 0 else 'underflow')
        if t[lab] < delta:
            return stat_err('underflow')
        t[lab] -= delta
        if t[lab] == 0:
            del t[lab]
        return stat_err('ok')

    def total_docs():
        return sum(m.docs.values()), sum(m.lens.values())

    def doc_add(lab, ln):
        if lab == ID_NONE:
            return stat_err('invalid')
        d, l = total_docs()
        if U64_MAX - d < 1:
            return stat_err('overflow')
        if U64_MAX - l < ln:
            return stat_err('overflow')
        m.docs[lab] = m.docs.get(lab, 0) + 1
        m.lens[lab] = m.lens.get(lab, 0) + ln
        return stat_err('ok')

    def doc_remove(lab, ln):
        if m.docs.get(lab, 0) == 0 or m.lens.get(lab, 0) < ln:
            return stat_err('underflow')
        m.docs[lab] -= 1
        m.lens[lab] -= ln
        return stat_err('ok')

    readers = [(0, []), (1, [0]), (2, [0, 1]), (3, [0, 1, 2]), (3, []), (2, [1])]
    for reader in readers:
        set_reader(*reader)
        for _ in range(350):
            choice = rng.randrange(8)
            term = rng.randrange(12)
            lab = rng.randrange(len(m.table) + 2) if rng.randrange(25) else ID_NONE
            if not m.visible(lab):
                extra['hidden_ops'] += 1
            if choice < 3:
                delta = rng.choice([0, 1, 1, 2, 5, 100])
                e = term_add(term, lab, delta)
                t = m.terms.get(term, {})
                emit(f'SA {term} {lab} {delta}', f'SA|{e}|{sum(t.values())}|{t.get(lab, 0)}')
            elif choice < 5:
                delta = rng.choice([0, 1, 1, 2, 3, 50])
                e = term_remove(term, lab, delta)
                t = m.terms.get(term, {})
                emit(f'SR {term} {lab} {delta}', f'SR|{e}|{sum(t.values())}|{t.get(lab, 0)}')
            elif choice == 5:
                ln = rng.randrange(0, 40)
                kind = 'DA' if rng.randrange(3) else 'DX'
                e = doc_add(lab, ln) if kind == 'DA' else doc_remove(lab, ln)
                d, l = total_docs()
                emit(f'{kind} {lab} {ln}', f'{kind}|{e}|{d}|{l}')
            elif choice == 6:
                t = m.terms.get(term, {})
                vis = sum(c for l, c in t.items() if m.visible(l))
                emit(f'SV {term}', f'SV|{vis}|{sum(t.values())}')
            else:
                vd = sum(c for l, c in m.docs.items() if m.visible(l))
                vl = sum(c for l, c in m.lens.items() if m.visible(l))
                d, l = total_docs()
                emit('ST', f'ST|{vd}|{vl}|{d}|{l}')
        term = rng.randrange(12)
        m.terms[term] = {}
        emit(f'SF {term}', 'SF|0')

    for _ in range(400):
        N = rng.choice([0, 1, 2, 10, 1000, 1 << 20, 1 << 40])
        n = rng.choice([0, 1, 2, 5, N, N + 1, N * 2 + 3, rng.randrange(N + 10)])
        emit(f'BI {N} {n}', f'BI|{fbits(idf(N, n))}')
    for _ in range(1500):
        N = rng.choice([1, 2, 10, 1000, 123456])
        tl = N * rng.randrange(1, 300) + rng.randrange(N)
        n = rng.randrange(0, N + 5)
        w = rng.choice([1.0, 0.1, 0.3, 2.5, 1e-9, 7.0 / 3.0])
        f = rng.randrange(0, 50)
        dl = rng.randrange(0, 2000)
        sc = rng.choice([1.0, 0.5, 0.75, 2.0, 0.375])
        avg = tl / N
        prepared = idf(N, n)
        c = contribution(avg, w, prepared, f, dl)
        emit(f'BM {N} {tl} {n} {fbits(w)} {f} {dl} {fbits(sc)}', f'BM|{fbits(prepared)}|{fbits(avg)}|{fbits(c)}|{fbits(c * sc)}')
    for _ in range(800):
        cst = rng.choice([60.0, 1.0, 10.0, 0.5, 0.0])
        window = rng.choice([20, 2, 3, 0, -1, 100])
        branches = []
        for _ in range(rng.randrange(1, 4)):
            pool = rng.sample(range(1, 60), rng.randrange(0, 25))
            if rng.randrange(8) == 0 and pool:
                pool.append(pool[0])
            branches.append(pool)
        parts = []
        for bi, b in enumerate(branches):
            n = len(b) if window <= 0 else min(len(b), window)
            for r in range(n):
                parts.append((b[r], bi, r, 1.0 / (cst + float(r + 1))))
        parts.sort(key=lambda p: (p[0], p[1], p[2]))
        fused = {}
        for d, _, _, v in parts:
            fused.setdefault(d, []).append(v)
        out = sorted(((d, fold(vs)) for d, vs in fused.items()), key=lambda p: (-p[1], p[0]))
        emit(f'FU {fbits(cst)} {window} {";".join(nats(b) for b in branches)}',
             'FU|' + (','.join(f'{d}:{fbits(s)}' for d, s in out) if out else '-'))
    for _ in range(800):
        k = rng.choice([0, 1, 3, 10, -2])
        items = []
        for _ in range(rng.randrange(0, 30)):
            items.append((rng.randrange(1, 40), rng.choice([0.5, 1.0, 1.0, 2.25, -1.0, math.inf, -math.inf, rng.random()])))
        if k <= 0:
            best, thr = [], math.inf
        else:
            ordered = sorted(items, key=lambda p: (-p[1], p[0]))
            best = ordered[:k]
            thr = -math.inf if len(best) < k else best[-1][1]
        emit(f'TK {k} {",".join(f"{d}:{fbits(s)}" for d, s in items) or "-"}',
             f'TK|{len(items)}|{",".join(f"{d}:{fbits(s)}" for d, s in best) or "-"}|{fbits(thr)}')
    for kind, count in stats.items():
        if count == 0:
            raise AssertionError('corpus has no ' + kind + ' rows')
    return '\n'.join(lines) + '\n', expected, stats, extra


def compare(label, got, want):
    rows = got.splitlines()
    if not want or len(rows) != len(want):
        raise AssertionError(f'{label}: {len(rows)} rows, expected {len(want)}')
    for i, (a, b) in enumerate(zip(rows, want)):
        if a != b:
            raise AssertionError(f'{label}: row {i}: {a[:300]!r} != {b[:300]!r}')


def check_fingerprints():
    pinned = json.loads((PACKAGE / 'source-sha256.json').read_text())
    if len(pinned) < 10:
        raise AssertionError('missing source drift gates')
    for name, wanted in pinned.items():
        if digest(ROOT / name) != wanted:
            raise AssertionError(f'source changed: {name}; reconcile the model before updating its gate')
    return pinned


def find_odin(env, explicit):
    candidates = [explicit, os.environ.get('ODIN'), shutil.which('odin', path=env.get('PATH')),
                  str(Path.home() / 'odin/current/odin')]
    for c in candidates:
        if c and Path(c).is_file() and os.access(c, os.X_OK):
            return str(Path(c).resolve())
    raise AssertionError('Odin compiler not found; use --odin, ODIN, PATH or ~/odin/current/odin')


def build(output, lean_bin, odin_path):
    env = dict(os.environ, LEAN_NUM_THREADS='1')
    if lean_bin:
        env['PATH'] = str(lean_bin.resolve()) + os.pathsep + env.get('PATH', '')
    lake = shutil.which('lake', path=env.get('PATH'))
    lean = shutil.which('lean', path=env.get('PATH'))
    if not lake or not lean:
        raise AssertionError('Lean 4.35.0 and Lake must be available; use --lean-bin or LEAN_BIN_DIR')
    odin = find_odin(env, odin_path)
    version = subprocess.run([lean, '--version'], cwd=PACKAGE, env=env, text=True, capture_output=True, check=True).stdout
    if not re.search(r'\bversion 4\.35\.0\b', version):
        raise AssertionError(f'expected pinned Lean 4.35.0: {version}')
    odin_version = subprocess.run([odin, 'version'], env=env, text=True, capture_output=True, check=True).stdout
    commands = [([lake, 'build'], PACKAGE),
                ([odin, 'build', str(PACKAGE / 'bridge.odin'), '-file', '-out:' + str(output / 'odin_bridge'),
                  '-thread-count:2', '-vet', '-strict-style'], ROOT)]
    lock = ROOT / '.build/proofs/compiler.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    logs = []
    with lock.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        for command, cwd in commands:
            result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
            logs.append(result.stdout + result.stderr)
            (output / 'build.txt').write_text('\n'.join(logs))
            if result.returncode:
                raise AssertionError(f'build failed; see {output / "build.txt"}\n{logs[-1][-4000:]}')
        axioms, kernel = audit_kernel(Path(lake), PACKAGE, output, env, 'Postings')
    versions = {'lean': version.strip(), 'odin': odin_version.strip()}
    tools = {name: digest(Path(path)) for name, path in (('lean', lean), ('lake', lake), ('odin', odin))}
    return PACKAGE / '.lake/build/bin/postings_model', output / 'odin_bridge', axioms, kernel, versions, tools


def first_row(expected, prefix, accept):
    return next((i for i, row in enumerate(expected) if row.startswith(prefix) and accept(row)), None)


def negative_controls(lines, expected):
    cases = {'empty': '', 'truncated': '\n'.join(expected[:-1]) + '\n',
             'extra': '\n'.join(expected + [expected[0]]) + '\n'}
    kinds = {}
    for i, row in enumerate(expected):
        kinds.setdefault(row.split('|')[0], i)
    for kind, i in sorted(kinds.items()):
        cells = expected[i].split('|')
        for column in range(1, len(cells)):
            mutated = list(expected)
            mutant = list(cells)
            mutant[column] = 'controlled-mutant'
            mutated[i] = '|'.join(mutant)
            cases[f'{kind}_column_{column}'] = '\n'.join(mutated) + '\n'

    def cell(row, k):
        return row.split('|')[k]

    def with_cell(row, k, value):
        c = row.split('|')
        c[k] = value
        return '|'.join(c)

    def line_of(row_index):
        return lines[row_index].split(' ')

    def bm25_alt(i):
        f = line_of(i)
        N, tl, n, w, fr, dl, sc = int(f[1]), int(f[2]), int(f[3]), unbits(f[4]), int(f[5]), int(f[6]), unbits(f[7])
        avg = tl / N
        prepared = idf(N, n)
        alt = w * prepared * (fr * (K1 + 1)) / (fr + K1 * (1 - B + B * dl / avg))
        return fbits(alt)

    def rrf_no_window(i):
        f = line_of(i)
        cst = unbits(f[1])
        branches = [[int(x) for x in g.split(',')] if g != '-' else [] for g in f[3].split(';')]
        fused = {}
        for bi, b in enumerate(branches):
            for r, d in enumerate(b):
                fused.setdefault(d, []).append((bi, r, 1.0 / (cst + float(r + 1))))
        out = sorted(((d, fold([v for _, _, v in sorted(vs)])) for d, vs in fused.items()), key=lambda p: (-p[1], p[0]))
        return 'FU|' + (','.join(f'{d}:{fbits(s)}' for d, s in out) if out else '-')

    def sd_no_prefix(i):
        f = line_of(i)
        prev = int(f[1])
        vals = [int(x) for x in f[2].split(',')] if f[2] != '-' else []
        return nats(sv_delta(vals, prev))

    semantic = {
        'delta_decode_without_prefix_sums': ('SD|', lambda i, r: cell(r, 3) != '-' and sd_no_prefix(i) != cell(r, 3),
                                             lambda i, r: with_cell(r, 3, sd_no_prefix(i))),
        'decode_overreads': ('SX|', lambda i, r: True, lambda i, r: with_cell(r, 4, str(int(cell(r, 4)) + 1))),
        'gallop_ignores_start': ('QB|', lambda i, r: cell(r, 3) != cell(r, 1), lambda i, r: with_cell(r, 3, cell(r, 1))),
        'intersection_keeps_left': ('QA|', lambda i, r: cell(r, 1) != line_of(i)[1], lambda i, r: with_cell(r, 1, line_of(i)[1])),
        'union_drops_right': ('QA|', lambda i, r: cell(r, 8) != line_of(i)[1], lambda i, r: with_cell(r, 8, line_of(i)[1])),
        'difference_keeps_excluded': ('QA|', lambda i, r: cell(r, 9) != line_of(i)[1], lambda i, r: with_cell(r, 9, line_of(i)[1])),
        'bitset_never_built': ('RO|', lambda i, r: ':b:' in r, lambda i, r: r.replace(':b:', ':a:', 1)),
        'runs_never_built': ('RP|1|', lambda i, r: ':r' in r, lambda i, r: re.sub(r':r\d+:', ':a:', r, count=1)),
        'offsets_counted': ('RD|', lambda i, r: cell(r, 1) != 'invalid', lambda i, r: with_cell(r, 1, str(int(cell(r, 1)) + 4))),
        'trailing_rejected': ('RD|', lambda i, r: cell(r, 1) != 'invalid' and len(line_of(i)[1]) // 2 > int(cell(r, 1)),
                              lambda i, r: 'RD|invalid'),
        'iteration_unsorted': ('RT|', lambda i, r: len([x for x in cell(r, 1).split(',') if x != '-']) >= 2 and
                               cell(r, 1).split(',')[0] != cell(r, 1).split(',')[1] and '-' not in cell(r, 1).split(',')[:2],
                               lambda i, r: with_cell(r, 1, ','.join([cell(r, 1).split(',')[1], cell(r, 1).split(',')[0]] +
                                                                    cell(r, 1).split(',')[2:]))),
        'out_of_order_accepted': ('PA|order', lambda i, r: True, lambda i, r: with_cell(r, 1, 'ok')),
        'collect_keeps_deleted': ('PK|', lambda i, r: cell(r, 1) != '0', lambda i, r: with_cell(r, 1, '0')),
        'deleted_posting_returned': ('PV|', lambda i, r: True, lambda i, r: with_cell(r, 1, cell(r, 1) + ',1')),
        'tree_drops_document': ('T|', lambda i, r: cell(r, 1) != '-', lambda i, r: with_cell(r, 1, ','.join(cell(r, 1).split(',')[1:]) or '-')),
        'inorder_ignores_order': ('PW|0|1', lambda i, r: True, lambda i, r: 'PW|1|1'),
        'unordered_accepts_equal_positions': ('PW|1|0', lambda i, r: line_of(i)[3] == '5;5,6', lambda i, r: 'PW|1|1'),
        'visible_totals_include_hidden': ('ST|', lambda i, r: cell(r, 1) != cell(r, 3), lambda i, r: with_cell(r, 1, cell(r, 3))),
        'term_visible_includes_hidden': ('SV|', lambda i, r: cell(r, 1) != cell(r, 2), lambda i, r: with_cell(r, 1, cell(r, 2))),
        'bm25_parenthesised_numerator': ('BM|', lambda i, r: bm25_alt(i) != cell(r, 3), lambda i, r: with_cell(r, 3, bm25_alt(i))),
        'idf_without_max': ('BI|', lambda i, r: int(line_of(i)[2]) > int(line_of(i)[1]),
                            lambda i, r: with_cell(r, 1, fbits(math.log(1 + (int(line_of(i)[1]) - int(line_of(i)[2]) + 0.5) /
                                                                       (int(line_of(i)[2]) + 0.5))))),
        'rrf_window_ignored': ('FU|', lambda i, r: rrf_no_window(i) != r, lambda i, r: rrf_no_window(i)),
        'topk_order_reversed': ('TK|', lambda i, r: cell(r, 2).count(',') >= 1 and
                                cell(r, 2).split(',')[0].split(':')[1] != cell(r, 2).split(',')[-1].split(':')[1],
                                lambda i, r: with_cell(r, 2, ','.join(reversed(cell(r, 2).split(','))))),
    }
    for name, (prefix, accept, mutate) in semantic.items():
        index = first_row(expected, prefix, lambda row: True)
        index = next((i for i, row in enumerate(expected) if row.startswith(prefix) and accept(i, row) and mutate(i, row) != row), None)
        if index is None:
            raise AssertionError('no row for semantic negative control ' + name)
        mutated = list(expected)
        mutated[index] = mutate(index, expected[index])
        cases['semantic_' + name] = '\n'.join(mutated) + '\n'
    rejected = []
    for name, mutant in cases.items():
        try:
            compare(name, mutant, expected)
        except AssertionError:
            rejected.append(name)
        else:
            raise AssertionError('negative control accepted: ' + name)
    return rejected


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('--lean-bin', type=Path, default=Path(os.environ['LEAN_BIN_DIR']) if 'LEAN_BIN_DIR' in os.environ else None)
    parser.add_argument('--odin', default=None)
    parser.add_argument('--output', type=Path, default=PACKAGE / '.build')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    output = args.output.resolve()
    (output / 'receipt.json').unlink(missing_ok=True)
    if hasattr(os, 'sched_getaffinity'):
        os.sched_setaffinity(0, {min(os.sched_getaffinity(0))})
    if hasattr(os, 'nice'):
        os.nice(10)
    fingerprints = check_fingerprints()
    lean_model, odin_bridge, axioms, kernel, versions, tools = build(output, args.lean_bin, args.odin)
    trace, expected, stats, extra = corpus()
    lines = trace.splitlines()
    path = output / 'cases.txt'
    path.write_text(trace)
    results = {}
    for name, binary in (('lean', lean_model), ('odin', odin_bridge)):
        result = subprocess.run([str(binary.resolve()), str(path)], text=True, capture_output=True)
        if result.returncode or result.stderr:
            raise AssertionError(f'{name}: exit {result.returncode}, stderr: {result.stderr[-2000:]}')
        (output / f'{name}-results.txt').write_text(result.stdout)
        compare(name, result.stdout, expected)
        results[name] = hashlib.sha256(result.stdout.encode()).hexdigest()
    if results['lean'] != results['odin']:
        raise AssertionError('Lean oracle and Odin rows differ')
    rejected = negative_controls(lines, expected)
    modules = {module: set(re.findall(r'^theorem\s+(\w+)', (PACKAGE / f'Postings/{module}.lean').read_text(), re.M))
               for files in AREAS.values() for module in files}
    comparisons = {area: sum(count for kind, count in stats.items() if ROW_AREAS[kind] == area) for area in AREAS}
    if any(not comparisons[area] for area in AREAS):
        raise AssertionError('every area needs comparison rows')
    area_evidence = {area: {'theorems': sorted(name for name in axioms
                                               if name.removeprefix('Postings.') in set().union(*(modules[m] for m in files))),
                            'comparisons': comparisons[area]}
                     for area, files in AREAS.items()}
    if any(not evidence['theorems'] for evidence in area_evidence.values()):
        raise AssertionError('every area needs named theorems in the manifest')
    receipt = {'rows': stats, 'details': extra, 'total_rows': len(expected), 'seed': hex(SEED),
               'toolchain': (PACKAGE / 'lean-toolchain').read_text().strip(),
               'area_evidence': area_evidence, 'checked_theorem_axioms': axioms,
               'kernel_inventory_sha256': digest(output / 'kernel-inventory.json'),
               'kernel_checked_theorems': len(kernel['theorem_axioms']),
               'source_sha256': fingerprints, 'versions': versions, 'tool_sha256': tools,
               'trace_sha256': hashlib.sha256(trace.encode()).hexdigest(), 'results_sha256': results,
               'executable_sha256': {'lean': digest(lean_model), 'odin': digest(odin_bridge)},
               'proof_source_sha256': {str(p.relative_to(PACKAGE)): digest(p) for p in sorted(PACKAGE.rglob('*'))
                                       if p.is_file() and not {'.lake', '.build', '__pycache__'} & set(p.parts)},
               'negative_controls_rejected': rejected,
               'odin_correspondence': 'finite implementation comparisons; no verified translation'}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    summary = {'rows': stats, 'details': extra, 'total_rows': len(expected), 'theorems': len(axioms),
               'kernel_checked_theorems': receipt['kernel_checked_theorems'],
               'negative_controls_rejected': len(rejected), 'receipt': str(output / 'receipt.json')}
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    run()
