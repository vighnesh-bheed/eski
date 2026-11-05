import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().parent
QUALIFIED_SOURCE = 'a94ed800e7b613cf43627a47e208fccf38e3e899dd187ac3e67b78a03685c19e'
QUALIFIED_SERVER = '12e631e338e6097be3029ddbe794e210723a094bebd55a7cae509169b5c42024'
QUALIFIED_TSAN_SERVER = '9e1f7df8dda63f4ef4693c49bf1871b0203224e00845c5c0525bf63041ea1685'
INVARIANTS = ['callback_lifetime_requires_join_not_park', 'no_fork_snapshot_with_live_worker_owners',
              'accepted_mutations_and_effects_reconciled_before_snapshot',
              'snapshot_contains_all_accepted_mutations', 'ordinary_libc_fork_runs_registered_hooks',
              'child_resets_tid_queues_and_dead_thread_handles',
              'parent_and_child_restore_exact_saved_signal_mask', 'parent_resumes_with_its_own_resources',
              'shutdown_reconciles_accepted_work_before_free',
              'no_queued_or_active_callback_after_logger_teardown',
              'all_accepted_legacy_effects_complete_before_teardown']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def module(name):
    spec = importlib.util.spec_from_file_location('lifecycle_' + name, PACKAGE / (name + '.py'))
    loaded = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = loaded
    spec.loader.exec_module(loaded)
    return loaded


def sources():
    expected = json.loads((PACKAGE / 'source_sha256.json').read_text())
    for name, sha in expected.items():
        if digest(ROOT / name) != sha:
            raise AssertionError('source drift; review lifecycle mapping before updating gate: ' + name)
    source = subprocess.check_output(['bash', 'tools/source_digest.sh'], cwd=ROOT, text=True).strip()
    if source != QUALIFIED_SOURCE:
        raise AssertionError('qualified runtime source fingerprint changed')
    return expected


def main():
    parser = argparse.ArgumentParser(description='Bounded exhaustive lifecycle models and exact-source owned runtime checks.')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--server', type=Path, default=ROOT / 'bin/eski')
    parser.add_argument('--tsan-server', type=Path)
    args = parser.parse_args()
    if not args.output.is_absolute():
        parser.error('--output must be an absolute path')
    output = args.output.resolve()
    if output in (ROOT, PACKAGE) or output in PACKAGE.parents or PACKAGE in output.parents:
        parser.error('output must be outside the public lifecycle sources')
    output.mkdir(parents=True, exist_ok=True)
    receipt = output / 'receipt.json'
    receipt.unlink(missing_ok=True)
    failure = output / 'failure.json'
    failure.unlink(missing_ok=True)
    try:
        tool_hashes = {str(p.relative_to(ROOT)): digest(p) for p in sorted(PACKAGE.iterdir()) if p.is_file()}
        source_hashes = sources()
        server = args.server.resolve()
        if digest(server) != QUALIFIED_SERVER:
            raise AssertionError('requires exact qualified release server')
        tsan = args.tsan_server.resolve() if args.tsan_server else None
        if tsan is not None and digest(tsan) != QUALIFIED_TSAN_SERVER:
            raise AssertionError('optional TSAN server is not exact source-matched qualified artifact')
        models = module('model').verify_models(output)
        if set(models['invariant_coverage']) != set(INVARIANTS):
            raise AssertionError('independent invariant inventory is incomplete')
        (output / 'models.json').write_text(json.dumps(models, indent=2) + '\n')
        actual = module('actual').actual_checks(output, server, tsan)
        if sources() != source_hashes or digest(server) != QUALIFIED_SERVER:
            raise AssertionError('runtime inputs changed during verification')
        if tool_hashes != {str(p.relative_to(ROOT)): digest(p) for p in sorted(PACKAGE.iterdir()) if p.is_file()}:
            raise AssertionError('verification assets changed during verification')
        executables = {'server': digest(server), 'probe': actual['build']['probe_sha256'],
                       'syslog_shim': actual['build']['shim_sha256']}
        if tsan:
            executables['tsan_server'] = digest(tsan)
        result = {'success': True, 'area': 8, 'exhausted': models['exhausted'],
                  'states': models['states'], 'edges': models['edges'], 'scenarios': models['scenario_count'],
                  'invariants': INVARIANTS, 'bounds': models['bounds'],
                  'mutant_witnesses': models['rejected_mutants'], 'models': models,
                  'invariant_coverage': models['invariant_coverage'],
                  'actual_checks': actual, 'source_sha256': source_hashes,
                  'runtime_source_sha256': QUALIFIED_SOURCE, 'tool_sha256': tool_hashes,
                  'executable_sha256': executables,
                  'versions': {'python': platform.python_version(),
                               'odin': actual['build']['tools']['odin']['version'],
                               'clang': actual['build']['tools']['clang']['version']},
                  'limits': ['Bounded lifecycle transition models are not formal refinements of the executable.',
                             'Pool model abstracts ownership as one owner per accepted job; multi-owner scheduling belongs to area seven.',
                             'Legacy service callbacks are abstracted as one queued/active job per service; counters are mathematical bounded naturals.',
                             'No whole-program, unbounded concurrency, universal weak-memory, durability, OOM, or performance claim.',
                             'Liveness assumes fair enabled progress, no new producer after closure, successful OS calls and terminating callbacks.',
                             'Real tests cover four exact alarm/other-signal mask classes; raw clone and fork failure are model controls only.']}
        receipt.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({'success': True, 'area': 8, 'states': models['states'], 'edges': models['edges'],
                          'scenarios': models['scenario_count'], 'receipt': str(receipt)}))
    except BaseException as error:
        failure.write_text(json.dumps({'success': False, 'area': 8, 'error': str(error)}, indent=2) + '\n')
        raise


if __name__ == '__main__':
    main()
