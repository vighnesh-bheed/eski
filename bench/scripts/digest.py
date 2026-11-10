import argparse
import difflib
import hashlib
import os
import re
import socket
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import Server, encode


class Raw:
    def __init__(self, port):
        self.s = socket.create_connection(('127.0.0.1', port), timeout=20)
        self.buf = b''

    def _fill(self):
        chunk = self.s.recv(65536)
        if not chunk:
            raise EOFError
        self.buf += chunk

    def _line(self):
        while b'\r\n' not in self.buf:
            self._fill()
        i = self.buf.index(b'\r\n')
        line, self.buf = self.buf[:i + 2], self.buf[i + 2:]
        return line

    def _take(self, n):
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def frame(self):
        line = self._line()
        t = line[:1]
        if t in b'+-:_#,(':
            return line
        if t in b'$!=':
            n = int(line[1:-2])
            if n < 0:
                return line
            return line + self._take(n + 2)
        if t in b'*~>%|':
            n = int(line[1:-2])
            if n < 0:
                return line
            k = n * 2 if t in b'%|' else n
            out = line
            for _ in range(k):
                out += self.frame()
            return out
        raise ValueError(line)

    def call(self, *args):
        self.s.sendall(encode(args))
        return self.frame()

    def close(self):
        self.s.close()


INFO_FIELDS = ('used_memory_scripts_eval', 'number_of_cached_scripts', 'number_of_functions', 'number_of_libraries',
               'used_memory_functions', 'evicted_scripts')


def normalise(args, frame):
    name = str(args[0]).upper()
    if name == 'INFO':
        keep = []
        for line in frame.split(b'\r\n'):
            field = line.split(b':', 1)[0].decode(errors='replace')
            if field in INFO_FIELDS:
                keep.append(line)
        return b'(info)' + b'|'.join(keep)
    if name == 'FUNCTION' and len(args) > 1 and str(args[1]).upper() == 'STATS':
        return re.sub(rb'duration_ms\r\n:\d+', b'duration_ms\r\n:D', frame)
    return frame


LIB = "#!lua name=lib\nredis.register_function('draw', function(keys, args) return {math.random(1000000), cjson.encode_max_depth(), cjson.encode({0.123456789012})} end)\nredis.register_function{function_name='ro', callback=function() return 'ro' end, flags={'no-writes'}}\nredis.register_function('tune', function() cjson.encode_max_depth(5); cjson.encode_number_precision(3); math.randomseed(13); return 1 end)"
LIB2 = "#!lua name=lib\nredis.register_function('draw', function() return 'replaced' end)"
OTHER = "#!lua name=other\nredis.register_function('other_f', function(keys, args) return redis.call('SET', keys[1], args[1]) end)"
SETTINGS = ("return {math.random(1000000), cjson.encode_max_depth(), cjson.decode_max_depth(), cjson.encode_number_precision(), "
            "tostring(cjson.encode_keep_buffer()), tostring(cjson.encode_invalid_numbers()), tostring(cjson.decode_invalid_numbers()), "
            "{cjson.encode_sparse_array()}, cjson.encode({0.123456789012}), collectgarbage('setpause', 150), collectgarbage('setstepmul', 250)}")
TUNE = ("cjson.encode_max_depth(4); cjson.decode_max_depth(6); cjson.encode_number_precision(2); cjson.encode_keep_buffer(false); "
        "cjson.encode_invalid_numbers('null'); cjson.decode_invalid_numbers(false); cjson.encode_sparse_array(true, 3, 4); "
        "collectgarbage('setpause', 111); return math.random(10)")


def session():
    steps = []
    def on(conn, *args):
        steps.append((conn, args))
    on('b', 'HELLO', '3')
    on('a', 'SCRIPT', 'HELP')
    on('a', 'SCRIPT', 'KILL')
    on('a', 'FUNCTION', 'KILL')
    on('a', 'FUNCTION', 'HELP')
    on('a', 'FUNCTION', 'STATS')
    on('a', 'EVAL', 'return {math.random(), math.random(1000), math.random(5, 50)}', 0)
    on('b', 'EVAL', 'return {math.random(1000), math.random(1000)}', 0)
    sha_draw = hashlib.sha1(b'return math.random(1000000)').hexdigest()
    on('a', 'EVALSHA', sha_draw, 0)
    on('a', 'SCRIPT', 'LOAD', 'return math.random(1000000)')
    on('b', 'EVALSHA', sha_draw, 0)
    on('b', 'EVALSHA_RO', sha_draw, 0)
    on('a', 'SCRIPT', 'EXISTS', sha_draw, sha_draw.upper(), 'nope', '0' * 40)
    on('a', 'EVAL', SETTINGS, 0)
    on('a', 'EVAL', TUNE, 0)
    on('b', 'EVAL', SETTINGS, 0)
    on('a', 'EVAL', SETTINGS, 0)
    on('a', 'EVAL', 'math.randomseed(42); return math.random(1000)', 0)
    on('b', 'EVAL', 'return math.random(1000)', 0)
    on('a', 'FUNCTION', 'LOAD', LIB)
    on('a', 'FUNCTION', 'LOAD', LIB)
    on('a', 'FUNCTION', 'LOAD', OTHER)
    on('b', 'FCALL', 'draw', 0)
    on('b', 'FCALL', 'tune', 0)
    on('a', 'FCALL', 'draw', 0)
    on('a', 'EVAL', SETTINGS, 0)
    on('a', 'FCALL_RO', 'ro', 0)
    on('a', 'FCALL_RO', 'draw', 0)
    on('a', 'FCALL', 'other_f', 1, 'fk', 'fv')
    on('a', 'FCALL', 'nope', 0)
    on('a', 'FUNCTION', 'LIST')
    on('b', 'FUNCTION', 'LIST', 'WITHCODE')
    on('a', 'FUNCTION', 'LIST', 'LIBRARYNAME', 'oth*')
    on('a', 'FUNCTION', 'STATS')
    on('a', 'FUNCTION', 'DUMP')
    on('a', 'FUNCTION', 'LOAD', 'REPLACE', LIB2)
    on('a', 'FCALL', 'draw', 0)
    on('a', 'FUNCTION', 'DELETE', 'other')
    on('a', 'FUNCTION', 'DELETE', 'other')
    on('a', 'INFO', 'memory')
    on('a', 'FUNCTION', 'FLUSH', 'SYNC')
    on('a', 'FCALL', 'draw', 0)
    on('a', 'EVAL', 'return math.random(1000000)', 0)
    on('a', 'FUNCTION', 'LOAD', LIB)
    on('a', 'FCALL', 'draw', 0)
    on('a', 'FUNCTION', 'RESTORE', b'\x00\x01', 'REPLACE')
    on('a', 'MULTI')
    on('a', 'EVALSHA', sha_draw, 0)
    on('a', 'EVAL', 'return 1', 0)
    on('a', 'SCRIPT', 'EXISTS', sha_draw)
    on('a', 'EXEC')
    on('a', 'EVAL', 'return x(', 0)
    on('a', 'EVAL', '#!lua flags=no-writes\nreturn redis.call("SET", "k", "v")', 0)
    on('a', 'EVAL', '#!lua flags=nope\nreturn 1', 0)
    on('a', 'EVAL_RO', 'return redis.call("GET", "k")', 0)
    on('a', 'EVALSHA', 'zz', 0)
    on('a', 'INFO', 'memory')
    on('a', 'INFO', 'stats')
    on('a', 'SCRIPT', 'FLUSH', 'ASYNC')
    on('a', 'SCRIPT', 'EXISTS', sha_draw)
    on('a', 'EVAL', 'return math.random(1000000)', 0)
    on('a', 'EVAL', SETTINGS, 0)
    on('a', 'INFO', 'memory')
    for i in range(505):
        on('a', 'EVAL', 'return %d' % i, 0)
    on('a', 'SCRIPT', 'EXISTS', *[hashlib.sha1(b'return %d' % i).hexdigest() for i in (0, 4, 5, 504)])
    on('a', 'INFO', 'stats')
    on('a', 'INFO', 'memory')
    on('a', 'SCRIPT', 'LOAD', 'return 504')
    on('a', 'SCRIPT', 'LOAD', 'return 700')
    for i in range(600, 1110):
        on('b', 'EVAL', 'return %d' % i, 0)
    on('a', 'SCRIPT', 'EXISTS', *[hashlib.sha1(b'return %d' % i).hexdigest() for i in (504, 700, 600, 1109)])
    on('a', 'INFO', 'stats')
    on('a', 'INFO', 'memory')
    on('a', 'SCRIPT', 'FLUSH')
    on('a', 'FUNCTION', 'FLUSH', 'ASYNC')
    on('a', 'EVAL', 'return math.random(1000000)', 0)
    on('a', 'INFO', 'memory')
    return steps


def run(binary, port, workdir, extra):
    server = Server(binary, port, workdir, ['--keyspace-threads', '0'] + extra)
    conns = {}
    out = []
    try:
        for who, args in session():
            if who not in conns:
                conns[who] = Raw(port)
            frame = conns[who].call(*args)
            label = ' '.join(a if isinstance(a, str) else (a.decode(errors='replace') if isinstance(a, bytes) else str(a)) for a in args)[:120]
            out.append((who, label, normalise(args, frame)))
        dump = [frame for who, label, frame in out if label == 'FUNCTION DUMP']
        if dump:
            payload = dump[0]
            body = payload.split(b'\r\n', 1)[1][:-2]
            out.append(('a', 'FUNCTION RESTORE dump REPLACE', conns['a'].call('FUNCTION', 'RESTORE', body, 'REPLACE')))
            out.append(('a', 'FUNCTION LIST', conns['a'].call('FUNCTION', 'LIST')))
            out.append(('a', 'FCALL draw', conns['a'].call('FCALL', 'draw', 0)))
    finally:
        for c in conns.values():
            c.close()
        server.stop()
    return out


def main():
    ap = argparse.ArgumentParser(description='Script and function digest: one fixed session of EVAL, EVALSHA, SCRIPT, FUNCTION and '
                                 'FCALL commands against two binaries with labels off, compared reply by reply.')
    ap.add_argument('--a', required=True)
    ap.add_argument('--b', required=True)
    ap.add_argument('--port', type=int, default=7654)
    ap.add_argument('--extra', default='', help='more server options for both binaries, split on spaces')
    ap.add_argument('--out', required=True, help='directory for the difference listing')
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    extra = args.extra.split()
    with tempfile.TemporaryDirectory(dir=args.out) as wa, tempfile.TemporaryDirectory(dir=args.out) as wb:
        a = run(args.a, args.port, wa, extra)
        b = run(args.b, args.port, wb, extra)
    diffs = [(who, label, fa, fb) for (who, label, fa), (_, _, fb) in zip(a, b) if fa != fb]
    with open(os.path.join(args.out, 'scripts-off.txt'), 'w') as fh:
        for who, label, fa, fb in diffs:
            fh.write('DIFF %s %s\n' % (who, label))
            for line in difflib.unified_diff(fa.decode(errors='replace').split('\r\n'), fb.decode(errors='replace').split('\r\n'), lineterm='', n=0):
                if not line.startswith(('---', '+++', '@@')):
                    fh.write('    ' + line[:300] + '\n')
    digest_a = hashlib.sha256(b''.join(f for _, _, f in a)).hexdigest()
    digest_b = hashlib.sha256(b''.join(f for _, _, f in b)).hexdigest()
    print('labels-off scripts: %d replies, %d identical, %d different; digest A %s B %s' % (len(a), len(a) - len(diffs), len(diffs), digest_a[:16], digest_b[:16]))
    sys.exit(1 if diffs or len(a) != len(b) else 0)


main()
