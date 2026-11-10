import math
import struct

M64 = (1 << 64) - 1
GOLDEN = 0x9E3779B97F4A7C15
LEVELS = ['L0', 'L1', 'L2']
COMPS = ['CA', 'CB']
TRUSTS = ['T0', 'T1']
DIM = 8
NAMES = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'ab', 'ba']
WRONGTYPE = '-WRONGTYPE Operation against a key holding the wrong kind of value'
NO_KEY = '-ERR key does not exist'
LINK_LIMIT = 32
COUNT_DEFAULT = 10
WRITES = ('VADD', 'VREM', 'VSETATTR', 'SET')


def label_mix(x):
    z = (x * GOLDEN) & M64
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
    return z ^ (z >> 31)


def finish(z):
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
    return z ^ (z >> 31)


def label_hash(lab):
    level, comps, trust = lab
    h = ((level | trust << 8) * GOLDEN + 0xD6E8FEB86659FD93) & M64
    for w in (comps, 0, 0, 0):
        h = ((h ^ w) * 0xBF58476D1CE4E5B9) & M64
        h ^= h >> 31
    return h ^ (h >> 29)


def below(streams, lab, n):
    if n <= 1:
        return 0
    floor = ((1 << 64) - n) % n
    while True:
        streams[lab] = (streams[lab] + GOLDEN) & M64
        v = finish(streams[lab])
        if v >= floor:
            return v % n


def all_labels():
    return [(lv, cm, tr) for lv in range(len(LEVELS)) for cm in range(1 << len(COMPS)) for tr in range(len(TRUSTS))]


def text(lab):
    level, comps, trust = lab
    out = LEVELS[level]
    picked = [COMPS[i] for i in range(len(COMPS)) if comps >> i & 1]
    if picked:
        out += '//' + '/'.join(picked)
    if trust:
        out += ';' + TRUSTS[trust]
    return out


def sees(r, d):
    return d[0] <= r[0] and d[1] & r[1] == d[1] and r[2] <= d[2]


def rank(x):
    return (x[0], bin(x[1]).count('1'), x[2])


def order_key(x):
    return (tuple(-v for v in rank(x)), -x[1])


def fmt_double(x):
    if x == int(x):
        return str(int(x))
    return repr(x)


def bulk(s):
    return f'${len(s)}^{s}^'


def integer(n):
    return f':{n}^'


def array(items):
    return f'*{len(items)}^' + ''.join(items)


NULL = '$-1^'


def score(a, b, dim):
    return 1 - bin((a ^ b) & ((1 << dim) - 1)).count('1') / dim


def escape(data):
    return ''.join(chr(b) if 0x20 <= b < 0x7f and chr(b) not in '\\|^' else '\\x%02x' % b for b in data)


class Obj:
    def __init__(self, dim):
        self.dim = dim
        self.parts = {}
        self.index = {}

    def part(self, lab):
        return self.parts.get(lab)

    def card(self):
        return sum(len(p['order']) for p in self.parts.values())

    def resolve(self, reader, name):
        best = None
        for lab in self.index.get(name, []):
            if lab == reader:
                return lab
            if not sees(reader, lab):
                continue
            if best is None or rank(lab) > rank(best):
                best = lab
        return best

    def other(self, writer, name):
        if any(lab != writer and sees(writer, lab) for lab in self.index.get(name, [])):
            return self.resolve(writer, name)
        return None


class Model:
    def __init__(self, seed):
        secret = label_mix(seed & M64)
        self.streams = {lab: label_mix(((label_hash(lab) ^ secret) + 6) & M64) for lab in all_labels()}
        self.keys = {}
        self.objects = {}
        self.next_obj = 0
        self.seq = 0

    def copies(self, key):
        return self.keys.setdefault(key, [])

    def lookup(self, reader, key):
        cs = self.copies(key)
        for c in cs:
            if c['label'] == reader:
                return c
        best = None
        for c in cs:
            if not sees(reader, c['label']):
                continue
            if best is None or rank(c['label']) > rank(best['label']):
                best = c
        return best

    def presence_add(self, key, lab, obj):
        self.seq += 1
        self.copies(key).append({'label': lab, 'kind': 'vset', 'obj': obj, 'seq': self.seq})

    def presence_drop(self, key, lab):
        cs = self.copies(key)
        cs[:] = [c for c in cs if c['label'] != lab]

    def insert(self, key, o, lab, name, mask, attr):
        created = lab not in o.parts
        if created:
            self.streams[lab] = (self.streams[lab] + GOLDEN) & M64
            o.parts[lab] = {'order': [], 'elems': {}, 'uid': 0}
            self.presence_add(key, lab, o)
        p = o.parts[lab]
        p['uid'] += 1
        p['order'].append(name)
        p['elems'][name] = {'mask': mask, 'attr': attr}
        o.index.setdefault(name, []).append(lab)

    def remove(self, key, o, lab, name):
        p = o.parts[lab]
        order = p['order']
        i = order.index(name)
        order[i] = order[-1]
        order.pop()
        del p['elems'][name]
        o.index[name].remove(lab)
        if not o.index[name]:
            del o.index[name]
        if not order:
            del o.parts[lab]
            self.presence_drop(key, lab)

    def view(self, reader, o):
        labs = sorted((lab for lab in o.parts if sees(reader, lab)), key=order_key)
        refs = []
        for lab in labs:
            for name in o.parts[lab]['order']:
                if o.resolve(reader, name) == lab:
                    refs.append((lab, name))
        return labs, refs

    def read(self, reader, key):
        c = self.lookup(reader, key)
        if c is None:
            return None, None
        if c['kind'] != 'vset':
            return 'wrong', None
        o = c['obj']
        labs, refs = self.view(reader, o)
        if not refs:
            return None, None
        return o, (labs, refs)

    def write_target(self, writer, key):
        c = self.lookup(writer, key)
        if c is None:
            return None, None
        if c['kind'] != 'vset':
            if c['label'] == writer:
                return WRONGTYPE + '^', None
            return f'-INUSE name in use at {text(c["label"])}^', None
        return None, c['obj']

    def run(self, lab, cmd, args):
        return getattr(self, 'c_' + cmd.lower())(lab, *args)

    def c_set(self, lab, key, value):
        c = self.lookup(lab, key)
        if c is not None and c['label'] != lab:
            return f'-INUSE name in use at {text(c["label"])}^'
        if c is None:
            self.seq += 1
            self.copies(key).append({'label': lab, 'kind': 'string', 'obj': None, 'seq': self.seq})
        return '+OK^'

    def c_vadd(self, lab, key, dim, mask, name, attr):
        refusal, o = self.write_target(lab, key)
        if refusal:
            return refusal
        mask &= (1 << dim) - 1
        if o is None:
            o = Obj(dim)
            self.next_obj += 1
            self.insert(key, o, lab, name, mask, attr)
            return integer(1)
        if dim != o.dim:
            return f'-ERR Vector dimension mismatch - got {dim} but set has {o.dim}^'
        if lab in o.index.get(name, []):
            e = o.parts[lab]['elems'][name]
            e['mask'] = mask
            o.parts[lab]['uid'] += 1
            if attr is not None:
                e['attr'] = attr
            return integer(0)
        other = o.other(lab, name)
        if other is not None:
            return f'-INUSE element in use at {text(other)}^'
        self.insert(key, o, lab, name, mask, attr)
        return integer(1)

    def c_vrem(self, lab, key, name):
        refusal, o = self.write_target(lab, key)
        if refusal:
            return refusal
        if o is None:
            return integer(0)
        if lab in o.index.get(name, []):
            self.remove(key, o, lab, name)
            return integer(1)
        other = o.other(lab, name)
        if other is not None:
            return f'-INUSE element in use at {text(other)}^'
        return integer(0)

    def c_vsetattr(self, lab, key, name, attr):
        refusal, o = self.write_target(lab, key)
        if refusal:
            return refusal
        if o is None:
            return integer(0)
        if lab in o.index.get(name, []):
            o.parts[lab]['elems'][name]['attr'] = attr if attr else None
            return integer(1)
        other = o.other(lab, name)
        if other is not None:
            return f'-INUSE element in use at {text(other)}^'
        return integer(0)

    def c_vcard(self, lab, key):
        o, v = self.read(lab, key)
        if o == 'wrong':
            return WRONGTYPE + '^'
        return integer(len(v[1]) if v else 0)

    def c_vdim(self, lab, key):
        o, v = self.read(lab, key)
        if o == 'wrong':
            return WRONGTYPE + '^'
        return integer(o.dim) if v else NO_KEY + '^'

    def found(self, lab, key, name):
        o, v = self.read(lab, key)
        if o == 'wrong':
            return 'wrong', None, None
        if v is None:
            return None, None, None
        r = o.resolve(lab, name)
        if r is None or r not in v[0]:
            return o, v, None
        return o, v, r

    def c_vismember(self, lab, key, name):
        o, v, r = self.found(lab, key, name)
        if o == 'wrong':
            return WRONGTYPE + '^'
        return integer(int(r is not None))

    def c_vgetattr(self, lab, key, name):
        o, v, r = self.found(lab, key, name)
        if o == 'wrong':
            return WRONGTYPE + '^'
        if r is None:
            return NULL
        attr = o.parts[r]['elems'][name]['attr']
        return NULL if attr is None else bulk(attr)

    def c_vinfo(self, lab, key):
        o, v = self.read(lab, key)
        if o == 'wrong':
            return WRONGTYPE + '^'
        if v is None:
            return '*-1^'
        labs, refs = v
        attrs = sum(1 for r, n in refs if o.parts[r]['elems'][n]['attr'] is not None)
        uid = sum(o.parts[x]['uid'] for x in labs)
        fields = [('quant-type', '+bin^'), ('hnsw-m', integer(16)), ('vector-dim', integer(o.dim)),
                  ('projection-input-dim', integer(0)), ('size', integer(len(refs))), ('max-level', integer(0)),
                  ('attributes-count', integer(attrs)), ('vset-uid', integer(0)), ('hnsw-max-node-uid', integer(uid))]
        return f'*{2 * len(fields)}^' + ''.join(f'+{k}^' + val for k, val in fields)

    def c_vemb(self, lab, key, name, raw):
        o, v, r = self.found(lab, key, name)
        if o == 'wrong':
            return WRONGTYPE + '^'
        if r is None:
            return NULL
        mask = o.parts[r]['elems'][name]['mask']
        if raw:
            data = escape(mask.to_bytes(8, 'little'))
            norm = struct.unpack('<f', struct.pack('<f', math.sqrt(o.dim)))[0]
            return f'*3^+bin^$8^{data}^' + bulk(fmt_double(norm))
        return array([bulk('1' if mask >> i & 1 else '-1') for i in range(o.dim)])

    def c_vlinks(self, lab, key, name, with_scores):
        o, v, r = self.found(lab, key, name)
        if o == 'wrong':
            return WRONGTYPE + '^'
        if r is None:
            return NULL
        p = o.parts[r]
        mask = p['elems'][name]['mask']
        others = [(score(mask, p['elems'][n]['mask'], o.dim), n) for n in p['order']
                  if n != name and o.resolve(lab, n) == r]
        others.sort(key=lambda h: (-h[0], h[1].encode()))
        others = others[:LINK_LIMIT]
        if with_scores:
            body = f'*{2 * len(others)}^' + ''.join(bulk(n) + bulk(fmt_double(s)) for s, n in others)
        else:
            body = array([bulk(n) for _, n in others])
        return '*1^' + body

    def c_vrange(self, lab, key, start, end, count):
        o, v = self.read(lab, key)
        if o == 'wrong':
            return WRONGTYPE + '^'
        if v is None:
            return '*0^'
        visible = {n for _, n in v[1]}
        names = sorted(visible, key=lambda n: n.encode())

        def above(n):
            if start == '-':
                return True
            return n.encode() >= start[1:].encode() if start[0] == '[' else n.encode() > start[1:].encode()

        def under(n):
            if end == '+':
                return True
            return n.encode() <= end[1:].encode() if end[0] == '[' else n.encode() < end[1:].encode()

        out = [n for n in names if above(n) and under(n)]
        if count is not None:
            out = out[:count]
        return array([bulk(n) for n in out])

    def c_vrandmember(self, lab, key, count):
        o, v = self.read(lab, key)
        if o == 'wrong':
            return WRONGTYPE + '^'
        if count is None:
            if v is None:
                return NULL
            return bulk(v[1][below(self.streams, lab, len(v[1]))][1])
        if v is None or count == 0:
            return '*0^'
        refs = v[1]
        n = len(refs)
        if count < 0:
            return array([bulk(refs[below(self.streams, lab, n)][1]) for _ in range(-count)])
        want = min(count, n)
        if want >= n:
            out = list(refs)
            self.shuffle(lab, out)
        elif want * 4 <= n:
            picks, out = set(), []
            for j in range(n - want, n):
                t = below(self.streams, lab, j + 1)
                if t not in picks:
                    picks.add(t)
                    out.append(refs[t])
                else:
                    picks.add(j)
                    out.append(refs[j])
            self.shuffle(lab, out)
        else:
            pool = list(range(n))
            for i in range(want):
                j = i + below(self.streams, lab, n - i)
                pool[i], pool[j] = pool[j], pool[i]
            out = [refs[pool[i]] for i in range(want)]
        return array([bulk(name) for _, name in out])

    def shuffle(self, lab, out):
        for i in range(len(out) - 1, 0, -1):
            j = below(self.streams, lab, i + 1)
            out[i], out[j] = out[j], out[i]

    def c_vsim(self, lab, key, query, count, with_scores, with_attribs, flt):
        o, v = self.read(lab, key)
        if o == 'wrong':
            return WRONGTYPE + '^'
        if v is None:
            return '*0^'
        if isinstance(query, str):
            r = o.resolve(lab, query)
            if r is None or r not in v[0]:
                return '-ERR element not found in set^'
            qmask = o.parts[r]['elems'][query]['mask']
        else:
            if o.dim != DIM:
                return f'-ERR Vector dimension mismatch - got {DIM} but set has {o.dim}^'
            qmask = query
        hits = []
        for r, n in v[1]:
            e = o.parts[r]['elems'][n]
            if flt is not None and not accept(flt, e['attr']):
                continue
            hits.append((score(qmask, e['mask'], o.dim), n, e['attr']))
        hits.sort(key=lambda h: (-h[0], h[1].encode()))
        hits = hits[:count if count is not None else COUNT_DEFAULT]
        out = []
        for s, n, attr in hits:
            out.append(bulk(n))
            if with_scores:
                out.append(bulk(fmt_double(s)))
            if with_attribs:
                out.append(NULL if attr is None else bulk(attr))
        return f'*{len(out)}^' + ''.join(out)


def accept(flt, attr):
    if attr is None:
        return False
    value = int(attr.split(':')[1].rstrip('}'))
    op, bound = flt
    return value > bound if op == '>' else value == bound


def vector_args(mask, dim):
    return ['VALUES', str(dim)] + ['1' if mask >> i & 1 else '-1' for i in range(dim)]


def command_args(cmd, args):
    if cmd == 'SET':
        return ['SET', args[0], args[1]]
    if cmd == 'VADD':
        key, dim, mask, name, attr = args
        out = ['VADD', key] + vector_args(mask, dim) + [name, 'BIN']
        if attr is not None:
            out += ['SETATTR', attr]
        return out
    if cmd in ('VREM', 'VCARD', 'VDIM', 'VINFO', 'VISMEMBER', 'VGETATTR'):
        return [cmd] + list(args)
    if cmd == 'VSETATTR':
        return ['VSETATTR', args[0], args[1], args[2]]
    if cmd == 'VEMB':
        return ['VEMB', args[0], args[1]] + (['RAW'] if args[2] else [])
    if cmd == 'VLINKS':
        return ['VLINKS', args[0], args[1]] + (['WITHSCORES'] if args[2] else [])
    if cmd == 'VRANGE':
        return ['VRANGE', args[0], args[1], args[2]] + ([str(args[3])] if args[3] is not None else [])
    if cmd == 'VRANDMEMBER':
        return ['VRANDMEMBER', args[0]] + ([str(args[1])] if args[1] is not None else [])
    if cmd == 'VSIM':
        key, query, count, with_scores, with_attribs, flt = args
        out = ['VSIM', key] + (['ELE', query] if isinstance(query, str) else vector_args(query, DIM))
        if count is not None:
            out += ['COUNT', str(count)]
        if with_scores:
            out.append('WITHSCORES')
        if with_attribs:
            out.append('WITHATTRIBS')
        if flt is not None:
            out += ['FILTER', f'.a {"==" if flt[0] == "=" else ">"} {flt[1]}']
        return out
    raise AssertionError(cmd)


def row_line(lab, cmd, args):
    argv = command_args(cmd, args)
    if lab is not None:
        marking = text(lab)
        argv = ['LABEL', 'AS', marking] + argv
    return 'E ' + ' '.join(a.encode().hex() if a else '-' for a in argv)


def random_command(rng, labs, keys, strings):
    lab = rng.choice(labs)
    key = rng.choice(keys)
    name = rng.choice(NAMES)
    k = rng.randrange(100)
    attr = rng.choice([None, None, '{"a":%d}' % rng.randrange(6)])
    if k < 34:
        dim = DIM if rng.randrange(25) else 2
        return lab, 'VADD', (key if rng.randrange(12) else rng.choice(strings), dim, rng.randrange(256), name, attr)
    if k < 42:
        return lab, 'VREM', (key, name)
    if k < 48:
        return lab, 'VSETATTR', (key, name, rng.choice(['{"a":%d}' % rng.randrange(6), '']))
    if k < 52:
        return lab, rng.choice(['VCARD', 'VDIM', 'VINFO']), (key if rng.randrange(6) else rng.choice(strings),)
    if k < 58:
        return lab, rng.choice(['VISMEMBER', 'VGETATTR']), (key, name)
    if k < 64:
        return lab, 'VEMB', (key, name, rng.randrange(3) == 0)
    if k < 70:
        return lab, 'VLINKS', (key, name, rng.randrange(2) == 0)
    if k < 76:
        bounds = ['-', '[' + rng.choice(NAMES), '(' + rng.choice(NAMES)]
        ends = ['+', '[' + rng.choice(NAMES), '(' + rng.choice(NAMES)]
        return lab, 'VRANGE', (key, rng.choice(bounds), rng.choice(ends), rng.choice([None, 1, 2, 5]))
    if k < 84:
        return lab, 'VRANDMEMBER', (key, rng.choice([None, 1, 2, 3, 5, 9, 30, -1, -4, 0]))
    query = rng.choice(NAMES) if rng.randrange(2) else rng.randrange(256)
    flt = rng.choice([None, None, ('>', rng.randrange(5)), ('=', rng.randrange(5))])
    return lab, 'VSIM', (key, query, rng.choice([None, 1, 2, 3, 4, 20]), rng.randrange(2) == 0,
                         rng.randrange(3) == 0, flt)


def session(rng, number, ops):
    universe = all_labels()
    labs = rng.sample(universe, rng.randrange(3, 8))
    if number % 5 == 4:
        labs = [(1, 1, 0), (1, 2, 0), (2, 3, 0), (2, 3, 0), (0, 0, 0)]
    keys = [f'k{number}_{i}' for i in range(rng.randrange(1, 3))]
    strings = [f's{number}']
    out = [(rng.choice(labs), 'SET', (strings[0], 'v')) for _ in range(rng.randrange(0, 3))]
    for _ in range(ops):
        out.append(random_command(rng, labs, keys, strings))
    return out, labs


def hidden_twin(rng, cmds, labs, number):
    universe = all_labels()
    observer = rng.choice(labs)
    hidden = [lab for lab in universe if not sees(observer, lab)]
    if not hidden:
        return None, observer
    keys = sorted({args[0] for _, cmd, args in cmds if cmd != 'SET'} | {f'k{number}_0'})
    twin = []
    for c in cmds:
        while rng.randrange(3) == 0:
            lab = rng.choice(hidden)
            name = rng.choice(NAMES)
            k = rng.randrange(10)
            key = rng.choice(keys)
            if k < 6:
                twin.append((lab, 'VADD', (key, DIM, rng.randrange(256), name, rng.choice([None, '{"a":1}']))))
            elif k < 8:
                twin.append((lab, 'VREM', (key, name)))
            else:
                twin.append((lab, 'VRANDMEMBER', (key, 3)) if k == 8 else (lab, 'VCARD', (key,)))
        twin.append(c)
    return twin, observer


def simulate(seed, cmds, stats=None):
    m = Model(seed)
    rows = []
    for lab, cmd, args in cmds:
        rows.append('E|' + m.run(lab, cmd, args))
        if stats is not None:
            stats['command_rows'] += 1
            stats['command_' + ('writes' if cmd in WRITES else 'reads')] += 1
            if 'INUSE' in rows[-1]:
                stats['command_refusals'] += 1
    if stats is not None:
        stats['command_objects'] += m.next_obj
        stats['command_split_keys'] += sum(1 for cs in m.keys.values()
                                           if len({id(c['obj']) for c in cs if c['kind'] == 'vset'}) > 1)
    return rows


def scheme_line(seed, labelled):
    return f'S {",".join(LEVELS)} {",".join(COMPS)} {",".join(TRUSTS)} {seed} {int(labelled)}'


STAT_KEYS = ('command_rows', 'command_writes', 'command_reads', 'command_refusals', 'command_objects',
             'command_split_keys', 'command_sessions', 'p2_pairs', 'p2_hidden_commands', 'p2_observer_rows',
             'p2_hidden_writes_accepted')


def corpus(rng, seed, sessions, twins):
    stats = {k: 0 for k in STAT_KEYS}
    cmds = []
    for n in range(sessions):
        s, _ = session(rng, n, rng.randrange(30, 90))
        cmds += s
        stats['command_sessions'] += 1
    main = ([scheme_line(seed, True)] + [row_line(lab, c, a) for lab, c, a in cmds],
            simulate(seed, cmds, stats), cmds)
    pairs = []
    for n in range(twins):
        base, labs = session(rng, 1000 + n, rng.randrange(30, 70))
        twin, observer = hidden_twin(rng, base, labs, 1000 + n)
        if twin is None:
            continue
        rows_a = simulate(seed, base)
        rows_b = simulate(seed, twin)
        marks = [i for i, c in enumerate(twin) if c not in base or twin.count(c) > base.count(c)]
        keep_b = [i for i in range(len(twin)) if sees(observer, twin[i][0])]
        observed = []
        j = 0
        for i, c in enumerate(twin):
            if j < len(base) and c is base[j]:
                if sees(observer, c[0]):
                    observed.append((j, i))
                j += 1
        assert j == len(base) and len(keep_b) >= len(observed) and marks is not None
        stats['p2_pairs'] += 1
        stats['p2_hidden_commands'] += len(twin) - len(base)
        stats['p2_observer_rows'] += len(observed)
        stats['p2_hidden_writes_accepted'] += sum(1 for i, r in enumerate(rows_b) if r == 'E|:1^' and
                                                    twin[i][1] in WRITES and not sees(observer, twin[i][0]))
        pairs.append(([scheme_line(seed, True)] + [row_line(lab, c, a) for lab, c, a in base], rows_a,
                      [scheme_line(seed, True)] + [row_line(lab, c, a) for lab, c, a in twin], rows_b, observed))
    return main, pairs, stats


def p10_corpus(rng, seed):
    writes, reads = [], []
    for k in range(rng.randrange(8, 12)):
        key = f'p{k}'
        for _ in range(rng.randrange(2, 14)):
            writes.append((None, 'VADD', (key, DIM, rng.randrange(256), rng.choice(NAMES),
                                          rng.choice([None, '{"a":%d}' % rng.randrange(5)]))))
        for _ in range(rng.randrange(1, 4)):
            writes.append((None, rng.choice(['VREM', 'VSETATTR']), (key, rng.choice(NAMES)) if rng.randrange(2)
                           else (key, rng.choice(NAMES), '{"a":2}')))
        for _ in range(30):
            c = random_command(rng, [None], [key], ['s'])
            if c[1] == 'VSIM':
                c = (c[0], c[1], c[2][:3] + (True,) + c[2][4:])
            if c[1] not in WRITES:
                reads.append(c)
    writes = [(lab, 'VREM', args[:2]) if cmd == 'VREM' else (lab, cmd, args) for lab, cmd, args in writes]
    fixed = []
    for lab, cmd, args in writes:
        if cmd == 'VSETATTR' and len(args) == 2:
            args = args + ('{"a":1}',)
        fixed.append((lab, cmd, args))
    plain = [row_line(None, c, a) for _, c, a in fixed + reads]
    labelled = [f'S L0,L1 - - {seed} 0'] + plain + ['A'] + [row_line((0, 0, 0), c, a) for _, c, a in reads] + \
        [row_line((1, 0, 0), c, a) for _, c, a in reads]
    single = [f'S L0 - - {seed} 1'] + plain
    return labelled, single, len(fixed), reads


def resp_items(row):
    body = row[2:].split('^')
    assert body[0].startswith('*'), row
    items, i = [], 1
    while i < len(body) - 1:
        if body[i] == '$-1':
            items.append(None)
            i += 1
        else:
            items.append(body[i + 1])
            i += 2
    return items


def p10_agree(cmd, args, plain, labelled):
    if cmd == 'VRANDMEMBER':
        head, other = plain.split('^')[0], labelled.split('^')[0]
        if head.startswith('E|*') or head == 'E|$-1':
            return head == other, 'random'
        return other.startswith('E|$') and other != 'E|$-1', 'random'
    if cmd == 'VINFO' and plain.startswith('E|*18^'):
        fixed = plain.split('^')
        fixed[16] = ':0'
        return '^'.join(fixed) == labelled, 'uid' if fixed != plain.split('^') else 'same'
    if cmd != 'VSIM' or plain == labelled or not plain.startswith('E|*'):
        return plain == labelled, 'same'
    width = 1 + int(args[3]) + int(args[4])
    a, b = resp_items(plain), resp_items(labelled)
    if len(a) != len(b) or len(a) % width or not args[3]:
        return False, 'ties'
    ra = [a[i:i + width] for i in range(0, len(a), width)]
    rb = [b[i:i + width] for i in range(0, len(b), width)]
    if [r[1] for r in ra] != [r[1] for r in rb]:
        return False, 'ties'
    groups = {}
    for r in ra:
        groups.setdefault(r[1], []).append(r)
    last = ra[-1][1]
    ok = True
    for score in groups:
        ga = sorted(tuple(r) for r in ra if r[1] == score)
        gb = [tuple(r) for r in rb if r[1] == score]
        if gb != sorted(gb, key=lambda r: r[0].encode()):
            ok = False
        if score != last and ga != sorted(gb):
            ok = False
    return ok, 'ties'


def model_mutants():
    def ignores_own(self, reader, key):
        best = None
        for c in self.copies(key):
            if sees(reader, c['label']) and (best is None or rank(c['label']) > rank(best['label'])):
                best = c
        return best

    def sees_all(self, reader, key):
        cs = self.copies(key)
        for c in cs:
            if c['label'] == reader:
                return c
        return max(cs, key=lambda c: rank(c['label']), default=None)

    def newest(self, reader, name):
        best = None
        for lab in self.index.get(name, []):
            if lab == reader:
                return lab
            if sees(reader, lab) and (best is None or rank(lab) >= rank(best)):
                best = lab
        return best

    original_insert = Model.insert

    def no_stream(self, key, o, lab, name, mask, attr):
        before = self.streams[lab]
        created = lab not in o.parts
        original_insert(self, key, o, lab, name, mask, attr)
        if created:
            self.streams[lab] = before

    original_vinfo = Model.c_vinfo

    def uid_shown(self, lab, key):
        row = original_vinfo(self, lab, key)
        return row.replace('+vset-uid^:0^', '+vset-uid^:1^')

    original_vsim = Model.c_vsim

    def ties_reversed(self, lab, key, query, count, with_scores, with_attribs, flt):
        row = original_vsim(self, lab, key, query, None if count is None else count, with_scores, with_attribs, flt)
        if not row.startswith('*') or with_scores or with_attribs:
            return row
        items = row.split('^')[1:-1]
        names = items[1::2]
        o, v = self.read(lab, key)
        if v is None or len(names) < 2 or isinstance(query, str):
            return row
        scored = [(score(query, o.parts[r]['elems'][n]['mask'], o.dim), n) for r, n in v[1] if n in names]
        scored.sort(key=lambda h: (-h[0], [-ord(ch) for ch in h[1]]))
        return array([bulk(n) for _, n in scored][:len(names)])

    return {'lookup_ignores_own': ('lookup', ignores_own), 'lookup_ignores_visibility': ('lookup', sees_all),
            'element_ties_newest': (('Obj', 'resolve'), newest), 'creation_keeps_stream': ('insert', no_stream),
            'vinfo_shows_uid': ('c_vinfo', uid_shown), 'vsim_ties_reversed': ('c_vsim', ties_reversed)}
