import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('readme_tables', ROOT/'test/readme_tables.py')
tables = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tables)
BINARY = ROOT/'bin/eski'


def skeleton():
    return '# Eski\n\n' + '\n\n'.join('<!-- BEGIN GENERATED '+name+' -->\n\n<!-- END GENERATED '+name+' -->' for name in tables.BLOCKS) + '\n'


class FixtureInputs:
    @classmethod
    def setUpClass(cls):
        cls.baseline = tables.validate_conformance(tables.read_json(ROOT/'test/conformance/baseline-redis.json'), 'baseline')
        cls.observed = tables.validate_conformance(tables.read_json(ROOT/'docs/data/conformance-redis.json'), 'observed')
        cls.dataset = tables.read_json(ROOT/'bench/testbed/runs/comparison-v1/dataset.json')


class Inputs(FixtureInputs, unittest.TestCase):
    def test_compact_snapshot_has_all_failure_identities_without_traces(self):
        self.assertEqual(len(self.observed['failing_tests']), self.observed['totals']['failed'])
        for unit in self.observed['units'].values():
            self.assertNotIn('tests', unit)
            self.assertNotIn('log', unit)
            for failure in unit['failures']:
                self.assertEqual(set(failure), {'test', 'category', 'reason'})
        text = json.dumps(self.observed)
        self.assertNotIn('/home/', text)
        self.assertNotIn('while executing', text)

    def test_compact_comparison_is_bound_to_the_baseline(self):
        baseline = copy.deepcopy(self.baseline)
        baseline['generated_at'] = 'different snapshot'
        with self.assertRaisesRegex(ValueError, 'another baseline'):
            tables.preserved_tests(baseline, self.observed)

    def test_conformance_rejects_mismatched_totals_and_suites(self):
        value = copy.deepcopy(self.observed)
        value['totals']['passed'] += 1
        with self.assertRaisesRegex(ValueError, 'totals disagree'):
            tables.validate_conformance(value, 'observed')
        value = copy.deepcopy(self.observed)
        value['suite']['sha256'] = 'another suite'
        with self.assertRaisesRegex(ValueError, 'different suites'):
            tables.preserved_tests(self.baseline, value)
        value = copy.deepcopy(self.observed)
        value['suite']['tags'] += ' -cluster'
        with self.assertRaisesRegex(ValueError, 'different tag filters'):
            tables.preserved_tests(self.baseline, value)
        for field, replacement in (('failing_tests', [None]), ('units', {'broken': None})):
            value = copy.deepcopy(self.observed)
            value[field] = replacement
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    tables.validate_conformance(value, 'observed')

    def test_recording_discards_assertion_snippets_and_recomputes_preservation(self):
        raw = copy.deepcopy(self.baseline)
        raw['suite']['server'] = '/home/example/private/server'
        next(unit for unit in raw['units'].values() if unit['failures'])['failures'][0]['message'] = 'private assertion code'
        compact = tables.compact_summary(raw, self.baseline)
        tables.validate_conformance(compact, 'recorded')
        text = json.dumps(compact)
        self.assertNotIn('/home/', text)
        self.assertNotIn('private assertion code', text)
        self.assertNotIn('"tests"', text)
        self.assertEqual(compact['baseline']['baseline_passed'], self.baseline['totals']['passed'])
        self.assertEqual(compact['baseline']['current_passed'], self.baseline['totals']['passed'])
        self.assertEqual(compact['baseline']['regressions'], [])

    def test_medians_use_included_benchmark_rows(self):
        dataset = copy.deepcopy(self.dataset)
        for row in dataset['rows']:
            if row['phase'] == 'calibration' or not row['included']:
                row['ops'] = 10**30
        for cell in dataset['summary']:
            if cell.get('ops'):
                cell['ops']['median'] = -1
        cells = tables.benchmark_cells(dataset)
        subject = cells[('get64-p1', 'eski-docker')]
        self.assertAlmostEqual(subject['ops']['median'], 203743.95)
        self.assertIsNone(cells[('mixed64-p16', 'eski-docker')]['ops'])
        self.assertEqual(len(cells[('mixed64-p16', 'eski-docker')]['excluded']), 4)
        ratio, limited = tables.benchmark_ratio(cells)
        self.assertAlmostEqual(ratio, 203743.95/185290.78)
        self.assertTrue(limited)

    def test_benchmark_rejects_duplicates_missing_repetitions_and_invalid_values(self):
        row_index = next(i for i, row in enumerate(self.dataset['rows']) if row['phase'] == 'benchmark')
        variations = []
        duplicate = copy.deepcopy(self.dataset)
        duplicate['rows'].append(copy.deepcopy(duplicate['rows'][row_index]))
        variations.append(duplicate)
        missing = copy.deepcopy(self.dataset)
        missing['rows'].pop(row_index)
        variations.append(missing)
        invalid = copy.deepcopy(self.dataset)
        included = next(row for row in invalid['rows'] if row['phase'] == 'benchmark' and row['included'])
        included['ops'] = float('nan')
        variations.append(invalid)
        counts = copy.deepcopy(self.dataset)
        counts['counts']['valid'] += 1
        variations.append(counts)
        annotation = copy.deepcopy(self.dataset)
        next(row for row in annotation['rows'] if row['phase'] == 'benchmark' and row['included'])['client_limited'] = 'false'
        variations.append(annotation)
        reasons = copy.deepcopy(self.dataset)
        next(row for row in reasons['rows'] if row['phase'] == 'benchmark' and not row['included'])['reasons'] = [None]
        variations.append(reasons)
        methodology = copy.deepcopy(self.dataset)
        methodology['design']['methodology'] = []
        variations.append(methodology)
        for dataset in variations:
            with self.subTest(counts=dataset.get('counts')):
                with self.assertRaises(ValueError):
                    tables.benchmark_cells(dataset)

    def test_run_directory_comes_from_the_rendered_dataset(self):
        self.assertEqual(tables.run_directory(self.dataset), 'bench/testbed/runs/comparison-v1')
        commands = {'ping': {'group': 'connection', 'summary': 'Pings.'}}
        renamed = copy.deepcopy(self.dataset)
        renamed['run']['root'] = 'cloud-v1'
        outputs = tables.render_outputs(commands, self.baseline, self.observed, renamed, skeleton())
        for name in ('README.md', 'docs/benchmarks.md'):
            self.assertNotIn('comparison-v1', outputs[name])
        self.assertIn('Recorded medians from `bench/testbed/runs/cloud-v1`', outputs['README.md'])
        self.assertIn('Generated from `bench/testbed/runs/cloud-v1/dataset.json`', outputs['docs/benchmarks.md'])
        self.assertIn('--benchmark-results bench/testbed/runs/cloud-v1`', outputs['docs/benchmarks.md'])
        self.assertIn('[recorded report](../bench/testbed/runs/cloud-v1/report.html)', outputs['docs/benchmarks.md'])
        self.assertIn('[cloud-v1 dataset](bench/testbed/runs/cloud-v1/dataset.json)', outputs['README.md'])
        self.assertIn('[self-contained report](bench/testbed/runs/cloud-v1/report.html)', outputs['README.md'])
        for value in (None, '', '../escape', 'two words', '.hidden', 'runs/cloud-v1'):
            broken = copy.deepcopy(self.dataset)
            broken['run']['root'] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'run.root'):
                tables.render_outputs(commands, self.baseline, self.observed, broken, skeleton())

    def test_new_machine_section_uses_the_run_and_names_existing_files(self):
        commands = {'ping': {'group': 'connection', 'summary': 'Pings.'}}
        page = tables.render_outputs(commands, self.baseline, self.observed, self.dataset, skeleton())['docs/benchmarks.md']
        section = page[page.index('## Run the comparison on a new machine'):page.index('## Local relative measurement')]
        self.assertIn('took 6.89 hours for 132 cases, with a median case of 80 seconds and a median gap of 110 seconds', section)
        self.assertIn('84 of the 124 valid measurements above are client limited', section)
        tokens = {token.strip('.,;:()') for token in re.split(r'[\s`]+', section)}
        named = sorted(token for token in tokens if re.fullmatch(r'(?:bench|test)/[\w./-]+\.(?:py|sh)|bench/testbed/design(?:s/[\w.-]+)?\.json', token))
        self.assertIn('bench/testbed/designs/cloud-two-client-cores.json', named)
        self.assertIn('bench/testbed/designs/cloud-four-client-cores.json', named)
        for name in named:
            self.assertTrue((ROOT/name).is_file(), name)
        untimed = copy.deepcopy(self.dataset)
        for row in untimed['rows']:
            row.pop('started_at', None)
        page = tables.render_outputs(commands, self.baseline, self.observed, untimed, skeleton())['docs/benchmarks.md']
        self.assertNotIn('The recorded run above took', page)
        self.assertIn('plan about 6 hours of machine time', page)

    def test_local_measurement_section_renders_the_recorded_floor(self):
        commands = {'ping': {'group': 'connection', 'summary': 'Pings.'}}
        floor = dict(schema=tables.AB_FLOOR_SCHEMA, session='aa-test', date='2026-11-02', binary_sha256='c' * 64, cpu_model='Test CPU', kernel='7.0',
                     governor='performance', epp='performance', cpus=dict(server='1', server_b='2'), rounds=8, seconds=20, warmup=5, load=[1.5, 2.5],
                     workloads={'get64-p16-max': dict(clean_pairs=4, median=1.002, min=0.994, max=1.012, floor=0.015),
                                'ping-p16-r20k': dict(clean_pairs=0, median=None, min=None, max=None, floor=None)})
        page = tables.render_outputs(commands, self.baseline, self.observed, self.dataset, skeleton(), floor)['docs/benchmarks.md']
        self.assertIn('## Local relative measurement', page)
        self.assertIn('| get64-p16-max | 4 | 1.002 [0.994, 1.012] | 1.5% |', page)
        self.assertIn('| ping-p16-r20k | 0 | insufficient | — |', page)
        self.assertIn('A/A session `aa-test` of one release build against itself (sha256 `cccccccccccc`)', page)
        self.assertIn('with a 1-minute load of 1.50 to 2.50', page)
        missing = tables.render_outputs(commands, self.baseline, self.observed, self.dataset, skeleton())['docs/benchmarks.md']
        self.assertIn('No reference floor is recorded.', missing)
        for broken in (dict(floor, schema='other'), dict(floor, workloads={}), dict(floor, workloads={'x': dict(clean_pairs=-1)}),
                       dict(floor, workloads={'x': dict(clean_pairs=1, floor=float('nan'))}), {k: v for k, v in floor.items() if k != 'cpus'}):
            with self.subTest(broken=sorted(broken)), self.assertRaises(ValueError):
                tables.render_outputs(commands, self.baseline, self.observed, self.dataset, skeleton(), broken)

    def test_default_run_is_the_latest_finished_recorded_run(self):
        self.assertEqual(tables.published_run(ROOT), (ROOT/'bench/testbed/runs/comparison-v1/dataset.json').resolve())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runs = root/tables.RUNS
            for name, finished in (('comparison-v1', 1.0), ('cloud-v1', 2.0), ('unfinished', None)):
                (runs/name).mkdir(parents=True)
                (runs/name/'dataset.json').write_text(json.dumps(dict(run=dict(root=name, finished_at=finished))))
            self.assertEqual(tables.published_run(root), (runs/'cloud-v1'/'dataset.json').resolve())
            (runs/'cloud-v1'/'dataset.json').write_text(json.dumps(dict(run=dict(root='cloud-v1', finished_at=1.0))))
            with self.assertRaisesRegex(ValueError, 'no single latest finished run'):
                tables.published_run(root)
            with self.assertRaisesRegex(ValueError, 'no single latest finished run'):
                tables.published_run(root/'empty')

    def test_ratio_requires_a_valid_nonzero_reference(self):
        cells = tables.benchmark_cells(self.dataset)
        cells[('get64-p1', 'redis')]['ops']['median'] = 0
        with self.assertRaisesRegex(ValueError, 'ratio needs valid'):
            tables.benchmark_ratio(cells)

    def test_failure_categories_distinguish_exclusions_and_actual_gaps(self):
        self.assertIn('outside the single-node scope', tables.failure_explanation('type/list', 'SWAPDB', 'unknown SYNC'))
        self.assertIn('compatibility gap', tables.failure_explanation('type/list', 'dirty', 'Expected 3 == 2'))
        self.assertIn('compatibility gap', tables.failure_explanation('pause', 'scripts are blocked', 'Timeout'))
        self.assertIn('compatibility gap', tables.failure_explanation('pause', 'active expiry', 'Expected 2 == 0'))

    def test_resp_reader_accepts_nested_values_and_rejects_truncation(self):
        connection = object.__new__(tables.Connection)
        connection.file = io.BytesIO(b'*3\r\n$3\r\nGET\r\n:1\r\n*1\r\n+OK\r\n')
        self.assertEqual(connection.reply(), ['GET', 1, ['OK']])
        for payload in (b'$4\r\na', b'+bad', b'*1\r\n', b'$-2\r\n', b'?unknown\r\n'):
            connection.file = io.BytesIO(payload)
            with self.subTest(payload=payload):
                with self.assertRaises(ValueError):
                    connection.reply()

    def test_inventory_detects_missing_registered_names(self):
        class Fake:
            def call(self, *arguments):
                return {'DOCS': ['ping', ['group', 'connection', 'summary', 'Pings.']], 'LIST': ['ping', 'echo'], 'COUNT': 2}[arguments[1]]
        with self.assertRaisesRegex(ValueError, 'missing: echo'):
            tables.command_inventory(Fake())

    def test_command_table_preserves_code_placeholders_pipes_and_backticks(self):
        commands = {'example': {'group': 'string', 'summary': 'Choose <key> | <other>.', 'arguments': [
            {'type': 'string', 'name': 'key'},
            {'type': 'oneof', 'arguments': [{'type': 'string', 'name': 'left'}, {'type': 'string', 'name': 'right'}]},
            {'type': 'pure-token', 'token': '`literal``'}]}}
        commands['script|debug'] = {'group': 'scripting', 'summary': 'Sets the script debug mode.'}
        commands['script|load'] = {'group': 'scripting', 'summary': 'Compiles and caches source.'}
        rendered = tables.command_table(commands)
        self.assertIn('| `EXAMPLE` | ``` <key> (<left> \\| <right>) `LITERAL`` ``` | Choose &lt;key&gt; \\| &lt;other&gt;. |', rendered)
        self.assertNotIn('&lt;key&gt; (', rendered)
        self.assertEqual(tables.table_code('`literal`'), '`` `literal` ``')
        self.assertEqual(tables.table_code('  spaced  '), '`   spaced   `')
        debug_row = next(line for line in rendered.splitlines() if line.startswith('| `SCRIPT DEBUG` |'))
        load_row = next(line for line in rendered.splitlines() if line.startswith('| `SCRIPT LOAD` |'))
        self.assertNotIn('Unsupported subcommand', debug_row)
        self.assertNotIn('Unsupported', load_row)
        self.assertNotIn('Compatibility entry', load_row)


    def clean_observed(self):
        observed = copy.deepcopy(self.observed)
        for unit in observed['units'].values():
            unit['failed'] = 0
            unit['errored'] = 0
            unit['failures'] = []
        observed['totals']['failed'] = 0
        observed['totals']['errored'] = 0
        observed['failing_tests'] = []
        return tables.validate_conformance(observed, 'clean control')

    def test_readme_table_uses_observed_units_and_keeps_historical_baseline_labelled(self):
        commands = {'ping': {'group': 'connection', 'summary': 'Pings.'}}
        outputs = tables.render_outputs(commands, self.baseline, self.observed, self.dataset, skeleton())
        added_unit = sorted(set(self.observed['units']) - set(self.baseline['units']))[0]
        unit = self.observed['units'][added_unit]
        row = '| %s | %d | %d | %d | %d |' % (added_unit, unit['passed'], unit['failed'], unit['skipped'], unit['errored'])
        self.assertIn(row, outputs['README.md'])
        self.assertIn('## Protected historical baseline', outputs['docs/conformance.md'])
        self.assertIn('| **Total** | **1504** | **6** | **120** | **0** |', outputs['docs/conformance.md'])

    def test_clean_snapshot_does_not_claim_remaining_failures(self):
        commands = {'ping': {'group': 'connection', 'summary': 'Pings.'}}
        outputs = tables.render_outputs(commands, self.baseline, self.clean_observed(), self.dataset, skeleton())
        self.assertIn('No test failures or unit errors were recorded', outputs['README.md'])
        self.assertNotIn('remaining failures', outputs['README.md'])
        self.assertNotIn('compatibility gaps listed below', outputs['docs/conformance.md'])
        self.assertIn('No test failures were recorded.', outputs['docs/conformance.md'])
        self.assertIn('--tags "-needs:repl"', outputs['docs/conformance.md'])

    def test_unit_errors_prevent_a_clean_result_even_without_test_failures(self):
        commands = {'ping': {'group': 'connection', 'summary': 'Pings.'}}
        observed = self.clean_observed()
        next(iter(observed['units'].values()))['errored'] = 1
        observed['totals']['errored'] = 1
        tables.validate_conformance(observed, 'unit error control')
        outputs = tables.render_outputs(commands, self.baseline, observed, self.dataset, skeleton())
        self.assertIn('**1 unit errors**', outputs['README.md'])
        self.assertNotIn('No test failures or unit errors were recorded', outputs['README.md'])
        self.assertNotIn('No test failures or unit errors were recorded', outputs['docs/conformance.md'])
        self.assertIn('Unit errors remain visible', outputs['docs/conformance.md'])

    def test_additional_compared_passes_do_not_replace_the_protected_baseline(self):
        commands = {'ping': {'group': 'connection', 'summary': 'Pings.'}}
        baseline_before = copy.deepcopy(self.baseline)
        observed = tables.compact_summary(copy.deepcopy(self.baseline), self.baseline)
        next(iter(observed['units'].values()))['passed'] += 24
        observed['totals']['passed'] += 24
        tables.validate_conformance(observed, 'additional pass control')
        outputs = tables.render_outputs(commands, self.baseline, observed, self.dataset, skeleton())
        self.assertIn('**1504 / 1504 baseline passes**', outputs['README.md'])
        self.assertIn('**1528 passes in the 28 compared units**', outputs['README.md'])
        self.assertIn('**24 additional passes**', outputs['README.md'])
        self.assertNotIn('1528 / 1528 baseline passes', outputs['README.md'])
        self.assertEqual(self.baseline, baseline_before)


@unittest.skipUnless(BINARY.is_file(), 'build bin/eski for live documentation tests')
class LiveInputs(FixtureInputs, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        with tables.server_connection(BINARY) as connection:
            cls.commands = tables.command_inventory(connection)

    def test_live_inventory_covers_registration_and_repeated_starts_are_deterministic(self):
        with tables.server_connection(BINARY) as connection:
            commands = tables.command_inventory(connection)
            self.assertEqual(set(commands), set(connection.call('COMMAND', 'LIST')))
            self.assertEqual(sum('|' not in name for name in commands), connection.call('COMMAND', 'COUNT'))
        self.assertEqual(self.commands, commands)
        self.assertGreater(len(commands), 200)

    def test_server_is_stopped_after_an_exception(self):
        endpoint = None
        with self.assertRaisesRegex(RuntimeError, 'stop the test'):
            with tables.server_connection(BINARY) as connection:
                endpoint = connection.socket.getpeername()
                raise RuntimeError('stop the test')
        with self.assertRaises(OSError):
            socket.create_connection(endpoint, timeout=0.5)

    def test_generated_readme_preserves_names_limits_and_version_policy(self):
        outputs = tables.render_outputs(self.commands, self.baseline, self.observed, self.dataset, skeleton())
        readme = outputs['README.md']
        for name in self.commands:
            self.assertIn('`'+name.upper().replace('|', ' ')+'`', readme)
        self.assertIn('excluded (4)', readme)
        self.assertIn('client limited', readme)
        self.assertNotIn('Redis 7', readme)
        self.assertNotIn('Valkey 8', readme)
        self.assertNotIn('Dragonfly 2', readme)
        self.assertIn('thermal_throttling', outputs['docs/benchmarks.md'])
        self.assertIn('baseline passes', outputs['docs/img/conformance.svg'])
        self.assertIn('observed, client limited', outputs['docs/img/benchmark-ratio.svg'])
        with self.assertRaisesRegex(ValueError, 'competitor server versions'):
            tables.render_outputs(self.commands, self.baseline, self.observed, self.dataset, skeleton()+'\nRedis 7.4\n')

    def fixture(self, directory):
        root = Path(directory)
        for name in ('test/conformance/baseline-redis.json', 'docs/data/conformance-redis.json', 'bench/testbed/runs/comparison-v1/dataset.json'):
            target = root/name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT/name, target)
        (root/'README.md').write_text(skeleton())
        return root

    def cli(self, root, *arguments):
        return subprocess.run([sys.executable, '-I', str(ROOT/'test/readme_tables.py'), '--root', str(root), '--server-binary', str(BINARY.resolve()), *arguments], capture_output=True, text=True, timeout=30)

    def tree_state(self, root):
        return {str(p.relative_to(root)): (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns) for p in root.rglob('*') if p.is_file()}

    def test_cli_generation_is_deterministic_and_check_does_not_write(self):
        with tempfile.TemporaryDirectory(prefix='eski-doc-test-') as directory:
            root = self.fixture(directory)
            result = self.cli(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            before = self.tree_state(root)
            result = self.cli(root, '--check')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.tree_state(root), before)
            result = self.cli(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.tree_state(root), before)

    def test_cli_follows_the_latest_run_and_rejects_a_misplaced_dataset(self):
        with tempfile.TemporaryDirectory(prefix='eski-doc-test-') as directory:
            root = self.fixture(directory)
            dataset = copy.deepcopy(self.dataset)
            dataset['run'].update(root='cloud-v1', finished_at=dataset['run']['finished_at'] + 1)
            target = root/'bench/testbed/runs/cloud-v1/dataset.json'
            target.parent.mkdir(parents=True)
            target.write_text(json.dumps(dataset))
            result = self.cli(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Generated from `bench/testbed/runs/cloud-v1/dataset.json`', (root/'docs/benchmarks.md').read_text())
            self.assertIn('Recorded medians from `bench/testbed/runs/cloud-v1`', (root/'README.md').read_text())
            self.assertEqual(self.cli(root, '--check').returncode, 0)
            self.assertEqual(self.cli(root, '--check', '--benchmark-results', 'bench/testbed/runs/comparison-v1').returncode, 1)
            misplaced = root/'bench/testbed/runs/other/dataset.json'
            misplaced.parent.mkdir(parents=True)
            misplaced.write_text(json.dumps(dataset))
            before = self.tree_state(root)
            result = self.cli(root, '--benchmark-results', 'bench/testbed/runs/other')
            self.assertEqual(result.returncode, 2)
            self.assertIn('bench/testbed/runs/cloud-v1/dataset.json', result.stderr)
            self.assertEqual(self.tree_state(root), before)

    def test_check_reports_missing_output_without_creating_it(self):
        with tempfile.TemporaryDirectory(prefix='eski-doc-test-') as directory:
            root = self.fixture(directory)
            before = self.tree_state(root)
            result = self.cli(root, '--check')
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('docs/commands.md', result.stderr)
            self.assertEqual(self.tree_state(root), before)

    def test_check_detects_readme_and_badge_drift_without_repairing(self):
        with tempfile.TemporaryDirectory(prefix='eski-doc-test-') as directory:
            root = self.fixture(directory)
            self.assertEqual(self.cli(root).returncode, 0)
            (root/'docs/img/conformance.svg').write_text('stale')
            readme = root/'README.md'
            readme.write_text(readme.read_text().replace('baseline passes', 'wrong summary')+'\n')
            before = self.tree_state(root)
            result = self.cli(root, '--check')
            self.assertEqual(result.returncode, 1)
            self.assertIn('README.md', result.stderr)
            self.assertIn('docs/img/conformance.svg', result.stderr)
            self.assertEqual(self.tree_state(root), before)

    def test_bad_inputs_and_missing_markers_do_not_partially_rewrite(self):
        with tempfile.TemporaryDirectory(prefix='eski-doc-test-') as directory:
            root = self.fixture(directory)
            (root/'README.md').write_text('# Missing blocks\n')
            before = self.tree_state(root)
            result = self.cli(root)
            self.assertEqual(result.returncode, 2)
            self.assertIn('marker pair', result.stderr)
            self.assertEqual(self.tree_state(root), before)
            (root/'test/conformance/baseline-redis.json').write_text('{}')
            before = self.tree_state(root)
            result = self.cli(root)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(self.tree_state(root), before)

    def test_recording_updates_a_compact_snapshot_and_check_cannot_record(self):
        with tempfile.TemporaryDirectory(prefix='eski-doc-test-') as directory:
            root = self.fixture(directory)
            source = root/'raw.json'
            source.write_text(json.dumps(self.baseline))
            raw_before = source.read_bytes()
            result = self.cli(root, '--record-conformance', 'raw.json')
            self.assertEqual(result.returncode, 0, result.stderr)
            snapshot = json.loads((root/'docs/data/conformance-redis.json').read_text())
            self.assertEqual(snapshot['schema'], 'eski-docs-conformance-v1')
            self.assertEqual(snapshot['totals']['passed'], self.baseline['totals']['passed'])
            self.assertEqual(source.read_bytes(), raw_before)
            before = self.tree_state(root)
            result = self.cli(root, '--check', '--record-conformance', 'raw.json')
            self.assertEqual(result.returncode, 2)
            self.assertEqual(self.tree_state(root), before)


if __name__ == '__main__':
    unittest.main()
