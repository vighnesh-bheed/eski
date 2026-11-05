import argparse
import collections
import fcntl
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from kernel_audit import audit as audit_kernel

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().parent
MIN_I64 = -(1 << 63)
MAX_I64 = (1 << 63) - 1
SEED = 0xE5A1C04


def byte_text(data, empty='-'):
    return ','.join(map(str, data)) if data else empty


def integer_bytes(value):
    if 0 <= value < 128:
        return bytes([value])
    if -4096 <= value < 4096:
        raw = value % 8192
        return bytes([192 + raw // 256, raw % 256])
    for width, tag in ((2, 241), (3, 242), (4, 243), (8, 244)):
        if -(1 << (8 * width - 1)) <= value < 1 << (8 * width - 1):
            return bytes([tag]) + value.to_bytes(width, 'little', signed=True)
    raise AssertionError('outside i64')


def string_bytes(value):
    n = len(value)
    if n < 64:
        header = bytes([128 + n])
    elif n < 4096:
        header = bytes([224 + n // 256, n % 256])
    else:
        header = b'\xf0' + n.to_bytes(4, 'little')
    return header + value


def back_bytes(n):
    if n > 0xffffffff:
        return b''
    width = next(width for width, threshold in enumerate((128, 16383, 2097151, 268435455, 1 << 32), 1) if n < threshold)
    groups = [(n // (128 ** power)) % 128 for power in range(width - 1, -1, -1)]
    return bytes([groups[0]] + [b + 128 for b in groups[1:]])


def read_back(data, last, lower):
    if lower < 0 or last < lower or last >= len(data):
        return None
    groups = []
    for at in range(last, max(lower - 1, last - 5), -1):
        groups.append(data[at] % 128)
        if data[at] < 128:
            value = sum(group * 128 ** k for k, group in enumerate(groups))
            return (value, len(groups)) if value <= 0xffffffff else None
    return None


def decode_body(data, offset=0):
    if not 0 <= offset < len(data):
        return None
    remain = data[offset:]
    tag = remain[0]
    if tag < 128:
        return 1, tag, None
    if tag < 192:
        header, length = 1, tag - 128
    elif tag < 224:
        if len(remain) < 2:
            return None
        raw = (tag - 192) * 256 + remain[1]
        return 2, raw - 8192 if raw >= 4096 else raw, None
    elif tag < 240:
        if len(remain) < 2:
            return None
        header, length = 2, (tag - 224) * 256 + remain[1]
    elif tag == 240:
        if len(remain) < 5:
            return None
        header, length = 5, int.from_bytes(remain[1:5], 'little')
    elif tag in (241, 242, 243, 244):
        width = {241: 2, 242: 3, 243: 4, 244: 8}[tag]
        if len(remain) <= width:
            return None
        return width + 1, int.from_bytes(remain[1:width + 1], 'little', signed=True), None
    else:
        return None
    if len(remain) < header + length:
        return None
    return header + length, 0, remain[header:header + length]


def body_text(data, offset=0):
    body = decode_body(data, offset)
    if body is None:
        return '0|0|0|-'
    length, value, payload = body
    return f'1|{length}|{value}|' + ('n' if payload is None else byte_text(payload, '~'))


def extent(data, offset, limit):
    if not 0 <= offset < limit <= len(data):
        return None
    body = decode_body(data[:limit], offset)
    if body is None:
        return None
    n = body[0]
    finish = offset + n + len(back_bytes(n))
    if finish > limit:
        return None
    back = read_back(data, finish - 1, 0)
    return finish if back and back[0] == n else None


def pack_text(data):
    if len(data) < 7 or int.from_bytes(data[:4], 'little') != len(data) or data[-1] != 255:
        return 'L|0|0|0|-|-'
    cached = int.from_bytes(data[4:6], 'little')
    offsets = []
    cursor = 6
    while cursor < len(data) - 1:
        offsets.append(cursor)
        finish = extent(data, cursor, len(data) - 1)
        if finish is None or finish <= cursor:
            return 'L|1|0|0|-|-'
        cursor = finish
    if cached not in (65535, len(offsets)):
        return 'L|1|0|0|-|-'
    return f'L|1|1|{len(offsets)}|{byte_text(offsets)}|{byte_text(offsets[::-1])}'


def parse_result(data, base, bulk_max, unauth, array_max, unauth_max):
    def result(kind=0, fault=0, consumed=0, need=0, payload=0, error=0, args=()):
        shown = '/'.join(byte_text(arg, '~') for arg in args) if args else '-'
        return f'{kind},{fault},{consumed},{need},{payload},{error}:{shown}'

    def line_at(start, fault):
        tail = data[start:]
        zero = tail.find(b'\0')
        cr = tail.find(b'\r')
        if cr < 0 or 0 <= zero < cr:
            return None, result(kind=2, fault=fault) if len(tail) > 65536 else result(need=len(data) + 1)
        at = start + cr
        if at + 1 == len(data):
            return None, result(need=at + 2)
        return (data[start:at], at + 2), None

    def integer(text):
        if not re.fullmatch(rb'(0|[1-9][0-9]*|-[1-9][0-9]*)', text):
            return None
        n = int(text)
        return n if MIN_I64 <= n <= MAX_I64 else None

    if not data:
        return result(need=1)
    header, incomplete = line_at(0, 7)
    if incomplete:
        return incomplete
    text, cursor = header
    count = integer(text[1:]) if text.startswith(b'*') else None
    if count is None or count > 2147483647:
        return result(kind=2, fault=1)
    if count <= 0:
        return result(kind=1, consumed=cursor)
    if unauth and count > array_max:
        return result(kind=2, fault=3)
    args = []
    for _ in range(count):
        header, incomplete = line_at(cursor, 8)
        if incomplete:
            return incomplete
        text, payload = header
        if not text.startswith(b'$'):
            return result(kind=2, fault=5, error=data[cursor])
        length = integer(text[1:])
        if length is None or length < 0 or length > bulk_max:
            return result(kind=2, fault=2)
        if unauth and length > unauth_max:
            return result(kind=2, fault=4)
        finish = payload + length + 2
        if base < 0 or base + finish > MAX_I64:
            return result(kind=2, fault=2)
        if finish > len(data):
            return result(need=finish, payload=payload)
        args.append(data[payload:finish - 2])
        cursor = finish
    return result(kind=1, consumed=cursor, args=args)


def corpus():
    rng = random.Random(SEED)
    lines, expected = [], []
    counts = collections.Counter()
    coverage = collections.Counter()

    def add(op, fields, want):
        lines.append(' '.join([op] + list(map(str, fields))))
        expected.append(want)
        counts[op] += 1
        if op == 'G':
            coverage['guard_accepted' if want.split('|')[1] == '1' else 'guard_rejected'] += 1
        elif op == 'D':
            coverage['body_accepted' if want.split('|')[1] == '1' else 'body_rejected'] += 1
        elif op == 'L':
            coverage['pack_deep_accepted' if want.split('|')[2] == '1' else 'pack_deep_rejected'] += 1

    extremes = (MIN_I64, -1, 0, 1, 7, MAX_I64 - 3, MAX_I64 - 2, MAX_I64 - 1, MAX_I64)
    for base, payload, length in itertools.product(extremes, repeat=3):
        valid = min(base, payload, length) >= 0 and base + payload + length + 2 <= MAX_I64
        add('G', [base, payload, length], f'G|{int(valid)}|{payload + length + 2 if valid else 0}')
    for _ in range(300):
        base, payload = rng.randrange(MAX_I64), rng.randrange(10000)
        for length in (MAX_I64 - base - payload - 3, MAX_I64 - base - payload - 2, MAX_I64 - base - payload - 1):
            if MIN_I64 <= length <= MAX_I64:
                valid = min(base, payload, length) >= 0 and base + payload + length + 2 <= MAX_I64
                add('G', [base, payload, length], f'G|{int(valid)}|{payload + length + 2 if valid else 0}')
    values = set(range(-4096, 4096))
    for edge in (MIN_I64, MAX_I64, -2147483648, 2147483647, -8388608, 8388607, -32768, 32767, -4096, 4095, 0, 127, 128):
        values.update(edge + delta for delta in range(-2, 3) if MIN_I64 <= edge + delta <= MAX_I64)
    values.update(rng.randrange(MIN_I64, MAX_I64 + 1) for _ in range(400))
    bodies = []
    for value in sorted(values):
        body = integer_bytes(value)
        coverage['integer_width_' + str(len(body))] += 1
        add('I', [value], f'I|{len(body)}|{byte_text(body)}|{body_text(body)}|{len(body) + len(back_bytes(len(body)))}')
        if value in (-4096, 4095, -32768, 32767, MIN_I64, MAX_I64, 0, 127, 128, -8388608, 8388607, -2147483648, 2147483647):
            bodies.append(body)
    for n in list(range(141)) + [255, 256, 257, 4094, 4095, 4096, 4097, 16381, 16382, 16383, 16384]:
        value = bytes((i * 197 + n) % 256 for i in range(n))
        body = string_bytes(value)
        coverage['string_header_' + str(len(body) - n)] += 1
        add('S', [byte_text(value)], f'S|{len(body)}|{byte_text(body)}|{body_text(body)}|{len(body) + len(back_bytes(len(body)))}')
        if n in (0, 1, 63, 64, 127, 128, 4095, 4096):
            bodies.append(body)
    back_values = {0, 1, (1 << 32) - 1, 1 << 32, (1 << 63) - 1, (1 << 64) - 1}
    for edge in (127, 128, 16382, 16383, 2097150, 2097151, 268435454, 268435455):
        back_values.update(range(edge - 2, edge + 3))
    back_values.update(rng.randrange(1 << 32) for _ in range(300))
    for n in sorted(back_values):
        encoded = back_bytes(n)
        got = read_back(encoded, len(encoded) - 1, 0)
        coverage['back_width_' + str(len(encoded))] += 1
        add('B', [n], f'B|{len(encoded)}|{byte_text(encoded)}|{got[0] if got else 0}|{got[1] if got else 0}|{int(got is not None)}')
        for last, lower in ((len(encoded) - 1, 0), (len(encoded), 0), (len(encoded) - 1, max(0, len(encoded) - 1))):
            if last < 0:
                continue
            got = read_back(encoded, last, lower)
            add('R', [byte_text(encoded), last, lower], f'R|{int(got is not None)}|{got[0] if got else 0}|{got[1] if got else 0}')
    for _ in range(300):
        data = rng.randbytes(rng.randrange(9))
        last, lower = rng.randrange(9), rng.randrange(9)
        got = read_back(data, last, lower)
        add('R', [byte_text(data), last, lower], f'R|{int(got is not None)}|{got[0] if got else 0}|{got[1] if got else 0}')
    for body in bodies:
        cuts = range(len(body) + 1) if len(body) < 20 else (0, 1, 2, 3, 4, 5, len(body) - 1, len(body))
        for end in cuts:
            for offset in (0, 2):
                data = bytes([255] * offset) + body[:end]
                add('D', [byte_text(data), offset], 'D|' + body_text(data, offset))
    for tag in range(245, 256):
        for n in range(10):
            data = bytes([tag]) + rng.randbytes(n)
            add('D', [byte_text(data), 0], 'D|' + body_text(data))
    for _ in range(300):
        data = rng.randbytes(rng.randrange(20))
        offset = rng.randrange(len(data) + 2)
        add('D', [byte_text(data), offset], 'D|' + body_text(data, offset))
    packs = []
    for entries in ([], bodies[:13], bodies[13:], bodies, [integer_bytes(0)], [string_bytes(b'')]):
        payload = b''.join(body + back_bytes(len(body)) for body in entries)
        for cached in (len(entries), 65535):
            pack = (7 + len(payload)).to_bytes(4, 'little') + cached.to_bytes(2, 'little') + payload + b'\xff'
            packs.append(pack)
    for pack in packs:
        add('L', [byte_text(pack)], pack_text(pack))
        cuts = range(len(pack)) if len(pack) < 25 else (0, 1, 5, 6, 7, len(pack) // 2, len(pack) - 1)
        for end in cuts:
            cut = pack[:end]
            add('L', [byte_text(cut)], pack_text(cut))
        for at in sorted({0, 4, 6, len(pack) - 2, len(pack) - 1}):
            for byte in (0, 128, 245, 255):
                bad = pack[:at] + bytes([byte]) + pack[at + 1:]
                add('L', [byte_text(bad)], pack_text(bad))
    parser_inputs = [b'', b'*0\r\n', b'*-1\r\n', b'*-9223372036854775808\r\n', b'*1\r\n$0\r\n\r\n', b'*1\r\n$3\r\n\x00\xff\r\r\n', b'*2\r\n$3\r\nSET\r\n$2\r\nxy\r\n', b'*1\rX$1\rYzAB', b'*01\r\n', b'*+1\r\n', b'*-0\r\n', b'*2147483648\r\n', b'*9223372036854775808\r\n', b'*1\r\n$-1\r\n', b'*1\r\n$01\r\n', b'*1\r\n:1\r\n', b'*1\r\n$9223372036854775808\r\n', b'*1\r\n$9223372036854775807\r\n', b'*1\r\n$4\r\nabc', b'*1\r\n$3\r\nabc\r\nx', b'*\x00\r\n', b'*1\r\n$\x00\r\n']

    def parser_case(data, sizes, limits=(0, 536870912, False, 10, 16384)):
        base, bulk, unauth, array_max, unauth_max = limits
        cursor, results = 0, []
        for size in sizes:
            cursor += size
            result = parse_result(data[:cursor], *limits)
            results.append(result)
            kind = int(result[0])
            coverage['parser_kind_' + str(kind)] += 1
        coverage['parser_calls'] += len(sizes)
        add('P', [base, bulk, int(unauth), array_max, unauth_max, byte_text(data), ','.join(map(str, sizes))], 'P|' + ';'.join(results))

    for data in parser_inputs:
        for split in range(len(data) + 1):
            parser_case(data, [split, len(data) - split])
        for end in range(len(data) + 1):
            parser_case(data[:end], [end])
    for count in (9, 10, 11):
        data = f'*{count}\r\n'.encode() + b'$0\r\n\r\n' * count
        for unauth in (False, True):
            parser_case(data, [len(data)], (0, 536870912, unauth, 10, 16384))
    for n in (0, 1, 127, 128, 16383, 16384, 16385):
        data = b'*1\r\n$' + str(n).encode() + b'\r\n'
        for unauth in (False, True):
            for bulk in (n - 1, n, MAX_I64):
                parser_case(data, [len(data)], (0, bulk, unauth, 10, 16384))
    for base in (-1, 0, MAX_I64 - 10, MAX_I64 - 9, MAX_I64 - 8, MAX_I64):
        for data in (b'*0\r\n', b'*1\r\n$0\r\n\r\n', b'*1\r\n$1\r\na\r\n'):
            parser_case(data, [len(data)], (base, MAX_I64, False, 10, 16384))
    for _ in range(300):
        args = [rng.randbytes(rng.randrange(33)) for _ in range(rng.randrange(1, 8))]
        data = f'*{len(args)}\r\n'.encode() + b''.join(b'$' + str(len(arg)).encode() + b'\r\n' + arg + b'\r\n' for arg in args)
        if rng.randrange(3) == 0:
            data = data[:rng.randrange(len(data) + 1)]
        sizes, remaining = [], len(data)
        while remaining:
            size = rng.randrange(1, min(remaining, 17) + 1)
            sizes.append(size)
            remaining -= size
        parser_case(data, sizes or [0], (rng.randrange(10), 64, bool(rng.randrange(2)), 10, 16384))
    for n in (65536, 65537):
        parser_case(b'*' + b'x' * (n - 1), [n])
        data = b'*1\r\n' + b'$' + b'x' * (n - 1)
        parser_case(data, [len(data)])
    for key in ('parser_kind_0', 'parser_kind_1', 'parser_kind_2', 'guard_accepted', 'guard_rejected', 'body_accepted', 'body_rejected', 'pack_deep_accepted', 'pack_deep_rejected', 'string_header_1', 'string_header_2', 'string_header_5'):
        if coverage[key] <= 0:
            raise AssertionError('empty required coverage: ' + key)
    for width in (1, 2, 3, 4, 5, 9):
        if not coverage['integer_width_' + str(width)]:
            raise AssertionError('missing integer width')
    for width in range(1, 6):
        if not coverage['back_width_' + str(width)]:
            raise AssertionError('missing backlen width')
    if set(counts) != {'G', 'I', 'S', 'B', 'R', 'D', 'L', 'P'} or min(counts.values()) <= 0:
        raise AssertionError('missing operation family')
    return '\n'.join(lines) + '\n', expected, dict(counts), dict(coverage)


def compare(label, got, expected):
    rows = got.splitlines()
    if len(rows) != len(expected):
        raise AssertionError(f'{label}: {len(rows)} rows, expected {len(expected)}')
    for index, (actual, want) in enumerate(zip(rows, expected)):
        if actual != want:
            raise AssertionError(f'{label}: row {index}: got {actual[:250]!r}, expected {want[:250]!r}')


def fingerprints():
    pinned = json.loads((PACKAGE / 'source-sha256.json').read_text())
    if not pinned:
        raise AssertionError('empty source drift gate')
    names = {'src/request_parser_adapter.odin', 'src/acl.odin', 'src/config_table.odin'}
    for package in ('request_parser', 'listpack', 'integer'):
        names.update(str(path.relative_to(ROOT)) for path in (ROOT / 'src' / package).glob('*.odin') if not path.name.endswith('_test.odin'))
    if set(pinned) != names:
        raise AssertionError('source inventory changed; reconcile imported source drift gate')
    for name, digest in pinned.items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
            raise AssertionError('source fingerprint changed; reconcile models before updating: ' + name)
    return pinned


def check_axioms(lake, env, output):
    return audit_kernel(lake, PACKAGE, output, env, "Encoding")


def negative_controls(expected):
    rejected = []
    probes = {'empty': '', 'truncated': '\n'.join(expected[:-1]) + '\n', 'extra': '\n'.join(expected + [expected[-1]]) + '\n'}
    for opcode in ('G', 'I', 'S', 'B', 'R', 'D', 'L', 'P'):
        index = next(i for i, row in enumerate(expected) if row.startswith(opcode + '|'))
        for column in range(1, len(expected[index].split('|'))):
            mutant = expected.copy()
            fields = mutant[index].split('|')
            fields[column] = 'controlled-bad-value'
            mutant[index] = '|'.join(fields)
            probes[f'{opcode}-column-{column}'] = '\n'.join(mutant) + '\n'
    for label, data in probes.items():
        try:
            compare('controlled-' + label, data, expected)
        except AssertionError:
            rejected.append(label)
        else:
            raise AssertionError('comparator accepted a controlled bad output: ' + label)
    return rejected


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('--lean-bin', type=Path, default=Path(os.environ['LEAN_BIN_DIR']) if 'LEAN_BIN_DIR' in os.environ else None)
    parser.add_argument('--output', type=Path, default=PACKAGE / '.build')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / 'receipt.json').unlink(missing_ok=True)
    if hasattr(os, 'sched_getaffinity'):
        os.sched_setaffinity(0, {min(os.sched_getaffinity(0))})
    if hasattr(os, 'nice'):
        os.nice(10)
    source_hashes = fingerprints()
    trace, expected, counts, coverage = corpus()
    trace_path = output / 'traces.txt'
    trace_path.write_text(trace)
    env = dict(os.environ)
    env['LEAN_NUM_THREADS'] = '1'
    if args.lean_bin:
        env['PATH'] = str(args.lean_bin.resolve()) + os.pathsep + env.get('PATH', '')
    bins = {name: shutil.which(name, path=env.get('PATH')) for name in ('lean', 'lake', 'odin')}
    if not all(bins.values()):
        raise AssertionError('Lean 4.35.0, Lake and Odin are required; supply --lean-bin or LEAN_BIN_DIR')
    versions = {}
    for name in bins:
        versions[name] = subprocess.run([bins[name], 'version' if name == 'odin' else '--version'], env=env, capture_output=True, text=True, check=True).stdout.strip()
    if not re.search(r'\bversion 4\.35\.0\b', versions['lean']):
        raise AssertionError('expected pinned Lean 4.35.0')
    lock_path = ROOT / '.build/proofs/compiler.lock'
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    outputs = {}
    executables = {'lean': PACKAGE / '.lake/build/bin/encoding_model', 'odin': output / 'odin_bridge'}
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        logs = []
        for command, cwd in (([bins['lake'], 'build'], PACKAGE), ([bins['odin'], 'build', str(PACKAGE / 'bridge.odin'), '-file', '-out:' + str(executables['odin']), '-thread-count:2', '-vet', '-strict-style'], ROOT)):
            result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True)
            logs.append(result.stdout + result.stderr)
            (output / 'build.txt').write_text('\n'.join(logs))
            if result.returncode:
                raise AssertionError('build failed: ' + logs[-1])
        audit, kernel = check_axioms(bins['lake'], env, output)
        for name, binary in executables.items():
            result = subprocess.run([str(binary), str(trace_path)], env=env, capture_output=True, text=True, check=True)
            if result.stderr:
                raise AssertionError(name + ': unexpected stderr: ' + result.stderr)
            (output / (name + '-results.txt')).write_text(result.stdout)
            compare(name, result.stdout, expected)
            outputs[name] = hashlib.sha256(result.stdout.encode()).hexdigest()
    rejected = negative_controls(expected)
    area4 = ['Encoding.' + name for name in re.findall(r'^theorem\s+(\w+)', (PACKAGE / 'Encoding/Parser.lean').read_text(), re.M)]
    area5 = ['Encoding.' + name for name in re.findall(r'^theorem\s+(\w+)', (PACKAGE / 'Encoding/Codec.lean').read_text(), re.M)]
    receipt = {'trace_rows': len(expected), 'cases': counts, 'coverage': coverage, 'seed': hex(SEED),
               'controlled_bad_outputs_rejected': rejected, 'checked_theorem_axioms': audit,
               'kernel_inventory_sha256': hashlib.sha256((output / 'kernel-inventory.json').read_bytes()).hexdigest(),
               'kernel_checked_theorems': len(kernel['theorem_axioms']),
               'source_sha256': source_hashes, 'versions': versions,
               'area_evidence': {'4': {'theorems': area4, 'comparisons': counts['G'] + coverage['parser_calls']},
                                 '5': {'theorems': area5, 'comparisons': sum(counts[op] for op in ('I', 'S', 'B', 'R', 'D', 'L'))}},
               'trace_sha256': hashlib.sha256(trace.encode()).hexdigest(), 'results_sha256': outputs,
               'executable_sha256': {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in executables.items()},
               'compiler_sha256': {name: hashlib.sha256(Path(path).read_bytes()).hexdigest() for name, path in bins.items()}}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    run()
