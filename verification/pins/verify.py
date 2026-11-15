import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import sys


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().parent
MODELLED = ['src/vset_threads.odin', 'src/compute_integration.odin', 'src/compute/pool.odin', 'src/cmd_vset.odin',
            'src/store.odin', 'src/lazyfree.odin', 'src/vsettype/vset.odin']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def module(name):
    spec = importlib.util.spec_from_file_location('pins_' + name, PACKAGE / (name + '.py'))
    loaded = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = loaded
    spec.loader.exec_module(loaded)
    return loaded


def main():
    parser = argparse.ArgumentParser(description='Bounded exhaustive model of the vector set pin protocol.')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--server', type=Path, default=ROOT / 'bin/eski')
    parser.add_argument('--tsan-server', type=Path)
    args = parser.parse_args()
    if not args.output.is_absolute():
        parser.error('--output must be an absolute path')
    output = args.output.resolve()
    if output in (ROOT, PACKAGE) or output in PACKAGE.parents or PACKAGE in output.parents:
        parser.error('output must be outside the public verification sources')
    output.mkdir(parents=True, exist_ok=True)
    receipt = output / 'receipt.json'
    receipt.unlink(missing_ok=True)
    failure = output / 'failure.json'
    failure.unlink(missing_ok=True)
    try:
        model = module('model')
        tools = {str(p.relative_to(ROOT)): digest(p) for p in sorted(PACKAGE.iterdir()) if p.is_file()}
        sources = {name: digest(ROOT / name) for name in MODELLED}
        models = model.verify_models()
        if set(models['invariant_coverage']) != set(model.INVARIANTS):
            raise AssertionError('independent invariant inventory is incomplete')
        (output / 'models.json').write_text(json.dumps(models, indent=2) + '\n')
        result = {'success': True, 'area': 'pins', 'exhausted': models['exhausted'], 'states': models['states'],
                  'edges': models['edges'], 'scenarios': models['scenario_count'], 'invariants': model.INVARIANTS,
                  'bounds': models['bounds'], 'mutant_witnesses': models['rejected_mutants'],
                  'invariant_coverage': models['invariant_coverage'], 'tool_sha256': tools,
                  'modelled_source_sha256': sources, 'versions': {'python': platform.python_version()},
                  'limits': ['The model is a bounded transition system, not a formal refinement of the executable.',
                             'Jobs read one set each; a flush acts on every set; a forget is modelled as closing the owner connections before its writes.',
                             'No actual implementation check runs here; the unit tests and the threading driver exercise the code.',
                             'No weak-memory, unbounded concurrency, out-of-memory or performance claim.']}
        receipt.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({'success': True, 'area': 'pins', 'states': models['states'], 'edges': models['edges'],
                          'scenarios': models['scenario_count'], 'mutants': sorted(models['rejected_mutants']),
                          'receipt': str(receipt)}))
    except BaseException as error:
        failure.write_text(json.dumps({'success': False, 'area': 'pins', 'error': str(error)}, indent=2) + '\n')
        raise


if __name__ == '__main__':
    main()
