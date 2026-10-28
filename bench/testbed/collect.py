import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import shutil
import subprocess
import sys
import tarfile
import time

sys.dont_write_bytecode = True

RECEIPTS = {'results': 'exports/receipt.json', 'fill': 'exports/fill-receipt.json'}
EXPORT_SCHEMA = 'eski-exam-export-v1'


class CollectError(ValueError):
    pass


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def write(path, value):
    path = Path(path)
    temporary = path.with_name('.' + path.name + '.part')
    temporary.write_text(json.dumps(value, indent=1, sort_keys=True) + '\n')
    os.replace(temporary, path)


def canonical_name(name):
    if not isinstance(name, str) or not name or '\\' in name or '\x00' in name:
        raise CollectError('invalid archive path: %r' % name)
    parts = PurePosixPath(name).parts
    if PurePosixPath(name).is_absolute() or any(part in ('', '.', '..') for part in parts) or name != str(PurePosixPath(*parts)):
        raise CollectError('archive path escapes or is not canonical: ' + name)
    return name


def check_receipt(receipt):
    if receipt.get('schema') != EXPORT_SCHEMA:
        raise CollectError('unsupported receipt schema')
    archive = receipt.get('archive')
    if not isinstance(archive, str) or '/' in archive or not archive.endswith('.tar.gz'):
        raise CollectError('receipt archive name is not a plain .tar.gz name')
    if not isinstance(receipt.get('sha256'), str) or len(receipt['sha256']) != 64:
        raise CollectError('receipt lacks a sha256')
    if type(receipt.get('bytes')) is not int or receipt['bytes'] <= 0:
        raise CollectError('receipt lacks a byte count')
    canonical_name(receipt.get('inventory'))
    return receipt


def check_inventory(partial, names, inventory_name):
    if inventory_name not in names:
        raise CollectError('the archive has no inventory at ' + inventory_name)
    inventory = json.loads((partial / inventory_name).read_text())
    if not isinstance(inventory, dict):
        raise CollectError('inventory is not an object')
    if set(inventory) != names - {inventory_name}:
        missing = sorted(set(inventory) - names)[:5]
        extra = sorted(names - {inventory_name} - set(inventory))[:5]
        raise CollectError('archive file set differs from the inventory: missing %s, extra %s' % (missing, extra))
    for name, item in sorted(inventory.items()):
        path = partial / canonical_name(name)
        if path.is_symlink() or not path.is_file():
            raise CollectError('inventory entry is not a regular file: ' + name)
        if not isinstance(item, dict) or sha(path) != item.get('sha256') or path.stat().st_size != item.get('bytes'):
            raise CollectError('file sha256 or size differs from the inventory: ' + name)


def verify(archive, receipt, destination):
    archive, destination = Path(archive), Path(destination)
    check_receipt(receipt)
    digest, size = sha(archive), archive.stat().st_size
    if digest != receipt['sha256'] or size != receipt['bytes']:
        raise CollectError('archive sha256 or size differs from the receipt: %s %d' % (digest, size))
    if destination.exists():
        raise CollectError('destination exists; collected results are never overwritten: ' + str(destination))
    with tarfile.open(archive, 'r:gz') as handle:
        members = handle.getmembers()
        names = set()
        for member in members:
            canonical_name(member.name)
            if not (member.isfile() or member.isdir()):
                raise CollectError('archive member is neither a file nor a directory: ' + member.name)
            if member.isfile():
                if member.name in names:
                    raise CollectError('duplicate archive member: ' + member.name)
                names.add(member.name)
        partial = destination.with_name('.' + destination.name + '.partial')
        if partial.exists():
            raise CollectError('a partial extraction is in the way: ' + str(partial))
        partial.mkdir(parents=True)
        try:
            handle.extractall(partial, filter='data')
            check_inventory(partial, names, receipt['inventory'])
        except BaseException:
            shutil.rmtree(partial, ignore_errors=True)
            raise
    os.rename(partial, destination)
    inventory = json.loads((destination / receipt['inventory']).read_text())
    return dict(archive=str(archive), sha256=digest, bytes=size, files=len(inventory), destination=str(destination), verified_at=time.time())


def remote_path(base, root, relative):
    if base.startswith('~/') and ' ' not in base:
        return '%s/%s/%s' % (base, shlex.quote(root), relative)
    return shlex.quote('%s/%s/%s' % (base, root, relative))


def fetch(args):
    command = ['ssh', '-o', 'BatchMode=yes', args.host]
    done = subprocess.run(command + ['cat ' + remote_path(args.base, args.root, RECEIPTS[args.kind])], capture_output=True, text=True)
    if done.returncode:
        raise CollectError('cannot read the remote receipt: ' + done.stderr.strip())
    receipt = check_receipt(json.loads(done.stdout))
    directory = Path(args.output) / args.root
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / receipt['archive']
    stem = receipt['archive'][:-len('.tar.gz')]
    destination = directory / stem
    if archive.exists() or destination.exists():
        raise CollectError('already collected: ' + str(archive))
    partial = directory / ('.' + receipt['archive'] + '.part')
    with partial.open('wb') as handle:
        done = subprocess.run(command + ['cat ' + remote_path(args.base, args.root, 'exports/' + receipt['archive'])], stdout=handle, stderr=subprocess.PIPE)
    if done.returncode:
        partial.unlink(missing_ok=True)
        raise CollectError('archive transfer failed: ' + done.stderr.decode(errors='replace').strip())
    os.rename(partial, archive)
    write(directory / (stem + '.receipt.json'), receipt)
    result = verify(archive, receipt, destination)
    result.update(kind=args.kind, host=args.host, root=args.root, receipt=receipt)
    write(directory / (stem + '.collected.json'), result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description='Fetch an export archive of the test bed and verify it against its receipt and inventory.')
    sub = parser.add_subparsers(dest='command', required=True)
    remote = sub.add_parser('fetch')
    remote.add_argument('--host', required=True)
    remote.add_argument('--root', required=True)
    remote.add_argument('--base', default='~/eski-exam')
    remote.add_argument('--kind', choices=sorted(RECEIPTS), default='results')
    remote.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / 'results')
    local = sub.add_parser('verify')
    local.add_argument('archive', type=Path)
    local.add_argument('--receipt', type=Path, required=True)
    local.add_argument('--extract', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == 'fetch':
            result = fetch(args)
        else:
            result = verify(args.archive, json.loads(args.receipt.read_text()), args.extract)
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError) as error:
        print('collect.py: error: ' + str(error), file=sys.stderr)
        return 2
    print(json.dumps(result, indent=1, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
