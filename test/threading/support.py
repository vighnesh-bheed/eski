import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
FIELDS = ('compute_threads_configured', 'compute_threads_active', 'compute_jobs_pending',
          'compute_memory_reserved', 'compute_jobs_submitted', 'compute_jobs_completed',
          'compute_jobs_cancelled', 'compute_sync_fallbacks', 'compute_worker_nanoseconds')


WORKER_LONE = frozenset(name.encode() for name in (
    'GET', 'SET', 'GETEX', 'GETDEL', 'GETSET', 'SETNX', 'SETEX', 'PSETEX', 'APPEND', 'STRLEN', 'GETRANGE', 'SUBSTR',
    'SETRANGE', 'INCR', 'DECR', 'INCRBY', 'DECRBY', 'INCRBYFLOAT', 'MGET', 'MSET', 'MSETNX', 'DEL', 'EXISTS',
    'TOUCH', 'TYPE', 'TTL', 'PTTL', 'EXPIRETIME', 'PEXPIRETIME', 'EXPIRE', 'PEXPIRE', 'EXPIREAT', 'PEXPIREAT',
    'PERSIST', 'HSET', 'HMSET', 'HSETNX', 'HGET', 'HMGET', 'HEXISTS', 'HSTRLEN', 'HDEL', 'HLEN', 'HINCRBY',
    'HINCRBYFLOAT', 'HEXPIRE', 'HPEXPIRE', 'HEXPIREAT', 'HPEXPIREAT', 'HTTL', 'HPTTL', 'HEXPIRETIME',
    'HPEXPIRETIME', 'HPERSIST'))


class ServerError(Exception):
    pass


class Push(list):
    pass


def encode(arguments):
    values = [value if isinstance(value, bytes) else str(value).encode() for value in arguments]
    return b'*%d\r\n' % len(values) + b''.join(b'$%d\r\n' % len(value) + value + b'\r\n' for value in values)


class Client:
    queue_ping = False
    in_multi = False

    def __init__(self, port, timeout=15, queue_ping=False):
        self.socket = socket.create_connection(('127.0.0.1', port), timeout=timeout)
        self.buffer = bytearray()
        self.pushes = []
        self.queue_ping = queue_ping
        self.in_multi = False

    def close(self):
        self.socket.close()

    def take(self, length):
        while len(self.buffer) < length:
            chunk = self.socket.recv(max(4096, min(length-len(self.buffer), 1 << 20)))
            if not chunk:
                raise EOFError('server closed the connection')
            self.buffer.extend(chunk)
        result = bytes(self.buffer[:length])
        del self.buffer[:length]
        return result

    def line(self):
        while True:
            at = self.buffer.find(b'\r\n')
            if at >= 0:
                return self.take(at+2)[:-2]
            if len(self.buffer) > 1 << 20:
                raise ValueError('RESP line exceeds the harness limit')
            chunk = self.socket.recv(4096)
            if not chunk:
                raise EOFError('server closed an incomplete RESP frame')
            self.buffer.extend(chunk)

    def read(self):
        prefix = self.take(1)
        if prefix == b'+':
            return self.line().decode()
        if prefix == b'-':
            return ServerError(self.line().decode(errors='replace'))
        if prefix == b':':
            return int(self.line())
        if prefix == b'_':
            if self.line():
                raise ValueError('invalid RESP null')
            return None
        if prefix == b'#':
            value = self.line()
            if value not in (b't', b'f'):
                raise ValueError('invalid RESP boolean')
            return value == b't'
        if prefix == b',':
            return float(self.line())
        if prefix in (b'$', b'=', b'*', b'~', b'>', b'%'):
            length = int(self.line())
            if length == -1:
                return None
            if length < 0 or length > (1 << 28 if prefix in (b'$', b'=') else 1000000):
                raise ValueError('invalid RESP length')
            if prefix in (b'$', b'='):
                value = self.take(length+2)
                if value[-2:] != b'\r\n':
                    raise ValueError('invalid RESP bulk terminator')
                return value[4:-2] if prefix == b'=' else value[:-2]
            if prefix == b'%':
                return {self.read(): self.read() for _ in range(length)}
            values = [self.read() for _ in range(length)]
            return Push(values) if prefix == b'>' else values
        raise ValueError('unexpected RESP prefix %r' % prefix)

    def reply(self):
        while True:
            value = self.read()
            if isinstance(value, Push):
                self.pushes.append(value)
            else:
                return value

    def send(self, *arguments):
        self.socket.sendall(encode(arguments))

    def send_many(self, commands):
        self.socket.sendall(b''.join(encode(command) for command in commands))

    def call(self, *arguments):
        name = (arguments[0] if isinstance(arguments[0], bytes) else str(arguments[0]).encode()).upper()
        if self.queue_ping and not self.in_multi and name in WORKER_LONE:
            return self.call_before_ping(*arguments)
        self.send(*arguments)
        value = self.reply()
        if name == b'MULTI' and value == 'OK':
            self.in_multi = True
        elif name in (b'EXEC', b'DISCARD', b'RESET'):
            self.in_multi = False
        if isinstance(value, ServerError):
            raise value
        return value

    def pipeline(self, commands):
        self.send_many(commands)
        return [self.reply() for _ in commands]

    def call_before_ping(self, *arguments):
        value, pong = self.pipeline([arguments, ('PING',)])
        if isinstance(value, ServerError):
            raise value
        if pong not in ('PONG', [b'pong', b'']):
            raise AssertionError('PING queued behind %r answered %r' % (arguments[:1], pong))
        return value

    def available(self, timeout=0):
        return bool(self.buffer) or bool(select.select([self.socket], [], [], timeout)[0])


def info(client, section='server'):
    value = client.call('INFO', section)
    if not isinstance(value, bytes):
        raise AssertionError('INFO did not return a bulk string')
    return dict(line.split(':', 1) for line in value.decode().splitlines() if ':' in line and not line.startswith('#'))


def compute_info(client):
    values = info(client)
    missing = set(FIELDS)-set(values)
    if missing:
        raise AssertionError('missing compute INFO fields: ' + ', '.join(sorted(missing)))
    return {name: int(values[name]) for name in FIELDS}


def wait_for(predicate, timeout=10, label='condition'):
    end = time.monotonic()+timeout
    while True:
        value = predicate()
        if value:
            return value
        if time.monotonic() >= end:
            raise AssertionError('timed out waiting for ' + label)
        time.sleep(0.005)


class Server:
    def __init__(self, binary, workers=2, memory=512 << 20, arguments=(), queue_ping=False):
        self.binary = Path(binary).resolve()
        self.queue_ping = queue_ping
        self.workers = workers
        self.memory = memory
        self.arguments = list(arguments)
        self.temporary = tempfile.TemporaryDirectory(prefix='eski-threading-')
        self.directory = Path(self.temporary.name)
        self.process = None
        self.clients = []
        self.log = None
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            self.port = probe.getsockname()[1]

    def start(self):
        if not self.binary.is_file():
            raise ValueError('server binary does not exist: ' + str(self.binary))
        command = [str(self.binary), '--bind', '127.0.0.1', '--port', str(self.port), '--dir', str(self.directory),
                   '--save', '', '--appendonly', 'no', '--enable-debug-command', 'yes', '--enable-protected-configs', 'yes']
        if self.workers is not None:
            command += ['--compute-threads', str(self.workers), '--compute-max-memory', str(self.memory)]
        self.log = (self.directory/'server.log').open('ab')
        self.process = subprocess.Popen(command+self.arguments, stdin=subprocess.DEVNULL, stdout=self.log,
                                        stderr=subprocess.STDOUT, start_new_session=True)
        end = time.monotonic()+15
        while time.monotonic() < end:
            if self.process.poll() is not None:
                raise AssertionError('server exited during startup: ' + (self.directory/'server.log').read_text(errors='replace')[-4000:])
            candidate = None
            try:
                candidate = Client(self.port, timeout=0.3)
                if candidate.call('PING') == 'PONG':
                    candidate.close()
                    return self
            except ServerError as error:
                if not str(error).startswith('LOADING '):
                    raise
            except (OSError, EOFError):
                pass
            finally:
                if candidate is not None:
                    candidate.close()
            time.sleep(0.02)
        raise AssertionError('server did not start within 15 seconds')

    def client(self, timeout=15):
        value = Client(self.port, timeout, self.queue_ping)
        self.clients.append(value)
        return value

    def stop(self, timeout=10, expected_exit=0):
        if expected_exit not in (0, 1) or (expected_exit == 1 and (self.process is None or self.process.poll() != 1)):
            raise ValueError('expected_exit=1 requires an already observed exact exit 1')
        for client in self.clients:
            client.close()
        self.clients.clear()
        problem = None
        if self.process is not None:
            try:
                if self.process.poll() is None:
                    try:
                        os.killpg(self.process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                forced = False
                try:
                    code = self.process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    forced = True
                    os.killpg(self.process.pid, signal.SIGKILL)
                    code = self.process.wait(timeout=5)
                if forced:
                    problem = 'server shutdown exceeded %.2f seconds and required SIGKILL (exit %s)' % (timeout, code)
                elif code != expected_exit:
                    problem = 'server exited with unexpected status %s; expected clean exit %s' % (code, expected_exit)
            except Exception as error:
                problem = 'server cleanup failed: '+type(error).__name__+': '+str(error)
                try:
                    self.process.kill()
                    self.process.wait(timeout=5)
                except Exception as final_error:
                    problem += '; final reap failed: '+str(final_error)
            finally:
                self.process = None
                if self.log is not None:
                    self.log.close()
                    self.log = None
        elif self.log is not None:
            self.log.close()
            self.log = None
        if problem:
            path = self.directory/'server.log'
            log = path.read_text(errors='replace')[-16384:] if path.exists() else '(server log unavailable)'
            raise AssertionError(problem+'\nserver log tail:\n'+log)

    def close(self):
        try:
            self.stop()
        finally:
            self.temporary.cleanup()

    def __enter__(self):
        try:
            return self.start()
        except BaseException:
            self.close()
            raise

    def __exit__(self, *unused):
        self.close()


def lcs_length(left, right):
    previous = [0]*(len(right)+1)
    for a in left:
        current = [0]
        for at, b in enumerate(right):
            current.append(previous[at]+1 if a == b else max(previous[at+1], current[-1]))
        previous = current
    return previous[-1]


def is_subsequence(part, whole):
    iterator = iter(whole)
    return all(any(value == expected for value in iterator) for expected in part)


def thread_cpu(pid):
    result = {}
    for directory in Path('/proc', str(pid), 'task').glob('*'):
        try:
            text = (directory/'stat').read_text()
            close = text.rindex(')')
            fields = text[close+2:].split()
            result[int(directory.name)] = {'name': text[text.index('(')+1:close], 'ticks': int(fields[11])+int(fields[12])}
        except (OSError, ValueError, IndexError):
            pass
    return result


def cpu_delta(before, after, elapsed, ticks_per_second=None):
    frequency = ticks_per_second or os.sysconf('SC_CLK_TCK')
    rows = []
    for tid, current in sorted(after.items()):
        old = before.get(tid, {'ticks': 0})
        seconds = max(0, current['ticks']-old['ticks'])/frequency
        rows.append({'tid': tid, 'name': current['name'], 'cpu_seconds': seconds,
                     'cpu_cores': seconds/elapsed if elapsed > 0 else 0.0})
    return rows
