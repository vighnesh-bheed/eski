import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
VERIFICATION = Path(__file__).resolve().parent
AREAS = {'scheduling': 7, 'lifecycle': 8}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def assets(package):
    return {str(path.relative_to(package)): digest(path) for path in sorted(package.rglob('*'))
            if path.is_file() and not {'.build', '__pycache__'}.intersection(path.relative_to(package).parts)}


def validate(name, path, server, tsan_server):
    receipt = json.loads(path.read_text())
    if receipt.get('success') is not True or receipt.get('exhausted') is not True or receipt.get('area') != AREAS[name]:
        raise RuntimeError(f'{name}: incomplete or unsuccessful verification')
    for field in ('states', 'edges', 'scenarios'):
        if type(receipt.get(field)) is not int or receipt[field] <= 0:
            raise RuntimeError(f'{name}: empty exploration evidence: {field}')
    for field in ('bounds', 'invariant_coverage', 'source_sha256', 'executable_sha256', 'versions'):
        if not isinstance(receipt.get(field), dict) or not receipt[field]:
            raise RuntimeError(f'{name}: missing {field}')
    invariants = receipt.get('invariants')
    if not isinstance(invariants, list) or not invariants or len(set(invariants)) != len(invariants) or set(invariants) != set(receipt['invariant_coverage']):
        raise RuntimeError(f'{name}: incomplete invariant inventory')
    for filename, expected in receipt['source_sha256'].items():
        if digest(ROOT / filename) != expected:
            raise RuntimeError(f'{name}: runtime source drift: {filename}')
    mutants = receipt.get('mutant_witnesses')
    if not isinstance(mutants, dict) or not mutants or any(value.get('rejected') is not True for value in mutants.values()):
        raise RuntimeError(f'{name}: missing rejected mutation controls')
    actual = receipt.get('actual_checks')
    if not isinstance(actual, dict) or not actual:
        raise RuntimeError(f'{name}: missing actual implementation checks')
    package = VERIFICATION / name
    current_assets = assets(package)
    if name == 'scheduling':
        if receipt.get('verification_source_sha256') != current_assets:
            raise RuntimeError('scheduling: verification assets changed')
        models = list(receipt.get('models', {}).values())
        if not models or any(model.get('exhausted') is not True for model in models):
            raise RuntimeError('scheduling: incomplete scenario exploration')
        if set(receipt.get('witness_replay', {})) != set(mutants) or any(value.get('replayed') is not True for value in receipt['witness_replay'].values()):
            raise RuntimeError('scheduling: mutation witnesses were not replayed')
        if len(receipt.get('graph_relation_audits', {})) != receipt['scenarios']:
            raise RuntimeError('scheduling: missing graph relation audits')
        control = receipt.get('engine_control', {})
        if (control.get('states'), control.get('edges')) != (16, 32) or control.get('cap_control_rejected') is not True:
            raise RuntimeError('scheduling: independent explorer control failed')
        required = ['harness', 'harness-tsan', 'instrumentation_control', 'release']
        if tsan_server is not None:
            required.append('tsan-server')
        if any(actual.get(check, {}).get('passed') is not True for check in required):
            raise RuntimeError('scheduling: required implementation check did not pass')
        race = actual['instrumentation_control']
        if race.get('exit_code') != 66 or race.get('expected_race_detected') is not True:
            raise RuntimeError('scheduling: real race instrumentation was not demonstrated')
        expected_executables = {'release': server, 'harness': path.parent / 'harness',
                                'harness-tsan': path.parent / 'harness-tsan', 'race-control': path.parent / 'race-control'}
        if tsan_server is not None:
            expected_executables['tsan-server'] = tsan_server
        native = receipt.get('native_build_inputs_sha256', {})
    else:
        expected_assets = {str((package / filename).relative_to(ROOT)): sha for filename, sha in current_assets.items()}
        if receipt.get('tool_sha256') != expected_assets:
            raise RuntimeError('lifecycle: verification assets changed')
        models = receipt.get('models', {}).get('scenarios', [])
        if not models or any(model.get('exhausted') is not True for model in models):
            raise RuntimeError('lifecycle: incomplete scenario exploration')
        if any(value.get('replayed') is not True for value in mutants.values()):
            raise RuntimeError('lifecycle: mutation witnesses were not replayed')
        for check in ('probe', 'release') + (('tsan',) if tsan_server is not None else ()):
            if actual.get(check, {}).get('success') is not True:
                raise RuntimeError(f'lifecycle: {check} did not pass')
        for check in ('release', 'tsan'):
            if actual.get(check) is not None and (actual[check].get('all_exit_zero') is not True or actual[check].get('sanitizer_suppressions') is not False):
                raise RuntimeError(f'lifecycle: invalid lifecycle outcome: {check}')
        expected_executables = {'server': server}
        if tsan_server is not None:
            expected_executables['tsan_server'] = tsan_server
        native = actual.get('build', {}).get('native_inputs_sha256', {})
    if len(models) != receipt['scenarios'] or sum(model['states'] for model in models) != receipt['states'] or sum(model['edges'] for model in models) != receipt['edges']:
        raise RuntimeError(f'{name}: scenario totals disagree')
    for label, executable in expected_executables.items():
        if receipt['executable_sha256'].get(label) != digest(executable):
            raise RuntimeError(f'{name}: executable identity changed: {label}')
    for filename, expected in native.items():
        if digest(ROOT / filename) != expected:
            raise RuntimeError(f'{name}: native input changed: {filename}')
    return receipt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--area', choices=tuple(AREAS), nargs='+', default=list(AREAS))
    parser.add_argument('--server', type=Path, default=ROOT / 'bin' / 'eski')
    parser.add_argument('--tsan-server', type=Path)
    parser.add_argument('--output', type=Path, default=VERIFICATION / '.build' / 'areas-seven-eight')
    parser.add_argument('--list', action='store_true')
    args = parser.parse_args()
    if len(set(args.area)) != len(args.area):
        parser.error('select each area at most once')
    if args.list:
        print(json.dumps({name: AREAS[name] for name in args.area}, indent=2))
        return
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    aggregate_path = output / 'receipt.json'
    aggregate_path.unlink(missing_ok=True)
    server = args.server.resolve()
    tsan_server = args.tsan_server.resolve() if args.tsan_server else None
    if hasattr(os, 'sched_getaffinity'):
        allowed = os.sched_getaffinity(0)
        os.sched_setaffinity(0, {1 if 1 in allowed else min(allowed)})
    receipts = {}
    for name in args.area:
        target = output / name
        target.mkdir(parents=True, exist_ok=True)
        child_receipt = target / 'receipt.json'
        child_receipt.unlink(missing_ok=True)
        command = [sys.executable, '-I', str(VERIFICATION / name / 'verify.py'),
                   '--output', str(target), '--server', str(server)]
        if tsan_server is not None:
            command.extend(['--tsan-server', str(tsan_server)])
        print(f'Verifying area {AREAS[name]}: {name}', flush=True)
        with (target / 'verify.log').open('w') as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f'{name}: verification exited {result.returncode}; see {target / "verify.log"}')
        receipt = validate(name, child_receipt, server, tsan_server)
        receipts[name] = {'area': AREAS[name], 'states': receipt['states'], 'edges': receipt['edges'],
                          'scenarios': receipt['scenarios'], 'invariants': receipt['invariants'],
                          'receipt_sha256': digest(child_receipt), 'receipt': str(child_receipt)}
        print(f'{name}: complete exploration and actual implementation checks passed', flush=True)
    result = {'success': True, 'areas': sorted(AREAS[name] for name in receipts), 'projects': receipts,
              'verification_source_sha256': {str(path.relative_to(ROOT)): digest(path)
                  for path in sorted(VERIFICATION.rglob('*')) if path.is_file()
                  and not {'.build', '__pycache__'}.intersection(path.relative_to(VERIFICATION).parts)},
              'qualification': 'bounded sequentially consistent models and targeted runtime checks; no unbounded or universal race proof'}
    aggregate_path.write_text(json.dumps(result, indent=2) + '\n')
    print(f'Areas verified; aggregate receipt: {aggregate_path}', flush=True)


if __name__ == '__main__':
    main()
