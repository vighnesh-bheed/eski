import random

FIXED = b'0123456789abcdef0123456789abcdef'
HEX = set(b'0123456789abcdefABCDEF')
KNOWN = {b'get', b'set', b'ping', b'echo', b'select', b'auth', b'hello', b'quit', b'reset', b'client', b'label', b'context',
         b'multi', b'exec', b'discard', b'watch', b'unwatch', b'subscribe', b'psubscribe', b'ssubscribe', b'save', b'bgsave',
         b'bgrewriteaof', b'dump', b'restore', b'migrate', b'debug', b'monitor', b'swapdb', b'latency', b'memory', b'slowlog', b'config', b'shutdown', b'eval', b'publish',
         b'script', b'function'}
PERSISTENCE = {b'save', b'bgsave', b'bgrewriteaof', b'dump', b'restore', b'migrate'}
INVALID = 'ERR invalid label'
CONTEXT = 'ERR invalid context'
TOKEN = 'ERR invalid label token'
PER_COMMAND = 'ERR this login must send every command through LABEL AS'
TOKEN_ONLY = 'ERR this login must send every command through LABEL AS TOKEN'
SESSION_NEEDED = 'ERR this command needs a session label set with LABEL SESSION'
SESSION_DENIED = 'ERR LABEL SESSION is not available to this login'
TRANSACTION = "ERR the command's label differs from the transaction's label"
NESTED = 'ERR LABEL AS cannot wrap LABEL AS or LABEL SESSION'
MISMATCH = "ERR the label differs from the context's label"
TOP = 'ERR this command needs a label that dominates the whole label scheme'
PERSIST = 'ERR persistence is off while a label scheme is configured'
SYNTAX = 'ERR syntax error'
CAP = 'ERR this login already holds the maximum number of contexts'
WATCH_IN_MULTI = 'ERR WATCH inside MULTI is not allowed'
EXEC_WATCH = 'EXECABORT Transaction discarded because of: ' + TRANSACTION[len('ERR '):]
OWNER_TRANSACTION = "ERR the command's owner differs from the transaction's owner"
EXEC_WATCH_OWNER = 'EXECABORT Transaction discarded because of: ' + OWNER_TRANSACTION[len('ERR '):]
OPERATOR = 'ERR this command needs a login with the owner-operator right'
OWNER_PERSIST = 'ERR persistence is off while owner mode is on'
REFUSALS = {PER_COMMAND: 'refused_per_command', TOKEN_ONLY: 'refused_token_only', TRANSACTION: 'refused_transaction',
            NESTED: 'refused_nested', MISMATCH: 'refused_mismatch', TOP: 'refused_top', PERSIST: 'refused_persist',
            SESSION_NEEDED: 'refused_session_needed', INVALID: 'refused_invalid', CONTEXT: 'refused_context',
            TOKEN: 'refused_token'}


MUTANTS = ('pin_before_acl', 'kill_by_dominance', 'pin_at_admission', 'multi_naming_ignored', 'token_counts_as_named')
ACL_POOL = [b'subscribe', b'psubscribe', b'ssubscribe', b'client|tracking', b'get', b'swapdb', b'monitor', b'bgrewriteaof']


def wrong(name):
    return f"ERR wrong number of arguments for '{name}' command"


def noperm(login, target):
    return f"NOPERM User {login.decode()} has no permissions to run the '{target.decode()}' command"


class Arrival:
    def __init__(self, helpers, mutant=None):
        self.h = helpers
        self.cfg = None
        self.now = 0
        self.notes = {}
        self.events = []
        self.mutant = mutant

    def note(self, key):
        self.notes[key] = self.notes.get(key, 0) + 1
        self.events.append(key)

    def reset(self, cfg, audience, idle, cap):
        self.cfg, self.audience, self.idle, self.cap = cfg, audience, idle, cap
        self.users, self.conns, self.ctxs, self.next, self.cache, self.tokens = {}, {}, [], 0, {}, {}
        self.denied, self.busy = {}, None

    def lit(self, a):
        return a[1] if a[0] == 'x' else (FIXED if a[0] == 'o' else None)

    def word(self, a, w):
        return a[0] == 'x' and a[1].lower() == w

    def arg_is(self, args, i, w):
        return i < len(args) and self.word(args[i], w)

    def name(self, args):
        b = self.lit(args[0]) if args else None
        return b.lower() if b is not None else b''

    def is_cmd(self, args, w):
        return self.name(args) == w

    def known(self, args):
        return self.name(args) in KNOWN

    def shaped(self, a):
        if a[0] in ('h', 'H', 'o'):
            return True
        return a[0] == 'x' and len(a[1]) == 32 and all(b in HEX for b in a[1])

    def href(self, a):
        if a[0] in ('h', 'H'):
            return ('h', a[1])
        return 's' if self.shaped(a) else 'm'

    def rules(self, login):
        return self.users.get(login, {'clear': '-', 'trust': '-', 'pc': False, 'rt': False, 'keys': []})

    def ceiling(self, login):
        r = self.rules(login)
        if r['clear'] == '*':
            sec = (len(self.cfg.levels) - 1, frozenset(range(len(self.cfg.comps))))
        elif r['clear'] == '-':
            sec = (0, frozenset())
        else:
            sec = r['clear']
        if r['trust'] == '*':
            trust = max(1, len(self.cfg.trusts)) - 1
        elif r['trust'] == '-':
            trust = 0
        else:
            trust = r['trust']
        return sec + (trust,)

    def admits(self, c, l):
        return l[0] <= c[0] and l[1] <= c[1] and l[2] <= c[2]

    def dominates(self, r, d):
        return d[0] <= r[0] and d[1] <= r[1] and r[2] <= d[2]

    def clear_watch(self, c):
        c['cas'], c['watched'], c['wlabels'] = False, [], []

    def end_tx(self, c):
        c['multi'] = c['dirty'] = False
        self.clear_watch(c)

    def state(self, c):
        lt = self.h['label_text']
        if c['wlabels']:
            first = c['wlabels'][0]
            ws = f"{int(any(x != first for x in c['wlabels']))}/{lt(first)}"
        else:
            ws = '-'
        return f"{int(c['multi'])}{int(c['dirty'])}{int(c['explicit'])}{int(c['cas'])}:" \
               f"{lt(c['session']) if c['explicit'] else '-'}:{lt(c['bound'])}:{ws}:{len(c['watched'])}"

    def touch(self, key, w):
        marked = []
        for cid in sorted(self.conns):
            c = self.conns[cid]
            if any(k == key and self.dominates(lab, w) for k, lab in c['watched']):
                self.note('touch_marked_again' if c['cas'] else 'touch_marked')
                c['cas'] = True
            elif any(k == key for k, _ in c['watched']):
                self.note('touch_unseen')
            if c['cas']:
                marked.append(str(cid))
        return 'AK|' + (','.join(marked) if marked else '-')

    def auth(self, cid, login):
        c = self.conns[cid]
        if c['login'] != login:
            c['login'], c['explicit'], c['session'] = login, False, (0, frozenset(), 0)
            self.note('auth_switched')
            if c['wlabels']:
                self.note('auth_kept_watches')
        return 'AA|' + self.state(c)

    def top(self, l):
        return l[0] >= len(self.cfg.levels) - 1 and l[1] >= frozenset(range(len(self.cfg.comps))) and l[2] == 0

    def session(self, c):
        if c['explicit']:
            return c['session']
        ceil = self.ceiling(c['login'])
        return (ceil[0], ceil[1], 0)

    def with_trust(self, marking, trust, has):
        if marking is None or (has and trust is None):
            return None
        label, err = self.h['parse'](self.cfg, marking)
        if err:
            return None
        if has:
            if b';' in marking:
                return None
            t = self.h['lookup'](self.cfg.trusts, trust)
            if t < 0:
                return None
            label = label[:2] + (t,)
        return label

    def expired(self, x):
        return self.now - x['last'] >= self.idle * 1000

    def find(self, login, ref):
        if not isinstance(ref, tuple):
            return None
        x = next((y for y in self.ctxs if y['handle'] == ref[1]), None)
        if x is None:
            self.note('find_gone')
            return None
        if self.expired(x):
            self.ctxs.remove(x)
            self.note('find_expired')
            if self.now - x['last'] == self.idle * 1000:
                self.note('find_expired_boundary')
            return None
        if x['owner'] != login:
            self.note('find_other_login')
            return None
        if not self.admits(self.ceiling(login), x['label']):
            self.note('find_outside_ceiling')
            return None
        x['last'] = self.now
        self.note('find_ok')
        return x

    def parse_i64(self, s):
        if s == b'0':
            return 0
        neg = s[:1] == b'-'
        body = s[1:] if neg else s
        if not body or len(body) > 19 or body[:1] == b'0' or not body.isdigit():
            return None
        v = int(body)
        if v > (1 << 63) - (0 if neg else 1):
            return None
        return -v if neg else v

    def token_check(self, login, sp):
        r = self.rules(login)
        if not r['keys'] or not self.audience or sp['flaw'] == 9:
            return None
        if sp['flaw'] in (5, 6, 7):
            return None
        if sp['secret'] not in r['keys'] or sp['flaw'] == 1:
            return None
        if sp['flaw'] in (2, 3, 4, 8):
            return None
        if sp['marking'] is None or sp['audience'] != self.audience:
            return None
        deadline = self.parse_i64(sp['expires'])
        label = self.with_trust(sp['marking'], sp['trust'], sp['trust'] is not None)
        if deadline is None or label is None or sp['ctx'] == 'm':
            return None
        return {'label': label, 'expires': deadline, 'ctx': sp['ctx']}

    def token_verify(self, login, sp):
        key = (login, tuple(sorted(sp.items())))
        entry = self.cache.get(key)
        if entry is None:
            entry = self.token_check(login, sp)
            if entry is None:
                self.note('token_rejected')
                return None
            self.cache[key] = entry
        else:
            self.note('token_cached')
        if self.now >= entry['expires']:
            del self.cache[key]
            self.note('token_expired')
            if self.now == entry['expires']:
                self.note('token_expired_boundary')
            return None
        if not self.cfg.valid(entry['label']) or not self.admits(self.ceiling(login), entry['label']):
            self.note('token_outside_ceiling')
            return None
        if entry['ctx'] is None:
            self.note('token_ok')
            return entry['label'], None
        x = self.find(login, entry['ctx'])
        if x is None or x['label'] != entry['label']:
            self.note('token_context_refused')
            return None
        self.note('token_context_ok')
        return entry['label'], x

    def label_as(self, login, args):
        if len(args) <= 2:
            return WRONG_AS, None
        if self.word(args[2], b'token') and len(args) > 4:
            sp = self.tokens.get(args[3][1]) if args[3][0] == 't' else None
            v = self.token_verify(login, sp) if sp is not None else None
            if v is None:
                return TOKEN, None
            self.note('form_token')
            return None, (4, v[0], v[1])
        if self.rules(login)['rt']:
            return TOKEN_ONLY, None
        if self.word(args[2], b'context') and len(args) > 4 and self.shaped(args[3]):
            x = self.find(login, self.href(args[3]))
            if x is None:
                return CONTEXT, None
            self.note('form_context')
            return None, (4, x['label'], x)
        marking, i, trust, has = self.lit(args[2]), 3, None, False
        if len(args) > 5 and self.word(args[3], b'trust'):
            trust, has, i = self.lit(args[4]), True, 5
        label = self.with_trust(marking, trust, has)
        if label is None or not self.admits(self.ceiling(login), label):
            return INVALID, None
        ctx = None
        if i + 2 < len(args) and self.word(args[i], b'context') and self.shaped(args[i + 1]):
            ctx = self.find(login, self.href(args[i + 1]))
            if ctx is None:
                return CONTEXT, None
            if ctx['label'] != label:
                return MISMATCH, None
            i += 2
            self.note('form_marking_context')
        if i >= len(args):
            return WRONG_AS, None
        self.note('form_marking_trust' if has else 'form_marking')
        return None, (i, label, ctx)

    def refuse(self, c, slot, msg):
        self.note('refused')
        if msg in REFUSALS:
            self.note(REFUSALS[msg])
        if self.is_cmd(slot, b'exec') and c['multi']:
            if c['wlabels'] or c['watched']:
                self.note('exec_abort_arrival_watched')
            self.end_tx(c)
            self.note('exec_abort_arrival')
            return 'no:EXECABORT Transaction discarded because of: ' + (msg[4:] if msg.startswith('ERR ') else msg)
        if c['multi']:
            c['dirty'] = True
        return 'no:' + msg

    def housekeeping(self, args):
        n = self.name(args)
        if not self.known(args) or n in (b'auth', b'hello', b'ping', b'quit', b'reset', b'echo', b'select'):
            return True
        if n == b'label':
            return any(self.arg_is(args, 1, w) for w in (b'whoami', b'help', b'session'))
        if n == b'context':
            return self.arg_is(args, 1, b'help')
        if n == b'client':
            return any(self.arg_is(args, 1, w) for w in (b'setname', b'setinfo', b'id'))
        return False

    def nested(self, args):
        return self.is_cmd(args, b'label') and (self.arg_is(args, 1, b'as') or self.arg_is(args, 1, b'session'))

    def subscribing(self, args):
        n = self.name(args)
        return n in (b'subscribe', b'psubscribe', b'ssubscribe') or \
            (n == b'client' and self.arg_is(args, 1, b'tracking') and self.arg_is(args, 2, b'on'))

    def acl_target(self, args):
        n = self.name(args)
        if n == b'client' and len(args) > 1 and args[1][0] == 'x':
            return n + b'|' + args[1][1].lower()
        return n

    def acl_refusal(self, c, args):
        target = self.acl_target(args)
        if target in self.denied.get(c['login'], ()):
            return noperm(c['login'], target)
        return None

    def refusal(self, args, label, c, prefixed):
        n = self.name(args)
        r = self.rules(c['login'])
        kept = prefixed or (c['multi'] and c['bprefixed']) or r['pc'] or r['rt']
        if self.subscribing(args) and not c['explicit'] and kept:
            return SESSION_NEEDED
        if self.mutant == 'pin_before_acl' and self.subscribing(args) and not c['explicit'] and not c['multi']:
            c['explicit'], c['session'] = True, label
        msg = self.acl_refusal(c, args)
        if msg:
            event = 'owner_noperm' if isinstance(self, Owners) else 'refused_noperm'
            self.note(event)
            if self.subscribing(args) and not c['explicit'] and not c['multi']:
                self.note(event + '_push')
            return msg
        if n in PERSISTENCE or (n == b'debug' and (self.arg_is(args, 1, b'reload') or self.arg_is(args, 1, b'loadaof'))) \
                or (n == b'shutdown' and any(self.word(a, b'save') for a in args[1:])):
            return PERSIST
        top_only = n in (b'monitor', b'swapdb', b'debug', b'latency') or \
            (n == b'client' and (self.arg_is(args, 1, b'pause') or self.arg_is(args, 1, b'unpause'))) or \
            (n == b'memory' and any(self.arg_is(args, 1, w) for w in (b'stats', b'doctor', b'malloc-stats', b'purge'))) or \
            (n == b'slowlog' and self.arg_is(args, 1, b'reset')) or (n == b'config' and self.arg_is(args, 1, b'resetstat')) or \
            (n == b'function' and any(self.arg_is(args, 1, w) for w in (b'load', b'delete', b'flush', b'restore'))) or \
            (n == b'script' and self.arg_is(args, 1, b'flush'))
        if top_only and not self.top(label):
            return TOP
        return None

    def arrive(self, c, args, run=True):
        login = c['login']
        prefixed, ctx = False, None
        if self.is_cmd(args, b'label') and self.arg_is(args, 1, b'as'):
            msg, parsed = self.label_as(login, args)
            if msg:
                return self.refuse(c, args, msg), None
            inner = args[parsed[0]:]
            if self.nested(inner):
                return self.refuse(c, args, NESTED), None
            label, ctx, prefixed = parsed[1], parsed[2], True
        else:
            r = self.rules(login)
            if (r['pc'] or r['rt']) and not c['multi'] and not self.housekeeping(args):
                return self.refuse(c, args, TOKEN_ONLY if r['rt'] else PER_COMMAND), None
            inner, label = args, self.session(c)
        if c['multi']:
            if prefixed and label != c['bound']:
                return self.refuse(c, inner, TRANSACTION), None
            label = c['bound']
        elif self.is_cmd(inner, b'multi'):
            c['bound'], c['bprefixed'] = label, prefixed
        if not self.admits(self.ceiling(login), label) or not self.cfg.valid(label):
            return self.refuse(c, inner, INVALID), None
        if self.known(inner):
            msg = self.refusal(inner, label, c, prefixed)
            if msg:
                return self.refuse(c, inner, msg), None
            if self.subscribing(inner) and not c['explicit'] and not c['multi']:
                if run or self.mutant == 'pin_at_admission':
                    c['explicit'], c['session'] = True, label
                    self.note('session_pinned')
                else:
                    self.note('vetoed_unpinned')
        self.note('arrived_prefixed' if prefixed else 'arrived_session')
        if c['multi']:
            self.note('arrived_in_multi')
        handle = f"h{ctx['handle']}" if ctx else '-'
        return f"ok:{self.h['label_text'](label)}:{len(inner)}:{handle}", (label, inner)

    def session_cmd(self, c, inner):
        if len(inner) < 3:
            return wrong('label|session')
        r = self.rules(c['login'])
        if r['pc'] or r['rt']:
            self.note('session_denied')
            return SESSION_DENIED
        if len(inner) == 3:
            label = self.with_trust(self.lit(inner[2]), None, False)
        elif len(inner) == 5 and self.word(inner[3], b'trust'):
            label = self.with_trust(self.lit(inner[2]), self.lit(inner[4]), True)
        else:
            return SYNTAX
        if label is None or not self.admits(self.ceiling(c['login']), label) or not self.cfg.valid(label):
            return INVALID
        c['explicit'], c['session'] = True, label
        self.note('session_set')
        return 'OK'

    def create(self, c, base, opts):
        level = trust = None
        has_level = has_trust = False
        for i in range(0, len(opts), 2):
            if i + 1 >= len(opts):
                return SYNTAX
            if self.word(opts[i], b'level') and not has_level:
                level, has_level = self.lit(opts[i + 1]), True
            elif self.word(opts[i], b'trust') and not has_trust:
                trust, has_trust = self.lit(opts[i + 1]), True
            else:
                return SYNTAX
        label = base
        if has_level:
            parsed = self.with_trust(level, trust, has_trust)
            if parsed is None:
                return INVALID
            if not has_trust and b';' not in level:
                parsed = parsed[:2] + (base[2],)
            label = parsed
        elif has_trust:
            t = self.h['lookup'](self.cfg.trusts, trust) if trust is not None else -1
            if t < 0:
                return INVALID
            label = base[:2] + (t,)
        if not self.admits(self.ceiling(c['login']), label) or not self.cfg.valid(label):
            return INVALID
        if sum(1 for x in self.ctxs if x['owner'] == c['login'] and not self.expired(x)) >= self.cap:
            self.note('create_full')
            return CAP
        self.ctxs.append({'handle': self.next, 'owner': c['login'], 'label': label, 'last': self.now})
        self.next += 1
        self.note('created')
        return f'h{self.next - 1}'

    def context_cmd(self, c, label, inner):
        if self.arg_is(inner, 1, b'create'):
            return self.create(c, label, inner[2:])
        if self.arg_is(inner, 1, b'info') or self.arg_is(inner, 1, b'drop'):
            drop = self.arg_is(inner, 1, b'drop')
            if len(inner) != 3:
                return wrong('context|drop' if drop else 'context|info')
            x = self.find(c['login'], self.href(inner[2]))
            if x is None:
                return CONTEXT
            if drop:
                self.ctxs.remove(x)
                self.note('dropped')
                return 'OK'
            trusts = self.cfg.trusts
            name = trusts[x['label'][2]] if x['label'][2] < len(trusts) else b''
            return f"info:{self.h['hexs'](self.cfg.format(x['label'][:2] + (0,)))}:{self.h['hexs'](name)}"
        return '-'

    def handle(self, c, label, inner):
        if c['multi'] and self.name(inner) not in (b'exec', b'discard', b'multi', b'watch', b'quit', b'reset'):
            self.note('queued')
            return 'queued'
        if self.is_cmd(inner, b'multi'):
            if c['multi']:
                return 'ERR MULTI calls can not be nested'
            c['multi'], c['dirty'] = True, False
            return 'OK'
        if self.is_cmd(inner, b'exec'):
            if not c['multi']:
                return 'ERR EXEC without MULTI'
            dirty, cas, labels, bound = c['dirty'], c['cas'], c['wlabels'], c['bound']
            self.end_tx(c)
            if dirty:
                self.note('exec_dirty')
                return 'EXECABORT Transaction discarded because of previous errors.'
            if any(x != bound for x in labels):
                self.note('exec_watch_refused')
                self.note('exec_watch_refused_marked' if cas else 'exec_watch_refused_clean')
                if len(set(labels)) > 1:
                    self.note('exec_watch_mixed')
                return EXEC_WATCH
            if cas:
                self.note('exec_watch_aborted')
                return 'nil'
            self.note('exec_watch_same' if labels else 'exec_clean')
            return 'exec'
        if self.is_cmd(inner, b'discard'):
            if not c['multi']:
                return 'ERR DISCARD without MULTI'
            self.end_tx(c)
            return 'OK'
        if self.is_cmd(inner, b'watch'):
            if c['multi']:
                self.note('watch_in_multi')
                return WATCH_IN_MULTI
            c['wlabels'].append(label)
            self.note('watch_noted')
            if c['cas']:
                self.note('watch_noted_marked')
            for a in inner[1:]:
                key = self.lit(a)
                if key is not None and not any(k == key for k, _ in c['watched']):
                    c['watched'].append((key, label))
                    if c['cas']:
                        self.note('watch_added_marked')
            return 'OK'
        if self.is_cmd(inner, b'unwatch'):
            self.clear_watch(c)
            self.note('unwatched')
            return 'OK'
        if self.is_cmd(inner, b'label') and self.arg_is(inner, 1, b'session'):
            return self.session_cmd(c, inner)
        if self.is_cmd(inner, b'context'):
            return self.context_cmd(c, label, inner)
        return '-'

    def veto(self, cid, args):
        c = self.conns[cid]
        arrival, _ = self.arrive(c, args, False)
        return f'AV|{arrival}|-|{self.state(c)}|{len(self.ctxs)}'

    def request(self, kind, cid, args):
        c = self.conns[cid]
        arrival, ok = self.arrive(c, args)
        reply = self.handle(c, ok[0], ok[1]) if ok else '-'
        if c['cas'] and c['watched']:
            self.note('marked_keeps_watches')
        return f'{kind}|{arrival}|{reply}|{self.state(c)}|{len(self.ctxs)}'

    def deny(self, login, names):
        self.denied[login] = set(names)
        self.cache = {}
        return f'{len(names)}'

    def kill_ok(self, label, owner, top, operator, script):
        if top:
            return True
        if not self.dominates(label, script[0]):
            return False
        if not isinstance(self, Owners):
            return True
        if self.mutant == 'kill_by_dominance':
            return operator or owner == script[1] or script[1] == 's'
        return operator or owner == script[1]

    def busy_start(self, kind, cid, args):
        c = self.conns[cid]
        arrival, ok = self.arrive(c, args)
        reply = self.handle(c, ok[0], ok[1]) if ok else '-'
        self.busy = (ok[0], 's') if ok and not c['multi'] else None
        return f'{kind}|{arrival}|{reply}|{self.state(c)}|{len(self.ctxs)}'

    def busy_call(self, kind, cid, args):
        c = self.conns[cid]
        script = self.busy
        arrival, ok = self.arrive(c, args)
        if not ok:
            verdict = '-'
        elif script is None:
            verdict = 'nobusy'
        elif c['multi']:
            verdict = 'queued'
        else:
            allowed = self.kill_ok(ok[0], 's', self.top(ok[0]), False, script)
            self.note('kill_allowed' if allowed else 'kill_refused')
            verdict = str(int(allowed))
        return f'{kind}|{arrival}|{verdict}|{self.state(c)}|{len(self.ctxs)}'

    def sweep(self):
        before = len(self.ctxs)
        self.ctxs = [x for x in self.ctxs if not self.expired(x)]
        if len(self.ctxs) < before:
            self.note('swept')
        if len(self.ctxs) + 1 < before:
            self.note('swept_several')
        return f'AW|{len(self.ctxs)}'

    def query(self, cid, a):
        x = self.find(self.conns[cid]['login'], self.href(a))
        return f"AQ|{'h' + str(x['handle']) if x else '-'}|{len(self.ctxs)}"

    def script_denied(self, args):
        n = self.name(args)
        if n == b'label':
            return not (self.arg_is(args, 1, b'whoami') or self.arg_is(args, 1, b'help'))
        if n == b'context':
            return not self.arg_is(args, 1, b'help')
        return False


INVALID_OWNER = 'ERR invalid owner'
OWNER_REQUIRED = 'ERR this login must name an owner with every command'
OWNER_CONTEXT = "ERR the owner differs from the context's owner"
OWNER_BOUND = 'ERR this connection is bound to another owner'
OWNER_REFUSALS = {INVALID_OWNER: 'refused_invalid_owner', OWNER_REQUIRED: 'refused_owner_required',
                  OWNER_CONTEXT: 'refused_owner_context', OWNER_BOUND: 'refused_owner_bound'}


def owner_text(o):
    if o == 's':
        return 's'
    if o == 'e':
        return 'e'
    return o.hex() if o else '-'


class Owners(Arrival):
    def reset(self, cfg, audience, idle, cap):
        super().reset(cfg, audience, idle, cap)
        self.orules, self.oconns, self.cowners, self.towners = {}, {}, {}, {}
        self.run = True

    def text_valid(self, t):
        return t is not None and 0 < len(t) <= 128 and all(33 <= b <= 126 for b in t) and t != b'*'

    def rule_of(self, login):
        return self.orules.get(login, {'kind': '-', 'id': None, 'shared': False, 'op': False})

    def act_text(self, r, t):
        if r['kind'] == '*':
            return True
        if r['kind'] == 'f':
            return t == r['id']
        return False

    def act(self, r, o):
        if o == 'e':
            return False
        if o == 's':
            return r['kind'] == '-' or r['shared']
        return self.act_text(r, o)

    def hk(self, args):
        if self.is_cmd(args, b'owners'):
            return self.arg_is(args, 1, b'help')
        return self.housekeeping(args)

    def owner_top(self, args):
        n = self.name(args)
        if n == b'owners':
            return not self.arg_is(args, 1, b'help')
        return n in (b'monitor', b'swapdb', b'debug', b'latency') or \
            (n == b'client' and (self.arg_is(args, 1, b'pause') or self.arg_is(args, 1, b'unpause'))) or \
            (n == b'memory' and any(self.arg_is(args, 1, w) for w in (b'stats', b'doctor', b'malloc-stats', b'purge'))) or \
            (n == b'slowlog' and self.arg_is(args, 1, b'reset')) or (n == b'config' and self.arg_is(args, 1, b'resetstat')) or \
            (n == b'function' and any(self.arg_is(args, 1, w) for w in (b'load', b'delete', b'flush', b'restore'))) or \
            (n == b'script' and self.arg_is(args, 1, b'flush'))

    def pick_at(self, args, i):
        if i + 2 < len(args) and self.word(args[i], b'owner'):
            return ('text', self.lit(args[i + 1]) or b''), i + 2
        if i + 1 < len(args) and self.word(args[i], b'shared'):
            return ('shared',), i + 1
        return None, i

    def label_as_o(self, c, args):
        login = c['login']
        if len(args) <= 2:
            return WRONG_AS, None
        if self.word(args[2], b'token') and len(args) > 4:
            sp = self.tokens.get(args[3][1]) if args[3][0] == 't' else None
            v = self.token_verify(login, sp) if sp is not None else None
            if v is None:
                return TOKEN, None
            self.note('form_token')
            return None, {'used': 4, 'label': v[0], 'ctx': v[1], 'pick': None, 'tok': self.towners.get(args[3][1], '-')}
        if self.word(args[2], b'owner') and len(args) > 4:
            return self.owner_only(c, args, ('text', self.lit(args[3]) or b''), 4)
        if self.word(args[2], b'shared') and len(args) > 3:
            return self.owner_only(c, args, ('shared',), 3)
        if self.rules(login)['rt']:
            return TOKEN_ONLY, None
        if self.word(args[2], b'context') and len(args) > 4 and self.shaped(args[3]):
            x = self.find(login, self.href(args[3]))
            if x is None:
                return CONTEXT, None
            self.note('form_context')
            return None, {'used': 4, 'label': x['label'], 'ctx': x, 'pick': None, 'tok': None}
        marking, i, trust, has = self.lit(args[2]), 3, None, False
        if len(args) > 5 and self.word(args[3], b'trust'):
            trust, has, i = self.lit(args[4]), True, 5
        label = self.with_trust(marking, trust, has)
        if label is None or not self.admits(self.ceiling(login), label):
            return INVALID, None
        pick, i = self.pick_at(args, i)
        ctx = None
        if i + 2 < len(args) and self.word(args[i], b'context') and self.shaped(args[i + 1]):
            ctx = self.find(login, self.href(args[i + 1]))
            if ctx is None:
                return CONTEXT, None
            if ctx['label'] != label:
                return MISMATCH, None
            i += 2
        if i >= len(args):
            return WRONG_AS, None
        self.note('form_marking_owner' if pick else 'form_marking')
        return None, {'used': i, 'label': label, 'ctx': ctx, 'pick': pick, 'tok': None}

    def owner_only(self, c, args, pick, i):
        self.note('form_owner_only')
        if i + 2 < len(args) and self.word(args[i], b'context') and self.shaped(args[i + 1]):
            if self.rules(c['login'])['rt']:
                return TOKEN_ONLY, None
            label = self.session(c)
            x = self.find(c['login'], self.href(args[i + 1]))
            if x is None:
                return CONTEXT, None
            if x['label'] != label:
                return MISMATCH, None
            return None, {'used': i + 2, 'label': label, 'ctx': x, 'pick': pick, 'tok': None}
        return None, {'used': i, 'label': None, 'ctx': None, 'pick': pick, 'tok': None}

    def owner_refuse(self, c, oc, slot, msg):
        if msg in OWNER_REFUSALS:
            self.note(OWNER_REFUSALS[msg])
        if msg == PERSIST and not (len(self.cfg.levels) > 1 or self.cfg.comps or len(self.cfg.trusts) > 1):
            self.note('refused_owner_persist')
            msg = OWNER_PERSIST
        out = self.refuse(c, slot, msg)
        if out.startswith('no:EXECABORT'):
            oc['wany'] = oc['wmixed'] = oc['wlmixed'] = False
        return out

    def owner_phase(self, c, oc, inner, label, pick, ctx, tok):
        r = self.rule_of(c['login'])
        if self.owner_top(inner) and not (self.top(label) and r['op']):
            self.note('refused_owner_top')
            if self.top(label):
                self.note('refused_operator')
            return (OPERATOR if self.top(label) else TOP), None
        named = None
        if tok is not None:
            if tok == '-':
                if r['kind'] == '*':
                    self.note('refused_token_owner')
                    return TOKEN, None
                token_owner, token_named = 's', False
            elif tok == 's':
                if not self.act(r, 's'):
                    self.note('refused_token_owner')
                    return TOKEN, None
                token_owner, token_named = 's', True
            else:
                if not (self.text_valid(tok) and self.act_text(r, tok)):
                    self.note('refused_token_owner')
                    return TOKEN, None
                token_owner, token_named = tok, True
            if ctx is not None:
                effective = token_owner if token_named else ('s' if r['kind'] == '-' else r['id'])
                if self.cowners.get(ctx['handle'], 's') != effective:
                    self.note('refused_token_owner')
                    return TOKEN, None
            if token_named:
                named = token_owner
                self.note('owner_token')
        elif ctx is not None:
            co = self.cowners.get(ctx['handle'], 's')
            if not self.act(r, co):
                self.note('refused_context_owner')
                return CONTEXT, None
            if pick is not None:
                want = 's' if pick[0] == 'shared' else pick[1]
                if co != want:
                    return OWNER_CONTEXT, None
            named = co
            self.note('owner_context')
        elif pick is not None:
            if pick[0] == 'shared':
                if not self.act(r, 's'):
                    return INVALID_OWNER, None
                named = 's'
            else:
                if not (self.text_valid(pick[1]) and self.act_text(r, pick[1])):
                    return INVALID_OWNER, None
                named = pick[1]
            self.note('owner_named')
        if named is not None:
            o = named
        elif c['multi']:
            o = oc['owner']
        elif r['kind'] == '-':
            o = 's'
        elif r['kind'] == 'f':
            o = r['id']
        elif self.hk(inner):
            o = 's'
            self.note('owner_housekeeping')
        elif r['op'] and self.subscribing(inner):
            o = 'e'
        else:
            return OWNER_REQUIRED, None
        if named is not None and oc['pinned'] and o != oc['pin']:
            return OWNER_BOUND, None
        if named is not None and c['multi'] and o != oc['owner']:
            self.note('refused_owner_transaction')
            return OWNER_TRANSACTION, None
        explicit = named is not None or (tok is not None and self.mutant == 'token_counts_as_named')
        if tok == '-' and not explicit:
            self.note('token_unnamed')
        if c['multi']:
            self.note('owner_multi')
            if explicit and not oc['named']:
                self.note('tx_named')
            if self.mutant != 'multi_naming_ignored':
                oc['named'] = oc['named'] or explicit
        else:
            oc['named'] = explicit
            oc['owner'] = o
            if self.subscribing(inner) and not oc['pinned']:
                if self.run or self.mutant == 'pin_at_admission':
                    oc['pinned'], oc['pin'] = True, o
                    self.note('owner_pinned_every' if o == 'e' else 'owner_pinned')
                else:
                    self.note('vetoed_owner_unpinned')
        return None, o

    def arrive_o(self, cid, args, run=True):
        self.run = run
        c, oc = self.conns[cid], self.oconns[cid]
        login = c['login']
        prefixed, ctx, pick, tok = False, None, None, None
        if self.is_cmd(args, b'label') and self.arg_is(args, 1, b'as'):
            msg, parsed = self.label_as_o(c, args)
            if msg:
                return self.owner_refuse(c, oc, args, msg), None
            inner = args[parsed['used']:]
            if self.nested(inner):
                return self.owner_refuse(c, oc, args, NESTED), None
            pick, tok = parsed['pick'], parsed['tok']
            if parsed['label'] is None:
                label = None
            else:
                label, ctx, prefixed = parsed['label'], parsed['ctx'], True
        else:
            inner, label = args, None
        if label is None:
            r = self.rules(login)
            if (r['pc'] or r['rt']) and not c['multi'] and not self.hk(inner):
                return self.owner_refuse(c, oc, inner, TOKEN_ONLY if r['rt'] else PER_COMMAND), None
            label = self.session(c)
        if c['multi']:
            if prefixed and label != c['bound']:
                return self.owner_refuse(c, oc, inner, TRANSACTION), None
            label = c['bound']
        elif self.is_cmd(inner, b'multi'):
            c['bound'], c['bprefixed'] = label, prefixed
        if not self.admits(self.ceiling(login), label) or not self.cfg.valid(label):
            return self.owner_refuse(c, oc, inner, INVALID), None
        pin = False
        if self.known(inner):
            msg = self.refusal(inner, label, c, prefixed)
            if msg:
                return self.owner_refuse(c, oc, inner, msg), None
            pin = self.subscribing(inner) and not c['explicit'] and not c['multi']
        if not (self.known(inner) or self.is_cmd(inner, b'owners')):
            handle = f"h{ctx['handle']}" if ctx else '-'
            return f"ok:{self.h['label_text'](label)}:s:{len(inner)}:{handle}:0", (label, 's', inner)
        msg, o = self.owner_phase(c, oc, inner, label, pick, ctx, tok)
        if msg:
            if pin:
                self.note('owner_refused_unpinned')
            return self.owner_refuse(c, oc, inner, msg), None
        if pin and (run or self.mutant == 'pin_at_admission'):
            c['explicit'], c['session'] = True, label
        handle = f"h{ctx['handle']}" if ctx else '-'
        return f"ok:{self.h['label_text'](label)}:{owner_text(o)}:{len(inner)}:{handle}:{int(oc['named'])}", (label, o, inner)

    def ostate(self, c, oc):
        lt = self.h['label_text']
        ws = f"{int(oc['wmixed'])}/{lt(oc['wlabel'])}/{owner_text(oc['wowner'])}" if oc['wany'] else '-'
        return f"{int(c['multi'])}{int(c['dirty'])}{int(c['explicit'])}{int(c['cas'])}:" \
               f"{lt(c['session']) if c['explicit'] else '-'}:{lt(c['bound'])}:{len(c['watched'])}:" \
               f"{int(oc['pinned'])}:{owner_text(oc['pin']) if oc['pinned'] else '-'}:{owner_text(oc['owner'])}:{ws}:" \
               f"{int(oc['named'])}"

    def create_o(self, c, base, owner, opts):
        lv = tr = pick = None
        i = 0
        while i < len(opts):
            a = opts[i]
            if pick is None and self.word(a, b'shared'):
                pick, i = ('shared',), i + 1
                continue
            if i + 1 >= len(opts):
                return SYNTAX
            v = opts[i + 1]
            if self.word(a, b'level') and lv is None:
                lv = self.lit(v) if self.lit(v) is not None else bytes([255])
            elif self.word(a, b'trust') and tr is None:
                tr = self.lit(v) if self.lit(v) is not None else bytes([255])
            elif pick is None and self.word(a, b'owner'):
                pick = ('text', self.lit(v) or b'')
            else:
                return SYNTAX
            i += 2
        label = base
        if lv is not None:
            parsed = self.with_trust(lv, tr, tr is not None)
            if parsed is None:
                return INVALID
            label = parsed if tr is not None or b';' in lv else parsed[:2] + (base[2],)
        elif tr is not None:
            k = self.h['lookup'](self.cfg.trusts, tr)
            if k < 0:
                return INVALID
            label = base[:2] + (k,)
        if not self.cfg.valid(label) or not self.admits(self.ceiling(c['login']), label):
            return INVALID
        r = self.rule_of(c['login'])
        if pick is not None:
            if pick[0] == 'shared':
                if not self.act(r, 's'):
                    return INVALID_OWNER
                owner = 's'
            else:
                if not (self.text_valid(pick[1]) and self.act_text(r, pick[1])):
                    return INVALID_OWNER
                owner = pick[1]
        if sum(1 for x in self.ctxs if x['owner'] == c['login'] and not self.expired(x)) >= self.cap:
            self.note('create_full')
            return CAP
        x = {'handle': self.next, 'owner': c['login'], 'label': label, 'last': self.now}
        self.ctxs.append(x)
        self.cowners[self.next] = owner
        self.next += 1
        self.note('created_owner')
        return f"h{x['handle']}"

    def handle_o(self, cid, label, owner, inner):
        c, oc = self.conns[cid], self.oconns[cid]
        if c['multi'] and self.name(inner) not in (b'exec', b'discard', b'multi', b'watch', b'quit', b'reset'):
            self.note('queued')
            return 'queued'
        if self.is_cmd(inner, b'exec') and c['multi']:
            dirty, cas, bound = c['dirty'], c['cas'], c['bound']
            differs = oc['wany'] and (oc['wmixed'] or oc['wlabel'] != bound or oc['wowner'] != oc['owner'])
            owner_differs = oc['wany'] and not oc['wmixed'] and oc['wlabel'] == bound and oc['wowner'] != oc['owner']
            label_differs = oc['wlmixed'] or oc['wlabel'] != bound
            self.end_tx(c)
            oc['wany'] = oc['wmixed'] = oc['wlmixed'] = False
            if dirty:
                return 'EXECABORT Transaction discarded because of previous errors.'
            if differs:
                self.note('exec_owner_watch_refused' if owner_differs else 'exec_scope_watch_refused')
                if not label_differs:
                    self.note('exec_owner_watch_text')
                return EXEC_WATCH if label_differs else EXEC_WATCH_OWNER
            return 'nil' if cas else 'exec'
        if self.is_cmd(inner, b'discard') and c['multi']:
            self.end_tx(c)
            oc['wany'] = oc['wmixed'] = oc['wlmixed'] = False
            return 'OK'
        if self.is_cmd(inner, b'watch') and not c['multi']:
            if not oc['wany']:
                oc['wany'], oc['wlabel'], oc['wowner'] = True, label, owner
            elif oc['wlabel'] != label or oc['wowner'] != owner:
                oc['wmixed'] = True
                if oc['wlabel'] != label:
                    oc['wlmixed'] = True
                self.note('watch_owner_mixed' if oc['wlabel'] == label else 'watch_scope_mixed')
            c['wlabels'].append(label)
            for a in inner[1:]:
                key = self.lit(a)
                if key is not None and not any(k == key for k, _ in c['watched']):
                    c['watched'].append((key, label))
            return 'OK'
        if self.is_cmd(inner, b'unwatch'):
            self.clear_watch(c)
            oc['wany'] = oc['wmixed'] = oc['wlmixed'] = False
            return 'OK'
        if self.is_cmd(inner, b'context') and self.arg_is(inner, 1, b'create'):
            return self.create_o(c, label, owner, inner[2:])
        if self.is_cmd(inner, b'context') and (self.arg_is(inner, 1, b'info') or self.arg_is(inner, 1, b'drop')):
            if len(inner) != 3:
                return wrong('context|info' if self.arg_is(inner, 1, b'info') else 'context|drop')
            x = self.find(c['login'], self.href(inner[2]))
            if x is None:
                return CONTEXT
            if self.arg_is(inner, 1, b'drop'):
                self.ctxs = [y for y in self.ctxs if y['handle'] != x['handle']]
                return 'OK'
            cfg = self.cfg
            marking = cfg.format(x['label'][:2] + (0,))
            trust = cfg.trusts[x['label'][2]] if x['label'][2] < len(cfg.trusts) else b''
            return f"info:{self.h['hexs'](marking)}:{self.h['hexs'](trust)}:{owner_text(self.cowners.get(x['handle'], 's'))}"
        return self.handle(c, label, inner)

    def veto_o(self, cid, args):
        c, oc = self.conns[cid], self.oconns[cid]
        arrival, _ = self.arrive_o(cid, args, False)
        self.run = True
        return f'OV|{arrival}|-|{self.ostate(c, oc)}|{len(self.ctxs)}'

    def request_o(self, cid, args):
        c, oc = self.conns[cid], self.oconns[cid]
        arrival, ok = self.arrive_o(cid, args)
        reply = self.handle_o(cid, ok[0], ok[1], ok[2]) if ok else '-'
        return f'OR|{arrival}|{reply}|{self.ostate(c, oc)}|{len(self.ctxs)}'

    def auth_o(self, cid, login):
        c, oc = self.conns[cid], self.oconns[cid]
        if c['login'] != login:
            c['login'], c['explicit'], c['session'] = login, False, (0, frozenset(), 0)
            oc['pinned'], oc['pin'] = False, 's'
            self.note('owner_auth_cleared')
        return 'OA|' + self.ostate(c, oc)

    def busy_start_o(self, cid, args):
        c, oc = self.conns[cid], self.oconns[cid]
        arrival, ok = self.arrive_o(cid, args)
        reply = self.handle_o(cid, ok[0], ok[1], ok[2]) if ok else '-'
        self.busy = (ok[0], ok[1]) if ok and not c['multi'] else None
        return f'OS|{arrival}|{reply}|{self.ostate(c, oc)}|{len(self.ctxs)}'

    def busy_call_o(self, cid, args):
        c, oc = self.conns[cid], self.oconns[cid]
        script = self.busy
        arrival, ok = self.arrive_o(cid, args)
        if not ok:
            verdict = '-'
        elif script is None:
            verdict = 'nobusy'
        elif c['multi']:
            verdict = 'queued'
        else:
            label, owner = ok[0], ok[1]
            operator = self.rule_of(c['login'])['op']
            allowed = self.kill_ok(label, owner, self.top(label) and operator, operator, script)
            if operator and not self.top(label):
                self.note('owner_kill_operator' if allowed else 'owner_kill_operator_refused')
            elif allowed and owner == script[1]:
                self.note('owner_kill_same')
            elif not allowed and self.dominates(label, script[0]) and script[1] == 's' and owner not in ('s', 'e'):
                self.note('owner_kill_refused_shared')
            elif not allowed and self.dominates(label, script[0]) and script[1] not in ('s', 'e') and owner not in ('s', 'e', script[1]):
                self.note('owner_kill_refused_user')
            elif not allowed and not self.dominates(label, script[0]) and owner == script[1]:
                self.note('owner_kill_refused_label')
            verdict = str(int(allowed))
        return f'OB|{arrival}|{verdict}|{self.ostate(c, oc)}|{len(self.ctxs)}'


WRONG_AS = wrong('label|as')
LEVEL_POOL = [b'U', b'C', b'S', b'TS', b'TOKEN', b'CONTEXT']
COMP_POOL = [b'A', b'B', b'NAVY', b'K9']
TRUST_POOL = [b'WEB', b'VETTED', b'ROOT']
LOGINS = [b'app', b'batch', b'ops', b'reader']


OWNER_IDS = [b'u1', b'u2', b'auth0|5f3c', b'u42', b'U1']
BAD_IDS = [b'a b', b'', b'x' * 129, bytes([0xe9]), b'tab\tx', b'-']


OWNER_NOTES = ('form_owner_only', 'form_marking_owner', 'owner_named', 'owner_context', 'owner_token', 'owner_multi',
               'owner_pinned', 'owner_pinned_every', 'owner_housekeeping', 'refused_owner_required', 'refused_invalid_owner',
               'refused_owner_bound', 'refused_owner_context', 'refused_owner_transaction', 'refused_owner_top',
               'refused_token_owner', 'refused_context_owner', 'exec_owner_watch_refused', 'exec_scope_watch_refused',
               'watch_owner_mixed', 'watch_scope_mixed', 'created_owner', 'owner_auth_cleared', 'owner_refused_unpinned',
               'owner_kill_same', 'owner_kill_operator', 'owner_kill_operator_refused', 'owner_kill_refused_shared',
               'owner_kill_refused_user', 'owner_kill_refused_label', 'owner_noperm', 'owner_noperm_push',
               'vetoed_owner_unpinned', 'refused_operator', 'exec_owner_watch_text', 'refused_owner_persist', 'tx_named',
               'token_unnamed')


def corpus(helpers, seed, sessions=64, steps=160, watch_sessions=32, episodes=30, owner_sessions=48, owner_steps=150,
           acl_sessions=40, acl_steps=60, owner_acl_sessions=48, owner_acl_steps=60, veto_sessions=24, veto_steps=50, mutant=None):
    rng = random.Random(seed ^ 0x0E115)
    m = Owners(helpers, mutant)
    hexs = helpers['hexs']
    trace, expected, stats, marks, owner_marks = [], [], {}, {}, {}

    def emit(line, row):
        trace.append(line)
        expected.append(row)
        kind = row.split('|')[0]
        stats[kind] = stats.get(kind, 0) + 1
        target = owner_marks if isinstance(m, Owners) else marks
        for event in m.events:
            target.setdefault(event, len(expected) - 1)
        m.events = []

    def x(b):
        return ('x', b)

    def arg_text(a):
        if a[0] == 'x':
            return 'x:' + hexs(a[1])
        if a[0] == 'o':
            return 'o'
        return f'{a[0]}:{a[1]}'

    def names_text(names):
        return ','.join(n.hex() for n in names) if names else '-'

    def random_label():
        level = rng.randrange(len(m.cfg.levels))
        comps = frozenset(k for k in range(len(m.cfg.comps)) if rng.random() < 0.4)
        trust = rng.randrange(max(1, len(m.cfg.trusts)))
        return (level, comps, trust)

    def marking_of(label, lower=False):
        text = m.cfg.format(label)
        return text.lower() if lower and rng.random() < 0.5 else text

    def secrecy_text(label):
        return m.cfg.format(label[:2] + (0,))

    def random_marking():
        roll = rng.random()
        if roll < 0.72:
            return marking_of(random_label(), True)
        return rng.choice([b'Q', b'S//ZZ', b'', b'S;', b'S;NOPE', b'U//', b'u', b'S//A//B', b'C;WEB', b' C '])

    def known_label(c):
        if rng.random() < 0.6:
            ceil = m.ceiling(c['login'])
            comps = frozenset(k for k in ceil[1] if rng.random() < 0.6)
            return (rng.randrange(ceil[0] + 1), comps, rng.randrange(ceil[2] + 1))
        return random_label()

    def owned(c):
        return [x for x in m.ctxs if c is not None and x['owner'] == c['login']]

    def handle_arg(c=None):
        roll = rng.random()
        mine = owned(c)
        if mine and roll < 0.5:
            return (rng.choice('hhhH'), rng.choice(mine)['handle'])
        if m.next and roll < 0.8:
            return (rng.choice('hhhH'), rng.randrange(m.next))
        return rng.choice([('o',), x(b'zz'), x(b'ABCDEF0123456789ABCDEF0123456789'), x(b'0123')])

    def inner_command(c, label):
        roll = rng.random()
        if roll < 0.3:
            return [x(b'GET'), x(b'k')]
        if roll < 0.38:
            return [x(b'SET'), x(b'k'), x(b'v')]
        if roll < 0.48:
            opts = []
            if rng.random() < 0.5:
                opts += [x(b'LEVEL'), x(random_marking() if rng.random() < 0.3 else marking_of(known_label(c)))]
            if rng.random() < 0.3 and m.cfg.trusts:
                opts += [x(b'TRUST'), x(rng.choice(m.cfg.trusts + [b'NOPE']))]
            if rng.random() < 0.05:
                opts += [x(b'LEVEL')]
            return [x(b'CONTEXT'), x(b'CREATE')] + opts
        if roll < 0.56:
            extra = [x(b'more')] if rng.random() < 0.05 else []
            return [x(b'CONTEXT'), x(rng.choice([b'INFO', b'info', b'INFO', b'DROP']))] + [handle_arg(c)] + extra
        if roll < 0.62:
            return [x(b'MULTI')]
        if roll < 0.68:
            return [x(b'EXEC')]
        if roll < 0.71:
            return [x(b'DISCARD')]
        if roll < 0.77:
            parts = [x(b'LABEL'), x(b'SESSION'), x(marking_of(known_label(c)[:2] + (0,)))]
            if rng.random() < 0.3 and m.cfg.trusts:
                parts += [x(b'TRUST'), x(rng.choice(m.cfg.trusts))]
            if rng.random() < 0.05:
                parts = parts[:2]
            return parts
        if roll < 0.8:
            return [x(b'LABEL'), x(b'AS'), x(b'C'), x(b'GET'), x(b'k')]
        return rng.choice([[x(b'PING')], [x(b'SUBSCRIBE'), x(b'ch')], [x(b'MONITOR')], [x(b'SAVE')], [x(b'BGREWRITEAOF')],
                           [x(b'DEBUG'), x(b'RELOAD')], [x(b'DEBUG'), x(b'SLEEP'), x(b'0')], [x(b'SHUTDOWN'), x(b'save')],
                           [x(b'SHUTDOWN'), x(b'NOSAVE')], [x(b'CLIENT'), x(b'TRACKING'), x(b'on')], [x(b'CLIENT'), x(b'ID')],
                           [x(b'CLIENT'), x(b'PAUSE'), x(b'1')], [x(b'CONFIG'), x(b'RESETSTAT')], [x(b'MEMORY'), x(b'STATS')],
                           [x(b'SLOWLOG'), x(b'RESET')], [x(b'FOO')], [x(b'LABEL'), x(b'WHOAMI')], [x(b'CONTEXT'), x(b'HELP')],
                           [x(b'ECHO'), x(b'hi')], [x(b'SELECT'), x(b'0')], [x(b'REPLICAOF'), x(b'no'), x(b'one')],
                           [x(b'LABEL'), x(b'SESSION'), x(b'C')], [x(b'PUBLISH'), x(b'ch'), x(b'm')], [x(b'SWAPDB'), x(b'0'), x(b'1')]])

    def prefix(c):
        roll = rng.random()
        if roll < 0.45:
            label = known_label(c)
            if rng.random() < 0.35 and m.cfg.trusts:
                parts = [x(b'LABEL'), x(b'AS'), x(secrecy_text(label)), x(b'TRUST'), x(m.cfg.trusts[label[2]] if label[2] < len(m.cfg.trusts) else b'NOPE')]
            else:
                parts = [x(b'LABEL'), x(b'AS'), x(marking_of(label, True) if rng.random() < 0.85 else random_marking())]
            mine = owned(c)
            if mine and rng.random() < 0.15:
                ctx = rng.choice(mine)
                parts = [x(b'LABEL'), x(b'AS'), x(marking_of(ctx['label'])), x(b'CONTEXT'), (rng.choice('hH'), ctx['handle'])]
            elif rng.random() < 0.15:
                parts += [x(b'CONTEXT'), handle_arg(c)]
            return parts
        if roll < 0.7:
            return [x(b'LABEL'), x(rng.choice([b'AS', b'as'])), x(rng.choice([b'CONTEXT', b'context'])), handle_arg(c)]
        if m.tokens and roll < 0.95:
            fitting = [n for n, sp in m.tokens.items() if sp['secret'] in m.rules(c['login'])['keys'] and sp['flaw'] == 0]
            pool = fitting if fitting and rng.random() < 0.7 else list(m.tokens)
            return [x(b'LABEL'), x(b'AS'), x(b'TOKEN'), ('t', rng.choice(pool))]
        return [x(b'LABEL'), x(b'AS'), x(b'TOKEN'), x(b'notatoken')]

    def rules_for(login):
        roll = rng.random()
        clear = '*' if roll < 0.2 else ('-' if roll < 0.3 else random_label()[:2])
        roll = rng.random()
        trust = '*' if roll < 0.25 else ('-' if roll < 0.45 or not m.cfg.trusts else rng.randrange(len(m.cfg.trusts)))
        pc = rng.random() < 0.18
        rt = rng.random() < 0.12
        keys = sorted(rng.sample(range(4), rng.choice([0, 1, 2, 2, 3])))
        texts = []
        if clear == '*':
            texts.append(b'clearance:*')
        elif clear != '-':
            texts.append(b'clearance:' + m.cfg.format(clear + (0,)))
        if trust == '*':
            texts.append(b'trust:*')
        elif trust != '-':
            texts.append(b'trust:' + m.cfg.trusts[trust])
        if pc:
            texts.append(b'label-per-command')
        if rt:
            texts.append(b'require-token')
        r = {'clear': clear, 'trust': trust, 'pc': pc, 'rt': rt, 'keys': keys}
        clear_text = clear if clear in ('*', '-') else helpers['label_text'](clear + (0,))
        line = f"AU {login.hex()} {clear_text} {trust} {int(pc)} {int(rt)} {','.join(map(str, keys)) or '-'} {names_text(texts)}"
        return r, line

    def set_user(login):
        r, line = rules_for(login)
        m.users[login] = r
        m.cache = {}
        ceil = m.ceiling(login)
        emit(line, f"AU|{helpers['label_text'](ceil)}|{int(r['pc'])}|{int(r['rt'])}|{len(r['keys'])}")

    def new_token():
        n = len(m.tokens)
        flaw = 0 if rng.random() < 0.8 else rng.randint(1, 9)
        roll = rng.random()
        if roll < 0.2:
            expires = str(m.now + rng.choice([100, 700, 1500, m.idle * 1000])).encode()
        elif roll < 0.72:
            expires = str(m.now + 100 * rng.randrange(1, 60)).encode()
        elif roll < 0.84:
            expires = str(m.now - 100 * rng.randrange(0, 20)).encode()
        else:
            expires = rng.choice([b'abc', b'-1', b'007', b'', b'99999999999999999999', b'0', b'9223372036854775807'])
        owners = [login for login, r in m.users.items() if r['keys']]
        owner = rng.choice(owners) if owners and rng.random() < 0.85 else None
        mine = [y for y in m.ctxs if owner is not None and y['owner'] == owner]
        roll = rng.random()
        if mine and roll < 0.4:
            target = rng.choice(mine)
            ctx = ('h', target['handle'])
        elif m.next and roll < 0.55:
            target, ctx = None, ('h', rng.randrange(m.next))
        elif roll < 0.6:
            target, ctx = None, rng.choice(['s', 'm'])
        else:
            target, ctx = None, '-'
        if target is not None and rng.random() < 0.85:
            label = target['label']
        elif owner is not None and rng.random() < 0.7:
            ceil = m.ceiling(owner)
            label = (rng.randrange(ceil[0] + 1), frozenset(k for k in ceil[1] if rng.random() < 0.5), rng.randrange(ceil[2] + 1))
        else:
            label = random_label()
        has_trust = rng.random() < 0.3 and m.cfg.trusts
        marking = secrecy_text(label) if has_trust else (marking_of(label) if rng.random() < 0.9 else random_marking())
        if rng.random() < 0.05 or marking == b'':
            marking = None
        trust = (m.cfg.trusts[label[2]] if rng.random() < 0.9 else b'NOPE') if has_trust else None
        audience = rng.choice([m.audience or b'node'] * 8 + [b'other', None])
        secret = rng.choice(m.users[owner]['keys']) if owner is not None and rng.random() < 0.9 else rng.randrange(4)
        sp = {'secret': secret, 'marking': marking, 'trust': trust, 'expires': expires, 'audience': audience,
              'ctx': None if ctx == '-' else ctx, 'flaw': flaw}
        m.tokens[n] = sp
        ctx_text = ctx if isinstance(ctx, str) else f'h:{ctx[1]}'
        opt = lambda v: '-' if v is None else hexs(v)
        line = f"AO {n} {sp['secret']} {opt(marking)} {opt(trust)} {hexs(expires)} {opt(audience)} {ctx_text} {flaw}"
        emit(line, f'AO|{n}')

    def open_session():
        cfg = helpers['Config']()
        levels = rng.sample(LEVEL_POOL[:4], rng.randint(2, 4))
        if rng.random() < 0.3:
            levels.append(rng.choice(LEVEL_POOL[4:]))
        comps = rng.sample(COMP_POOL, rng.randint(0, 3))
        trusts = rng.sample(TRUST_POOL, rng.choice([0, 2, 2, 3]))
        for kind, names in (('CL', levels), ('CC', comps), ('CT', trusts)):
            for n in names:
                assert cfg.add(kind, n) == 'ok'
        audience = b'node' if rng.random() < 0.85 else b''
        idle, cap = rng.randint(1, 4), rng.randint(1, 3)
        m.reset(cfg, audience, idle, cap)
        emit(f'AX {names_text(levels)} {names_text(comps)} {names_text(trusts)} {hexs(audience)} {idle} {cap}',
             f'AX|{len(levels)}|{len(comps)}|{len(trusts)}')
        logins = rng.sample(LOGINS, rng.randint(2, 4))
        for login in logins:
            set_user(login)
        for cid in range(rng.randint(2, 5)):
            login = rng.choice(logins)
            m.conns[cid] = {'login': login, 'explicit': False, 'session': (0, frozenset(), 0), 'multi': False,
                            'dirty': False, 'bound': (0, frozenset(), 0), 'bprefixed': False, 'cas': False,
                            'watched': [], 'wlabels': []}
            emit(f'AC {cid} {login.hex()}', f'AC|{cid}')
        return logins

    def owner_id():
        roll = rng.random()
        if roll < 0.9:
            return rng.choice(OWNER_IDS)
        return rng.choice(BAD_IDS)

    def set_owner_user(login):
        r, line = rules_for(login)
        roll = rng.random()
        kind = '-' if roll < 0.3 else ('*' if roll < 0.75 else 'f')
        oid = rng.choice(OWNER_IDS) if kind == 'f' else None
        shared, op = rng.random() < 0.4, rng.random() < 0.3
        texts = []
        if kind == '*':
            texts.append(b'owners:*')
        elif kind == 'f':
            texts.append(b'owner:' + oid)
        if shared:
            texts.append(b'owner-shared')
        if op:
            texts.append(b'owner-operator')
        base = line.split(' ')
        rule_texts = base[7].split(',') if base[7] != '-' else []
        rule_texts += [t.hex() for t in texts]
        base[0] = 'OU'
        base[7] = ','.join(rule_texts) if rule_texts else '-'
        line = ' '.join(base) + f" {kind} {oid.hex() if oid else '-'} {int(shared)} {int(op)}"
        m.users[login] = r
        m.orules[login] = {'kind': kind, 'id': oid, 'shared': shared, 'op': op}
        m.cache = {}
        ceil = m.ceiling(login)
        emit(line, f"OU|{helpers['label_text'](ceil)}|{int(r['pc'])}|{int(r['rt'])}|{len(r['keys'])}|{kind}|{int(shared)}|{int(op)}")

    def new_owner_token():
        before = len(trace)
        new_token()
        line = trace[before]
        n = len(m.tokens) - 1
        roll = rng.random()
        if roll < 0.3:
            spec = '-'
        elif roll < 0.45:
            spec = 's'
        elif roll < 0.9:
            spec = 'x:' + hexs(owner_id())
        else:
            spec = rng.choice(['B', 'D', 'L'])
        if spec in ('B', 'D', 'L') and m.tokens[n]['flaw'] == 0:
            m.tokens[n]['flaw'] = 4
        m.towners[n] = '-' if spec == '-' else ('s' if spec == 's' else (bytes.fromhex(spec[2:]) if spec.startswith('x:') and spec != 'x:-' else (b'' if spec == 'x:-' else None)))
        trace[before] = 'OO' + line[2:] + ' ' + spec
        expected[before] = f'OO|{n}'
        stats['AO'] -= 1
        stats['OO'] = stats.get('OO', 0) + 1

    def open_owner_session():
        cfg = helpers['Config']()
        levels = rng.sample(LEVEL_POOL[:4], rng.choice([1, 2, 3, 3, 4]))
        comps = rng.sample(COMP_POOL, rng.randint(0, 2)) if len(levels) > 1 else []
        trusts = rng.sample(TRUST_POOL, rng.choice([0, 2, 2])) if len(levels) > 1 else []
        for kind, names in (('CL', levels), ('CC', comps), ('CT', trusts)):
            for n in names:
                assert cfg.add(kind, n) == 'ok'
        audience = b'node' if rng.random() < 0.9 else b''
        idle, cap = rng.randint(1, 4), rng.randint(1, 3)
        m.reset(cfg, audience, idle, cap)
        emit(f'OX {names_text(levels)} {names_text(comps)} {names_text(trusts)} {hexs(audience)} {idle} {cap}',
             f'OX|{len(levels)}|{len(comps)}|{len(trusts)}')
        logins = rng.sample(LOGINS, rng.randint(2, 4))
        for login in logins:
            set_owner_user(login)
        for cid in range(rng.randint(2, 5)):
            login = rng.choice(logins)
            m.conns[cid] = {'login': login, 'explicit': False, 'session': (0, frozenset(), 0), 'multi': False,
                            'dirty': False, 'bound': (0, frozenset(), 0), 'bprefixed': False, 'cas': False,
                            'watched': [], 'wlabels': []}
            m.oconns[cid] = {'pinned': False, 'pin': 's', 'owner': 's', 'wany': False, 'wmixed': False,
                             'wlabel': (0, frozenset(), 0), 'wowner': 's', 'wlmixed': False, 'named': False}
            emit(f'OC {cid} {login.hex()}', f'OC|{cid}')
        return logins

    def owner_clause(c):
        roll = rng.random()
        if roll < 0.55:
            return [x(b'OWNER'), x(owner_id())]
        if roll < 0.8:
            return [x(rng.choice([b'SHARED', b'shared']))]
        return []

    def owner_prefix(c):
        roll = rng.random()
        mine = owned(c)
        if roll < 0.3:
            parts = [x(b'LABEL'), x(b'AS'), x(marking_of(known_label(c), True))] + owner_clause(c)
            if mine and rng.random() < 0.2:
                ctx = rng.choice(mine)
                parts = [x(b'LABEL'), x(b'AS'), x(marking_of(ctx['label']))] + owner_clause(c) + [x(b'CONTEXT'), ('h', ctx['handle'])]
            return parts
        if roll < 0.6:
            parts = [x(b'LABEL'), x(b'AS')] + (owner_clause(c) or [x(b'OWNER'), x(owner_id())])
            if mine and rng.random() < 0.15:
                parts += [x(b'CONTEXT'), ('h', rng.choice(mine)['handle'])]
            return parts
        if roll < 0.72:
            return [x(b'LABEL'), x(b'AS'), x(b'CONTEXT'), handle_arg(c)]
        if m.tokens and roll < 0.9:
            fitting = [n for n, sp in m.tokens.items() if sp['secret'] in m.rules(c['login'])['keys'] and sp['flaw'] == 0]
            pool = fitting if fitting and rng.random() < 0.8 else list(m.tokens)
            return [x(b'LABEL'), x(b'AS'), x(b'TOKEN'), ('t', rng.choice(pool))]
        return []

    def owner_inner(c):
        roll = rng.random()
        if roll < 0.2:
            return [x(b'GET'), x(b'k')]
        if roll < 0.3:
            return rng.choice([[x(b'PING')], [x(b'ECHO'), x(b'hi')], [x(b'LABEL'), x(b'WHOAMI')], [x(b'CLIENT'), x(b'ID')],
                               [x(b'OWNERS'), x(b'HELP')], [x(b'FOO')], [x(b'SELECT'), x(b'0')]])
        if roll < 0.42:
            return rng.choice([[x(b'SUBSCRIBE'), x(b'ch')], [x(b'PSUBSCRIBE'), x(b'c*')], [x(b'SSUBSCRIBE'), x(b'ch')],
                               [x(b'CLIENT'), x(b'TRACKING'), x(b'on')]])
        if roll < 0.52:
            opts = []
            if rng.random() < 0.3:
                opts += [x(b'LEVEL'), x(marking_of(known_label(c)))]
            r2 = rng.random()
            if r2 < 0.35:
                opts += [x(b'OWNER'), x(owner_id())]
            elif r2 < 0.55:
                opts += [x(b'SHARED')]
            if rng.random() < 0.05:
                opts += [x(b'OWNER')]
            rng.shuffle(opts) if rng.random() < 0.1 else None
            return [x(b'CONTEXT'), x(b'CREATE')] + opts
        if roll < 0.58:
            return [x(b'CONTEXT'), x(rng.choice([b'INFO', b'DROP', b'INFO']))] + [handle_arg(c)]
        if roll < 0.68:
            return rng.choice([[x(b'DEBUG'), x(b'SLEEP'), x(b'0')], [x(b'MONITOR')], [x(b'OWNERS'), x(b'INFO'), x(b'u1')],
                               [x(b'OWNERS'), x(b'FORGET'), x(b'u2')], [x(b'SAVE')], [x(b'CONFIG'), x(b'RESETSTAT')],
                               [x(b'SLOWLOG'), x(b'RESET')]])
        if roll < 0.74:
            parts = [x(b'LABEL'), x(b'SESSION'), x(marking_of(known_label(c)[:2] + (0,)))]
            return parts + ([x(b'OWNER'), x(b'u1')] if rng.random() < 0.1 else [])
        if roll < 0.8:
            return [x(b'PUBLISH'), x(b'ch'), x(b'm')]
        return [x(b'SET'), x(b'k'), x(b'v')]

    def owner_request(cid, args):
        emit(f'OR {cid} ' + ' '.join(map(arg_text, args)), m.request_o(cid, args))

    def owned_prefix(c, scope):
        label, owner = scope
        parts = [x(b'LABEL'), x(b'AS')]
        if label is not None:
            parts.append(x(marking_of(label)))
        if owner == 's':
            parts.append(x(b'SHARED'))
        elif owner is not None:
            parts += [x(b'OWNER'), x(owner)]
        return parts if len(parts) > 2 else []

    def random_scope(c):
        label = known_label(c) if rng.random() < 0.4 else None
        roll = rng.random()
        owner = rng.choice(OWNER_IDS[:3]) if roll < 0.6 else ('s' if roll < 0.8 else None)
        return label, owner

    for session in range(owner_sessions):
        logins = open_owner_session()
        for _ in range(owner_steps):
            roll = rng.random()
            if roll < 0.04:
                m.now += rng.choice([0, 100, 700, 1500, m.idle * 1000])
                emit(f'OT {m.now}', f'OT|{m.now}')
                continue
            if roll < 0.09:
                new_owner_token()
                continue
            if roll < 0.11:
                set_owner_user(rng.choice(logins))
                continue
            cid = rng.choice(list(m.conns))
            c = m.conns[cid]
            if roll < 0.13:
                login = rng.choice(logins)
                emit(f'OA {cid} {login.hex()}', m.auth_o(cid, login))
                continue
            if roll < 0.25 and not c['multi']:
                scope = random_scope(c)
                for _ in range(rng.choice([0, 1, 1, 2])):
                    watch = scope if rng.random() < 0.6 else random_scope(c)
                    owner_request(cid, owned_prefix(c, watch) + [x(b'WATCH'), x(rng.choice([b'w0', b'w1']))])
                owner_request(cid, owned_prefix(c, scope) + [x(b'MULTI')])
                for _ in range(rng.randint(0, 3)):
                    body = owner_inner(c) if rng.random() < 0.3 else [x(b'GET'), x(b'k')]
                    if c['multi'] and rng.random() < 0.5:
                        body = owned_prefix(c, scope if rng.random() < 0.6 else random_scope(c)) + body
                    owner_request(cid, body)
                end = [x(rng.choice([b'EXEC', b'EXEC', b'DISCARD']))]
                if rng.random() < 0.3:
                    end = owned_prefix(c, scope if rng.random() < 0.5 else random_scope(c)) + end
                owner_request(cid, end)
                continue
            if roll < 0.3:
                owner_request(cid, owned_prefix(c, random_scope(c)) + [x(b'UNWATCH')])
                continue
            pre = owner_prefix(c) if rng.random() < 0.8 else []
            args = pre + owner_inner(c)
            if rng.random() < 0.03:
                args = rng.choice([[x(b'LABEL'), x(b'AS'), x(b'OWNER'), x(b'u1')], [x(b'LABEL'), x(b'AS'), x(b'SHARED')],
                                   [x(b'LABEL'), x(b'AS'), x(b'OWNER'), x(b'u1'), x(b'LABEL'), x(b'AS'), x(b'C'), x(b'GET'), x(b'k')],
                                   [x(b'LABEL'), x(b'AS'), x(marking_of(known_label(c))), x(b'OWNER'), x(b'u1')],
                                   [x(b'LABEL'), x(b'AS'), x(marking_of(known_label(c))), x(b'OWNER'), x(b'u1'), x(b'TRUST'), x(b'WEB'), x(b'GET')]])
            owner_request(cid, args)

    owner_model = m
    m = Arrival(helpers, mutant)
    rng = random.Random(seed)
    emit('OT 0', 'OT|0')
    for session in range(sessions):
        logins = open_session()
        for _ in range(steps):
            roll = rng.random()
            if roll < 0.06:
                m.now += rng.choice([0, 100, 700, 1500, 2600, 5000, m.idle * 1000, m.idle * 1000, m.idle * 1000 - 100])
                emit(f'AT {m.now}', f'AT|{m.now}')
                if rng.random() < 0.3:
                    emit('AW', m.sweep())
                continue
            if roll < 0.1:
                new_token()
                continue
            if roll < 0.125:
                set_user(rng.choice(logins))
                continue
            if roll < 0.14:
                emit('AW', m.sweep())
                continue
            cid = rng.choice(list(m.conns))
            c = m.conns[cid]
            if roll < 0.16 and not c['multi']:
                pre = prefix(c) if rng.random() < 0.5 else []
                args = pre + [x(b'MULTI')]
                emit(f'AR {cid} ' + ' '.join(map(arg_text, args)), m.request('AR', cid, args))
                for _ in range(rng.randint(0, 3)):
                    body = rng.choice([[x(b'GET'), x(b'k')], [x(b'SET'), x(b'k'), x(b'v')], [x(b'CONTEXT'), x(b'CREATE')]])
                    if c['multi'] and rng.random() < 0.4:
                        body = [x(b'LABEL'), x(b'AS'), x(marking_of(c['bound']) if rng.random() < 0.8 else marking_of(random_label()))] + body
                    emit(f'AR {cid} ' + ' '.join(map(arg_text, body)), m.request('AR', cid, body))
                end = [x(rng.choice([b'EXEC', b'EXEC', b'DISCARD']))]
                if rng.random() < 0.2:
                    end = [x(b'LABEL'), x(b'AS'), x(marking_of(c['bound']) if rng.random() < 0.5 else marking_of(random_label()))] + end
                emit(f'AR {cid} ' + ' '.join(map(arg_text, end)), m.request('AR', cid, end))
                continue
            if roll < 0.18:
                a = handle_arg()
                emit(f'AQ {cid} {arg_text(a)}', m.query(cid, a))
                continue
            if roll < 0.19:
                args = rng.choice([[x(b'LABEL'), x(b'AS'), x(b'S'), x(b'GET')], [x(b'label'), x(b'session'), x(b'S')],
                                   [x(b'LABEL'), x(b'WHOAMI')], [x(b'LABEL'), x(b'help')], [x(b'LABEL')],
                                   [x(b'CONTEXT'), x(b'CREATE')], [x(b'CONTEXT'), x(b'HELP')], [x(b'context'), x(b'drop'), x(b'h')],
                                   [x(b'GET'), x(b'k')], [x(b'CONTEXT')]])
                emit('AS ' + ' '.join(map(arg_text, args)), f'AS|{int(m.script_denied(args))}')
                continue
            roll = rng.random()
            if roll < 0.32:
                args = inner_command(c, None)
            elif roll < 0.95:
                args = prefix(c) + inner_command(c, None)
            else:
                args = rng.choice([[x(b'LABEL'), x(b'AS')], [x(b'LABEL'), x(b'AS'), x(b'S')],
                                   [x(b'LABEL'), x(b'AS'), x(b'TOKEN'), x(b'GET')],
                                   [x(b'LABEL'), x(b'AS'), x(b'CONTEXT'), ('o',)],
                                   [x(b'LABEL'), x(b'AS'), x(b'C'), x(b'TRUST'), x(b'GET')]])
            kind = 'AH' if any(a[0] in ('h', 'H', 'o') for a in args) or any(m.word(a, b'context') for a in args[:3]) \
                or (len(args) > 3 and args[3][0] == 't' and m.tokens[args[3][1]]['ctx'] is not None) else 'AR'
            emit(f'{kind} {cid} ' + ' '.join(map(arg_text, args)), m.request(kind, cid, args))
    watch_keys = [b'w0', b'w1', b'w2']

    def labelled(label, words):
        return [x(b'LABEL'), x(b'AS'), x(marking_of(label))] + words if label is not None else words

    def request(cid, args):
        kind = 'AH' if any(m.word(a, b'context') for a in args[:3]) else 'AR'
        emit(f'{kind} {cid} ' + ' '.join(map(arg_text, args)), m.request(kind, cid, args))

    def watch_label(c):
        return known_label(c) if rng.random() < 0.6 else None

    def touch_label(c, aims):
        if aims and rng.random() < 0.6:
            base = rng.choice(aims)
            comps = frozenset(k for k in base[1] if rng.random() < 0.6)
            trusts = max(1, len(m.cfg.trusts))
            return (rng.randrange(base[0] + 1), comps, rng.randrange(base[2], trusts))
        return random_label()

    for session in range(watch_sessions):
        logins = open_session()
        for _ in range(episodes):
            roll = rng.random()
            if roll < 0.05:
                set_user(rng.choice(logins))
                continue
            cid = rng.choice(list(m.conns))
            c = m.conns[cid]
            if roll < 0.1 and c['multi']:
                request(cid, [x(b'DISCARD')])
            if rng.random() < 0.25:
                request(cid, labelled(watch_label(c) if rng.random() < 0.3 else None, [x(b'UNWATCH')]))
            if rng.random() < 0.2 and m.cfg.levels:
                parts = [x(b'LABEL'), x(b'SESSION'), x(marking_of(known_label(c)[:2] + (0,)))]
                request(cid, parts)
            multi_label = watch_label(c)
            same = rng.random() < 0.5
            aims = []
            for _ in range(rng.randint(1, 3)):
                label = multi_label if same else watch_label(c)
                if label is not None:
                    aims.append(label)
                keys = [x(k) for k in rng.sample(watch_keys, rng.randint(1, 2))]
                request(cid, labelled(label, [x(b'WATCH')] + keys))
            if not aims:
                aims.append(m.session(c))
            for _ in range(rng.choice([0, 1, 1, 2])):
                key = rng.choice(watch_keys)
                w = touch_label(c, aims)
                emit(f'AK {key.hex()} {helpers["label_text"](w)}', m.touch(key, w))
            if rng.random() < 0.25:
                request(cid, labelled(watch_label(c) if not same else multi_label, [x(b'WATCH'), x(rng.choice(watch_keys))]))
            if rng.random() < 0.15:
                login = rng.choice(logins)
                emit(f'AA {cid} {login.hex()}', m.auth(cid, login))
            request(cid, labelled(multi_label, [x(b'MULTI')]))
            for _ in range(rng.randint(0, 2)):
                body = rng.choice([[x(b'GET'), x(b'k')], [x(b'SET'), x(b'k'), x(b'v')], [x(b'PING')]])
                if c['multi'] and rng.random() < 0.3:
                    body = labelled(c['bound'], body)
                request(cid, body)
            if rng.random() < 0.15:
                request(cid, [x(b'WATCH'), x(rng.choice(watch_keys))])
            if rng.random() < 0.1:
                key = rng.choice(watch_keys)
                w = touch_label(c, aims)
                emit(f'AK {key.hex()} {helpers["label_text"](w)}', m.touch(key, w))
            end = [x(b'DISCARD')] if rng.random() < 0.08 else [x(b'EXEC')]
            roll = rng.random()
            if roll < 0.2:
                end = labelled(c['bound'], end)
            elif roll < 0.25:
                end = labelled(random_label(), end)
            request(cid, end)
    def acl_prefix(c):
        return [x(b'LABEL'), x(b'AS'), x(marking_of(known_label(c)))] if rng.random() < 0.4 else []

    def acl_inner(c):
        roll = rng.random()
        if roll < 0.35:
            return rng.choice([[x(b'SUBSCRIBE'), x(b'ch')], [x(b'CLIENT'), x(b'TRACKING'), x(b'on')]])
        if roll < 0.6:
            return rng.choice([[x(b'GET'), x(b'k')], [x(b'SWAPDB'), x(b'0'), x(b'1')], [x(b'MONITOR')], [x(b'BGREWRITEAOF')]])
        if roll < 0.7:
            return [x(b'LABEL'), x(b'SESSION'), x(marking_of(known_label(c)[:2] + (0,)))]
        return rng.choice([[x(b'PING')], [x(b'SAVE')], [x(b'DEBUG'), x(b'SLEEP'), x(b'0')], [x(b'CLIENT'), x(b'ID')],
                           [x(b'SET'), x(b'k'), x(b'v')], [x(b'PUBLISH'), x(b'ch'), x(b'm')]])

    def deny_line(kind, login):
        names = sorted(rng.sample(ACL_POOL, rng.randint(0, 4)))
        emit(f'{kind} {login.hex()} {names_text(names)}', f'{kind}|{m.deny(login, names)}')

    def kill_body():
        return rng.choice([[x(b'SCRIPT'), x(b'KILL')], [x(b'FUNCTION'), x(b'KILL')], [x(b'FUNCTION'), x(b'STATS')]])

    rng = random.Random(seed ^ 0xAC1)
    for session in range(acl_sessions):
        logins = open_session()
        for login in logins:
            if rng.random() < 0.8:
                deny_line('AP', login)
        for _ in range(acl_steps):
            roll = rng.random()
            if roll < 0.04:
                set_user(rng.choice(logins))
                continue
            if roll < 0.1:
                deny_line('AP', rng.choice(logins))
                continue
            cid = rng.choice(list(m.conns))
            c = m.conns[cid]
            if roll < 0.13:
                login = rng.choice(logins)
                emit(f'AA {cid} {login.hex()}', m.auth(cid, login))
                continue
            if roll < 0.3 and not c['multi'] and len(m.conns) > 1:
                args = acl_prefix(c) + [x(b'EVAL'), x(b'while true do end'), x(b'0')]
                emit(f'AE {cid} ' + ' '.join(map(arg_text, args)), m.busy_start('AE', cid, args))
                if m.busy is not None:
                    for _ in range(rng.randint(1, 3)):
                        other = rng.choice([k for k in m.conns if k != cid])
                        args = acl_prefix(m.conns[other]) + kill_body()
                        emit(f'AB {other} ' + ' '.join(map(arg_text, args)), m.busy_call('AB', other, args))
                continue
            if roll < 0.4 and not c['multi']:
                args = acl_prefix(c) + [x(b'MULTI')]
                emit(f'AR {cid} ' + ' '.join(map(arg_text, args)), m.request('AR', cid, args))
                for _ in range(rng.randint(0, 2)):
                    body = acl_inner(c)
                    emit(f'AR {cid} ' + ' '.join(map(arg_text, body)), m.request('AR', cid, body))
                end = [x(rng.choice([b'EXEC', b'DISCARD']))]
                emit(f'AR {cid} ' + ' '.join(map(arg_text, end)), m.request('AR', cid, end))
                continue
            args = acl_prefix(c) + acl_inner(c)
            emit(f'AR {cid} ' + ' '.join(map(arg_text, args)), m.request('AR', cid, args))

    label_model = m
    m = Owners(helpers, mutant)
    rng = random.Random(seed ^ 0x0AC1)
    emit('OT 0', 'OT|0')
    for session in range(owner_acl_sessions):
        logins = open_owner_session()
        for login in logins:
            if rng.random() < 0.8:
                deny_line('OP', login)
        for _ in range(owner_acl_steps):
            roll = rng.random()
            if roll < 0.04:
                set_owner_user(rng.choice(logins))
                continue
            if roll < 0.1:
                deny_line('OP', rng.choice(logins))
                continue
            cid = rng.choice(list(m.conns))
            c = m.conns[cid]
            if roll < 0.13:
                login = rng.choice(logins)
                emit(f'OA {cid} {login.hex()}', m.auth_o(cid, login))
                continue
            if roll < 0.4 and not c['multi'] and len(m.conns) > 1:
                args = owned_prefix(c, random_scope(c)) + [x(b'EVAL'), x(b'while true do end'), x(b'0')]
                emit(f'OS {cid} ' + ' '.join(map(arg_text, args)), m.busy_start_o(cid, args))
                if m.busy is not None:
                    for _ in range(rng.randint(1, 3)):
                        other = rng.choice([k for k in m.conns if k != cid])
                        args = owned_prefix(m.conns[other], random_scope(m.conns[other])) + kill_body()
                        emit(f'OB {other} ' + ' '.join(map(arg_text, args)), m.busy_call_o(other, args))
                continue
            if roll < 0.48 and not c['multi']:
                scope = random_scope(c)
                owner_request(cid, owned_prefix(c, scope) + [x(b'MULTI')])
                for _ in range(rng.randint(0, 2)):
                    owner_request(cid, acl_inner(c))
                owner_request(cid, [x(rng.choice([b'EXEC', b'DISCARD']))])
                continue
            pre = owned_prefix(c, random_scope(c)) if rng.random() < 0.6 else []
            owner_request(cid, pre + acl_inner(c))

    def veto_body():
        return rng.choice([[x(b'SUBSCRIBE'), x(b'ch')], [x(b'PSUBSCRIBE'), x(b'c*')], [x(b'SSUBSCRIBE'), x(b'sh')],
                           [x(b'CLIENT'), x(b'TRACKING'), x(b'on')], [x(b'CLIENT'), x(b'TRACKING'), x(b'on')], [x(b'GET'), x(b'k')],
                           [x(b'FUNCTION'), x(b'LOAD'), x(b'lib')], [x(b'SCRIPT'), x(b'FLUSH')], [x(b'FUNCTION'), x(b'FLUSH')],
                           [x(b'PING')], [x(b'SAVE')]])

    owner_veto_model = m
    m = label_model
    rng = random.Random(seed ^ 0x7E70)
    for session in range(veto_sessions):
        logins = open_session()
        for _ in range(veto_steps):
            roll = rng.random()
            cid = rng.choice(list(m.conns))
            c = m.conns[cid]
            if roll < 0.08:
                login = rng.choice(logins)
                emit(f'AA {cid} {login.hex()}', m.auth(cid, login))
                continue
            if roll < 0.16:
                args = [x(b'LABEL'), x(b'SESSION'), x(marking_of(known_label(c)[:2] + (0,)))]
                emit(f'AR {cid} ' + ' '.join(map(arg_text, args)), m.request('AR', cid, args))
                continue
            args = acl_prefix(c) + veto_body()
            kind = 'AV' if roll < 0.7 else 'AR'
            line = m.veto(cid, args) if kind == 'AV' else m.request('AR', cid, args)
            emit(f'{kind} {cid} ' + ' '.join(map(arg_text, args)), line)

    label_model = m
    m = Owners(helpers, mutant)
    rng = random.Random(seed ^ 0x7E71)
    emit('OT 0', 'OT|0')
    for session in range(veto_sessions):
        logins = open_owner_session()
        for _ in range(veto_steps):
            roll = rng.random()
            cid = rng.choice(list(m.conns))
            c = m.conns[cid]
            if roll < 0.08:
                login = rng.choice(logins)
                emit(f'OA {cid} {login.hex()}', m.auth_o(cid, login))
                continue
            scope = random_scope(c)
            if rng.random() < 0.15:
                scope = (scope[0], b'*')
            pre = owned_prefix(c, scope) if rng.random() < 0.7 else []
            args = pre + veto_body()
            if roll < 0.7:
                emit(f'OV {cid} ' + ' '.join(map(arg_text, args)), m.veto_o(cid, args))
            else:
                owner_request(cid, args)

    notes = dict(label_model.notes)
    for key in OWNER_NOTES:
        count = owner_model.notes.get(key, 0) + owner_veto_model.notes.get(key, 0) + m.notes.get(key, 0)
        if count:
            notes[key] = count
    for key, at in owner_marks.items():
        if key in OWNER_NOTES:
            marks.setdefault(key, at)
    return '\n'.join(trace) + '\n', expected, stats, dict(sorted(notes.items())), marks
