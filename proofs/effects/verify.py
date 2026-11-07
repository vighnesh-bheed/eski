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
ALLOWED_AXIOMS = {'propext', 'Classical.choice', 'Quot.sound'}
SEED = 0xE5A1EFFE


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hash_text(state, now=None):
    return ''.join(f'{f}={v}@{deadline},' for f, (v, deadline) in sorted(state.items())
                   if now is None or deadline == 0 or now <= deadline)


def allowed(condition, old, deadline):
    return {'ANY': True, 'NX': old == 0, 'XX': old != 0,
            'GT': old != 0 and deadline > old, 'LT': old == 0 or deadline < old}[condition]


def oracle_operation(state, args, now):
    commands = []
    opcode = args[0]
    if opcode == 'B':
        deadline, condition = int(args[1]), args[2]
        for field in args[3:]:
            commands.extend(oracle_operation(state, ['X', field, str(deadline), condition], now))
        return commands
    f = int(args[1])
    if opcode in ('W', 'F'):
        deadline = int(args[3]) if opcode == 'F' else 0
        state[f] = (args[2], deadline)
        commands.append(f'W,{f},{args[2]}')
        if deadline:
            if deadline <= now:
                raise AssertionError('float final deadline must be future or persistent')
            commands.append(f'X,{f},{deadline}')
    elif opcode == 'X' and f in state:
        deadline = int(args[2])
        value, old = state[f]
        if allowed(args[3], old, deadline):
            if deadline <= now:
                del state[f]
                commands.append(f'D,{f}')
            else:
                state[f] = (value, deadline)
                commands.append(f'X,{f},{deadline}')
    elif opcode == 'P' and f in state:
        value, deadline = state[f]
        if deadline and now <= deadline:
            state[f] = (value, 0)
            commands.append(f'P,{f}')
    elif opcode == 'D' and f in state:
        del state[f]
        commands.append(f'D,{f}')
    elif opcode == 'G' and f in state:
        value, deadline = state[f]
        if deadline and deadline < now:
            del state[f]
            commands.append(f'D,{f}')
    return commands


def rollback_expected():
    before = 'old0:true:71:false:false:true:9000:1:0:true:123;old1:true:72:true:true:false:10000:2:0:false:456'
    after = 'c:true:71:true:true:false:0:2:0:true:0;b:true:72:true:true:false:0:2:0:false:0'
    return [f'K0|true|false|{before}|0|0|0', f'K1|true|true|{before}|0|0|0',
            f'K2|false|false|{after}|3|6|2', 'OBJECT|restored|aliases|metadata|balanced']


def key_expected():
    commands = ['KS,final,1250', 'KS,final,1001', 'KK,final', 'KK,final', 'KX,1250', 'KD', 'KP', 'KD', 'KD', 'KS,final,1001']
    return [f'KEY{i}|{command}' for i, command in enumerate(commands)]


def normalize_key(argv):
    if argv[:2] == ['SET', 'key'] and len(argv) == 5 and argv[3] == 'PXAT':
        return f'KS,{argv[2]},{int(argv[4])}'
    if argv[:2] == ['SET', 'key'] and len(argv) == 4 and argv[3] == 'KEEPTTL':
        return f'KK,{argv[2]}'
    if argv[:2] == ['PEXPIREAT', 'key'] and len(argv) == 3:
        return f'KX,{int(argv[2])}'
    if argv == ['PERSIST', 'key']:
        return 'KP'
    if argv == ['DEL', 'key']:
        return 'KD'
    raise AssertionError(f'unexpected key translation {argv}')


def check_key_replay(mode, command):
    before = ('final', 0 if mode == 3 else 5000)
    kind, *args = command.split(',')
    if kind == 'KD':
        actual = None
    elif kind == 'KP':
        actual = (before[0], 0)
    elif kind == 'KK':
        actual = (args[0], before[1])
    elif kind == 'KS':
        actual = (args[0], int(args[1])) if int(args[1]) > 1000 else None
    elif kind == 'KX':
        actual = (before[0], int(args[0])) if int(args[0]) > 1000 else None
    else:
        raise AssertionError('invalid normalized key command')
    after = [('final', 1250), ('final', 1001), ('final', 5000), ('final', 0),
             ('final', 1250), None, ('final', 0), None, None, ('final', 1001)][mode]
    if actual != after:
        raise AssertionError(f'key replay differs for fixture {mode}')

def corpus():
    rng = random.Random(SEED)
    lines, expected, steps = [], [], []
    state = {}
    now = 1000
    stats = {'expiry_steps': 0, 'generated_steps': 0, 'boundary_steps': 0, 'resets': 0}

    def directive(line):
        nonlocal state, now
        fields = line.split()
        lines.append(line)
        if fields[0] == 'R':
            state, now = {}, int(fields[2])
            stats['resets'] += 1
        else:
            now = int(fields[1])

    def operation(line, category='boundary_steps'):
        before = dict(state)
        commands = oracle_operation(state, line.split(), now)
        expected.append(f'{hash_text(state)}|{";".join(commands)}|{hash_text(state, now)}')
        steps.append((before, dict(state), now))
        lines.append(line)
        stats['expiry_steps'] += 1
        stats[category] += 1

    for table in (0, 1):
        for condition in ('ANY', 'NX', 'XX', 'GT', 'LT'):
            for old in (0, 999, 1000, 1001, 2000):
                for deadline in (0, 999, 1000, 1001, 1999, 2000, 2001, 10**12):
                    directive(f'R {table} 1')
                    operation('W 0 initial')
                    if old:
                        operation(f'X 0 {old} ANY')
                    directive('T 1000')
                    operation(f'X 0 {deadline} {condition}')
                    operation('P 0')
                    operation('G 0')
        directive(f'R {table} 1000')
        for f in range(4):
            operation(f'W {f} value{f}')
        operation('X 0 2000 ANY')
        operation('B 2001 NX 0 1 7 1 2')
        operation('B 1000 XX 0 1 3 7 0')
        operation('B 5000 ANY 2 3 4 5 2')
        operation('F 2 3.1415926535897932384626 7000')
        operation('F 2 -0 0')
        operation('X 3 2000 ANY')
        directive('T 1999'); operation('G 3')
        directive('T 2000'); operation('G 3'); operation('P 3')
        operation('X 3 2001 ANY')
        directive('T 2002'); operation('P 3'); operation('G 3')
        operation('D 2'); operation('D 2')
        for _ in range(75):
            directive(f'R {table} 1000')
            for _ in range(40):
                f = rng.randrange(8)
                code = rng.choice(('W', 'W', 'F', 'X', 'X', 'P', 'D', 'G', 'B'))
                if code == 'W':
                    line = f'W {f} {rng.choice(("a", "3.5", "-0", "001", "1e300", "long_value"))}'
                elif code == 'F':
                    line = f'F {f} {rng.choice(("3.5", "-0.00001", "1e300"))} {rng.choice((0, 1001, 2000, 10**12))}'
                elif code == 'X':
                    line = f'X {f} {rng.choice((0, 1, 999, 1000, 1001, 2000, 10**12))} {rng.choice(("ANY", "NX", "XX", "GT", "LT"))}'
                elif code == 'B':
                    line = f'B {rng.choice((0, 999, 1000, 1001, 2000))} {rng.choice(("ANY", "NX", "XX", "GT", "LT"))} ' + ' '.join(str(rng.randrange(8)) for _ in range(rng.randrange(1, 7)))
                else:
                    line = f'{code} {f}'
                operation(line, 'generated_steps')
    return '\n'.join(lines) + '\n', expected, steps, stats


def resp_commands(data):
    commands = []
    cursor = 0

    def line():
        nonlocal cursor
        end = data.find(b'\r\n', cursor)
        if end < 0:
            raise AssertionError('truncated RESP line')
        out, cursor = data[cursor:end], end + 2
        return out

    while cursor < len(data):
        header = line()
        if not re.fullmatch(rb'\*[1-9][0-9]*', header):
            raise AssertionError('invalid RESP command header')
        argv = []
        for _ in range(int(header[1:])):
            header = line()
            if not re.fullmatch(rb'\$[0-9]+', header):
                raise AssertionError('invalid RESP bulk header')
            size = int(header[1:])
            if cursor + size + 2 > len(data) or data[cursor + size:cursor + size + 2] != b'\r\n':
                raise AssertionError('truncated RESP bulk')
            argv.append(data[cursor:cursor + size].decode())
            cursor += size + 2
        commands.append(argv)
    return commands


def normalize(commands):
    out = []
    for argv in commands:
        name = argv[0]
        if name == 'HSET' and len(argv) == 4 and argv[1] == 'key':
            out.append(f'W,{int(argv[2])},{argv[3]}')
        elif name == 'HPEXPIREAT' and len(argv) >= 6 and argv[1] == 'key':
            marker = argv.index('FIELDS')
            count = int(argv[marker + 1])
            if count <= 0 or len(argv) != marker + 2 + count:
                raise AssertionError('invalid HFE translated field count')
            out.extend(f'X,{int(f)},{int(argv[2])}' for f in argv[marker + 2:])
        elif name == 'HPERSIST' and len(argv) >= 5 and argv[1:3] == ['key', 'FIELDS']:
            if int(argv[3]) != len(argv) - 4:
                raise AssertionError('invalid persist field count')
            out.extend(f'P,{int(f)}' for f in argv[4:])
        elif name == 'HDEL' and len(argv) >= 3 and argv[1] == 'key':
            out.extend(f'D,{int(f)}' for f in argv[2:])
        else:
            raise AssertionError(f'unexpected translated command: {argv}')
    return ';'.join(out)


def replay_python(before, commands, now):
    state = dict(before)
    for command in commands.split(';') if commands else []:
        fields = command.split(',')
        f = int(fields[1])
        if fields[0] == 'W':
            state[f] = (fields[2], 0)
        elif fields[0] == 'D':
            state.pop(f, None)
        elif fields[0] == 'X' and f in state:
            value, _ = state[f]
            deadline = int(fields[2])
            if deadline <= now:
                del state[f]
            else:
                state[f] = (value, deadline)
        elif fields[0] == 'P' and f in state:
            value, deadline = state[f]
            if not deadline or now <= deadline:
                state[f] = (value, 0)
    return state


def compare(label, actual, expected):
    rows = actual.splitlines()
    if len(rows) != len(expected):
        raise AssertionError(f'{label}: got {len(rows)} rows, expected {len(expected)}')
    for i, (got, want) in enumerate(zip(rows, expected)):
        if got != want:
            raise AssertionError(f'{label}: row {i}: {got!r} != {want!r}')


def check_sources():
    pinned = json.loads((PACKAGE / 'source-sha256.json').read_text())
    current = {str(p.relative_to(ROOT)): digest(p) for p in sorted((ROOT / 'src').rglob('*')) if p.is_file()}
    if current != pinned:
        changed = sorted(k for k in current.keys() | pinned.keys() if current.get(k) != pinned.get(k))
        raise AssertionError(f'source drift: {changed}; review contracts before updating pins')
    return pinned


def parse_axioms(stdout, manifest):
    pattern = r"'([^']+)' (?:depends on axioms:\s*\[([^\]]*)\]|does not depend on any axioms)"
    found, cursor = {}, 0
    for match in re.finditer(pattern, stdout):
        if stdout[cursor:match.start()].strip():
            raise AssertionError('unrecognized axiom audit output')
        name, entries = match.groups()
        if name in found:
            raise AssertionError('duplicate axiom output')
        found[name] = [s.strip() for s in entries.split(',') if s.strip()] if entries else []
        if set(found[name]) - ALLOWED_AXIOMS:
            raise AssertionError(f'unapproved axiom in {name}: {found[name]}')
        cursor = match.end()
    if stdout[cursor:].strip() or set(found) != set(manifest):
        raise AssertionError('incomplete or noisy axiom manifest')
    return found


def check_axioms(lake, env, output):
    return audit_kernel(lake, PACKAGE, output, env, "Effects")


def negative_axiom_fixtures(lake, env, output):
    directory = output / 'negative-audit'
    directory.mkdir(exist_ok=True)
    fixtures = {
        'custom': 'namespace Effects\naxiom fixtureAxiom : False\ntheorem fixture : False := fixtureAxiom\nend Effects\n#print axioms Effects.fixture\n',
        'admitted': 'set_option warn.sorry false\nnamespace Effects\ntheorem fixture : False := by sorry\nend Effects\n#print axioms Effects.fixture\n',
    }
    evidence = {}
    for name, source in fixtures.items():
        path = directory / (name + '.lean')
        path.write_text(source)
        result = subprocess.run([lake, 'env', 'lean', '-j1', str(path)], cwd=PACKAGE, env=env,
                                capture_output=True, text=True, check=True)
        (directory / (name + '.txt')).write_text(result.stdout + result.stderr)
        if result.stderr:
            raise AssertionError('unexpected negative fixture diagnostics')
        try:
            parse_axioms(result.stdout, ['Effects.fixture'])
        except AssertionError as error:
            if not str(error).startswith('unapproved axiom'):
                raise
            evidence[name] = {'compiled': True, 'rejected': str(error), 'source_sha256': digest(path),
                              'printed_manifest_sha256': hashlib.sha256(result.stdout.encode()).hexdigest()}
        else:
            raise AssertionError('compiled invalid proof fixture accepted by axiom gate')
    (output / 'negative-axioms.json').write_text(json.dumps(evidence, indent=2) + '\n')

def build(output, lean_bin):
    env = dict(os.environ, LEAN_NUM_THREADS='1')
    if lean_bin:
        env['PATH'] = str(lean_bin.resolve()) + os.pathsep + env.get('PATH', '')
    binaries = {name: shutil.which(name, path=env.get('PATH')) for name in ('lean', 'lake', 'odin')}
    if not all(binaries.values()):
        raise AssertionError('requires pinned Lean 4.35.0, Lake and repository Odin toolchain')
    versions = {}
    for name, argument in (('lean', '--version'), ('lake', '--version'), ('odin', 'version')):
        versions[name] = subprocess.run([binaries[name], argument], env=env, capture_output=True,
                                        text=True, check=True).stdout.strip()
    if not re.search(r'\bversion 4\.35\.0\b', versions['lean']):
        raise AssertionError('requires pinned Lean 4.35.0')
    overlay = output / 'overlay'
    if overlay.exists():
        shutil.rmtree(overlay)
    shutil.copytree(ROOT / 'src', overlay / 'src')
    (overlay / 'src/main.odin').unlink()
    for path in (overlay / 'src').glob('*_test.odin'):
        path.unlink()
    shutil.copyfile(PACKAGE / 'bridge.odin', overlay / 'src/proof_bridge.odin')
    (overlay / '.build').symlink_to(ROOT / '.build', target_is_directory=True)
    copied = {str(p.relative_to(overlay)): digest(p) for p in sorted((overlay / 'src').rglob('*')) if p.is_file()}
    for name, sha in copied.items():
        if name != 'src/proof_bridge.odin' and sha != digest(ROOT / name):
            raise AssertionError('overlay source identity failure')
    link_inputs = [ROOT / '.build/diagnostics/release/libeski-diagnostics.a', ROOT / '.build/diagnostics/libunwind.so',
                   ROOT / '.build/lua/release/libeslua-runtime.a']
    link_hashes = {str(p.relative_to(ROOT)): digest(p) for p in link_inputs}
    lock = ROOT / '.build/proofs/compiler.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    logs = []
    with lock.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        for command, cwd in (([binaries['lake'], 'build'], PACKAGE),
                             ([binaries['odin'], 'build', str(overlay / 'src'), '-out:' + str(output / 'odin_bridge'),
                               '-thread-count:2', '-vet', '-strict-style'], ROOT)):
            result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True)
            logs.append(result.stdout + result.stderr)
            (output / 'build.txt').write_text('\n'.join(logs))
            if result.returncode:
                raise AssertionError(f'build failed: {logs[-1]}')
        audit, kernel = check_axioms(binaries['lake'], env, output)
        negative_axiom_fixtures(binaries['lake'], env, output)
    if any(digest(ROOT / name) != sha for name, sha in link_hashes.items()):
        raise AssertionError('prebuilt native inputs changed during check')
    (output / 'overlay-sha256.json').write_text(json.dumps(copied, indent=2) + '\n')
    tool_hashes = {name: digest(Path(path).resolve()) for name, path in binaries.items()}
    return PACKAGE / '.lake/build/bin/effects_model', output / 'odin_bridge', audit, versions, tool_hashes, link_hashes, kernel


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
    sources = check_sources()
    lean, odin, audit, versions, tools, native_inputs, kernel = build(output, args.lean_bin)
    trace, expected, steps, stats = corpus()
    path = output / 'traces.txt'
    path.write_text(trace)
    boundary_fixtures = ['BOUNDARY0|live|persist|stale-min|active-removed|ttl:0', 'BOUNDARY1|live|persist|stale-min|active-removed|ttl:0']
    normal_error = ['COMMAND_ERROR|ERR|value-preserved|deadline-preserved|dirty:0']
    wanted = rollback_expected() + key_expected() + normal_error + boundary_fixtures + expected
    results = {}
    for label, binary in (('lean', lean), ('odin', odin)):
        result = subprocess.run([str(binary.resolve()), str(path)], capture_output=True, text=True, check=True)
        if result.stderr:
            raise AssertionError(f'{label}: unexpected stderr: {result.stderr}')
        (output / f'{label}-raw.txt').write_text(result.stdout)
        if label == 'odin':
            rows = result.stdout.splitlines()
            if len(rows) != len(wanted):
                raise AssertionError('Odin bridge row count mismatch')
            normalized = rows[:4]
            for mode, row in enumerate(rows[4:14]):
                key_label, encoded = row.split('|')
                commands = resp_commands(bytes.fromhex(encoded))
                if len(commands) != 1 or key_label != f'KEY{mode}':
                    raise AssertionError('key fixture output mismatch')
                command = normalize_key(commands[0])
                check_key_replay(mode, command)
                normalized.append(f'{key_label}|{command}')
            normalized.extend(rows[14:17])
            for i, row in enumerate(rows[17:]):
                state, encoded, live = row.split('|')
                commands = normalize(resp_commands(bytes.fromhex(encoded)))
                before, after, now = steps[i]
                if replay_python(before, commands, now) != after:
                    raise AssertionError(f'Odin translation replay mismatch at step {i}')
                normalized.append(f'{state}|{commands}|{live}')
            actual = '\n'.join(normalized) + '\n'
        else:
            actual = result.stdout
        compare(label, actual, wanted)
        (output / f'{label}-results.txt').write_text(actual)
        results[label] = hashlib.sha256(actual.encode()).hexdigest()
    rejected = []
    mutants = {'missing-row': wanted[:-1], 'extra-row': wanted + [wanted[-1]]}
    for index, name in enumerate(('physical-state', 'translated-command', 'live-view')):
        mutant = list(wanted)
        columns = mutant[17].split('|')
        columns[index] = 'controlled-bad-result'
        mutant[17] = '|'.join(columns)
        mutants[name] = mutant
    mutant = list(wanted)
    mutant[1] = mutant[1].replace('|true|true|', '|true|false|')
    mutants['rollback'] = mutant
    for label, before, after in (('rollback-dirty', '|0|0|0', '|1|0|0'),
                                 ('unpublished-event', '|0|0|0', '|0|1|0'),
                                 ('restored-metadata', ':9000:', ':9001:')):
        mutant = list(wanted)
        mutant[1] = mutant[1].replace(before, after)
        mutants[label] = mutant
    deadline_row = next(i for i, row in enumerate(wanted[17:], 17) if '|X,' in row)
    mutant = list(wanted)
    columns = mutant[deadline_row].split('|')
    command = columns[1].split(',')
    command[2] = str(int(command[2]) + 1)
    columns[1] = ','.join(command)
    mutant[deadline_row] = '|'.join(columns)
    mutants['absolute-deadline'] = mutant
    for label, mutant in mutants.items():
        try:
            compare(label, '\n'.join(mutant) + '\n', wanted)
        except AssertionError:
            rejected.append(label)
        else:
            raise AssertionError('negative comparison control accepted')
    for axiom in ('sorryAx', 'Effects.untrusted'):
        try:
            parse_axioms(f"'Effects.fixture' depends on axioms: [{axiom}]\n", ['Effects.fixture'])
        except AssertionError:
            rejected.append(axiom)
        else:
            raise AssertionError('negative axiom parser control accepted')
    sources = check_sources()
    theorem_areas = {area: ['Effects.' + n for module in modules for n in re.findall(r'^theorem\s+(\w+)',
                      (PACKAGE / 'Effects' / module).read_text(), re.M)]
                     for area, modules in (('2', ['Rollback.lean']), ('3', ['Persistence.lean', 'KeyTTL.lean']))}
    receipt = {**stats, 'seed': hex(SEED), 'rollback_fixtures': 4, 'normal_error_fixtures': 1, 'key_translation_fixtures': 10, 'exact_now_fixtures': 2,
               'area_evidence': {area: {'theorems': names, 'comparisons': 5 if area == '2' else stats['expiry_steps'] + 12}
                                 for area, names in theorem_areas.items()},
               'checked_theorem_axioms': audit, 'kernel_inventory_sha256': digest(output / 'kernel-inventory.json'),
               'kernel_checked_theorems': len(kernel['theorem_axioms']), 'negative_axiom_fixtures': json.loads((output / 'negative-axioms.json').read_text()), 'source_sha256': sources, 'versions': versions,
               'tool_sha256': tools, 'native_build_inputs_sha256': native_inputs,
               'executable_sha256': {'lean': digest(lean), 'odin': digest(odin)},
               'trace_sha256': digest(path), 'results_sha256': results, 'negative_controls_rejected': rejected,
               'proof_source_sha256': {str(p.relative_to(PACKAGE)): digest(p) for p in sorted(PACKAGE.rglob('*'))
                                        if p.is_file() and not {'.lake', '.build', '__pycache__'}.intersection(p.parts)},
               'overlay_manifest_sha256': digest(output / 'overlay-sha256.json')}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'theorems': len(audit), **stats, 'rollback_fixtures': 4, 'normal_error_fixtures': 1, 'key_translation_fixtures': 10, 'exact_now_fixtures': 2,
                      'receipt': str(output / 'receipt.json')}, indent=2))


if __name__ == '__main__':
    run()
