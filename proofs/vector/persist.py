import copy

FREE = 255
TWIN = 253
CAP = 30
CLAUSES = ('shape', 'free', 'slot', 'seq', 'level', 'degree', 'link', 'sym', 'entry', 'twin')
CLASS = {'shape': 'shape', 'free': 'free', 'slot': 'slot', 'seq': 'seq', 'level': 'graph', 'degree': 'graph',
         'link': 'link', 'sym': 'sym', 'entry': 'entry', 'twin': 'twin'}
STATES = []


def tokens(s):
    out = [s['m'], s['high'], s['uid'], s['entry'], s['top'], 1 if s['table'] else 0, len(s['free'])]
    out += s['free']
    out.append(len(s['elems']))
    for slot, seq in s['elems']:
        out += [slot, seq]
    for x in s['slots']:
        if x['level'] == TWIN:
            out += [TWIN, x['prev']]
        elif x['level'] <= CAP:
            out.append(x['level'])
            for l in x['lists']:
                out.append(len(l))
                out += l
        else:
            out.append(x['level'])
    return out


def verdicts(s):
    high = s['high']
    slots = s['slots']
    empty = {'level': FREE, 'prev': 0, 'lists': []}

    def at(i):
        return slots[i] if i < len(slots) else empty

    def level(i):
        return at(i)['level']

    def node(i):
        return i < high and level(i) <= CAP

    def twin(i):
        return i < high and level(i) == TWIN

    def links(i, l):
        ls = at(i)['lists']
        return ls[l] if l < len(ls) else []

    def prev(i):
        return at(i)['prev']

    def canon(x):
        if x['level'] == TWIN:
            first = x['lists'] == []
        else:
            first = x['prev'] == 0
        if x['level'] <= CAP:
            return first and len(x['lists']) == x['level'] + 1
        return first and x['lists'] == []

    free = s['free']
    slots_used = [e[0] for e in s['elems']]
    seqs = [e[1] for e in s['elems']]
    out = {}
    out['shape'] = (4 <= s['m'] <= 4096 and len(slots) == high and len(s['elems']) > 0 and
                    len(free) + len(s['elems']) == high and len(s['elems']) <= s['uid'] < 2 ** 63 and all(canon(x) for x in slots))
    out['free'] = all(f < high for f in free) and len(set(free)) == len(free)
    out['slot'] = all(e < high and e not in free for e in slots_used) and len(set(slots_used)) == len(slots_used)
    out['seq'] = all(1 <= q <= s['uid'] for q in seqs) and len(set(seqs)) == len(seqs)
    out['level'] = all(((i in free) == (level(i) == FREE)) and (level(i) <= CAP or level(i) in (TWIN, FREE))
                       for i in range(high))
    out['degree'] = all(not node(i) or all(len(links(i, l)) <= (2 * s['m'] if l == 0 else s['m'])
                                           for l in range(level(i) + 1)) for i in range(high))
    out['link'] = all(not node(i) or all(len(set(links(i, l))) == len(links(i, l)) and
                                         all(j < high and j != i and node(j) and l <= level(j) for j in links(i, l))
                                         for l in range(level(i) + 1)) for i in range(high))
    out['sym'] = all(not node(i) or all(i in links(j, l) for l in range(level(i) + 1) for j in links(i, l))
                     for i in range(high))
    out['entry'] = (node(s['entry']) and level(s['entry']) == s['top'] and
                    all(not node(i) or level(i) <= s['top'] for i in range(high)))
    twins = [i for i in range(high) if twin(i)]

    def reaches(k, t):
        for _ in range(k):
            p = prev(t)
            if node(p):
                return True
            if not twin(p):
                return False
            t = p
        return False

    out['twin'] = ((not twins or s['table']) and
                   all(prev(t) < high and prev(t) != t and (node(prev(t)) or twin(prev(t))) and reaches(len(twins), t)
                       for t in twins) and
                   len(set(prev(t) for t in twins)) == len(twins))
    return out


def row(s, skip=None):
    v = verdicts(s)
    for name in CLAUSES:
        if name != skip and not v[name]:
            return 'KS|0|' + CLASS[name]
    return 'KS|1|' + ','.join(map(str, tokens(s)))


def valid_state(rng):
    m = rng.choice((4, 5, 6))
    high = rng.randrange(2, 14)
    nfree = rng.randrange(0, high - 1)
    free = rng.sample(range(high), nfree)
    used = [i for i in range(high) if i not in free]
    rng.shuffle(used)
    kinds = {}
    nodes = [used[0]]
    kinds[used[0]] = rng.choice((0, 1, 2))
    for i in used[1:]:
        if rng.random() < 0.3:
            kinds[i] = TWIN
        else:
            kinds[i] = rng.choice((0, 0, 0, 1, 1, 2))
            nodes.append(i)
    prevs = {}
    taken = set()
    placed = list(nodes)
    for i in used:
        if kinds[i] != TWIN:
            continue
        options = [x for x in placed if x not in taken]
        p = rng.choice(options)
        prevs[i] = p
        taken.add(p)
        placed.append(i)
    lists = {i: [[] for _ in range(kinds[i] + 1)] for i in nodes}
    for l in range(3):
        members = [i for i in nodes if kinds[i] >= l]
        cap = 2 * m if l == 0 else m
        pairs = [(a, b) for a in members for b in members if a < b]
        rng.shuffle(pairs)
        for a, b in pairs:
            if rng.random() < 0.55 and len(lists[a][l]) < cap and len(lists[b][l]) < cap:
                lists[a][l].append(b)
                lists[b][l].append(a)
    for i in nodes:
        for l in lists[i]:
            rng.shuffle(l)
    top = max(kinds[i] for i in nodes)
    entry = rng.choice([i for i in nodes if kinds[i] == top])
    uid = len(used) + rng.randrange(0, 6)
    seqs = rng.sample(range(1, uid + 1), len(used))
    slots = []
    for i in range(high):
        if i in free:
            slots.append({'level': FREE, 'prev': 0, 'lists': []})
        elif kinds[i] == TWIN:
            slots.append({'level': TWIN, 'prev': prevs[i], 'lists': []})
        else:
            slots.append({'level': kinds[i], 'prev': 0, 'lists': lists[i]})
    has_twins = any(kinds[i] == TWIN for i in used)
    return {'m': m, 'high': high, 'uid': uid, 'entry': entry, 'top': top, 'table': has_twins or rng.random() < 0.2,
            'free': free, 'elems': list(zip(used, seqs)), 'slots': slots}


def nodes_of(s, minimum=0):
    return [i for i, x in enumerate(s['slots']) if x['level'] <= CAP and x['level'] >= minimum]


def twins_of(s):
    return [i for i, x in enumerate(s['slots']) if x['level'] == TWIN]


def faults(rng, base):
    out = []

    def make(name, fn):
        s = copy.deepcopy(base)
        if fn(s) is not False:
            out.append((name, s))

    make('m below four', lambda s: s.update(m=3))
    make('counter at the limit', lambda s: s.update(uid=2 ** 63))
    make('free slot beyond the slots', lambda s: len(s['free']) > 0 and s['free'].__setitem__(0, s['high'] + 2))
    make('free slot repeated', lambda s: len(s['free']) > 1 and s['free'].__setitem__(1, s['free'][0]))
    make('element beyond the slots', lambda s: s['elems'].__setitem__(0, (s['high'] + 1, s['elems'][0][1])))
    make('element slot repeated', lambda s: len(s['elems']) > 1 and s['elems'].__setitem__(1, (s['elems'][0][0], s['elems'][1][1])))
    make('element on a free slot', lambda s: len(s['free']) > 0 and s['elems'].__setitem__(0, (s['free'][0], s['elems'][0][1])))
    make('sequence zero', lambda s: s['elems'].__setitem__(0, (s['elems'][0][0], 0)))
    make('sequence above the counter', lambda s: s['elems'].__setitem__(0, (s['elems'][0][0], s['uid'] + 1)))
    make('sequence repeated', lambda s: len(s['elems']) > 1 and s['elems'].__setitem__(1, (s['elems'][1][0], s['elems'][0][1])))

    def bad_level(s):
        i = s['elems'][0][0]
        s['slots'][i] = {'level': 40, 'prev': 0, 'lists': []}

    make('level outside every kind', bad_level)

    def free_on_element(s):
        i = s['elems'][-1][0]
        s['slots'][i] = {'level': FREE, 'prev': 0, 'lists': []}

    make('free level on an element', free_on_element)

    def node_on_free(s):
        if not s['free']:
            return False
        s['slots'][s['free'][0]] = {'level': 0, 'prev': 0, 'lists': [[]]}

    make('node level on a free slot', node_on_free)

    def degree(s):
        a = nodes_of(s)[0]
        while len(s['slots'][a]['lists'][0]) <= 2 * s['m']:
            s['slots'][a]['lists'][0].append(a)

    make('layer zero above two M', degree)

    def first_link(s, layer=0):
        for a in nodes_of(s, layer):
            if s['slots'][a]['lists'][layer]:
                return a
        return None

    def self_link(s):
        a = first_link(s)
        if a is None or len(s['slots'][a]['lists'][0]) >= 2 * s['m']:
            return False
        s['slots'][a]['lists'][0].append(a)

    make('link to itself', self_link)

    def far_link(s):
        a = first_link(s)
        if a is None:
            return False
        s['slots'][a]['lists'][0][0] = s['high'] + 1

    make('link beyond the slots', far_link)

    def repeat_link(s):
        a = first_link(s)
        if a is None or len(s['slots'][a]['lists'][0]) >= 2 * s['m']:
            return False
        s['slots'][a]['lists'][0].append(s['slots'][a]['lists'][0][0])

    make('link repeated', repeat_link)

    def free_link(s):
        a = first_link(s)
        if a is None or not s['free']:
            return False
        s['slots'][a]['lists'][0][0] = s['free'][0]

    make('link to a free slot', free_link)

    def twin_link(s):
        a = first_link(s)
        ts = twins_of(s)
        if a is None or not ts:
            return False
        s['slots'][a]['lists'][0][0] = ts[0]

    make('link to a twin', twin_link)

    def low_link(s):
        a = first_link(s, 1)
        lows = [i for i in nodes_of(s) if s['slots'][i]['level'] == 0]
        if a is None or not lows or len(s['slots'][a]['lists'][1]) >= s['m']:
            return False
        if lows[0] in s['slots'][a]['lists'][1]:
            return False
        s['slots'][a]['lists'][1].append(lows[0])

    make('upper link to a lower node', low_link)

    def one_way(s):
        a = first_link(s)
        if a is None:
            return False
        b = s['slots'][a]['lists'][0][0]
        s['slots'][b]['lists'][0].remove(a)

    make('one way link', one_way)

    def low_entry(s):
        lows = [i for i in nodes_of(s) if s['slots'][i]['level'] < s['top']]
        if not lows:
            return False
        s['entry'] = lows[0]

    make('entry below the top', low_entry)

    def raised_top(s):
        if s['top'] >= CAP:
            return False
        s['top'] += 1

    make('top above every node', raised_top)

    def twin_entry(s):
        ts = twins_of(s)
        if not ts:
            return False
        s['entry'] = ts[0]

    make('entry on a twin', twin_entry)

    def twin_self(s):
        ts = twins_of(s)
        if not ts:
            return False
        s['slots'][ts[0]]['prev'] = ts[0]

    make('twin after itself', twin_self)

    def twin_far(s):
        ts = twins_of(s)
        if not ts:
            return False
        s['slots'][ts[0]]['prev'] = s['high'] + 1

    make('twin after nothing', twin_far)

    def twin_free(s):
        ts = twins_of(s)
        if not ts or not s['free']:
            return False
        s['slots'][ts[0]]['prev'] = s['free'][0]

    make('twin after a free slot', twin_free)

    def twin_fork(s):
        ts = twins_of(s)
        if len(ts) < 2:
            return False
        p = s['slots'][ts[0]]['prev']
        if p == ts[1]:
            return False
        s['slots'][ts[1]]['prev'] = p

    make('two twins after one slot', twin_fork)

    def twin_cycle(s):
        ts = twins_of(s)
        heads = [t for t in ts if s['slots'][s['slots'][t]['prev']]['level'] <= CAP]
        followers = {s['slots'][t]['prev'] for t in ts}
        loose = [t for t in heads if t not in followers]
        if len(loose) < 2:
            return False
        x, y = loose[0], loose[1]
        s['slots'][x]['prev'] = y
        s['slots'][y]['prev'] = x

    make('twins in a cycle', twin_cycle)

    def no_table(s):
        if not twins_of(s):
            return False
        s['table'] = False

    make('twins without their table', no_table)
    return out


def persist_corpus(rng, emit, stats):
    STATES.clear()
    for key in ('persist_rows', 'persist_valid', 'persist_rejected', 'persist_twins', 'persist_upper', 'persist_free'):
        stats[key] = 0
    classes = {}
    for _ in range(260):
        base = valid_state(rng)
        cases = [('valid', base)]
        if rng.random() < 0.6:
            options = faults(rng, base)
            if options:
                cases.append(rng.choice(options))
        for name, s in cases:
            r = row(s)
            STATES.append(s)
            emit('KS ' + ' '.join(map(str, tokens(s))), r)
            stats['persist_rows'] += 1
            if r.startswith('KS|1|'):
                stats['persist_valid'] += 1
                stats['persist_twins'] += len(twins_of(s))
                stats['persist_upper'] += sum(x['level'] for x in s['slots'] if x['level'] <= CAP)
                stats['persist_free'] += len(s['free'])
            else:
                stats['persist_rejected'] += 1
                classes[r[5:]] = classes.get(r[5:], 0) + 1
    for name in CLASS.values():
        if not classes.get(name):
            raise AssertionError('the persistence corpus has no rejected row of class ' + name)
    stats['persist_classes'] = len(classes)


def mutant_rows(skip):
    return [row(s, skip) for s in STATES]
