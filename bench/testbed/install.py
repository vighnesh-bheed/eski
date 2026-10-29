import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

sys.dont_write_bytecode = True

OVERLAY_SCHEMA = 'eski-testbed-overlay-v1'
RECEIPT_SCHEMA = 'eski-testbed-install-v1'
PROFILE_SCHEMA = 'eski-exam-profile-v1'
PROTOCOL_SCHEMA = 'eski-exam-protocol-v1'
RUNNER = ('run.sh', 'spec.py', 'compare.py', 'exam.sh', 'exam_workflow.py', 'exam_scheduler.py', 'exam_metrics.py')
TESTBED = ('fill.sh',)
EXECUTABLE = {'workspace/bench/run.sh', 'workspace/bench/exam.sh', 'workspace/bench/testbed/fill.sh'}
DEFAULT_BASE = '~/eski-exam'
WRAPPER = '#!/usr/bin/env bash\nset -euo pipefail\nexec "$(dirname "$(readlink -f "$0")")/workspace/bench/exam.sh" "$@"\n'
FILL_WRAPPER = '#!/usr/bin/env bash\nset -euo pipefail\nexec "$(dirname "$(readlink -f "$0")")/workspace/bench/testbed/fill.sh" "$@"\n'
JQ_WRAPPER = '''#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
LD_LIBRARY_PATH="$here/../jq/{libraries}${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}" exec "$here/../jq/{binary}" "$@"
'''


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def encode(value):
    return (json.dumps(value, indent=1, sort_keys=True, allow_nan=False) + '\n').encode()


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(encode(value))


def plans_module():
    spec = importlib.util.spec_from_file_location('eski_testbed_plans', Path(__file__).with_name('plans.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def image_archive(manifest, manifest_path):
    archive = (manifest.get('archive') or {}).get('path')
    expected = (manifest.get('archive') or {}).get('sha256')
    if not archive or not expected:
        raise ValueError('the image manifest has no exported archive; build it with bench/image.sh --export DIR')
    path = Path(archive)
    if not path.is_absolute():
        path = Path(manifest_path).resolve().parent / path
    if not path.is_file():
        raise ValueError('image archive not found: ' + str(path))
    if sha(path) != expected:
        raise ValueError('image archive sha256 differs from the manifest: ' + str(path))
    checksum = Path(str(path) + '.sha256')
    if checksum.exists() and checksum.read_text().split()[0] != expected:
        raise ValueError('image archive checksum file disagrees with the manifest')
    for field in ('image_id', 'source_revision', 'source_sha256'):
        if not manifest.get(field):
            raise ValueError('the image manifest lacks ' + field)
    if not (manifest.get('binary') or {}).get('sha256'):
        raise ValueError('the image manifest lacks the binary sha256')
    return path


def build_overlay(repository, design_path, manifest_path, root_name, output):
    repository = Path(repository).resolve()
    plans = plans_module()
    design = plans.validate(load(design_path))
    if not any(engine['target'] == 'eski-docker' for engine in design['engines']):
        raise ValueError('the design does not measure the eski-docker target')
    manifest = load(manifest_path)
    archive = image_archive(manifest, manifest_path)
    staging = Path(tempfile.mkdtemp(prefix='eski-overlay-', dir=Path(output).parent))
    try:
        bench = staging / 'workspace' / 'bench'
        (bench / 'testbed').mkdir(parents=True)
        for name in RUNNER:
            shutil.copy2(repository / 'bench' / name, bench / name)
        for name in TESTBED:
            shutil.copy2(repository / 'bench' / 'testbed' / name, bench / 'testbed' / name)
        plans.write(design, staging / 'workspace' / 'plans')
        shutil.copy2(design_path, staging / 'design.json')
        (staging / 'images').mkdir()
        shutil.copy2(archive, staging / 'images' / archive.name)
        (staging / 'images' / (archive.name + '.sha256')).write_text('%s  %s\n' % (manifest['archive']['sha256'], archive.name))
        shipped = dict(manifest, archive=dict(path='images/' + archive.name, sha256=manifest['archive']['sha256']), extracted_binary=None)
        write(staging / 'image.json', shipped)
        shutil.copy2(Path(__file__).resolve(), staging / 'install.py')
        for relative in EXECUTABLE:
            (staging / relative).chmod(0o755)
        files = {str(path.relative_to(staging)): sha(path) for path in sorted(staging.rglob('*')) if path.is_file()}
        overlay = dict(schema=OVERLAY_SCHEMA, root=root_name, files=files, image_id=manifest['image_id'],
                       source=dict(revision=manifest['source_revision'], sha256=manifest['source_sha256']),
                       created_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
        write(staging / 'overlay.json', overlay)
        with tarfile.open(output, 'w') as handle:
            for path in sorted(staging.rglob('*')):
                handle.add(path, arcname=str(path.relative_to(staging)), recursive=False)
    finally:
        shutil.rmtree(staging)
    return dict(path=str(output), sha256=sha(output), bytes=Path(output).stat().st_size, files=len(files))


def ssh(host, command, **options):
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', host, command], **options)


def install(args):
    repository = Path(__file__).resolve().parents[2]
    if not args.root or '/' in args.root or args.root.startswith('.'):
        raise ValueError('the root name must be a plain directory name')
    work = Path(tempfile.mkdtemp(prefix='eski-install-'))
    try:
        overlay = build_overlay(repository, args.design, args.image_manifest, args.root, work / ('overlay-' + args.root + '.tar'))
        print('overlay   %s sha256 %s (%d files, %d bytes)' % (overlay['path'], overlay['sha256'], overlay['files'], overlay['bytes']), file=sys.stderr)
        quoted_base = args.base if args.base.startswith('~/') and ' ' not in args.base else shlex.quote(args.base)
        staging_dir = quoted_base + '/.overlays'
        remote_name = '%s/%s-%s.tar' % (staging_dir, args.root, overlay['sha256'][:12])
        done = ssh(args.host, 'mkdir -p %s && test ! -e %s/%s' % (staging_dir, quoted_base, shlex.quote(args.root)), capture_output=True, text=True)
        if done.returncode:
            raise ValueError('remote base unusable or root %s already exists: %s' % (args.root, done.stderr.strip()))
        with open(overlay['path'], 'rb') as handle:
            done = ssh(args.host, 'cat > %s.part && mv %s.part %s && sha256sum %s' % (remote_name, remote_name, remote_name, remote_name),
                       stdin=handle, capture_output=True, text=True)
        if done.returncode or done.stdout.split()[:1] != [overlay['sha256']]:
            raise ValueError('overlay copy failed or arrived with another sha256: ' + (done.stdout + done.stderr).strip())
        print('copied    %s:%s' % (args.host, remote_name), file=sys.stderr)
        command = 'python3 -I -B - remote --overlay %s --sha256 %s --base %s --root %s' % (remote_name, overlay['sha256'], quoted_base, shlex.quote(args.root))
        done = ssh(args.host, command, input=Path(__file__).read_text(), capture_output=True, text=True)
        sys.stderr.write(done.stderr)
        if done.returncode:
            raise ValueError('remote installation failed: ' + (done.stdout.strip().splitlines() or ['no output'])[-1])
        receipt = json.loads(done.stdout.strip().splitlines()[-1])
        if args.receipt:
            write(args.receipt, receipt)
        print(json.dumps(receipt, indent=1, sort_keys=True))
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(argv, **options):
    done = subprocess.run(argv, capture_output=True, text=True, **options)
    if done.returncode:
        raise ValueError('%s failed: %s' % (' '.join(argv[:3]), (done.stderr or done.stdout).strip()[-500:]))
    return done.stdout


def docker_id(reference):
    done = subprocess.run(['docker', 'image', 'inspect', '--format', '{{.Id}}', reference], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else None


def pinned_image(reference):
    if '@sha256:' not in reference:
        raise ValueError('image reference is not pinned: ' + reference)
    image = docker_id(reference)
    pulled = False
    if image is None:
        print('pulling   ' + reference, file=sys.stderr)
        run(['docker', 'pull', '--quiet', reference])
        image = docker_id(reference)
        pulled = True
    if not image or not image.startswith('sha256:'):
        raise ValueError('cannot resolve a local image id for ' + reference)
    digests = json.loads(run(['docker', 'image', 'inspect', '--format', '{{json .RepoDigests}}', image]) or '[]') or []
    digest = reference.split('@', 1)[1]
    if not any(item.endswith('@' + digest) for item in digests) and image != digest:
        raise ValueError('local image %s does not carry the pinned digest %s' % (image, digest))
    return dict(reference=reference, image_id=image, pulled=pulled)


def load_eski(root, manifest):
    archive = root / manifest['archive']['path']
    if sha(archive) != manifest['archive']['sha256']:
        raise ValueError('shipped image archive sha256 differs from the manifest')
    output = run(['docker', 'load', '--input', str(archive)])
    tags = [line.split(':', 1)[1].strip() for line in output.splitlines() if line.startswith('Loaded image:')]
    ids = [line.split(':', 1)[1].strip() for line in output.splitlines() if line.startswith('Loaded image ID:')]
    reference = (tags or ids or [None])[0]
    if not reference:
        raise ValueError('docker load reported no image: ' + output.strip())
    image = docker_id(reference)
    if not image:
        raise ValueError('loaded image is not inspectable: ' + reference)
    container = run(['docker', 'create', '--label', 'eski-testbed-install=verify', image]).strip()
    try:
        with tempfile.TemporaryDirectory() as temporary:
            info_path = Path(temporary) / 'build-info.txt'
            run(['docker', 'cp', container + ':/usr/share/doc/eski/build-info.txt', str(info_path)])
            info = dict(line.split('=', 1) for line in info_path.read_text().splitlines() if '=' in line)
    finally:
        subprocess.run(['docker', 'rm', container], capture_output=True)
    if info.get('binary_sha256') != manifest['binary']['sha256'] or info.get('source_sha256') != manifest['source_sha256']:
        raise ValueError('the loaded image holds another binary or source tree than the manifest records')
    return dict(reference=reference, image_id=image, built_image_id=manifest['image_id'], binary_sha256=info['binary_sha256'],
                version=info.get('version') or manifest['binary'].get('version'), source_revision=manifest['source_revision'])


def install_jq(partial, design):
    tool = (design.get('tools') or {}).get('jq')
    if not tool:
        raise ValueError('the design does not declare the jq packages')
    download = partial / '.downloads'
    download.mkdir()
    run(['apt-get', 'download'] + ['%s=%s' % (package['name'], package['version']) for package in tool['packages']], cwd=download)
    target = partial / 'workspace' / 'tools' / 'jq'
    target.mkdir(parents=True)
    packages = []
    for package in tool['packages']:
        matches = sorted(download.glob('%s_*.deb' % package['name']))
        if len(matches) != 1:
            raise ValueError('apt-get download did not produce exactly one package for ' + package['name'])
        digest = sha(matches[0])
        if digest != package['sha256']:
            raise ValueError('package %s has sha256 %s, the design pins %s' % (matches[0].name, digest, package['sha256']))
        run(['dpkg-deb', '-x', str(matches[0]), str(target)])
        packages.append(dict(package, file=matches[0].name))
    shutil.rmtree(download)
    wrapper = partial / 'workspace' / 'tools' / 'bin' / 'jq'
    wrapper.parent.mkdir(parents=True)
    wrapper.write_text(JQ_WRAPPER.format(libraries=tool['libraries'], binary=tool['binary']))
    wrapper.chmod(0o755)
    version = run([str(wrapper), '--version']).strip()
    return dict(packages=packages, version=version)


def verify_overlay(partial):
    overlay = load(partial / 'overlay.json')
    if overlay.get('schema') != OVERLAY_SCHEMA:
        raise ValueError('unsupported overlay schema')
    present = {str(path.relative_to(partial)) for path in partial.rglob('*') if path.is_file()} - {'overlay.json'}
    if present != set(overlay['files']):
        raise ValueError('overlay file set differs from its manifest')
    for name, expected in overlay['files'].items():
        if sha(partial / name) != expected:
            raise ValueError('overlay file changed in transit: ' + name)
    return overlay


def preflight(root):
    done = subprocess.run([str(root / 'exam.sh'), 'inspect'], capture_output=True, text=True, timeout=600)
    if done.returncode:
        raise ValueError('preflight rejected: ' + (done.stderr or done.stdout).strip()[-1500:])
    return json.loads(done.stdout)


def remote(args, check=preflight, jq=install_jq, eski=load_eski, engine=pinned_image):
    base = Path(os.path.expanduser(args.base)).resolve()
    root = base / args.root
    if root.exists():
        raise ValueError('root already exists; earlier roots are never replaced: ' + str(root))
    overlay_path = Path(os.path.expanduser(args.overlay))
    if sha(overlay_path) != args.sha256:
        raise ValueError('overlay sha256 differs from the one copied')
    siblings = sorted(path.name for path in base.iterdir() if path.is_dir() and not path.name.startswith('.'))
    partial = base / ('.%s.partial-%d' % (args.root, os.getpid()))
    partial.mkdir()
    try:
        with tarfile.open(overlay_path) as handle:
            handle.extractall(partial, filter='data')
        overlay = verify_overlay(partial)
        design = load(partial / 'design.json')
        manifest = load(partial / 'image.json')
        tools = dict(jq=jq(partial, design))
        images = {'eski-docker': eski(partial, manifest)}
        for item in design['engines']:
            if item['target'] != 'eski-docker':
                images[item['target']] = engine(item['image'])
        images['memtier'] = engine(design['load_generator']['image'])
        cli = images.get('redis') if design['cli_image'] == next((item['image'] for item in design['engines'] if item['target'] == 'redis'), None) else engine(design['cli_image'])
        base_workspace = partial / 'workspace'
        files = {str(path.relative_to(base_workspace)): sha(path) for path in sorted(base_workspace.rglob('*')) if path.is_file()}
        roles = {target: value['image_id'] for target, value in images.items()}
        roles['cli'] = cli['image_id']
        profile = dict(schema=PROFILE_SCHEMA, source_revision=manifest['source_revision'], source_sha256=manifest['source_sha256'],
                       harness='bench/run.sh', tool_bin='tools/bin', dragonfly_threads=design['resources']['dragonfly_threads'],
                       images=roles, files=files)
        write(base_workspace / 'profile.json', profile)
        engines = []
        for item in design['engines']:
            image = images[item['target']]
            engines.append(dict(target=item['target'], label=item['label'], reference=image['reference'], image_id=image['image_id'],
                                version=image.get('version') if item['target'] == 'eski-docker' else item.get('version')))
        write(partial / 'engines.json', dict(engines=engines, load_generator=dict(design['load_generator'], image_id=roles['memtier'])))
        (partial / 'exam.sh').write_text(WRAPPER)
        (partial / 'exam.sh').chmod(0o755)
        (partial / 'fill.sh').write_text(FILL_WRAPPER)
        (partial / 'fill.sh').chmod(0o755)
        os.rename(partial, root)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    try:
        observed = check(root)
        phases = {phase: dict(identity=value['sha256'], plan_sha256=value['plan_sha256'], profile_sha256=value['profile_sha256'], config=value['config'])
                  for phase, value in observed['phases'].items()}
        benchmark = observed['phases']['benchmark']
        protocol = dict(schema=PROTOCOL_SCHEMA, root=args.root, design=design, engines=engines,
                        images={target: value['image_id'] for target, value in images.items()}, phases=phases,
                        machine=benchmark['host'], resources=benchmark['config'], tools=tools,
                        source=dict(revision=manifest['source_revision'], sha256=manifest['source_sha256'], image=images['eski-docker'],
                                    runner={name: benchmark['files'].get('bench/' + name) for name in RUNNER}),
                        frozen_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
        write(root / 'protocol.json', protocol)
        counts = {phase: len(load(root / 'workspace' / 'plans' / phase / 'plan.json')['items']) * len(value['config']['targets']) * value['config']['repetitions']
                  for phase, value in observed['phases'].items()}
        receipt = dict(schema=RECEIPT_SCHEMA, root=str(root), base=str(base), overlay=dict(path=str(overlay_path), sha256=args.sha256, files=len(overlay['files'])),
                       protocol_sha256=sha(root / 'protocol.json'), phase_identities={phase: value['identity'] for phase, value in phases.items()},
                       images={target: dict(reference=value['reference'], image_id=value['image_id'], pulled=value.get('pulled', False)) for target, value in images.items()},
                       tools=dict(jq=tools['jq']['version']), planned_measurements=counts, siblings=siblings, started=False,
                       start_command=str(root / 'exam.sh'), status_command=str(root / 'exam.sh') + ' status',
                       installed_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
        write(root / 'install.json', receipt)
    except BaseException:
        aside = base / ('.failed-%s-%d' % (args.root, int(time.time())))
        os.rename(root, aside)
        raise
    print(json.dumps(receipt, sort_keys=True))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description='Install the benchmark test bed into a new root on the test machine over ssh; never starts anything.')
    sub = parser.add_subparsers(dest='command')
    local = sub.add_parser('install')
    local.add_argument('--host', required=True)
    local.add_argument('--root', required=True)
    local.add_argument('--base', default=DEFAULT_BASE)
    local.add_argument('--design', type=Path, default=Path(__file__).with_name('design.json'))
    local.add_argument('--image-manifest', type=Path, default=Path(__file__).resolve().parents[1] / 'image.json')
    local.add_argument('--receipt', type=Path)
    machine = sub.add_parser('remote')
    machine.add_argument('--overlay', required=True)
    machine.add_argument('--sha256', required=True)
    machine.add_argument('--base', required=True)
    machine.add_argument('--root', required=True)
    arguments = list(sys.argv[1:] if argv is None else argv)
    if not arguments or arguments[0] not in ('install', 'remote', '-h', '--help'):
        arguments.insert(0, 'install')
    args = parser.parse_args(arguments)
    try:
        return remote(args) if args.command == 'remote' else install(args)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, tarfile.TarError) as error:
        print('install.py: error: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
