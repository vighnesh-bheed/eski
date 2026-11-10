import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODES = ('labelled', 'owners-shared', 'owners-user', 'owners-only-user')
SUITES = ('conformance', 'scripting', 'vectorset')


def suite_differences(reference, result):
    ref_units = reference.get('units', {})
    differences = set()
    passing = set()
    for name, unit in result.get('units', {}).items():
        if name not in ref_units:
            continue
        ref_tests = ref_units[name].get('tests', {})
        for test, counts in ref_tests.items():
            before = counts.get('passed', 0)
            if before <= 0:
                continue
            key = '%s::%s' % (name, test)
            passing.add(key)
            now = unit.get('tests', {}).get(test, {}).get('passed', 0)
            if now < before:
                differences.add(key)
    return differences, passing


def compare_differences(result):
    differences = set()
    for step in result.get('steps', []):
        if not step.get('ok'):
            differences.add(step['label'])
    return differences, None


def smoke_differences(log):
    differences = set()
    for line in log.splitlines():
        if line.startswith('FAIL: '):
            differences.add(line[len('FAIL: '):])
    if not re.search(r'^passed: \d+ failed: \d+$', log, re.M):
        differences.add('smoke ran to its summary line')
    return differences, None


def anchors(doc):
    found = set()
    for line in doc.read_text().splitlines():
        if line.startswith('#'):
            title = line.lstrip('#').strip().lower()
            slug = ''.join(c for c in title if c.isalnum() or c in ' -_').replace(' ', '-')
            found.add(slug)
    return found


def check_doc(path, link):
    name, _, anchor = link.partition('#')
    doc = ROOT / name
    if not name.startswith('docs/') or not doc.is_file():
        raise SystemExit('%s: documentation %s does not exist' % (path, link))
    if anchor and anchor not in anchors(doc):
        raise SystemExit('%s: %s has no section #%s' % (path, name, anchor))


def load_expected(path):
    data = json.loads(Path(path).read_text())
    entries = []
    for category in data['categories']:
        for reason in ('id', 'reason', 'doc'):
            if not category.get(reason):
                raise SystemExit('%s: category without %s' % (path, reason))
        check_doc(path, category['doc'])
        for entry in category.get('entries', []):
            entries.append(((entry, False), category['id']))
        for pattern in category.get('patterns', []):
            entries.append(((pattern, True), category['id']))
    return data, entries


def matches(entry, name):
    text, pattern = entry
    if pattern:
        return fnmatch.fnmatchcase(name, text)
    return text == name


def main():
    parser = argparse.ArgumentParser(description='Compare a labelled-mode run with labels-off and its expected differences.')
    parser.add_argument('runner', choices=SUITES + ('compare', 'smoke'))
    parser.add_argument('--mode', choices=MODES, default='labelled')
    parser.add_argument('--result', required=True, help='the run under test: a summary JSON, or the smoke log')
    parser.add_argument('--reference', help='labels-off summary for the suite, its scripting unit and the vector set unit')
    parser.add_argument('--expected', help='expected differences (default: test/labelled/expected/RUNNER.json in labelled mode, '
                        'test/labelled/expected/MODE/RUNNER.json otherwise)')
    args = parser.parse_args()
    folder = ROOT / 'test/labelled/expected'
    if args.mode != 'labelled':
        folder = folder / args.mode
    expected_path = args.expected or folder / ('%s.json' % args.runner)
    data, entries = load_expected(expected_path)
    if data.get('runner') != args.runner:
        raise SystemExit('%s describes runner %r, not %s' % (expected_path, data.get('runner'), args.runner))
    if data.get('mode', 'labelled') != args.mode:
        raise SystemExit('%s describes mode %r, not %s' % (expected_path, data.get('mode', 'labelled'), args.mode))
    if args.runner in SUITES:
        if not args.reference:
            raise SystemExit('--reference is required for ' + args.runner)
        differences, passing = suite_differences(json.loads(Path(args.reference).read_text()), json.loads(Path(args.result).read_text()))
    elif args.runner == 'compare':
        differences, passing = compare_differences(json.loads(Path(args.result).read_text()))
    else:
        differences, passing = smoke_differences(Path(args.result).read_text(errors='replace'))
    unexpected = sorted(d for d in differences if not any(matches(e, d) for e, _ in entries))
    stale = []
    counts = {}
    for entry, category in entries:
        hit = [d for d in differences if matches(entry, d)]
        if hit:
            counts[category] = counts.get(category, 0) + len(hit)
            continue
        if passing is not None and not any(matches(entry, p) for p in passing):
            continue
        stale.append((entry, category))
    for name in unexpected:
        print('unexpected difference: %s' % name)
    for entry, category in stale:
        print('expected difference no longer seen (%s): %s' % (category, entry[0]))
    summary = ', '.join('%s %d' % (c['id'], counts.get(c['id'], 0)) for c in data['categories'])
    print('%s %s: %d differences, %d unexpected, %d stale; by category: %s' % (
        args.mode, args.runner, len(differences), len(unexpected), len(stale), summary))
    return 1 if unexpected or stale else 0


if __name__ == '__main__':
    sys.exit(main())
