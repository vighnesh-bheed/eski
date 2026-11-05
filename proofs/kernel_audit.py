import hashlib
import json
from pathlib import Path
import re
import subprocess


ALLOWED_AXIOMS = {'propext', 'Classical.choice', 'Quot.sound'}
HELPER = Path(__file__).with_name('KernelAudit.lean')
EXCLUDED = {'.lake', '.build', '__pycache__', '.git'}


def project_modules(package):
    package = Path(package).resolve()
    modules = {}
    for path in sorted(package.rglob('*.lean')):
        relative = path.relative_to(package)
        if any(part in EXCLUDED for part in relative.parts):
            continue
        parts = relative.with_suffix('').parts
        if not all(re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', part) for part in parts):
            raise AssertionError(f'unsupported Lean module path: {relative}')
        name = '.'.join(parts)
        if name in modules:
            raise AssertionError(f'duplicate Lean module: {name}')
        modules[name] = path
    if not modules:
        raise AssertionError('empty project module inventory')
    return modules


def audit(lake, package, output, env, manifest_module):
    package, output = Path(package).resolve(), Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    evidence_path = output / 'kernel-inventory.json'
    evidence_path.unlink(missing_ok=True)
    modules = project_modules(package)
    sources = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in modules.items()}
    if manifest_module not in modules:
        raise AssertionError('axiom manifest module is missing')
    request = output / 'kernel-modules.txt'
    request.write_text('\n'.join(modules) + '\n')
    build = subprocess.run([str(lake), 'build', *('+' + name for name in modules)],
                           cwd=package, env=env, text=True, capture_output=True)
    (output / 'kernel-build.txt').write_text(build.stdout + build.stderr)
    if build.returncode:
        raise AssertionError('project module inventory failed to build; see kernel-build.txt')
    result = subprocess.run([str(lake), 'env', 'lean', '-j1', '--run', str(HELPER),
                             str(request), str(evidence_path)],
                            cwd=package, env=env, text=True, capture_output=True)
    (output / 'kernel-audit.txt').write_text(result.stdout + result.stderr)
    if result.returncode or result.stdout or result.stderr:
        raise AssertionError('kernel inventory failed or produced unexpected output; see kernel-audit.txt')
    evidence = json.loads(evidence_path.read_text())
    if evidence.get('modules') != list(modules) or not isinstance(evidence.get('declarations'), list):
        raise AssertionError('incomplete kernel module inventory')
    artifacts = evidence.get('module_artifacts')
    if not isinstance(artifacts, dict) or set(artifacts) != set(modules):
        raise AssertionError('incomplete compiled module inventory')
    compiled = {}
    for name, artifact in artifacts.items():
        path = Path(artifact)
        path = (path if path.is_absolute() else package / path).resolve()
        expected = package / '.lake/build/lib/lean' / Path(*name.split('.')).with_suffix('.olean')
        if path != expected.resolve() or not path.is_file():
            raise AssertionError(f'project module resolved outside its compiled artifact: {name}')
        files = [path] + [extra for suffix in ('.private', '.server') if (extra := Path(str(path) + suffix)).is_file()]
        compiled[name] = {str(item.relative_to(package)): hashlib.sha256(item.read_bytes()).hexdigest() for item in files}
    seen, theorems = set(), {}
    for entry in evidence['declarations']:
        name, origin, kind, axioms = (entry.get(key) for key in ('name', 'module', 'kind', 'axioms'))
        if not isinstance(name, str) or not name or name in seen or origin not in modules:
            raise AssertionError('invalid kernel declaration inventory')
        seen.add(name)
        if kind not in {'theorem', 'axiom', 'declaration'} or not isinstance(axioms, list):
            raise AssertionError('invalid kernel declaration evidence')
        if kind == 'axiom' or set(axioms) - ALLOWED_AXIOMS:
            raise AssertionError(f'unapproved kernel dependencies: {name}: {axioms}')
        if kind == 'theorem':
            theorems[name] = axioms
    if not theorems:
        raise AssertionError('empty kernel theorem inventory')
    manifest = re.findall(r'^#print axioms (\S+)', modules[manifest_module].read_text(), re.M)
    if not manifest or len(set(manifest)) != len(manifest) or not set(manifest) <= set(theorems):
        raise AssertionError('manifest must name distinct kernel theorems')
    printed = subprocess.run([str(lake), 'env', 'lean', '-j1', str(modules[manifest_module])],
                             cwd=package, env=env, text=True, capture_output=True, check=True)
    (output / 'axioms.txt').write_text(printed.stdout + printed.stderr)
    found, cursor = {}, 0
    pattern = r"'([^']+)' (?:depends on axioms:\s*\[([^\]]*)\]|does not depend on any axioms)"
    for match in re.finditer(pattern, printed.stdout):
        if printed.stdout[cursor:match.start()].strip():
            raise AssertionError('unexpected axiom manifest output')
        name, dependencies = match.groups()
        if name in found:
            raise AssertionError('duplicate axiom manifest output')
        found[name] = [item.strip() for item in (dependencies or '').split(',') if item.strip()]
        cursor = match.end()
    if printed.stderr or printed.stdout[cursor:].strip() or set(found) != set(manifest):
        raise AssertionError('incomplete or noisy axiom manifest output')
    for name, axioms in found.items():
        if set(axioms) != set(theorems[name]):
            raise AssertionError(f'manifest/kernel axiom mismatch: {name}')
    evidence['declarations'].sort(key=lambda entry: entry['name'])
    evidence['theorem_axioms'] = dict(sorted(theorems.items()))
    current = project_modules(package)
    if set(current) != set(modules) or any(hashlib.sha256(path.read_bytes()).hexdigest() != sources[name] for name, path in current.items()):
        raise AssertionError('project Lean sources changed during kernel audit')
    evidence['source_sha256'] = sources
    evidence['compiled_module_sha256'] = compiled
    evidence['helper_sha256'] = hashlib.sha256(HELPER.read_bytes()).hexdigest()
    evidence['audit_runner_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    evidence_path.write_text(json.dumps(evidence, indent=2) + '\n')
    return found, evidence
