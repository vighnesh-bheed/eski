import builtins
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
spec = importlib.util.spec_from_file_location('baseline_plan', HERE / 'baseline.py')
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)
PLACEHOLDER = re.compile(r'\{([a-z]+)\}')
KNOWN = {'dir', 'new', 'rep', 'json', 'port', 'odd', 'pid'}
MOVED = ('stock-exam', 'aof-append', 'change-log-append', 'graph-load', 'search-json', 'simulation-rate')


def context(profile='rehearsal', out=None):
    return dict(profile=profile, out=out or '/srv/run/run-1',
                binaries={key: '/srv/run/bin/' + key for key in baseline.BINARY_KEYS},
                server_cpus='2', client_cpus='4-7', control_cpus='3', ports=[17840, 17879],
                images={key: 'sha256:' + '%064x' % index for index, key in enumerate(baseline.IMAGE_KEYS, 1)},
                limits=dict(server_memory='8g', client_memory='2g', maxmemory=6442450944), python=[sys.executable, '-IB'],
                seeds=dict(first=8, count=256, steps=128))


def scripts(command):
    found = []
    for part in command:
        if re.fullmatch(r'(bench|test|tools)/[A-Za-z0-9_/.-]+\.(py|sh)', part):
            found.append(part)
    return found


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.plans = {profile: baseline.steps(context(profile)) for profile in baseline.PROFILES}

    def test_names_are_unique_and_the_same_in_both_profiles(self):
        for profile, rows in self.plans.items():
            names = [row['name'] for row in rows]
            self.assertEqual(len(names), len(set(names)), profile)
            for name in names:
                self.assertRegex(name, baseline.NAME)
        self.assertEqual([r['name'] for r in self.plans['full']], [r['name'] for r in self.plans['rehearsal']])

    def test_every_area_is_covered_or_listed(self):
        covered = {row['area'] for row in self.plans['full']}
        for row in self.plans['full']:
            self.assertIn(row['area'], baseline.AREAS)
        listed = {key.split(':', 1)[0] for key in baseline.UNCOVERED}
        missing = set(baseline.AREAS) - covered - set(baseline.UNCOVERED_AREAS)
        self.assertEqual(missing, set())
        self.assertTrue(all(reason for reason in baseline.UNCOVERED.values()))
        self.assertTrue(listed)

    def test_the_moved_measurements_are_present(self):
        names = {row['name'] for row in self.plans['full']}
        for name in MOVED:
            self.assertIn(name, names)

    def test_every_command_points_at_a_file_that_exists(self):
        for profile, rows in self.plans.items():
            for row in rows:
                found = scripts(row['command'])
                self.assertTrue(found, row['name'])
                for script in found:
                    self.assertTrue((ROOT / script).is_file(), '%s: %s' % (row['name'], script))
                for part in row['command']:
                    for name in PLACEHOLDER.findall(part):
                        self.assertIn(name, KNOWN, row['name'])

    def test_fields_types_and_artifacts_inside_out(self):
        for profile, rows in self.plans.items():
            for row in rows:
                self.assertEqual(set(row), {'name', 'area', 'command', 'artifact', 'timeout', 'environment', 'needs', 'estimate_seconds'})
                self.assertTrue(all(isinstance(part, str) for part in row['command']))
                self.assertIsInstance(row['timeout'], int)
                self.assertIsInstance(row['estimate_seconds'], int)
                self.assertGreater(row['timeout'], row['estimate_seconds'])
                self.assertIsInstance(row['environment'], dict)
                self.assertTrue(set(row['needs']) <= set(baseline.IMAGE_KEYS))
                artifact = Path(row['artifact'])
                self.assertFalse(artifact.is_absolute())
                self.assertNotIn('..', artifact.parts)
                self.assertEqual(artifact.parts[0], row['name'])

    def test_steps_write_only_under_their_own_directory(self):
        out = context()['out']
        for row in self.plans['rehearsal']:
            for part in row['command']:
                if part.startswith(out):
                    self.assertTrue(part == out or part.startswith(out + '/' + row['name']), '%s: %s' % (row['name'], part))

    def test_ports_stay_in_the_given_block(self):
        first, last = context()['ports']
        for row in self.plans['full']:
            command = row['command']
            for index, part in enumerate(command[:-1]):
                if part == '--port':
                    self.assertTrue(first <= int(command[index + 1]) <= last - 9, row['name'])
                if part == '--ports':
                    low, high = map(int, command[index + 1].split('-'))
                    self.assertTrue(first <= low <= high <= last, row['name'])

    def test_rehearsal_is_smaller_than_full(self):
        full = sum(row['estimate_seconds'] for row in self.plans['full'])
        rehearsal = sum(row['estimate_seconds'] for row in self.plans['rehearsal'])
        self.assertLess(rehearsal * 10, full)
        self.assertLess(rehearsal, 1800)

    def test_calling_steps_has_no_side_effects(self):
        with tempfile.TemporaryDirectory() as folder:
            out = str(Path(folder) / 'never-created')
            refuse = mock.Mock(side_effect=AssertionError('side effect'))
            with mock.patch.object(builtins, 'open', refuse), mock.patch.object(subprocess, 'Popen', refuse), \
                    mock.patch.object(os, 'mkdir', refuse), mock.patch.object(os, 'makedirs', refuse), mock.patch.object(os, 'system', refuse):
                rows = baseline.steps(context('full', out))
            self.assertTrue(rows)
            self.assertFalse(Path(out).exists())
            self.assertEqual(os.listdir(folder), [])

    def test_invalid_contexts_are_refused(self):
        for change in (dict(profile='quick'), dict(out='relative'), dict(ports=[17840, 17850]), dict(python=[])):
            with self.assertRaises(ValueError):
                baseline.steps(dict(context(), **change))
        bad = context()
        del bad['seeds']
        with self.assertRaises(ValueError):
            baseline.steps(bad)
        bad = context()
        bad['images'] = dict(bad['images'], memtier=None)
        with self.assertRaises(ValueError):
            baseline.steps(bad)

    def test_preflight_context_with_nothing_resolved_still_plans(self):
        with tempfile.TemporaryDirectory() as folder:
            early = context('full', str(Path(folder) / 'not-yet'))
            early['images'] = {key: '' for key in baseline.IMAGE_KEYS}
            early['binaries'] = {key: str(Path(folder) / 'missing' / key) for key in baseline.BINARY_KEYS}
            rows = baseline.steps(early)
            self.assertEqual([r['name'] for r in rows], [r['name'] for r in self.plans['full']])
            self.assertEqual(os.listdir(folder), [])

    def test_names_avoid_the_coordinators_own(self):
        for row in self.plans['full']:
            self.assertNotIn(row['name'], baseline.RESERVED)
            self.assertFalse(row['name'].startswith(baseline.RESERVED_PREFIXES), row['name'])

    def test_controller_cpus_reach_the_steps_that_need_a_controller(self):
        for profile, rows in self.plans.items():
            for row in rows:
                command = row['command']
                if row['name'] in ('stock-exam', 'stock-spec', 'stock-fill', 'noise-floor'):
                    self.assertEqual(command[command.index('--control-cpus') + 1], '3', row['name'])
                    self.assertNotEqual(command[0], 'taskset', row['name'])
                else:
                    self.assertNotIn('--control-cpus', command, row['name'])
        for change in (dict(control_cpus='2'), dict(control_cpus='5'), dict(control_cpus=''), dict(control_cpus='x')):
            with self.assertRaises(ValueError, msg=str(change)):
                baseline.steps(dict(context(), **change))

    def test_downloads_name_the_archive_the_step_reads(self):
        text = (ROOT / 'bench/run.sh').read_text()
        version = re.search(r'^SPEC_VERSION="([^"]+)"$', text, re.MULTILINE)[1]
        digest = re.search(r'^SPEC_SHA256="([^"]+)"$', text, re.MULTILINE)[1]
        exam = (ROOT / 'bench/stock_exam.py').read_text()
        names = {row['name'] for row in self.plans['full']}
        self.assertTrue(baseline.DOWNLOADS)
        for row in baseline.DOWNLOADS:
            self.assertEqual(set(row), {'name', 'url', 'sha256', 'path', 'steps'})
            self.assertTrue(row['path'].startswith('.build/downloads/') and '..' not in Path(row['path']).parts)
            self.assertTrue(set(row['steps']) <= names)
            self.assertIn(row['sha256'], exam)
            self.assertIn(row['url'], exam)
        spec = next(row for row in baseline.DOWNLOADS if 'stock-spec' in row['steps'])
        self.assertEqual(spec['sha256'], digest)
        self.assertIn('v%s.tar.gz' % version, spec['url'])
        self.assertEqual(spec['path'], '.build/downloads/redis-benchmarks-specification-%s.tar.gz' % version)
        for profile, rows in self.plans.items():
            command = next(row['command'] for row in rows if row['name'] == 'stock-spec')
            self.assertEqual(command[command.index('--spec-archive') + 1], spec['path'])

    def test_the_full_profile_cannot_be_softened(self):
        for row in self.plans['full']:
            command = row['command']
            self.assertNotIn('--advisory-gates', command, row['name'])
            self.assertFalse(any('rehearsal' in part for part in command), row['name'])
            self.assertEqual(command[command.index('--profile') + 1], 'full', row['name'])
            self.assertFalse(any(key.startswith(('BENCH_', 'ESKI_')) for key in row['environment']), row['name'])
        for row in self.plans['rehearsal']:
            self.assertEqual(row['command'][row['command'].index('--profile') + 1], 'rehearsal', row['name'])

    def test_images_named_by_needs_are_the_ones_the_command_uses(self):
        images = context()['images']
        for row in self.plans['full']:
            text = ' '.join(row['command'])
            for key in row['needs']:
                self.assertIn(images[key], text, row['name'])


if __name__ == '__main__':
    unittest.main()
