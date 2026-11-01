import argparse
import fcntl
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from kernel_audit import audit as audit_kernel

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().parent
MAX = (1 << 63) - 1
MASK = (1 << 64) - 1


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def key_hash(key):
    data = f'{key:07d}'.encode()
    a = (int.from_bytes(data[:4], 'little') << 32) | int.from_bytes(data[:4], 'little')
    b = (int.from_bytes(data[-4:], 'little') << 32) | int.from_bytes(data[-4:], 'little')
    product = (a ^ 0x8BB84B93962EACC9) * b
    lo, hi = product & MASK, product >> 64
    product = (lo ^ 0x2D358DCCAA6C78A5 ^ len(data)) * (hi ^ 0x8BB84B93962EACC9)
    return ((product & MASK) ^ (product >> 64)) & MASK


def cell_text(cell):
    if cell is None:
        return '-'
    if cell is False:
        return 'x'
    key, _, value, expiry, clock = cell
    return f'{key}:{value}:{expiry}:{clock}'


def table_text(slots):
    live = sum(isinstance(c, tuple) for c in slots)
    tombs = sum(c is False for c in slots)
    cap = len(slots)
    return f'{cap},{live},{tombs},{cap - cap // 8 - live - tombs};' + ','.join(map(cell_text, slots))


def corpus():
    rng = random.Random(0xE5A1506)
    lines, expected = [], []
    stats = {'table_operations': 0, 'accounting_operations': 0, 'resizes': 0,
             'partial_batches': 0, 'zero_budget_batches': 0, 'queries': 0,
             'deletions': 0, 'same_home_and_tag_keys': 0, 'rollback_record_seed_failures': 0, 'rejected_free_ownership_checks': 0}
    src, dst, cursor, logical = [], [], -1, {}
    tokens, limit, initialized = {}, 0, False

    def claim(slots, entry):
        groups = len(slots) // 16
        home = (entry[1] >> 7) % groups
        for step in range(groups):
            group = (home + step * (step + 1) // 2) % groups
            for i in range(group * 16, (group + 1) * 16):
                if not isinstance(slots[i], tuple):
                    slots[i] = entry
                    return
        raise AssertionError('invalid corpus destination capacity')

    def step(code, *args):
        nonlocal src, dst, cursor, logical, tokens, limit, initialized
        lines.append(' '.join(map(str, (code,) + args)))
        if code == 'R':
            src, dst, cursor, logical = [None] * args[0], [], -1, {}
            return
        if code == 'A':
            assert not tokens
            limit, initialized = args[0], bool(args[1])
            return
        if code in ('E', 'P', 'L', 'F', 'N', 'W', 'Z'):
            ok = False
            used = sum(tokens.values())
            if code in ('E', 'P'):
                ident, size = args
                assert ident not in tokens
                charge = size + 32 if code == 'P' else size
                valid = size > 0 and size <= MAX - 32 if code == 'P' else size >= 0
                ok = initialized and valid and charge <= limit - used
                if ok:
                    tokens[ident] = charge
            elif code in ('L', 'F'):
                ok = args[0] in tokens
                if ok:
                    del tokens[args[0]]
            elif code in ('W', 'Z'):
                assert args[0] in tokens
                stats['rejected_free_ownership_checks'] += 1
            else:
                assert used == 0
                stats['rollback_record_seed_failures'] += 1
            expected.append(f'K|{int(ok)}|{sum(tokens.values())}')
            stats['accounting_operations'] += 1
            return
        reply = '0'
        if code in ('I', 'D', 'Q'):
            key, hashed = args[:2]
            assert hashed == key_hash(key)
            found = next(((bank, i) for bank in (src, dst) for i, c in enumerate(bank)
                          if isinstance(c, tuple) and c[0] == key), None)
            if code == 'I':
                entry = args
                reply = str(int(found is None))
                if found:
                    found[0][found[1]] = entry
                else:
                    claim(dst if cursor >= 0 else src, entry)
                logical[key] = entry
            elif code == 'D':
                stats['deletions'] += 1
                if found:
                    reply = '1'
                    bank, i = found
                    group = bank[(i // 16) * 16:(i // 16 + 1) * 16]
                    bank[i] = None if any(c is None for c in group) else False
                    del logical[key]
            else:
                reply = cell_text(logical[key]) if key in logical else 'n'
                stats['queries'] += 1
        elif code == 'G':
            assert cursor < 0
            assert len(logical) <= args[0] * 7 // 8
            dst, cursor = [None] * args[0], 0
            stats['resizes'] += 1
        elif code == 'M':
            max_groups, want = args
            if want == 0 or max_groups == 0:
                stats['zero_budget_batches'] += 1
            if cursor >= 0:
                moved = visited = 0
                groups = len(src) // 16
                while cursor < groups and moved < want and visited < max_groups:
                    occupied = [i for i in range(cursor * 16, (cursor + 1) * 16)
                                if isinstance(src[i], tuple)]
                    chosen = occupied[:want - moved]
                    for i in chosen:
                        claim(dst, src[i])
                        src[i] = False
                    moved += len(chosen)
                    if len(chosen) < len(occupied):
                        stats['partial_batches'] += 1
                        break
                    cursor += 1
                    visited += 1
                if cursor >= groups or not any(isinstance(c, tuple) for c in src):
                    src, dst, cursor = dst, [], -1
        else:
            raise AssertionError(code)
        physical = [c for c in src + dst if isinstance(c, tuple)]
        assert len(physical) == len(logical) and {e[0]: e for e in physical} == logical
        expected.append(f'T|{reply}|{cursor}|{table_text(src)}|{table_text(dst)}')
        stats['table_operations'] += 1

    collision_keys = []
    for key in range(1, 150000):
        h = key_hash(key)
        if (h >> 7) % 4 == 3 and h % 128 == 31:
            collision_keys.append(key)
            if len(collision_keys) == 40:
                break
    assert len(collision_keys) == 40
    stats['same_home_and_tag_keys'] = len(collision_keys)
    for scenario in range(42):
        step('R', 64)
        keys = collision_keys if scenario < 3 else rng.sample(range(1, 100000), 40)
        for index, key in enumerate(keys):
            step('I', key, key_hash(key), MASK if index % 3 == 0 else rng.randrange(1 << 32),
                 ((1 << 48) - 1) if index % 4 == 0 else index * 100, 65535 if index % 5 == 0 else index)
        for key in keys[::7]:
            step('D', key, key_hash(key))
        for key in keys:
            step('Q', key, key_hash(key))
        step('G', 128)
        step('M', 0, 1)
        step('M', 1, 0)
        for iteration in range(30):
            key = rng.choice(keys)
            if iteration % 4 == 0:
                step('I', key, key_hash(key), iteration + 1, iteration * 222, iteration)
            elif iteration % 4 == 1:
                step('D', key, key_hash(key))
            step('M', 1 + iteration % 2, 1 + iteration % 5)
            step('Q', key, key_hash(key))
        step('M', MAX, MAX)
        assert cursor == -1
        step('G', 64)
        for _ in range(8):
            step('M', 1, 2)
        step('M', MAX, MAX)
        for key in keys:
            step('Q', key, key_hash(key))
    for cap in (16, 32, 64, 128):
        step('R', cap)
        step('G', 16)
        step('M', 0, 0)
        assert cursor == -1
    next_id = 1
    for initialized_case in (0, 1):
        for budget in (0, 1, 32, 33, 64, 127, 1024, MAX):
            step('A', budget, initialized_case)
            for size in (-1, 0, 1, 31, 32, 33, min(budget, 4096), MAX - 32, MAX):
                for code in ('E', 'P'):
                    if code == 'P' and size > 4096 and size <= MAX - 32 and budget == MAX and initialized_case:
                        continue
                    ident = next_id
                    next_id += 1
                    step(code, ident, size)
                    if ident in tokens:
                        step('L' if code == 'E' else 'F', ident)
            assert not tokens
    for _ in range(12):
        step('A', 1024, 1)
        active = {}
        ident = next_id
        next_id += 1
        step('P', ident, 32)
        step('W', ident)
        step('Z', ident)
        step('F', ident)
        for _ in range(90):
            if active and rng.randrange(3) == 0:
                ident = rng.choice(list(active))
                step(active.pop(ident), ident)
            else:
                code = rng.choice(('E', 'P'))
                ident = next_id
                next_id += 1
                step(code, ident, rng.randrange(0, 500))
                if ident in tokens:
                    active[ident] = 'L' if code == 'E' else 'F'
        for ident, code in active.items():
            step(code, ident)
        step('N')
    stats['rows'] = len(expected)
    assert stats['table_operations'] > 5000 and stats['accounting_operations'] > 1000
    assert stats['partial_batches'] > 0 and stats['zero_budget_batches'] > 0
    return '\n'.join(lines) + '\n', expected, stats


def compare(label, got, expected):
    rows = got.splitlines()
    if not expected or len(rows) != len(expected):
        raise AssertionError(f'{label}: row count {len(rows)} != {len(expected)}')
    for i, (a, b) in enumerate(zip(rows, expected)):
        if a != b:
            raise AssertionError(f'{label}: row {i}: {a!r} != {b!r}')


def source_gate():
    pinned = json.loads((PACKAGE / 'source-sha256.json').read_text())
    if len(pinned) < 7:
        raise AssertionError('missing source drift gates')
    for name, wanted in pinned.items():
        if digest(ROOT / name) != wanted:
            raise AssertionError(f'source changed: {name}; reconcile the contracts before updating the gate')
    return pinned


def audit_axioms(lake, env, output):
    return audit_kernel(lake, PACKAGE, output, env, "Storage")


def procedure(text, name):
    start = text.index(name + ' ::')
    brace = text.index('{', start)
    depth, quoted, escaped = 1, False, False
    i = brace + 1
    while depth:
        c = text[i]
        if quoted:
            if escaped:
                escaped = False
            elif c == '\\':
                escaped = True
            elif c == '"':
                quoted = False
        elif c == '"':
            quoted = True
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
        i += 1
    return text[start:i] + '\n'


def overlay(output):
    target = output / 'overlay'
    target.mkdir(exist_ok=True)
    provenance = {}
    for name in ('table', 'hash'):
        original = ROOT / f'src/{name}.odin'
        shutil.copyfile(original, target / original.name)
        provenance[original.name] = {'source': f'src/{name}.odin', 'sha256': digest(original), 'whole_file': True}
    value = (ROOT / 'src/value.odin').read_text()
    prefix = value[:value.index('string_encoding_of ::')]
    (target / 'value_types.odin').write_text(prefix)
    provenance['value_types.odin'] = {'source': 'src/value.odin', 'sha256': hashlib.sha256(prefix.encode()).hexdigest(), 'whole_file': False, 'slice': [0, len(prefix.encode())]}
    source = (ROOT / 'src/store.odin').read_text()
    snippets = []
    for name in ('db_locate', 'db_rehash_swap', 'db_rehash_groups'):
        snippet = procedure(source, name)
        snippets.append(snippet)
        provenance[name] = {'source': 'src/store.odin', 'sha256': hashlib.sha256(snippet.encode()).hexdigest(), 'whole_file': False, 'exact_procedure': name}
    template = (PACKAGE / 'bridge.odin').read_text().replace('@KEYSPACE@', os.path.relpath(ROOT / 'src/keyspace', target))
    (target / 'main.odin').write_text(template + '\n' + '\n'.join(snippets))
    (output / 'overlay-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    return target, provenance


def build(lean_bin, output):
    env = dict(os.environ, LEAN_NUM_THREADS='1')
    if lean_bin:
        env['PATH'] = str(lean_bin.resolve()) + os.pathsep + env.get('PATH', '')
    paths = {name: shutil.which(name, path=env.get('PATH')) for name in ('lean', 'lake', 'odin')}
    if not all(paths.values()):
        raise AssertionError('Lean, Lake and Odin required; use --lean-bin or LEAN_BIN_DIR')
    versions = {name: subprocess.run([paths[name], '--version' if name == 'lean' else 'version'],
                                   env=env, text=True, capture_output=True, check=True).stdout.strip()
                for name in ('lean', 'odin')}
    if not re.search(r'\bversion 4\.35\.0\b', versions['lean']):
        raise AssertionError('expected official pinned Lean 4.35.0')
    target, provenance = overlay(output)
    commands = [([paths['lake'], 'build'], PACKAGE),
                ([paths['odin'], 'build', str(target), '-out:' + str(output / 'odin_bridge'),
                  '-thread-count:2', '-vet', '-strict-style'], ROOT)]
    lock = ROOT / '.build/proofs/compiler.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    logs = []
    with lock.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        for command, cwd in commands:
            result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
            logs.append(result.stdout + result.stderr)
            (output / 'build.txt').write_text('\n'.join(logs))
            if result.returncode:
                raise AssertionError('build failed:\n' + logs[-1])
        axioms, kernel = audit_axioms(paths['lake'], env, output)
    binaries = {'lean': PACKAGE / '.lake/build/bin/storage_model', 'odin': output / 'odin_bridge'}
    return binaries, axioms, versions, provenance, {k: digest(Path(v)) for k, v in paths.items()}, kernel


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('--lean-bin', type=Path, default=Path(os.environ['LEAN_BIN_DIR']) if 'LEAN_BIN_DIR' in os.environ else None)
    parser.add_argument('--output', type=Path, default=PACKAGE / '.build')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / 'receipt.json').unlink(missing_ok=True)
    os.nice(10)
    os.sched_setaffinity(0, {min(os.sched_getaffinity(0))})
    fingerprints = source_gate()
    binaries, axioms, versions, provenance, tools, kernel = build(args.lean_bin, output)
    trace, expected, stats = corpus()
    path = output / 'traces.txt'
    path.write_text(trace)
    results = {}
    for name, binary in binaries.items():
        result = subprocess.run([str(binary.resolve()), str(path)], text=True, capture_output=True, check=True)
        if result.stderr:
            raise AssertionError(f'{name}: unexpected stderr: {result.stderr}')
        compare(name, result.stdout, expected)
        (output / f'{name}-results.txt').write_text(result.stdout)
        results[name] = hashlib.sha256(result.stdout.encode()).hexdigest()
    negatives = []
    cases = {'empty': '', 'truncated': '\n'.join(expected[:-1]) + '\n', 'extra': '\n'.join(expected + [expected[0]]) + '\n'}
    for column in range(5):
        mutated = list(expected)
        cells = mutated[0].split('|')
        cells[column] = 'controlled-mutant'
        mutated[0] = '|'.join(cells)
        cases[f'table_column_{column}'] = '\n'.join(mutated) + '\n'
    accounting_row = next(i for i, row in enumerate(expected) if row.startswith('K|'))
    for column in (1, 2):
        mutated = list(expected)
        cells = mutated[accounting_row].split('|')
        cells[column] = 'controlled-mutant'
        mutated[accounting_row] = '|'.join(cells)
        cases[f'accounting_column_{column}'] = '\n'.join(mutated) + '\n'
    for name, mutant in cases.items():
        try:
            compare(name, mutant, expected)
        except AssertionError:
            negatives.append(name)
        else:
            raise AssertionError('negative control accepted: ' + name)
    ledger_names = {'Storage.' + n for n in re.findall(r'^theorem\s+(\w+)', (PACKAGE / 'Storage/Ledger.lean').read_text(), re.M)}
    area_evidence = {'1': {'theorems': sorted(set(axioms) - ledger_names), 'comparisons': stats['table_operations']},
                     '6': {'theorems': sorted(ledger_names), 'comparisons': stats['accounting_operations']}}
    receipt = {**stats, 'area_evidence': area_evidence, 'seed': '0xE5A1506', 'checked_theorem_axioms': axioms, 'kernel_inventory_sha256': digest(output / 'kernel-inventory.json'),
               'kernel_checked_theorems': len(kernel['theorem_axioms']),
               'source_sha256': fingerprints, 'versions': versions, 'tool_sha256': tools,
               'overlay_provenance': provenance, 'trace_sha256': hashlib.sha256(trace.encode()).hexdigest(),
               'results_sha256': results, 'executable_sha256': {n: digest(p) for n, p in binaries.items()},
               'proof_source_sha256': {str(p.relative_to(PACKAGE)): digest(p) for p in PACKAGE.rglob('*')
                                       if p.is_file() and '.lake' not in p.parts and '.build' not in p.parts and '__pycache__' not in p.parts},
               'negative_controls_rejected': negatives}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({**stats, 'theorems': len(axioms), 'receipt': str(output / 'receipt.json')}, indent=2))


if __name__ == '__main__':
    run()
