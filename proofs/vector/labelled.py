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
