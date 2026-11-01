import argparse
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().parent
MIN_I64 = -(1 << 63)
MAX_I64 = (1 << 63) - 1


def limits(signed, bits):
    return (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)


def read_field(data, signed, bits, offset):
    raw = 0
    for at in range(offset, offset + bits):
        raw = raw * 2 + ((data[at // 8] >> (7 - at % 8)) & 1 if at // 8 < len(data) else 0)
    return raw - (1 << bits) if signed and raw >= (1 << (bits - 1)) else raw


def write_field(data, bits, offset, value):
    raw = value % (1 << bits)
    for k in range(bits):
        at = offset + k
        mask = 1 << (7 - at % 8)
        if (raw >> (bits - k - 1)) & 1:
            data[at // 8] |= mask
        else:
            data[at // 8] &= 255 ^ mask


def bytes_text(data):
    return ','.join(map(str, data)) if data else '-'


def expected_step(data, ops):
    before = len(data)
    needed = max([before] + [(off + bits + 7) // 8 for code, sign, bits, off, arg, mode in ops if code != 'G'])
    data.extend(bytes(needed - before))
    grown = len(data) > before
    changes = 0
    replies = []
    for code, signed, bits, offset, arg, mode in ops:
        old = read_field(data, signed, bits, offset)
        if code == 'G':
            replies.append(str(old))
            continue
        lo, hi = limits(signed, bits)
        target = old + arg if code == 'I' else arg if signed else arg % (1 << 64)
        if mode == 'F' and not lo <= target <= hi:
            replies.append('n')
            continue
        if mode == 'W':
            new = target % (1 << bits)
            if signed and new >= (1 << (bits - 1)):
                new -= 1 << bits
        elif target > hi:
            new = hi
        elif target < lo:
            new = hi if signed and code == 'S' and bits < 64 and hi - target > MAX_I64 else lo
        else:
            new = target
        replies.append(str(old if code == 'S' else new))
        changes += int(grown or old != new)
        write_field(data, bits, offset, new)
    return f'{changes}|{bytes_text(data)}|{",".join(replies)}'


def corpus():
    rng = random.Random(0xE5A1B17)
    lines = []
    expected = []
    stats = {'programs': 0, 'operations': 0, 'boundary_programs': 0, 'generated_programs': 0}
    data = bytearray()

    def reset(initial):
        nonlocal data
        data = bytearray(initial)
        lines.append('R ' + bytes_text(data))

    def program(ops, category='boundary_programs'):
        lines.append('P' + ''.join(' ' + ' '.join(map(str, op)) for op in ops))
        expected.append(expected_step(data, ops))
        stats['programs'] += 1
        stats[category] += 1
        stats['operations'] += len(ops)

    for signed in (0, 1):
        for bits in range(1, 65 if signed else 64):
            lo, hi = limits(signed, bits)
            values = sorted({MIN_I64, MAX_I64, -1, 0, 1, lo, hi, max(MIN_I64, lo - 1), min(MAX_I64, hi + 1)})
            for shift in range(8):
                offset = 8 + shift
                for mode in ('W', 'S', 'F'):
                    for code in ('S', 'I'):
                        for index, arg in enumerate(values):
                            initial = bytearray(rng.randbytes(18 if index % 2 else 9))
                            if offset + bits <= len(initial) * 8:
                                write_field(initial, bits, offset, (lo, hi, 0, 1, -1)[index % 5])
                            reset(initial)
                            program([(code, signed, bits, offset, arg, mode), ('G', signed, bits, offset, 0, 'W')])
    for length in (0, 1, 7, 8, 9, 16):
        for signed in (0, 1):
            for bits in (1, 8, 31, 63, 64) if signed else (1, 8, 31, 63):
                for shift in range(8):
                    reset(rng.randbytes(length))
                    program([('G', signed, bits, length * 8 + shift, 0, 'W')])
    reset(b'')
    program([('G', 0, 8, 0, 0, 'W'), ('G', 1, 64, 100, 0, 'W')])
    program([('S', 0, 8, 100, 300, 'F')])
    program([('S', 0, 8, 0, 0, 'W'), ('I', 0, 8, 0, 0, 'W')])
    program([('S', 0, 8, 200, 0, 'W'), ('S', 0, 8, 0, 0, 'W'), ('G', 0, 8, 0, 0, 'W')])
    program([('S', 0, 8, 0, 255, 'W'), ('I', 0, 8, 0, 1, 'F'), ('I', 0, 8, 0, 1, 'S')])
    program([('I', 0, 8, 0, 256, 'W'), ('S', 1, 8, 8, MIN_I64, 'S')])
    for bits, arg in ((8, MIN_I64 + 127), (8, MIN_I64 + 128), (1, MIN_I64 + 1)):
        reset(b'')
        program([('S', 1, bits, 0, arg, 'S'), ('G', 1, bits, 0, 0, 'W')])
    for _ in range(180):
        reset(rng.randbytes(rng.randrange(24)))
        for _ in range(5):
            ops = []
            for _ in range(rng.randrange(1, 7)):
                signed = rng.randrange(2)
                bits = rng.randrange(1, 65 if signed else 64)
                lo, hi = limits(signed, bits)
                arg = rng.choice((MIN_I64, MAX_I64, -1, 0, 1, lo, hi, rng.randrange(MIN_I64, MAX_I64 + 1)))
                ops.append((rng.choice(('G', 'S', 'I')), signed, bits, rng.randrange(280), arg, rng.choice(('W', 'S', 'F'))))
            program(ops, 'generated_programs')
    return '\n'.join(lines) + '\n', expected, stats


def compare(label, got, want):
    rows = got.splitlines()
    if len(rows) != len(want):
        raise AssertionError(f'{label}: {len(rows)} rows, expected {len(want)}')
    for i, (actual, expected) in enumerate(zip(rows, want)):
        if actual != expected:
            raise AssertionError(f'{label}: program {i}: actual {actual!r}, expected {expected!r}')


def check_fingerprints():
    pinned = json.loads((PACKAGE / 'source-sha256.json').read_text())
    for name, digest in pinned.items():
        current = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
        if current != digest:
            raise AssertionError(f'source fingerprint changed: {name}; review and reconcile the model before updating its gate')
    return pinned


def check_axioms(lake, output, env):
    expected = []
    for path in sorted((PACKAGE / 'Bitfield').glob('*.lean')):
        expected.extend('Bitfield.' + name for name in re.findall(r'^theorem\s+(\w+)', path.read_text(), re.M))
    manifest = re.findall(r'^#print axioms (\S+)', (PACKAGE / 'Bitfield.lean').read_text(), re.M)
    if sorted(expected) != sorted(manifest) or len(set(manifest)) != len(manifest):
        raise AssertionError('axiom manifest must list every theorem exactly once')
    result = subprocess.run([str(lake), 'env', 'lean', '-j1', 'Bitfield.lean'], cwd=PACKAGE,
                            env=env, text=True, capture_output=True, check=True)
    (output / 'axioms.txt').write_text(result.stdout + result.stderr)
    found = {}
    pattern = r"'([^']+)' (?:depends on axioms:\s*\[([^\]]*)\]|does not depend on any axioms)"
    cursor = 0
    for match in re.finditer(pattern, result.stdout):
        if result.stdout[cursor:match.start()].strip():
            raise AssertionError('unrecognized axiom audit output')
        name, entries = match.groups()
        if name in found:
            raise AssertionError(f'duplicate axiom result: {name}')
        found[name] = [s.strip() for s in entries.split(',') if s.strip()] if entries else []
        cursor = match.end()
    if result.stdout[cursor:].strip():
        raise AssertionError('unrecognized trailing axiom audit output')
    if set(found) != set(manifest) or result.stderr:
        raise AssertionError('incomplete or noisy axiom audit')
    allowed = {'propext', 'Classical.choice', 'Quot.sound'}
    for name, axioms in found.items():
        if set(axioms) - allowed:
            raise AssertionError(f'{name}: unapproved axioms {axioms}')
    return found


def build(output, lean_bin):
    env = dict(os.environ)
    env['LEAN_NUM_THREADS'] = '1'
    if lean_bin:
        env['PATH'] = str(lean_bin.resolve()) + os.pathsep + env.get('PATH', '')
    lake = shutil.which('lake', path=env.get('PATH'))
    lean = shutil.which('lean', path=env.get('PATH'))
    odin = shutil.which('odin', path=env.get('PATH'))
    if not lake or not lean or not odin:
        raise AssertionError('Lean 4.35.0, Lake, and Odin must be available; use --lean-bin for a local official toolchain')
    version = subprocess.run([lean, '--version'], env=env, text=True, capture_output=True, check=True).stdout
    if not re.search(r'\bversion 4\.35\.0\b', version):
        raise AssertionError(f'expected pinned Lean 4.35.0: {version}')
    commands = [([lake, 'build'], PACKAGE),
                ([odin, 'build', str(PACKAGE / 'bridge.odin'), '-file',
                  '-out:' + str(output / 'odin_bridge'), '-thread-count:2', '-vet', '-strict-style'], ROOT)]
    logs = []
    for command, cwd in commands:
        result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
        logs.append(result.stdout + result.stderr)
        (output / 'build.txt').write_text('\n'.join(logs))
        if result.returncode:
            raise AssertionError(f'build failed; see {output / "build.txt"}\n{logs[-1]}')
    audit = check_axioms(Path(lake), output, env)
    odin_version = subprocess.run([odin, 'version'], env=env, text=True, capture_output=True, check=True).stdout
    versions = {'lean': version.strip(), 'odin': odin_version.strip()}
    return PACKAGE / '.lake/build/bin/bitfield_model', output / 'odin_bridge', audit, versions


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('--lean-bin', type=Path, default=Path(os.environ['LEAN_BIN_DIR']) if 'LEAN_BIN_DIR' in os.environ else None)
    parser.add_argument('--output', type=Path, default=PACKAGE / '.build')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    args.output = args.output.resolve()
    (args.output / 'receipt.json').unlink(missing_ok=True)
    if hasattr(os, 'sched_getaffinity'):
        os.sched_setaffinity(0, {min(os.sched_getaffinity(0))})
    if hasattr(os, 'nice'):
        os.nice(10)
    fingerprints = check_fingerprints()
    lean_model, odin_model, audit, versions = build(args.output, args.lean_bin)
    trace, expected, stats = corpus()
    path = args.output / 'traces.txt'
    path.write_text(trace)
    outputs = {}
    for name, binary in (('lean', lean_model), ('odin', odin_model)):
        result = subprocess.run([str(binary.resolve()), str(path.resolve())], text=True, capture_output=True, check=True)
        if result.stderr:
            raise AssertionError(f'{name}: unexpected stderr: {result.stderr}')
        compare(name, result.stdout, expected)
        (args.output / f'{name}-results.txt').write_text(result.stdout)
        outputs[name] = hashlib.sha256(result.stdout.encode()).hexdigest()
    rejected = []
    for column, label in enumerate(('dirty', 'bytes', 'reply')):
        mutant = list(expected)
        parts = mutant[0].split('|')
        parts[column] = str(int(parts[0]) + 1) if column == 0 else 'controlled-bad-result'
        mutant[0] = '|'.join(parts)
        try:
            compare('controlled-' + label + '-mutant', '\n'.join(mutant) + '\n', expected)
        except AssertionError:
            rejected.append(label)
        else:
            raise AssertionError(f'comparison failed to reject the controlled {label} mutant')
    stats['controlled_mutants_rejected'] = rejected
    receipt = {**stats, 'seed': '0xE5A1B17', 'toolchain': (PACKAGE / 'lean-toolchain').read_text().strip(),
               'source_sha256': fingerprints, 'trace_sha256': hashlib.sha256(trace.encode()).hexdigest(),
               'results_sha256': outputs, 'checked_theorem_axioms': audit, 'versions': versions,
               'executable_sha256': {name: hashlib.sha256(binary.read_bytes()).hexdigest()
                                     for name, binary in (('lean', lean_model), ('odin', odin_model))}}
    (args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    run()
