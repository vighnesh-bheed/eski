import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(command, output, name, timeout=120, env=None):
    cpu = str(min(os.sched_getaffinity(0)))
    command = ['nice', '-n', '10', 'taskset', '-c', cpu] + list(map(str, command))
    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    (output / (name + '.log')).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise AssertionError(name + ' failed: ' + (result.stdout + result.stderr)[-6000:])
    return {'command': command, 'returncode': result.returncode,
            'log_sha256': digest(output / (name + '.log')),
            'stdout': result.stdout, 'stderr': result.stderr}


def build_probe(output):
    overlay = output / 'overlay'
    if overlay.exists():
        shutil.rmtree(overlay)
    shutil.copytree(ROOT / 'src', overlay / 'src')
    removed = []
    for path in [overlay / 'src/main.odin', *sorted((overlay / 'src').glob('*_test.odin'))]:
        removed.append(str(path.relative_to(overlay)))
        path.unlink()
    shutil.copyfile(PACKAGE / 'bridge.odin', overlay / 'src/lifecycle_bridge.odin')
    additions = {'src/lazyfree.odin': PACKAGE / 'lazy_adapter.odin.inc',
                 'src/aof.odin': PACKAGE / 'bio_adapter.odin.inc'}
    for name, adapter in additions.items():
        original = (ROOT / name).read_bytes()
        (overlay / name).write_bytes(original + adapter.read_bytes())
    copied = {}
    for path in sorted((overlay / 'src').rglob('*')):
        if not path.is_file():
            continue
        name = str(path.relative_to(overlay))
        expected = ((PACKAGE / 'bridge.odin').read_bytes() if name == 'src/lifecycle_bridge.odin'
                    else (ROOT / name).read_bytes() + (additions[name].read_bytes() if name in additions else b''))
        if path.read_bytes() != expected:
            raise AssertionError('overlay differs from exact declared transformation: ' + name)
        copied[name] = digest(path)
    (overlay / '.build').symlink_to(ROOT / '.build', target_is_directory=True)
    inputs = ['.build/diagnostics/release/libeski-diagnostics.a', '.build/diagnostics/libunwind.so',
              '.build/lua/release/libeslua-runtime.a']
    native_hashes = {name: digest(ROOT / name) for name in inputs}
    compiler = shutil.which('odin')
    if not compiler:
        raise AssertionError('repository Odin toolchain is required')
    lock = ROOT / '.build/proofs/compiler.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    with lock.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        evidence = run([compiler, 'build', overlay / 'src', '-out:' + str(output / 'lifecycle_probe'),
                        '-thread-count:2', '-vet', '-strict-style'], output, 'odin-build')
        shim = output / 'record-operations.so'
        clang = shutil.which('clang')
        if not clang:
            raise AssertionError('clang required for owned syslog recording shim')
        shim_build = run([clang, '-shared', '-fPIC', '-O1', '-pthread',
                          ROOT / 'test/compatibility/runtime_operations_shim.c', '-o', shim],
                         output, 'shim-build')
    if any(digest(ROOT / name) != sha for name, sha in native_hashes.items()):
        raise AssertionError('native build inputs changed')
    return {'original_source_preserved': True, 'removed': removed,
            'appended_adapters': {name: digest(path) for name, path in additions.items()},
            'overlay_sha256': copied, 'native_inputs_sha256': native_hashes,
            'build': evidence, 'shim_build': shim_build, 'probe_sha256': digest(output / 'lifecycle_probe'),
            'shim_sha256': digest(shim),
            'tools': {'odin': {'path': str(Path(compiler).resolve()), 'sha256': digest(Path(compiler).resolve()),
                               'version': subprocess.check_output([compiler, 'version'], text=True).strip()},
                      'clang': {'path': str(Path(clang).resolve()), 'sha256': digest(Path(clang).resolve()),
                                'version': subprocess.check_output([clang, '--version'], text=True).splitlines()[0]}}}


def probe_check(output):
    record = output / 'probe-syslog.txt'
    record.unlink(missing_ok=True)
    env = dict(os.environ, LD_PRELOAD=str(output / 'record-operations.so'), ESKI_TEST_SYSLOG_RECORD=str(record))
    result = run([output / 'lifecycle_probe'], output, 'actual-probe', timeout=30, env=env)
    required = ['POOL|parked_callbacks_alive|joined_before_free|resume_hooks|accepted_completed',
                'FORK|libc_atfork|four_exact_masks|child_tid_and_state_reset|parent_state_retained',
                'SHUTDOWN|queued_zero_active_one|blocked_until_release|logger_after_callback', 'LIFECYCLE|PASS']
    if not all(line in result['stdout'].splitlines() for line in required):
        raise AssertionError('actual lifecycle probe did not complete all cases')
    text = record.read_text()
    if text.count('CLOSE\n') != 1 or not text.rstrip().endswith('CLOSE'):
        raise AssertionError('logger closed incorrectly during active callback probe')
    if text.index('lifecycle-active-callback') >= text.index('CLOSE\n'):
        raise AssertionError('active callback outlived logger')
    return {'success': True, 'cases': required[:-1], 'run': result,
            'syslog_sha256': digest(record), 'queued_zero_active_one_observed': True}


def encode(parts):
    parts = [str(part).encode() if not isinstance(part, bytes) else part for part in parts]
    return b'*' + str(len(parts)).encode() + b'\r\n' + b''.join(
        b'$' + str(len(part)).encode() + b'\r\n' + part + b'\r\n' for part in parts)


class Client:
    def __init__(self, port):
        self.socket = socket.create_connection(('127.0.0.1', port), timeout=3)
        self.file = self.socket.makefile('rb')

    def close(self):
        self.file.close()
        self.socket.close()

    def read(self):
        line = self.file.readline()
        if not line:
            raise EOFError('owned server closed RESP connection')
        tag, content = line[:1], line[1:-2]
        if tag == b'+':
            return content.decode()
        if tag == b'-':
            raise ServerError(content.decode())
        if tag == b':':
            return int(content)
        if tag == b'$':
            length = int(content)
            if length < 0:
                return None
            payload = self.file.read(length + 2)
            if len(payload) != length + 2 or not payload.endswith(b'\r\n'):
                raise AssertionError('short RESP bulk')
            return payload[:-2]
        if tag == b'*':
            return [self.read() for _ in range(int(content))]
        raise AssertionError('invalid RESP reply')

    def call(self, *parts):
        self.socket.sendall(encode(parts))
        return self.read()

    def pipeline(self, commands):
        self.socket.sendall(b''.join(encode(command) for command in commands))
        return [self.read() for _ in commands]


def wait_until(function, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = function()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError('bounded owned-process wait expired')


class ServerError(AssertionError):
    pass


class Node:
    def __init__(self, binary, directory, shim=None):
        self.binary, self.directory, self.shim = binary, directory, shim
        self.process = None
        self.clients = []

    def start(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            self.port = reservation.getsockname()[1]
        self.log = (self.directory / 'server.log').open('wb')
        env = dict(os.environ)
        env['TSAN_OPTIONS'] = 'halt_on_error=1:exitcode=66'
        arguments = ['--bind', '127.0.0.1', '--port', str(self.port), '--save', '',
                     '--dir', str(self.directory), '--dbfilename', 'dump.rdb',
                     '--keyspace-threads', '2', '--compute-threads', '2', '--enable-debug-command', 'yes',
                     '--rdb-key-save-delay', '2000']
        if self.shim:
            env.update(LD_PRELOAD=str(self.shim), ESKI_TEST_SYSLOG_RECORD=str(self.directory / 'syslog.txt'))
            arguments += ['--syslog-enabled', 'yes', '--syslog-ident', 'eski-lifecycle-owned-node',
                          '--bio-cpulist', 'bad']
        self.process = subprocess.Popen(['nice', '-n', '10', 'taskset', '-c', str(min(os.sched_getaffinity(0))),
                                         str(self.binary), *arguments], cwd=self.directory, env=env,
                                        stdin=subprocess.DEVNULL, stdout=self.log, stderr=subprocess.STDOUT)

        def ready():
            if self.process.poll() is not None:
                raise AssertionError('owned server exited during readiness')
            try:
                client = Client(self.port)
            except OSError:
                return False
            try:
                try:
                    reply = client.call('PING')
                except ServerError as error:
                    if str(error).startswith('LOADING '):
                        return False
                    raise
                if reply != 'PONG':
                    raise AssertionError('unexpected readiness reply')
            finally:
                client.close()
            return True

        wait_until(ready)
        return self

    def client(self):
        client = Client(self.port)
        self.clients.append(client)
        return client

    def close(self):
        for client in self.clients:
            client.close()
        self.clients = []
        if self.process is not None and self.process.poll() is None:
            try:
                client = Client(self.port)
                try:
                    client.call('SHUTDOWN', 'NOSAVE')
                except EOFError:
                    pass
                finally:
                    client.close()
                self.process.wait(timeout=5)
            except BaseException:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=3)
        if hasattr(self, 'log'):
            self.log.close()


def info(client, section):
    return dict(line.split(':', 1) for line in client.call('INFO', section).decode().splitlines()
                if line and not line.startswith('#') and ':' in line)


def server_checks(binary, output, label):
    directory = output / label
    if directory.exists():
        shutil.rmtree(directory)
    node = Node(binary, directory)
    facts = {}
    try:
        node.start()
        client = node.client()
        commands = [('SET', 'snapshot:' + str(i), 'accepted:' + str(i)) for i in range(8)]
        replies = client.pipeline(commands + [('BGSAVE',)])
        if replies[:8] != ['OK'] * 8 or not str(replies[-1]).startswith('Background saving started'):
            raise AssertionError('worker mutation/BGSAVE pipeline failed')
        if client.call('SET', 'parent-after-fork', 'retained') != 'OK':
            raise AssertionError('parent failed to resume keyspace workers')
        wait_until(lambda: info(client, 'persistence').get('rdb_bgsave_in_progress') == '0')
        state = info(client, 'persistence')
        if state.get('rdb_last_bgsave_status') != 'ok':
            raise AssertionError('background persistence failed')
        if client.call('GET', 'parent-after-fork') != b'retained':
            raise AssertionError('parent mutation lost after fork')
        full = info(client, 'all')
        submitted = full.get('keyspace_jobs_submitted')
        if submitted is None or int(submitted) < 9:
            raise AssertionError('target fixture did not use actual keyspace workers')
        facts['keyspace_jobs_submitted'] = int(submitted)
        facts['rdb_sha256'] = digest(directory / 'dump.rdb')
        facts['parent_resumed'] = True
    finally:
        node.close()
    if node.process.returncode != 0:
        raise AssertionError('first owned persistence node failed to exit')
    (directory / 'server.log').rename(directory / 'snapshot-server.log')
    second = Node(binary, directory)
    try:
        second.start()
        client = second.client()
        for i in range(8):
            if client.call('GET', 'snapshot:' + str(i)) != ('accepted:' + str(i)).encode():
                raise AssertionError('fork snapshot omitted accepted mutation')
        if client.call('GET', 'parent-after-fork') is not None:
            raise AssertionError('fork snapshot included later parent write')
        facts['snapshot_reloaded'] = True
    finally:
        second.close()
    if second.process.returncode != 0:
        raise AssertionError('owned reload node failed to exit')
    shutdown_directory = output / (label + '-shutdown')
    if shutdown_directory.exists():
        shutil.rmtree(shutdown_directory)
    shutdown = Node(binary, shutdown_directory, output / 'record-operations.so')
    try:
        shutdown.start()
        client = shutdown.client()
        if client.call('SADD', 'shutdown-owned', *range(2048)) != 2048:
            raise AssertionError('shutdown fixture allocation failed')
        client.socket.sendall(encode(('UNLINK', 'shutdown-owned')) + encode(('SHUTDOWN', 'NOSAVE')))
        response = bytearray()
        while True:
            chunk = client.socket.recv(16)
            if not chunk:
                break
            response.extend(chunk)
            if len(response) > 4:
                raise AssertionError('unexpected shutdown pipeline response')
        if bytes(response) not in (b'', b':1\r\n'):
            raise AssertionError('partial/wrong shutdown prefix reply')
        if shutdown.process.wait(timeout=10) != 0:
            raise AssertionError('owned shutdown node exit failed')
        text = (shutdown.directory / 'syslog.txt').read_text()
        if text.count('CLOSE\n') != 1 or not text.rstrip().endswith('CLOSE'):
            raise AssertionError('background logging outlived teardown')
        warning = 'Ignoring invalid bio-cpulist CPU list'
        if warning not in text or text.index(warning) >= text.index('CLOSE\n'):
            raise AssertionError('real background warning was not ordered before logger close')
        facts['shutdown_worker_warning_before_only_close'] = True
        facts['shutdown_syslog_sha256'] = digest(shutdown.directory / 'syslog.txt')
    finally:
        shutdown.close()
    logs = [directory / 'snapshot-server.log', directory / 'server.log', shutdown.directory / 'server.log']
    for log in logs:
        text = log.read_text(errors='replace')
        if 'WARNING: ThreadSanitizer' in text or 'ThreadSanitizer: data race' in text:
            raise AssertionError('new actual TSAN report: ' + str(log))
    return {'success': True, 'executable_sha256': digest(binary), 'cases': facts,
            'logs_sha256': {str(path.relative_to(output)): digest(path) for path in logs},
            'owned_nodes': 3, 'all_exit_zero': True, 'sanitizer_suppressions': False,
            'tsan_runtime_options': 'halt_on_error=1:exitcode=66'}


def actual_checks(output, server, tsan_server=None):
    lock = ROOT / '.build/verification/check.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    with lock.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        build = build_probe(output)
        probe = probe_check(output)
        release = server_checks(server, output, 'server')
        tsan = server_checks(tsan_server, output, 'tsan-server') if tsan_server else None
    return {'build': build, 'probe': probe, 'release': release, 'tsan': tsan,
            'source_happens_before': ['lazyfree callback and all side effects precede lazy_jobs Release decrement; shutdown Acquire zero precedes logger flag/ident teardown',
                                      'BIO side effects precede all-kind jobs_pending Release decrement; shutdown/fork Acquire zero precedes teardown/snapshot',
                                      'pool callbacks return before thread.join returns; keyspace fence publishes accepted effects before stop/join/fork'],
            'limits': ['The forced queued=0 active=1 callback is a source-level controlled schedule, not an OS scheduler exhaustiveness claim.',
                       'The optional TSAN server runs target fixtures without suppressions; instrumentation controls belong to the aggregate race-check gate.',
                       'OS fork failure is modeled; real fork failure and OOM are not injected.']}
