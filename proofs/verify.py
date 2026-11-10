import argparse
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROOFS = Path(__file__).resolve().parent
sys.path.insert(0, str(PROOFS))
from kernel_audit import project_modules

PROJECTS = {
    'storage': {'items': [1, 6], 'description': 'Hash-table migration and requested-memory accounting'},
    'effects': {'items': [2, 3], 'description': 'Worker rollback and expiry-aware persistence translations'},
    'encoding': {'items': [4, 5], 'description': 'Request parsing and packed codecs'},
    'bitfield': {'items': [9], 'description': 'Fixed-width arithmetic and mutation counts'},
    'vector': {'areas': ['projection', 'quantisation', 'heaps', 'visited', 'graph', 'arena', 'filter',
                         'merge', 'resolution', 'independence', 'compatibility'],
               'proof_only': ['filter'], 'odin_option': True,
               'description': 'Vector projection, quantisation, heaps, visited set, graph links and twins, arena free list and filter programs, and the labelled vector set: partition merge, name resolution and views, label independence and labels-off compatibility'},
    'label': {'areas': ['lattice', 'marking', 'interning', 'persistence', 'visibility', 'admission', 'rules', 'counters',
                        'contexts', 'arrival'],
              'odin_option': True,
              'description': 'Access label lattice, markings, interning, persistence, visibility bitsets, search admission, read and write rules, partitioned counters, context handles and command arrival'},
    'postings': {'areas': ['svbyte', 'sorted', 'roaring', 'cursors', 'phrases', 'statistics', 'scoring'],
                 'odin_option': True,
                 'description': 'Stream VByte codec, sorted-array kernels, Roaring bitmaps and their serialization, cursor algebra, phrase windows, label-partitioned term statistics and ranking formulas'},
    'text': {'areas': ['classes', 'tokenizer', 'folding', 'stopwords', 'analysis'],
             'odin_option': True,
             'description': 'Byte classes, document tokenizer, Unicode 17.0.0 lower-casing and folding, stop-word tables and the analysis position and stem rules'},
    'query': {'areas': ['lexer', 'parser', 'reference'],
              'odin_option': True,
              'description': 'Query lexer and parser fragment for terms, patterns, unions, intersections, negation, optional terms and groups in dialects 1 and 2, checked against recorded reference output'},
}
ALLOWED_AXIOMS = {'propext', 'Classical.choice', 'Quot.sound'}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs(selected):
    result = {}
    paths = [Path(__file__).resolve(), PROOFS / 'kernel_audit.py', PROOFS / 'KernelAudit.lean']
    for name in selected:
        paths.extend((PROOFS / name).rglob('*'))
    for path in sorted(paths):
        if not path.is_file() or any(part in {'.build', '.lake', '__pycache__'} for part in path.relative_to(PROOFS).parts):
            continue
        if path.suffix in {'.lean', '.odin', '.py', '.json', '.toml'} or path.name == 'lean-toolchain':
            result[str(path.relative_to(ROOT))] = digest(path)
    return result


def area_names(name):
    return [str(item) for item in PROJECTS[name].get('items', [])] + list(PROJECTS[name].get('areas', []))


def project_label(name):
    if 'items' in PROJECTS[name]:
        return f'items {PROJECTS[name]["items"]}'
    return f'areas {PROJECTS[name]["areas"]}'


def validate_receipt(name, path):
    receipt = json.loads(path.read_text())
    axioms = receipt.get('checked_theorem_axioms')
    if not isinstance(axioms, dict) or not axioms:
        raise RuntimeError(f'{name}: no checked theorem inventory in receipt')
    for theorem, dependencies in axioms.items():
        if not isinstance(dependencies, list) or set(dependencies) - ALLOWED_AXIOMS:
            raise RuntimeError(f'{name}: invalid axiom dependencies for {theorem}')
    for field in ('source_sha256', 'versions', 'executable_sha256'):
        if not isinstance(receipt.get(field), dict) or not receipt[field]:
            raise RuntimeError(f'{name}: missing {field} evidence')
    for source, expected in receipt['source_sha256'].items():
        if digest(ROOT / source) != expected:
            raise RuntimeError(f'{name}: source changed after verification: {source}')
    kernel_path = path.parent / 'kernel-inventory.json'
    if digest(kernel_path) != receipt.get('kernel_inventory_sha256'):
        raise RuntimeError(f'{name}: kernel inventory identity mismatch')
    kernel = json.loads(kernel_path.read_text())
    modules = project_modules(PROOFS / name)
    if kernel.get('modules') != list(modules):
        raise RuntimeError(f'{name}: incomplete kernel module inventory')
    expected_sources = {module: digest(source) for module, source in modules.items()}
    if kernel.get('source_sha256') != expected_sources:
        raise RuntimeError(f'{name}: proof modules changed after kernel audit')
    if kernel.get('helper_sha256') != digest(PROOFS / 'KernelAudit.lean') or kernel.get('audit_runner_sha256') != digest(PROOFS / 'kernel_audit.py'):
        raise RuntimeError(f'{name}: kernel audit tooling changed')
    declarations = kernel.get('declarations')
    if not isinstance(declarations, list) or not declarations:
        raise RuntimeError(f'{name}: empty kernel declaration inventory')
    seen, kernel_theorems = set(), {}
    for declaration in declarations:
        theorem, origin, kind, dependencies = (declaration.get(key) for key in ('name', 'module', 'kind', 'axioms'))
        if not isinstance(theorem, str) or theorem in seen or origin not in modules:
            raise RuntimeError(f'{name}: invalid kernel declaration')
        seen.add(theorem)
        if kind not in {'theorem', 'declaration'} or not isinstance(dependencies, list) or set(dependencies) - ALLOWED_AXIOMS:
            raise RuntimeError(f'{name}: unapproved kernel declaration: {theorem}')
        if kind == 'theorem':
            kernel_theorems[theorem] = dependencies
    if not kernel_theorems or kernel.get('theorem_axioms') != kernel_theorems or receipt.get('kernel_checked_theorems') != len(kernel_theorems):
        raise RuntimeError(f'{name}: kernel theorem inventory mismatch')
    if not set(axioms) <= set(kernel_theorems) or any(set(dependencies) != set(kernel_theorems[theorem]) for theorem, dependencies in axioms.items()):
        raise RuntimeError(f'{name}: manifest disagrees with kernel inventory')
    executables = {'lean': PROOFS / name / '.lake' / 'build' / 'bin' / (name + '_model'),
                   'odin': path.parent / 'odin_bridge'}
    if name == 'label':
        executables['arrival_odin'] = path.parent / 'arrival_bridge'
    if any(receipt['executable_sha256'].get(binary) != digest(executable) for binary, executable in executables.items()):
        raise RuntimeError(f'{name}: executable changed after comparisons')
    evidence = receipt.get('area_evidence')
    if name == 'bitfield' and evidence is None:
        evidence = {'9': {'theorems': list(axioms), 'comparisons': receipt.get('programs', 0)}}
    if not isinstance(evidence, dict) or set(evidence) != set(area_names(name)):
        raise RuntimeError(f'{name}: incomplete area evidence')
    proof_only = set(PROJECTS[name].get('proof_only', []))
    for item, area in evidence.items():
        names = area.get('theorems')
        count = area.get('comparisons')
        if not isinstance(names, list) or not names or not set(names) <= set(axioms):
            raise RuntimeError(f'{name}: area {item} lacks audited theorem evidence')
        if type(count) is not int or count < 0 or (count == 0) != (item in proof_only):
            raise RuntimeError(f'{name}: area {item} lacks implementation comparisons')
    receipt['area_evidence'] = evidence
    return receipt


def clean_project(project, lean_bin, env):
    lake = shutil.which('lake', path=env.get('PATH'))
    if lean_bin is not None:
        lake = str(lean_bin / 'lake')
    if not lake:
        raise RuntimeError('Lake is required to clean proof build outputs')
    lock_dir = ROOT / '.build' / 'proofs'
    lock_dir.mkdir(parents=True, exist_ok=True)
    with (lock_dir / 'compiler.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        subprocess.run([lake, 'clean'], cwd=project, env=env, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--project', nargs='+', choices=tuple(PROJECTS), default=list(PROJECTS))
    parser.add_argument('--lean-bin', type=Path, default=Path(os.environ['LEAN_BIN_DIR']) if 'LEAN_BIN_DIR' in os.environ else None)
    parser.add_argument('--odin', type=Path, default=None)
    parser.add_argument('--output', type=Path, default=PROOFS / '.build' / 'phase-one')
    parser.add_argument('--clean', action='store_true')
    parser.add_argument('--list', action='store_true')
    args = parser.parse_args()
    if len(set(args.project)) != len(args.project):
        parser.error('select each project at most once')
    if args.list:
        print(json.dumps({name: PROJECTS[name] for name in args.project}, indent=2))
        return
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    aggregate_path = args.output / 'receipt.json'
    aggregate_path.unlink(missing_ok=True)
    for name in args.project:
        if not (PROOFS / name / 'verify.py').is_file():
            raise RuntimeError(f'{name}: project verifier is missing')
    env = dict(os.environ, LEAN_NUM_THREADS='1')
    if args.lean_bin is not None:
        args.lean_bin = args.lean_bin.resolve()
        env['PATH'] = str(args.lean_bin) + os.pathsep + env.get('PATH', '')
    if args.odin is not None:
        args.odin = args.odin.resolve()
        if not args.odin.is_file() or not os.access(args.odin, os.X_OK):
            parser.error('--odin must name an executable Odin compiler')
        env['PATH'] = str(args.odin.parent) + os.pathsep + env.get('PATH', '')
    if hasattr(os, 'sched_getaffinity'):
        os.sched_setaffinity(0, {min(os.sched_getaffinity(0))})
    receipts = {}
    for name in args.project:
        project = PROOFS / name
        output = args.output / name
        output.mkdir(parents=True, exist_ok=True)
        child_receipt = output / 'receipt.json'
        child_receipt.unlink(missing_ok=True)
        if args.clean:
            clean_project(project, args.lean_bin, env)
        command = [sys.executable, '-I', str(project / 'verify.py'), '--output', str(output)]
        if args.lean_bin is not None:
            command.extend(['--lean-bin', str(args.lean_bin)])
        if args.odin is not None and PROJECTS[name].get('odin_option'):
            command.extend(['--odin', str(args.odin)])
        print(f'Verifying {name}: {project_label(name)}', flush=True)
        with (output / 'verify.log').open('w') as log:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f'{name}: verification exited {result.returncode}; see {output / "verify.log"}')
        receipt = validate_receipt(name, child_receipt)
        receipts[name] = {
            **PROJECTS[name],
            'checked_theorems': len(receipt['checked_theorem_axioms']),
            'kernel_checked_theorems': receipt['kernel_checked_theorems'],
            'area_evidence': receipt['area_evidence'],
            'receipt_sha256': digest(child_receipt),
            'receipt': str(child_receipt),
        }
        print(f'{name}: passed {receipts[name]["checked_theorems"]} checked theorems and project comparisons', flush=True)
    aggregate = {
        'schema_version': 2,
        'items': sorted({item for name in receipts for item in PROJECTS[name].get('items', [])}),
        'areas': {name: PROJECTS[name]['areas'] for name in receipts if 'areas' in PROJECTS[name]},
        'projects': receipts,
        'checked_theorems': sum(value['checked_theorems'] for value in receipts.values()),
        'kernel_checked_theorems': sum(value['kernel_checked_theorems'] for value in receipts.values()),
        'proof_inputs_sha256': inputs(receipts),
        'odin_correspondence': 'finite implementation comparisons; no verified translation',
    }
    aggregate_path.write_text(json.dumps(aggregate, indent=2) + '\n')
    print(f'Aggregate verification passed; receipt: {aggregate_path}', flush=True)


if __name__ == '__main__':
    main()
