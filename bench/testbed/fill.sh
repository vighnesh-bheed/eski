#!/usr/bin/env bash
set -euo pipefail
TESTBED_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WORKSPACE="$(dirname "$(dirname "$TESTBED_DIR")")"
ROOT="$(dirname "$WORKSPACE")"
if [ "$(basename "$WORKSPACE")" != workspace ] || [ ! -f "$WORKSPACE/profile.json" ] || [ ! -f "$ROOT/design.json" ]; then
  printf 'fill.sh: error: run the copy installed by bench/testbed/install.py, at <root>/fill.sh on the test machine\n' >&2
  exit 2
fi
exec python3 -B -I - "$ROOT" "$@" <<'PY'
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import tarfile
import tempfile
import time

root = Path(sys.argv[1]).resolve()
workspace = root / 'workspace'
parser = argparse.ArgumentParser(prog='fill.sh', description='Fill every engine of the design with ten million keys and record bytes per key; never runs while the exam controller is active.')
parser.add_argument('--targets', help='comma separated subset of the design engines')
args = parser.parse_args(sys.argv[2:])


def load(path):
    return json.loads(Path(path).read_text())


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def atomic(path, value):
    path = Path(path)
    temporary = path.with_name('.' + path.name + '.part')
    temporary.write_text(json.dumps(value, indent=1, sort_keys=True, allow_nan=False) + '\n')
    os.replace(temporary, path)


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def package_celsius(chip, label):
    for path in sorted(Path('/sys/class/hwmon').glob('hwmon*/temp*_input')):
        if read(path.parent / 'name') == chip and read(path.with_name(path.name.replace('_input', '_label'))) == label:
            value = read(path)
            return int(value) / 1000 if value and value.lstrip('-').isdigit() else None
    return None


def fail(message):
    print('fill.sh: error: ' + message, file=sys.stderr)
    sys.exit(2)


design = load(root / 'design.json')
fill = design['fill']
if fill.get('keys') != 10000000 or fill.get('data_size') != 64 or fill.get('scenario') != 'fill10m':
    fail('bench/run.sh measures the fill10m scenario of 10,000,000 keys of 64 B; the design asks for something else')
profile = load(workspace / 'profile.json')
experiment = load(workspace / 'plans' / 'benchmark' / 'experiment.json')
engines = {engine['target']: engine for engine in load(root / 'engines.json')['engines']}
targets = [engine['target'] for engine in design['engines']]
if args.targets:
    wanted = args.targets.split(',')
    if not set(wanted) <= set(targets):
        fail('unknown target in --targets; the design has ' + ', '.join(targets))
    targets = [target for target in targets if target in wanted]

status = subprocess.run([str(root / 'exam.sh'), 'status', '--json'], capture_output=True, text=True)
if status.returncode:
    fail('cannot read the exam status: ' + status.stderr.strip())
current = json.loads(status.stdout)
if current['status'] in ('STARTING', 'RUNNING') or current['tmux_running'] or current['controller_alive']:
    fail('the exam controller is active (%s); the fill waits until it stops' % current['status'])
lock_path = Path(tempfile.gettempdir()) / ('eski-exam-%d.lock' % os.getuid())
lock = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC, 0o600)
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    fail('another exam or fill holds ' + str(lock_path))

stamp = time.strftime('%Y%m%d-%H%M%S')
output = root / 'fill' / stamp
output.mkdir(parents=True)
environment = os.environ.copy()
for name in list(environment):
    if name.startswith('BENCH_') or name == 'ESKI_BIN':
        del environment[name]
environment['PATH'] = str((workspace / profile['tool_bin']).resolve()) + os.pathsep + environment.get('PATH', '')
environment['PYTHONDONTWRITEBYTECODE'] = '1'
images = profile['images']
environment.update(BENCH_REDIS_IMAGE=images['cli'], BENCH_MEMTIER_IMAGE=images['memtier'], BENCH_SERVER_CPUS=experiment['server_cpus'],
                   BENCH_CLIENT_CPUS=experiment['client_cpus'], BENCH_DRAGONFLY_THREADS=str(profile['dragonfly_threads']),
                   BENCH_SERVER_MEMORY=experiment['server_memory'], BENCH_CLIENT_MEMORY=experiment['client_memory'],
                   BENCH_SERVER_MAXMEMORY=str(experiment['maxmemory']))
for role, name in (('valkey', 'BENCH_VALKEY_IMAGE'), ('dragonfly', 'BENCH_DRAGONFLY_IMAGE'), ('eski-docker', 'BENCH_ESKI_IMAGE')):
    if role in images:
        environment[name] = images[role]
chip, label = experiment['sensor_chip'], experiment['sensor_label']
results = []
last_end = None
started_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
for target in targets:
    directory = output / target
    directory.mkdir()
    deadline = time.monotonic() + fill['max_wait_seconds']
    while True:
        celsius = package_celsius(chip, label)
        rested = last_end is None or time.monotonic() - last_end >= fill['rest_seconds']
        if celsius is not None and celsius <= fill['cool_temp_c'] and rested:
            gate = 'met'
            break
        if time.monotonic() >= deadline:
            gate = 'not met within %d s (package %s C)' % (fill['max_wait_seconds'], celsius)
            break
        time.sleep(2)
    entry = dict(target=target, label=engines.get(target, {}).get('label', target), image_id=images.get(target), gate=gate,
                 package_c_before=package_celsius(chip, label), started_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
    if gate != 'met':
        entry.update(status='skipped', error='cooling gate ' + gate)
        results.append(entry)
        print('[%s] skipped: %s' % (target, entry['error']), flush=True)
        continue
    run_env = dict(environment, BENCH_OUTPUT_DIR=str(directory / 'run'), BENCH_RUN_ID='fill-%s-%s' % (stamp, target),
                   BENCH_OWNER_EVENTS=str(directory / 'owners.jsonl'), BENCH_SPEC_CACHE=str(directory / 'probe-cache'))
    print('[%s] filling %d keys' % (target, fill['keys']), flush=True)
    with (directory / 'harness.log').open('wb') as log:
        code = subprocess.run(['bash', str(workspace / 'bench' / 'run.sh'), '--targets', target, '--scenarios', 'fill10m'],
                              cwd=workspace, env=run_env, stdout=log, stderr=subprocess.STDOUT).returncode
    last_end = time.monotonic()
    entry.update(returncode=code, finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), package_c_after=package_celsius(chip, label))
    records = []
    if (directory / 'run' / 'records.jsonl').exists():
        records = [json.loads(line) for line in (directory / 'run' / 'records.jsonl').read_text().splitlines() if line.strip()]
    record = next((item for item in records if item.get('scenario') == 'fill10m'), {})
    peaks = []
    if (directory / 'owners.jsonl').exists():
        for line in (directory / 'owners.jsonl').read_text().splitlines():
            try:
                owner = json.loads(line)
            except ValueError:
                continue
            value = (owner.get('cgroup') or {}).get('memory.peak')
            if owner.get('event') == 'before-stop' and owner.get('role') == 'server' and str(owner.get('artifact_dir') or '').endswith('/run/' + target) and isinstance(value, (int, float)):
                peaks.append(value)
    for field in ('keys_requested', 'dbsize', 'used_memory', 'used_memory_rss', 'bytes_per_key_rss', 'bytes_per_key_used', 'ops_per_sec', 'p50_ms', 'p99_ms', 'p999_ms', 'max_ms', 'error'):
        entry[field] = record.get(field)
    entry['cgroup_peak_bytes'] = max(peaks) if peaks else None
    entry['bytes_per_key_cgroup_peak'] = entry['cgroup_peak_bytes'] / entry['dbsize'] if entry['cgroup_peak_bytes'] and entry['dbsize'] else None
    summary = directory / 'run' / 'summary.json'
    version = ((load(summary).get('meta') or {}).get('targets') or {}).get(target, {}).get('version') if summary.exists() else None
    entry['version'] = version
    valid = code == 0 and not record.get('error') and isinstance(record.get('dbsize'), int) and record['dbsize'] >= fill['keys'] and entry['bytes_per_key_rss'] is not None
    entry['status'] = 'valid' if valid else 'failed'
    if not valid and not entry.get('error'):
        entry['error'] = 'harness exit %d, %s keys' % (code, record.get('dbsize'))
    results.append(entry)
    print('[%s] %s: %s B/key resident, %s keys, %s ops/s, worst request %s ms' % (target, entry['status'], entry['bytes_per_key_rss'], entry['dbsize'], entry['ops_per_sec'], entry['max_ms']), flush=True)
processors = [line.split(':', 1)[1].strip() for line in (read('/proc/cpuinfo') or '').splitlines() if line.startswith('model name')]
fill_result = dict(schema='eski-testbed-fill-v1', root=root.name, stamp=stamp, design=fill, engines=results,
                   machine=dict(hostname=socket.gethostname(), kernel=platform.release(), cpu_model=processors[0] if processors else None),
                   resources={name: experiment[name] for name in ('server_cpus', 'client_cpus', 'server_memory', 'client_memory', 'maxmemory')},
                   dragonfly_threads=profile['dragonfly_threads'], started_at=started_at, finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
atomic(output / 'fill.json', fill_result)
files = sorted(path for path in output.rglob('*') if path.is_file() and not path.is_symlink())
inventory = {str(path.relative_to(root)): dict(sha256=sha(path), bytes=path.stat().st_size) for path in files}
atomic(output / 'inventory.json', inventory)
exports = root / 'exports'
exports.mkdir(exist_ok=True)
archive = exports / ('fill-%s.tar.gz' % stamp)
with tarfile.open(archive, 'w:gz') as handle:
    for path in files + [output / 'inventory.json']:
        handle.add(path, arcname=str(path.relative_to(root)), recursive=False)
receipt = dict(schema='eski-exam-export-v1', kind='fill', archive=archive.name, sha256=sha(archive), bytes=archive.stat().st_size, files=len(inventory),
               inventory=str((output / 'inventory.json').relative_to(root)), root=root.name, created_at=time.time())
atomic(exports / 'fill-receipt.json', receipt)
print(json.dumps(receipt, sort_keys=True))
sys.exit(0 if all(entry['status'] == 'valid' for entry in results) else 1)
PY
