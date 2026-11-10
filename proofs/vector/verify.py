import argparse
import fcntl
import hashlib
import heapq
import json
import math
import os
import random
import re
import shutil
import struct
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from kernel_audit import audit as audit_kernel
from labelled import labelled_corpus

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().parent
SEED = 0xE5A1EC7
DIM_MAX = 1 << 19
U8_MAX = (1 << 8) - 1
F32_OVERFLOW = Fraction(2 ** 128 - 2 ** 103)
AREAS = {
    'projection': ['Projection'],
    'quantisation': ['Quantise', 'Binary'],
    'heaps': ['Heap'],
    'visited': ['Visited'],
    'graph': ['Graph', 'Width', 'Twin'],
    'arena': ['Arena'],
    'filter': ['Filter'],
    'merge': ['Merge'],
    'resolution': ['Resolve'],
    'independence': ['Partition'],
    'compatibility': ['Plain'],
}
PROOF_ONLY = ('filter',)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def text(f):
    return f'{f.numerator}/{f.denominator}'


NONE = (1 << 32) - 1
LEVEL_FREE = 255
LEVEL_RESERVED = 254
LEVEL_TWIN = 253
LEVEL_CAP = 30
ISLAND_LIMIT = 64
FREE_MARK = 1 << 31
FREE_NIL = FREE_MARK - 1
ARENA_LIMIT = (1 << 31) - 1


def ids_text(ids):
    return ','.join(map(str, ids)) if ids else '-'


def cand_text(cs):
    return ','.join(f'{d}:{i}' for d, i in cs) if cs else '-'


class Index:
    def __init__(self, m, efc):
        self.m, self.m0, self.efc = m, 2 * m, efc
        self.coin = min(max(m // 2, 1), 2)
        self.level, self.nxt, self.prv, self.adj, self.pts = [], [], [], [], []
        self.free = []
        self.twins = self.live = self.max_level = 0
        self.entry = NONE
        self.width = 2
        self.events = {'evictions': 0, 'adoptions': 0, 'island_adoptions': 0, 'relinks': 0, 'repairs': 0}

    def cap(self, layer):
        return self.m0 if layer == 0 else self.m

    def dist(self, a, b):
        (xa, ya), (xb, yb) = self.pts[a], self.pts[b]
        return (xa - xb) ** 2 + (ya - yb) ** 2

    def is_node(self, x):
        return x < len(self.level) and self.level[x] <= LEVEL_CAP

    def is_live(self, x):
        return x < len(self.level) and self.level[x] < LEVEL_RESERVED

    def reserve(self):
        if self.free:
            slot = self.free.pop(0)
            self.level[slot] = LEVEL_RESERVED
            return slot
        slot = len(self.level)
        self.level.append(LEVEL_RESERVED)
        self.nxt.append(NONE)
        self.prv.append(0)
        self.adj.append([[]])
        self.pts.append((0, 0))
        return slot

    def push_free(self, slot):
        self.level[slot] = LEVEL_FREE
        self.adj[slot] = [[]]
        self.nxt[slot] = NONE
        self.free.insert(0, slot)

    def release(self, slot):
        if slot >= len(self.level) or self.level[slot] != LEVEL_RESERVED:
            return 3
        self.push_free(slot)
        return 0

    def list_remove(self, x, layer, y):
        lst = self.adj[x][layer]
        if y in lst:
            i = lst.index(y)
            lst[i] = lst[-1]
            lst.pop()

    def list_replace(self, x, layer, old, new):
        lst = self.adj[x][layer]
        if old in lst:
            lst[lst.index(old)] = new

    def list_append(self, x, layer, y):
        if len(self.adj[x][layer]) < self.cap(layer):
            self.adj[x][layer].append(y)

    def link_pair(self, a, b, layer):
        self.list_append(a, layer, b)
        self.list_append(b, layer, a)

    def greedy(self, dq, ep, d, layer):
        best = (d, ep)
        while True:
            changed = False
            for x in list(self.adj[best[1]][layer]):
                c = (dq(x), x)
                if c < best:
                    best, changed = c, True
            if not changed:
                return best

    def search_layer(self, entries, ef, layer, dq, adj=None):
        adj = adj if adj is not None else (lambda x: self.adj[x][layer])
        seen, cands, results = set(), [], []

        def push_result(c):
            if len(results) < ef:
                heapq.heappush(results, (-c[0], -c[1]))
            elif c < (-results[0][0], -results[0][1]):
                heapq.heapreplace(results, (-c[0], -c[1]))

        for e in entries:
            if e[1] in seen:
                continue
            seen.add(e[1])
            heapq.heappush(cands, e)
            push_result(e)
        while cands:
            c = heapq.heappop(cands)
            if results and c[0] > -results[0][0]:
                break
            fresh = []
            for x in adj(c[1]):
                if x not in seen:
                    seen.add(x)
                    fresh.append(x)
            for x in fresh:
                n = (dq(x), x)
                if len(results) < ef or n < (-results[0][0], -results[0][1]):
                    heapq.heappush(cands, n)
                    push_result(n)
        return sorted((-d, -i) for d, i in results)

    def select(self, work):
        selected, pruned = [], []
        for c in work:
            if len(selected) >= self.m:
                break
            if all(not (self.dist(c[1], r[1]) < c[0]) for r in selected):
                selected.append(c)
            else:
                pruned.append(c)
        for c in pruned:
            if len(selected) >= self.m:
                break
            selected.append(c)
        return selected

    def stranded(self, frm, hub, layer):
        seen, trail, head = {frm}, [frm], 0
        while head < len(trail):
            for y in self.adj[trail[head]][layer]:
                if y == hub:
                    return False
                if y not in seen:
                    seen.add(y)
                    if len(trail) == ISLAND_LIMIT:
                        return False
                    trail.append(y)
            head += 1
        return True

    def adopt(self, orphan, hub, layer):
        best = None
        for y in list(self.adj[hub][layer]):
            if (y == orphan or len(self.adj[y][layer]) >= self.cap(layer) or orphan in self.adj[y][layer]
                    or y in self.adj[orphan][layer]):
                continue
            c = (self.dist(orphan, y), y)
            if best is None or c < best:
                best = c
        if best is not None:
            self.link_pair(orphan, best[1], layer)

    def shrink_victim(self, e, layer, q, dq):
        shrink = sorted([(self.dist(e, y), y) for y in self.adj[e][layer]] + [(dq, q)])
        kept, dropped, blockers = [], [], []
        for c in shrink:
            blocker = None
            for r in kept:
                if self.dist(c[1], r[1]) < c[0]:
                    blocker = r[1]
                    break
            if blocker is None:
                kept.append(c)
            else:
                dropped.append(c)
                blockers.append(blocker)
        for i in range(len(dropped) - 1, -1, -1):
            v = dropped[i][1]
            if i < len(blockers) and len(self.adj[v][layer]) > 1 and blockers[i] in self.adj[v][layer]:
                return v
        for c in dropped:
            if c[1] == q and len(self.adj[q][layer]) > 1:
                return q
        for c in reversed(dropped):
            if len(self.adj[c[1]][layer]) > 1:
                return c[1]
        for c in reversed(kept):
            if len(self.adj[c[1]][layer]) > 1:
                return c[1]
        return shrink[-1][1]

    def connect(self, q, layer, selected):
        cap = self.cap(layer)
        own = [c[1] for c in selected[:cap]]
        self.adj[q][layer] = list(own)
        for c in selected[:len(own)]:
            e = c[1]
            if len(self.adj[e][layer]) < cap:
                self.adj[e][layer].append(q)
                continue
            victim = self.shrink_victim(e, layer, q, c[0])
            if victim == q:
                self.list_remove(q, layer, e)
            else:
                self.list_replace(e, layer, victim, q)
                self.list_remove(victim, layer, e)
            self.events['evictions'] += 1
            if len(self.adj[victim][layer]) == 0:
                self.events['adoptions'] += 1
                self.adopt(victim, e, layer)
            elif victim != q and self.stranded(victim, e, layer):
                self.events['island_adoptions'] += 1
                self.adopt(victim, e, layer)

    def coincident(self, work, dqq):
        t = self.coin
        if t == 0 or len(work) < t:
            return None
        tie = work[0][0]
        if work[t - 1][0] != tie or not tie <= dqq:
            return None
        head, found = None, 0
        for d, i in work:
            if d != tie:
                break
            if tie <= self.dist(i, i):
                if head is None:
                    head = i
                found += 1
                if found == t:
                    return head
        return None

    def insert(self, slot, lv):
        if self.entry == NONE:
            self.place(slot, lv)
            self.entry, self.max_level = slot, lv
            return
        dq = lambda x: self.dist(slot, x)
        ep, d = self.entry, dq(self.entry)
        for l in range(self.max_level, lv, -1):
            d, ep = self.greedy(dq, ep, d, l)
        entries = [(d, ep)]
        top = min(self.max_level, lv)
        layered = {}
        for l in range(top, -1, -1):
            work = [c for c in self.search_layer(entries, self.efc, l, dq) if c[1] != slot]
            entries = layered[l] = work
        head = self.coincident(layered[0], dq(slot))
        if head is not None:
            first = self.nxt[head]
            self.nxt[head], self.nxt[slot], self.prv[slot] = slot, first, head
            if first != NONE:
                self.prv[first] = slot
            self.level[slot] = LEVEL_TWIN
            self.adj[slot] = [[]]
            self.twins += 1
            self.live += 1
            return
        self.place(slot, lv)
        for l in range(top, -1, -1):
            self.connect(slot, l, self.select(layered[l]))
        if lv > self.max_level:
            self.entry, self.max_level = slot, lv

    def place(self, slot, lv):
        self.level[slot] = lv
        self.adj[slot] = [[] for _ in range(lv + 1)]
        self.live += 1

    def pick_entry(self):
        best, best_level = NONE, -1
        for i in range(len(self.level)):
            if self.is_node(i) and self.level[i] > best_level:
                best, best_level = i, self.level[i]
        self.entry, self.max_level = best, max(best_level, 0)

    def other_at_level(self, n, layer):
        for i in range(len(self.level)):
            if i != n and self.is_node(i) and self.level[i] >= layer:
                return i
        return NONE

    def relink(self, n, layer):
        start = self.entry
        if start == n:
            start = self.other_at_level(n, layer)
        if start == NONE:
            return
        dq = lambda x: self.dist(n, x)
        ep, d = start, dq(start)
        for l in range(self.level[start], layer, -1):
            d, ep = self.greedy(dq, ep, d, l)
        entries = []
        if ep != n:
            entries.append((d, ep))
        if layer + 1 <= self.level[n]:
            entries += [(dq(v), v) for v in self.adj[n][layer + 1]]
        if not entries:
            entries.append((dq(start), start))
        work = [c for c in self.search_layer(entries, self.efc, layer, dq) if c[1] != n]
        self.connect(n, layer, self.select(work))

    def repair(self, n, layer, group):
        cap = self.cap(layer)
        if len(self.adj[n][layer]) >= cap:
            return
        work = sorted((self.dist(n, c), c) for c in group if c != n and c not in self.adj[n][layer])
        pruned = []
        for c in work:
            if len(self.adj[n][layer]) >= cap:
                break
            if len(self.adj[c[1]][layer]) >= cap:
                continue
            if all(not (self.dist(c[1], r) < c[0]) for r in self.adj[n][layer]):
                self.link_pair(n, c[1], layer)
            else:
                pruned.append(c)
        for c in pruned:
            if len(self.adj[n][layer]) >= cap:
                break
            if len(self.adj[c[1]][layer]) >= cap:
                continue
            self.link_pair(n, c[1], layer)
        self.events['repairs'] += 1
        if len(self.adj[n][layer]) == 0:
            self.events['relinks'] += 1
            self.relink(n, layer)

    def remove(self, slot):
        if not self.is_live(slot):
            return 4
        if self.level[slot] == LEVEL_TWIN:
            p, n = self.prv[slot], self.nxt[slot]
            self.nxt[p] = n
            if n != NONE:
                self.prv[n] = p
            self.nxt[slot] = NONE
            self.twins -= 1
            self.push_free(slot)
            self.live -= 1
            return 0
        lv = self.level[slot]
        if self.nxt[slot] != NONE:
            heir = self.nxt[slot]
            self.adj[heir] = [list(x) for x in self.adj[slot]]
            self.level[heir] = lv
            for l in range(lv + 1):
                for y in list(self.adj[heir][l]):
                    self.list_replace(y, l, slot, heir)
            if self.entry == slot:
                self.entry = heir
            self.twins -= 1
            self.push_free(slot)
            self.live -= 1
            return 0
        removed = [list(self.adj[slot][l]) for l in range(lv + 1)]
        for l in range(lv + 1):
            for n in removed[l]:
                self.list_remove(n, l, slot)
        self.push_free(slot)
        self.live -= 1
        if self.live == 0:
            self.entry, self.max_level = NONE, 0
            return 0
        if self.entry == slot:
            self.pick_entry()
        for l in range(lv + 1):
            for n in removed[l]:
                self.repair(n, l, removed[l])
        return 0

    def search(self, qx, qy, k, ef):
        if self.entry == NONE or k <= 0:
            return []
        dq = lambda x: (self.pts[x][0] - qx) ** 2 + (self.pts[x][1] - qy) ** 2
        ep, d = self.entry, dq(self.entry)
        for l in range(self.max_level, 0, -1):
            d, ep = self.greedy(dq, ep, d, l)
        res = self.search_layer([(d, ep)], max(ef, k), 0, dq)
        if self.twins > 0:
            results = []

            def push(c):
                if len(results) < k:
                    heapq.heappush(results, (-c[0], -c[1]))
                elif c < (-results[0][0], -results[0][1]):
                    heapq.heapreplace(results, (-c[0], -c[1]))

            for c in res:
                if len(results) >= k and not c < (-results[0][0], -results[0][1]):
                    break
                push(c)
                t = self.nxt[c[1]]
                while t != NONE:
                    if len(results) >= k and not c[0] < -results[0][0]:
                        break
                    push((dq(t), t))
                    t = self.nxt[t]
            res = sorted((-d, -i) for d, i in results)
        return res[:k]

    def state(self):
        entry = '-' if self.entry == NONE else str(self.entry)
        slots = []
        for x, lv in enumerate(self.level):
            nxt = '-' if self.nxt[x] == NONE else str(self.nxt[x])
            prv = str(self.prv[x]) if lv == LEVEL_TWIN else '-'
            lists = '/'.join(ids_text(self.adj[x][l]) for l in range(lv + 1)) if lv <= LEVEL_CAP else '-'
            slots.append(f'{lv}:{nxt}:{prv}:{lists}')
        return f'{entry}:{self.max_level}:{self.live}:{self.twins}:{self.width}|{ids_text(self.free)}|{";".join(slots)}'

    def check(self):
        n = len(self.level)
        twins = [x for x in range(n) if self.level[x] == LEVEL_TWIN]
        nodes = [x for x in range(n) if self.level[x] <= LEVEL_CAP]
        assert all(self.level[x] <= LEVEL_CAP or self.level[x] in (LEVEL_TWIN, LEVEL_RESERVED, LEVEL_FREE) for x in range(n))
        assert self.twins == len(twins) and self.live == len(nodes) + len(twins)
        assert sorted(self.free) == [x for x in range(n) if self.level[x] == LEVEL_FREE] and len(set(self.free)) == len(self.free)
        for x in range(n):
            if self.nxt[x] != NONE:
                assert self.is_live(x) and self.level[self.nxt[x]] == LEVEL_TWIN and self.prv[self.nxt[x]] == x
        for t in twins:
            assert self.nxt[self.prv[t]] == t
            at, steps = t, 0
            while self.level[at] == LEVEL_TWIN:
                at, steps = self.prv[at], steps + 1
                assert steps <= len(twins)
            assert self.level[at] <= LEVEL_CAP
        if self.live:
            assert self.is_node(self.entry) and self.level[self.entry] == self.max_level
            assert all(self.level[x] <= self.max_level for x in nodes)
        else:
            assert self.entry == NONE
        for x in nodes:
            for l in range(self.level[x] + 1):
                lst = self.adj[x][l]
                assert len(lst) <= self.cap(l) and len(set(lst)) == len(lst) and x not in lst
                for y in lst:
                    assert self.is_node(y) and self.level[y] >= l and x in self.adj[y][l]


def f32_bits(v):
    return struct.unpack('<I', struct.pack('<f', v))[0]


def live_norm(b):
    if b & FREE_MARK == 0:
        return b, 1
    if b & 0x7F800000 == 0x7F800000 and b & 0x7FFFFF:
        return b & FREE_NIL, 1
    return b, 0


ENCODE_TOKENS = {'0': 1.0, '-0': 1.0, 'tiny': 1.0, 'huge': float('inf'), 'big': float(2 ** 63)}


class Arena:
    def __init__(self, cap):
        self.norms, self.cap, self.free, self.live = [], cap, NONE, 0

    def alloc(self):
        if self.free != NONE:
            slot = self.free
            nxt = self.norms[slot] & FREE_NIL
            self.free = NONE if nxt == FREE_NIL else nxt
            self.norms[slot] = 0
            self.live += 1
            return slot
        if len(self.norms) == self.cap:
            if self.cap >= ARENA_LIMIT:
                return None
            self.cap = min(max(1, self.cap * 2), ARENA_LIMIT)
        self.norms.append(0)
        self.live += 1
        return len(self.norms) - 1

    def release(self, s):
        if s >= len(self.norms):
            return 1
        if self.norms[s] & FREE_MARK:
            return 2
        self.norms[s] = FREE_MARK | (FREE_NIL if self.free == NONE else self.free)
        self.free = s
        self.live -= 1
        return 0

    def set_norm(self, s, b):
        stored, ok = live_norm(b)
        if ok:
            self.norms[s] = stored
        return ok

    def insert_normalised(self, b):
        if not live_norm(b)[1]:
            return None
        slot = self.alloc()
        self.set_norm(slot, b)
        return slot

    def set_encoded(self, s, token):
        value = ENCODE_TOKENS.get(token)
        if value is None:
            value = float(abs(int(token)))
        self.norms[s] = live_norm(f32_bits(value))[0]

    def is_live(self, s):
        return int(s < len(self.norms) and not self.norms[s] & FREE_MARK)

    def chain(self):
        out, at = [], self.free
        while at != NONE:
            assert at < len(self.norms) and len(out) <= len(self.norms)
            out.append(at)
            nxt = self.norms[at] & FREE_NIL
            at = NONE if nxt == FREE_NIL else nxt
        return out

    def state(self):
        free = '-' if self.free == NONE else str(self.free)
        norms = ','.join(format(w, 'x') for w in self.norms) if self.norms else '-'
        return f'{len(self.norms)}:{self.cap}:{self.live}:{free}|{ids_text(self.chain())}|{norms}'

    def check(self):
        chain = self.chain()
        assert len(set(chain)) == len(chain) and self.live + len(chain) == len(self.norms)
        for s, w in enumerate(self.norms):
            assert bool(w & FREE_MARK) == (s in chain)


def joined(items):
    items = list(items)
    return ','.join(items) if items else '-'


def sign(j, i):
    return -1 if bin(j & i).count('1') & 1 else 1


def projection_row(n, out):
    if not (1 <= n <= DIM_MAX and 1 <= out <= n):
        return 'P|0', None
    rows = [''.join('+' if sign(j, i) == 1 else '-' for i in range(n)) for j in range(out)]
    walsh = {}
    gram = []
    for j in range(out):
        for k in range(j, out):
            c = j ^ k
            if c not in walsh:
                walsh[c] = sum(sign(c, i) for i in range(n))
            gram.append(walsh[c])
    off = [walsh[j ^ k] for j in range(out) for k in range(j + 1, out)]
    two = n & -n
    orthogonal = all(v == 0 for v in off)
    assert orthogonal == (out <= two), (n, out)
    assert walsh[0] == n
    return f'P|1|{",".join(rows)}|{",".join(map(str, gram))}', (orthogonal, max((abs(v) for v in off), default=0))


def round_half_away(t):
    if t < 0:
        return -math.floor(-t + Fraction(1, 2))
    return math.floor(t + Fraction(1, 2))


def q8_round(t):
    if t in ('inf', '-inf', 'nan'):
        return 0
    return round_half_away(min(max(t, Fraction(-127)), Fraction(127)))


def quantise_codes(xs):
    r = max((abs(x) for x in xs), default=Fraction(0))
    if r == 0 or Fraction(127) / r >= F32_OVERFLOW:
        qs, decoded = [0] * len(xs), [Fraction(0)] * len(xs)
        bound = r
    else:
        qs = [q8_round(x * 127 / r) for x in xs]
        decoded = [q * r / 127 for q in qs]
        bound = r / 254
    for x, d in zip(xs, decoded):
        assert abs(d - x) <= bound
    for q in qs:
        assert -127 <= q <= 127
    return r, qs, decoded


def quantise_row(xs):
    r, qs, decoded = quantise_codes(xs)
    return f'Q|{text(r)}|{joined(map(str, qs))}|{joined(map(text, decoded))}'


def quantise_encoded_row(xs):
    assert all(abs(x) <= Fraction(1, 2 ** 75) for x in xs)
    r, qs, decoded = quantise_codes(xs)
    return f'QE|1/1|{text(r)}|{joined(map(str, qs))}|{joined(map(text, decoded))}'


def pack(xs, dim):
    words = [0] * ((dim + 63) // 64)
    for i, x in enumerate(xs):
        if x > 0:
            words[i // 64] |= 1 << (i % 64)
    return words


def padding_clear(ws, dim):
    tail = dim & 63
    if tail == 0 or not ws:
        return 1
    return int(ws[-1] >> tail == 0)


def hamming(a, b):
    return sum(bin(x ^ y).count('1') for x, y in zip(a, b))


def closer(a, b):
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1])


def heap_lt(maximum):
    return (lambda a, b: closer(b, a)) if maximum else closer


def heap_push(h, c, maximum):
    lt = heap_lt(maximum)
    h.append(c)
    i = len(h) - 1
    while i > 0:
        p = (i - 1) // 2
        if not lt(c, h[p]):
            break
        h[i] = h[p]
        i = p
    h[i] = c


def sift_down(h, c, lt):
    n = len(h)
    i = 0
    while True:
        child = 2 * i + 1
        if child >= n:
            break
        if child + 1 < n and lt(h[child + 1], h[child]):
            child += 1
        if not lt(h[child], c):
            break
        h[i] = h[child]
        i = child
    h[i] = c


def heap_ok(h, maximum):
    lt = heap_lt(maximum)
    return all(not lt(h[j], h[(j - 1) // 2]) for j in range(1, len(h)))


def heap_text(h):
    return joined(f'{d}:{i}' for d, i in h)


def dyadic_token(f):
    num, den = f.numerator, f.denominator
    assert den & (den - 1) == 0 and abs(num) <= 1 << 24
    return f'{num}:{den.bit_length() - 1}'


def round_token(t):
    return t if isinstance(t, str) else dyadic_token(t)


def corpus():
    rng = random.Random(SEED)
    lines, expected = [], []
    stats = {'projection_shapes': 0, 'projection_rejected_shapes': 0, 'projection_entries': 0,
             'projection_gram_entries': 0, 'non_power_of_two_shapes': 0, 'non_orthogonal_shapes': 0,
             'quantised_vectors': 0, 'quantised_components': 0, 'half_way_components': 0, 'rounding_cases': 0,
             'binary_vectors': 0, 'binary_components': 0, 'hamming_pairs': 0, 'raw_word_pairs': 0,
             'dirty_padding_pairs': 0, 'heap_operations': 0, 'heap_sessions': 0, 'heap_pops': 0,
             'heap_replacements': 0, 'visited_operations': 0, 'visited_sessions': 0, 'epoch_wraps': 0,
             'visited_marks': 0, 'visited_growths': 0, 'visited_natural_wraps': 0, 'overflow_vectors': 0,
             'encoded_vectors': 0, 'special_rounds': 0, 'sort_rows': 0, 'long_sorts': 0, 'width_rows': 0,
             'index_operations': 0, 'index_sessions': 0, 'index_inserts': 0, 'twin_attaches': 0, 'twin_detaches': 0,
             'promotions': 0, 'plain_removals': 0, 'index_searches': 0, 'reencodes': 0, 'slot_releases': 0,
             'live_norm_rows': 0, 'arena_operations': 0, 'arena_sessions': 0, 'double_frees': 0, 'invalid_frees': 0,
             'arena_reuses': 0, 'rejected_norms': 0}

    def emit(line, row):
        lines.append(line)
        if row is not None:
            expected.append(row)

    shapes = [(1, 1), (2, 1), (2, 2), (3, 1), (3, 2), (3, 3), (4, 4), (5, 5), (6, 2), (6, 3), (6, 6), (7, 7),
              (8, 8), (12, 4), (12, 5), (12, 12), (16, 16), (24, 8), (24, 9), (31, 31), (32, 32), (48, 16),
              (48, 17), (64, 16), (64, 64), (100, 4), (100, 5), (128, 128), (300, 4), (300, 5), (384, 128),
              (384, 129), (768, 256), (768, 257), (1024, 64), (DIM_MAX, 1),
              (0, 0), (0, 1), (3, 0), (3, 4), (1, 2), (DIM_MAX + 1, 1)]
    for n, out in shapes:
        row, info = projection_row(n, out)
        emit(f'P {n} {out}', row)
        if info is None:
            stats['projection_rejected_shapes'] += 1
            continue
        stats['projection_shapes'] += 1
        stats['projection_entries'] += n * out
        stats['projection_gram_entries'] += out * (out + 1) // 2
        if n & (n - 1):
            stats['non_power_of_two_shapes'] += 1
        if not info[0]:
            stats['non_orthogonal_shapes'] += 1

    def quantise_case(xs):
        stats['quantised_vectors'] += 1
        stats['quantised_components'] += len(xs)
        emit('Q ' + ' '.join(map(dyadic_token, xs)), quantise_row(xs))

    for k in range(-6, 4):
        r = Fraction(127) * Fraction(2) ** k
        for length in (1, 2, 3, 5, 8, 16, 33):
            for _ in range(6):
                xs = []
                for _ in range(length):
                    choice = rng.randrange(4)
                    if choice == 0:
                        h = rng.randrange(-127, 127)
                        xs.append((Fraction(h) + Fraction(1, 2)) * Fraction(2) ** k)
                        stats['half_way_components'] += 1
                    elif choice == 1:
                        xs.append(Fraction(rng.randrange(-127, 128)) * Fraction(2) ** k)
                    else:
                        xs.append(Fraction(rng.randrange(-(1 << 12), (1 << 12) + 1), 1 << 12) * r)
                xs[rng.randrange(length)] = r if rng.randrange(2) else -r
                quantise_case(xs)
    for xs in ([Fraction(0)], [Fraction(0)] * 7, [Fraction(127)], [Fraction(-127)],
               [Fraction(127), Fraction(1, 2), Fraction(-1, 2), Fraction(3, 2), Fraction(-3, 2)],
               [Fraction(127, 64), Fraction(1, 128), Fraction(-1, 128), Fraction(3, 128)]):
        quantise_case(xs)

    def tiny_vector(k, length, subnormal):
        unit = Fraction(1, 2 ** 149) if subnormal else Fraction(2) ** k
        xs = []
        for _ in range(length):
            if subnormal:
                xs.append(Fraction(rng.randrange(-(1 << 20), (1 << 20) + 1)) * unit)
            elif rng.randrange(3) == 0:
                xs.append((Fraction(rng.randrange(-127, 127)) + Fraction(1, 2)) * unit)
            else:
                xs.append(Fraction(rng.randrange(-127, 128)) * unit)
        if not subnormal:
            xs[rng.randrange(length)] = 127 * unit if rng.randrange(2) else -127 * unit
        return xs

    for k in (-127, -128, -140):
        for length in (1, 2, 5, 9):
            for _ in range(3):
                xs = tiny_vector(k, length, False)
                if Fraction(127) / max(abs(x) for x in xs) >= F32_OVERFLOW:
                    stats['overflow_vectors'] += 1
                quantise_case(xs)
    for length in (1, 3, 8):
        for _ in range(4):
            xs = tiny_vector(0, length, True)
            if any(xs) and Fraction(127) / max(abs(x) for x in xs) >= F32_OVERFLOW:
                stats['overflow_vectors'] += 1
            quantise_case(xs)
    for k in (-82, -100, -127, -128, -140):
        for length in (1, 4, 7):
            for _ in range(3):
                xs = tiny_vector(k, length, False)
                stats['encoded_vectors'] += 1
                emit('QE ' + ' '.join(map(dyadic_token, xs)), quantise_encoded_row(xs))
    for length in (2, 6):
        for _ in range(3):
            xs = tiny_vector(0, length, True)
            stats['encoded_vectors'] += 1
            emit('QE ' + ' '.join(map(dyadic_token, xs)), quantise_encoded_row(xs))

    rounds = set()
    for h in range(-131, 131):
        rounds.update({Fraction(h), Fraction(h) + Fraction(1, 2), Fraction(h) + Fraction(1, 2) - Fraction(1, 1 << 16),
                       Fraction(h) + Fraction(1, 2) + Fraction(1, 1 << 16)})
    rounds.update({Fraction((1 << 24) - 1, 1 << 25), -Fraction((1 << 24) - 1, 1 << 25), Fraction(1, 1 << 30),
                   Fraction(-1, 1 << 30), Fraction(1000), Fraction(-1000), Fraction(1 << 20), Fraction(-(1 << 20)),
                   Fraction(255, 2), Fraction(-255, 2), Fraction(253, 2), Fraction(-253, 2)})
    for t in sorted(rounds):
        stats['rounding_cases'] += 1
        emit(f'R {dyadic_token(t)}', f'R|{q8_round(t)}')
    for t in ('inf', '-inf', 'nan'):
        stats['rounding_cases'] += 1
        stats['special_rounds'] += 1
        emit(f'R {t}', 'R|0')

    def component():
        choice = rng.randrange(6)
        if choice == 0:
            return Fraction(0)
        if choice == 1:
            return Fraction(1, 1 << 100)
        if choice == 2:
            return -Fraction(1, 1 << 100)
        return Fraction(rng.randrange(-(1 << 10), (1 << 10) + 1), 1 << rng.randrange(0, 12))

    for dim in (1, 2, 3, 7, 63, 64, 65, 100, 127, 128, 129, 191, 192, 193, 256, 300, 511, 512, 513):
        for _ in range(12):
            xs = [component() for _ in range(dim)]
            ws = pack(xs, dim)
            stats['binary_vectors'] += 1
            stats['binary_components'] += dim
            emit(f'B {dim} ' + ' '.join(map(dyadic_token, xs)), f'B|{joined(map(str, ws))}|{padding_clear(ws, dim)}')
        for _ in range(12):
            xs = [component() for _ in range(dim)]
            ys = [component() for _ in range(dim)] if rng.randrange(4) else list(xs)
            h = hamming(pack(xs, dim), pack(ys, dim))
            assert 0 <= h <= dim
            score = text(1 - Fraction(h, dim)) if dim & (dim - 1) == 0 else '-'
            stats['hamming_pairs'] += 1
            emit(f'H {dim} ' + ' '.join(map(dyadic_token, xs + ys)), f'H|{h}|{score}')
    full = (1 << 64) - 1
    raw = [(1, [full], [0]), (1, [1], [0]), (63, [full], [0]), (64, [full], [0]), (65, [full, 1], [0, 0]),
           (65, [full, full], [0, 0]), (65, [7, 3], [7, 1]), (100, [5, (1 << 36) - 1], [5, 1 << 40]),
           (128, [full, full], [0, 0]), (130, [0, 0, 3], [0, 0, 4]), (0, [], []), (1, [2], [2])]
    for dim, a, b in raw:
        stats['raw_word_pairs'] += 1
        h = hamming(a, b)
        if h > dim:
            stats['dirty_padding_pairs'] += 1
        emit(' '.join(['W', str(dim), str(len(a))] + [str(w) for w in a + b]),
             f'W|{h}|{padding_clear(a, dim)}|{padding_clear(b, dim)}')

    for session in range(70):
        maximum = session % 2 == 1
        stats['heap_sessions'] += 1
        emit('HN ' + ('max' if maximum else 'min'), None)
        h = []
        spread = (1, 2, 4, 16, 1000)[session % 5]
        for _ in range(rng.randrange(20, 160)):
            choice = rng.randrange(20)
            if not h or choice < 11:
                c = (rng.randrange(-spread, spread + 1), rng.randrange(0, 64 if session % 3 else 4096))
                heap_push(h, c, maximum)
                assert heap_ok(h, maximum)
                emit(f'HP {c[0]} {c[1]}', f'HP|{heap_text(h)}')
            elif choice < 16:
                want = max(h, key=lambda x: x) if maximum else min(h, key=lambda x: x)
                top = h[0]
                assert top == want
                last = h.pop()
                if h:
                    sift_down(h, last, heap_lt(maximum))
                assert heap_ok(h, maximum)
                stats['heap_pops'] += 1
                emit('HO', f'HO|{top[0]}:{top[1]}|{heap_text(h)}')
            elif choice < 18 or not maximum:
                assert h[0] == (max(h) if maximum else min(h))
                emit('HT', f'HT|{h[0][0]}:{h[0][1]}')
            else:
                c = (rng.randrange(-spread, spread + 1), rng.randrange(0, 4096))
                top = h[0]
                assert top == max(h)
                sift_down(h, c, heap_lt(True))
                assert heap_ok(h, True)
                stats['heap_replacements'] += 1
                emit(f'HR {c[0]} {c[1]}', f'HR|{top[0]}:{top[1]}|{heap_text(h)}')
            stats['heap_operations'] += 1
        while h:
            top = h[0]
            last = h.pop()
            if h:
                sift_down(h, last, heap_lt(maximum))
            stats['heap_pops'] += 1
            stats['heap_operations'] += 1
            emit('HO', f'HO|{top[0]}:{top[1]}|{heap_text(h)}')

    def visited_session(rounds, near_wrap, max_marks):
        stats['visited_sessions'] += 1
        emit('VN', None)
        stamps, epoch = [], 0
        current = set()
        for round_ in range(rounds):
            if near_wrap and round_ == 1:
                epoch = U8_MAX - rng.randrange(0, 4)
                current = {i for i, s in enumerate(stamps) if s == epoch}
                stats['visited_operations'] += 1
                emit(f'VE {epoch}', f'VE|{epoch}')
            n = rng.choice((1, 5, 10, 40, 64, 65, 96, 100, 150, 200))
            if n > len(stamps):
                grown = max(n, len(stamps) + len(stamps) // 2, 64)
                stamps += [0] * (grown - len(stamps))
                stats['visited_growths'] += 1
            if epoch == U8_MAX:
                stamps = [0] * len(stamps)
                epoch = 0
                stats['epoch_wraps'] += 1
                if not near_wrap:
                    stats['visited_natural_wraps'] += 1
            epoch = (epoch + 1) % (1 << 8)
            current = {i for i, s in enumerate(stamps) if s == epoch}
            assert not current and all(s < epoch for s in stamps)
            stats['visited_operations'] += 1
            emit(f'VB {n}', f'VB|{epoch}|{len(stamps)}|{joined(map(str, sorted(current)))}')
            marked = set()
            for _ in range(rng.randrange(0, min(2 * n + 2, max_marks))):
                ident = rng.randrange(n)
                if rng.randrange(4):
                    result = int(stamps[ident] != epoch)
                    assert result == int(ident not in marked)
                    stamps[ident] = epoch
                    current.add(ident)
                    marked.add(ident)
                    stats['visited_marks'] += 1
                    emit(f'VM {ident}', f'VM|{result}|{joined(map(str, sorted(current)))}')
                else:
                    assert (stamps[ident] == epoch) == (ident in marked)
                    emit(f'VC {ident}', f'VC|{int(stamps[ident] == epoch)}')
                stats['visited_operations'] += 1

    for session in range(40):
        visited_session(rng.randrange(6, 14), session % 4 != 0, 80)
    for rounds in (300, 520, 780):
        visited_session(rounds, False, 3)

    for length in list(range(0, 12)) + [20, 47, 48, 49, 50, 64, 80]:
        for _ in range(4):
            cs = [(rng.randrange(-4, 5), rng.randrange(0, 12)) for _ in range(length)]
            stats['sort_rows'] += 1
            if length > 48:
                stats['long_sorts'] += 1
            emit(' '.join(['CS'] + [f'{d}:{i}' for d, i in cs]), f'CS|{heap_text(sorted(cs))}')
    for c in (0, 1, 2, 16, 65534, 65535, 65536, 16777214, 16777215, 16777216, (1 << 32) - 2):
        w = 2 if c <= 65535 else 3 if c <= 16777215 else 4
        stats['width_rows'] += 1
        emit(f'LW {c}', f'LW|{w}|{(1 << (8 * w)) - 1}')

    words = [0, 1, 0x3F800000, 0x40A00000, 0x7F7FFFFF, 0x7F800000, 0x7F800001, 0x7FC00000, 0x7FFFFFFF,
             0x80000000, 0x80000001, 0xBF800000, 0xFF7FFFFF, 0xFF800000, 0xFF800001, 0xFFC00000, 0xFFC00001,
             0xFFFFFFFF, 0x807FFFFF]
    words += [rng.randrange(0, 1 << 32) for _ in range(40)]
    for w in words:
        stored, ok = live_norm(w)
        stats['live_norm_rows'] += 1
        emit(f'LN {w}', f'LN|{format(stored, "x")}|{ok}')

    norm_choices = [0x3F800000, 0x40A00000, 0x7F800000, 0x7FC00000, 0xFFC00001, 0x80000000, 0xBF800000, 0xFF800000,
                    0x00000001, 0x7F800001]
    for session in range(14):
        stats['arena_sessions'] += 1
        cap = (0, 1, 3)[session % 3]
        a = Arena(cap)
        emit(f'AN {cap}', f'AN|{a.state()}')
        for _ in range(rng.randrange(20, 60)):
            choice = rng.randrange(20)
            high = len(a.norms)
            live = [s for s in range(high) if a.is_live(s)]
            if choice < 6 or high == 0:
                reuse = a.free != NONE
                slot = a.alloc()
                if reuse:
                    stats['arena_reuses'] += 1
                emit('AA', f'AA|{"-" if slot is None else slot}|{a.state()}')
            elif choice < 11:
                if rng.randrange(5) == 0:
                    s = high + rng.randrange(0, 3)
                elif live and rng.randrange(3):
                    s = rng.choice(live)
                else:
                    s = rng.randrange(high)
                r = a.release(s)
                if r == 2:
                    stats['double_frees'] += 1
                elif r == 1:
                    stats['invalid_frees'] += 1
                emit(f'AF {s}', f'AF|{r}|{a.state()}')
            elif choice < 14 and live:
                s = rng.choice(live)
                b = rng.choice(norm_choices)
                kind = 'AS' if rng.randrange(2) else 'AZ'
                ok = a.set_norm(s, b)
                if not ok:
                    stats['rejected_norms'] += 1
                emit(f'{kind} {s} {b}', f'{kind}|{ok}|{a.state()}')
            elif choice < 16:
                b = rng.choice(norm_choices)
                slot = a.insert_normalised(b)
                if slot is None:
                    stats['rejected_norms'] += 1
                emit(f'AI {b}', f'AI|{"-" if slot is None else slot}|{a.state()}')
            elif choice < 18 and live:
                s = rng.choice(live)
                tok = rng.choice(['0', '-0', 'tiny', 'huge', 'big', '3', '-5', '7', '4095', '-1'])
                a.set_encoded(s, tok)
                emit(f'AE {s} {tok}', f'AE|{a.state()}')
            else:
                s = rng.randrange(high + 2)
                emit(f'AL {s}', f'AL|{a.is_live(s)}')
            a.check()
            stats['arena_operations'] += 1

    def index_session(m, efc, pool, ops, upper):
        stats['index_sessions'] += 1
        ix = Index(m, efc)
        emit(f'XN {m} {efc}', f'XN|{ix.coin}|{ix.width}')
        widened = 2
        for _ in range(ops):
            choice = rng.randrange(24)
            live = [x for x in range(len(ix.level)) if ix.is_live(x)]
            reserved = [x for x in range(len(ix.level)) if ix.level[x] == LEVEL_RESERVED]
            if choice < 12 or not live:
                point = rng.choice(pool)
                lv = rng.randrange(1, 4) if rng.randrange(100) < upper else 0
                slot = ix.reserve()
                ix.pts[slot] = point
                twins_before = ix.twins
                ix.insert(slot, lv)
                if ix.twins > twins_before:
                    stats['twin_attaches'] += 1
                stats['index_inserts'] += 1
                emit(f'XI {point[0]} {point[1]} {lv}', f'XI|{slot}|0|{ix.state()}')
            elif choice < 18:
                slot = rng.choice(live)
                kind = ('twin' if ix.level[slot] == LEVEL_TWIN else 'promote' if ix.nxt[slot] != NONE else 'plain')
                err = ix.remove(slot)
                stats[{'twin': 'twin_detaches', 'promote': 'promotions', 'plain': 'plain_removals'}[kind]] += 1
                emit(f'XD {slot}', f'XD|{err}|{ix.state()}')
            elif choice < 20:
                q = rng.choice(pool) if rng.randrange(2) else (rng.randrange(-7, 8), rng.randrange(-7, 8))
                k = rng.randrange(1, 9)
                ef = rng.randrange(1, 20)
                stats['index_searches'] += 1
                emit(f'XS {q[0]} {q[1]} {k} {ef}', f'XS|{heap_text(ix.search(q[0], q[1], k, ef))}')
            elif choice < 22:
                if reserved and rng.randrange(2):
                    slot = rng.choice(reserved)
                    err = ix.release(slot)
                    stats['slot_releases'] += 1
                    emit(f'XF {slot}', f'XF|{err}|{ix.state()}')
                else:
                    slot = ix.reserve()
                    emit('XR', f'XR|{slot}|{ix.state()}')
            elif widened < 4:
                widened += 1
                ix.width = widened
                stats['reencodes'] += 1
                emit(f'XW {widened}', f'XW|0|{ix.state()}')
            else:
                dead = [x for x in range(len(ix.level)) if not ix.is_live(x)]
                if not dead:
                    continue
                slot = rng.choice(dead)
                emit(f'XD {slot}', f'XD|{ix.remove(slot)}|{ix.state()}')
            ix.check()
            stats['index_operations'] += 1
        for key, count in ix.events.items():
            stats[key] = stats.get(key, 0) + count

    for session in range(24):
        pool = [(rng.randrange(-6, 7), rng.randrange(-6, 7)) for _ in range(rng.randrange(3, 14))]
        index_session((2, 3, 4, 6)[session % 4], (4, 8, 16, 32)[(session // 4) % 4], pool, rng.randrange(30, 70), 25)
    for session in range(40):
        shape = session % 4
        if shape == 0:
            pool = [(i * rng.randrange(1, 4), 0) for i in range(rng.randrange(5, 40))]
        elif shape == 1:
            pool = [(rng.randrange(-40, 41), rng.randrange(-40, 41)) for _ in range(40)]
        elif shape == 2:
            pool = [(c * 20 + rng.randrange(-2, 3), rng.randrange(-2, 3)) for c in range(4) for _ in range(6)]
        else:
            pool = [(2 ** i, 0) for i in range(12)] + [(-(2 ** i), 0) for i in range(12)]
        index_session((2, 3)[session % 2], (1, 1, 1, 2)[(session // 2) % 4], pool, rng.randrange(60, 90), 50)

    labelled_corpus(rng, emit, stats)
    assert stats['refusals'] > 0 and stats['forced_copies'] > 0 and stats['hidden_bursts'] > 0
    assert stats['conversions'] > 0 and stats['graph_searches'] > 0 and stats['tied_results'] > 0
    stats['rows'] = len(expected)
    assert stats['non_orthogonal_shapes'] > 0 and stats['epoch_wraps'] > 0 and stats['dirty_padding_pairs'] > 0
    assert stats['half_way_components'] > 0 and stats['heap_replacements'] > 0 and stats['visited_natural_wraps'] > 0
    assert stats['overflow_vectors'] > 0 and stats['twin_attaches'] > 0 and stats['twin_detaches'] > 0
    assert stats['promotions'] > 0 and stats['double_frees'] > 0 and stats['invalid_frees'] > 0 and stats['long_sorts'] > 0
    assert stats['adoptions'] > 0 and stats['island_adoptions'] > 0 and stats['relinks'] > 0
    return '\n'.join(lines) + '\n', expected, stats


def compare(label, got, want):
    rows = got.splitlines()
    if not want or len(rows) != len(want):
        raise AssertionError(f'{label}: {len(rows)} rows, expected {len(want)}')
    for i, (a, b) in enumerate(zip(rows, want)):
        if a != b:
            raise AssertionError(f'{label}: row {i}: {a[:200]!r} != {b[:200]!r}')


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
        axioms, kernel = audit_kernel(Path(lake), PACKAGE, output, env, 'Vectors')
    versions = {'lean': version.strip(), 'odin': odin_version.strip()}
    tools = {name: digest(Path(path)) for name, path in (('lean', lean), ('lake', lake), ('odin', odin))}
    return PACKAGE / '.lake/build/bin/vector_model', output / 'odin_bridge', axioms, kernel, versions, tools


def tied_pair(row):
    body = row.split('|')[-1]
    items = body.split(',')
    for i in range(len(items) - 1):
        a, b = items[i].rsplit(':', 1), items[i + 1].rsplit(':', 1)
        if len(a) == 2 and len(b) == 2 and a[1] == b[1] and a[0] != b[0]:
            return i
    return None


def swap_tied(row):
    head, _, body = row.rpartition('|')
    items = body.split(',')
    i = tied_pair(row)
    items[i], items[i + 1] = items[i + 1], items[i]
    return (head + '|' if head else '') + ','.join(items)


def negative_controls(expected):
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
    wraps, previous = set(), None
    for i, row in enumerate(expected):
        if row.startswith('VB|'):
            if previous == '255' and row.split('|')[1] == '1':
                wraps.add(i)
            previous = row.split('|')[1]
    semantic = {
        'visited_wrap_epoch': ('VB|', lambda r: False, lambda r: r.replace('VB|1|', 'VB|256|', 1)),
        'twin_chain_next': ('XI|', lambda r: ':253:' in r or ';253:' in r,
                            lambda r: r.replace(';253:-:', ';253:0:', 1) if ';253:-:' in r else r + ';'),
        'promoted_heir_level': ('XD|0|', lambda r: '|255:' in r or ';255:' in r, lambda r: r.replace(';255:', ';254:', 1)),
        'double_free_result': ('AF|2|', lambda r: True, lambda r: r.replace('AF|2|', 'AF|0|', 1)),
        'free_chain_order': ('AF|0|', lambda r: r.split('|')[3].count(',') > 0,
                             lambda r: '|'.join(r.split('|')[:3] + [','.join(reversed(r.split('|')[3].split(',')))] + r.split('|')[4:])),
        'overflow_codes': ('Q|', lambda r: r.split('|')[1] != '0/1' and set(r.split('|')[2].split(',')) == {'0'},
                           lambda r: '|'.join(r.split('|')[:2] + ['127' + r.split('|')[2][1:]] + r.split('|')[3:])),
        'special_round': ('R|0', lambda r: True, lambda r: 'R|127'),
        'merge_name_order': ('ZQ|ok|', lambda r: tied_pair(r) is not None, swap_tied),
        'merge_truncation': ('ZQ|ok|', lambda r: r.count(',') > 0, lambda r: r.rsplit(',', 1)[0]),
        'refusal_label': ('ZA|0|0|0|0|inuse|', lambda r: True, lambda r: r[:-1] + str((int(r[-1]) + 1) % 10)),
        'view_size': ('ZC|', lambda r: True, lambda r: 'ZC|' + str(int(r.split('|')[1]) + 1) + r[len('ZC|' + r.split('|')[1]):]),
        'pinned_mode': ('ZC|', lambda r: ':pinned:' in r, lambda r: r.replace(':pinned:', ':flat:', 1)),
        'graph_mode': ('ZC|', lambda r: ':graph:' in r, lambda r: r.replace(':graph:', ':flat:', 1)),
        'resolved_label': ('ZF|', lambda r: r != 'ZF|-', lambda r: 'ZF|-'),
        'sample_order': ('ZM|', lambda r: r.count(',') > 0, lambda r: 'ZM|' + ','.join(reversed(r[3:].split(',')))),
        'plain_seq_order': ('ZO|sim|', lambda r: tied_pair(r[7:]) is not None, lambda r: 'ZO|sim|' + swap_tied(r[7:])),
    }
    for name, (prefix, accept, mutate) in semantic.items():
        index = next((i for i, row in enumerate(expected) if row.startswith(prefix) and (accept(row) or
                      (name == 'visited_wrap_epoch' and i in wraps)) and mutate(row) != row), None)
        if index is None:
            raise AssertionError('no row for semantic negative control ' + name)
        mutated = list(expected)
        mutated[index] = mutate(expected[index])
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
    trace, expected, stats = corpus()
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
    rejected = negative_controls(expected)
    modules = {module: set(re.findall(r'^theorem\s+(\w+)', (PACKAGE / f'Vectors/{module}.lean').read_text(), re.M))
               for files in AREAS.values() for module in files}
    comparisons = {'projection': stats['projection_shapes'] + stats['projection_rejected_shapes'],
                   'quantisation': stats['quantised_vectors'] + stats['encoded_vectors'] + stats['rounding_cases'] +
                   stats['binary_vectors'] + stats['hamming_pairs'] + stats['raw_word_pairs'],
                   'heaps': stats['heap_operations'], 'visited': stats['visited_operations'],
                   'graph': stats['sort_rows'] + stats['width_rows'] + stats['index_sessions'] + stats['index_operations'],
                   'arena': stats['live_norm_rows'] + stats['arena_sessions'] + stats['arena_operations'], 'filter': 0,
                   'merge': stats['merge_rows'], 'resolution': stats['resolution_rows'],
                   'independence': stats['independence_rows'], 'compatibility': stats['compatibility_rows']}
    if any(comparisons[area] for area in PROOF_ONLY) or any(not comparisons[area] for area in AREAS if area not in PROOF_ONLY):
        raise AssertionError('comparison evidence does not match the proof-only areas')
    area_evidence = {area: {'theorems': sorted(name for name in axioms
                                               if name.removeprefix('Vectors.') in set().union(*(modules[m] for m in files))),
                            'comparisons': comparisons[area]}
                     for area, files in AREAS.items()}
    receipt = {**stats, 'seed': hex(SEED), 'toolchain': (PACKAGE / 'lean-toolchain').read_text().strip(),
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
    summary = {**stats, 'theorems': len(axioms), 'kernel_checked_theorems': receipt['kernel_checked_theorems'],
               'negative_controls_rejected': len(rejected), 'receipt': str(output / 'receipt.json')}
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    run()
