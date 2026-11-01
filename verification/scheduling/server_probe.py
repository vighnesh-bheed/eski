import os
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def encode(arguments):
    fields = [x if isinstance(x, bytes) else str(x).encode() for x in arguments]
    return b'*' + str(len(fields)).encode() + b'\r\n' + b''.join(
        b'$' + str(len(x)).encode() + b'\r\n' + x + b'\r\n' for x in fields)


class Client:
    def __init__(self, port):
        self.socket = socket.create_connection(('127.0.0.1', port), timeout=3)
        self.socket.settimeout(5)
        self.file = self.socket.makefile('rb')

    def close(self):
        self.file.close()
        self.socket.close()

    def read(self):
        head = self.file.read(1)
        if not head:
            return None
        line = self.file.readline()
        if not line.endswith(b'\r\n'):
            raise AssertionError('truncated reply')
        line = line[:-2]
        if head == b'+':
            return line
        if head == b'-':
            return ('error', line)
        if head == b':':
            return int(line)
        if head == b'$':
            size = int(line)
            if size == -1:
                return None
            payload = self.file.read(size + 2)
            if len(payload) != size + 2 or not payload.endswith(b'\r\n'):
                raise AssertionError('truncated bulk reply')
            return payload[:-2]
        if head == b'*':
            return [self.read() for _ in range(int(line))]
        raise AssertionError('unknown reply marker ' + repr(head))

    def command(self, *arguments):
        self.socket.sendall(encode(arguments))
        return self.read()


def run(binary, output, label):
    output = Path(output)
    directory = Path(tempfile.mkdtemp(prefix=label + '-node-', dir=output))
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    environment = dict(os.environ)
    environment['TSAN_OPTIONS'] = 'halt_on_error=1:exitcode=66'
    clients = []
    checks = []
    normal_exit = False
    log_path = output / (label + '-server.log')
    with log_path.open('w') as log:
        command = [str(binary), '--bind', '127.0.0.1', '--port', str(port), '--protected-mode', 'no',
                   '--save', '', '--appendonly', 'no', '--keyspace-threads', '2', '--compute-threads', '0',
                   '--dir', str(directory), '--loglevel', 'warning']
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=environment)
        try:
            deadline = time.monotonic() + 12
            while True:
                if process.poll() is not None:
                    raise AssertionError('owned server exited before readiness')
                try:
                    control = Client(port)
                    answer = control.command('PING')
                    if answer != b'PONG':
                        control.close()
                        raise AssertionError('unexpected readiness response ' + repr(answer))
                    clients.append(control)
                    break
                except (ConnectionRefusedError, ConnectionResetError, TimeoutError, OSError):
                    if time.monotonic() >= deadline:
                        raise AssertionError('owned server readiness deadline')
                    time.sleep(0.01)
            def info():
                payload = control.command('INFO', 'server')
                return {key.decode(): value.decode() for row in payload.split(b'\r\n')
                        if b':' in row for key, value in [row.split(b':', 1)]}
            before = int(info()['keyspace_jobs_submitted'])
            actor = Client(port)
            clients.append(actor)
            commands = [('SET', 'fifo', 'A'), ('GET', 'fifo'), ('APPEND', 'fifo', 'B'), ('GET', 'fifo'),
                        ('MSET', 'a', 'left', 'b', 'right', 'a', 'last'), ('MGET', 'b', 'a', 'a'),
                        ('RENAME', 'a', 'b'), ('MGET', 'b', 'a')]
            actor.socket.sendall(b''.join(encode(x) for x in commands))
            replies = [actor.read() for _ in commands]
            expected = [b'OK', b'A', 2, b'AB', b'OK', [b'right', b'last', b'last'], b'OK', [b'last', None]]
            if replies != expected:
                raise AssertionError('accepted connection history differs: ' + repr(replies))
            checks.extend(('pipeline_fifo', 'immutable_read_result', 'multi_record_reverse_alias', 'rename_conflict'))
            bad = actor.command('SET', 'fifo', 'bad', 'PX', '0')
            if not isinstance(bad, tuple) or bad[0] != 'error' or actor.command('GET', 'fifo') != b'AB':
                raise AssertionError('failed command changed value')
            checks.append('command_error_preserves_data')
            for index in range(4):
                writer = Client(port)
                try:
                    writer.socket.sendall(encode(('INCR', 'disconnected-' + str(index))))
                finally:
                    writer.close()
                deadline = time.monotonic() + 3
                while control.command('GET', 'disconnected-' + str(index)) != b'1':
                    if time.monotonic() >= deadline:
                        raise AssertionError('accepted write did not survive socket close')
                    time.sleep(0.005)
                checks.append('disconnect_write_' + str(index))
            after = int(info()['keyspace_jobs_submitted'])
            if after - before < 12:
                raise AssertionError('worker admission counter did not cover targeted commands')
            checks.append('worker_admission_observed')
            actor.close()
            clients.remove(actor)
            control.socket.sendall(encode(('SHUTDOWN', 'NOSAVE')))
            while control.file.read(1024):
                pass
            status = process.wait(timeout=8)
            if status != 0:
                raise AssertionError('owned server shutdown status ' + str(status))
            normal_exit = True
        finally:
            for client in clients:
                client.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    content = log_path.read_text()
    if 'ThreadSanitizer' in content or 'Sanitizer:DEADLYSIGNAL' in content:
        raise AssertionError('sanitizer report in ' + log_path.name)
    if not normal_exit:
        raise AssertionError('forced cleanup cannot pass')
    shutil.rmtree(directory)
    return {'passed': True, 'checks': checks, 'count': len(checks), 'submitted_delta': after - before,
            'exit_code': status, 'log': log_path.name, 'cleanup': 'owned process reaped; clients closed',
            'bounds': {'workers': 2, 'pipeline_commands': 8, 'disconnects': 4, 'nodes': 1}}
