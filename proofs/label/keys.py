import fnmatch

LEVELS = ['L0', 'L1', 'L2']
COMPS = ['CA', 'CB']
TRUSTS = ['T0', 'T1']
NOW = 1_700_000_000_000
WRONGTYPE = '-WRONGTYPE Operation against a key holding the wrong kind of value^'
NOT_INT = '-ERR value is not an integer or out of range^'
NO_KEY = '-ERR no such key^'
DIRECTION = "-ERR the target label must be below the copy's label^"
SAME = '-ERR source and destination objects are the same^'
NULL = '$-1^'
OK = '+OK^'
DBS = 16
SCAN_SHIFT = 48


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


def part_key(x):
    return (-x[0], -bin(x[1]).count('1'), -x[2], -x[1])


def bulk(s):
    return f'${len(s)}^{s}^'


def integer(n):
    return f':{n}^'


def array(items):
    return f'*{len(items)}^' + ''.join(items)


def inuse(lab):
    return f'-INUSE name in use at {text(lab)}^'


def fmt_score(x):
    return str(int(x)) if x == int(x) else repr(x)


class Copy:
    def __init__(self, lab, kind, val, exp, touch):
        self.label, self.kind, self.val, self.exp, self.touch = lab, kind, val, exp, touch

    def clone(self, lab, touch=None):
        val = self.val
        if isinstance(val, (dict, list, set)):
            val = type(val)(val) if not isinstance(val, list) else list(val)
        if self.kind == 'stream':
            val = {'n': self.val['n'], 'last': self.val['last']}
        return Copy(lab, self.kind, val, self.exp, self.touch if touch is None else touch)


class Keys:
    def __init__(self, labelled=True):
        self.labelled = labelled
        self.now = NOW
        self.db = 0
        self.names = [dict() for _ in range(DBS)]
        self.ordered = [set() for _ in range(DBS)]
        self.notes = {}
        self.events = []
        self.paused = False

    def sees(self, r, d):
        return sees(r, d)

    def rank(self, x):
        return rank(x)

    def part_order(self, labs):
        return sorted(labs, key=part_key)

    def occupied(self, d, lab, k):
        return self.find(d, lab, k) is not None

    def inuse_label(self, d, lab, name):
        return self.other(d, lab, name).label

    def note(self, key):
        self.notes[key] = self.notes.get(key, 0) + 1

    def copies(self, d, name):
        return self.names[d].get(name, [])

    def own(self, d, lab, name):
        return next((c for c in self.copies(d, name) if c.label == lab), None)

    def better(self, a, b):
        return self.rank(a.label) > self.rank(b.label)

    def other(self, d, lab, name):
        best = None
        for c in self.copies(d, name):
            if c.label == lab or not self.sees(lab, c.label):
                continue
            if best is None or self.better(c, best):
                best = c
        return best

    def resolve(self, d, lab, name):
        o = self.own(d, lab, name)
        if o is not None:
            b = self.other(d, lab, name)
            if b is not None and self.rank(b.label) > self.rank(lab):
                self.note('own_over_better')
            return o
        return self.other(d, lab, name)

    def survey(self, d, lab, name):
        cs = self.copies(d, name)
        vis = [c for c in cs if c.label != lab and self.sees(lab, c.label)]
        if any(not self.sees(lab, c.label) for c in cs) and vis:
            self.note('hidden_beside_visible')
        if vis:
            top = max(self.rank(c.label) for c in vis)
            if sum(1 for c in vis if self.rank(c.label) == top) > 1 and self.own(d, lab, name) is None:
                self.note('tie_by_age')

    def create(self, d, lab, name, c):
        self.events.append(('A', d, name, lab))
        self.names[d].setdefault(name, []).append(c)
        self.ordered[d].add(lab)
        if len(self.names[d][name]) > 1:
            self.note('copies_held')

    def drop(self, d, lab, name):
        cs = self.names[d].get(name, [])
        if any(c.label == lab for c in cs):
            self.events.append(('D', d, name, lab))
        cs[:] = [c for c in cs if c.label != lab]
        if not cs:
            self.names[d].pop(name, None)

    def visible_names(self, d, lab):
        return sorted(n for n, cs in self.names[d].items() if any(self.sees(lab, c.label) for c in cs))

    def parts(self, d, lab):
        return self.part_order([p for p in self.ordered[d] if self.sees(lab, p)])

    def writes(self, cmd, args):
        if cmd in ('SET',):
            return [(args[0], 'NX' in [a.upper() for a in args[2:]])]
        if cmd in ('SETNX',):
            return [(args[0], True)]
        if cmd == 'MSETNX':
            return [(args[i], True) for i in range(0, len(args), 2)]
        if cmd == 'MSET':
            return [(args[i], False) for i in range(0, len(args), 2)]
        if cmd in ('DEL',):
            return [(a, False) for a in args]
        if cmd in ('APPEND', 'INCR', 'EXPIRE', 'PERSIST', 'HSET', 'RPUSH', 'SADD', 'ZADD', 'XADD', 'MOVE'):
            return [(args[0], False)]
        if cmd == 'RENAME':
            return [(args[0], False), (args[1], False)]
        if cmd == 'RENAMENX':
            return [(args[0], False), (args[1], True)]
        if cmd == 'DECLASSIFY':
            return [(args[0], False)]
        return []

    def run(self, lab, cmd, args):
        d = self.db
        if self.labelled:
            for name, creates_only in self.writes(cmd, args):
                if self.own(d, lab, name) is not None:
                    continue
                o = self.other(d, lab, name)
                if o is not None:
                    if creates_only:
                        self.note('create_only_visible')
                        continue
                    self.note('inuse')
                    return inuse(self.inuse_label(d, lab, name))
        return getattr(self, 'c_' + cmd.lower())(d, lab, *args)

    def find(self, d, lab, name):
        self.survey(d, lab, name)
        c = self.resolve(d, lab, name)
        if c is not None and c.label != lab:
            self.note('foreign_read')
        return c

    def touch(self, c, lab):
        if c is not None and c.label == lab:
            c.touch = self.now

    def c_get(self, d, lab, k):
        c = self.find(d, lab, k)
        self.touch(c, lab)
        if c is None:
            return NULL
        return bulk(c.val) if c.kind == 'string' else WRONGTYPE

    def c_mget(self, d, lab, *ks):
        out = []
        for k in ks:
            c = self.find(d, lab, k)
            self.touch(c, lab)
            out.append(bulk(c.val) if c is not None and c.kind == 'string' else NULL)
        return array(out)

    def c_exists(self, d, lab, *ks):
        return integer(sum(1 for k in ks if self.find(d, lab, k) is not None))

    def c_type(self, d, lab, k):
        c = self.find(d, lab, k)
        return '+' + (c.kind if c is not None else 'none') + '^'

    def c_ttl(self, d, lab, k):
        c = self.find(d, lab, k)
        if c is None:
            return integer(-2)
        if c.exp is None:
            return integer(-1)
        return integer((c.exp - self.now + 500) // 1000)

    def c_pttl(self, d, lab, k):
        c = self.find(d, lab, k)
        if c is None:
            return integer(-2)
        return integer(-1 if c.exp is None else c.exp - self.now)

    def c_strlen(self, d, lab, k):
        c = self.find(d, lab, k)
        if c is None:
            return integer(0)
        return integer(len(c.val)) if c.kind == 'string' else WRONGTYPE

    def typed(self, d, lab, k, kind):
        c = self.find(d, lab, k)
        if c is None:
            return None, None
        if c.kind != kind:
            return None, WRONGTYPE
        return c, None

    def c_hget(self, d, lab, k, f):
        c, err = self.typed(d, lab, k, 'hash')
        return err or (bulk(c.val[f]) if c is not None and f in c.val else NULL)

    def c_hlen(self, d, lab, k):
        c, err = self.typed(d, lab, k, 'hash')
        return err or integer(len(c.val) if c else 0)

    def c_llen(self, d, lab, k):
        c, err = self.typed(d, lab, k, 'list')
        return err or integer(len(c.val) if c else 0)

    def c_lrange(self, d, lab, k, a, b):
        c, err = self.typed(d, lab, k, 'list')
        return err or array([bulk(x) for x in (c.val if c else [])])

    def c_scard(self, d, lab, k):
        c, err = self.typed(d, lab, k, 'set')
        return err or integer(len(c.val) if c else 0)

    def c_sismember(self, d, lab, k, m):
        c, err = self.typed(d, lab, k, 'set')
        return err or integer(int(c is not None and m in c.val))

    def c_zscore(self, d, lab, k, m):
        c, err = self.typed(d, lab, k, 'zset')
        return err or (bulk(fmt_score(c.val[m])) if c is not None and m in c.val else NULL)

    def c_zcard(self, d, lab, k):
        c, err = self.typed(d, lab, k, 'zset')
        return err or integer(len(c.val) if c else 0)

    def c_xlen(self, d, lab, k):
        c, err = self.typed(d, lab, k, 'stream')
        return err or integer(c.val['n'] if c else 0)

    def c_labelof(self, d, lab, k):
        c = self.find(d, lab, k)
        return NULL if c is None else bulk(text(c.label))

    def c_idletime(self, d, lab, k):
        c = self.find(d, lab, k)
        return NULL if c is None else integer((self.now // 1000) - (c.touch // 1000))

    def c_dbsize(self, d, lab):
        return integer(len(self.visible_names(d, lab)) if self.labelled else len(self.names[d]))

    def c_keys(self, d, lab, pat):
        names = [n for n in self.visible_names(d, lab) if fnmatch.fnmatchcase(n, pat)]
        return f'{len(names)}' + ''.join(',' + n for n in names)

    def c_scan(self, d, lab, cursor, *opts):
        pat = opts[opts.index('MATCH') + 1] if 'MATCH' in opts else '*'
        parts = self.parts(d, lab)
        k = int(cursor) >> SCAN_SHIFT
        chosen = set(parts[k:])
        names = [n for n in self.visible_names(d, lab)
                 if self.resolve(d, lab, n).label in chosen and fnmatch.fnmatchcase(n, pat)]
        if k:
            self.note('scan_resumed')
            empty = [p for p in parts if not any(c.label == p for cs in self.names[d].values() for c in cs)]
            if empty and any(parts.index(p) < k for p in empty):
                self.note('scan_empty_part')
        return '0:' + f'{len(names)}' + ''.join(',' + n for n in names)

    def live(self, c):
        return c.exp is None or c.exp > self.now

    def c_randomkey(self, d, lab):
        visible = [(n, c) for n, cs in self.names[d].items() for c in cs if self.sees(lab, c.label)]
        names = sorted({n for n, c in visible if self.live(c)})
        expired = sorted({n for n, c in visible if not self.live(c)})
        if self.paused:
            self.note('paused_live' if names else ('paused_expired' if expired else 'paused_empty'))
            if names and expired:
                self.note('paused_live_beside_expired')
            if not names:
                names = expired
        elif expired and not names:
            self.note('unpaused_expired_only')
        return {NULL} if not names else {bulk(n) for n in names}

    def c_pause(self, d, lab, ms, mode):
        self.paused = True
        return OK

    def c_unpause(self, d, lab):
        self.paused = False
        return OK

    def c_select(self, d, lab, n):
        self.db = int(n)
        return OK

    def put(self, d, lab, k, kind, val, exp=None, keep=False):
        c = self.own(d, lab, k)
        if c is not None:
            c.kind, c.val, c.touch = kind, val, self.now
            if not keep:
                c.exp = exp
            self.note('overwrite')
            return c
        c = Copy(lab, kind, val, exp, self.now)
        self.create(d, lab, k, c)
        self.note('create')
        return c

    def c_set(self, d, lab, k, v, *opts):
        up = [o.upper() for o in opts]
        exp = None
        if 'PX' in up:
            exp = self.now + int(opts[up.index('PX') + 1])
        if 'NX' in up and self.occupied(d, lab, k):
            self.note('nx_refused')
            return NULL
        if 'XX' in up and self.find(d, lab, k) is None:
            return NULL
        self.put(d, lab, k, 'string', v, exp)
        return OK

    def c_setnx(self, d, lab, k, v):
        if self.occupied(d, lab, k):
            self.note('nx_refused')
            return integer(0)
        self.put(d, lab, k, 'string', v)
        return integer(1)

    def c_msetnx(self, d, lab, *kv):
        if any(self.occupied(d, lab, kv[i]) for i in range(0, len(kv), 2)):
            self.note('nx_refused')
            return integer(0)
        for i in range(0, len(kv), 2):
            self.put(d, lab, kv[i], 'string', kv[i + 1])
        return integer(1)

    def c_append(self, d, lab, k, v):
        c = self.own(d, lab, k)
        if c is not None and c.kind != 'string':
            return WRONGTYPE
        c = self.put(d, lab, k, 'string', (c.val if c else '') + v, c.exp if c else None)
        return integer(len(c.val))

    def c_incr(self, d, lab, k):
        c = self.own(d, lab, k)
        if c is not None and c.kind != 'string':
            return WRONGTYPE
        old = c.val if c else '0'
        if not (old.isdigit() or (old.startswith('-') and old[1:].isdigit())) or (len(old) > 1 and old[0] == '0'):
            return NOT_INT
        c = self.put(d, lab, k, 'string', str(int(old) + 1), c.exp if c else None)
        return integer(int(c.val))

    def c_del(self, d, lab, *ks):
        n = 0
        for k in ks:
            if self.own(d, lab, k) is not None:
                self.drop(d, lab, k)
                n += 1
        if n:
            self.note('deleted')
        return integer(n)

    def c_expire(self, d, lab, k, s):
        c = self.own(d, lab, k)
        if c is None:
            return integer(0)
        c.exp = self.now + int(s) * 1000
        return integer(1)

    def c_persist(self, d, lab, k):
        c = self.own(d, lab, k)
        if c is None or c.exp is None:
            return integer(0)
        c.exp = None
        return integer(1)

    def container(self, d, lab, k, kind, empty):
        c = self.own(d, lab, k)
        if c is not None and c.kind != kind:
            return None, WRONGTYPE
        if c is None:
            c = Copy(lab, kind, empty, None, self.now)
            self.create(d, lab, k, c)
            self.note('create')
        else:
            c.touch = self.now
        return c, None

    def c_hset(self, d, lab, k, *fv):
        c, err = self.container(d, lab, k, 'hash', {})
        if err:
            return err
        n = 0
        for i in range(0, len(fv), 2):
            n += fv[i] not in c.val
            c.val[fv[i]] = fv[i + 1]
        return integer(n)

    def c_rpush(self, d, lab, k, *vs):
        c, err = self.container(d, lab, k, 'list', [])
        if err:
            return err
        c.val.extend(vs)
        return integer(len(c.val))

    def c_sadd(self, d, lab, k, *ms):
        c, err = self.container(d, lab, k, 'set', set())
        if err:
            return err
        n = len(set(ms) - c.val)
        c.val |= set(ms)
        return integer(n)

    def c_zadd(self, d, lab, k, s, m):
        c, err = self.container(d, lab, k, 'zset', {})
        if err:
            return err
        n = int(m not in c.val)
        c.val[m] = float(s)
        return integer(n)

    def c_xadd(self, d, lab, k, star, f, v):
        c, err = self.container(d, lab, k, 'stream', {'n': 0, 'last': (0, -1)})
        if err:
            return err
        ms, seq = c.val['last']
        seq = seq + 1 if ms == self.now else 0
        c.val['last'] = (self.now, seq)
        c.val['n'] += 1
        return bulk(f'{self.now}-{seq}')

    def c_rename(self, d, lab, a, b):
        c = self.own(d, lab, a)
        if c is None:
            return NO_KEY
        if a == b:
            return OK
        self.drop(d, lab, a)
        if self.own(d, lab, b) is not None:
            self.drop(d, lab, b)
            self.note('rename_replaced')
        self.create(d, lab, b, c.clone(lab, self.now))
        self.note('renamed')
        return OK

    def c_renamenx(self, d, lab, a, b):
        c = self.own(d, lab, a)
        if c is None:
            return NO_KEY
        if self.occupied(d, lab, b):
            self.note('nx_refused')
            return integer(0)
        self.drop(d, lab, a)
        self.create(d, lab, b, c.clone(lab, self.now))
        self.note('renamed')
        return integer(1)

    def c_copy(self, d, lab, a, b, *opts):
        replace = 'REPLACE' in [o.upper() for o in opts]
        if a == b:
            return SAME
        src = self.find(d, lab, a)
        if src is None:
            return integer(0)
        own = self.own(d, lab, b)
        if own is None and self.labelled:
            o = self.other(d, lab, b)
            if o is not None:
                if not replace:
                    self.note('create_only_visible')
                    return integer(0)
                self.note('inuse')
                return inuse(o.label)
        if own is not None:
            if not replace:
                return integer(0)
            self.drop(d, lab, b)
        self.create(d, lab, b, src.clone(lab, self.now))
        self.note('copied_foreign' if src.label != lab else 'copied')
        return integer(1)

    def c_move(self, d, lab, k, target):
        t = int(target)
        if t == d:
            return SAME
        if self.own(t, lab, k) is not None or (self.labelled and self.other(t, lab, k) is not None):
            self.note('move_refused' if self.own(t, lab, k) is not None else 'move_visible_target')
            return integer(0)
        c = self.own(d, lab, k)
        if c is None:
            return integer(0)
        self.drop(d, lab, k)
        self.create(t, lab, k, c.clone(lab, self.now))
        self.note('moved')
        return integer(1)

    def c_declassify(self, d, lab, k, target):
        if target == lab or not self.sees(lab, target):
            self.note('declassify_direction')
            return DIRECTION
        c = self.own(d, lab, k)
        if c is None:
            return NO_KEY
        seen = self.resolve(d, target, k)
        if seen is not None:
            self.note('declassify_target_sees')
            return inuse(seen.label)
        self.drop(d, lab, k)
        self.create(d, target, k, c.clone(target))
        self.note('declassified')
        return OK


READS = ('GET', 'MGET', 'EXISTS', 'TYPE', 'TTL', 'PTTL', 'STRLEN', 'HGET', 'HLEN', 'LLEN', 'LRANGE', 'SCARD',
         'SISMEMBER', 'ZSCORE', 'ZCARD', 'XLEN', 'LABELOF', 'IDLETIME', 'DBSIZE', 'KEYS', 'SCAN', 'RANDOMKEY')
KINDS = {'KEYS': 'N', 'SCAN': 'C', 'RANDOMKEY': 'R'}
NAMES = ['k0', 'k1', 'k2', 'k3', 'k4', 'k5', 'k6']
PATTERNS = ['*', 'k*', '*1', 'k?', 'i*']
BOTTOM = (0, 0, 0)


def argv(cmd, args):
    if cmd == 'LABELOF':
        return ['LABEL', 'OF'] + list(args)
    if cmd == 'DECLASSIFY':
        return ['LABEL', 'DECLASSIFY', args[0], text(args[1])]
    if cmd == 'IDLETIME':
        return ['OBJECT', 'IDLETIME'] + list(args)
    if cmd in ('PAUSE', 'UNPAUSE'):
        return ['CLIENT', cmd] + list(args)
    return [cmd] + [str(a) for a in args]


def row_line(lab, cmd, args, labelled=True):
    if cmd == 'T':
        return f'T {args[0]}'
    words = argv(cmd, args)
    if labelled:
        words = ['LABEL', 'AS', text(lab)] + words
    return KINDS.get(cmd, 'E') + ' ' + ' '.join(w.encode().hex() if w else '-' for w in words)


def expected(m, lab, cmd, args):
    if cmd == 'T':
        m.now = int(args[0])
        return f'T|{m.now}'
    out = m.run(lab, cmd, args)
    if isinstance(out, set):
        return {'E|' + x for x in out}
    return KINDS.get(cmd, 'E') + '|' + out if cmd in KINDS else 'E|' + out


def write_command(rng, lab, labs, names):
    k = rng.choice(names)
    r = rng.randrange(100)
    v = rng.choice(['a', 'bb', '7', 'x1'])
    if r < 18:
        opts = rng.choice([(), (), ('NX',), ('XX',), ('PX', str(rng.choice([10_000_000, 20_000_000])))])
        return 'SET', (k, v) + opts
    if r < 23:
        return 'SETNX', (k, v)
    if r < 27:
        a, b = rng.sample(names, 2)
        return 'MSETNX', (a, v, b, 'w')
    if r < 31:
        return 'APPEND', (k, v)
    if r < 34:
        return 'INCR', (k,)
    if r < 41:
        return 'DEL', tuple(rng.sample(names, rng.randint(1, 3)))
    if r < 44:
        return 'EXPIRE', (k, str(rng.choice([50000, 90000])))
    if r < 46:
        return 'PERSIST', (k,)
    if r < 51:
        return 'HSET', (k, rng.choice(['f', 'g']), v)
    if r < 55:
        return 'RPUSH', (k, v)
    if r < 59:
        return 'SADD', (k, v)
    if r < 63:
        return 'ZADD', (k, rng.choice(['1', '2.5', '3']), rng.choice(['m', 'n']))
    if r < 66:
        return 'XADD', (k, '*', 'f', v)
    if r < 71:
        a, b = rng.sample(names, 2)
        return rng.choice(['RENAME', 'RENAMENX']), (a, b)
    if r < 78:
        a, b = rng.sample(names, 2)
        return 'COPY', (a, b) + rng.choice([(), ('REPLACE',)])
    if r < 82:
        return 'MOVE', (k, '1')
    below = [t for t in labs if t != lab and sees(lab, t)]
    target = rng.choice(below) if below and rng.randrange(5) else rng.choice(labs)
    return 'DECLASSIFY', (k, target)


def read_command(rng, names):
    k = rng.choice(names)
    r = rng.randrange(100)
    if r < 14:
        return 'GET', (k,)
    if r < 20:
        return 'MGET', tuple(rng.sample(names, rng.randint(2, 4)))
    if r < 26:
        return 'EXISTS', tuple(rng.choice(names) for _ in range(rng.randint(1, 3)))
    if r < 31:
        return 'TYPE', (k,)
    if r < 34:
        return rng.choice(['TTL', 'PTTL']), (k,)
    if r < 37:
        return 'STRLEN', (k,)
    if r < 42:
        return rng.choice([('HGET', (k, 'f')), ('HLEN', (k,))])
    if r < 46:
        return rng.choice([('LLEN', (k,)), ('LRANGE', (k, '0', '-1'))])
    if r < 50:
        return rng.choice([('SCARD', (k,)), ('SISMEMBER', (k, 'a'))])
    if r < 54:
        return rng.choice([('ZSCORE', (k, 'm')), ('ZCARD', (k,))])
    if r < 56:
        return 'XLEN', (k,)
    if r < 68:
        return 'LABELOF', (k,)
    if r < 75:
        return 'DBSIZE', ()
    if r < 82:
        return 'KEYS', (rng.choice(PATTERNS),)
    if r < 93:
        opts = ('COUNT', '1000') + (('MATCH', rng.choice(PATTERNS)) if rng.randrange(3) == 0 else ())
        return 'SCAN', (str(rng.randrange(4) << SCAN_SHIFT),) + opts
    return 'RANDOMKEY', ()


TIES = [(1, 1, 0), (1, 2, 0), (2, 3, 0), (0, 0, 0), (1, 1, 1), (2, 1, 0)]


def session_labels(rng, number):
    if number % 4 == 3:
        return list(TIES)
    return rng.sample(all_labels(), rng.randrange(3, 8))


def session(rng, number, ops):
    labs = session_labels(rng, number)
    out, now, probes = [], NOW, 0
    for _ in range(ops):
        r = rng.randrange(100)
        lab = rng.choice(labs)
        if r < 4:
            now += 1000 * rng.randint(1, 5)
            out.append((None, 'T', (now,)))
        elif r < 8:
            readers = [x for x in labs if x != lab and sees(x, lab)]
            name = f'i{number}_{probes}'
            probes += 1
            out.append((lab, 'SET', (name, 'p')))
            now += 1000 * rng.randint(1, 4)
            out.append((None, 'T', (now,)))
            for x in readers[:2]:
                out.append((x, rng.choice(['GET', 'EXISTS', 'TYPE', 'STRLEN', 'MGET']), (name,)))
                out.append((x, 'IDLETIME', (name,)))
            out.append((lab, 'IDLETIME', (name,)))
            out.append((lab, 'GET', (name,)))
            out.append((lab, 'IDLETIME', (name,)))
        elif r < 15 and r >= 13 and number % 4 == 3:
            x, y = rng.sample([(1, 1, 0), (1, 2, 0)], 2)
            name, src = f'a{number}_{probes}', f'b{number}_{probes}'
            probes += 1
            out += [(x, 'SET', (name, 'x')), (y, 'SET', (name, 'y')), ((2, 3, 0), 'LABELOF', (name,)),
                    (x, 'SET', (src, 's'))]
            op = rng.choice(['COPY', 'RENAME', 'SET', 'RENAMENX'])
            if op == 'COPY':
                out.append((x, 'COPY', (src, name, 'REPLACE')))
            elif op == 'RENAME':
                out.append((x, 'RENAME', (src, name)))
            elif op == 'RENAMENX':
                out.append((x, 'RENAMENX', (src, name)))
            else:
                out.append((x, 'SET', (name, 'z')))
            out += [((2, 3, 0), 'LABELOF', (name,)), ((2, 3, 0), 'GET', (name,))]
        elif r < 16 and r >= 15:
            ys = [(y, x) for y in labs for x in labs if y != x and sees(y, x)]
            if ys:
                y, x = rng.choice(ys)
                name = f'm{number}_{probes}'
                probes += 1
                out += [(x, 'SELECT', ('1',)), (x, 'SET', (name, 'one')), (x, 'SELECT', ('0',)),
                        (y, 'SET', (name, 'zero')), (y, 'MOVE', (name, '1')), (y, 'GET', (name,)),
                        (y, 'SELECT', ('1',)), (y, 'LABELOF', (name,)), (y, 'GET', (name,)), (y, 'SELECT', ('0',))]
        elif r < 13 and r >= 11:
            x = rng.choice(labs)
            name = f'e{number}_{probes}'
            probes += 1
            out += [(x, 'SET', (name, 'e')), (x, 'DEL', (name,))]
            readers = [y for y in labs if sees(y, x)]
            for k in range(1, 4):
                out.append((rng.choice(readers), 'SCAN', (str(k << SCAN_SHIFT), 'COUNT', '1000')))
        elif r < 11:
            k = rng.choice(NAMES)
            out += [(lab, 'SELECT', ('1',)), (lab, rng.choice(['GET', 'TYPE', 'LABELOF', 'EXISTS']), (k,)),
                    (lab, 'DBSIZE', ()), (lab, 'SELECT', ('0',))]
        elif r < 21:
            name = rng.choice(NAMES)
            group = rng.sample(labs, min(len(labs), rng.randint(2, 3)))
            if number % 4 == 3 and rng.randrange(2):
                group = rng.sample([(1, 1, 0), (1, 2, 0)], 2)
            group.sort(key=lambda x: -sum(1 for y in all_labels() if sees(x, y)))
            for x in group:
                cmd = rng.choice(['SET', 'SET', 'HSET', 'RPUSH'])
                out.append((x, cmd, (name, 'f', 'b') if cmd == 'HSET' else (name, 'b')))
            for _ in range(rng.randint(2, 4)):
                reader = (2, 3, 0) if number % 4 == 3 and rng.randrange(2) else rng.choice(labs)
                out.append((reader, rng.choice(['GET', 'LABELOF', 'LABELOF', 'TYPE', 'EXISTS']), (name,)))
        elif r < 52:
            cmd, args = write_command(rng, lab, labs, NAMES)
            out.append((lab, cmd, args))
        else:
            cmd, args = read_command(rng, NAMES)
            out.append((lab, cmd, args))
    return out, labs


def scheme_line(seed, labelled):
    return f'S {",".join(LEVELS)} {",".join(COMPS)} {",".join(TRUSTS)} {seed} {int(labelled)}'


def simulate(cmds, labelled=True, mutant=None):
    m = Keys(labelled)
    if mutant:
        mutant(m)
    rows = [expected(m, lab if labelled else BOTTOM, cmd, args) for lab, cmd, args in cmds]
    return rows, m


def hidden_twin(rng, cmds, labs, number):
    observer = rng.choice(labs)
    hidden = [lab for lab in all_labels() if not sees(observer, lab)]
    if not hidden:
        return None, None, observer
    cmds = [c for c in cmds if c[1] != 'DECLASSIFY' or sees(observer, c[0])]
    twin = []
    for c in cmds:
        while rng.randrange(3) == 0:
            lab = rng.choice(hidden)
            if rng.randrange(3):
                cmd, args = write_command(rng, lab, hidden, NAMES)
                if cmd == 'DECLASSIFY':
                    cmd, args = 'SET', (args[0], 'h')
            else:
                cmd, args = read_command(rng, NAMES)
            twin.append((lab, cmd, args))
        twin.append(c)
    return cmds, twin, observer


def mutants():
    def own_rule_dropped(m):
        def resolve(d, lab, name):
            best = None
            for c in m.copies(d, name):
                if m.sees(lab, c.label) and (best is None or m.rank(c.label) > m.rank(best.label)):
                    best = c
            return best
        m.resolve = resolve

    def hidden_compartment_visible(m):
        m.sees = lambda r, d: d[0] <= r[0] and r[2] <= d[2]

    def trust_not_reversed(m):
        m.sees = lambda r, d: d[0] <= r[0] and d[1] & r[1] == d[1] and d[2] <= r[2]

    def age_reversed(m):
        m.better = lambda a, b: m.rank(a.label) >= m.rank(b.label)

    def foreign_read_touches(m):
        def touch(c, lab):
            if c is not None:
                c.touch = m.now
        m.touch = touch

    def inuse_names_hidden(m):
        def inuse_label(d, lab, name):
            best = None
            for c in m.copies(d, name):
                if c.label != lab and (best is None or m.rank(c.label) > m.rank(best.label)):
                    best = c
            return best.label
        m.inuse_label = inuse_label

    def create_only_writes(m):
        m.occupied = lambda d, lab, k: m.own(d, lab, k) is not None

    def declassify_skips_target(m):
        def c_declassify(d, lab, k, target):
            if target == lab or not m.sees(lab, target):
                return DIRECTION
            c = m.own(d, lab, k)
            if c is None:
                return NO_KEY
            if m.own(d, target, k) is not None:
                return inuse(target)
            m.drop(d, lab, k)
            m.create(d, target, k, c.clone(target))
            return OK
        m.c_declassify = c_declassify

    def scan_counts_hidden(m):
        m.parts = lambda d, lab: m.part_order(list(m.ordered[d]))

    def scan_forgets_empty(m):
        m.parts = lambda d, lab: m.part_order([p for p in m.ordered[d] if m.sees(lab, p) and
                                               any(c.label == p for cs in m.names[d].values() for c in cs)])

    def partition_order_reversed(m):
        m.part_order = lambda labs: sorted(labs, key=part_key, reverse=True)

    def dbsize_counts_hidden(m):
        m.c_dbsize = lambda d, lab: integer(len(m.names[d]))

    def keys_show_hidden(m):
        def c_keys(d, lab, pat):
            names = sorted(n for n in m.names[d] if fnmatch.fnmatchcase(n, pat))
            return f'{len(names)}' + ''.join(',' + n for n in names)
        m.c_keys = c_keys

    def labelof_reports_reader(m):
        m.c_labelof = lambda d, lab, k: NULL if m.find(d, lab, k) is None else bulk(text(lab))

    def copy_replace_keeps_age(m):
        original = m.c_copy

        def c_copy(d, lab, a, b, *opts):
            own = m.own(d, lab, b)
            src = m.find(d, lab, a)
            if own is not None and src is not None and a != b and 'REPLACE' in [o.upper() for o in opts]:
                own.kind, own.val, own.exp = src.kind, src.clone(lab).val, src.exp
                return integer(1)
            return original(d, lab, a, b, *opts)
        m.c_copy = c_copy

    def rename_keeps_age(m):
        original = m.c_rename

        def c_rename(d, lab, a, b):
            c = m.own(d, lab, a)
            dst = m.own(d, lab, b)
            if c is not None and a != b and dst is not None:
                m.drop(d, lab, a)
                dst.kind, dst.val, dst.exp = c.kind, c.val, c.exp
                return OK
            return original(d, lab, a, b)
        m.c_rename = c_rename

    def write_check_first_only(m):
        original = m.writes
        m.writes = lambda cmd, args: original(cmd, args)[:1]

    def move_ignores_visible(m):
        def c_move(d, lab, k, target):
            t = int(target)
            if m.own(t, lab, k) is not None:
                return integer(0)
            c = m.own(d, lab, k)
            if c is None:
                return integer(0)
            m.drop(d, lab, k)
            m.create(t, lab, k, c.clone(lab, m.now))
            return integer(1)
        m.c_move = c_move

    def copy_reads_own_only(m):
        original = m.c_copy

        def c_copy(d, lab, a, b, *opts):
            if a != b and m.own(d, lab, a) is None:
                return integer(0)
            return original(d, lab, a, b, *opts)
        m.c_copy = c_copy

    return {f.__name__: f for f in (own_rule_dropped, hidden_compartment_visible, trust_not_reversed, age_reversed,
                                    foreign_read_touches, inuse_names_hidden, create_only_writes,
                                    declassify_skips_target, scan_counts_hidden, scan_forgets_empty,
                                    partition_order_reversed, dbsize_counts_hidden, keys_show_hidden,
                                    labelof_reports_reader, copy_replace_keeps_age, rename_keeps_age,
                                    write_check_first_only, move_ignores_visible, copy_reads_own_only)}


WRITES = ('SET', 'SETNX', 'MSETNX', 'APPEND', 'INCR', 'DEL', 'EXPIRE', 'PERSIST', 'HSET', 'RPUSH', 'SADD', 'ZADD',
          'XADD', 'RENAME', 'RENAMENX', 'COPY', 'MOVE', 'DECLASSIFY')
NOTES = ('create', 'overwrite', 'deleted', 'inuse', 'create_only_visible', 'nx_refused', 'foreign_read',
         'copies_held', 'own_over_better', 'tie_by_age', 'hidden_beside_visible', 'declassified',
         'declassify_target_sees', 'declassify_direction', 'moved', 'copied', 'copied_foreign', 'renamed',
         'scan_resumed', 'scan_empty_part', 'rename_replaced', 'move_visible_target')


def row_kind(cmd):
    if cmd == 'LABELOF':
        return 'KO'
    if cmd in WRITES:
        return 'KW'
    return 'KR'


def corpus(rng, seed, sessions, ops):
    out = []
    for number in range(sessions):
        cmds, labs = session(rng, number, rng.randrange(ops // 2, ops))
        rows, m = simulate(cmds)
        lines = [scheme_line(seed, True)] + [row_line(lab, c, a) for lab, c, a in cmds]
        out.append((lines, rows, cmds, m.notes))
    return out


def twin_corpus(rng, seed, pairs):
    out = []
    for n in range(pairs):
        base, labs = session(rng, 1000 + n, rng.randrange(50, 110))
        raw = []
        for c in base:
            raw.append(c)
            if c[1] in ('SCAN', 'RANDOMKEY', 'KEYS') and rng.randrange(2):
                raw.append((c[0], 'RAWSCAN', ('0', 'COUNT', str(rng.choice([1, 2, 3])))))
        base, twin, observer = hidden_twin(rng, raw, labs, 1000 + n)
        if twin is None:
            continue
        out.append((base, twin, observer))
    return out


def raw_line(lab, cmd, args):
    if cmd == 'RAWSCAN':
        return 'E ' + ' '.join(w.encode().hex() for w in ['LABEL', 'AS', text(lab), 'SCAN'] + list(args))
    if cmd == 'RANDOMKEY':
        return 'E ' + ' '.join(w.encode().hex() for w in ['LABEL', 'AS', text(lab), 'RANDOMKEY'])
    return row_line(lab, cmd, args)


def twin_rows(cmds):
    m = Keys(True)
    rows = []
    for lab, cmd, args in cmds:
        if cmd == 'RAWSCAN':
            rows.append(None)
            continue
        r = expected(m, lab, cmd, args)
        rows.append(None if cmd == 'RANDOMKEY' else r)
    return rows


def p10_commands(rng):
    names = NAMES
    writes, reads = [], []
    for _ in range(rng.randrange(40, 70)):
        cmd, args = write_command(rng, BOTTOM, [BOTTOM], names)
        if cmd in ('DECLASSIFY', 'MOVE'):
            cmd, args = 'SET', (args[0], 'p')
        writes.append((BOTTOM, cmd, args))
    for _ in range(rng.randrange(40, 70)):
        cmd, args = read_command(rng, names)
        if cmd in ('LABELOF', 'IDLETIME'):
            cmd, args = 'GET', (args[0],)
        if cmd == 'SCAN':
            args = ('0',) + args[1:]
        reads.append((BOTTOM, cmd, args))
    return writes, reads


def ids(lab):
    picked = [str(i) for i in range(len(COMPS)) if lab[1] >> i & 1]
    return f'{lab[0]}:{",".join(picked) if picked else "-"}:{lab[2]}'


def resolution_trace(sessions):
    lines, rows = [], []
    for _, _, cmds, _ in sessions:
        m = Keys(True)
        lines.append('KX')
        rows.append('KX')
        for lab, cmd, args in cmds:
            expected(m, lab, cmd, args)
            for kind, d, name, l in m.events:
                lines.append(f'K{kind} {d} {name.encode().hex()} {ids(l)}')
                rows.append(f'K{kind}')
            m.events = []
            if cmd == 'LABELOF':
                c = m.resolve(m.db, lab, args[0])
                lines.append(f'KQ {m.db} {ids(lab)} {args[0].encode().hex()}')
                rows.append('KQ|' + (ids(c.label) if c is not None else '-'))
    return lines, rows


TOP = (len(LEVELS) - 1, (1 << len(COMPS)) - 1, 0)
PAUSE_SPANS = ['400', '1500', '2600']
PAUSE_NOTES = ('paused_live', 'paused_expired', 'paused_empty', 'paused_live_beside_expired', 'unpaused_expired_only')


def reach(x):
    return sum(1 for y in all_labels() if sees(x, y))


def pause_session(rng, number):
    labs = session_labels(rng, number)
    out, now = [], NOW
    for name in rng.sample(NAMES, rng.randint(2, 6)):
        group = rng.sample(labs, rng.randint(1, min(3, len(labs))))
        group.sort(key=lambda x: -reach(x))
        for lab in group:
            if rng.randrange(10) < 7:
                out.append((lab, 'SET', (name, 'p', 'PX', rng.choice(PAUSE_SPANS))))
            else:
                out.append((lab, 'SET', (name, 'q')))
    for _ in range(rng.randint(1, 3)):
        out.append((rng.choice(labs), 'RANDOMKEY', ()))
    now += rng.choice([1000, 2000, 3000])
    out.append((None, 'T', (now,)))
    out.append((TOP, 'PAUSE', ('100000000', 'WRITE')))
    for _ in range(rng.randint(4, 10)):
        out.append((rng.choice(labs + [TOP]), 'RANDOMKEY', ()))
    out.append((TOP, 'UNPAUSE', ()))
    for _ in range(rng.randint(1, 3)):
        out.append((rng.choice(labs), 'RANDOMKEY', ()))
    return out, labs


def pause_corpus(rng, seed, sessions):
    out = []
    for number in range(sessions):
        cmds, labs = pause_session(rng, number)
        rows, m = simulate(cmds)
        lines = [scheme_line(seed, True)] + [row_line(lab, c, a) for lab, c, a in cmds]
        out.append((lines, rows, cmds, m.notes))
    return out


def pause_branches(cmds):
    m = Keys(True)
    out = []
    for lab, cmd, args in cmds:
        before = dict(m.notes)
        expected(m, lab, cmd, args)
        changed = [n for n in PAUSE_NOTES if m.notes.get(n, 0) != before.get(n, 0) and n != 'paused_live_beside_expired']
        out.append(changed[0] if changed else None)
    return out


def pause_hidden(rng, hidden, writes):
    lab = rng.choice(hidden)
    k = rng.choice(NAMES)
    r = rng.randrange(4) if writes else 3
    if r == 0:
        return lab, 'SET', (k, 'h', 'PX', rng.choice(PAUSE_SPANS))
    if r == 1:
        return lab, 'SET', (k, 'h')
    if r == 2:
        return lab, 'DEL', (k,)
    return lab, 'RANDOMKEY', ()


def pause_twin_corpus(rng, seed, pairs):
    out = []
    for n in range(pairs):
        base, labs = pause_session(rng, 2000 + n)
        observer = rng.choice(labs)
        hidden = [lab for lab in all_labels() if not sees(observer, lab)]
        if not hidden:
            continue
        twin = []
        phase = 'before'
        for c in base:
            while phase != 'expired' and rng.randrange(2) == 0:
                twin.append(pause_hidden(rng, hidden, phase == 'before'))
            phase = {'T': 'expired', 'PAUSE': 'paused'}.get(c[1], phase)
            twin.append(c)
        out.append((base, twin, observer))
    return out


def pause_mutants():
    def expired_never_drawn(m):
        original = m.c_randomkey

        def c_randomkey(d, lab):
            out = original(d, lab)
            live = {bulk(n) for n, cs in m.names[d].items() if any(m.sees(lab, c.label) and m.live(c) for c in cs)}
            return out if live else {NULL}
        m.c_randomkey = c_randomkey

    def hidden_expired_drawn(m):
        def c_randomkey(d, lab):
            live = sorted({n for n, cs in m.names[d].items() for c in cs if m.sees(lab, c.label) and m.live(c)})
            if not live and m.paused:
                live = sorted({n for n, cs in m.names[d].items() for c in cs if not m.live(c)})
            return {NULL} if not live else {bulk(n) for n in live}
        m.c_randomkey = c_randomkey

    def expired_drawn_unpaused(m):
        def c_randomkey(d, lab):
            visible = [(n, c) for n, cs in m.names[d].items() for c in cs if m.sees(lab, c.label)]
            names = sorted({n for n, c in visible if m.live(c)}) or sorted({n for n, c in visible})
            return {NULL} if not names else {bulk(n) for n in names}
        m.c_randomkey = c_randomkey

    def expired_name_drawn_beside_live(m):
        def c_randomkey(d, lab):
            visible = [(n, c) for n, cs in m.names[d].items() for c in cs if m.sees(lab, c.label)]
            names = sorted({n for n, c in visible if not m.live(c)}) if m.paused else []
            names = names or sorted({n for n, c in visible if m.live(c)})
            return {NULL} if not names else {bulk(n) for n in names}
        m.c_randomkey = c_randomkey

    return {f.__name__: f for f in (expired_never_drawn, hidden_expired_drawn, expired_drawn_unpaused,
                                    expired_name_drawn_beside_live)}
