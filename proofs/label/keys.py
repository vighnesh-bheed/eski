import fnmatch
import re

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

    def inuse_text(self, lab):
        return inuse(lab)

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
                    return self.inuse_text(self.inuse_label(d, lab, name))
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
                return self.inuse_text(o.label)
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


OWNER_IDS = ['u1', 'u2', 'u3']
TOP_LABEL = (len(LEVELS) - 1, (1 << len(COMPS)) - 1, 0)
LOGINS = {'any': True, 'op': True, 'plain': False, 'fx': True}
OWNER_NOTES = ('own_exact', 'shared_exact', 'shared_exact_over_own', 'own_before_shared', 'shared_over_own',
               'own_over_shared', 'other_owner_present', 'own_tie_by_age', 'inuse_own', 'inuse_shared',
               'create_only_visible', 'foreign_read', 'scan_phase0', 'scan_phase1', 'scan_skip_own_list',
               'ever_kept_empty', 'renamed', 'copied_shared', 'moved', 'declassified',
               'declassify_target_sees', 'forgot', 'flush_everything', 'flush_user_label', 'flush_user_all',
               'flush_shared_label', 'flush_shared_all', 'flush_named_multi', 'flush_unnamed_multi')


def scope_text(scope):
    lab, o = scope
    return text(lab) + (' SHARED' if o is None else ' OWNER ' + o)


def osees(r, d):
    return sees(r[0], d[0]) and (d[1] is None or d[1] == r[1])


class OKeys(Keys):
    def __init__(self):
        super().__init__(True)
        self.ever = [dict() for _ in range(DBS)]
        self.login = 'any'
        self.tx = None
        self.quotas = set()

    def sees(self, r, d):
        return osees(r, d)

    def inuse_text(self, scope):
        return f'-INUSE name in use at {scope_text(scope)}^'

    def okey(self, reader, c):
        return rank(c.label[0]), int(reader[1] is not None and c.label[1] == reader[1])

    def other(self, d, W, name):
        cs = self.copies(d, name)
        if W[1] is not None:
            for c in cs:
                if c.label == (W[0], None):
                    return c
        best = None
        for c in cs:
            if c.label[0] == W[0] or not self.sees(W, c.label):
                continue
            if best is None or self.okey(W, c) > self.okey(W, best):
                best = c
        return best

    def resolve(self, d, W, name):
        o = self.own(d, W, name)
        if o is not None:
            return o
        return self.other(d, W, name)

    def own_resolve(self, d, W, name):
        o = self.own(d, W, name)
        if o is not None:
            return o
        best = None
        for c in self.copies(d, name):
            if c.label[1] != W[1] or c.label[0] == W[0] or not sees(W[0], c.label[0]):
                continue
            if best is None or rank(c.label[0]) > rank(best.label[0]):
                best = c
        return best

    def shared_resolve(self, d, W, name):
        best = None
        for c in self.copies(d, name):
            if c.label[1] is not None or not sees(W[0], c.label[0]):
                continue
            if c.label[0] == W[0]:
                return c
            if best is None or rank(c.label[0]) > rank(best.label[0]):
                best = c
        return best

    def survey(self, d, W, name):
        cs = self.copies(d, name)
        if any(c.label[1] is not None and c.label[1] != W[1] for c in cs):
            self.note('other_owner_present')
        if self.own(d, W, name) is not None:
            if W[1] is not None:
                self.note('own_exact')
            return
        vis = [c for c in cs if c.label[0] != W[0] and self.sees(W, c.label)]
        if W[1] is not None and any(c.label == (W[0], None) for c in cs):
            self.note('shared_exact')
            if any(c.label[1] == W[1] and rank(c.label[0]) > rank(W[0]) for c in vis):
                self.note('shared_exact_over_own')
            return
        if not vis or W[1] is None:
            return
        top = max(rank(c.label[0]) for c in vis)
        at = [c for c in vis if rank(c.label[0]) == top]
        owners = {c.label[1] for c in at}
        if W[1] in owners and None in owners:
            self.note('own_before_shared')
        elif None in owners and any(c.label[1] == W[1] for c in vis):
            self.note('shared_over_own')
        elif W[1] in owners and any(c.label[1] is None for c in vis):
            self.note('own_over_shared')
        if sum(1 for c in at if c.label[1] == W[1]) > 1:
            self.note('own_tie_by_age')

    def create(self, d, W, name, c):
        self.events.append(('A', d, name, W))
        self.names[d].setdefault(name, []).append(c)
        if W[1] is None:
            self.ordered[d].add(W[0])
        else:
            self.ever_add(d, W)
        if len(self.names[d][name]) > 1:
            self.note('copies_held')

    def ever_add(self, d, W):
        labs = self.ever[d].setdefault(W[1], [])
        if W[0] not in labs:
            labs.append(W[0])

    def vadd(self, d, W):
        if W[1] is None:
            self.ordered[d].add(W[0])
        else:
            self.ever_add(d, W)

    def decl_element(self, d, W, target, ok):
        if W[1] is None:
            if ok:
                self.ordered[d].add(target)
            return
        self.ever_add(d, W)
        if ok:
            self.ever_add(d, (target, W[1]))

    def copy_refused(self, d, W, dest):
        if W[1] is not None:
            self.ever_add(dest, W)

    def tidy(self):
        for d in range(DBS):
            for o, labs in self.ever[d].items():
                held = {c.label[0] for cs in self.names[d].values() for c in cs if c.label[1] == o}
                if any(lab not in held for lab in labs):
                    self.note('ever_kept_empty')
                    return

    def own_parts(self, d, W):
        return self.part_order([p for p in self.ever[d].get(W[1], []) if sees(W[0], p)]) if W[1] is not None else []

    def shared_parts(self, d, W):
        return self.part_order([p for p in self.ordered[d] if sees(W[0], p)])

    def has_own(self, d, W, name):
        return any(c.label[1] == W[1] and sees(W[0], c.label[0]) for c in self.copies(d, name))

    def c_labelof(self, d, W, k):
        c = self.find(d, W, k)
        return NULL if c is None else bulk(scope_text(c.label))

    def scan_names(self, d, W, phase, k, pat):
        out = set()
        if phase == 0:
            chosen = set(self.own_parts(d, W)[k:])
            for n in self.names[d]:
                c = self.own_resolve(d, W, n)
                if c is not None and c.label[1] == W[1] and c.label[0] in chosen:
                    out.add(n)
            k = 0
        chosen = set(self.shared_parts(d, W)[k:])
        for n in self.names[d]:
            if W[1] is not None and self.has_own(d, W, n):
                continue
            c = self.shared_resolve(d, W, n)
            if c is not None and c.label[0] in chosen:
                out.add(n)
        return sorted(n for n in out if fnmatch.fnmatchcase(n, pat))

    def c_scan(self, d, W, cursor, *opts):
        pat = opts[opts.index('MATCH') + 1] if 'MATCH' in opts else '*'
        cur = int(cursor)
        if W[1] is None:
            names = self.scan_names(d, W, 1, cur >> SCAN_SHIFT, pat)
        else:
            phase, k = cur & 1, (cur >> SCAN_SHIFT) & 0x7FFF
            if phase == 0 and k >= len(self.own_parts(d, W)):
                if k:
                    self.note('scan_skip_own_list')
                phase, k = 1, 0
            self.note('scan_phase0' if phase == 0 else 'scan_phase1')
            names = self.scan_names(d, W, phase, k, pat)
        return '0:' + f'{len(names)}' + ''.join(',' + n for n in names)

    def c_declassify(self, d, W, k, target):
        if target == W[0] or not sees(W[0], target):
            self.note('declassify_direction')
            return DIRECTION
        c = self.own(d, W, k)
        if c is None:
            return NO_KEY
        to = (target, W[1])
        seen = self.resolve(d, to, k)
        if seen is not None:
            self.note('declassify_target_sees')
            return self.inuse_text(seen.label)
        self.drop(d, W, k)
        self.create(d, to, k, c.clone(to))
        self.note('declassified')
        return OK

    def flush(self, W, named, all_dbs):
        user = W[1] is not None
        everything = W[0] == TOP_LABEL and LOGINS[self.login] and not user and not named
        top = W[0] == TOP_LABEL
        for d in range(DBS):
            if not all_dbs and d != self.db:
                continue
            for name in list(self.names[d]):
                cs = self.names[d][name]
                keep = [c for c in cs if not (everything or (c.label[1] == W[1] and (top or c.label[0] == W[0])))]
                for c in cs:
                    if c not in keep:
                        self.events.append(('D', d, name, c.label))
                cs[:] = keep
                if not cs:
                    del self.names[d][name]
        if everything:
            self.note('flush_everything')
        else:
            self.note(('flush_user_' if user else 'flush_shared_') + ('all' if top else 'label'))
        return OK

    def c_flushdb(self, d, W, *opts, named=True):
        return self.flush(W, named, False)

    def c_flushall(self, d, W, *opts, named=True):
        return self.flush(W, named, True)

    def c_forget(self, d, W, o):
        n = 0
        for dd in range(DBS):
            self.ever[dd].pop(o, None)
            for name in list(self.names[dd]):
                cs = self.names[dd][name]
                gone = [c for c in cs if c.label[1] == o]
                n += len(gone)
                for c in gone:
                    self.events.append(('D', dd, name, c.label))
                cs[:] = [c for c in cs if c.label[1] != o]
                if not cs:
                    del self.names[dd][name]
        self.note('forgot')
        return re.compile(re.escape(f'E|*6^$4^keys^:{n}^$8^elements^:0^$5^bytes^:') + r'\d+\^')

    def c_config(self, d, W, *args):
        return OK

    def c_lquota(self, d, W, marking, limit):
        if limit == '0':
            self.quotas.discard(marking)
        else:
            self.quotas.add(marking)
        return OK

    def conflict_copy(self, d, W, name):
        return self.other(d, W, name)

    def write_cmd(self, cmd):
        return cmd in WRITES or cmd in ('MSET', 'FLUSHDB', 'FLUSHALL')

    def orun(self, W, cmd, args, named):
        d = self.db
        if cmd in ('FLUSHDB', 'FLUSHALL'):
            if W[1] is not None:
                self.ever_add(d, W)
            out = getattr(self, 'c_' + cmd.lower())(d, W, *args, named=named)
            self.tidy()
            return out
        for name, creates_only in self.writes(cmd, args):
            if self.own(d, W, name) is not None:
                continue
            o = self.conflict_copy(d, W, name)
            if o is not None:
                if creates_only:
                    self.note('create_only_visible')
                    continue
                self.note('inuse_shared' if o.label[1] is None else 'inuse_own')
                return self.inuse_text(o.label)
        if W[1] is not None and self.write_cmd(cmd):
            self.ever_add(d, W)
        if cmd == 'COPY':
            src = self.find(d, W, args[0])
            if src is not None and src.label[1] is None and W[1] is not None:
                self.note('copied_shared')
        out = getattr(self, 'c_' + cmd.lower())(d, W, *args)
        self.tidy()
        return out


def owner_words(scope, form):
    lab, o = scope
    if form == 'o':
        return ['OWNER', o]
    if form == 's':
        return ['SHARED']
    return []


def default_form(scope):
    return 'o' if scope[1] is not None else 's'


def owner_argv(cmd, args):
    if cmd == 'FORGET':
        return ['OWNERS', 'FORGET', args[0]]
    if cmd == 'QUOTA':
        return ['OWNERS', 'QUOTA', args[0], 'LIMIT', str(args[1])]
    if cmd == 'RAWSCAN':
        return ['SCAN'] + list(args)
    if cmd == 'RAWRANDOM':
        return ['RANDOMKEY']
    if cmd == 'INFOKS':
        return ['INFO', 'keyspace']
    if cmd == 'FREQ':
        return ['OBJECT', 'FREQ'] + list(args)
    if cmd == 'LQUOTA':
        return ['LABEL', 'QUOTA', args[0], 'LIMIT', args[1]]
    return vector_argv(cmd, args)


def vector_argv(cmd, args):
    if cmd == 'XVADD':
        return ['VADD', args[0], 'VALUES', '2', '1', '-1', args[1]]
    if cmd == 'XDECL':
        return ['LABEL', 'DECLASSIFY', args[0], text(args[1]), 'ELEMENT', args[2]]
    if cmd == 'XVRAND':
        return ['VRANDMEMBER', args[0], args[1]]
    if cmd == 'XVCARD':
        return ['VCARD', args[0]]
    if cmd == 'XCOPY':
        return ['COPY', args[0], args[1], 'DB', str(args[2])]
    return argv(cmd, args)


VADDED = 'E|:1^'
DECL_REFUSED = re.compile(r'E\|-(ERR element not found in set|INUSE element in use at [^^]*)\^')
VSET_COPY_REFUSED = 'E|-ERR not supported for this module key^'
PARTITION_LIMIT = '-ERR label partition limit reached^'
OWNER_RAW = ('RAWSCAN', 'RAWRANDOM', 'INFOKS', 'FREQ', 'WATCH', 'MULTI', 'EXEC', 'QEXISTS', 'QUOTA', 'NOTES', 'XVRAND',
             'XVCARD')
OWNER_KINDS = {'KEYS': 'N', 'SCAN': 'C'}


def owner_line(item):
    scope, cmd, args, form = item
    if cmd == 'T':
        return f'T {args[0]}'
    if cmd == 'U':
        return f'U {args[0]}'
    if cmd == 'NOTES':
        return 'Q'
    if cmd == 'QEXISTS':
        cmd = 'EXISTS'
    words = owner_argv(cmd, args)
    head = ['LABEL', 'AS', text(scope[0])] + owner_words(scope, form)
    kind = 'W' if cmd in ('SESSION', 'PSUBSCRIBE') else OWNER_KINDS.get(cmd, 'E')
    if cmd == 'SESSION':
        return 'W ' + ' '.join(w.encode().hex() for w in ['LABEL', 'SESSION', text(scope[0])])
    if cmd == 'PSUBSCRIBE':
        head = ['LABEL', 'AS'] + (['OWNER', scope[1]] if scope[1] is not None else ['SHARED'])
    return kind + ' ' + ' '.join(w.encode().hex() if w else '-' for w in head + words)


def oexpected(m, item):
    scope, cmd, args, form = item
    if cmd == 'T':
        m.now = int(args[0])
        return f'T|{m.now}'
    if cmd == 'U':
        m.login = args[0]
        return f'U|{args[0]}'
    if cmd == 'XVADD':
        m.vadd(m.db, scope)
        return VADDED
    if cmd == 'XDECL':
        ok = args[3] == 'ok'
        m.decl_element(m.db, scope, args[1], ok)
        return 'E|' + OK if ok else DECL_REFUSED
    if cmd == 'XCOPY':
        m.copy_refused(m.db, scope, int(args[2]))
        return VSET_COPY_REFUSED
    if cmd in OWNER_RAW or cmd in ('SESSION', 'PSUBSCRIBE'):
        return None
    named = form in ('o', 's')
    if cmd == 'SELECT':
        m.db = int(args[0])
        return 'E|' + OK
    if cmd == 'FORGET':
        return m.c_forget(m.db, scope, args[0])
    out = m.orun(scope, cmd, args, named)
    if isinstance(out, set):
        return {'E|' + x for x in out}
    if cmd in OWNER_KINDS:
        return OWNER_KINDS[cmd] + '|' + out
    return 'E|' + out


def osimulate(items, mutant=None):
    m = OKeys()
    if mutant:
        mutant(m)
    rows = [oexpected(m, it) for it in items]
    return rows, m


def owner_scheme_line(seed):
    return f'S {",".join(LEVELS)} {",".join(COMPS)} {",".join(TRUSTS)} {seed} 1 1'


def pick_owner(rng, weights=(4, 4, 2, 1)):
    return rng.choices([None] + OWNER_IDS, weights=weights)[0]


def owner_write(rng, scope, labs, names):
    cmd, args = write_command(rng, scope[0], labs, names)
    return cmd, args


def owner_read(rng, scope, names, shared_parts=4):
    cmd, args = read_command(rng, names)
    if cmd == 'SCAN':
        k = int(args[0]) >> SCAN_SHIFT
        if scope[1] is not None:
            args = (str((k << SCAN_SHIFT) | rng.randrange(2)),) + args[1:]
    return cmd, args


CORNER = [(1, 0, 0), (1, 0, 1), (0, 0, 1), (2, 1, 0), (2, 1, 1)]


def owner_session_labels(rng, number):
    if number % 4 == 3:
        return list(TIES)
    if number % 4 == 2:
        return list(CORNER)
    return rng.sample(all_labels(), rng.randrange(3, 8))


def owner_session(rng, number, ops):
    labs = owner_session_labels(rng, number)
    out, now, probes = [], NOW, 0
    owners = [None, 'u1', 'u2'] if number % 3 else [None, 'u1', 'u2', 'u3']

    def at(lab, o):
        return (lab, o)

    if number % 3 == 0:
        first = rng.choice(labs)
        out += [((first, 'u2'), 'SET', (f'o{number}', 'x'), 'o'), ((TOP_LABEL, 'u1'), 'RANDOMKEY', (), 'o'),
                ((TOP_LABEL, 'u3'), 'DBSIZE', (), 'o'), ((TOP_LABEL, 'u1'), 'SCAN', ('0', 'COUNT', '1000'), 'o')]
    for _ in range(ops):
        r = rng.randrange(100)
        lab = rng.choice(labs)
        o = rng.choice(owners)
        scope = at(lab, o)
        if r < 3:
            now += 1000 * rng.randint(1, 5)
            out.append((None, 'T', (now,), ''))
        elif r < 12:
            name = rng.choice(NAMES)
            group = rng.sample(labs, min(len(labs), rng.randint(1, 3)))
            group.sort(key=lambda x: -reach(x))
            who = [None, rng.choice(owners[1:])]
            for x in group:
                for w in who:
                    if rng.randrange(3):
                        cmd = rng.choice(['SET', 'SET', 'HSET', 'RPUSH'])
                        out.append((at(x, w), cmd, (name, 'f', 'b') if cmd == 'HSET' else (name, 'b'), default_form(at(x, w))))
            for _ in range(rng.randint(2, 4)):
                reader = at(rng.choice(labs), rng.choice(owners))
                cmd = rng.choice(['GET', 'LABELOF', 'LABELOF', 'TYPE', 'EXISTS', 'DBSIZE'])
                out.append((reader, cmd, () if cmd == 'DBSIZE' else (name,), default_form(reader)))
        elif r < 15:
            x = rng.choice(labs)
            name = f'e{number}_{probes}'
            probes += 1
            out += [(at(x, o), 'SET', (name, 'e'), default_form(at(x, o))), (at(x, o), 'DEL', (name,), default_form(at(x, o)))]
            for k in range(0, 3):
                reader = at(rng.choice(labs), o)
                cur = (k << SCAN_SHIFT) | (rng.randrange(2) if o is not None else 0)
                out.append((reader, 'SCAN', (str(cur), 'COUNT', '1000'), default_form(reader)))
        elif r < 17:
            ys = [(y, x) for y in labs for x in labs if y != x and sees(y, x)]
            if ys:
                y, x = rng.choice(ys)
                name = f'm{number}_{probes}'
                probes += 1
                out += [(at(x, o), 'SELECT', ('1',), default_form(at(x, o))), (at(x, o), 'SET', (name, 'one'), default_form(at(x, o))),
                        (at(x, o), 'SELECT', ('0',), default_form(at(x, o))), (at(y, o), 'SET', (name, 'zero'), default_form(at(y, o))),
                        (at(y, o), 'MOVE', (name, '1'), default_form(at(y, o))), (at(y, o), 'GET', (name,), default_form(at(y, o))),
                        (at(y, o), 'SELECT', ('1',), default_form(at(y, o))), (at(y, o), 'LABELOF', (name,), default_form(at(y, o))),
                        (at(y, o), 'GET', (name,), default_form(at(y, o))), (at(y, o), 'SELECT', ('0',), default_form(at(y, o)))]
        elif r < 19:
            name = f'c{number}_{probes}'
            probes += 1
            src = at(rng.choice(labs), None)
            dst = at(rng.choice([x for x in labs if sees(x, src[0])] or [src[0]]), rng.choice(owners[1:]))
            out += [(src, 'SET', (name, 's'), 's'), (dst, 'COPY', (name, name + 'x'), 'o'), (dst, 'GET', (name + 'x',), 'o'),
                    (dst, 'LABELOF', (name + 'x',), 'o'), (dst, 'LABELOF', (name,), 'o')]
        elif r < 20 and number % 5 == 1:
            victim = rng.choice(OWNER_IDS)
            out.append(((TOP_LABEL, None), 'FORGET', (victim,), 's'))
            for _ in range(2):
                reader = at(rng.choice(labs), victim)
                cmd = rng.choice(['DBSIZE', 'SCAN', 'KEYS'])
                out.append((reader, cmd, {'DBSIZE': (), 'SCAN': ('0', 'COUNT', '1000'), 'KEYS': ('*',)}[cmd], default_form(reader)))
        elif r < 21:
            scope = at(lab, rng.choice(owners))
            out.append((scope, rng.choice(['FLUSHDB', 'FLUSHDB', 'FLUSHALL']), (), default_form(scope)))
        elif r < 24 and number % 4 == 3:
            name = f't{number}_{probes}'
            probes += 1
            u = rng.choice(owners[1:])
            first, second = rng.sample([(1, 1, 0), (1, 2, 0)], 2)
            out += [((first, u), 'SET', (name, 'x'), 'o'), ((second, u), 'SET', (name, 'y'), 'o')]
            if rng.randrange(2):
                out.append(((rng.choice([(1, 1, 0), (1, 2, 0)]), None), 'SET', (name, 's'), 's'))
            out += [(((2, 3, 0), u), 'LABELOF', (name,), 'o'), (((2, 3, 0), u), 'GET', (name,), 'o'),
                    (((2, 3, 0), None), 'LABELOF', (name,), 's')]
        elif r < 55:
            cmd, args = owner_write(rng, scope, labs, NAMES)
            out.append((scope, cmd, args, default_form(scope)))
        else:
            cmd, args = owner_read(rng, scope, NAMES)
            out.append((scope, cmd, args, default_form(scope)))
    return out, labs


def owner_row_kind(cmd):
    if cmd == 'LABELOF':
        return 'PO'
    if cmd in WRITES or cmd in ('FLUSHDB', 'FLUSHALL', 'FORGET'):
        return 'PW'
    return 'PR'


def owner_corpus(rng, seed, sessions, ops):
    out = []
    for number in range(sessions):
        items, labs = owner_session(rng, number, rng.randrange(ops // 2, ops))
        rows, m = osimulate(items)
        lines = [owner_scheme_line(seed)] + [owner_line(it) for it in items]
        out.append((lines, rows, items, m.notes))
    return out


def tx_line(item):
    scope, cmd, args, form = item
    if cmd in ('TXMULTI', 'TXEXEC'):
        return owner_line((scope, cmd[2:], (), form))
    if cmd == 'TXQ':
        return owner_line((scope, args[0], args[1], form))
    return owner_line(item)


def fexpected(m, item):
    scope, cmd, args, form = item
    named = form in ('o', 's')
    if cmd == 'TXMULTI':
        m.tx = {'scope': scope, 'named': named, 'queue': []}
        return 'E|' + OK
    if cmd == 'TXQ':
        if named:
            m.tx['named'] = True
        m.tx['queue'].append(args)
        return 'E|+QUEUED^'
    if cmd == 'TXEXEC':
        tx, m.tx = m.tx, None
        named = named or tx['named']
        m.note('flush_named_multi' if named else 'flush_unnamed_multi')
        replies = [m.orun(tx['scope'], c, a, named) for c, a in tx['queue']]
        return 'E|' + f'*{len(replies)}^' + ''.join(replies)
    return oexpected(m, item)


FLUSH_LABS = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (2, 1, 0), (1, 0, 1), TOP_LABEL]
FLUSH_OWNERS = [None, 'u1', 'u2', 'fx']


def flush_case(rng, number):
    out = []
    names = [f'f{number}_{i}' for i in range(rng.randint(3, 6))]
    for d in (1, 0):
        if d:
            out.append(((BOTTOM, None), 'SELECT', ('1',), 's'))
        for name in names:
            for _ in range(rng.randint(1, 4)):
                scope = (rng.choice(FLUSH_LABS), rng.choice(FLUSH_OWNERS))
                cmd = rng.choice(['SET', 'SET', 'RPUSH'])
                out.append((scope, cmd, (name, 'v'), default_form(scope)))
        if d:
            out.append(((BOTTOM, None), 'SELECT', ('0',), 's'))
    login = rng.choice(['any', 'any', 'op', 'op', 'plain', 'fx'])
    lab = TOP_LABEL if rng.randrange(3) else rng.choice(FLUSH_LABS[:-1])
    if login == 'any':
        owner = rng.choice(FLUSH_OWNERS)
        form = default_form((lab, owner))
    elif login == 'fx':
        owner, form = 'fx', rng.choice(['', 'o'])
    else:
        owner, form = None, rng.choice(['', '', 's'])
    scope = (lab, owner)
    cmd = rng.choice(['FLUSHDB', 'FLUSHALL'])
    out.append((None, 'U', (login,), ''))
    if login == 'op' and rng.randrange(2):
        out.append((scope, 'TXMULTI', (), form))
        if rng.randrange(2):
            out.append((scope, 'TXQ', ('EXISTS', (names[0],)), 's'))
        out.append((scope, 'TXQ', (cmd, ()), ''))
        out.append((scope, 'TXQ', ('DBSIZE', ()), ''))
        out.append((scope, 'TXEXEC', (), ''))
    else:
        out.append((scope, cmd, (), form))
    out.append((None, 'U', ('any',), ''))
    for d in (0, 1):
        if d:
            out.append(((BOTTOM, None), 'SELECT', ('1',), 's'))
        for o in FLUSH_OWNERS:
            probe = (TOP_LABEL, o)
            out.append((probe, 'KEYS', ('*',), default_form(probe)))
            out.append((probe, 'DBSIZE', (), default_form(probe)))
        for name in names:
            for o in FLUSH_OWNERS:
                probe = (rng.choice(FLUSH_LABS), o)
                out.append((probe, 'LABELOF', (name,), default_form(probe)))
        if d:
            out.append(((BOTTOM, None), 'SELECT', ('0',), 's'))
    return out


def flush_corpus(rng, seed, cases):
    items = []
    for n in range(cases):
        items += flush_case(rng, n)
    m = OKeys()
    rows = [fexpected(m, it) for it in items]
    lines = [owner_scheme_line(seed)] + [tx_line(it) for it in items]
    return lines, rows, items, m.notes


def forget_case(rng, number):
    labs = rng.sample(all_labels(), rng.randrange(3, 6))
    names = [f'g{number}_{i}' for i in range(rng.randint(3, 6))]
    setup = []
    for name in names:
        for _ in range(rng.randint(1, 4)):
            scope = (rng.choice(labs), rng.choice([None, 'u1', 'u1', 'u2']))
            setup.append((scope, rng.choice(['SET', 'HSET', 'SADD']), (name, 'v') if True else (), default_form(scope)))
    setup = [(s, c, (a[0], 'f', 'v') if c == 'HSET' else a, f) for s, c, a, f in setup]
    probes = []
    for lab in labs:
        picks = [rng.choice(['GET', 'TYPE', 'LABELOF', 'EXISTS']) for _ in names]
        for o in (None, 'u1', 'u2'):
            sc = (lab, o)
            probes.append((sc, 'DBSIZE', (), default_form(sc)))
            probes.append((sc, 'KEYS', ('*',), default_form(sc)))
            probes.append((sc, 'SCAN', ('0', 'COUNT', '1000'), default_form(sc)))
            for name, cmd in zip(names, picks):
                probes.append((sc, cmd, (name,), default_form(sc)))
    forget = [((TOP_LABEL, None), 'FORGET', ('u1',), 's')]
    return setup, probes, forget


def forget_corpus(rng, seed, cases):
    items, spans = [], []
    for n in range(cases):
        setup, probes, forget = forget_case(rng, n)
        start = len(items)
        items += setup
        a = len(items)
        items += probes
        b = len(items)
        items += forget
        c = len(items)
        items += probes
        spans.append((a, b, c, len(probes)))
        items += [(None, 'U', ('op',), ''), ((TOP_LABEL, None), 'FLUSHALL', (), ''), (None, 'U', ('any',), '')]
    m = OKeys()
    rows = [oexpected(m, it) for it in items]
    lines = [owner_scheme_line(seed)] + [owner_line(it) for it in items]
    return lines, rows, items, spans, m.notes


def observer_scan(rng, scope):
    k = rng.randrange(3)
    ph = rng.randrange(2) if scope[1] is not None else 0
    return str((k << SCAN_SHIFT) | ph)


def observer_command(rng, scope, lfu, pending):
    r = rng.randrange(100)
    if r < 38:
        cmd, args = write_command(rng, scope[0], [scope[0]], NAMES)
        if cmd == 'DECLASSIFY':
            cmd, args = 'SET', (args[0], 'd')
        return [(scope, cmd, args, default_form(scope))]
    if r < 70:
        cmd, args = read_command(rng, NAMES)
        if cmd == 'SCAN':
            args = (observer_scan(rng, scope),) + args[1:]
        return [(scope, cmd, args, default_form(scope))]
    if r < 80:
        k = rng.randrange(4)
        if k == 0:
            return [(scope, 'RAWSCAN', (observer_scan(rng, scope), 'COUNT', str(rng.choice([1, 2, 3]))), default_form(scope))]
        if k == 1:
            return [(scope, 'RAWRANDOM', (), default_form(scope))]
        if k == 2:
            return [(scope, 'INFOKS', (), default_form(scope))]
        return [(scope, 'FREQ' if lfu else 'IDLETIME', (rng.choice(NAMES),), default_form(scope))]
    if r < 88:
        if pending[0] is None:
            pending[0] = scope
            return [(scope, 'WATCH', (rng.choice(NAMES),), default_form(scope))]
        w = pending[0]
        pending[0] = None
        return [(w, 'MULTI', (), default_form(w)), (w, 'QEXISTS', (rng.choice(NAMES),), default_form(w)),
                (w, 'EXEC', (), default_form(w))]
    if r < 94:
        return [(None, 'NOTES', (), '')]
    return [(scope, 'DBSIZE', (), default_form(scope))]


def hidden_command(rng, scope, quota):
    o = scope[1]
    other_user = o in ('u2', 'u3')
    r = rng.randrange(100)
    if r < 52:
        cmd, args = write_command(rng, scope[0], [scope[0]], NAMES)
        if cmd == 'DECLASSIFY' and not other_user:
            cmd, args = 'SET', (args[0], 'h')
        if cmd == 'DECLASSIFY':
            below = [t for t in all_labels() if t != scope[0] and sees(scope[0], t)]
            if not below:
                cmd, args = 'SET', (args[0], 'h')
            else:
                args = (args[0], rng.choice(below))
        return [(scope, cmd, args, default_form(scope))]
    if r < 64:
        cmd, args = read_command(rng, NAMES)
        if cmd == 'SCAN':
            args = (observer_scan(rng, scope),) + args[1:]
        return [(scope, cmd, args, default_form(scope))]
    if r < 70:
        if r < 68:
            return [(scope, 'RAWRANDOM', (), default_form(scope))]
        return [(scope, 'RAWSCAN', ('0', 'COUNT', '2'), default_form(scope))]
    if r < 76:
        if scope[0] == TOP_LABEL and not other_user:
            return [(scope, 'DEL', (rng.choice(NAMES),), default_form(scope))]
        return [(scope, 'FLUSHDB', (), default_form(scope))]
    if r < 80 and other_user:
        top = (TOP_LABEL, o)
        return [(top, rng.choice(['FLUSHDB', 'FLUSHALL']), (), 'o')]
    if r < 84 and other_user:
        return [((TOP_LABEL, None), 'FORGET', (o,), 's')]
    if r < 88 and other_user and quota:
        return [((TOP_LABEL, None), 'QUOTA', (o, rng.choice([200, 600, 1500])), 's')] + \
            [(scope, 'SET', (rng.choice(NAMES), 'q' * rng.choice([8, 40, 200])), 'o') for _ in range(rng.randint(1, 3))]
    if r < 94:
        return [(scope, 'EXPIRE', (rng.choice(NAMES), str(rng.choice([50000, 90000]))), default_form(scope))]
    a, b = rng.sample(NAMES, 2)
    return [(scope, rng.choice(['RENAME', 'COPY']), (a, b), default_form(scope))]


def owner_twin_case(rng, number, ops, same_owner):
    labs = rng.sample(all_labels(), rng.randrange(3, 7))
    if same_owner:
        labs = rng.sample([lab for lab in all_labels() if lab != TOP_LABEL], rng.randrange(2, 5))
    la, lb = rng.sample(labs, 2) if len(labs) > 1 else (labs[0], labs[0])
    lc = rng.choice(labs)
    observers = [(la, 'u1'), (lb, 'u1'), (lc, None)]
    lfu = number % 3 == 2 and not same_owner
    watcher = rng.choice(observers)
    setup = [((TOP_LABEL, None), 'CONFIG', ('SET', 'notify-keyspace-events', 'KEA'), 's')]
    if lfu:
        setup.append(((TOP_LABEL, None), 'CONFIG', ('SET', 'maxmemory-policy', 'allkeys-lfu'), 's'))
    setup += [(watcher, 'SESSION', (), ''), (watcher, 'PSUBSCRIBE', ('__key*__:*',), '')]
    base, pending = [], [None]
    for _ in range(ops):
        base += observer_command(rng, rng.choice(observers), lfu, pending)
    if pending[0] is not None:
        w = pending[0]
        base += [(w, 'MULTI', (), default_form(w)), (w, 'QEXISTS', ('k0',), default_form(w)), (w, 'EXEC', (), default_form(w))]
    base.append((None, 'NOTES', (), ''))
    if same_owner:
        hidden_scopes = [(lab, 'u1') for lab in all_labels() if not any(osees(w, (lab, 'u1')) for w in observers)]
        if not hidden_scopes:
            return None
    else:
        hidden_scopes = [(lab, o) for lab in all_labels() for o in (None, 'u2', 'u3')
                         if not any(osees(w, (lab, o)) for w in observers)]
    marker = None
    seen = [lab for lab in all_labels() if sees(la, lab)]
    if not same_owner:
        free, inside = [], False
        for i, c in enumerate(base):
            if not inside:
                free.append(i)
            inside = (inside or c[1] == 'MULTI') and c[1] != 'EXEC'
        at = rng.choice(free)
        marker = ((rng.choice(seen), None), 'SET', (f'z{number}', 'v'), 's')
        base[at:at] = [marker, ((la, 'u1'), 'DBSIZE', (), 'o')]
    twin, inside = [], False
    for c in base:
        while not inside and rng.randrange(3) == 0:
            scope = rng.choice(hidden_scopes)
            for h in hidden_command(rng, scope, not same_owner):
                if same_owner and h[1] in ('RAWRANDOM', 'RAWSCAN', 'FORGET', 'QUOTA', 'FLUSHALL'):
                    continue
                twin.append(h + ('hidden',))
        twin.append(c)
        if c[1] == 'MULTI':
            inside = True
        elif c[1] == 'EXEC':
            inside = False
    return setup, base, twin, observers, marker


def owner_twin_rows(setup, items, apply_hidden=False, mutant=None):
    m = OKeys()
    if mutant:
        mutant(m)
    rows = []
    for it in setup + items:
        hidden = len(it) > 4
        item = it[:4]
        if hidden and not apply_hidden:
            rows.append(None)
            continue
        r = oexpected(m, item)
        rows.append(None if hidden and item[1] in ('FORGET',) else r)
    return rows


def owner_twin_lines(seed, setup, items):
    return [owner_scheme_line(seed)] + [owner_line(it[:4]) for it in setup + items]


def owner_twin_corpus(rng, seed, pairs, ops=(40, 90), same_owner=False):
    out = []
    for n in range(pairs):
        case = owner_twin_case(rng, 3000 + n + (500 if same_owner else 0), rng.randrange(*ops), same_owner)
        if case is None:
            continue
        out.append(case)
    return out


def label_twin_case(rng, number, ops):
    tops = [lab for lab in all_labels() if lab != TOP_LABEL and any(t != lab and sees(lab, t) for t in all_labels())]
    la = rng.choice(tops)
    lw = rng.choice([t for t in all_labels() if t != la and sees(la, t)])
    hidden_labels = [t for t in all_labels() if not sees(la, t)]
    observers = [(la, 'u1'), (lw, 'u1'), (rng.choice([la, lw]), None)]
    setup = []
    base, pending = [], [None]
    for _ in range(ops):
        base += observer_command(rng, rng.choice(observers), False, pending)
    if pending[0] is not None:
        w = pending[0]
        base += [(w, 'MULTI', (), default_form(w)), (w, 'QEXISTS', ('k0',), default_form(w)), (w, 'EXEC', (), default_form(w))]
    block = [((la, 'u1'), 'FLUSHDB', (), 'o'), ((lw, 'u1'), 'FLUSHDB', (), 'o'), ((lw, 'u1'), 'SET', (f'w{number}', 'v'), 'o')]
    for k in range(1, 4):
        block.append(((la, 'u1'), 'SCAN', (str(k << SCAN_SHIFT), 'COUNT', '1000'), 'o'))
    block += [((la, 'u1'), 'RAWSCAN', ('0', 'COUNT', '1'), 'o'), ((la, 'u1'), 'DBSIZE', (), 'o'),
              ((la, 'u1'), 'KEYS', ('*',), 'o')]
    twin = []
    for c in base:
        twin.append(c)
    hidden = [((rng.choice(hidden_labels), 'u1'), 'SET', (f'h{number}_{i}', 'h'), 'o', 'hidden') for i in range(rng.randint(1, 3))]
    free, inside = [], False
    for i, c in enumerate(base):
        if not inside:
            free.append(i)
        inside = (inside or c[1] == 'MULTI') and c[1] != 'EXEC'
    free.append(len(base))
    at = rng.choice(free)
    twin = base[:at] + hidden + base[at:] + block
    return setup, base + block, twin, observers, None


def label_twin_corpus(rng, seed, cases, ops=(20, 50)):
    return [label_twin_case(rng, 4000 + n, rng.randrange(*ops)) for n in range(cases)]


def observer_base(rng, observers, ops):
    base, pending = [], [None]
    for _ in range(ops):
        base += observer_command(rng, rng.choice(observers), False, pending)
    if pending[0] is not None:
        w = pending[0]
        base += [(w, 'MULTI', (), default_form(w)), (w, 'QEXISTS', ('k0',), default_form(w)), (w, 'EXEC', (), default_form(w))]
    return base


def reader_probes(la):
    probes = [((la, 'u1'), 'SCAN', (str(k << SCAN_SHIFT), 'COUNT', '1000'), 'o') for k in range(1, 4)]
    return probes + [((la, 'u1'), 'RAWSCAN', ('0', 'COUNT', '1'), 'o'),
                     ((la, 'u1'), 'RAWSCAN', (str(1 << SCAN_SHIFT), 'COUNT', '1'), 'o'),
                     ((la, 'u1'), 'DBSIZE', (), 'o'), ((la, 'u1'), 'KEYS', ('*',), 'o')]


def stream_probes(number, at, reader):
    vr = f'vr{number}'
    out = [(at, 'XVADD', (vr, e), default_form(at)) for e in 'abcd']
    return out + [(reader, 'XVRAND', (vr, '-8'), default_form(reader)) for _ in range(2)]


def declassify_twin_case(rng, number, ops, element):
    tops = [lab for lab in all_labels() if lab != TOP_LABEL and sum(1 for t in all_labels() if sees(lab, t)) >= 3]
    la = rng.choice(tops)
    below = [t for t in all_labels() if t != la and sees(la, t)]
    lw = rng.choice(below)
    targets = [t for t in below if t != lw]
    tgt = rng.choice(targets)
    hidden_labels = [h for h in all_labels() if not sees(la, h) and sees(h, tgt)]
    if not hidden_labels:
        return None
    hl = rng.choice(hidden_labels)
    observers = [(la, 'u1'), (lw, 'u1'), (rng.choice([la, lw]), None)]
    base = observer_base(rng, observers, ops)
    dx = f'dx{number}'
    shared_at = rng.choice([t for t in all_labels() if sees(tgt, t)])
    base.append(((shared_at, None), 'SET', (dx, 'v'), 's'))
    lows = [x for x in all_labels() if sees(la, x) and x != tgt and part_key(x) > part_key(tgt)]
    if lows:
        base.append(((rng.choice(lows), 'u1'), 'SET', (f'lo{number}', 'v'), 'o'))
    scope = (hl, 'u1')
    vs = f'vs{number}'
    kind = 'key'
    if element:
        others = [h for h in all_labels() if h != hl and sees(hl, h) and not sees(la, h)]
        lows = [t for t in all_labels() if t != hl and sees(hl, t) and not sees(la, t)]
        kind = rng.choice(['missing', 'shared'] + (['other_own'] if others else []) + (['moved'] if lows else []))
        if kind == 'shared':
            base.append(((hl, None), 'XVADD', (vs, 's'), 's'))
        if kind == 'other_own':
            base.append(((rng.choice(others), 'u1'), 'XVADD', (vs, 'f'), 'o'))
        base.append((scope, 'XVADD', (vs, 'e'), 'o'))
        element_of = {'missing': 'nosuch', 'shared': 's', 'other_own': 'f', 'moved': 'e'}[kind]
        to = rng.choice(lows) if kind == 'moved' else tgt
        hidden = [(scope, 'XDECL', (vs, to, element_of, 'ok' if kind == 'moved' else 'refused'), 'o')]
    else:
        hidden = [(scope, 'DECLASSIFY', (f'missing{number}', tgt), 'o'),
                  (scope, 'SET', (dx, 'own'), 'o'), (scope, 'DECLASSIFY', (dx, tgt), 'o'),
                  (scope, 'DECLASSIFY', (dx, scope[0]), 'o')]
    hidden = [h + ('hidden',) for h in hidden]
    probes = reader_probes(la)
    witness = ()
    if element:
        probes += stream_probes(number, (shared_at, None), (tgt, 'u1'))
        probes.append(((tgt, 'u1'), 'XVCARD', (vs,), 'o'))
        if kind == 'moved':
            probes.append(((to, 'u1'), 'XVCARD', (vs,), 'o'))
            witness = (len(base) + len(probes) - 1,)
    return [], base + probes, base + hidden + probes, observers, (kind, witness)


def copy_twin_case(rng, number, ops):
    tops = [lab for lab in all_labels() if lab != TOP_LABEL and any(t != lab and sees(lab, t) for t in all_labels())]
    la = rng.choice(tops)
    lw = rng.choice([t for t in all_labels() if t != la and sees(la, t)])
    after = {h: [x for x in all_labels() if x != h and sees(h, x) and part_key(x) > part_key(h)] for h in all_labels()}
    hidden_labels = [t for t in all_labels() if not sees(la, t) and after[t]]
    if not hidden_labels:
        return None
    hl = rng.choice(hidden_labels)
    observers = [(la, 'u1'), (lw, 'u1'), (rng.choice([la, lw]), None)]
    base = observer_base(rng, observers, ops)
    scope = (hl, 'u1')
    vc = f'vc{number}'
    base += [((rng.choice(after[hl]), 'u1'), 'SET', (f'lo{number}', 'v'), 'o'),
             (scope, 'SELECT', ('1',), 'o'), (scope, 'XVADD', (vc, 'e'), 'o'), (scope, 'SELECT', ('0',), 'o')]
    hidden = [(scope, 'SELECT', ('1',), 'o'), (scope, 'XCOPY', (vc, rng.choice([vc, vc + 'd']), 0), 'o'),
              (scope, 'SELECT', ('0',), 'o')]
    hidden = [h + ('hidden',) for h in hidden]
    probes = reader_probes(la) + [((lw, 'u1'), 'SCAN', (str(1 << SCAN_SHIFT), 'COUNT', '1000'), 'o')]
    at = len(base) + len(probes)
    probes += [(scope, 'SCAN', (str(k << SCAN_SHIFT), 'COUNT', '1000'), 'o') for k in range(1, 6)]
    return [], base + probes, base + hidden + probes, observers, ('copy', tuple(range(at, at + 5)))


def copy_twin_corpus(rng, seed, cases, ops=(15, 35)):
    out, n = [], 0
    while len(out) < cases:
        case = copy_twin_case(rng, 6000 + n, rng.randrange(*ops))
        n += 1
        if case is not None:
            out.append(case)
    return out


def limit_scheme(seed, limit):
    return f'S {",".join(LEVELS)} {",".join(COMPS)} {",".join(TRUSTS)} {seed} 1 0 {limit}'


def limit_line(lab, cmd, args):
    words = ['LABEL', 'AS', text(lab)] + vector_argv(cmd, args)
    return KINDS.get(cmd, 'E') + ' ' + ' '.join(w.encode().hex() if w else '-' for w in words)


def limit_rows(items, limit, leak=False):
    parts, names, rows = set(), {}, []
    for lab, cmd, args in items:
        if cmd == 'XVADD':
            if lab != BOTTOM:
                parts.add(lab)
            names.setdefault(args[0], set()).add(lab)
            rows.append(VADDED)
        elif cmd == 'XDECL':
            if leak and args[1] != BOTTOM:
                parts.add(args[1])
            rows.append(DECL_REFUSED)
        elif cmd == 'SET':
            if lab != BOTTOM and lab not in parts:
                if len(parts) >= limit:
                    rows.append('E|' + PARTITION_LIMIT)
                    continue
                parts.add(lab)
            names.setdefault(args[0], set()).add(lab)
            rows.append('E|' + OK)
        elif cmd == 'XVRAND':
            rows.append(None)
        else:
            vis = sorted(n for n, ls in names.items() if any(sees(lab, x) for x in ls))
            listed = ','.join([str(len(vis))] + vis)
            rows.append({'DBSIZE': 'E|' + integer(len(vis)), 'KEYS': 'N|' + listed, 'SCAN': 'C|0:' + listed}[cmd])
    return rows


def limit_twin_case(rng, number):
    labs = [x for x in all_labels() if x != BOTTOM]
    while True:
        hl = rng.choice(labs)
        tgts = [x for x in labs if x != hl and sees(hl, x) and any(g != x and sees(x, g) for g in all_labels())]
        observers = [x for x in labs if not sees(x, hl)]
        if not tgts:
            continue
        tgt = rng.choice(tgts)
        grounds = [g for g in all_labels() if g != tgt and sees(tgt, g)]
        ground = BOTTOM if BOTTOM in grounds else rng.choice(grounds)
        vs = f'vs{number}'
        base, elem, kind = [], 'nosuch', 'missing'
        others = [h for h in all_labels() if h != hl and sees(hl, h) and not sees(tgt, h)]
        if others and rng.randrange(2):
            base.append((rng.choice(others), 'XVADD', (vs, 's')))
            elem, kind = 's', 'inuse'
        base.append((hl, 'XVADD', (vs, 'e')))
        writers = [x for x in observers if x != tgt]
        for i in range(rng.randint(0, 2)):
            base.append((rng.choice(writers), 'SET', (f'b{number}_{i}', 'v')))
        used = {x for x, _, _ in base if x != BOTTOM} | ({ground} - {BOTTOM})
        fresh = [x for x in writers if x not in used]
        if len(fresh) >= 3:
            break
    rng.shuffle(fresh)
    vr = f'vr{number}'
    tail = [(ground, 'XVADD', (vr, e)) for e in 'abcd'] + [(tgt, 'XVRAND', (vr, '-8')) for _ in range(2)]
    tail += [(x, 'SET', (f'f{number}_{i}', 'v')) for i, x in enumerate(fresh[:3])]
    for r in rng.sample(observers, 2):
        tail += [(r, 'SCAN', ('0', 'COUNT', '1000')), (r, 'DBSIZE', ()), (r, 'KEYS', ('*',))]
    hidden = [(hl, 'XDECL', (vs, tgt, elem, 'refused'))]
    return len(used) + 2, base + tail, base + hidden + tail, hl, kind


def limit_twin_corpus(rng, cases):
    return [limit_twin_case(rng, 7000 + n) for n in range(cases)]


def declassify_twin_corpus(rng, seed, cases, element, ops=(15, 35)):
    out = []
    n = 0
    while len(out) < cases:
        case = declassify_twin_case(rng, 5000 + n + (500 if element else 0), rng.randrange(*ops), element)
        n += 1
        if case is not None:
            out.append(case)
    return out


def quota_case(rng, number):
    lab = rng.choice([x for x in all_labels() if x != TOP_LABEL])
    names = [f'q{number}_{i}' for i in range(rng.randint(2, 4))]
    out = [((lab, None), 'SET', (n, 'v' * 64), 's') for n in names]
    out.append(((TOP_LABEL, None), 'LQUOTA', (text(lab), '1'), 's'))
    user = rng.choice(OWNER_IDS)
    for i in range(rng.randint(2, 5)):
        out.append(((lab, user), 'SET', (f'p{number}_{i}', 'w' * rng.choice([8, 64])), 'o'))
    out += [((lab, user), 'DBSIZE', (), 'o'), ((lab, user), 'KEYS', ('p*',), 'o')]
    out.append(((TOP_LABEL, None), 'LQUOTA', (text(lab), '0'), 's'))
    out.append((None, 'U', ('op',), ''))
    out.append(((TOP_LABEL, None), 'FLUSHALL', (), ''))
    out.append((None, 'U', ('any',), ''))
    return out


def quota_corpus(rng, seed, cases):
    items = []
    for n in range(cases):
        items += quota_case(rng, n)
    m = OKeys()
    rows = [oexpected(m, it) for it in items]
    lines = [owner_scheme_line(seed)] + [owner_line(it) for it in items]
    return lines, rows, items


def strip_suffix(row):
    row = re.sub(r'(-INUSE (?:name|element) in use at [^^]*?) SHARED\^', lambda m: m.group(1) + '^', row)
    def bulk_fix(m):
        body = m.group(2)
        return f'${len(body)}^{body}^'
    return re.sub(r'\$(\d+)\^([^^]*?) SHARED\^', bulk_fix, row)


def owner_p10_lines(seed, cmds, owner):
    out = [owner_scheme_line(seed)]
    for lab, cmd, args in cmds:
        if cmd == 'T':
            out.append(f'T {args[0]}')
            continue
        scope = (lab, owner)
        out.append(owner_line((scope, cmd, args, default_form(scope))))
    return out


def owner_resolution_trace(sessions):
    lines, rows = [], []
    for _, _, items, _ in sessions:
        m = OKeys()
        lines.append('PX')
        rows.append('PX')
        for item in items:
            oexpected(m, item)
            for kind, d, name, sc in m.events:
                lines.append(f'P{kind} {d} {name.encode().hex()} {ids(sc[0])} {sc[1].encode().hex() if sc[1] else "-"}')
                rows.append(f'P{kind}')
            m.events = []
            scope, cmd, args, _ = item
            if cmd == 'LABELOF':
                c = m.resolve(m.db, scope, args[0])
                lines.append(f'PQ {m.db} {ids(scope[0])} {scope[1].encode().hex() if scope[1] else "-"} {args[0].encode().hex()}')
                rows.append('PQ|' + (f'{ids(c.label[0])}:{c.label[1].encode().hex() if c.label[1] else "s"}' if c is not None else '-'))
    return lines, rows


def owner_mutants():
    def owner_check_dropped(m):
        original = m.orun

        def orun(W, cmd, args, named):
            if W[1] is not None and m.write_cmd(cmd):
                W = (W[0], None)
            return original(W, cmd, args, named)
        m.orun = orun

    def shared_hidden(m):
        m.sees = lambda r, d: sees(r[0], d[0]) and d[1] == r[1]

    def other_owner_visible(m):
        m.sees = lambda r, d: sees(r[0], d[0])

    def own_before_shared_reversed(m):
        m.okey = lambda reader, c: (rank(c.label[0]), int(c.label[1] is None))

    def inuse_names_other_owner(m):
        def conflict_copy(d, W, name):
            best = None
            for c in m.copies(d, name):
                if c.label == W or not sees(W[0], c.label[0]):
                    continue
                if best is None or rank(c.label[0]) > rank(best.label[0]):
                    best = c
            return best
        m.conflict_copy = conflict_copy

    def forget_leaves_copy(m):
        original = m.c_forget

        def c_forget(d, W, o):
            kept = None
            for dd in range(DBS):
                for name, cs in m.names[dd].items():
                    for c in cs:
                        if c.label[1] == o and kept is None:
                            kept = (dd, name, c)
            out = original(d, W, o)
            if kept is not None:
                dd, name, c = kept
                m.names[dd].setdefault(name, []).append(c)
            return out
        m.c_forget = c_forget

    def forget_touches_other_owner(m):
        original = m.c_forget

        def c_forget(d, W, o):
            out = original(d, W, o)
            for dd in range(DBS):
                for name in list(m.names[dd]):
                    cs = m.names[dd][name]
                    for c in cs:
                        if c.label[1] is not None and c.label[1] != o:
                            cs.remove(c)
                            if not cs:
                                del m.names[dd][name]
                            return out
            return out
        m.c_forget = c_forget

    def scan_counts_other_owner(m):
        def own_parts(d, W):
            if W[1] is None:
                return []
            labs = {lab for labs in m.ever[d].values() for lab in labs}
            return m.part_order([p for p in labs if sees(W[0], p)])
        m.own_parts = own_parts

    def dbsize_counts_other_owner(m):
        m.c_dbsize = lambda d, W: integer(len({n for n, cs in m.names[d].items() if any(sees(W[0], c.label[0]) for c in cs)}))

    def randomkey_other_owner(m):
        def c_randomkey(d, W):
            names = sorted({n for n, cs in m.names[d].items() if any(sees(W[0], c.label[0]) for c in cs)})
            return {NULL} if not names else {bulk(n) for n in names}
        m.c_randomkey = c_randomkey

    def label_quota_across_owners(m):
        original = m.orun

        def orun(W, cmd, args, named):
            if W[1] is not None and cmd == 'SET' and text(W[0]) in m.quotas:
                return "-OOM command not allowed when used memory > 'label-quota'.^"
            return original(W, cmd, args, named)
        m.orun = orun

    def flush_naming_ignored(m):
        original = m.flush
        m.flush = lambda W, named, all_dbs: original(W, False, all_dbs)

    def list_dropped_with_last_partition(m):
        def tidy():
            for d in range(DBS):
                for o in list(m.ever[d]):
                    if not any(c.label[1] == o for cs in m.names[d].values() for c in cs):
                        del m.ever[d][o]
        m.tidy = tidy

    def declassify_element_leaves_target(m):
        original = m.decl_element

        def decl_element(d, W, target, ok):
            original(d, W, target, ok)
            if W[1] is not None:
                m.ever_add(d, (target, W[1]))
        m.decl_element = decl_element

    return {f.__name__: f for f in (owner_check_dropped, shared_hidden, other_owner_visible, own_before_shared_reversed,
                                    inuse_names_other_owner, forget_leaves_copy, forget_touches_other_owner,
                                    scan_counts_other_owner, dbsize_counts_other_owner, randomkey_other_owner,
                                    label_quota_across_owners, flush_naming_ignored, list_dropped_with_last_partition,
                                    declassify_element_leaves_target)}


def osimulate_with(items, expect, mutant):
    m = OKeys()
    mutant(m)
    return [expect(m, it) for it in items]
