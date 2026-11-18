import argparse
import json
import multiprocessing
import os
import random
import signal
import statistics
import struct
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from harness import Conn, Container, Server, ServerError, encode, parse_info, process_status

SCHEMA = 'eski-baseline-search-v1'
TARGETS = ('eski', 'redis-search')
VOCABULARY = ('amber', 'basil', 'cedar', 'delta', 'ember', 'fennel', 'gamma', 'harbor', 'indigo', 'juniper', 'kestrel', 'lumen',
              'maple', 'nectar', 'onyx', 'pepper', 'quartz', 'raven', 'saffron', 'tundra', 'umber', 'velvet', 'willow', 'xenon',
              'yonder', 'zephyr', 'anchor', 'bramble', 'cobalt', 'dune', 'falcon', 'glacier')
TAGS = 16
DIM = 16
HASH = 'bench:h:'
JSON_PREFIX = 'bench:j:'
NORMALIZATIONS = {
    'projection-field-order': 'Search projections are field dictionaries; the reference puts a sort key first. The projected fields, their values '
                              'and the result order must match.',
    'hybrid-execution-time': 'FT.HYBRID execution_time measures the current execution and is removed; all rows and scores must match.',
    'cursor-id': 'Cursor ids are allocated independently and are removed; every page of rows must match.',
}
KNOWN_UNEQUAL = {
    'hybrid-rrf': 'FT.HYBRID with COMBINE RRF returns a different total and different fused scores from the reference on this corpus; the request '
                  'is checked on every run and timed only once the replies are equal.',
    'hybrid-linear': 'FT.HYBRID with COMBINE LINEAR returns a different total and a different set of fused rows from the reference on this '
                     'corpus; the request is checked on every run and timed only once the replies are equal.',
}
KNOWN_DIFFERENCES = {
    'hnsw': 'HNSW is approximate: the two engines build different graphs, and neither builds the same graph twice, so the neighbours they '
            'return for one query may differ; a reply is within the difference only when it has the same total and the same number of '
            'results and every key both replies return carries the same fields, so a wrong distance or a short or failed reply is '
            'unexpected; the request is timed with the difference counted',
    'score-ties': 'Eski orders documents with equal scores differently from the reference, and a page can end inside a group of equal scores; '
                  'replies are compared exactly and counted, a reply that also differs in its scores or in the keys of a complete group of equal '
                  'scores is an unexpected difference, and the request is timed with the difference counted',
    'number-array-format': 'The reference prints a JSON number array whose elements are all exact in half precision in its shortest half '
                           'precision form, Eski in the shortest double form; replies are compared exactly and counted, a reply that also '
                           'differs once both are parsed and their numbers rounded to half precision is an unexpected difference, and the '
                           'request is timed with the difference counted',
}


def interrupted(signum, frame):
    raise KeyboardInterrupt


def vector(rng):
    return [round(rng.uniform(-1, 1) * 1024) / 1024 for _ in range(DIM)]


def blob(values):
    return struct.pack('<%df' % len(values), *values)


class Corpus:
    def __init__(self, size, seed):
        rng = random.Random(seed)
        order = list(range(size))
        rng.shuffle(order)
        weights = [1 / (rank + 1) for rank in range(len(VOCABULARY))]
        self.size = size
        self.docs = []
        for i in range(size):
            title = ' '.join(rng.choices(VOCABULARY, weights, k=3))
            body = ' '.join(rng.choices(VOCABULARY, weights, k=12))
            self.docs.append(dict(title=title, body=body, tag='t%d' % (i % TAGS), num=order[i], vec=vector(rng),
                                  tags=['k%d' % (i % 5), 'k%d' % (i % 7)]))
        self.probes = [vector(rng) for _ in range(64)]

    def hash_frames(self):
        return [encode(('HSET', '%s%d' % (HASH, i), 'title', d['title'], 'body', d['body'], 'tag', d['tag'], 'num', d['num'], 'vec', blob(d['vec'])))
                for i, d in enumerate(self.docs)]

    def json_text(self, i, vectors=True):
        d = self.docs[i]
        value = dict(title=d['title'], body=d['body'], tag=d['tag'], num=d['num'], tags=d['tags'])
        if vectors:
            value['vec'] = d['vec']
        return json.dumps(value, separators=(',', ':'))

    def json_frames(self, vectors=True):
        return [encode(('JSON.SET', '%s%d' % (JSON_PREFIX, i), '$', self.json_text(i, vectors))) for i in range(self.size)]


def index_specs(area):
    vec_flat = ['VECTOR', 'FLAT', '6', 'TYPE', 'FLOAT32', 'DIM', str(DIM), 'DISTANCE_METRIC', 'L2']
    vec_hnsw = ['VECTOR', 'HNSW', '6', 'TYPE', 'FLOAT32', 'DIM', str(DIM), 'DISTANCE_METRIC', 'L2']
    hash_on = ['ON', 'HASH', 'PREFIX', '1', HASH, 'SCHEMA']
    json_on = ['ON', 'JSON', 'PREFIX', '1', JSON_PREFIX, 'SCHEMA']
    if area == 'search-hash':
        return {'h-fields': hash_on + ['title', 'TEXT', 'tag', 'TAG', 'num', 'NUMERIC', 'SORTABLE']}
    if area in ('search-json', 'json'):
        return {'j-fields': json_on + ['$.title', 'AS', 'title', 'TEXT', '$.tag', 'AS', 'tag', 'TAG', '$.num', 'AS', 'num', 'NUMERIC', 'SORTABLE']}
    if area == 'full-text':
        return {'h-text': hash_on + ['title', 'TEXT', 'WEIGHT', '2', 'body', 'TEXT', 'num', 'NUMERIC', 'SORTABLE']}
    if area == 'vector-search':
        return {'h-flat': hash_on + ['vec'] + vec_flat, 'h-hnsw': hash_on + ['vec'] + vec_hnsw,
                'j-flat': json_on + ['$.vec', 'AS', 'vec'] + vec_flat, 'j-hnsw': json_on + ['$.vec', 'AS', 'vec'] + vec_hnsw}
    if area == 'hybrid':
        return {'h-hybrid': hash_on + ['title', 'TEXT', 'body', 'TEXT', 'tag', 'TAG', 'num', 'NUMERIC', 'SORTABLE', 'vec'] + vec_flat}
    if area == 'aggregate':
        return {'h-agg': hash_on + ['title', 'TEXT', 'tag', 'TAG', 'SORTABLE', 'num', 'NUMERIC', 'SORTABLE']}
    raise ValueError(area)


def storages(area):
    if area in ('search-json', 'json'):
        return ('json',)
    if area == 'vector-search':
        return ('hash', 'json')
    return ('hash',)


def shapes(area, corpus):
    words = VOCABULARY[:12]
    n = corpus.size
    out = []

    def add(name, make, kind='read', difference=None):
        out.append(dict(name=name, make=make, kind=kind, difference=difference))
    if area in ('search-hash', 'search-json'):
        index = 'h-fields' if area == 'search-hash' else 'j-fields'
        title = 'title' if area == 'search-hash' else '$.title'
        add('term', lambda r: (('FT.SEARCH', index, '@title:%s' % r.choice(words), 'SORTBY', 'num', 'ASC', 'NOCONTENT', 'LIMIT', '0', '10', 'DIALECT', '2'),))
        add('tag', lambda r: (('FT.SEARCH', index, '@tag:{t%d}' % r.randrange(TAGS), 'SORTBY', 'num', 'ASC', 'NOCONTENT', 'LIMIT', '0', '10', 'DIALECT', '2'),))
        add('numeric-range', lambda r: (lambda lo: (('FT.SEARCH', index, '@num:[%d %d]' % (lo, lo + max(4, n // 20)), 'SORTBY', 'num', 'ASC', 'NOCONTENT',
                                                    'LIMIT', '0', '10', 'DIALECT', '2'),))(r.randrange(n)))
        add('combined', lambda r: (('FT.SEARCH', index, '@title:%s @tag:{t%d} @num:[0 %d]' % (r.choice(words), r.randrange(TAGS), n // 2), 'SORTBY', 'num',
                                    'DESC', 'NOCONTENT', 'LIMIT', '0', '10', 'DIALECT', '2'),))
        add('sorted-page', lambda r: (('FT.SEARCH', index, '*', 'SORTBY', 'num', 'DESC', 'LIMIT', str(r.randrange(max(1, n - 10))), '10', 'RETURN', '2', title, 'num',
                                       'DIALECT', '2'),))
        add('count', lambda r: (('FT.SEARCH', index, '@tag:{t%d}' % r.randrange(TAGS), 'LIMIT', '0', '0', 'DIALECT', '2'),))
    elif area == 'full-text':
        ties = 'score-ties'
        add('one-term', lambda r: (('FT.SEARCH', 'h-text', r.choice(words), 'WITHSCORES', 'NOCONTENT', 'LIMIT', '0', '10'),), difference=ties)
        add('two-terms', lambda r: (('FT.SEARCH', 'h-text', '%s %s' % tuple(r.sample(words, 2)), 'WITHSCORES', 'NOCONTENT', 'LIMIT', '0', '10'),), difference=ties)
        add('three-terms', lambda r: (('FT.SEARCH', 'h-text', '%s %s %s' % tuple(r.sample(words, 3)), 'WITHSCORES', 'NOCONTENT', 'LIMIT', '0', '10'),),
            difference=ties)
        add('phrase', lambda r: (('FT.SEARCH', 'h-text', '"%s %s"' % tuple(r.sample(words[:4], 2)), 'WITHSCORES', 'NOCONTENT', 'LIMIT', '0', '10'),),
            difference=ties)
        add('prefix', lambda r: (('FT.SEARCH', 'h-text', '%s*' % r.choice(words)[:3], 'WITHSCORES', 'NOCONTENT', 'LIMIT', '0', '10'),), difference=ties)
        add('either', lambda r: (('FT.SEARCH', 'h-text', '%s|%s' % tuple(r.sample(words, 2)), 'WITHSCORES', 'NOCONTENT', 'LIMIT', '0', '10'),), difference=ties)
        add('field-term', lambda r: (('FT.SEARCH', 'h-text', '@title:%s' % r.choice(words), 'WITHSCORES', 'NOCONTENT', 'LIMIT', '0', '10'),), difference=ties)
    elif area == 'vector-search':
        for index, kind in (('h-flat', None), ('h-hnsw', 'hnsw'), ('j-flat', None), ('j-hnsw', 'hnsw')):
            add('knn-' + index, (lambda index: lambda r: (('FT.SEARCH', index, '*=>[KNN 10 @vec $v AS d]', 'PARAMS', '2', 'v', blob(r.choice(corpus.probes)),
                                                           'SORTBY', 'd', 'RETURN', '1', 'd', 'DIALECT', '2'),))(index), difference=kind)
        add('range-h-flat', lambda r: (('FT.SEARCH', 'h-flat', '@vec:[VECTOR_RANGE 2.5 $v]=>{$YIELD_DISTANCE_AS: d}', 'PARAMS', '2', 'v', blob(r.choice(corpus.probes)),
                                        'SORTBY', 'd', 'LIMIT', '0', '10', 'RETURN', '1', 'd', 'DIALECT', '2'),))
    elif area == 'hybrid':
        add('knn-tag-filter', lambda r: (('FT.SEARCH', 'h-hybrid', '(@tag:{t%d})=>[KNN 10 @vec $v AS d]' % r.randrange(TAGS), 'PARAMS', '2', 'v', blob(r.choice(corpus.probes)),
                                          'SORTBY', 'd', 'RETURN', '1', 'd', 'DIALECT', '2'),))
        add('knn-text-filter', lambda r: (('FT.SEARCH', 'h-hybrid', '(@title:%s)=>[KNN 10 @vec $v AS d]' % r.choice(words[:6]), 'PARAMS', '2', 'v', blob(r.choice(corpus.probes)),
                                           'SORTBY', 'd', 'RETURN', '1', 'd', 'DIALECT', '2'),))
        add('knn-range-filter', lambda r: (('FT.SEARCH', 'h-hybrid', '(@num:[0 %d])=>[KNN 10 @vec $v AS d]' % (n // 3), 'PARAMS', '2', 'v', blob(r.choice(corpus.probes)),
                                            'SORTBY', 'd', 'RETURN', '1', 'd', 'DIALECT', '2'),))
        add('hybrid-rrf', lambda r: (('FT.HYBRID', 'h-hybrid', 'SEARCH', r.choice(words[:6]), 'VSIM', '@vec', '$q', 'KNN', '2', 'K', '10', 'COMBINE', 'RRF', '2',
                                      'CONSTANT', '60', 'LIMIT', '0', '10', 'PARAMS', '2', 'q', blob(r.choice(corpus.probes))),))
        add('hybrid-linear', lambda r: (('FT.HYBRID', 'h-hybrid', 'SEARCH', r.choice(words[:6]), 'VSIM', '@vec', '$q', 'KNN', '2', 'K', '10', 'COMBINE', 'LINEAR', '4',
                                         'ALPHA', '0.5', 'BETA', '0.5', 'LIMIT', '0', '10', 'PARAMS', '2', 'q', blob(r.choice(corpus.probes))),))
    elif area == 'aggregate':
        add('group-count', lambda r: (('FT.AGGREGATE', 'h-agg', '*', 'GROUPBY', '1', '@tag', 'REDUCE', 'COUNT', '0', 'AS', 'n', 'SORTBY', '2', '@tag', 'ASC',
                                       'LIMIT', '0', '50'),))
        add('group-reducers', lambda r: (('FT.AGGREGATE', 'h-agg', '@title:%s' % r.choice(words), 'GROUPBY', '1', '@tag', 'REDUCE', 'SUM', '1', '@num', 'AS', 's',
                                          'REDUCE', 'MIN', '1', '@num', 'AS', 'lo', 'REDUCE', 'MAX', '1', '@num', 'AS', 'hi', 'REDUCE', 'COUNT_DISTINCT', '1', '@num', 'AS', 'd',
                                          'SORTBY', '2', '@tag', 'ASC', 'LIMIT', '0', '50'),))
        add('apply-sort', lambda r: (('FT.AGGREGATE', 'h-agg', '@tag:{t%d}' % r.randrange(TAGS), 'LOAD', '1', '@num', 'APPLY', '@num * 2', 'AS', 'twice',
                                      'SORTBY', '2', '@twice', 'DESC', 'LIMIT', '0', '10'),))
        add('filter', lambda r: (('FT.AGGREGATE', 'h-agg', '*', 'LOAD', '1', '@num', 'FILTER', '@num < %d' % r.randrange(1, n), 'GROUPBY', '1', '@tag',
                                  'REDUCE', 'COUNT', '0', 'AS', 'n', 'SORTBY', '2', '@tag', 'ASC', 'LIMIT', '0', '50'),))
        add('cursor', lambda r: (('CURSOR', 'h-agg', '@tag:{t%d}' % r.randrange(TAGS), 'LOAD', '1', '@num', 'SORTBY', '2', '@num', 'ASC', 'MAX', str(n),
                                  'WITHCURSOR', 'COUNT', '5'),))
    elif area == 'json':
        def key(r, owner):
            return '%s%d' % (JSON_PREFIX, owner(r))
        add('set-document', lambda r, k: (('JSON.SET', k, '$', corpus.json_text(int(k[len(JSON_PREFIX):]))),), 'write')
        add('set-path', lambda r, k: (('JSON.SET', k, '$.num', str(corpus.docs[int(k[len(JSON_PREFIX):])]['num'])),), 'write')
        add('numincrby-pair', lambda r, k: (('JSON.NUMINCRBY', k, '$.num', '3'), ('JSON.NUMINCRBY', k, '$.num', '-3')), 'write')
        add('arrappend-pop', lambda r, k: (('JSON.ARRAPPEND', k, '$.tags', '"extra"'), ('JSON.ARRPOP', k, '$.tags')), 'write')
        add('merge', lambda r, k: (('JSON.MERGE', k, '$', '{"tag":"%s"}' % corpus.docs[int(k[len(JSON_PREFIX):])]['tag']),), 'write')
        add('set-del-field', lambda r, k: (('JSON.SET', k, '$.extra', '1'), ('JSON.DEL', k, '$.extra')), 'write')
        add('get-path', lambda r, k: (('JSON.GET', k, '$.title'),), 'read')
        add('get-document', lambda r, k: (('JSON.GET', k),), 'read', 'number-array-format')
        add('mget', lambda r, k: (('JSON.MGET', k, '%s%d' % (JSON_PREFIX, r.randrange(n)), '$.num'),), 'read')
        add('type-strlen', lambda r, k: (('JSON.TYPE', k, '$.title'), ('JSON.STRLEN', k, '$.title')), 'read')
        add('objkeys-arrlen', lambda r, k: (('JSON.OBJKEYS', k, '$'), ('JSON.ARRLEN', k, '$.tags'), ('JSON.OBJLEN', k, '$')), 'read')
    return out


def normalize(reply):
    if isinstance(reply, ServerError):
        return ['error', str(reply)]
    if isinstance(reply, bytes):
        return reply.decode('latin-1')
    if isinstance(reply, list):
        return [normalize(item) for item in reply]
    return reply


def projection_view(reply):
    if not isinstance(reply, list):
        return reply
    out = []
    for item in reply:
        if isinstance(item, list) and len(item) % 2 == 0 and all(isinstance(name, str) for name in item[::2]):
            out.append(sorted([item[i], item[i + 1]] for i in range(0, len(item), 2)))
        else:
            out.append(item)
    return out


def tie_view(entries):
    groups = []
    for key, score in entries:
        if groups and groups[-1][0] == score:
            groups[-1][1].append(key)
        else:
            groups.append([score, [key]])
    view = [[score, sorted(keys)] for score, keys in groups[:-1]]
    if groups:
        view.append([groups[-1][0], len(groups[-1][1])])
    return view


def scored_view(reply):
    if isinstance(reply, list) and reply and isinstance(reply[0], int) and len(reply) % 2 == 1:
        return [reply[0], 'score-ties', tie_view([(reply[i], reply[i + 1]) for i in range(1, len(reply), 2)])]
    return reply


def hybrid_view(reply):
    if isinstance(reply, list) and len(reply) % 2 == 0:
        pairs = [[reply[i], reply[i + 1]] for i in range(0, len(reply), 2) if reply[i] != 'execution_time']
        for pair in pairs:
            if pair[0] == 'results' and isinstance(pair[1], list):
                rows = [dict(zip(row[::2], row[1::2])) for row in pair[1] if isinstance(row, list)]
                if all('__key' in row and '__score' in row for row in rows):
                    pair[1] = ['score-ties', tie_view([(row['__key'], row['__score']) for row in rows])]
        return pairs
    return reply


def rounded(value):
    if isinstance(value, float):
        try:
            return struct.unpack('<e', struct.pack('<e', value))[0]
        except (OverflowError, struct.error):
            return value
    if isinstance(value, list):
        return [rounded(item) for item in value]
    if isinstance(value, dict):
        return {key: rounded(item) for key, item in value.items()}
    return value


def parsed_numbers(reply):
    try:
        return [rounded(json.loads(item)) if isinstance(item, str) else item for item in reply]
    except ValueError:
        return None


def keyed(reply):
    if not isinstance(reply, list):
        return None, None
    total = None
    pairs = reply
    if reply and isinstance(reply[0], int) and len(reply) % 2 == 1:
        total, pairs = reply[0], reply[1:]
    keys = pairs[0::2]
    if len(pairs) % 2 or not all(isinstance(key, str) for key in keys) or len(set(keys)) != len(keys):
        return None, None
    return total, dict(zip(keys, pairs[1::2]))


def approximate_neighbours(eski, reference):
    if not isinstance(eski, list) or not isinstance(reference, list) or len(eski) != len(reference):
        return False
    for mine, theirs in zip(eski, reference):
        total, found = keyed(mine)
        other_total, other = keyed(theirs)
        if found is None or other is None or total != other_total or len(found) != len(other):
            return False
        if any(found[key] != other[key] for key in found.keys() & other.keys()):
            return False
    return True


def within_difference(name, eski, reference):
    if name == 'hnsw':
        return approximate_neighbours(eski, reference)
    if name == 'score-ties':
        return [scored_view(item) for item in eski] == [scored_view(item) for item in reference]
    if name == 'number-array-format':
        view = parsed_numbers(eski)
        return view is not None and view == parsed_numbers(reference)
    return False


def call(conn, argv):
    conn.s.sendall(encode(argv))
    return conn.reply()


def execute(conn, request):
    replies = []
    for argv in request:
        if argv[0] == 'CURSOR':
            first = call(conn, ('FT.AGGREGATE',) + tuple(argv[1:]))
            pages = []
            while isinstance(first, list) and len(first) == 2 and isinstance(first[1], int):
                pages.append(normalize(first[0]))
                if first[1] == 0:
                    break
                first = call(conn, ('FT.CURSOR', 'READ', argv[1], first[1]))
            if not pages:
                pages.append(normalize(first))
            replies.append(['cursor-pages', pages])
        elif argv[0] == 'FT.HYBRID':
            replies.append(hybrid_view(normalize(call(conn, argv))))
        elif argv[0] == 'FT.SEARCH':
            replies.append(projection_view(normalize(call(conn, argv))))
        else:
            replies.append(normalize(call(conn, argv)))
    return replies


def plan_requests(area, corpus, shape_list, count, connections, seed):
    rng = random.Random(seed)
    plan = []
    owned = [list(range(owner, corpus.size, connections)) for owner in range(connections)]
    for i in range(count):
        shape = shape_list[i % len(shape_list)] if i < len(shape_list) else rng.choice(shape_list)
        owner = i % connections
        if area == 'json':
            request = shape['make'](rng, '%s%d' % (JSON_PREFIX, rng.choice(owned[owner])))
        else:
            request = shape['make'](rng)
        plan.append(dict(shape=shape['name'], owner=owner, request=tuple(tuple(part) for part in request)))
    return plan


def key_of(request):
    return repr(request)


def wait_indexed(conn, names, timeout=600):
    deadline = time.monotonic() + timeout
    while True:
        pending = []
        for name in names:
            info = conn.call('FT.INFO', name)
            fields = dict(zip(info[::2], info[1::2])) if isinstance(info, list) else {}
            indexing = fields.get(b'indexing', fields.get('indexing'))
            percent = fields.get(b'percent_indexed', fields.get('percent_indexed'))
            if str(normalize(indexing)) not in ('0', 'None') or (percent is not None and float(normalize(percent)) < 1):
                pending.append(name)
        if not pending:
            return
        if time.monotonic() > deadline:
            raise RuntimeError('indexes %s did not finish' % pending)
        time.sleep(0.002)


def load(conn, corpus, area):
    frames = []
    for storage in storages(area):
        frames += corpus.hash_frames() if storage == 'hash' else corpus.json_frames()
    started = time.perf_counter()
    replies = conn.pipeline(frames, window=256)
    seconds = time.perf_counter() - started
    bad = [r for r in replies if isinstance(r, ServerError) or (r != 'OK' and not isinstance(r, int))]
    if bad:
        raise RuntimeError('loading the corpus failed: %r' % bad[:3])
    return dict(seconds=seconds, commands=len(frames))


def build_indexes(conn, area):
    started = time.perf_counter()
    specs = index_specs(area)
    for name, argv in specs.items():
        reply = conn.call('FT.CREATE', name, *argv)
        if reply != 'OK':
            raise RuntimeError('FT.CREATE %s returned %r' % (name, reply))
    wait_indexed(conn, list(specs))
    return dict(seconds=time.perf_counter() - started, indexes=list(specs))


def memory(conn, pid, container=None):
    info = parse_info(conn.call('INFO', 'memory'))
    row = {name: int(info[name]) for name in ('used_memory', 'used_memory_rss', 'used_memory_peak') if name in info and info[name].strip().isdigit()}
    status = process_status(pid) if pid else {}
    row.update(rss_bytes=status.get('VmRSS'), peak_rss_bytes=status.get('VmHWM'))
    if container is not None:
        row['cgroup'] = container.memory().get('cgroup')
    return row


def start(target, args, port, folder):
    if target == 'eski':
        server = Server(args.server, port, folder, ('--maxmemory', '4gb'), cpus=args.server_cpus)
        return server, server.pid, None
    container = Container('eski-baseline-search-%d-%d' % (port, os.getpid()), args.image,
                          ['redis-server', '--bind', '127.0.0.1', '--port', port, '--protected-mode', 'yes', '--save', '', '--appendonly', 'no',
                           '--maxmemory', '4gb'], port, folder, cpus=args.server_cpus, memory=args.server_memory, tmpfs='/data:rw,size=64m')
    return container, container.pid, container


def worker(port, requests, expected, path, barrier):
    conn = Conn(port, timeout=120)
    samples = []
    errors = []
    barrier.wait()
    for number, (shape, request) in enumerate(requests):
        tick = time.perf_counter_ns()
        try:
            got = execute(conn, request)
        except (ServerError, OSError, EOFError) as error:
            got = ['exception', str(error)]
        samples.append((shape, time.perf_counter_ns() - tick))
        if got != expected[key_of(request)]:
            errors.append(dict(request=number, shape=shape))
    conn.close()
    Path(path).write_text(json.dumps(dict(samples=samples, errors=errors)))


def timed(port, plan, expected, connections, folder):
    context = multiprocessing.get_context('fork')
    barrier = context.Barrier(connections + 1)
    shares = [[(p['shape'], p['request']) for p in plan if p['owner'] == k] for k in range(connections)]
    paths = [folder / ('connection-%d.json' % k) for k in range(connections)]
    processes = [context.Process(target=worker, args=(port, shares[k], expected, paths[k], barrier)) for k in range(connections)]
    for process in processes:
        process.start()
    try:
        barrier.wait(timeout=120)
        started = time.perf_counter()
        for process in processes:
            process.join()
        seconds = time.perf_counter() - started
    finally:
        for process in processes:
            if process.is_alive():
                process.terminate()
                process.join()
    if any(process.exitcode for process in processes):
        raise RuntimeError('a client connection failed')
    by_shape, errors = {}, []
    for path in paths:
        data = json.loads(path.read_text())
        errors += data['errors']
        for shape, ns in data['samples']:
            by_shape.setdefault(shape, []).append(ns)
    total = sum(len(v) for v in by_shape.values())
    failed = {}
    for error in errors:
        failed[error['shape']] = failed.get(error['shape'], 0) + 1
    return dict(connections=connections, requests=total, seconds=seconds, errors=len(errors),
                successful_requests_per_s=(total - len(errors)) / seconds if seconds else None,
                by_shape={shape: dict(requests=len(v), errors=failed.get(shape, 0), latency_us=percentiles([x / 1000 for x in v]))
                          for shape, v in sorted(by_shape.items())},
                raw=[str(path.name) for path in paths])


def percentiles(values):
    ordered = sorted(values)
    if not ordered:
        return {}
    return {('p%g' % q): ordered[min(len(ordered) - 1, max(0, int(round(len(ordered) * q / 100 + .5)) - 1))] for q in (50, 90, 99, 99.9)} | dict(max=ordered[-1], mean=statistics.fmean(ordered))


def verify(args, corpus, shape_list, plans, folder):
    ports = dict(eski=args.port, **{'redis-search': args.port + 1})
    engines = {}
    replies = {}
    try:
        for target in TARGETS:
            engines[target] = start(target, args, ports[target], folder / ('verify-' + target))
        distinct = {}
        for plan in plans.values():
            for item in plan:
                distinct.setdefault(key_of(item['request']), item)
        for target in TARGETS:
            conn = Conn(ports[target], timeout=120)
            try:
                load(conn, corpus, args.area)
                build_indexes(conn, args.area)
                replies[target] = {key: execute(conn, item['request']) for key, item in distinct.items()}
            finally:
                conn.close()
    finally:
        for handle, _, _ in engines.values():
            handle.stop()
    by_shape = {shape['name']: dict(checked=0, equal=0, within_named_difference=0, beyond_named_difference=0, differences=[],
                                    difference=shape['difference']) for shape in shape_list}
    for key, item in distinct.items():
        row = by_shape[item['shape']]
        row['checked'] += 1
        reference = replies['redis-search'][key]
        if args.corrupt_check == item['shape'] and row['checked'] == 1:
            reference = reference + ['deliberately wrong expectation']
        if replies['eski'][key] == reference:
            row['equal'] += 1
            continue
        if row['difference'] and within_difference(row['difference'], replies['eski'][key], reference):
            row['within_named_difference'] += 1
        else:
            row['beyond_named_difference'] += 1
        if len(row['differences']) < 5:
            row['differences'].append(dict(request=[[part if isinstance(part, str) else repr(part) for part in argv] for argv in item['request']],
                                           eski=replies['eski'][key], reference=reference))
    expected = {target: {key: replies[target][key] for key in distinct} for target in TARGETS}
    (folder / 'verification.json').write_text(json.dumps(by_shape, indent=1, default=repr) + '\n')
    return by_shape, expected


def measure(args, corpus, plans, verified, timed_shapes, folder, rows):
    for rep in range(1, args.repetitions + 1):
        order = TARGETS if rep % 2 else tuple(reversed(TARGETS))
        for target in order:
            expected = verified[target]
            for variant in (('noindex', 'index') if args.area == 'json' else ('index',)):
                directory = folder / ('rep-%d-%s-%s' % (rep, target, variant))
                directory.mkdir()
                handle, pid, container = start(target, args, args.port, directory / 'server')
                row = dict(rep=rep, target=target, variant=variant, order=list(order))
                rows.append(row)
                try:
                    conn = Conn(args.port, timeout=120)
                    row['memory_empty'] = memory(conn, pid, container)
                    row['load'] = load(conn, corpus, args.area)
                    row['memory_loaded'] = memory(conn, pid, container)
                    if variant == 'index':
                        row['index_build'] = build_indexes(conn, args.area)
                        row['memory_indexed'] = memory(conn, pid, container)
                        if 'used_memory' in row['memory_indexed'] and 'used_memory' in row['memory_loaded']:
                            row['index_bytes'] = row['memory_indexed']['used_memory'] - row['memory_loaded']['used_memory']
                    if 'used_memory' in row['memory_loaded'] and 'used_memory' in row['memory_empty']:
                        row['bytes_per_document'] = (row['memory_loaded']['used_memory'] - row['memory_empty']['used_memory']) / max(1, row['load']['commands'])
                    warm = [(p['shape'], p['request']) for p in plans['warmup'] if p['shape'] in timed_shapes]
                    failed = {}
                    for shape, request in warm:
                        if execute(conn, request) != expected[key_of(request)]:
                            failed[shape] = failed.get(shape, 0) + 1
                    row['warmup'] = dict(requests=len(warm), errors=sum(failed.values()), errors_by_shape=failed)
                    conn.close()
                    row['levels'] = []
                    for level in args.connections:
                        plan = [p for p in plans[level] if p['shape'] in timed_shapes]
                        level_dir = directory / ('connections-%d' % level)
                        level_dir.mkdir()
                        row['levels'].append(timed(args.port, plan, expected, level, level_dir))
                    conn = Conn(args.port, timeout=120)
                    row['memory_after'] = memory(conn, pid, container)
                    conn.close()
                finally:
                    handle.stop()


def main():
    parser = argparse.ArgumentParser(description='Search, aggregation, vector, hybrid and JSON workloads on Eski and on the pinned Redis 8.10.3 image: '
                                     'the same seeded corpus and the same requests go to both, every distinct request is first sent to both engines '
                                     'and its replies compared, only requests whose replies were compared are timed, the engine order alternates by '
                                     'repetition, and every repetition keeps raw per-request latencies, error counts, load and index build times and memory.')
    parser.add_argument('--area', required=True, choices=('search-hash', 'search-json', 'full-text', 'vector-search', 'hybrid', 'aggregate', 'json'))
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--image', required=True, help='local image ID of the Redis 8.10.3 reference')
    parser.add_argument('--server-cpus', required=True)
    parser.add_argument('--port', type=int, required=True, help='first of two loopback ports')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--documents', type=int, default=20000)
    parser.add_argument('--requests', type=int, default=5000, help='timed requests per connection level')
    parser.add_argument('--warmup', type=int, default=500)
    parser.add_argument('--repetitions', type=int, default=4)
    parser.add_argument('--connections', default='1,8')
    parser.add_argument('--seed', type=int, default=9137)
    parser.add_argument('--server-memory', default='8g')
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--corrupt-check', help='deliberately corrupt the expected reply of the first request of this shape, to prove the check fails')
    args = parser.parse_args()
    args.connections = [int(v) for v in args.connections.split(',')]
    if args.documents < TAGS or args.requests < 1 or args.repetitions < 1 or min(args.connections) < 1:
        parser.error('invalid sizes')
    args.out = args.out.resolve()
    args.out.mkdir(parents=True)
    signal.signal(signal.SIGTERM, interrupted)
    corpus = Corpus(args.documents, args.seed)
    shape_list = shapes(args.area, corpus)
    plans = {level: plan_requests(args.area, corpus, shape_list, args.requests, level, args.seed + level) for level in args.connections}
    plans['warmup'] = plan_requests(args.area, corpus, shape_list, args.warmup, 1, args.seed - 1)
    summary = dict(schema=SCHEMA, area=args.area, documents=args.documents, seed=args.seed, requests=args.requests, warmup=args.warmup,
                   repetitions=args.repetitions, connections=args.connections, reference_image=args.image, server=str(args.server),
                   server_cpus=args.server_cpus, client_cpus=sorted(os.sched_getaffinity(0)), indexes=index_specs(args.area),
                   shapes=[dict(name=s['name'], kind=s['kind'], difference=s['difference'], documented=KNOWN_DIFFERENCES.get(s['difference'])) for s in shape_list],
                   normalizations=NORMALIZATIONS, timed=not args.verify_only, rows=[], exit_code=1)
    report = args.out / 'summary.json'
    try:
        verification, expected = verify(args, corpus, shape_list, plans, args.out)
        summary['verification'] = verification
        unequal = [name for name, row in verification.items() if row['beyond_named_difference']]
        unexpected = [name for name in unequal if name not in KNOWN_UNEQUAL]
        timed_shapes = {name for name, row in verification.items() if not row['beyond_named_difference']}
        summary['dropped_shapes'] = {name: 'replies differ from the reference: %d of %d equal%s' % (
            verification[name]['equal'], verification[name]['checked'], '; ' + KNOWN_UNEQUAL[name] if name in KNOWN_UNEQUAL else '; not expected') for name in unequal}
        summary['unexpected_differences'] = unexpected
        summary['timed_shapes'] = sorted(timed_shapes)
        if not args.verify_only and timed_shapes:
            measure(args, corpus, plans, expected, timed_shapes, args.out, summary['rows'])
        errors = sum(entry['errors'] for row in summary['rows'] for level in row.get('levels', [])
                     for name, entry in level['by_shape'].items() if not verification[name]['difference'])
        errors += sum(count for row in summary['rows'] for name, count in row.get('warmup', {}).get('errors_by_shape', {}).items()
                      if not verification[name]['difference'])
        summary['timed_errors'] = errors
        summary['exit_code'] = int(bool(unexpected) or not timed_shapes or bool(errors))
    except KeyboardInterrupt:
        summary['error'] = 'interrupted'
        summary['exit_code'] = 130
        raise
    finally:
        report.write_text(json.dumps(summary, indent=1, default=repr) + '\n')
    return summary['exit_code']


if __name__ == '__main__':
    sys.exit(main())
