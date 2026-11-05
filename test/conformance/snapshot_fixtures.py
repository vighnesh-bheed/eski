import argparse
import hashlib
import json
from pathlib import Path
import shutil


def snapshot(tree, output):
    root = Path(tree) / 'tests/tmp'
    destination = Path(output)
    destination.mkdir(parents=True, exist_ok=False)
    records = []
    for path in sorted(root.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        if not path.name.startswith(('stdout', 'stderr', 'redis.conf')):
            continue
        relative = path.relative_to(root)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        records.append({'path': str(relative), 'bytes': target.stat().st_size,
                        'sha256': hashlib.sha256(target.read_bytes()).hexdigest()})
    (destination / 'snapshot.json').write_text(json.dumps({'files': records, 'data_files_copied': False}, indent=2) + '\n')


    for path in root.iterdir():
        if path.name == '.gitignore':
            continue
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)


def main():
    parser = argparse.ArgumentParser(description='Preserve managed server logs/configs before upstream fixture cleanup; exclude RDB/AOF data.')
    parser.add_argument('--tree', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    snapshot(args.tree, args.output)


if __name__ == '__main__':
    main()
