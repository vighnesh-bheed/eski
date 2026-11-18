import hashlib
import json
import os
import signal
import socket
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MEMORY_LOG = 'ESKI_BENCH_MEMORY_LOG'
GUARD_DIR = 'ESKI_BENCH_GUARD'
INFO_MEMORY_FIELDS = ('used_memory', 'used_memory_rss', 'used_memory_peak', 'used_memory_dataset', 'used_memory_overhead',
                      'mem_fragmentation_ratio', 'allocator_allocated', 'allocator_resident')


class ServerError(Exception):
    pass


def encode(args):
    out = [b'*%d\r\n' % len(args)]
    for a in args:
        if not isinstance(a, bytes):
            a = str(a).encode()
        out.append(b'$%d\r\n%s\r\n' % (len(a), a))
    return b''.join(out)


class Conn:
    def __init__(self, port, timeout=120):
        self.s = socket.create_connection(('127.0.0.1', port), timeout=timeout)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = bytearray()
        self.pos = 0

    def close(self):
        self.s.close()

    def fill(self):
        chunk = self.s.recv(1 << 20)
        if not chunk:
            raise EOFError('server closed the connection')
        if self.pos > (1 << 20):
            del self.buf[:self.pos]
            self.pos = 0
        self.buf += chunk

    def line(self):
        while True:
            i = self.buf.find(b'\r\n', self.pos)
            if i >= 0:
                v = bytes(self.buf[self.pos:i])
                self.pos = i + 2
                return v
            self.fill()

    def reply(self):
        head = self.line()
        t = head[:1]
        if t in (b'+', b'_'):
            return head[1:].decode()
        if t == b':':
            return int(head[1:])
        if t == b',':
            return float(head[1:])
        if t == b'-':
            return ServerError(head[1:].decode(errors='replace'))
        if t in (b'$', b'='):
            n = int(head[1:])
            if n < 0:
                return None
            while len(self.buf) - self.pos < n + 2:
                self.fill()
            v = bytes(self.buf[self.pos:self.pos + n])
            self.pos += n + 2
            return v
        if t in (b'*', b'~', b'>'):
            n = int(head[1:])
            if n < 0:
                return None
            return [self.reply() for _ in range(n)]
        if t == b'%':
            n = int(head[1:])
            return [self.reply() for _ in range(2 * n)]
        raise ValueError(head)

    def call(self, *args):
        self.s.sendall(encode(args))
        r = self.reply()
        if isinstance(r, ServerError):
            raise r
        return r

    def pipeline(self, frames, window=2000):
        replies = []
        sent = 0
        n = len(frames)
        while len(replies) < n:
            batch = []
            while sent < n and sent - len(replies) < window:
                batch.append(frames[sent])
                sent += 1
            if batch:
                self.s.sendall(b''.join(batch))
            target = min(n, len(replies) + window // 2) if sent < n else n
            while len(replies) < target:
                replies.append(self.reply())
        return replies


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def cpu_seconds(pid):
    fields = Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK')


def rss_bytes(pid):
    for line in Path('/proc/%d/status' % pid).read_text().splitlines():
        if line.startswith('VmRSS:'):
            return int(line.split()[1]) * 1024
    return 0


def parse_info(text):
    if isinstance(text, bytes):
        text = text.decode()
    out = {}
    for line in text.splitlines():
        if ':' in line and not line.startswith('#'):
            k, v = line.split(':', 1)
            out[k] = v
    return out


def pairs(reply):
    out = {}
    for i in range(0, len(reply) - 1, 2):
        k = reply[i].decode() if isinstance(reply[i], bytes) else reply[i]
        out[k] = reply[i + 1]
    return out


def operator_rules(extra, rules):
    if '--label-levels' in extra:
        return list(rules) + ['clearance:*', 'trust:*'] if '--label-trust-levels' in extra else list(rules) + ['clearance:*']
    return list(rules)


def process_status(pid):
    values = {}
    try:
        text = Path('/proc/%d/status' % pid).read_text()
    except OSError:
        return values
    for line in text.splitlines():
        name, _, rest = line.partition(':')
        if name in ('VmRSS', 'VmHWM', 'VmPeak', 'VmSize') and rest.split():
            values[name] = int(rest.split()[0]) * 1024
    return values


def start_ticks(pid):
    try:
        return int(Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()[19])
    except (OSError, IndexError, ValueError):
        return None


def info_memory(port, timeout=5):
    try:
        conn = Conn(port, timeout=timeout)
        try:
            fields = parse_info(conn.call('INFO', 'memory'))
        finally:
            conn.close()
    except (OSError, EOFError, ServerError, ValueError) as error:
        return {'error': str(error)[:200]}
    return {name: fields[name].strip() for name in INFO_MEMORY_FIELDS if name in fields}


def append_record(variable, record):
    path = os.environ.get(variable)
    if not path:
        return
    with open(path, 'a') as handle:
        handle.write(json.dumps(record, sort_keys=True) + '\n')


def record_memory(kind, port, pid=None, extra=None):
    record = dict(kind=kind, port=port, pid=pid, at=time.time(), info=info_memory(port))
    if pid:
        status = process_status(pid)
        record.update(rss_bytes=status.get('VmRSS'), peak_rss_bytes=status.get('VmHWM'))
    record.update(extra or {})
    append_record(MEMORY_LOG, record)
    return record


def guard_path(kind, name):
    folder = os.environ.get(GUARD_DIR)
    return Path(folder) / ('%s-%s' % (kind, name)) if folder else None


def guard_add(kind, name, value):
    path = guard_path(kind, name)
    if path is not None:
        pending = path.with_name('.' + path.name)
        pending.write_text(value)
        pending.replace(path)


def guard_remove(kind, name):
    path = guard_path(kind, name)
    if path is not None:
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def port_free(port):
    with socket.socket() as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(('127.0.0.1', port))
        except OSError:
            return False
    return True


class Server:
    def __init__(self, binary, port, workdir, args=(), cpus=None, env=None):
        self.binary = str(Path(binary).resolve())
        self.port = port
        self.dir = Path(workdir)
        self.dir.mkdir(parents=True, exist_ok=True)
        if not port_free(port):
            raise SystemExit('port %d is in use' % port)
        argv = [self.binary, '--bind', '127.0.0.1', '--port', str(port), '--dir', str(self.dir), '--save', '', '--appendonly', 'no',
                '--memcached-port', '0'] + [str(a) for a in args]
        if cpus:
            argv = ['taskset', '-c', str(cpus)] + argv
        self.log_path = self.dir / 'server.log'
        self.log = open(self.log_path, 'ab')
        self.proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=self.log, stderr=subprocess.STDOUT, env=env,
                                     start_new_session=True)
        self.pid = self.proc.pid
        guard_add('server', str(self.pid), '%d %s\n' % (self.pid, start_ticks(self.pid)))
        (self.dir / 'server.pid').write_text('%d\n' % self.pid)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                guard_remove('server', str(self.pid))
                raise SystemExit('server exited at startup: ' + self.log_path.read_text(errors='replace')[-2000:])
            try:
                c = Conn(port, timeout=5)
                c.call('PING')
                c.close()
                return
            except (OSError, EOFError, ServerError):
                time.sleep(0.05)
        self.stop()
        raise SystemExit('server did not answer on port %d' % port)

    def conn(self, timeout=120):
        return Conn(self.port, timeout)

    def fatal_lines(self):
        text = self.log_path.read_text(errors='replace')
        return [line for line in text.splitlines() if 'fatal' in line.lower() or 'panic' in line.lower() or 'AddressSanitizer' in line]

    def stop(self):
        if self.proc.poll() is None:
            if os.environ.get(MEMORY_LOG):
                record_memory('eski', self.port, self.pid, dict(binary=self.binary, directory=str(self.dir)))
            try:
                os.kill(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.kill(self.pid, signal.SIGKILL)
                self.proc.wait(timeout=10)
        self.log.close()
        guard_remove('server', str(self.pid))
        try:
            (self.dir / 'server.pid').unlink()
        except FileNotFoundError:
            pass
        return self.proc.returncode


def cgroup_memory(pid):
    try:
        line = next(row for row in Path('/proc/%d/cgroup' % pid).read_text().splitlines() if row.startswith('0::'))
    except (OSError, StopIteration):
        return {}
    base = Path('/sys/fs/cgroup') / line[3:].lstrip('/')
    values = {}
    for name in ('memory.current', 'memory.peak', 'memory.max'):
        try:
            text = (base / name).read_text().strip()
        except OSError:
            continue
        values[name] = int(text) if text.isdigit() else text
    return values


def docker(*args, timeout=60):
    return subprocess.run(['docker', *map(str, args)], capture_output=True, text=True, timeout=timeout)


class Container:
    def __init__(self, name, image, argv, port, workdir, cpus=None, memory=None, volumes=(), user=None, tmpfs=None):
        self.name, self.image, self.port = name, image, port
        self.dir = Path(workdir)
        self.dir.mkdir(parents=True, exist_ok=True)
        if not port_free(port):
            raise SystemExit('port %d is in use' % port)
        command = ['run', '--pull=never', '-d', '--name', name, '--network', 'host']
        if cpus:
            command += ['--cpuset-cpus', str(cpus)]
        if memory:
            command += ['--memory', memory, '--memory-swap', memory]
        for volume in volumes:
            command += ['-v', volume]
        if user:
            command += ['--user', user]
        if tmpfs:
            command += ['--tmpfs', tmpfs]
        command += [image] + [str(a) for a in argv]
        guard_add('container', name, name + '\n')
        (self.dir / 'container.json').write_text(json.dumps(dict(name=name, image=image, argv=command), indent=1) + '\n')
        done = docker(*command)
        if done.returncode:
            self.remove()
            raise SystemExit('container %s did not start: %s' % (name, done.stderr.strip()[-500:]))
        state = docker('inspect', '--format', '{{.State.Pid}}', name)
        self.pid = int(state.stdout.strip() or 0) if state.returncode == 0 else 0
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            running = docker('inspect', '--format', '{{.State.Running}}', name)
            if running.stdout.strip() != 'true':
                self.save_log()
                self.remove()
                raise SystemExit('container %s exited at startup: %s' % (name, (self.dir / 'server.log').read_text(errors='replace')[-1500:]))
            try:
                c = Conn(port, timeout=5)
                reply = c.call('PING')
                c.close()
                if reply == 'PONG':
                    return
            except (OSError, EOFError, ServerError):
                pass
            time.sleep(0.1)
        self.stop()
        raise SystemExit('container %s did not answer on port %d' % (name, port))

    def conn(self, timeout=120):
        return Conn(self.port, timeout)

    def memory(self):
        return dict(cgroup=cgroup_memory(self.pid) if self.pid else {}, **process_status(self.pid)) if self.pid else {}

    def save_log(self):
        done = docker('logs', self.name, timeout=60)
        (self.dir / 'server.log').write_text(done.stdout + done.stderr)

    def remove(self):
        for _ in range(3):
            done = docker('rm', '-f', self.name, timeout=120)
            gone = docker('container', 'inspect', self.name)
            if gone.returncode:
                guard_remove('container', self.name)
                return True
        return done.returncode == 0

    def stop(self):
        if self.pid and os.environ.get(MEMORY_LOG):
            record_memory('container', self.port, self.pid, dict(name=self.name, image=self.image, cgroup=cgroup_memory(self.pid)))
        try:
            self.save_log()
        except (OSError, subprocess.SubprocessError):
            pass
        if not self.remove():
            raise RuntimeError('container %s could not be removed' % self.name)
