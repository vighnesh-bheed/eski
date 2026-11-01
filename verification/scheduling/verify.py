import argparse
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parents[1]
sys.path.insert(0, str(PACKAGE))
import model
import server_probe


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def source_files():
    paths = [p for directory in ('src', 'third_party/lua') for p in (ROOT / directory).rglob('*') if p.is_file()]
    paths.extend(ROOT / name for name in ('tools/build_lua.sh', 'tools/build_diagnostics.sh', 'tools/source_digest.sh'))
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(paths)}


def source_check():
    expected = json.loads((PACKAGE / 'source-sha256.json').read_text())
    actual = source_files()
    if expected != actual:
        changed = sorted(name for name in expected.keys() | actual.keys() if expected.get(name) != actual.get(name))
        raise AssertionError('runtime source or module inventory drift: ' + ', '.join(changed))
    lines = ''.join(f'{sha}  {name}\n' for name, sha in sorted(actual.items()))
    fingerprint = hashlib.sha256(lines.encode()).hexdigest()
    identities = json.loads((PACKAGE / 'binary-identities.json').read_text())
    if fingerprint != identities['source_sha256']:
        raise AssertionError('qualified source fingerprint mismatch')
    return actual, fingerprint, identities


def restrict_process():
    os.nice(10)
    available = os.sched_getaffinity(0)
    os.sched_setaffinity(0, {1 if 1 in available else min(available)})


def invoke(command, output, log, env=None, expected=0, timeout=40):
    result = subprocess.run([str(x) for x in command], cwd=ROOT, capture_output=True, text=True,
                            timeout=timeout, env=env)
    content = result.stdout + result.stderr
    (output / log).write_text(content)
    if result.returncode != expected:
        raise AssertionError(f'{log}: exit {result.returncode}, expected {expected}; see captured log')
    return {'passed': True, 'exit_code': result.returncode, 'log': log,
            'log_sha256': digest(output / log)}, content


def overlay_build(output, odin):
    overlay = output / 'overlay'
    if overlay.exists():
        shutil.rmtree(overlay)
    shutil.copytree(ROOT / 'src', overlay / 'src')
    (overlay / 'src/main.odin').unlink()
    omitted = ['src/main.odin']
    for path in (overlay / 'src').glob('*_test.odin'):
        omitted.append(str(path.relative_to(overlay)))
        path.unlink()
    shutil.copyfile(PACKAGE / 'harness.odin', overlay / 'src/scheduling_harness.odin')
    (overlay / '.build').symlink_to(ROOT / '.build', target_is_directory=True)
    manifest = {str(path.relative_to(overlay)): digest(path)
                for path in sorted((overlay / 'src').rglob('*')) if path.is_file()}
    expected = {str(path.relative_to(ROOT)): digest(path) for path in (ROOT / 'src').rglob('*')
                if path.is_file() and str(path.relative_to(ROOT)) not in omitted}
    original = {name: sha for name, sha in manifest.items() if name != 'src/scheduling_harness.odin'}
    if original != expected:
        raise AssertionError('exact-source overlay identity or module inventory mismatch')
    write_json(output / 'overlay-sha256.json', {'original': original, 'omitted_entry_and_tests': sorted(omitted),
                                               'adapter': {'src/scheduling_harness.odin': digest(PACKAGE / 'harness.odin')}})
    link_paths = ['.build/diagnostics/libunwind.so']
    for mode in ('release', 'thread'):
        link_paths.extend((f'.build/diagnostics/{mode}/libeski-diagnostics.a', f'.build/lua/{mode}/libeslua-runtime.a'))
    link_hashes = {name: digest(ROOT / name) for name in link_paths}
    compiler_lock = ROOT / '.build/proofs/compiler.lock'
    compiler_lock.parent.mkdir(parents=True, exist_ok=True)
    builds = {}
    with compiler_lock.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        base = [odin, 'build', str(overlay / 'src'), '-thread-count:2', '-vet', '-strict-style']
        for name, flags in (('harness', []), ('harness-tsan', ['-sanitize:thread'])):
            builds[name], _ = invoke(base + ['-out:' + str(output / name)] + flags, output, name + '-build.log')
        builds['race-control'], _ = invoke([odin, 'build', str(PACKAGE / 'race_control.odin'), '-file',
                                            '-out:' + str(output / 'race-control'), '-thread-count:2', '-vet',
                                            '-strict-style', '-sanitize:thread'], output, 'race-control-build.log')
    if link_hashes != {name: digest(ROOT / name) for name in link_paths}:
        raise AssertionError('native link inputs changed during build')
    return builds, link_hashes


def actual(output, args, identities):
    odin = shutil.which(os.environ.get('ODIN', os.environ.get('ODIN_BIN', 'odin')))
    clang = shutil.which(os.environ.get('CC', 'clang'))
    if not odin or not clang:
        raise AssertionError('installed Odin and clang are required; missing tool cannot pass')
    versions = {}
    for name, command in (('odin', [odin, 'version']), ('clang', [clang, '--version']), ('python', [sys.executable, '--version'])):
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        versions[name] = (result.stdout + result.stderr).strip()
    tool_hashes = {'odin': digest(Path(odin).resolve()), 'clang': digest(Path(clang).resolve()),
                   'python': digest(Path(sys.executable).resolve())}
    servers = [('release', args.server.resolve())]
    if args.tsan_server:
        servers.append(('tsan-server', args.tsan_server.resolve()))
    for label, path in servers:
        expected = identities['release_sha256' if label == 'release' else 'tsan_sha256']
        if digest(path) != expected:
            raise AssertionError(label + ' executable is not the qualified source-bound identity')
    builds, native_inputs = overlay_build(output, odin)
    environment = dict(os.environ)
    environment['TSAN_OPTIONS'] = 'halt_on_error=1:exitcode=66'
    control, report = invoke([output / 'race-control'], output, 'race-control.log', environment, expected=66, timeout=15)
    if 'WARNING: ThreadSanitizer: data race' not in report or 'main::shared' not in report:
        raise AssertionError('deliberate race control did not demonstrate actual TSAN instrumentation')
    control['expected_race_detected'] = True
    checks = {'instrumentation_control': control}
    expected_lines = {
        'POOL': 10, 'COORDINATOR': 5, 'SNAPSHOT': 4,
    }
    for label in ('harness', 'harness-tsan'):
        result, text = invoke([output / label], output, label + '.log', environment, timeout=15)
        if 'ThreadSanitizer' in text:
            raise AssertionError('safe original-source harness reported a race')
        rows = [line.split('|') for line in text.splitlines() if line]
        if {row[0]: len(row) - 1 for row in rows} != expected_lines:
            raise AssertionError('original-source harness did not complete every declared check')
        result['checks'] = {row[0]: row[1:] for row in rows}
        result['count'] = sum(expected_lines.values())
        result['original_source_overlay'] = True
        result['sanitizer'] = 'thread' if label.endswith('tsan') else 'none'
        checks[label] = result
    for label, binary in servers:
        result = server_probe.run(binary, output, label)
        result['log_sha256'] = digest(output / result['log'])
        checks[label] = result
    binaries = {name: digest(output / name) for name in builds}
    binaries.update({name: digest(binary) for name, binary in servers})
    return {'checks': checks, 'builds': builds, 'native_build_inputs_sha256': native_inputs,
            'versions': versions, 'tool_sha256': tool_hashes, 'executable_sha256': binaries,
            'overlay_manifest_sha256': digest(output / 'overlay-sha256.json')}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=PACKAGE / '.build')
    parser.add_argument('--server', type=Path, default=ROOT / 'bin/eski')
    parser.add_argument('--tsan-server', type=Path)
    parser.add_argument('--replay', type=Path)
    args = parser.parse_args()
    if args.replay:
        print(json.dumps(model.replay(args.replay), sort_keys=True))
        return
    if not args.output.is_absolute():
        parser.error('--output must be an absolute path')
    output = args.output.resolve()
    if output in (ROOT, ROOT / 'src', PACKAGE):
        parser.error('--output must be a dedicated generated-artifact directory')
    output.mkdir(parents=True, exist_ok=True)
    receipt_path = output / 'receipt.json'
    receipt_path.unlink(missing_ok=True)
    (output / 'failure.json').unlink(missing_ok=True)
    started = time.monotonic()
    try:
        restrict_process()
        sources, fingerprint, identities = source_check()
        models = model.run(output)
        graph_audits = {scenario.name: model.audit_graph(scenario, output / (scenario.name + '.json.gz'))
                        for scenario in model.scenarios()}
        replayed = {name: model.replay(output / result['witness']) for name, result in models['mutants'].items()}
        actual_lock = ROOT / '.build/verification/check.lock'
        actual_lock.parent.mkdir(parents=True, exist_ok=True)
        with actual_lock.open('a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            production = actual(output, args, identities)
        final_sources, final_fingerprint, _ = source_check()
        if final_sources != sources or fingerprint != final_fingerprint:
            raise AssertionError('runtime inputs changed during verification')
        coverage = {}
        for result in models['scenarios'].values():
            for name, count in result['transition_coverage'].items():
                coverage[name] = coverage.get(name, 0) + count
        assets = {str(path.relative_to(PACKAGE)): digest(path) for path in PACKAGE.rglob('*')
                  if path.is_file() and not {'.build', '__pycache__'}.intersection(path.parts)}
        receipt = {'success': True, 'area': 7, 'exhausted': True, 'states': models['states'], 'edges': models['edges'],
                   'scenarios': len(models['scenarios']), 'terminals': models['terminals'],
                   'bounds': {'workers': 2, 'records_max': 3, 'jobs_max': 3, 'internal_retry_per_job_max': 1,
                              'disconnect_per_scenario_max': 1, 'pause_resume_cycles_max': 1,
                              'pool_capacity_max': 3, 'explorer_state_cap_per_scenario': 250000,
                              'explorer_deadline_seconds_per_scenario': 90, 'memory_model': 'sequential consistency'},
                   'invariants': models['invariants'], 'invariant_coverage': {
                       name: {'states_checked': models['states'], 'edges_checked': models['edges'],
                              'terminal_histories': models['terminals']} for name in models['invariants']},
                   'transition_coverage': coverage, 'models': models['scenarios'], 'graph_relation_audits': graph_audits,
                   'engine_control': models['engine_control'], 'mutant_witnesses': models['mutants'], 'witness_replay': replayed,
                   'actual_checks': production['checks'], 'actual_builds': production['builds'],
                   'source_sha256': sources, 'runtime_source_fingerprint': fingerprint,
                   'executable_sha256': production['executable_sha256'], 'versions': production['versions'],
                   'tool_sha256': production['tool_sha256'], 'native_build_inputs_sha256': production['native_build_inputs_sha256'],
                   'overlay_manifest_sha256': production['overlay_manifest_sha256'], 'verification_source_sha256': assets,
                   'elapsed_seconds': round(time.monotonic() - started, 3),
                   'limitations': [
                       'Finite source-informed SC models; no executable refinement theorem, weak-memory proof or unbounded liveness proof.',
                       'Progress assumes eventual worker/coordinator scheduling, eventual delivery of internal wakeups, and environment resume.',
                       'Environment yield self-loops model starvation; all nonstuttering reachable graphs are acyclic; no product deadlock found within bounds.',
                       'Record values abstract allocation, pointer lifetimes, all datatype kernels and every effect payload; original-source fixtures and narrow live probes test selected bridges.',
                       'TSAN covers bounded original pool/coordinator/snapshot paths after a deliberate race control; no whole-engine race-freedom claim.',
                       'Coordinator retry fixture uses an ordering adapter that invokes original INCR; synthetic completion injection is separate from live socket probes.',
                       'Live disconnect probes confirm accepted worker writes and final records; they do not enumerate every kernel socket timing.'
                   ]}
        write_json(receipt_path, receipt)
        print(json.dumps({'success': True, 'area': 7, 'states': models['states'], 'edges': models['edges'],
                          'scenarios': len(models['scenarios']), 'receipt': str(receipt_path)}, sort_keys=True))
    except Exception as error:
        write_json(output / 'failure.json', {'success': False, 'area': 7, 'error': str(error), 'type': type(error).__name__})
        raise


if __name__ == '__main__':
    main()
