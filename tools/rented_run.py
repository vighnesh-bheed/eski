import argparse
import hashlib
import importlib.util
import io
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
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PYTHON = (sys.executable, '-IB')
GIB = 1 << 30
MINIMUM_PYTHON = (3, 11)
FUNCTIONAL = 'test/functional/check.py'
SIMULATION = 'test/simulation/exercise.py'
APPEND = 'bench/persist/aof_append.py'
SEARCH = 'bench/search_json.py'
PLAN = 'bench/baseline.py'
SCHEMA = 'eski-rented-run-v2'
CORRECTNESS = ('functional', 'virtual', 'native', 'change-log-probe', 'search-json-probe')
BUILDS = ('lua-build', 'diagnostics-build', 'release-build', 'debug-build', 'simulation-build', 'change-log-build')
REQUIRED_BUILDS = tuple(name for name in BUILDS if name != 'debug-build')
BUILD_OUTPUTS = {'release-build': 'eski', 'debug-build': 'eski-debug', 'simulation-build': 'eski-simulation',
                 'change-log-build': 'eski-change-log'}
BINARIES = ('eski', 'eski-debug', 'eski-simulation', 'eski-change-log')
QUALIFIED_BINARIES = ('eski', 'eski-simulation', 'eski-change-log')
FINAL = 'bundle'
RESERVED = set(CORRECTNESS) | set(BUILDS) | {FINAL, 'bin', 'inputs', 'summary', 'rented-run', 'SHA256SUMS'}
PLAN_IMAGES = ('redis', 'valkey', 'dragonfly', 'memtier', 'redis-search')
ODIN_VERSION = 'dev-2026-10-nightly:84bc3fc'
CLANG_MAJORS = (18, 22)
SMOKE_REDIS = 'docker.io/library/redis:7.4.11@sha256:44960b3100c48159a66d28c18b0588c193492e25f7551d60e51dd464fc3eca5b'
MEMCACHED = 'docker.io/library/memcached:1.6@sha256:a395a1bcf5e0e2b0fa4a0142e12b4e24a2320ba4b7c6ffa8655a1a86e8f29dee'
DISPLAY_DRIVERS = ('i915', 'xe', 'ast', 'amdgpu', 'radeon', 'nouveau', 'mgag200')
PACKAGE_TIMERS = ('apt-daily.timer', 'apt-daily-upgrade.timer', 'unattended-upgrades.service', 'dnf-makecache.timer',
                  'packagekit.service', 'fwupd-refresh.timer')
SANITIZER_PROGRAM = 'int main(void) { volatile char data[8] = {0}; return data[3]; }\n'
HEADER_PROGRAM = '#include <libunwind.h>\n#include <openssl/ssl.h>\n#include <lzma.h>\nint main(void) { return OPENSSL_VERSION_MAJOR < 3; }\n'
FULL_SIZES = {'first_seed': 8, 'seeds': 256, 'steps': 128, 'cycles': 64, 'transactions': 100, 'probe_writes': 5000}
REHEARSAL_SIZES = {'first_seed': 8, 'seeds': 2, 'steps': 4, 'cycles': 2, 'transactions': 3, 'probe_writes': 200}
VIRTUAL_TIMEOUT = 90
FUNCTIONAL_ALLOWANCE = 2 * GIB
FIELDS = ('revision', 'server_cpus', 'client_cpus', 'capture', 'observed', 'expected', 'modern_python', 'llama_python',
          'input_sums', 'port_base', 'min_free_gib', 'first_seed', 'seeds', 'steps', 'cycles', 'transactions',
          'plan_profile', 'rehearsal')


def digest(path):
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def git_command():
    return ['git', '-C', str(ROOT), '-c', 'core.fsmonitor=false']


def source_fingerprint(revision):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS='0')

    def read_git(*args):
        return subprocess.run([*git_command(), *args], env=environment, capture_output=True,
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
    pending = path.with_name(path.name + '.tmp')
    pending.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    pending.replace(path)


def probe(command, input=None, timeout=20):
    result = subprocess.run(list(map(str, command)), cwd=ROOT, input=input, capture_output=True, text=True,
                            timeout=timeout)
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


def read_text(path, default=None):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return default


def topology(cpus):
    rows = {}
    for cpu in sorted(cpus):
        root = Path(f'/sys/devices/system/cpu/cpu{cpu}/topology')
        rows[str(cpu)] = {name: (root / name).read_text().strip()
                          for name in ('physical_package_id', 'core_id', 'thread_siblings_list')
                          if (root / name).is_file()}
    return rows


def boot_id():
    return digest('/proc/sys/kernel/random/boot_id')


def load_functional():
    spec = importlib.util.spec_from_file_location('eski_functional_check', ROOT / FUNCTIONAL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def required_functional_steps(profile):
    return load_functional().profile_steps(profile, True)


def functional_timeouts(profile):
    module = load_functional()
    args = argparse.Namespace(profile=profile, port_base=17840, steps=None, capture=Path('capture.py'),
                              observed=Path('observed.json'), expected=ROOT / 'test/search/expected.json',
                              modern_python=Path('modern'), llama_python=Path('llama'), server=Path('eski'))
    run = module.Run(args, Path('out'), dry=True)
    run.full() if profile == 'full' else run.light()
    return sum(row['timeout'] for row in run.rows)


def load_plan():
    spec = importlib.util.spec_from_file_location('eski_baseline_plan', ROOT / PLAN)
    if spec is None or spec.loader is None:
        raise ValueError(f'{PLAN} is missing')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def checked_plan(module, context):
    areas = getattr(module, 'AREAS', None)
    if not isinstance(areas, tuple) or not areas or not all(isinstance(area, str) for area in areas):
        raise ValueError('the baseline plan must define AREAS as a tuple of names')
    steps = module.steps(context)
    if not isinstance(steps, list):
        raise ValueError('the baseline plan returned no list of steps')
    seen = set()
    for step in steps:
        if not isinstance(step, dict):
            raise ValueError('every baseline step must be a dict')
        name = step.get('name')
        if not isinstance(name, str) or not re.fullmatch(r'[a-z0-9][a-z0-9-]*', name) or name in seen:
            raise ValueError(f'baseline step name {name!r} is invalid or repeated')
        if name in RESERVED or name.startswith(('functional', 'bundle', 'rented-run')):
            raise ValueError(f'baseline step name {name} collides with a stage or file of the run')
        seen.add(name)
        if step.get('area') not in areas:
            raise ValueError(f'baseline step {name} names an unknown area')
        command = step.get('command')
        if not isinstance(command, list) or not command or not all(isinstance(part, str) for part in command):
            raise ValueError(f'baseline step {name} needs a command of strings')
        artifact = step.get('artifact')
        if not isinstance(artifact, str) or Path(artifact).is_absolute() or '..' in Path(artifact).parts or not artifact:
            raise ValueError(f'baseline step {name} needs a relative artifact path inside the run directory')
        for key in ('timeout', 'estimate_seconds'):
            if not isinstance(step.get(key), int) or isinstance(step.get(key), bool) or step[key] < 0:
                raise ValueError(f'baseline step {name} needs a whole number {key}')
        if step['timeout'] < 1:
            raise ValueError(f'baseline step {name} needs a positive timeout')
        environment = step.get('environment')
        if not isinstance(environment, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in environment.items()):
            raise ValueError(f'baseline step {name} needs an environment of strings')
        needs = step.get('needs')
        if not isinstance(needs, list) or set(needs) - set(PLAN_IMAGES):
            raise ValueError(f'baseline step {name} needs known image keys')
    return areas, steps


def image_names():
    design = json.loads((ROOT / 'bench/testbed/design.json').read_text())
    images = {row['target']: row['image'] for row in design['engines'] if row['target'] != 'eski-docker'}
    images['memtier'] = design['load_generator']['image']
    search = (ROOT / 'test/search/compare.py').read_text()
    images['redis-search'] = re.search(r'^IMAGE = "([^"]+)"$', search, re.MULTILINE)[1]
    images['smoke-redis'] = SMOKE_REDIS
    images['memcached'] = MEMCACHED
    return images, design['resources']


def executable(name):
    resolved = shutil.which(name)
    if not resolved:
        raise ValueError(f'executable {name} is unavailable')
    return str(Path(resolved).absolute())


def mount_of(path):
    path = Path(path).resolve()
    while not path.exists():
        path = path.parent
    best = None
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        left, _, right = line.partition(' - ')
        fields, tail = left.split(), right.split()
        point = fields[4].replace('\\040', ' ')
        if (path == Path(point) or Path(point) in path.parents) and (best is None or len(point) >= len(best['mount'])):
            best = {'mount': point, 'fstype': tail[0], 'source': tail[1] if len(tail) > 1 else ''}
    if best:
        device = Path(best['source']).name
        block = Path('/sys/class/block') / device
        if block.exists():
            parent = block.resolve().parent if (block / 'partition').exists() else block.resolve()
            best['rotational'] = read_text(parent / 'queue/rotational')
            best['model'] = read_text(parent / 'device/model')
    return best


def cpuinfo():
    models, microcode = set(), set()
    for line in read_text('/proc/cpuinfo', '').splitlines():
        key, _, value = line.partition(':')
        if key.strip() == 'model name':
            models.add(value.strip())
        elif key.strip() == 'microcode':
            microcode.add(value.strip())
    return {'model': sorted(models), 'microcode': sorted(microcode)}


def meminfo():
    rows = {}
    for line in read_text('/proc/meminfo', '').splitlines():
        key, _, value = line.partition(':')
        if key in ('MemTotal', 'HugePages_Total', 'Hugepagesize'):
            rows[key] = value.strip()
    return rows


def host_fingerprint(cpus, out):
    frequency = {}
    for cpu in sorted(cpus):
        root = Path(f'/sys/devices/system/cpu/cpu{cpu}/cpufreq')
        frequency[str(cpu)] = {name: read_text(root / name) for name in (
            'scaling_governor', 'scaling_driver', 'scaling_min_freq', 'scaling_max_freq',
            'cpuinfo_min_freq', 'cpuinfo_max_freq', 'energy_performance_preference')}
    return {'cpu': cpuinfo(), 'kernel_cmdline': read_text('/proc/cmdline'), 'frequency': frequency,
            'smt': {'control': read_text('/sys/devices/system/cpu/smt/control'),
                    'active': read_text('/sys/devices/system/cpu/smt/active')},
            'transparent_hugepage': {'enabled': read_text('/sys/kernel/mm/transparent_hugepage/enabled'),
                                     'defrag': read_text('/sys/kernel/mm/transparent_hugepage/defrag')},
            'memory': meminfo(), 'filesystems': {'output': mount_of(out), 'checkout': mount_of(ROOT)}}


def quiet_findings(fingerprint, shared, out):
    findings, refusals = [], []
    for cpu, row in fingerprint['frequency'].items():
        if row['scaling_governor'] != 'performance':
            findings.append(f'CPU {cpu} governor is {row["scaling_governor"] or "not exposed"}, not performance')
    active, control = fingerprint['smt']['active'], fingerprint['smt']['control']
    if active == '1':
        findings.append('simultaneous multithreading is active')
    elif active is None and control not in ('notsupported', 'notimplemented', 'off', 'forceoff'):
        findings.append(f'simultaneous multithreading state is unknown (control {control})')
    if shared:
        findings.append('the server and client CPU roles share physical cores: ' + ','.join(map(str, shared)))
    loaded = {line.split()[0] for line in read_text('/proc/modules', '').splitlines() if line}
    for driver in DISPLAY_DRIVERS:
        if driver in loaded:
            findings.append(f'display driver {driver} is loaded')
    systemctl = shutil.which('systemctl')
    if systemctl:
        for unit in PACKAGE_TIMERS:
            state = subprocess.run([systemctl, 'is-active', unit], capture_output=True, text=True, timeout=10).stdout.strip()
            if state in ('active', 'activating'):
                findings.append(f'{unit} is {state}')
    else:
        findings.append('systemctl is unavailable, so package timers were not inspected')
    if '[always]' in (fingerprint['transparent_hugepage']['enabled'] or ''):
        findings.append('transparent huge pages are enabled always')
    output = fingerprint['filesystems']['output'] or {}
    if output.get('fstype') in ('tmpfs', 'ramfs'):
        refusals.append(f'the output directory is on {output["fstype"]}, where sync timings are meaningless')
    return findings, refusals


def parse_sums(path):
    sums = {}
    for line in Path(path).read_text().splitlines():
        match = re.fullmatch(r'([a-f0-9]{64}) [ *](.+)', line.strip())
        if match:
            sums[Path(match[2]).name] = match[1]
    return sums


def conformance_downloads():
    rows = []
    run = (ROOT / 'test/conformance/run.sh').read_text()
    tag = re.search(r'^REDIS_TAG="([^"]+)"$', run, re.MULTILINE)[1]
    rows.append({'name': f'Redis {tag} test suite', 'url': f'https://github.com/redis/redis/archive/refs/tags/{tag}.tar.gz',
                 'cached': (ROOT / f'test/conformance/.redis/redis-{tag}/tests/test_helper.tcl').is_file()})
    vectorset = (ROOT / 'test/conformance/vectorset.sh').read_text()
    tag = re.search(r'^REDIS_TAG="([^"]+)"$', vectorset, re.MULTILINE)[1]
    rows.append({'name': f'Redis {tag} vector set unit', 'url': f'https://github.com/redis/redis/archive/refs/tags/{tag}.tar.gz',
                 'cached': (ROOT / f'test/conformance/.vectorset/redis-{tag}').is_dir()})
    rows.append({'name': 'pinned redis client for the vector set unit', 'url': 'https://pypi.org/simple/redis/',
                 'cached': (ROOT / 'test/conformance/.vectorset/venv/bin/python3').exists()})
    return rows


def plan_context(args, out, binaries, images, limits, sizes):
    return {'profile': args.plan_profile, 'out': str(out),
            'binaries': {name: str(binaries / name) for name in BINARIES},
            'server_cpus': args.server_cpus, 'client_cpus': args.client_cpus,
            'ports': [args.port_base, args.port_base + 39],
            'images': {key: images.get(key) or '' for key in PLAN_IMAGES},
            'limits': dict(limits), 'python': list(PYTHON),
            'seeds': {'first': sizes['first_seed'], 'count': sizes['seeds'], 'steps': sizes['steps']}}


def preflight(args):
    issues = []
    ready = {'errors': issues, 'timing_refusals': [], 'quiet_findings': [], 'platform': platform.uname()._asdict(),
             'rehearsal': args.rehearsal}

    def inspect(label, action):
        try:
            return action()
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            issues.append(f'{label}: {error}')
            return None

    sizes = REHEARSAL_SIZES.copy() if args.rehearsal else {
        key: value if getattr(args, key, None) is None else getattr(args, key) for key, value in FULL_SIZES.items()}
    ready['sizes'] = sizes
    available = os.sched_getaffinity(0)
    ready['cpu_affinity'] = sorted(available)
    ready['cpu_topology'] = inspect('CPU topology', lambda: topology(available))
    server = client = set()
    try:
        server, client = cpu_set(args.server_cpus), cpu_set(args.client_cpus)
    except ValueError as error:
        issues.append(str(error))
    if server & client or (server | client) - available:
        issues.append('CPU roles must be disjoint and permitted by current affinity')
    shared = []
    if ready['cpu_topology']:
        siblings = {i for cpu in server for i in cpu_set(ready['cpu_topology'].get(str(cpu), {}).get('thread_siblings_list', str(cpu)))}
        shared = sorted(siblings & client)
    ready['shared_physical_cores'] = shared
    ready['source'] = {'revision': args.revision, 'sha256': inspect('source fingerprint', lambda: source_fingerprint(args.revision))}
    ready['os_release'] = inspect('OS release', lambda: Path('/etc/os-release').read_text())
    ready['boot_id_sha256'] = inspect('boot ID', boot_id)
    ready['settings'] = {key: getattr(args, key) for key in ('server_cpus', 'client_cpus', 'port_base', 'min_free_gib',
                                                              'plan_profile')}
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
    if sizes['first_seed'] + sizes['seeds'] - 1 >= 1 << 64:
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
                               ('ss', 'ss', '--version'), ('timeout', 'timeout', '--version'),
                               ('tar', 'tar', '--version'), ('sha256sum', 'sha256sum', '--version'),
                               ('python', sys.executable, '--version')):
        def tool():
            path = executable(name)
            return {'path': path, 'version': probe([path, version]).splitlines()[0]}
        ready['tools'][key] = inspect(key, tool)
    odin_row = ready['tools']['odin']
    if odin_row and odin_row['version'].split()[-1] != ODIN_VERSION:
        issues.append(f'Odin is {odin_row["version"].split()[-1]}; this tree is built and checked with {ODIN_VERSION}')
    clang_row = ready['tools']['clang']
    if clang_row:
        match = re.search(r'clang version (\d+)\.', clang_row['version'])
        if not match or not CLANG_MAJORS[0] <= int(match[1]) <= CLANG_MAJORS[1]:
            issues.append(f'clang must be a major version from {CLANG_MAJORS[0]} to {CLANG_MAJORS[1]}: {clang_row["version"]}')
    tcl = next((shutil.which(name) for name in ('tclsh8.6', 'tclsh9.0', 'tclsh8.5', 'tclsh') if shutil.which(name)), None)
    if tcl:
        ready['tools']['tcl'] = inspect('native Tcl version', lambda: probe([tcl], 'puts [info patchlevel]\n'))
    if clang_row:
        ready['native'] = inspect('native compiler checks', lambda: native_checks(clang_row['path']))
    ready['python_venv'] = inspect('python3 -m venv', venv_check)
    ready['downloads'] = conformance_downloads()
    for row in ready['downloads']:
        if not row['cached']:
            row['reachable'] = inspect(f'reach {row["url"]}', lambda: bool(probe(['curl', '-sSfIL', '--max-time', '20', '-o', '/dev/null', '-w', '%{http_code}', row['url']], timeout=30)))
    inputs = {'capture': args.capture, 'observed': args.observed, 'expected': args.expected}
    ready['input_files'] = {name: {'path': str(path), 'sha256': inspect(name, lambda: digest(path))}
                            for name, path in inputs.items() if path is not None}
    if not args.rehearsal:
        for name in ('capture', 'observed'):
            if inputs[name] is None:
                issues.append(f'--{name} is required outside a rehearsal')
    if args.input_sums:
        staged = inspect('staged input checksums', lambda: parse_sums(args.input_sums))
        if staged is not None:
            for name in ('capture', 'observed'):
                row = ready['input_files'].get(name)
                if row and staged.get(Path(row['path']).name) != row['sha256']:
                    issues.append(f'{name} does not match the staged checksum file {args.input_sums}')
            ready['input_sums'] = {'path': str(args.input_sums), 'sha256': digest(args.input_sums)}
    ready['interpreters'] = {}
    for name, path in (('modern', args.modern_python), ('llama', args.llama_python)):
        if path is None:
            if not args.rehearsal:
                issues.append(f'--{name}-python is required outside a rehearsal')
            continue

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
    ready['host'] = host_fingerprint(server | client, args.out)
    ready['quiet_findings'], ready['timing_refusals'] = quiet_findings(ready['host'], shared, args.out)
    plan_out = args.out / 'run-preflight'
    images = {key: (ready['images'].get(key) or {}).get('id') for key in PLAN_IMAGES}
    try:
        areas, steps = checked_plan(load_plan(), plan_context(args, plan_out, plan_out / 'bin', images,
                                                             ready['settings']['stock_limits'], sizes))
        ready['plan'] = {'areas': list(areas), 'steps': [{key: step[key] for key in ('name', 'area', 'estimate_seconds', 'timeout', 'needs')} for step in steps]}
    except Exception as error:
        ready['plan'] = None
        ready['timing_refusals'].append(f'baseline plan {PLAN}: {error}')
    ready['estimate'] = estimate(args, sizes, ready['plan'])
    return ready


def native_checks(clang):
    with tempfile.TemporaryDirectory(prefix='eski-preflight-') as folder:
        folder = Path(folder)
        (folder / 'asan.c').write_text(SANITIZER_PROGRAM)
        (folder / 'headers.c').write_text(HEADER_PROGRAM)
        probe([clang, '-fsanitize=address', '-g', str(folder / 'asan.c'), '-o', str(folder / 'asan')], timeout=120)
        subprocess.run([str(folder / 'asan')], check=True, timeout=30, capture_output=True)
        probe([clang, str(folder / 'headers.c'), '-o', str(folder / 'headers'), '-lunwind', '-lssl', '-lcrypto', '-llzma'], timeout=120)
        subprocess.run([str(folder / 'headers')], check=True, timeout=30, capture_output=True)
    return {'address_sanitizer': 'compiled, linked and ran', 'headers': 'libunwind, OpenSSL 3 and liblzma compiled, linked and ran'}


def venv_check():
    python3 = executable('python3')
    with tempfile.TemporaryDirectory(prefix='eski-venv-') as folder:
        probe([python3, '-I', '-m', 'venv', str(Path(folder) / 'venv')], timeout=120)
        version = probe([str(Path(folder) / 'venv/bin/python3'), '-I', '-c', 'import platform; print(platform.python_version())'])
    return {'python3': python3, 'version': version}


def estimate(args, sizes, plan):
    builds = len(BUILDS) * 3600
    functional = functional_timeouts('light' if args.rehearsal else 'full')
    virtual = sizes['seeds'] * 7 * VIRTUAL_TIMEOUT
    upper = {'builds': builds, 'functional': functional, 'virtual': virtual, 'native': 86400,
             'change-log-probe': 14400, 'search-json-probe': 14400}
    plan_seconds = sum(step['estimate_seconds'] for step in plan['steps']) if plan else None
    disk = {'virtual_traces': sizes['seeds'] * 7 * (sizes['steps'] + 32) * 256,
            'native_append_file': sizes['cycles'] * sizes['transactions'] * 160,
            'functional_allowance': FUNCTIONAL_ALLOWANCE if not args.rehearsal else FUNCTIONAL_ALLOWANCE // 16,
            'binaries': 64 << 20}
    disk['bundles'] = sum(disk.values())
    return {'correctness_upper_bound_seconds': upper, 'plan_estimate_seconds': plan_seconds,
            'disk_bytes_before_baseline': disk, 'disk_note': 'the plan states no disk use; keep the free-space margin'}


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
    keep = {key: data.get(key) for key in ('source', 'platform', 'tools', 'interpreters', 'images', 'rehearsal')}
    keep['input_files'] = {key: value.get('sha256') for key, value in (data.get('input_files') or {}).items()
                           if key != 'expected'}
    keep['sizes'] = data.get('sizes')
    return keep


def new_run_dir(root):
    root.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix=time.strftime('run-%Y%m%d-%H%M%S-'), dir=root))


def utc():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


class Tee(io.TextIOBase):
    def __init__(self, stream, path):
        self.stream = stream
        self.file = path.open('a', buffering=1)

    def write(self, text):
        self.file.write(text)
        try:
            self.stream.write(text)
            self.stream.flush()
        except (OSError, ValueError):
            pass
        return len(text)

    def flush(self):
        self.file.flush()


def private_path(relative):
    parts = Path(relative).parts
    return bool(parts) and (parts[0] == 'inputs' or 'search-capture' in parts or Path(relative).name == 'search-capture.log')


def state_of(row):
    if not row:
        return 'not run'
    return 'interrupted' if row.get('exit_code') == 130 else 'failed'


def print_owed(report):
    owed = report.get('owed') or []
    print('qualified' if report.get('qualified') else 'not qualified' + (' (rehearsal)' if report.get('rehearsal') else ''), flush=True)
    for row in owed:
        print(f'owed {row["stage"]}{"/" + row["step"] if row.get("step") else ""}: {row["state"]}; complete with: {" ".join(row["command"])}', flush=True)


def describe_estimate(ready):
    value = ready.get('estimate') or {}
    upper = value.get('correctness_upper_bound_seconds') or {}
    plan = value.get('plan_estimate_seconds')
    disk = sum((value.get('disk_bytes_before_baseline') or {}).values())
    return ('estimate: builds and correctness finish within %.1f hours by their timeouts; the baseline plan states %s; '
            'about %.1f GiB of output before the baseline' % (sum(upper.values()) / 3600,
                                                                'no plan' if plan is None else '%d min' % -(-plan // 60),
                                                                disk / GIB))


class Run:
    def __init__(self, args, ready, previous=None, log_output=True):
        self.args = args
        self.ready = ready
        self.sizes = ready['sizes']
        if previous:
            self.out = previous
            self.report = json.loads((previous / 'summary.json').read_text())
        else:
            self.out = new_run_dir(args.out)
            self.report = {'schema': SCHEMA, 'stages': {}, 'binary_sha256': {}, 'exit_code': None,
                           'rehearsal': args.rehearsal, 'qualifying': not args.rehearsal,
                           'settings': {key: str(getattr(args, key)) if isinstance(getattr(args, key), Path) else getattr(args, key) for key in FIELDS},
                           'invocations': [], 'first_preflight': ready}
        self.bin = self.out / 'bin'
        self.bin.mkdir(exist_ok=True)
        self.report['preflight'] = ready
        self.report['invocations'].append({'started': utc(), 'boot_id_sha256': ready.get('boot_id_sha256'),
                                           'argv': sys.argv[1:], 'only': args.only, 'skip': args.skip,
                                           'allow_unqualified': args.allow_unqualified,
                                           'allow_noisy_host': args.allow_noisy_host})
        self.base = args.port_base
        self.env = {key: val for key, val in os.environ.items() if not key.startswith(('BENCH_', 'ESKI_'))}
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
        self.interrupted = False
        if log_output:
            sys.stdout = Tee(sys.__stdout__, self.out / 'rented-run.log')
            sys.stderr = Tee(sys.__stderr__, self.out / 'rented-run.log')
        self.save()
        print(f'rented run output {self.out}', flush=True)

    def save(self):
        write_json(self.out / 'summary.json', self.report)

    def passed(self, name):
        row = self.report['stages'].get(name)
        return bool(row) and row.get('exit_code') == 0

    def retire(self, name):
        row = self.report['stages'].get(name)
        if not row:
            return []
        history = row.pop('history', [])
        attempt = len(history) + 1
        log = self.out / row.get('log', f'{name}.log')
        if log.is_file():
            kept = log.with_name(f'{name}.attempt-{attempt}.log')
            log.replace(kept)
            row['log'] = kept.name
        history.append(row)
        return history

    def step(self, name, args, timeout, artifact=None, extra=None, kind='correctness', inputs=None):
        command = list(map(str, args))
        log = self.out / f'{name}.log'
        history = self.retire(name)
        row = {'kind': kind, 'command': command, 'log': log.name, 'environment': extra or {}, 'exit_code': None,
               'started': utc(), 'boot_id_sha256': boot_id(), 'inputs': inputs or {}}
        if history:
            row['history'] = history
        self.report['stages'][name] = row
        self.save()
        print(name, flush=True)
        start = time.monotonic()
        try:
            with log.open('wb') as output:
                process = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                           env=dict(self.env, **(extra or {})), stdin=subprocess.DEVNULL,
                                           start_new_session=True)
                try:
                    row['exit_code'] = process.wait(timeout=timeout)
                finally:
                    stop_step(process)
            if artifact:
                row['artifact'] = artifact
                path = self.out / artifact
                if path.is_file():
                    row['artifact_sha256'] = digest(path)
                if row['exit_code'] == 0 and (not path.is_file() or json.loads(path.read_text()).get('exit_code', 0) != 0):
                    raise ValueError(f'missing or failing report {artifact}')
            if row['exit_code'] != 0:
                raise RuntimeError(f'{name} exited with {row["exit_code"]}. See {log}')
        except KeyboardInterrupt:
            row.update(exit_code=130, error='interrupted')
            self.interrupted = True
            raise
        except subprocess.TimeoutExpired:
            row.update(exit_code=124, error=f'{name} did not finish within {timeout} seconds')
            print(row['error'], file=sys.stderr)
        except Exception as error:
            row['error'] = str(error)
            row['exit_code'] = row['exit_code'] or 1
            print(error, file=sys.stderr)
        finally:
            if log.is_file():
                row['log_sha256'] = digest(log)
            row['seconds'] = round(time.monotonic() - start, 2)
            row['finished'] = utc()
            self.save()
        return row['exit_code'] == 0

    def fail(self, name, error):
        row = self.report['stages'][name]
        row.update(exit_code=1, error=error)
        print(f'{name}: {error}', file=sys.stderr)
        self.save()

    def record_binaries(self):
        self.report['binary_sha256'] = {name: digest(self.bin / name) for name in BINARIES if (self.bin / name).is_file()}
        self.save()

    def check_receipts(self):
        for name, row in self.report['stages'].items():
            if row.get('exit_code') != 0:
                continue
            for key in ('log', 'artifact'):
                if row.get(key) and digest(self.out / row[key]) != row.get(key + '_sha256'):
                    raise ValueError(f'the receipt of {name} changed since it was recorded ({row[key]})')
        for name, expected in self.report['binary_sha256'].items():
            if digest(self.bin / name) != expected:
                raise ValueError(f'binary {name} changed since it was recorded')

    def stage_inputs(self):
        inputs = self.out / 'inputs'
        inputs.mkdir(mode=0o700, exist_ok=True)
        staged = self.report.setdefault('inputs', {})
        for name in ('capture', 'observed', 'expected'):
            original = getattr(self.args, name)
            if original is None:
                continue
            want = self.ready['input_files'][name]['sha256']
            current = staged.get(name)
            if current and current['sha256'] == want and digest(self.out / current['path']) == want:
                continue
            suffix = Path(original).suffix
            count = len([key for key in staged.get('history', []) if key.get('name') == name])
            destination = inputs / (f'{name}{suffix}' if not current else f'{name}-{count + 2}{suffix}')
            shutil.copyfile(original, destination)
            destination.chmod(0o600)
            if digest(destination) != want:
                raise ValueError(f'{name} changed after preflight')
            if current:
                staged.setdefault('history', []).append(dict(current, name=name))
            staged[name] = {'path': str(destination.relative_to(self.out)), 'sha256': want}
        self.save()

    def input_path(self, name):
        row = self.report.get('inputs', {}).get(name)
        return self.out / row['path'] if row else None

    def builds(self):
        odin = self.env['ODIN']
        commands = {
            'lua-build': ['bash', 'tools/build_lua.sh', 'release'],
            'diagnostics-build': ['bash', 'tools/build_diagnostics.sh', 'release'],
            'release-build': [odin, 'build', 'src', '-o:speed', f'-out:{self.server}'],
            'debug-build': [odin, 'build', 'src', '-o:speed', '-debug', f'-out:{self.bin / "eski-debug"}'],
            'simulation-build': [*PYTHON, SIMULATION, 'build', '--output', self.worker],
            'change-log-build': [odin, 'build', 'tools/change_log', '-vet', '-strict-style', f'-out:{self.reader}'],
        }

        def done(name):
            return self.passed(name) and (name not in BUILD_OUTPUTS or (self.bin / BUILD_OUTPUTS[name]).is_file())

        rebuild_all = not (done('lua-build') and done('diagnostics-build'))
        for name in BUILDS:
            if rebuild_all or not done(name):
                self.step(name, commands[name], 3600, kind='build')
        old = dict(self.report['binary_sha256'])
        self.record_binaries()
        for name, value in old.items():
            if self.report['binary_sha256'].get(name) != value:
                for stage in CORRECTNESS:
                    row = self.report['stages'].get(stage)
                    if row and row.get('exit_code') == 0:
                        row.update(exit_code=1, error=f'binary {name} was rebuilt with a different hash')
        self.save()
        return all(self.passed(name) for name in REQUIRED_BUILDS)

    def functional_dir(self):
        attempts = len(self.report['stages'].get('functional', {}).get('history', [])) + (1 if 'functional' in self.report['stages'] else 0)
        return 'functional' if attempts == 0 else f'functional-{attempts + 1}'

    def functional_inputs(self):
        return {name: (self.report.get('inputs', {}).get(name) or {}).get('sha256') for name in ('capture', 'observed', 'expected')}

    def correctness(self):
        a, s = self.args, self.sizes
        profile = 'light' if a.rehearsal else 'full'
        functional = self.report['stages'].get('functional')
        if functional and functional.get('exit_code') == 0 and functional.get('inputs') != self.functional_inputs():
            functional.update(exit_code=1, error='an input of the functional check changed')
        if not self.passed('functional'):
            previous = self.report['stages'].get('functional', {}).get('artifact')
            folder = self.functional_dir()
            command = [*PYTHON, FUNCTIONAL, '--profile', profile, '--server', self.server,
                       '--out', self.out / folder, '--port-base', self.base]
            if not a.rehearsal:
                command += ['--modern-python', a.modern_python, '--llama-python', a.llama_python,
                            '--capture', self.input_path('capture'), '--observed', self.input_path('observed'),
                            '--expected', self.input_path('expected')]
            if previous and (self.out / previous).is_file():
                command += ['--resume', (self.out / previous).parent]
            self.step('functional', command, 172800, f'{folder}/summary.json', inputs=self.functional_inputs())
        if not self.passed('virtual'):
            folder = 'virtual' if 'virtual' not in self.report['stages'] else f'virtual-{len(self.report["stages"]["virtual"].get("history", [])) + 2}'
            self.step('virtual', [*PYTHON, SIMULATION, 'virtual', '--binary', self.worker, '--out', self.out / folder,
                                  '--first-seed', s['first_seed'], '--seeds', s['seeds'], '--steps', s['steps'],
                                  '--timeout', VIRTUAL_TIMEOUT], 86400, f'{folder}/summary.json')
        if not self.passed('native'):
            folder = 'native' if 'native' not in self.report['stages'] else f'native-{len(self.report["stages"]["native"].get("history", [])) + 2}'
            self.step('native', [*PYTHON, SIMULATION, 'native', '--binary', self.server, '--out', self.out / folder,
                                 '--ports', f'{self.base}-{self.base+9}', '--cycles', s['cycles'],
                                 '--transactions', s['transactions']], 86400, f'{folder}/summary.json')
        if not self.passed('change-log-probe'):
            attempt = self.attempt_suffix('change-log-probe')
            self.step('change-log-probe', [*self.client, *PYTHON, APPEND, '--server', self.server, '--cpu', a.server_cpus,
                                           '--port', self.base + 4, '--size', 'custom', '--writes', s['probe_writes'],
                                           '--fsync', 'always', '--change-log-reader', self.reader,
                                           '--work-dir', self.out / f'change-log-probe{attempt}-data',
                                           '--out', self.out / f'change-log-probe{attempt}.json', '--verify-only'],
                      14400, f'change-log-probe{attempt}.json')
        if not self.passed('search-json-probe'):
            attempt = self.attempt_suffix('search-json-probe')
            self.step('search-json-probe', [*self.client, *PYTHON, SEARCH, '--server', self.server,
                                            '--server-cpus', a.server_cpus, '--port', self.base + 5,
                                            '--out', self.out / f'search-json-probe{attempt}', '--documents', 24,
                                            '--warmup', 0, '--requests', 8, '--verify-only'],
                      14400, f'search-json-probe{attempt}/summary.json')

    def attempt_suffix(self, name):
        row = self.report['stages'].get(name)
        return '' if not row else f'-{len(row.get("history", [])) + 2}'

    def verify_outcomes(self):
        profile = 'light' if self.args.rehearsal else 'full'
        hashes = self.report['binary_sha256']
        checks = {
            'functional': lambda r: self.verify_functional(r, profile, hashes),
            'virtual': lambda r: (r['sha256'] == hashes.get('eski-simulation') and r['completed_seeds'] == self.sizes['seeds']
                                  and r['first_seed'] == self.sizes['first_seed'] and r['steps'] == self.sizes['steps']
                                  and r['seeds'] == self.sizes['seeds'] and not r.get('failures')) or 'virtual receipt does not cover the requested seeds and binary',
            'native': lambda r: (r['sha256'] == hashes.get('eski') and r['appendfsync'] == 'always'
                                 and r['recovered_cycles'] == self.sizes['cycles']
                                 and r['acknowledged_transactions'] == self.sizes['cycles'] * self.sizes['transactions']) or 'native receipt does not cover the requested restarts and binary',
            'change-log-probe': lambda r: (len(r['rows']) == 2 and {row['change_log'] for row in r['rows']} == {True, False}
                                           and not any(row['timed'] or row['fsync'] != 'always' for row in r['rows'])) or 'change-log receipt omits the untimed off/on probes',
            'search-json-probe': lambda r: (not r['timed'] and {row['target'] for row in r['rows']} == {'redis-search', 'eski'}
                                            and all(row['checked_requests'] >= 8 for row in r['rows'])) or 'Search/JSON receipt omits the untimed checks on both engines',
        }
        for name, check in checks.items():
            row = self.report['stages'].get(name)
            if not row or row.get('exit_code') != 0:
                continue
            try:
                verdict = check(json.loads((self.out / row['artifact']).read_text()))
            except (OSError, ValueError, KeyError, TypeError) as error:
                verdict = f'{name} receipt is unreadable: {error}'
            if verdict is not True:
                self.fail(name, verdict)

    def verify_functional(self, result, profile, hashes):
        required = set(required_functional_steps(profile))
        steps = {row['step']: row.get('exit_code') for row in result.get('steps', [])}
        if result.get('profile') != profile:
            return f'functional summary is not the {profile} profile'
        missing = sorted(required - steps.keys())
        failed = sorted(name for name, code in steps.items() if code != 0)
        if missing or failed or not result.get('complete'):
            return 'functional report misses steps ' + (', '.join(missing) or 'none') + ' and has failed steps ' + (', '.join(failed) or 'none')
        if result.get('server_sha256') != hashes.get('eski'):
            return 'functional summary used a different server binary'
        return True

    def correctness_failures(self):
        failures = []
        for name in (*REQUIRED_BUILDS, *CORRECTNESS):
            row = self.report['stages'].get(name)
            if not row:
                failures.append({'stage': name, 'state': 'not run'})
            elif row.get('exit_code') != 0:
                failures.append({'stage': name, 'state': 'failed', 'error': row.get('error')})
        functional = self.report['stages'].get('functional')
        if functional and functional.get('artifact') and (self.out / functional['artifact']).is_file():
            try:
                result = json.loads((self.out / functional['artifact']).read_text())
                for row in result.get('steps', []):
                    if row.get('exit_code') not in (0,):
                        failures.append({'stage': 'functional', 'step': row.get('step'), 'state': 'failed',
                                         'error': row.get('error'), 'log': f'{Path(functional["artifact"]).parent}/{row.get("log", "")}'})
                for name in result.get('planned', []):
                    if name not in {row.get('step') for row in result.get('steps', [])}:
                        failures.append({'stage': 'functional', 'step': name, 'state': 'not run'})
            except (OSError, ValueError):
                pass
        return failures

    def baseline_gate(self):
        blockers = []
        complete = all(self.passed(name) for name in (*REQUIRED_BUILDS, *CORRECTNESS))
        if not complete and not self.args.allow_unqualified:
            blockers.append('correctness is incomplete; pass --allow-unqualified to time an unqualified run')
        blockers += self.ready['timing_refusals']
        if self.ready['quiet_findings'] and not (self.args.allow_noisy_host or self.args.rehearsal):
            blockers.append('the host is not quiet; pass --allow-noisy-host to time it anyway')
        if self.ready['plan'] is None:
            blockers.append('the baseline plan is unavailable')
        try:
            if source_fingerprint(self.args.revision) != self.ready['source']['sha256']:
                blockers.append('source changed before the baseline')
            for key, info in self.ready['images'].items():
                if probe(['docker', 'image', 'inspect', '--format', '{{.Id}}', info['name']]) != info['id']:
                    blockers.append(f'image identity changed after preflight: {key}')
            self.check_receipts()
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            blockers.append(str(error))
        return complete, blockers

    def selected(self, step):
        only, skip = self.args.only, self.args.skip
        if only and step['name'] not in only and step['area'] not in only:
            return False
        return not (skip and (step['name'] in skip or step['area'] in skip))

    def plan_steps(self):
        images = {key: (self.ready['images'].get(key) or {}).get('id') for key in PLAN_IMAGES}
        context = plan_context(self.args, self.out, self.bin, images, self.ready['settings']['stock_limits'], self.sizes)
        areas, steps = checked_plan(load_plan(), context)
        self.report['plan'] = {'profile': self.args.plan_profile, 'areas': list(areas), 'context': context,
                               'steps': [step['name'] for step in steps]}
        return steps

    def baseline(self):
        complete, blockers = self.baseline_gate()
        self.report['timing'] = {'blocked_by': blockers, 'quiet_findings': self.ready['quiet_findings'],
                                 'allow_noisy_host': self.args.allow_noisy_host or self.args.rehearsal,
                                 'correctness_complete': complete}
        self.save()
        if not blockers:
            try:
                steps = self.plan_steps()
            except Exception as error:
                blockers.append(f'baseline plan {PLAN}: {error}')
        if blockers:
            self.report['timing']['blocked_by'] = blockers
            self.save()
            print('baseline not started: ' + '; '.join(blockers), file=sys.stderr)
            return
        for step in steps:
            if not self.selected(step) or self.passed(step['name']):
                continue
            self.step(step['name'], step['command'], step['timeout'], step['artifact'], dict(step['environment']),
                      kind='baseline')
            row = self.report['stages'][step['name']]
            row.update(area=step['area'], needs=step['needs'], timed=True, qualified=complete and not self.args.rehearsal)

    def owed(self, include_bundle=True):
        rows = []
        settings = self.report['settings']
        resume = ['python3', '-IB', 'tools/rented_run.py', 'run', '--resume', str(self.out)]
        for name in (*BUILDS, *CORRECTNESS):
            row = self.report['stages'].get(name)
            if not row or row.get('exit_code') != 0:
                rows.append({'stage': name, 'state': state_of(row), 'error': (row or {}).get('error'),
                             'command': resume})
        for failure in self.correctness_failures():
            if failure.get('step'):
                rows.append(dict(failure, command=resume))
        planned = self.report.get('plan', {}).get('steps') or [step['name'] for step in (self.ready.get('plan') or {}).get('steps', [])]
        for name in planned:
            row = self.report['stages'].get(name)
            if not row or row.get('exit_code') != 0:
                entry = {'stage': name, 'state': state_of(row), 'error': (row or {}).get('error'),
                         'command': resume + ['--only', name], 'kind': 'baseline'}
                if not row and (self.report.get('timing') or {}).get('blocked_by'):
                    entry['blocked_by'] = self.report['timing']['blocked_by']
                rows.append(entry)
        if include_bundle and not self.report.get('bundle'):
            rows.append({'stage': FINAL, 'state': 'not run', 'command': ['python3', '-IB', 'tools/rented_run.py', 'bundle', str(self.out)]})
        if settings.get('rehearsal'):
            for row in rows:
                row['note'] = 'rehearsal: rerun at full size with a fresh run, never by resuming this directory'
        return rows

    def summarise(self, include_bundle=True):
        failures = self.correctness_failures()
        complete = not failures
        timed = [row for row in self.report['stages'].values() if row.get('kind') == 'baseline' and row.get('exit_code') is not None]
        boots = sorted({row['boot_id_sha256'] for row in timed})
        self.report.update(correctness={'complete': complete, 'failures': failures},
                           qualified=complete and not self.args.rehearsal,
                           timed_boots=boots, timed_stages_span_boots=len(boots) > 1)
        self.report.pop('unqualified', None)
        early = sorted(name for name, row in self.report['stages'].items() if row.get('kind') == 'baseline' and row.get('qualified') is False)
        if timed and not complete:
            self.report['unqualified'] = {'reason': 'timed while correctness had recorded failures (--allow-unqualified)',
                                          'failures': failures}
        elif early and not self.args.rehearsal:
            self.report['unqualified'] = {'reason': 'these timed steps ran before correctness was complete; rerun them to qualify them',
                                          'steps': early}
        self.report['owed'] = self.owed(include_bundle)

    def execute(self):
        if 'bundle' in self.report:
            self.report.setdefault('bundle_history', []).append(self.report.pop('bundle'))
        try:
            self.check_receipts()
            self.stage_inputs()
            if self.builds():
                self.correctness()
                self.verify_outcomes()
            self.baseline()
            self.summarise(include_bundle=False)
            self.report['exit_code'] = int(bool(self.report['owed']))
            self.save()
            print_owed(self.report)
            bundle(self.out, self.report)
        except KeyboardInterrupt:
            self.report.update(exit_code=130, error='interrupted')
            self.summarise()
        except Exception as error:
            self.report.update(exit_code=1, error=str(error))
            print(error, file=sys.stderr)
            self.summarise()
        finally:
            self.report['invocations'][-1]['finished'] = utc()
            self.save()
        return self.report['exit_code']


def bundle(run_dir, report=None):
    run_dir = Path(run_dir)
    report = report if report is not None else json.loads((run_dir / 'summary.json').read_text())
    report['bundle'] = {'state': 'packed', 'packed': utc(),
                        'main': f'{run_dir.name}.tar.gz', 'private': f'{run_dir.name}-private.tar.gz',
                        'note': 'the bundled summary.json was written before packing; the checksum files cover it'}
    report['owed'] = [row for row in report.get('owed', []) if row.get('stage') != FINAL]
    write_json(run_dir / 'summary.json', report)
    public, private = [], []
    for path in sorted(run_dir.rglob('*')):
        if path.is_file() and not path.is_symlink():
            relative = path.relative_to(run_dir)
            if relative.name in ('SHA256SUMS', 'SHA256SUMS.private'):
                continue
            (private if private_path(relative) else public).append(relative)
    results = {}
    for label, files, sums in (('main', public, 'SHA256SUMS'), ('private', private, 'SHA256SUMS.private')):
        lines = [f'{digest(run_dir / item)}  {item}' for item in files]
        (run_dir / sums).write_text('\n'.join(lines) + ('\n' if lines else ''))
        target = run_dir.parent / report['bundle'][label]
        pending = target.with_name(target.name + '.tmp')
        with tarfile.open(pending, 'w:gz') as archive:
            for item in [Path(sums), *files]:
                archive.add(run_dir / item, arcname=f'{run_dir.name}/{item}', recursive=False)
        if label == 'private':
            pending.chmod(0o600)
        pending.replace(target)
        verify_bundle(target, sums)
        value = digest(target)
        target.with_name(target.name + '.sha256').write_text(f'{value}  {target.name}\n')
        results[label] = {'path': str(target), 'sha256': value, 'files': len(files), 'bytes': target.stat().st_size}
    report['bundle'].update(results)
    write_json(run_dir / 'summary.json', report)
    print(f'bundle {results["main"]["path"]} sha256 {results["main"]["sha256"]}', flush=True)
    print(f'private bundle {results["private"]["path"]} sha256 {results["private"]["sha256"]}', flush=True)
    return results


def verify_bundle(path, sums_name):
    with tarfile.open(path, 'r:gz') as archive:
        members = {member.name.split('/', 1)[1]: member for member in archive.getmembers() if member.isfile()}
        listing = archive.extractfile(members[sums_name]).read().decode()
        expected = {}
        for line in listing.splitlines():
            value, _, name = line.partition('  ')
            expected[name] = value
        if set(expected) != set(members) - {sums_name}:
            raise ValueError(f'{path.name} does not hold exactly the files its checksum list names')
        for name, value in expected.items():
            if hashlib.sha256(archive.extractfile(members[name]).read()).hexdigest() != value:
                raise ValueError(f'{path.name}: {name} does not match its checksum')
    return len(expected)


def clean(run_dir):
    run_dir = Path(run_dir).resolve()
    report = json.loads((run_dir / 'summary.json').read_text())
    info = (report.get('bundle') or {}).get('private')
    if not info:
        raise ValueError('bundle the run before removing its private copies')
    target = Path(info['path'])
    if digest(target) != info['sha256']:
        raise ValueError(f'{target} does not match the recorded checksum')
    verify_bundle(target, 'SHA256SUMS.private')
    removed = []
    for path in sorted(run_dir.rglob('*'), key=lambda item: len(item.parts), reverse=True):
        relative = path.relative_to(run_dir)
        if private_path(relative) and (path.is_file() or path.is_symlink()):
            path.unlink()
            removed.append(str(relative))
    for path in sorted(run_dir.rglob('*'), key=lambda item: len(item.parts), reverse=True):
        if path.is_dir() and private_path(path.relative_to(run_dir)) and not any(path.iterdir()):
            path.rmdir()
    report['private_removed'] = {'when': utc(), 'files': len(removed)}
    write_json(run_dir / 'summary.json', report)
    print(f'removed {len(removed)} private files from {run_dir}; the private bundle {target} remains')
    return 0


def limits(lo, hi):
    def parse(text):
        number = int(text)
        if not lo <= number <= hi:
            raise argparse.ArgumentTypeError(f'expected {lo} through {hi}')
        return number
    return parse


def interrupted(signum, frame):
    raise KeyboardInterrupt


def hangup(signum, frame):
    print('terminal hangup received; the run continues', flush=True)


def names(text):
    return [item for item in text.split(',') if item]


def parser():
    result = argparse.ArgumentParser(description='Inspect preparation, run Eski qualification and the baseline on one host, '
                                                 'pack the results or remove private copies')
    result.add_argument('mode', choices=('preflight', 'run', 'bundle', 'clean', 'images'))
    result.add_argument('run_dir', nargs='?', type=lambda path: Path(path).resolve(), help='run directory for bundle and clean')
    result.add_argument('--out', type=lambda path: Path(path).resolve(), help='parent for unique run directories')
    result.add_argument('--resume', type=lambda path: Path(path).resolve(),
                        help='complete this earlier run directory: rerun only stages and steps that failed or never ran')
    result.add_argument('--revision', help='full source revision supplied by the operator')
    for name in ('server-cpus', 'client-cpus'):
        result.add_argument('--' + name, help='Linux CPU list, e.g. 2,4-5')
    for name in ('capture', 'observed', 'modern-python', 'llama-python', 'input-sums'):
        result.add_argument('--' + name, type=lambda path: Path(os.path.abspath(path)))
    result.add_argument('--expected', type=lambda path: Path(path).resolve())
    options = (('port-base', 17840, 1024, 65496), ('min-free-gib', 10, 1, 1000000),
               ('first-seed', 8, 0, (1 << 64) - 1), ('seeds', 256, 1, 1000000), ('steps', 128, 1, 4096),
               ('cycles', 64, 1, 1000), ('transactions', 100, 1, 100000))
    for name, default, lo, hi in options:
        result.add_argument('--' + name, type=limits(lo, hi), help=f'{name.replace("-", " ")} (default {default})')
    result.add_argument('--plan-profile', choices=('full', 'rehearsal'), help='baseline plan profile (default full)')
    result.add_argument('--only', type=names, help='comma-separated baseline steps or areas to run')
    result.add_argument('--skip', type=names, help='comma-separated baseline steps or areas to leave out')
    result.add_argument('--allow-unqualified', action='store_true',
                        help='run the baseline although correctness recorded failures; the summary marks the run unqualified')
    result.add_argument('--allow-noisy-host', action='store_true',
                        help='time on a host that preflight did not find quiet; the summary records it')
    result.add_argument('--rehearsal', action='store_true',
                        help='the whole sequence at toy size; the summary can never serve as a correctness receipt')
    result.add_argument('--detach', action='store_true', help='start run in its own session and return at once')
    return result, {name: default for name, default, lo, hi in options}


def complete_settings(args, defaults):
    stored = {}
    if args.resume:
        summary = args.resume / 'summary.json'
        if not summary.is_file():
            raise ValueError(f'{args.resume} holds no summary.json')
        stored = json.loads(summary.read_text()).get('settings', {})
        if args.out and args.out != args.resume.parent:
            raise ValueError('--out and --resume disagree; leave --out out when resuming')
        args.out = args.resume.parent
        if stored.get('rehearsal') and not args.rehearsal:
            args.rehearsal = True
    for key in FIELDS:
        if getattr(args, key, None) is None and stored.get(key) is not None and key != 'rehearsal':
            value = stored[key]
            if key in ('capture', 'observed', 'expected', 'modern_python', 'llama_python', 'input_sums'):
                value = Path(value)
            setattr(args, key, value)
    for name, default in defaults.items():
        key = name.replace('-', '_')
        if getattr(args, key) is None:
            setattr(args, key, default)
    if args.plan_profile is None:
        args.plan_profile = 'rehearsal' if args.rehearsal else 'full'
    if args.expected is None:
        args.expected = ROOT / 'test/search/expected.json'


def detach(argv, out):
    out.mkdir(parents=True, exist_ok=True)
    log = out / time.strftime('detached-%Y%m%d-%H%M%S.log')
    command = [sys.executable, '-IB', str(Path(__file__).resolve()), *[part for part in argv if part != '--detach']]
    with log.open('ab') as output:
        process = subprocess.Popen(command, cwd=os.getcwd(), stdin=subprocess.DEVNULL, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
    print(f'started process {process.pid}; its output goes to {log} and to rented-run.log in the run directory')
    return 0


def main():
    if sys.version_info < MINIMUM_PYTHON:
        print('tools/rented_run.py needs Python %d.%d or later; this is %s' % (*MINIMUM_PYTHON, platform.python_version()),
              file=sys.stderr)
        return 1
    command_parser, defaults = parser()
    args = command_parser.parse_args()
    try:
        if args.mode == 'images':
            print('\n'.join(dict.fromkeys(image_names()[0].values())))
            return 0
        if args.mode == 'bundle':
            if not args.run_dir:
                command_parser.error('bundle needs a run directory')
            bundle(args.run_dir)
            return 0
        if args.mode == 'clean':
            if not args.run_dir:
                command_parser.error('clean needs a run directory')
            return clean(args.run_dir)
        complete_settings(args, defaults)
    except (OSError, ValueError, tarfile.TarError) as error:
        print(error, file=sys.stderr)
        return 1
    if args.out is None or args.revision is None or args.server_cpus is None or args.client_cpus is None:
        command_parser.error('--out (or --resume), --revision, --server-cpus and --client-cpus are required')
    if not re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}', args.revision):
        command_parser.error('--revision needs a full hexadecimal source identifier')
    if args.detach:
        if args.mode != 'run':
            command_parser.error('--detach applies to run')
        return detach(sys.argv[1:], args.out)
    if args.mode == 'run':
        signal.signal(signal.SIGHUP, hangup)
        signal.signal(signal.SIGTERM, interrupted)
    try:
        ready = preflight(args)
        print(describe_estimate(ready), file=sys.stderr)
        if args.mode == 'preflight':
            print(json.dumps(ready, indent=2, sort_keys=True))
            blocked = ready['errors'] or ready['timing_refusals'] or ready['quiet_findings'] and not (args.allow_noisy_host or args.rehearsal)
            return int(bool(blocked))
        if ready['errors']:
            print(json.dumps(ready, indent=2, sort_keys=True))
            if args.resume:
                print('preflight failed; the run directory was not changed', file=sys.stderr)
            elif args.out != ROOT and ROOT not in args.out.parents:
                where = new_run_dir(args.out)
                write_json(where / 'summary.json', {'schema': SCHEMA, 'preflight': ready, 'stages': {}, 'binary_sha256': {},
                                                     'correctness': {'complete': False}, 'exit_code': 1})
                print(f'rented run output {where}', file=sys.stderr)
            return 1
        if args.resume:
            old = json.loads((args.resume / 'summary.json').read_text())
            first = old.get('first_preflight') or old.get('preflight')
            mine, theirs = identity(ready), identity(first)
            if mine != theirs:
                keys = sorted(key for key in mine if mine[key] != theirs.get(key))
                raise ValueError('this host, checkout or input differs from the run being resumed: ' + ', '.join(keys))
            return Run(args, ready, args.resume).execute()
        return Run(args, ready).execute()
    except KeyboardInterrupt:
        print('interrupted before the run started', file=sys.stderr)
        return 130
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
