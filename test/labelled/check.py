import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


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


def load_expected(path):
    data = json.loads(Path(path).read_text())
    entries = []
    for category in data['categories']:
        for reason in ('id', 'reason', 'doc'):
            if not category.get(reason):
                raise SystemExit('%s: category without %s' % (path, reason))
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
    parser.add_argument('runner', choices=('conformance', 'vectorset', 'compare', 'smoke'))
    parser.add_argument('--result', required=True, help='the labelled run: a summary JSON, or the smoke log')
    parser.add_argument('--reference', help='labels-off summary for conformance and vectorset')
    parser.add_argument('--expected', help='expected differences (default: test/labelled/expected/RUNNER.json)')
    args = parser.parse_args()
    expected_path = args.expected or ROOT / 'test/labelled/expected' / ('%s.json' % args.runner)
    data, entries = load_expected(expected_path)
    if data.get('runner') != args.runner:
        raise SystemExit('%s describes runner %r, not %s' % (expected_path, data.get('runner'), args.runner))
    if args.runner in ('conformance', 'vectorset'):
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
    print('labelled %s: %d differences, %d unexpected, %d stale; by category: %s' % (
        args.runner, len(differences), len(unexpected), len(stale), summary))
    return 1 if unexpected or stale else 0


if __name__ == '__main__':
    sys.exit(main())
