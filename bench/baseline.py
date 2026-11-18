import re

AREAS = ('stock', 'memory', 'search-hash', 'search-json', 'full-text', 'vector-search', 'hybrid', 'aggregate', 'json',
         'vector-sets', 'persistence', 'change-log', 'access', 'internal', 'simulation', 'trace')
PROFILES = ('full', 'rehearsal')
CONTEXT_KEYS = ('profile', 'out', 'binaries', 'server_cpus', 'client_cpus', 'ports', 'images', 'limits', 'python', 'seeds')
BINARY_KEYS = ('eski', 'eski-debug', 'eski-simulation', 'eski-change-log')
IMAGE_KEYS = ('redis', 'valkey', 'dragonfly', 'memtier', 'redis-search')
NAME = re.compile(r'[a-z0-9]+(?:-[a-z0-9]+)*$')
RUNNER = 'bench/baseline_run.py'
RESERVED = ('functional', 'virtual', 'native', 'change-log-probe', 'search-json-probe', 'lua-build', 'diagnostics-build', 'release-build',
            'debug-build', 'simulation-build', 'change-log-build', 'bundle', 'bin', 'inputs', 'summary', 'rented-run', 'SHA256SUMS')
RESERVED_PREFIXES = ('functional', 'bundle', 'rented-run')

UNCOVERED_AREAS = {}

UNCOVERED = {
    'stock: eski-docker': 'The competitors run in containers and Eski runs natively, as the qualified release binary. The tree\'s container image is '
                          'built by its own Dockerfile with a different compiler, so it would measure another binary; the stock-exam step records '
                          'the container memory peak of every competitor and the resident and peak resident size of the native Eski process instead.',
    'stock: multicore scaling': 'Every engine gets one server core, as in the recorded comparison; keyspace and compute worker scaling is measured '
                                'by vector-sets-threads only.',
    'search: FT.SPELLCHECK, FT.SUG*, FT.SYN*, phonetic matching, SVS-VAMANA': 'Eski does not implement them, so there is nothing to compare.',
    'search: FT.PROFILE': 'Its reply describes each engine\'s own execution steps, so equal replies cannot be checked and the request is never timed.',
    'search: highlighting and summaries': 'Excerpt boundaries differ from the reference by design (docs/search.md), so replies cannot be compared.',
    'search: DIALECT 4 sorted paging': 'Counts and order differ from the reference by design (docs/search.md).',
    'hybrid: FT.HYBRID with COMBINE RRF or LINEAR': 'On the plan\'s corpus Eski returned a different total and different fused rows from the '
                                                    'reference; the hybrid step checks both requests on every run and times them only once the replies '
                                                    'are equal, and times KNN filtered by tag, text and range meanwhile.',
    'access: labelled-mode A/B against an older tree': 'bench/ab.py --extra-a/--extra-b compares two binaries; the run has one qualified binary, '
                                                       'so the labelled and owner costs come from access-* steps that run both modes in one binary.',
    'internal: bench/disasm.py': 'It compares the instructions of two binaries and needs no host; it runs on the workstation.',
    'internal: bench/pts.sh, bench/vectorset_load.py': 'pts.sh needs the Phoronix suite and network access; vectorset_load.py is the older form of '
                                                       'graph_load.py, which the graph-load step runs.',
    'internal: bench/scripts/digest.py': 'It is a correctness comparison of two binaries, not a measurement.',
    'trace: simulation': 'The simulation worker is a separate test binary, not the server; its rate is measured by simulation-rate.',
}

SIZES = {
    'full': dict(
        exam_repetitions=4, exam_test_seconds=60, exam_warmup_seconds=10, exam_keys=100000, exam_idle_watch=600, exam_case_overhead=45,
        exam_workloads=8, spec_repetitions=2, spec_test_seconds=30, spec_case_limit=1, spec_groups=14, spec_max_groups=0,
        fill_keys=10000000, fill_seconds_per_engine=120,
        search_documents=20000, search_requests=5000, search_warmup=500, search_repetitions=4, search_connections=8,
        json_documents=16000, json_requests=10000, json_warmup=500, json_rounds=4,
        vset_elements=50000, vset_dim=128, vset_queries=4000, vset_repetitions=4, vset_connections=8,
        threads_size='full', threads_list='0,1,2,4', threads_repetitions=3,
        graph_elements=100000, graph_rounds=4, graph_repetitions=2,
        append_writes=200000, append_repetitions=4, latency_samples=20000, mirror_rounds=4, mirror_writes=100000,
        save_partitions=2000, save_keys=40, save_elements=20, save_repetitions=3,
        engine_keys=1000000, engine_writes=200000, engine_repetitions=4,
        owners_size='full', forms_users=30000, forms_rounds=4, bytes_users=100000, script_commands=200000, script_rounds=4,
        vset_owners='300000 50000 4000', store_keys=200000, store_reps=5, store_rounds=8,
        resize_sizes='98304,786432', resize_rounds=8, sort_seconds=10, sort_rounds=5,
        floor_rounds=8, floor_seconds=20, floor_warmup=5, floor_workloads=7,
        simulation_repetitions=3, trace_seconds=30, trace_scale=1),
    'rehearsal': dict(
        exam_repetitions=1, exam_test_seconds=2, exam_warmup_seconds=1, exam_keys=2000, exam_idle_watch=3, exam_case_overhead=8,
        exam_workloads=2, spec_repetitions=1, spec_test_seconds=2, spec_case_limit=1, spec_groups=2, spec_max_groups=2,
        fill_keys=20000, fill_seconds_per_engine=10,
        search_documents=96, search_requests=60, search_warmup=8, search_repetitions=2, search_connections=2,
        json_documents=64, json_requests=100, json_warmup=10, json_rounds=2,
        vset_elements=300, vset_dim=16, vset_queries=40, vset_repetitions=2, vset_connections=2,
        threads_size='smoke', threads_list='0,2', threads_repetitions=1,
        graph_elements=500, graph_rounds=2, graph_repetitions=1,
        append_writes=200, append_repetitions=2, latency_samples=50, mirror_rounds=2, mirror_writes=200,
        save_partitions=3, save_keys=40, save_elements=12, save_repetitions=1,
        engine_keys=2000, engine_writes=300, engine_repetitions=2,
        owners_size='smoke', forms_users=300, forms_rounds=1, bytes_users=300, script_commands=500, script_rounds=1,
        vset_owners='300 600 50', store_keys=2000, store_reps=2, store_rounds=2,
        resize_sizes='98304', resize_rounds=1, sort_seconds=1, sort_rounds=1,
        floor_rounds=2, floor_seconds=2, floor_warmup=1, floor_workloads=2,
        simulation_repetitions=2, trace_seconds=5, trace_scale=0),
}

PLANNING = dict(server_start=2, container_start=3, odin_package_build=60, odin_tree_build=150, search_request=0.002, json_request=0.0005,
                vset_request=0.001, load_per_document=0.0001, vadd_per_element=0.0005, write=0.00002, fsync_write=0.002, case_overhead=13,
                simulation_worker_step=0.00015, perf_report=15)
FLOOR_WORKLOADS = ('get64-p1-r3k', 'get64-p16-max', 'set64-p1-r3k', 'get64-p16-r20k', 'set64-p16-r20k', 'ping-p16-r20k', 'get64-p1-r1k')
TRACE_TARGETS = ('stock', 'search', 'json', 'vector-sets', 'persistence', 'change-log', 'access')


def validate(context):
    missing = [key for key in CONTEXT_KEYS if key not in context]
    if missing:
        raise ValueError('context lacks ' + ', '.join(missing))
    if context['profile'] not in PROFILES:
        raise ValueError('profile must be full or rehearsal')
    if not isinstance(context['out'], str) or not context['out'].startswith('/'):
        raise ValueError('out must be an absolute path')
    for key in BINARY_KEYS:
        if not isinstance(context['binaries'].get(key), str) or not context['binaries'][key].startswith('/'):
            raise ValueError('binaries.%s must be an absolute path' % key)
    for key in IMAGE_KEYS:
        if not isinstance(context['images'].get(key), str):
            raise ValueError('images.%s must be a string, empty when preflight could not resolve it' % key)
    first, last = context['ports']
    if not (isinstance(first, int) and isinstance(last, int) and 1024 <= first and last - first + 1 >= 40 and last <= 65535):
        raise ValueError('ports must name forty consecutive ports')
    for key in ('server_memory', 'client_memory', 'maxmemory'):
        if key not in context['limits']:
            raise ValueError('limits.%s is required' % key)
    for key in ('first', 'count', 'steps'):
        if not isinstance(context['seeds'].get(key), int):
            raise ValueError('seeds.%s must be an integer' % key)
    if not context['python'] or not all(isinstance(part, str) for part in context['python']):
        raise ValueError('python must be an argv prefix')
    return context


def first_cpu(cpus):
    return re.split(r'[,-]', cpus)[0]


def cpu_count(cpus):
    total = 0
    for part in cpus.split(','):
        low, _, high = part.partition('-')
        total += int(high or low) - int(low) + 1
    return total


class Plan:
    def __init__(self, context):
        self.c = validate(context)
        self.s = SIZES[context['profile']]
        self.py = list(context['python'])
        self.out = context['out'].rstrip('/')
        self.port = context['ports'][0]
        self.server = context['server_cpus']
        self.client = context['client_cpus']
        self.bin = context['binaries']
        self.images = context['images']
        self.rows = []

    def add(self, name, area, command, timeout, estimate, needs=(), artifact=None, environment=None):
        self.rows.append(dict(name=name, area=area, command=[str(part) for part in command], artifact=artifact or name + '/result.json',
                              timeout=int(timeout), environment=dict(environment or {}), needs=list(needs), estimate_seconds=int(estimate)))

    def wrapped(self, name, area, driver, estimate, repeat=1, collect=(), needs=(), sample=True, eski_port=None, eski_args=(), timeout=None, containers=(),
                pin=True):
        command = (['taskset', '-c', self.client] if pin else []) + [*self.py, RUNNER, '--name', name, '--area', area, '--profile', self.c['profile'],
                   '--out', self.out, '--artifact', name + '/result.json', '--repeat', repeat, '--server-cpus', self.server,
                   '--client-cpus', self.client, '--sample-seconds', 2 if sample else 0]
        for pattern in collect:
            command += ['--collect', pattern]
        for pattern in containers:
            command += ['--guard-container', pattern]
        if eski_port:
            command += ['--eski', self.bin['eski'], '--eski-port', eski_port]
            for arg in eski_args:
                command += ['--eski-arg=' + arg]
        self.add(name, area, command + ['--', *driver], timeout or max(900, 6 * estimate), estimate, needs)

    def images_args(self, keys):
        argv = []
        for key in keys:
            argv += ['--image', '%s=%s' % (key, self.images[key])]
        return argv

    def limits_args(self):
        limits = self.c['limits']
        return ['--server-memory', limits['server_memory'], '--client-memory', limits['client_memory'], '--maxmemory', limits['maxmemory']]

    def stock(self):
        s = self.s
        ports = '%d-%d' % (self.port, self.port + 9)
        common = ['--profile', self.c['profile'], '--eski', self.bin['eski'], '--server-cpus', self.server, '--client-cpus', self.client,
                  '--ports', ports, *self.images_args(('redis', 'valkey', 'dragonfly', 'memtier')), *self.limits_args()]
        cases = (s['exam_workloads'] * s['exam_repetitions'] + 1) * 4
        exam = s['exam_idle_watch'] + cases * (s['exam_test_seconds'] + s['exam_warmup_seconds'] + s['exam_case_overhead'])
        self.add('stock-exam', 'stock', [*self.py, 'bench/stock_exam.py', 'exam', '--out', self.out + '/stock-exam', *common],
                 max(1800, 3 * exam), exam, ('redis', 'valkey', 'dragonfly', 'memtier'), 'stock-exam/result.json')
        spec_cases = s['spec_groups'] * s['spec_case_limit'] * s['spec_repetitions'] * 4
        spec = 60 + s['exam_idle_watch'] + spec_cases * (s['spec_test_seconds'] + s['exam_case_overhead'])
        self.add('stock-spec', 'stock', [*self.py, 'bench/stock_exam.py', 'spec', '--out', self.out + '/stock-spec', *common,
                                         '--spec-test-seconds', s['spec_test_seconds'], '--spec-repetitions', s['spec_repetitions'],
                                         '--spec-cases-per-group', s['spec_case_limit'], '--spec-max-groups', s['spec_max_groups']],
                 max(1800, 3 * spec), spec, ('redis', 'valkey', 'dragonfly', 'memtier'), 'stock-spec/result.json')
        fill = 4 * s['fill_seconds_per_engine']
        self.add('stock-fill', 'memory', [*self.py, 'bench/stock_exam.py', 'fill', '--out', self.out + '/stock-fill', *common,
                                          '--fill-keys', s['fill_keys']],
                 max(1800, 4 * fill), fill, ('redis', 'valkey', 'dragonfly', 'memtier'), 'stock-fill/result.json')

    def search(self):
        s = self.s
        image = self.images['redis-search']
        for area, name, documents in (('search-hash', 'search-hash', s['search_documents']), ('search-json', 'search-json-fields', s['search_documents']),
                                      ('full-text', 'full-text', s['search_documents']), ('vector-search', 'vector-search', s['search_documents']),
                                      ('hybrid', 'hybrid', s['search_documents']), ('aggregate', 'aggregate', s['search_documents']),
                                      ('json', 'json-commands', s['search_documents'])):
            driver = [*self.py, 'bench/search_bench.py', '--area', area, '--server', self.bin['eski'], '--image', image,
                      '--server-cpus', self.server, '--port', self.port, '--out', '{dir}/run', '--documents', documents,
                      '--requests', s['search_requests'], '--warmup', s['search_warmup'], '--repetitions', s['search_repetitions'],
                      '--connections', '1,%d' % s['search_connections'], '--server-memory', self.c['limits']['server_memory']]
            cost = PLANNING['json_request'] if area == 'json' else PLANNING['search_request']
            variants = 2 if area == 'json' else 1
            requests = s['search_requests'] * 2 + s['search_warmup']
            verify = 2 * (PLANNING['container_start'] + documents * PLANNING['load_per_document'] + requests * cost)
            per_rep = 2 * variants * (PLANNING['container_start'] + documents * PLANNING['load_per_document'] + requests * cost)
            estimate = 5 + verify + s['search_repetitions'] * per_rep
            self.wrapped(name, area, driver, estimate, collect=('run/summary.json',), needs=('redis-search',))
        estimate = 5 + s['json_rounds'] * 2 * (PLANNING['container_start'] + s['json_documents'] * PLANNING['load_per_document']
                                               + (s['json_requests'] + s['json_warmup']) * PLANNING['search_request'])
        self.wrapped('search-json', 'search-json', [*self.py, 'bench/search_json.py', '--server', self.bin['eski'], '--image', image, '--server-cpus', self.server,
                                                    '--port', self.port, '--out', '{dir}/run', '--documents', s['json_documents'],
                                                    '--warmup', s['json_warmup'], '--requests', s['json_requests'], '--rounds', s['json_rounds']],
                     estimate, collect=('run/summary.json',), needs=('redis-search',), containers=('eski-search-%d-{pid}' % self.port,))

    def vector_sets(self):
        s = self.s
        driver = [*self.py, 'bench/vectorset/vset_compare.py', '--server', self.bin['eski'], '--image', self.images['redis-search'],
                  '--server-cpus', self.server, '--port', self.port, '--out', '{dir}/run', '--elements', s['vset_elements'], '--dim', s['vset_dim'],
                  '--queries', s['vset_queries'], '--repetitions', s['vset_repetitions'], '--connections', '1,%d' % s['vset_connections'],
                  '--server-memory', self.c['limits']['server_memory']]
        build = s['vset_elements'] * s['vset_dim'] / 128 * PLANNING['vadd_per_element']
        queries = (2 * s['vset_queries'] + 200) * PLANNING['vset_request']
        estimate = 5 + 2 * (PLANNING['container_start'] + build + queries) + s['vset_repetitions'] * 2 * (PLANNING['container_start'] + build + queries)
        self.wrapped('vector-sets', 'vector-sets', driver, estimate, collect=('run/summary.json',), needs=('redis-search',))
        threads = len(s['threads_list'].split(','))
        estimate = s['threads_repetitions'] * threads * 2 * (60 if s['threads_size'] == 'full' else PLANNING['server_start'])
        self.wrapped('vector-sets-threads', 'vector-sets', [*self.py, 'bench/vectorset/vsim_threads.py', '--server', self.bin['eski'],
                                                            '--port', self.port, '--size', s['threads_size'], '--threads', s['threads_list'],
                                                            '--cpu', self.server, '--work-dir', '{new}', '--out', '{json}'],
                     estimate, repeat=s['threads_repetitions'], collect=('result.json',))
        estimate = s['graph_repetitions'] * (2 * PLANNING['server_start'] + s['graph_elements'] * PLANNING['vadd_per_element'] * (1 + s['graph_rounds']))
        self.wrapped('graph-load', 'vector-sets', [*self.py, 'bench/vectorset/graph_load.py', '--server', self.bin['eski'], '--cpu', self.server,
                                                   '--port', self.port + 6, '--size', 'custom', '--elements', s['graph_elements'],
                                                   '--rounds', s['graph_rounds'], '--work-dir', '{new}', '--out', '{json}'],
                     estimate, repeat=s['graph_repetitions'], collect=('result.json',))

    def persistence(self):
        s = self.s
        estimate = s['append_repetitions'] * 2 * (PLANNING['server_start'] + s['append_writes'] * PLANNING['fsync_write'] / 10
                                                  + s['latency_samples'] * PLANNING['fsync_write'])
        self.wrapped('aof-append', 'persistence', [*self.py, 'bench/persist/aof_append.py', '--server', self.bin['eski'], '--cpu', self.server,
                                                   '--port', self.port, '--modes', 'off', '--encryption', 'off', '--fsync', 'always',
                                                   '--size', 'custom', '--writes', s['append_writes'], '--latency-samples', s['latency_samples'],
                                                   '--work-dir', '{new}', '--out', '{json}'],
                     estimate, repeat=s['append_repetitions'], collect=('result.json',))
        configs = 6
        estimate = s['save_repetitions'] * configs * (2 * PLANNING['server_start'] + s['save_partitions'] * (s['save_keys'] + s['save_elements']) * PLANNING['write'] * 3)
        self.wrapped('save-load', 'persistence', [*self.py, 'bench/persist/save_load.py', '--server', self.bin['eski'], '--cpu', self.server,
                                                  '--port', self.port, '--size', 'custom', '--partitions', s['save_partitions'],
                                                  '--keys', s['save_keys'], '--elements', s['save_elements'], '--work-dir', '{new}', '--out', '{json}'],
                     estimate, repeat=s['save_repetitions'], collect=('result.json',))
        driver = [*self.py, 'bench/persist/engine_compare.py', '--server', self.bin['eski'], *self.images_args(('redis', 'valkey')),
                  '--server-cpus', self.server, '--port', self.port, '--out', '{dir}/run', '--keys', s['engine_keys'], '--writes', s['engine_writes'],
                  '--repetitions', s['engine_repetitions'], '--server-memory', self.c['limits']['server_memory']]
        estimate = s['engine_repetitions'] * 3 * (5 * PLANNING['container_start'] + s['engine_keys'] * PLANNING['write'] * 3
                                                   + s['engine_writes'] * (PLANNING['fsync_write'] / 10 + PLANNING['write']))
        self.wrapped('persistence-engines', 'persistence', driver, estimate, collect=('run/summary.json',), needs=('redis', 'valkey'))
        estimate = s['mirror_rounds'] * 2 * (PLANNING['server_start'] + s['mirror_writes'] * PLANNING['fsync_write'] / 10
                                             + s['latency_samples'] * PLANNING['fsync_write'])
        self.wrapped('change-log-append', 'change-log', [*self.py, 'bench/persist/aof_append.py', '--server', self.bin['eski'], '--cpu', self.server,
                                                         '--port', self.port + 4, '--size', 'custom', '--writes', s['mirror_writes'], '--fsync', 'always',
                                                         '--change-log-reader', self.bin['eski-change-log'], '--mirror-rounds', s['mirror_rounds'],
                                                         '--latency-samples', s['latency_samples'],
                                                         '--work-dir', '{new}', '--out', '{json}'],
                     estimate, collect=('result.json',))

    def access(self):
        s = self.s
        self.wrapped('access-owner-scale', 'access', [*self.py, 'bench/owners/scale.py', '--binary', self.bin['eski'], '--port', self.port,
                                                      '--size', s['owners_size'], '--probes', '--cpu', self.server, '--workdir', '{new}', '--out', '{json}'],
                     1800 if s['owners_size'] == 'full' else 10, collect=('result.json',))
        self.wrapped('access-owner-forms', 'access', [*self.py, 'bench/owners/forms.py', '--binary', self.bin['eski'], '--port', self.port,
                                                      '--users', s['forms_users'], '--rounds', s['forms_rounds'], '--cpu', self.server,
                                                      '--workdir', '{new}', '--out', '{json}'],
                     2 * PLANNING['server_start'] + s['forms_users'] * s['forms_rounds'] * 14 * PLANNING['write'], collect=('result.json',))
        self.wrapped('access-owner-bytes', 'access', [*self.py, 'bench/owners/bytes.py', '--binary', self.bin['eski'], '--port', self.port,
                                                      '--users', s['bytes_users'], '--shape', 'vset', '--cpu', self.server, '--workdir', '{new}',
                                                      '--out', '{json}'],
                     PLANNING['server_start'] + s['bytes_users'] * 4 * PLANNING['write'], collect=('result.json',))
        for mode in ('off', 'labelled', 'owners'):
            self.wrapped('access-scripts-' + mode, 'access', [*self.py, 'bench/scripts/load.py', '--binary', self.bin['eski'], '--mode', mode,
                                                              '--port', self.port, '--commands', s['script_commands'], '--rounds', s['script_rounds'],
                                                              '--cpu', self.server, '--workdir', '{new}', '--out', '{json}'],
                         PLANNING['server_start'] + s['script_commands'] * 5 * s['script_rounds'] * PLANNING['write'], collect=('result.json',))
        owners, graph, rounds = (int(v) for v in s['vset_owners'].split())
        self.wrapped('access-owner-vset', 'access', [*self.py, 'bench/probe_run.py', 'owners-vset', '--work', '{dir}/build', '--cpu', first_cpu(self.server),
                                                     '--owners', owners, '--graph', graph, '--rounds', rounds, '--out', '{json}'],
                     PLANNING['odin_package_build'] + owners * PLANNING['write'] * 4 + graph * PLANNING['vadd_per_element'] + rounds * 0.05,
                     collect=('result.json',))

    def internal(self):
        s = self.s
        self.wrapped('internal-store', 'internal', [*self.py, 'bench/probe_run.py', 'store', '--work', '{dir}/build', '--keys', s['store_keys'],
                                                    '--reps', s['store_reps'], '--rounds', s['store_rounds'], '--cpu', first_cpu(self.server),
                                                    '--out', '{json}'],
                     PLANNING['odin_tree_build'] + s['store_rounds'] * 2 * s['store_reps'] * s['store_keys'] * 7 * 0.0000005, collect=('result.json',))
        for kind in ('hash', 'set', 'zset'):
            self.wrapped('internal-%s-resize' % kind, 'internal', [*self.py, 'bench/%s_resize.py' % kind, '--source', '.', '--label', kind + '-resize',
                                                                    '--sizes', s['resize_sizes'], '--rounds', s['resize_rounds'],
                                                                    '--cpu', first_cpu(self.server), '--output', '{json}'],
                         PLANNING['odin_package_build'] / 3 + s['resize_rounds'] * len(s['resize_sizes'].split(',')) * 6, collect=('result.json',))
        self.wrapped('internal-sort', 'internal', [*self.py, 'bench/sort.py', '--target', 'eski:{port}', '--seconds', s['sort_seconds'],
                                                   '--rounds', s['sort_rounds'], '--output', '{json}'],
                     PLANNING['server_start'] + s['sort_seconds'] * s['sort_rounds'] * 2, collect=('result.json',), eski_port=self.port,
                     eski_args=('--maxmemory', '1gb'))
        workloads = ','.join(FLOOR_WORKLOADS[:s['floor_workloads']])
        passes = 1 if cpu_count(self.server) >= 2 and cpu_count(self.client) >= 4 else 2
        floor = s['floor_rounds'] * passes * (2 * PLANNING['server_start'] + s['floor_workloads'] * (s['floor_seconds'] + s['floor_warmup'] + 2 * PLANNING['container_start']))
        self.wrapped('noise-floor', 'internal', [*self.py, 'bench/ab_floor_run.py', '--binary', self.bin['eski'], '--server-cpus', self.server,
                                                 '--client-cpus', self.client, '--port', self.port, '--memtier-image', self.images['memtier'],
                                                 '--rounds', s['floor_rounds'], '--seconds', s['floor_seconds'], '--warmup', s['floor_warmup'],
                                                 '--workloads', workloads,
                                                 '--out', '{dir}/session', '--result', '{json}'],
                     floor, collect=('result.json',), needs=('memtier',), sample=False, pin=False)

    def simulation(self):
        s = self.s
        seeds = self.c['seeds']
        count = seeds['count'] if self.c['profile'] == 'full' else min(seeds['count'], 2)
        estimate = s['simulation_repetitions'] * (5 + count * max(1, seeds['steps']) * 7 * PLANNING['simulation_worker_step'])
        self.wrapped('simulation-rate', 'simulation', [*self.py, 'test/simulation/exercise.py', 'virtual', '--binary', self.bin['eski-simulation'],
                                                       '--out', '{new}', '--first-seed', seeds['first'], '--seeds', count,
                                                       '--steps', seeds['steps'], '--measure'],
                     estimate, repeat=s['simulation_repetitions'], collect=('data/summary.json',))

    def trace(self):
        s = self.s
        for target in TRACE_TARGETS:
            driver = [*self.py, 'bench/trace.py', '--target', target, '--server', self.bin['eski-debug'], '--server-cpus', self.server,
                      '--client-cpus', self.client, '--port', self.port, '--seconds', s['trace_seconds'], '--scale', s['trace_scale'],
                      '--out', '{dir}/trace', '--result', '{json}', '--memtier-image', self.images['memtier']]
            setup = 20 if s['trace_scale'] else 2
            self.wrapped('trace-' + target, 'trace', driver, PLANNING['server_start'] + setup + s['trace_seconds'] + PLANNING['perf_report'], collect=('result.json',),
                         needs=('memtier',) if target == 'stock' else (), sample=False)

    def build(self):
        self.stock()
        self.search()
        self.vector_sets()
        self.persistence()
        self.access()
        self.internal()
        self.simulation()
        self.trace()
        return self.rows


def steps(context):
    return Plan(context).build()


def uncovered():
    return dict(UNCOVERED)
