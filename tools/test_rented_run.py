import argparse
import contextlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rented_run

AREAS = ('stock', 'memory', 'search-hash', 'search-json', 'full-text', 'vector-search', 'hybrid', 'aggregate', 'json',
         'vector-sets', 'persistence', 'change-log', 'access', 'internal', 'simulation', 'trace')


def plan_module(rows, areas=AREAS, downloads=()):
    module = types.ModuleType('plan')
    module.AREAS = areas
    module.DOWNLOADS = downloads
    module.steps = lambda context: [dict(row) for row in rows]
    return module


def plan_row(name, area='stock', fail=False, measured=None, own_directory=False):
    report = {'exit_code': int(fail)}
    if measured:
        report['measured'] = measured
    artifact = f'{name}/result.json' if own_directory else f'plan/{name}.json'
    script = 'import json,sys,pathlib; p=pathlib.Path(sys.argv[1]); p.parent.mkdir(parents=True, exist_ok=%s); ' \
             'p.write_text(json.dumps(%r)); sys.exit(%d)' % (not own_directory, report, int(fail))
    return {'name': name, 'area': area, 'artifact': artifact, 'timeout': 60, 'environment': {},
            'needs': [], 'estimate_seconds': 1, 'command': [sys.executable, '-c', script, '{out}/' + artifact]}


def ready(rehearsal=False, plan=None):
    images = {key: {'name': key, 'id': 'sha256:' + '0' * 64} for key in
              ('redis', 'valkey', 'dragonfly', 'memtier', 'redis-search', 'smoke-redis', 'memcached')}
    sizes = dict(rented_run.REHEARSAL_SIZES if rehearsal else rented_run.FULL_SIZES)
    return {'errors': [], 'timing_refusals': [], 'quiet_findings': [], 'sizes': sizes, 'rehearsal': rehearsal,
            'platform': {'system': 'Linux'}, 'source': {'revision': 'a' * 40, 'sha256': 'b' * 64},
            'tools': {'odin': {'path': '/bin/true', 'version': 'odin version ' + rented_run.ODIN_VERSION}},
            'interpreters': {}, 'images': images, 'boot_id_sha256': 'c' * 64,
            'input_files': {'expected': {'path': '/dev/null', 'sha256': 'd' * 64}},
            'settings': {'stock_limits': {'server_memory': '8g', 'client_memory': '2g', 'maxmemory': 1}},
            'plan': plan}


def arguments(out, **changes):
    values = dict(out=out, resume=None, revision='a' * 40, server_cpus='0', client_cpus='1', control_cpus='2', capture=None,
                  observed=None, expected=None, modern_python=None, llama_python=None, input_sums=None,
                  port_base=17840, min_free_gib=1, first_seed=8, seeds=2, steps=4, cycles=2, transactions=3,
                  plan_profile='rehearsal', only=None, skip=None, allow_unqualified=False, allow_noisy_host=False,
                  rehearsal=True)
    values.update(changes)
    return argparse.Namespace(**values)


class StubRun(rented_run.Run):
    fail = ()
    calls = None

    def step(self, name, args, timeout, artifact=None, extra=None, kind='correctness', inputs=None):
        self.calls.append((name, [str(part) for part in args]))
        if kind == 'baseline':
            command = [part.replace('{out}', str(self.out)) for part in args]
            return super().step(name, command, timeout, artifact, extra, kind, inputs)
        result = {'exit_code': int(name in self.fail)}
        for key, binary in rented_run.BUILD_OUTPUTS.items():
            if name == key:
                (self.bin / binary).write_text('stub ' + name)
        if name == 'virtual':
            result.update(sha256=rented_run.digest(self.worker), first_seed=self.sizes['first_seed'], seeds=self.sizes['seeds'],
                          completed_seeds=self.sizes['seeds'], steps=self.sizes['steps'], failures=[])
        elif name == 'native':
            result.update(sha256=rented_run.digest(self.server), recovered_cycles=self.sizes['cycles'], appendfsync='always',
                          acknowledged_transactions=self.sizes['cycles'] * self.sizes['transactions'])
        elif name == 'change-log-probe':
            result['rows'] = [{'change_log': flag, 'timed': False, 'fsync': 'always', 'writes': self.sizes['probe_writes'],
                               'dbsize': self.sizes['probe_writes'] + 1, 'all_writes_mirrored': True} for flag in (False, True)]
        elif name == 'search-json-probe':
            result.update(timed=False, rows=[{'target': target, 'checked_requests': 8} for target in ('eski', 'redis-search')])
        elif name == 'functional':
            steps = rented_run.required_functional_steps('light')
            result.update(profile='light', complete=not result['exit_code'], server_sha256=rented_run.digest(self.server),
                          planned=steps, steps=[{'step': step, 'exit_code': int(result['exit_code'] and step == steps[-1])} for step in steps])
        script = ['import json,sys', 'from pathlib import Path']
        if artifact:
            script += [f'out=Path({str(self.out / artifact)!r})', 'out.parent.mkdir(parents=True, exist_ok=True)',
                       f'out.write_text(json.dumps({result!r}))']
        script.append(f'sys.exit({result["exit_code"]})')
        return super().step(name, [sys.executable, '-IB', '-c', '\n'.join(script)], 30, artifact, extra, kind, inputs)


class RunStages(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.out = Path(self.folder.name)
        self.patches = [mock.patch.object(rented_run, 'source_fingerprint', lambda revision: 'b' * 64),
                        mock.patch.object(rented_run, 'probe', lambda command, input=None, timeout=20: 'sha256:' + '0' * 64)]
        for patch in self.patches:
            patch.start()

    def tearDown(self):
        for patch in self.patches:
            patch.stop()
        sys.stdout, sys.stderr = sys.__stdout__, sys.__stderr__
        self.folder.cleanup()

    def run_once(self, args, plan, fail=(), previous=None, state=None):
        StubRun.fail, StubRun.calls = fail, []
        with mock.patch.object(rented_run, 'load_plan', lambda: plan), contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            run = StubRun(args, state or ready(rehearsal=args.rehearsal, plan={'steps': []}), previous, log_output=False)
            code = run.execute()
        return run, code, [name for name, _ in StubRun.calls]

    def test_baseline_steps_are_independent_and_a_failed_one_completes_alone(self):
        plan = plan_module([plan_row('one'), plan_row('two', fail=True), plan_row('three', 'trace')])
        run, code, called = self.run_once(arguments(self.out), plan)
        self.assertEqual(code, 1)
        self.assertEqual(called[-3:], ['one', 'two', 'three'])
        self.assertTrue(run.passed('one') and run.passed('three') and not run.passed('two'))
        owed = [row for row in run.report['owed'] if row.get('kind') == 'baseline']
        self.assertEqual([row['stage'] for row in owed], ['two'])
        self.assertEqual(owed[0]['command'][-2:], ['--only', 'two'])
        self.assertTrue(Path(run.report['bundle']['main']['path']).is_file())
        plan = plan_module([plan_row('one'), plan_row('two'), plan_row('three', 'trace')])
        args = arguments(self.out, resume=run.out, only=['two'])
        again, code, called = self.run_once(args, plan, previous=run.out)
        self.assertEqual(code, 0)
        self.assertEqual(called, ['two'])
        self.assertEqual(len(again.report['stages']['two']['history']), 1)

    def test_correctness_failure_blocks_timing_unless_unqualified_is_allowed(self):
        plan = plan_module([plan_row('one')])
        run, code, called = self.run_once(arguments(self.out), plan, fail=('native',))
        self.assertEqual(code, 1)
        self.assertNotIn('one', called)
        self.assertIn('correctness is incomplete', ' '.join(run.report['timing']['blocked_by']))
        self.assertFalse(run.report['qualified'])
        self.assertIn('native', [row['stage'] for row in run.report['correctness']['failures']])
        run, code, called = self.run_once(arguments(self.out, allow_unqualified=True), plan, fail=('native',))
        self.assertIn('one', called)
        self.assertFalse(run.report['qualified'])
        self.assertEqual([row['stage'] for row in run.report['unqualified']['failures']], ['native'])
        self.assertFalse(run.report['stages']['one']['qualified'])

    def test_resume_reruns_only_failed_stages_and_passes_the_functional_resume(self):
        plan = plan_module([plan_row('one')])
        run, code, called = self.run_once(arguments(self.out), plan, fail=('functional', 'virtual'))
        self.assertEqual(code, 1)
        again, code, called = self.run_once(arguments(self.out, resume=run.out), plan, previous=run.out)
        self.assertEqual(code, 0)
        self.assertEqual(called, ['functional', 'virtual', 'one'])
        functional = dict(StubRun.calls)['functional']
        self.assertEqual(functional[functional.index('--resume') + 1], str(run.out / 'functional'))
        self.assertEqual(functional[functional.index('--out') + 1], str(run.out / 'functional-2'))
        self.assertTrue(again.report['qualified'] is False and again.report['correctness']['complete'])

    def test_changed_expected_input_reruns_the_functional_stage_only(self):
        plan = plan_module([])
        expected = self.out / 'expected.json'
        expected.write_text('{"categories": []}\n')
        state = ready(rehearsal=True, plan={'steps': []})
        state['input_files']['expected'] = {'path': str(expected), 'sha256': rented_run.digest(expected)}
        run, code, called = self.run_once(arguments(self.out, expected=expected), plan, state=state)
        self.assertEqual(code, 0)
        expected.write_text('{"categories": [] }\n')
        state['input_files']['expected']['sha256'] = rented_run.digest(expected)
        again, code, called = self.run_once(arguments(self.out, expected=expected, resume=run.out), plan,
                                            previous=run.out, state=state)
        self.assertEqual(called, ['functional'])
        self.assertTrue((run.out / 'inputs/expected-2.json').is_file())
        self.assertEqual(code, 0)

    def test_a_step_measured_with_exclusions_is_kept_and_rerun_only_by_name(self):
        measured = {'excluded': 2, 'valid': 30, 'cases': 32, 'list': 'phases.benchmark.excluded'}
        plan = plan_module([plan_row('stock-exam', fail=True, measured=measured), plan_row('two')])
        run, code, called = self.run_once(arguments(self.out), plan)
        self.assertEqual(code, 0)
        row = run.report['stages']['stock-exam']
        self.assertEqual(row['state'], 'measured')
        self.assertEqual(row['measured']['listed_in'], 'plan/stock-exam.json, field phases.benchmark.excluded')
        owed = run.report['owed']
        self.assertEqual([(entry['stage'], entry['state'], entry.get('choice')) for entry in owed], [('stock-exam', 'measured', True)])
        self.assertIn('operator', owed[0]['note'])
        self.assertEqual(run.report['measured_with_exclusions']['stock-exam']['excluded'], 2)
        again, code, called = self.run_once(arguments(self.out, resume=run.out), plan, previous=run.out)
        self.assertEqual((code, called), (0, []))
        again, code, called = self.run_once(arguments(self.out, resume=run.out, only=['stock']), plan, previous=run.out)
        self.assertEqual(called, [])
        again, code, called = self.run_once(arguments(self.out, resume=run.out, only=['stock-exam']), plan, previous=run.out)
        self.assertEqual(called, ['stock-exam'])
        broken = {'excluded': 0, 'valid': 30, 'cases': 30, 'list': 'x'}
        run, code, called = self.run_once(arguments(self.out), plan_module([plan_row('stock-spec', fail=True, measured=broken)]))
        self.assertEqual(code, 1)
        self.assertNotIn('state', run.report['stages']['stock-spec'])

    def test_a_rerun_step_gets_a_fresh_directory_and_keeps_the_old_one(self):
        plan = plan_module([plan_row('one', fail=True, own_directory=True)])
        run, code, called = self.run_once(arguments(self.out), plan)
        self.assertEqual(code, 1)
        plan = plan_module([plan_row('one', own_directory=True)])
        again, code, called = self.run_once(arguments(self.out, resume=run.out, only=['one']), plan, previous=run.out)
        self.assertEqual((code, called), (0, ['one']))
        history = again.report['stages']['one']['history'][0]
        self.assertEqual((history['directory'], history['artifact']), ('one.attempt-1', 'one.attempt-1/result.json'))
        self.assertTrue((run.out / 'one.attempt-1/result.json').is_file() and (run.out / 'one/result.json').is_file())

    def test_the_rehearsal_plan_profile_never_qualifies_a_timed_step(self):
        plan = plan_module([plan_row('one')])
        state = ready(rehearsal=False, plan={'steps': []})
        for profile, because in (('rehearsal', ['rehearsal plan profile']), ('full', None)):
            args = arguments(self.out, rehearsal=False, plan_profile=profile)
            with mock.patch.object(rented_run.Run, 'correctness', lambda self: None), \
                    mock.patch.object(rented_run.Run, 'verify_outcomes', lambda self: None), \
                    mock.patch.object(rented_run.Run, 'baseline_gate', lambda self: (True, [])):
                run, code, called = self.run_once(args, plan, state=state)
            row = run.report['stages']['one']
            self.assertEqual(row['qualified'], because is None, profile)
            self.assertEqual(row.get('unqualified_because'), because)

    def test_noisy_host_and_tmpfs(self):
        plan = plan_module([plan_row('one')])
        state = ready(rehearsal=False, plan={'steps': []})
        state['quiet_findings'] = ['CPU 0 governor is powersave, not performance']
        args = arguments(self.out, rehearsal=False, plan_profile='full', modern_python=None)
        with mock.patch.object(rented_run.Run, 'correctness', lambda self: None), \
                mock.patch.object(rented_run.Run, 'verify_outcomes', lambda self: None):
            run, code, called = self.run_once(args, plan, state=state)
        self.assertIn('host is not quiet', ' '.join(run.report['timing']['blocked_by']))
        state['timing_refusals'] = ['the output directory is on tmpfs, where sync timings are meaningless']
        run, code, called = self.run_once(arguments(self.out, allow_noisy_host=True, allow_unqualified=True), plan, state=state)
        self.assertNotIn('one', called)
        self.assertIn('tmpfs', ' '.join(run.report['timing']['blocked_by']))


class Pieces(unittest.TestCase):
    def test_plan_contract_is_checked(self):
        good = plan_row('stock-get')
        rented_run.checked_plan(plan_module([good]), {})
        for change in ({'name': 'Bad_Name'}, {'name': 'functional'}, {'area': 'nowhere'}, {'artifact': '../x.json'},
                       {'artifact': '/abs.json'}, {'timeout': 0}, {'estimate_seconds': 1.5}, {'needs': ['postgres']},
                       {'command': 'echo'}, {'environment': {'A': 1}}):
            with self.assertRaises(ValueError, msg=str(change)):
                rented_run.checked_plan(plan_module([dict(good, **change)]), {})
        with self.assertRaisesRegex(ValueError, 'repeated'):
            rented_run.checked_plan(plan_module([good, good]), {})
        with self.assertRaisesRegex(ValueError, 'AREAS'):
            rented_run.checked_plan(plan_module([good], areas=['stock']), {})

    def test_the_controller_is_chosen_outside_both_roles_or_refused(self):
        self.assertEqual(rented_run.control_cpus(None, set(range(8)), {2}, {4, 5}), ('7', None))
        self.assertEqual(rented_run.control_cpus(None, {0, 1, 2}, {1}, {2}), ('0', None))
        self.assertIn('no CPU', rented_run.control_cpus(None, {1, 2}, {1}, {2})[1])
        self.assertIsNone(rented_run.control_cpus('6-7', set(range(8)), {2}, {4, 5})[1])
        for given in ('2', '5', '9', 'x'):
            self.assertIsNotNone(rented_run.control_cpus(given, set(range(8)), {2}, {4, 5})[1], given)

    def test_plan_downloads_are_checked(self):
        good = {'name': 'archive', 'url': 'https://example.org/a.tar.gz', 'sha256': 'a' * 64,
                'path': '.build/downloads/a.tar.gz', 'steps': ('stock-get',)}
        self.assertEqual(rented_run.plan_downloads(plan_module([], downloads=(good,)), ['stock-get'])[0]['steps'], ['stock-get'])
        for change in ({'url': 'http://example.org/a'}, {'sha256': 'b'}, {'path': '.build/a.tar.gz'}, {'path': '.build/downloads/../a'},
                       {'path': '/tmp/a'}, {'steps': ()}, {'steps': ('other',)}):
            with self.assertRaises(ValueError, msg=str(change)):
                rented_run.plan_downloads(plan_module([], downloads=(dict(good, **change),)), ['stock-get'])
        with self.assertRaisesRegex(ValueError, 'DOWNLOADS'):
            rented_run.plan_downloads(types.ModuleType('plan'))
        with tempfile.TemporaryDirectory() as folder:
            with mock.patch.object(rented_run, 'ROOT', Path(folder)):
                (Path(folder) / '.build/downloads').mkdir(parents=True)
                (Path(folder) / good['path']).write_text('x')
                state = rented_run.download_state(dict(good, sha256=rented_run.digest(Path(folder) / good['path'])))
                self.assertEqual(state, {'cached': True})
                self.assertFalse(rented_run.download_state(good)['cached'])

    def test_call_graphs_without_perf_are_a_finding(self):
        with mock.patch.object(rented_run.shutil, 'which', lambda name: None):
            probe = rented_run.call_graph_probe()
        self.assertFalse(probe['permitted'])
        self.assertIn('not installed', probe['reason'])

    def test_the_planning_figure_comes_from_recorded_durations(self):
        steps = rented_run.required_functional_steps('full')
        record = {'profile': 'full', 'recorded': '2026-11-18', 'machine': {'cpu': 'a test machine', 'cpus': 'CPUs 0 to 3'},
                  'stages': {name: 10 for name in rented_run.BUILDS if name != 'debug-build'} | {'virtual': 20, 'native': 30,
                                                                                                 'change-log-probe': 1, 'search-json-probe': 2},
                  'functional': {name: 100 for name in steps if not name.startswith('packages-')} | {'packages': 1000},
                  'partial': {'functional/packages': 'ended early'},
                  'covers': {'functional/packages': ['functional/' + name for name in steps if name.startswith('packages-')]}}
        rehearsal = {'profile': 'rehearsal', 'plan_profile': 'full', 'machine': {'cpu': 'another'}, 'plan': {'one': 500}}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'durations.json'
            path.write_text(json.dumps({'records': [record, rehearsal]}))
            args = arguments(Path(folder), rehearsal=False, plan_profile='full')
            plan = {'steps': [{'name': 'one', 'estimate_seconds': 7}, {'name': 'two', 'estimate_seconds': 9}]}
            figure = rented_run.planning_figure(args, plan, path)
        functional = 100 * len([name for name in steps if not name.startswith('packages-')]) + 1000
        self.assertEqual(figure['correctness_seconds'], 50 + 53 + functional)
        self.assertEqual(figure['unrecorded'], ['debug-build'])
        self.assertEqual(figure['lower_bounds'], {'functional/packages': 'ended early'})
        self.assertEqual((figure['plan_seconds'], figure['plan_steps_from_estimate']), (509, ['two']))
        line = rented_run.describe_estimate({'estimate': {'correctness_upper_bound_seconds': {'x': 3600}, 'plan_estimate_seconds': 16,
                                                          'planning': figure, 'disk_bytes_before_baseline': {}}})
        self.assertIn('planning figure', line)
        self.assertIn('from another machine, not a bound', line)
        self.assertIn('a test machine', line)
        self.assertIn('error', rented_run.planning_figure(args, plan, Path(folder) / 'missing.json'))
        tracked = rented_run.planning_figure(args, plan)
        self.assertNotIn('error', tracked)
        self.assertEqual(tracked['unrecorded'], ['debug-build'])

    def test_identity_ignores_what_timing_may_change(self):
        first, second = ready(), ready()
        second.update(boot_id_sha256='e' * 64, settings={'server_cpus': '3', 'port_base': 9000, 'plan_profile': 'rehearsal'},
                      plan={'steps': [{'name': 'x'}]}, quiet_findings=['noisy'])
        second['input_files'] = {'expected': {'path': '/other', 'sha256': 'f' * 64}}
        self.assertEqual(rented_run.identity(first), rented_run.identity(second))
        second['sizes'] = dict(second['sizes'], seeds=3)
        self.assertNotEqual(rented_run.identity(first), rented_run.identity(second))
        self.assertNotEqual(rented_run.identity(ready(rehearsal=True)), rented_run.identity(ready()))

    def test_functional_names_come_from_the_check(self):
        steps = rented_run.required_functional_steps('full')
        self.assertIn('search-advanced-reference', steps)
        self.assertNotIn('release-build', steps)
        self.assertTrue(all(name == name.lower() and '_' not in name for name in steps))

    def test_bundle_separates_private_files_and_clean_removes_them(self):
        with tempfile.TemporaryDirectory() as folder:
            run = Path(folder) / 'run-1'
            for relative, text in (('summary.json', '{"owed": []}'), ('inputs/capture.py', 'secret'),
                                   ('functional/search-capture/comparison.json', 'replies'),
                                   ('functional/search-capture.log', 'sections'), ('functional/summary.json', '{}'),
                                   ('virtual/summary.json', '{}')):
                (run / relative).parent.mkdir(parents=True, exist_ok=True)
                (run / relative).write_text(text)
            with contextlib.redirect_stdout(io.StringIO()):
                result = rented_run.bundle(run)
            with tarfile.open(result['main']['path']) as archive:
                names = archive.getnames()
            self.assertIn('run-1/virtual/summary.json', names)
            self.assertFalse(any('capture' in name for name in names))
            with tarfile.open(result['private']['path']) as archive:
                self.assertEqual(sorted(archive.getnames()), ['run-1/SHA256SUMS.private', 'run-1/functional/search-capture.log',
                                                              'run-1/functional/search-capture/comparison.json',
                                                              'run-1/inputs/capture.py'])
            sidecar = Path(result['main']['path'] + '.sha256').read_text().split()
            self.assertEqual(sidecar[0], rented_run.digest(result['main']['path']))
            with contextlib.redirect_stdout(io.StringIO()):
                rented_run.clean(run)
            self.assertFalse((run / 'inputs').exists() or (run / 'functional/search-capture').exists())
            self.assertTrue((run / 'functional/summary.json').is_file())
            broken = Path(folder) / 'broken.tar.gz'
            with tarfile.open(broken, 'w:gz') as archive:
                (Path(folder) / 'SHA256SUMS').write_text('0' * 64 + '  a\n')
                (Path(folder) / 'a').write_text('x')
                archive.add(Path(folder) / 'SHA256SUMS', arcname='r/SHA256SUMS')
                archive.add(Path(folder) / 'a', arcname='r/a')
            with self.assertRaisesRegex(ValueError, 'does not match'):
                rented_run.verify_bundle(broken, 'SHA256SUMS')

    def test_quiet_host_findings(self):
        fingerprint = {'frequency': {'2': {'scaling_governor': 'powersave'}}, 'smt': {'active': '1', 'control': 'on'},
                       'transparent_hugepage': {'enabled': '[always] madvise never'},
                       'filesystems': {'output': {'fstype': 'tmpfs'}}}
        with mock.patch.object(rented_run.shutil, 'which', lambda name: None):
            findings, refusals = rented_run.quiet_findings(fingerprint, [3], Path('/tmp'))
        text = ' '.join(findings)
        for word in ('powersave', 'multithreading', 'share physical cores', 'always', 'systemctl'):
            self.assertIn(word, text)
        self.assertEqual(len(refusals), 1)
        self.assertIn('tmpfs', refusals[0])
        self.assertIsNotNone(rented_run.mount_of(Path('/')))

    def test_staged_checksums_are_parsed_by_file_name(self):
        with tempfile.TemporaryDirectory() as folder:
            sums = Path(folder) / 'SHA256SUMS'
            sums.write_text('%s  capture.py\n%s *dir/observed.json\nnoise\n' % ('a' * 64, 'b' * 64))
            self.assertEqual(rented_run.parse_sums(sums), {'capture.py': 'a' * 64, 'observed.json': 'b' * 64})


if __name__ == '__main__':
    unittest.main()
