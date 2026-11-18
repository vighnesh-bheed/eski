import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PYTHON = (sys.executable, '-IB')
GIB = 1 << 30
FUNCTIONAL = 'test/functional/check.py'
SIMULATION = 'test/simulation/exercise.py'
APPEND = 'bench/persist/aof_append.py'
SEARCH = 'bench/search_json.py'
CORRECTNESS = ('functional', 'virtual', 'native', 'change-log-probe', 'search-json-probe')
BINARIES = ('eski', 'eski-simulation', 'eski-change-log')
STOCK_SCENARIOS = 'mixed_p1,mixed_p16,get_p1,set_p1'


def digest(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def source_fingerprint(revision):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS='0')
    command = ['git', '-C', ROOT, '-c', 'core.fsmonitor=false']

    def read_git(*args):
        return subprocess.run([*map(str, command), *args], env=environment, capture_output=True,
                              check=True, timeout=20).stdout

    head = read_git('rev-parse', '--verify', 'HEAD').decode().strip()
    if head != revision:
        raise ValueError(f'checkout HEAD {head} differs from --revision {revision}')
    if read_git('status', '--porcelain=v1', '-z', '--untracked-files=all'):
        raise ValueError('checkout has modified or untracked files')
    paths = read_git('ls-files', '-z').split(b'\0')
    hasher = hashlib.sha256()
    for relative in paths:
        if not relative:
            continue
        path = ROOT / os.fsdecode(relative)
        mode = int(bool(path.stat().st_mode & 0o111))
        hasher.update(relative + b'\0' + bytes([mode]) + bytes.fromhex(digest(path)))
    return hasher.hexdigest()


def write_json(path, value):
    pending = path.with_suffix('.tmp')
    pending.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    pending.replace(path)


def probe(command, input=None):
    result = subprocess.run(list(map(str, command)), cwd=ROOT, input=input, capture_output=True, text=True, timeout=20)
    if result.returncode:
        error = result.stderr.strip() or result.stdout.strip()
        raise ValueError(f'{command[0]} exit {result.returncode}: {error[-2000:]}')
    return (result.stdout or result.stderr).strip()


def cpu_set(text):
    if not re.fullmatch(r'\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*', text):
        raise ValueError(f'invalid CPU list {text}')
    cpus = set()
    for piece in text.split(','):
        first, _, last = piece.partition('-')
        lo, hi = int(first), int(last or first)
        if not lo <= hi < 1048576:
            raise ValueError(f'invalid CPU range {piece}')
        cpus.update(range(lo, hi + 1))
    return cpus


def topology(cpus):
    rows = {}
    for cpu in sorted(cpus):
        root = Path(f'/sys/devices/system/cpu/cpu{cpu}/topology')
        rows[str(cpu)] = {name: (root / name).read_text().strip()
                          for name in ('physical_package_id', 'core_id', 'thread_siblings_list')
                          if (root / name).is_file()}
    return rows


def image_names():
    design = json.loads((ROOT / 'bench/testbed/design.json').read_text())
    images = {row['target']: row['image'] for row in design['engines'] if row['target'] != 'eski-docker'}
    images['memtier'] = design['load_generator']['image']
    search = (ROOT / 'test/search/compare.py').read_text()
    images['redis-search'] = re.search(r'^IMAGE = "([^"]+)"$', search, re.MULTILINE)[1]
    images['smoke-redis'] = 'docker.io/library/redis:7.4.11'
    images['memcached'] = 'docker.io/library/memcached:1.6'
    return images, design['resources']


def executable(name):
    resolved = shutil.which(name)
    if not resolved:
        raise ValueError(f'executable {name} is unavailable')
    return str(Path(resolved).absolute())


def preflight(args):
    issues = []
    ready = {'errors': issues, 'platform': platform.uname()._asdict()}

    def inspect(label, action):
        try:
            return action()
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            issues.append(f'{label}: {error}')
            return None

    available = os.sched_getaffinity(0)
    ready['cpu_affinity'] = sorted(available)
    ready['cpu_topology'] = inspect('CPU topology', lambda: topology(available))
    server, client = cpu_set(args.server_cpus), cpu_set(args.client_cpus)
    if server & client or (server | client) - available:
        issues.append('CPU roles must be disjoint and permitted by current affinity')
    if ready['cpu_topology']:
        siblings = {i for cpu in server for i in cpu_set(ready['cpu_topology'].get(str(cpu), {}).get('thread_siblings_list', str(cpu)))}
        ready['shared_physical_cores'] = sorted(siblings & client)
    ready['source'] = {'revision': args.revision, 'sha256': inspect('source fingerprint', lambda: source_fingerprint(args.revision))}
    ready['os_release'] = inspect('OS release', lambda: Path('/etc/os-release').read_text())
    ready['boot_id_sha256'] = inspect('boot ID', lambda: digest(Path('/proc/sys/kernel/random/boot_id')))
    ready['settings'] = {key: getattr(args, key) for key in (
        'server_cpus', 'client_cpus', 'port_base', 'first_seed', 'seeds', 'steps', 'cycles', 'transactions',
        'search_documents', 'search_requests', 'search_warmup', 'append_writes', 'graph_elements', 'min_free_gib')}
    ready['plan'] = {'virtual_workers': args.seeds * 7, 'virtual_model_iterations': args.seeds * args.steps * 5,
                     'native_transactions': args.cycles * args.transactions, 'stock_scenarios': STOCK_SCENARIOS,
                     'search_rounds': 2, 'append_rounds': 2, 'graph_rounds': 2}
    ready['output_root'] = str(args.out)
    ancestor = next(path for path in (args.out, *args.out.parents) if path.exists())
    if not ancestor.is_dir() or not os.access(ancestor, os.W_OK | os.X_OK):
        issues.append('output root has no writable directory ancestor')
    for key, folder in (('output_free_bytes', ancestor), ('checkout_free_bytes', ROOT)):
        ready[key] = inspect(key, lambda: shutil.disk_usage(folder).free)
        if ready[key] is not None and ready[key] < args.min_free_gib * GIB:
            issues.append(f'{key} below {args.min_free_gib} GiB')
    if args.out == ROOT or ROOT in args.out.parents:
        issues.append('output must sit outside the clean checkout')
    if args.first_seed + args.seeds - 1 >= 1 << 64:
        issues.append('virtual seed range exceeds the unsigned 64-bit limit')
    for port in range(args.port_base, args.port_base + 40):
        with socket.socket() as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind(('127.0.0.1', port))
            except OSError as error:
                issues.append(f'loopback port {port}: {error}')
    ready['tools'] = {}
    odin = os.environ.get('ODIN') or ('odin' if shutil.which('odin') else str(Path.home() / 'odin/current/odin'))
    for key, name, version in (('odin', odin, 'version'), ('docker', 'docker', '--version'),
                               ('clang', 'clang', '--version'), ('git', 'git', '--version'),
                               ('jq', 'jq', '--version'), ('taskset', 'taskset', '--version'),
                               ('openssl', 'openssl', 'version'), ('bash', 'bash', '--version'),
                               ('curl', 'curl', '--version'), ('ar', 'ar', '--version'),
                               ('flock', 'flock', '--version'), ('ld', 'ld', '--version'),
                               ('python', sys.executable, '--version')):
        def tool():
            path = executable(name)
            return {'path': path, 'version': probe([path, version]).splitlines()[0]}
        ready['tools'][key] = inspect(key, tool)
    tcl = next((shutil.which(name) for name in ('tclsh8.6', 'tclsh9.0', 'tclsh8.5', 'tclsh') if shutil.which(name)), None)
    if tcl:
        ready['tools']['tcl'] = inspect('native Tcl version', lambda: probe([tcl], 'puts [info patchlevel]\n'))
    ready['input_files'] = {name: {'path': str(path), 'sha256': inspect(name, lambda: digest(path))}
                            for name, path in (('capture', args.capture), ('observed', args.observed), ('expected', args.expected))}
    ready['interpreters'] = {}
    for name, path in (('modern', args.modern_python), ('llama', args.llama_python)):
        def interpreter():
            command = 'import importlib.metadata as m,json,platform; print(json.dumps([platform.python_version(),sorted((d.metadata["Name"],d.version) for d in m.distributions())]))'
            version, distributions = json.loads(probe([executable(str(path)), '-IB', '-c', command]))
            return {'path': str(path), 'sha256': digest(path), 'version': version, 'packages': distributions}
        ready['interpreters'][name] = inspect(name, interpreter)
        resolved = ready['interpreters'][name]
        if resolved:
            requirements = ROOT / 'test/compatibility/search_clients' / f'requirements-{name}.txt'
            have = {pkg.lower().replace('_', '-'): version for pkg, version in resolved['packages']}
            want = [line.split('==', 1) for line in requirements.read_text().splitlines() if line.strip()]
            missing = [f'{pkg}=={version}' for pkg, version in want if have.get(pkg) != version]
            if missing:
                issues.append(f'{name} environment differs from its lock file: {", ".join(missing)}')
    names, resources = image_names()
    if not tcl:
        names['tcl'] = 'eski-conformance-tcl:8.6'
    ready['images'] = {}
    ready['settings']['stock_limits'] = {key: resources[key] for key in ('server_memory', 'client_memory', 'maxmemory')}
    docker = ready['tools']['docker']
    if docker:
        ready['tools']['docker_engine'] = inspect('Docker engine', lambda: probe([docker['path'], 'version', '--format', '{{.Server.Version}}']))
    for key, name in names.items():
        def image_id():
            value = probe([docker['path'], 'image', 'inspect', '--format', '{{.Id}}', name])
            if not re.fullmatch(r'sha256:[a-f0-9]{64}', value):
                raise ValueError(f'invalid ID returned for {name}')
            return value
        ready['images'][key] = {'name': name, 'id': inspect(name, image_id) if docker else None}
    return ready


def stop_step(process):
    if process.poll() is not None:
        return
    for interrupt in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, interrupt)
            process.wait(timeout=30)
            return
        except ProcessLookupError:
            return
        except subprocess.TimeoutExpired:
            pass


def identity(data):
    return {key: data[key] for key in ('source', 'boot_id_sha256', 'platform', 'cpu_affinity', 'settings',
                                       'tools', 'input_files', 'interpreters', 'images')}


def new_run_dir(root):
    root.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix=time.strftime('run-%Y%m%d-%H%M%S-'), dir=root))


class Run:
    def __init__(self, args, ready):
        self.args = args
        self.ready = ready
        self.out = new_run_dir(args.out)
        self.bin = self.out / 'bin'
        self.bin.mkdir()
        self.report = {'preflight': ready, 'stages': {}, 'binary_sha256': {}, 'correctness': False, 'exit_code': None}
        self.base = args.port_base
        self.env = {key: val for key, val in os.environ.items()
                    if not key.startswith(('BENCH_', 'ESKI_'))}
        self.env.update(ODIN=ready['tools']['odin']['path'], PYTHONUTF8='1',
                        ESKI_REDIS_IMAGE=ready['images']['smoke-redis']['id'],
                        ESKI_MEMCACHED_IMAGE=ready['images']['memcached']['id'],
                        ESKI_VSET_IMAGE=ready['images']['redis-search']['name'])
        self.report['shared_environment'] = {key: self.env[key] for key in (
            'ODIN', 'PYTHONUTF8', 'ESKI_REDIS_IMAGE', 'ESKI_MEMCACHED_IMAGE', 'ESKI_VSET_IMAGE')}
        self.client = ['taskset', '-c', args.client_cpus]
        self.server = self.bin / 'eski'
        self.worker = self.bin / 'eski-simulation'
        self.reader = self.bin / 'eski-change-log'
        self.save()
        print(f'rented run output {self.out}', flush=True)

    def save(self):
        write_json(self.out / 'summary.json', self.report)

    def step(self, name, args, timeout, artifact=None, extra=None, independent=False):
        command = list(map(str, args))
        log = self.out / f'{name}.log'
        env = dict(self.env, **(extra or {}))
        row = {'command': command, 'log': log.name, 'environment': extra or {}, 'exit_code': None}
        self.report['stages'][name] = row
        self.save()
        print(name, flush=True)
        start = time.monotonic()
        try:
            with log.open('wb') as output:
                process = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                           env=env, stdin=subprocess.DEVNULL, start_new_session=True)
                try:
                    row['exit_code'] = process.wait(timeout=timeout)
                finally:
                    stop_step(process)
            if artifact:
                path = self.out / artifact
                if path.is_file():
                    row.update(artifact=artifact, artifact_sha256=digest(path))
                if row['exit_code'] == 0 and (not path.is_file() or json.loads(path.read_text()).get('exit_code', 0) != 0):
                    raise ValueError(f'missing or failing report {artifact}')
            if row['exit_code'] != 0:
                raise RuntimeError(f'{name} exited with {row["exit_code"]}. See {log}')
        except KeyboardInterrupt:
            row['exit_code'] = 130
            raise
        except Exception as error:
            row['error'] = str(error)
            row['exit_code'] = row['exit_code'] or 1
            if not independent:
                raise
            print(error, file=sys.stderr)
        finally:
            if log.is_file():
                row['log_sha256'] = digest(log)
            row['seconds'] = time.monotonic() - start
            self.save()

    def reuse(self, previous):
        old = json.loads((previous / 'summary.json').read_text())
        if old.get('correctness') is not True or identity(old['preflight']) != identity(self.ready):
            raise ValueError('correctness receipt does not match this boot, source, inputs and run settings')
        for stage in CORRECTNESS:
            entry = old['stages'][stage]
            if (entry['exit_code'] or digest(previous / entry['artifact']) != entry['artifact_sha256']
                    or digest(previous / entry['log']) != entry['log_sha256']):
                raise ValueError(f'correctness receipt for {stage} is incomplete or changed')
        for name in BINARIES:
            binary = previous / 'bin' / name
            if digest(binary) != old['binary_sha256'][name]:
                raise ValueError(f'reused binary {name} changed')
        evidence = self.out / 'reused-correctness'
        evidence.mkdir()
        for stage in CORRECTNESS:
            entry = old['stages'][stage].copy()
            for key in ('artifact', 'log'):
                source = previous / entry[key]
                destination = evidence / f'{stage}{source.suffix}'
                shutil.copy2(source, destination)
                entry[key] = str(destination.relative_to(self.out))
            self.report['stages'][stage] = entry
        for name in BINARIES:
            shutil.copy2(previous / 'bin' / name, self.bin / name)
        self.report['reused_correctness'] = str(previous)
        self.record_binaries()

    def record_binaries(self):
        self.report['binary_sha256'] = {name: digest(self.bin / name) for name in BINARIES}
        self.save()

    def correctness(self):
        a = self.args
        inputs = self.out / 'inputs'
        inputs.mkdir()
        for name, original in (('capture.py', a.capture), ('observed.json', a.observed), ('expected.json', a.expected)):
            destination = inputs / name
            shutil.copyfile(original, destination)
            if digest(destination) != self.ready['input_files'][name.split('.')[0]]['sha256']:
                raise ValueError(f'{name} changed after preflight')
        odin = self.env['ODIN']
        for name in ('lua', 'diagnostics'):
            self.step(f'{name}-build', ['bash', f'tools/build_{name}.sh', 'release'], 3600)
        self.step('release-build', [odin, 'build', 'src', '-o:speed', f'-out:{self.server}'], 3600)
        self.step('simulation-build', [*PYTHON, SIMULATION, 'build', '--output', self.worker], 3600)
        self.step('change-log-build', [odin, 'build', 'tools/change_log', '-vet', '-strict-style', f'-out:{self.reader}'], 3600)
        self.record_binaries()
        self.step('functional', [*PYTHON, FUNCTIONAL, '--profile', 'full', '--server', self.server,
                                 '--out', self.out / 'functional', '--port-base', self.base,
                                 '--modern-python', a.modern_python, '--llama-python', a.llama_python,
                                 '--capture', inputs / 'capture.py', '--observed', inputs / 'observed.json',
                                 '--expected', inputs / 'expected.json'], 172800, 'functional/summary.json', independent=True)
        row = self.report['stages']['functional']
        if row['exit_code'] == 0:
            receipt = self.out / 'functional/server.sha256'
            if not receipt.is_file() or receipt.read_text().strip() != self.report['binary_sha256']['eski']:
                row.update(exit_code=1, error='functional summary used a different server binary')
        self.step('virtual', [*PYTHON, SIMULATION, 'virtual', '--binary', self.worker, '--out', self.out / 'virtual',
                              '--first-seed', a.first_seed, '--seeds', a.seeds, '--steps', a.steps], 86400, 'virtual/summary.json', independent=True)
        self.step('native', [*PYTHON, SIMULATION, 'native', '--binary', self.server, '--out', self.out / 'native',
                             '--ports', f'{self.base}-{self.base+9}', '--cycles', a.cycles,
                             '--transactions', a.transactions], 86400, 'native/summary.json', independent=True)
        self.append_probe('change-log-probe', verify=True)
        self.search_probe('search-json-probe', verify=True)

    def append_probe(self, name, verify=False):
        command = [*self.client, *PYTHON, APPEND, '--server', self.server, '--cpu', self.args.server_cpus,
                   '--port', self.base+4, '--size', 'custom', '--writes', self.args.append_writes, '--fsync', 'always',
                   '--change-log-reader', self.reader, '--work-dir', self.out / f'{name}-data',
                   '--out', self.out / f'{name}.json']
        self.step(name, command + (['--verify-only'] if verify else []), 14400, f'{name}.json', independent=verify)

    def search_probe(self, name, verify=False):
        a = self.args
        command = [*self.client, *PYTHON, SEARCH, '--server', self.server, '--server-cpus', a.server_cpus,
                   '--port', self.base+5, '--out', self.out / name, '--documents', 24 if verify else a.search_documents,
                   '--warmup', 0 if verify else a.search_warmup, '--requests', 8 if verify else a.search_requests]
        self.step(name, command + (['--verify-only'] if verify else []), 14400, f'{name}/summary.json', independent=verify)

    def verify_outcomes(self):
        failed = [name for name in CORRECTNESS if self.report['stages'][name]['exit_code'] != 0]
        if failed:
            raise ValueError('correctness stages failed: ' + ', '.join(failed))
        results = {name: json.loads((self.out / self.report['stages'][name]['artifact']).read_text())
                   for name in CORRECTNESS}
        functional = {row['step']: row['exit_code'] for row in results['functional']['steps']}
        required = {'strict-check', 'documentation', 'conformance-off', 'vectorset-off', 'scripting-off',
                    'smoke-off', 'vector-replies-off', 'labelled', 'owners-shared', 'owners-user',
                    'owners-only-user', 'search-smoke', 'search-capture', 'packages', 'search-clients',
                    'search-advanced-reference', 'search-pipeline-reference'}
        if results['functional']['profile'] != 'full' or required - functional.keys() or any(functional.values()):
            raise ValueError('functional report omits successful full-profile checks')
        virtual = results['virtual']
        count = self.args.seeds
        if (virtual['sha256'] != self.report['binary_sha256']['eski-simulation'] or
                virtual['completed_seeds'] != count or virtual['first_seed'] != self.args.first_seed or
                virtual['steps'] != self.args.steps or virtual['seeds'] != count):
            raise ValueError('virtual receipt does not cover the requested seeds and binary')
        native = results['native']
        if (native['sha256'] != self.report['binary_sha256']['eski'] or
                native['appendfsync'] != 'always' or native['recovered_cycles'] != self.args.cycles or
                native['acknowledged_transactions'] != self.args.cycles * self.args.transactions):
            raise ValueError('native receipt does not cover the requested restarts and binary')
        mirror = results['change-log-probe']['rows']
        if (len(mirror) != 2 or {row['change_log'] for row in mirror} != {True, False} or
                any(row['timed'] or row['fsync'] != 'always' for row in mirror)):
            raise ValueError('change-log receipt omits the untimed off/on probes')
        search = results['search-json-probe']
        if (search['timed'] or {row['target'] for row in search['rows']} != {'redis-search', 'eski'} or
                any(row['checked_requests'] < 10 for row in search['rows'])):
            raise ValueError('Search/JSON receipt omits the untimed checks on both engines')

    def baseline(self):
        a = self.args
        if not self.report['correctness']:
            raise RuntimeError('successful correctness receipt is required before benchmarks')
        for key, info in self.ready['images'].items():
            if probe(['docker', 'image', 'inspect', '--format', '{{.Id}}', info['name']]) != info['id']:
                raise ValueError(f'image identity changed after preflight: {key}')
        stock = self.ready['settings']['stock_limits']
        env = {'ESKI_BIN': str(self.server), 'BENCH_OUTPUT_DIR': str(self.out / 'stock'),
               'BENCH_SERVER_CPUS': a.server_cpus, 'BENCH_CLIENT_CPUS': a.client_cpus,
               'BENCH_DRAGONFLY_THREADS': str(len(cpu_set(a.server_cpus))), 'BENCH_SERVER_MEMORY': stock['server_memory'],
               'BENCH_CLIENT_MEMORY': stock['client_memory'], 'BENCH_SERVER_MAXMEMORY': str(stock['maxmemory'])}
        for offset, target in enumerate(('redis', 'valkey', 'dragonfly', 'eski')):
            env[f'BENCH_PORT_{target.upper()}'] = str(self.base+offset)
        for key in ('redis', 'valkey', 'dragonfly', 'memtier'):
            env[f'BENCH_{key.upper()}_IMAGE'] = self.ready['images'][key]['id']
        self.step('stock', ['bash', 'bench/run.sh', '--targets', 'redis,valkey,dragonfly,eski',
                            '--scenarios', STOCK_SCENARIOS], 14400, 'stock/summary.json', env)
        self.step('aof-append', [*self.client, *PYTHON, APPEND, '--server', self.server, '--cpu', a.server_cpus,
                                 '--port', self.base, '--modes', 'off', '--encryption', 'off', '--fsync', 'always',
                                 '--size', 'custom', '--writes', a.append_writes, '--work-dir', self.out / 'aof-data',
                                 '--out', self.out / 'aof-append.json'], 14400, 'aof-append.json')
        self.append_probe('change-log-append')
        self.step('graph-load', [*self.client, *PYTHON, 'bench/vectorset/graph_load.py', '--server', self.server,
                                 '--cpu', a.server_cpus, '--port', self.base+6, '--size', 'custom',
                                 '--elements', a.graph_elements, '--work-dir', self.out / 'graph-data',
                                 '--out', self.out / 'graph-load.json'], 14400, 'graph-load.json')
        self.search_probe('search-json')
        self.step('simulation-rate', [*self.client, *PYTHON, SIMULATION, 'virtual', '--binary', self.worker,
                                      '--out', self.out / 'simulation-rate', '--first-seed', a.first_seed,
                                      '--seeds', min(a.seeds, 16), '--steps', a.steps, '--measure'],
                  14400, 'simulation-rate/summary.json')

    def execute(self):
        try:
            if self.args.reuse_correctness:
                self.reuse(self.args.reuse_correctness)
            else:
                self.correctness()
            self.verify_outcomes()
            if source_fingerprint(self.args.revision) != self.ready['source']['sha256']:
                raise ValueError('source changed before baseline')
            if any(digest(self.bin / name) != expected for name, expected in self.report['binary_sha256'].items()):
                raise ValueError('binary changed before baseline')
            self.report['correctness'] = True
            self.save()
            self.baseline()
            self.report['exit_code'] = 0
        except KeyboardInterrupt:
            self.report.update(exit_code=130, error='interrupted')
        except Exception as error:
            self.report.update(exit_code=1, error=str(error))
            print(error, file=sys.stderr)
        finally:
            self.save()
        return self.report['exit_code']


def limits(lo, hi):
    def parse(text):
        number = int(text)
        if not lo <= number <= hi:
            raise argparse.ArgumentTypeError(f'expected {lo} through {hi}')
        return number
    return parse


def interrupted(signum, frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description='Inspect preparation or explicitly run Eski qualification and baseline on one host')
    parser.add_argument('mode', choices=('preflight', 'run'))
    parser.add_argument('--out', type=lambda path: Path(path).resolve(), required=True, help='parent for unique run directories')
    parser.add_argument('--revision', required=True, help='full source revision supplied by the operator')
    for name in ('server-cpus', 'client-cpus'):
        parser.add_argument('--' + name, required=True, help='Linux CPU list, e.g. 2,4-5')
    for name in ('capture', 'observed', 'modern-python', 'llama-python'):
        parser.add_argument('--' + name, type=lambda path: Path(os.path.abspath(path)), required=True)
    parser.add_argument('--expected', type=lambda path: Path(path).resolve(), default=ROOT / 'test/search/expected.json')
    parser.add_argument('--reuse-correctness', type=lambda path: Path(path).resolve())
    options = (('port-base', 17840, 1024, 65496), ('min-free-gib', 10, 1, 1000000),
               ('first-seed', 8, 0, (1 << 64) - 1), ('seeds', 256, 1, 1000000), ('steps', 128, 1, 4096),
               ('cycles', 64, 1, 1000), ('transactions', 100, 1, 100000), ('search-documents', 16000, 8, 1000000),
               ('search-requests', 10000, 1, 1000000), ('search-warmup', 500, 0, 1000000),
               ('append-writes', 5000, 1, 1000000), ('graph-elements', 100000, 1, 1000000))
    for name, default, lo, hi in options:
        parser.add_argument('--' + name, type=limits(lo, hi), default=default,
                            help=f'{name.replace("-", " ")} (default {default})')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}', args.revision):
        parser.error('--revision needs a full hexadecimal source identifier')
    try:
        ready = preflight(args)
        if args.mode == 'preflight':
            print(json.dumps(ready, indent=2, sort_keys=True))
            return int(bool(ready['errors']))
        if ready['errors']:
            print(json.dumps(ready, indent=2, sort_keys=True))
            if args.out != ROOT and ROOT not in args.out.parents:
                where = new_run_dir(args.out)
                write_json(where / 'summary.json', {'preflight': ready, 'stages': {}, 'binary_sha256': {},
                                                     'correctness': False, 'exit_code': 1})
                print(f'rented run output {where}', file=sys.stderr)
            return 1
        signal.signal(signal.SIGTERM, interrupted)
        return Run(args, ready).execute()
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
