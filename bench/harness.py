import hashlib
import os
import signal
import socket
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


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
        (self.dir / 'server.pid').write_text('%d\n' % self.pid)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
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
        try:
            (self.dir / 'server.pid').unlink()
        except FileNotFoundError:
            pass
        return self.proc.returncode
