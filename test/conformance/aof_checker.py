#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import time
import uuid


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    fixture = Path.cwd().resolve()
    wrapper = Path(__file__).resolve()
    receipt = json.loads((fixture / 'fixture-receipt.json').read_text())
    if wrapper != fixture / 'src/redis-check-aof' or receipt.get('aof_checker', {}).get('sha256') != digest(wrapper):
        raise ValueError('checker must run inside its owned, hash-verified managed fixture')
    temporary = fixture / 'tests/tmp'
    asset = fixture / 'tests/assets/rdb-preamble.aof'
    for path in [temporary, asset]:
        if not path.exists() or not path.resolve().is_relative_to(fixture) or ',' in str(path):
            raise ValueError('checker fixture mounts are missing or outside the owned fixture')
    if not sys.argv[1:]:
        raise ValueError('checker requires an owned fixture AOF path')
    target = Path(sys.argv[-1]).resolve()
    if not target.is_relative_to(temporary.resolve()) and target != asset.resolve():
        raise ValueError('checker target is outside the owned temporary files and reference asset')
    asset_hash = digest(asset)
    if asset_hash != receipt['original_files']['tests/assets/rdb-preamble.aof']:
        raise ValueError('checker reference asset differs from the pinned test archive')
    image = os.environ.get('ESKI_AOF_CHECKER_IMAGE', '')
    if not re.fullmatch(r'(?:sha256:[0-9a-f]{64}|[^@\s]+@sha256:[0-9a-f]{64})', image):
        raise ValueError('ESKI_AOF_CHECKER_IMAGE must name an immutable, already local image ID or digest')
    image_info = json.loads(subprocess.check_output(['docker', 'image', 'inspect', image], text=True))[0]
    output = Path(os.environ.get('ESKI_AOF_CHECKER_RECEIPTS', str(fixture / '.aof-checker-receipts'))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    identity = uuid.uuid4().hex
    name = 'eski-aof-checker-' + identity
    labels = ['--label', 'eski.test.aof-checker=' + identity]
    base = ['docker', 'run', '--pull=never', '--rm', '--network', 'none', '--user', '%d:%d' % (os.getuid(), os.getgid())]
    process = None
    asset_copy = None
    names = [name, name + '-audit']
    result = {'wrapper_sha256': digest(wrapper), 'image_reference': image, 'image_id': image_info['Id'],
              'fixture': str(fixture), 'argv': sys.argv[1:], 'container': name, 'started': time.time()}
    exit_code = 2

    def interrupted(number, frame):
        raise InterruptedError(number)

    for number in [signal.SIGTERM, signal.SIGINT]:
        signal.signal(number, interrupted)
    try:
        cache = output / ('image-' + image_info['Id'].replace(':', '-') + '.json')
        if cache.exists():
            audit = json.loads(cache.read_text())
        else:
            checked = subprocess.run(base + ['--name', names[1]] + labels + ['--entrypoint', '/usr/bin/sha256sum', image, '/usr/local/bin/redis-check-aof'], capture_output=True, text=True, timeout=30, check=True)
            utility_hash = checked.stdout.split()[0]
            if not re.fullmatch('[0-9a-f]{64}', utility_hash):
                raise ValueError('checker utility hash is invalid')
            audit = {'image_id': image_info['Id'], 'utility_path': '/usr/local/bin/redis-check-aof', 'utility_sha256': utility_hash}
            staged = output / ('.audit-' + identity + '.json')
            staged.write_text(json.dumps(audit, indent=2) + '\n')
            staged.replace(cache)
        if audit['image_id'] != image_info['Id']:
            raise ValueError('checker cached image identity mismatch')
        result['utility_sha256'] = audit['utility_sha256']
        asset_mount = 'type=bind,src=%s,dst=%s,readonly' % (asset, asset)
        if target == asset.resolve():
            work = temporary / '.aof-checker-assets'
            work.mkdir(exist_ok=True)
            asset_copy = work / (identity + '.aof')
            shutil.copyfile(asset, asset_copy)
            asset_mount = 'type=bind,src=%s,dst=%s' % (asset_copy, asset)
            result['asset_work_copy'] = str(asset_copy)
        command = base + ['--name', name] + labels + ['-i', '--workdir', str(fixture),
                   '--mount', 'type=bind,src=%s,dst=%s' % (temporary, temporary),
                   '--mount', asset_mount,
                   '--entrypoint', '/usr/local/bin/redis-check-aof', image] + sys.argv[1:]
        process = subprocess.Popen(command)
        exit_code = process.wait(timeout=120)
    except InterruptedError as error:
        exit_code = 128 + error.args[0]
        result['interrupted'] = error.args[0]
    except subprocess.TimeoutExpired:
        exit_code = 124
        result['timeout_seconds'] = 120
    finally:
        for number in [signal.SIGTERM, signal.SIGINT]:
            signal.signal(number, signal.SIG_IGN)
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        for owned_name in names:
            subprocess.run(['docker', 'rm', '-f', owned_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        if asset_copy is not None:
            asset_copy.unlink(missing_ok=True)
            try:
                asset_copy.parent.rmdir()
            except OSError:
                pass
        result['asset_source_sha256'] = digest(asset)
        result['asset_source_unchanged'] = result['asset_source_sha256'] == asset_hash
        if not result['asset_source_unchanged']:
            exit_code = 2
            print('AOF checker fixture error: pristine asset changed', file=sys.stderr)
        result.update(exit_code=exit_code, finished=time.time())
        (output / (identity + '.json')).write_text(json.dumps(result, indent=2) + '\n')
    return exit_code


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('AOF checker fixture error: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
