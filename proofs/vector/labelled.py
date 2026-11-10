from functools import cmp_to_key

M64 = (1 << 64) - 1
GOLDEN = 0x9E3779B97F4A7C15
STREAM_BASE = 0xBB67AE8584CAA73B
LINK_LIMIT = 32
BIG_BUDGET = 100000


def mix64(z):
    z &= M64
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
    return z ^ (z >> 31)


def stream_seed(i):
    return mix64((STREAM_BASE + i * GOLDEN) & M64) | 1


def stream_below(st, n):
    if n <= 1:
        return 0, st
    floor = ((1 << 64) - n) % n
    while True:
        st = (st + GOLDEN) & M64
        v = mix64(st)
        if v >= floor:
            return v % n, st


def score(a, b):
    return 64 - bin((a ^ b) & M64).count('1')


def name_token(n):
    return n.decode() if n else '~'


def attr_token(a):
    if a is None:
        return '-'
    if a == 'e':
        return 'e'
    return f'a{a}'


def hit_key(h):
    return (-h[0], h[1])


class Scheme:
    def __init__(self, labels):
        self.labels = labels
        self.decisive = 0

    def sees(self, r, d):
        lr, ld = self.labels[r], self.labels[d]
        return ld[0] <= lr[0] and ld[1] & lr[1] == ld[1] and lr[2] <= ld[2]

    def rank(self, x):
        level, comps, trust = self.labels[x]
        return (level, bin(comps).count('1'), trust)

    def order_cmp(self, x, y):
        rx, ry = self.rank(x), self.rank(y)
        if rx != ry:
            return -1 if rx > ry else 1
        cx, cy = self.labels[x][1], self.labels[y][1]
        if cx != cy:
            return -1 if cx > cy else 1
        return -1 if x < y else (1 if x > y else 0)

    def resolve(self, own, ls):
        if own in ls and any(l != own and self.sees(own, l) and self.rank(l) > self.rank(own) for l in ls):
            self.decisive += 1
        best = None
        for l in ls:
            if l == own:
                return l
            if not self.sees(own, l):
                continue
            if best is None or self.rank(l) > self.rank(best):
                best = l
        return best


class LSet:
    def __init__(self, scheme, flat, shrink, plain):
        self.scheme, self.flat, self.shrink = scheme, flat, shrink
        self.parts, self.index = {}, {}
        self.streams = {i: stream_seed(i) for i in range(len(scheme.labels))}
        self.plain = plain
        if plain:
            self.parts[0] = {'mode': 'pinned', 'uid': 0, 'order': []}

    def elem(self, l, n):
        return next(e for e in self.parts[l]['order'] if e['name'] == n)

    def total(self):
        return sum(len(p['order']) for p in self.parts.values())

    def insert(self, l, n, mask, spec):
        if l not in self.parts:
            self.streams[l] = (self.streams[l] + GOLDEN) & M64
            self.parts[l] = {'mode': 'flat', 'uid': 0, 'order': []}
        p = self.parts[l]
        p['uid'] += 1
        attr = None if spec is None else spec
        p['order'].append({'name': n, 'mask': mask, 'attr': attr, 'seq': p['uid']})
        if p['mode'] == 'flat' and len(p['order']) > self.flat:
            p['mode'] = 'graph'
        self.index.setdefault(n, []).append(l)

    def update(self, l, n, mask, spec):
        p = self.parts[l]
        p['uid'] += 1
        e = self.elem(l, n)
        e['mask'], e['seq'] = mask, p['uid']
        if spec == 'e':
            e['attr'] = None
        elif spec is not None:
            e['attr'] = spec

    def drop(self, l, n):
        p = self.parts[l]
        order = p['order']
        i = next(i for i, e in enumerate(order) if e['name'] == n)
        order[i] = order[-1]
        order.pop()
        self.index[n].remove(l)
        if not self.index[n]:
            del self.index[n]
        if not order:
            del self.parts[l]
            return True
        if p['mode'] == 'graph' and len(order) <= self.shrink:
            p['mode'] = 'flat'
        return False

    def other(self, w, ls):
        if any(l != w and self.scheme.sees(w, l) for l in ls):
            return self.scheme.resolve(w, ls)
        return None

    def add_at(self, w, n, mask, spec):
        ls = list(self.index.get(n, []))
        if w in ls:
            self.update(w, n, mask, spec)
            return 'ZA|0|0|0|0|none|-'
        o = self.other(w, ls)
        if o is not None:
            return f'ZA|0|0|0|0|inuse|{o}'
        created = w not in self.parts
        self.insert(w, n, mask, spec)
        return f'ZA|1|{int(created)}|0|0|none|-'

    def remove_at(self, w, n):
        ls = list(self.index.get(n, []))
        if w in ls:
            gone = self.drop(w, n)
            return f'ZR|1|{int(gone)}|{int(self.total() == 0)}|none|-'
        o = self.other(w, ls)
        if o is not None:
            return f'ZR|0|0|0|inuse|{o}'
        return 'ZR|0|0|0|none|-'

    def set_attribute_at(self, w, n, spec):
        ls = list(self.index.get(n, []))
        if w in ls:
            self.elem(w, n)['attr'] = None if spec == 'e' else spec
            return 'ZE|1|none|-'
        o = self.other(w, ls)
        if o is not None:
            return f'ZE|0|inuse|{o}'
        return 'ZE|0|none|-'

    def relabel(self, src, t, n):
        ls = list(self.index.get(n, []))
        if src not in ls:
            o = self.other(src, ls)
            return 'ZX|0|0|notfound|-' if o is None else f'ZX|0|0|inuse|{o}'
        if t in ls:
            return f'ZX|0|0|inuse|{t}'
        e = self.elem(src, n)
        to_new = t not in self.parts
        self.insert(t, n, e['mask'], e['attr'])
        from_gone = self.drop(src, n)
        return f'ZX|{int(from_gone)}|{int(to_new)}|none|-'

    def remove_label(self, w):
        if w not in self.parts:
            return f'ZL|0|0|0|{int(self.total() == 0)}'
        removed = len(self.parts[w]['order'])
        for e in list(self.parts[w]['order']):
            self.index[e['name']].remove(w)
            if not self.index[e['name']]:
                del self.index[e['name']]
        del self.parts[w]
        return f'ZL|{removed}|1|1|{int(self.total() == 0)}'

    def view(self, rd):
        sch = self.scheme
        labels = sorted((l for l in self.parts if sch.sees(rd, l)), key=cmp_to_key(sch.order_cmp))
        shadows = set()
        for n, ls in self.index.items():
            if len(ls) < 2:
                continue
            vis = [l for l in ls if l in labels]
            if len(vis) < 2:
                continue
            best = sch.resolve(rd, ls)
            for l in vis:
                if l != best:
                    shadows.add((l, n))
        return labels, shadows

    def find(self, rd, n):
        labels, _ = self.view(rd)
        l = self.scheme.resolve(rd, self.index.get(n, []))
        if l is None or l not in labels:
            return None
        return l

    def visible_order(self, l, shadows):
        return [e for e in self.parts[l]['order'] if (l, e['name']) not in shadows]

    def card(self, rd):
        labels, shadows = self.view(rd)
        size = sum(len(self.parts[l]['order']) for l in labels) - len(shadows)
        attrs = sum(sum(1 for e in self.parts[l]['order'] if e['attr'] is not None) for l in labels)
        attrs -= sum(1 for (l, n) in shadows if self.elem(l, n)['attr'] is not None)
        return labels, shadows, size, attrs

    def row_card(self, rd):
        labels, _, size, attrs = self.card(rd)
        uid = sum(self.parts[l]['uid'] for l in labels)
        parts = ','.join(f"{l}:{self.parts[l]['mode']}:{len(self.parts[l]['order'])}:{self.parts[l]['uid']}" for l in labels)
        return f'ZC|{size}|{attrs}|{uid}|{parts or "-"}'

    def row_find(self, rd, n):
        l = self.find(rd, n)
        if l is None:
            return 'ZF|-'
        e = self.elem(l, n)
        return f"ZF|{l}|{attr_token(e['attr'])}|{e['mask']}"

    def range_names(self, rd, lo, hi, limit):
        if limit == 0 or lo == '+' or hi == '-':
            return []
        out = []
        for n in sorted(self.index):
            if not in_bound(n, lo, True) or not in_bound(n, hi, False):
                continue
            if self.find(rd, n) is None:
                continue
            out.append(n)
            if limit > 0 and len(out) >= limit:
                break
        return out

    def row_range(self, rd, lo, hi, limit):
        names = self.range_names(rd, lo, hi, limit)
        return 'ZG|' + (','.join(name_token(n) for n in names) or '-')

    def own_results(self, labels, shadows, q, count, filt):
        own = []
        for l in labels:
            hits = [(score(q, e['mask']), e['name']) for e in self.visible_order(l, shadows) if accept(e, filt)]
            k = min(count, len(self.parts[l]['order']))
            own.append((l, sorted(hits, key=hit_key)[:k], hits))
        return own

    def search(self, rd, kind, arg, count, filt, eps):
        labels, shadows, size, _ = self.card(rd)
        if size == 0:
            return None if kind == 'e' else []
        if kind == 'e':
            l = self.find(rd, arg)
            if l is None:
                return None
            q = self.elem(l, arg)['mask']
        else:
            q = arg
        own = self.own_results(labels, shadows, q, count, filt)
        merged = sorted((h for _, o, _ in own for h in o), key=hit_key)[:count]
        if eps is not None:
            merged = [h for h in merged if h[0] >= 64 - eps]
        return merged

    def view_refs(self, rd):
        labels, shadows = self.view(rd)
        refs = []
        for l in labels:
            refs.extend(self.visible_order(l, shadows))
        return refs

    def sample(self, rd, kind, count):
        refs = self.view_refs(rd)
        n = len(refs)
        st = self.streams[rd]
        out = []
        if kind == 'm':
            if n:
                j, st = stream_below(st, n)
                out = [refs[j]]
        elif kind == 'r':
            if n:
                for _ in range(count):
                    j, st = stream_below(st, n)
                    out.append(refs[j])
        elif n and count:
            if count >= n:
                out = list(refs)
                st = shuffle(out, st)
            elif count * 4 <= n:
                picks = set()
                for j in range(n - count, n):
                    t, st = stream_below(st, j + 1)
                    if t not in picks:
                        picks.add(t)
                        out.append(refs[t])
                    else:
                        picks.add(j)
                        out.append(refs[j])
                st = shuffle(out, st)
            else:
                pool = list(range(n))
                for i in range(count):
                    r, st = stream_below(st, n - i)
                    j = i + r
                    pool[i], pool[j] = pool[j], pool[i]
                out = [refs[i] for i in pool[:count]]
        self.streams[rd] = st
        return 'ZM|' + (','.join(name_token(e['name']) for e in out) or '-')

    def row_links(self, rd, n):
        l = self.find(rd, n)
        if l is None:
            return 'ZK|-'
        if self.parts[l]['mode'] != 'flat':
            return 'ZK|graph'
        _, shadows = self.view(rd)
        me = self.elem(l, n)
        hits = sorted(((score(me['mask'], e['mask']), e['name']) for e in self.visible_order(l, shadows)
                       if e['name'] != n), key=hit_key)[:LINK_LIMIT]
        return 'ZK|' + hits_text(hits)

    def plain_part(self):
        return self.parts[0]

    def plain_add(self, n, mask, spec):
        p = self.plain_part()
        if any(e['name'] == n for e in p['order']):
            self.update(0, n, mask, spec)
            return 'ZO|add|0'
        p['uid'] += 1
        p['order'].append({'name': n, 'mask': mask, 'attr': spec, 'seq': p['uid']})
        self.index.setdefault(n, []).append(0)
        return 'ZO|add|1'

    def plain_search(self, q, count, filt):
        p = self.plain_part()
        hits = sorted(((score(q, e['mask']), e['seq'], e['name']) for e in p['order'] if accept(e, filt)),
                      key=lambda h: (-h[0], h[1]))[:min(count, len(p['order']))]
        return 'ZO|sim|' + (','.join(f'{name_token(n)}:{s}' for s, _, n in hits) or '-')


def shuffle(out, st):
    for i in range(len(out) - 1, 0, -1):
        j, st = stream_below(st, i + 1)
        out[i], out[j] = out[j], out[i]
    return st


def accept(e, filt):
    return filt is None or (isinstance(e['attr'], int) and e['attr'] >= filt)


def in_bound(n, b, lower):
    if b == '-':
        return lower
    if b == '+':
        return not lower
    v = b'' if b[1:] == '~' else b[1:].encode()
    if b[0] == '[':
        return v <= n if lower else n <= v
    return v < n if lower else n < v


def hits_text(hits):
    return ','.join(f'{name_token(n)}:{s}' for s, n in hits) or '-'


def spec_of(tok):
    return None if tok == '-' else ('e' if tok == 'e' else int(tok[1:]))


STAT_KEYS = ('labelled_sessions', 'plain_sessions', 'labelled_writes', 'labelled_searches', 'graph_searches',
             'tied_results', 'refusals', 'forced_copies', 'samples', 'hidden_bursts', 'conversions',
             'merge_rows', 'resolution_rows', 'independence_rows', 'compatibility_rows', 'trusted_labels',
             'own_rule_decisive', 'relabel_rows', 'relabel_moves', 'relabel_refusals', 'relabel_bytes')


def labelled_corpus(rng, emit, stats):
    for key in STAT_KEYS:
        stats.setdefault(key, 0)
    names = [b''] + [f'n{i}'.encode() for i in range(18)] + [b'n1x', b'm']

    def scheme_labels():
        kind = rng.randrange(3)
        if kind == 0:
            out = [(0, 0, 0), (0, 1, 0), (0, 2, 0), (0, 4, 0), (0, 8, 0), (1, 3, 0), (1, 12, 0), (2, 15, 0)]
            return out[:1] + rng.sample(out[1:5], 4) + rng.sample(out[5:], 3)
        if kind == 1:
            out = [(0, 0, 0), (0, 0, 1), (0, 1, 0), (0, 1, 1), (0, 2, 2), (1, 3, 0), (1, 3, 1), (1, 3, 2), (2, 15, 0)]
            return out[:1] + rng.sample(out[1:5], 3) + rng.sample(out[5:], 3)
        out = [(0, 0, 0)]
        while len(out) < rng.randrange(4, 9):
            lab = (rng.randrange(3), rng.randrange(16), rng.randrange(3) if rng.randrange(2) else 0)
            if lab not in out:
                out.append(lab)
        return out

    def graph_safe(s, rd, q, count, filt):
        labels, shadows, _, _ = s.card(rd)
        for l in labels:
            if s.parts[l]['mode'] == 'flat':
                continue
            scores = sorted((score(q, e['mask']) for e in s.visible_order(l, shadows) if accept(e, filt)), reverse=True)
            k = min(count, len(s.parts[l]['order']))
            if len(scores) > k and k > 0 and scores[k - 1] == scores[k]:
                return False
        return True

    def search_case(s, rd, mode):
        stats['labelled_searches'] += 1
        kind = 'e' if rng.randrange(4) == 0 else 'v'
        arg = rng.choice(names) if kind == 'e' else rng.getrandbits(64)
        filt = rng.randrange(6) if rng.randrange(3) == 0 else None
        eps = rng.randrange(1, 30) if rng.randrange(5) == 0 else None
        truth = rng.randrange(4) == 0
        q = arg
        if kind == 'e':
            l = s.find(rd, arg)
            q = s.elem(l, arg)['mask'] if l is not None else None
        count = rng.randrange(1, 14)
        if not truth and q is not None:
            options = [c for c in range(1, 25) if graph_safe(s, rd, q, c, filt)]
            if options:
                count = rng.choice(options)
            else:
                truth = True
        budget = f'b{BIG_BUDGET}' if filt is not None else '-'
        res = s.search(rd, kind, arg, count, filt, eps)
        line = (f"ZQ {rd} {kind} {name_token(arg) if kind == 'e' else arg} {count} {int(truth)} "
                f"{'-' if filt is None else 'f' + str(filt)} {budget} {'-' if eps is None else 'k' + str(eps)}")
        row = 'ZQ|notfound' if res is None else 'ZQ|ok|' + hits_text(res)
        if res is not None and len(res) > 1 and any(res[i][0] == res[i + 1][0] for i in range(len(res) - 1)):
            stats['tied_results'] += 1
        if any(s.parts[l]['mode'] != 'flat' for l in s.view(rd)[0]):
            stats['graph_searches'] += 1
        emit(line, row)
        stats[mode] += 1

    def digest(s, rd):
        rows = [s.row_card(rd)]
        for n in names[:6]:
            rows.append(s.row_find(rd, n))
        rows.append(s.row_range(rd, '-', '+', -1))
        q = 0x5555AAAA5555AAAA
        res = s.search(rd, 'v', q, 12, None, None)
        rows.append('ZQ|ok|' + hits_text(res) if res is not None else 'ZQ|notfound')
        return rows

    def emit_digest(s, rd, area):
        lines = [f'ZC {rd}'] + [f'ZF {rd} {name_token(n)}' for n in names[:6]] + [f'ZG {rd} - + -1']
        q = 0x5555AAAA5555AAAA
        lines.append(f'ZQ {rd} v {q} 12 1 - - -')
        rows = digest(s, rd)
        for line, row in zip(lines, rows):
            emit(line, row)
            stats[area] += 1
        return rows

    def fresh_mask(s, w):
        used = s.used.setdefault(w, set())
        while True:
            m = rng.getrandbits(64)
            if m not in used:
                used.add(m)
                return m

    def write(s, w, area, targets=None):
        op = rng.randrange(14)
        n = rng.choice(names)
        if op >= 12:
            held = [m for m, ls in s.index.items() if w in ls]
            if held and rng.randrange(4):
                n = rng.choice(sorted(held))
            t = rng.choice(targets if targets is not None else range(len(s.scheme.labels)))
            ls = s.index.get(n, [])
            if w in ls and t not in ls:
                mask = s.elem(w, n)['mask']
                if mask in s.used.setdefault(t, set()):
                    return
                s.used[t].add(mask)
            row = s.relabel(w, t, n)
            if row.startswith('ZX|0|0|inuse|'):
                stats['relabel_refusals'] += 1
            elif row.startswith('ZX|') and '|none|' in row:
                stats['relabel_moves'] += 1
            emit(f'ZX {w} {t} {name_token(n)}', row)
            stats['relabel_rows'] += 1
            stats[area] += 1
            return
        if op < 7:
            mask = fresh_mask(s, w)
            if rng.randrange(6) == 0:
                others = [e['mask'] for l, p in s.parts.items() if l != w for e in p['order']]
                if others:
                    cand = rng.choice(others)
                    if cand not in s.used.setdefault(w, set()):
                        s.used[w].add(cand)
                        mask = cand
            spec = rng.choice(['-', '-', 'e', 'a0', 'a1', 'a2', 'a3', 'a4', 'a5'])
            row = s.add_at(w, n, mask, spec_of(spec))
            if '|inuse|' in row:
                stats['refusals'] += 1
            elif row.startswith('ZA|1|') and len(s.index.get(n, [])) > 1:
                stats['forced_copies'] += 1
            emit(f'ZA {w} {name_token(n)} {mask} {spec}', row)
        elif op < 10:
            ls = s.index.get(n, [])
            if w in ls and s.total() <= 1:
                return
            row = s.remove_at(w, n)
            if '|inuse|' in row:
                stats['refusals'] += 1
            emit(f'ZR {w} {name_token(n)}', row)
        elif op < 11:
            spec = rng.choice(['e', 'a1', 'a3', 'a5'])
            emit(f'ZE {w} {name_token(n)} {spec}', s.set_attribute_at(w, n, spec_of(spec)))
        else:
            if w not in s.parts or s.total() - len(s.parts[w]['order']) <= 0:
                return
            emit(f'ZL {w}', s.remove_label(w))
        stats['labelled_writes'] += 1
        stats[area] += 1

    def read(s, rd):
        op = rng.randrange(10)
        if op < 3:
            search_case(s, rd, 'merge_rows')
            return
        if op < 4:
            emit(f'ZC {rd}', s.row_card(rd))
        elif op < 5:
            n = rng.choice(names)
            emit(f'ZF {rd} {name_token(n)}', s.row_find(rd, n))
        elif op < 6:
            bounds = ['-', '+'] + [b + name_token(n) for b in '[(' for n in names[:8]]
            lo, hi = rng.choice(bounds), rng.choice(bounds)
            limit = rng.choice([-1, -1, 0, 1, 3, 7])
            emit(f'ZG {rd} {lo} {hi} {limit}', s.row_range(rd, lo, hi, limit))
        elif op < 8:
            kind = rng.choice('mdr')
            count = rng.randrange(0, 12)
            emit(f'ZM {rd} {kind} {count}', s.sample(rd, kind, count))
            stats['samples'] += 1
        else:
            n = rng.choice(names)
            emit(f'ZK {rd} {name_token(n)}', s.row_links(rd, n))
        stats['resolution_rows'] += 1

    for session in range(36):
        if session:
            stats['own_rule_decisive'] += sch.decisive
        labels = scheme_labels()
        stats['trusted_labels'] += sum(1 for lab in labels if lab[2])
        sch = Scheme(labels)
        emit('ZT ' + ' '.join(f'{a}:{b}:{c}' for a, b, c in labels), f'ZT|{len(labels)}')
        flat, shrink = rng.choice([(3, 0), (4, 1), (6, 2), (512, 128)])
        plain = session % 4 == 3
        s = LSet(sch, flat, shrink, plain)
        s.used = {}
        emit(f'ZN {flat} {shrink} {"plain" if plain else "lab"} {rng.randrange(len(labels))}', 'ZN|ok')
        stats['labelled_sessions'] += 1
        src, dst = rng.sample(range(len(labels)), 2)
        quant = ('q8', 'f32', 'bin')[session % 3]
        emit(f'ZB {quant} {src} {dst}', f'ZB|{quant}|1|1|1')
        stats['relabel_bytes'] += 1
        stats['relabel_rows'] += 1
        if plain:
            stats['plain_sessions'] += 1
            for _ in range(rng.randrange(3, 16)):
                n = rng.choice(names)
                mask = fresh_mask(s, 0)
                spec = rng.choice(['-', 'e', 'a1', 'a3'])
                emit(f'ZO add {name_token(n)} {mask} {spec}', s.plain_add(n, mask, spec_of(spec)))
                stats['compatibility_rows'] += 1
            q = rng.getrandbits(64)
            i, j = rng.sample(range(64), 2)
            for tie, bit in ((b'tie_a', i), (b'tie_b', j)):
                mask = q ^ (1 << bit)
                s.used.setdefault(0, set()).add(mask)
                emit(f'ZO add {tie.decode()} {mask} a2', s.plain_add(tie, mask, 2))
                stats['compatibility_rows'] += 1
            p = s.plain_part()
            count = rng.randrange(2, 12)
            filt = rng.choice([None, 2])
            attrs = sum(1 for e in p['order'] if e['attr'] is not None)
            plain_rows = [
                ('ZO card', f"ZO|card|{len(p['order'])}"),
                ('ZO info', f"ZO|info|{len(p['order'])}|{attrs}|{p['uid']}"),
                ('ZO range', 'ZO|range|' + (','.join(name_token(n) for n in sorted(e['name'] for e in p['order'])) or '-')),
                (f"ZO sim {q} {count} {'-' if filt is None else 'f' + str(filt)}", s.plain_search(q, count, filt)),
            ]
            for n in names[:5]:
                e = next((e for e in p['order'] if e['name'] == n), None)
                plain_rows.append((f'ZO find {name_token(n)}', 'ZO|find|0' if e is None else
                                   f"ZO|find|1|{attr_token(e['attr'])}|{e['mask']}"))
            for line, row in plain_rows:
                emit(line, row)
                stats['compatibility_rows'] += 1
            labelled = s.search(0, 'v', q, count, filt, None)
            assert [h[0] for h in labelled] == [int(x.split(':')[1]) for x in s.plain_search(q, count, filt).split('|')[2].split(',') if x != '-']
            assert s.card(0)[2] == len(p['order'])
            emit(f'ZQ 0 v {q} {count} 1 {"-" if filt is None else "f" + str(filt)} - -', 'ZQ|ok|' + hits_text(labelled))
            emit('ZC 0', s.row_card(0))
            emit('ZG 0 - + -1', s.row_range(0, '-', '+', -1))
            stats['compatibility_rows'] += 3
            before = emit_digest(s, 0, 'compatibility_rows')
            w = next((i for i in range(1, len(labels)) if not sch.sees(0, i)), None)
            if before is not None and w is not None:
                n = rng.choice(names)
                mask = fresh_mask(s, w)
                emit(f'ZA {w} {name_token(n)} {mask} -', s.add_at(w, n, mask, None))
                stats['conversions'] += 1
                after = emit_digest(s, 0, 'compatibility_rows')
                assert after == before
        steps = rng.randrange(40, 120)
        for _ in range(steps):
            w = rng.randrange(len(labels))
            if rng.randrange(5) < 3 or s.total() == 0:
                write(s, w, 'independence_rows')
            else:
                read(s, rng.randrange(len(labels)))
        for _ in range(3):
            rd = rng.randrange(len(labels))
            hidden = [i for i in range(len(labels)) if not sch.sees(rd, i)]
            if not hidden or s.total() == 0:
                continue
            before = emit_digest(s, rd, 'independence_rows')
            if before is None:
                continue
            for _ in range(rng.randrange(10, 40)):
                write(s, rng.choice(hidden), 'independence_rows', hidden)
            after = emit_digest(s, rd, 'independence_rows')
            if after is not None:
                assert after == before
                stats['hidden_bursts'] += 1
        for rd in range(len(labels)):
            search_case(s, rd, 'merge_rows')
            emit(f'ZC {rd}', s.row_card(rd))
            stats['resolution_rows'] += 1
    stats['own_rule_decisive'] += sch.decisive


EVERY_OWNER = (1 << 32) - 1
OWNER_SLOTS = 8
OWNER_NAMES = [b''] + [f'n{i}'.encode() for i in range(10)] + [b'm', b'n1x']
OWNER_STAT_KEYS = ('owner_sessions', 'owner_plain_sessions', 'owner_writes', 'owner_refusals', 'owner_forced_copies',
                   'owner_searches', 'owner_graph_searches', 'owner_tied_results', 'owner_samples', 'owner_bursts',
                   'owner_forgets', 'owner_scope_removals', 'owner_graduations', 'owner_flattens', 'owner_account_rows',
                   'owner_invalid_rows', 'owner_twin_pairs', 'owner_twin_rows', 'owner_twin_hidden',
                   'owner_sensitivity', 'owner_single_pairs', 'owner_single_rows', 'owner_tie_decisive',
                   'owner_mixed_views', 'owner_merge_rows', 'owner_resolution_rows', 'owner_independence_rows',
                   'owner_compatibility_rows', 'owner_trust_sessions', 'owner_shared_exact_decisive')


def scope_seed(l, o):
    return stream_seed(l + 4096 * o)


def scope_token(x):
    return f'{x[0]}:{x[1]}'


class OSet:
    def __init__(self, scheme, flat, shrink, owners, plain):
        self.scheme, self.flat, self.shrink, self.owners = scheme, flat, shrink, owners
        self.parts, self.index = {}, {}
        self.streams = {(l, o): scope_seed(l, o) for l in range(len(scheme.labels)) for o in range(OWNER_SLOTS)}
        if plain:
            self.parts[(0, 0)] = {'mode': 'pinned', 'uid': 0, 'order': []}

    def sees(self, w, x):
        return self.scheme.sees(w[0], x[0]) and x[1] in (0, w[1])

    def key(self, w, x):
        return (self.scheme.rank(x[0]), x[1] != 0)

    def stream_key(self, x):
        return x

    def write_scope(self, w):
        return w

    def resolve(self, w, ls):
        if w in ls:
            return w
        if w[1] != 0 and (w[0], 0) in ls:
            return (w[0], 0)
        best = None
        for x in ls:
            if self.sees(w, x) and (best is None or self.key(w, x) > self.key(w, best)):
                best = x
        return best

    def scope_cmp(self, x, y):
        rx, ry = self.scheme.rank(x[0]), self.scheme.rank(y[0])
        if rx != ry:
            return -1 if rx > ry else 1
        if x[1] != y[1]:
            return -1 if x[1] != 0 else 1
        return self.scheme.order_cmp(x[0], y[0])

    def elem(self, x, n):
        return next(e for e in self.parts[x]['order'] if e['name'] == n)

    def total(self):
        return sum(len(p['order']) for p in self.parts.values())

    def insert(self, x, n, mask, spec):
        if x not in self.parts:
            k = self.stream_key(x)
            self.streams[k] = (self.streams[k] + GOLDEN) & M64
            self.parts[x] = {'mode': 'flat', 'uid': 0, 'order': []}
        p = self.parts[x]
        p['uid'] += 1
        p['order'].append({'name': n, 'mask': mask, 'attr': spec, 'seq': p['uid']})
        if p['mode'] == 'flat' and len(p['order']) > self.flat:
            p['mode'] = 'graph'
        self.index.setdefault(n, []).append(x)

    def update(self, x, n, mask, spec):
        p = self.parts[x]
        p['uid'] += 1
        e = self.elem(x, n)
        e['mask'], e['seq'] = mask, p['uid']
        if spec == 'e':
            e['attr'] = None
        elif spec is not None:
            e['attr'] = spec

    def drop(self, x, n):
        p = self.parts[x]
        order = p['order']
        i = next(i for i, e in enumerate(order) if e['name'] == n)
        order[i] = order[-1]
        order.pop()
        self.index[n].remove(x)
        if not self.index[n]:
            del self.index[n]
        if not order:
            del self.parts[x]
            return True
        if p['mode'] == 'graph' and len(order) <= self.shrink:
            p['mode'] = 'flat'
        return False

    def drop_part(self, x):
        for e in self.parts[x]['order']:
            self.index[e['name']].remove(x)
            if not self.index[e['name']]:
                del self.index[e['name']]
        del self.parts[x]

    def other(self, w, ls):
        if any(x != w and self.sees(w, x) for x in ls):
            return self.resolve(w, ls)
        return None

    def add_at(self, w, n, mask, spec):
        w = self.write_scope(w)
        ls = list(self.index.get(n, []))
        if w in ls:
            self.update(w, n, mask, spec)
            return '0|0|0|0|none|-'
        o = self.other(w, ls)
        if o is not None:
            return f'0|0|0|0|inuse|{scope_token(o)}'
        created = w not in self.parts
        self.insert(w, n, mask, spec)
        return f'1|{int(created)}|0|0|none|-'

    def remove_at(self, w, n):
        w = self.write_scope(w)
        ls = list(self.index.get(n, []))
        if w in ls:
            gone = self.drop(w, n)
            return f'1|{int(gone)}|{int(self.total() == 0)}|none|-'
        o = self.other(w, ls)
        if o is not None:
            return f'0|0|0|inuse|{scope_token(o)}'
        return '0|0|0|none|-'

    def set_attribute_at(self, w, n, spec):
        w = self.write_scope(w)
        ls = list(self.index.get(n, []))
        if w in ls:
            self.elem(w, n)['attr'] = None if spec == 'e' else spec
            return '1|none|-'
        o = self.other(w, ls)
        if o is not None:
            return f'0|inuse|{scope_token(o)}'
        return '0|none|-'

    def remove_scope(self, w):
        w = self.write_scope(w)
        if w not in self.parts:
            return f'0|0|0|{int(self.total() == 0)}'
        removed = len(self.parts[w]['order'])
        self.drop_part(w)
        return f'{removed}|1|1|{int(self.total() == 0)}'

    def forget(self, o):
        labels = [] if o == 0 else sorted(l for (l, w) in self.parts if w == o)
        removed = sum(len(self.parts[(l, o)]['order']) for l in labels)
        for l in labels:
            self.drop_part((l, o))
        shown = ','.join(str(l) for l in labels) or '-'
        return f'{removed}|{int(removed > 0)}|{int(removed > 0)}|{int(self.total() == 0)}|{shown}'

    def view(self, w):
        scopes = sorted((x for x in self.parts if self.sees(w, x)), key=cmp_to_key(self.scope_cmp))
        shadows = set()
        for n, ls in self.index.items():
            if len(ls) < 2:
                continue
            vis = [x for x in ls if x in scopes]
            if len(vis) < 2:
                continue
            best = self.resolve(w, ls)
            for x in vis:
                if x != best:
                    shadows.add((x, n))
        return scopes, shadows

    def find(self, w, n):
        scopes, _ = self.view(w)
        x = self.resolve(w, self.index.get(n, []))
        if x is None or x not in scopes:
            return None
        return x

    def visible_order(self, x, shadows):
        return [e for e in self.parts[x]['order'] if (x, e['name']) not in shadows]

    def card(self, w):
        scopes, shadows = self.view(w)
        size = sum(len(self.parts[x]['order']) for x in scopes) - len(shadows)
        attrs = sum(sum(1 for e in self.parts[x]['order'] if e['attr'] is not None) for x in scopes)
        attrs -= sum(1 for (x, n) in shadows if self.elem(x, n)['attr'] is not None)
        return scopes, shadows, size, attrs

    def row_card(self, w):
        scopes, _, size, attrs = self.card(w)
        uid = sum(self.parts[x]['uid'] for x in scopes)
        parts = ','.join(f"{x[0]}:{x[1]}:{self.parts[x]['mode']}:{len(self.parts[x]['order'])}:{self.parts[x]['uid']}"
                         for x in scopes)
        return f'YC|{size}|{attrs}|{uid}|{parts or "-"}'

    def row_find(self, w, n):
        x = self.find(w, n)
        if x is None:
            return 'YF|-'
        e = self.elem(x, n)
        return f"YF|{scope_token(x)}|{attr_token(e['attr'])}|{e['mask']}"

    def range_names(self, w, lo, hi, limit):
        if limit == 0 or lo == '+' or hi == '-':
            return []
        out = []
        for n in sorted(self.index):
            if not in_bound(n, lo, True) or not in_bound(n, hi, False):
                continue
            if self.find(w, n) is None:
                continue
            out.append(n)
            if limit > 0 and len(out) >= limit:
                break
        return out

    def search(self, w, kind, arg, count, filt, eps):
        scopes, shadows, size, _ = self.card(w)
        if size == 0:
            return None if kind == 'e' else []
        if kind == 'e':
            x = self.find(w, arg)
            if x is None:
                return None
            q = self.elem(x, arg)['mask']
        else:
            q = arg
        own = []
        for x in scopes:
            hits = [(score(q, e['mask']), e['name']) for e in self.visible_order(x, shadows) if accept(e, filt)]
            k = min(count, len(self.parts[x]['order']))
            own.extend(sorted(hits, key=hit_key)[:k])
        merged = sorted(own, key=hit_key)[:count]
        if eps is not None:
            merged = [h for h in merged if h[0] >= 64 - eps]
        return merged

    def sample(self, w, kind, count):
        scopes, shadows = self.view(w)
        refs = []
        for x in scopes:
            refs.extend(self.visible_order(x, shadows))
        n = len(refs)
        key = self.stream_key(w)
        st = self.streams[key]
        out = []
        if kind == 'm':
            if n:
                j, st = stream_below(st, n)
                out = [refs[j]]
        elif kind == 'r':
            if n:
                for _ in range(count):
                    j, st = stream_below(st, n)
                    out.append(refs[j])
        elif n and count:
            if count >= n:
                out = list(refs)
                st = shuffle(out, st)
            elif count * 4 <= n:
                picks = set()
                for j in range(n - count, n):
                    t, st = stream_below(st, j + 1)
                    if t not in picks:
                        picks.add(t)
                        out.append(refs[t])
                    else:
                        picks.add(j)
                        out.append(refs[j])
                st = shuffle(out, st)
            else:
                pool = list(range(n))
                for i in range(count):
                    r, st = stream_below(st, n - i)
                    j = i + r
                    pool[i], pool[j] = pool[j], pool[i]
                out = [refs[i] for i in pool[:count]]
        self.streams[key] = st
        return 'YM|' + (','.join(name_token(e['name']) for e in out) or '-')

    def row_links(self, w, n):
        x = self.find(w, n)
        if x is None:
            return 'YK|-'
        if self.parts[x]['mode'] != 'flat':
            return 'YK|graph'
        _, shadows = self.view(w)
        me = self.elem(x, n)
        hits = sorted(((score(me['mask'], e['mask']), e['name']) for e in self.visible_order(x, shadows)
                       if e['name'] != n), key=hit_key)[:LINK_LIMIT]
        return 'YK|' + hits_text(hits)

    def row_stats(self, w):
        scopes, _ = self.view(w)
        if w in self.parts:
            top = w
        elif w[1] != 0 and (w[0], 0) in self.parts:
            top = (w[0], 0)
        else:
            top = scopes[0] if scopes else None
        o = w[1]
        labels = [] if o == 0 else sorted(l for (l, v) in self.parts if v == o)
        ocard = sum(len(self.parts[(l, o)]['order']) for l in labels)
        ocount = len({v for (_, v) in self.parts if v != 0})
        return f"YS|{scope_token(top) if top is not None else '-'}|{ocard}|{ocount}|{','.join(map(str, labels)) or '-'}"

    def plain_add(self, n, mask, spec):
        p = self.parts[(0, 0)]
        if any(e['name'] == n for e in p['order']):
            self.update((0, 0), n, mask, spec)
            return 'YP|0'
        p['uid'] += 1
        p['order'].append({'name': n, 'mask': mask, 'attr': spec, 'seq': p['uid']})
        self.index.setdefault(n, []).append((0, 0))
        return 'YP|1'

    def checked(self, kind, w, n, mask=None, spec=None):
        x = self.write_scope(w)
        before = self.parts[x]['mode'] if x in self.parts else None
        if kind == 'a':
            body = self.add_at(w, n, mask, spec)
        else:
            body = self.remove_at(w, n)
        after = self.parts[x]['mode'] if x in self.parts else None
        gm = 'g' if (before, after) == ('flat', 'graph') else ('f' if (before, after) == ('graph', 'flat') else '-')
        fresh, gone = before is None and after is not None, before is not None and after is None
        sh = '-' if w[1] == 0 else '1'
        ix = '-' if w[1] != 0 and (fresh or gone) else '1'
        return f'YU|{kind}|{body}|{gm}|{sh}|1|{ix}|1'

    def step(self, f):
        op = f[0]
        if op == 'YP':
            return self.plain_add(parse_name(f[1]), int(f[2]), spec_of(f[3]))
        if op in ('YA', 'YR', 'YE', 'YL'):
            w = (int(f[1]), int(f[2]))
            if op == 'YA':
                return 'YA|' + self.add_at(w, parse_name(f[3]), int(f[4]), spec_of(f[5]))
            if op == 'YR':
                return 'YR|' + self.remove_at(w, parse_name(f[3]))
            if op == 'YE':
                return 'YE|' + self.set_attribute_at(w, parse_name(f[3]), spec_of(f[4]))
            return 'YL|' + self.remove_scope(w)
        if op == 'YU':
            w = (int(f[2]), int(f[3]))
            if f[1] == 'a':
                return self.checked('a', w, parse_name(f[4]), int(f[5]), spec_of(f[6]))
            return self.checked('r', w, parse_name(f[4]))
        if op == 'YW':
            return 'YW|' + self.forget(int(f[1]))
        if op == 'YZ':
            o, src = int(f[1]), int(f[2])
            for l in range(len(self.scheme.labels)):
                self.streams[(l, o)] = scope_seed(l, src)
            return 'YZ|ok'
        if op == 'YI':
            o = int(f[3])
            ok = f[1] != 'relabelx' and (o == 0 or (o != EVERY_OWNER and f[4] == '1'))
            return f"YI|{f[1]}|{'ok' if ok else 'invalid'}"
        w = (int(f[1]), int(f[2]))
        if op == 'YC':
            return self.row_card(w)
        if op == 'YF':
            return self.row_find(w, parse_name(f[3]))
        if op == 'YG':
            names = self.range_names(w, f[3], f[4], int(f[5]))
            return 'YG|' + (','.join(name_token(n) for n in names) or '-')
        if op == 'YQ':
            kind = f[3]
            arg = parse_name(f[4]) if kind == 'e' else int(f[4])
            count = int(f[5]) or 10
            filt = None if f[7] == '-' else int(f[7][1:])
            eps = None if f[9] == '-' else int(f[9][1:])
            res = self.search(w, kind, arg, count, filt, eps)
            return 'YQ|notfound' if res is None else 'YQ|ok|' + hits_text(res)
        if op == 'YM':
            return self.sample(w, f[3], int(f[4]))
        if op == 'YK':
            return self.row_links(w, parse_name(f[3]))
        if op == 'YS':
            return self.row_stats(w)
        raise AssertionError('unknown owner line ' + ' '.join(f))


def parse_name(tok):
    return b'' if tok == '~' else tok.encode()


def scheme_choice(rng):
    kind = rng.randrange(3)
    if kind == 0:
        out = [(0, 0, 0), (0, 1, 0), (0, 2, 0), (0, 4, 0), (0, 8, 0), (1, 3, 0), (1, 12, 0), (2, 15, 0)]
        return out[:1] + rng.sample(out[1:5], 3) + rng.sample(out[5:], 2)
    if kind == 1:
        out = [(0, 0, 0), (0, 0, 1), (0, 1, 0), (0, 1, 1), (0, 2, 2), (1, 3, 0), (1, 3, 1), (1, 3, 2), (2, 15, 0)]
        return out[:1] + rng.sample(out[1:5], 3) + rng.sample(out[5:], 2)
    out = [(0, 0, 0)]
    while len(out) < rng.randrange(3, 7):
        lab = (rng.randrange(3), rng.randrange(16), rng.randrange(3) if rng.randrange(2) else 0)
        if lab not in out:
            out.append(lab)
    return out


class OwnerRun:
    def __init__(self, cls=OSet):
        self.cls = cls
        self.lines, self.rows = [], []
        self.s, self.scheme = None, None
        self.kinds = []

    def emit(self, line, area=None):
        f = line.split(' ')
        if f[0] == 'ZT':
            self.scheme = Scheme([tuple(int(v) for v in tok.split(':')) for tok in f[1:]])
            row = f'ZT|{len(f) - 1}'
        elif f[0] == 'YN':
            self.s = self.cls(self.scheme, int(f[1]), int(f[2]), int(f[4]), f[3] == 'plain')
            row = 'YN|ok'
        else:
            row = self.s.step(f)
        self.lines.append(line)
        self.rows.append(row)
        self.kinds.append(area)
        return len(self.rows) - 1


def replay(lines, cls=OSet):
    run = OwnerRun(cls)
    for line in lines:
        run.emit(line)
    return run.rows


def owner_digest_lines(w, q):
    r, o = w
    lines = [f'YC {r} {o}'] + [f'YF {r} {o} {name_token(n)}' for n in OWNER_NAMES[:6]] + [f'YG {r} {o} - + -1']
    lines.append(f'YQ {r} {o} v {q} 12 1 - - -')
    return lines


def owner_scope_visible(scheme, w, line):
    f = line.split(' ')
    op = f[0]
    if op in ('ZT', 'YN', 'YZ', 'YP', 'YI'):
        return True
    if op == 'YW':
        return int(f[1]) in (0, w[1])
    if op == 'YU':
        x = (int(f[2]), int(f[3]))
    else:
        x = (int(f[1]), int(f[2]))
    return scheme.sees(w[0], x[0]) and x[1] in (0, w[1])


def normalise_owner(row, u):
    head = row.split('|')
    kind = head[0]
    if kind in ('YA', 'YR', 'YE') and '|inuse|' in row:
        l, o = head[-1].split(':')
        head[-1] = f'{l}:{0 if o == str(u) else o}'
    elif kind == 'YF' and row != 'YF|-':
        l, o = head[1].split(':')
        head[1] = f'{l}:{0 if o == str(u) else o}'
    elif kind == 'YC' and head[4] != '-':
        parts = []
        for p in head[4].split(','):
            l, o, rest = p.split(':', 2)
            parts.append(f'{l}:{0 if o == str(u) else o}:{rest}')
        head[4] = ','.join(parts)
    return '|'.join(head)


OBSERVED = ('YC', 'YF', 'YG', 'YQ', 'YM', 'YK')
ROW_AREAS = {'YQ': 'owner_merge_rows', 'YC': 'owner_resolution_rows', 'YF': 'owner_resolution_rows',
             'YG': 'owner_resolution_rows', 'YM': 'owner_resolution_rows', 'YK': 'owner_resolution_rows',
             'YS': 'owner_resolution_rows', 'YI': 'owner_resolution_rows', 'YA': 'owner_independence_rows',
             'YR': 'owner_independence_rows', 'YE': 'owner_independence_rows', 'YL': 'owner_independence_rows',
             'YW': 'owner_independence_rows', 'YU': 'owner_independence_rows', 'YP': 'owner_compatibility_rows'}


def line_scope(line):
    f = line.split(' ')
    if f[0] == 'YU':
        return int(f[2]), int(f[3])
    return int(f[1]), int(f[2])


def observer_rows(lines, obs):
    return [i for i, line in enumerate(lines) if line.split(' ')[0] in OBSERVED and line_scope(line) == obs]


def owner_corpus(rng, stats):
    for key in OWNER_STAT_KEYS:
        stats.setdefault(key, 0)
    main = OwnerRun()
    state = {'run': main}
    twins, singles, sensitivity = [], [], []

    def cur():
        return state['run'].s

    def emit(line, area=None):
        return state['run'].emit(line, area)

    def fresh_mask(x):
        used = cur().used.setdefault(x, set())
        while True:
            m = rng.getrandbits(64)
            if m not in used:
                used.add(m)
                return m

    def graph_safe(w, q, count, filt):
        s = cur()
        scopes, shadows, _, _ = s.card(w)
        for x in scopes:
            if s.parts[x]['mode'] == 'flat':
                continue
            scores = sorted((score(q, e['mask']) for e in s.visible_order(x, shadows) if accept(e, filt)), reverse=True)
            k = min(count, len(s.parts[x]['order']))
            if len(scores) > k and k > 0 and scores[k - 1] == scores[k]:
                return False
        return True

    def search_line(w):
        s = cur()
        stats['owner_searches'] += 1
        kind = 'e' if rng.randrange(4) == 0 else 'v'
        arg = rng.choice(OWNER_NAMES) if kind == 'e' else rng.getrandbits(64)
        filt = rng.randrange(6) if rng.randrange(3) == 0 else None
        eps = rng.randrange(1, 30) if rng.randrange(5) == 0 else None
        truth = rng.randrange(4) == 0
        q = arg
        if kind == 'e':
            x = s.find(w, arg)
            q = s.elem(x, arg)['mask'] if x is not None else None
        count = rng.randrange(1, 14)
        if not truth and q is not None:
            options = [c for c in range(1, 25) if graph_safe(w, q, c, filt)]
            if options:
                count = rng.choice(options)
            else:
                truth = True
        budget = f'b{BIG_BUDGET}' if filt is not None else '-'
        scopes = s.view(w)[0]
        if any(s.parts[x]['mode'] != 'flat' for x in scopes):
            stats['owner_graph_searches'] += 1
        if any(x[1] == 0 for x in scopes) and any(x[1] != 0 for x in scopes):
            stats['owner_mixed_views'] += 1
        return (f"YQ {w[0]} {w[1]} {kind} {name_token(arg) if kind == 'e' else arg} {count} {int(truth)} "
                f"{'-' if filt is None else 'f' + str(filt)} {budget} {'-' if eps is None else 'k' + str(eps)}")

    def note(row):
        if row.startswith('YQ|ok|'):
            vals = [h.rsplit(':', 1)[1] for h in row[6:].split(',') if h != '-']
            if any(vals[i] == vals[i + 1] for i in range(len(vals) - 1)):
                stats['owner_tied_results'] += 1

    def decisive(w):
        s = cur()
        for n, ls in s.index.items():
            if w in ls:
                continue
            vis = [x for x in ls if s.sees(w, x)]
            own = [s.scheme.rank(x[0]) for x in vis if x[1] != 0]
            shared = [s.scheme.rank(x[0]) for x in vis if x[1] == 0]
            if own and shared and max(own) == max(shared):
                stats['owner_tie_decisive'] += 1
            if w[1] != 0 and (w[0], 0) in ls:
                best = None
                for x in vis:
                    if best is None or s.key(w, x) > s.key(w, best):
                        best = x
                if best != (w[0], 0):
                    stats['owner_shared_exact_decisive'] += 1

    def write_line(w, k, area, keep_owner=None, checked=True):
        s = cur()
        op = rng.randrange(40)
        n = rng.choice(OWNER_NAMES)
        held = sorted(m for m, ls in s.index.items() if w in ls)
        if held and rng.randrange(3) == 0:
            n = rng.choice(held)
        r, o = w
        if op < 20:
            x = s.write_scope(w)
            mask = fresh_mask(x)
            if rng.randrange(6) == 0:
                others = [e['mask'] for y, p in s.parts.items() if y != x for e in p['order']]
                if others:
                    cand = rng.choice(others)
                    if cand not in s.used.setdefault(x, set()):
                        s.used[x].add(cand)
                        mask = cand
            spec = rng.choice(['-', '-', 'e', 'a0', 'a1', 'a2', 'a3', 'a4', 'a5'])
            kind = 'YU a' if checked and rng.randrange(3) == 0 else 'YA'
            line = f'{kind} {r} {o} {name_token(n)} {mask} {spec}'
        elif op < 30:
            if w in s.index.get(n, []) and s.total() <= 1:
                return None
            kind = 'YU r' if checked and rng.randrange(3) == 0 else 'YR'
            line = f'{kind} {r} {o} {name_token(n)}'
        elif op < 35:
            line = f"YE {r} {o} {name_token(n)} {rng.choice(['e', 'a1', 'a3', 'a5'])}"
        elif op < 38:
            if w not in s.parts or s.total() - len(s.parts[w]['order']) <= 0:
                return None
            line = f'YL {r} {o}'
            stats['owner_scope_removals'] += 1
        else:
            choices = [v for v in range(1, k + 1) if v != keep_owner]
            if not choices:
                return None
            v = rng.choice(choices)
            mine = sum(len(p['order']) for (_, u), p in s.parts.items() if u == v)
            if s.total() - mine <= 0:
                return None
            line = f'YW {v}'
            stats['owner_forgets'] += 1
        before = len(s.index.get(n, []))
        row = state['run'].rows[emit(line, area)]
        stats['owner_writes'] += 1
        if '|inuse|' in row:
            stats['owner_refusals'] += 1
        if (row.startswith('YA|1|') or row.startswith('YU|a|1|')) and before > 0:
            stats['owner_forced_copies'] += 1
        return line

    def read_line(w, area=None, with_stats=True):
        r, o = w
        op = rng.randrange(11 if with_stats else 10)
        if op < 3:
            line = search_line(w)
        elif op < 4:
            line = f'YC {r} {o}'
        elif op < 5:
            line = f'YF {r} {o} {name_token(rng.choice(OWNER_NAMES))}'
        elif op < 6:
            bounds = ['-', '+'] + [b + name_token(n) for b in '[(' for n in OWNER_NAMES[:8]]
            line = f'YG {r} {o} {rng.choice(bounds)} {rng.choice(bounds)} {rng.choice([-1, -1, 0, 1, 3, 7])}'
        elif op < 8:
            line = f"YM {r} {o} {rng.choice('mdr')} {rng.randrange(0, 12)}"
            stats['owner_samples'] += 1
        elif op < 10:
            line = f'YK {r} {o} {name_token(rng.choice(OWNER_NAMES))}'
        else:
            line = f'YS {r} {o}'
        decisive(w)
        note(state['run'].rows[emit(line, area)])
        return line

    def cycle(w, flat, shrink):
        s = cur()
        x = s.write_scope(w)
        i = 0
        while (x not in s.parts or s.parts[x]['mode'] == 'flat') and i < flat + 4:
            n = f'g{w[0]}x{w[1]}y{i}'.encode()
            i += 1
            if s.index.get(n):
                continue
            emit(f'YU a {w[0]} {w[1]} {name_token(n)} {fresh_mask(x)} -', 'owner_independence_rows')
        if x not in s.parts or s.parts[x]['mode'] != 'graph' or shrink == 0:
            return
        names = [e['name'] for e in s.parts[x]['order'] if e['name'].startswith(b'g')]
        while x in s.parts and s.parts[x]['mode'] == 'graph' and names:
            emit(f'YU r {w[0]} {w[1]} {name_token(names.pop())}', 'owner_independence_rows')

    def header(sub, labels, flat, shrink, plain, k):
        sub.emit('ZT ' + ' '.join(f'{a}:{b}:{c}' for a, b, c in labels))
        sub.emit(f"YN {flat} {shrink} {'plain' if plain else 'lab'} {k}")
        sub.s.used = {}

    def limits():
        return rng.choice([(3, 0), (4, 1), (6, 2), (512, 128)])

    for session in range(30):
        plain = session % 5 == 4
        k = (2, 3, 4)[session % 3]
        labels = scheme_choice(rng)
        nl = len(labels)
        flat, shrink = limits()
        header(main, labels, flat, shrink, plain, k)
        stats['owner_sessions'] += 1
        converted = not plain
        if plain:
            stats['owner_plain_sessions'] += 1
            for _ in range(rng.randrange(3, 10)):
                n = rng.choice(OWNER_NAMES)
                emit(f"YP {name_token(n)} {fresh_mask((0, 0))} {rng.choice(['-', 'e', 'a1', 'a3'])}",
                     'owner_compatibility_rows')
            for o in range(k + 1):
                for line in owner_digest_lines((0, o), 0x0F0F0F0F0F0F0F0F):
                    emit(line, 'owner_compatibility_rows')
        for step in range(rng.randrange(70, 150)):
            w = (rng.randrange(nl), rng.randrange(k + 1))
            if converted and flat <= 6 and step % 40 == 20:
                cycle((rng.randrange(nl), rng.randrange(1, k + 1) if rng.randrange(4) else 0), flat, shrink)
            if rng.randrange(5) < 3 or cur().total() == 0:
                line = write_line(w, k, None, checked=converted)
                if line is not None and not converted and main.rows[-1].startswith('YA|1|1|') and w != (0, 0):
                    converted = True
            else:
                read_line(w)
        for _ in range(3):
            w = (rng.randrange(nl), rng.randrange(1, k + 1) if rng.randrange(4) else 0)
            s = cur()
            hidden = [(l, o) for l in range(nl) for o in range(k + 1) if not s.sees(w, (l, o))]
            if not hidden or s.total() == 0:
                continue
            q = rng.getrandbits(64)
            before = [main.rows[emit(line, 'owner_independence_rows')] for line in owner_digest_lines(w, q)]
            for _ in range(rng.randrange(10, 40)):
                x = rng.choice(hidden)
                if rng.randrange(6) == 0:
                    emit(f"YM {x[0]} {x[1]} {rng.choice('mdr')} {rng.randrange(1, 6)}", 'owner_independence_rows')
                else:
                    write_line(x, k, 'owner_independence_rows', keep_owner=w[1], checked=converted)
            after = [main.rows[emit(line, 'owner_independence_rows')] for line in owner_digest_lines(w, q)]
            assert after == before
            stats['owner_bursts'] += 1
        for o in range(k + 1):
            for r in range(nl):
                if rng.randrange(2):
                    note(main.rows[emit(search_line((r, o)))])
                    emit(f'YC {r} {o}')

    trust_schemes = ([(0, 0, 0), (0, 0, 1), (0, 0, 2), (1, 0, 0), (1, 0, 1)],
                     [(0, 0, 0), (0, 0, 1), (0, 1, 0), (0, 1, 1), (1, 3, 0), (1, 3, 1)])
    for session in range(8):
        labels = list(trust_schemes[session % 2])
        nl = len(labels)
        k = 3
        flat, shrink = limits()
        header(main, labels, flat, shrink, False, k)
        stats['owner_sessions'] += 1
        stats['owner_trust_sessions'] += 1
        sch = Scheme(labels)
        pairs = [(r, d) for r in range(nl) for d in range(nl)
                 if r != d and sch.sees(r, d) and sch.rank(d) > sch.rank(r)]
        for j in range(4):
            r, d = rng.choice(pairs)
            n = f't{j}'
            u = rng.randrange(1, k + 1)
            emit(f'YA {r} 0 {n} {fresh_mask((r, 0))} a1')
            emit(f'YA {d} 0 {n} {fresh_mask((d, 0))} -')
            ups = [x for x in range(nl) if x != d and sch.sees(r, x) and sch.rank(x) > sch.rank(r) and not sch.sees(x, d)]
            if ups:
                x = rng.choice(ups)
                emit(f'YA {x} {u} {n} {fresh_mask((x, u))} a2')
            for o in range(1, k + 1):
                emit(f'YF {r} {o} {n}')
                emit(f'YS {r} {o}')
                emit(f'YC {r} {o}')
            emit(f'YQ {r} {u} e {n} 5 1 - - -')
            emit(f'YA {r} {u} {n} {fresh_mask((r, u))} -')
            emit(f'YE {r} {u} {n} a4')
        lows = [i for i, lab in enumerate(labels) if lab[2] == 0]
        steps = rng.randrange(80, 140)
        for step in range(steps):
            cands = lows if step < steps // 3 else list(range(nl))
            if rng.randrange(5) < 3 or cur().total() == 0:
                write_line((rng.choice(cands), 0 if rng.randrange(2) else rng.randrange(1, k + 1)), k, None)
            else:
                read_line((rng.choice(lows), rng.randrange(1, k + 1) if rng.randrange(4) else 0))
        for o in range(1, k + 1):
            for line in owner_digest_lines((0, o), rng.getrandbits(64)):
                emit(line)

    for op in ('create', 'view', 'add', 'rem', 'set', 'relabel', 'casp', 'casc', 'relabelx'):
        for o, st in ((0, 0), (0, 1), (1, 0), (1, 1), (3, 1), (EVERY_OWNER, 0), (EVERY_OWNER, 1)):
            emit(f'YI {op} 1 {o} {st}')
            stats['owner_invalid_rows'] += 1

    for pair in range(14):
        k = (3, 4)[pair % 2]
        labels = scheme_choice(rng)
        nl = len(labels)
        sch = Scheme(labels)
        flat, shrink = limits()
        obs = (rng.randrange(nl), rng.randrange(1, k + 1) if pair % 4 else 0)
        sub = OwnerRun()
        header(sub, labels, flat, shrink, False, k)
        state['run'] = sub
        for _ in range(rng.randrange(120, 200)):
            if rng.randrange(5) == 0:
                read_line(obs)
            else:
                w = (rng.randrange(nl), rng.randrange(k + 1))
                if rng.randrange(4) == 0:
                    read_line(w)
                else:
                    write_line(w, k, None)
        state['run'] = main
        lines, rows_a = sub.lines, sub.rows
        purged = [line for line in lines if owner_scope_visible(sch, obs, line)]
        seen_a, seen_b = observer_rows(lines, obs), observer_rows(purged, obs)
        rows_b = replay(purged)
        assert len(seen_a) == len(seen_b) and [rows_a[i] for i in seen_a] == [rows_b[i] for i in seen_b]
        base_a = len(main.rows)
        for line in lines:
            emit(line, 'owner_independence_rows')
        base_b = len(main.rows)
        for line in purged:
            emit(line, 'owner_independence_rows')
        twins.append(([base_a + i for i in seen_a], [base_b + i for i in seen_b]))
        stats['owner_twin_pairs'] += 1
        stats['owner_twin_rows'] += len(seen_a)
        stats['owner_twin_hidden'] += len(lines) - len(purged)
        if obs[1] == 0:
            continue
        cands = [i for i, line in enumerate(lines) if i > 1 and (line.startswith('YA ') or line.startswith('YU a '))
                 and rows_a[i].startswith(('YA|1|', 'YU|a|1|')) and line_scope(line)[1] == 0
                 and owner_scope_visible(sch, obs, line)]
        rng.shuffle(cands)
        for c in cands[:40]:
            dropped = lines[:c] + lines[c + 1:]
            rows_c = replay(dropped)
            seen_c = observer_rows(dropped, obs)
            if [rows_c[i] for i in seen_c] != [rows_a[i] for i in seen_a]:
                base_c = len(main.rows)
                for line in dropped:
                    emit(line, 'owner_independence_rows')
                sensitivity.append(([base_a + i for i in seen_a], [base_c + i for i in seen_c]))
                stats['owner_sensitivity'] += 1
                break

    for pair in range(8):
        u = rng.randrange(1, 4)
        labels = scheme_choice(rng)
        nl = len(labels)
        flat, shrink = limits()
        sub = OwnerRun()
        header(sub, labels, flat, shrink, False, 3)
        state['run'] = sub
        for _ in range(rng.randrange(60, 120)):
            w = (rng.randrange(nl), 0)
            if rng.randrange(5) < 3 or sub.s.total() == 0:
                op = rng.randrange(14)
                n = rng.choice(OWNER_NAMES)
                if op < 8:
                    sub.emit(f"YA {w[0]} 0 {name_token(n)} {fresh_mask(w)} {rng.choice(['-', 'e', 'a1', 'a3'])}")
                elif op < 12:
                    if w in sub.s.index.get(n, []) and sub.s.total() <= 1:
                        continue
                    sub.emit(f'YR {w[0]} 0 {name_token(n)}')
                else:
                    sub.emit(f"YE {w[0]} 0 {name_token(n)} {rng.choice(['e', 'a1', 'a3'])}")
            else:
                read_line(w, with_stats=False)
        state['run'] = main
        lines = sub.lines
        moved = []
        for line in lines[2:]:
            f = line.split(' ')
            f[2] = str(u)
            moved.append(' '.join(f))
        lines_b = lines[:2] + [f'YZ {u} 0'] + moved
        rows_a, rows_b = sub.rows, replay(lines_b)
        assert [normalise_owner(r, u) for r in rows_b[3:]] == rows_a[2:]
        base_a = len(main.rows)
        for line in lines:
            emit(line, 'owner_compatibility_rows')
        base_b = len(main.rows)
        for line in lines_b:
            emit(line, 'owner_compatibility_rows')
        singles.append((list(range(base_a + 2, base_a + len(lines))), list(range(base_b + 3, base_b + len(lines_b))), u))
        stats['owner_single_pairs'] += 1
        stats['owner_single_rows'] += len(lines) - 2

    for row in main.rows:
        if row.startswith('YU|'):
            stats['owner_account_rows'] += 1
            gm = row.split('|')[-5]
            stats['owner_graduations'] += gm == 'g'
            stats['owner_flattens'] += gm == 'f'
    for line, area in zip(main.lines, main.kinds):
        kind = line.split(' ')[0]
        if kind in ('ZT', 'YN', 'YZ'):
            continue
        stats[area or ROW_AREAS[kind]] += 1
    assert stats['owner_refusals'] > 0 and stats['owner_forced_copies'] > 0 and stats['owner_bursts'] > 0
    assert stats['owner_graduations'] > 0 and stats['owner_flattens'] > 0 and stats['owner_forgets'] > 0
    assert stats['owner_twin_pairs'] > 0 and stats['owner_sensitivity'] > 0 and stats['owner_single_pairs'] > 0
    assert stats['owner_shared_exact_decisive'] > 0
    return main, twins, singles, sensitivity
